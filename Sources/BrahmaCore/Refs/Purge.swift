import Foundation
import GRDB
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// What the owner's purge of a ref (`Store.purge`) removed and what may still hold it. Named apart from ML's `PurgeReport
/// { backups, transcripts }` (a resource's purge), from which `backupsFlagged` and `transcripts` are copied.
public struct RefPurgeReport: Codable, Equatable, Sendable {
    /// Vault files removed (`<area>/<name>`).
    public var vaultPaths: [String]
    /// Share refs deleted (`refs/brahma/shares/<id>`).
    public var gitRefs: [String]
    /// DB and data-home backups taken since the content was shared (by name): they may still contain it.
    public var backupsFlagged: [String]
    /// Turn ids whose captured transcripts may contain it.
    public var transcripts: [String]
    /// The content is committed: its share refs are gone, but the company's git history still holds it.
    public var stillInHistory: Bool
    /// C5 fix round 1: the files the owner exported it to (`refRead` rows `via = export`): copies outside Brahma, which it
    /// can't delete; each gets an owner notice.
    public var exportedCopies: [String] = []

    public init(vaultPaths: [String] = [], gitRefs: [String] = [], backupsFlagged: [String] = [], transcripts: [String] = [],
                stillInHistory: Bool = false, exportedCopies: [String] = []) {
        self.vaultPaths = vaultPaths; self.gitRefs = gitRefs; self.backupsFlagged = backupsFlagged; self.transcripts = transcripts
        self.stillInHistory = stillInHistory; self.exportedCopies = exportedCopies
    }
}

/// Plan C Task C2b (design §4.5): the owner's purge of shared content. Owner callers only (the CLI and the app): nothing in
/// `CompanyTools` reaches it, and no company tool is named for it.
extension Store {
    /// Purges `ref` (as shared: a resource `F-<n>`, a pinned file or diff, a commit, a memory entry) from everywhere Brahma keeps
    /// it, in this order:
    /// 1. what carries it: every `messageRef` of the company with its canonical form, and the pin's own `share`/`snapshot`;
    ///    nothing found in this company is `"that ref isn't available to you"`;
    /// 2. the bytes: a resource through ML's `purgeResource` (secure delete, FTS optimize, WAL checkpoint, vault and mirror
    ///    removal); a memory entry through ML's `ownerDeleteMemory` (`purgeMemoryDocs`); worktree-diff snapshots and the diff
    ///    cache of a committed diff through `Vault` (their rows get `purgedAt`); C2b-carry fix round 1 (F1): every flattened
    ///    copy of a vouched PDF by the ref's name (or a resource's bytes), its vouch withdrawn first;
    /// 3. git, under the company's `GitLock` and never while a turn of the company runs (pruning while an agent writes the
    ///    object store can orphan its commit): `deleteShareRef` for every share, then `SafeGit.expireAndPrune` with the blobs
    ///    the engine itself wrote for `@worktree`/`.brahma` pins, each of which must be gone afterwards;
    /// 4. one transaction: every carrying `messageRef` becomes `purged`, a `purgeLog` row, an `.access` activity line, and
    ///    one owner notice per flagged backup (`"backup 2026-10-20 contains purged content · delete or re-create"`), per
    ///    transcript, and for committed content (`stillInHistory`).
    /// Taint rows (`taintedCommit`) are never deleted. A purge that could not remove everything (an object git still holds,
    /// a vault file that would not go) raises an engine alert and throws `WorkError.conflict` after recording what it did, so
    /// it can be run again; it is never reported as complete.
    ///
    /// C2b fix round 1: the git part runs inside the company's purge fence (`PurgeFence`, which every turn start takes
    /// shared), and the running-turn check is made again inside it, so no turn starts between the check and the prune. The
    /// ref's name appears in messages, alerts and notices only with the stored values (`knownValues`, and the engine's
    /// redactor) and the secret patterns redacted from it.
    public func purge(companyId: String, ref: WorkRef, contentVault: ContentVault, paths: BrahmaPaths,
                      knownValues: [(name: String, value: String)] = [], now: Date = Store.now()) throws -> RefPurgeReport {
        guard contentVault.paths == paths else { throw WorkError.invalid("the vault belongs to another data home") }
        guard let company = try company(id: companyId) else { throw WorkError.notFound(Self.refUnavailable) }
        let workspace = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        let canonical = Self.unpinned(ref).canonical
        let shown = (try? redact(SecretGate.shown(canonical, knownValues: knownValues))) ?? "a shared ref"
        let vault = Vault(paths: paths, companyId: companyId, content: contentVault)
        let blobPin = ref.kind == .file && (ref.isWorktree || (ref.branch == nil && ref.id.hasPrefix(".brahma/")))

        // 1. What carries it.
        let rows = try writer.read { db in
            try MessageRef.fetchAll(db, sql: "SELECT * FROM messageRef WHERE companyId = ? AND canonical = ? ORDER BY createdAt, id",
                                    arguments: [companyId, canonical])
        }
        var shares: [String: String?] = [:]          // share id → the object it pinned
        var snapshotIds = Set<String>()
        for row in rows {
            let params = (try? JSONDecoder().decode([String: String].self, from: Data(row.params.utf8))) ?? [:]
            if let share = params["share"] { shares[share] = row.rev }
            if let snapshot = params["snapshot"] { snapshotIds.insert(snapshot) }
        }
        let git = try refGit(workspace)
        if let share = ref.params["share"], shares[share] == nil {
            // A pin no message carries: only when its share ref in this company's repository points at its object.
            if let rev = ref.rev, (try? git.shareTarget(share)) == rev { shares[share] = rev }
        }
        if let snapshot = ref.params["snapshot"] { snapshotIds.insert(snapshot) }
        let snapshots = try writer.read { db -> [RefSnapshot] in
            var found = try RefSnapshot.fetchAll(db, sql: "SELECT * FROM refSnapshot WHERE companyId = ? AND kind = ? AND id IN (\(snapshotIds.map { _ in "?" }.joined(separator: ", ")))",
                                                 arguments: StatementArguments([companyId, RefSnapshot.worktreeDiff]) + StatementArguments(Array(snapshotIds)))
            // A committed diff's cache rows (keyed `<base>..<head>[/<path hash>]`) for every head it was shared at.
            if ref.kind == .diff, !ref.isWorktree {
                let heads = Set(rows.compactMap(\.rev) + [ref.rev].compactMap { $0 }).filter { (try? SafeGit.checkRevShape($0)) != nil }
                for head in heads {
                    found += try RefSnapshot.fetchAll(db, sql: """
                        SELECT * FROM refSnapshot WHERE companyId = ? AND kind = ? AND instr(cacheKey, ?) > 0
                        """, arguments: [companyId, RefSnapshot.diffCache, "..\(head)"])
                }
            }
            return found
        }
        // C2b-carry fix round 1 (F1): the owner's vouches for files by this name (the ref's canonical form, pinned or not),
        // whose flattened copies (`flattened/<row id>.pdf`, Ruling 42) are derived from its bytes.
        let names = Array(Set([canonical, ref.canonical].map(Self.canonicalHash))).sorted()
        var vouches = try writer.read { db in
            try FileVouch.fetchAll(db, sql: "SELECT * FROM fileVouch WHERE companyId = ? AND canonicalHash IN (\(names.map { _ in "?" }.joined(separator: ", ")))",
                                   arguments: StatementArguments([companyId]) + StatementArguments(names))
        }
        var resource: Resource?
        var memoryNumber: Int?
        switch ref.kind {
        case .resource:
            guard let n = Int(ref.id), let r = try self.resource(companyId: companyId, number: n), r.removedAt == nil else {
                throw WorkError.notFound(Self.refUnavailable)
            }
            resource = r
        case .memory:
            guard let n = Int(ref.id), try writer.read({ db in
                try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM memoryEntry WHERE companyId = ? AND number = ?)", arguments: [companyId, n])
            }) == true else { throw WorkError.notFound(Self.refUnavailable) }
            memoryNumber = n
        case .file, .diff, .commit:
            guard !rows.isEmpty || !shares.isEmpty || !snapshots.isEmpty || !vouches.isEmpty else { throw WorkError.notFound(Self.refUnavailable) }
        default:
            throw WorkError.invalid("items, asks, kb pages, messages and the like are live records, not shared content: there are no "
                                    + "stored bytes to purge. Purge the file or resource they carry, or edit the record itself")
        }
        // A resource's bytes vouched under any name (by their hash) are its too.
        if let sha = resource?.sha256 {
            let known = Set(vouches.map(\.id))
            vouches += try writer.read { db in
                try FileVouch.fetchAll(db, sql: "SELECT * FROM fileVouch WHERE companyId = ? AND sha256 = ?", arguments: [companyId, sha])
            }.filter { !known.contains($0.id) }
        }
        let stillInHistory = (ref.kind == .file && !blobPin) || ref.kind == .commit || (ref.kind == .diff && !ref.isWorktree)

        // Git is never pruned under a running turn: refuse before anything changes (and again inside the fence, below).
        func refuseWhileRunning() throws {
            let running = try writer.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM turn WHERE companyId = ? AND endedAt IS NULL", arguments: [companyId]) ?? 0
            }
            guard running == 0 else { throw WorkError.conflict("a turn is running in this company; purge \(shown) when it ends") }
        }
        if !shares.isEmpty {
            try refuseWhileRunning()
            try refHooks.afterPurgeTurnCheck?()
        }

        // What may still hold it: backups taken since it was first shared (all of them when that is unknown), and the
        // captured turns that read it through Brahma (`refRead`).
        let backups = BackupService(paths: paths).list().map { (name: $0.name, takenAt: $0.date) }
            + HomeSnapshot.list(paths: paths).map { (name: $0.name, takenAt: $0.date) }
        let since = (rows.map(\.createdAt) + snapshots.map(\.createdAt) + [resource?.createdAt].compactMap { $0 }).min()
        var report = RefPurgeReport(stillInHistory: stillInHistory)
        var problems: [String] = []
        var incomplete = false

        // Steps 2 and 3, inside the fence when git is pruned.
        let shareIds = shares.keys.sorted()
        func removeEverything() throws {
            // 2. The bytes.
            if let resource {
                report.vaultPaths = try writer.read { db in
                    try String.fetchAll(db, sql: """
                        SELECT vaultPath FROM resource WHERE companyId = ? AND (id = ? OR parentId = ?) AND vaultPath IS NOT NULL AND purgedAt IS NULL
                        ORDER BY number
                        """, arguments: [companyId, resource.id, resource.id])
                }
                let ml = try purgeResource(companyId: companyId, number: resource.number, backups: backups, contentVault: contentVault,
                                           paths: paths, now: now)
                report.backupsFlagged = ml.backups
                report.transcripts = ml.transcripts
                report.exportedCopies = ml.exports      // listed, with their notices, by ML's purge
            }
            if let memoryNumber { try ownerDeleteMemory(companyId: companyId, number: memoryNumber, now: now) }
            for snapshot in snapshots where snapshot.purgedAt == nil {
                try writer.write { db in
                    try db.execute(sql: "UPDATE refSnapshot SET purgedAt = ? WHERE companyId = ? AND id = ?", arguments: [now, companyId, snapshot.id])
                }
                do { try vault.remove(snapshot.vaultPath) } catch { problems.append("its vault copy \(snapshot.vaultPath) would not go (\(error))") }
                report.vaultPaths.append(snapshot.vaultPath)
            }
            // C2b-carry fix round 1 (F1): the flattened copies. The database first: each vouch is withdrawn and its copy's
            // hash cleared, so no copy is ever served or reused again (a later vouch makes a fresh one); then the files,
            // which a purge run again (the rows are found by name again) removes if any is left.
            if !vouches.isEmpty {
                try writer.write { db in
                    for v in vouches {
                        try db.execute(sql: """
                            UPDATE fileVouch SET copySha256 = NULL, vouchedAt = NULL, vouchedBy = NULL WHERE companyId = ? AND id = ?
                            """, arguments: [companyId, v.id])
                    }
                }
                for v in vouches {
                    let path = "\(VaultArea.flattened.rawValue)/\(v.id).pdf"
                    do { try vault.remove(path) } catch { problems.append("its flattened copy \(path) would not go (\(error))") }
                    if v.copySha256 != nil { report.vaultPaths.append(path) }
                }
            }

            // 3. Git: the share refs, then the objects the engine wrote for blob pins.
            var blobs: [String] = []
            if blobPin {
                for id in shareIds {
                    if let pinnedObject = shares[id], let oid = pinnedObject, oid.utf8.count == 40 || oid.utf8.count == 64 { blobs.append(oid) }
                }
            }
            if !shareIds.isEmpty {
                do {
                    try GitLock.withLock(paths: paths, companyId: companyId) {
                        for id in shareIds {
                            try git.deleteShareRef(id)
                            report.gitRefs.append(SafeGit.sharesPrefix + id)
                        }
                        try git.expireAndPrune(purged: Array(Set(blobs)).sorted())
                    }
                } catch SafeGitError.purgeIncomplete(let remaining) {
                    incomplete = true
                    problems.append("\(remaining) object(s) are still in the repository (another share, a branch, an index or a worktree still holds them)")
                } catch {
                    problems.append("git: \(error)")
                }
            }
        }
        if shareIds.isEmpty {
            try removeEverything()
        } else {
            do {
                try PurgeFence.withExclusive(home: dataHome ?? refHooks.fenceHome ?? paths.home, companyId: companyId,
                                             wait: refHooks.fenceWait ?? PurgeFence.defaultWait) {
                    try refuseWhileRunning()
                    try removeEverything()
                }
            } catch let e as PurgeFenceError {
                throw WorkError.conflict("the purge of \(shown) could not start: \(e)")
            }
        }

        // 4. The record.
        let extraBackups = backups.filter { b in since.map { b.takenAt >= $0 } ?? true }.filter { $0.takenAt <= now }
            .sorted { ($0.takenAt, $0.name) < ($1.takenAt, $1.name) }
        for b in extraBackups where !report.backupsFlagged.contains(b.name) { report.backupsFlagged.append(b.name) }
        let read = try writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT DISTINCT turnId FROM refRead WHERE companyId = ? AND canonical = ? AND turnId IS NOT NULL AND readerKind = 'agent'
                ORDER BY turnId
                """, arguments: [companyId, canonical])
        }
        for t in read where !report.transcripts.contains(t) { report.transcripts.append(t) }
        // C5 fix round 1: every copy the owner exported, by the path it was saved at (a resource's: by `purgeResource`).
        if resource == nil { report.exportedCopies = try writer.read { db in
            try String.fetchAll(db, sql: """
                SELECT exportPath FROM refRead WHERE companyId = ? AND canonical IN (?, ?) AND via = 'export' AND exportPath IS NOT NULL
                GROUP BY exportPath ORDER BY MIN(createdAt), exportPath
                """, arguments: [companyId, canonical, ref.canonical])
        } }
        let dates = Dictionary(backups.map { ($0.name, $0.takenAt) }, uniquingKeysWith: { a, _ in a })
        let day = DateFormatter()
        day.locale = Locale(identifier: "en_US_POSIX")
        day.timeZone = ownerTimeZone()
        day.dateFormat = "yyyy-MM-dd"
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        func json(_ list: [String]) throws -> String { String(decoding: try encoder.encode(list), as: UTF8.self) }
        try writer.write { db in
            var sql = "UPDATE messageRef SET state = 'purged' WHERE companyId = ? AND (canonical = ?"
            var args: StatementArguments = [companyId, canonical]
            if !shareIds.isEmpty {
                sql += " OR id IN (\(shareIds.map { _ in "?" }.joined(separator: ", ")))"
                args += StatementArguments(shareIds)
            }
            try db.execute(sql: sql + ")", arguments: args)
            // The log keeps the name as every message shows it: stored values and secret patterns redacted (fix round 2).
            try PurgeLog(companyId: companyId, canonical: shown, vaultPaths: try json(report.vaultPaths), gitRefs: try json(report.gitRefs),
                         backupsFlagged: try json(report.backupsFlagged), createdAt: now).insert(db)
            let holders = "\(report.backupsFlagged.count) backups and \(report.transcripts.count) transcripts may still contain it"
                + (report.exportedCopies.isEmpty ? "" : "; \(report.exportedCopies.count) copies you exported are outside Brahma")
                + (stillInHistory ? "; it is still in the company's git history" : "")
            try ActivityEvent(companyId: companyId, agentId: nil, turnId: nil, kind: .access,
                              text: try redact("Purged \(shown) (\(holders))"), createdAt: now).insert(db)
            for name in report.backupsFlagged {
                let when = dates[name].map { day.string(from: $0) } ?? name
                try notifyOwner(db: db, companyId: companyId, kind: .system, urgency: .normal, title: "Purged content in a backup",
                                body: "backup \(when) contains purged content · delete or re-create", now: now)
            }
            for turn in report.transcripts {
                try notifyOwner(db: db, companyId: companyId, kind: .system, urgency: .normal, title: "Purged content in a transcript",
                                body: "the transcript of turn \(turn) may contain purged content · delete it", now: now)
            }
            for path in report.exportedCopies where resource == nil {
                try notifyOwner(db: db, companyId: companyId, kind: .system, urgency: .normal, title: Self.exportedCopiesTitle,
                                body: Self.exportedCopyBody(shown, path: path), now: now)
            }
            if stillInHistory {
                try notifyOwner(db: db, companyId: companyId, kind: .system, urgency: .normal, title: "Purged content is still in git",
                                body: "\(shown) is still in the company's git history; its shares were removed, but rewriting history is up to you",
                                now: now)
            }
        }
        guard problems.isEmpty else {
            let text = "The purge of \(shown) is incomplete: \(problems.joined(separator: "; ")). "
                + (incomplete ? "Remove what still holds it, then purge it again." : "Purge it again.")
            do {
                try EngineAlerts.raise(store: self, text: text, now: now, reason: "purge-incomplete:\(StableHash.fnv1a64(companyId + "\u{0}" + canonical))",
                                       companyId: companyId)
            } catch {
                FileHandle.standardError.write(Data("brahma: \(text) (the alert failed too: \(error))\n".utf8))
            }
            throw WorkError.conflict(text)
        }
        return report
    }
}

extension Store {
    /// C5 fix round 1: the title of the owner notice for each exported copy of purged content.
    public static let exportedCopiesTitle = "Copies outside Brahma you may want to delete"

    /// The body of that notice: the ref as messages show it and the path the owner saved it at.
    static func exportedCopyBody(_ shown: String, path: String) -> String {
        "you exported \(shown) to \(Store.flat(path, max: 1000)) · Brahma can't delete it; delete it if you no longer need it"
    }

    /// The message of an item check or extension trial refused while the owner's purge holds the fence (R4-6).
    static let purgingRefusal = "the owner is purging content in this company"

    /// C2b fix round 4 (R4-6, ruling 35): the company's purge fence held shared for work that reads its repository outside
    /// a recorded turn (an item check, an extension trial turn: `kind`), waiting up to `PurgeFence.defaultWait` (tests: the
    /// hook's wait) while a purge holds it or (round 5) waits for it; nil when the store has no data home (no fence, as for
    /// turns). Throws `WorkError.conflict(purgingRefusal …)` past the wait.
    func holdPurgeFence(companyId: String, kind: PurgeFence.HolderKind) throws -> PurgeFence.Hold? {
        guard let home = dataHome ?? refHooks.fenceHome else { return nil }
        guard let hold = try PurgeFence.holdShared(home: home, companyId: companyId, wait: refHooks.fenceWait ?? PurgeFence.defaultWait,
                                                   kind: kind) else {
            throw WorkError.conflict("\(Self.purgingRefusal); try again in a moment")
        }
        return hold
    }
}

public enum PurgeFenceError: Error, Equatable, CustomStringConvertible {
    /// The fence stayed taken for the whole wait; `holders` says by what (round 5, R5-4).
    case timeout(holders: [PurgeFence.HolderKind])
    /// The company id is not one safe path component, or the fence file could not be opened.
    case unavailable(String)

    public var description: String {
        switch self {
        case .timeout(let holders) where holders.isEmpty: "something still holds this company's purge fence; try again"
        case .timeout(let holders): "\(holders.map(\.phrase).joined(separator: " and ")) in this company; try again when it ends"
        case .unavailable(let why): "the company's purge fence is unavailable: \(why)"
        }
    }
}

/// One company's purge fence (C2b fix round 1): an `flock` on `<home>/run/purge-<companyId>.lock`. A purge holds it
/// exclusively while it checks that no turn runs and prunes git; every turn start holds it shared while it records the
/// turn (`Store.beginTurn`, `Store.startTurn`), so a turn either is recorded before the purge's check (which then refuses)
/// or starts after the purge. Round 4 (R4-6): an item check and an extension trial turn, which no turn row records, hold it
/// shared for their whole run (`holdShared`). It lives under the data home, never in a workspace, so no agent can hold it.
///
/// Round 5 (R5-4): a purge, once waiting, goes ahead of new holders (writer preference), so overlapping checks can't starve
/// it: a turnstile (`purge-<companyId>.gate`) that a purge holds exclusively while it waits for the fence, and that every
/// shared holder passes (held shared only until it has the fence). Each holder registers what it is (`HolderKind`) under
/// `purge-<companyId>.holders/` while it holds the fence, so a purge that times out says what held it.
public enum PurgeFence {
    public static let defaultWait = Duration.seconds(30)
    static let pollInterval: TimeInterval = 0.02

    /// What holds (or waits for) the fence.
    public enum HolderKind: String, Sendable, CaseIterable {
        case turn, check, trial, purge

        /// How a purge's refusal names it.
        public var phrase: String {
            switch self {
            case .turn: "a turn is starting"
            case .check: "an item check is running"
            case .trial: "an extension trial is running"
            case .purge: "another purge is running"
            }
        }
    }

    public static func lockURL(home: URL, companyId: String) throws -> URL {
        guard companyId.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil else {
            throw PurgeFenceError.unavailable("invalid company id")
        }
        return home.appending(path: "run", directoryHint: .isDirectory).appending(path: "purge-\(companyId).lock", directoryHint: .notDirectory)
    }

    /// The turnstile a waiting purge holds exclusively (R5-4).
    static func gateURL(home: URL, companyId: String) throws -> URL {
        try lockURL(home: home, companyId: companyId).deletingLastPathComponent().appending(path: "purge-\(companyId).gate", directoryHint: .notDirectory)
    }

    /// Where holders register what they are (R5-4).
    static func holdersURL(home: URL, companyId: String) throws -> URL {
        try lockURL(home: home, companyId: companyId).deletingLastPathComponent().appending(path: "purge-\(companyId).holders", directoryHint: .isDirectory)
    }

    /// `body` with the fence held exclusively (a purge), waiting up to `wait`; `PurgeFenceError.timeout` (naming what held
    /// it) past it. While it waits, no new holder gets the fence.
    public static func withExclusive<T>(home: URL, companyId: String, wait: Duration = defaultWait, kind: HolderKind = .purge,
                                        _ body: () throws -> T) throws -> T {
        let deadline = AwakeTime.uptime() + seconds(wait)
        let gate = try openLockFile(try gateURL(home: home, companyId: companyId))
        defer { close(gate) }
        // The gate first: from here on, new shared holders wait behind this purge.
        let mine = try register(kind, home: home, companyId: companyId)
        defer { unregister(mine) }
        guard try lock(gate, LOCK_EX, until: deadline) else {
            throw PurgeFenceError.timeout(holders: try holders(home: home, companyId: companyId, except: mine))
        }
        defer { flock(gate, LOCK_UN) }
        let fence = try openLockFile(try lockURL(home: home, companyId: companyId))
        defer { close(fence) }
        guard try lock(fence, LOCK_EX, until: deadline) else {
            throw PurgeFenceError.timeout(holders: try holders(home: home, companyId: companyId, except: mine))
        }
        defer { flock(fence, LOCK_UN) }
        return try body()
    }

    /// `body` with the fence held shared (a turn start), waiting up to `wait` (zero: not at all); nil, without running
    /// `body`, while a purge holds it or waits for it.
    public static func withShared<T>(home: URL, companyId: String, wait: Duration, kind: HolderKind = .turn,
                                     _ body: () throws -> T) throws -> T? {
        guard let hold = try holdShared(home: home, companyId: companyId, wait: wait, kind: kind) else { return nil }
        defer { hold.release() }
        return try body()
    }

    /// C2b fix round 4 (R4-6, ruling 35): the fence held shared until `release` (or the hold's end), for work that reads the
    /// company's repository outside a recorded turn and lasts across suspension points (an item check, an extension trial
    /// turn). Waits up to `wait`; nil while a purge holds it or (round 5) waits for it.
    public static func holdShared(home: URL, companyId: String, wait: Duration, kind: HolderKind = .check) throws -> Hold? {
        let deadline = AwakeTime.uptime() + seconds(wait)
        let gate = try openLockFile(try gateURL(home: home, companyId: companyId))
        defer { close(gate) }
        guard try lock(gate, LOCK_SH, until: deadline) else { return nil }
        defer { flock(gate, LOCK_UN) }
        let fence = try openLockFile(try lockURL(home: home, companyId: companyId))
        guard try lock(fence, LOCK_SH, until: deadline) else { close(fence); return nil }
        let registration: URL
        do { registration = try register(kind, home: home, companyId: companyId) } catch {
            flock(fence, LOCK_UN)
            close(fence)
            throw error
        }
        return Hold(fd: fence, registration: registration)
    }

    /// A shared hold of the fence: released once (`release`, or when it is freed).
    public final class Hold: @unchecked Sendable {
        private let lock = NSLock()
        private var fd: Int32?
        private let registration: URL?
        init(fd: Int32, registration: URL? = nil) { self.fd = fd; self.registration = registration }
        public func release() {
            lock.withLock {
                guard let fd else { return }
                if let registration { PurgeFence.unregister(registration) }
                flock(fd, LOCK_UN)
                close(fd)
                self.fd = nil
            }
        }
        deinit { release() }
    }

    static func seconds(_ wait: Duration) -> TimeInterval {
        Double(wait.components.seconds) + Double(wait.components.attoseconds) / 1e18
    }

    /// A lock file under `<home>/run`, created if missing: close-on-exec and no link followed, as `GitLock`.
    private static func openLockFile(_ url: URL) throws -> Int32 {
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw PurgeFenceError.unavailable("\(error)") }
        let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PurgeFenceError.unavailable("cannot open the fence file") }
        return fd
    }

    /// `operation` on `fd`, polling until `deadline`; false past it.
    private static func lock(_ fd: Int32, _ operation: Int32, until deadline: TimeInterval) throws -> Bool {
        while flock(fd, operation | LOCK_NB) != 0 {
            if errno != EWOULDBLOCK && errno != EINTR { throw PurgeFenceError.unavailable("cannot take the fence") }
            guard AwakeTime.uptime() < deadline else { return false }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        return true
    }

    /// Registers this process as a `kind` holder: an empty file `<kind>.<pid>.<uuid>` under the holders directory.
    static func register(_ kind: HolderKind, home: URL, companyId: String) throws -> URL {
        let dir = try holdersURL(home: home, companyId: companyId)
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch { throw PurgeFenceError.unavailable("\(error)") }
        let url = dir.appending(path: "\(kind.rawValue).\(getpid()).\(UUID().uuidString)", directoryHint: .notDirectory)
        let fd = open(url.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PurgeFenceError.unavailable("cannot register a fence holder") }
        close(fd)
        return url
    }

    static func unregister(_ url: URL) { unlink(url.path) }

    /// What holds or waits for the fence now (registrations of live processes only, `except` this one's), in a fixed order.
    static func holders(home: URL, companyId: String, except: URL) throws -> [HolderKind] {
        let dir = try holdersURL(home: home, companyId: companyId)
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        var kinds = Set<HolderKind>()
        for name in names where name != except.lastPathComponent {
            let parts = name.split(separator: ".")
            guard parts.count == 3, let kind = HolderKind(rawValue: String(parts[0])), let pid = Int32(parts[1]) else { continue }
            if kill(pid, 0) == 0 || errno == EPERM { kinds.insert(kind) }
        }
        return HolderKind.allCases.filter(kinds.contains)
    }
}
