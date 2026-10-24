import Foundation
import GRDB

/// One send attempt of the push dispatcher.
public struct PushLogEntry: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "pushLog"

    public var id: Int64?
    public var sentAt: Date
    public var ok: Bool
    public var status: Int?
    /// Engine text only: `urgent`, `normal`, `cap`, `test`, or an error class. Never a payload.
    public var detail: String?

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

extension Store {
    // MARK: Settings

    /// Turns phone alerts off (`nil`) or on for a provider. Switching them on marks every existing notice as pushed, so
    /// a backlog from before is not sent as a flood; asks still waiting are pushed (once).
    public func setPush(provider: PushProvider?, topic: String? = nil, server: String? = nil, now: Date = Store.now()) throws {
        var prefs = try ownerPrefs()
        let wasOff = prefs.pushProvider == nil
        prefs.pushProvider = provider
        if provider == .ntfy { prefs.pushTopic = topic }
        if let server { prefs.pushServer = server }
        try updateOwnerPrefs(prefs, now: now)
        if wasOff, provider != nil {
            try writer.write { db in try db.execute(sql: "UPDATE ownerNotice SET pushedAt = ? WHERE pushedAt IS NULL", arguments: [now]) }
        }
    }

    public func setPushDetail(_ detail: PushDetail, now: Date = Store.now()) throws {
        var prefs = try ownerPrefs()
        prefs.pushDetail = detail
        try updateOwnerPrefs(prefs, now: now)
    }

    // MARK: What is due

    /// Notices not yet pushed, oldest first.
    public func duePushNotices(limit: Int = 200) throws -> [OwnerNotice] {
        try writer.read { db in
            try OwnerNotice.filter(sql: "pushedAt IS NULL").order(Column("id")).limit(limit).fetchAll(db)
        }
    }

    /// Marks these pushed (called only after the push got a 2xx).
    public func markPushed(askIds: [String], noticeIds: [Int64], now: Date) throws {
        guard !askIds.isEmpty || !noticeIds.isEmpty else { return }
        try writer.write { db in
            for id in askIds { try db.execute(sql: "UPDATE ask SET pushedAt = ? WHERE id = ? AND pushedAt IS NULL", arguments: [now, id]) }
            for id in noticeIds { try db.execute(sql: "UPDATE ownerNotice SET pushedAt = ? WHERE id = ? AND pushedAt IS NULL", arguments: [now, id]) }
        }
    }

    // MARK: Log

    /// Records an attempt. Rows older than 30 days go with it.
    public func logPush(ok: Bool, status: Int?, detail: String, now: Date) throws {
        try writer.write { db in
            var row = PushLogEntry(id: nil, sentAt: now, ok: ok, status: status, detail: detail)
            try row.insert(db)
            try db.execute(sql: "DELETE FROM pushLog WHERE sentAt < ?", arguments: [now.addingTimeInterval(-30 * 86400)])
        }
    }

    public func pushLog(limit: Int = 50) throws -> [PushLogEntry] {
        try writer.read { db in try PushLogEntry.order(Column("id").desc).limit(limit).fetchAll(db).reversed() }
    }

    /// Successful pushes since `start` (the cap's one final push does not count), and whether that final push went.
    func pushCounts(since start: Date) throws -> (sent: Int, capNoticeSent: Bool) {
        try writer.read { db in
            let sent = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pushLog WHERE ok = 1 AND sentAt >= ? AND COALESCE(detail, '') NOT IN ('cap', 'test')",
                                        arguments: [start]) ?? 0
            let cap = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM pushLog WHERE ok = 1 AND sentAt >= ? AND detail = 'cap'", arguments: [start]) ?? 0
            return (sent, cap > 0)
        }
    }
}
