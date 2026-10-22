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
/// link planted at the target is replaced, never followed. Reads are capped. Removal works on descriptors only
/// (`removeEntry`): no path is ever rebuilt, so nothing outside the workspace can be removed through a swapped link.
public enum EngineFiles {
    public static let defaultReadLimit = 1 << 20

    /// What sits at a name in an engine directory.
    public enum Entry: Equatable, Sendable {
        case missing
        case regular
        case unsafe(UnsafeEngineFile)
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

    // MARK: Files

    /// What is at `name` in the directory (which is created when missing).
    public static func entry(workspace: URL, dir relative: String, name: String) throws -> Entry {
        let fd = try openDirectory(workspace: workspace, relative)
        defer { close(fd) }
        return try entry(fd: fd, name: name, shown: logical(workspace, relative).appending(path: name).path)
    }

    /// At most `limit` bytes of `name`; nil when it does not exist. Throws `UnsafeEngineFile` when it is a link, not a regular
    /// file, or has another hard link.
    public static func read(workspace: URL, dir relative: String, name: String, limit: Int = defaultReadLimit) throws -> Data? {
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
        guard st.st_mode & S_IFMT == S_IFREG else { throw UnsafeEngineFile(path: shown, problem: "is not a regular file") }
        guard st.st_nlink == 1 else { throw UnsafeEngineFile(path: shown, problem: "has another hard link") }
        return try readAll(fd: fd, limit: limit, shown: shown)
    }

    /// Creates `name` with `data`; false when the name is taken (by anything, a link included, which is never followed).
    public static func create(_ data: Data, workspace: URL, dir relative: String, name: String) throws -> Bool {
        let dfd = try openDirectory(workspace: workspace, relative)
        defer { close(dfd) }
        let shown = logical(workspace, relative).appending(path: name).path
        return try create(data, dfd: dfd, name: name, shown: shown)
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
    public static func replace(_ data: Data, workspace: URL, dir relative: String, name: String) throws -> UnsafeEngineFile? {
        let dfd = try openDirectory(workspace: workspace, relative)
        defer { close(dfd) }
        let shown = logical(workspace, relative).appending(path: name).path
        let before = try entry(fd: dfd, name: name, shown: shown)
        let temp = ".\(name).tmp-\(UUID().uuidString)"
        guard try create(data, dfd: dfd, name: temp, shown: shown) else {
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

    /// At most `limit` bytes of the regular, single-link file at `url`, which must lie under `root`. `root` is resolved (the
    /// owner may have put it behind a link); every part of `url` under it is opened without following a link. Nil otherwise.
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
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1 else { return nil }
        return try? readAll(fd: fd, limit: limit, shown: url.path)
    }

    // MARK: Open directories (engine checkouts)

    /// An engine directory opened by the safe walk and held open, so a caller that must hand its path to another program
    /// (git, tar) can check it is still where the walk found it before and after that program runs.
    final class OpenDirectory: @unchecked Sendable {
        let fd: Int32
        /// The kernel's path for it when it was opened.
        let real: String
        /// The path as the caller names it.
        let shown: URL

        fileprivate init(fd: Int32, real: String, shown: URL) { self.fd = fd; self.real = real; self.shown = shown }
        deinit { close(fd) }

        /// True while the directory is still at the path it was opened at (no part of the way to it was moved or swapped):
        /// the kernel's path for the descriptor is unchanged, and the path the caller names (`shown`, the last part not
        /// followed) is this same directory by (device, inode), so a program handed that path reaches this directory.
        var isInPlace: Bool {
            guard EngineFiles.path(of: fd) == real else { return false }
            var held = stat(), named = stat()
            guard fstat(fd, &held) == 0, lstat(shown.path, &named) == 0 else { return false }
            return held.st_dev == named.st_dev && held.st_ino == named.st_ino
        }

        /// What is at `name` in it, never following a link.
        func kind(of name: String) -> Kind {
            var st = stat()
            guard fstatat(fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return errno == ENOENT ? .missing : .other }
            switch st.st_mode & S_IFMT {
            case S_IFDIR: return .directory
            case S_IFLNK: return .link
            default: return .other
            }
        }

        enum Kind: Equatable { case missing, directory, link, other }

        /// Creates the directory `name` in it (which must not exist) and opens it.
        func makeDirectory(_ name: String, mode: mode_t = 0o755) throws -> OpenDirectory {
            let shownChild = shown.appending(path: name, directoryHint: .isDirectory)
            try EngineFiles.checkName(name, shownChild.path)
            guard mkdirat(fd, name, mode) == 0 else {
                throw UnsafeEngineFile(path: shownChild.path, problem: "cannot be created (\(String(cString: strerror(errno))))")
            }
            return try child(name)
        }

        /// The real directory `name` in it, opened without following a link.
        func child(_ name: String) throws -> OpenDirectory {
            let shownChild = shown.appending(path: name, directoryHint: .isDirectory)
            try EngineFiles.checkName(name, shownChild.path)
            let child = try EngineFiles.openChild(fd, name, shown: shownChild)
            guard let path = EngineFiles.path(of: child), path.lowercased() == (real + "/" + name).lowercased() else {
                close(child)
                throw UnsafeEngineFile(path: shownChild.path, problem: "moved while it was opened")
            }
            return OpenDirectory(fd: child, real: path, shown: shownChild)
        }

        /// The names in it (without `.` and `..`).
        func names() throws -> [String] { try EngineFiles.entryNames(fd: fd, shown: shown.path) }

        /// Removes `name` from it (`EngineFiles.removeEntry`).
        func remove(_ name: String) throws {
            try EngineFiles.removeEntry(dfd: fd, name: name, shown: shown.appending(path: name).path)
        }
    }

    /// `<workspace>/<relative>` opened as a real directory (created when missing), as `directory(workspace:_:)` walks it.
    static func openWalked(workspace: URL, _ relative: String) throws -> OpenDirectory {
        let fd = try openDirectory(workspace: workspace, relative)
        guard let real = path(of: fd) else {
            close(fd)
            throw UnsafeEngineFile(path: logical(workspace, relative).path, problem: "cannot be opened as a real directory")
        }
        return OpenDirectory(fd: fd, real: real, shown: logical(workspace, relative))
    }

    /// Tests only: called with the directory's path and the name of each directory entry about to be removed.
    nonisolated(unsafe) static var removalProbe: ((_ parent: String, _ name: String) -> Void)?

    // MARK: Internals

    private static func logical(_ workspace: URL, _ relative: String) -> URL {
        workspace.appending(path: relative, directoryHint: .isDirectory)
    }

    private static func checkName(_ name: String, _ shown: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw UnsafeEngineFile(path: shown, problem: "is not a valid file name")
        }
    }

    /// The directory, opened: the workspace resolved (it may sit behind a link the owner chose), then every part under it
    /// opened relative to the one before with `O_NOFOLLOW` (created with `mkdirat` when missing), so no link is ever
    /// followed on the way. The opened directory must still be where the walk put it, inside the resolved workspace.
    private static func openDirectory(workspace: URL, _ relative: String) throws -> Int32 {
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
    static func removeEntry(dfd: Int32, name: String, shown: String) throws {
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

    /// The names in the directory open at `fd` (without `.` and `..`), read through a fresh descriptor of it.
    private static func entryNames(fd: Int32, shown: String) throws -> [String] {
        let own = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard own >= 0, let dir = fdopendir(own) else {
            if own >= 0 { close(own) }
            throw UnsafeEngineFile(path: shown, problem: "cannot be listed")
        }
        defer { closedir(dir) }
        var names: [String] = []
        while let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
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
        return String(cString: buffer)
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
        case S_IFREG: return st.st_nlink == 1 ? .regular : .unsafe(UnsafeEngineFile(path: shown, problem: "has another hard link"))
        case S_IFLNK: return .unsafe(UnsafeEngineFile(path: shown, problem: "is a symbolic link"))
        case S_IFDIR: return .unsafe(UnsafeEngineFile(path: shown, problem: "is a directory, not a file"))
        default: return .unsafe(UnsafeEngineFile(path: shown, problem: "is not a regular file"))
        }
    }

    private static func create(_ data: Data, dfd: Int32, name: String, shown: String) throws -> Bool {
        try checkName(name, shown)
        let fd = openat(dfd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o644)
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
