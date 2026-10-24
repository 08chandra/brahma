import Foundation
import GRDB

public enum NoticeKind: String, Codable, Sendable, CaseIterable {
    case digest, system
}

public enum NoticeUrgency: String, Codable, Sendable, CaseIterable {
    case normal, urgent

    /// Agents and items blocked on an ask at which it stops being a normal notice.
    public static let blockedThreshold = 3

    /// Urgency comes only from how much work is blocked, never from anything an agent wrote.
    public static func of(blockedCount: Int) -> NoticeUrgency {
        blockedCount >= blockedThreshold ? .urgent : .normal
    }
}

/// A message from the engine to the owner that is not an ask (asks stay on their own `notifiedAt` path).
/// `title` and `body` are single-line, agent-influenced text: render them verbatim, never as markup.
public struct OwnerNotice: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "ownerNotice"

    public var id: Int64?
    public var companyId: String?
    public var kind: NoticeKind
    public var urgency: NoticeUrgency
    public var title: String
    public var body: String
    public var createdAt: Date
    public var deliveredAt: Date?

    public init(id: Int64? = nil, companyId: String?, kind: NoticeKind, urgency: NoticeUrgency, title: String, body: String,
                createdAt: Date, deliveredAt: Date? = nil) {
        self.id = id; self.companyId = companyId; self.kind = kind; self.urgency = urgency
        self.title = title; self.body = body; self.createdAt = createdAt; self.deliveredAt = deliveredAt
    }

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// The owner's notification, quiet-hours, digest and sleep preferences. One row, `id = 1`.
public struct OwnerPrefs: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "ownerPrefs"

    var id: Int = 1
    public var notificationsEnabled: Bool
    public var quietEnabled: Bool
    /// `HH:mm` in the owner's time zone.
    public var quietStart: String
    public var quietEnd: String
    public var digestTime: String
    public var preventSleep: Bool
    /// Phone alerts (Task 7b): nil is off. The credentials are in the vault, never here.
    public var pushProvider: PushProvider?
    /// The ntfy base URL (`https` only).
    public var pushServer: String
    public var pushTopic: String?
    public var pushDetail: PushDetail

    public static let defaultPushServer = "https://ntfy.sh"

    public init(notificationsEnabled: Bool = true, quietEnabled: Bool = true, quietStart: String = "22:00",
                quietEnd: String = "08:00", digestTime: String = "08:00", preventSleep: Bool = true,
                pushProvider: PushProvider? = nil, pushServer: String = OwnerPrefs.defaultPushServer, pushTopic: String? = nil,
                pushDetail: PushDetail = .counts) {
        self.notificationsEnabled = notificationsEnabled; self.quietEnabled = quietEnabled
        self.quietStart = quietStart; self.quietEnd = quietEnd
        self.digestTime = digestTime; self.preventSleep = preventSleep
        self.pushProvider = pushProvider; self.pushServer = pushServer; self.pushTopic = pushTopic; self.pushDetail = pushDetail
    }

    /// Quiet hours 22:00-08:00 and a digest at 08:00 (owner time zone), notifications and sleep prevention on.
    public static let defaults = OwnerPrefs()

    /// Parses `HH:mm` (24-hour). Nil for anything else.
    public static func parseTime(_ text: String) -> (hour: Int, minute: Int)? {
        let parts = text.split(separator: ":", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].count == 2, parts[1].count == 2,
              let h = Int(parts[0]), let m = Int(parts[1]), (0...23).contains(h), (0...59).contains(m) else { return nil }
        return (h, m)
    }

    /// The quiet window; nil when quiet hours are off, or a stored time does not parse.
    public var quietHours: QuietHours? {
        guard quietEnabled, let s = Self.parseTime(quietStart), let e = Self.parseTime(quietEnd) else { return nil }
        return QuietHours(startHour: s.hour, startMinute: s.minute, endHour: e.hour, endMinute: e.minute)
    }

    /// The digest time as numbers, falling back to the default when the stored text does not parse.
    public var digestHourMinute: (hour: Int, minute: Int) {
        Self.parseTime(digestTime) ?? Self.parseTime(Self.defaults.digestTime) ?? (8, 0)
    }

    /// Throws `SettingsError.invalid` when a time is not `HH:mm`.
    func validate() throws {
        for (label, text) in [("quiet start", quietStart), ("quiet end", quietEnd), ("digest time", digestTime)]
        where Self.parseTime(text) == nil {
            throw SettingsError.invalid("\(label) '\(text)' is not HH:MM")
        }
        do { _ = try PushURL.validate(server: pushServer) } catch { throw SettingsError.invalid("\(error)") }
        if let pushTopic, !PushURL.validTopic(pushTopic) { throw SettingsError.invalid("\(PushError.badTopic)") }
        if pushProvider == .ntfy, pushTopic == nil { throw SettingsError.invalid("ntfy needs a topic") }
    }
}

/// A daily window in the owner's time zone. It may wrap midnight; start == end means never quiet.
///
/// Membership is decided on local wall-clock minutes, so a DST night keeps the same start and end labels.
public struct QuietHours: Equatable, Sendable {
    public let startHour: Int, startMinute: Int, endHour: Int, endMinute: Int

    public init(startHour: Int, startMinute: Int, endHour: Int, endMinute: Int) {
        self.startHour = startHour; self.startMinute = startMinute; self.endHour = endHour; self.endMinute = endMinute
    }

    private var start: Int { startHour * 60 + startMinute }
    private var end: Int { endHour * 60 + endMinute }

    public func contains(_ date: Date, tz: TimeZone) -> Bool {
        guard start != end else { return false }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = tz
        let c = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (c.hour ?? 0) * 60 + (c.minute ?? 0)
        return start < end ? (start <= minute && minute < end) : (minute >= start || minute < end)
    }

    /// The first moment strictly after `date` at which quiet hours end (local `end` time). Nil when never quiet.
    public func nextEnd(after date: Date, tz: TimeZone) -> Date? {
        guard start != end else { return nil }
        return TimerSchedule.daily(hour: endHour, minute: endMinute).next(after: date, timeZone: tz)
    }
}
