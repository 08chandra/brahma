import Foundation
import GRDB

/// When a timer fires. Timers are calendar-facing: `daily` and `weekly` are wall-clock times in the owner's time zone.
public enum TimerSchedule: Codable, Equatable, Sendable {
    case once(at: Date)
    case daily(hour: Int, minute: Int)
    /// `weekday` uses `Calendar` numbering: 1 is Sunday ... 7 is Saturday.
    case weekly(weekday: Int, hour: Int, minute: Int)
    case every(seconds: Int)

    public static let minimumInterval = 60

    public var isValid: Bool {
        switch self {
        case .once, .every: true
        case .daily(let h, let m): (0...23).contains(h) && (0...59).contains(m)
        case .weekly(let d, let h, let m): (1...7).contains(d) && (0...23).contains(h) && (0...59).contains(m)
        }
    }

    /// The first fire strictly after `after`; nil when there is none (a `once` that has passed).
    ///
    /// A local time that happens twice (fall-back) fires at its first occurrence only; one that does not exist
    /// (spring-forward) fires at the next valid time.
    public func next(after: Date, timeZone: TimeZone) -> Date? {
        switch self {
        case .once(let at):
            return at > after ? at : nil
        case .every(let seconds):
            return after.addingTimeInterval(TimeInterval(max(seconds, Self.minimumInterval)))
        case .daily(let hour, let minute):
            return Self.nextLocal(after: after, timeZone: timeZone, weekday: nil, hour: hour, minute: minute)
        case .weekly(let weekday, let hour, let minute):
            return Self.nextLocal(after: after, timeZone: timeZone, weekday: weekday, hour: hour, minute: minute)
        }
    }

    /// Where a new timer first fires: a `once` at its own time even when that is already past (it fires on the next
    /// tick); everything else at its next occurrence after `now`.
    func firstFire(now: Date, timeZone: TimeZone) -> Date? {
        if case .once(let at) = self { return at }
        return next(after: now, timeZone: timeZone)
    }

    /// Walks local calendar days and takes the first occurrence of `hour:minute` on each, so the second pass through
    /// a repeated hour is never a candidate.
    private static func nextLocal(after: Date, timeZone: TimeZone, weekday: Int?, hour: Int, minute: Int) -> Date? {
        guard (0...23).contains(hour), (0...59).contains(minute) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let today = calendar.startOfDay(for: after)
        let components = DateComponents(hour: hour, minute: minute, second: 0)
        for offset in 0...8 {
            guard let shifted = calendar.date(byAdding: .day, value: offset, to: today) else { continue }
            let day = calendar.startOfDay(for: shifted)
            if let weekday, calendar.component(.weekday, from: day) != weekday { continue }
            guard let candidate = calendar.nextDate(after: day.addingTimeInterval(-1), matching: components,
                                                    matchingPolicy: .nextTime, repeatedTimePolicy: .first,
                                                    direction: .forward),
                  calendar.isDate(candidate, inSameDayAs: day) else { continue }
            if candidate > after { return candidate }
        }
        return nil
    }

    /// Short text for the CLI and logs, in the owner's time zone for `once`.
    public func summary(timeZone: TimeZone) -> String {
        func hm(_ h: Int, _ m: Int) -> String { String(format: "%02d:%02d", h, m) }
        switch self {
        case .once(let at):
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = timeZone
            f.dateFormat = "yyyy-MM-dd HH:mm"
            return "once \(f.string(from: at))"
        case .daily(let h, let m): return "daily \(hm(h, m))"
        case .weekly(let d, let h, let m):
            let names = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
            return "weekly \(names[(max(1, min(7, d))) - 1]) \(hm(h, m))"
        case .every(let s):
            let s = max(s, Self.minimumInterval)
            if s % 3600 == 0 { return "every \(s / 3600)h" }
            if s % 60 == 0 { return "every \(s / 60)m" }
            return "every \(s)s"
        }
    }
}

public enum TimerAction: Codable, Equatable, Sendable {
    /// A named engine job from the `TimerJobRegistry`.
    case job(String)
    /// A system DM to the agent that wakes it.
    case turn(agentId: String, prompt: String)
}

public struct EngineTimer: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "timer"

    public var id: String
    /// Nil for engine-wide timers.
    public var companyId: String?
    public var name: String
    public var action: TimerAction
    public var schedule: TimerSchedule
    public var nextFireAt: Date
    public var lastFiredAt: Date?
    public var enabled: Bool
    public var createdAt: Date
}

public enum TimerError: Error, Equatable {
    case invalidSchedule
}

/// What a job gets when it runs (off the orchestrator actor).
public struct TimerContext: Sendable {
    public let store: Store
    public let paths: BrahmaPaths
    public let timer: EngineTimer
    public let now: Date
    /// The engine's blocking-work gate: jobs run database and git work inside it, never on the cooperative pool.
    let blocking: Blocking
}

public struct TimerJobRegistry: Sendable {
    public typealias Job = @Sendable (TimerContext) async throws -> Void
    private var jobs: [String: Job] = [:]

    public init() {}

    /// The engine's own jobs: `backup.hourly`, `backup.repos` and `backup.home` are real; the rest are no-ops until the tasks that own them
    /// (target backups, digest) replace them.
    public static var system: TimerJobRegistry {
        var registry = TimerJobRegistry()
        for name in SystemTimers.jobNames { registry.register(name) { _ in } }
        registry.register("backup.hourly", BackupJobs.hourly)
        registry.register("backup.repos", BackupJobs.repos)
        registry.register("backup.home", BackupJobs.home)
        return registry
    }

    public mutating func register(_ name: String, _ job: @escaping Job) { jobs[name] = job }
    public func job(_ name: String) -> Job? { jobs[name] }
}

public enum SystemTimers {
    public static let jobNames = ["backup.hourly", "backup.repos", "backup.home", "backup.targets", "digest.daily"]

    /// Upserts the engine-wide backup timers and one `digest.daily` per company. Idempotent: a timer whose action
    /// and schedule are unchanged keeps its next fire time. `digestTime` defaults to the owner's preference.
    public static func ensure(store: Store, now: Date, digestTime: (hour: Int, minute: Int)? = nil) throws {
        let zone = store.ownerTimeZone()
        let digestTime = try digestTime ?? store.ownerPrefs().digestHourMinute
        let global: [(String, TimerSchedule)] = [
            ("backup.hourly", .every(seconds: 3600)),
            ("backup.repos", .daily(hour: 3, minute: 30)),
            ("backup.home", .daily(hour: 4, minute: 0)),
            ("backup.targets", .daily(hour: 4, minute: 30)),
        ]
        for (name, schedule) in global {
            _ = try store.upsertTimer(companyId: nil, name: name, action: .job(name), schedule: schedule, now: now, timeZone: zone)
        }
        for company in try store.companies() {
            _ = try store.upsertTimer(companyId: company.id, name: "digest.daily", action: .job("digest.daily"),
                                      schedule: .daily(hour: digestTime.hour, minute: digestTime.minute), now: now, timeZone: zone)
        }
    }
}
