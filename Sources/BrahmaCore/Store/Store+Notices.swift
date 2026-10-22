import Foundation
import GRDB

extension Store {
    // MARK: Prefs

    public func ownerPrefs() throws -> OwnerPrefs {
        try writer.read { db in try OwnerPrefs.fetchOne(db, key: 1) } ?? .defaults
    }

    /// Replaces the preferences. A changed digest time moves every existing `digest.daily` timer to it and
    /// recomputes its next fire (calendar time, owner zone).
    public func updateOwnerPrefs(_ prefs: OwnerPrefs, now: Date = Store.now()) throws {
        try prefs.validate()
        var row = prefs
        row.id = 1
        let zone = ownerTimeZone()
        try writer.write { db in try row.save(db) }
        let time = row.digestHourMinute
        let schedule = TimerSchedule.daily(hour: time.hour, minute: time.minute)
        for timer in try timers(companyId: nil) where timer.name == "digest.daily" && timer.schedule != schedule {
            try upsertTimer(companyId: timer.companyId, name: timer.name, action: timer.action, schedule: schedule,
                            now: now, timeZone: zone)
        }
    }

    // MARK: Notices

    /// The one place notice text is cleaned before it is stored: secrets are redacted (while any newlines are still in,
    /// so a multi-line secret matches), then newlines and control characters become spaces.
    func noticeText(_ text: String) -> String {
        let redacted = redact(text)
        return String(String.UnicodeScalarView(redacted.unicodeScalars.map { Store.noticeBlocked.contains($0) ? " " : $0 }))
    }

    fileprivate static let noticeBlocked = CharacterSet.newlines.union(.controlCharacters)

    /// A normal-urgency `system` notice for the owner.
    public func notifyOwner(companyId: String, title: String, body: String, now: Date = Store.now()) throws {
        try writer.write { db in
            try notifyOwner(db: db, companyId: companyId, kind: .system, urgency: .normal, title: title, body: body, now: now)
        }
    }

    @discardableResult
    func notifyOwner(db: Database, companyId: String?, kind: NoticeKind, urgency: NoticeUrgency,
                            title: String, body: String, now: Date) throws -> OwnerNotice {
        var notice = OwnerNotice(companyId: companyId, kind: kind, urgency: urgency, title: noticeText(title),
                                 body: noticeText(body), createdAt: now)
        try notice.insert(db)
        return notice
    }

    /// Notices not yet delivered, oldest first.
    public func undeliveredNotices(limit: Int = 200) throws -> [OwnerNotice] {
        try writer.read { db in
            try OwnerNotice.filter(Column("deliveredAt") == nil).order(Column("id")).limit(limit).fetchAll(db)
        }
    }

    /// Newest `limit` notices, delivered or not, returned oldest first.
    public func allNotices(limit: Int = 200) throws -> [OwnerNotice] {
        try writer.read { db in
            try OwnerNotice.order(Column("id").desc).limit(limit).fetchAll(db).reversed()
        }
    }

    /// Marks the notices delivered. Already-delivered ones keep their first delivery time.
    public func markNoticesDelivered(ids: [Int64], now: Date) throws {
        guard !ids.isEmpty else { return }
        try writer.write { db in
            try OwnerNotice.filter(ids.contains(Column("id")) && Column("deliveredAt") == nil)
                .updateAll(db, Column("deliveredAt").set(to: now))
        }
    }
}
