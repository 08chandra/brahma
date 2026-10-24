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
    private let launchProbe: (@Sendable () -> Void)?
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var process: Process?
    private var starts = 0

    public static func pidFile(paths: BrahmaPaths) -> URL { paths.runDir.appending(path: "litestream.pid") }

    /// `launchProbe`: tests only, called just before each launch.
    public init(executable: String, paths: BrahmaPaths, tools: BackupTools = .system, grace: TimeInterval = WALShipper.stopGrace,
                launchProbe: (@Sendable () -> Void)? = nil,
                sleeper: @escaping Sleeper = { try await AwakeTime.sleep(for: $0) },
                note: @escaping @Sendable (String) -> Void = { _ in }) {
        self.executable = executable
        self.arguments = WALShipping.replicateArguments(paths: paths)
        self.environment = tools.litestreamEnvironment
        self.paths = paths
        self.grace = grace
        self.launchProbe = launchProbe
        self.sleeper = sleeper
        self.note = note
    }

    /// How many times litestream has been started.
    public var startCount: Int { lock.withLock { starts } }

    /// Blocking for at most about `grace` + 2 s when a stale litestream has to be stopped first.
    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard task == nil else { return }
        if let text = Self.reapStale(paths: paths, grace: grace) { note(text) }
        task = Task.detached { [self] in await supervise() }
    }

    /// Stops supervising and ends the child (SIGTERM, `grace`, SIGKILL); returns when it is gone. Blocking.
    public func stop() {
        let (running, child) = lock.withLock { () -> (Task<Void, Never>?, Process?) in
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
            let began = AwakeTime.uptime()
            let status = await runOnce()
            if Task.isCancelled || status == -2 { return }
            if AwakeTime.uptime() - began >= ShipperBackoff.healthyRun { backoff.reset() }
            let delay = backoff.take()
            note("litestream exited (\(status)); restarting in \(delay)")
            do { try await sleeper(delay) } catch { return }
        }
    }

    private func runOnce() async -> Int32 {
        await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<Int32, Never>) in
                let p = Process()
                p.executableURL = URL(fileURLWithPath: executable)
                p.arguments = arguments
                p.environment = environment
                p.standardInput = FileHandle.nullDevice
                p.standardOutput = FileHandle.nullDevice
                p.standardError = FileHandle.nullDevice
                p.terminationHandler = { [weak self] finished in
                    self?.lock.withLock { if self?.process === finished { self?.process = nil } }
                    continuation.resume(returning: finished.terminationStatus)
                }
                launchProbe?()
                // Launch and publish in one step under the lock: `stop` (which takes the lock) either runs first, and nothing
                // is launched, or after, and finds a launched process. An unlaunched Process is never terminated.
                lock.lock()
                guard task != nil, !Task.isCancelled else {
                    lock.unlock()
                    p.terminationHandler = nil
                    continuation.resume(returning: -2)                      // stopped before it started
                    return
                }
                do { try p.run() } catch {
                    lock.unlock()
                    p.terminationHandler = nil
                    continuation.resume(returning: -1)
                    return
                }
                starts += 1
                process = p
                let record = "\(p.processIdentifier)\n\(WALShipping.configURL(paths: paths).path)\n"
                if (try? TranscriptCapture.writePrivate(Data(record.utf8), to: Self.pidFile(paths: paths))) == nil {
                    note("could not write \(Self.pidFile(paths: paths).path)")
                }
                lock.unlock()
            }
        } onCancel: { [weak self] in
            // Only a launched process is ever published, so this never signals an unlaunched one.
            self?.lock.withLock { self?.process }?.terminate()
        }
    }

    /// SIGTERM, up to `grace` awake seconds, SIGKILL, then up to 2 s more for it to be reaped.
    static func end(_ p: Process, grace: TimeInterval) {
        guard p.isRunning else { return }
        p.terminate()
        let soft = AwakeTime.uptime() + grace
        while p.isRunning, AwakeTime.uptime() < soft { Thread.sleep(forTimeInterval: 0.01) }
        guard p.isRunning else { return }
        kill(p.processIdentifier, SIGKILL)
        let hard = AwakeTime.uptime() + 2
        while p.isRunning, AwakeTime.uptime() < hard { Thread.sleep(forTimeInterval: 0.01) }
    }

    /// A litestream an earlier engine left running for this config (named by the pid file): stopped (SIGTERM, `grace`, SIGKILL)
    /// only when its argv shows it is litestream `replicate -config <this config>`. The pid file is removed either way.
    /// Returns a line for the log, or nil when there was no pid file.
    static func reapStale(paths: BrahmaPaths, grace: TimeInterval) -> String? {
        let file = pidFile(paths: paths)
        guard let data = EngineFiles.readNoFollow(file, under: paths.runDir, limit: 4096) else { return nil }
        defer { unlink(file.path) }
        let config = WALShipping.configURL(paths: paths).path
        guard let pid = String(decoding: data, as: UTF8.self).split(separator: "\n").first.flatMap({ Int32($0) }), pid > 1 else {
            return "removed an unreadable \(file.lastPathComponent)"
        }
        guard kill(pid, 0) == 0 || errno == EPERM else { return nil }          // gone already
        guard let argv = ProcessArguments.of(pid), isLitestream(argv, config: config) else {
            return "\(file.lastPathComponent) named pid \(pid), which is not litestream for this config; it was left alone"
        }
        kill(pid, SIGTERM)
        let soft = AwakeTime.uptime() + grace
        while kill(pid, 0) == 0, AwakeTime.uptime() < soft { Thread.sleep(forTimeInterval: 0.01) }
        if kill(pid, 0) == 0, ProcessArguments.of(pid).map({ isLitestream($0, config: config) }) == true {
            kill(pid, SIGKILL)
            let hard = AwakeTime.uptime() + 2
            while kill(pid, 0) == 0, AwakeTime.uptime() < hard { Thread.sleep(forTimeInterval: 0.01) }
        }
        return "stopped litestream pid \(pid), left running by an earlier engine"
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
