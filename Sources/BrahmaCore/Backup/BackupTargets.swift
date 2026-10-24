import Foundation
import GRDB

/// An off-machine place the engine's backups are copied to (Task 13b).
public enum BackupTarget: Codable, Equatable, Sendable {
    /// A folder (an external drive, a NAS mount): a hard-link mirror of `paths.backupsDir` under `<path>/<hostname>/`.
    case folder(path: String)
    /// An rclone remote of type `crypt`: Brahma only ever uploads encrypted backups.
    case rclone(remote: String)

    public var summary: String {
        switch self {
        case .folder(let path): "folder \(path)"
        case .rclone(let remote): "rclone \(remote):"
        }
    }
}

public enum BackupTargetError: Error, Equatable, CustomStringConvertible, Sendable {
    case invalid(String)
    public var description: String { if case .invalid(let text) = self { return text }; return "" }
}

/// Where `rclone` and `litestream` are looked for. Neither is bundled: each degrades to "unavailable" when it is missing. Tests inject
/// a `searchPath` holding fake executables.
public struct BackupTools: Sendable {
    public var searchPath: String
    /// Other variables the tools may need (`HOME` for rclone's config, `RCLONE_CONFIG`...). Everything else is left out.
    public var passthrough: [String: String]

    public init(searchPath: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.searchPath = searchPath ?? environment["PATH"] ?? "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"
        var kept: [String: String] = [:]
        for (key, value) in environment where Self.passedThrough(key) { kept[key] = value }
        self.passthrough = kept
    }

    public static let system = BackupTools()

    private static func passedThrough(_ key: String) -> Bool {
        ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "XDG_CONFIG_HOME"].contains(key) || key.hasPrefix("RCLONE_")
    }

    public var environment: [String: String] {
        var env = passthrough
        env["PATH"] = searchPath
        return env
    }

    public func find(_ name: String) -> String? {
        for dir in searchPath.split(separator: ":") {
            let candidate = String(dir) + "/" + name
            var isDir: ObjCBool = false
            if FileManager.default.isExecutableFile(atPath: candidate),
               FileManager.default.fileExists(atPath: candidate, isDirectory: &isDir), !isDir.boolValue { return candidate }
        }
        return nil
    }

    public var rclone: String? { find("rclone") }
    public var litestream: String? { find("litestream") }
}

/// A finished external command.
struct ToolResult: Sendable {
    var status: Int32
    var output: String
    var timedOut: Bool
    var launched: Bool
}

enum ExternalTool {
    /// Runs `executable` and waits, counting awake time: past `timeout` the child is SIGTERMed, then SIGKILLed a second later.
    /// Blocking: call it inside a `Blocking` body (or a CLI's main thread). Only the last 64 KB of output are kept.
    static func run(executable: String, arguments: [String], environment: [String: String], timeout: TimeInterval) -> ToolResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.environment = environment
        let out = Pipe()
        let capture = Capture()
        let drained = DispatchSemaphore(value: 0)
        out.fileHandleForReading.readabilityHandler = { h in
            let d = h.availableData
            if d.isEmpty { h.readabilityHandler = nil; drained.signal() } else { capture.append(d) }
        }
        p.standardOutput = out
        p.standardError = out
        p.standardInput = FileHandle.nullDevice
        do { try p.run() } catch {
            out.fileHandleForReading.readabilityHandler = nil
            return ToolResult(status: -1, output: "\(error)", timedOut: false, launched: false)
        }
        let deadline = AwakeTime.uptime() + timeout
        var termAt: TimeInterval?
        var killed = false
        while p.isRunning {
            let now = AwakeTime.uptime()
            if termAt == nil, now >= deadline { termAt = now; p.terminate() }
            if let t = termAt, !killed, now - t >= 1 { killed = true; kill(p.processIdentifier, SIGKILL) }
            Thread.sleep(forTimeInterval: 0.01)
        }
        if termAt == nil { _ = drained.wait(timeout: .now() + 2) }
        out.fileHandleForReading.readabilityHandler = nil
        return ToolResult(status: p.terminationStatus, output: String(decoding: capture.snapshot, as: UTF8.self),
                          timedOut: termAt != nil, launched: true)
    }

    private final class Capture: @unchecked Sendable {
        private let lock = NSLock()
        private var data = Data()
        static let cap = 64 * 1024
        func append(_ d: Data) {
            lock.withLock { data.append(d); if data.count > Self.cap { data = data.suffix(Self.cap) } }
        }
        var snapshot: Data { lock.withLock { data } }
    }
}

/// What one target's sync did.
public enum TargetOutcome: Equatable, Sendable {
    case synced(files: Int)
    /// Not attempted (a drive that is not connected). The caller tells the owner, at most once a day.
    case skipped(String)
    /// A tool the target needs is not installed.
    case unavailable(String)
    case failed(String)
}

public struct TargetResult: Equatable, Sendable {
    public let target: BackupTarget
    public let outcome: TargetOutcome
}

/// Configuration, validation and sync of the off-machine backup targets.
public enum BackupTargets {
    /// rclone's `sync` of the whole backup set: awake seconds.
    public static let rcloneTimeout: TimeInterval = 6 * 3600

    public static func notConnectedNotice(_ path: String) -> String { "Backup drive \(path) not connected" }

    // MARK: Validation

    /// The target as stored, or the reason it is refused. A folder must exist, be writable and lie outside `paths.home` and every
    /// workspace (neither inside one, nor holding one); an rclone remote must be on PATH and of type `crypt`.
    public static func validate(_ target: BackupTarget, paths: BrahmaPaths, workspaces: [URL] = [], tools: BackupTools = .system)
        throws -> BackupTarget {
        switch target {
        case .folder(let raw):
            let path = (raw as NSString).expandingTildeInPath
            guard path.hasPrefix("/") else { throw BackupTargetError.invalid("\(raw) is not an absolute path") }
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                throw BackupTargetError.invalid("\(path) is not a folder that exists (is the drive connected?)")
            }
            guard FileManager.default.isWritableFile(atPath: path) else { throw BackupTargetError.invalid("\(path) is not writable") }
            let resolved = resolve(URL(fileURLWithPath: path, isDirectory: true))
            let forbidden = [paths.home, paths.workspaces] + workspaces
            for other in forbidden.map(resolve) where contains(resolved, other) || contains(other, resolved) {
                throw BackupTargetError.invalid("\(path) is inside (or holds) Brahma's own data (\(other.path)); "
                    + "a backup there is not off the machine and agents could reach it")
            }
            return .folder(path: resolved.path)
        case .rclone(let given):
            let remote = normalizedRemote(given)
            guard !remote.isEmpty, remote.first != "-",
                  remote.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "_-.".unicodeScalars.contains($0) }) else {
                throw BackupTargetError.invalid("'\(given)' is not an rclone remote name")
            }
            guard let rclone = tools.rclone else { throw BackupTargetError.invalid("rclone is not installed (it is not on PATH)") }
            guard isCrypt(remote: remote, rclone: rclone, tools: tools) else {
                throw BackupTargetError.invalid("\(remote) is not an rclone crypt remote — Brahma only uploads encrypted backups")
            }
            return .rclone(remote: remote)
        }
    }

    static func normalizedRemote(_ text: String) -> String {
        text.hasSuffix(":") ? String(text.dropLast()) : text
    }

    static func isCrypt(remote: String, rclone: String, tools: BackupTools) -> Bool {
        let result = ExternalTool.run(executable: rclone, arguments: ["config", "show", remote], environment: tools.environment, timeout: 60)
        guard result.launched, result.status == 0 else { return false }
        return result.output.split(whereSeparator: \.isNewline).contains { line in
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            return parts.count == 2 && parts[0] == "type" && parts[1] == "crypt"
        }
    }

    /// Symlinks resolved and the path standardized, as the sandbox compares paths.
    static func resolve(_ url: URL) -> URL { url.resolvingSymlinksInPath().standardizedFileURL }

    static func contains(_ parent: URL, _ child: URL) -> Bool {
        let p = parent.path.hasSuffix("/") ? parent.path : parent.path + "/"
        return child.path == parent.path || child.path.hasPrefix(p)
    }

    // MARK: Protection

    /// Every configured folder target as a resolved URL. These are added to `protected` and `denyRead` for every turn (Task 1a's
    /// `backupTargets`) and every sandboxed run (Task 2's `SandboxBaseline`): an agent can neither read nor delete the backups.
    public static func protectedFolders(store: Store) -> [URL] {
        protectedFolders(targets: (try? store.backupTargets()) ?? [])
    }

    public static func protectedFolders(targets: [BackupTarget]) -> [URL] {
        targets.compactMap { target in
            if case .folder(let path) = target { return resolve(URL(fileURLWithPath: path, isDirectory: true)) }
            return nil
        }
    }

    // MARK: Sync

    /// The directory a machine's backups live in on a target: its sanitized host name.
    public static func hostName(_ raw: String = ProcessInfo.processInfo.hostName) -> String {
        let cleaned = String(raw.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return cleaned.isEmpty ? "mac" : cleaned
    }

    /// Syncs `paths.backupsDir` to one target. Blocking.
    public static func sync(_ target: BackupTarget, paths: BrahmaPaths, hostname: String = hostName(), tools: BackupTools = .system)
        -> TargetOutcome {
        guard FileManager.default.fileExists(atPath: paths.backupsDir.path) else { return .synced(files: 0) }
        switch target {
        case .folder(let path):
            var isDir: ObjCBool = false
            guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
                return .skipped(notConnectedNotice(path))
            }
            do {
                let destination = URL(fileURLWithPath: path, isDirectory: true).appending(path: hostname, directoryHint: .isDirectory)
                return .synced(files: try mirror(from: paths.backupsDir, to: destination))
            } catch { return .failed("\(error)") }
        case .rclone(let remote):
            guard let rclone = tools.rclone else { return .unavailable("rclone is not installed") }
            // Re-checked on every run: a remote that was reconfigured to plain storage must never receive a backup.
            guard isCrypt(remote: remote, rclone: rclone, tools: tools) else {
                return .failed("\(remote) is not an rclone crypt remote — Brahma only uploads encrypted backups")
            }
            let result = ExternalTool.run(executable: rclone,
                                          arguments: ["sync", paths.backupsDir.path, "\(remote):\(hostname)", "--fast-list"],
                                          environment: tools.environment, timeout: rcloneTimeout)
            if result.timedOut { return .failed("rclone did not finish within \(Int(rcloneTimeout / 3600)) h and was stopped") }
            guard result.launched, result.status == 0 else {
                return .failed("rclone exited \(result.status): " + String(result.output.suffix(300)))
            }
            return .synced(files: 0)
        }
    }

    /// Syncs every target. An unmounted folder is skipped, and the owner told once a day.
    public static func syncAll(store: Store, paths: BrahmaPaths, hostname: String = hostName(), tools: BackupTools = .system,
                               now: Date = Store.now()) throws -> [TargetResult] {
        var results: [TargetResult] = []
        for target in try store.backupTargets() {
            let outcome = sync(target, paths: paths, hostname: hostname, tools: tools)
            if case .skipped(let text) = outcome { try noticeOncePerDay(store: store, title: "Backup target skipped", body: text, now: now) }
            results.append(TargetResult(target: target, outcome: outcome))
        }
        return results
    }

    /// One notice per calendar day (owner time zone) with this text.
    static func noticeOncePerDay(store: Store, title: String, body: String, now: Date) throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = store.ownerTimeZone()
        let recent = try store.writer.read { db in
            try Date.fetchAll(db, sql: "SELECT createdAt FROM ownerNotice WHERE title = ? AND body = ? ORDER BY id DESC LIMIT 1",
                              arguments: [title, body])
        }
        if let last = recent.first, calendar.isDate(last, inSameDayAs: now) { return }
        try store.writer.write { db in
            try store.notifyOwner(db: db, companyId: nil, kind: .system, urgency: .normal, title: title, body: body, now: now)
        }
    }

    // MARK: Hard-link mirror

    /// Makes `destination` match `source`: new and changed files are hard-linked (copied when the target is another volume),
    /// files no longer in `source` are removed. Symbolic links are never followed or copied. An empty source removes nothing: a
    /// lost backup set must not empty the drive. Returns the number of files in the mirror.
    static func mirror(from source: URL, to destination: URL) throws -> Int {
        let fm = FileManager.default
        try fm.createDirectory(at: destination, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        var wanted: Set<String> = []
        var count = 0
        guard let walker = fm.enumerator(atPath: source.path) else { return 0 }
        for case let relative as String in walker {
            let from = source.appending(path: relative)
            let type = (try? fm.attributesOfItem(atPath: from.path))?[.type] as? FileAttributeType
            let target = destination.appending(path: relative)
            switch type {
            case .typeDirectory:
                try fm.createDirectory(at: target, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                wanted.insert(relative)
            case .typeRegular:
                wanted.insert(relative)
                count += 1
                try place(from, at: target)
            default:
                continue                                    // symbolic links, sockets...: never followed or copied
            }
        }
        guard count > 0 else { return 0 }
        var stale: [String] = []
        if let existing = fm.enumerator(atPath: destination.path) {
            for case let relative as String in existing where !wanted.contains(relative) { stale.append(relative) }
        }
        // Deepest first, so a directory is emptied before it is removed.
        for relative in stale.sorted(by: { $0.count > $1.count }) { try? fm.removeItem(at: destination.appending(path: relative)) }
        return count
    }

    private static func place(_ file: URL, at target: URL) throws {
        let fm = FileManager.default
        guard let source = try? fm.attributesOfItem(atPath: file.path) else { return }
        if let existing = try? fm.attributesOfItem(atPath: target.path) {
            if existing[.systemFileNumber] as? UInt64 == source[.systemFileNumber] as? UInt64,
               existing[.systemNumber] as? Int == source[.systemNumber] as? Int { return }     // already the same file
            if existing[.type] as? FileAttributeType == .typeRegular, existing[.size] as? UInt64 == source[.size] as? UInt64,
               let a = existing[.modificationDate] as? Date, let b = source[.modificationDate] as? Date,
               abs(a.timeIntervalSince(b)) < 1 { return }
            try fm.removeItem(at: target)
        }
        if link(file.path, target.path) == 0 { return }
        // Another volume: copy beside the target, then rename, so a reader never sees half a file.
        let temp = target.deletingLastPathComponent().appending(path: ".\(target.lastPathComponent).partial")
        try? fm.removeItem(at: temp)
        try fm.copyItem(at: file, to: temp)
        var attributes: [FileAttributeKey: Any] = [.posixPermissions: 0o600]
        if let modified = source[.modificationDate] { attributes[.modificationDate] = modified }
        try? fm.setAttributes(attributes, ofItemAtPath: temp.path)
        guard rename(temp.path, target.path) == 0 else {
            let code = errno
            try? fm.removeItem(at: temp)
            throw BackupTargetError.invalid("could not place \(target.path) (errno \(code))")
        }
    }
}

extension Store {
    public func backupTargets() throws -> [BackupTarget] {
        let text: String? = try writer.read { db in try String.fetchOne(db, sql: "SELECT backupTargets FROM ownerPrefs WHERE id = 1") }
        guard let data = text?.data(using: .utf8), let list = try? JSONDecoder().decode([BackupTarget].self, from: data) else { return [] }
        return list
    }

    public func setBackupTargets(_ targets: [BackupTarget]) throws {
        let json = String(decoding: try JSONEncoder().encode(targets), as: UTF8.self)
        try writer.write { db in
            try db.execute(sql: "UPDATE ownerPrefs SET backupTargets = ? WHERE id = 1", arguments: [json])
        }
    }

    /// Adds a target already validated by `BackupTargets.validate`; one already present is not added twice.
    public func addBackupTarget(_ target: BackupTarget) throws {
        var list = try backupTargets()
        if !list.contains(target) { list.append(target) }
        try setBackupTargets(list)
    }

    /// Removes the target at the 1-based position `number` (as `brahma backup targets` numbers them).
    @discardableResult
    public func removeBackupTarget(number: Int) throws -> BackupTarget {
        var list = try backupTargets()
        guard number >= 1, number <= list.count else { throw BackupTargetError.invalid("there is no target \(number)") }
        let removed = list.remove(at: number - 1)
        try setBackupTargets(list)
        return removed
    }

    public func walShipping() throws -> WALShippingConfig? {
        let text: String? = try writer.read { db in try String.fetchOne(db, sql: "SELECT walShipping FROM ownerPrefs WHERE id = 1") }
        guard let data = text?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(WALShippingConfig.self, from: data)
    }

    public func setWALShipping(_ config: WALShippingConfig?) throws {
        let json = try config.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try writer.write { db in try db.execute(sql: "UPDATE ownerPrefs SET walShipping = ? WHERE id = 1", arguments: [json]) }
    }
}
