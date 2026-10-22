import Foundation
import GRDB

extension Store {
    /// A random 32-byte token for one turn, hex. Only its SHA-256 is stored. The token reaches `brahma mcp` through
    /// the 0600 per-turn MCP config, never through the agent's process environment.
    public static func newTurnToken() -> String {
        (0..<32).map { _ in UInt8.random(in: 0...255) }.map { String(format: "%02x", $0) }.joined()
    }

    /// Issues the credential for a turn that is in progress. `kind`/`itemId` let later review turns bind to one item.
    public func issueTurnCredential(turnId: String, kind: String = "work", itemId: String? = nil,
                                    now: Date = Store.now()) throws -> String {
        let token = Store.newTurnToken()
        try writer.write { db in
            guard let turn = try Turn.fetchOne(db, key: turnId) else { throw StoreError.notFound }
            try db.execute(sql: """
                INSERT OR REPLACE INTO turnCredential(turnId, companyId, agentId, kind, itemId, tokenHash, createdAt)
                VALUES (?, ?, ?, ?, ?, ?, ?)
                """, arguments: [turnId, turn.companyId, turn.agentId, kind, itemId, SHA256.hex(token), now])
        }
        return token
    }

    /// The kind and item a live token was issued for, when it belongs to an in-progress turn of exactly this company and agent.
    /// The server derives its mode from this, never from its own command line.
    public func turnCredentialContext(token: String, companyId: String, agentId: String) -> (kind: String, itemId: String?, turnId: String)? {
        guard !token.isEmpty else { return nil }
        let row = try? writer.read { db in
            try Row.fetchOne(db, sql: """
                SELECT c.kind AS kind, c.itemId AS itemId, c.turnId AS turnId FROM turnCredential c JOIN turn t ON t.id = c.turnId
                WHERE c.tokenHash = ? AND c.companyId = ? AND c.agentId = ?
                  AND t.companyId = c.companyId AND t.agentId = c.agentId
                  AND t.outcome = 'inProgress' AND t.endedAt IS NULL
                """, arguments: [SHA256.hex(token), companyId, agentId])
        }
        guard let row, let kind: String = row["kind"], let turnId: String = row["turnId"] else { return nil }
        return (kind, row["itemId"], turnId)
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
