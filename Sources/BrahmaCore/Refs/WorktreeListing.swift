import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// What the engine finds in a held item worktree, enumerated by descriptors only (`EngineFiles.OpenDirectory`: every
/// directory opened `O_NOFOLLOW` relative to its parent, every entry judged by `fstatat(AT_SYMLINK_NOFOLLOW)`, a link's target
/// read with `readlinkat`), so no path is ever resolved by name and nothing is followed. For `SafeGit.worktreeDiff`, whose
/// phase 1 must not hand git the agent's worktree as a work tree.
///
/// The walk omits nothing git would list: whatever it cannot account for refuses the whole walk (`Refusal`), never a skip,
/// because a path missing here would show as a false deletion or a hidden change.
/// - Listed: regular files (size, owner's x bit) and symbolic links (their target bytes); the names of the regular
///   `.gitignore` files are also kept apart, so the caller can hand git engine-owned copies of their bytes (read through
///   `SafeFS`, never here).
/// - Nothing is pruned by ignore rules: the engine keeps no gitignore parser (one would disagree with git and hide changes),
///   so every directory is walked and git's single `check-ignore` gives the verdict on every untracked path.
/// - Not listed, as git lists none of them: `.git` entries, devices, pipes and sockets, and the directory of a submodule the
///   base records (`gitlinks`; git compares those as gitlinks).
/// - A `.git` entry (any spelling git might take for one) in a directory under which the base tracks paths
///   (`trackedDirectories`, compared case- and normalization-folded; the root included) refuses:
///   `.repositoryInTrackedDirectory`.
/// - A directory the base tracks nothing under whose `.git` is a repository by a check strictly narrower than git's
///   (`isRepository`) is listed as one entry in `repositories` and not walked, as git lists `sub/`; any other `.git` there (a
///   file, a link, an invalid directory) is skipped and the directory walked as usual — git does at least as much, so
///   nothing git lists is ever hidden (at worst more is listed than git would).
/// - Bounds, each a refusal (`.tooLarge`): more than `maxEntries` entries seen, more than `maxPathBytes` bytes of path text
///   kept (every listed path plus one, so the caller's stdin for git and its memory are bounded too), more than `maxDepth`
///   directory levels. A directory that cannot be listed or opened, or an entry that cannot be inspected or read
///   (`EACCES`, `EMFILE`, `EIO`, a directory moved while it was opened), is `.unreadable`.
/// `tick` runs every `tickEvery` entries (the caller's time budget).
struct WorktreeListing {
    enum Kind: Equatable { case file(size: Int, executable: Bool), link(target: Data) }
    struct Entry { let path: String; let kind: Kind }

    /// Why the walk refused. The cases name no path: the caller's error text stays generic.
    enum Refusal: Error, Equatable {
        /// Past `maxEntries`, `maxPathBytes` or `maxDepth`: `entries` seen, `bytes` of path text summed when it stopped.
        case tooLarge(entries: Int, bytes: Int)
        /// A directory could not be listed or opened, or an entry inspected or read.
        case unreadable
        /// A `.git` entry inside a directory under which the base tracks paths.
        case repositoryInTrackedDirectory
    }

    var entries: [Entry] = []
    /// Worktree-relative paths of the regular `.gitignore` files seen.
    var ignoreFiles: [String] = []
    /// Worktree-relative paths of the untracked directories holding a nested repository (listed, not walked).
    var repositories: [String] = []

    static let maxEntries = 100_000
    static let maxDepth = 256
    static let tickEvery = 256

    static func walk(_ root: EngineFiles.OpenDirectory, trackedDirectories: Set<String>, gitlinks: Set<String>, maxEntries: Int = maxEntries,
                     maxPathBytes: Int, maxDepth: Int = maxDepth, tick: () throws -> Void) throws -> WorktreeListing {
        var listing = WorktreeListing()
        var seen = 0, bytes = 0
        // Compared folded (NFC, lower case), as a case- and normalization-insensitive volume or git's precomposing may spell
        // a tracked directory differently from the base: more directories count as tracked (more refusals), never fewer.
        let tracked = Set(trackedDirectories.map(fold))
        func keep(_ rel: String) throws {
            bytes += rel.utf8.count + 1
            if bytes > maxPathBytes { throw Refusal.tooLarge(entries: seen, bytes: bytes) }
        }
        // Depth first with an explicit stack (no recursion: a deep tree must not exhaust a thread's stack); one open
        // directory per level, as before.
        struct Frame { let dir: EngineFiles.OpenDirectory; let prefix: String; let depth: Int; let names: [String]; var next = 0 }
        /// The frame for an opened directory, or nil when it holds a nested repository (listed as one entry, not walked).
        func enter(_ dir: EngineFiles.OpenDirectory, _ prefix: String, depth: Int) throws -> Frame? {
            guard depth <= maxDepth else { throw Refusal.tooLarge(entries: seen, bytes: bytes) }
            let names: [String]
            do { names = try dir.names(limit: maxEntries - seen + 1, byteLimit: maxPathBytes - bytes + 1) } catch { throw Refusal.unreadable }
            let isTracked = prefix.isEmpty || tracked.contains(fold(prefix))
            // The root's own `.git` (the worktree's link to the repository) is the one `.git` expected where paths are tracked.
            if names.contains(where: { isDotGit($0) && !(prefix.isEmpty && $0 == ".git") }) {
                if isTracked { throw Refusal.repositoryInTrackedDirectory }
                if names.contains(".git"), isRepository(dir) {
                    try keep(prefix)
                    listing.repositories.append(prefix)
                    return nil
                }
            }
            return Frame(dir: dir, prefix: prefix, depth: depth, names: names.sorted())
        }
        var stack: [Frame] = []
        if let top = try enter(root, "", depth: 0) { stack.append(top) }
        while var frame = stack.popLast() {
            guard frame.next < frame.names.count else { continue }
            let name = frame.names[frame.next]
            frame.next += 1
            stack.append(frame)
            seen += 1
            if seen > maxEntries { throw Refusal.tooLarge(entries: seen, bytes: bytes) }
            if seen % tickEvery == 0 { try tick() }
            if name == ".git" { continue }                                       // git never lists a `.git` entry
            let dir = frame.dir
            let rel = frame.prefix.isEmpty ? name : "\(frame.prefix)/\(name)"
            try keep(rel)
            guard let st = dir.status(of: name) else { throw Refusal.unreadable }
            switch st.st_mode & S_IFMT {
            case S_IFREG:
                if name == ".gitignore" { listing.ignoreFiles.append(rel) }
                listing.entries.append(Entry(path: rel, kind: .file(size: Int(st.st_size), executable: st.st_mode & S_IXUSR != 0)))
            case S_IFLNK:
                guard let target = dir.linkTarget(of: name) else { throw Refusal.unreadable }
                listing.entries.append(Entry(path: rel, kind: .link(target: Data(target))))
            case S_IFDIR:
                if gitlinks.contains(rel) { continue }                            // a submodule's directory: compared as a gitlink
                let child: EngineFiles.OpenDirectory
                do { child = try dir.child(name) } catch { throw Refusal.unreadable }
                if let next = try enter(child, rel, depth: frame.depth + 1) { stack.append(next) }
            default:
                continue                                                           // devices, pipes, sockets: git lists none
            }
        }
        return listing
    }

    static func fold(_ path: String) -> String { path.precomposedStringWithCanonicalMapping.lowercased() }

    /// `.git` in any ASCII case (a case-insensitive volume and git's `core.ignorecase` take `.GIT` for `.git`).
    static func isDotGit(_ name: String) -> Bool {
        name.utf8.count == 4 && name.utf8.elementsEqual(".git".utf8, by: { ($0 | 0x20) == ($1 | 0x20) })
    }

    /// Whether `dir/.git` is a repository by a check strictly narrower than git's own (`is_git_directory`: `HEAD` a symbolic
    /// ref under `refs/` or an object id; `objects` and `refs` searchable; the common dir from a `commondir` file), so that
    /// whatever passes here git also takes for a nested repository: `.git` a real directory; no `commondir` file; `objects`
    /// and `refs` real, searchable directories; `HEAD` a regular file that starts `ref: refs/` or with 40 lowercase hex digits.
    /// Anything else is not a repository here, and the directory is walked (git lists at most as much).
    static func isRepository(_ dir: EngineFiles.OpenDirectory) -> Bool {
        guard dir.kind(of: ".git") == .directory, let git = try? dir.child(".git") else { return false }
        guard git.kind(of: "commondir") == .missing, git.kind(of: "objects") == .directory, git.kind(of: "refs") == .directory,
              faccessat(git.fd, "objects", X_OK, 0) == 0, faccessat(git.fd, "refs", X_OK, 0) == 0,
              let (fd, st) = try? git.openEntry("HEAD") else { return false }
        defer { close(fd) }
        guard st.st_mode & S_IFMT == S_IFREG else { return false }
        var buffer = [UInt8](repeating: 0, count: 255)
        let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
        guard n > 0 else { return false }
        let head = buffer[0..<n]
        if head.starts(with: Array("ref: refs/".utf8)) { return true }
        return head.count >= 40 && head.prefix(40).allSatisfy { (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }
    }
}
