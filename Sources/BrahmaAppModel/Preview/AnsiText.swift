import Foundation

/// The 16 basic terminal colors (SGR 30–37 and 90–97). The app maps them to theme tokens; nothing else is styled.
public enum AnsiColor: CaseIterable, Equatable, Sendable {
    case black, red, green, yellow, blue, magenta, cyan, white
    case brightBlack, brightRed, brightGreen, brightYellow, brightBlue, brightMagenta, brightCyan, brightWhite
}

/// A run of terminal text with one style.
public struct AnsiSpan: Equatable, Sendable {
    public var text: String
    public var color: AnsiColor?
    public var bold: Bool

    public init(text: String, color: AnsiColor? = nil, bold: Bool = false) {
        self.text = text
        self.color = color
        self.bold = bold
    }
}

/// A pure, bounded parser for terminal output (Plan 4a Task 8a; Collab reuses it for run logs). Only SGR 0, 1, 22,
/// 30–37, 39 and 90–97 apply. Every other CSI, OSC, DCS and lone ESC is dropped, `\r` with text after it on the same line
/// erases what came before (a progress bar's last state), and other control characters are removed (a tab stays: it is
/// log alignment). Lines are cut at `RendererCaps.maxLineBytes` and only the last `maxLines` are built: the tail is found
/// by scanning the bytes backwards, so a 50 MB flood costs the same as 2000 lines (fix 11). Styles set before the kept
/// tail are not seen, so the first kept line starts unstyled.
public enum AnsiText {
    public static let maxLines = 2000

    /// One array of spans per line; an empty line is `[]`. A trailing newline ends the last line and adds nothing.
    public static func parse(_ text: String) -> [[AnsiSpan]] {
        var text = text
        text.makeContiguousUTF8()
        let utf8 = text.utf8
        guard !utf8.isEmpty else { return [] }
        var end = utf8.endIndex
        if utf8[utf8.index(before: end)] == 0x0A { end = utf8.index(before: end) }
        var start = end
        var newlines = 0
        while start > utf8.startIndex {
            let previous = utf8.index(before: start)
            if utf8[previous] == 0x0A {
                newlines += 1
                if newlines == maxLines { break }
            }
            start = previous
        }
        var state = Style()
        var lines: [[AnsiSpan]] = []
        lines.reserveCapacity(min(newlines + 1, maxLines))
        for raw in utf8[start..<end].split(separator: 0x0A, omittingEmptySubsequences: false) {
            lines.append(parseLine(RendererCaps.truncateLine(Substring(raw)), state: &state))
        }
        return lines
    }

    struct Style: Equatable {
        var color: AnsiColor?
        var bold = false
    }

    private static let esc: Unicode.Scalar = "\u{1B}"
    private static let bel: Unicode.Scalar = "\u{07}"

    /// One line's spans. `state` is the style carried in and out (SGR persists across lines).
    static func parseLine(_ line: String, state: inout Style) -> [AnsiSpan] {
        let s = Array(line.unicodeScalars)
        var spans: [AnsiSpan] = []
        var text = String.UnicodeScalarView()
        func flush() {
            if !text.isEmpty {
                spans.append(AnsiSpan(text: String(text), color: state.color, bold: state.bold))
                text = String.UnicodeScalarView()
            }
        }
        // A CR erases the line only once printable text follows it: `done\r\e[0m` and CRLF endings keep their line.
        var pendingReset = false
        func put(_ c: Unicode.Scalar) {
            if pendingReset {
                spans.removeAll()
                text = String.UnicodeScalarView()
                pendingReset = false
            }
            text.append(c)
        }
        var i = 0
        while i < s.count {
            let c = s[i]
            switch c {
            case esc:
                i = skipEscape(s, at: i) { params in
                    let next = applySGR(params, to: state)
                    if next != state {
                        flush()
                        state = next
                    }
                }
            case "\r":
                pendingReset = true
                i += 1
            case "\t":
                put(c)
                i += 1
            default:
                if c.value >= 0x20, c.value != 0x7F, !(0x80...0x9F).contains(c.value) { put(c) }
                i += 1
            }
        }
        flush()
        return spans
    }

    /// The index after the escape sequence starting at `i` (an ESC). `sgr` is called with the parameter string of a
    /// well-formed SGR (`CSI <digits and ;> m`); every other sequence is dropped. A cut-off sequence consumes the rest.
    private static func skipEscape(_ s: [Unicode.Scalar], at i: Int, sgr: (String) -> Void) -> Int {
        guard i + 1 < s.count else { return s.count }
        let kind = s[i + 1]
        switch kind {
        case "[":
            var j = i + 2
            var params = ""
            var simple = true
            while j < s.count, (0x30...0x3F).contains(s[j].value) {
                if !(s[j] == ";" || ("0"..."9").contains(s[j])) { simple = false }
                params.unicodeScalars.append(s[j])
                j += 1
            }
            var intermediates = false
            while j < s.count, (0x20...0x2F).contains(s[j].value) { intermediates = true; j += 1 }
            guard j < s.count else { return s.count }
            guard (0x40...0x7E).contains(s[j].value) else { return j }   // malformed: the sequence is abandoned there
            if s[j] == "m", simple, !intermediates { sgr(params) }
            return j + 1
        case "]", "P", "X", "^", "_":
            // OSC, DCS, SOS, PM, APC: a string ended by BEL or ST (ESC \). An ESC that is not ST ends it and is reread.
            var j = i + 2
            while j < s.count {
                if s[j] == bel { return j + 1 }
                if s[j] == esc { return j + 1 < s.count && s[j + 1] == "\\" ? j + 2 : j }
                j += 1
            }
            return j
        default:
            if (0x20...0x2F).contains(kind.value) {
                // nF: intermediates then one final byte, such as ESC ( B.
                var j = i + 1
                while j < s.count, (0x20...0x2F).contains(s[j].value) { j += 1 }
                return j < s.count && (0x30...0x7E).contains(s[j].value) ? j + 1 : j
            }
            if (0x30...0x7E).contains(kind.value) { return i + 2 }   // Fp, Fe, Fs: ESC plus one byte
            return i + 1                                            // a lone ESC before a control or non-ASCII scalar
        }
    }

    /// `style` after the SGR parameters. Extended colors (38 and 48 with 5;n or 2;r;g;b) are skipped whole so their
    /// arguments never read as basic colors; every other code is ignored.
    static func applySGR(_ params: String, to style: Style) -> Style {
        var next = style
        let codes = params.split(separator: ";", omittingEmptySubsequences: false).map { Int($0) ?? 0 }
        var k = 0
        while k < codes.count {
            let code = codes[k]
            switch code {
            case 0: next = Style()
            case 1: next.bold = true
            case 22: next.bold = false
            case 30...37: next.color = AnsiColor.allCases[code - 30]
            case 39: next.color = nil
            case 90...97: next.color = AnsiColor.allCases[8 + code - 90]
            case 38, 48:
                if k + 1 < codes.count {
                    switch codes[k + 1] {
                    case 5: k += 2
                    case 2: k += 4
                    default: k += 1
                    }
                }
            default: break
            }
            k += 1
        }
        return next
    }
}
