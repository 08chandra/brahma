import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Path resolution and comparison for sandbox scopes. Every path is resolved like realpath(3): links followed (`/tmp`
/// becomes `/private/tmp`), `.` and `..` removed. A path that does not exist (yet) keeps its missing tail, appended to its
/// longest existing resolved parent; a dangling link on the way is followed by its text.
public enum SandboxPath {
    /// `'`, `"`, `\`, every C0 control (NUL, tab, line breaks, ESC …) and DEL: no sandbox profile (SBPL string escapes) or
    /// settings file may carry them. Also `%00`: `URL.path` keeps a NUL percent-encoded.
    public static func isUnsafe(_ path: String) -> Bool {
        path.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7F || $0 == "'" || $0 == "\"" || $0 == "\\" }
            || path.contains("%00")
    }

    /// The resolved form of an absolute path. A relative or unsafe path is returned unchanged (validation refuses it).
    public static func resolve(_ path: String) -> String {
        guard path.hasPrefix("/"), !isUnsafe(path) else { return path }
        var hops = 0
        return resolve(parts: path.split(separator: "/").map(String.init), hops: &hops)
    }

    private static func resolve(parts: [String], hops: inout Int) -> String {
        let joined = "/" + parts.joined(separator: "/")
        if let real = realpathString(joined) { return real }
        guard let last = parts.last else { return "/" }
        let parent = resolve(parts: Array(parts.dropLast()), hops: &hops)
        switch last {
        case ".": return parent
        case "..": return parentOf(parent)
        default: break
        }
        let candidate = parent == "/" ? "/" + last : parent + "/" + last
        // A dangling link: what it names is where a later write would land.
        if hops < 40, let target = readLink(candidate) {
            hops += 1
            let next = target.hasPrefix("/") ? target : (parent == "/" ? "/" : parent + "/") + target
            return resolve(parts: next.split(separator: "/").map(String.init), hops: &hops)
        }
        return candidate
    }

    private static func parentOf(_ path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), path != "/" else { return "/" }
        let up = String(path[..<slash])
        return up.isEmpty ? "/" : up
    }

    private static func realpathString(_ path: String) -> String? {
        guard let r = realpath(path, nil) else { return nil }
        defer { free(r) }
        return String(cString: r)
    }

    private static func readLink(_ path: String) -> String? {
        var st = stat()
        guard lstat(path, &st) == 0, st.st_mode & S_IFMT == S_IFLNK else { return nil }
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let n = readlink(path, &buffer, buffer.count - 1)
        guard n > 0 else { return nil }
        return String(decoding: buffer[0..<n].map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// The first component of `path` below `root` that is a symbolic link (or a `.`/`..` part, or `path` itself when it is
    /// not under `root`); nil when there is none. A missing component ends the walk: what does not exist cannot be a link.
    public static func linkedComponent(_ path: String, under root: String) -> String? {
        guard path != root else { return nil }
        guard path.hasPrefix(root + "/") else { return path }
        var current = root
        for part in path.dropFirst(root.count + 1).split(separator: "/") {
            current += "/" + part
            if part == "." || part == ".." { return current }
            switch kind(current) {
            case .link: return current
            case .missing: return nil
            default: continue
            }
        }
        return nil
    }

    /// Paths compare case-insensitively on Darwin (APFS and HFS+ default): an overlap that differs only in case is still one.
    public static func key(_ path: String) -> String {
        #if canImport(Darwin)
        return path.lowercased()
        #else
        return path
        #endif
    }

    /// `a` is `b` or lies inside it.
    public static func isInside(_ a: String, _ b: String) -> Bool {
        let a = key(a), b = key(b)
        if b == "/" { return a.hasPrefix("/") }
        return a == b || a.hasPrefix(b + "/")
    }

    public static func overlaps(_ a: String, _ b: String) -> Bool { isInside(a, b) || isInside(b, a) }

    /// `~` and `~/…` against `userHome`; an absolute path as is; anything else throws `.invalidPath`.
    public static func expand(_ raw: String, userHome: URL) throws -> URL {
        if isUnsafe(raw) { throw SandboxError.unsafePathCharacter(raw) }
        if raw == "~" { return userHome }
        if raw.hasPrefix("~/") { return userHome.appending(path: String(raw.dropFirst(2))) }
        guard raw.hasPrefix("/") else { throw SandboxError.invalidPath(raw) }
        return URL(fileURLWithPath: raw, isDirectory: false)
    }

    public enum Kind: Sendable { case missing, directory, file, link, other }

    public static func kind(_ path: String) -> Kind {
        var st = stat()
        guard lstat(path, &st) == 0 else { return .missing }
        switch st.st_mode & S_IFMT {
        case S_IFDIR: return .directory
        case S_IFREG: return .file
        case S_IFLNK: return .link
        default: return .other
        }
    }

    // MARK: Aliases and identity

    /// Spellings `realpath` leaves alone that name another place: the Data volume's firmlinked view
    /// (`/System/Volumes/Data/Users/…` is `/Users/…`) and the kernel's alias namespaces. No allowed entry may use one.
    static let aliasPrefixes = ["/System/Volumes", "/.nofollow", "/.resolve", "/.vol"]

    /// The alias prefix `path` is spelled under, if any.
    static func alias(_ path: String) -> String? { aliasPrefixes.first { isInside(path, $0) } }

    /// A file system object: compared by device and inode, two spellings of one directory (a firmlink, an alias namespace)
    /// are the same place.
    public struct Identity: Hashable, Sendable { let dev: UInt64; let ino: UInt64 }

    /// The identity of what `path` names (links followed); nil when it does not exist.
    public static func identity(_ path: String) -> Identity? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return Identity(dev: UInt64(truncatingIfNeeded: st.st_dev), ino: UInt64(truncatingIfNeeded: st.st_ino))
    }

    /// The identities of `/` and of every existing prefix of `path`, `path` itself last (the walk stops at a missing part).
    public static func lineage(_ path: String) -> [Identity] {
        var out: [Identity] = identity("/").map { [$0] } ?? []
        var current = ""
        for part in path.split(separator: "/") {
            current += "/" + part
            guard let id = identity(current) else { break }
            out.append(id)
        }
        return out
    }

    /// Roots compared by identity: whatever spelling a path uses, it overlaps a root when it is the root, lies inside it, or
    /// contains it.
    public struct IdentityRoots {
        private let roots: [(path: String, id: Identity, lineage: Set<Identity>)]

        /// Each root's lineage is built from its resolved path (a root spelled through a link is the place it names). A root
        /// that does not exist (yet) is kept with the lineage of its existing part, so a path that contains where it would
        /// be still overlaps it.
        private let missing: [(path: String, lineage: Set<Identity>)]

        public init(_ urls: [URL]) {
            var seen: Set<Identity> = []
            var kept: [(path: String, id: Identity, lineage: Set<Identity>)] = []
            var absent: [(path: String, lineage: Set<Identity>)] = []
            for url in urls {
                let resolved = SandboxPath.resolve(url.path)
                if let id = SandboxPath.identity(resolved) {
                    if seen.insert(id).inserted { kept.append((url.path, id, Set(SandboxPath.lineage(resolved)))) }
                } else {
                    absent.append((url.path, Set(SandboxPath.lineage(resolved))))
                }
            }
            roots = kept
            missing = absent
        }

        /// The first root `path` equals, lies inside or contains.
        public func overlapping(_ path: String) -> String? {
            let mine = SandboxPath.lineage(path)
            let inside = Set(mine)
            let id = SandboxPath.identity(path)
            if let hit = roots.first(where: { inside.contains($0.id) || (id.map($0.lineage.contains) ?? false) }) { return hit.path }
            // A missing root: `path` contains it when `path` is an existing ancestor of it.
            return id.flatMap { id in missing.first { $0.lineage.contains(id) }?.path }
        }

        /// The first root `path` equals or contains.
        func containedIn(_ path: String) -> String? {
            guard let id = SandboxPath.identity(path) else { return nil }
            return (roots.first { $0.lineage.contains(id) }?.path) ?? (missing.first { $0.lineage.contains(id) }?.path)
        }
    }

    /// An existing directory reached without a symbolic link or an alias spelling: absolute and safe, it resolves to itself,
    /// and an `lstat` walk from `/` finds a real directory at every part. A read-path grant must stay this.
    public static func isPinnedDirectory(_ path: String) -> Bool {
        guard path.hasPrefix("/"), !isUnsafe(path), alias(path) == nil, key(resolve(path)) == key(path) else { return false }
        var current = ""
        for part in path.split(separator: "/") {
            if part == "." || part == ".." { return false }
            current += "/" + part
            guard kind(current) == .directory else { return false }
        }
        return true
    }

    /// The names in a directory (not following a link at `path`), sorted; empty when it is missing or not a real directory.
    public static func entries(_ path: String) -> [String] {
        guard kind(path) == .directory, let names = try? FileManager.default.contentsOfDirectory(atPath: path) else { return [] }
        return names.sorted()
    }
}

extension URL {
    /// This path resolved for a sandbox scope (`SandboxPath.resolve`), as a file URL without a directory hint.
    public var resolvedForSandbox: URL { URL(fileURLWithPath: SandboxPath.resolve(path), isDirectory: false) }

}

extension SandboxPath {
    public static func checkAllowed(_ entry: URL, protected: [URL], deniedRoots: [URL]) throws {
        try checkAllowed(entry, protected: protected, deniedRoots: deniedRoots,
                         byIdentity: (SandboxPath.IdentityRoots(protected), SandboxPath.IdentityRoots(deniedRoots)))
    }

    /// The overlap checks by spelling and by identity (device and inode: a firmlink or alias spelling of a protected place is
    /// that place), and no alias spelling at all (`SandboxPath.aliasPrefixes`). Every allowed entry goes through here: cwd,
    /// writable, readable, read-only, toolchain and grant read paths.
    public static func checkAllowed(_ entry: URL, protected: [URL], deniedRoots: [URL],
                             byIdentity: (protected: SandboxPath.IdentityRoots, denied: SandboxPath.IdentityRoots)) throws {
        if let prefix = SandboxPath.alias(entry.path) { throw SandboxError.aliasSpelling(path: entry.path, alias: prefix) }
        if let hit = protected.first(where: { SandboxPath.overlaps(entry.path, $0.path) }) {
            throw SandboxError.overlapsProtected(path: entry.path, protected: hit.path)
        }
        if let hit = deniedRoots.first(where: { SandboxPath.isInside($0.path, entry.path) }) {
            throw SandboxError.overlapsProtected(path: entry.path, protected: hit.path)
        }
        if let hit = byIdentity.protected.overlapping(entry.path) {
            throw SandboxError.overlapsProtected(path: entry.path, protected: hit)
        }
        if let hit = byIdentity.denied.containedIn(entry.path) {
            throw SandboxError.overlapsProtected(path: entry.path, protected: hit)
        }
    }
}
