import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// What a `Place` is: a real directory, or a real regular file.
public enum PlaceKind: String, Hashable, Sendable {
    case directory, file
}

/// A place an action may name to the sandbox (spec §6.3.1): verified as a real directory or file of the expected kind by an
/// fd-anchored open, and carried as its resolved path. Only `BrahmaSafety` makes one (`verify`, `logical`), so a policy is
/// built only from places the engine checked; `SandboxPolicyFactory.decide` takes nothing else.
public struct Place: Hashable, Sendable {
    public let resolvedPath: String
    public let kind: PlaceKind

    init(resolvedPath: String, kind: PlaceKind) { self.resolvedPath = resolvedPath; self.kind = kind }

    var url: URL { URL(fileURLWithPath: resolvedPath, isDirectory: kind == .directory) }

    /// `url` as a place of `kind`, checked now:
    /// - its path is absolute, carries no character a profile string may not (`SandboxPath.isUnsafe`), has no `.` or `..`
    ///   part, and is already resolved (`SandboxPath.resolve(url.path) == url.path`: no link anywhere on the way);
    /// - it lies at or under `root`, which is resolved by the engine (the owner may keep a workspace behind a link) and opened
    ///   as a directory;
    /// - every part below `root` is opened relative to the one before without following a link (`O_NOFOLLOW`); the place
    ///   itself is judged in its opened parent without following a link: a directory by `fstatat`, a regular file opened
    ///   `O_NONBLOCK` (a FIFO never hangs) and judged by `fstat` of that descriptor;
    /// - the kernel's path of what was opened is `url.path`.
    /// Throws `SandboxError` (`.invalidPath`, `.unsafePathCharacter`, `.linkedPath`) or `UnsafeEngineFile` (a link, a missing
    /// part, the wrong kind); a caller maps any throw to its own refusal.
    public static func verify(_ url: URL, kind: PlaceKind, under root: URL) throws -> Place {
        let path = try checkedPath(url)
        guard SandboxPath.resolve(path) == path else { throw SandboxError.linkedPath(path) }
        let rootPath = SandboxPath.resolve(root.path)
        guard rootPath.hasPrefix("/"), !SandboxPath.isUnsafe(rootPath) else { throw SandboxError.invalidPath(root.path) }
        guard path == rootPath || SandboxPath.isInside(path, rootPath) else {
            throw SandboxError.invalidPath("\(path) is not under \(rootPath)")
        }
        let parts = path == rootPath ? [] : path.dropFirst(rootPath == "/" ? 1 : rootPath.count + 1).split(separator: "/").map(String.init)
        // The root opened as SafeRead opens its engine-resolved roots (`realpath`, then a directory open), then walked.
        var dir = try SafeRead.openRoot(URL(fileURLWithPath: rootPath))
        let opened: String
        switch kind {
        case .directory:
            // Every directory on the way is opened; the place itself is judged by `fstatat` in its opened parent, never
            // following a link (a directory the engine may not open, such as Foundation's `TemporaryItems`, is still a place).
            guard let name = parts.last else { opened = dir.real; break }
            for part in parts.dropLast() { dir = try dir.child(part) }
            guard let st = dir.status(of: name) else { throw UnsafeEngineFile(path: path, problem: "does not exist") }
            guard st.st_mode & S_IFMT == S_IFDIR else {
                throw UnsafeEngineFile(path: path, problem: st.st_mode & S_IFMT == S_IFLNK ? "is a symbolic link" : "is not a directory")
            }
            opened = dir.real + "/" + name
        case .file:
            guard let name = parts.last else { throw UnsafeEngineFile(path: path, problem: "is a directory, not a file") }
            for part in parts.dropLast() { dir = try dir.child(part) }
            let (fd, st) = try dir.openEntry(name)
            defer { close(fd) }
            guard st.st_mode & S_IFMT == S_IFREG else { throw UnsafeEngineFile(path: path, problem: "is not a regular file") }
            guard let real = EngineFiles.path(of: fd) else { throw UnsafeEngineFile(path: path, problem: "cannot be located") }
            opened = real
        }
        guard opened.lowercased() == path.lowercased() else { throw UnsafeEngineFile(path: path, problem: "moved while it was opened") }
        return Place(resolvedPath: path, kind: kind)
    }

    /// `url` with its parent resolved by the engine and the place itself never followed: the parent is resolved
    /// (`SandboxPath.resolve`: `$TMPDIR` behind `/var`, a data home or workspace behind a link the owner chose), then the
    /// place is verified under it (`verify`), so a link at the place itself is refused, as a policy naming it was before
    /// Plan S. For an engine-made place a site named as it is.
    public static func atResolvedParent(_ url: URL, kind: PlaceKind) throws -> Place {
        let path = try checkedPath(url)
        guard path != "/" else { throw SandboxError.invalidPath(path) }
        let parent = SandboxPath.resolve(URL(fileURLWithPath: path).deletingLastPathComponent().path)
        let named = (parent == "/" ? "" : parent) + "/" + URL(fileURLWithPath: path).lastPathComponent
        return try verify(URL(fileURLWithPath: named, isDirectory: kind == .directory), kind: kind, under: URL(fileURLWithPath: parent))
    }

    /// `url` resolved whole (every link on the way followed, the last part included), then verified under its resolved
    /// parent: for a site that named a place by its resolved path before Plan S (`URL.resolvedForSandbox`,
    /// `SandboxPath.resolve`), which now names the same path as a verified place.
    public static func resolved(_ url: URL, kind: PlaceKind) throws -> Place {
        let path = SandboxPath.resolve(try checkedPath(url))
        let parent = URL(fileURLWithPath: path).deletingLastPathComponent()
        return try verify(URL(fileURLWithPath: path, isDirectory: kind == .directory), kind: kind, under: parent)
    }

    /// `url` named logically under `root` (4a fix round 1, I1: a macOS app's data place): an absolute, safe path with no `.`
    /// or `..` part, strictly inside `root`, as a directory, kept as spelled. It is not resolved here: a link at it or on
    /// its way (left by the app's previous run, the one thing that can write there) fails the policy check
    /// (`SandboxPolicyCheck`, run by `decide`) instead of widening the grant to the link's target.
    public static func logical(_ url: URL, under root: Place) throws -> Place {
        let path = try checkedPath(url)
        guard root.kind == .directory, SandboxPath.isInside(path, root.resolvedPath), path != root.resolvedPath else {
            throw SandboxError.invalidPath("\(path) is not inside \(root.resolvedPath)")
        }
        return Place(resolvedPath: path, kind: .directory)
    }

    /// The path of `url`, refused unless absolute, safe and free of `.`/`..` parts.
    private static func checkedPath(_ url: URL) throws -> String {
        var path = url.path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        guard path.hasPrefix("/") else { throw SandboxError.invalidPath(path) }
        if SandboxPath.isUnsafe(path) { throw SandboxError.unsafePathCharacter(path) }
        guard !path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw SandboxError.linkedPath(path) }
        return path
    }
}
