import Foundation

/// Which repo paths an item claims, and whether two claims collide. Claims are repo-relative paths or globs; an item that
/// declares none claims the whole repo (`"."`), which overlaps everything.
public enum PathOverlap {
    public static let wholeRepo = "."

    /// "./a//b/" → "a/b"; "" and "." → ".".
    public static func normalized(_ path: String) -> String {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).filter { $0 != "." }
        return parts.isEmpty ? wholeRepo : parts.joined(separator: "/")
    }

    /// An item's claimed paths: its check's paths plus its touch paths, normalized; none declared = the whole repo.
    public static func claimed(_ item: WorkItem) -> [String] {
        let all = ((item.checkSpec?.paths ?? []) + item.touchPaths).map(normalized)
        var seen = Set<String>(), out: [String] = []
        for p in all where seen.insert(p).inserted { out.append(p) }
        return out.isEmpty ? [wholeRepo] : out
    }

    private static func hasGlob(_ path: String) -> Bool { path.contains { "*?[".contains($0) } }

    /// The leading components before the first one with a glob character.
    private static func literalPrefix(_ path: String) -> [Substring] {
        var out: [Substring] = []
        for part in path.split(separator: "/") {
            if part.contains(where: { "*?[".contains($0) }) { break }
            out.append(part)
        }
        return out
    }

    private static func isPrefix(_ a: [Substring], of b: [Substring]) -> Bool {
        a.count <= b.count && Array(b.prefix(a.count)) == a
    }

    /// True when one path contains the other (component-wise), or when either has a glob and the literal parts before
    /// the first glob component contain one another. Globs are compared conservatively: "maybe overlaps" counts.
    public static func overlaps(path a: String, _ b: String) -> Bool {
        let (x, y) = (normalized(a), normalized(b))
        if x == wholeRepo || y == wholeRepo { return true }
        let px = hasGlob(x) ? literalPrefix(x) : x.split(separator: "/").map { $0 }
        let py = hasGlob(y) ? literalPrefix(y) : y.split(separator: "/").map { $0 }
        return isPrefix(px, of: py) || isPrefix(py, of: px)
    }

    /// The first path of `theirs` that overlaps any path of `mine` (an empty list means the whole repo).
    public static func firstOverlap(_ mine: [String], _ theirs: [String]) -> String? {
        let a = mine.isEmpty ? [wholeRepo] : mine, b = theirs.isEmpty ? [wholeRepo] : theirs
        return b.first { t in a.contains { overlaps(path: $0, t) } }.map(normalized)
    }

    public static func overlaps(_ mine: [String], _ theirs: [String]) -> Bool { firstOverlap(mine, theirs) != nil }
}
