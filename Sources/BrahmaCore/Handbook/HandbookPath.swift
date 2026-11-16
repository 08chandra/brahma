import Foundation

/// The name of a handbook page: up to `maxSegments` `/`-separated parts of letters, digits, spaces and `- _ . , & ( ) '`.
/// Normalized to NFC with each part trimmed and its inner spaces collapsed, so the same name typed twice (or composed
/// differently) is the same page. Paths compare case-insensitively in the database (`COLLATE NOCASE`).
public enum HandbookPath {
    public static let maxSegments = 6
    public static let maxSegmentChars = 64
    /// Top-level names the engine keeps for itself (the mirror's index and readme), case-insensitively.
    public static let reserved: Set<String> = ["index", "readme"]

    static let invalidMessage = "handbook paths are up to 6 parts of letters, digits, spaces and - _ . , & ( ) '"
    static let reservedMessage = "INDEX and README are reserved page names"

    /// Punctuation a part may hold besides letters, digits and spaces.
    private static let punctuation: Set<Character> = ["-", "_", ".", ",", "&", "(", ")", "'"]

    /// The canonical page path of `raw` (an optional `kb:` prefix and `#section` suffix are dropped).
    public static func normalize(_ raw: String) throws -> String { try normalizeRef(raw).path }

    /// The canonical page path of `raw` and the section it names after `#` (trimmed; nil when there is none). Throws
    /// `WorkError.invalid` for anything that is not a page name.
    public static func normalizeRef(_ raw: String) throws -> (path: String, section: String?) {
        var text = raw.precomposedStringWithCanonicalMapping.trimmingCharacters(in: .whitespaces)
        if text.lowercased().hasPrefix("kb:") { text = String(text.dropFirst(3)) }
        var section: String?
        if let hash = text.firstIndex(of: "#") {
            let rest = text[text.index(after: hash)...].trimmingCharacters(in: .whitespaces)
            section = rest.isEmpty ? nil : rest
            text = String(text[..<hash])
        }
        let parts = text.split(separator: "/", omittingEmptySubsequences: false).map { collapse(String($0)) }
        guard (1...maxSegments).contains(parts.count), parts.allSatisfy(isValidSegment) else {
            throw WorkError.invalid(invalidMessage)
        }
        if parts.count == 1, reserved.contains(parts[0].lowercased()) { throw WorkError.invalid(reservedMessage) }
        return (parts.joined(separator: "/"), section)
    }

    /// What two paths compare as when looking for look-alikes: compatibility-normalized (NFKC) and case-folded.
    static func foldKey(_ path: String) -> String {
        path.precomposedStringWithCompatibilityMapping.folding(options: [.caseInsensitive], locale: nil)
    }

    /// The page's section: its first part.
    public static func section(of path: String) -> String {
        String(path.split(separator: "/", omittingEmptySubsequences: false).first ?? Substring(path))
    }

    /// The title a page gets when none is given: its last part.
    public static func defaultTitle(of path: String) -> String {
        String(path.split(separator: "/", omittingEmptySubsequences: false).last ?? Substring(path))
    }

    /// Trimmed of spaces at both ends, with every run of inner spaces as one space. Other whitespace is left in place (and
    /// refused by `isValidSegment`).
    private static func collapse(_ s: String) -> String {
        var out = ""
        var pendingSpace = false
        for ch in s {
            if ch == " " {
                pendingSpace = true
            } else {
                if pendingSpace, !out.isEmpty { out.append(" ") }
                pendingSpace = false
                out.append(ch)
            }
        }
        return out
    }

    private static func isValidSegment(_ s: String) -> Bool {
        guard (1...maxSegmentChars).contains(s.count), !s.hasPrefix(".") else { return false }
        // No control, format (bidi, zero-width), separator, private-use or unassigned scalar anywhere: a joiner attaches to
        // the letter before it, so the per-character check below would not see it.
        for scalar in s.unicodeScalars {
            switch scalar.properties.generalCategory {
            case .control, .format, .lineSeparator, .paragraphSeparator, .surrogate, .privateUse, .unassigned: return false
            case .spaceSeparator where scalar != " ": return false
            default: continue
            }
        }
        return s.allSatisfy { $0 == " " || $0.isLetter || $0.isNumber || punctuation.contains($0) }
    }
}
