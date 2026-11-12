import Foundation
import GRDB

/// One message as the live map draws it: who sent it, to whom, where (Plan 4b Task 1a).
public struct MessageFlow: Equatable, Sendable {
    public var rowId: Int64
    public var messageId: String
    public var companyId: String
    /// Agent id or `"owner"`; never `"system"` (system traffic is excluded in SQL).
    public var senderId: String
    public var channelId: String
    public var channelName: String
    public var channelKind: ChannelKind
    /// The `message.kind` text (`text` until Collab-MVP adds the column).
    public var kind: String
    /// DM: the channel's other members (agent ids or `"owner"`). Channel: the non-killed company agents whose handle is
    /// @mentioned, excluding the sender, in mention order.
    public var recipientIds: [String]
    /// `t` when the channel name is `team-<t>`.
    public var team: String?
    public var createdAt: Date

    public init(rowId: Int64, messageId: String, companyId: String, senderId: String, channelId: String, channelName: String,
                channelKind: ChannelKind, kind: String, recipientIds: [String], team: String?, createdAt: Date) {
        self.rowId = rowId; self.messageId = messageId; self.companyId = companyId; self.senderId = senderId
        self.channelId = channelId; self.channelName = channelName; self.channelKind = channelKind; self.kind = kind
        self.recipientIds = recipientIds; self.team = team; self.createdAt = createdAt
    }
}

/// One hand-off as the live map draws it.
public struct HandoffFlow: Equatable, Sendable {
    public var rowId: Int64
    public var id: String
    public var itemKey: String
    public var authorId: String
    public var toAgentId: String?
    public var createdAt: Date

    public init(rowId: Int64, id: String, itemKey: String, authorId: String, toAgentId: String?, createdAt: Date) {
        self.rowId = rowId; self.id = id; self.itemKey = itemKey; self.authorId = authorId; self.toAgentId = toAgentId
        self.createdAt = createdAt
    }
}

/// Read-only, company-scoped feeds the map controller polls. Every query filters by `companyId`: rowids are global
/// across companies, and the handle → id map, the DM memberships and the mention resolution are built from that
/// company's rows only. Each call is one read transaction.
extension Store {
    // MARK: Live (cursor) feeds

    /// Messages after `afterRowId`, ascending rowid, at most `limit`.
    public func messageFlows(companyId: String, afterRowId: Int64, limit: Int = 500) throws -> [MessageFlow] {
        try writer.read { db in
            try Self.messageFlows(db, companyId: companyId, where: "m.rowid > ?", arguments: [afterRowId], limit: limit)
        }
    }

    /// The company's newest message rowid (system rows included: the cursor advances past them), 0 when none.
    public func maxMessageRowId(companyId: String) throws -> Int64 {
        try writer.read { db in try Self.maxRowId(db, table: "message", companyId: companyId) }
    }

    /// Hand-offs after `afterRowId`, ascending rowid, at most `limit`.
    public func handoffFlows(companyId: String, afterRowId: Int64, limit: Int = 200) throws -> [HandoffFlow] {
        try writer.read { db in
            try Self.handoffFlows(db, companyId: companyId, where: "h.rowid > ?", arguments: [afterRowId], limit: limit)
        }
    }

    /// The company's newest hand-off rowid, 0 when none.
    public func maxHandoffRowId(companyId: String) throws -> Int64 {
        try writer.read { db in try Self.maxRowId(db, table: "handoff", companyId: companyId) }
    }

    // MARK: Range feeds (half-open `[since, until)`, ascending)

    /// `truncated` is set when more than `limit` rows fall in the range (the query fetches `limit + 1`).
    public func messageFlows(companyId: String, since: Date, until: Date, limit: Int = 20_000) throws -> (flows: [MessageFlow], truncated: Bool) {
        try writer.read { db in
            var flows = try Self.messageFlows(db, companyId: companyId, where: "m.createdAt >= ? AND m.createdAt < ?",
                                              arguments: [since, until], limit: limit + 1)
            let truncated = flows.count > limit
            if truncated { flows.removeLast(flows.count - limit) }
            return (flows, truncated)
        }
    }

    public func handoffFlows(companyId: String, since: Date, until: Date) throws -> [HandoffFlow] {
        try writer.read { db in
            try Self.handoffFlows(db, companyId: companyId, where: "h.createdAt >= ? AND h.createdAt < ?",
                                  arguments: [since, until], limit: nil)
        }
    }

    /// The company's activity events of the given kinds in the range, ascending id.
    public func events(companyId: String, kinds: Set<ActivityKind>, since: Date, until: Date, limit: Int = 20_000) throws -> [ActivityEvent] {
        guard !kinds.isEmpty else { return [] }
        return try writer.read { db in
            try ActivityEvent
                .filter(Column("companyId") == companyId)
                .filter(kinds.map(\.rawValue).sorted().contains(Column("kind")))
                .filter(Column("createdAt") >= since && Column("createdAt") < until)
                .order(Column("id")).limit(limit).fetchAll(db)
        }
    }

    // MARK: Queries

    /// A reverse rowid scan that stops at the company's newest row.
    private static func maxRowId(_ db: Database, table: String, companyId: String) throws -> Int64 {
        try Int64.fetchOne(db, sql: "SELECT rowid FROM \(table) WHERE companyId = ? ORDER BY rowid DESC LIMIT 1", arguments: [companyId]) ?? 0
    }

    /// Schema seam: Collab-MVP's `message.kind` (`text|share|showRequest|showAnswer|fileAsk|system`) is not on this
    /// branch yet. When the column exists the query selects it and excludes `kind = 'system'` in SQL; until then every
    /// row is `kind = "text"` and only `senderId = 'system'` is excluded. `message.parentId` is never read: a thread
    /// reply resolves its recipients exactly like a post in its channel or DM. The detection becomes a no-op (always
    /// true) once the column lands; nothing else here changes.
    private static func messageFlows(_ db: Database, companyId: String, where predicate: String, arguments: StatementArguments,
                                     limit: Int) throws -> [MessageFlow] {
        let hasKind = try db.columns(in: "message").contains { $0.name == "kind" }
        let kindSelect = hasKind ? "COALESCE(m.kind, 'text')" : "'text'"
        let kindFilter = hasKind ? " AND COALESCE(m.kind, 'text') <> 'system'" : ""
        var args: StatementArguments = [companyId]
        args += arguments
        args += [limit]
        let rows = try Row.fetchAll(db, sql: """
            SELECT m.rowid AS rowId, m.id AS messageId, m.companyId, m.senderId, m.channelId, m.text, m.createdAt,
                   \(kindSelect) AS kind, c.name AS channelName, c.kind AS channelKind
            FROM message m JOIN channel c ON c.id = m.channelId
            WHERE m.companyId = ? AND \(predicate) AND m.senderId <> 'system'\(kindFilter)
            ORDER BY m.rowid LIMIT ?
            """, arguments: args)
        guard !rows.isEmpty else { return [] }

        // Loaded once per call: this company's live handles and its DM memberships.
        let idByHandle: [String: String] = try Row.fetchAll(db, sql: "SELECT name, id FROM agent WHERE companyId = ? AND state <> ?",
                                                            arguments: [companyId, AgentState.killed.rawValue])
            .reduce(into: [:]) { $0[$1["name"]] = $1["id"] }
        let dmMembers: [String: [String]] = try Row.fetchAll(db, sql: """
            SELECT cm.channelId, cm.member FROM channelMember cm
            JOIN channel c ON c.id = cm.channelId
            WHERE c.companyId = ? AND c.kind = ? ORDER BY cm.rowid
            """, arguments: [companyId, ChannelKind.dm.rawValue])
            .reduce(into: [:]) { $0[$1["channelId"], default: []].append($1["member"]) }

        return rows.map { row in
            let senderId: String = row["senderId"]
            let channelId: String = row["channelId"]
            let channelName: String = row["channelName"]
            let channelKind = ChannelKind(rawValue: row["channelKind"]) ?? .channel
            let recipientIds: [String]
            switch channelKind {
            case .dm:
                recipientIds = (dmMembers[channelId] ?? []).filter { $0 != senderId }
            case .channel:
                let text: String = row["text"]
                recipientIds = MessageRouter.mentions(in: text).compactMap { idByHandle[$0] }.filter { $0 != senderId }
            }
            return MessageFlow(rowId: row["rowId"], messageId: row["messageId"], companyId: row["companyId"], senderId: senderId,
                               channelId: channelId, channelName: channelName, channelKind: channelKind, kind: row["kind"],
                               recipientIds: recipientIds, team: team(ofChannelNamed: channelName), createdAt: row["createdAt"])
        }
    }

    private static func handoffFlows(_ db: Database, companyId: String, where predicate: String, arguments: StatementArguments,
                                     limit: Int?) throws -> [HandoffFlow] {
        var args: StatementArguments = [companyId]
        args += arguments
        var sql = """
            SELECT h.rowid AS rowId, h.id, h.authorId, h.toAgentId, h.createdAt, w.key AS itemKey
            FROM handoff h JOIN workItem w ON w.id = h.itemId
            WHERE h.companyId = ? AND \(predicate)
            ORDER BY h.rowid
            """
        if let limit { sql += " LIMIT ?"; args += [limit] }
        return try Row.fetchAll(db, sql: sql, arguments: args).map { row in
            HandoffFlow(rowId: row["rowId"], id: row["id"], itemKey: row["itemKey"], authorId: row["authorId"],
                        toAgentId: row["toAgentId"], createdAt: row["createdAt"])
        }
    }

    /// `"team-core"` → `"core"`; anything else → nil.
    private static func team(ofChannelNamed name: String) -> String? {
        guard name.hasPrefix("team-") else { return nil }
        let team = String(name.dropFirst("team-".count))
        return team.isEmpty ? nil : team
    }
}
