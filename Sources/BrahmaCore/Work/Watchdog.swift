import Foundation
import GRDB

/// What the stream of one turn says about looping: the longest run of identical consecutive tool calls (name and input)
/// and of identical consecutive tool results, and the digest of all its calls.
public struct TurnObservation: Equatable, Sendable {
    public var maxRepeatedCall: Int
    public var maxRepeatedResult: Int
    public var signature: String?

    public init(maxRepeatedCall: Int = 0, maxRepeatedResult: Int = 0, signature: String? = nil) {
        self.maxRepeatedCall = maxRepeatedCall; self.maxRepeatedResult = maxRepeatedResult; self.signature = signature
    }

    /// The longest run of equal neighbours in `values` (0 when empty).
    public static func longestRun(_ values: [String]) -> Int {
        var best = 0, run = 0
        var previous: String?
        for v in values {
            run = v == previous ? run + 1 : 1
            previous = v
            best = max(best, run)
        }
        return best
    }
}

/// The watchdog's limits: nudge and escalate after this many judged turns without work-item progress; a loop is this many
/// identical consecutive tool calls or results in one turn, or this many turns in a row with the same tool-call signature.
public struct WatchdogConfig: Equatable, Sendable {
    public var nudgeAfter: Int
    public var escalateAfter: Int
    public var repeatLimit: Int
    public var signatureTurns: Int

    public init(nudgeAfter: Int = 3, escalateAfter: Int = 5, repeatLimit: Int = 5, signatureTurns: Int = 3) {
        self.nudgeAfter = nudgeAfter; self.escalateAfter = escalateAfter; self.repeatLimit = repeatLimit
        self.signatureTurns = signatureTurns
    }

    public static let standard = WatchdogConfig()
}

public enum WatchdogVerdict: Equatable, Sendable {
    case ok
    case nudge(Int)
    case escalate(String)
}

public enum Watchdog {
    /// Failed (non-inconclusive) check outcomes on one item since its latest claim before the engine takes it back.
    public static let failedCheckLimit = 3

    /// The pure rule. `recentSignatures`: the tool-call signatures of the agent's latest judged turns, this one first.
    /// Returns the verdict and the new count of turns without progress.
    public static func evaluate(progressed: Bool, hasWork: Bool, previousCount: Int, recentSignatures: [String?],
                                observation: TurnObservation, config: WatchdogConfig = .standard) -> (verdict: WatchdogVerdict, count: Int) {
        if observation.maxRepeatedCall >= config.repeatLimit {
            return (.escalate("loop: the same tool call \(observation.maxRepeatedCall) times in a row"), 0)
        }
        if observation.maxRepeatedResult >= config.repeatLimit {
            return (.escalate("loop: the same tool result \(observation.maxRepeatedResult) times in a row"), 0)
        }
        if !progressed, recentSignatures.count >= config.signatureTurns {
            let first = Array(recentSignatures.prefix(config.signatureTurns))
            if let s = first[0], first.allSatisfy({ $0 == s }) {
                return (.escalate("loop: identical tool calls in \(config.signatureTurns) turns"), 0)
            }
        }
        if progressed || !hasWork { return (.ok, 0) }
        let n = previousCount + 1
        if n >= config.escalateAfter { return (.escalate("no work-item progress in \(n) turns"), 0) }
        if n == config.nudgeAfter { return (.nudge(n), n) }
        return (.ok, n)
    }

    /// The item's `stopReason` for an escalation reason.
    static func stopReason(for reason: String) -> String {
        reason.hasPrefix("loop") ? "loop" : "no-progress"
    }

    static func nudgeText(_ n: Int) -> String {
        "Watchdog: \(n) turns without work-item progress. Update your item, write a hand-off, or call set_blocked with what you need."
    }

    /// Work-item event kinds Task 13 records when a sprint is planned or closed (matched by name; harmless when absent).
    static let sprintProgressKinds = ["sprintPlanned", "sprintClosed"]
}

extension Store {
    /// The watchdog step of a counted turn (inside `endTurn`). Work turns are judged; a review or audit turn that recorded a
    /// decision resets the counter and is otherwise left out. Returns the blocker the agent ends in when it escalated.
    func watchdogStep(db: Database, turnId: String, agent: Agent, observation: TurnObservation, now: Date) throws -> Blocker? {
        guard let turn = try Turn.fetchOne(db, key: turnId), !turn.infra, turn.sessionResetReason == nil,
              turn.stopReason != TurnStop.sessionReset,
              var current = try Agent.fetchOne(db, key: agent.id) else { return nil }
        let progressed = try Store.madeProgress(db: db, agent: current, turn: turn)
        switch turn.kind {
        case .work: break
        case .review, .audit:
            if progressed, current.turnsWithoutProgress != 0 {
                current.turnsWithoutProgress = 0
                try current.update(db, columns: ["turnsWithoutProgress"])
            }
            return nil
        case .notice, .plan: return nil
        }
        let work = try Store.watchdogWork(db: db, agentId: current.id)
        let earlier = try String?.fetchAll(db, sql: """
            SELECT toolSignature FROM turn
            WHERE agentId = ? AND id <> ? AND kind = 'work' AND infra = 0 AND sessionResetReason IS NULL
              AND (outcome = 'succeeded' OR stopReason IN (?, ?))
            ORDER BY startedAt DESC, rowid DESC LIMIT ?
            """, arguments: [current.id, turn.id, TurnStop.turnCap, TurnStop.budgetCap, WatchdogConfig.standard.signatureTurns - 1])
        let (verdict, count) = Watchdog.evaluate(progressed: progressed, hasWork: work.hasWork,
                                                 previousCount: current.turnsWithoutProgress,
                                                 recentSignatures: [observation.signature ?? turn.toolSignature] + earlier,
                                                 observation: observation)
        current.turnsWithoutProgress = count
        try current.update(db, columns: ["turnsWithoutProgress"])
        switch verdict {
        case .ok:
            return nil
        case .nudge(let n):
            try MessageRouter(store: self).sendDM(db: db, companyId: current.companyId, from: .system, to: current.name,
                                                  text: Watchdog.nudgeText(n), now: now)
            return nil
        case .escalate(let reason):
            return try watchdogEscalate(db: db, agent: current, item: work.item, reason: reason,
                                        stopReason: Watchdog.stopReason(for: reason), now: now)
        }
    }

    /// Whether the agent did something that moves work during the turn: a progress-kind item event of its own, an ask it
    /// proposed, decided or escalated, an audit it recorded, or a sprint planned or closed.
    static func madeProgress(db: Database, agent: Agent, turn: Turn) throws -> Bool {
        let kinds = WorkEventKind.progress.map(\.rawValue) + Watchdog.sprintProgressKinds
        let marks = Array(repeating: "?", count: kinds.count).joined(separator: ", ")
        let events = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM workItemEvent WHERE companyId = ? AND actorId = ? AND createdAt >= ? AND kind IN (\(marks))
            """, arguments: StatementArguments([agent.companyId, agent.id] as [any DatabaseValueConvertible])
                + StatementArguments([turn.startedAt]) + StatementArguments(kinds)) ?? 0
        if events > 0 { return true }
        let asks = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM ask WHERE companyId = ? AND (
                (requesterId = ? AND createdAt >= ?) OR (decidedBy = ? AND internalDecidedAt >= ?))
            """, arguments: [agent.companyId, agent.id, turn.startedAt, "@\(agent.name)", turn.startedAt]) ?? 0
        if asks > 0 { return true }
        let escalated = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM activityEvent WHERE companyId = ? AND kind = 'approval' AND createdAt >= ? AND text LIKE ? ESCAPE '\\'
            """, arguments: [agent.companyId, turn.startedAt, "Escalated: % by @\(Store.likeEscaped(agent.name)): %"]) ?? 0
        if escalated > 0 { return true }
        let audits = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM reviewAudit WHERE auditorId = ? AND auditedAt >= ?
            """, arguments: [agent.id, turn.startedAt]) ?? 0
        return audits > 0
    }

    static func likeEscaped(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%").replacingOccurrences(of: "_", with: "\\_")
    }

    /// What the watchdog counts as the agent having work: a lease on an item not in review, or an owned item in progress
    /// or blocked. The item is the one an escalation takes back.
    static func watchdogWork(db: Database, agentId: String) throws -> (hasWork: Bool, item: WorkItem?) {
        if let lease = try WorkLease.filter(Column("agentId") == agentId).fetchOne(db),
           let item = try WorkItem.fetchOne(db, key: lease.itemId), item.status != .inReview {
            return (true, item)
        }
        let owned = try WorkItem.fetchOne(db, sql: """
            SELECT * FROM workItem WHERE ownerId = ? AND status IN ('inProgress', 'blocked') ORDER BY updatedAt DESC, number DESC LIMIT 1
            """, arguments: [agentId])
        return (owned != nil, owned)
    }

    /// The nearest manager above the agent who is not killed, or nil for the owner.
    static func nearestLiveAncestor(db: Database, of agent: Agent) throws -> Agent? {
        var next = agent.managerId
        var seen = Set<String>([agent.id])
        while let id = next, seen.insert(id).inserted {
            guard let ancestor = try Agent.fetchOne(db, key: id) else { break }
            if ancestor.state != .killed { return ancestor }
            next = ancestor.managerId
        }
        return nil
    }

    /// The engine stops the agent's work: its lease goes (the orphan sweep auto-commits and removes the worktree, keeping the
    /// branch), the item goes back to Ready unassigned with `stopReason` and a `watchdog` event, and the nearest non-killed
    /// ancestor (else the owner) is told. Returns the blocker the agent should end in. An item over its budget keeps its
    /// block (only a lead may lift it); it is still unassigned.
    @discardableResult
    func watchdogEscalate(db: Database, agent: Agent, item: WorkItem?, reason: String, stopReason: String, now: Date) throws -> Blocker {
        if var item {
            let lease = try WorkLease.fetchOne(db, key: item.id)
            if lease != nil {
                try db.execute(sql: "DELETE FROM workLease WHERE itemId = ?", arguments: [item.id])
                try Store.endSecretUses(db: db, itemId: item.id, now: now)
            }
            let from = item.status
            let budgetBlocked = from == .blocked && item.stopReason == "budget"
            if !budgetBlocked {
                if from == .inProgress || from == .blocked {
                    item.status = .ready
                    item.blockedReason = nil
                    item.blockedSinceActive = nil
                    item.blockedAskId = nil; item.blockedAskBy = nil; item.statusBeforeBlock = nil
                }
                item.stopReason = stopReason
            }
            if item.ownerId == agent.id { item.ownerId = nil }
            item.updatedAt = now
            try item.update(db)
            if from != item.status {
                try recordItemEvent(db: db, item: item, actor: "system", kind: .statusChanged,
                                    text: "\(from.title) → \(item.status.title): watchdog", now: now)
            }
            try recordItemEvent(db: db, item: item, actor: "system", kind: .watchdog,
                                text: "watchdog: @\(agent.name) — \(reason); lease released, back in \(item.status.title)",
                                alsoNotify: lease.map { [$0.agentId] } ?? [], now: now)
        }
        let what = item?.key ?? "No item"
        let text = "Watchdog: @\(agent.name) — \(reason). \(what) is back in Ready; reassign it or talk to @\(agent.name)."
        if let target = try Store.nearestLiveAncestor(db: db, of: agent) {
            try alert(db: db, companyId: agent.companyId, agentId: target.id, text: text, now: now)
            return .agent(target.id)
        }
        try MessageRouter(store: self).sendDM(db: db, companyId: agent.companyId, from: .system, to: "owner", text: text, now: now)
        return .owner(reason: "watchdog: \(reason)")
    }

    /// Loop guard on checks (after a real failure returned the item): the `failedCheckLimit`-th failed check since the latest
    /// claim takes the item back like the watchdog. The holder, if not mid-turn, is blocked at once; a running holder ends its
    /// turn blocked (through `requestedBlocker`).
    func noteFailedCheck(db: Database, itemId: String, holderId: String?, now: Date) throws {
        try db.execute(sql: "UPDATE workItem SET failedChecksSinceClaim = failedChecksSinceClaim + 1 WHERE id = ?", arguments: [itemId])
        guard let item = try WorkItem.fetchOne(db, key: itemId),
              let failures = try Int.fetchOne(db, sql: "SELECT failedChecksSinceClaim FROM workItem WHERE id = ?", arguments: [itemId]),
              failures >= Watchdog.failedCheckLimit,
              let holderId, let holder = try Agent.fetchOne(db, key: holderId), holder.companyId == item.companyId else { return }
        try db.execute(sql: "UPDATE workItem SET failedChecksSinceClaim = 0 WHERE id = ?", arguments: [itemId])
        let blocker = try watchdogEscalate(db: db, agent: holder, item: item,
                                           reason: "\(Watchdog.failedCheckLimit) failed checks on \(item.key)",
                                           stopReason: "failed-checks", now: now)
        guard var holder = try Agent.fetchOne(db, key: holder.id), holder.state != .killed else { return }
        if holder.state == .running {
            holder.requestedBlocker = blocker
            try holder.update(db, columns: ["requestedBlocker"])
        } else if !holder.paused {
            try Store.transition(db: db, agentId: holder.id, to: .blocked, blocker: blocker, now: now)
        }
    }
}
