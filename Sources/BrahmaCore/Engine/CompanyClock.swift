import Foundation
import GRDB

public enum SettingsError: Error, Equatable {
    case invalid(String)
}

/// Owner-wide plan setting. It decides the per-mode concurrency caps (Task 5 amendment) and how many agents a new
/// company seats.
public enum PlanTier: String, Codable, CaseIterable, Sendable {
    case max5x, max20x

    public func modeCap(_ mode: UsageMode) -> Int {
        switch (self, mode) {
        case (.max5x, .low): 1
        case (.max5x, .balanced): 3
        case (.max5x, .max): 8
        case (.max20x, .low): 2
        case (.max20x, .balanced): 6
        case (.max20x, .max): 16
        }
    }

    /// The most turns the plan can sustain at once; also the ceiling for `SchedulerConfig.hardCap`.
    public var hardCap: Int { modeCap(.max) }

    /// Agents a new company seats up front (see `OrgGenerator.staff`).
    public var seatBudget: Int { self == .max5x ? 8 : 24 }
}

/// Company-active time: the seconds a company was `running` while no engine hold was active. Leases, timeboxes,
/// aging and the like count this, never wall-clock differences, so a quit, a sleep or an outage does not expire them.
public enum CompanyClock {
    /// One tick gap never adds more than this, however long the app was asleep or closed.
    public static let maxGap: TimeInterval = 60
}

private struct CompanyActivity: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "companyActivity"
    var companyId: String
    var activeSeconds: Double
    var lastAccruedAt: Date?
}

extension Store {
    // MARK: Active time

    /// Called first in every tick. Each company that is `running` while no hold is active gains the time since its
    /// last accrual, at most `CompanyClock.maxGap`; every company's `lastAccruedAt` moves to `now` regardless, so a
    /// pause or a hold is never counted afterwards.
    public func accrueActiveTime(now: Date) throws {
        try writer.write { db in
            let held = try EngineHold.fetchOne(db, key: 1) != nil
            for company in try Company.fetchAll(db) {
                var row = try CompanyActivity.fetchOne(db, key: company.id)
                    ?? CompanyActivity(companyId: company.id, activeSeconds: 0, lastAccruedAt: nil)
                if company.status == .running, !held {
                    let gap = now.timeIntervalSince(row.lastAccruedAt ?? now)
                    row.activeSeconds += min(max(gap, 0), CompanyClock.maxGap)
                }
                row.lastAccruedAt = now
                try row.save(db)
            }
        }
    }

    public func activeNow(companyId: String) -> TimeInterval {
        (try? writer.read { db in try CompanyActivity.fetchOne(db, key: companyId)?.activeSeconds }) ?? 0
    }

    /// Test helper: moves a company's active time forward without waiting.
    func advanceActive(companyId: String, by seconds: TimeInterval) throws {
        try writer.write { db in
            var row = try CompanyActivity.fetchOne(db, key: companyId)
                ?? CompanyActivity(companyId: companyId, activeSeconds: 0, lastAccruedAt: nil)
            row.activeSeconds += seconds
            try row.save(db)
        }
    }

    /// The one place that says when active time stands still: an engine hold, or a company that is not running
    /// (or does not exist). The future owner stop (5-lite) joins here.
    public func isFrozen(companyId: String) -> Bool {
        (try? writer.read { db in
            if try EngineHold.fetchOne(db, key: 1) != nil { return true }
            return try Company.fetchOne(db, key: companyId)?.status != .running
        }) ?? true
    }

    // MARK: Owner settings

    private static func ensureOwnerSettings(_ db: Database) throws {
        try db.execute(sql: "INSERT OR IGNORE INTO ownerSettings(id, timeZone) VALUES (1, ?)",
                       arguments: [TimeZone.current.identifier])
    }

    /// The owner's time zone for every calendar-facing string. Persists `TimeZone.current` on first read.
    public func ownerTimeZone() -> TimeZone {
        let id: String? = try? writer.write { db in
            try Store.ensureOwnerSettings(db)
            return try String.fetchOne(db, sql: "SELECT timeZone FROM ownerSettings WHERE id = 1")
        }
        return id.flatMap { TimeZone(identifier: $0) } ?? .current
    }

    public func setOwnerTimeZone(_ id: String) throws {
        guard !id.isEmpty, TimeZone(identifier: id) != nil else { throw SettingsError.invalid(id) }
        try writer.write { db in
            try Store.ensureOwnerSettings(db)
            try db.execute(sql: "UPDATE ownerSettings SET timeZone = ? WHERE id = 1", arguments: [id])
        }
    }

    /// `HH:mm` (or `HH:mm:ss`) in the owner's time zone.
    public func formatTime(_ date: Date, seconds: Bool = false) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = ownerTimeZone()
        f.dateFormat = seconds ? "HH:mm:ss" : "HH:mm"
        return f.string(from: date)
    }

    public func planTier() -> PlanTier {
        let raw: String? = try? writer.read { db in try String.fetchOne(db, sql: "SELECT planTier FROM ownerSettings WHERE id = 1") }
        return raw.flatMap(PlanTier.init(rawValue:)) ?? .max5x
    }

    public func setPlanTier(_ tier: PlanTier) throws {
        try writer.write { db in
            try Store.ensureOwnerSettings(db)
            try db.execute(sql: "UPDATE ownerSettings SET planTier = ? WHERE id = 1", arguments: [tier.rawValue])
        }
    }

    /// Agents a new company seats up front, from the plan tier (max5x 8, max20x 24).
    public func seatBudget() -> Int { planTier().seatBudget }

    /// Fraction (0.1...1.0) of the weekly allowance the company engine may use; the rest is the owner's reserve.
    public func weeklyShare() -> Double {
        let v: Double? = try? writer.read { db in try Double.fetchOne(db, sql: "SELECT weeklyShare FROM ownerSettings WHERE id = 1") }
        return v ?? 0.7
    }

    public func setWeeklyShare(_ share: Double) throws {
        guard share >= 0.1, share <= 1.0 else { throw SettingsError.invalid("share \(share)") }
        try writer.write { db in
            try Store.ensureOwnerSettings(db)
            try db.execute(sql: "UPDATE ownerSettings SET weeklyShare = ? WHERE id = 1", arguments: [share])
        }
    }

    /// Per-company override of the owner reserve (0.0...0.9); nil goes back to `1 - weeklyShare`.
    public func setOwnerReserve(companyId: String, _ reserve: Double?) throws {
        if let reserve, !(0.0...0.9).contains(reserve) { throw SettingsError.invalid("reserve \(reserve)") }
        try writer.write { db in
            guard try Company.fetchOne(db, key: companyId) != nil else { throw StoreError.notFound }
            try db.execute(sql: "UPDATE company SET ownerReserve = ? WHERE id = ?", arguments: [reserve, companyId])
        }
    }
}
