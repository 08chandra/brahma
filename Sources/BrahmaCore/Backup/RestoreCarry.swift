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
        return c
    }

    /// Writes into the staged (migrated) snapshot: the stop, the live database's grant ends and taint marks (or, when it could
    /// not be read, every grant revoked and every session and open item marked), and the machine-wide lab mark. Returns the
    /// notes the owner should see.
    static func apply(_ live: Live, to db: Database, snapshot: String, now: Date) throws -> [String] {
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

    /// S35: every security-relevant company setting (`CompanySecurity.fields`) and the owner-wide auto-merge switch keep the
    /// stricter of the live and the restored value. Rows (agents, extensions, presets, secrets) are reported only.
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
    }
}

extension RestoreCarry {
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

        /// Every `ownerSettings` column, classified for restores (S36; `OwnerSettingsSecurityTests` fails on a new column in
        /// neither list). Security-relevant ones keep the stricter value (`keepStricterSettings`).
        static let ownerSecurityColumns: [String: String] = [
            "autoMerge": "off is stricter: kept off when it is off live",
            "autoMergePaths": "the narrower folder list: both set, their intersection; one set, the live list",
        ]
        static let ownerNotSecurityColumns: [String: String] = [
            "id": "the one row", "timeZone": "calendar display", "planTier": "spend pacing", "weeklyShare": "spend pacing",
            "pctPerDollar": "usage calibration", "pctPerDollar5h": "usage calibration", "calibUtil": "usage calibration",
            "calibResetsAt": "usage calibration", "calibCost": "usage calibration", "calibration": "usage calibration",
            "hotPaths": "merge serialization against conflicts; risk tags use the built-in list, not this one",
        ]

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
            let paths = narrowerAutoMergePaths(live: live.ownerAutoMergePaths, restored: restored.ownerAutoMergePaths)
            if paths != restored.ownerAutoMergePaths {
                func show(_ p: [String]?) -> String { p.map { $0.isEmpty ? "none" : $0.joined(separator: ", ") } ?? "the pack's list" }
                out.append("owner-wide auto-merge folders kept at \(show(paths)) (the snapshot had \(show(restored.ownerAutoMergePaths)))")
            }
            return out
        }
    }
}
