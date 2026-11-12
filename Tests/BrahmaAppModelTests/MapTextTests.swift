import Testing
import Foundation
@testable import BrahmaAppModel

@Suite struct MapTextTests {
    @Test func cleansControlBidiAndLength() {
        #expect(MapText.clean("a\nb\t c", max: 40) == "a b c")
        #expect(MapText.clean("evil\u{202E}txt.exe", max: 40) == "eviltxt.exe")
        #expect(MapText.clean(String(repeating: "x", count: 10_000), max: 40).count == 40)
        #expect(MapText.clean(String(repeating: "x", count: 50), max: 40).hasSuffix("…"))
        #expect(MapText.clean("   ", max: 40) == "—"); #expect(MapText.clean(nil, max: 40) == "—")
        #expect(MapText.clean("👩‍💻👩‍💻👩‍💻", max: 2) == "👩‍💻…")
    }

    @Test func invisibleAndLayoutCharactersRemoved() {
        #expect(MapText.clean("a\u{2028}b\u{061C}c\u{E0041}", max: 40) == "a bc")
        #expect(MapText.clean("a\u{00AD}b\u{180E}c\u{3164}d\u{200B}e", max: 40) == "abcde")
        #expect(MapText.clean("👨‍👩‍👧‍👦", max: 1) == "👨‍👩‍👧‍👦")   // joiner sequences survive
    }

    @Test func combiningMarksAndInputAreCapped() {
        #expect(MapText.clean("e" + String(repeating: "\u{0301}", count: 5000), max: 40).unicodeScalars.count <= 5)
        #expect(MapText.clean(String(repeating: "x", count: 5000), max: 40).count == 40)
    }

    /// The controller's ruling on `max`: the total output clusters, the trailing "…" included.
    @Test func maxCountsTheEllipsis() {
        let cut = MapText.clean(String(repeating: "x", count: 50), max: 40)
        #expect(cut == String(repeating: "x", count: 39) + "…")
        #expect(MapText.clean("abc", max: 3) == "abc")
        #expect(MapText.clean("abcd", max: 3) == "ab…")
    }

    /// Every listed invisible, bidi and layout scalar goes; the non-joiner and the joiner stay.
    @Test func everyListedScalarRemoved() {
        var listed: [UInt32] = [0x00AD, 0x034F, 0x061C, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x180E, 0x200B, 0x200E, 0x200F,
                                0x3164, 0xFEFF, 0xFFA0]
        listed += Array(0x202A...0x202E) + Array(0x2060...0x2069) + Array(0xE0000...0xE007F)
        for v in listed {
            let s = "a" + String(Character(Unicode.Scalar(v)!)) + "b"
            #expect(MapText.clean(s, max: 40) == "ab", "U+\(String(v, radix: 16, uppercase: true))")
        }
        #expect(MapText.clean("a\u{200C}b", max: 40).unicodeScalars.map(\.value) == [0x61, 0x200C, 0x62])
    }

    @Test func everyNewlineAndWhitespaceKindCollapses() {
        #expect(MapText.clean("\u{2029} a\r\n\u{0085}\u{000B}\u{000C}\u{00A0}\u{3000}b \u{2028}", max: 40) == "a b")
        #expect(MapText.clean("\u{1B}[2Jhi\u{7F}there", max: 40) == "[2Jhi there")
        #expect(MapText.clean("\u{202E}\u{2066}\u{200B}\u{FEFF} \n\t", max: 40) == "—")
    }

    /// Each cluster keeps at most 8 scalars, at most 4 of them combining marks (Mn, Me, Mc).
    @Test func zalgoClustersCapped() {
        let zalgo = "a" + String(repeating: "\u{0301}\u{0489}\u{0903}", count: 20) + "b"
        let out = MapText.clean(zalgo, max: 40)
        #expect(out.count == 2)
        for c in out {
            #expect(c.unicodeScalars.count <= 8)
            let marks = c.unicodeScalars.filter {
                [.nonspacingMark, .enclosingMark, .spacingMark].contains($0.properties.generalCategory)
            }
            #expect(marks.count <= 4)
        }
        // Emoji modifiers and variation selectors are not marks: a skin-toned profession keeps all its scalars.
        #expect(MapText.clean("👩🏽‍💻", max: 1) == "👩🏽‍💻")
    }

    /// A cut cluster must not fuse with its neighbour into a longer one: every output cluster honours the cap.
    @Test func cutClustersNeverFuse() {
        // Nine scalars each (five emoji, four joiners): cut to eight they end in a joiner, which would glue the next one on.
        let chain = "👨‍👩‍👧‍👦‍👦"
        let out = MapText.clean(String(repeating: chain, count: 400), max: 4096)
        for c in out { #expect(c.unicodeScalars.count <= 8) }
        // Hangul jamo: a cut L* run before a V-led cluster.
        let jamo = String(repeating: "\u{1100}", count: 9) + "\u{1161}\u{11A8}"
        let out2 = MapText.clean(String(repeating: jamo + "\u{1161}", count: 50), max: 4096)
        for c in out2 { #expect(c.unicodeScalars.count <= 8) }
        // A cut cluster of prepend scalars (U+0600) would swallow the "…": it is dropped and "…" stays its own cluster.
        let prepend = MapText.clean(String(repeating: "\u{0600}", count: 9) + "x\u{FFF9}ab", max: 2)
        #expect(prepend == "…")
    }

    @Test func outputIsBoundedForHugeInputs() {
        let mixed = String(repeating: "x\u{202E}\u{E0041}\u{0301}\u{0301}\u{0301}\u{0301}\u{0301}\n", count: 10_000)
        let out = MapText.clean(mixed, max: 80)
        #expect(out.count <= 80)
        #expect(out.unicodeScalars.count <= 80 * 8)
        #expect(!out.unicodeScalars.contains { $0.value == 0x202E || $0.value == 0xE0041 || $0.value == 0x0A })
        #expect(MapText.clean(String(repeating: " ", count: 10_000) + "x", max: 40) == "—")   // past the input limit
    }

    @Test func tinyMax() {
        #expect(MapText.clean("abc", max: 1) == "…")
        #expect(MapText.clean("a", max: 1) == "a")
        #expect(MapText.clean("abc", max: 0) == "…")
    }

    @Test func vacancyCleaned() {
        let v = Vacancy(id: "eng-9\u{202E}", role: "engineer\n", roleTitle: "  Engineer  ", managerId: "a-mgr-1",
                        team: nil, note: "", source: .org).cleaned()
        #expect(v == Vacancy(id: "eng-9", role: "engineer", roleTitle: "Engineer", managerId: "a-mgr-1", team: nil, note: "",
                             source: .org))
        let w = Vacancy(id: "x", role: "r", roleTitle: "R", managerId: nil, team: String(repeating: "t", count: 50),
                        note: String(repeating: "n", count: 100), source: .provider).cleaned()
        #expect(w.team?.count == 32)
        #expect(w.note.count == 80)
        #expect(w.source == .provider)
    }
}
