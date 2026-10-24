import Foundation
import GRDB
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum HomeSnapshotError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case damaged(String)
    case io(String)
    public var description: String {
        switch self {
        case .damaged(let text): "the data-home snapshot is damaged: \(text)"
        case .io(let text): text
        }
    }
    public var errorDescription: String? { description }
}

/// One data-home snapshot on disk: `<backups>/home/home-<stamp>/` with the mirrored `tree/` and a `MANIFEST.json`.
public struct HomeSnapshotInfo: Equatable, Sendable {
    public let url: URL
    public let date: Date
    public var name: String { url.lastPathComponent }
    public var treeURL: URL { url.appending(path: "tree", directoryHint: .isDirectory) }
    public var manifestURL: URL { url.appending(path: "MANIFEST.json") }
}

public struct HomeSnapshotManifest: Codable, Equatable, Sendable {
    public struct Entry: Codable, Equatable, Sendable {
        public var size: Int64
        public var mtimeNs: Int64
        /// StableHash (FNV-1a 64) of the snapshot's copy of the file.
        public var sha: String
        /// `file`, or `sqlite` for a `VACUUM INTO` copy.
        public var kind: String
    }
    public var format = 1
    public var takenAt: Date
    public var files: [String: Entry]
}

public struct HomeSnapshotResult: Equatable, Sendable {
    public let info: HomeSnapshotInfo
    public let linked: Int
    public let copied: Int
    /// Files left out because they could not be copied or failed their check (named, with the reason).
    public let problems: [String]
}

public struct HomeRestoreResult: Equatable, Sendable {
    /// `<home>/.pre-restore-<stamp>`: every file the restore overwrote or moved away.
    public let preRestore: URL
    public let restored: Int
    public let movedAway: Int
}

/// An incremental hard-link mirror of the data home: everything under `paths.home` except `run/`, `backups/`, `tmp/`, `cache/`,
/// `*.sqlite-wal`, `*.sqlite-shm`, `*.lock` and the live `brahma.sqlite`. A file unchanged since the previous snapshot is a hard
/// link to that snapshot's copy; SQLite files (the company archives) are `VACUUM INTO` copies, integrity-checked.
public enum HomeSnapshot {
    public static let keepDaily = 30

    static let excludedDirectories: Set<String> = ["run", "backups", "tmp", "cache"]
    static let excludedSuffixes = [".sqlite-wal", ".sqlite-shm", ".lock"]
    static let preRestorePrefix = ".pre-restore-"

    /// Whether the path (relative to the data home) is left out of the backup set.
    public static func excluded(_ relative: String) -> Bool {
        let parts = relative.split(separator: "/").map(String.init)
        guard let first = parts.first else { return true }
        if excludedDirectories.contains(first) { return true }
        if first.hasPrefix(preRestorePrefix) { return true }
        // The live database and its byte copies (`brahma.sqlite.pre-restore-*`, `.restoring`): the database has its own snapshots.
        if parts.count == 1, first.hasPrefix("brahma.sqlite") { return true }
        guard let name = parts.last else { return true }
        return excludedSuffixes.contains { name.hasSuffix($0) }
    }

    // MARK: Listing

    static func stamp(_ date: Date) -> String { "home-" + BackupService.stamp(date) }

    static func parse(name: String) -> Date? {
        guard name.hasPrefix("home-") else { return nil }
        return BackupService.parse(name: "brahma-" + name.dropFirst("home-".count) + "-manual.sqlite")?.date
    }

    /// Every snapshot with a manifest, newest first.
    public static func list(paths: BrahmaPaths) -> [HomeSnapshotInfo] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: paths.homeSnapshots.path)) ?? []
        return names.compactMap { name -> HomeSnapshotInfo? in
            guard let date = parse(name: name) else { return nil }
            let info = HomeSnapshotInfo(url: paths.homeSnapshots.appending(path: name, directoryHint: .isDirectory), date: date)
            return FileManager.default.fileExists(atPath: info.manifestURL.path) ? info : nil
        }
        .sorted { ($0.date, $0.name) > ($1.date, $1.name) }
    }

    /// The newest snapshot taken at or before `date`.
    public static func newest(atOrBefore date: Date, paths: BrahmaPaths) -> HomeSnapshotInfo? {
        list(paths: paths).first { $0.date <= date }
    }

    public static func manifest(of info: HomeSnapshotInfo) throws -> HomeSnapshotManifest {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        do { return try decoder.decode(HomeSnapshotManifest.self, from: Data(contentsOf: info.manifestURL)) } catch {
            throw HomeSnapshotError.damaged("\(info.name) has no readable manifest (\(error))")
        }
    }

    /// Regular files under `root`, relative to it.
    public static func relativeFiles(under root: URL) throws -> [String] {
        var found: [String] = []
        func walk(_ dir: URL, _ prefix: String) throws {
            for name in try FileManager.default.contentsOfDirectory(atPath: dir.path).sorted() {
                let url = dir.appending(path: name)
                var st = stat()
                guard lstat(url.path, &st) == 0 else { continue }
                switch st.st_mode & S_IFMT {
                case S_IFDIR: try walk(url, prefix + name + "/")
                case S_IFREG: found.append(prefix + name)
                default: continue
                }
            }
        }
        try walk(root, "")
        return found
    }

    // MARK: Take

    /// Blocking (file system and SQLite work): the caller runs it inside a `Blocking` body.
    ///
    /// 1. Stage `tree/` under `<home>/tmp`; for each file in the backup set: unchanged since the previous snapshot (same size and
    ///    modification time) is a hard link to its copy there; otherwise it is copied (a SQLite file with `VACUUM INTO` and
    ///    `integrity_check`), hashed, and linked instead when the hash equals the previous snapshot's.
    /// 2. `MANIFEST.json`, then the staging directory is renamed into `backups/home/`.
    /// 3. Snapshots beyond `keepDaily` are pruned (their links keep the surviving snapshots whole).
    @discardableResult
    public static func take(paths: BrahmaPaths, now: Date = Date()) throws -> HomeSnapshotResult {
        let fm = FileManager.default
        try paths.ensureTmpDir()
        try BrahmaPaths.ensurePrivateDirectory(paths.homeSnapshots)
        let name = stamp(now)
        let final = paths.homeSnapshots.appending(path: name, directoryHint: .isDirectory)
        guard !fm.fileExists(atPath: final.path) else { throw HomeSnapshotError.io("\(name) already exists") }
        let staging = paths.tmpDir.appending(path: "home-snapshot-\(UUID().uuidString)", directoryHint: .isDirectory)
        try BrahmaPaths.ensurePrivateDirectory(staging)
        defer { try? fm.removeItem(at: staging) }
        let tree = staging.appending(path: "tree", directoryHint: .isDirectory)
        try BrahmaPaths.ensurePrivateDirectory(tree)

        let previous = list(paths: paths).first
        let before = previous.flatMap { try? manifest(of: $0) }
        var files: [String: HomeSnapshotManifest.Entry] = [:]
        var problems: [String] = []
        var linked = 0, copied = 0

        var candidates: [String] = []
        try walkHome(paths.home, prefix: "") { candidates.append($0) }
        for relative in candidates.sorted() {
            let source = paths.home.appending(path: relative)
            var st = stat()
            guard lstat(source.path, &st) == 0, (st.st_mode & S_IFMT) == S_IFREG else { continue }
            let target = tree.appending(path: relative)
            try BrahmaPaths.ensurePrivateDirectory(target.deletingLastPathComponent())
            let isSQLite = relative.hasSuffix(".sqlite")
            let kind = isSQLite ? "sqlite" : "file"
            let size = Int64(st.st_size), mtime = modificationNs(st)
            let old = before?.files[relative]
            let oldCopy = previous?.treeURL.appending(path: relative)
            do {
                // Unchanged file: link the previous copy (a SQLite file is re-copied: its bytes do not change with its mtime
                // alone being trustworthy, and a VACUUM INTO of an unchanged database is the same bytes).
                if !isSQLite, let old, let oldCopy, old.size == size, old.mtimeNs == mtime,
                   link(oldCopy.path, target.path) == 0 {
                    files[relative] = old
                    linked += 1
                    continue
                }
                if isSQLite {
                    let temp = paths.tmpDir.appending(path: "home-sqlite-\(UUID().uuidString).sqlite")
                    defer { unlink(temp.path) }
                    try vacuumCopy(source, to: temp)
                    let hash = try fileHash(temp)
                    if let old, old.sha == hash, let oldCopy, link(oldCopy.path, target.path) == 0 {
                        linked += 1
                    } else {
                        guard rename(temp.path, target.path) == 0 else { throw HomeSnapshotError.io("could not stage \(relative) (errno \(errno))") }
                        chmod(target.path, 0o600)
                        copied += 1
                    }
                    var after = stat()
                    let copySize = (lstat(target.path, &after) == 0) ? Int64(after.st_size) : size
                    files[relative] = .init(size: copySize, mtimeNs: mtime, sha: hash, kind: kind)
                    continue
                }
                try copyFile(source, to: target)
                let hash = try fileHash(target)
                if let old, old.sha == hash, let oldCopy {
                    // Same bytes, new mtime: link instead of keeping a second copy.
                    unlink(target.path)
                    if link(oldCopy.path, target.path) == 0 { linked += 1 } else {
                        try copyFile(source, to: target)
                        copied += 1
                    }
                } else {
                    copied += 1
                }
                var after = stat()
                let copySize = (lstat(target.path, &after) == 0) ? Int64(after.st_size) : size
                files[relative] = .init(size: copySize, mtimeNs: mtime, sha: hash, kind: kind)
            } catch {
                unlink(target.path)
                problems.append("\(relative): \(error)")
            }
        }

        let record = HomeSnapshotManifest(takenAt: now, files: files)
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try TranscriptCapture.writePrivate(try encoder.encode(record), to: staging.appending(path: "MANIFEST.json"))
        guard rename(staging.path, final.path) == 0 else {
            throw HomeSnapshotError.io("could not move the snapshot into \(paths.homeSnapshots.path) (errno \(errno))")
        }
        chmod(final.path, 0o700)
        BackupService.syncDirectory(paths.homeSnapshots)
        prune(paths: paths)
        return HomeSnapshotResult(info: HomeSnapshotInfo(url: final, date: now), linked: linked, copied: copied, problems: problems)
    }

    static func prune(paths: BrahmaPaths) {
        for old in list(paths: paths).dropFirst(keepDaily) { try? FileManager.default.removeItem(at: old.url) }
    }

    /// The backup set: regular files under the home, never through a link, honouring `excluded`.
    private static func walkHome(_ dir: URL, prefix: String, _ visit: (String) -> Void) throws {
        for name in try FileManager.default.contentsOfDirectory(atPath: dir.path) {
            let relative = prefix + name
            if excluded(relative) { continue }
            let url = dir.appending(path: name)
            var st = stat()
            guard lstat(url.path, &st) == 0 else { continue }
            switch st.st_mode & S_IFMT {
            case S_IFDIR: try walkHome(url, prefix: relative + "/", visit)
            case S_IFREG: visit(relative)
            default: continue
            }
        }
    }

    private static func modificationNs(_ st: stat) -> Int64 {
        #if canImport(Darwin)
        Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        #else
        Int64(st.st_mtim.tv_sec) * 1_000_000_000 + Int64(st.st_mtim.tv_nsec)
        #endif
    }

    private static func copyFile(_ source: URL, to target: URL) throws {
        let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard input >= 0 else { throw HomeSnapshotError.io("cannot read (errno \(errno))") }
        defer { close(input) }
        let output = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw HomeSnapshotError.io("cannot create the copy (errno \(errno))") }
        var ok = true
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        copying: while true {
            let n = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress!, $0.count) }
            if n < 0 { if errno == EINTR { continue }; ok = false; break }
            if n == 0 { break }
            var done = 0
            while done < n {
                let w = buffer.withUnsafeBytes { write(output, $0.baseAddress! + done, n - done) }
                if w < 0 { if errno == EINTR { continue }; ok = false; break copying }
                done += w
            }
        }
        ok = ok && fsync(output) == 0
        let closed = close(output) == 0
        guard ok, closed else { unlink(target.path); throw HomeSnapshotError.io("copy failed (errno \(errno))") }
    }

    /// FNV-1a 64 of a file, streamed.
    static func fileHash(_ url: URL) throws -> String {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw HomeSnapshotError.io("cannot read \(url.lastPathComponent) (errno \(errno))") }
        defer { close(fd) }
        var hash: UInt64 = 0xcbf29ce484222325
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress!, $0.count) }
            if n < 0 { if errno == EINTR { continue }; throw HomeSnapshotError.io("cannot read \(url.lastPathComponent) (errno \(errno))") }
            if n == 0 { break }
            for i in 0..<n { hash ^= UInt64(buffer[i]); hash = hash &* 0x100000001b3 }
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    /// `VACUUM INTO` a SQLite file that is not ours alone (a company archive), then `integrity_check` on the copy. A file that is
    /// not a database at all is copied as it is.
    private static func vacuumCopy(_ source: URL, to destination: URL) throws {
        var config = Configuration()
        config.busyMode = .timeout(5)
        do {
            let queue = try DatabaseQueue(path: source.path, configuration: config)
            defer { try? queue.close() }
            try queue.writeWithoutTransaction { db in try db.execute(sql: "VACUUM INTO ?", arguments: [destination.path]) }
        } catch let error as DatabaseError where error.resultCode == .SQLITE_NOTADB {
            try copyFile(source, to: destination)
            return
        }
        chmod(destination.path, 0o600)
        let problems = BackupService.integrity(of: destination)
        guard problems == ["ok"] else {
            unlink(destination.path)
            throw HomeSnapshotError.damaged("integrity check failed (\(problems.prefix(2).joined(separator: "; ")))")
        }
    }

    // MARK: Restore

    /// Hashes every file of the snapshot against its manifest; throws on the first mismatch. Changes nothing.
    @discardableResult
    public static func verify(_ snapshot: HomeSnapshotInfo) throws -> HomeSnapshotManifest {
        let recorded = try manifest(of: snapshot)
        for (relative, entry) in recorded.files.sorted(by: { $0.key < $1.key }) {
            guard !excluded(relative), !relative.contains("..") else { throw HomeSnapshotError.damaged("\(relative) is not a path a snapshot may hold") }
            let copy = snapshot.treeURL.appending(path: relative)
            guard let hash = try? fileHash(copy), hash == entry.sha else {
                throw HomeSnapshotError.damaged("\(relative) does not match its recorded hash in \(snapshot.name)")
            }
        }
        return recorded
    }

    /// Puts the home's files back as they were in `snapshot`, holding no lock of its own (`BackupService.restore` calls it with
    /// the engine lock held).
    ///
    /// 1. Every file of the snapshot is hashed against its manifest first; a mismatch throws and nothing has changed.
    /// 2. Each file in the backup set that is in the home but not in the snapshot, and each one the snapshot replaces, is moved
    ///    to `<home>/.pre-restore-<stamp>/` (never deleted).
    /// 3. The snapshot's files are copied in (a copy, never a link, so the snapshot stays intact) and each is hashed again.
    public static func restore(_ snapshot: HomeSnapshotInfo, paths: BrahmaPaths, now: Date = Date()) throws -> HomeRestoreResult {
        let fm = FileManager.default
        let recorded = try verify(snapshot)
        let keep = paths.home.appending(path: preRestorePrefix + BackupService.stamp(now), directoryHint: .isDirectory)
        var moved = 0, restored = 0
        func moveAside(_ relative: String) throws {
            let from = paths.home.appending(path: relative)
            var st = stat()
            guard lstat(from.path, &st) == 0 else { return }
            let to = keep.appending(path: relative)
            try BrahmaPaths.ensurePrivateDirectory(to.deletingLastPathComponent())
            guard rename(from.path, to.path) == 0 else { throw HomeSnapshotError.io("could not move \(relative) aside (errno \(errno))") }
            moved += 1
        }
        var present: [String] = []
        try walkHome(paths.home, prefix: "") { present.append($0) }
        for relative in present where recorded.files[relative] == nil {
            if relative.hasSuffix(".sqlite") { for suffix in ["-wal", "-shm"] { try moveAside(relative + suffix) } }
            try moveAside(relative)
        }
        for (relative, entry) in recorded.files.sorted(by: { $0.key < $1.key }) {
            let destination = paths.home.appending(path: relative)
            if entry.kind == "sqlite" { for suffix in ["-wal", "-shm"] { try moveAside(relative + suffix) } }
            try moveAside(relative)
            try BrahmaPaths.ensurePrivateDirectory(destination.deletingLastPathComponent())
            let staging = destination.deletingLastPathComponent().appending(path: ".\(destination.lastPathComponent).\(UUID().uuidString).restoring")
            try copyFile(snapshot.treeURL.appending(path: relative), to: staging)
            guard try fileHash(staging) == entry.sha, rename(staging.path, destination.path) == 0 else {
                unlink(staging.path)
                throw HomeSnapshotError.damaged("\(relative) did not verify after the copy")
            }
            restored += 1
        }
        if moved > 0 { BackupService.syncDirectory(paths.home) }
        if !fm.fileExists(atPath: keep.path) { try? BrahmaPaths.ensurePrivateDirectory(keep) }
        return HomeRestoreResult(preRestore: keep, restored: restored, movedAway: moved)
    }
}
