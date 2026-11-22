import Foundation
import Testing
@testable import BrahmaAppModel

/// `AnsiText` (Plan 4a Task 8a): the pure SGR parser behind the terminal preview and Collab's run logs. Only colors and
/// bold apply; every other escape is dropped; the output is bounded to the last 2000 lines of 4 KB each.
@MainActor @Suite(.scratch) struct AnsiTextTests {
    static func plain(_ lines: [[AnsiSpan]]) -> [String] { lines.map { $0.map(\.text).joined() } }

    @Test func sgrColorsApplied() {
        let lines = AnsiText.parse("\u{1B}[32mPASS\u{1B}[0m streaks \u{1B}[1;31mbold red\u{1B}[22m dim \u{1B}[39mdefault\n\u{1B}[94mbright blue")
        #expect(lines.count == 2)
        #expect(lines[0] == [
            AnsiSpan(text: "PASS", color: .green, bold: false),
            AnsiSpan(text: " streaks ", color: nil, bold: false),
            AnsiSpan(text: "bold red", color: .red, bold: true),
            AnsiSpan(text: " dim ", color: .red, bold: false),
            AnsiSpan(text: "default", color: nil, bold: false),
        ])
        #expect(lines[1] == [AnsiSpan(text: "bright blue", color: .brightBlue, bold: false)])
        // State carries across lines until a reset.
        let carried = AnsiText.parse("\u{1B}[33mone\ntwo")
        #expect(carried[1] == [AnsiSpan(text: "two", color: .yellow, bold: false)])
        // Extended colors (38;5;n and 38;2;r;g;b) are ignored whole: their arguments never read as basic colors.
        let extended = AnsiText.parse("\u{1B}[38;5;31mx\u{1B}[38;2;31;32;33my\u{1B}[48;5;196mz")
        #expect(extended[0] == [AnsiSpan(text: "xyz", color: nil, bold: false)])
        #expect(AnsiColor.allCases.count == 16)
    }

    @Test func dropsNonSGRSequences() {
        let text = "\u{1B}[2J\u{1B}[H\u{1B}[?25lcursor\u{1B}[3;4Hmoves"       // CSI other than m
            + "\u{1B}]0;title\u{07}"                                            // OSC with BEL
            + "\u{1B}]8;;http://evil\u{1B}\\link"                              // OSC with ST
            + "\u{1B}Pq#0;2;0;0;0\u{1B}\\sixel"                                 // DCS
            + "\u{1B}(B\u{1B}=\u{1B}7lone"                                     // nF and Fp escapes
            + "\u{1B}"                                                          // a trailing lone ESC
            + "\u{07}\u{08}\u{0C}\u{7F}bell"                                   // other C0 controls and DEL
        let lines = AnsiText.parse(text)
        #expect(Self.plain(lines) == ["cursormoveslinksixellonebell"])
        #expect(lines[0].allSatisfy { $0.color == nil && !$0.bold })
        // A tab survives (log alignment); a form feed, vertical tab and C1 controls do not.
        #expect(Self.plain(AnsiText.parse("a\tb\u{0B}c\u{85}d")) == ["a\tbcd"])
        // A CSI cut by the end of the input is dropped with nothing shown.
        #expect(Self.plain(AnsiText.parse("ok\u{1B}[31")) == ["ok"])
    }

    @Test func carriageReturnOverwritesLine() {
        #expect(Self.plain(AnsiText.parse("10%\r20%\r100% done\nnext")) == ["100% done", "next"])
        // CRLF endings are plain line ends, not an erased line; nor is a CR followed only by escape codes.
        #expect(Self.plain(AnsiText.parse("one\r\ntwo\r\n")) == ["one", "two"])
        #expect(Self.plain(AnsiText.parse("done\r\u{1B}[0m\nnext")) == ["done", "next"])
        #expect(Self.plain(AnsiText.parse("a\r\u{1B}[31mb")) == ["b"])
        // Color set before the overwrite still applies to what replaces it.
        let colored = AnsiText.parse("\u{1B}[32mold\rnew")
        #expect(colored == [[AnsiSpan(text: "new", color: .green, bold: false)]])
    }

    @Test func keepsLastLines() {
        let text = (1...3000).map { "line \($0)" }.joined(separator: "\n")
        let lines = AnsiText.parse(text)
        #expect(lines.count == AnsiText.maxLines)
        #expect(Self.plain(lines).first == "line 1001")
        #expect(Self.plain(lines).last == "line 3000")
        // A trailing newline does not add an empty line; an empty line inside is kept.
        #expect(Self.plain(AnsiText.parse("a\n\nb\n")) == ["a", "", "b"])
        #expect(AnsiText.parse("").isEmpty)
    }

    @Test func longProgressLineShowsLastState() {
        // 1501 `\r`-separated updates, ~9 KB on one line: the last state shows, with the color set shortly before it.
        var updates = (0...1500).map { "\r\($0)%" }
        updates[1400] = "\r\u{1B}[32m1400%"
        let lines = AnsiText.parse(updates.joined() + "\nnext")
        #expect(lines[0] == [AnsiSpan(text: "1500%", color: .green, bold: false)])
        #expect(Self.plain(lines)[1] == "next")
        // Trailing escape-only segments do not count as an overwrite: the last printed state stays.
        let trailing = AnsiText.parse(updates.joined() + "\r\u{1B}[0m")
        #expect(Self.plain(trailing) == ["1500%"])
        // A long line without `\r` is still cut from its start.
        let long = AnsiText.parse(String(repeating: "x", count: 5000))
        #expect(Self.plain(long)[0].hasSuffix("…") && Self.plain(long)[0].utf8.count <= RendererCaps.maxLineBytes + 3)
    }

    @Test func longLineCut() {
        let long = String(repeating: "é", count: 5000)   // 10 000 bytes
        let lines = AnsiText.parse(long + "\nshort")
        let first = Self.plain(lines)[0]
        #expect(first.hasSuffix("…"))
        #expect(first.utf8.count <= RendererCaps.maxLineBytes + "…".utf8.count)
        #expect(!first.contains("\u{FFFD}"))
        #expect(Self.plain(lines)[1] == "short")
    }

    @Test func hugeInputBounded() {
        let text = String(repeating: "a\n", count: 25_000_000)   // 50 MB
        let clock = SuspendingClock()
        let start = clock.now
        let lines = AnsiText.parse(text)
        let elapsed = clock.now - start
        #expect(lines.count == AnsiText.maxLines)
        #expect(lines.allSatisfy { $0 == [AnsiSpan(text: "a", color: nil, bold: false)] })
        #expect(elapsed < .seconds(2), "\(elapsed)")
    }
}
