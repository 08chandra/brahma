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

    var grants: [GrantEnd] = []
    var labMarks: [LabMark] = []
    var companyMarks: [CompanyMark] = []
    var machineMark: MachineMark?
    var neverCleanCommits: [(sha: String, recordedAt: Date)] = []
    var taintedCommits: [TaintedCommit] = []
    var taintedAgents: [AgentTaint] = []
    var taintedItems: [String] = []

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
        return c
    }

    /// Writes into the staged (migrated) snapshot: the stop, the live database's grant ends and taint marks (or, when it could
    /// not be read, every grant revoked and every session and open item marked), and the machine-wide lab mark. Returns the
    /// notes the owner should see.
    static func apply(_ live: Live, to db: Database, snapshot: String, now: Date) throws -> [String] {
        var notes: [String] = []
        // The owner's stop, whatever the snapshot or the live database said: nothing runs until `brahma resume`.
        try db.execute(sql: #"INSERT OR REPLACE INTO engineStop (id, since, "by", note) VALUES (1, ?, 'restore', ?)"#,
                       arguments: [now, "restored from \(Store.flat(snapshot, max: 120)): check grants, lab marks and main, then resume"])

        switch live {
        case .none:
            break
        case .read(let c):
            try carry(c, into: db)
        case .unreadable(let why):
            try db.execute(sql: #"UPDATE "grant" SET revokedAt = ?, revokedBy = 'restore' WHERE revokedAt IS NULL"#, arguments: [now])
            try db.execute(sql: """
                UPDATE agent SET sessionTainted = 1, freshSessionRequested = 1,
                  taintSources = CASE WHEN taintSources = '' THEN 'restore: the previous database could not be read' ELSE taintSources END
                """)
            try db.execute(sql: "UPDATE workItem SET taintedOrigin = 1 WHERE status <> 'done'")
            notes.append("the current database could not be read (\(Store.flat(why, max: 160))): every grant was revoked and every "
                + "agent's session and open item marked as having read outside content")
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

    private static func carry(_ c: RestoreCarry, into db: Database) throws {
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
    }
}
