import Foundation
import GRDB

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
    /// A replica written within this many awake-independent seconds counts as current (the doctor's `wal-shipping` check).
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
        try Data(text.utf8).write(to: url, options: .atomic)
        chmod(url.path, 0o600)
        return url
    }

    /// A YAML double-quoted scalar.
    static func quoted(_ text: String) -> String {
        var out = "\""
        for scalar in text.unicodeScalars {
            switch scalar {
            case "\\": out += "\\\\"
            case "\"": out += "\\\""
            case "\n": out += "\\n"
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out + "\""
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
    /// `BackupService.planRestore(snapshot:)` and `restore`. Blocking.
    public static func restoreFile(paths: BrahmaPaths, replica: String, timestamp: Date, tools: BackupTools = .system) throws -> URL {
        guard let litestream = tools.litestream else { throw WALShippingError.unavailable }
        try config(paths: paths, replica: replica)
        let staging = stagingURL(paths: paths)
        try? FileManager.default.removeItem(at: staging)
        let result = ExternalTool.run(executable: litestream, arguments: restoreArguments(paths: paths, timestamp: timestamp),
                                      environment: tools.environment, timeout: restoreTimeout)
        guard result.launched, !result.timedOut, result.status == 0, FileManager.default.fileExists(atPath: staging.path) else {
            try? FileManager.default.removeItem(at: staging)
            let why = result.timedOut ? "it did not finish in time" : String(result.output.suffix(300))
            throw WALShippingError.failed("litestream restore failed: \(why)")
        }
        chmod(staging.path, 0o600)
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
        let version = ExternalTool.run(executable: litestream, arguments: ["version"], environment: tools.environment, timeout: 30)
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
public final class WALShipper: @unchecked Sendable {
    public typealias Sleeper = @Sendable (Duration) async throws -> Void
    private let executable: String
    private let arguments: [String]
    private let environment: [String: String]
    private let sleeper: Sleeper
    private let note: @Sendable (String) -> Void
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var process: Process?
    private var starts = 0

    public init(executable: String, paths: BrahmaPaths, tools: BackupTools = .system,
                sleeper: @escaping Sleeper = { try await AwakeTime.sleep(for: $0) },
                note: @escaping @Sendable (String) -> Void = { _ in }) {
        self.executable = executable
        self.arguments = WALShipping.replicateArguments(paths: paths)
        self.environment = tools.environment
        self.sleeper = sleeper
        self.note = note
    }

    /// How many times litestream has been started.
    public var startCount: Int { lock.withLock { starts } }

    public func start() {
        lock.lock(); defer { lock.unlock() }
        guard task == nil else { return }
        task = Task.detached { [self] in await supervise() }
    }

    public func stop() {
        let (running, child) = lock.withLock { () -> (Task<Void, Never>?, Process?) in
            let pair = (task, process); task = nil; return pair
        }
        running?.cancel()
        child?.terminate()
    }

    deinit { stop() }

    private func supervise() async {
        var backoff = ShipperBackoff()
        while !Task.isCancelled {
            let began = AwakeTime.uptime()
            let status = await runOnce()
            if Task.isCancelled { return }
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
                    self?.lock.withLock { self?.process = nil }
                    continuation.resume(returning: finished.terminationStatus)
                }
                lock.lock()
                if task == nil { lock.unlock(); continuation.resume(returning: -2); return }      // stopped before it started
                starts += 1
                process = p
                lock.unlock()
                do { try p.run() } catch {
                    lock.withLock { process = nil }
                    p.terminationHandler = nil
                    continuation.resume(returning: -1)
                    return
                }
                if Task.isCancelled { p.terminate() }
            }
        } onCancel: { [weak self] in
            self?.lock.withLock { self?.process }?.terminate()
        }
    }
}
