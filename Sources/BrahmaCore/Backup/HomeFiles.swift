import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// File work under the data home (and inside a data-home snapshot's tree) with `EngineFiles`' discipline: the root is
/// resolved once (it may sit behind a link the owner chose), then every directory on the way is opened relative to the one
/// before with `O_NOFOLLOW | O_DIRECTORY` (`EngineFiles.OpenDirectory.child`, which also checks the kernel's path for it, so
/// a part moved while it was walked is caught) and created with `mkdirat` (0700) when missing. Files are opened relative to
/// their directory's descriptor with `O_NOFOLLOW`; a new file is created with `O_EXCL`; a move is a `renameat` between two
/// held descriptors. No path is ever rebuilt and followed, so a link planted anywhere under the home cannot redirect a read
/// or a write outside it: the walk refuses it (`UnsafeEngineFile`, "is a symbolic link, not a real directory").
enum HomeFiles {
    typealias Directory = EngineFiles.OpenDirectory

    /// `url` resolved and opened as a real directory.
    static func root(_ url: URL) throws -> Directory { try EngineFiles.openWalked(workspace: url, "") }

    /// The real directory `parts` under `dir`, one part at a time, never through a link; with `create`, missing parts are made.
    static func walk(_ dir: Directory, _ parts: some Sequence<String>, create: Bool) throws -> Directory {
        var current = dir
        for part in parts {
            if create, current.kind(of: part) == .missing, let made = try? current.makeDirectory(part, mode: 0o700) {
                current = made
            } else {
                current = try current.child(part)
            }
        }
        return current
    }

    /// What is at `name` in `dir`, never following a link.
    static func status(_ dir: Directory, _ name: String) -> stat? {
        var st = stat()
        return fstatat(dir.fd, name, &st, AT_SYMLINK_NOFOLLOW) == 0 ? st : nil
    }

    /// `name` in `dir` opened for reading: never through a link, never blocking on a FIFO, and a regular file.
    static func openRead(_ dir: Directory, _ name: String) throws -> Int32 {
        let shown = dir.shown.appending(path: name).path
        let fd = openat(dir.fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else {
            let err = errno
            throw UnsafeEngineFile(path: shown, problem: err == ELOOP ? "is a symbolic link" : "cannot be read (\(String(cString: strerror(err))))")
        }
        var st = stat()
        guard fstat(fd, &st) == 0, st.st_mode & S_IFMT == S_IFREG else {
            close(fd)
            throw UnsafeEngineFile(path: shown, problem: "is not a regular file")
        }
        return fd
    }

    /// Creates `name` in `dir` (0600, `O_EXCL`, never through a link) with everything readable from `input`, synced.
    static func copy(from input: Int32, toNew dir: Directory, _ name: String) throws {
        let output = openat(dir.fd, name, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard output >= 0 else {
            throw UnsafeEngineFile(path: dir.shown.appending(path: name).path, problem: "cannot be created (\(String(cString: strerror(errno))))")
        }
        let ok = copy(from: input, to: output) && fchmod(output, 0o600) == 0 && fsync(output) == 0
        let closed = close(output) == 0
        guard ok, closed else {
            unlinkat(dir.fd, name, 0)
            throw HomeSnapshotError.io("could not write \(dir.shown.appending(path: name).path) (errno \(errno))")
        }
    }

    /// Copies `input` (from where it is) to `output`. False on a read or write error.
    static func copy(from input: Int32, to output: Int32) -> Bool {
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(input, $0.baseAddress!, $0.count) }
            if n < 0 { if errno == EINTR { continue }; return false }
            if n == 0 { return true }
            var done = 0
            while done < n {
                let w = buffer.withUnsafeBytes { write(output, $0.baseAddress! + done, n - done) }
                if w < 0 { if errno == EINTR { continue }; return false }
                done += w
            }
        }
    }

    /// FNV-1a 64 of `name` in `dir`, read through `openRead`.
    static func hash(_ dir: Directory, _ name: String) throws -> String {
        let fd = try openRead(dir, name)
        defer { close(fd) }
        return try hash(fd: fd, shown: name)
    }

    /// FNV-1a 64 of an open file, from where it is to its end.
    static func hash(fd: Int32, shown: String) throws -> String {
        var hash: UInt64 = 0xcbf29ce484222325
        var buffer = [UInt8](repeating: 0, count: 1 << 20)
        while true {
            let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress!, $0.count) }
            if n < 0 { if errno == EINTR { continue }; throw HomeSnapshotError.io("cannot read \(shown) (errno \(errno))") }
            if n == 0 { break }
            for i in 0..<n { hash ^= UInt64(buffer[i]); hash = hash &* 0x100000001b3 }
        }
        let hex = String(hash, radix: 16)
        return String(repeating: "0", count: 16 - hex.count) + hex
    }

    /// `renameat` of `name` in `from` to `newName` in `to`: the entry itself moves (a link is moved, never followed).
    static func rename(_ from: Directory, _ name: String, to: Directory, _ newName: String) throws {
        guard renameat(from.fd, name, to.fd, newName) == 0 else {
            throw HomeSnapshotError.io("could not move \(from.shown.appending(path: name).path) (errno \(errno))")
        }
    }

    /// Hands out the directory for each relative parent, keeping the last one open: consecutive entries of one directory
    /// (the usual order of a sorted manifest) share a single walk and descriptor, and at most one walk's worth is held.
    struct Parents {
        let root: Directory
        let create: Bool
        private var last: (key: [String], dir: Directory)?

        init(_ root: Directory, create: Bool) { self.root = root; self.create = create }

        mutating func directory(_ parts: [String]) throws -> Directory {
            if let last, last.key == parts { return last.dir }
            let dir = try HomeFiles.walk(root, parts, create: create)
            last = (parts, dir)
            return dir
        }
    }
}
