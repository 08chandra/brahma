import Foundation

/// Characters a reader can't see made visible (collab design §4.6): bidi controls, zero-width characters, U+00AD and every other
/// `Cf` code point become a `⟦U+XXXX⟧` span flagged `hidden`, in `CodeView` and `DiffView`. Tabs, spaces and ordinary text stay.
public enum InvisibleMarkers {
    /// Whether `v` is drawn as a marker: a bidi control, a zero-width character, a soft hyphen, a Mongolian vowel separator, any
    /// other format (`Cf`) character, or a C0/C1 control other than the tab (a NUL, a CR inside a line, …).
    public static func isHidden(_ scalar: Unicode.Scalar) -> Bool {
        let v = scalar.value
        if v == 0x09 { return false }
        if v < 0x20 || (0x7F...0x9F).contains(v) { return true }
        if (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v) || (0x200B...0x200F).contains(v) { return true }
        if v == 0x2060 || v == 0xFEFF || v == 0x00AD || v == 0x061C || v == 0x180E || v == 0x2028 || v == 0x2029 { return true }
        return scalar.properties.generalCategory == .format
    }

    /// The marker text of a hidden scalar: `⟦U+202E⟧`.
    public static func marker(_ scalar: Unicode.Scalar) -> String {
        "\u{27E6}U+" + String(format: "%04X", scalar.value) + "\u{27E7}"
    }

    /// `line` as spans: runs of visible text (`hidden = false`, kind `.plain`) and one marker span per hidden character.
    public static func mark(_ line: String) -> (spans: [CodeSpan], hasHidden: Bool) {
        var spans: [CodeSpan] = []
        var hasHidden = false
        for span in split(line, kind: .plain) {
            if span.hidden { hasHidden = true }
            spans.append(span)
        }
        return (spans, hasHidden)
    }

    /// `text` split into visible runs and marker spans, every span of `kind`.
    static func split(_ text: String, kind: TokenKind) -> [CodeSpan] {
        var out: [CodeSpan] = []
        var run = String.UnicodeScalarView()
        for scalar in text.unicodeScalars {
            if isHidden(scalar) {
                if !run.isEmpty { out.append(CodeSpan(text: String(run), kind: kind, hidden: false)); run = String.UnicodeScalarView() }
                out.append(CodeSpan(text: marker(scalar), kind: kind, hidden: true))
            } else {
                run.append(scalar)
            }
        }
        if !run.isEmpty { out.append(CodeSpan(text: String(run), kind: kind, hidden: false)) }
        return out
    }

    /// Whether `text` holds any character a marker would stand for.
    public static func holdsHidden(_ text: String) -> Bool { text.unicodeScalars.contains(where: isHidden) }
}
