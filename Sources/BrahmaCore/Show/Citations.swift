import Foundation

/// Plan C Task C4c: one claim of a show answer's note: a sentence of at least `CitationCheck.minClaimWords` words, and the
/// source numbers (`[n]`) it names.
public struct Claim: Equatable, Sendable, Codable {
    public var text: String
    public var cites: [Int]

    public init(text: String, cites: [Int]) { self.text = text; self.cites = cites }
}

/// What `CitationCheck.verify` found: every claim, the ones without a valid source, and whether the note is verified.
public struct CitationResult: Equatable, Sendable {
    public var verified: Bool
    public var claims: [Claim]
    /// The claims with no marker `[n]` in `1…refCount`.
    public var uncited: [String]

    public init(verified: Bool, claims: [Claim], uncited: [String]) {
        self.verified = verified; self.claims = claims; self.uncited = uncited
    }
}

/// Cited answers (design §2.3): an answer must cite a source for every claim, or it is shown UNVERIFIED. Plain code, no
/// model: the note is split into sentences (after `.`, `!` or `?` followed by white space or the end, and at every line break);
/// a sentence of at least `minClaimWords` words (markers not counted) is a claim and needs at least one marker `[n]` with
/// `1 ≤ n ≤ refCount`. The note is verified only when every claim has one, no marker anywhere is out of range, and there is at
/// least one source. The refs a marker points at were each resolved `.full` for the caller by `show`, so a citation can't
/// point at something the owner can't open.
public enum CitationCheck {
    public static let minClaimWords = 3

    public static func verify(note: String, refCount: Int) -> CitationResult {
        var claims: [Claim] = []
        var uncited: [String] = []
        var outOfRange = false
        for sentence in sentences(note) {
            let marks = markers(sentence)
            if marks.contains(where: { $0 < 1 || $0 > refCount }) { outOfRange = true }
            guard words(sentence) >= minClaimWords else { continue }
            claims.append(Claim(text: sentence, cites: marks))
            if !marks.contains(where: { $0 >= 1 && $0 <= refCount }) { uncited.append(sentence) }
        }
        return CitationResult(verified: refCount > 0 && !outOfRange && uncited.isEmpty, claims: claims, uncited: uncited)
    }

    /// The note's sentences, trimmed, empty ones dropped.
    static func sentences(_ note: String) -> [String] {
        var out: [String] = []
        var current = ""
        let chars = Array(note)
        func flush() {
            let s = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !s.isEmpty { out.append(s) }
            current = ""
        }
        var i = 0
        while i < chars.count {
            let c = chars[i]
            if c.isNewline { flush(); i += 1; continue }
            current.append(c)
            if c == "." || c == "!" || c == "?" {
                let next = i + 1 < chars.count ? chars[i + 1] : nil
                if next == nil || next!.isWhitespace { flush() }
            }
            i += 1
        }
        flush()
        return out
    }

    /// Every `[n]` in the text, in order (`n` decimal digits).
    static func markers(_ text: String) -> [Int] {
        guard let re = try? NSRegularExpression(pattern: #"\[([0-9]{1,4})\]"#) else { return [] }
        let ns = text as NSString
        return re.matches(in: text, range: NSRange(location: 0, length: ns.length)).compactMap {
            Int(ns.substring(with: $0.range(at: 1)))
        }
    }

    /// Words of the sentence with its markers removed.
    static func words(_ sentence: String) -> Int {
        let bare = sentence.replacingOccurrences(of: #"\[[0-9]{1,4}\]"#, with: " ", options: .regularExpression)
        return bare.split(whereSeparator: { $0.isWhitespace }).filter { word in word.contains(where: { $0.isLetter || $0.isNumber }) }.count
    }
}
