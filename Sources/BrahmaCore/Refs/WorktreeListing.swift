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
/// Listed: regular files (size, owner's x bit) and symbolic links (their target bytes). Skipped: `.git` entries, directories
/// holding a `.git` entry (a nested repository: never diffed), anything else (devices, pipes, sockets), and directories a
/// `.gitignore` on the way clearly ignores (`GitIgnoreRules`: pruning only, and only while no negation is in force; git's
/// own `check-ignore` gives the verdict on files). `.gitignore` files are listed separately so the caller can hand their bytes
/// to git from engine-owned copies. The walk stops at `maxEntries` entries seen; `tick` runs every `tickEvery` entries (the
/// caller's time budget).
struct WorktreeListing {
    enum Kind: Equatable { case file(size: Int, executable: Bool), link(target: Data) }
    struct Entry { let path: String; let kind: Kind }

    var entries: [Entry] = []
    /// Worktree-relative paths of the regular `.gitignore` files seen (not pruned).
    var ignoreFiles: [String] = []
    /// The walk passed `maxEntries` and stopped: the caller refuses.
    var truncated = false

    static let maxEntries = 100_000
    static let tickEvery = 256

    static func walk(_ root: EngineFiles.OpenDirectory, maxEntries: Int = maxEntries, tick: () throws -> Void) throws -> WorktreeListing {
        var listing = WorktreeListing()
        var seen = 0
        var rules = GitIgnoreRules()
        func visit(_ dir: EngineFiles.OpenDirectory, _ prefix: String, depth: Int) throws {
            guard depth < 256 else { return }
            let names = try dir.names().sorted()
            let ignoreDepth = rules.count
            defer { rules.truncate(to: ignoreDepth) }
            if names.contains(".gitignore"), let st = dir.status(of: ".gitignore"), st.st_mode & S_IFMT == S_IFREG {
                let rel = prefix.isEmpty ? ".gitignore" : "\(prefix)/.gitignore"
                listing.ignoreFiles.append(rel)
                // Read for pruning only, through the same descriptor rules as any file (no link, one link, this user's).
                if st.st_nlink == 1, st.st_uid == getuid(), st.st_size <= 1 << 20, let (fd, _) = try? dir.openEntry(".gitignore") {
                    var data = Data()
                    var buffer = [UInt8](repeating: 0, count: 64 * 1024)
                    while true {
                        let n = buffer.withUnsafeMutableBytes { read(fd, $0.baseAddress, $0.count) }
                        if n <= 0 { break }
                        data.append(contentsOf: buffer[0..<n])
                    }
                    close(fd)
                    rules.push(String(decoding: data, as: UTF8.self), base: prefix)
                }
            }
            for name in names {
                seen += 1
                if seen > maxEntries { listing.truncated = true; return }
                if seen % tickEvery == 0 { try tick() }
                guard name != ".git", let st = dir.status(of: name) else { continue }
                let rel = prefix.isEmpty ? name : "\(prefix)/\(name)"
                switch st.st_mode & S_IFMT {
                case S_IFREG:
                    listing.entries.append(Entry(path: rel, kind: .file(size: Int(st.st_size), executable: st.st_mode & S_IXUSR != 0)))
                case S_IFLNK:
                    guard let target = dir.linkTarget(of: name) else { continue }
                    listing.entries.append(Entry(path: rel, kind: .link(target: Data(target))))
                case S_IFDIR:
                    if rules.prunes(directory: rel) { continue }
                    guard let child = try? dir.child(name) else { continue }      // swapped meanwhile: not walked, never followed
                    if child.kind(of: ".git") != .missing { continue }              // a nested repository
                    try visit(child, rel, depth: depth + 1)
                    if listing.truncated { return }
                default:
                    continue
                }
            }
        }
        try visit(root, "", depth: 0)
        return listing
    }
}

/// The subset of gitignore the walk uses to prune directories: pattern lines of the `.gitignore` files on the way, matched
/// with `fnmatch` (a pattern with a `/` against the path relative to its file's directory, `FNM_PATHNAME` unless it holds
/// `**`; one without a `/` against the entry's name). Conservative: a directory is pruned only when a positive pattern matches
/// it and no negation pattern (`!`) is in force anywhere on the way, since a negation could re-include what is below. Files are
/// never judged here (`git check-ignore` is).
struct GitIgnoreRules {
    private struct Pattern { let text: String; let negated: Bool; let directoryOnly: Bool; let anchored: Bool; let base: String }
    private var patterns: [Pattern] = []
    private var marks: [Int] = []

    var count: Int { marks.count }

    /// Adds the patterns of one `.gitignore` whose directory is `base` (worktree-relative, "" for the root).
    mutating func push(_ text: String, base: String) {
        marks.append(patterns.count)
        for raw in text.split(separator: "\n", omittingEmptySubsequences: false) {
            var line = String(raw)
            while line.hasSuffix(" "), !line.hasSuffix("\\ ") { line.removeLast() }
            guard !line.isEmpty, !line.hasPrefix("#") else { continue }
            var negated = false
            if line.hasPrefix("!") { negated = true; line.removeFirst() }
            if line.hasPrefix("\\") { line.removeFirst() }
            var directoryOnly = false
            if line.hasSuffix("/") { directoryOnly = true; line.removeLast() }
            let anchored = line.contains("/")
            if line.hasPrefix("/") { line.removeFirst() }
            guard !line.isEmpty else { continue }
            patterns.append(Pattern(text: line, negated: negated, directoryOnly: directoryOnly, anchored: anchored, base: base))
        }
    }

    /// Drops the `.gitignore` files pushed after the first `depth` ones.
    mutating func truncate(to depth: Int) {
        guard depth < marks.count else { return }
        patterns.removeSubrange(marks[depth]...)
        marks.removeSubrange(depth...)
    }

    /// Whether `path` (a directory, worktree-relative) is clearly ignored.
    func prunes(directory path: String) -> Bool {
        guard !patterns.contains(where: \.negated) else { return false }
        let name = String(path.split(separator: "/").last ?? "")
        for pattern in patterns.reversed() {
            let subject: String
            if pattern.anchored {
                guard pattern.base.isEmpty || path.hasPrefix(pattern.base + "/") else { continue }
                subject = pattern.base.isEmpty ? path : String(path.dropFirst(pattern.base.count + 1))
            } else {
                subject = name
            }
            let flags = pattern.text.contains("**") ? 0 : (pattern.anchored ? FNM_PATHNAME : 0)
            if fnmatch(pattern.text, subject, flags) == 0 { return true }
        }
        return false
    }
}
