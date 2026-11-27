import Foundation
import GRDB

/// What one finished work item came to, written once when it is done. Facts are only recorded: they never affect
/// scheduling, trust or prompts. Infrastructure turns, session resets and inconclusive runs are left out of every count but
/// `inconclusiveRuns`.
public struct ItemFact: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "itemFact"

    public var itemId: String
    public var companyId: String
    public var type: String
    public var tier: String
    public var ownerId: String?
    public var reviewerId: String?
    /// The first non-inconclusive submit run passed without a re-run, and no review asked for changes.
    public var firstPass: Bool
    /// Finished, non-inconclusive runs (submit and merge), and of those the failed (failed, timed out, refused) and flaky ones.
    public var verificationRuns: Int
    public var failedRuns: Int
    public var flakyRuns: Int
    public var inconclusiveRuns: Int
    public var reworkRounds: Int
    public var reviewRejections: Int
    public var turnsUsed: Int
    public var tokensUsed: Int
    public var tierMaxTurns: Int
    public var tierMaxTokens: Int
    /// Company-active seconds from the first claim to completion (nil for an item never claimed).
    public var cycleActiveSeconds: Int?
    public var blockedActiveSeconds: Int
    /// Who last edited the check (else the item's author), and their role (`owner`, `system` or the agent's role).
    public var checkAuthorId: String?
    public var checkAuthorRole: String?
    public var mergeConflicts: Int
    /// Subscription turns' list-equivalent cost only; the gateway's dollars are `meteredUSD` (spec §8.2.1: facts split cost
    /// by mode).
    public var costLE: Double
    public var tierMaxCostLE: Double
    public var reviewCostLE: Double
    public var autoMerged: Bool
    /// Sampled for an audit (9c); the verdict arrives when the audit is recorded.
    public var audited: Bool
    public var auditVerdict: String?
    /// The rung of the last counted work turn, and the work modes the item's turns ran in (comma-joined, sorted).
    public var rungAtPass: Int?
    public var modesUsed: String?
    public var completedAt: Date
    /// The dollars the model gateway charged for the item (Plan X1 Task 9; `ItemUsage.meteredUSD`).
    public var meteredUSD: Double = 0
}

/// Writes the item's `ItemFact` inside the transaction that completes it. Always the store's first observer.
struct OutcomeFactsObserver: WorkItemObserver {
    let catalog: PackCatalog

    func itemCompleted(_ item: WorkItem, db: Database) throws {
        guard let company = try Company.fetchOne(db, key: item.companyId) else { return }
        // Containers (epics, stories) are done by the container rule; they did no work of their own.
        if catalog.pack(company.packId)?.itemType(item.type.rawValue)?.container ?? false { return }
        let fact = try Self.fact(db: db, item: item, now: item.doneAt ?? Store.now())
        try fact.save(db)
    }

    static func fact(db: Database, item: WorkItem, now: Date) throws -> ItemFact {
        let runs = try VerificationRun.filter(Column("itemId") == item.id).order(Column.rowID).fetchAll(db)
        let finished = runs.filter { ![.queued, .running].contains($0.status) }
        let conclusive = finished.filter { $0.status != .inconclusive }
        let failed = conclusive.filter { [.failed, .timedOut, .error].contains($0.status) }
        let events = try WorkItemEvent.filter(Column("itemId") == item.id).order(Column("id")).fetchAll(db)
        let rejections = events.filter { $0.kind == .changesRequested }.count
        let firstSubmit = conclusive.first { $0.purpose == .submit }
        let firstPass = firstSubmit.map { $0.status == .passed && !$0.flaky } == true && rejections == 0

        let usage = try Store.itemUsage(db: db, itemId: item.id)
        let budget = TierBudget.of(item.tier)
        let reviewCost = try Double.fetchOne(db, sql: """
            SELECT COALESCE(SUM(costLE), 0) FROM turn WHERE itemId = ? AND kind = 'review' AND infra = 0 AND sessionResetReason IS NULL
            """, arguments: [item.id]) ?? 0
        let active = try Store.activeNow(db: db, companyId: item.companyId)

        // Blocked time: each `statusChanged` into Blocked opens a span, the next one out of it closes it.
        var blocked = 0.0
        var since: Double?
        let blockedTitle = WorkItemStatus.blocked.title
        for e in events where e.kind == .statusChanged {
            if e.text.hasPrefix("\(blockedTitle) → ") {
                if let s = since { blocked += max(e.createdActive - s, 0); since = nil }
            } else if e.text.contains(" → \(blockedTitle)") {
                if since == nil { since = e.createdActive }
            }
        }
        if let s = since { blocked += max(active - s, 0) }

        var checkAuthor: String? = events.last { $0.kind == .checkEdited }?.actorId ?? item.authorId
        if checkAuthor?.isEmpty == true { checkAuthor = nil }
        var checkRole: String?
        if let id = checkAuthor {
            checkRole = id == "owner" || id == "system" ? id : try Agent.fetchOne(db, key: id)?.role
        }
        let audit = try ReviewAudit.fetchOne(db, key: item.id)
        let rung = try Int.fetchOne(db, sql: """
            SELECT rung FROM turn WHERE itemId = ? AND kind = 'work' AND infra = 0 AND sessionResetReason IS NULL AND rung IS NOT NULL
            ORDER BY startedAt DESC, rowid DESC LIMIT 1
            """, arguments: [item.id])
        let modes = try String.fetchAll(db, sql: """
            SELECT DISTINCT mode FROM turn WHERE itemId = ? AND infra = 0 AND sessionResetReason IS NULL AND mode IS NOT NULL ORDER BY mode
            """, arguments: [item.id])

        return ItemFact(
            itemId: item.id, companyId: item.companyId, type: item.type.rawValue, tier: item.tier.rawValue, ownerId: item.ownerId,
            reviewerId: item.reviewerId, firstPass: firstPass, verificationRuns: conclusive.count, failedRuns: failed.count,
            flakyRuns: conclusive.filter(\.flaky).count, inconclusiveRuns: finished.count - conclusive.count,
            reworkRounds: max(item.reviewRound - 1, 0), reviewRejections: rejections, turnsUsed: usage.turns,
            tokensUsed: usage.tokens, tierMaxTurns: budget.maxTurns, tierMaxTokens: budget.maxTokens,
            cycleActiveSeconds: item.firstClaimedActive.map { Int((active - $0).rounded()) },
            blockedActiveSeconds: Int(blocked.rounded()), checkAuthorId: checkAuthor, checkAuthorRole: checkRole,
            mergeConflicts: events.filter { $0.kind == .mergeConflict }.count, costLE: usage.costLE,
            tierMaxCostLE: budget.maxCostLE + item.budgetBoostLE, reviewCostLE: reviewCost, autoMerged: item.autoApproved,
            audited: audit != nil, auditVerdict: audit?.verdict, rungAtPass: rung, modesUsed: modes.isEmpty ? nil : modes.joined(separator: ","),
            completedAt: now, meteredUSD: usage.meteredUSD)
    }
}

extension Store {
    /// The company's outcome facts, newest first.
    public func itemFacts(companyId: String, limit: Int = 50) throws -> [ItemFact] {
        try writer.read { db in
            try ItemFact.filter(Column("companyId") == companyId)
                .order(Column("completedAt").desc, Column.rowID.desc).limit(max(limit, 0)).fetchAll(db)
        }
    }

    public func itemFact(itemId: String) throws -> ItemFact? {
        try writer.read { db in try ItemFact.fetchOne(db, key: itemId) }
    }

    /// An audit of an auto-merged item was recorded: its fact carries the verdict.
    static func recordAuditFact(db: Database, itemId: String, verdict: String) throws {
        try db.execute(sql: "UPDATE itemFact SET audited = 1, auditVerdict = ? WHERE itemId = ?", arguments: [verdict, itemId])
    }
}

/// The `brahma perf facts` table.
public enum FactsText {
    public static func line(_ f: ItemFact, key: String, handles: [String: String]) -> String {
        func who(_ id: String?) -> String {
            guard let id else { return "none" }
            if id == "owner" || id == "system" { return "@\(id)" }
            return "@" + (handles[id] ?? "?")
        }
        var parts = [key, f.type, f.tier.uppercased(), f.firstPass ? "first-pass" : "reworked"]
        parts.append("runs \(f.verificationRuns) (\(f.failedRuns) failed, \(f.flakyRuns) flaky, \(f.inconclusiveRuns) inconclusive)")
        parts.append("rework \(f.reworkRounds), rejections \(f.reviewRejections)")
        parts.append("turns \(f.turnsUsed)/\(f.tierMaxTurns), tokens \(f.tokensUsed / 1000)k/\(f.tierMaxTokens / 1000)k, "
                     + "$\(BudgetText.money(f.costLE))/$\(BudgetText.money(f.tierMaxCostLE)) + review $\(BudgetText.money(f.reviewCostLE))")
        parts.append("cycle \(f.cycleActiveSeconds.map { "\($0)s" } ?? "-"), blocked \(f.blockedActiveSeconds)s")
        parts.append("check by \(who(f.checkAuthorId))\(f.checkAuthorRole.map { " (\($0))" } ?? "")")
        parts.append("conflicts \(f.mergeConflicts)")
        if f.autoMerged { parts.append("auto-merged" + (f.audited ? ", audit \(f.auditVerdict ?? "pending")" : "")) }
        if let r = f.rungAtPass { parts.append("R\(r)") }
        if let m = f.modesUsed { parts.append("modes \(m)") }
        parts.append("owner \(who(f.ownerId))")
        return parts.joined(separator: "  ")
    }
}
