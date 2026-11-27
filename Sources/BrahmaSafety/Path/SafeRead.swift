import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Why `SafeRead.smallText` refused a file. Every case is a refusal: a caller that maps it to "unreadable" fails closed.
public enum SafeReadError: Error, Equatable, Sendable {
    /// The target is a symbolic link (never followed).
    case linked
    /// The target is not a regular file (a directory, a FIFO, a device, a socket).
    case notRegular
    /// The target has more than one hard link (its bytes may be another file's).
    case multiplyLinked
    /// The target is owned by another user.
    case notOwned
    /// The target is larger than the limit (the limit, in bytes).
    case tooLarge(Int)
    /// The bytes are not strict UTF-8.
    case notUTF8
    /// A component could not be opened or read, or the name is not a valid path (why, for the log).
    case io(String)
}

/// The one bounded no-follow reader for small engine-verified files (spec §6.9 item 2): a worktree's `.git` pointer, an
/// admin directory's `HEAD`, `commondir` and `gitdir`, a ref file. The root is engine-resolved (`realpath`, then opened as a
/// directory); every component under it is opened `O_NOFOLLOW` relative to the one before (`EngineFiles.OpenDirectory`),
/// and the file itself `O_NOFOLLOW | O_NONBLOCK` (a FIFO never hangs). The verdict is taken from `fstat` of that open
/// descriptor, never from a look at the path: regular, a single link, this user's, at most `limit` bytes. At most
/// `limit + 1` bytes are read (so a file that grew past the limit after `fstat` is still refused), and decoded as strict
/// UTF-8.
public enum SafeRead {
    /// The default bound: a pointer file is a line; 4 KiB is generous.
    public static let defaultLimit = 4096

    /// The text of `<root>/<relative>`, or a `SafeReadError`. `relative` is one or more `/`-separated names, none of them
    /// `.` or `..`.
    public static func smallText(_ relative: String, under root: URL, limit: Int = defaultLimit) throws -> String {
        let parts = relative.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let name = parts.last, isValidName(name) else { throw SafeReadError.io("\(relative) is not a valid file name") }
        var dir = try openRoot(root)
        for part in parts.dropLast() {
            do { dir = try dir.child(part) } catch let problem as UnsafeEngineFile { throw SafeReadError.io(problem.description) }
        }
        let fd = name.withCString { openat(dir.fd, $0, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC) }
        guard fd >= 0 else {
            let err = errno
            if err == ELOOP { throw SafeReadError.linked }
            throw SafeReadError.io("\(root.appending(path: relative).path) cannot be opened (\(String(cString: strerror(err))))")
        }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw SafeReadError.io("\(root.appending(path: relative).path) cannot be inspected") }
        guard st.st_mode & S_IFMT == S_IFREG else { throw SafeReadError.notRegular }
        guard st.st_nlink == 1 else { throw SafeReadError.multiplyLinked }
        guard st.st_uid == getuid() else { throw SafeReadError.notOwned }
        guard st.st_size <= limit else { throw SafeReadError.tooLarge(limit) }
        let bytes = try readUpTo(limit + 1, fd: fd, shown: root.appending(path: relative).path)
        guard bytes.count <= limit else { throw SafeReadError.tooLarge(limit) }
        guard let text = String(bytes: bytes, encoding: .utf8) else { throw SafeReadError.notUTF8 }
        return text
    }

    /// The B1 activity line: `subject` (an item key, a surface, a release) ran sandboxed because the engine could not confirm
    /// its author (`reason`: no holder, an unknown agent, a lookup that failed).
    public static func sandboxedNote(subject: String, reason: String) -> String {
        "\(subject) ran sandboxed: the engine could not confirm who wrote it (\(reason))"
    }

    // MARK: Mechanism

    private static func isValidName(_ name: String) -> Bool {
        !name.isEmpty && name != "." && name != ".." && !name.contains("\0")
    }

    /// `root` resolved by the engine and opened as a directory, held as an `OpenDirectory` so each component under it is
    /// opened relative to it and the directory is checked to be where the walk left it.
    private static func openRoot(_ root: URL) throws -> EngineFiles.OpenDirectory {
        guard let resolved = realpath(root.path, nil) else {
            throw SafeReadError.io("\(root.path) cannot be resolved (\(String(cString: strerror(errno))))")
        }
        defer { free(resolved) }
        let real = String(cString: resolved)
        let fd = open(real, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard fd >= 0 else { throw SafeReadError.io("\(root.path) cannot be opened as a directory (\(String(cString: strerror(errno))))") }
        return EngineFiles.OpenDirectory(fd: fd, real: real, shown: root)
    }

    /// At most `count` bytes from `fd`; a read error is a refusal, never a truncated result.
    private static func readUpTo(_ count: Int, fd: Int32, shown: String) throws -> [UInt8] {
        var out: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: count)
        while out.count < count {
            let n = Foundation.read(fd, &buffer, count - out.count)
            if n < 0 {
                if errno == EINTR { continue }
                throw SafeReadError.io("\(shown) cannot be read (\(String(cString: strerror(errno))))")
            }
            if n == 0 { break }
            out.append(contentsOf: buffer[0..<n])
        }
        return out
    }
}
