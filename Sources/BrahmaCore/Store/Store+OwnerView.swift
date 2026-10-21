import Foundation
import GRDB

extension Store {
    /// Records that the owner has read `channelId` up to `upTo`. Never moves the mark backward.
    public func markRead(channelId: String, upTo: Date) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO ownerReadMark(channelId, lastReadAt) VALUES (?, ?)
                ON CONFLICT(channelId) DO UPDATE SET lastReadAt = max(lastReadAt, excluded.lastReadAt)
                """, arguments: [channelId, upTo])
        }
    }

    /// Unread message counts per channel id for the owner: channels plus DMs the owner is in; zero counts omitted.
    public func unreadCounts(companyId: String) throws -> [String: Int] {
        try writer.read { db in
            let rows = try Row.fetchAll(db, sql: """
                SELECT m.channelId AS channelId, COUNT(*) AS n
                FROM message m
                JOIN channel c ON c.id = m.channelId
                LEFT JOIN ownerReadMark r ON r.channelId = m.channelId
                WHERE c.companyId = ?
                  AND (c.kind = 'channel'
                       OR (c.kind = 'dm' AND EXISTS (
                           SELECT 1 FROM channelMember cm WHERE cm.channelId = c.id AND cm.member = 'owner')))
                  AND m.senderId != 'owner'
                  AND (r.lastReadAt IS NULL OR m.createdAt > r.lastReadAt)
                GROUP BY m.channelId
                """, arguments: [companyId])
            return Dictionary(uniqueKeysWithValues: rows.map { ($0["channelId"] as String, $0["n"] as Int) })
        }
    }

    /// Re-reads the company, applies `change` and writes it back in one transaction.
    @discardableResult
    public func updateCompany(id: String, _ change: (inout Company) -> Void) throws -> Company {
        try writer.write { db in
            guard var company = try Company.fetchOne(db, key: id) else { throw StoreError.notFound }
            change(&company)
            try company.update(db)
            return company
        }
    }

    /// The newest `limit` events for the company, oldest first.
    public func recentEvents(companyId: String, limit: Int) throws -> [ActivityEvent] {
        try writer.read { db in
            try ActivityEvent.filter(Column("companyId") == companyId)
                .order(Column("id").desc).limit(limit).fetchAll(db).reversed()
        }
    }
}
