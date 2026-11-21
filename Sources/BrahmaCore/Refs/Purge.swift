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

    public init(vaultPaths: [String] = [], gitRefs: [String] = [], backupsFlagged: [String] = [], transcripts: [String] = [],
                stillInHistory: Bool = false) {
        self.vaultPaths = vaultPaths; self.gitRefs = gitRefs; self.backupsFlagged = backupsFlagged; self.transcripts = transcripts
        self.stillInHistory = stillInHistory
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
    ///    cache of a committed diff through `Vault` (their rows get `purgedAt`);
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
            guard !rows.isEmpty || !shares.isEmpty || !snapshots.isEmpty else { throw WorkError.notFound(Self.refUnavailable) }
        default:
            throw WorkError.invalid("items, asks, kb pages, messages and the like are live records, not shared content: there are no "
                                    + "stored bytes to purge. Purge the file or resource they carry, or edit the record itself")
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
            }
            if let memoryNumber { try ownerDeleteMemory(companyId: companyId, number: memoryNumber, now: now) }
            for snapshot in snapshots where snapshot.purgedAt == nil {
                try writer.write { db in
                    try db.execute(sql: "UPDATE refSnapshot SET purgedAt = ? WHERE companyId = ? AND id = ?", arguments: [now, companyId, snapshot.id])
                }
                do { try vault.remove(snapshot.vaultPath) } catch { problems.append("its vault copy \(snapshot.vaultPath) would not go (\(error))") }
                report.vaultPaths.append(snapshot.vaultPath)
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
                try PurgeFence.withExclusive(home: dataHome ?? refHooks.fenceHome ?? paths.home, companyId: companyId) {
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
            try PurgeLog(companyId: companyId, canonical: canonical, vaultPaths: try json(report.vaultPaths), gitRefs: try json(report.gitRefs),
                         backupsFlagged: try json(report.backupsFlagged), createdAt: now).insert(db)
            let holders = "\(report.backupsFlagged.count) backups and \(report.transcripts.count) transcripts may still contain it"
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

public enum PurgeFenceError: Error, Equatable, CustomStringConvertible {
    /// The fence stayed taken for the whole wait.
    case timeout
    /// The company id is not one safe path component, or the fence file could not be opened.
    case unavailable(String)

    public var description: String {
        switch self {
        case .timeout: "a turn is starting in this company or another purge is running; try again"
        case .unavailable(let why): "the company's purge fence is unavailable: \(why)"
        }
    }
}

/// One company's purge fence (C2b fix round 1): an `flock` on `<home>/run/purge-<companyId>.lock`. A purge holds it
/// exclusively while it checks that no turn runs and prunes git; every turn start holds it shared while it records the
/// turn (`Store.beginTurn`, `Store.startTurn`), so a turn either is recorded before the purge's check (which then refuses)
/// or starts after the purge. It lives under the data home, never in a workspace, so no agent can hold it.
public enum PurgeFence {
    public static let defaultWait = Duration.seconds(30)
    static let pollInterval: TimeInterval = 0.02

    public static func lockURL(home: URL, companyId: String) throws -> URL {
        guard companyId.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil else {
            throw PurgeFenceError.unavailable("invalid company id")
        }
        return home.appending(path: "run", directoryHint: .isDirectory).appending(path: "purge-\(companyId).lock", directoryHint: .notDirectory)
    }

    /// `body` with the fence held exclusively (a purge), waiting up to `wait`; `PurgeFenceError.timeout` past it.
    public static func withExclusive<T>(home: URL, companyId: String, wait: Duration = defaultWait, _ body: () throws -> T) throws -> T {
        guard let value = try with(LOCK_EX, home: home, companyId: companyId, wait: wait, body) else { throw PurgeFenceError.timeout }
        return value
    }

    /// `body` with the fence held shared (a turn start), waiting up to `wait` (zero: not at all); nil, without running
    /// `body`, while a purge holds it.
    public static func withShared<T>(home: URL, companyId: String, wait: Duration, _ body: () throws -> T) throws -> T? {
        try with(LOCK_SH, home: home, companyId: companyId, wait: wait, body)
    }

    private static func with<T>(_ operation: Int32, home: URL, companyId: String, wait: Duration, _ body: () throws -> T) throws -> T? {
        let url = try lockURL(home: home, companyId: companyId)
        do {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true,
                                                    attributes: [.posixPermissions: 0o700])
        } catch { throw PurgeFenceError.unavailable("\(error)") }
        // Close-on-exec and no link followed, as `GitLock`.
        let fd = open(url.path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw PurgeFenceError.unavailable("cannot open the fence file") }
        defer { close(fd) }
        let seconds = Double(wait.components.seconds) + Double(wait.components.attoseconds) / 1e18
        let deadline = AwakeTime.uptime() + seconds
        while flock(fd, operation | LOCK_NB) != 0 {
            if errno != EWOULDBLOCK && errno != EINTR { throw PurgeFenceError.unavailable("cannot take the fence") }
            guard AwakeTime.uptime() < deadline else { return nil }
            Thread.sleep(forTimeInterval: pollInterval)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }
}
