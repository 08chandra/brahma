import Foundation

/// Text Brahma did not write and must never treat as instructions (Ruling 14, the stand-in for `Untrusted<String>`): an agent's
/// note, an issue body, a review comment. `source` says where it came from in the engine's words ("review note by @rev-1"),
/// and every renderer shows it as data — quoted, capped, never as a heading, a mention or a reference.
public struct ExternalText: Codable, Equatable, Sendable {
    public var text: String
    public var source: String

    public init(text: String, source: String) { self.text = text; self.source = source }
}
