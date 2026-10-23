import Foundation
import GRDB

extension Store {
    static func normalizeChannelName(_ name: String) -> String {
        var n = name.trimmingCharacters(in: .whitespaces)
        while n.hasPrefix("#") { n.removeFirst() }
        return n.lowercased()
    }

    @discardableResult
    static func insertChannel(_ db: Database, companyId: String, name: String, kind: ChannelKind,
                              members: [String], now: Date) throws -> Channel {
        let channel = Channel(id: UUID().uuidString, companyId: companyId, name: name, kind: kind, createdAt: now)
        try channel.insert(db)
        for m in members { try ChannelMember(channelId: channel.id, member: m).insert(db, onConflict: .ignore) }
        return channel
    }

    public func createChannel(companyId: String, name: String, members: [String]) throws -> Channel {
        let normalized = Store.normalizeChannelName(name)
        // ':' is not allowed, so user-created channels can never collide with "dm:<a>:<b>" names.
        guard normalized.range(of: "^[a-z0-9][a-z0-9_-]{0,63}$", options: .regularExpression) != nil
        else { throw StoreError.invalidName }
        let now = Store.now()
        do {
            return try writer.write { db in
                try Store.insertChannel(db, companyId: companyId, name: normalized, kind: .channel, members: members, now: now)
            }
        } catch let error as DatabaseError where error.extendedResultCode == .SQLITE_CONSTRAINT_UNIQUE {
            throw StoreError.duplicateName
        }
    }

    public func channel(companyId: String, name: String) throws -> Channel? {
        let normalized = Store.normalizeChannelName(name)
        return try writer.read { db in
            try Channel.filter(Column("companyId") == companyId && Column("name") == normalized).fetchOne(db)
        }
    }

    public func channels(companyId: String, memberId: String? = nil) throws -> [Channel] {
        try writer.read { db in
            var request = Channel.filter(Column("companyId") == companyId)
            if let memberId {
                request = request.filter(
                    sql: "id IN (SELECT channelId FROM channelMember WHERE member = ?)", arguments: [memberId])
            }
            return try request.order(Column("createdAt"), Column.rowID).fetchAll(db)
        }
    }

    public func members(channelId: String) throws -> [String] {
        try writer.read { db in
            try String.fetchAll(db, sql: "SELECT member FROM channelMember WHERE channelId = ? ORDER BY member",
                                arguments: [channelId])
        }
    }

    public func addMember(channelId: String, member: String) throws {
        try writer.write { db in try ChannelMember(channelId: channelId, member: member).insert(db, onConflict: .ignore) }
    }

    /// Oldest to newest. `before` is exclusive; `limit` keeps the newest matching messages.
    public func messages(channelId: String, limit: Int, before: Date? = nil) throws -> [Message] {
        try writer.read { db in
            var request = Message.filter(Column("channelId") == channelId)
            if let before { request = request.filter(Column("createdAt") < before) }
            return try request.order(Column("createdAt").desc, Column.rowID.desc).limit(limit).fetchAll(db).reversed()
        }
    }

    /// Waking items only, oldest first. Quiet channel traffic is counted by `pendingChannelCounts`.
    public func pendingInbox(agentId: String) throws -> [(InboxItem, Message, Channel)] {
        try writer.read { db in
            let items = try InboxItem.filter(Column("agentId") == agentId && Column("deliveredTurnId") == nil && Column("wakes") == true)
                .order(Column("id")).fetchAll(db)
            return try items.compactMap { item in
                guard let message = try Message.fetchOne(db, key: item.messageId),
                      let channel = try Channel.fetchOne(db, key: message.channelId) else { return nil }
                return (item, message, channel)
            }
        }
    }

    /// Undelivered non-waking items as (item id, channel name).
    func pendingQuietItems(agentId: String) throws -> [(id: Int64, channel: String)] {
        try writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT inboxItem.id AS id, channel.name AS name FROM inboxItem
                JOIN message ON message.id = inboxItem.messageId JOIN channel ON channel.id = message.channelId
                WHERE inboxItem.agentId = ? AND inboxItem.deliveredTurnId IS NULL AND inboxItem.wakes = 0
                ORDER BY inboxItem.id
                """, arguments: [agentId]).map { (id: $0["id"] as Int64, channel: $0["name"] as String) }
        }
    }

    func pendingQuietItemIds(agentId: String) throws -> [Int64] { try pendingQuietItems(agentId: agentId).map(\.id) }

    /// Unread non-waking items per channel, busiest first.
    public func pendingChannelCounts(agentId: String) throws -> [(channel: String, count: Int)] {
        Self.channelCounts(try pendingQuietItems(agentId: agentId))
    }

    static func channelCounts(_ items: [(id: Int64, channel: String)]) -> [(channel: String, count: Int)] {
        var counts: [String: Int] = [:]
        for i in items { counts[i.channel, default: 0] += 1 }
        return counts.map { (channel: $0.key, count: $0.value) }.sorted { ($1.count, $0.channel) < ($0.count, $1.channel) }
    }

    public func markDelivered(itemIds: [Int64], turnId: String) throws {
        guard !itemIds.isEmpty else { return }
        try writer.write { db in try Store.markDelivered(db: db, itemIds: itemIds, turnId: turnId) }
    }

    static func markDelivered(db: Database, itemIds: [Int64], turnId: String) throws {
        guard !itemIds.isEmpty else { return }
        try InboxItem.filter(itemIds.contains(Column("id"))).updateAll(db, Column("deliveredTurnId").set(to: turnId))
    }

    public func searchMessages(companyId: String, query: String, limit: Int = 50) throws -> [Message] {
        // Quote each term so user input cannot be parsed as FTS5 syntax.
        let terms = query.split(whereSeparator: \.isWhitespace)
            .map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        guard !terms.isEmpty else { return [] }
        return try writer.read { db in
            try Message.fetchAll(db, sql: """
                SELECT message.* FROM message
                JOIN messageFts ON messageFts.rowid = message.rowid
                WHERE messageFts MATCH ? AND message.companyId = ?
                ORDER BY bm25(messageFts), message.createdAt DESC LIMIT ?
                """, arguments: [terms.joined(separator: " "), companyId, limit])
        }
    }
}
