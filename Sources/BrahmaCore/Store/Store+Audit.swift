import Foundation
import GRDB

/// One sampled auto-merge (9c) and its audit.
public struct ReviewAudit: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "reviewAudit"

    public var itemId: String
    public var companyId: String
    public var sampledActive: Double
    public var auditedAt: Date? = nil
    /// `ok` or `failed`.
    public var verdict: String? = nil
    public var notes: String? = nil
    /// Who did the work (the lease holder at landing, else the assignee).
    public var authorId: String? = nil
    public var baseCommit: String? = nil
    public var mergedCommit: String? = nil
    /// The agent the sample is batched to, and the audit turn that may record its verdict.
    public var auditorId: String? = nil
    public var auditTurnId: String? = nil
    public var batchedActive: Double? = nil
}

extension Store {
    static let auditTurnOnlyMessage = "audits happen in their own audit turn; you will get one when auto-merged work is sampled"
    static let maxAuditNotes = 8192

    // MARK: Auto-approval

    /// The engine's measurement of a submitted change for risk-tiered review, or nil when the item cannot qualify whatever the
    /// change (not tier S, flagged, no check or no recorded base, an author on full review, not a submit run). Runs git
    /// through the hardened `GitCommand`, only on engine-recorded commits: the item's base (recorded at claim), `main`'s recorded
    /// head and the commit the check ran on. Nothing comes from the agent.
    func assessAutoMerge(run: VerificationRun, git: GitWorkspace) -> AutoMergeAssessment? {
        guard run.purpose == .submit,
              let pre = try? writer.read({ db -> (WorkItem, String?)? in
                  guard let item = try WorkItem.fetchOne(db, key: run.itemId),
                        try autoMergeCandidate(db: db, item: item, run: run) else { return nil }
                  return (item, try Company.fetchOne(db, key: item.companyId)?.mainCommit)
              }) ?? nil,
              let base = pre.0.baseCommit
        else { return nil }
        let (item, recordedMain) = pre
        func keep(_ why: String, lines: Int = 0) -> AutoMergeAssessment {
            AutoMergeAssessment(commit: run.commit, base: base, lines: lines, reason: why)
        }
        do {
            guard try git.isAncestor(base, of: run.commit) else { return keep("the branch does not start from its recorded base") }
            guard let recordedMain, let mergeBase = try git.mergeBase(recordedMain, run.commit) else {
                return keep("no merge base with main")
            }
            // What the branch changed since it was claimed, and what landing it would change relative to `main`: both count.
            var lines = 0
            var paths = Set<String>()
            for from in Set([base, mergeBase]) {
                let stats = try git.changeStats(base: from, head: run.commit)
                if stats.truncated { return keep("the change could not be measured") }
                if stats.binary { return keep("a binary file changed") }
                lines = max(lines, stats.lines)
                paths.formUnion(stats.paths)
            }
            var scripts = Set(item.checkSpec.map { CheckScripts.candidatePaths(command: $0.command) } ?? [])
            if let snapshot = try latestCheckSnapshot(itemId: item.id, upTo: item.checkRevision) { scripts.formUnion(snapshot.manifest.keys) }
            if let path = paths.sorted().first(where: { ReviewPolicy.isSensitive($0, checkScripts: scripts) }) {
                return keep("sensitive path \(Self.flat(path, max: 200))", lines: lines)
            }
            if paths.isEmpty { return keep("no changes") }
            if lines >= ReviewPolicy.autoMergeMaxLines { return keep("\(lines) changed lines", lines: lines) }
            return AutoMergeAssessment(commit: run.commit, base: base, lines: lines, reason: nil)
        } catch {
            return keep("the change could not be measured")
        }
    }

    /// The database half of the auto-approval rule (checked again inside the transaction that records the pass): tier S with
    /// an engine check, no review flags, nothing decided this round, no merge pending, a recorded base, and neither the
    /// assignee, the lease holder nor the submitter on full review.
    func autoMergeCandidate(db: Database, item: WorkItem, run: VerificationRun) throws -> Bool {
        guard item.tier == .s, item.checkSpec != nil, item.reviewFlags.isEmpty, item.status == .inReview, item.mergeState == .none,
              item.reviewedRound < item.reviewRound, item.baseCommit != nil, run.purpose == .submit, !run.flaky else { return false }
        let authors = Set([item.ownerId, try Self.leaseHolderId(db: db, itemId: item.id), run.requestedBy].compactMap { $0 })
        for id in authors {
            if let agent = try Agent.fetchOne(db, key: id), agent.fullReview { return false }
        }
        return true
    }

    // MARK: Sampling

    /// Called in the transaction that marks an item merged, before its lease goes: an auto-approved item counts as an
    /// auto-merge of its company, and every `auditSampleEvery`-th is sampled for an audit.
    func sampleAutoMerge(db: Database, item: WorkItem, mergedCommit: String) throws {
        guard item.autoApproved else { return }
        try db.execute(sql: "UPDATE company SET autoMergeCount = autoMergeCount + 1 WHERE id = ?", arguments: [item.companyId])
        let count = try Int.fetchOne(db, sql: "SELECT autoMergeCount FROM company WHERE id = ?", arguments: [item.companyId]) ?? 0
        guard count > 0, count % ReviewPolicy.auditSampleEvery == 0 else { return }
        let author = try Self.leaseHolderId(db: db, itemId: item.id) ?? item.ownerId
        let active = try Self.activeNow(db: db, companyId: item.companyId)
        try db.execute(sql: "DELETE FROM reviewAudit WHERE itemId = ?", arguments: [item.id])
        try ReviewAudit(itemId: item.id, companyId: item.companyId, sampledActive: active, authorId: author,
                        baseCommit: item.baseCommit, mergedCommit: mergedCommit).insert(db)
    }

    public func reviewAudits(companyId: String) throws -> [ReviewAudit] {
        try writer.read { db in
            try ReviewAudit.filter(Column("companyId") == companyId).order(Column("sampledActive"), Column.rowID).fetchAll(db)
        }
    }

    // MARK: Batching

    /// Once per `ReviewPolicy.auditInterval` company-active seconds, the oldest unaudited samples (at most `auditBatchMax`)
    /// that resolve to one auditor go to that agent as one batch. The auditor is resolved as for a review: the item's reviewer
    /// while usable, else `resolveReviewer`; never the sample's author. Samples batched to a killed agent go back to the pool
    /// first; nothing new is batched while a batch is out. Returns the auditor, if a batch went out.
    @discardableResult
    func scheduleAudit(companyId: String, now: Date) throws -> Agent? {
        try writer.write { db -> Agent? in
            try db.execute(sql: """
                UPDATE reviewAudit SET auditorId = NULL, auditTurnId = NULL, batchedActive = NULL
                WHERE companyId = ? AND auditedAt IS NULL AND auditorId IS NOT NULL
                AND auditorId NOT IN (SELECT id FROM agent WHERE companyId = ? AND state <> 'killed')
                """, arguments: [companyId, companyId])
            let out = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM reviewAudit WHERE companyId = ? AND auditedAt IS NULL AND auditorId IS NOT NULL
                """, arguments: [companyId]) ?? 0
            guard out == 0, let company = try Company.fetchOne(db, key: companyId) else { return nil }
            let active = try Self.activeNow(db: db, companyId: companyId)
            guard active - company.lastAuditActive >= ReviewPolicy.auditInterval else { return nil }
            let samples = try ReviewAudit.fetchAll(db, sql: """
                SELECT * FROM reviewAudit WHERE companyId = ? AND auditedAt IS NULL AND auditorId IS NULL
                ORDER BY sampledActive, rowid LIMIT 50
                """, arguments: [companyId])
            var auditor: Agent?
            var batch: [String] = []
            for sample in samples where batch.count < ReviewPolicy.auditBatchMax {
                guard let candidate = try auditorFor(db: db, sample: sample) else { continue }
                if auditor == nil { auditor = candidate }
                if candidate.id == auditor?.id { batch.append(sample.itemId) }
            }
            guard let auditor, !batch.isEmpty else { return nil }
            for itemId in batch {
                try db.execute(sql: "UPDATE reviewAudit SET auditorId = ?, auditTurnId = NULL, batchedActive = ? WHERE itemId = ?",
                               arguments: [auditor.id, active, itemId])
            }
            try db.execute(sql: "UPDATE company SET lastAuditActive = ? WHERE id = ?", arguments: [active, companyId])
            try ActivityEvent(companyId: companyId, agentId: auditor.id, turnId: nil, kind: .work,
                              text: "@\(auditor.name) will audit \(batch.count) auto-merged item\(batch.count == 1 ? "" : "s")",
                              createdAt: now).insert(db)
            if auditor.state == .sleeping, !auditor.paused { try Store.transition(db: db, agentId: auditor.id, to: .ready, now: now) }
            return auditor
        }
    }

    private func auditorFor(db: Database, sample: ReviewAudit) throws -> Agent? {
        guard let item = try WorkItem.fetchOne(db, key: sample.itemId), item.companyId == sample.companyId else { return nil }
        if try reviewerIsUsable(db: db, item: item), let id = item.reviewerId, id != sample.authorId,
           let reviewer = try Agent.fetchOne(db, key: id) {
            return reviewer
        }
        var probe = item
        if probe.ownerId == nil { probe.ownerId = sample.authorId }
        guard let resolved = try? resolveReviewer(db: db, item: probe), resolved.id != sample.authorId else { return nil }
        return resolved
    }

    /// The samples batched to this agent and not yet audited, oldest first.
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
    /// failed) audit turn gives the samples it did not audit back to the pool: they go out with the next batch. An interrupted,
    /// usage-limited or infrastructure-failed one keeps them with its auditor for another audit turn.
    func noteAuditTurnEnd(db: Database, turn: Turn, end: TurnEnd, infra: Bool) throws {
        var release = false
        switch end {
        case .succeeded, .capped: release = true
        case .failed: release = !infra
        default: release = false
        }
        if release {
            try db.execute(sql: """
                UPDATE reviewAudit SET auditorId = NULL, auditTurnId = NULL, batchedActive = NULL WHERE auditTurnId = ? AND auditedAt IS NULL
                """, arguments: [turn.id])
        } else {
            try db.execute(sql: "UPDATE reviewAudit SET auditTurnId = NULL WHERE auditTurnId = ? AND auditedAt IS NULL", arguments: [turn.id])
        }
    }

    // MARK: Verdicts

    /// The auditor's verdict on one sample, from inside its audit turn. Authority: `turnId` is an in-progress audit turn of
    /// this agent in this company, and the item is a sample bound to that turn and not yet audited. A failed audit sets the
    /// author's `fullReview` (every later change of theirs gets a review turn), records the notes as a comment on the item and
    /// tells the author's nearest active manager (else the owner) by DM; the DM carries no agent-written text.
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
            let body = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            guard body.count <= Self.maxAuditNotes else { throw WorkError.invalid("the notes are longer than \(Self.maxAuditNotes) characters") }
            if !ok, body.isEmpty { throw WorkError.invalid("a failed audit needs notes: say what is wrong") }
            sample.auditedAt = now
            sample.verdict = ok ? "ok" : "failed"
            sample.notes = body
            try sample.update(db)
            try Store.recordAuditFact(db: db, itemId: item.id, verdict: sample.verdict ?? "ok")
            try ActivityEvent(companyId: companyId, agentId: agentId, turnId: turnId, kind: .work,
                              text: "@\(actor.handle) audited \(item.key): \(ok ? "ok" : "failed")", createdAt: now).insert(db)
            guard !ok else { return sample }
            let author = try sample.authorId.flatMap { try Agent.fetchOne(db, key: $0) }
            if let author, author.companyId == companyId {
                try db.execute(sql: "UPDATE agent SET fullReview = 1 WHERE id = ?", arguments: [author.id])
            }
            var target = "owner"
            var cursor = author?.managerId
            var hops = 0
            while let id = cursor, hops < 50, let ancestor = try Agent.fetchOne(db, key: id) {
                if ancestor.state != .killed { target = ancestor.name; break }
                cursor = ancestor.managerId
                hops += 1
            }
            let managerId = target == "owner" ? nil : try Agent.filter(Column("companyId") == companyId && Column("name") == target).fetchOne(db)?.id
            try recordItemEvent(db: db, item: item, actor: agentId, kind: .commented, text: "audit failed: \(body)",
                                alsoNotify: [managerId].compactMap { $0 }, onlyAlsoNotify: true, now: now)
            let who = author.map { "@\($0.name)" } ?? "its author"
            let merged = sample.mergedCommit.map { " (merged at \($0.prefix(7)))" } ?? ""
            try MessageRouter(store: self).sendDM(
                db: db, companyId: companyId, from: .system, to: target,
                text: "The audit of \(item.key)\(merged) by @\(actor.handle) failed: it was auto-merged without a review turn. "
                    + "\(who)'s changes now always get a full review. The audit notes are on \(item.key).", now: now)
            return sample
        }
    }
}
