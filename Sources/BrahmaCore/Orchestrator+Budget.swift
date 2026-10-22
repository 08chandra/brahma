import Foundation
import GRDB

// Token and cost accounting and the per-item budget step of `Store.endTurn` (Task 14a). Kept apart from
// `Orchestrator.swift` so the turn-end transaction only calls into it.

/// What the stream said about a turn that is not in its `TurnResult`: recorded on the turn row.
struct TurnTelemetry: Sendable, Equatable {
    var toolSignature: String? = nil
    var workflowAgents = 0
    var subagentsSpawned = 0
    /// Appended to the turn's `modeReason` (for example that the org's effort cap lowered the requested effort).
    var modeNote: String? = nil
}

/// One turn's accounting, worked out inside the turn-end transaction.
struct TurnAccounting: Equatable {
    /// This turn's own cost: the result's `total_cost_usd` minus the session's previous total (probe L-4: the total is
    /// cumulative over `--resume`). Nil when the turn reported no cost.
    var cost: Double?
    var sessionId: String?
    var sessionTotal: Double?
    var usage: TurnUsage?
    var modelsUsed: [String] = []
}

extension Store {
    /// Records which item a turn works on and what kind of turn it is. The orchestrator calls it once the turn's lease
    /// and context are known; `endTurn` falls back to the agent's lease when no item was recorded.
    func setTurnContext(turnId: String, kind: TurnKind, itemId: String?) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE turn SET kind = ?, itemId = ? WHERE id = ?", arguments: [kind.rawValue, itemId, turnId])
        }
    }

    /// The effort tier the next work turn of the agent runs under: its leased item's tier. An item whose spec nobody
    /// trusted yet never gets a tier model (an agent could otherwise author itself onto opus by writing `L`).
    func workTier(agentId: String) throws -> EffortTier? {
        try writer.read { db in
            guard let lease = try WorkLease.filter(Column("agentId") == agentId).fetchOne(db),
                  let item = try WorkItem.fetchOne(db, key: lease.itemId) else { return nil }
            if TierBudget.of(item.tier).model != nil, item.specConfirmedBy == nil { return nil }
            return item.tier
        }
    }

    /// The cost of a turn that reported `total` for `sessionId`: the total less the largest total any earlier turn of that
    /// session recorded. A total that went down starts over (a new session under a reused id).
    static func turnCost(db: Database, turnId: String, sessionId: String?, total: Double) throws -> Double {
        guard let sessionId, !sessionId.isEmpty else { return total }
        let previous = try Double.fetchOne(db, sql: """
            SELECT MAX(sessionTotalUSD) FROM turn WHERE sessionId = ? AND id <> ? AND sessionTotalUSD IS NOT NULL
            """, arguments: [sessionId, turnId]) ?? 0
        return total >= previous ? total - previous : total
    }

    static func accounting(db: Database, turnId: String, end: TurnEnd) throws -> TurnAccounting {
        let result: TurnResult?
        switch end {
        case .succeeded(let r, _), .capped(let r, _): result = r
        case .interrupted(let partial): result = partial
        case .failed(_, _, let partial): result = partial
        default: result = nil
        }
        guard let result else { return TurnAccounting() }
        let session = result.sessionId.isEmpty ? nil : result.sessionId
        let cost = try result.costUSD.map { try turnCost(db: db, turnId: turnId, sessionId: session, total: $0) }
        return TurnAccounting(cost: cost, sessionId: session, sessionTotal: result.costUSD, usage: result.usage,
                              modelsUsed: result.modelsUsed)
    }

    /// Writes everything the accounting and telemetry add to the closed turn.
    static func writeAccounting(db: Database, turnId: String, accounting a: TurnAccounting, telemetry t: TurnTelemetry,
                                end: TurnEnd, resetSession: Bool) throws {
        guard var turn = try Turn.fetchOne(db, key: turnId) else { return }
        turn.costLE = a.cost
        turn.sessionId = a.sessionId
        turn.sessionTotalUSD = a.sessionTotal
        turn.modelsUsed = a.modelsUsed.isEmpty ? nil : a.modelsUsed.joined(separator: ",")
        // A claim made in the middle of the turn left no item on the row: attribute the turn to the item the agent holds now,
        // so the item's usage counts it (and the budget step below sees it).
        if turn.itemId == nil,
           let leased = try WorkLease.filter(Column("agentId") == turn.agentId).fetchOne(db),
           let item = try WorkItem.fetchOne(db, key: leased.itemId), item.companyId == turn.companyId {
            turn.itemId = item.id
        }
        if let u = a.usage {
            turn.inputTokens = u.inputTokens; turn.outputTokens = u.outputTokens
            turn.cacheReadTokens = u.cacheReadTokens; turn.cacheCreationTokens = u.cacheCreationTokens
        }
        turn.toolSignature = t.toolSignature
        turn.workflowAgents = t.workflowAgents
        turn.subagentsSpawned = t.subagentsSpawned
        if let note = t.modeNote { turn.modeReason = [turn.modeReason, note].compactMap { $0 }.joined(separator: "; ") }
        switch end {
        case .capped(let r, _): turn.stopReason = r.stopReason
        default: break
        }
        if resetSession { turn.stopReason = TurnStop.sessionReset }
        try turn.update(db)
    }

    /// The item a turn worked on: the one recorded at its start, else the agent's lease.
    private static func turnItem(db: Database, turn: Turn) throws -> WorkItem? {
        var itemId = turn.itemId
        if itemId == nil { itemId = try WorkLease.filter(Column("agentId") == turn.agentId).fetchOne(db)?.itemId }
        guard let itemId, let item = try WorkItem.fetchOne(db, key: itemId), item.companyId == turn.companyId else { return nil }
        return item
    }

    /// The nearest manager above the agent who is not killed, else the owner. Returns the DM address.
    static func escalationTarget(db: Database, from agent: Agent) throws -> String {
        var next = agent.managerId
        var seen = Set<String>([agent.id])
        while let id = next, seen.insert(id).inserted {
            guard let ancestor = try Agent.fetchOne(db, key: id) else { break }
            if ancestor.state != .killed { return ancestor.name }
            next = ancestor.managerId
        }
        return "owner"
    }

    /// Budget step of a counted work turn: an item that went over its tier's turns, counted tokens or cost is blocked
    /// (its lease released, the reason recorded), the manager told once, and only a manager, executive or the owner can
    /// unblock it. Review turns, infrastructure failures and turns without an item are not subject to it.
    func budgetStep(db: Database, turnId: String, agent: Agent, now: Date) throws {
        guard let turn = try Turn.fetchOne(db, key: turnId), turn.kind == TurnKind.work.rawValue, !turn.infra,
              var item = try Store.turnItem(db: db, turn: turn),
              item.status == .inProgress || item.status == .ready else { return }
        let usage = try Store.itemUsage(db: db, itemId: item.id)
        let budget = TierBudget.of(item.tier)
        let costCap = budget.maxCostLE + item.budgetBoostLE
        guard usage.turns > budget.maxTurns || usage.tokens > budget.maxTokens || usage.costLE > costCap else { return }

        let calibration = try Store.calibration(db)
        let parts = BudgetText.parts(usage: usage, budget: budget, costCapLE: costCap, pctPerDollar: calibration.pctPerDollar)
        let from = item.status
        item.status = .blocked
        item.blockedReason = String("over budget: \(parts)".prefix(500))
        item.blockedSinceActive = try Store.activeNow(db: db, companyId: item.companyId)
        item.stopReason = "budget"
        item.updatedAt = now
        try item.update(db)
        let lease = try WorkLease.fetchOne(db, key: item.id)
        if lease != nil { try db.execute(sql: "DELETE FROM workLease WHERE itemId = ?", arguments: [item.id]) }

        try recordItemEvent(db: db, item: item, actor: "system", kind: .statusChanged,
                            text: "\(from.title) → \(WorkItemStatus.blocked.title): over budget", now: now)
        try recordItemEvent(db: db, item: item, actor: "system", kind: .budgetExceeded,
                            text: "over its tier \(item.tier.label) budget: \(parts)", now: now)
        if let lease {
            try recordItemEvent(db: db, item: item, actor: "system", kind: .leaseReleased,
                                text: "lease released: over budget", alsoNotify: [lease.agentId], now: now)
        }
        let assignee = try item.ownerId.flatMap { try Agent.fetchOne(db, key: $0) } ?? agent
        let target = try Store.escalationTarget(db: db, from: assignee)
        let text = "\(item.key) (@\(assignee.name)) is over its tier \(item.tier.label) budget: \(parts). "
            + BudgetText.escalationAdvice
        try MessageRouter(store: self).sendDM(db: db, companyId: item.companyId, from: .system, to: target, text: text, now: now)
    }

    /// Parks an agent until the doctor passes again (an unexpected model billed, or the session did not match the mode).
    func holdForDoctor(agentId: String, reason: String, now: Date) throws {
        try writer.write { db in
            guard let a = try Agent.fetchOne(db, key: agentId), a.state == .ready || a.state == .sleeping else { return }
            try Store.transition(db: db, agentId: agentId, to: .blocked,
                                 blocker: .owner(reason: "\(Store.doctorHoldPrefix)\(reason)"), now: now)
        }
    }

    static let doctorHoldPrefix = "doctor re-run needed: "

    /// A passing doctor lets the agents parked by `holdForDoctor` run again.
    func releaseDoctorHeldAgents(now: Date) throws {
        try writer.write { db in
            for a in try Agent.filter(Column("state") == AgentState.blocked.rawValue).fetchAll(db) {
                guard case .owner(let reason)? = a.blocker, reason.hasPrefix(Store.doctorHoldPrefix) else { continue }
                try Store.transition(db: db, agentId: a.id, to: a.paused ? .sleeping : .ready, now: now)
            }
        }
    }
}

extension Orchestrator {
    /// The per-turn assertions after a result: fast mode must be off, only expected models may bill. Alerts the owner
    /// once per kind and parks the agent until the doctor passes when an unexpected model billed. Safety-fallback
    /// models are only recorded.
    nonisolated func auditResult(_ result: TurnResult, request: TurnRequest, initModel: String?, agent: Agent,
                                 turn: Turn, now: Date) {
        // `modelUsage` is cumulative over `--resume`: only models no earlier turn of this session billed are judged.
        var seen = Set<String>()
        if !result.sessionId.isEmpty {
            let rows = (try? store.writer.read { db in
                try String.fetchAll(db, sql: "SELECT modelsUsed FROM turn WHERE sessionId = ? AND id <> ? AND modelsUsed IS NOT NULL",
                                    arguments: [result.sessionId, turn.id])
            }) ?? []
            for row in rows { seen.formUnion(row.split(separator: ",").map(String.init)) }
        }
        let f = TurnAudit.findings(result: result, initModel: initModel, main: request.agent.model,
                                   fallback: TurnProfileCompiler.profile(for: request).fallbackModel, expectations: request.expectations,
                                   previouslySeen: seen)
        if let fast = f.fastMode {
            attempt {
                try EngineAlerts.raise(store: store, text: "Fast mode is not off for @\(agent.name) (\(fast)). Fast mode bills outside "
                                       + "your usage windows; check ~/.claude/settings.json, then run `brahma doctor`.",
                                       now: now, reason: "fast-mode")
            }
        }
        if !f.unexpectedModels.isEmpty {
            let models = f.unexpectedModels.joined(separator: ", ")
            attempt {
                try EngineAlerts.raise(store: store, text: "A turn of @\(agent.name) billed an unexpected model (\(models)). Its next turn "
                                       + "waits until `brahma doctor` passes again.", now: now, reason: "model")
                try store.holdForDoctor(agentId: agent.id, reason: "unexpected model \(models)", now: now)
            }
        }
        if !f.safetyFallbacks.isEmpty {
            attempt {
                try store.appendEvent(ActivityEvent(
                    companyId: agent.companyId, agentId: agent.id, turnId: turn.id, kind: .usage,
                    text: "@\(agent.name) turn billed the safety-fallback model \(f.safetyFallbacks.joined(separator: ", ")); recorded only",
                    createdAt: now))
            }
        }
    }
}
