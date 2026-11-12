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

        // 5. Each cluster keeps at most 8 scalars, at most 4 of them combining marks.
        var capped: [Character] = []
        for c in line { append(capCluster(c), to: &capped) }
        trimBlank(&capped)
        if capped.isEmpty { return empty }

        // 6. At most `max` clusters, the last one "…" when cut.
        var out = capped
        if capped.count > max {
            out = Array(capped.prefix(max - 1))
            append(ellipsis, to: &out)
        }
        let result = String(out)
        // Defence in depth: the repairs above keep every cluster within the caps; should one ever slip through, the label
        // shows "—" rather than an oversized cluster.
        return withinCaps(result, max: max) ? result : empty
    }

    /// The cluster's scalars up to the caps. Skipping a mark can split what is left (a virama that held a conjunct
    /// together, say); only the first cluster of the remainder is kept, so the piece is always exactly one cluster.
    static func capCluster(_ c: Character) -> Character {
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
        return String(kept).first ?? c   // `kept` is never empty: a cluster's first scalar always fits
    }

    /// Appends `piece` so that it stays its own cluster and the cluster before it is unchanged. A cut cluster can end in a
    /// scalar that glues onto what follows (a joiner, a prepend, a Hangul jamo, an unpaired regional indicator, a virama),
    /// which would rebuild a long cluster or shift flag pairs; such trailing scalars are stripped from the previous
    /// cluster, one at a time, until the two segment exactly as two clusters split at the junction.
    static func append(_ piece: Character, to clusters: inout [Character]) {
        while let last = clusters.last {
            let pair = String(last) + String(piece)
            if pair.count == 2, pair.first!.unicodeScalars.count == last.unicodeScalars.count { break }
            clusters.removeLast()
            var shorter = String.UnicodeScalarView(last.unicodeScalars)
            shorter.removeLast()
            // A prefix of a cluster is one cluster; anything else is dropped rather than trusted.
            let rest = String(shorter)
            if let only = rest.first, rest.count == 1 { clusters.append(only) }
        }
        clusters.append(piece)
    }

    /// Blank clusters (only whitespace or joiners, e.g. a space left between two pieces that step 5 shrank, or a lone
    /// U+200C) go at both ends, and a run of spaces becomes one, so the text can never be blank or space-padded.
    static func trimBlank(_ clusters: inout [Character]) {
        func blank(_ c: Character) -> Bool {
            c.unicodeScalars.allSatisfy { $0.properties.isWhitespace || $0.value == 0x200C || $0.value == 0x200D }
        }
        while let f = clusters.first, blank(f) { clusters.removeFirst() }
        while let l = clusters.last, blank(l) { clusters.removeLast() }
        var i = 1
        while i < clusters.count {
            if clusters[i] == " " && clusters[i - 1] == " " { clusters.remove(at: i) } else { i += 1 }
        }
    }

    static func withinCaps(_ text: String, max: Int) -> Bool {
        var count = 0
        for c in text {
            count += 1
            if count > max || c.unicodeScalars.count > scalarsPerCluster
                || c.unicodeScalars.filter(isMark).count > marksPerCluster { return false }
        }
        return true
    }
}
