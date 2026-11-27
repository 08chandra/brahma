import Testing
import Foundation
@testable import BrahmaCore
@testable import BrahmaAppModel

/// Plan C Task C6b: the `DiffModel` presentation helpers — the split view's pairing, folded context, change stops and
/// per-file highlighting — plus the file rows that show the engine's binary and large-file summaries.
@MainActor @Suite(.scratch) struct DiffPresentationTests {
    /// One file `path` with one hunk of `body` lines (each with its `+`/`-`/space marker).
    static func file(_ path: String, _ body: [String], header: String = "@@ -1,1 +1,1 @@") -> String {
        var out = "diff --git a/\(path) b/\(path)\nindex 1111111..2222222 100644\n--- a/\(path)\n+++ b/\(path)\n\(header)\n"
        for line in body { out += line + "\n" }
        return out
    }

    @Test func splitViewPairsLines() {
        let patch = Self.file("src/a.ts", [" ctx one", "-a", "-b", "+c", "+d", "+e", " ctx two"]) + Self.file("src/b.ts", ["+only add", " tail"])
        let m = DiffModel.parse(patch: patch)
        let rows = m.splitRows(file: 0)
        #expect(rows.count == 5)
        #expect(rows[0].left?.text == "ctx one" && rows[0].right?.text == "ctx one", "context lines sit on both sides")
        #expect(rows[0].left?.kind == .ctx && rows[0].right?.kind == .ctx)
        #expect(rows[1].left?.text == "a" && rows[1].right?.text == "c")
        #expect(rows[2].left?.text == "b" && rows[2].right?.text == "d")
        #expect(rows[3].left == nil && rows[3].right?.text == "e", "an extra addition pairs with nothing")
        #expect(rows[4].left?.text == "ctx two" && rows[4].right?.text == "ctx two")
        #expect(rows.allSatisfy { $0.hunk == 0 })
        // Line numbers travel with their lines.
        #expect(rows[1].left?.oldNo == 2 && rows[1].right?.newNo == 2 && rows[3].right?.newNo == 4)
        // A pure addition run pairs with nil on the left; deletions alone pair with nil on the right.
        let b = m.splitRows(file: 1)
        #expect(b.count == 2 && b[0].left == nil && b[0].right?.text == "only add" && b[1].left?.text == "tail")
        let dels = DiffModel.parse(patch: Self.file("x", ["-gone", "-too", " keep"])).splitRows(file: 0)
        #expect(dels.count == 3 && dels[0].left?.text == "gone" && dels[0].right == nil && dels[1].right == nil && dels[2].right?.text == "keep")
        #expect(m.splitRows(file: 9).isEmpty, "an unknown file index is empty, never a crash")
        // The mode the owner picks round-trips through its raw value.
        #expect(DiffViewMode(rawValue: "split") == .split && DiffViewMode.unified.rawValue == "unified")
    }

    @Test func collapseUnchanged() {
        let twenty = (1...20).map { " same \($0)" }
        let m = DiffModel.parse(patch: Self.file("a.ts", ["+first"] + twenty + ["+last"]))
        let items = m.collapsed(context: 3)
        // +first, 3 context, one fold of 14, 3 context, +last.
        #expect(items.count == 9, "\(items)")
        #expect(items.first == .line(file: 0, hunk: 0, index: 0))
        #expect(items[1] == .line(file: 0, hunk: 0, index: 1) && items[3] == .line(file: 0, hunk: 0, index: 3))
        #expect(items[4] == .fold(file: 0, hunk: 0, range: 4..<18, count: 14))
        #expect(items[5] == .line(file: 0, hunk: 0, index: 18) && items[7] == .line(file: 0, hunk: 0, index: 20))
        #expect(items.last == .line(file: 0, hunk: 0, index: 21))
        if case .fold(_, _, _, let count) = items[4] { #expect(DiffRowItem.foldText(count) == "⋯ 14 unchanged lines") }
        // A run of 2 × context stays whole.
        let six = (1...6).map { " same \($0)" }
        let short = DiffModel.parse(patch: Self.file("a.ts", ["+first"] + six + ["+last"])).collapsed(context: 3)
        #expect(short.count == 8 && !short.contains { if case .fold = $0 { return true } else { return false } })
        // Expanding a fold shows its lines in place.
        let expanded = m.collapsed(context: 3, expanded: [items[4]])
        #expect(expanded.count == 22 && !expanded.contains { if case .fold = $0 { return true } else { return false } })
        // Context 0 folds every unchanged run; a hunk with no change folds nothing but its lines still list.
        #expect(DiffModel.parse(patch: Self.file("a.ts", ["+x", " y", " z"])).collapsed(context: 0).count == 2)
        // Two files, two hunks: items name their file and hunk.
        let two = DiffModel.parse(patch: Self.file("a.ts", ["+x"]) + Self.file("b.ts", ["-y"])).collapsed()
        #expect(two == [.line(file: 0, hunk: 0, index: 0), .line(file: 1, hunk: 0, index: 0)])
        // M-5: a caller's context is clamped — never a trap or an overflow.
        #expect(m.collapsed(context: -3) == m.collapsed(context: 0))
        #expect(m.collapsed(context: Int.max).count == 22 && m.collapsed(context: Int.max / 2 + 1).count == 22)
        #expect(DiffModel.parse(patch: "").collapsed(context: Int.min).isEmpty)
    }

    @Test func nextPrevChange() {
        let patch = Self.file("a.ts", [" ctx", "-a", "+b", " ctx", "+c", " ctx"]) + Self.file("b.ts", ["+z"])
        let m = DiffModel.parse(patch: patch)
        let stops = m.changeStops
        #expect(stops == [DiffStop(file: 0, hunk: 0, line: 1), DiffStop(file: 0, hunk: 0, line: 4), DiffStop(file: 1, hunk: 0, line: 0)],
                "the first line of every run of changes, in file order")
        // Stepping: next past the last stays; previous from the first stays; nothing to step with no stops.
        #expect(DiffStops.next(nil, count: 3) == 0)
        #expect(DiffStops.next(0, count: 3) == 1 && DiffStops.next(2, count: 3) == 2)
        #expect(DiffStops.previous(nil, count: 3) == 0)
        #expect(DiffStops.previous(2, count: 3) == 1 && DiffStops.previous(0, count: 3) == 0)
        #expect(DiffStops.next(nil, count: 0) == nil && DiffStops.previous(1, count: 0) == nil)
        // A stop relocates to the same file after a re-parse that shifts the file index.
        let shifted = DiffModel.parse(patch: Self.file("0.ts", ["+new"]) + patch)
        #expect(DiffStops.relocate(stops[1], from: m, in: shifted) == DiffStop(file: 1, hunk: 0, line: 4))
        #expect(DiffStops.relocate(stops[2], from: m, in: DiffModel.parse(patch: Self.file("a.ts", ["+q"]))) == nil, "a file that is gone has no stop")
        #expect(DiffModel.parse(patch: Self.file("a.ts", [" only", " context"])).changeStops.isEmpty)
    }

    /// I-1: the parser reads paths as the engine does — git's trailing tab after a path with a space, C-quoted paths decoded, no
    /// fake rename from the `diff --git` line.
    @Test func parserPathsMatchTheEngine() {
        let spaced = "diff --git a/src/we ird.ts b/src/we ird.ts\nnew file mode 100644\nindex 0000000..1111111\n--- /dev/null\n+++ b/src/we ird.ts\t\n@@ -0,0 +1 @@\n+x\n"
        let m = DiffModel.parse(patch: spaced)
        #expect(m.files.count == 1 && m.files[0].path == "src/we ird.ts" && m.files[0].oldPath == nil && m.files[0].hunks[0].lines.count == 1)
        let quoted = "diff --git \"a/src/caf\\303\\251 \\\"q\\\".ts\" \"b/src/caf\\303\\251 \\\"q\\\".ts\"\nindex 1..2 100644\n--- \"a/src/caf\\303\\251 \\\"q\\\".ts\"\n+++ \"b/src/caf\\303\\251 \\\"q\\\".ts\"\n@@ -1 +1 @@\n-a\n+b\n"
        let q = DiffModel.parse(patch: quoted)
        #expect(q.files.count == 1 && q.files[0].path == "src/caf\u{E9} \"q\".ts" && q.files[0].oldPath == nil && q.files[0].hunks.count == 1)
        #expect(ChangesPatch.pathFromGitLine("diff --git a/x y b/x y") == "x y")
        #expect(ChangesPatch.prefixedPath("b/a b.txt\t", "b/") == "a b.txt")
        // A rename still names both paths.
        let renamed = DiffModelTests.patch(adds: [1], dels: [0], rename: true)
        #expect(DiffModel.parse(patch: renamed).files[0].oldPath == "src/old0.swift")
    }

    @Test func highlightPerFile() {
        let patch = Self.file("Sources/App.swift", ["+let x = 1", " func f() {}", "-// gone"])
            + "diff --git a/img/logo.png b/img/logo.png\nindex 1111111..2222222 100644\nBinary files a/img/logo.png and b/img/logo.png differ\n"
            + Self.file("notes.txt", ["+plain \u{202E}text"])
        let m = DiffModel.parse(patch: patch)
        #expect(m.files.count == 3)
        let swift = m.highlighted(file: 0)
        #expect(swift.count == 3, "one span row per hunk line")
        #expect(swift[0].contains { $0.text == "let" && $0.kind == .keyword })
        #expect(swift[1].contains { $0.text == "func" && $0.kind == .keyword })
        #expect(swift[2].contains { $0.kind == .comment })
        #expect(m.files[1].hunks.isEmpty && m.highlighted(file: 1).isEmpty, "a binary file has no hunks to highlight")
        let plain = m.highlighted(file: 2)
        #expect(plain.count == 1 && plain[0].contains { $0.hidden && $0.text == "⟦U+202E⟧" }, "invisible characters show as markers")
        #expect(plain[0].allSatisfy { $0.kind == .plain })
        #expect(m.highlighted(file: 7).isEmpty)
        // Highlighting never exceeds the diff cap.
        let big = DiffModel.parse(patch: Self.file("a.swift", (0..<6_000).map { "+let v\($0) = \($0)" }))
        #expect(big.highlighted(file: 0).count <= DiffModel.defaultMaxLines)
    }

    @Test func summariesShownForBinaryAndLarge() {
        // The patch holds the two sections the engine emitted (a.ts, new.ts); binary and large files have none. The rows map by the
        // engine's `patchIndex`, never by path text (I-1): the shown path of new.ts differs from its raw one.
        let patch = Self.file("src/a.ts", ["+one", "-two"]) + Self.file("src/n\u{200B}ew.ts", ["+a", "+b", "+c"])
        let diff = DiffModel.parse(patch: patch)
        let files = [ChangedFile(path: "src/a.ts", status: "M", added: 1, removed: 1, patchIndex: 0),
                     ChangedFile(path: "img/logo.png", status: "M", added: 0, removed: 0, summary: "binary · 1.2 KB → 1.3 KB"),
                     ChangedFile(path: "data/big.bin", status: "A", added: 0, removed: 0, summary: "large file · 4.1 MB, diff not shown"),
                     ChangedFile(path: "src/new.ts", oldPath: "src/old.ts", status: "R", added: 3, removed: 0, summary: "1,500 more lines not shown",
                                 patchIndex: 1)]
        let snapshot = ChangesSnapshot(key: "ENG-1", compare: .main, base: "abc", target: "worktree", files: files, added: 4, removed: 1, patch: patch,
                                       truncated: false, tainted: false, taintReason: nil, lastEdit: nil, patchHash: "h", computedAt: .now)
        let rows = ChangesFiles.rows(snapshot, diff: diff)
        #expect(rows.map(\.path) == ["src/a.ts", "img/logo.png", "data/big.bin", "src/new.ts"])
        #expect(rows[0].summary == nil && rows[0].fileIndex == 0 && rows[0].stats == "+1 −1")
        #expect(rows[1].summary == "binary · 1.2 KB → 1.3 KB" && rows[1].fileIndex == nil, "a summarized file has no hunks to open")
        #expect(rows[2].summary == "large file · 4.1 MB, diff not shown" && rows[2].fileIndex == nil && rows[2].status == "A")
        #expect(rows[3].summary == "1,500 more lines not shown" && rows[3].oldPath == "src/old.ts" && rows[3].stats == "+3 −0" && rows[3].fileIndex == 1)
        // A section the parser did not keep (the 5000-line cut) has no hunks to open.
        var cut = files
        cut[3].patchIndex = 7
        #expect(ChangesFiles.rows(ChangesSnapshot(key: "ENG-1", compare: .main, base: "abc", target: "worktree", files: cut, added: 4, removed: 1, patch: patch,
                                                  truncated: true, tainted: false, taintReason: nil, lastEdit: nil, patchHash: "h", computedAt: .now),
                                  diff: diff)[3].fileIndex == nil)
        // The summary is the engine's gated string, shown as is (never rebuilt here).
        #expect(rows[1].stats == "+0 −0")
    }
}
