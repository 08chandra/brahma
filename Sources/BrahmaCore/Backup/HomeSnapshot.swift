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
    /// Entries not restored because their way in the home is not a real directory (a link planted there, or a file where a
    /// directory should be), each `<relative path>: <what is in the way>`. Nothing was written or moved through them.
    public var refused: [String] = []
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
    ///
    /// The home is read through `HomeFiles` (a descriptor walk that never follows a link): a linked directory or file under the
    /// home is not in the snapshot, and nothing outside the home is read.
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

        let home = try HomeFiles.root(paths.home)
        var walkProblems: [String] = []
        try walkHome(home, prefix: "", depth: 0, problems: &walkProblems) { dir, leaf, relative, st in
            let target = tree.appending(path: relative)
            let isSQLite = relative.hasSuffix(".sqlite")
            let kind = isSQLite ? "sqlite" : "file"
            let size = Int64(st.st_size), mtime = modificationNs(st)
            let old = before?.files[relative]
            let oldCopy = previous?.treeURL.appending(path: relative)
            do {
                try BrahmaPaths.ensurePrivateDirectory(target.deletingLastPathComponent())
                // Unchanged file: link the previous copy (a SQLite file is re-copied: its bytes do not change with its mtime
                // alone being trustworthy, and a VACUUM INTO of an unchanged database is the same bytes).
                if !isSQLite, let old, let oldCopy, old.size == size, old.mtimeNs == mtime,
                   link(oldCopy.path, target.path) == 0 {
                    files[relative] = old
                    linked += 1
                    return
                }
                if isSQLite {
                    let temp = paths.tmpDir.appending(path: "home-sqlite-\(UUID().uuidString).sqlite")
                    defer { unlink(temp.path) }
                    try vacuumCopy(in: dir, leaf, expected: st, to: temp)
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
                    return
                }
                let input = try HomeFiles.openRead(dir, leaf)
                defer { close(input) }
                try copyFile(from: input, to: target)
                let hash = try fileHash(target)
                if let old, old.sha == hash, let oldCopy {
                    // Same bytes, new mtime: link instead of keeping a second copy (the link replaces the copy atomically).
                    let swap = target.deletingLastPathComponent().appending(path: ".link-\(UUID().uuidString)")
                    if link(oldCopy.path, swap.path) == 0, rename(swap.path, target.path) == 0 { linked += 1 } else {
                        unlink(swap.path)
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

        problems = walkProblems + problems
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

    /// Deeper than this, a directory under the home is left out (named in `problems`).
    static let maxDepth = 64

    /// The backup set: regular files under the home, honouring `excluded`, walked by descriptor (`HomeFiles`): a link is
    /// never followed, a directory that moved while it was walked is left out (named in `problems`), and a name no manifest
    /// may hold (`pathProblem`) is left out and named. `visit` gets the file's open directory, its name there, its path
    /// relative to the home and its `fstatat` status.
    private static func walkHome(_ dir: HomeFiles.Directory, prefix: String, depth: Int, problems: inout [String],
                                 _ visit: (HomeFiles.Directory, String, String, stat) throws -> Void) throws {
        guard depth < maxDepth else { problems.append("\(prefix): deeper than \(maxDepth) directories; left out"); return }
        for name in try dir.names().sorted() {
            let relative = prefix + name
            if excluded(relative) { continue }
            guard let st = HomeFiles.status(dir, name) else { continue }
            switch st.st_mode & S_IFMT {
            case S_IFDIR:
                if let problem = pathProblem(relative) { problems.append("\(String(reflecting: relative)): \(problem); left out"); continue }
                let child: HomeFiles.Directory
                do { child = try dir.child(name) } catch { problems.append("\(relative)/: \(error); left out"); continue }
                try walkHome(child, prefix: relative + "/", depth: depth + 1, problems: &problems, visit)
            case S_IFREG:
                if let problem = pathProblem(relative) { problems.append("\(String(reflecting: relative)): \(problem); left out"); continue }
                try visit(dir, name, relative, st)
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

    /// A new private copy of an open file at `target` (inside the engine's own staging; `O_EXCL`, never through a link).
    private static func copyFile(from input: Int32, to target: URL) throws {
        let output = open(target.path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else { throw HomeSnapshotError.io("cannot create the copy (errno \(errno))") }
        let ok = HomeFiles.copy(from: input, to: output) && fsync(output) == 0
        let closed = close(output) == 0
        guard ok, closed else { unlink(target.path); throw HomeSnapshotError.io("copy failed (errno \(errno))") }
    }

    /// `copyFile(from:to:)` from a path whose last part is never followed (the exporter's archive copies).
    private static func copyFile(_ source: URL, to target: URL) throws {
        let input = open(source.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard input >= 0 else { throw HomeSnapshotError.io("cannot read (errno \(errno))") }
        defer { close(input) }
        var st = stat()
        guard fstat(input, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { throw HomeSnapshotError.io("not a regular file") }
        try copyFile(from: input, to: target)
    }

    /// FNV-1a 64 of a file, streamed.
    static func fileHash(_ url: URL) throws -> String {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw HomeSnapshotError.io("cannot read \(url.lastPathComponent) (errno \(errno))") }
        defer { close(fd) }
        return try HomeFiles.hash(fd: fd, shown: url.lastPathComponent)
    }

    /// `VACUUM INTO` the SQLite file `name` of a home directory held open by the walk. SQLite needs a path, so it is given the
    /// kernel's path for that directory (every part a real directory when the walk opened it) and the walk checks, before and
    /// after, that the directory is still in place and `name` is still the same regular file (device and inode): a part or
    /// the file swapped for a link while it was copied makes the copy fail, and it is thrown away.
    private static func vacuumCopy(in dir: HomeFiles.Directory, _ name: String, expected: stat, to destination: URL) throws {
        func same() -> Bool {
            guard dir.isInPlace, let now = HomeFiles.status(dir, name) else { return false }
            return now.st_mode & S_IFMT == S_IFREG && now.st_dev == expected.st_dev && now.st_ino == expected.st_ino
        }
        guard same() else { throw HomeSnapshotError.io("moved or replaced while it was copied") }
        try vacuumCopy(URL(fileURLWithPath: dir.real).appending(path: name), to: destination)
        guard same() else {
            unlink(destination.path)
            throw HomeSnapshotError.io("moved or replaced while it was copied")
        }
    }

    /// `VACUUM INTO` a SQLite file that is not ours alone (a company archive), then `integrity_check` on the copy. A file that is
    /// not a database at all is copied as it is.
    static func vacuumCopy(_ source: URL, to destination: URL) throws {
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

    /// Why `relative` (a manifest key) is not a path a snapshot may hold, or nil when it is one: it must be relative, made of
    /// non-empty parts none of which is `.` or `..` (a `..` inside a name, like `a..b.md`, is fine), at most 255 bytes a part,
    /// with no NUL or other control character, and in the backup set (`excluded`).
    public static func pathProblem(_ relative: String) -> String? {
        if relative.isEmpty { return "is empty" }
        if relative.hasPrefix("/") { return "is absolute" }
        if relative.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7f }) { return "holds a control character" }
        for part in relative.split(separator: "/", omittingEmptySubsequences: false) {
            if part.isEmpty { return "has an empty part" }
            if part == "." || part == ".." { return "has a '\(part)' part" }
            if part.utf8.count > 255 { return "has a part longer than 255 bytes" }
        }
        if excluded(relative) { return "is left out of every snapshot" }
        return nil
    }

    private static func parts(_ relative: String) -> (parents: [String], name: String) {
        let parts = relative.split(separator: "/").map(String.init)
        return (Array(parts.dropLast()), parts.last ?? relative)
    }

    /// Checks every manifest path (`pathProblem`) and hashes every file of the snapshot against its manifest, reading the tree
    /// by descriptor (`HomeFiles`); throws on the first problem. Changes nothing.
    @discardableResult
    public static func verify(_ snapshot: HomeSnapshotInfo) throws -> HomeSnapshotManifest {
        let recorded = try manifest(of: snapshot)
        let entries = recorded.files.sorted(by: { $0.key < $1.key })
        for (relative, _) in entries {
            if let problem = pathProblem(relative) {
                throw HomeSnapshotError.damaged("\(String(reflecting: relative)) is not a path a snapshot may hold (\(problem))")
            }
        }
        let tree: HomeFiles.Directory
        do { tree = try HomeFiles.root(snapshot.treeURL) } catch {
            throw HomeSnapshotError.damaged("\(snapshot.name) has no readable tree (\(error))")
        }
        var parents = HomeFiles.Parents(tree, create: false)
        for (relative, entry) in entries {
            let (dirs, name) = parts(relative)
            guard let dir = try? parents.directory(dirs), let hash = try? HomeFiles.hash(dir, name), hash == entry.sha else {
                throw HomeSnapshotError.damaged("\(relative) does not match its recorded hash in \(snapshot.name)")
            }
        }
        return recorded
    }

    /// Puts the home's files back as they were in `snapshot`, holding no lock of its own (`BackupService.restore` calls it with
    /// the engine lock held).
    ///
    /// 1. Every manifest path is checked and every file of the snapshot hashed against its manifest first (`verify`); a problem
    ///    throws and nothing has changed.
    /// 2. Each file in the backup set that is in the home but not in the snapshot, and each one the snapshot replaces, is moved
    ///    to `<home>/.pre-restore-<stamp>/` (never deleted).
    /// 3. The snapshot's files are copied in (a copy, never a link, so the snapshot stays intact) to a staging name and each is
    ///    hashed again before it is renamed into place.
    ///
    /// Every read, write and move goes through `HomeFiles` (descriptors from the resolved home, `O_NOFOLLOW` at every part,
    /// `renameat` between held directories). An entry whose way in the home is not a real directory (a link planted there, or a
    /// file where a directory should be) is refused and named in `refused`; nothing is written or moved through it, and the
    /// other entries are restored.
    public static func restore(_ snapshot: HomeSnapshotInfo, paths: BrahmaPaths, now: Date = Date()) throws -> HomeRestoreResult {
        let recorded = try verify(snapshot)
        let keepName = preRestorePrefix + BackupService.stamp(now)
        let keepURL = paths.home.appending(path: keepName, directoryHint: .isDirectory)
        let home = try HomeFiles.root(paths.home)
        let tree = try HomeFiles.root(snapshot.treeURL)
        var homeParents = HomeFiles.Parents(home, create: true)
        var treeParents = HomeFiles.Parents(tree, create: false)
        var keepRoot: HomeFiles.Directory?
        var keepParents: HomeFiles.Parents?
        var moved = 0, restored = 0
        var refused: [String] = []

        func keepDirectory(_ dirs: [String]) throws -> HomeFiles.Directory {
            if keepParents == nil {
                let root = try HomeFiles.walk(home, [keepName], create: true)
                keepRoot = root
                keepParents = HomeFiles.Parents(root, create: true)
            }
            return try keepParents!.directory(dirs)
        }
        /// Moves `name` (in `dir`, at `relative` in the home) to the same place under the pre-restore directory; no-op when absent.
        func moveAside(_ dir: HomeFiles.Directory, _ name: String, _ relative: String) throws {
            guard HomeFiles.status(dir, name) != nil else { return }
            try HomeFiles.rename(dir, name, to: try keepDirectory(parts(relative).parents), name)
            moved += 1
        }
        func refuse(_ relative: String, _ error: UnsafeEngineFile) { refused.append("\(relative): \(error)") }

        var present: [String] = []
        var ignored: [String] = []
        try walkHome(home, prefix: "", depth: 0, problems: &ignored) { _, _, relative, _ in present.append(relative) }
        for relative in present where recorded.files[relative] == nil {
            let (dirs, name) = parts(relative)
            do {
                let dir = try homeParents.directory(dirs)
                if relative.hasSuffix(".sqlite") { for suffix in ["-wal", "-shm"] { try moveAside(dir, name + suffix, relative + suffix) } }
                try moveAside(dir, name, relative)
            } catch let error as UnsafeEngineFile { refuse(relative, error) }
        }
        for (relative, entry) in recorded.files.sorted(by: { $0.key < $1.key }) {
            let (dirs, name) = parts(relative)
            let dir: HomeFiles.Directory
            do {
                dir = try homeParents.directory(dirs)
                if entry.kind == "sqlite" { for suffix in ["-wal", "-shm"] { try moveAside(dir, name + suffix, relative + suffix) } }
                try moveAside(dir, name, relative)
            } catch let error as UnsafeEngineFile { refuse(relative, error); continue }
            let staging = ".brahma-restoring-\(UUID().uuidString)"
            do {
                let source = try HomeFiles.openRead(try treeParents.directory(dirs), name)
                defer { close(source) }
                try HomeFiles.copy(from: source, toNew: dir, staging)
                guard try HomeFiles.hash(dir, staging) == entry.sha else { throw HomeSnapshotError.damaged("hash mismatch") }
                try HomeFiles.rename(dir, staging, to: dir, name)
            } catch {
                unlinkat(dir.fd, staging, 0)
                throw HomeSnapshotError.damaged("\(relative) did not verify after the copy (\(error))")
            }
            restored += 1
        }
        if moved > 0 || restored > 0 { fsync(home.fd) }
        if keepRoot == nil { _ = try? keepDirectory([]) }
        return HomeRestoreResult(preRestore: keepURL, restored: restored, movedAway: moved, refused: refused)
    }
}
