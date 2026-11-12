import Foundation
import GRDB

/// One auto-merge (9c) and its audit. Every auto-merged item gets one.
public struct ReviewAudit: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "reviewAudit"

    public var itemId: String
    public var companyId: String
    /// Company-active seconds when the item landed.
    public var sampledActive: Double
    public var auditedAt: Date? = nil
    /// `ok` or `failed`.
    public var verdict: String? = nil
    public var notes: String? = nil
    /// Who did the work (the lease holder at landing, else the assignee).
    public var authorId: String? = nil
    public var baseCommit: String? = nil
    public var mergedCommit: String? = nil
    /// The agent the sample is routed to, and the audit turn that may record its verdict.
    public var auditorId: String? = nil
    public var auditTurnId: String? = nil
    public var batchedActive: Double? = nil
    /// The item's assignee and the agent that submitted the landed change: like the author, never its auditor.
    public var assigneeId: String? = nil
    public var submitterId: String? = nil
    /// Audit turns that ended without a verdict on it.
    public var attempts: Int = 0
    /// Not routed before this many company-active seconds (after an audit without a verdict, or when its diff could not be read).
    public var deferredUntilActive: Double? = nil
    /// The owner was alerted that this audit is overdue.
    public var escalated: Bool = false
    /// The work item a failed audit opened to revert or fix the change.
    public var followUpId: String? = nil
}

extension Store {
    static let auditTurnOnlyMessage = "audits happen in their own audit turn; you will get one when auto-merged work needs an audit"
    static let maxAuditNotes = 8192

    static func auditOverdueAlertReason(_ itemId: String) -> String { "auditoverdue:\(itemId)" }

    // MARK: Owner settings

    /// The owner-wide master switch for risk-tiered auto-merge (on by default). Each company's own switch (`autoMergeSmall`, off
    /// until the owner switches it on) and the pack's `autoMerge` must allow it as well.
    public func autoMergeEnabled() -> Bool {
        (try? writer.read { db in try Self.ownerAutoMerge(db: db) }) ?? true
    }

    static func ownerAutoMerge(db: Database) throws -> Bool {
        try Bool.fetchOne(db, sql: "SELECT autoMerge FROM ownerSettings WHERE id = 1") ?? true
    }

    /// Switching it off also takes back every auto-approval that has not landed (`revokeAutoApprovals`).
    public func setAutoMerge(_ on: Bool, now: Date = Store.now()) throws {
        try writer.write { db in
            try Store.ensureOwnerSettings(db)
            try db.execute(sql: "UPDATE ownerSettings SET autoMerge = ? WHERE id = 1", arguments: [on])
            if !on { try revokeAutoApprovals(db: db, companyId: nil, now: now) }
        }
    }

    /// The company's auto-merge switch (off for a new company). Switching it off takes back the company's auto-approvals that
    /// have not landed (`revokeAutoApprovals`).
    public func setAutoMergeSmall(companyId: String, _ on: Bool, now: Date = Store.now()) throws {
        try writer.write { db in
            guard try Company.fetchOne(db, key: companyId) != nil else { throw WorkError.notFound("no such company") }
            _ = try Company.filter(key: companyId).updateAll(db, Column("autoMergeSmall").set(to: on))
            if !on { try revokeAutoApprovals(db: db, companyId: companyId, now: now) }
        }
    }

    /// Every auto-approved item still in review goes back to a normal review: its round is reopened, and an item waiting to
    /// land (`pending`) has its review turn due at once on the commit its check passed on. One re-checking after a rebase
    /// (`verifying`) goes to its reviewer when that check passes (`finishVerification`). An item whose merge was already under
    /// way when the switch flipped still lands; it is queued for audit like an auto-merge (`queueAudit`). `companyId` nil: every
    /// company's.
    func revokeAutoApprovals(db: Database, companyId: String?, now: Date) throws {
        try Store.revokeAutoApprovals(db: db, companyId: companyId, now: now) { item, text in
            _ = try recordItemEvent(db: db, item: item, actor: "system", kind: .edited, text: text, now: now)
        }
    }

    static let autoApprovalRevokedText = "auto-merge was switched off before it landed; it needs a review"

    /// The body of `revokeAutoApprovals`, with the item event written by `event` (a restore writes into a database no store
    /// has open, so it records the event itself; fix-wave S35).
    static func revokeAutoApprovals(db: Database, companyId: String?, now: Date,
                                    event: (WorkItem, String) throws -> Void) throws {
        var request = WorkItem.filter(Column("autoApproved") == true && Column("status") == WorkItemStatus.inReview.rawValue
                                      && [MergeState.pending.rawValue, MergeState.verifying.rawValue].contains(Column("mergeState")))
        if let companyId { request = request.filter(Column("companyId") == companyId) }
        let items = try request.fetchAll(db)
        for var item in items {
            item.autoApproved = false
            item.reviewedRound = max(item.reviewRound - 1, 0)
            item.reviewAttempts = 0
            if item.mergeState == .pending { item.mergeState = .none }
            item.updatedAt = now
            try item.update(db)
            try event(item, autoApprovalRevokedText)
            try Store.wakeReviewer(db: db, item: item, now: now)
        }
    }

    /// The directories an auto-merged change may touch: the owner's list, else the company's pack's, else
    /// `ReviewPolicy.defaultAutoMergePaths`.
    public func autoMergePaths(companyId: String) -> [String] {
        (try? writer.read { db in try autoMergePaths(db: db, company: try Company.fetchOne(db, key: companyId)) })
            ?? ReviewPolicy.defaultAutoMergePaths
    }

    func autoMergePaths(db: Database, company: Company?) throws -> [String] {
        if let json = try String.fetchOne(db, sql: "SELECT autoMergePaths FROM ownerSettings WHERE id = 1"),
           let paths = try? JSONDecoder().decode([String].self, from: Data(json.utf8)) { return paths }
        return company.flatMap { catalog.pack($0.packId)?.autoMergePaths } ?? ReviewPolicy.defaultAutoMergePaths
    }

    /// `nil` goes back to the pack's list (else the default).
    public func setAutoMergePaths(_ paths: [String]?) throws {
        if let paths {
            do { try CheckSpec.validatePaths(paths, what: "auto-merge") } catch let e as WorkError { throw SettingsError.invalid(e.message) }
        }
        let json = paths.map { String(decoding: (try? JSONEncoder().encode($0)) ?? Data("[]".utf8), as: UTF8.self) }
        try writer.write { db in
            try Store.ensureOwnerSettings(db)
            try db.execute(sql: "UPDATE ownerSettings SET autoMergePaths = ? WHERE id = 1", arguments: [json])
        }
    }

    // MARK: Auto-approval

    /// The engine's measurement of a submitted change for risk-tiered review, or nil when the item cannot qualify whatever the
    /// change (`autoMergeCandidate`). Runs git through the hardened `GitCommand`, only on engine-recorded commits: the item's
    /// base (recorded at claim), `main`'s recorded head and the commit the check ran on. Nothing comes from the agent.
    func assessAutoMerge(run: VerificationRun, git: GitWorkspace) -> AutoMergeAssessment? {
        guard run.purpose == .submit,
              let pre = try? writer.read({ db -> (WorkItem, String?, [String])? in
                  guard let item = try WorkItem.fetchOne(db, key: run.itemId),
                        try autoMergeCandidate(db: db, item: item, run: run) else { return nil }
                  let company = try Company.fetchOne(db, key: item.companyId)
                  return (item, company?.mainCommit, try autoMergePaths(db: db, company: company))
              }) ?? nil,
              let base = pre.0.baseCommit
        else { return nil }
        let (item, recordedMain, allowed) = pre
        var lines = 0, bytes = 0
        func keep(_ why: String) -> AutoMergeAssessment {
            AutoMergeAssessment(commit: run.commit, base: base, lines: lines, bytes: bytes, reason: why)
        }
        do {
            guard try git.isAncestor(base, of: run.commit) else { return keep("the branch does not start from its recorded base") }
            guard let recordedMain, let mergeBase = try git.mergeBase(recordedMain, run.commit) else {
                return keep("no merge base with main")
            }
            // What the branch changed since it was claimed, and what landing it would change relative to `main`: both count.
            var paths = Set<String>()
            for from in Set([base, mergeBase]) {
                let stats = try git.changeStats(base: from, head: run.commit)
                if stats.truncated { return keep("the change could not be measured") }
                if stats.binary { return keep("a binary file changed") }
                if stats.deleted { return keep("a file was deleted") }
                if stats.specialMode { return keep("an executable, symlink or submodule changed") }
                lines = max(lines, stats.lines)
                bytes = max(bytes, stats.bytes)
                paths.formUnion(stats.paths)
            }
            if paths.isEmpty { return keep("no changes") }
            if let path = paths.sorted().first(where: { !ReviewPolicy.isAllowed($0, under: allowed) }) {
                return keep("\(Self.flat(path, max: 200)) is outside the auto-merge paths")
            }
            let reach = item.checkSpec.map { CheckScripts.checkReach(command: $0.command) } ?? CheckReach()
            // A check outside the allowlisted grammar could reach any file: every change keeps its review.
            guard reach.parseable else {
                return keep("the check command is not an allowlisted test or build command with plain arguments")
            }
            var scripts = Set<String>()
            if let snapshot = try latestCheckSnapshot(itemId: item.id, upTo: item.checkRevision) { scripts.formUnion(snapshot.manifest.keys) }
            if let path = paths.sorted().first(where: { ReviewPolicy.isSensitive($0, checkScripts: scripts, reach: reach) }) {
                return keep("sensitive path \(Self.flat(path, max: 200))")
            }
            if lines >= ReviewPolicy.autoMergeMaxLines { return keep("\(lines) changed lines") }
            if bytes >= ReviewPolicy.autoMergeMaxBytes { return keep("\(bytes) changed bytes") }
            return AutoMergeAssessment(commit: run.commit, base: base, lines: lines, bytes: bytes, reason: nil)
        } catch {
            return keep("the change could not be measured")
        }
    }

    /// The database half of the auto-approval rule (checked again inside the transaction that records the pass): auto-merge
    /// on owner-wide, for the company (`autoMergeSmall`) and for the pack (off when the company's pack is missing); tier S with an engine check, both (and the spec confirmation) set by a trusted
    /// non-implementer (`autoMergeProvenanceHolds`); the first review round with no review flag and no earlier change request;
    /// no merge pending; a recorded base; and neither the assignee, the lease holder nor the submitter on full review.
    func autoMergeCandidate(db: Database, item: WorkItem, run: VerificationRun) throws -> Bool {
        // A marked item (a tainted session wrote its spec or code) always gets a real review (Task 10 fix round 2).
        guard !item.taintedOrigin, !(try writesTainted(db: db, actorId: run.requestedBy ?? "")),
              item.tier == .s, item.checkSpec != nil, item.reviewFlags.isEmpty, item.status == .inReview, item.mergeState == .none,
              item.reviewRound == 1, item.reviewedRound == 0, item.baseCommit != nil, run.purpose == .submit, !run.flaky,
              let company = try Company.fetchOne(db, key: item.companyId),
              company.autoMergeSmall, try Self.ownerAutoMerge(db: db), catalog.pack(company.packId)?.autoMerge == true
        else { return false }
        let returned = try WorkItemEvent.filter(Column("itemId") == item.id && Column("kind") == WorkEventKind.changesRequested.rawValue)
            .fetchCount(db)
        guard returned == 0 else { return false }
        // S21: any event of the round (round 1: the item's whole history) a tainted session wrote rules auto-merge out; so does
        // a mark set since this item value was read.
        let taintedEvents = try WorkItemEvent.filter(Column("itemId") == item.id && Column("taintedOrigin") == true).fetchCount(db)
        let marked = try Bool.fetchOne(db, sql: "SELECT taintedOrigin FROM workItem WHERE id = ?", arguments: [item.id]) ?? true
        guard taintedEvents == 0, !marked else { return false }
        let current = Set([item.ownerId, try Self.leaseHolderId(db: db, itemId: item.id), run.requestedBy].compactMap { $0 })
        for id in current {
            if let agent = try Agent.fetchOne(db, key: id), agent.fullReview { return false }
        }
        // Everyone who ever held the lease or submitted the item counts as its implementer, besides the current ones.
        let past = try String.fetchAll(db, sql: """
            SELECT DISTINCT actorId FROM workItemEvent WHERE itemId = ? AND kind IN (?, ?)
            """, arguments: [item.id, WorkEventKind.leaseClaimed.rawValue, WorkEventKind.submitted.rawValue])
        let implementers = current.union(past.filter { !WorkPolicy.isPrivileged($0) })
        return Self.autoMergeProvenanceHolds(item: item, implementers: implementers)
    }

    /// Tier S, the check and the spec confirmation were each set by the engine, the owner, or a manager or executive who is
    /// none of `implementers` (the assignee, the lease holder, the submitter and anyone who held or submitted the item before).
    /// `checkSpecSetBy` is the item's last check editor. A field with no recorded setter (an item from before they were
    /// recorded) never qualifies.
    static func autoMergeProvenanceHolds(item: WorkItem, implementers: Set<String>) -> Bool {
        [item.tierSetBy, item.checkSpecSetBy, item.specConfirmedBy].allSatisfy { trustedSetter($0, implementers: implementers) }
    }

    static func trustedSetter(_ label: String?, implementers: Set<String>) -> Bool {
        guard let label else { return false }
        let parts = label.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2 else { return false }
        let (id, role) = (parts[0], parts[1])
        if WorkPolicy.isPrivileged(id) { return role == id }
        guard let kind = RoleKind(rawValue: role), WorkPolicy.isLead(kind) else { return false }
        return !implementers.contains(id)
    }

    // MARK: Queueing

    /// Called in the transaction that marks an item merged, before its lease goes: an auto-approved item counts as an
    /// auto-merge of its company, and every one is queued for an audit. So does an item that landed with its round still open
    /// (every approval closes it): an auto-approval revoked while its merge was already under way.
    func queueAudit(db: Database, item: WorkItem, mergedCommit: String) throws {
        guard item.autoApproved || item.reviewedRound < item.reviewRound else { return }
        try db.execute(sql: "UPDATE company SET autoMergeCount = autoMergeCount + 1 WHERE id = ?", arguments: [item.companyId])
        let author = try Self.leaseHolderId(db: db, itemId: item.id) ?? item.ownerId
        let submitter = try VerificationRun.filter(Column("itemId") == item.id && Column("purpose") == VerificationPurpose.submit.rawValue)
            .order(Column("createdAt").desc, Column.rowID.desc).fetchOne(db)?.requestedBy
        let active = try Self.activeNow(db: db, companyId: item.companyId)
        try db.execute(sql: "DELETE FROM reviewAudit WHERE itemId = ?", arguments: [item.id])
        try ReviewAudit(itemId: item.id, companyId: item.companyId, sampledActive: active, authorId: author,
                        baseCommit: item.baseCommit, mergedCommit: mergedCommit, assigneeId: item.ownerId, submitterId: submitter)
            .insert(db)
    }

    public func reviewAudits(companyId: String) throws -> [ReviewAudit] {
        try writer.read { db in
            try ReviewAudit.filter(Column("companyId") == companyId).order(Column("sampledActive"), Column.rowID).fetchAll(db)
        }
    }

    // MARK: Routing

    /// Each tick for a running company. A cheap read first, so a tick with nothing to do writes nothing. Then, in one
    /// transaction: samples routed to an agent that is killed or paused (or gone) are released; samples unaudited for
    /// `ReviewPolicy.auditEscalateAfter` active seconds, or after `auditMaxAttempts` turns without a verdict, alert the owner
    /// once; and every unrouted sample that is not deferred goes to its auditor (`auditorFor`), who is woken. Routing is per
    /// sample, so one auditor's outstanding batch never holds up another's. Returns the auditors given new samples.
    @discardableResult
    func scheduleAudit(companyId: String, now: Date) throws -> [Agent] {
        guard try writer.read({ db in try auditRoutingDue(db: db, companyId: companyId) }) else { return [] }
        return try writer.write { db in try routeAudits(db: db, companyId: companyId, now: now) }
    }

    private static let strandedAuditSQL = """
        companyId = ? AND auditedAt IS NULL AND auditorId IS NOT NULL
        AND auditorId NOT IN (SELECT id FROM agent WHERE companyId = ? AND state <> 'killed' AND paused = 0)
        """

    private static let overdueAuditSQL = """
        companyId = ? AND auditedAt IS NULL AND escalated = 0 AND (sampledActive <= ? OR attempts >= ?)
        """

    private func auditRoutingDue(db: Database, companyId: String) throws -> Bool {
        let active = try Self.activeNow(db: db, companyId: companyId)
        let stranded = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM reviewAudit WHERE " + Self.strandedAuditSQL,
                                        arguments: [companyId, companyId]) ?? 0
        if stranded > 0 { return true }
        let overdue = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM reviewAudit WHERE " + Self.overdueAuditSQL, arguments: [
            companyId, active - ReviewPolicy.auditEscalateAfter, ReviewPolicy.auditMaxAttempts]) ?? 0
        if overdue > 0 { return true }
        for sample in try Self.unroutedAudits(db: db, companyId: companyId, active: active) where try auditorFor(db: db, sample: sample) != nil {
            return true
        }
        return false
    }

    private static func unroutedAudits(db: Database, companyId: String, active: Double) throws -> [ReviewAudit] {
        try ReviewAudit.fetchAll(db, sql: """
            SELECT * FROM reviewAudit WHERE companyId = ? AND auditedAt IS NULL AND auditorId IS NULL
            AND (deferredUntilActive IS NULL OR deferredUntilActive <= ?) ORDER BY sampledActive, rowid
            """, arguments: [companyId, active])
    }

    private func routeAudits(db: Database, companyId: String, now: Date) throws -> [Agent] {
        guard let company = try Company.fetchOne(db, key: companyId) else { return [] }
        let active = try Self.activeNow(db: db, companyId: companyId)
        try db.execute(sql: "UPDATE reviewAudit SET auditorId = NULL, auditTurnId = NULL, batchedActive = NULL WHERE " + Self.strandedAuditSQL,
                       arguments: [companyId, companyId])

        let overdue = try ReviewAudit.fetchAll(db, sql: "SELECT * FROM reviewAudit WHERE " + Self.overdueAuditSQL + " ORDER BY sampledActive, rowid",
                                               arguments: [companyId, active - ReviewPolicy.auditEscalateAfter, ReviewPolicy.auditMaxAttempts])
        for sample in overdue {
            try db.execute(sql: "UPDATE reviewAudit SET escalated = 1 WHERE itemId = ?", arguments: [sample.itemId])
            let key = try WorkItem.fetchOne(db, key: sample.itemId)?.key ?? "an item"
            let why = sample.attempts >= ReviewPolicy.auditMaxAttempts
                ? "\(sample.attempts) audit turns ended without a verdict" : "it has waited \(Int(ReviewPolicy.auditEscalateAfter / 86_400)) active days"
            let text = "\(company.name): the audit of auto-merged \(key) is overdue (\(why)). It stays queued; check that an auditor "
                + "(its reviewer, a manager, the CTO or an executive) is active."
            try MessageRouter(store: self).sendDM(db: db, companyId: companyId, from: .system, to: "owner", text: text, now: now)
            try ActivityEvent(companyId: companyId, agentId: nil, turnId: nil, kind: .error, text: text, createdAt: now).insert(db)
            try fileEngineAlert(db, company: company, reason: Self.auditOverdueAlertReason(sample.itemId), text: text, now: now)
        }

        var routed: [String: (agent: Agent, count: Int)] = [:]
        for sample in try Self.unroutedAudits(db: db, companyId: companyId, active: active) {
            guard let auditor = try auditorFor(db: db, sample: sample) else { continue }
            try db.execute(sql: """
                UPDATE reviewAudit SET auditorId = ?, auditTurnId = NULL, batchedActive = ?, deferredUntilActive = NULL WHERE itemId = ?
                """, arguments: [auditor.id, active, sample.itemId])
            routed[auditor.id] = (auditor, (routed[auditor.id]?.count ?? 0) + 1)
        }
        let auditors = routed.values.sorted { $0.agent.name < $1.agent.name }
        for (auditor, count) in auditors {
            try ActivityEvent(companyId: companyId, agentId: auditor.id, turnId: nil, kind: .work,
                              text: "@\(auditor.name) will audit \(count) auto-merged item\(count == 1 ? "" : "s")", createdAt: now).insert(db)
            if auditor.state == .sleeping, !auditor.paused { try Store.transition(db: db, agentId: auditor.id, to: .ready, now: now) }
        }
        return auditors.map(\.agent)
    }

    /// Who audits a sample, resolved like a reviewer: the item's reviewer, else the nearest manager above the author (else the
    /// assignee), else the CTO, else an executive. Never the author, the assignee, the submitter or anyone who held the item's
    /// lease or submitted it before, and never an agent that is killed or paused. Nil when nobody qualifies (the sample waits; the overdue alert tells the owner).
    func auditorFor(db: Database, sample: ReviewAudit) throws -> Agent? {
        guard let item = try WorkItem.fetchOne(db, key: sample.itemId), item.companyId == sample.companyId,
              let company = try Company.fetchOne(db, key: item.companyId) else { return nil }
        // Anyone who ever held the item's lease or submitted it is one of its implementers as well.
        let past = try String.fetchAll(db, sql: """
            SELECT DISTINCT actorId FROM workItemEvent WHERE itemId = ? AND kind IN (?, ?)
            """, arguments: [item.id, WorkEventKind.leaseClaimed.rawValue, WorkEventKind.submitted.rawValue])
        let excluded = Set([sample.authorId, sample.assigneeId, sample.submitterId].compactMap { $0 } + past)
        func usable(_ agent: Agent?) -> Agent? {
            guard let agent, agent.companyId == item.companyId, agent.state != .killed, !agent.paused, !excluded.contains(agent.id)
            else { return nil }
            return agent
        }
        if let id = item.reviewerId, let reviewer = usable(try Agent.fetchOne(db, key: id)) { return reviewer }
        for start in [sample.authorId, sample.assigneeId].compactMap({ $0 }) {
            var cursor = try Agent.fetchOne(db, key: start)?.managerId
            var hops = 0
            while let id = cursor, hops < 50, let manager = try Agent.fetchOne(db, key: id) {
                if let found = usable(manager) { return found }
                cursor = manager.managerId
                hops += 1
            }
        }
        let ctoRoles = catalog.pack(company.packId)?.rolesCovering("cto") ?? []
        let live = try Agent.filter(Column("companyId") == item.companyId && Column("state") != AgentState.killed.rawValue)
            .order(Column("createdAt"), Column.rowID).fetchAll(db).compactMap(usable)
        if let cto = live.first(where: { ctoRoles.contains($0.role) }) { return cto }
        return live.first { catalog.template(role: $0.role, pack: company.packId).kind == .executive }
    }

    /// The samples routed to this agent and not yet audited, oldest first: at most one audit turn's batch.
    public func pendingAudits(agentId: String) throws -> [ReviewAudit] {
        try writer.read { db in try Self.pendingAudits(db: db, agentId: agentId) }
    }

    static func pendingAudits(db: Database, agentId: String) throws -> [ReviewAudit] {
        guard let agent = try Agent.fetchOne(db, key: agentId), agent.state != .killed else { return [] }
        return try ReviewAudit.fetchAll(db, sql: """
            SELECT * FROM reviewAudit WHERE companyId = ? AND auditorId = ? AND auditedAt IS NULL ORDER BY sampledActive, rowid LIMIT ?
            """, arguments: [agent.companyId, agentId, ReviewPolicy.auditBatchMax])
    }

    static func hasPendingAudit(db: Database, agentId: String) throws -> Bool {
        try !pendingAudits(db: db, agentId: agentId).isEmpty
    }

    /// Samples whose merged diff could not be produced are not put to the auditor (who would be judging a change it cannot
    /// see): they leave its batch and wait `ReviewPolicy.auditDeferral` active seconds before they are routed again.
    func deferAudits(itemIds: [String], agentId: String) throws {
        guard !itemIds.isEmpty else { return }
        try writer.write { db in
            guard let agent = try Agent.fetchOne(db, key: agentId) else { return }
            let until = try Self.activeNow(db: db, companyId: agent.companyId) + ReviewPolicy.auditDeferral
            for itemId in itemIds {
                try db.execute(sql: """
                    UPDATE reviewAudit SET auditorId = NULL, auditTurnId = NULL, batchedActive = NULL, deferredUntilActive = ?
                    WHERE itemId = ? AND auditorId = ? AND auditedAt IS NULL
                    """, arguments: [until, itemId, agentId])
            }
        }
    }

    /// The audit turn starts: it is recorded as one (no item), and exactly these samples are bound to it, so its `audit` tool
    /// can record verdicts for them and nothing else.
    func bindAuditTurn(turnId: String, agentId: String, itemIds: [String]) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE turn SET kind = 'audit', itemId = NULL WHERE id = ? AND agentId = ?", arguments: [turnId, agentId])
            for itemId in itemIds {
                try db.execute(sql: "UPDATE reviewAudit SET auditTurnId = ? WHERE itemId = ? AND auditorId = ? AND auditedAt IS NULL",
                               arguments: [turnId, itemId, agentId])
            }
        }
    }

    /// The keys an audit turn may record verdicts for.
    func auditTurnKeys(turnId: String) throws -> [String] {
        try writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT w.key FROM reviewAudit a JOIN workItem w ON w.id = a.itemId WHERE a.auditTurnId = ? AND a.auditedAt IS NULL
                ORDER BY a.sampledActive, a.rowid
                """, arguments: [turnId])
        }
    }

    /// Called when a turn is recorded as ended, inside the same transaction. A completed (or controlled-stop, or ordinarily
    /// failed) audit turn releases the samples it did not audit: each counts an attempt and is routed again after
    /// `ReviewPolicy.auditRetryDelay` active seconds. An interrupted, usage-limited or infrastructure-failed one keeps them with
    /// its auditor for another audit turn, attempt-free.
    func noteAuditTurnEnd(db: Database, turn: Turn, end: TurnEnd, infra: Bool) throws {
        var release = false
        switch end {
        case .succeeded, .capped: release = true
        case .failed: release = !infra
        default: release = false
        }
        if release {
            let until = try Self.activeNow(db: db, companyId: turn.companyId) + ReviewPolicy.auditRetryDelay
            try db.execute(sql: """
                UPDATE reviewAudit SET auditorId = NULL, auditTurnId = NULL, batchedActive = NULL, attempts = attempts + 1,
                deferredUntilActive = ? WHERE auditTurnId = ? AND auditedAt IS NULL
                """, arguments: [until, turn.id])
        } else {
            try db.execute(sql: "UPDATE reviewAudit SET auditTurnId = NULL WHERE auditTurnId = ? AND auditedAt IS NULL", arguments: [turn.id])
        }
    }

    // MARK: Verdicts

    /// The auditor's verdict on one sample, from inside its audit turn. Authority: `turnId` is an in-progress audit turn of
    /// this agent in this company, and the item is a sample bound to that turn and not yet audited. A failed audit sets the
    /// author's `fullReview` (every later change of theirs gets a review turn), records the notes as a comment on the item,
    /// opens a normal follow-up work item to revert or fix the change (the engine never reverts `main`), and tells the author's
    /// nearest active manager (else the owner) by DM; the DM carries no agent-written text.
    @discardableResult
    public func recordAudit(turnId: String, agentId: String, companyId: String, key: String, ok: Bool, notes: String,
                            now: Date = Store.now()) throws -> ReviewAudit {
        try writer.write { db in
            let actor = try resolveActor(db, .agent(agentId), companyId: companyId)
            guard let turn = try Turn.fetchOne(db, key: turnId), turn.agentId == agentId, turn.companyId == companyId,
                  turn.kind == .audit, turn.outcome == .inProgress else {
                throw WorkError.forbidden(Self.auditTurnOnlyMessage)
            }
            let wanted = key.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
            let keys = try String.fetchAll(db, sql: """
                SELECT w.key FROM reviewAudit a JOIN workItem w ON w.id = a.itemId WHERE a.auditTurnId = ? AND a.auditorId = ?
                ORDER BY a.sampledActive, a.rowid
                """, arguments: [turnId, agentId])
            guard let item = try WorkItem.filter(Column("companyId") == companyId && Column("key") == wanted).fetchOne(db),
                  var sample = try ReviewAudit.fetchOne(db, key: item.id), sample.auditTurnId == turnId, sample.auditorId == agentId,
                  sample.companyId == companyId else {
                throw WorkError.forbidden("this audit turn is limited to \(keys.isEmpty ? "its batch" : keys.joined(separator: ", "))")
            }
            guard sample.auditedAt == nil else { throw WorkError.conflict("\(item.key) was already audited") }
            let body = try redact(notes).trimmingCharacters(in: .whitespacesAndNewlines)   // raw first
            guard body.count <= Self.maxAuditNotes else { throw WorkError.invalid("the notes are longer than \(Self.maxAuditNotes) characters") }
            if !ok, body.isEmpty { throw WorkError.invalid("a failed audit needs notes: say what is wrong") }
            sample.auditedAt = now
            sample.verdict = ok ? "ok" : "failed"
            sample.notes = body
            try sample.update(db)
            try resolveEngineAlerts(db, reasons: [Self.auditOverdueAlertReason(item.id)], now: now)
            try Store.recordAuditFact(db: db, itemId: item.id, verdict: sample.verdict ?? "ok")
            try ActivityEvent(companyId: companyId, agentId: agentId, turnId: turnId, kind: .work,
                              text: "@\(actor.handle) audited \(item.key): \(ok ? "ok" : "failed")", createdAt: now).insert(db)
            guard !ok else { return sample }
            let author = try sample.authorId.flatMap { try Agent.fetchOne(db, key: $0) }
            if let author, author.companyId == companyId {
                try db.execute(sql: "UPDATE agent SET fullReview = 1 WHERE id = ?", arguments: [author.id])
            }
            var manager: Agent?
            var cursor = author?.managerId
            var hops = 0
            while let id = cursor, hops < 50, let ancestor = try Agent.fetchOne(db, key: id) {
                if ancestor.state != .killed, ancestor.companyId == companyId { manager = ancestor; break }
                cursor = ancestor.managerId
                hops += 1
            }
            try recordItemEvent(db: db, item: item, actor: agentId, kind: .commented, text: "audit failed: \(body)",
                                alsoNotify: [manager?.id].compactMap { $0 }, onlyAlsoNotify: true, now: now)
            let followUp = try openAuditFollowUp(db: db, item: item, sample: sample, auditor: actor.handle, ownerId: manager?.id,
                                                 notes: body, now: now)
            sample.followUpId = followUp.id
            try sample.update(db)
            let who = author.map { "@\($0.name)" } ?? "its author"
            let merged = sample.mergedCommit.map { " (merged at \($0.prefix(7)))" } ?? ""
            try MessageRouter(store: self).sendDM(
                db: db, companyId: companyId, from: .system, to: manager?.name ?? "owner",
                text: "The audit of \(item.key)\(merged) by @\(actor.handle) failed: it was auto-merged without a review turn. "
                    + "\(who)'s changes now always get a full review. The audit notes are on \(item.key); \(followUp.key) is open "
                    + "to revert or fix the change.", now: now)
            return sample
        }
    }

    /// The normal work item a failed audit opens: a bug (or the pack's first non-container type) for the author's manager,
    /// ready, linked to the merged item. Reverting or fixing goes through the usual claim, check and review.
    private func openAuditFollowUp(db: Database, item: WorkItem, sample: ReviewAudit, auditor: String, ownerId: String?,
                                   notes: String, now: Date) throws -> WorkItem {
        let company = try Company.fetchOne(db, key: item.companyId)
        let pack = company.flatMap { catalog.pack($0.packId) }
        let type: WorkItemType = pack == nil || pack?.itemType(WorkItemType.bug.rawValue) != nil
            ? .bug : WorkItemType(pack?.itemTypes.first { !$0.container }?.id ?? WorkItemType.bug.rawValue)
        let at = sample.mergedCommit.map { " at \($0.prefix(7))" } ?? ""
        var draft = WorkItemDraft(type: type, title: "Audit: revert or fix \(item.key)")
        draft.description = "The audit of \(item.key) (\(Self.flat(item.title, max: 200))), auto-merged into main\(at) without a review "
            + "turn, failed. Revert the change or fix it through a normal reviewed change; the engine does not revert main.\n\n"
            + "Audit notes from @\(auditor):\n\(notes)"
        draft.acceptanceCriteria = "What the audit of \(item.key) found is reverted or fixed on main through a reviewed change."
        draft.priority = 1
        draft.ownerId = ownerId
        draft.status = .ready
        let created = try createWorkItem(db: db, companyId: item.companyId, by: .system, draft: draft, now: now)
        try db.execute(sql: "INSERT OR IGNORE INTO workItemDependency (itemId, dependsOnId, linkedBy, createdAt) VALUES (?, ?, 'system', ?)",
                       arguments: [created.id, item.id, now])
        try recordItemEvent(db: db, item: created, actor: "system", kind: .dependencyAdded, text: "depends on \(item.key)", now: now)
        return created
    }
}
