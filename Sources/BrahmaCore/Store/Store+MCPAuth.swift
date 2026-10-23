import Foundation
import GRDB

/// What a live turn credential was issued for. The server derives its whole mode from this, never from its command line or
/// environment.
public struct TurnCredentialContext: Equatable, Sendable {
    public var turnId: String
    public var kind: String
    public var itemId: String?
    /// The turn's MCP quotas: as recorded at issue for a work or plan credential, the strictest when none were recorded (fail
    /// closed); nil for a review credential (its server offers only the review tools).
    public var quotas: ModeQuotas?
}

/// The turn a server or a quota unit is for is no longer in progress, or holds no credential row.
public struct TurnNotLive: Error, CustomStringConvertible, Sendable {
    public var turnId: String
    public var description: String { "turn \(turnId) has ended or holds no credential" }
}

extension Store {
    /// A random 32-byte token for one turn, hex. Only its SHA-256 is stored. The token reaches `brahma mcp` through
    /// the 0600 per-turn MCP config, never through the agent's process environment.
    public static func newTurnToken() -> String {
        (0..<32).map { _ in UInt8.random(in: 0...255) }.map { String(format: "%02x", $0) }.joined()
    }

    /// Issues the credential for a turn that is in progress. `kind`/`itemId` let later review turns bind to one item; `quotas`
    /// are the work or plan turn's mode quotas, which `brahma mcp` enforces from this row.
    public func issueTurnCredential(turnId: String, kind: String = "work", itemId: String? = nil, quotas: ModeQuotas? = nil,
                                    now: Date = Store.now()) throws -> String {
        let token = Store.newTurnToken()
        let encoded = try quotas.map { String(decoding: try JSONEncoder().encode($0), as: UTF8.self) }
        try writer.write { db in
            guard let turn = try Turn.fetchOne(db, key: turnId) else { throw StoreError.notFound }
            try db.execute(sql: """
                INSERT OR REPLACE INTO turnCredential(turnId, companyId, agentId, kind, itemId, tokenHash, createdAt, quotas)
                VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                """, arguments: [turnId, turn.companyId, turn.agentId, kind, itemId, SHA256.hex(token), now, encoded])
        }
        return token
    }

    /// What a live token was issued for, when it belongs to an in-progress turn of exactly this company and agent.
    /// The server derives its mode from this, never from its own command line or environment.
    public func turnCredentialContext(token: String, companyId: String, agentId: String) -> TurnCredentialContext? {
        guard !token.isEmpty else { return nil }
        let row = try? writer.read { db in
            try Row.fetchOne(db, sql: """
                SELECT c.turnId AS turnId, c.kind AS kind, c.itemId AS itemId, c.quotas AS quotas
                FROM turnCredential c JOIN turn t ON t.id = c.turnId
                WHERE c.tokenHash = ? AND c.companyId = ? AND c.agentId = ?
                  AND t.companyId = c.companyId AND t.agentId = c.agentId
                  AND t.outcome = 'inProgress' AND t.endedAt IS NULL
                """, arguments: [SHA256.hex(token), companyId, agentId])
        }
        guard let row, let kind: String = row["kind"], let turnId: String = row["turnId"] else { return nil }
        var quotas: ModeQuotas?
        if kind != "review", kind != "audit" {
            // Unrecorded or unreadable quotas on a work or plan credential: the strictest (fail closed).
            let stored: String? = row["quotas"]
            quotas = stored.flatMap { try? JSONDecoder().decode(ModeQuotas.self, from: Data($0.utf8)) } ?? .strictest
        }
        return TurnCredentialContext(turnId: turnId, kind: kind, itemId: row["itemId"], quotas: quotas)
    }

    /// The turn is in progress and still holds its credential row: what every call of its MCP server needs (A5). A server
    /// that outlives its turn (or a turn whose credential is gone) is refused, whatever the tool.
    public func turnCredentialIsLive(turnId: String, companyId: String, agentId: String) throws -> Bool {
        try writer.read { db in try Self.turnCredentialIsLive(db, turnId: turnId, companyId: companyId, agentId: agentId) }
    }

    static func turnCredentialIsLive(_ db: Database, turnId: String, companyId: String? = nil, agentId: String? = nil) throws -> Bool {
        try Bool.fetchOne(db, sql: """
            SELECT EXISTS(SELECT 1 FROM turnCredential c JOIN turn t ON t.id = c.turnId
                          WHERE c.turnId = ? AND t.companyId = c.companyId AND t.agentId = c.agentId
                            AND (? IS NULL OR c.companyId = ?) AND (? IS NULL OR c.agentId = ?)
                            AND t.outcome = 'inProgress' AND t.endedAt IS NULL)
            """, arguments: [turnId, companyId, companyId, agentId, agentId]) ?? false
    }

    // MARK: Per-turn quota counts

    /// Takes one unit of the turn's `kind` quota when fewer than `limit` are used, in one write transaction, so concurrent
    /// server processes of the same turn can never overshoot. False when the quota is used up. A turn without a live
    /// credential row (it ended, or it never had one) takes nothing and throws `TurnNotLive`.
    public func reserveTurnQuota(turnId: String, kind: String, limit: Int) throws -> Bool {
        // Write first (no read-then-upgrade), and the increment is conditional in the same statement.
        try writer.write { db in
            guard try Self.turnCredentialIsLive(db, turnId: turnId) else { throw TurnNotLive(turnId: turnId) }
            try db.execute(sql: "INSERT INTO turnQuotaUsage(turnId, kind, used) VALUES (?, ?, 0) ON CONFLICT(turnId, kind) DO NOTHING",
                           arguments: [turnId, kind])
            try db.execute(sql: "UPDATE turnQuotaUsage SET used = used + 1 WHERE turnId = ? AND kind = ? AND used < ?",
                           arguments: [turnId, kind, limit])
            return db.changesCount > 0
        }
    }

    /// Gives back a unit taken by `reserveTurnQuota` when the call it was for failed (a failed call costs nothing).
    public func releaseTurnQuota(turnId: String, kind: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE turnQuotaUsage SET used = MAX(0, used - 1) WHERE turnId = ? AND kind = ?",
                           arguments: [turnId, kind])
        }
    }

    public func turnQuotaUsed(turnId: String, kind: String) throws -> Int {
        try writer.read { db in
            try Int.fetchOne(db, sql: "SELECT used FROM turnQuotaUsage WHERE turnId = ? AND kind = ?", arguments: [turnId, kind]) ?? 0
        }
    }

    /// True only when the token's hash matches a credential whose turn is still in progress for exactly this
    /// company, agent, kind and item. Fails closed on any other state.
    public func verifyTurnCredential(token: String, companyId: String, agentId: String,
                                     kind: String = "work", itemId: String? = nil) -> Bool {
        guard !token.isEmpty else { return false }
        let found = try? writer.read { db in
            try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM turnCredential c JOIN turn t ON t.id = c.turnId
                WHERE c.tokenHash = ? AND c.companyId = ? AND c.agentId = ? AND c.kind = ? AND c.itemId IS ?
                  AND t.companyId = c.companyId AND t.agentId = c.agentId
                  AND t.outcome = 'inProgress' AND t.endedAt IS NULL
                """, arguments: [SHA256.hex(token), companyId, agentId, kind, itemId])
        }
        return (found ?? 0) > 0
    }
}
