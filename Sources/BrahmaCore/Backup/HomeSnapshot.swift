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
    static let excludedSuffixes = [".sqlite-wal", ".sqlite-shm", ".sqlite-journal", ".lock"]
    static let preRestorePrefix = ".pre-restore-"

    /// A name as the file system compares it (APFS is case- and normalization-insensitive by default): NFC, case-folded, NFC.
    static func fold(_ name: String) -> String {
        name.precomposedStringWithCanonicalMapping.folding(options: [.caseInsensitive], locale: nil).precomposedStringWithCanonicalMapping
    }

    /// `fold` applied to every part of a relative path.
    static func foldPath(_ relative: String) -> String {
        relative.split(separator: "/", omittingEmptySubsequences: false).map { fold(String($0)) }.joined(separator: "/")
    }

    /// Whether the path (relative to the data home) is left out of the backup set. Compared as the file system compares names
    /// (`fold`): `Brahma.SQLITE`, `RUN/x` or `a.SQLITE-WAL` are left out like their lower-case spellings.
    public static func excluded(_ relative: String) -> Bool {
        let parts = relative.split(separator: "/").map { fold(String($0)) }
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

    /// The manifest's `files` keys exactly as written (read through `NSDictionary`, which compares keys literally).
    static func manifestKeys(of info: HomeSnapshotInfo) throws -> [String] {
        guard let data = try? Data(contentsOf: info.manifestURL),
              let top = try? JSONSerialization.jsonObject(with: data) as? NSDictionary,
              let files = top["files"] as? NSDictionary else {
            throw HomeSnapshotError.damaged("\(info.name) has no readable manifest")
        }
        return files.allKeys.compactMap { ($0 as? NSString).map { String($0) } }
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
        var seen = Set<String>()
        try walkHome(home, prefix: "", depth: 0, problems: &walkProblems) { dir, leaf, relative, st in
            // Two names one file system would take for the same file (case or normalization only): the second is left out, so
            // the manifest never holds keys a restore must refuse.
            guard seen.insert(foldPath(relative)).inserted else {
                problems.append("\(String(reflecting: relative)): another file differs from it only in case or Unicode normalization; left out")
                return
            }
            let target = tree.appending(path: relative)
            let isSQLite = fold(leaf).hasSuffix(".sqlite")
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
                    try sqliteCopy(in: dir, leaf, relative: relative, expected: st, tmpDir: paths.tmpDir, to: temp)
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

    static func modificationNs(_ st: stat) -> Int64 {
        #if canImport(Darwin)
        Int64(st.st_mtimespec.tv_sec) * 1_000_000_000 + Int64(st.st_mtimespec.tv_nsec)
        #else
        Int64(st.st_mtim.tv_sec) * 1_000_000_000 + Int64(st.st_mtim.tv_nsec)
        #endif
    }

    /// A new private copy of an open file at `target` (inside the engine's own staging; `O_EXCL`, never through a link).
    static func copyFile(from input: Int32, to target: URL) throws {
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

    /// Tests only: called with the file's relative path just before `sqliteCopy` opens it (a seam to swap a part for a link).
    @TaskLocal static var sqliteCopyProbe: (@Sendable (String) -> Void)?

    /// A consistent, checked copy at `destination` of the SQLite file `name` in a directory held open by a descriptor walk
    /// (the data home's, or the exporter's). SQLite is never pointed at the original path:
    /// 1. The file (and its `-wal`, when there is one) is opened relative to the held directory with `O_NOFOLLOW` (a link at
    ///    the leaf is refused) and must be the regular file the walk saw (`expected`: device and inode).
    /// 2. Both are copied by descriptor into a private directory under `tmpDir` (0700; the `-shm` is not copied, SQLite
    ///    rebuilds it from the `-wal`).
    /// 3. Afterwards the directory must still be in place and both names still the same files; a size or modification-time
    ///    change during the copy (a live writer) starts the copy over, at most three times.
    /// 4. Only then is the private copy opened by SQLite: `VACUUM INTO destination` and `integrity_check` (`vacuumCopy`). A
    ///    file that is not a database is copied as it is.
    static func sqliteCopy(in dir: HomeFiles.Directory, _ name: String, relative: String, expected: stat, tmpDir: URL,
                           to destination: URL) throws {
        sqliteCopyProbe?(relative)
        func same(_ a: stat, _ b: stat) -> Bool { a.st_dev == b.st_dev && a.st_ino == b.st_ino }
        func unchanged(_ a: stat, _ b: stat) -> Bool { a.st_size == b.st_size && modificationNs(a) == modificationNs(b) }
        let staging = tmpDir.appending(path: "sqlite-\(UUID().uuidString)", directoryHint: .isDirectory)
        try BrahmaPaths.ensurePrivateDirectory(staging)
        defer { try? FileManager.default.removeItem(at: staging) }
        let stage = try HomeFiles.root(staging, create: false)
        let copy = "db.sqlite"
        var attempt = 0
        while true {
            attempt += 1
            guard dir.isInPlace else { throw HomeSnapshotError.io("moved while it was copied") }
            let main = try HomeFiles.openRead(dir, name)
            defer { close(main) }
            var opened = stat()
            guard fstat(main, &opened) == 0, same(opened, expected) else { throw HomeSnapshotError.io("replaced while it was copied") }
            var wal: Int32?
            if let st = HomeFiles.status(dir, name + "-wal"), st.st_mode & S_IFMT == S_IFREG { wal = try HomeFiles.openRead(dir, name + "-wal") }
            defer { if let wal { close(wal) } }
            var walOpened = stat()
            if let wal { fstat(wal, &walOpened) }
            unlinkat(stage.fd, copy, 0)
            unlinkat(stage.fd, copy + "-wal", 0)
            try HomeFiles.copy(from: main, toNew: stage, copy)
            if let wal { try HomeFiles.copy(from: wal, toNew: stage, copy + "-wal") }
            var mainAfter = stat(), walAfter = stat()
            fstat(main, &mainAfter)
            if let wal { fstat(wal, &walAfter) }
            guard dir.isInPlace, let named = HomeFiles.status(dir, name), same(named, opened) else {
                throw HomeSnapshotError.io("moved or replaced while it was copied")
            }
            var quiet = unchanged(mainAfter, opened)
            if wal != nil {
                let namedWal = HomeFiles.status(dir, name + "-wal")
                quiet = quiet && namedWal.map { same($0, walOpened) } == true && unchanged(walAfter, walOpened)
            }
            if quiet { break }
            guard attempt < 3 else { throw HomeSnapshotError.io("kept changing while it was copied") }
        }
        try vacuumCopy(staging.appending(path: copy), to: destination)
    }

    /// `VACUUM INTO` a private copy of a SQLite file (`sqliteCopy` made it; nothing else opens it), then `integrity_check` on
    /// the result. A file that is not a database at all is copied as it is.
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
        // The keys exactly as written (a Swift dictionary would merge NFC and NFD spellings): each must be a valid path, and no
        // two may name one file once case and normalization are ignored.
        var seen: [String: String] = [:]
        for relative in try manifestKeys(of: snapshot) {
            if let problem = pathProblem(relative) {
                throw HomeSnapshotError.damaged("\(String(reflecting: relative)) is not a path a snapshot may hold (\(problem))")
            }
            let folded = foldPath(relative)
            if let other = seen[folded] {
                throw HomeSnapshotError.damaged("\(String(reflecting: relative)) is not a path a snapshot may hold (it names the same "
                    + "file as \(String(reflecting: other)) once case and Unicode normalization are ignored)")
            }
            seen[folded] = relative
        }
        let recorded = try manifest(of: snapshot)
        let entries = recorded.files.sorted(by: { $0.key < $1.key })
        let tree: HomeFiles.Directory
        do { tree = try HomeFiles.root(snapshot.treeURL, create: false) } catch {
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
        let tree = try HomeFiles.root(snapshot.treeURL, create: false)
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
        let recordedFolded = Set(recorded.files.keys.map(foldPath))
        for relative in present where !recordedFolded.contains(foldPath(relative)) {
            let (dirs, name) = parts(relative)
            do {
                let dir = try homeParents.directory(dirs)
                if fold(name).hasSuffix(".sqlite") { for suffix in ["-wal", "-shm"] { try moveAside(dir, name + suffix, relative + suffix) } }
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
