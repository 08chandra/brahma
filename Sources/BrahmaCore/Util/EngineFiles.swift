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
/// conflict briefs, plan directories, check snapshots). Every directory on the way is a real directory inside the resolved
/// workspace (created one part at a time, never through a link); files are opened relative to that directory with
/// `O_NOFOLLOW`. A new file is created with `O_EXCL`; a rewrite goes to a temporary file that is renamed over the target, so a
/// link planted at the target is replaced, never followed. Reads are capped.
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

    /// Removes `name` (a file, a link or a whole directory, never what a link points at) from the directory.
    public static func remove(workspace: URL, dir relative: String, name: String) throws {
        let dfd = try openDirectory(workspace: workspace, relative)
        defer { close(dfd) }
        let shown = logical(workspace, relative).appending(path: name).path
        try checkName(name, shown)
        var st = stat()
        guard fstatat(dfd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 else { return }
        if st.st_mode & S_IFMT == S_IFDIR {
            // The directory is reached through the real path of the checked directory, so no link is followed on the way.
            guard let real = path(of: dfd) else { throw UnsafeEngineFile(path: shown, problem: "cannot be removed") }
            try FileManager.default.removeItem(atPath: real + "/" + name)
        } else if unlinkat(dfd, name, 0) != 0 {
            throw UnsafeEngineFile(path: shown, problem: "cannot be removed (\(String(cString: strerror(errno))))")
        }
    }

    /// At most `limit` bytes of the regular, single-link file at `url`, opened without following a link; nil otherwise.
    public static func readNoFollow(_ url: URL, limit: Int = defaultReadLimit) -> Data? {
        let fd = open(url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_nlink == 1 else { return nil }
        return try? readAll(fd: fd, limit: limit, shown: url.path)
    }

    // MARK: Internals

    private static func logical(_ workspace: URL, _ relative: String) -> URL {
        workspace.appending(path: relative, directoryHint: .isDirectory)
    }

    private static func checkName(_ name: String, _ shown: String) throws {
        guard !name.isEmpty, name != ".", name != "..", !name.contains("/"), !name.contains("\0") else {
            throw UnsafeEngineFile(path: shown, problem: "is not a valid file name")
        }
    }

    /// The directory, opened: the workspace resolved (it may sit behind a link the owner chose), every part under it a real
    /// directory, created when missing; the opened directory must still be inside the resolved workspace.
    private static func openDirectory(workspace: URL, _ relative: String) throws -> Int32 {
        let fm = FileManager.default
        if !fm.fileExists(atPath: workspace.path) { try fm.createDirectory(at: workspace, withIntermediateDirectories: true) }
        guard let root = resolved(workspace.path) else {
            throw UnsafeEngineFile(path: workspace.path, problem: "cannot be resolved")
        }
        let rootPath = root
        let parts = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        var current = rootPath
        var shown = workspace
        for part in parts {
            shown = shown.appending(path: part, directoryHint: .isDirectory)
            guard part != ".", part != "..", !part.contains("\0") else {
                throw UnsafeEngineFile(path: shown.path, problem: "is not a valid directory name")
            }
            let next = current + "/" + part
            var st = stat()
            if lstat(next, &st) != 0 {
                guard errno == ENOENT else { throw UnsafeEngineFile(path: shown.path, problem: "cannot be inspected") }
                if mkdir(next, 0o755) != 0, errno != EEXIST {
                    throw UnsafeEngineFile(path: shown.path, problem: "cannot be created (\(String(cString: strerror(errno))))")
                }
                guard lstat(next, &st) == 0 else { throw UnsafeEngineFile(path: shown.path, problem: "cannot be created") }
            }
            switch st.st_mode & S_IFMT {
            case S_IFDIR: current = next
            case S_IFLNK: throw UnsafeEngineFile(path: shown.path, problem: "is a symbolic link, not a real directory")
            default: throw UnsafeEngineFile(path: shown.path, problem: "is not a directory")
            }
        }
        let fd = open(current, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else {
            throw UnsafeEngineFile(path: shown.path, problem: "cannot be opened as a real directory")
        }
        // A part swapped for a link between the walk and the open is caught here: the opened directory must be where it was.
        guard let opened = path(of: fd), opened == rootPath || opened.hasPrefix(rootPath + "/"),
              opened.lowercased() == current.lowercased() else {
            close(fd)
            throw UnsafeEngineFile(path: shown.path, problem: "moved outside the workspace while it was opened")
        }
        return fd
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
