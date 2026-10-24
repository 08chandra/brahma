import Foundation
import GRDB

/// One captured turn: its slice of the Claude session transcript, redacted and compressed (`TranscriptCapture`).
public struct TurnTranscript: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "turnTranscript"

    public var turnId: String
    public var companyId: String
    public var agentId: String
    public var sessionId: String
    /// Relative to the data home: `transcripts/<companyId>/<agentId>/<sessionId>/<turnId>.jsonl.<zst|gz>`.
    public var path: String
    /// The bytes of the source session file this turn covers: `[byteStart, byteEnd)`, ending after a newline.
    public var byteStart: Int64
    public var byteEnd: Int64
    /// `zst` or `gz`.
    public var codec: String
    /// StableHash (FNV-1a 64) of the stored content before compression: checked when the transcript is read back.
    public var sha: String
    public var capturedAt: Date
}

extension Store {
    /// The captured slice of a turn, if any.
    public func transcript(turnId: String) throws -> TurnTranscript? {
        try writer.read { db in try TurnTranscript.fetchOne(db, key: turnId) }
    }

    /// The end of the newest capture of a session: where the next capture of it starts.
    func lastTranscriptEnd(sessionId: String) throws -> Int64? {
        try writer.read { db in
            try Int64.fetchOne(db, sql: "SELECT byteEnd FROM turnTranscript WHERE sessionId = ? ORDER BY capturedAt DESC, rowid DESC LIMIT 1",
                               arguments: [sessionId])
        }
    }

    func recordTranscript(_ row: TurnTranscript) throws {
        try writer.write { db in try row.insert(db) }
    }

    /// A company's captured turns whose id starts with `prefix` (oldest first).
    public func transcripts(companyId: String, turnIdPrefix prefix: String) throws -> [TurnTranscript] {
        let escaped = prefix.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return try writer.read { db in
            try TurnTranscript.fetchAll(db, sql: "SELECT * FROM turnTranscript WHERE companyId = ? AND turnId LIKE ? ESCAPE '\\' ORDER BY capturedAt, rowid",
                                        arguments: [companyId, escaped + "%"])
        }
    }

    /// An agent's newest `limit` captured turns, returned oldest first.
    public func recentTranscripts(companyId: String, agentId: String, limit: Int) throws -> [TurnTranscript] {
        try writer.read { db in
            try TurnTranscript.fetchAll(db, sql: """
                SELECT * FROM (SELECT *, rowid AS rid FROM turnTranscript WHERE companyId = ? AND agentId = ?
                               ORDER BY capturedAt DESC, rowid DESC LIMIT ?)
                ORDER BY capturedAt, rid
                """, arguments: [companyId, agentId, max(1, limit)])
        }
    }
}
