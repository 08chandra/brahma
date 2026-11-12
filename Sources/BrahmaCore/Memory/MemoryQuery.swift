import Foundation

/// Turns what a reader typed into an FTS5 expression of quoted literals only, so no FTS operator, column filter or prefix
/// syntax in the input is ever interpreted.
enum MemoryQuery {
    /// The same tokens joined two ways: `and` (implicit AND) and `or`.
    struct Expr: Equatable {
        var and: String
        var or: String
    }

    static let maxTokens = 12
    static let minTokenLength = 2

    /// NFC; control, bidi and zero-width characters stripped; lowercased. Split on anything that is not a letter or a digit,
    /// keeping `-` inside a token; a hyphenated token becomes the quoted phrase of its parts (`ENG-142` → `"eng 142"`).
    /// Tokens shorter than 2 are dropped (digits excepted); at most 12. Nil when nothing is left.
    static func expression(_ raw: String) -> Expr? {
        var cleaned = String.UnicodeScalarView()
        for scalar in raw.precomposedStringWithCanonicalMapping.unicodeScalars {
            switch scalar.properties.generalCategory {
            // A control character (a newline, a tab) separates words, as it does in the indexed text.
            case .control: cleaned.append(" ")
            // Format characters (bidi controls, zero-width characters, the BOM) are invisible: dropped from inside a word.
            case .format: continue
            default: cleaned.append(scalar)
            }
        }
        let text = String(cleaned).lowercased()

        var words: [String] = []
        var current = ""
        for ch in text {
            if ch.isLetter || ch.isNumber || ch == "-" {
                current.append(ch)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }

        var tokens: [String] = []
        for word in words {
            let parts = word.split(separator: "-").map(String.init)
            guard !parts.isEmpty else { continue }
            let token = parts.joined(separator: " ")
            if parts.count == 1, token.count < minTokenLength, !token.allSatisfy(\.isNumber) { continue }
            let literal = "\"" + token.replacingOccurrences(of: "\"", with: "") + "\""
            if !tokens.contains(literal) { tokens.append(literal) }
            if tokens.count == maxTokens { break }
        }
        guard !tokens.isEmpty else { return nil }
        return Expr(and: tokens.joined(separator: " "), or: tokens.joined(separator: " OR "))
    }
}
