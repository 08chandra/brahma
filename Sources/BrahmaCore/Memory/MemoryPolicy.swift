import Foundation

/// The pinned numbers of company memory, and its ranking functions.
public enum MemoryPolicy {
    /// Search hits returned by default, and at most.
    public static let defaultHits = 5
    public static let maxHits = 10
    /// Candidate rows a search pass reads from the index before the access engine filters them.
    public static let candidateRows = 200
    /// An AND search with fewer readable hits than this is rerun as OR.
    public static let orFallbackBelow = 3
    /// Snippet length: tokens around the match, and characters at most.
    public static let snippetTokens = 24
    public static let snippetChars = 240
    /// bm25 column weights (title, body).
    public static let bm25Weights = (title: 3.0, body: 1.0)
    /// Indexed caps.
    public static let maxBodyChars = 200_000
    public static let maxTitleChars = 160
    /// `recall(ref:)` / `kb_read` output bound: whichever comes first.
    public static let readLines = 400
    public static let readBytes = 40_960
    /// `remember`: the fact's length, the key's form, the rate per agent per active hour, the defaults and the TTL range.
    public static let maxFactChars = 600
    public static let keyPattern = "^[a-z0-9][a-z0-9._-]{0,79}$"
    public static let rememberPerActiveHour = 30
    public static let defaultConfidence = 0.7
    public static let maxTTLDays = 90

    /// `0.3 + 0.7 × 0.5^(ageDays / 14)`; `age` in seconds since `max(updatedAt, lastRecalledAt)` (a future date counts as 0).
    public static func recency(_ age: TimeInterval) -> Double {
        0.3 + 0.7 * pow(0.5, max(age, 0) / 86_400 / 14)
    }

    /// A memory entry's ranking weight: `(0.5 + 0.5 × confidence) × (1 + 0.1 × min(confirmations, 5))`, halved when an
    /// untainted entry contradicts it.
    public static func entryWeight(confidence: Double, confirmations: Int, contradicted: Bool) -> Double {
        (0.5 + 0.5 * confidence) * (1 + 0.1 * Double(min(max(confirmations, 0), 5))) * (contradicted ? 0.5 : 1)
    }
}
