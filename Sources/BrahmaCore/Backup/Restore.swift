import Foundation
import GRDB

public enum RestoreError: Error, Equatable, CustomStringConvertible, LocalizedError {
    /// The `OrchestratorLock` is held: the app or `brahma run` is running.
    case engineRunning
    /// Another process has the database (or its `-wal`/`-shm`) open.
    case dbOpenElsewhere([Int32])
    case corrupt
    /// The snapshot was written by a newer Brahma than this one.
    case newerSchema
    case notFound
    /// No tool to list who has the database open (`lsof` on macOS, `/proc` on Linux).
    case cannotCheckOpeners
    case failed(String)

    public var description: String {
        switch self {
        case .engineRunning: "Brahma is running (the app or 'brahma run'); quit it first"
        case .dbOpenElsewhere(let pids): "another process has the database open (pid \(pids.map(String.init).joined(separator: ", "))); close it first"
        case .corrupt: "that snapshot failed its integrity check"
        case .newerSchema: "that snapshot was written by a newer Brahma; update Brahma first"
        case .notFound: "no such snapshot"
        case .cannotCheckOpeners: "cannot tell whether another process has the database open (lsof is unavailable)"
        case .failed(let text): text
        }
    }
    public var errorDescription: String? { description }
}

/// Who has the database open, other than this process.
public enum DBOpeners {
    public static func pids(of db: URL) throws -> [Int32] {
        let files = [db.path, db.path + "-wal", db.path + "-shm"].filter { FileManager.default.fileExists(atPath: $0) }
        guard !files.isEmpty else { return [] }
        let me = getpid()
        #if os(Linux)
        var found = Set<Int32>()
        guard let procs = try? FileManager.default.contentsOfDirectory(atPath: "/proc") else { throw RestoreError.cannotCheckOpeners }
        let wanted = Set(files.map { URL(fileURLWithPath: $0).resolvingSymlinksInPath().path })
        for entry in procs {
            guard let pid = Int32(entry), pid != me,
                  let fds = try? FileManager.default.contentsOfDirectory(atPath: "/proc/\(entry)/fd") else { continue }
            for fd in fds {
                if let target = try? FileManager.default.destinationOfSymbolicLink(atPath: "/proc/\(entry)/fd/\(fd)"), wanted.contains(target) {
                    found.insert(pid)
                    break
                }
            }
        }
        return found.sorted()
        #else
        let lsof = "/usr/sbin/lsof"
        guard FileManager.default.isExecutableFile(atPath: lsof) else { throw RestoreError.cannotCheckOpeners }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: lsof)
        process.arguments = ["-t"] + files
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { throw RestoreError.cannotCheckOpeners }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        // 0: something found; 1: nothing open. Anything else means lsof itself failed.
        guard process.terminationStatus == 0 || process.terminationStatus == 1 else { throw RestoreError.cannotCheckOpeners }
        let pids = String(decoding: data, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { Int32($0) }
        return Array(Set(pids.filter { $0 != me })).sorted()
        #endif
    }
}

public struct RepoAhead: Equatable, Sendable {
    public let company: String
    public let commitsAfterSnapshot: Int
    public var warning: String { "\(company): repo has \(commitsAfterSnapshot) commits after the snapshot; they are kept and re-adopted" }
}

public struct RestorePlan: Equatable, Sendable {
    public let snapshot: URL
    public let snapshotDate: Date?
    public let reposAhead: [RepoAhead]
    public var warnings: [String] { reposAhead.map(\.warning) }
}

public struct RestoreOutcome: Equatable, Sendable {
    /// The byte copy of the database as it was (`brahma.sqlite.pre-restore-<stamp>`).
    public let previousCopy: URL?
    /// The verified pre-restore snapshot, when the old database could still be snapshotted.
    public let preRestoreSnapshot: URL?
    public let warnings: [String]
}

extension BackupService {
    /// `<home>/run/restored-at`: written by a restore; the next Orchestrator tick that sees it re-adopts every repo.
    public static func restoreMarker(paths: BrahmaPaths) -> URL { paths.runDir.appending(path: "restored-at") }
    static func restoreMarker(home: URL) -> URL { home.appending(path: "run/restored-at") }

    private var lockPaths: BrahmaPaths { BrahmaPaths(home: home, workspaces: home) }

    // MARK: Validation and plan

    /// The checks every snapshot must pass: it exists, passes `integrity_check`, and is not from a newer schema.
    func validate(snapshot: URL) throws {
        guard FileManager.default.fileExists(atPath: snapshot.path) else { throw RestoreError.notFound }
        guard integrityCheck(snapshot) == ["ok"] else { throw RestoreError.corrupt }
        do {
            let queue = try Self.openForReading(snapshot)
            defer { try? queue.close() }
            if try queue.read({ db in try Migrations.migrator().hasBeenSuperseded(db) }) { throw RestoreError.newerSchema }
        } catch let error as RestoreError {
            throw error
        } catch {
            throw RestoreError.corrupt
        }
    }

    /// The newest snapshot that passes `validate`.
    public func latestGood() -> BackupInfo? {
        list().first { (try? validate(snapshot: $0.url)) != nil }
    }

    public func planRestore(snapshot: URL) throws -> RestorePlan {
        guard FileManager.default.fileExists(atPath: snapshot.path) else { throw RestoreError.notFound }
        do {
            // Nothing is held after this: the real check is `restore`, which holds the lock throughout.
            _ = try OrchestratorLock.acquire(paths: lockPaths)
        } catch OrchestratorLockError.alreadyRunning {
            throw RestoreError.engineRunning
        } catch {
            throw RestoreError.failed("cannot check the engine lock: \(error)")
        }
        let openers = try DBOpeners.pids(of: database)
        if !openers.isEmpty { throw RestoreError.dbOpenElsewhere(openers) }
        try validate(snapshot: snapshot)
        return RestorePlan(snapshot: snapshot, snapshotDate: Self.parse(name: snapshot.lastPathComponent)?.date,
                           reposAhead: reposAhead(of: snapshot))
    }

    /// Companies whose `main` has commits the snapshot's record of it does not: they survive a restore (git is not touched).
    private func reposAhead(of snapshot: URL) -> [RepoAhead] {
        guard let queue = try? Self.openForReading(snapshot) else { return [] }
        defer { try? queue.close() }
        let rows = (try? queue.read { db in
            try Row.fetchAll(db, sql: "SELECT name, workspacePath, mainCommit FROM company WHERE mainCommit IS NOT NULL ORDER BY createdAt, rowid")
        }) ?? []
        var ahead: [RepoAhead] = []
        for row in rows {
            let name: String = row["name"], path: String = row["workspacePath"], recorded: String = row["mainCommit"]
            guard FileManager.default.fileExists(atPath: path + "/.git") else { continue }
            let git = GitWorkspace(root: URL(fileURLWithPath: path, isDirectory: true))
            if let n = try? git.commitCount(from: recorded, to: GitWorkspace.mainRef), n > 0 {
                ahead.append(RepoAhead(company: name, commitsAfterSnapshot: n))
            }
        }
        return ahead
    }

    // MARK: Restore

    /// Replaces the live database with the snapshot, holding the `OrchestratorLock` throughout.
    ///
    /// 1. checkpoint (`TRUNCATE`) the live database and snapshot it (`.preRestore`), then close it;
    /// 2. keep a byte copy as `brahma.sqlite.pre-restore-<stamp>`;
    /// 3. copy the snapshot to `brahma.sqlite.restoring` and fsync it;
    /// 4. `rename(2)` it over `brahma.sqlite`: there is never a moment without a database;
    /// 5. remove the stale `-wal` and `-shm`;
    /// 6. rebuild every FTS index (`VACUUM` may have renumbered the implicit rowids the external-content indexes point at) and
    ///    run their integrity check;
    /// 7. write the restore marker.
    @discardableResult
    public func restore(_ plan: RestorePlan) throws -> RestoreOutcome {
        let lock: OrchestratorLock
        do { lock = try OrchestratorLock.acquire(paths: lockPaths) } catch OrchestratorLockError.alreadyRunning {
            throw RestoreError.engineRunning
        } catch { throw RestoreError.failed("cannot take the engine lock: \(error)") }
        defer { withExtendedLifetime(lock) {} }
        let fm = FileManager.default
        func openersCheck() throws {
            let openers = try DBOpeners.pids(of: database)
            if !openers.isEmpty { throw RestoreError.dbOpenElsewhere(openers) }
        }
        try openersCheck()
        try validate(snapshot: plan.snapshot)
        var warnings: [String] = []
        var preSnapshot: URL?
        let stamp = Self.stamp(now())
        let sibling = database.deletingLastPathComponent()
        let previous = sibling.appending(path: database.lastPathComponent + ".pre-restore-\(stamp)")
        let hadDatabase = fm.fileExists(atPath: database.path)

        // 1.
        if hadDatabase {
            do {
                let live = try DatabaseQueue(path: database.path)
                try? live.writeWithoutTransaction { db in try db.execute(sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
                var service = self
                service.writer = live
                do { preSnapshot = try service.snapshot(reason: .preRestore) } catch {
                    warnings.append("could not take a verified snapshot of the current database (\(error)); the byte copy below is kept")
                }
                try live.close()
            } catch {
                warnings.append("the current database could not be opened (\(error)); the byte copy below is kept")
            }
            // 2.
            do {
                try fm.copyItem(at: database, to: previous)
                chmod(previous.path, 0o600)
            } catch { throw RestoreError.failed("could not keep a copy of the current database: \(error)") }
            pruneByteCopies()
        }

        // 3.
        let staging = sibling.appending(path: database.lastPathComponent + ".restoring")
        try? fm.removeItem(at: staging)
        do {
            try fm.copyItem(at: plan.snapshot, to: staging)
            chmod(staging.path, 0o600)
            try Self.syncFile(staging)
        } catch { throw RestoreError.failed("could not stage the snapshot: \(error)") }

        // 4. and 5. The old log is empty after the checkpoint; removing it first means the renamed file never meets a stale one.
        try openersCheck()
        for suffix in ["-wal", "-shm"] { try? fm.removeItem(atPath: database.path + suffix) }
        guard rename(staging.path, database.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: staging)
            throw RestoreError.failed("could not put the snapshot in place (errno \(code))")
        }
        for suffix in ["-wal", "-shm"] { try? fm.removeItem(atPath: database.path + suffix) }
        Self.syncDirectory(sibling)

        // 6.
        do {
            let queue = try DatabaseQueue(path: database.path)
            defer { try? queue.close() }
            try queue.writeWithoutTransaction { db in try Self.rebuildSearchIndexes(db, check: true) }
        } catch {
            throw RestoreError.failed("restored, but the search index could not be rebuilt: \(error)")
        }

        // 7.
        let marker = Self.restoreMarker(home: home)
        try BrahmaPaths.ensurePrivateDirectory(marker.deletingLastPathComponent())
        let when = plan.snapshotDate.map { ISO8601DateFormatter().string(from: $0) } ?? ""
        try Data("\(plan.snapshot.lastPathComponent)\n\(when)\n".utf8).write(to: marker, options: .atomic)
        chmod(marker.path, 0o600)
        return RestoreOutcome(previousCopy: hadDatabase ? previous : nil, preRestoreSnapshot: preSnapshot, warnings: warnings)
    }

    private func pruneByteCopies() {
        let prefix = database.lastPathComponent + ".pre-restore-"
        let dir = database.deletingLastPathComponent()
        let copies = ((try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []).filter { $0.hasPrefix(prefix) }.sorted()
        for old in copies.dropLast(Self.keep[.preRestore] ?? 5) { try? FileManager.default.removeItem(at: dir.appending(path: old)) }
    }

    static func syncDirectory(_ url: URL) {
        let fd = open(url.path, O_RDONLY)
        guard fd >= 0 else { return }
        fsync(fd)
        close(fd)
    }

    /// Rebuilds every FTS5 table from its content, then (with `check`) runs FTS5's own integrity check on each.
    /// `VACUUM` and `VACUUM INTO` may renumber the implicit rowids of tables with a TEXT primary key (`message`), which would
    /// desynchronize a `content_rowid='rowid'` index.
    static func rebuildSearchIndexes(_ db: Database, check: Bool) throws {
        let names = try String.fetchAll(db, sql: """
            SELECT name FROM sqlite_master WHERE type = 'table' AND lower(sql) LIKE 'create virtual table%using fts5%'
            """)
        for name in names {
            let quoted = "\"" + name.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            try db.execute(sql: "INSERT INTO \(quoted)(\(quoted)) VALUES('rebuild')")
            if check { try db.execute(sql: "INSERT INTO \(quoted)(\(quoted)) VALUES('integrity-check')") }
        }
    }
}
