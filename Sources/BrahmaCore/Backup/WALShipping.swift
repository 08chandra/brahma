import Foundation
import GRDB
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Optional Litestream WAL shipping (Task 13b). Litestream is not bundled: when it is missing the feature reads "unavailable".
public struct WALShippingConfig: Codable, Equatable, Sendable {
    /// Where the replica lives: a folder, or a URL litestream understands (`s3://bucket/path`, `sftp://...`).
    public var replica: String
    public init(replica: String) { self.replica = replica }
}

public enum WALShippingError: Error, Equatable, CustomStringConvertible, Sendable {
    case unavailable
    case failed(String)
    public var description: String {
        switch self {
        case .unavailable: "litestream is not installed (it is not on PATH)"
        case .failed(let text): text
        }
    }
}

public enum WALShipping {
    /// A replica written within this many wall-clock seconds counts as current (the doctor's `wal-shipping` check).
    public static let freshness: TimeInterval = 600
    /// `litestream restore` may rebuild a large database: awake seconds.
    public static let restoreTimeout: TimeInterval = 3600

    public static func configURL(paths: BrahmaPaths) -> URL { paths.runDir.appending(path: "litestream.yml") }

    /// `<home>/brahma.sqlite.restoring`: where a point-in-time restore is rebuilt, then swapped in by Task 12's restore.
    public static func stagingURL(paths: BrahmaPaths) -> URL {
        paths.home.appending(path: paths.database.lastPathComponent + ".restoring")
    }

    /// Writes `<home>/run/litestream.yml` (0600) for the engine database and returns its URL.
    @discardableResult
    public static func config(paths: BrahmaPaths, replica: String) throws -> URL {
        try BrahmaPaths.ensurePrivateDirectory(paths.runDir)
        let key = replica.contains("://") ? "url" : "path"
        let text = """
            dbs:
              - path: \(quoted(paths.database.path))
                replicas:
                  - \(key): \(quoted(replica))

            """
        let url = configURL(paths: paths)
        // 0600 from the moment it exists (O_EXCL temporary, renamed in): never briefly readable at the default umask.
        try TranscriptCapture.writePrivate(Data(text.utf8), to: url)
        return url
    }

    /// A YAML double-quoted scalar: `\`, `"` and every control character are escaped (`\n`, `\r`, `\t`, else `\uXXXX`).
    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x7f || (0x80...0x9f).contains(scalar.value):
                out += String(format: "\\u%04X", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
    }

    /// The replica as it is stored, or why it is refused.
    /// - A folder (or `file://` URL) gets exactly a folder target's checks (`BackupTargets.validate`): absolute, existing,
    ///   writable, and, with links resolved, neither inside nor holding the data home or any workspace. The resolved path is
    ///   what is stored (and what `BackupTargets.protectedFolders` hands the sandbox).
    /// - A remote URL must parse and name a host, and must not carry credentials (`user:password@`): Brahma never stores replica
    ///   credentials; litestream reads them from its environment (`BackupTools.litestreamEnvironment`).
    /// - No control character anywhere (it would end up in `litestream.yml`).
    public static func validateReplica(_ replica: String, paths: BrahmaPaths, workspaces: [URL] = []) throws -> String {
        if replica.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) {
            throw WALShippingError.failed("the WAL replica holds a control character")
        }
        var folder = replica
        if let range = replica.range(of: "://") {
            let scheme = replica[..<range.lowerBound].lowercased()
            if scheme == "file" {
                folder = String(replica[range.upperBound...])
            } else {
                guard let parts = URLComponents(string: replica), let host = parts.host, !host.isEmpty,
                      scheme.allSatisfy({ $0.isLetter || $0.isNumber || "+-.".contains($0) }) else {
                    throw WALShippingError.failed("the WAL replica is not a URL litestream understands (scheme://host/path)")
                }
                if parts.password != nil {
                    throw WALShippingError.failed("the WAL replica URL holds credentials (user:password@); Brahma never stores them. "
                        + "Remove them from the URL and set them in the environment Brahma runs with instead "
                        + "(AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY, LITESTREAM_*, or an SSH agent through SSH_AUTH_SOCK)")
                }
                return replica
            }
        }
        do {
            guard case .folder(let resolved) = try BackupTargets.validate(.folder(path: folder), paths: paths, workspaces: workspaces) else {
                throw WALShippingError.failed("\(folder) is not a folder")
            }
            return resolved
        } catch let error as BackupTargetError {
            throw WALShippingError.failed("WAL replica: \(error)")
        }
    }

    /// Checks a `litestream restore` result before it is preferred over a verified snapshot: `PRAGMA integrity_check` says
    /// "ok", it opens as SQLite, it holds Brahma's core tables, and every migration it records is one this build knows (so its
    /// schema is not newer than ours). Throws `WALShippingError.failed` naming what failed.
    public static func checkRestored(_ url: URL) throws {
        let problems = BackupService.integrity(of: url)
        guard problems == ["ok"] else {
            throw WALShippingError.failed("the litestream rebuild failed its integrity check (\(problems.prefix(2).joined(separator: "; ")))")
        }
        do {
            let queue = try BackupService.openForReading(url)
            defer { try? queue.close() }
            try queue.read { db in
                for table in ["grdb_migrations", "company", "agent", "ownerPrefs"] where try !db.tableExists(table) {
                    throw WALShippingError.failed("the litestream rebuild failed its check: it has no \(table) table, so it is not a Brahma database")
                }
                let applied = try String.fetchAll(db, sql: "SELECT identifier FROM grdb_migrations")
                let known = Set(Migrations.migrator().migrations)
                if applied.isEmpty || applied.contains(where: { !known.contains($0) }) {
                    throw WALShippingError.failed("the litestream rebuild failed its check: its schema is not one this Brahma knows (newer, or not Brahma's)")
                }
            }
        } catch let error as WALShippingError {
            throw error
        } catch {
            throw WALShippingError.failed("the litestream rebuild failed its check: it does not open as a database (\(error))")
        }
    }

    public static func replicateArguments(paths: BrahmaPaths) -> [String] {
        ["replicate", "-config", configURL(paths: paths).path]
    }

    /// The `litestream restore` argv for a point in time: the result lands in `<home>/brahma.sqlite.restoring`.
    public static func restoreArguments(paths: BrahmaPaths, timestamp: Date) -> [String] {
        ["restore", "-config", configURL(paths: paths).path, "-timestamp", rfc3339(timestamp),
         "-o", stagingURL(paths: paths).path, paths.database.path]
    }

    public static func rfc3339(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        f.timeZone = TimeZone(identifier: "UTC")
        return f.string(from: date)
    }

    /// The replica the stored preferences name, read without migrating or writing (a damaged database reads as "off").
    public static func configuredReplica(paths: BrahmaPaths) -> String? {
        guard let queue = try? BackupService.openForReading(paths.database) else { return nil }
        defer { try? queue.close() }
        let json: String? = try? queue.read { db in
            try db.tableExists("ownerPrefs") && db.columns(in: "ownerPrefs").contains { $0.name == "walShipping" }
                ? String.fetchOne(db, sql: "SELECT walShipping FROM ownerPrefs WHERE id = 1") : nil
        }
        guard let data = json?.data(using: .utf8) else { return nil }
        return (try? JSONDecoder().decode(WALShippingConfig.self, from: data))?.replica
    }

    /// Rebuilds the database as it was at `timestamp` into `<home>/brahma.sqlite.restoring` and returns that file, ready for
    /// `BackupService.planRestore(snapshot:)` and `restore`, after it passed `checkRestored` (else it is removed and this
    /// throws, and the caller falls back to the newest verified snapshot). Blocking.
    public static func restoreFile(paths: BrahmaPaths, replica: String, timestamp: Date, tools: BackupTools = .system) throws -> URL {
        guard let litestream = tools.litestream else { throw WALShippingError.unavailable }
        try config(paths: paths, replica: replica)
        let staging = stagingURL(paths: paths)
        try? FileManager.default.removeItem(at: staging)
        let result = ExternalTool.run(executable: litestream, arguments: restoreArguments(paths: paths, timestamp: timestamp),
                                      environment: tools.litestreamEnvironment, timeout: restoreTimeout)
        guard result.launched, !result.timedOut, result.status == 0, FileManager.default.fileExists(atPath: staging.path) else {
            try? FileManager.default.removeItem(at: staging)
            let why = result.timedOut ? "it did not finish in time" : String(result.output.suffix(300))
            throw WALShippingError.failed("litestream restore failed: \(why)")
        }
        chmod(staging.path, 0o600)
        // Never preferred over a verified snapshot unless it passes the same kind of check.
        do { try checkRestored(staging) } catch {
            try? FileManager.default.removeItem(at: staging)
            throw error
        }
        return staging
    }

    // MARK: Doctor

    /// Seconds since the newest file in a folder replica was written (nil: not a folder replica, or empty).
    static func replicaAge(replica: String, now: Date) -> TimeInterval? {
        guard !replica.contains("://") else { return nil }
        let root = URL(fileURLWithPath: replica, isDirectory: true)
        guard let walker = FileManager.default.enumerator(at: root, includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey]) else {
            return nil
        }
        var newest: Date?
        for case let url as URL in walker {
            let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .isRegularFileKey])
            guard values?.isRegularFile == true, let modified = values?.contentModificationDate else { continue }
            if newest == nil || modified > newest! { newest = modified }
        }
        return newest.map { now.timeIntervalSince($0) }
    }

    /// The doctor's `wal-shipping` item: `litestream version` runs, and the replica was written within the last 10 minutes.
    /// Blocking.
    public static func doctorItem(replica: String?, tools: BackupTools = .system, now: Date = .now) -> DoctorItem {
        guard let replica else { return DoctorItem(name: "wal-shipping", status: .pass, detail: "off (optional; see: brahma backup wal enable)") }
        guard let litestream = tools.litestream else {
            return DoctorItem(name: "wal-shipping", status: .warn, detail: "on, but litestream is not installed (it is not on PATH)")
        }
        let version = ExternalTool.run(executable: litestream, arguments: ["version"], environment: tools.litestreamEnvironment, timeout: 30)
        guard version.launched, !version.timedOut, version.status == 0 else {
            return DoctorItem(name: "wal-shipping", status: .warn, detail: "'litestream version' failed")
        }
        let name = version.output.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let age = replicaAge(replica: replica, now: now) else {
            let detail = replica.contains("://") ? "litestream \(name); the replica is remote, so its age is not checked"
                : "litestream \(name); the replica \(replica) has nothing in it yet"
            return DoctorItem(name: "wal-shipping", status: replica.contains("://") ? .pass : .warn, detail: detail)
        }
        if age > freshness {
            return DoctorItem(name: "wal-shipping", status: .warn,
                              detail: "litestream \(name); the replica was last written \(Int(age / 60)) min ago (more than 10)")
        }
        return DoctorItem(name: "wal-shipping", status: .pass, detail: "litestream \(name); the replica was written \(Int(age)) s ago")
    }
}

/// Backoff for a restarting shipper: 5 s, doubling to 5 min.
public struct ShipperBackoff: Equatable, Sendable {
    public static let initial: Duration = .seconds(5)
    public static let ceiling: Duration = .seconds(300)
    /// A run at least this long (awake) counts as healthy and starts the backoff over.
    public static let healthyRun: TimeInterval = 60
    public private(set) var next: Duration = ShipperBackoff.initial
    public init() {}
    public mutating func take() -> Duration {
        let current = next
        next = min(next * 2, Self.ceiling)
        return current
    }
    public mutating func reset() { next = Self.initial }
}

/// Supervises `litestream replicate -config …`: restarts it whenever it exits, with `ShipperBackoff` between runs (awake time).
///
/// Lifecycle: the child's pid and config path are kept in `<home>/run/litestream.pid` (0600) while it runs. `start` first
/// stops a litestream an earlier engine left running for this same config (its pid file names it, and its argv must be
/// litestream `replicate -config <this config>`: an unrelated process is never signalled). `stop` sends SIGTERM, waits up to
/// `grace` awake seconds, then SIGKILLs, and returns once the child is gone. A process is only ever signalled after it was
/// launched (it is published under the lock in the same step as `run()`).
public final class WALShipper: @unchecked Sendable {
    public typealias Sleeper = @Sendable (Duration) async throws -> Void
    /// SIGTERM, then this many awake seconds, then SIGKILL.
    public static let stopGrace: TimeInterval = 2

    private let executable: String
    private let arguments: [String]
    private let environment: [String: String]
    private let paths: BrahmaPaths
    private let grace: TimeInterval
    private let sleeper: Sleeper
    private let note: @Sendable (String) -> Void
    /// Told when shipping pauses (Task 9c fix rounds 2 and 3): a live litestream for this config that this engine cannot prove
    /// it started (`foreign`: nothing is signalled, no second one is started, before every launch), or a child whose start time
    /// could not be read twice (`startUnreadable`: each was stopped as its own unreaped child). The caller tells the owner.
    private let onPaused: (@Sendable (PauseReason) -> Void)?
    /// The leader's start time right after a spawn (tests inject a failing one): `ProcessTable.entry(pid)?.start`.
    private let startTimeProbe: @Sendable (Int32) -> Double?
    private let launchProbe: (@Sendable () -> Void)?

    /// Why `start` or a restart launched nothing.
    public enum PauseReason: Equatable, Sendable {
        /// A live litestream `replicate -config <this config>` of this user that is not this shipper's own child.
        case foreign(pid: Int32)
        /// Two spawns in a row whose start time could not be read; both children were stopped.
        case startUnreadable
        /// The process table could not be read, so a foreign litestream for this database cannot be ruled out (S4 fix round 1,
        /// I2): nothing was started.
        case tableUnreadable
    }
    /// Awake seconds, for how long one run lasted (`ShipperBackoff.healthyRun`); a test seam.
    private let awakeUptime: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var process: ProcessGroupChild?
    private var starts = 0

    public static func pidFile(paths: BrahmaPaths) -> URL { paths.runDir.appending(path: "litestream.pid") }

    /// `launchProbe`: tests only, called just before each launch. `awakeUptime`: tests only, the clock a run's length is
    /// measured on (awake time).
    public init(executable: String, paths: BrahmaPaths, tools: BackupTools = .system, grace: TimeInterval = WALShipper.stopGrace,
                launchProbe: (@Sendable () -> Void)? = nil,
                sleeper: @escaping Sleeper = { try await AwakeTime.sleep(for: $0) },
                note: @escaping @Sendable (String) -> Void = { _ in },
                awakeUptime: @escaping @Sendable () -> TimeInterval = { AwakeTime.uptime() },
                onPaused: (@Sendable (PauseReason) -> Void)? = nil,
                startTimeProbe: (@Sendable (Int32) -> Double?)? = nil) {
        self.onPaused = onPaused
        self.startTimeProbe = startTimeProbe ?? { ProcessTable.entry($0)?.start }
        self.executable = executable
        self.arguments = WALShipping.replicateArguments(paths: paths)
        self.environment = tools.litestreamEnvironment
        self.paths = paths
        self.grace = grace
        self.launchProbe = launchProbe
        self.sleeper = sleeper
        self.note = note
        self.awakeUptime = awakeUptime
    }

    /// How many times litestream has been started.
    public var startCount: Int { lock.withLock { starts } }

    /// Blocking for at most about `grace` + 2 s when a stale litestream has to be stopped first. Nothing is started while a live
    /// litestream for this config exists that this engine cannot prove it started: the one the pid file names without a
    /// matching start (`StaleOutcome.unprovenLive`), or any other found by a read-only look at the process table
    /// (`foreignLitestream`, repeated before every launch, Task 9c fix round 3). Two litestreams must not replicate one
    /// database, and nothing unproven is ever signalled; `onPaused` tells the owner, called after the lock is released (it
    /// writes to the database, and a concurrent `stop` must not wait on that).
    public func start() {
        let paused: PauseReason? = lock.withLock {
            guard task == nil else { return nil }
            let outcome = Self.reapStale(paths: paths, grace: grace)
            if let text = outcome.text { note(text) }
            if case .unprovenLive(let pid, _) = outcome { return .foreign(pid: pid) }
            if let blocked = Self.foreignLitestream(paths: paths, excluding: nil) {
                note(Self.blockedNote(blocked))
                return blocked
            }
            task = Task.detached { [self] in await supervise() }
            return nil
        }
        if let paused { onPaused?(paused) }
    }

    /// What blocks a launch: a live `litestream replicate -config <this config>` of this user other than `excluding` (this
    /// shipper's own child, `.foreign`), or a process table that cannot be read (`.tableUnreadable`: a foreign one cannot be
    /// ruled out, so it blocks too, S4 fix round 1, I2); nil when nothing does. Read-only: the table is read and argvs looked
    /// at; nothing is signalled. Zombies and this process are skipped. `table` is injectable for tests.
    static func foreignLitestream(paths: BrahmaPaths, excluding own: Int32?,
                                  table: () -> [ProcessEntry]? = ProcessTable.snapshot) -> PauseReason? {
        let config = WALShipping.configURL(paths: paths).path
        let me = getpid(), uid = getuid()
        guard let entries = table() else { return .tableUnreadable }
        for entry in entries where entry.uid == uid && !entry.isZombie && entry.pid != me && entry.pid != own && entry.pid > 1 {
            if let argv = ProcessArguments.of(entry.pid), isLitestream(argv, config: config) { return .foreign(pid: entry.pid) }
        }
        return nil
    }

    /// The log line for a launch `foreignLitestream` blocked.
    static func blockedNote(_ reason: PauseReason) -> String {
        switch reason {
        case .foreign(let pid):
            "litestream pid \(pid) is replicating this database and this engine did not start it; WAL shipping is paused until it is stopped"
        case .tableUnreadable:
            "the process table could not be read, so another litestream for this database cannot be ruled out; WAL shipping is paused"
        case .startUnreadable:
            "litestream's start time could not be read twice in a row; WAL shipping is paused"
        }
    }

    /// Whether `start` is supervising a litestream (false before `start`, after `stop`, or while paused on an unproven one).
    public var isSupervising: Bool { lock.withLock { task != nil } }

    /// Stops supervising and ends the child (SIGTERM, `grace`, SIGKILL); returns when it is gone. Blocking.
    public func stop() {
        let (running, child) = lock.withLock { () -> (Task<Void, Never>?, ProcessGroupChild?) in
            let pair = (task, process); task = nil; return pair
        }
        guard running != nil || child != nil else { return }                 // never started (or already stopped)
        running?.cancel()
        if let child { Self.end(child, grace: grace) }
        unlink(Self.pidFile(paths: paths).path)
    }

    deinit { stop() }

    private func supervise() async {
        var backoff = ShipperBackoff()
        while !Task.isCancelled {
            let began = awakeUptime()
            let status = await runOnce()
            if Task.isCancelled || status == -2 || status == -3 { return }   // stopped before it started, or paused
            if awakeUptime() - began >= ShipperBackoff.healthyRun { backoff.reset() }
            let delay = backoff.take()
            note("litestream exited (\(status)); restarting in \(delay)")
            do { try await sleeper(delay) } catch { return }
        }
    }

    private func runOnce() async -> Int32 {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
                launchProbe?()
                // Launch and publish in one step under the lock: `stop` (which takes the lock) either runs first, and nothing
                // is launched, or after, and finds a launched process. An unlaunched child is never signalled.
                lock.lock()
                guard task != nil, !Task.isCancelled else {
                    lock.unlock()
                    continuation.resume(returning: -2)                      // stopped before it started
                    return
                }
                // Before every launch (a restart too): a litestream for this database that is not ours pauses shipping.
                if let blocked = Self.foreignLitestream(paths: paths, excluding: nil) {
                    task = nil
                    lock.unlock()
                    note(Self.blockedNote(blocked))
                    onPaused?(blocked)
                    continuation.resume(returning: -3)
                    return
                }
                // The child leads its own process group, so litestream's own helpers (ssh, sftp) go down with it. Its start
                // time is read right after the spawn and recorded with its pid: a stop path signals it only while all three
                // match. A start that cannot be read leaves no proof, so that child (provably ours: our own unreaped child) is
                // stopped at once and the spawn tried once more; a second failure pauses shipping (Task 9c fix round 3).
                let child: ProcessGroupChild
                var start: Double?
                var attempts = 0
                repeat {
                    attempts += 1
                    let spawned: ProcessGroupChild
                    do {
                        spawned = try ProcessGroupChild.spawn(executable: executable, arguments: [executable] + arguments,
                                                              environment: environment,
                                                              workingDirectory: URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true),
                                                              output: -1)
                    } catch {
                        lock.unlock()
                        continuation.resume(returning: -1)
                        return
                    }
                    starts += 1
                    start = startTimeProbe(spawned.pid)
                    if start != nil { child = spawned; break }
                    spawned.signalGroup(SIGKILL)
                    spawned.finish()
                    note("litestream pid \(spawned.pid): its start time could not be read, so it was stopped (attempt \(attempts) of 2)")
                    if attempts == 2 {
                        task = nil
                        lock.unlock()
                        // Outside the lock, as on the foreign path: the owner's notice is a database write.
                        onPaused?(.startUnreadable)
                        continuation.resume(returning: -3)
                        return
                    }
                } while true
                process = child
                let record = "\(child.pid)\n\(WALShipping.configURL(paths: paths).path)\n\(start ?? 0)\n"
                if (try? TranscriptCapture.writePrivate(Data(record.utf8), to: Self.pidFile(paths: paths))) == nil {
                    note("could not write \(Self.pidFile(paths: paths).path)")
                }
                lock.unlock()
                // Waits for the leader, sweeps what is left of its group, reaps it (nothing is signalled after that).
                let thread = Thread { [weak self] in
                    let status = ProcessGroupChild.exitCode(child.finish())
                    self?.lock.withLock { if self?.process === child { self?.process = nil } }
                    continuation.resume(returning: status)
                }
                thread.name = "brahma-litestream-reaper"
                thread.start()
            }
        } onCancel: { [weak self] in
            // Only a launched child is ever published, so this never signals an unlaunched one.
            self?.lock.withLock { self?.process }?.signalGroup(SIGTERM)
        }
    }

    /// SIGTERM to the child's whole process group, up to `grace` awake seconds, SIGKILL to the group, then up to 2 s more for the
    /// leader to go; what is left in the group is swept before the leader is reaped.
    static func end(_ child: ProcessGroupChild, grace: TimeInterval) {
        if !child.hasExited() {
            child.signalGroup(SIGTERM)
            let soft = AwakeTime.uptime() + grace
            while !child.hasExited(), AwakeTime.uptime() < soft { Thread.sleep(forTimeInterval: 0.01) }
            if !child.hasExited() {
                child.signalGroup(SIGKILL)
                let hard = AwakeTime.uptime() + 2
                while !child.hasExited(), AwakeTime.uptime() < hard { Thread.sleep(forTimeInterval: 0.01) }
            }
        }
        // A leader that ended (TERM was enough) may have left helpers in the group: the sweep kills them. A leader that
        // survived SIGKILL is not waited for.
        if child.hasExited() { child.finish() }
    }

    /// The litestream the pid file names, ended now (SIGTERM, then SIGKILL at once) when its argv shows it is litestream
    /// `replicate -config <this config>` and its start time is the one recorded: the forced exit's and the expired bound's best
    /// effort (Task 9c fix round 1, M2). Returns a line for the log, or nil when there was no pid file.
    public static func killRecorded(paths: BrahmaPaths) -> String? { reapStale(paths: paths, grace: 0).text }

    /// What `reapStale` found in the pid file.
    enum StaleOutcome: Equatable {
        /// No pid file, or the process it named is gone.
        case nothing
        case removedUnreadable
        /// A litestream for this config whose recorded start time matched: signalled.
        case stopped(Int32)
        /// Not litestream for this config (another process holds the pid now): never signalled.
        case leftAlone(Int32)
        /// Litestream for this config, alive, but without proof this engine started it (an older two-line record, or a start
        /// time that does not match): never signalled; the caller must not start a second one.
        case unprovenLive(Int32, StartProblem)

        enum StartProblem: Equatable { case missing, mismatched }

        var text: String? {
            switch self {
            case .nothing: nil
            case .removedUnreadable: "removed an unreadable litestream.pid"
            case .stopped(let pid): "stopped litestream pid \(pid), left running by an earlier engine"
            case .leftAlone(let pid): "litestream.pid named pid \(pid), which is not litestream for this config; it was left alone"
            case .unprovenLive(let pid, .missing):
                "litestream.pid named pid \(pid), litestream for this config, but recorded no start time; it was left alone"
                + " and WAL shipping is paused until it is stopped"
            case .unprovenLive(let pid, .mismatched):
                "litestream.pid named pid \(pid), litestream for this config, but its start time is not the recorded one; it was left alone"
                + " and WAL shipping is paused until it is stopped"
            }
        }
    }

    /// A litestream an earlier engine left running for this config (named by the pid file): stopped (SIGTERM, `grace`, SIGKILL)
    /// only when its argv shows it is litestream `replicate -config <this config>` and the record's start time (the third line,
    /// written at spawn) is still that process's. A record without a start time (the two-line form of engines before Task 9c)
    /// or with another is stale: the process is never signalled (`unprovenLive`). The pid file is removed in every case.
    static func reapStale(paths: BrahmaPaths, grace: TimeInterval) -> StaleOutcome {
        let file = pidFile(paths: paths)
        guard let data = EngineFiles.readNoFollow(file, under: paths.runDir, limit: 4096) else { return .nothing }
        defer { unlink(file.path) }
        let config = WALShipping.configURL(paths: paths).path
        let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")
        guard let pid = lines.first.flatMap({ Int32($0) }), pid > 1 else { return .removedUnreadable }
        guard kill(pid, 0) == 0 || errno == EPERM else { return .nothing }          // gone already
        guard let argv = ProcessArguments.of(pid), isLitestream(argv, config: config) else { return .leftAlone(pid) }
        guard lines.count > 2, let recordedStart = Double(lines[2]), recordedStart > 0 else { return .unprovenLive(pid, .missing) }
        guard ProcessTable.entry(pid)?.start == recordedStart else { return .unprovenLive(pid, .mismatched) }
        kill(pid, SIGTERM)
        let soft = AwakeTime.uptime() + grace
        while kill(pid, 0) == 0, AwakeTime.uptime() < soft { Thread.sleep(forTimeInterval: 0.01) }
        if kill(pid, 0) == 0, ProcessArguments.of(pid).map({ isLitestream($0, config: config) }) == true,
           ProcessTable.entry(pid)?.start == recordedStart {
            kill(pid, SIGKILL)
            let hard = AwakeTime.uptime() + 2
            while kill(pid, 0) == 0, AwakeTime.uptime() < hard { Thread.sleep(forTimeInterval: 0.01) }
        }
        return .stopped(pid)
    }

    /// The owner's notice when shipping paused (engine-written; the pid is the engine's own number). Only a relaunch restarts
    /// shipping: the shipper is made once per engine start.
    public static func pausedNotice(_ reason: PauseReason) -> (title: String, body: String) {
        switch reason {
        case .foreign(let pid):
            ("WAL shipping paused",
             "A litestream for this database (pid \(pid)) is running that this engine did not start, so no second one was started. "
             + "Stop that litestream process, then relaunch Brahma.")
        case .startUnreadable:
            ("WAL shipping paused",
             "Brahma could not read its own litestream's start time twice in a row and stopped both, so WAL shipping is off. "
             + "Relaunch Brahma to try again.")
        case .tableUnreadable:
            ("WAL shipping paused",
             "Brahma could not read the process table, so it could not rule out another litestream for this database and started "
             + "none. Relaunch Brahma to try again.")
        }
    }

    /// litestream (directly, or a script run by its interpreter: the name is the first or second argument) running
    /// `replicate -config <config>`.
    static func isLitestream(_ argv: [String], config: String) -> Bool {
        let named = argv.prefix(2).contains { URL(fileURLWithPath: $0).lastPathComponent == "litestream" }
        let configured = zip(argv, argv.dropFirst()).contains { $0 == "-config" && $1 == config }
        return named && argv.contains("replicate") && configured
    }
}

/// The argv of a running process (another user's, or a gone one, reads as nil).
enum ProcessArguments {
    static func of(_ pid: Int32) -> [String]? {
        #if canImport(Darwin)
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 4 else { return nil }
        var buffer = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buffer, &size, nil, 0) == 0, size > 4 else { return nil }
        let argc = Int(buffer.withUnsafeBytes { $0.loadUnaligned(as: Int32.self) })
        var i = 4
        while i < size, buffer[i] != 0 { i += 1 }                            // the executable path
        while i < size, buffer[i] == 0 { i += 1 }                            // its padding
        var argv: [String] = []
        while argv.count < argc, i < size {
            let start = i
            while i < size, buffer[i] != 0 { i += 1 }
            argv.append(String(decoding: buffer[start..<i], as: UTF8.self))
            i += 1
        }
        return argv.count == argc ? argv : nil
        #else
        guard let data = FileManager.default.contents(atPath: "/proc/\(pid)/cmdline"), !data.isEmpty else { return nil }
        return data.split(separator: 0, omittingEmptySubsequences: false).dropLast().map { String(decoding: $0, as: UTF8.self) }
        #endif
    }
}
