import Foundation

/// A title fit for a chip (design §4.6): NFC, without controls, bidi or zero-width characters, whitespace collapsed to one
/// space, at most `max` characters (cut with `…`), and flagged `confusable` when Latin letters mix with Cyrillic or Greek.
public struct SafeTitle: Equatable, Sendable {
    public static let max = 120

    public var text: String
    public var confusable: Bool

    public init(text: String, confusable: Bool) { self.text = text; self.confusable = confusable }

    public static func make(_ raw: String) -> SafeTitle {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in raw.precomposedStringWithCanonicalMapping.unicodeScalars {
            let v = scalar.value
            if scalar.properties.isWhitespace || v == 0x0A || v == 0x09 || v == 0x0D {
                pendingSpace = true
                continue
            }
            if RefText.isHidden(v) || v == 0x00AD || v == 0x180E { continue }
            if pendingSpace, !out.isEmpty { out.append(" ") }
            pendingSpace = false
            out.append(scalar)
        }
        var text = String(out)
        if text.count > max { text = String(text.prefix(max - 1)) + "\u{2026}" }
        return SafeTitle(text: text, confusable: isConfusable(text))
    }

    /// Latin letters together with Cyrillic or Greek ones.
    static func isConfusable(_ s: String) -> Bool {
        var latin = false, other = false
        for scalar in s.unicodeScalars where scalar.properties.isAlphabetic {
            switch scalar.value {
            case 0x41...0x5A, 0x61...0x7A, 0xC0...0x24F, 0x1E00...0x1EFF: latin = true
            case 0x370...0x3FF, 0x1F00...0x1FFF, 0x400...0x52F, 0x1C80...0x1C8F, 0x2DE0...0x2DFF, 0xA640...0xA69F: other = true
            default: break
            }
        }
        return latin && other
    }
}
