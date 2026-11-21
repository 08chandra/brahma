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
    /// Awake seconds `lsof` may take before it is killed and the check reported impossible (`cannotCheckOpeners`).
    public static let lsofTimeout: TimeInterval = 20
    /// Seconds between SIGTERM and SIGKILL of a timed-out `lsof`.
    static let killGrace: TimeInterval = 1
    /// Awake seconds to wait for `lsof` to be gone after SIGKILL. A process that survives it (stuck in the kernel) is abandoned
    /// and the check reported impossible, so a restore never waits on it.
    static let killWait: TimeInterval = 2

    /// The processes other than this one that have the database (or its `-wal`/`-shm`) open.
    public static func pids(of db: URL) throws -> [Int32] {
        try pids(of: db, lsof: "/usr/sbin/lsof", timeout: lsofTimeout)
    }

    /// `lsof`, `timeout` and `killWait` are test seams (macOS only).
    static func pids(of db: URL, lsof: String, timeout: TimeInterval, killWait: TimeInterval = DBOpeners.killWait) throws -> [Int32] {
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
        guard FileManager.default.isExecutableFile(atPath: lsof) else { throw RestoreError.cannotCheckOpeners }
        // Bounded in awake time (`GroupExec`): a hung lsof is SIGTERMed, then SIGKILLed with its group, and abandoned if it
        // is still there `killWait` later; its output is never waited on after a timeout.
        let r = GroupExec.run(executable: lsof, arguments: ["-t"] + files, environment: ProcessInfo.processInfo.environment,
                              output: .capture(cap: 1 << 20, stderr: false), timeout: timeout, killGrace: killGrace,
                              abandonAfter: killWait)
        guard r.launched, !r.timedOut else { throw RestoreError.cannotCheckOpeners }
        // 0: something found; 1: nothing open. Anything else means lsof itself failed.
        guard r.status == 0 || r.status == 1 else { throw RestoreError.cannotCheckOpeners }
        let pids = String(decoding: r.output, as: UTF8.self).split(whereSeparator: \.isNewline).compactMap { Int32($0) }
        return Array(Set(pids.filter { $0 != me })).sorted()
        #endif
    }
}

/// The restore marker `<home>/run/restored-at`. It holds only the nonce of a `restoreEvent` row; the marker by itself grants
/// nothing. It is honoured only when it is a regular file (never a link) in this user's private `run/` directory, owned by this
/// user, mode 0600, at most `maxBytes`, and its nonce names a restore event the database has not taken up yet.
public enum RestoreMarker {
    public static let maxBytes = 512

    public enum Reading: Equatable, Sendable {
        case absent
        /// A well-formed marker; its nonce still has to match an unconsumed `restoreEvent` row.
        case nonce(String)
        /// Not honoured. `removable`: unlinking it is safe (its directory is this user's own, and it is not a directory).
        /// `identity` tells one bad marker from the next, so each is logged once.
        case ignored(reason: String, removable: Bool, identity: String)
    }

    /// 256 bits from `SystemRandomNumberGenerator`, as 64 lowercase hex digits.
    static func makeNonce() -> String {
        var rng = SystemRandomNumberGenerator()
        return (0..<4).map { _ -> String in
            let hex = String(rng.next() as UInt64, radix: 16)
            return String(repeating: "0", count: 16 - hex.count) + hex
        }.joined()
    }

    static func isNonce(_ text: String) -> Bool {
        text.utf8.count == 64 && text.utf8.allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }

    /// Reads the marker without following a link (lstat, then `O_NOFOLLOW` and an fstat that must name the same file).
    public static func read(_ url: URL) -> Reading {
        var st = stat()
        guard lstat(url.path, &st) == 0 else {
            let code = errno
            return code == ENOENT ? .absent : .ignored(reason: "it cannot be examined (errno \(code))", removable: false, identity: "lstat:\(code)")
        }
        let identity = "\(st.st_dev):\(st.st_ino):\(st.st_size):\(st.st_mode)"
        let dir = url.deletingLastPathComponent().path
        var ds = stat()
        let dirStat: Bool = lstat(dir, &ds) == 0
        let dirIsDirectory: Bool = (ds.st_mode & S_IFMT) == S_IFDIR
        let dirIsMine: Bool = ds.st_uid == getuid()
        let dirIsPrivate: Bool = (ds.st_mode & mode_t(0o022)) == 0
        let dirSafe = dirStat && dirIsDirectory && dirIsMine && dirIsPrivate
        let type = st.st_mode & S_IFMT
        func ignored(_ reason: String) -> Reading {
            .ignored(reason: reason, removable: dirSafe && type != S_IFDIR, identity: identity + " " + reason)
        }
        guard dirSafe else { return ignored("its directory is not this user's private run directory") }
        if type == S_IFLNK { return ignored("it is a symbolic link") }
        guard type == S_IFREG else { return ignored("it is not a regular file") }
        guard st.st_uid == getuid() else { return ignored("it is owned by uid \(st.st_uid), not this user") }
        let permissions: mode_t = st.st_mode & mode_t(0o7777)
        guard permissions == mode_t(0o600) else { return ignored("its mode is \(String(permissions, radix: 8)), not 600") }
        guard st.st_size <= maxBytes else { return ignored("it is too large (\(st.st_size) bytes)") }
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return ignored("it cannot be opened without following a link (errno \(errno))") }
        defer { _ = closeMarkerFD(fd) }
        var fs = stat()
        guard fstat(fd, &fs) == 0 else { return ignored("it cannot be examined once open") }
        let same: Bool = fs.st_dev == st.st_dev && fs.st_ino == st.st_ino
        let stillRegular: Bool = (fs.st_mode & S_IFMT) == S_IFREG && fs.st_uid == getuid()
        let stillPrivate: Bool = (fs.st_mode & mode_t(0o7777)) == mode_t(0o600)
        guard same, stillRegular, stillPrivate else { return ignored("it changed while it was read") }
        guard let bytes = readMarkerFD(fd, limit: maxBytes + 1) else { return ignored("it cannot be read") }
        guard bytes.count <= maxBytes else { return ignored("it is too large") }
        let first = String(decoding: bytes, as: UTF8.self).split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        guard isNonce(first) else { return ignored("it holds no restore nonce") }
        return .nonce(first)
    }

    /// Writes `<nonce>\n` as a fresh 0600 file (`O_CREAT|O_EXCL|O_NOFOLLOW`), fsynced, then renamed over the marker.
    public static func write(nonce: String, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try BrahmaPaths.ensurePrivateDirectory(dir)
        let staging = dir.appending(path: ".\(url.lastPathComponent).\(makeNonce().prefix(16)).tmp")
        let fd = open(staging.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw RestoreError.failed("could not write the restore marker (errno \(errno))") }
        let ok = fchmod(fd, 0o600) == 0 && writeMarkerFD(fd, Array((nonce + "\n").utf8)) && fsync(fd) == 0
        let closed = closeMarkerFD(fd)
        guard ok, closed, rename(staging.path, url.path) == 0 else {
            let code = errno
            unlink(staging.path)
            throw RestoreError.failed("could not write the restore marker (errno \(code))")
        }
        BackupService.syncDirectory(dir)
    }
}

private func readMarkerFD(_ fd: Int32, limit: Int) -> [UInt8]? {
    var buffer = [UInt8](repeating: 0, count: limit)
    var total = 0
    while total < limit {
        let n = buffer.withUnsafeMutableBytes { raw in read(fd, raw.baseAddress! + total, limit - total) }
        if n < 0 { if errno == EINTR { continue }; return nil }
        if n == 0 { break }
        total += n
    }
    return Array(buffer[..<total])
}

private func writeMarkerFD(_ fd: Int32, _ bytes: [UInt8]) -> Bool {
    var done = 0
    while done < bytes.count {
        let n = bytes.withUnsafeBytes { raw in write(fd, raw.baseAddress! + done, bytes.count - done) }
        if n < 0 { if errno == EINTR { continue }; return false }
        done += n
    }
    return true
}

private func closeMarkerFD(_ fd: Int32) -> Bool { close(fd) == 0 }

public struct RepoAhead: Equatable, Sendable {
    public let company: String
    public let commitsAfterSnapshot: Int
    /// The commits stay in git, but a restore re-adopts only the snapshot's own record of `main` (Task 12 fix 1): the owner reviews
    /// and accepts the newer head (`brahma main accept`), as for any move of `main` outside Brahma.
    public var warning: String {
        "\(company): repo has \(commitsAfterSnapshot) commits after the snapshot; they are kept, but Brahma will not adopt them "
            + "until you review main and accept it (brahma main accept)"
    }
}

public struct RestorePlan: Equatable, Sendable {
    public let snapshot: URL
    public let snapshotDate: Date?
    public let reposAhead: [RepoAhead]
    /// The newest data-home snapshot at or before the database snapshot: what `restore(_:withFiles:)` puts the files back to.
    public let homeSnapshot: HomeSnapshotInfo?
    public var warnings: [String] { reposAhead.map(\.warning) }

    public init(snapshot: URL, snapshotDate: Date?, reposAhead: [RepoAhead], homeSnapshot: HomeSnapshotInfo? = nil) {
        self.snapshot = snapshot; self.snapshotDate = snapshotDate; self.reposAhead = reposAhead; self.homeSnapshot = homeSnapshot
    }
}

public struct RestoreOutcome: Equatable, Sendable {
    /// The byte copy of the database as it was (`brahma.sqlite.pre-restore-<stamp>`).
    public let previousCopy: URL?
    /// The verified pre-restore snapshot, when the old database could still be snapshotted.
    public let preRestoreSnapshot: URL?
    public let warnings: [String]
    /// With `withFiles`: the files put back from the data-home snapshot, and where the ones they replaced were kept.
    public var filesRestored: Int = 0
    public var filesPreRestore: URL?
    /// With `withFiles`: the data-home snapshot the files came from, and the entries it refused (`HomeRestoreResult.refused`).
    public var filesSnapshot: HomeSnapshotInfo?
    public var filesRefused: [String] = []
}

extension BackupService {
    /// `<home>/run/restored-at`: written by a restore with the nonce of its `restoreEvent` row (`RestoreMarker`); the next
    /// Orchestrator tick that sees it, and finds that row unconsumed, re-adopts each company's recorded `main`.
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

    /// `date`: when the snapshot's content is from, for a file whose name does not say (a Litestream point-in-time rebuild).
    public func planRestore(snapshot: URL) throws -> RestorePlan { try planRestore(snapshot: snapshot, date: nil) }

    public func planRestore(snapshot: URL, date explicitDate: Date?) throws -> RestorePlan {
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
        let date = explicitDate ?? Self.parse(name: snapshot.lastPathComponent)?.date
        return RestorePlan(snapshot: snapshot, snapshotDate: date, reposAhead: reposAhead(of: snapshot),
                           homeSnapshot: date.flatMap { HomeSnapshot.newest(atOrBefore: $0, paths: lockPaths) })
    }

    /// The newest snapshot taken at or before `date` that passes `validate` (`brahma restore --at`).
    public func snapshot(atOrBefore date: Date) -> BackupInfo? {
        list().first { $0.date <= date && (try? validate(snapshot: $0.url)) != nil }
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
    /// 2. keep a byte copy as `brahma.sqlite.pre-restore-<stamp>` (with the `-wal`/`-shm` beside it when the checkpoint failed);
    /// 3. copy the snapshot to `brahma.sqlite.restoring`, migrate it and write into it what must not roll back
    ///    (`RestoreCarry`, final review I3: the owner's stop, so the engine comes back stopped; the live database's grant
    ///    revocations and used-up uses; every taint mark; the machine-wide lab mark), then fsync it;
    /// 4. `rename(2)` it over `brahma.sqlite`: there is never a moment without a database;
    /// 5. remove the stale `-wal` and `-shm`;
    /// 6. record the restore in the restored database (`restoreEvent` with a random nonce, and each company's recorded
    ///    `mainCommit` in `restoreMain`) and write the nonce to the restore marker, before anything else can fail;
    /// 7. rebuild every FTS index (`VACUUM` may have renumbered the implicit rowids the external-content indexes point at) and
    ///    run their integrity check.
    ///
    /// With `withFiles` the data home's files are then put back from `plan.homeSnapshot` (`HomeSnapshot.restore`): that snapshot is
    /// verified against its manifest before anything changes, and what the restore overwrites is kept in `.pre-restore-<stamp>/`.
    @discardableResult
    public func restore(_ plan: RestorePlan, withFiles: Bool = false) throws -> RestoreOutcome {
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
        if withFiles {
            guard let home = plan.homeSnapshot else {
                throw RestoreError.failed("there is no data-home snapshot at or before that snapshot; nothing was changed "
                    + "(see: brahma restore without --with-files)")
            }
            do { try HomeSnapshot.verify(home) } catch { throw RestoreError.failed("\(error); nothing was changed") }
        }
        var warnings: [String] = []
        var preSnapshot: URL?
        let stamp = Self.stamp(now())
        let sibling = database.deletingLastPathComponent()
        let previous = sibling.appending(path: database.lastPathComponent + ".pre-restore-\(stamp)")
        let hadDatabase = fm.fileExists(atPath: database.path)
        // What the live database holds that a restore must not roll back (I3): read before anything changes.
        var carried: RestoreCarry.Live = hadDatabase ? .unreadable("the database could not be opened") : .none

        // 1.
        if hadDatabase {
            var checkpointProblem: String? = "the database could not be opened"
            do {
                let live = try DatabaseQueue(path: database.path)
                do {
                    // busy = 1: a reader kept the log from being emptied (the call itself does not throw then).
                    let row = try live.writeWithoutTransaction { db in try Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
                    let busy: Int = row?[0] ?? 1
                    checkpointProblem = busy == 0 ? nil : "it was busy"
                } catch { checkpointProblem = "\(error)" }
                do { carried = .read(try live.read { db in try RestoreCarry.read(db) }) } catch { carried = .unreadable("\(error)") }
                var service = self
                service.writer = live
                do { preSnapshot = try service.snapshot(reason: .preRestore) } catch {
                    warnings.append("could not take a verified snapshot of the current database (\(error)); the byte copy below is kept")
                }
                try live.close()
            } catch {
                warnings.append("the current database could not be opened (\(error)); the byte copy below is kept")
            }
            // 2. Without a checkpoint the newest commits may live only in the -wal: it travels with the byte copy.
            do {
                try fm.copyItem(at: database, to: previous)
                chmod(previous.path, 0o600)
                if let checkpointProblem {
                    var kept: [String] = []
                    for suffix in ["-wal", "-shm"] where fm.fileExists(atPath: database.path + suffix) {
                        try fm.copyItem(atPath: database.path + suffix, toPath: previous.path + suffix)
                        chmod(previous.path + suffix, 0o600)
                        kept.append(previous.lastPathComponent + suffix)
                    }
                    warnings.append("the current database could not be checkpointed (\(Self.flatText(checkpointProblem))); "
                        + (kept.isEmpty ? "it had no -wal/-shm to keep" : "its log was kept beside the byte copy: \(kept.joined(separator: ", "))"))
                }
            } catch { throw RestoreError.failed("could not keep a copy of the current database: \(error)") }
            pruneByteCopies()
        }

        // 3.
        let staging = sibling.appending(path: database.lastPathComponent + ".restoring")
        // A Litestream rebuild (`WALShipping.restoreFile`) already sits at `staging`: it is swapped in as it is.
        let alreadyStaged = plan.snapshot.resolvingSymlinksInPath().path == staging.resolvingSymlinksInPath().path
        if !alreadyStaged { try? fm.removeItem(at: staging) }
        do {
            if !alreadyStaged { try fm.copyItem(at: plan.snapshot, to: staging) }
            chmod(staging.path, 0o600)
        } catch { throw RestoreError.failed("could not stage the snapshot: \(error)") }
        // 3b. The staged copy is brought to this schema and given what must not roll back (I3): the owner's stop, the live
        // database's grant ends and taint marks, the machine-wide lab mark. Done before the rename, so the database at the live
        // path never lacks them; a failure here changes nothing.
        do {
            // Git's captured output for the restore's listing (Ruling 22) goes under the data home's `tmp`; without it, nothing
            // is listed (the restore epoch then fails closed).
            let gitTemp = home.appending(path: "tmp", directoryHint: .isDirectory)
            let gitTempRoot: URL? = (try? BrahmaPaths.ensurePrivateDirectory(gitTemp)) != nil ? gitTemp : nil
            warnings += try Self.carryForward(carried, into: staging, snapshot: plan.snapshot.lastPathComponent, now: now(),
                                              gitTempRoot: gitTempRoot)
            try Self.syncFile(staging)
        } catch {
            if !alreadyStaged { try? fm.removeItem(at: staging) }
            throw RestoreError.failed("could not prepare the snapshot (\(error)); nothing was changed")
        }

        // 4. and 5. The old log is empty after the checkpoint (or kept beside the byte copy); removing it first means the
        // renamed file never meets a stale one.
        try openersCheck()
        for suffix in ["-wal", "-shm"] { try? fm.removeItem(atPath: database.path + suffix) }
        guard rename(staging.path, database.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: staging)
            throw RestoreError.failed("could not put the snapshot in place (errno \(code))")
        }
        for suffix in ["-wal", "-shm"] { try? fm.removeItem(atPath: database.path + suffix) }
        Self.syncDirectory(sibling)

        let queue: DatabaseQueue
        do { queue = try DatabaseQueue(path: database.path) } catch {
            throw RestoreError.failed("restored, but the database could not be opened: \(error)")
        }
        defer { try? queue.close() }

        // 6. The nonce lives in the database the engine reads; the marker only points at it.
        do {
            let recordedAt = now()
            let nonce = try queue.write { db in
                try Self.recordRestoreEvent(db, snapshot: plan.snapshot.lastPathComponent, now: recordedAt, notes: warnings)
            }
            do {
                try RestoreMarker.write(nonce: nonce, to: Self.restoreMarker(home: home))
            } catch {
                // No marker will ever name this nonce: a live one would let anyone who reads it from the database roll `main` back
                // without an alert. Use it up.
                try? queue.write { db in
                    try db.execute(sql: "UPDATE restoreEvent SET consumedAt = ? WHERE nonce = ? AND consumedAt IS NULL",
                                   arguments: [recordedAt, nonce])
                }
                throw error
            }
        } catch {
            throw RestoreError.failed("restored, but the restore could not be recorded (\(error)); repositories are not re-adopted: "
                + "review each company's main and accept it (brahma main accept)")
        }

        // 7.
        do {
            try queue.writeWithoutTransaction { db in try searchRebuild(db) }
        } catch {
            throw RestoreError.failed("restored, but the search index could not be rebuilt: \(error)")
        }
        var outcome = RestoreOutcome(previousCopy: hadDatabase ? previous : nil, preRestoreSnapshot: preSnapshot, warnings: warnings)

        // 8. The files, last: the database is already where it should be.
        if withFiles, let homeSnapshot = plan.homeSnapshot {
            do {
                let result = try HomeSnapshot.restore(homeSnapshot, paths: lockPaths, now: now())
                outcome.filesRestored = result.restored
                outcome.filesPreRestore = result.movedAway > 0 || result.restored > 0 ? result.preRestore : nil
                outcome.filesSnapshot = homeSnapshot
                outcome.filesRefused = result.refused
            } catch {
                throw RestoreError.failed("the database was restored, but the files could not be put back (\(error)); "
                    + "run 'brahma restore' again with --with-files, or copy them from \(homeSnapshot.url.path)")
            }
        }
        return outcome
    }

    /// Migrates the staged snapshot and writes `RestoreCarry.apply` into it in one transaction, then empties its log and closes
    /// it, so the file renamed into place holds everything. Returns the notes for the owner.
    static func carryForward(_ live: RestoreCarry.Live, into staged: URL, snapshot: String, now: Date,
                             gitTempRoot: URL? = nil) throws -> [String] {
        let queue = try DatabaseQueue(path: staged.path)
        var closed = false
        defer { if !closed { try? queue.close() } }
        try Migrations.migrator().migrate(queue)
        let notes = try queue.write { db in try RestoreCarry.apply(live, to: db, snapshot: snapshot, now: now, gitTempRoot: gitTempRoot) }
        let row = try queue.writeWithoutTransaction { db in try Row.fetchOne(db, sql: "PRAGMA wal_checkpoint(TRUNCATE)") }
        let busy: Int = row?[0] ?? 0
        guard busy == 0 else { throw RestoreError.failed("the staged snapshot's log could not be emptied") }
        try queue.close()
        closed = true
        for suffix in ["-wal", "-shm"] { try? FileManager.default.removeItem(atPath: staged.path + suffix) }
        return notes
    }

    /// Records a restore in the (restored) database: one `restoreEvent` row with a fresh nonce, the `notes` (warnings, logged as
    /// activity when the engine takes the restore up) and, per company, the `mainCommit` this database recorded. Any earlier
    /// restore that was never taken up is marked consumed: only the newest restore can re-adopt. Returns the nonce.
    static func recordRestoreEvent(_ db: Database, snapshot: String, now: Date, notes: [String] = []) throws -> String {
        try Migrations.createRestoreTables(db)
        try db.execute(sql: "UPDATE restoreEvent SET consumedAt = ? WHERE consumedAt IS NULL", arguments: [now])
        let nonce = RestoreMarker.makeNonce()
        try db.execute(sql: "INSERT INTO restoreEvent (nonce, snapshot, restoredAt, notes) VALUES (?, ?, ?, ?)",
                       arguments: [nonce, snapshot, now, notes.joined(separator: "\n")])
        let recorded = try db.columns(in: "company").contains { $0.name == "mainCommit" } ? "mainCommit" : "NULL"
        try db.execute(sql: "INSERT INTO restoreMain (nonce, companyId, mainCommit) SELECT ?, id, \(recorded) FROM company",
                       arguments: [nonce])
        return nonce
    }

    private static func flatText(_ text: String) -> String {
        String(text.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(200))
    }

    private func pruneByteCopies() {
        let prefix = database.lastPathComponent + ".pre-restore-"
        let dir = database.deletingLastPathComponent()
        let names = (try? FileManager.default.contentsOfDirectory(atPath: dir.path)) ?? []
        let copies = names.filter { $0.hasPrefix(prefix) && !$0.hasSuffix("-wal") && !$0.hasSuffix("-shm") }.sorted()
        for old in copies.dropLast(Self.keep[.preRestore] ?? 5) {
            for name in [old, old + "-wal", old + "-shm"] { try? FileManager.default.removeItem(at: dir.appending(path: name)) }
        }
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
