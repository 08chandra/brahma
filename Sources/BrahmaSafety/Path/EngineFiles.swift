import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Something in the way of an engine file under `<workspace>/.brahma/`: a link, or not a regular file or directory. Agents can
/// write `.brahma/`, so the engine never writes or reads through what it finds there.
public struct UnsafeEngineFile: Error, Equatable, CustomStringConvertible, Sendable {
    public let path: String
    public let problem: String

    public init(path: String, problem: String) { self.path = path; self.problem = problem }

    public var description: String { "\(path) \(problem)" }
}

/// The one way the engine writes and reads its own files under `<workspace>/.brahma/` (notes, progress files, hand-offs,
/// conflict briefs, plan directories, check snapshots, the item and check checkouts' places). Every directory on the way is a
/// real directory inside the resolved workspace, opened one part at a time relative to the one before with `O_NOFOLLOW` (and
/// created with `mkdirat` when missing), never through a link; files are opened relative to that directory with
/// `O_NOFOLLOW`. A new file is created with `O_EXCL`; a rewrite goes to a temporary file that is renamed over the target, so a
/// link planted at the target is replaced, never followed. Reads are capped, and return only a file that passes
/// `copyProblem` on its open descriptor (regular, a single link, this user's: S7), so the engine never copies the bytes of
/// an owner file an agent hard-linked into a place it can write. Removal works on descriptors only
/// (`removeEntry`): no path is ever rebuilt, so nothing outside the workspace can be removed through a swapped link.
public enum EngineFiles {
    public static let defaultReadLimit = 1 << 20

    /// What sits at a name in an engine directory.
    public enum Entry: Equatable, Sendable {
        case missing
        case regular
        case unsafe(UnsafeEngineFile)
    }

    // MARK: Sizes

    /// A tree `treeBytes` could not measure: `path` is a directory still there that could not be listed.
    public struct Unmeasurable: Error, Equatable, Sendable {
        public let path: String
        public init(path: String) { self.path = path }
    }

    /// The bytes of every entry under `root` (`lstat` sizes; a link counts as itself and is never followed, nothing is opened
    /// or read), summed until the total passes `stopAbove`. A directory that vanishes counts as what was seen of it; one that
    /// is still there but cannot be listed throws `Unmeasurable` naming it (fail closed, spec §6.7; S4 fix round 1, M2: its own
    /// refusal, never "over the size cap"). For the import's size cap (Plan L Task 14): the engine's own fresh repository,
    /// while git fills it.
    public static func treeBytes(_ root: URL, stopAbove: Int64 = .max) throws -> Int64 {
        var total: Int64 = 0
        var pending = [root.path]
        while let dir = pending.popLast() {
            var st = stat()
            guard lstat(dir, &st) == 0 else { continue }
            total += Int64(st.st_size)
            guard st.st_mode & S_IFMT == S_IFDIR else { continue }
            let names: [String]
            do { names = try FileManager.default.contentsOfDirectory(atPath: dir) } catch {
                // Gone meanwhile (git renames its temporary directories): what was seen. Still a directory: unmeasurable.
                guard lstat(dir, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { continue }
                throw Unmeasurable(path: dir)
            }
            for name in names {
                let path = dir + "/" + name
                guard lstat(path, &st) == 0 else { continue }
                if st.st_mode & S_IFMT == S_IFDIR { pending.append(path) } else { total += Int64(st.st_size) }
                if total > stopAbove { return total }
            }
        }
        return total
    }

    // MARK: Directories

    /// `<workspace>/<relative>` (such as `.brahma/notes`) as a real directory; missing parts are created. Throws
    /// `UnsafeEngineFile` when a part is a link or not a directory. Returns the path as the caller names it (not resolved).
    @discardableResult
    public static func directory(workspace: URL, _ relative: String) throws -> URL {
        let fd = try openDirectory(workspace: workspace, relative)
        close(fd)
        return logical(workspace, relative)
    }

    /// As `directory(workspace:_:)`, then sets the directory's own mode (through its descriptor, never a path) to `mode`.
    /// Parts created on the way keep the default mode.
    @discardableResult
    public static func directory(workspace: URL, _ relative: String, mode: mode_t) throws -> URL {
        let fd = try openDirectory(workspace: workspace, relative)
        defer { close(fd) }
        guard fchmod(fd, mode) == 0 else {
            throw UnsafeEngineFile(path: logical(workspace, relative).path, problem: "cannot be given mode \(String(mode, radix: 8)) (\(String(cString: strerror(errno))))")
        }
        return logical(workspace, relative)
    }

    // MARK: Files

    /// What is at `name` in the directory (which is created when missing): `.regular` only for a file that passes
    /// `copyProblem` (a single link, this user's); anything else is `.unsafe`, to be replaced, never read.
    public static func entry(workspace: URL, dir relative: String, name: String) throws -> Entry {
        let fd = try openDirectory(workspace: workspace, relative)
        defer { close(fd) }
        return try entry(fd: fd, name: name, shown: logical(workspace, relative).appending(path: name).path)
    }

    /// What keeps the bytes of an opened file from being handed to anything the engine writes (a rewrite, a copy, a prompt):
    /// nil only for a regular file with a single link that this user owns. Anything else is treated like a link and never
    /// copied: a second hard link may be an owner secret an agent linked into a place it can write (S7, confused deputy), and
    /// a file of another user is not the engine's to pass on.
    public static func copyProblem(_ st: stat) -> String? {
        guard st.st_mode & S_IFMT == S_IFREG else { return "is not a regular file" }
        guard st.st_nlink == 1 else { return "has another hard link" }
        guard st.st_uid == getuid() else { return "is owned by another user (uid \(st.st_uid))" }
        return nil
    }

    /// At most `limit` bytes of `name`; nil when it does not exist. Throws `UnsafeEngineFile` when it is a link, or fails
    /// `copyProblem` (not a regular file, another hard link, another owner) on the opened descriptor, or a read fails part-way
    /// (never a truncated result).
    /// `problem` replaces `copyProblem` as the check on the opened descriptor (a stricter one, such as the canary probe file's
    /// exact mode).
    public static func read(workspace: URL, dir relative: String, name: String, limit: Int = defaultReadLimit,
                            problem: (stat) -> String? = copyProblem) throws -> Data? {
        let dfd = try openDirectory(workspace: workspace, relative)
        defer { close(dfd) }
        let shown = logical(workspace, relative).appending(path: name).path
        try checkName(name, shown)
        let fd = openat(dfd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        if fd < 0 {
            let err = errno
            if err == ENOENT { return nil }
            if err == ELOOP { throw UnsafeEngineFile(path: shown, problem: "is a symbolic link") }
            throw UnsafeEngineFile(path: shown, problem: "cannot be opened (\(String(cString: strerror(err))))")
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw UnsafeEngineFile(path: shown, problem: "cannot be read") }
        if let found = problem(st) { throw UnsafeEngineFile(path: shown, problem: found) }
        return try readAll(fd: fd, limit: limit, shown: shown)
    }

    /// Creates `name` with `data`; false when the name is taken (by anything, a link included, which is never followed).
    public static func create(_ data: Data, workspace: URL, dir relative: String, name: String, mode: mode_t = 0o644) throws -> Bool {
        let dfd = try openDirectory(workspace: workspace, relative)
        defer { close(dfd) }
        let shown = logical(workspace, relative).appending(path: name).path
        return try create(data, dfd: dfd, name: name, shown: shown, mode: mode)
    }

    /// Creates `<base>.<ext>`, else `<base>-2.<ext>`, `<base>-3.<ext>` …, and returns its path and every link or odd file found
    /// on the names it skipped (the engine alerts on those; they are left alone).
    public static func createUnique(_ data: Data, workspace: URL, dir relative: String, base: String,
                                    ext: String) throws -> (url: URL, skipped: [UnsafeEngineFile]) {
        let dfd = try openDirectory(workspace: workspace, relative)
        defer { close(dfd) }
        let dirURL = logical(workspace, relative)
        var skipped: [UnsafeEngineFile] = []
        for n in 1...1000 {
            let name = n == 1 ? "\(base).\(ext)" : "\(base)-\(n).\(ext)"
            let shown = dirURL.appending(path: name).path
            if try create(data, dfd: dfd, name: name, shown: shown) { return (dirURL.appending(path: name), skipped) }
            if case .unsafe(let problem) = try entry(fd: dfd, name: name, shown: shown) { skipped.append(problem) }
        }
        throw UnsafeEngineFile(path: dirURL.appending(path: "\(base).\(ext)").path, problem: "has no free name left")
    }

    /// Writes `data` to `name` atomically (a temporary file renamed over it). Returns the problem when what it replaced was a
    /// link or not a regular file: that thing is gone and was never followed. Throws when the target is a directory.
    @discardableResult
    public static func replace(_ data: Data, workspace: URL, dir relative: String, name: String,
                               mode: mode_t = 0o644) throws -> UnsafeEngineFile? {
        let dfd = try openDirectory(workspace: workspace, relative)
        defer { close(dfd) }
        let shown = logical(workspace, relative).appending(path: name).path
        let before = try entry(fd: dfd, name: name, shown: shown)
        let temp = ".\(name).tmp-\(UUID().uuidString)"
        guard try create(data, dfd: dfd, name: temp, shown: shown, mode: mode) else {
            throw UnsafeEngineFile(path: shown, problem: "cannot be written (its temporary file exists)")
        }
        guard renameat(dfd, temp, dfd, name) == 0 else {
            let err = errno
            unlinkat(dfd, temp, 0)
            if err == EISDIR || err == ENOTEMPTY || err == EEXIST {
                throw UnsafeEngineFile(path: shown, problem: "is a directory, not a file")
            }
            throw UnsafeEngineFile(path: shown, problem: "cannot be written (\(String(cString: strerror(err))))")
        }
        if case .unsafe(let problem) = before { return problem }
        return nil
    }

    /// Removes `name` (a file, a link or a whole directory, never what a link points at) from the directory. Everything is
    /// done relative to descriptors (`removeEntry`): no path is rebuilt, so a part swapped for a link meanwhile is never
    /// followed.
    public static func remove(workspace: URL, dir relative: String, name: String) throws {
        let dfd = try openDirectory(workspace: workspace, relative)
        defer { close(dfd) }
        try removeEntry(dfd: dfd, name: name, shown: logical(workspace, relative).appending(path: name).path)
    }

    // MARK: Removal by descriptor under a root

    /// What `removeNoFollow` came to.
    public enum Removal: Equatable, Sendable {
        /// The entry was there and is gone (a link: the link itself).
        case removed
        /// Nothing was there (or a directory on the way does not exist).
        case missing
        /// A part on the way is a link or not a directory: nothing was removed through it.
        case blocked(UnsafeEngineFile)
    }

    /// Removes what is at `url` (a file, a link or a whole directory; never what a link points at), which must lie under
    /// `root`. `root` is resolved (the owner may have put it behind a link) and never created; every directory between it and
    /// `url` is opened relative to the one before with `O_NOFOLLOW`, and the entry itself is removed relative to its parent's
    /// descriptor (`removeEntry`). No path is rebuilt, so nothing outside can be removed through a part swapped for a link.
    /// Throws `UnsafeEngineFile` when the entry is there and cannot be removed, or `url` is not under `root`.
    @discardableResult
    public static func removeNoFollow(_ url: URL, under root: URL) throws -> Removal {
        let base = root.standardizedFileURL.path, target = url.standardizedFileURL.path
        guard target.hasPrefix(base + "/") else { throw UnsafeEngineFile(path: url.path, problem: "is not under \(base)") }
        let parts = target.dropFirst(base.count + 1).split(separator: "/").map { Array(String($0).utf8) }
        return try removeNoFollow(parts: parts, under: root, shown: url.path)
    }

    /// Moves what is at `url` (a file, a link or a whole directory; never what a link points at), which must lie under `root`,
    /// into `<root>/<trash>` as `name`, by descriptor (`renameat` between the two opened directories): nothing is followed,
    /// nothing is lost. The trash directory is created (0700) without following a link.
    @discardableResult
    public static func moveNoFollow(_ url: URL, under root: URL, toDirectory trash: String, name: String) throws -> Removal {
        let base = root.standardizedFileURL.path, target = url.standardizedFileURL.path
        guard target.hasPrefix(base + "/") else { throw UnsafeEngineFile(path: url.path, problem: "is not under \(base)") }
        let parts = target.dropFirst(base.count + 1).split(separator: "/").map { Array(String($0).utf8) }
        guard let last = parts.last, isValidName(last), let entryName = String(bytes: last, encoding: .utf8) else {
            throw UnsafeEngineFile(path: url.path, problem: "is not a valid file name")
        }
        let dfd: Int32
        switch try openWay(root: root, parts.dropLast()[...], shown: url.path) {
        case .missing: return .missing
        case .blocked(let problem, _): return .blocked(problem)
        case .open(let fd): dfd = fd
        }
        defer { close(dfd) }
        let tfd = try openDirectory(workspace: root, trash)
        defer { close(tfd) }
        _ = fchmod(tfd, 0o700)
        try checkName(name, url.path)
        guard renameat(dfd, entryName, tfd, name) == 0 else {
            if errno == ENOENT { return .missing }
            throw UnsafeEngineFile(path: url.path, problem: "cannot be moved aside (\(String(cString: strerror(errno))))")
        }
        return .removed
    }

    /// `removeNoFollow(_:under:)` for a path given as raw bytes relative to `root` (a name git reports need not be UTF-8).
    @discardableResult
    public static func removeNoFollow(relative: [UInt8], under root: URL) throws -> Removal {
        let parts = relative.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: true).map(Array.init)
        let shown = root.path + "/" + String(decoding: relative, as: UTF8.self)
        return try removeNoFollow(parts: parts, under: root, shown: shown)
    }

    private static func removeNoFollow(parts: [[UInt8]], under root: URL, shown: String) throws -> Removal {
        guard let name = parts.last else { throw UnsafeEngineFile(path: shown, problem: "is not a valid file name") }
        let dfd: Int32
        switch try openWay(root: root, parts.dropLast(), shown: shown) {
        case .missing: return .missing
        case .blocked(let problem, _): return .blocked(problem)
        case .open(let fd): dfd = fd
        }
        defer { close(dfd) }
        guard isValidName(name) else { throw UnsafeEngineFile(path: shown, problem: "is not a valid file name") }
        var st = stat()
        let present = withCName(name) { fstatat(dfd, $0, &st, AT_SYMLINK_NOFOLLOW) } == 0
        guard present else {
            if errno == ENOENT { return .missing }
            throw UnsafeEngineFile(path: shown, problem: "cannot be inspected")
        }
        if let text = String(bytes: name, encoding: .utf8), Array(text.utf8) == name {
            try removeEntry(dfd: dfd, name: text, shown: shown)
        } else {
            // A name that is not UTF-8 is only ever a file or a link here (`unlinkat` never removes a directory).
            guard withCName(name, { unlinkat(dfd, $0, 0) }) == 0 || errno == ENOENT else {
                throw UnsafeEngineFile(path: shown, problem: "cannot be removed (\(String(cString: strerror(errno))))")
            }
        }
        return .removed
    }

    /// `blocked` carries the `openat` errno: only ENOTDIR and ELOOP (a file or a link on the way) mean the path is out of
    /// reach; anything else (EACCES, EMFILE, EIO, ...) is a refusal (NB4).
    private enum Way { case open(Int32), missing, blocked(UnsafeEngineFile, errno: Int32) }

    /// `root` resolved and opened, then each of `parts` opened relative to the one before with `O_NOFOLLOW` (never created).
    private static func openWay(root: URL, _ parts: ArraySlice<[UInt8]>, shown: String) throws -> Way {
        guard let real = resolved(root.path) else { return .missing }
        var fd = open(real, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else {
            let err = errno
            return err == ENOENT ? .missing : .blocked(UnsafeEngineFile(path: root.path, problem: "cannot be opened as a directory"), errno: err)
        }
        var reached = root.path
        for part in parts {
            reached += "/" + String(decoding: part, as: UTF8.self)
            guard isValidName(part) else {
                close(fd)
                throw UnsafeEngineFile(path: reached, problem: "is not a valid directory name")
            }
            let next = withCName(part) { openat(fd, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
            if next < 0 {
                let err = errno
                let problem = withCName(part) { openProblem(dfd: fd, String(cString: $0), errno: err) }
                close(fd)
                return err == ENOENT ? .missing : .blocked(UnsafeEngineFile(path: reached, problem: problem), errno: err)
            }
            close(fd)
            fd = next
        }
        return .open(fd)
    }

    private static func isValidName(_ name: [UInt8]) -> Bool {
        !name.isEmpty && name != [0x2e] && name != [0x2e, 0x2e] && !name.contains(UInt8(ascii: "/")) && !name.contains(0)
    }

    private static func withCName<T>(_ name: [UInt8], _ body: (UnsafePointer<CChar>) -> T) -> T {
        (name + [0]).withUnsafeBytes { body($0.baseAddress!.assumingMemoryBound(to: CChar.self)) }
    }

    /// Walks the real directory `relative` under `root` (resolved; every part opened with `O_NOFOLLOW`, never created) and
    /// removes each entry that is not a directory and that `shouldRemove` (given its path relative to that directory and its
    /// `lstat`) approves, with `unlinkat` relative to the descriptor of the directory it was found in. A directory is walked
    /// into only through `openat(O_NOFOLLOW | O_DIRECTORY)` of its name in its parent's descriptor, so one swapped for a link
    /// meanwhile is skipped, never followed; `enter` (given its relative path) may skip one. At most `maxDepth` levels and
    /// `maxEntries` entries in all are looked at. Returns the relative paths removed (nothing when `relative` is missing or a
    /// part of the way to it is a link).
    public static func removeFilesNoFollow(under root: URL, _ relative: String, maxDepth: Int, maxEntries: Int,
                                    enter: (String) -> Bool, shouldRemove: (String, stat) -> Bool) throws -> [String] {
        let parts = relative.split(separator: "/").map { Array(String($0).utf8) }
        guard case .open(let top) = try openWay(root: root, parts[...], shown: root.appending(path: relative).path) else { return [] }
        var removed: [String] = []
        var budget = maxEntries
        func walk(_ fd: Int32, _ prefix: String, depth: Int) {
            guard depth < maxDepth, budget > 0 else { return }
            // Removal only (stale locks): a directory that cannot be listed keeps its files, and nothing is decided on it.
            var names: [String] = []
            bestEffort("listing a directory for files to remove") { names = try entryNames(fd: fd, shown: prefix, limit: budget) }
            budget -= names.count
            for name in names.sorted() {
                let rel = prefix.isEmpty ? name : "\(prefix)/\(name)"
                var st = stat()
                guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { continue }
                if st.st_mode & S_IFMT == S_IFDIR {
                    guard enter(rel) else { continue }
                    let child = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
                    guard child >= 0 else { continue }
                    walk(child, rel, depth: depth + 1)
                    close(child)
                    continue
                }
                guard shouldRemove(rel, st) else { continue }
                // Relative to this directory's descriptor; never a directory (no `AT_REMOVEDIR`).
                if unlinkat(fd, name, 0) == 0 { removed.append(rel) }
            }
        }
        walk(top, "", depth: 0)
        close(top)
        return removed
    }

    /// At most `limit` bytes of the file at `url`, which must lie under `root` and pass `copyProblem` (regular, a single link,
    /// this user's). `root` is resolved (the owner may have put it behind a link); every part of `url` under it is opened
    /// without following a link. Nil otherwise, and on a read error part-way.
    public static func readNoFollow(_ url: URL, under root: URL, limit: Int = defaultReadLimit) -> Data? {
        let base = root.standardizedFileURL.path, target = url.standardizedFileURL.path
        guard target.hasPrefix(base + "/"), let real = resolved(base) else { return nil }
        let parts = target.dropFirst(base.count + 1).split(separator: "/").map(String.init)
        guard let name = parts.last, !parts.contains(where: { $0 == "." || $0 == ".." }) else { return nil }
        var dfd = open(real, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard dfd >= 0 else { return nil }
        defer { close(dfd) }
        for part in parts.dropLast() {
            let next = openat(dfd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard next >= 0 else { return nil }
            close(dfd); dfd = next
        }
        let fd = openat(dfd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, copyProblem(st) == nil else { return nil }
        do {
            return try readAll(fd: fd, limit: limit, shown: url.path)
        } catch {
            // A read error part-way: nil, as every refusal above (never the part that was read).
            return nil
        }
    }

    /// The file `<root>/<relative>` opened with `flags` (plus `O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC`) relative to a descriptor
    /// walk from `root` (resolved; every directory on the way opened with `O_NOFOLLOW`, never created), for an engine file
    /// that a sandboxed process can reach (a preview's log). Nil when the file or a directory on the way does not exist.
    /// Throws `UnsafeEngineFile` when a part of the way is a link or not a directory, the file is a link, or it fails
    /// `copyProblem` (not regular, another hard link, another owner). The caller closes the descriptor.
    public static func openFileNoFollow(under root: URL, _ relative: String, flags: Int32) throws -> Int32? {
        let parts = relative.split(separator: "/").map { Array($0.utf8) }
        guard let name = parts.last, isValidName(name) else {
            throw UnsafeEngineFile(path: root.appending(path: relative).path, problem: "is not a valid file name")
        }
        let dfd: Int32
        switch try openWay(root: root, parts.dropLast(), shown: root.appending(path: relative).path) {
        case .missing: return nil
        case .blocked(let problem, _): throw problem
        case .open(let fd): dfd = fd
        }
        defer { close(dfd) }
        let shown = root.appending(path: relative).path
        let fd = withCName(name) { openat(dfd, $0, flags | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard fd >= 0 else {
            let err = errno
            if err == ENOENT { return nil }
            throw UnsafeEngineFile(path: shown, problem: err == ELOOP ? "is a symbolic link" : "cannot be opened (\(String(cString: strerror(err))))")
        }
        var st = stat()
        guard fstat(fd, &st) == 0 else { close(fd); throw UnsafeEngineFile(path: shown, problem: "cannot be inspected") }
        if let problem = copyProblem(st) { close(fd); throw UnsafeEngineFile(path: shown, problem: problem) }
        return fd
    }

    // MARK: Open directories (engine checkouts)

    /// An engine directory opened by the safe walk and held open, so a caller that must hand its path to another program
    /// (git, tar) can check it is still where the walk found it before and after that program runs.
    public final class OpenDirectory: @unchecked Sendable {
        public let fd: Int32
        /// The kernel's path for it when it was opened.
        public let real: String
        /// The path as the caller names it.
        public let shown: URL

        init(fd: Int32, real: String, shown: URL) { self.fd = fd; self.real = real; self.shown = shown }
        deinit { close(fd) }

        /// True while the directory is still at the path it was opened at (no part of the way to it was moved or swapped):
        /// the kernel's path for the descriptor is unchanged, and the path the caller names (`shown`, the last part not
        /// followed) is this same directory by (device, inode), so a program handed that path reaches this directory.
        public var isInPlace: Bool {
            guard EngineFiles.path(of: fd) == real else { return false }
            var held = stat(), named = stat()
            guard fstat(fd, &held) == 0, lstat(shown.path, &named) == 0 else { return false }
            return held.st_dev == named.st_dev && held.st_ino == named.st_ino
        }

        /// What is at `name` in it, never following a link.
        public func kind(of name: String) -> Kind {
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return errno == ENOENT ? .missing : .other }
            switch st.st_mode & S_IFMT {
            case S_IFDIR: return .directory
            case S_IFLNK: return .link
            default: return .other
            }
        }

        public enum Kind: Equatable, Sendable { case missing, directory, link, other }

        /// The `fstatat(AT_SYMLINK_NOFOLLOW)` of `name` in it (never following a link); nil when it is not there or the name is
        /// not a valid entry name.
        public func status(of name: String) -> stat? {
            guard EngineFiles.isValidName(name) else { return nil }
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return nil }
            return st
        }

        /// The target bytes of the symbolic link `name` in it (`readlinkat`, never followed); nil when it is not a link.
        public func linkTarget(of name: String) -> [UInt8]? {
            guard EngineFiles.isValidName(name) else { return nil }
            var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
            let n = readlinkat(fd, name, &buffer, buffer.count - 1)
            guard n > 0 else { return nil }
            return Array(buffer[0..<Int(n)])
        }

        /// Creates the directory `name` in it (which must not exist) and opens it.
        public func makeDirectory(_ name: String, mode: mode_t = 0o755) throws -> OpenDirectory {
            let shownChild = shown.appending(path: name, directoryHint: .isDirectory)
            try EngineFiles.checkName(name, shownChild.path)
            guard mkdirat(fd, name, mode) == 0 else {
                throw UnsafeEngineFile(path: shownChild.path, problem: "cannot be created (\(String(cString: strerror(errno))))")
            }
            return try child(name)
        }

        /// The real directory `name` in it, opened without following a link.
        public func child(_ name: String) throws -> OpenDirectory {
            let shownChild = shown.appending(path: name, directoryHint: .isDirectory)
            try EngineFiles.checkName(name, shownChild.path)
            let child = try EngineFiles.openChild(fd, name, shown: shownChild)
            guard let path = EngineFiles.path(of: child), path.lowercased() == (real + "/" + name).lowercased() else {
                close(child)
                throw UnsafeEngineFile(path: shownChild.path, problem: "moved while it was opened")
            }
            return OpenDirectory(fd: child, real: path, shown: shownChild)
        }

        /// The `(device, inode)` of the directory itself, from its open descriptor.
        public func identity() throws -> (dev: dev_t, ino: ino_t) {
            var st = stat()
            guard fstat(fd, &st) == 0 else { throw UnsafeEngineFile(path: shown.path, problem: "cannot be inspected") }
            return (st.st_dev, st.st_ino)
        }

        /// The entry `name` directly in it, opened for reading without following a link (`O_RDONLY | O_NOFOLLOW`), with the
        /// `fstat` of that open descriptor, for a caller that judges the descriptor itself and refuses by its own rules
        /// (`SafeFS`: regular, one link, the workspace's device, a size cap). Nothing is read here. Throws `UnsafeEngineFile`
        /// when the name is a link, does not exist or cannot be opened or inspected. The caller closes `fd`.
        public func openEntry(_ name: String) throws -> (fd: Int32, st: stat) {
            let shownEntry = shown.appending(path: name).path
            try EngineFiles.checkName(name, shownEntry)
            let fd = openat(self.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else {
                let err = errno
                if err == ELOOP { throw UnsafeEngineFile(path: shownEntry, problem: "is a symbolic link") }
                if err == ENOENT { throw UnsafeEngineFile(path: shownEntry, problem: "does not exist") }
                throw UnsafeEngineFile(path: shownEntry, problem: "cannot be opened (\(String(cString: strerror(err))))")
            }
            var st = stat()
            guard fstat(fd, &st) == 0 else { close(fd); throw UnsafeEngineFile(path: shownEntry, problem: "cannot be inspected") }
            return (fd, st)
        }

        /// The names in it (without `.` and `..`).
        public func names() throws -> [String] { try EngineFiles.entryNames(fd: fd, shown: shown.path) }

        /// The names in it, stopping right after `limit` names or right after the name that takes their summed UTF-8 bytes
        /// past `byteLimit` (a caller bounding a walk sees the overflow and refuses).
        public func names(limit: Int, byteLimit: Int) throws -> [String] {
            guard let names = DirectoryListing.names(fd: fd, limit: limit, byteLimit: byteLimit) else {
                throw UnsafeEngineFile(path: shown.path, problem: "cannot be listed")
            }
            return names
        }

        /// Removes `name` from it (`EngineFiles.removeEntry`).
        public func remove(_ name: String) throws {
            try EngineFiles.removeEntry(dfd: fd, name: name, shown: shown.appending(path: name).path)
        }
    }

    /// `<workspace>/<relative>` opened as a real directory (created when missing), as `directory(workspace:_:)` walks it.
    public static func openWalked(workspace: URL, _ relative: String) throws -> OpenDirectory {
        let fd = try openDirectory(workspace: workspace, relative)
        guard let real = path(of: fd) else {
            close(fd)
            throw UnsafeEngineFile(path: logical(workspace, relative).path, problem: "cannot be opened as a real directory")
        }
        return OpenDirectory(fd: fd, real: real, shown: logical(workspace, relative))
    }

    // MARK: Staging (engine-fed commits)

    /// What the engine found at a path of a checkout it is about to commit (`GitWorkspace.stage`), reached through
    /// descriptors only: every directory on the way opened `O_NOFOLLOW` relative to the one before, the name itself opened
    /// `O_NOFOLLOW`, and the verdict taken from `fstat` of that open descriptor, never from a look at the path. Whatever the
    /// agent swaps in afterwards, the bytes git gets are the bytes of the file that was checked.
    public enum Staged: Sendable {
        /// Nothing there (or a directory on the way is gone).
        case missing
        /// A regular file that passes `copyProblem`, open for reading; the caller closes `fd`. `executable` is the owner's x bit.
        case file(fd: Int32, size: Int64, executable: Bool)
        /// A symbolic link and its target, as `readlinkat` gives it.
        case link(target: [UInt8])
        /// A directory.
        case directory
        /// The way to it is blocked: a directory on the way is now a file or a link (ENOTDIR, ELOOP, and only those). Nothing
        /// was read; for a commit the path is simply gone (NB4). Any other error on the way is `refused`.
        case unreachable(UnsafeEngineFile)
        /// Anything else, with the reason: a file failing `copyProblem` (another hard link, another owner, not regular), a
        /// name that cannot be opened.
        case refused(UnsafeEngineFile)
    }

    /// Opens `parts` (a path relative to `top`, raw bytes, no `.`/`..`) as `Staged`.
    public static func staged(in top: OpenDirectory, relative parts: [[UInt8]], shown: String) -> Staged {
        guard let name = parts.last, parts.allSatisfy(isValidName) else {
            return .refused(UnsafeEngineFile(path: shown, problem: "is not a valid path"))
        }
        let way = walkWay(from: top.fd, parts.dropLast(), shown: shown)
        let dfd: Int32
        switch way {
        case .missing: return .missing
        case .blocked(let problem, let err):
            // Only a file or a link where a directory was makes the path gone (NB4); a directory the engine cannot open
            // (EACCES after `chmod 000`, EMFILE, EIO, ...) is refused, so its tracked files are kept and the owner told.
            return err == ENOTDIR || err == ELOOP ? .unreachable(problem) : .refused(problem)
        case .open(let fd): dfd = fd
        }
        defer { if dfd != top.fd { close(dfd) } }
        let fd = withCName(name) { openat(dfd, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        if fd < 0 {
            let err = errno
            if err == ENOENT { return .missing }
            if err == ELOOP {
                var buffer = [UInt8](repeating: 0, count: Int(PATH_MAX) + 1)
                let n = withCName(name) { readlinkat(dfd, $0, &buffer, buffer.count - 1) }
                guard n > 0 else { return .refused(UnsafeEngineFile(path: shown, problem: "is a symbolic link that cannot be read")) }
                return .link(target: Array(buffer[0..<Int(n)]))
            }
            return .refused(UnsafeEngineFile(path: shown, problem: "cannot be opened (\(String(cString: strerror(err))))"))
        }
        var st = stat()
        guard fstat(fd, &st) == 0 else {
            close(fd)
            return .refused(UnsafeEngineFile(path: shown, problem: "cannot be inspected"))
        }
        if st.st_mode & S_IFMT == S_IFDIR { close(fd); return .directory }
        if let problem = copyProblem(st) { close(fd); return .refused(UnsafeEngineFile(path: shown, problem: problem)) }
        return .file(fd: fd, size: Int64(st.st_size), executable: st.st_mode & S_IXUSR != 0)
    }

    /// At most `limit` bytes of the regular file at `parts` under `top`, reached as `staged` reaches it and read from its own
    /// descriptor only when it passes `copyProblem`; nil when it does not exist. Throws `UnsafeEngineFile` for every other shape.
    public static func readStaged(in top: OpenDirectory, relative parts: [[UInt8]], limit: Int, shown: String) throws -> Data? {
        switch staged(in: top, relative: parts, shown: shown) {
        case .missing: return nil
        case .file(let fd, _, _):
            defer { close(fd) }
            return try readAll(fd: fd, limit: limit, shown: shown)
        case .link: throw UnsafeEngineFile(path: shown, problem: "is a symbolic link")
        case .directory: throw UnsafeEngineFile(path: shown, problem: "is a directory, not a file")
        case .unreachable(let problem), .refused(let problem): throw problem
        }
    }

    /// What the directory way `parts` under `top` is, walked with `O_NOFOLLOW | O_DIRECTORY` part by part.
    public enum WayKind: Equatable, Sendable { case real, missing, blocked }

    public static func wayKind(in top: OpenDirectory, relative parts: [[UInt8]]) -> WayKind {
        guard parts.allSatisfy(isValidName) else { return .blocked }
        switch walkWay(from: top.fd, parts[...], shown: top.shown.path) {
        case .missing: return .missing
        case .blocked: return .blocked
        case .open(let fd): if fd != top.fd { close(fd) }; return .real
        }
    }

    /// The (device, inode) of `name` directly in `top`, never following a link; nil when it is not there.
    public static func identity(in top: OpenDirectory, name: [UInt8]) -> (dev: dev_t, ino: ino_t)? {
        guard isValidName(name) else { return nil }
        var st = stat()
        guard withCName(name, { fstatat(top.fd, $0, &st, AT_SYMLINK_NOFOLLOW) }) == 0 else { return nil }
        return (st.st_dev, st.st_ino)
    }

    /// Each of `parts` opened `O_NOFOLLOW | O_DIRECTORY` relative to the one before, starting from `from` (which is handed
    /// back untouched when there is nothing to walk; the caller never closes it).
    private static func walkWay(from: Int32, _ parts: ArraySlice<[UInt8]>, shown: String) -> Way {
        var fd = from
        for part in parts {
            let next = withCName(part) { openat(fd, $0, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
            if next < 0 {
                let err = errno
                let problem = withCName(part) { openProblem(dfd: fd, String(cString: $0), errno: err) }
                if fd != from { close(fd) }
                if err == ENOENT { return .missing }
                return .blocked(UnsafeEngineFile(path: shown, problem: "has \(String(decoding: part, as: UTF8.self)) on the way that \(problem)"), errno: err)
            }
            if fd != from { close(fd) }
            fd = next
        }
        return .open(fd)
    }

    /// Tests only: called with the directory's path and the name of each directory entry about to be removed.
    nonisolated(unsafe) static var removalProbe: ((_ parent: String, _ name: String) -> Void)?

    // MARK: Internals

    private static func logical(_ workspace: URL, _ relative: String) -> URL {
        workspace.appending(path: relative, directoryHint: .isDirectory)
    }

    private static func checkName(_ name: String, _ shown: String) throws {
        guard isValidName(name) else { throw UnsafeEngineFile(path: shown, problem: "is not a valid file name") }
    }

    /// A single entry name: not empty, `.` or `..`, without `/` or NUL (what `checkName` accepts).
    fileprivate static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("/") && !name.contains("\0")
    }

    /// The directory, opened: the workspace resolved (it may sit behind a link the owner chose), then every part under it
    /// opened relative to the one before with `O_NOFOLLOW` (created with `mkdirat` when missing), so no link is ever
    /// followed on the way. The opened directory must still be where the walk put it, inside the resolved workspace.
    public static func openDirectory(workspace: URL, _ relative: String) throws -> Int32 {
        let fm = FileManager.default
        if !fm.fileExists(atPath: workspace.path) { try fm.createDirectory(at: workspace, withIntermediateDirectories: true) }
        guard let root = resolved(workspace.path) else {
            throw UnsafeEngineFile(path: workspace.path, problem: "cannot be resolved")
        }
        var fd = open(root, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw UnsafeEngineFile(path: workspace.path, problem: "cannot be opened as a directory") }
        var expected = root
        var shown = workspace
        for part in relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init) {
            shown = shown.appending(path: part, directoryHint: .isDirectory)
            guard part != ".", part != "..", !part.contains("\0") else {
                close(fd)
                throw UnsafeEngineFile(path: shown.path, problem: "is not a valid directory name")
            }
            var next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if next < 0, errno == ENOENT {
                if mkdirat(fd, part, 0o755) != 0, errno != EEXIST {
                    let err = errno
                    close(fd)
                    throw UnsafeEngineFile(path: shown.path, problem: "cannot be created (\(String(cString: strerror(err))))")
                }
                next = openat(fd, part, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            }
            if next < 0 {
                let problem = openProblem(dfd: fd, part, errno: errno)
                close(fd)
                throw UnsafeEngineFile(path: shown.path, problem: problem)
            }
            close(fd)
            fd = next
            expected += "/" + part
        }
        // A part moved while it was walked is caught here: the directory must still be where the walk put it.
        guard let opened = path(of: fd), opened == root || opened.hasPrefix(root + "/"),
              opened.lowercased() == expected.lowercased() else {
            close(fd)
            throw UnsafeEngineFile(path: shown.path, problem: "moved outside the workspace while it was opened")
        }
        return fd
    }

    /// `name` in `dfd` opened as a real directory, never through a link.
    private static func openChild(_ dfd: Int32, _ name: String, shown: URL) throws -> Int32 {
        let fd = openat(dfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { throw UnsafeEngineFile(path: shown.path, problem: openProblem(dfd: dfd, name, errno: errno)) }
        return fd
    }

    private static func openProblem(dfd: Int32, _ name: String, errno err: Int32) -> String {
        var st = stat()
        if err == ELOOP || (fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 && st.st_mode & S_IFMT == S_IFLNK) {
            return "is a symbolic link, not a real directory"
        }
        if err == ENOTDIR { return "is not a directory" }
        if err == ENOENT { return "does not exist" }
        return "cannot be opened as a real directory (\(String(cString: strerror(err))))"
    }

    /// Removes `name` from the directory open at `dfd`, never following a link and never rebuilding a path. A directory is
    /// first renamed to a fresh name in the same directory (so nothing can be put back under its old name while it is
    /// emptied), then opened with `O_NOFOLLOW` and emptied entry by entry relative to its own descriptor, then removed with
    /// `AT_REMOVEDIR`. A link (anywhere in the tree) is unlinked; what it points at is never touched.
    public static func removeEntry(dfd: Int32, name: String, shown: String) throws {
        try checkName(name, shown)
        removalProbe?(path(of: dfd) ?? "", name)
        var st = stat()
        guard fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return }
            throw UnsafeEngineFile(path: shown, problem: "cannot be inspected")
        }
        guard st.st_mode & S_IFMT == S_IFDIR else {
            if unlinkat(dfd, name, 0) != 0, errno != ENOENT {
                throw UnsafeEngineFile(path: shown, problem: "cannot be removed (\(String(cString: strerror(errno))))")
            }
            return
        }
        let temp = ".brahma-removing-\(UUID().uuidString)"
        guard renameat(dfd, name, dfd, temp) == 0 else {
            if errno == ENOENT { return }
            throw UnsafeEngineFile(path: shown, problem: "cannot be removed (\(String(cString: strerror(errno))))")
        }
        try removeTree(dfd: dfd, name: temp, shown: shown, depth: 0)
    }

    private static let maxRemovalDepth = 512

    // MARK: Clearing what must not stay readable

    /// What `clear` came to.
    public enum Clearance: Equatable, Sendable {
        /// Nothing is left (or nothing was there).
        case removed
        /// Something could not be removed, but every regular file left in it is empty.
        case emptied
        /// Something with content is left, or could not be inspected: why.
        case failed(String)
    }

    /// The prefix `removeEntry` gives a directory it is removing: a leftover with it is the remains of a removal that failed.
    static let removingPrefix = ".brahma-removing-"

    /// Removes `name` (when given) from `<workspace>/<relative>` and every leftover of an earlier removal there
    /// (`.brahma-removing-*`). When a removal fails part-way (an agent made a directory unwritable, say), what is left is made
    /// inert and the removal is tried again: through descriptors only, never following a link, each directory of this user
    /// gets its owner's `rwx` back (`fchmodat(AT_SYMLINK_NOFOLLOW)` in its parent, then `fchmod` on the opened directory), and
    /// each regular file with a single link that this user owns is truncated to zero bytes (opened `O_NOFOLLOW`, checked to
    /// be the same file). A file with another hard link or of another user is never written (it may be an owner file): only
    /// its name is removed. Throws `UnsafeEngineFile` when the directory itself cannot be opened safely.
    public static func clear(workspace: URL, dir relative: String, name: String?) throws -> Clearance {
        let dfd = try openDirectory(workspace: workspace, relative)
        defer { close(dfd) }
        let base = logical(workspace, relative)
        if let name {
            try checkName(name, base.appending(path: name).path)
            // A failure here is handled below: what is left (under `name` or a `.brahma-removing-*` name) is cleared, and
            // `residue` decides the clearance.
            bestEffort("removing an entry before clearing it") { try removeEntry(dfd: dfd, name: name, shown: base.appending(path: name).path) }
        }
        var targets: [String] = []
        if let name, exists(dfd, name) { targets.append(name) }
        targets += try entryNames(fd: dfd, shown: base.path).filter { $0.hasPrefix(removingPrefix) }.sorted()
        var worst = Clearance.removed
        for target in targets {
            let shown = base.appending(path: target).path
            // A failed removal is made inert and tried again; `residue` (not the error) says what, if anything, stays readable.
            var gone = false
            bestEffort("removing a leftover") {
                try removeTree(dfd: dfd, name: target, shown: shown, depth: 0)
                gone = !exists(dfd, target)
            }
            if gone { continue }
            makeInert(dfd: dfd, name: target, depth: 0)
            bestEffort("removing a leftover made inert") {
                try removeTree(dfd: dfd, name: target, shown: shown, depth: 0)
                gone = !exists(dfd, target)
            }
            if gone { continue }
            if let why = residue(dfd: dfd, name: target, shown: shown, depth: 0) {
                worst = .failed(why)
            } else if worst == .removed {
                worst = .emptied
            }
        }
        return worst
    }

    private static func exists(_ dfd: Int32, _ name: String) -> Bool {
        var st = stat()
        return fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0
    }

    /// Makes `name` in `dfd` removable and empty: see `clear`. Best effort: what it cannot do, `residue` reports.
    private static func makeInert(dfd: Int32, name: String, depth: Int) {
        guard depth < maxRemovalDepth else { return }
        var st = stat()
        guard fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0, st.st_uid == getuid() else { return }
        switch st.st_mode & S_IFMT {
        case S_IFDIR:
            if st.st_mode & 0o700 != 0o700 { _ = fchmodat(dfd, name, (st.st_mode & 0o7777) | 0o700, AT_SYMLINK_NOFOLLOW) }
            let fd = openat(dfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return }
            defer { close(fd) }
            var opened = stat()
            guard fstat(fd, &opened) == 0, opened.st_dev == st.st_dev, opened.st_ino == st.st_ino else { return }
            if opened.st_mode & 0o700 != 0o700 { _ = fchmod(fd, (opened.st_mode & 0o7777) | 0o700) }
            let names: [String]
            do { names = try entryNames(fd: fd, shown: "") } catch { return }   // `residue` reports it
            for child in names { makeInert(dfd: fd, name: child, depth: depth + 1) }
        case S_IFREG:
            guard st.st_nlink == 1, st.st_size > 0 else { return }
            if st.st_mode & 0o200 == 0 { _ = fchmodat(dfd, name, (st.st_mode & 0o7777) | 0o200, AT_SYMLINK_NOFOLLOW) }
            let fd = openat(dfd, name, O_WRONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return }
            defer { close(fd) }
            var opened = stat()
            guard fstat(fd, &opened) == 0, opened.st_mode & S_IFMT == S_IFREG, opened.st_dev == st.st_dev,
                  opened.st_ino == st.st_ino, opened.st_nlink == 1, opened.st_uid == getuid() else { return }
            _ = ftruncate(fd, 0)
        default:
            return
        }
    }

    /// Why what is left of `name` may still be readable (a regular file with bytes, something that cannot be inspected or
    /// listed), or nil when nothing with content is left.
    private static func residue(dfd: Int32, name: String, shown: String, depth: Int) -> String? {
        var st = stat()
        guard fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return errno == ENOENT ? nil : "\(shown) cannot be inspected" }
        switch st.st_mode & S_IFMT {
        case S_IFREG: return st.st_size > 0 ? "\(shown) still holds \(st.st_size) bytes" : nil
        case S_IFDIR:
            guard depth < maxRemovalDepth else { return "\(shown) is nested too deeply" }
            let fd = openat(dfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            guard fd >= 0 else { return "\(shown) cannot be opened" }
            defer { close(fd) }
            let names: [String]
            do { names = try entryNames(fd: fd, shown: shown) } catch { return "\(shown) cannot be listed" }
            for child in names {
                if let why = residue(dfd: fd, name: child, shown: shown + "/" + child, depth: depth + 1) { return why }
            }
            return nil
        default: return nil
        }
    }

    /// Removes `name` from `dfd`: a real directory is emptied through its own descriptor and then removed; anything else
    /// (a link included) is unlinked.
    private static func removeTree(dfd: Int32, name: String, shown: String, depth: Int) throws {
        guard depth < maxRemovalDepth else { throw UnsafeEngineFile(path: shown, problem: "is nested too deeply to remove") }
        func failure(_ err: Int32) -> UnsafeEngineFile {
            UnsafeEngineFile(path: shown, problem: "cannot be removed (\(String(cString: strerror(err))))")
        }
        for _ in 0..<8 {
            let fd = openat(dfd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
            if fd < 0 {
                let err = errno
                if err == ENOENT { return }
                guard err == ELOOP || err == ENOTDIR else { throw failure(err) }
                // A link or a file: unlinked, never followed. (It may have become a directory again meanwhile: go round.)
                if unlinkat(dfd, name, 0) == 0 || errno == ENOENT { return }
                if errno == EPERM || errno == EISDIR { continue }
                throw failure(errno)
            }
            do {
                defer { close(fd) }
                try emptyDirectory(fd: fd, shown: shown, depth: depth)
            }
            if unlinkat(dfd, name, AT_REMOVEDIR) == 0 || errno == ENOENT { return }
            // Something was added meanwhile, or the name now holds something else: go round.
            if errno == ENOTEMPTY || errno == EEXIST || errno == ENOTDIR { continue }
            throw failure(errno)
        }
        throw UnsafeEngineFile(path: shown, problem: "kept changing while it was removed")
    }

    private static func emptyDirectory(fd: Int32, shown: String, depth: Int) throws {
        for _ in 0..<8 {
            let names = try entryNames(fd: fd, shown: shown)
            if names.isEmpty { return }
            for child in names {
                removalProbe?(path(of: fd) ?? "", child)
                try removeTree(dfd: fd, name: child, shown: shown, depth: depth + 1)
            }
        }
    }

    /// The names in the directory open at `fd` (without `.` and `..`), at most `limit` of them, read through a fresh
    /// descriptor of it.
    private static func entryNames(fd: Int32, shown: String, limit: Int = .max) throws -> [String] {
        guard let names = DirectoryListing.names(fd: fd, limit: limit) else {
            throw UnsafeEngineFile(path: shown, problem: "cannot be listed")
        }
        return names
    }

    private static func resolved(_ path: String) -> String? {
        guard let p = realpath(path, nil) else { return nil }
        defer { free(p) }
        return String(cString: p)
    }

    /// The path the kernel has for an open descriptor.
    private static func path(of fd: Int32) -> String? {
        #if canImport(Darwin)
        var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
        guard fcntl(fd, F_GETPATH, &buffer) == 0 else { return nil }
        return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        #else
        return resolved("/proc/self/fd/\(fd)")
        #endif
    }

    private static func entry(fd: Int32, name: String, shown: String) throws -> Entry {
        try checkName(name, shown)
        var st = stat()
        guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { return .missing }
            throw UnsafeEngineFile(path: shown, problem: "cannot be inspected")
        }
        switch st.st_mode & S_IFMT {
        case S_IFREG: return copyProblem(st).map { .unsafe(UnsafeEngineFile(path: shown, problem: $0)) } ?? .regular
        case S_IFLNK: return .unsafe(UnsafeEngineFile(path: shown, problem: "is a symbolic link"))
        case S_IFDIR: return .unsafe(UnsafeEngineFile(path: shown, problem: "is a directory, not a file"))
        default: return .unsafe(UnsafeEngineFile(path: shown, problem: "is not a regular file"))
        }
    }

    private static func create(_ data: Data, dfd: Int32, name: String, shown: String, mode: mode_t = 0o644) throws -> Bool {
        try checkName(name, shown)
        let fd = openat(dfd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, mode)
        if fd < 0 {
            let err = errno
            if err == EEXIST || err == ELOOP { return false }
            throw UnsafeEngineFile(path: shown, problem: "cannot be created (\(String(cString: strerror(err))))")
        }
        var ok = true
        data.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Foundation.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n <= 0 { if n < 0 && errno == EINTR { continue }; ok = false; break }
                offset += n
            }
        }
        if ok, fsync(fd) != 0 { ok = false }
        close(fd)
        guard ok else {
            unlinkat(dfd, name, 0)
            throw UnsafeEngineFile(path: shown, problem: "cannot be written")
        }
        return true
    }

    private static func readAll(fd: Int32, limit: Int, shown: String) throws -> Data {
        var out = Data()
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while out.count < limit {
            let n = Foundation.read(fd, &buffer, min(buffer.count, limit - out.count))
            if n < 0 { if errno == EINTR { continue }; throw UnsafeEngineFile(path: shown, problem: "cannot be read") }
            if n == 0 { break }
            out.append(contentsOf: buffer[0..<n])
        }
        return out
    }
}
