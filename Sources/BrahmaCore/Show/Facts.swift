import Foundation

// Plan C Task C4a defines these value types exactly as Task C4b lists them, so `ShowResult` compiles before the facts
// resolver exists. C4b answers them (`FactsResolver`); nothing in C4a builds one.

/// What a factual question asks about (C4b's one trigger per kind).
public enum FactKind: String, CaseIterable, Codable, Sendable {
    case usage, blocked, whoIsOn, shipped, pendingAsks, sprintProgress, failingChecks
}

/// One line of a fact answer.
public struct FactLine: Equatable, Sendable, Codable {
    /// Engine-composed; any agent text inside is flattened and cut to 80 characters.
    public var text: String
    /// At least one.
    public var refs: [WorkRef]

    public init(text: String, refs: [WorkRef]) { self.text = text; self.refs = refs }
}

/// An engine-composed answer to a factual question (no LLM).
public struct FactAnswer: Equatable, Sendable, Codable {
    public static let maxLines = 12

    public var kind: FactKind
    /// `"BLOCKED · 3 ITEMS, 1 AGENT"`.
    public var title: String
    /// At most `maxLines`, then `"and <n> more"`, whose ref is the matching search.
    public var lines: [FactLine]
    /// `"Nothing is blocked."`.
    public var emptyText: String?
    public var asOf: Date
    public var query: String

    public init(kind: FactKind, title: String, lines: [FactLine], emptyText: String?, asOf: Date, query: String) {
        self.kind = kind; self.title = title; self.lines = lines; self.emptyText = emptyText; self.asOf = asOf; self.query = query
    }
}
