import Foundation
import GRDB

/// How one item relates to a landed item (Plan X6a Task 2; `docs/measure/metrics.md`, "escaped" and "revert").
public enum ItemLinkKind: String, Codable, Sendable, CaseIterable {
    /// The item is a defect found after the target landed.
    case regressionOf
    /// The item undoes the target's change.
    case revertOf

    /// `regression of` / `revert of`: the words a refusal and the CLI use.
    public var phrase: String {
        switch self {
        case .regressionOf: "regression of"
        case .revertOf: "revert of"
        }
    }

    /// `regression-of`, `regressionOf`, `regression_of` (any case) → `.regressionOf`; same for `revert`.
    public init?(spelling: String) {
        let norm = spelling.lowercased().replacingOccurrences(of: "-", with: "").replacingOccurrences(of: "_", with: "")
        guard let kind = Self.allCases.first(where: { $0.rawValue.lowercased() == norm }) else { return nil }
        self = kind
    }
}

/// One row of `workItemLink`: `itemId` is a `kind` of `targetId`. `createdBy` is `"owner"` (the CLI), an agent id (`create_work_item`)
/// or `"system"` (a failed audit's follow-up).
public struct ItemLink: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "workItemLink"

    public var companyId: String
    public var itemId: String
    public var kind: ItemLinkKind
    public var targetId: String
    public var createdBy: String
    public var createdAt: Date

    public init(companyId: String, itemId: String, kind: ItemLinkKind, targetId: String, createdBy: String, createdAt: Date) {
        self.companyId = companyId; self.itemId = itemId; self.kind = kind; self.targetId = targetId; self.createdBy = createdBy
        self.createdAt = createdAt
    }
}

extension Store {
    // MARK: Links

    /// Records that `itemKey` is a `kind` of `targetKey`, both keys of `companyId`'s items (matched like every key: trimmed, any
    /// case). Refused: an unknown key or one of another company (`WorkError.notFound`, the same words as a missing item), a target
    /// that has not landed (`<KEY> has not landed; only landed items can regress or be reverted`), the item itself. The same link
    /// twice is one link.
    public func linkItem(companyId: String, itemKey: String, kind: ItemLinkKind, targetKey: String, by actor: String, now: Date = Store.now()) throws {
        try writer.write { db in
            let item = try Self.item(db, companyId: companyId, key: itemKey)
            let target = try Self.item(db, companyId: companyId, key: targetKey)
            try linkItem(db: db, item: item, kind: kind, target: target, by: actor, now: now)
        }
    }

    /// The in-transaction form, for a write that creates the item and links it in one step: nothing is created when the link is
    /// refused. `item` and `target` are rows of the same company (the caller resolved both within it).
    func linkItem(db: Database, item: WorkItem, kind: ItemLinkKind, target: WorkItem, by actor: String, now: Date) throws {
        guard item.companyId == target.companyId else { throw WorkError.notFound(Self.noSuchItem(target.key)) }
        guard item.id != target.id else { throw WorkError.invalid("\(item.key) cannot be a \(kind.phrase) itself") }
        try Self.requireLanded(db, target)
        try Self.insertLink(db, ItemLink(companyId: item.companyId, itemId: item.id, kind: kind, targetId: target.id, createdBy: actor, createdAt: now))
    }

    /// Only a landed item can be regressed or reverted (metrics.md: "landed item").
    static func requireLanded(_ db: Database, _ target: WorkItem) throws {
        guard try hasLanded(db, companyId: target.companyId, itemId: target.id) else {
            throw WorkError.invalid("\(target.key) has not landed; only landed items can regress or be reverted")
        }
    }

    /// The engine's own link (a failed audit's follow-up): the engine knows the target landed, so nothing is checked here beyond
    /// the primary key.
    static func insertLink(_ db: Database, _ link: ItemLink) throws {
        try db.execute(sql: """
            INSERT OR IGNORE INTO workItemLink (companyId, itemId, kind, targetId, createdBy, createdAt) VALUES (?, ?, ?, ?, ?, ?)
            """, arguments: [link.companyId, link.itemId, link.kind.rawValue, link.targetId, link.createdBy, link.createdAt])
    }

    /// Creates the item and its links in one transaction (`create_work_item` with `regression_of` / `revert_of`): a refused link
    /// creates nothing. `links` name the targets by id, resolved by the caller within `companyId`.
    public func createWorkItem(companyId: String, by sender: Sender, draft: WorkItemDraft, links: [(kind: ItemLinkKind, targetId: String)],
                               now: Date = Store.now()) throws -> (item: WorkItem, links: [ItemLink]) {
        try writer.write { db in
            var targets: [(ItemLinkKind, WorkItem)] = []
            for (kind, targetId) in links {
                guard let target = try WorkItem.fetchOne(db, key: targetId), target.companyId == companyId else {
                    throw WorkError.notFound(Self.noSuchItem(targetId))
                }
                try Self.requireLanded(db, target)
                targets.append((kind, target))
            }
            let created = try createWorkItem(db: db, companyId: companyId, by: sender, draft: draft, now: now)
            var made: [ItemLink] = []
            for (kind, target) in targets {
                try linkItem(db: db, item: created, kind: kind, target: target, by: sender.id, now: now)
                made.append(ItemLink(companyId: companyId, itemId: created.id, kind: kind, targetId: target.id, createdBy: sender.id, createdAt: now))
            }
            return (created, made)
        }
    }

    /// The company's links of one kind whose `createdAt` falls in the window, oldest first.
    public func itemLinks(companyId: String, kind: ItemLinkKind, in window: MeasureWindow) throws -> [ItemLink] {
        try writer.read { db in
            try ItemLink.fetchAll(db, sql: """
                SELECT * FROM workItemLink WHERE companyId = ? AND kind = ? AND createdAt >= ? AND createdAt < ?
                ORDER BY createdAt, itemId, targetId
                """, arguments: [companyId, kind.rawValue, window.since, window.until])
        }
    }

    static func noSuchItem(_ key: String) -> String { "no such work item \(key)" }

    /// The company's item with this key (trimmed, any case), else `WorkError.notFound`.
    static func item(_ db: Database, companyId: String, key raw: String) throws -> WorkItem {
        let key = raw.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard let item = try WorkItem.filter(Column("companyId") == companyId && Column("key") == key).fetchOne(db) else {
            throw WorkError.notFound(noSuchItem(key))
        }
        return item
    }

    // MARK: Daily counters

    /// Adds `delta` to the company's `name` counter for `day` (`YYYY-MM-DD` in the owner's calendar: `measureDay`).
    public func addCounter(companyId: String, name: String, day: String, delta: Double) throws {
        try writer.write { db in try Self.addCounter(db, companyId: companyId, name: name, day: day, delta: delta) }
    }

    /// The in-transaction form, for the recorder that counts inside the tick's own write.
    static func addCounter(_ db: Database, companyId: String, name: String, day: String, delta: Double) throws {
        try db.execute(sql: """
            INSERT INTO measureCounter (companyId, name, day, value) VALUES (?, ?, ?, ?)
            ON CONFLICT (companyId, name, day) DO UPDATE SET value = value + excluded.value
            """, arguments: [companyId, name, day, delta])
    }

    /// The sum of the company's `name` counter over the days whose calendar day (in `tz`, default the owner's zone) overlaps the
    /// window: the day of `since` through the day of `until`, except that a window ending exactly at midnight does not reach into
    /// that day. Nothing recorded is 0.
    public func counters(companyId: String, name: String, in window: MeasureWindow, tz: TimeZone? = nil) throws -> Double {
        let zone = tz ?? ownerTimeZone()
        return try writer.read { db in try Self.counterTotal(db, companyId: companyId, name: name, in: window, tz: zone).sum }
    }

    /// The in-transaction form, with the number of day rows summed: a metric whose source is a counter tells "nothing recorded"
    /// (no rows) from a recorded 0. `companyId` "" is an owner-wide counter (`reserveBreaches`).
    static func counterTotal(_ db: Database, companyId: String, name: String, in window: MeasureWindow, tz: TimeZone) throws
        -> (sum: Double, rows: Int) {
        let first = measureDay(window.since, in: tz)
        // The last instant inside the window is just before `until`; its day is the last day the window touches.
        let last = measureDay(window.until.addingTimeInterval(-1), in: tz)
        guard first <= last else { return (0, 0) }
        let row = try Row.fetchOne(db, sql: """
            SELECT COALESCE(SUM(value), 0) AS total, COUNT(*) AS days FROM measureCounter
            WHERE companyId = ? AND name = ? AND day >= ? AND day <= ?
            """, arguments: [companyId, name, first, last])
        guard let row else { return (0, 0) }
        return (row["total"] as Double, row["days"] as Int)
    }

    /// The earliest day the company's `name` counter has a row for (`YYYY-MM-DD`), or nil.
    static func firstCounterDay(_ db: Database, companyId: String, name: String) throws -> String? {
        try String.fetchOne(db, sql: "SELECT MIN(day) FROM measureCounter WHERE companyId = ? AND name = ?", arguments: [companyId, name])
    }

    /// `YYYY-MM-DD` of `date` in `zone`: the key of a day's counters.
    public static func measureDay(_ date: Date, in zone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }
}
