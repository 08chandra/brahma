import Foundation
import GRDB

/// What a restore must not roll back (final review I3). A snapshot is older than the live database, and some of the live
/// database's state only ever moves toward "safer": the owner's stop, grant revocations and used-up uses, and every taint mark.
/// `Restore.restore` reads that state from the live database before the swap (`read`) and writes it into the staged snapshot
/// (`apply`) before the staged file is renamed into place, so there is no moment when the restored database lacks it.
///
/// Revocations are carried from the live database (not from a journal kept outside it): the live database is the one authority
/// on every way a grant ends (the owner's revoke, a path that changed, a use-up, a sprint end), the restore already opens it
/// for its pre-restore snapshot, and a side journal would be a second record every one of those paths has to keep in step.
/// When the live database cannot be read, nothing about it can be trusted, so the restore fails closed instead: every grant
/// is revoked (the owner approves again what is still wanted) and every session is treated as tainted.
///
/// The security-relevant company settings (`CompanySecurity`, S35: autonomy, profiles, read paths, domains, local listening,
/// auto-merge, the pause) and the owner-wide auto-merge keep the stricter of the live and the restored value.
///
/// Grants the live database no longer counts for any reason (expired on company-active time, sprint ended, used up) are
/// revoked in the restored one (fix-wave F1): both clocks roll back with the database, so carrying `revokedAt` alone is not
/// enough. Other settings the owner turned off are not carried (fix-wave F2): every one the restore turns back on is listed in
/// the stop note, the restore's warnings and an engine alert in every company, so the owner reviews them before resuming.
///
/// Whatever was read, the restored engine comes back stopped (the owner resumes it) and the machine-wide lab mark is set:
/// a lab commit made after the snapshot is never recorded clean, and the owner's machine-wide clear (which snapshots every
/// lab's commits as never-clean, S33) is the only way back.
struct RestoreCarry {
    struct GrantEnd { var id: String; var revokedAt: Date?; var revokedBy: String?; var usesLeft: Int? }
    struct LabMark { var agentId: String; var source: String; var markedAt: Date }
    struct CompanyMark { var companyId: String; var source: String?; var profile: String?; var markedAt: Date?; var clearedAt: Date? }
    struct MachineMark { var source: String?; var markedAt: Date?; var clearedAt: Date? }
    struct TaintedCommit { var agentId: String; var sha: String; var turnId: String?; var recordedAt: Date }
    struct AgentTaint { var id: String; var sources: String; var fresh: Bool }
    /// A row of Plan C's `taintedCommit` (P2 R4-4).
    struct ItemCommitTaint {
        var companyId: String, sha: String, itemId: String?, agentId: String?, turnId: String?, source: String, createdAt: Date
        var clearedBy: String?, clearedAt: Date?, carriedTo: String?
        /// The restore epoch that recorded it (P2 R5-1), or nil.
        var restoreEpoch: String? = nil
    }

    var grants: [GrantEnd] = []
    /// Grants not live in the live database at restore time for any reason `GrantResolver.isLive` knows (revoked, used up,
    /// expired on company-active time, sprint ended): fix-wave F1. Both clocks live in the database and roll back with it,
    /// so these are revoked in the restored one rather than carrying the clocks.
    var notLiveGrants: [String] = []
    /// What the owner can turn off, as the live database has it (fix-wave F2): compared with the restored database so the
    /// restore's stop note and alert name every setting it rolled back.
    var settings = Settings()
    var labMarks: [LabMark] = []
    var companyMarks: [CompanyMark] = []
    var machineMark: MachineMark?
    var neverCleanCommits: [(sha: String, recordedAt: Date)] = []
    var taintedCommits: [TaintedCommit] = []
    var taintedAgents: [AgentTaint] = []
    var taintedItems: [String] = []
    /// Plan C's tainted commits (P2 R4-4): git is not rolled back, so a commit recorded tainted after the snapshot is still on
    /// its branch; without its row, refs to it (a commit ref, a key-less file at it, its item's diff) would read clean.
    var itemCommitTaints: [ItemCommitTaint] = []
    /// Ruling 22's restore epochs (P2 R5-1): an earlier restore over an unreadable database; an uncleared one must not be lost.
    var restoreEpochs: [BrahmaCore.RestoreEpoch] = []
    /// C4b fix round 1 (I-1): the engine's commit-author record (`turnCommit`). Git is not rolled back, so a commit whose turn
    /// was recorded after the snapshot is still there; without its row it would read unverified, and a later turn reaching it
    /// could become its first recorder.
    var commitAuthors: [CommitAuthor] = []

    /// A row of C4b's `turnCommit`.
    struct CommitAuthor { var companyId: String, sha: String, itemId: String?, agentId: String, turnId: String?, createdAt: Date }

    /// What the live database says, or why it could not be read.
    enum Live {
        /// There was no live database: nothing newer than the snapshot exists.
        case none
        case read(RestoreCarry)
        case unreadable(String)
    }

    /// The live database's forward-only state. Tables an older schema lacks hold nothing to carry.
    static func read(_ db: Database) throws -> RestoreCarry {
        var c = RestoreCarry()
        func has(_ table: String) throws -> Bool { try db.tableExists(table) }
        if try has("grant") {
            c.grants = try Row.fetchAll(db, sql: """
                SELECT id, revokedAt, revokedBy, usesLeft FROM "grant" WHERE revokedAt IS NOT NULL OR usesLeft IS NOT NULL
                """).map { GrantEnd(id: $0["id"], revokedAt: $0["revokedAt"], revokedBy: $0["revokedBy"], usesLeft: $0["usesLeft"]) }
        }
        if try has("grant") {
            var active: [String: Double] = [:], sprints: [String: Set<String>] = [:]
            for g in try Grant.fetchAll(db) where g.revokedAt == nil {
                if active[g.companyId] == nil { active[g.companyId] = try Store.activeNow(db: db, companyId: g.companyId) }
                if sprints[g.companyId] == nil { sprints[g.companyId] = try Store.activeSprintIds(db, companyId: g.companyId) }
                let live = GrantResolver.isLive(g, activeNow: active[g.companyId] ?? 0, sprintActive: { sprints[g.companyId]?.contains($0) ?? false })
                if !live { c.notLiveGrants.append(g.id) }
            }
        }
        c.settings = try Settings.read(db)
        if try has("labTaint") {
            c.labMarks = try Row.fetchAll(db, sql: "SELECT agentId, source, markedAt FROM labTaint")
                .map { LabMark(agentId: $0["agentId"], source: $0["source"], markedAt: $0["markedAt"]) }
        }
        if try has("companyTaint") {
            c.companyMarks = try Row.fetchAll(db, sql: "SELECT companyId, source, profile, markedAt, clearedAt FROM companyTaint")
                .map { CompanyMark(companyId: $0["companyId"], source: $0["source"], profile: $0["profile"], markedAt: $0["markedAt"],
                                   clearedAt: $0["clearedAt"]) }
        }
        if try has("machineTaint") {
            c.machineMark = try Row.fetchOne(db, sql: "SELECT source, markedAt, clearedAt FROM machineTaint WHERE id = 1")
                .map { MachineMark(source: $0["source"], markedAt: $0["markedAt"], clearedAt: $0["clearedAt"]) }
        }
        if try has("taintedLabCommit") {
            c.neverCleanCommits = try Row.fetchAll(db, sql: "SELECT sha, recordedAt FROM taintedLabCommit").map { ($0["sha"], $0["recordedAt"]) }
        }
        if try has("labCommit") {
            c.taintedCommits = try Row.fetchAll(db, sql: "SELECT agentId, sha, turnId, recordedAt FROM labCommit WHERE tainted = 1")
                .map { TaintedCommit(agentId: $0["agentId"], sha: $0["sha"], turnId: $0["turnId"], recordedAt: $0["recordedAt"]) }
        }
        let agentColumns = Set(try db.columns(in: "agent").map(\.name))
        if agentColumns.isSuperset(of: ["sessionTainted", "freshSessionRequested", "taintSources"]) {
            c.taintedAgents = try Row.fetchAll(db, sql: """
                SELECT id, taintSources, freshSessionRequested FROM agent WHERE sessionTainted = 1 OR freshSessionRequested = 1
                """).map { AgentTaint(id: $0["id"], sources: $0["taintSources"], fresh: $0["freshSessionRequested"]) }
        }
        if try db.columns(in: "workItem").contains(where: { $0.name == "taintedOrigin" }) {
            c.taintedItems = try String.fetchAll(db, sql: "SELECT id FROM workItem WHERE taintedOrigin = 1")
        }
        if try has("taintedCommit") {
            let epoch = try db.columns(in: "taintedCommit").contains { $0.name == "restoreEpoch" } ? "restoreEpoch" : "NULL"
            c.itemCommitTaints = try Row.fetchAll(db, sql: """
                SELECT companyId, sha, itemId, agentId, turnId, source, createdAt, clearedBy, clearedAt, carriedTo,
                  \(epoch) AS restoreEpoch FROM taintedCommit
                """).map {
                    ItemCommitTaint(companyId: $0["companyId"], sha: $0["sha"], itemId: $0["itemId"], agentId: $0["agentId"],
                                    turnId: $0["turnId"], source: $0["source"], createdAt: $0["createdAt"], clearedBy: $0["clearedBy"],
                                    clearedAt: $0["clearedAt"], carriedTo: $0["carriedTo"], restoreEpoch: $0["restoreEpoch"])
                }
        }
        if try has("restoreEpoch") {
            c.restoreEpochs = try BrahmaCore.RestoreEpoch.fetchAll(db, sql: "SELECT * FROM restoreEpoch")
        }
        if try has("turnCommit") {
            c.commitAuthors = try Row.fetchAll(db, sql: "SELECT companyId, sha, itemId, agentId, turnId, createdAt FROM turnCommit").map {
                CommitAuthor(companyId: $0["companyId"], sha: $0["sha"], itemId: $0["itemId"], agentId: $0["agentId"], turnId: $0["turnId"],
                             createdAt: $0["createdAt"])
            }
        }
        return c
    }

    /// Writes into the staged (migrated) snapshot: the stop, the live database's grant ends and taint marks (or, when it could
    /// not be read, every grant revoked and every session and open item marked), and the machine-wide lab mark. Returns the
    /// notes the owner should see.
    static func apply(_ live: Live, to db: Database, snapshot: String, now: Date, gitTempRoot: URL? = nil) throws -> [String] {
        var notes: [String] = []
        // What the restore rolled back of what the owner had turned off (F2), read before anything is written.
        let rolledBack: [String]
        switch live {
        case .none: rolledBack = []
        case .read(let c): rolledBack = Settings.rolledBack(live: c.settings, restored: try Settings.read(db))
        case .unreadable:
            rolledBack = ["the previous database could not be read, so what this restore rolled back is unknown: review every "
                + "company's agents, profiles, network and access settings, extensions, auto-merge and secrets"]
        }
        let summary = rolledBack.isEmpty
            ? "nothing you had turned off was rolled back"
            : "differs from the snapshot (review before resuming): " + rolledBack.joined(separator: "; ")
        // The owner's stop, whatever the snapshot or the live database said: nothing runs until `brahma resume`.
        try db.execute(sql: #"INSERT OR REPLACE INTO engineStop (id, since, "by", note) VALUES (1, ?, 'restore', ?)"#,
                       arguments: [now, Store.flat("restored from \(snapshot): check grants, lab marks and main, then resume; " + summary, max: 4000)])
        notes += rolledBack.map { "after the restore: \($0)" }
        try raiseRestoreAlert(db, snapshot: snapshot, summary: summary, now: now)
        notes += try cancelApprovedReleases(db, now: now)
        notes += try cancelRequestedRollbacks(db, now: now)

        switch live {
        case .none:
            break
        case .read(let c):
            try carry(c, into: db, now: now)
            try keepStricterSettings(c.settings, into: db, now: now)
        case .unreadable(let why):
            try db.execute(sql: #"UPDATE "grant" SET revokedAt = ?, revokedBy = 'restore' WHERE revokedAt IS NULL"#, arguments: [now])
            try db.execute(sql: """
                UPDATE agent SET sessionTainted = 1, freshSessionRequested = 1,
                  taintSources = CASE WHEN taintSources = '' THEN 'restore: the previous database could not be read' ELSE taintSources END
                """)
            try db.execute(sql: "UPDATE workItem SET taintedOrigin = 1 WHERE status <> 'done'")
            try markEveryOpenItemsCommits(db, now: now)
            try recordRestoreEpochs(db, now: now, gitTempRoot: gitTempRoot)
            notes.append("the current database could not be read (\(Store.flat(why, max: 160))): every grant was revoked and every "
                + "agent's session and open item marked as having read outside content; every commit this database can't place "
                + "(off main as the snapshot recorded it) reads as outside content until you vouch for it")
        }

        // The machine-wide lab mark, kept with an earlier source if one stands; the owner's last clear time is kept too.
        let source = Store.flat("restored from \(snapshot): lab commits made after the snapshot are not trusted", max: 200)
        try db.execute(sql: """
            INSERT INTO machineTaint (id, source, markedAt) VALUES (1, ?, ?)
            ON CONFLICT(id) DO UPDATE SET source = COALESCE(machineTaint.source, excluded.source),
              markedAt = COALESCE(machineTaint.markedAt, excluded.markedAt)
            """, arguments: [source, now])
        return notes
    }

    /// Final-review m7: what a release approved in the snapshot but never started records after the restore.
    static let restoredRelease = "restored from backup; propose again"

    /// Final-review m7: a release the snapshot holds `approved` (the owner's approval, not yet started) is never carried out
    /// by the restored engine: the owner may have rolled it back, or approved something else, since. Each is `cancelled`
    /// (`"restored from backup; propose again"`, with an activity line), whatever the live database said. Returns the notes.
    static func cancelApprovedReleases(_ db: Database, now: Date) throws -> [String] {
        guard try db.tableExists("release") else { return [] }
        var notes: [String] = []
        let approved = try Release.filter(Column("status") == ReleaseStatus.approved.rawValue)
            .order(Column("companyId"), Column("number")).fetchAll(db)
        for var r in approved {
            r.status = .cancelled
            r.finishedAt = now
            r.failedReason = restoredRelease
            try r.update(db)
            try ActivityEvent(companyId: r.companyId, agentId: nil, turnId: nil, kind: .release,
                              text: "\(r.ref) (release \(r.version)) was cancelled: \(restoredRelease)", createdAt: now).insert(db)
            let name = try Company.fetchOne(db, key: r.companyId)?.name ?? r.companyId
            notes.append("\(name): \(r.ref) (release \(r.version)) was approved in the snapshot and is cancelled; propose it again")
        }
        return notes
    }

    /// Final-fix2 R1 (the m7 residual): what a rollback requested in the snapshot but never started records after the restore.
    static let restoredRollback = "restored from backup; request it again"

    /// Final-fix2 R1: a rollback the snapshot holds `requested` (the owner's request, not yet started) is never carried out by
    /// the restored engine, exactly like an approved release that never started (`cancelApprovedReleases`): since the
    /// snapshot the rollback may have run and later releases gone live, so running it again could take down what is live now.
    /// Each is cleared (`rollbackStatus` and `rollbackRequestedAt` nil; the release keeps its status, so the owner can request
    /// it again), with an activity line, whatever the live database said. A `running` rollback is not touched: engine start
    /// records it `interrupted` and never runs it again. Returns the notes.
    static func cancelRequestedRollbacks(_ db: Database, now: Date) throws -> [String] {
        guard try db.tableExists("release") else { return [] }
        var notes: [String] = []
        let requested = try Release.filter(Column("rollbackStatus") == RollbackStatus.requested.rawValue)
            .order(Column("companyId"), Column("number")).fetchAll(db)
        for var r in requested {
            r.rollbackStatus = nil
            r.rollbackRequestedAt = nil
            try r.update(db)
            try ActivityEvent(companyId: r.companyId, agentId: nil, turnId: nil, kind: .release,
                              text: "the rollback of \(r.ref) (release \(r.version)) was cancelled: \(restoredRollback)", createdAt: now).insert(db)
            let name = try Company.fetchOne(db, key: r.companyId)?.name ?? r.companyId
            notes.append("\(name): the rollback of \(r.ref) (release \(r.version)) was requested in the snapshot and is cancelled; "
                + "request it again")
        }
        return notes
    }

    /// The restore's owner alert in every company of the restored database (an engine alert in the Inbox and an activity line):
    /// it is stopped, and what it rolled back.
    static let restoreAlertReason = "restore"

    static func raiseRestoreAlert(_ db: Database, snapshot: String, summary: String, now: Date) throws {
        let text = "Brahma was restored from \(snapshot) and is stopped. It \(summary). Grants revoked after the snapshot and every "
            + "lab mark were kept; the machine-wide lab mark is set. Review, then resume (brahma resume)."
        for company in try Company.fetchAll(db) {
            try ActivityEvent(companyId: company.id, agentId: nil, turnId: nil, kind: .error, text: Store.flat(text, max: 4000),
                              createdAt: now).insert(db)
            // An earlier restore's alert still open in the snapshot says this one instead.
            _ = try Ask.filter(Column("companyId") == company.id && Column("kind") == AskKind.engineAlert
                               && Column("status") == AskStatus.pendingOwner.rawValue
                               && Column("subjectId") == Store.engineAlertKey(restoreAlertReason))
                .updateAll(db, Column("title").set(to: Store.flat(text, max: Store.maxAskTitle)),
                           Column("summary").set(to: Store.stripControls(text, keepNewlines: true)), Column("updatedAt").set(to: now))
            try Store.fileEngineAlert(db, company: company, reason: restoreAlertReason, text: text, now: now)
        }
    }

    /// S35: every security-relevant company setting (`CompanySecurity.fields`) and the owner-wide auto-merge and provider-policy
    /// (`subscriptionAllowed`) switches keep the stricter of the live and the restored value; owner-added providers follow the
    /// live set (`Settings.providerChanges`, Ruling 35). Rows (agents, extensions, presets, secrets) are reported only.
    ///
    /// Where auto-merge is kept off (owner-wide, or a company's), the snapshot's auto-approvals that have not landed are taken
    /// back exactly as switching it off live does (`Store.revokeAutoApprovals`), so none lands on a switch the owner turned off.
    static func keepStricterSettings(_ live: Settings, into db: Database, now: Date) throws {
        var revokeScopes: [String] = []
        for restored in try Company.fetchAll(db) {
            guard let current = live.companies[restored.id] else { continue }
            let (merged, lines) = CompanySecurity.stricter(live: current, restored: restored)
            if !lines.isEmpty { try merged.update(db) }
            if restored.autoMergeSmall, !merged.autoMergeSmall { revokeScopes.append(restored.id) }
        }
        var keptOffOwnerWide = false
        if live.ownerAutoMerge == false, try db.tableExists("ownerSettings") {
            try Store.ensureOwnerSettings(db)
            keptOffOwnerWide = try Store.ownerAutoMerge(db: db)   // the snapshot had it on
            try db.execute(sql: "UPDATE ownerSettings SET autoMerge = 0 WHERE id = 1")
        }
        // Plan X1 (Ruling 7b): subscription turns the owner switched off stay off.
        if live.ownerSubscriptionAllowed == false, try db.tableExists("ownerSettings") {
            try Store.ensureOwnerSettings(db)
            try db.execute(sql: "UPDATE ownerSettings SET subscriptionAllowed = 0 WHERE id = 1")
        }
        // Plan X1 (Ruling 35): owner-added providers follow the live set (built-ins are untouched).
        for change in Settings.providerChanges(live: live, restored: try Settings.read(db)) {
            switch change {
            case .removed(let id):
                try db.execute(sql: "DELETE FROM modelRoute WHERE provider = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM providerCap WHERE provider = ?", arguments: [id])
                try db.execute(sql: "DELETE FROM provider WHERE id = ? AND builtin = 0", arguments: [id])
            case .changed(let id, let endpoint, _):
                try db.execute(sql: "UPDATE provider SET baseURL = ?, host = ?, keySecret = ?, adapter = ?, lan = ? WHERE id = ? AND builtin = 0",
                               arguments: [endpoint.baseURL, endpoint.host, endpoint.keySecret, endpoint.adapter, endpoint.lan, id])
            }
        }
        // S36: the narrower auto-merge folder list.
        if try db.tableExists("ownerSettings") {
            let restored = try Settings.read(db).ownerAutoMergePaths
            let paths = Settings.narrowerAutoMergePaths(live: live.ownerAutoMergePaths, restored: restored)
            if paths != restored {
                try Store.ensureOwnerSettings(db)
                let json = paths.map { String(decoding: (try? JSONEncoder().encode($0)) ?? Data("[]".utf8), as: UTF8.self) }
                try db.execute(sql: "UPDATE ownerSettings SET autoMergePaths = ? WHERE id = 1", arguments: [json])
            }
        }
        func revoke(_ companyId: String?) throws {
            try Store.revokeAutoApprovals(db: db, companyId: companyId, now: now) { item, text in
                var event = WorkItemEvent(id: nil, companyId: item.companyId, itemId: item.id, actorId: "system", kind: .edited,
                                          text: text + " (kept off by a restore)", createdAt: now,
                                          createdActive: try Store.activeNow(db: db, companyId: item.companyId))
                try event.insert(db)
            }
        }
        if keptOffOwnerWide { try revoke(nil) } else { for id in revokeScopes { try revoke(id) } }
    }

    private static func carry(_ c: RestoreCarry, into db: Database, now: Date) throws {
        // Revocations first (their own time and author), then every other grant the live database no longer counts (F1).
        for g in c.grants {
            if let revokedAt = g.revokedAt {
                try db.execute(sql: #"UPDATE "grant" SET revokedAt = ?, revokedBy = ? WHERE id = ? AND revokedAt IS NULL"#,
                               arguments: [revokedAt, g.revokedBy ?? "restore", g.id])
            }
            if let uses = g.usesLeft {
                try db.execute(sql: #"UPDATE "grant" SET usesLeft = ? WHERE id = ? AND (usesLeft IS NULL OR usesLeft > ?)"#,
                               arguments: [uses, g.id, uses])
            }
        }
        for id in c.notLiveGrants {
            try db.execute(sql: #"UPDATE "grant" SET revokedAt = ?, revokedBy = 'restore' WHERE id = ? AND revokedAt IS NULL"#,
                           arguments: [now, id])
        }
        for m in c.labMarks {
            try db.execute(sql: """
                INSERT OR IGNORE INTO labTaint (agentId, source, markedAt) SELECT ?, ?, ? WHERE EXISTS (SELECT 1 FROM agent WHERE id = ?)
                """, arguments: [m.agentId, m.source, m.markedAt, m.agentId])
        }
        for m in c.companyMarks where try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM company WHERE id = ?", arguments: [m.companyId]) ?? 0 > 0 {
            // A mark either database holds stands; a Full mark wins; the later clear is kept (it is the stricter one, S33).
            try db.execute(sql: """
                INSERT INTO companyTaint (companyId, source, profile, markedAt, clearedAt) VALUES (?, ?, ?, ?, ?)
                ON CONFLICT(companyId) DO UPDATE SET
                  source = COALESCE(companyTaint.source, excluded.source),
                  markedAt = COALESCE(companyTaint.markedAt, excluded.markedAt),
                  profile = CASE WHEN excluded.profile = 'full' OR companyTaint.profile IS NULL THEN COALESCE(excluded.profile, companyTaint.profile)
                                 ELSE companyTaint.profile END,
                  clearedAt = CASE WHEN companyTaint.clearedAt IS NULL OR excluded.clearedAt > companyTaint.clearedAt
                                   THEN COALESCE(excluded.clearedAt, companyTaint.clearedAt) ELSE companyTaint.clearedAt END
                """, arguments: [m.companyId, m.source, m.profile, m.markedAt, m.clearedAt])
        }
        if let m = c.machineMark {
            try db.execute(sql: """
                INSERT INTO machineTaint (id, source, markedAt, clearedAt) VALUES (1, ?, ?, ?)
                ON CONFLICT(id) DO UPDATE SET source = COALESCE(machineTaint.source, excluded.source),
                  markedAt = COALESCE(machineTaint.markedAt, excluded.markedAt),
                  clearedAt = CASE WHEN machineTaint.clearedAt IS NULL OR excluded.clearedAt > machineTaint.clearedAt
                                   THEN COALESCE(excluded.clearedAt, machineTaint.clearedAt) ELSE machineTaint.clearedAt END
                """, arguments: [m.source, m.markedAt, m.clearedAt])
        }
        for commit in c.neverCleanCommits {
            try db.execute(sql: "INSERT OR IGNORE INTO taintedLabCommit (sha, recordedAt) VALUES (?, ?)", arguments: [commit.sha, commit.recordedAt])
        }
        for t in c.taintedCommits {
            try db.execute(sql: """
                INSERT INTO labCommit (agentId, sha, turnId, tainted, recordedAt) SELECT ?, ?, ?, 1, ?
                WHERE EXISTS (SELECT 1 FROM agent WHERE id = ?)
                ON CONFLICT(agentId, sha) DO UPDATE SET tainted = 1
                """, arguments: [t.agentId, t.sha, t.turnId, t.recordedAt, t.agentId])
            // A commit tainted in one lab is never clean in another either (it may have been copied there).
            try db.execute(sql: "INSERT OR IGNORE INTO taintedLabCommit (sha, recordedAt) VALUES (?, ?)", arguments: [t.sha, t.recordedAt])
        }
        for a in c.taintedAgents {
            try db.execute(sql: """
                UPDATE agent SET sessionTainted = 1, freshSessionRequested = freshSessionRequested OR ?,
                  taintSources = CASE WHEN taintSources = '' THEN ? ELSE taintSources END
                WHERE id = ?
                """, arguments: [a.fresh, a.sources.isEmpty ? "restore: tainted before the restore" : a.sources, a.id])
        }
        for id in c.taintedItems {
            try db.execute(sql: "UPDATE workItem SET taintedOrigin = 1 WHERE id = ?", arguments: [id])
        }
        try carryRestoreEpochs(c.restoreEpochs, into: db)
        try carryItemCommitTaints(c.itemCommitTaints, into: db)
        try carryCommitAuthors(c.commitAuthors, into: db)
    }

    /// C4b fix round 1 (I-1): the live database's commit-author rows come back (when their company is in the snapshot). The
    /// first record of a sha wins, as at recording: a row the snapshot already has stays as it is there (`INSERT OR IGNORE`).
    /// A row naming an agent the snapshot lacks is kept too: it attributes to nobody visible, but still holds the sha against
    /// a later turn.
    static func carryCommitAuthors(_ rows: [CommitAuthor], into db: Database) throws {
        guard !rows.isEmpty, try db.tableExists("turnCommit") else { return }
        for r in rows {
            try db.execute(sql: """
                INSERT OR IGNORE INTO turnCommit (companyId, sha, itemId, agentId, turnId, createdAt)
                SELECT ?, ?, ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM company WHERE id = ?)
                """, arguments: [r.companyId, r.sha, r.itemId, r.agentId, r.turnId, r.createdAt, r.companyId])
        }
    }

    /// P2 R5-1: the live database's restore epochs come back like its tainted commits (`carryItemCommitTaints`): one only it
    /// has is inserted as it is there (when its company is in the snapshot); one uncleared in either database stays uncleared.
    /// A clearing carried in has no `taintOrder` sequence here, so it counts as uncleared at every publish (fail closed).
    static func carryRestoreEpochs(_ epochs: [BrahmaCore.RestoreEpoch], into db: Database) throws {
        guard !epochs.isEmpty, try db.tableExists("restoreEpoch") else { return }
        for e in epochs {
            try db.execute(sql: """
                INSERT INTO restoreEpoch (id, companyId, mainCommit, listed, source, createdAt, clearedBy, clearedAt)
                SELECT ?, ?, ?, ?, ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM company WHERE id = ?)
                ON CONFLICT(id) DO UPDATE SET
                  clearedBy = CASE WHEN excluded.clearedBy IS NULL THEN NULL ELSE restoreEpoch.clearedBy END,
                  clearedAt = CASE WHEN excluded.clearedBy IS NULL THEN NULL ELSE restoreEpoch.clearedAt END
                """, arguments: [e.id, e.companyId, e.mainCommit, e.listed, e.source, e.createdAt, e.clearedBy, e.clearedAt, e.companyId])
        }
    }

    /// P2 R4-4: the live database's tainted commits come back, so a restore never loses one (git is not rolled back). A row
    /// only the live database has is inserted as it is there (when its company is in the snapshot); a row uncleared in either
    /// database stays uncleared (an uncleared live row undoes the snapshot's clearing of it); everything else of a row the
    /// snapshot has stays as the snapshot has it. Ruling 19's sequences are not carried: the two databases' sequences are not
    /// comparable, so a clearing carried in has none in the restored database and counts as uncleared at every publish
    /// (fail closed). A merged row keeps a restore epoch only when both rows carry one (P2 breaker B-4): a row a turn (or a
    /// marker, or a rebase carry) wrote in either database is never epoch-only, so the owner's restore vouch
    /// (`vouchRestoredCommits`, which clears only epoch rows) can't clear it.
    static func carryItemCommitTaints(_ rows: [ItemCommitTaint], into db: Database) throws {
        guard !rows.isEmpty, try db.tableExists("taintedCommit") else { return }
        for r in rows {
            try db.execute(sql: """
                INSERT INTO taintedCommit (companyId, sha, itemId, agentId, turnId, source, createdAt, clearedBy, clearedAt, carriedTo,
                  restoreEpoch)
                SELECT ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ? WHERE EXISTS (SELECT 1 FROM company WHERE id = ?)
                ON CONFLICT(companyId, sha) DO UPDATE SET
                  clearedBy = CASE WHEN excluded.clearedBy IS NULL THEN NULL ELSE taintedCommit.clearedBy END,
                  clearedAt = CASE WHEN excluded.clearedBy IS NULL THEN NULL ELSE taintedCommit.clearedAt END,
                  restoreEpoch = CASE WHEN taintedCommit.restoreEpoch IS NULL OR excluded.restoreEpoch IS NULL THEN NULL
                                      ELSE taintedCommit.restoreEpoch END
                """, arguments: [r.companyId, r.sha, r.itemId, r.agentId, r.turnId, r.source, r.createdAt, r.clearedBy, r.clearedAt,
                                 r.carriedTo, r.restoreEpoch, r.companyId])
        }
    }

    /// The source of the fail-closed markers when the live database's tainted commits can't be carried (P2 R4-4).
    static let unreadableCommitTaintSource = "restore: the previous database could not be read"

    /// P2 R4-4, when the live database can't be read: its tainted commits are unknown, so every open item of the restored
    /// database gets an `unrecorded-…` marker, as a turn-end record that failed does: none of the item's commits is provably
    /// clean, so its diff, its files and a commit ref to anything on its branch read tainted until it is merged through review
    /// or the owner vouches for it.
    static func markEveryOpenItemsCommits(_ db: Database, now: Date) throws {
        guard try db.tableExists("taintedCommit") else { return }
        for row in try Row.fetchAll(db, sql: "SELECT id, companyId FROM workItem WHERE status <> 'done'") {
            let (itemId, companyId): (String, String) = (row["id"], row["companyId"])
            try db.execute(sql: """
                INSERT OR IGNORE INTO taintedCommit (companyId, sha, itemId, agentId, turnId, source, createdAt)
                VALUES (?, ?, ?, NULL, NULL, ?, ?)
                """, arguments: [companyId, BrahmaCore.TaintedCommit.unrecordedPrefix + UUID().uuidString, itemId,
                                 unreadableCommitTaintSource, now])
        }
    }
}

extension RestoreCarry {
    /// Ruling 22 (P2 R5-1), when the live database can't be read: its tainted commits are unknown, and git is not rolled back,
    /// so a commit made after the snapshot (on the branch of an item the snapshot doesn't have, or of one it has as done) has
    /// no row here and would read clean. Each company of the restored database gets a restore epoch:
    /// - every commit not in the history of `main` as the snapshot recorded it (`company.mainCommit`; none recorded: every
    ///   commit) reads tainted (`RefTaint`), and every file or diff whose range from that `main` holds one, listed or not
    ///   (Rulings 24 and 25: a dangling or reflog-only commit the listing can't see may be made reachable later);
    /// - its repository is listed now, to attribute what it holds: every commit any ref or worktree `HEAD` holds that is not
    ///   in that `main`'s history is recorded as a tainted commit naming the epoch (an existing row is kept as it is), of the
    ///   item whose `item/<KEY>` branch holds it when this database has that item, else of no item; the epoch is `listed`.
    ///   When that listing fails (no repository, git fails, past git's output cap, no data-home temp folder), nothing is
    ///   recorded and the epoch is not `listed`; either way the rule above applies, so the listing never makes a commit clean.
    /// Either way it stands until the owner vouches (`Store.vouchRestoredCommits`). Never throws for git; a database error
    /// throws (the restore then changes nothing).
    static func recordRestoreEpochs(_ db: Database, now: Date, gitTempRoot: URL?) throws {
        guard try db.tableExists("restoreEpoch"), try db.tableExists("taintedCommit") else { return }
        let source = unreadableCommitTaintSource
        for company in try Row.fetchAll(db, sql: "SELECT id, workspacePath, mainCommit FROM company") {
            let (companyId, workspace, main): (String, String, String?) = (company["id"], company["workspacePath"], company["mainCommit"])
            let epoch = UUID().uuidString
            var listing: [(sha: String, itemId: String?)]?
            if let gitTempRoot {
                do {
                    let git = SafeGit(workspace: URL(fileURLWithPath: workspace, isDirectory: true), runner: LiveGitRunner(tempRoot: gitTempRoot))
                    var keys: [String: String] = [:]
                    for row in try Row.fetchAll(db, sql: "SELECT id, key FROM workItem WHERE companyId = ?", arguments: [companyId]) {
                        keys[row["key"]] = row["id"]
                    }
                    var found: [(sha: String, itemId: String?)] = []
                    for (branch, head) in try git.branchHeads(prefix: "item/").sorted(by: { $0.key < $1.key }) {
                        guard let itemId = keys[String(branch.dropFirst("item/".count))] else { continue }
                        found += try git.commits(from: head, excluding: main).map { ($0, itemId) }
                    }
                    found += try git.commits(from: nil, excluding: main).map { ($0, nil) }
                    listing = found
                } catch {
                    listing = nil
                }
            }
            for c in listing ?? [] {
                try db.execute(sql: """
                    INSERT OR IGNORE INTO taintedCommit (companyId, sha, itemId, agentId, turnId, source, createdAt, restoreEpoch)
                    VALUES (?, ?, ?, NULL, NULL, ?, ?, ?)
                    """, arguments: [companyId, c.sha, c.itemId, source, now, epoch])
            }
            try BrahmaCore.RestoreEpoch(id: epoch, companyId: companyId, mainCommit: main, listed: listing != nil, source: source,
                                        createdAt: now, clearedBy: nil, clearedAt: nil).insert(db)
        }
    }

    /// The settings the owner turns off to make Brahma safer (fix-wave F2), read from one database. Tables an older schema
    /// lacks read as empty.
    struct Settings {
        var companies: [String: Company] = [:]
        var agents: [String: (name: String, companyId: String, killed: Bool)] = [:]
        /// `companyId|extension id` → enabled.
        var extensions: [String: Bool] = [:]
        /// `companyId|preset id` of every enabled access preset.
        var presets: Set<String> = []
        /// `companyId|secret name`.
        var secrets: Set<String> = []
        var ownerAutoMerge: Bool?
        /// `ownerSettings.autoMergePaths` (S36): nil is the pack's list (else the default).
        var ownerAutoMergePaths: [String]?
        /// `ownerSettings.subscriptionAllowed` (Plan X1, Ruling 7b): the provider-policy switch for subscription turns.
        var ownerSubscriptionAllowed: Bool?
        /// The owner-added (non-built-in) providers by id (Plan X1, Ruling 35); nil when the database has no `provider` table.
        /// Their hosts are the gateway's upstream allowlist, so a restore follows the live set.
        var providers: [String: ProviderEndpoint]?

        struct ProviderEndpoint: Equatable {
            var baseURL: String
            var host: String
            var keySecret: String?
            var adapter: String
            var lan: Bool
        }

        /// Every `ownerSettings` column, classified for restores (S36; `OwnerSettingsSecurityTests` fails on a new column in
        /// neither list). Security-relevant ones keep the stricter value (`keepStricterSettings`).
        static let ownerSecurityColumns: [String: String] = [
            "autoMerge": "off is stricter: kept off when it is off live",
            "autoMergePaths": "the narrower folder list: both set, their intersection; one set, the live list",
            "subscriptionAllowed": "off is stricter: subscription turns kept off when they are off live",
        ]
        static let ownerNotSecurityColumns: [String: String] = [
            "id": "the one row", "timeZone": "calendar display", "planTier": "spend pacing", "weeklyShare": "spend pacing",
            "pctPerDollar": "usage calibration", "pctPerDollar5h": "usage calibration", "calibUtil": "usage calibration",
            "calibResetsAt": "usage calibration", "calibCost": "usage calibration", "calibration": "usage calibration",
            "hotPaths": "merge serialization against conflicts; risk tags use the built-in list, not this one",
            "pacingPreset": "spend pacing", "dayStartUtil": "spend pacing (the daily share's baseline)",
            "dayStartDate": "spend pacing (the daily share's baseline)",
        ]

        /// Plan X1 (Ruling 35): what a restore changes so the owner-added providers follow the live set — a restored one absent
        /// live is removed (with the routes and caps naming it); one whose endpoint, key name or adapter differs takes the live
        /// values, and its LAN flag is the stricter of the two (off unless both are on; Ruling 60). A provider only live is not
        /// added back. Nothing when either database has no `provider` table.
        enum ProviderChange: Equatable {
            case removed(String)
            case changed(String, live: ProviderEndpoint, restored: ProviderEndpoint)

            var line: String {
                switch self {
                case .removed(let id):
                    return "provider \(id), removed after the snapshot, stays removed with the routes and caps naming it"
                case .changed(let id, let live, let restored):
                    func show(_ e: ProviderEndpoint) -> String {
                        "\(e.baseURL) (host \(e.host), key \(e.keySecret ?? "none"), adapter \(e.adapter)\(e.lan ? ", LAN" : ""))"
                    }
                    return "provider \(id) kept at \(show(live)) (the snapshot had \(show(restored)))"
                }
            }
        }

        static func providerChanges(live: Settings, restored: Settings) -> [ProviderChange] {
            guard let liveProviders = live.providers, let restoredProviders = restored.providers else { return [] }
            return restoredProviders.sorted { $0.key < $1.key }.compactMap { id, then in
                guard var now = liveProviders[id] else { return .removed(id) }
                now.lan = now.lan && then.lan
                return now == then ? nil : .changed(id, live: now, restored: then)
            }
        }

        /// S36: the narrower auto-merge folder list. Both set: their intersection (in the live order); one set: the live list.
        static func narrowerAutoMergePaths(live: [String]?, restored: [String]?) -> [String]? {
            guard let live, let restored else { return live }
            let allowed = Set(restored)
            return live.filter { allowed.contains($0) }
        }

        static func read(_ db: Database) throws -> Settings {
            var s = Settings()
            for c in try Company.fetchAll(db) { s.companies[c.id] = c }
            for row in try Row.fetchAll(db, sql: "SELECT id, name, companyId, state FROM agent") {
                s.agents[row["id"]] = (row["name"], row["companyId"], (row["state"] as String) == AgentState.killed.rawValue)
            }
            if try db.tableExists("companyExtension") {
                for row in try Row.fetchAll(db, sql: "SELECT companyId, id, enabled FROM companyExtension") {
                    s.extensions["\(row["companyId"] as String)|\(row["id"] as String)"] = row["enabled"]
                }
            }
            if try db.tableExists("accessPreset") {
                s.presets = Set(try Row.fetchAll(db, sql: "SELECT companyId, presetId FROM accessPreset WHERE enabled = 1")
                    .map { "\($0["companyId"] as String)|\($0["presetId"] as String)" })
            }
            if try db.tableExists("secret") {
                s.secrets = Set(try Row.fetchAll(db, sql: "SELECT companyId, name FROM secret").map { "\($0["companyId"] as String)|\($0["name"] as String)" })
            }
            if try db.tableExists("ownerSettings"), try db.columns(in: "ownerSettings").contains(where: { $0.name == "autoMerge" }) {
                s.ownerAutoMerge = try Bool.fetchOne(db, sql: "SELECT autoMerge FROM ownerSettings WHERE id = 1")
                s.ownerAutoMergePaths = try String.fetchOne(db, sql: "SELECT autoMergePaths FROM ownerSettings WHERE id = 1")
                    .flatMap { try? JSONDecoder().decode([String].self, from: Data($0.utf8)) }
            }
            if try db.tableExists("ownerSettings"), try db.columns(in: "ownerSettings").contains(where: { $0.name == "subscriptionAllowed" }) {
                s.ownerSubscriptionAllowed = try Bool.fetchOne(db, sql: "SELECT subscriptionAllowed FROM ownerSettings WHERE id = 1")
            }
            if try db.tableExists("provider") {
                var providers: [String: ProviderEndpoint] = [:]
                for row in try Row.fetchAll(db, sql: "SELECT id, baseURL, host, keySecret, adapter, lan FROM provider WHERE builtin = 0") {
                    providers[row["id"]] = ProviderEndpoint(baseURL: row["baseURL"], host: row["host"], keySecret: row["keySecret"],
                                                            adapter: row["adapter"], lan: row["lan"])
                }
                s.providers = providers
            }
            return s
        }

        /// Every setting the owner had turned off (or narrowed, or removed) in `live` that `restored` has on again, in words:
        /// the company settings and the owner-wide auto-merge the restore keeps at the stricter value (S35), and the rows it
        /// reports only (agents and companies, extensions, access presets, secrets).
        static func rolledBack(live: Settings, restored: Settings) -> [String] {
            var out: [String] = []
            func companyName(_ id: String) -> String { restored.companies[id]?.name ?? live.companies[id]?.name ?? id }
            func split(_ key: String) -> (String, String) {
                let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
                return (parts.first ?? key, parts.count > 1 ? parts[1] : "")
            }
            for (id, c) in restored.companies.sorted(by: { $0.value.name < $1.value.name }) {
                guard let now = live.companies[id] else { out.append("company \(c.name), removed after the snapshot, is back"); continue }
                // S35: every security-relevant company setting keeps the stricter value (`CompanySecurity`); reported here.
                out += CompanySecurity.stricter(live: now, restored: c).1.map { "\(c.name): \($0)" }
            }
            for (id, a) in restored.agents.sorted(by: { $0.value.name < $1.value.name }) where !a.killed {
                if live.agents[id]?.killed ?? true {
                    out.append("@\(a.name) (\(companyName(a.companyId))), removed after the snapshot, is back")
                }
            }
            for (key, enabled) in restored.extensions.sorted(by: { $0.key < $1.key }) where enabled {
                let (company, ext) = split(key)
                switch live.extensions[key] {
                case false?: out.append("\(companyName(company)): extension \(ext) enabled again")
                case nil: out.append("\(companyName(company)): extension \(ext), removed after the snapshot, is back")
                default: break
                }
            }
            for key in restored.presets.subtracting(live.presets).sorted() {
                let (company, preset) = split(key)
                out.append("\(companyName(company)): access preset \(preset) on again")
            }
            for key in restored.secrets.subtracting(live.secrets).sorted() {
                let (company, name) = split(key)
                out.append("\(companyName(company)): secret \(name), removed after the snapshot, is listed again (its value is not)")
            }
            if restored.ownerAutoMerge != false, live.ownerAutoMerge == false { out.append("owner-wide auto-merge kept off (the snapshot had it on)") }
            if restored.ownerSubscriptionAllowed != false, live.ownerSubscriptionAllowed == false {
                out.append("owner-wide subscription turns kept off by provider policy (the snapshot had them on)")
            }
            out += providerChanges(live: live, restored: restored).map(\.line)
            let paths = narrowerAutoMergePaths(live: live.ownerAutoMergePaths, restored: restored.ownerAutoMergePaths)
            if paths != restored.ownerAutoMergePaths {
                func show(_ p: [String]?) -> String { p.map { $0.isEmpty ? "none" : $0.joined(separator: ", ") } ?? "the pack's list" }
                out.append("owner-wide auto-merge folders kept at \(show(paths)) (the snapshot had \(show(restored.ownerAutoMergePaths)))")
            }
            return out
        }
    }
}
