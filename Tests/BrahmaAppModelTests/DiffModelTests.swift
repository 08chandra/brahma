import Testing
import Foundation
import BrahmaCore
@testable import BrahmaAppModel

@MainActor @Suite(.scratch) struct DiffModelTests {
    /// A unified patch of `files` files; file `i` adds `adds[i]` lines and removes `dels[i]`, in one hunk each, plus 2 context lines.
    static func patch(adds: [Int], dels: [Int], rename: Bool = false) -> String {
        var out = ""
        for (i, (a, d)) in zip(adds, dels).enumerated() {
            let path = "src/file\(i).swift"
            if rename, i == 0 {
                out += "diff --git a/src/old0.swift b/\(path)\nsimilarity index 90%\nrename from src/old0.swift\nrename to \(path)\n"
                out += "--- a/src/old0.swift\n+++ b/\(path)\n"
            } else {
                out += "diff --git a/\(path) b/\(path)\nindex 1111111..2222222 100644\n--- a/\(path)\n+++ b/\(path)\n"
            }
            out += "@@ -10,\(d + 2) +10,\(a + 2) @@ func hunk\(i)()\n"
            out += " context one\n"
            for n in 0..<d { out += "-removed \(n)\n" }
            for n in 0..<a { out += "+added \(n)\n" }
            out += " context two\n"
        }
        return out
    }

    @Test func diffStatParse() {
        let text = Self.patch(adds: [20, 20, 20, 20, 20, 20], dels: [9, 5, 5, 5, 5, 5], rename: true)
        let m = DiffModel.parse(patch: text)
        #expect(m.files.count == 6 && m.added == 120 && m.removed == 34)
        #expect(m.statLine == "+120 −34 · 6 files")
        #expect(!m.truncated && !m.hasHidden)
        let first = m.files[0]
        #expect(first.path == "src/file0.swift" && first.oldPath == "src/old0.swift" && first.added == 20 && first.removed == 9)
        #expect(m.files[1].oldPath == nil)
        #expect(first.hunks.count == 1)
        let hunk = first.hunks[0]
        #expect(hunk.header == "@@ -10,11 +10,22 @@ func hunk0()")
        #expect(hunk.lines.first == DiffLine(kind: .ctx, text: "context one", oldNo: 10, newNo: 10))
        #expect(hunk.lines[1] == DiffLine(kind: .del, text: "removed 0", oldNo: 11, newNo: nil))
        let firstAdd = hunk.lines.first { $0.kind == .add }
        #expect(firstAdd == DiffLine(kind: .add, text: "added 0", oldNo: nil, newNo: 11))
        #expect(hunk.lines.last == DiffLine(kind: .ctx, text: "context two", oldNo: 20, newNo: 31))
        #expect(DiffModel.parse(patch: Self.patch(adds: [1], dels: [0])).statLine == "+1 −0 · 1 file")
        #expect(DiffModel.parse(patch: "").statLine == "+0 −0 · 0 files")
        // `\ No newline at end of file` and unknown lines never count.
        let odd = DiffModel.parse(patch: Self.patch(adds: [1], dels: [1]) + "\\ No newline at end of file\n")
        #expect(odd.added == 1 && odd.removed == 1)
    }

    @Test func diffCappedAt5000() {
        let big = Self.patch(adds: [6_000], dels: [0])
        let m = DiffModel.parse(patch: big)
        #expect(m.truncated)
        let lines = m.files.flatMap { $0.hunks.flatMap(\.lines) }.count
        #expect(lines <= 5_000 && lines >= 4_990)
        #expect(m.added <= 5_000)
        let small = DiffModel.parse(patch: big, maxLines: 100)
        #expect(small.truncated && small.files.flatMap { $0.hunks.flatMap(\.lines) }.count <= 100)
        // A patch within the cap is whole.
        #expect(!DiffModel.parse(patch: Self.patch(adds: [4_000], dels: [0])).truncated)
    }

    @Test func diffHiddenCharactersFlagged() {
        var text = Self.patch(adds: [2], dels: [0])
        text = text.replacingOccurrences(of: "+added 1\n", with: "+added \u{202E}evil\u{202C}\n")
        let m = DiffModel.parse(patch: text)
        #expect(m.hasHidden)
        let line = m.files[0].hunks[0].lines.first { $0.text.contains("evil") }
        #expect(line?.text == "added \u{202E}evil\u{202C}")
        // The display spans show the markers.
        let spans = InvisibleMarkers.mark(line?.text ?? "")
        #expect(spans.hasHidden && spans.spans.contains { $0.text == "⟦U+202E⟧" } && spans.spans.contains { $0.text == "⟦U+202C⟧" })
        // A hidden character in a path flags the model too.
        let pathy = Self.patch(adds: [1], dels: [0]).replacingOccurrences(of: "src/file0.swift", with: "src/fi\u{200B}le0.swift")
        #expect(DiffModel.parse(patch: pathy).hasHidden)
        #expect(!DiffModel.parse(patch: Self.patch(adds: [2], dels: [1])).hasHidden)
    }
}
