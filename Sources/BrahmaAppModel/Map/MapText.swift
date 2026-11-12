import Foundation
import BrahmaCore

/// The single gate every agent-controlled string passes before it reaches a map label, texture or overlay. Agent text is
/// never trusted: the result is one line, without controls, bidi overrides, invisible or layout-breaking scalars, with
/// bounded grapheme clusters and at most `max` clusters.
public enum MapText {
    /// Input beyond this many unicode scalars is ignored before any other work.
    public static let inputLimit = 4096
    /// Per grapheme cluster: scalars kept, and combining marks (Mn, Me, Mc) among them.
    static let scalarsPerCluster = 8
    static let marksPerCluster = 4
    static let empty = "—"
    static let ellipsis: Character = "…"

    /// Invisible, bidi and layout-breaking scalars. U+200C and U+200D (the joiners) are kept: U+200D glues emoji sequences.
    static func isRemoved(_ s: Unicode.Scalar) -> Bool {
        switch s.value {
        case 0x00AD, 0x034F, 0x061C, 0x115F, 0x1160, 0x17B4, 0x17B5, 0x180E, 0x200B, 0x200E, 0x200F,
             0x202A...0x202E, 0x2060...0x2069, 0x3164, 0xFEFF, 0xFFA0, 0xE0000...0xE007F:
            true
        default:
            false
        }
    }

    static func isMark(_ s: Unicode.Scalar) -> Bool {
        switch s.properties.generalCategory {
        case .nonspacingMark, .enclosingMark, .spacingMark: true
        default: false
        }
    }

    /// Empty or nil gives "—". A caller that needs "no text" keeps its field optional or empty and does not call this.
    public static func clean(_ s: String?, max: Int) -> String {
        guard let s, !s.isEmpty else { return empty }
        let max = Swift.max(1, max)

        // 1. At most the first `inputLimit` unicode scalars.
        var limited = String.UnicodeScalarView()
        limited.append(contentsOf: s.unicodeScalars.prefix(inputLimit))

        // 2. Controls (C0, DEL, C1) become spaces.
        let sanitized = TerminalText.sanitize(String(limited))

        // 3. Invisible, bidi and layout-breaking scalars go.
        var visible = String.UnicodeScalarView()
        visible.append(contentsOf: sanitized.unicodeScalars.filter { !isRemoved($0) })

        // 4. Runs of whitespace and newlines (U+2028/2029 included) become one space; trimmed.
        var line = ""
        var pendingSpace = false
        for c in String(visible) {
            if c.isWhitespace || c.isNewline {
                pendingSpace = !line.isEmpty
            } else {
                if pendingSpace { line.append(" "); pendingSpace = false }
                line.append(c)
            }
        }

        // 5. Each cluster keeps at most 8 scalars, at most 4 of them combining marks. A cut cluster can end in a scalar
        //    that glues onto the next one (a joiner, a Hangul leading jamo, a prepend), which would rebuild a long cluster;
        //    a cluster that would fuse with the one before it is dropped instead.
        var capped: [Character] = []
        for c in line {
            var kept = String.UnicodeScalarView()
            var marks = 0
            for u in c.unicodeScalars {
                if kept.count == scalarsPerCluster { break }
                if isMark(u) {
                    if marks == marksPerCluster { continue }
                    marks += 1
                }
                kept.append(u)
            }
            let piece = String(kept)
            guard let first = piece.first, piece.count == 1 else { continue }
            if let last = capped.last, (String(last) + piece).count != 2 { continue }
            capped.append(first)
        }
        if capped.isEmpty { return empty }

        // 6. At most `max` clusters, the last one "…" when cut.
        guard capped.count > max else { return String(capped) }
        var head = Array(capped.prefix(max - 1))
        // "…" must stay its own cluster (a cut cluster ending in a prepend scalar would swallow it).
        while let last = head.last, (String(last) + String(ellipsis)).count != 2 { head.removeLast() }
        return String(head) + String(ellipsis)
    }
}
