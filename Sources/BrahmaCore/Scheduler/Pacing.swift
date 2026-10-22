import Foundation
import GRDB

/// Where the weekly spend stands against the straight line the owner allows.
public struct Pace: Equatable, Sendable {
    /// Fraction of the week's allowance usable right now (burst included, never above `1 - reserve`).
    public var allowed: Double
    public var used: Double
    /// `max(0, used - allowed)`.
    public var ahead: Double
    /// Nil when open; otherwise when the gate reopens.
    public var closedUntil: Date?

    public var text: String {
        used >= allowed ? "ahead by \(max(1, Int((ahead * 100).rounded())))%" : "on pace"
    }
}

extension UsageGate {
    static let week: TimeInterval = 7 * 86_400

    /// Weekly pacing; nil without seven-day utilization and reset (both are required).
    ///
    /// ```
    /// elapsed = clamp(1 - (reset - now) / week, 0, 1)
    /// allowed = min(1 - reserve, (elapsed + burst) * (1 - reserve))
    /// closed when util >= allowed:
    ///   until = util >= 1 - reserve ? reset : reset - week + week * (util / (1 - reserve) - burst); open if until <= now
    /// ```
    public static func pace(_ info: RateLimitInfo?, reserve: Double, now: Date) -> Pace? {
        guard let info, let reset = info.sevenDayResetsAt, let util = info.sevenDayUtilization else { return nil }
        let share = 1 - reserve
        let elapsed = min(max(1 - reset.timeIntervalSince(now) / week, 0), 1)
        let allowed = min(share, (elapsed + burst) * share)
        var until: Date?
        if util >= allowed {
            let at = util >= share ? reset : reset.addingTimeInterval(-week + week * (util / share - burst))
            if at > now { until = at }
        }
        return Pace(allowed: allowed, used: util, ahead: max(0, util - allowed), closedUntil: until)
    }
}

extension SchedulerConfig {
    /// The owner reserve that applies to a company: its override, else the owner-wide value.
    public func reserve(for company: Company) -> Double { company.ownerReserve ?? ownerReserve }
}

/// How much of the week one dollar of `total_cost_usd` ($LE, list-price equivalent) uses, learned from successive
/// usage snapshots: an exponential moving average of Δ`sevenDayUtilization` per dollar spent between them.
public struct UsageCalibration: Equatable, Sendable {
    public static let alpha = 0.3
    /// Utilization is quantized (about 1%), so a sample needs at least this much movement ...
    public static let minDelta = 0.01
    /// ... and at least this much spend behind it.
    public static let minCost = 0.05

    /// Fraction of the week per dollar, once calibrated.
    public var pctPerDollar: Double?
    public var baselineUtil: Double?
    public var baselineResetsAt: Date?
    /// Spend since the baseline.
    public var cost: Double

    public init(pctPerDollar: Double? = nil, baselineUtil: Double? = nil, baselineResetsAt: Date? = nil, cost: Double = 0) {
        self.pctPerDollar = pctPerDollar; self.baselineUtil = baselineUtil
        self.baselineResetsAt = baselineResetsAt; self.cost = cost
    }

    public mutating func addCost(_ usd: Double) { if usd > 0 { cost += usd } }

    public mutating func observe(util: Double, resetsAt: Date?) {
        // A different reset (more than an hour apart) is a new week; a drop means the same.
        func sameWeek() -> Bool {
            guard let a = baselineResetsAt, let b = resetsAt else { return baselineResetsAt == nil && resetsAt == nil }
            return abs(a.timeIntervalSince(b)) < 3600
        }
        guard let base = baselineUtil, sameWeek(), util >= base else {
            baselineUtil = util; baselineResetsAt = resetsAt; cost = 0
            return
        }
        let delta = util - base
        guard delta >= Self.minDelta, cost >= Self.minCost else { return }
        let sample = delta / cost
        pctPerDollar = pctPerDollar.map { Self.alpha * sample + (1 - Self.alpha) * $0 } ?? sample
        baselineUtil = util; baselineResetsAt = resetsAt; cost = 0
    }
}

extension Store {
    public func usageCalibration() throws -> UsageCalibration {
        try writer.read { db in try Store.calibration(db) }
    }

    static func calibration(_ db: Database) throws -> UsageCalibration {
        guard let row = try Row.fetchOne(db, sql: "SELECT pctPerDollar, calibUtil, calibResetsAt, calibCost FROM ownerSettings WHERE id = 1")
        else { return UsageCalibration() }
        return UsageCalibration(pctPerDollar: row["pctPerDollar"], baselineUtil: row["calibUtil"],
                                baselineResetsAt: row["calibResetsAt"], cost: row["calibCost"] ?? 0)
    }

    static func saveCalibration(_ db: Database, _ cal: UsageCalibration) throws {
        try db.execute(sql: "INSERT OR IGNORE INTO ownerSettings(id, timeZone) VALUES (1, ?)", arguments: [TimeZone.current.identifier])
        try db.execute(sql: "UPDATE ownerSettings SET pctPerDollar = ?, calibUtil = ?, calibResetsAt = ?, calibCost = ? WHERE id = 1",
                       arguments: [cal.pctPerDollar, cal.baselineUtil, cal.baselineResetsAt, cal.cost])
    }

    /// Feeds one usage snapshot into the calibration.
    static func calibrate(_ db: Database, observing info: RateLimitInfo) throws {
        guard let util = info.sevenDayUtilization else { return }
        var cal = try calibration(db)
        cal.observe(util: util, resetsAt: info.sevenDayResetsAt)
        try saveCalibration(db, cal)
    }

    /// Adds a finished turn's `total_cost_usd` to the spend since the last snapshot.
    static func recordSpend(_ db: Database, _ usd: Double) throws {
        guard usd > 0 else { return }
        var cal = try calibration(db)
        cal.addCost(usd)
        try saveCalibration(db, cal)
    }

    func recordSpend(_ usd: Double) throws { try writer.write { db in try Store.recordSpend(db, usd) } }

    /// Turn cost since the start of the owner's calendar day.
    public func costToday(now: Date) -> Double {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = ownerTimeZone()
        let start = calendar.startOfDay(for: now)
        let end = calendar.date(byAdding: .day, value: 1, to: start) ?? start.addingTimeInterval(86_400)
        return (try? writer.read { db in
            try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(costUSD), 0) FROM turn WHERE startedAt >= ? AND startedAt < ?",
                                arguments: [start, end])
        }) ?? 0
    }
}
