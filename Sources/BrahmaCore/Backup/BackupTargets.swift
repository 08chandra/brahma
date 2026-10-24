import Foundation
import GRDB
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

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
    /// Replica credentials, for litestream only (`litestreamEnvironment`): `AWS_*`, `LITESTREAM_*` and `SSH_AUTH_SOCK`. Brahma
    /// never stores replica credentials; the owner provides them in the environment the engine runs with. Litestream is
    /// engine-run, never by an agent; rclone does not get them.
    public var litestreamCredentials: [String: String]

    public init(searchPath: String? = nil, environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.searchPath = searchPath ?? environment["PATH"] ?? "/usr/bin:/bin:/opt/homebrew/bin:/usr/local/bin"
        var kept: [String: String] = [:], credentials: [String: String] = [:]
        for (key, value) in environment {
            if Self.passedThrough(key) { kept[key] = value }
            if Self.litestreamCredential(key) { credentials[key] = value }
        }
        self.passthrough = kept
        self.litestreamCredentials = credentials
    }

    static func litestreamCredential(_ key: String) -> Bool {
        key.hasPrefix("AWS_") || key.hasPrefix("LITESTREAM_") || key == "SSH_AUTH_SOCK"
    }

    public static let system = BackupTools()

    private static func passedThrough(_ key: String) -> Bool {
        ["HOME", "USER", "LOGNAME", "TMPDIR", "LANG", "LC_ALL", "XDG_CONFIG_HOME"].contains(key) || key.hasPrefix("RCLONE_")
    }

    /// What litestream runs with: `environment` plus `litestreamCredentials`.
    public var litestreamEnvironment: [String: String] { environment.merging(litestreamCredentials) { $1 } }

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
        return cryptSection(result.output, remote: remote)
    }

    /// True when the `[<remote>]` section of `rclone config show` output (and only that section: another remote's section,
    /// or lines before any section header, never count) has `type = crypt`.
    static func cryptSection(_ output: String, remote: String) -> Bool {
        var inRemote = false
        for raw in output.split(whereSeparator: \.isNewline) {
            let line = raw.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                inRemote = line.dropFirst().dropLast() == Substring(remote)
                continue
            }
            guard inRemote else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            if parts.count == 2 && parts[0] == "type" { return parts[1] == "crypt" }
        }
        return false
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
    /// The WAL replica, when it is a folder, is protected the same way (it holds the database's whole history).
    public static func protectedFolders(store: Store) -> [URL] {
        protectedFolders(targets: (try? store.backupTargets()) ?? [], walReplica: (try? store.walShipping())?.replica)
    }

    public static func protectedFolders(targets: [BackupTarget], walReplica: String? = nil) -> [URL] {
        var folders = targets.compactMap { target -> URL? in
            if case .folder(let path) = target { return resolve(URL(fileURLWithPath: path, isDirectory: true)) }
            return nil
        }
        if let walReplica {
            var path: String?
            if walReplica.lowercased().hasPrefix("file://") { path = String(walReplica.dropFirst("file://".count)) }
            else if !walReplica.contains("://") { path = walReplica }
            if let path, path.hasPrefix("/") {
                let url = resolve(URL(fileURLWithPath: path, isDirectory: true))
                if !folders.contains(url) { folders.append(url) }
            }
        }
        return folders
    }

    // MARK: Sync

    /// The directory a machine's backups live in on a target: its sanitized host name.
    public static func hostName(_ raw: String = ProcessInfo.processInfo.hostName) -> String {
        let cleaned = String(raw.unicodeScalars.map { CharacterSet.alphanumerics.contains($0) || "-_.".unicodeScalars.contains($0) ? Character($0) : "-" })
            .trimmingCharacters(in: CharacterSet(charactersIn: ".-"))
        return cleaned.isEmpty ? "mac" : cleaned
    }

    /// Syncs `paths.backupsDir` to one target. Blocking.
    ///
    /// A folder is checked again first, every time (`recheck`): still where it was added (no part of it became a link), still
    /// outside the data home and every workspace, and mounted (an emptied mount point under `volumesRoot` on the data home's
    /// volume reads as not connected). `workspaces`: the companies' workspaces (`syncAll` passes them).
    public static func sync(_ target: BackupTarget, paths: BrahmaPaths, hostname: String = hostName(), tools: BackupTools = .system,
                            workspaces: [URL] = [], volumesRoot: URL = URL(fileURLWithPath: "/Volumes")) -> TargetOutcome {
        guard FileManager.default.fileExists(atPath: paths.backupsDir.path) else { return .synced(files: 0) }
        switch target {
        case .folder(let path):
            if let refused = recheck(folder: path, paths: paths, workspaces: workspaces, volumesRoot: volumesRoot) { return refused }
            do {
                return .synced(files: try mirror(from: paths.backupsDir, into: URL(fileURLWithPath: path, isDirectory: true),
                                                 hostname: hostname))
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
        let workspaces = try store.companies().map { URL(fileURLWithPath: $0.workspacePath, isDirectory: true) }
        for target in try store.backupTargets() {
            let outcome = sync(target, paths: paths, hostname: hostname, tools: tools, workspaces: workspaces)
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

    // MARK: Folder check at each sync

    /// Nil when the stored folder may receive the mirror now; else the outcome to report instead.
    static func recheck(folder path: String, paths: BrahmaPaths, workspaces: [URL], volumesRoot: URL) -> TargetOutcome? {
        guard path.hasPrefix("/") else { return .failed("\(path) is not an absolute path; re-add the target") }
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return .skipped(notConnectedNotice(path))
        }
        let stored = URL(fileURLWithPath: path, isDirectory: true).standardizedFileURL
        let now = resolve(stored)
        guard now.path == stored.path else {
            return .failed("\(path) now resolves to \(now.path) (a part of it was replaced by a link); nothing was copied. "
                + "Check the drive and re-add the target (brahma backup target add folder)")
        }
        for other in ([paths.home, paths.workspaces] + workspaces).map(resolve) where contains(now, other) || contains(other, now) {
            return .failed("\(path) is inside (or holds) Brahma's own data (\(other.path)); nothing was copied. Re-add a folder outside it")
        }
        // An emptied mount point left on the boot volume (the drive is unplugged) must not receive the mirror.
        let volumes = resolve(volumesRoot)
        if contains(volumes, now), now.path != volumes.path {
            var target = stat(), home = stat()
            if stat(now.path, &target) == 0, stat(paths.home.path, &home) == 0, target.st_dev == home.st_dev {
                return .skipped(notConnectedNotice(path))
            }
        }
        guard FileManager.default.isWritableFile(atPath: path) else { return .failed("\(path) is not writable") }
        return nil
    }

    // MARK: Folder mirror

    /// Deeper than this, a directory of the backup set is not mirrored.
    static let maxMirrorDepth = 64

    /// Makes `<target>/<hostname>/` match `source` (the backups directory). Every read, write and removal goes through
    /// descriptors (`HomeFiles` / `EngineFiles.OpenDirectory`): the target is resolved once, then each directory is opened with
    /// `O_NOFOLLOW | O_DIRECTORY` relative to the one before (a link at `<target>/<hostname>` or anywhere in the mirror is
    /// refused and the sync fails, nothing written through it); files are copied to an `O_EXCL` temporary in the held
    /// directory and `renameat`-ed into place; stale entries are removed with `EngineFiles.removeEntry` relative to their
    /// held parent (a link is unlinked, never followed), so removal never leaves `<target>/<hostname>/`.
    ///
    /// Files are always copied, never hard-linked to the source, even on the same volume: a target never shares an inode with
    /// a file under the data home. Within one run, files that are one inode in the source (the data-home snapshots' links)
    /// become one inode in the mirror too. A file already there with the same size and modification time is left as it is.
    /// An empty source removes nothing: a lost backup set must not empty the drive. Returns the number of files mirrored.
    static func mirror(from source: URL, into target: URL, hostname: String) throws -> Int {
        let from = try HomeFiles.root(source)
        let root = try HomeFiles.root(target)
        let host = try HomeFiles.walk(root, [hostname], create: true)
        var run = MirrorRun(host: host)
        try run.copy(from, into: host, prefix: "", depth: 0)
        guard run.count > 0 else { return 0 }
        try run.prune(host, prefix: "", depth: 0)
        return run.count
    }

    private struct InodeKey: Hashable { let dev: Int64; let ino: UInt64 }

    private struct MirrorRun {
        let host: HomeFiles.Directory
        var wanted: Set<String> = []
        var count = 0
        /// Source inode -> the mirror path of its first copy this run.
        var placed: [InodeKey: String] = [:]

        init(host: HomeFiles.Directory) { self.host = host }

        mutating func copy(_ from: HomeFiles.Directory, into to: HomeFiles.Directory, prefix: String, depth: Int) throws {
            guard depth < BackupTargets.maxMirrorDepth else { return }
            for name in try from.names().sorted() {
                guard let st = HomeFiles.status(from, name) else { continue }
                let relative = prefix + name
                switch st.st_mode & S_IFMT {
                case S_IFDIR:
                    wanted.insert(relative)
                    let child = try from.child(name)
                    try copy(child, into: try HomeFiles.walk(to, [name], create: true), prefix: relative + "/", depth: depth + 1)
                case S_IFREG:
                    wanted.insert(relative)
                    count += 1
                    try place(from, name, st, into: to, relative: relative)
                default:
                    continue                                                // links, sockets...: never followed or copied
                }
            }
        }

        private mutating func place(_ from: HomeFiles.Directory, _ name: String, _ st: stat, into to: HomeFiles.Directory,
                                    relative: String) throws {
            let key = InodeKey(dev: Int64(st.st_dev), ino: UInt64(st.st_ino))
            if let existing = HomeFiles.status(to, name), existing.st_mode & S_IFMT == S_IFREG,
               !(existing.st_dev == st.st_dev && existing.st_ino == st.st_ino),       // a hard link to the source is replaced
               existing.st_size == st.st_size, abs(BackupTargets.mtime(existing) - BackupTargets.mtime(st)) < 2 {
                if placed[key] == nil { placed[key] = relative }
                return
            }
            let temp = ".brahma-partial-\(UUID().uuidString)"
            if let first = placed[key], linkWithin(first, to: to, temp) {
                // Same source inode as a file already mirrored this run: the same mirror inode.
            } else {
                let input = try HomeFiles.openRead(from, name)
                defer { close(input) }
                try HomeFiles.copy(from: input, toNew: to, temp)
                BackupTargets.setMtime(of: temp, in: to, like: st)
            }
            if let existing = HomeFiles.status(to, name), existing.st_mode & S_IFMT == S_IFDIR {
                try EngineFiles.removeEntry(dfd: to.fd, name: name, shown: to.shown.appending(path: name).path)
            }
            do { try HomeFiles.rename(to, temp, to: to, name) } catch {
                unlinkat(to.fd, temp, 0)
                throw error
            }
            if placed[key] == nil { placed[key] = relative }
        }

        /// A hard link, inside the mirror, from the earlier copy at `first` to `name` in `to`.
        private func linkWithin(_ first: String, to: HomeFiles.Directory, _ name: String) -> Bool {
            let parts = first.split(separator: "/").map(String.init)
            guard let leaf = parts.last, let dir = try? HomeFiles.walk(host, parts.dropLast(), create: false) else { return false }
            return linkat(dir.fd, leaf, to.fd, name, 0) == 0
        }

        /// Removes what is in the mirror but no longer in the source, relative to each held directory.
        func prune(_ dir: HomeFiles.Directory, prefix: String, depth: Int) throws {
            guard depth < BackupTargets.maxMirrorDepth else { return }
            for name in try dir.names() {
                let relative = prefix + name
                guard let st = HomeFiles.status(dir, name) else { continue }
                if !wanted.contains(relative) {
                    try? EngineFiles.removeEntry(dfd: dir.fd, name: name, shown: dir.shown.appending(path: name).path)
                } else if st.st_mode & S_IFMT == S_IFDIR, let child = try? dir.child(name) {
                    try prune(child, prefix: relative + "/", depth: depth + 1)
                }
            }
        }
    }

    static func mtime(_ st: stat) -> TimeInterval {
        #if canImport(Darwin)
        TimeInterval(st.st_mtimespec.tv_sec) + TimeInterval(st.st_mtimespec.tv_nsec) / 1e9
        #else
        TimeInterval(st.st_mtim.tv_sec) + TimeInterval(st.st_mtim.tv_nsec) / 1e9
        #endif
    }

    /// Gives `name` in `dir` the source's modification time (never following a link), so the next run sees it unchanged.
    static func setMtime(of name: String, in dir: HomeFiles.Directory, like st: stat) {
        #if canImport(Darwin)
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), st.st_mtimespec]
        #else
        var times = [timespec(tv_sec: 0, tv_nsec: Int(UTIME_OMIT)), st.st_mtim]
        #endif
        _ = utimensat(dir.fd, name, &times, AT_SYMLINK_NOFOLLOW)
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
