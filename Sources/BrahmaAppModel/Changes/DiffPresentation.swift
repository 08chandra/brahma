import Foundation
import BrahmaCore

/// How the CHANGES tab draws a diff: one column, or deletions beside additions (`DiffModel.splitRows`). Saved per company.
public enum DiffViewMode: String, Codable, Sendable {
    case unified, split
}

/// Stepping through `DiffModel.changeStops` (⌥↓ / ⌥↑): clamped at both ends, nil with nothing to stop at.
public enum DiffStops {
    /// The next stop: the first from nothing; past the last stays on the last.
    public static func next(_ current: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return min((current ?? -1) + 1, count - 1)
    }

    /// The previous stop: the first from nothing; before the first stays on the first.
    public static func previous(_ current: Int?, count: Int) -> Int? {
        guard count > 0 else { return nil }
        return max((current ?? 1) - 1, 0)
    }

    /// Where `stop` of `old` sits in `new` after a re-parse: the same hunk and line in the file of the same path when that is
    /// still a stop, else the nearest stop in that file; nil when the file is gone or has no change left.
    public static func relocate(_ stop: DiffStop, from old: DiffModel, in new: DiffModel) -> DiffStop? {
        guard old.files.indices.contains(stop.file) else { return nil }
        let path = old.files[stop.file].path
        guard let index = new.files.firstIndex(where: { $0.path == path }) else { return nil }
        let candidates = new.changeStops.filter { $0.file == index }
        if let same = candidates.first(where: { $0.hunk == stop.hunk && $0.line == stop.line }) { return same }
        func distance(_ s: DiffStop) -> Int { abs(s.hunk - stop.hunk) * 1_000_000 + abs(s.line - stop.line) }
        return candidates.min { distance($0) < distance($1) }
    }
}

/// One row of the changes board as the view draws it. Every string is the engine's gated final text or built here from the
/// engine's numbers; `agent` and `title` are agent-controlled (`Text(verbatim:)`).
public struct BoardRowView: Equatable, Identifiable, Sendable {
    public var key: String
    public var title: String
    /// `@eng-1`.
    public var agent: String
    /// `"+120 −34 · 6 files"`.
    public var stats: String
    /// `"edited 12 s ago"`, `"no edits yet"`.
    public var edited: String
    /// `CHECK PASSED`, `CHECK FAILED`, `CHECK RUNNING` or `NO CHECK`.
    public var check: String
    public var checkTone: PreviewTone
    public var agentTone: PreviewTone
    /// `@qa-2` when the item has a reviewer.
    public var reviewer: String?
    /// The TAINTED chip (`warning`): the live diff carries outside content.
    public var tainted: Bool

    public var id: String { key }

    /// C7c fix round 1 (m-6): the row's chips as the board draws them (TAINTED `warning` when the live diff carries outside content).
    public var chips: [RefChip] { tainted ? [RefChip(text: "TAINTED", tone: .warn)] : [] }
}

public enum BoardRows {
    public static func make(_ rows: [BoardRow], now: Date) -> [BoardRowView] {
        rows.map { row in
            let (check, tone) = checkText(row.checkStatus)
            return BoardRowView(key: row.key, title: row.title, agent: "@" + row.agent, stats: stats(added: row.added, removed: row.removed, files: row.files),
                                edited: edited(row.lastEdit, now: now), check: check, checkTone: tone, agentTone: agentTone(row.agentState),
                                reviewer: row.reviewer.map { "@" + $0 }, tainted: row.tainted)
        }
    }

    /// `"+120 −34 · 6 files"` (U+2212 minus, as `DiffModel.statLine`).
    public static func stats(added: Int, removed: Int, files: Int) -> String {
        "+\(added) \u{2212}\(removed) · \(files) \(files == 1 ? "file" : "files")"
    }

    /// Wall-clock age of the newest edit (a file time, not a company-active duration).
    public static func edited(_ date: Date?, now: Date) -> String {
        guard let date else { return "no edits yet" }
        let s = max(0, Int(now.timeIntervalSince(date)))
        if s < 60 { return "edited \(s) s ago" }
        if s < 3600 { return "edited \(s / 60) min ago" }
        if s < 86_400 { return "edited \(s / 3600) h ago" }
        return "edited \(s / 86_400) d ago"
    }

    /// The engine's `passed` / `failed` / `running` / `none` as a chip and its tone.
    public static func checkText(_ status: String?) -> (String, PreviewTone) {
        switch status {
        case "passed": return ("CHECK PASSED", .good)
        case "failed": return ("CHECK FAILED", .bad)
        case "running": return ("CHECK RUNNING", .busy)
        default: return ("NO CHECK", .idle)
        }
    }

    /// The holder's state as a tone: running `success`, blocked `warning`, killed `danger`, ready and sleeping `text2`.
    public static func agentTone(_ state: String) -> PreviewTone {
        switch state {
        case "running": return .good
        case "blocked": return .warn
        case "killed": return .bad
        default: return .idle
        }
    }
}

/// One file of a changes snapshot as the file list draws it: the engine's gated path, status and summary, and the index of its
/// hunks in the parsed `DiffModel` (nil for a binary, large or otherwise summarized file with no hunks to open). The index is the
/// engine's `patchIndex` (I-1): the display path never has to equal the raw one.
public struct ChangedFileRow: Equatable, Identifiable, Sendable {
    public var path: String
    public var oldPath: String?
    /// `A`, `M`, `D` or `R`.
    public var status: String
    /// `"+3 −0"`.
    public var stats: String
    /// `"binary · 1.2 MB → 1.3 MB"`, `"large file · 4.1 MB, diff not shown"`, `"1,500 more lines not shown"` — the engine's words.
    public var summary: String?
    public var fileIndex: Int?

    public var id: String { path }
}

public enum ChangesFiles {
    /// The snapshot's files in the engine's order, each pointing at its section in `diff` when the parser kept it with hunks.
    public static func rows(_ snapshot: ChangesSnapshot, diff: DiffModel) -> [ChangedFileRow] {
        snapshot.files.map { f in
            let index = f.patchIndex.flatMap { diff.files.indices.contains($0) && !diff.files[$0].hunks.isEmpty ? $0 : nil }
            return ChangedFileRow(path: f.path, oldPath: f.oldPath, status: f.status, stats: "+\(f.added) \u{2212}\(f.removed)", summary: f.summary,
                                  fileIndex: index)
        }
    }
}

/// C7c fix round 1 (m-6): a diff comment as the marker's thread draws it — its kind and its chips come from here, not the view.
public enum DiffThread {
    public static func chips(for comment: DiffComment) -> [RefChip] {
        comment.tainted ? [RefChip(text: "TAINTED", tone: .warn)] : []
    }

    /// `COMMENT` or `REVERT REQUEST`.
    public static func kindText(_ comment: DiffComment) -> String {
        comment.kind == DiffComment.revertRequest ? "REVERT REQUEST" : "COMMENT"
    }
}

/// C7c fix round 1 (m-2): the worktree the app's FSEvents nudger may watch, re-checked right before the stream is made: a real
/// directory named for the key directly in a real `.brahma/wt` (no component a link, no `.`/`..`, never a file or a missing path).
/// The nudger only asks the engine for an early recompute; this keeps a swapped-in link from pointing its stream elsewhere.
public enum WorktreeWatchRoot {
    public static func isSafe(path: String, key: String) -> Bool {
        guard !key.isEmpty, !key.contains("/"), key != ".", key != "..", path.hasPrefix("/") else { return false }
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard !parts.contains("."), !parts.contains(".."), parts.count >= 3,
              parts[parts.count - 1] == key, parts[parts.count - 2] == "wt", parts[parts.count - 3] == ".brahma" else { return false }
        let leaf = URL(fileURLWithPath: path)
        let wt = leaf.deletingLastPathComponent()
        let brahma = wt.deletingLastPathComponent()
        return [leaf, wt, brahma].allSatisfy { isRealDirectory($0.path) }
    }

    /// `lstat`: a directory, not a link to one.
    static func isRealDirectory(_ path: String) -> Bool {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path) else { return false }
        return (attributes[.type] as? FileAttributeType) == .typeDirectory
    }
}
