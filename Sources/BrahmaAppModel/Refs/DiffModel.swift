import Foundation

/// One line of a unified diff hunk, with its old and new line numbers.
public struct DiffLine: Equatable, Sendable {
    public enum Kind: Equatable, Sendable { case add, del, ctx }

    public var kind: Kind
    /// The line without its `+`/`-`/space prefix (agent-controlled text: `Text(verbatim:)`, markers for hidden characters).
    public var text: String
    public var oldNo: Int?
    public var newNo: Int?

    public init(kind: Kind, text: String, oldNo: Int?, newNo: Int?) { self.kind = kind; self.text = text; self.oldNo = oldNo; self.newNo = newNo }
}

public struct DiffHunk: Equatable, Sendable {
    /// The `@@ … @@` line as written (agent-controlled).
    public var header: String
    public var lines: [DiffLine]

    public init(header: String, lines: [DiffLine]) { self.header = header; self.lines = lines }
}

public struct DiffFile: Equatable, Sendable {
    public var path: String
    /// Set for a rename.
    public var oldPath: String?
    public var added: Int
    public var removed: Int
    public var hunks: [DiffHunk]

    public init(path: String, oldPath: String? = nil, added: Int = 0, removed: Int = 0, hunks: [DiffHunk] = []) {
        self.path = path; self.oldPath = oldPath; self.added = added; self.removed = removed; self.hunks = hunks
    }
}

/// A unified patch parsed for `DiffView` (collab design §1.3): files, hunks and lines with numbers, the totals, a flag for hidden
/// characters anywhere in it, and whether the parse stopped at `maxLines` hunk lines. There is no second diff engine: the
/// patch comes from C1a's `SafeGit` (`worktreeDiff`, `diff`, `show`).
public struct DiffModel: Equatable, Sendable {
    public static let defaultMaxLines = 5_000

    public var files: [DiffFile]
    public var added: Int
    public var removed: Int
    public var hasHidden: Bool
    public var truncated: Bool

    public init(files: [DiffFile] = [], added: Int = 0, removed: Int = 0, hasHidden: Bool = false, truncated: Bool = false) {
        self.files = files; self.added = added; self.removed = removed; self.hasHidden = hasHidden; self.truncated = truncated
    }

    /// `"+120 −34 · 6 files"` (U+2212 minus).
    public var statLine: String {
        "+\(added) \u{2212}\(removed) · \(files.count) \(files.count == 1 ? "file" : "files")"
    }

    /// Parses `patch` (`git diff` / `git show` output): `diff --git`, `rename from/to`, `---`/`+++`, `@@` hunks, `+`/`-`/` ` lines;
    /// `\ No newline at end of file` and anything else is skipped. At most `maxLines` hunk lines are kept (`truncated`).
    public static func parse(patch: String, maxLines: Int = defaultMaxLines) -> DiffModel {
        var model = DiffModel()
        var file: DiffFile?
        var hunk: DiffHunk?
        var oldNo = 0, newNo = 0
        var kept = 0

        func closeHunk() {
            if let h = hunk { file?.hunks.append(h) }
            hunk = nil
        }
        func closeFile() {
            closeHunk()
            if let f = file {
                model.files.append(f)
                model.added += f.added
                model.removed += f.removed
            }
            file = nil
        }
        func noteHidden(_ s: String) { if !model.hasHidden, InvisibleMarkers.holdsHidden(s) { model.hasHidden = true } }

        for line in CodeHighlighter.splitLines(patch) {
            if line.hasPrefix("diff --git ") {
                closeFile()
                let (a, b) = Self.gitPaths(line)
                file = DiffFile(path: b ?? a ?? "", oldPath: a != nil && a != b ? a : nil)
                noteHidden(line)
                continue
            }
            guard file != nil else { continue }
            if line.hasPrefix("rename from ") {
                file?.oldPath = Self.unquote(String(line.dropFirst("rename from ".count)))
                noteHidden(line)
                continue
            }
            if line.hasPrefix("rename to ") {
                file?.path = Self.unquote(String(line.dropFirst("rename to ".count)))
                noteHidden(line)
                continue
            }
            if line.hasPrefix("--- ") || line.hasPrefix("+++ ") {
                if hunk == nil {
                    // `+++ b/<path>` names the new path (a `/dev/null` keeps the header's).
                    if line.hasPrefix("+++ b/") { file?.path = Self.unquote(String(line.dropFirst("+++ b/".count))) }
                    noteHidden(line)
                    continue
                }
            }
            if line.hasPrefix("@@") {
                closeHunk()
                let (o, n) = Self.hunkStarts(line)
                oldNo = o
                newNo = n
                hunk = DiffHunk(header: line, lines: [])
                noteHidden(line)
                continue
            }
            guard hunk != nil, let first = line.unicodeScalars.first else { continue }
            if kept >= maxLines {
                model.truncated = true
                break
            }
            let text = String(line.unicodeScalars.dropFirst())
            switch first {
            case "+":
                hunk?.lines.append(DiffLine(kind: .add, text: text, oldNo: nil, newNo: newNo))
                newNo += 1
                file?.added += 1
            case "-":
                hunk?.lines.append(DiffLine(kind: .del, text: text, oldNo: oldNo, newNo: nil))
                oldNo += 1
                file?.removed += 1
            case " ":
                hunk?.lines.append(DiffLine(kind: .ctx, text: text, oldNo: oldNo, newNo: newNo))
                oldNo += 1
                newNo += 1
            default:
                // `\ No newline at end of file` and anything unknown.
                continue
            }
            kept += 1
            noteHidden(text)
        }
        closeFile()
        return model
    }

    /// The `a/<old>` and `b/<new>` of a `diff --git` line.
    static func gitPaths(_ line: String) -> (String?, String?) {
        let rest = String(line.dropFirst("diff --git ".count))
        // Quoted paths (`"a/x y" "b/x y"`) or plain (`a/x b/x`).
        if rest.hasPrefix("\"") {
            var parts: [String] = []
            var current = ""
            var inQuote = false
            var escaped = false
            for ch in rest {
                if escaped { current.append(ch); escaped = false; continue }
                if ch == "\\" { escaped = true; continue }
                if ch == "\"" { inQuote.toggle(); if !inQuote { parts.append(current); current = "" }; continue }
                if inQuote { current.append(ch) }
            }
            return (parts.first.map(Self.stripSide), parts.dropFirst().first.map(Self.stripSide))
        }
        let parts = rest.split(separator: " ", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return (parts.first.map(Self.stripSide), nil) }
        return (Self.stripSide(parts[0]), Self.stripSide(parts[1]))
    }

    static func stripSide(_ s: String) -> String {
        if s.hasPrefix("a/") || s.hasPrefix("b/") { return String(s.dropFirst(2)) }
        return s
    }

    static func unquote(_ s: String) -> String {
        guard s.hasPrefix("\""), s.hasSuffix("\""), s.count >= 2 else { return s }
        return String(s.dropFirst().dropLast())
    }

    /// The old and new start lines of an `@@ -a,b +c,d @@` header (1 when it can't be read).
    static func hunkStarts(_ line: String) -> (Int, Int) {
        let parts = line.split(separator: " ")
        var old = 1, new = 1
        for p in parts {
            if p.hasPrefix("-"), let n = Int(p.dropFirst().split(separator: ",").first ?? "") { old = n }
            if p.hasPrefix("+"), let n = Int(p.dropFirst().split(separator: ",").first ?? "") { new = n }
        }
        return (old, new)
    }
}
