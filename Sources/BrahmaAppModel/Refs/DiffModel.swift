import Foundation
import BrahmaCore

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
                // C6b I-1: the path exactly as the engine's `ChangesPatch` reads it (C-quoting decoded, a space never a rename).
                file = DiffFile(path: ChangesPatch.pathFromGitLine(line))
                noteHidden(line)
                continue
            }
            guard file != nil else { continue }
            if line.hasPrefix("rename from ") {
                file?.oldPath = Self.gitName(String(line.dropFirst("rename from ".count)))
                noteHidden(line)
                continue
            }
            if line.hasPrefix("rename to ") {
                file?.path = Self.gitName(String(line.dropFirst("rename to ".count)))
                noteHidden(line)
                continue
            }
            if line.hasPrefix("--- ") || line.hasPrefix("+++ ") {
                if hunk == nil {
                    // `+++ b/<path>` names the new path (a `/dev/null` keeps the header's); git's trailing tab after a path with a
                    // space and its C-quoting are the engine's to read (`prefixedPath`).
                    if line.hasPrefix("+++ "), let p = ChangesPatch.prefixedPath(String(line.dropFirst(4)), "b/") { file?.path = p }
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

    /// A `rename from` / `rename to` name as git writes it (possibly C-quoted), read by the engine's rule; a malformed quote keeps
    /// the text as written.
    static func gitName(_ s: String) -> String {
        ChangesPatch.prefixedPath(s, "") ?? s
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

// MARK: - Presentation (Plan C Task C6b)

/// One row of the split view: a deletion beside the addition it pairs with, a context line on both sides, or one side alone.
public struct SplitRow: Equatable, Sendable {
    public var left: DiffLine?
    public var right: DiffLine?
    /// The hunk the row belongs to (the view draws the hunk header above its first row).
    public var hunk: Int

    public init(left: DiffLine?, right: DiffLine?, hunk: Int = 0) { self.left = left; self.right = right; self.hunk = hunk }
}

/// A row of the unified view with folded context: a hunk line by index, or a fold standing for `count` unchanged lines.
public enum DiffRowItem: Hashable, Sendable {
    case line(file: Int, hunk: Int, index: Int)
    /// `"⋯ <count> unchanged lines"`; `range` indexes the hunk's lines it stands for. Expandable (`collapsed(context:expanded:)`).
    case fold(file: Int, hunk: Int, range: Range<Int>, count: Int)

    /// The fold's label.
    public static func foldText(_ count: Int) -> String { "\u{22EF} \(count) unchanged \(count == 1 ? "line" : "lines")" }
}

/// The first line of a run of changes: where ⌥↓ / ⌥↑ stop. `line` indexes the hunk's lines.
public struct DiffStop: Equatable, Sendable {
    public var file: Int
    public var hunk: Int
    public var line: Int

    public init(file: Int, hunk: Int, line: Int) { self.file = file; self.hunk = hunk; self.line = line }
}

extension DiffModel {
    /// The split view's rows of file `file` across its hunks: a run of deletions pairs line by line with the run of additions
    /// that follows it; the extra lines of the longer run pair with nil; a context line sits on both sides. An unknown file
    /// index is empty.
    public func splitRows(file: Int) -> [SplitRow] {
        guard files.indices.contains(file) else { return [] }
        var rows: [SplitRow] = []
        for (h, hunk) in files[file].hunks.enumerated() {
            let lines = hunk.lines
            var i = 0
            while i < lines.count {
                if lines[i].kind == .ctx {
                    rows.append(SplitRow(left: lines[i], right: lines[i], hunk: h))
                    i += 1
                    continue
                }
                var dels: [DiffLine] = [], adds: [DiffLine] = []
                while i < lines.count, lines[i].kind == .del { dels.append(lines[i]); i += 1 }
                while i < lines.count, lines[i].kind == .add { adds.append(lines[i]); i += 1 }
                for n in 0..<max(dels.count, adds.count) {
                    rows.append(SplitRow(left: n < dels.count ? dels[n] : nil, right: n < adds.count ? adds[n] : nil, hunk: h))
                }
            }
        }
        return rows
    }

    /// The unified rows of every file with the unchanged runs longer than 2 × `context` folded to `context` lines on each side
    /// and one `fold` item for the rest; a fold named in `expanded` shows its lines in place.
    public func collapsed(context: Int = 3, expanded: Set<DiffRowItem> = []) -> [DiffRowItem] {
        // M-5: a caller's context is clamped (negative → 0; huge → never folds) so `2 * context` and the ranges stay sound.
        let context = min(max(context, 0), Self.maxContext)
        var out: [DiffRowItem] = []
        for (f, file) in files.enumerated() {
            for (h, hunk) in file.hunks.enumerated() {
                let lines = hunk.lines
                var i = 0
                while i < lines.count {
                    guard lines[i].kind == .ctx else {
                        out.append(.line(file: f, hunk: h, index: i))
                        i += 1
                        continue
                    }
                    var end = i
                    while end < lines.count, lines[end].kind == .ctx { end += 1 }
                    let run = end - i
                    if run > 2 * context {
                        let range = (i + context)..<(end - context)
                        let fold = DiffRowItem.fold(file: f, hunk: h, range: range, count: range.count)
                        for n in i..<range.lowerBound { out.append(.line(file: f, hunk: h, index: n)) }
                        if expanded.contains(fold) {
                            for n in range { out.append(.line(file: f, hunk: h, index: n)) }
                        } else {
                            out.append(fold)
                        }
                        for n in range.upperBound..<end { out.append(.line(file: f, hunk: h, index: n)) }
                    } else {
                        for n in i..<end { out.append(.line(file: f, hunk: h, index: n)) }
                    }
                    i = end
                }
            }
        }
        return out
    }

    /// The largest `context` `collapsed` honours (more than any hunk the engine emits).
    public static let maxContext = 1_000

    /// The first line of every run of changes, in file and hunk order.
    public var changeStops: [DiffStop] {
        var out: [DiffStop] = []
        for (f, file) in files.enumerated() {
            for (h, hunk) in file.hunks.enumerated() {
                var inRun = false
                for (i, line) in hunk.lines.enumerated() {
                    if line.kind == .ctx { inRun = false; continue }
                    if !inRun { out.append(DiffStop(file: f, hunk: h, line: i)); inRun = true }
                }
            }
        }
        return out
    }

    /// Every hunk line of file `file` through `CodeHighlighter` with the file's language (each hunk lexed as one text, so a
    /// string or comment state carries across its lines), invisible characters as markers; one span row per line in hunk
    /// order, never more than `defaultMaxLines`.
    public func highlighted(file: Int) -> [[CodeSpan]] {
        guard files.indices.contains(file) else { return [] }
        let language = CodeLanguage.detect(path: files[file].path)
        var out: [[CodeSpan]] = []
        for hunk in files[file].hunks {
            guard !hunk.lines.isEmpty else { continue }
            let room = Self.defaultMaxLines - out.count
            guard room > 0 else { break }
            let lines = Array(hunk.lines.prefix(room))
            var spans = Array(CodeHighlighter.highlight(lines.map(\.text).joined(separator: "\n"), language: language).prefix(lines.count))
            // M-4: the highlighter's line split drops one trailing CR per line; its marker is put back so a CRLF file shows it.
            for (i, line) in lines.enumerated() where i < spans.count && line.text.unicodeScalars.last == "\r" {
                spans[i].append(CodeSpan(text: InvisibleMarkers.marker("\r"), kind: .plain, hidden: true))
            }
            // `highlight` yields one row per line of its input (a trailing newline would add an empty one; none is given).
            out.append(contentsOf: spans)
        }
        return out
    }
}
