import Foundation
import GRDB

/// What the store knows about an item that `ModePolicy` reads (design §3.1), all as effective values.
public struct ItemModeFacts: Equatable, Sendable {
    public var item: WorkItem
    public var tier: EffortTier
    public var priority: Int
    public var riskTags: Set<String>
    public var blockingCount: Int
    /// The tier's $LE cap plus any boost, less what the item's work turns spent.
    public var budgetLeftLE: Double
    public var planWritten: Bool
    public var reviewRejections: Int
    public var replanRequested: Bool
    public var p2OnlyFix: Bool
    /// Company-active seconds and date of the latest claim (nil when never claimed).
    public var claimedAt: Date?
}

/// One check failure since the claim, before the scope test (which needs git).
public struct FailedRun: Equatable, Sendable {
    public var commit: String
    public var real: Bool
}

extension Store {
    // MARK: Facts

    /// The facts of `itemId` for a turn of `holderId` (its lease holder, or the reviewer's view when nil).
    public func itemModeFacts(itemId: String, holderId: String?) throws -> ItemModeFacts? {
        try writer.read { db in try Store.itemModeFacts(db: db, itemId: itemId, holderId: holderId) }
    }

    static func itemModeFacts(db: Database, itemId: String, holderId: String?) throws -> ItemModeFacts? {
        guard let item = try WorkItem.fetchOne(db, key: itemId) else { return nil }
        let holder = try holderId ?? leaseHolderId(db: db, itemId: item.id) ?? item.ownerId
        let usage = try Store.itemUsage(db: db, itemId: item.id)
        let budget = TierBudget.of(item.tier)
        let claimedAt = try Date.fetchOne(db, sql: """
            SELECT createdAt FROM workItemEvent WHERE itemId = ? AND kind = 'leaseClaimed' ORDER BY id DESC LIMIT 1
            """, arguments: [item.id])
        let since = claimedAt ?? .distantPast
        let planWritten = try WorkItemEvent.filter(Column("itemId") == item.id && Column("kind") == WorkEventKind.planWritten.rawValue
                                                   && Column("createdAt") >= since).fetchCount(db) > 0
        let rejections = try WorkItemEvent.filter(Column("itemId") == item.id
                                                  && Column("kind") == WorkEventKind.changesRequested.rawValue
                                                  && Column("createdAt") >= since).order(Column("id")).fetchAll(db)
        var replan = false
        if rejections.count >= ModePolicy.replanRejections, let second = rejections.dropFirst(ModePolicy.replanRejections - 1).first {
            replan = try WorkItemEvent.filter(Column("itemId") == item.id && Column("kind") == WorkEventKind.planWritten.rawValue
                                              && Column("id") > (second.id ?? 0)).fetchCount(db) == 0
        }
        // The newest review decision decides the P2-only rule: changes requested, every finding marked P2.
        var p2Only = false
        if let last = try WorkItemEvent.filter(Column("itemId") == item.id
                                               && [WorkEventKind.changesRequested.rawValue, WorkEventKind.reviewApproved.rawValue,
                                                   WorkEventKind.submitted.rawValue].contains(Column("kind")))
            .order(Column("id").desc).fetchOne(db), last.kind == .changesRequested {
            p2Only = last.text.contains("[P2]") && !last.text.contains("[P1]")
        }
        return ItemModeFacts(
            item: item,
            tier: EffectiveSpec.tier(stored: item.tier, confirmedBy: item.specConfirmedBy, holderId: holder),
            priority: EffectiveSpec.priority(stored: item.priority, confirmedBy: item.specConfirmedBy, holderId: holder),
            riskTags: WorkPolicy.riskTags(item),
            blockingCount: try Store.blockingDependentCount(db: db, item: item),
            budgetLeftLE: budget.maxCostLE + item.budgetBoostLE - usage.costLE,
            planWritten: planWritten, reviewRejections: rejections.count, replanRequested: replan, p2OnlyFix: p2Only,
            claimedAt: claimedAt)
    }

    /// The check failures of the item's submissions since `since`, one per commit in submission order: `real` when the run and
    /// its re-run both failed (a flaky pass, an inconclusive or infrastructure run never is).
    public func failedRuns(itemId: String, since: Date?) throws -> [FailedRun] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT "commit" AS c, MIN(rowid) AS first,
                       SUM(CASE WHEN status IN ('failed', 'timedOut') THEN 1 ELSE 0 END) AS failures
                FROM verificationRun WHERE itemId = ? AND purpose = 'submit' AND createdAt >= ?
                GROUP BY "commit" ORDER BY first
                """, arguments: [itemId, since ?? .distantPast])
            return rows.map { FailedRun(commit: $0["c"], real: ($0["failures"] as Int? ?? 0) > Store.flakeReruns) }
        }
    }

    /// The level of the agent's last work turn on the item (1 when there is none).
    func lastWorkRung(itemId: String, agentId: String) throws -> Int {
        try writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT rung FROM turn WHERE itemId = ? AND agentId = ? AND kind = 'work' AND rung IS NOT NULL
                ORDER BY startedAt DESC, rowid DESC LIMIT 1
                """, arguments: [itemId, agentId]) ?? 1
        }
    }

    /// Consecutive newest work turns on the item that `--max-budget-usd` stopped.
    func cappedInRow(itemId: String) throws -> Int {
        try writer.read { db in
            let stops = try String?.fetchAll(db, sql: """
                SELECT stopReason FROM turn WHERE itemId = ? AND kind = 'work' AND outcome IN ('succeeded', 'failed')
                ORDER BY startedAt DESC, rowid DESC LIMIT 5
                """, arguments: [itemId])
            return stops.prefix { $0 == TurnStop.budgetCap }.count
        }
    }

    /// Failure escalations and rejection escalations already applied since the claim, and whether Ultra was proposed.
    func escalationState(itemId: String, since: Date?) throws -> (failures: Bool, rejections: Bool, ultra: Bool) {
        try writer.read { db in
            let texts = try String.fetchAll(db, sql: """
                SELECT text FROM workItemEvent WHERE itemId = ? AND kind = 'modeEscalated' AND actorId = 'system' AND createdAt >= ?
                """, arguments: [itemId, since ?? .distantPast])
            let ultra = try Ask.filter(Column("itemId") == itemId && Column("kind") == AskKind.boost
                                       && Column("createdAt") >= (since ?? .distantPast)).fetchCount(db) > 0
            return (texts.contains { $0.hasPrefix(Self.failureEscalationPrefix) },
                    texts.contains { $0.hasPrefix(Self.rejectionEscalationPrefix) }, ultra)
        }
    }

    static let failureEscalationPrefix = "failed checks: "
    static let rejectionEscalationPrefix = "review rejections: "

    // MARK: Escalation

    /// Applies what `ModePolicy.escalation` decided for an item, in one transaction: a raised floor (an item event, so it is
    /// also the record that it happened for this claim), a held escalation or a too-small turn cap (a manager DM), or the
    /// failure-path Ultra ask (always the owner's).
    func applyEscalation(itemId: String, actions: [EscalationAction], kind: String, since: Date? = nil, now: Date) throws {
        guard !actions.isEmpty else { return }
        var ultraReason: String?
        try writer.write { db in
            guard var item = try WorkItem.fetchOne(db, key: itemId) else { return }
            let prefix = kind == "rejections" ? Store.rejectionEscalationPrefix : Store.failureEscalationPrefix
            let assignee = try item.ownerId.flatMap { try Agent.fetchOne(db, key: $0) }
            for action in actions {
                switch action {
                case .raiseFloor(let to, let opus, let why):
                    guard to > item.rungFloor else { continue }
                    item.rungFloor = to
                    item.updatedAt = now
                    try item.update(db)
                    try recordItemEvent(db: db, item: item, actor: "system", kind: .modeEscalated,
                                        text: prefix + "\(why); floor R\(to) from the next turn" + (opus ? " (explicit escalation to opus)" : ""),
                                        now: now)
                case .heldByBudget(let why):
                    try recordItemEvent(db: db, item: item, actor: "system", kind: .modeEscalated, text: prefix + "held: \(why)", now: now)
                    if let assignee {
                        try MessageRouter(store: self).sendDM(
                            db: db, companyId: item.companyId, from: .system, to: try Store.escalationTarget(db: db, from: assignee),
                            text: "\(item.key) would escalate (\(why)). Raise its tier, split it or reassign it.", now: now)
                    }
                case .turnCapTooSmall:
                    let text = "turn cap too small for \(item.key): two turns in a row stopped at their --max-budget-usd cap."
                    let sent = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message WHERE senderId = 'system' AND text = ? AND createdAt >= ?",
                                                arguments: [text, since ?? .distantPast]) ?? 0
                    if let assignee, sent == 0 {
                        try MessageRouter(store: self).sendDM(
                            db: db, companyId: item.companyId, from: .system, to: try Store.escalationTarget(db: db, from: assignee),
                            text: text, now: now)
                    }
                case .proposeUltra(let why):
                    ultraReason = why
                }
            }
        }
        if let ultraReason, let item = try workItem(id: itemId) {
            try fileFailurePathBoost(companyId: item.companyId, itemId: itemId, reason: "\(item.key): \(ultraReason)", now: now)
        }
    }

    // MARK: Review spend

    /// $LE the item's review and audit turns spent.
    public func reviewSpendLE(itemId: String) throws -> Double {
        try writer.read { db in
            try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(costLE), 0) FROM turn WHERE itemId = ? AND kind IN ('review', 'audit')",
                                arguments: [itemId]) ?? 0
        }
    }

    /// Review spend passed `ModePolicy.reviewSpendShare` of the tier's $LE: reviews drop to Standard.
    public func reviewSpendCapped(item: WorkItem) throws -> Bool {
        try reviewSpendLE(itemId: item.id) > ModePolicy.reviewSpendShare * (TierBudget.of(item.tier).maxCostLE + item.budgetBoostLE)
    }

    /// Tells the assignee's manager (else the owner) once that reviews of the item dropped to Standard.
    public func noteReviewSpendCap(item: WorkItem, now: Date = Store.now()) throws {
        try writer.write { db in
            let text = "review spend on \(item.key) passed \(Int(ModePolicy.reviewSpendShare * 100))% of its tier budget; "
                + "its reviews run in Standard mode from now on."
            guard try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message WHERE senderId = 'system' AND text = ?", arguments: [text]) == 0
            else { return }
            let target: String
            if let owner = try item.ownerId.flatMap({ try Agent.fetchOne(db, key: $0) }) {
                target = try Store.escalationTarget(db: db, from: owner)
            } else {
                target = "owner"
            }
            try MessageRouter(store: self).sendDM(db: db, companyId: item.companyId, from: .system, to: target, text: text, now: now)
        }
    }

    // MARK: Opus availability, calibration, records

    /// True for an hour after at least two turns that asked for opus billed only sonnet (design §3.1).
    public func opusScarce(now: Date) throws -> Bool {
        try writer.read { db in
            let rows = try String?.fetchAll(db, sql: """
                SELECT modelsUsed FROM turn WHERE rung >= 3 AND endedAt IS NOT NULL AND endedAt >= ? AND kind IN ('work', 'plan', 'review')
                """, arguments: [now.addingTimeInterval(-Store.opusScarceWindow)])
            let fellBack = rows.compactMap { $0?.lowercased() }.filter { !$0.contains("opus") && $0.contains("sonnet") }
            return fellBack.count >= 2
        }
    }

    static let opusScarceWindow: TimeInterval = 3600

    public func modeCalibration() throws -> ModeCalibration {
        try writer.read { db in try Store.calibration(db).modes ?? ModeCalibration() }
    }

    /// Feeds a finished work turn's $LE into the rung-cost EMA of its (model, effort).
    static func recordModeCost(db: Database, model: String, effort: Effort, costLE: Double) throws {
        var cal = try calibration(db)
        var modes = cal.modes ?? ModeCalibration()
        modes.record(model: model, effort: effort, costLE: costLE)
        cal.modes = modes
        try saveCalibration(db, cal)
    }

    /// What the turn runs with: stored on the turn row when it starts.
    func setTurnMode(turnId: String, decision d: ModeDecision) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE turn SET mode = ?, rung = ?, effort = ?, modeReason = ? WHERE id = ?",
                           arguments: [d.mode.rawValue, d.rung.level, d.effort.rawValue, String(d.reason.prefix(1000)), turnId])
        }
    }

    /// $LE by mode since `since` (the Budget view's "this week by mode").
    public func costByMode(companyId: String, since: Date) throws -> [String: Double] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT mode, COALESCE(SUM(costLE), 0) AS cost FROM turn
                WHERE companyId = ? AND mode IS NOT NULL AND startedAt >= ? GROUP BY mode
                """, arguments: [companyId, since])
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["mode"] as String, $0["cost"] as Double) })
        }
    }

    /// The built-in agent types the doctor's mode-canary recorded for the installed CLI (the init `agents` set every turn must
    /// match); nil until a canary ran.
    func recordedBuiltinAgents() -> Set<String>? {
        (try? latestProbe())?.builtinAgents.map(Set.init)
    }
}
