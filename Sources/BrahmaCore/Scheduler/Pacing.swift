import Foundation
import GRDB

public enum PaceState: String, Sendable { case onPace, near, ahead, closed }

/// Where the weekly spend stands against the straight line the owner allows.
public struct Pace: Equatable, Sendable {
    /// Fraction of the week's allowance usable right now (burst included, never above `1 - reserve`).
    public var allowed: Double
    public var used: Double
    /// `max(0, used - allowed)`.
    public var ahead: Double
    /// Nil when open; otherwise when the gate reopens.
    public var closedUntil: Date?
    /// The straight line without burst: `elapsed * (1 - reserve)`.
    public var line: Double = 0
    /// Utilization at which nothing runs at all, not even the critical path: `1 - reserve`.
    public var reserveLine: Double = 1
    /// $LE left before the gate closes (`(allowed - used) / pctPerDollar`); nil until calibrated.
    public var headroomLE: Double? = nil

    public var state: PaceState {
        if closedUntil != nil { return .closed }
        if used > line { return .ahead }
        return used >= line - PaceState.nearBand ? .near : .onPace
    }

    /// The critical-path exemption holds only while the owner's reserve is untouched.
    public var criticalPathExempt: Bool { used < reserveLine }

    public var text: String {
        used >= allowed ? "ahead by \(max(1, Int((ahead * 100).rounded())))%" : "on pace"
    }
}

extension PaceState {
    /// Within this much (of the week) below the line counts as "near".
    static let nearBand = 0.05
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
    public static func pace(_ info: RateLimitInfo?, reserve: Double, now: Date, pctPerDollar: Double? = nil) -> Pace? {
        guard let info, let reset = info.sevenDayResetsAt, let util = info.sevenDayUtilization else { return nil }
        let share = 1 - reserve
        let elapsed = min(max(1 - reset.timeIntervalSince(now) / week, 0), 1)
        let allowed = min(share, (elapsed + burst) * share)
        var until: Date?
        if util >= allowed {
            let at = util >= share ? reset : reset.addingTimeInterval(-week + week * (util / share - burst))
            if at > now { until = at }
        }
        return Pace(allowed: allowed, used: util, ahead: max(0, util - allowed), closedUntil: until, line: elapsed * share,
                    reserveLine: share, headroomLE: pctPerDollar.flatMap { $0 > 0 ? max(0, allowed - util) / $0 : nil })
    }
}

extension SchedulerConfig {
    /// The owner reserve that applies to a company: its override, else the owner-wide value.
    public func reserve(for company: Company) -> Double { company.ownerReserve ?? ownerReserve }
}

/// How much of a usage window one dollar of `total_cost_usd` ($LE, list-price equivalent) uses, learned from
/// successive usage snapshots. A *sample* is one accumulation window: from a baseline snapshot until the utilization
/// has moved at least `minDelta` (2 points; utilization is quantized), with ratio = Σ Δutil / Σ $LE over the window.
/// Admission uses the 80th percentile of the samples (the pessimistic end), and only once there are `minWindows`.
public struct UsageCalibration: Equatable, Sendable, Codable {
    public struct Track: Equatable, Sendable, Codable {
        public var baselineUtil: Double?
        public var baselineResetsAt: Date?
        /// Spend since the baseline.
        public var cost: Double = 0
        /// Ratios of the last `maxSamples` windows (fraction of the window per dollar).
        public var samples: [Double] = []

        public init() {}

        /// 80th percentile (nearest rank) once there are enough windows.
        public var estimate: Double? {
            guard samples.count >= UsageCalibration.minWindows else { return nil }
            let sorted = samples.sorted()
            return sorted[Int((Double(sorted.count) * UsageCalibration.percentile).rounded(.up)) - 1]
        }

        public mutating func addCost(_ usd: Double) { if usd > 0 { cost += usd } }

        public mutating func observe(util: Double, resetsAt: Date?) {
            // A different reset (more than an hour apart) is a new window; a drop means the same.
            func sameWindow() -> Bool {
                guard let a = baselineResetsAt, let b = resetsAt else { return baselineResetsAt == nil && resetsAt == nil }
                return abs(a.timeIntervalSince(b)) < 3600
            }
            guard let base = baselineUtil, sameWindow(), util >= base else {
                baselineUtil = util; baselineResetsAt = resetsAt; cost = 0
                return
            }
            let delta = util - base
            // Sub-point movement keeps accumulating into the same window; it is never a sample by itself.
            guard delta >= UsageCalibration.minDelta - 1e-9, cost >= UsageCalibration.minCost else { return }
            samples.append(delta / cost)
            if samples.count > UsageCalibration.maxSamples { samples.removeFirst(samples.count - UsageCalibration.maxSamples) }
            baselineUtil = util; baselineResetsAt = resetsAt; cost = 0
        }
    }

    public static let percentile = 0.8
    public static let minDelta = 0.02
    public static let minCost = 0.05
    public static let minWindows = 10
    public static let maxSamples = 50

    public var week = Track()
    public var fiveHour = Track()
    /// The rung-cost EMA (`modeCalibration`, Task 14c), kept in the same stored JSON.
    public var modes: ModeCalibration? = nil

    public init() {}

    /// Fraction of the week per dollar (p80), once calibrated.
    public var pctPerDollar: Double? { week.estimate }
    /// Fraction of the five-hour window per dollar (p80), once calibrated.
    public var pctPerDollar5h: Double? { fiveHour.estimate }

    public mutating func addCost(_ usd: Double) { week.addCost(usd); fiveHour.addCost(usd) }
    public mutating func observe(util: Double, resetsAt: Date?) { week.observe(util: util, resetsAt: resetsAt) }
    public mutating func observeFiveHour(util: Double, resetsAt: Date?) { fiveHour.observe(util: util, resetsAt: resetsAt) }
}

extension Store {
    public func usageCalibration() throws -> UsageCalibration {
        try writer.read { db in try Store.calibration(db) }
    }

    static func calibration(_ db: Database) throws -> UsageCalibration {
        guard let json = try String.fetchOne(db, sql: "SELECT calibration FROM ownerSettings WHERE id = 1"),
              let cal = try? JSONDecoder().decode(UsageCalibration.self, from: Data(json.utf8)) else { return UsageCalibration() }
        return cal
    }

    static func saveCalibration(_ db: Database, _ cal: UsageCalibration) throws {
        try db.execute(sql: "INSERT OR IGNORE INTO ownerSettings(id, timeZone) VALUES (1, ?)", arguments: [TimeZone.current.identifier])
        let json = String(decoding: try JSONEncoder().encode(cal), as: UTF8.self)
        try db.execute(sql: "UPDATE ownerSettings SET calibration = ?, pctPerDollar = ?, pctPerDollar5h = ? WHERE id = 1",
                       arguments: [json, cal.pctPerDollar, cal.pctPerDollar5h])
    }

    /// Feeds one usage snapshot into the calibration (both windows).
    static func calibrate(_ db: Database, observing info: RateLimitInfo) throws {
        guard info.sevenDayUtilization != nil || info.fiveHourUtilization != nil else { return }
        var cal = try calibration(db)
        if let util = info.sevenDayUtilization { cal.observe(util: util, resetsAt: info.sevenDayResetsAt) }
        if let util = info.fiveHourUtilization { cal.observeFiveHour(util: util, resetsAt: info.fiveHourResetsAt) }
        try saveCalibration(db, cal)
    }

    /// Adds a finished turn's `total_cost_usd` to the spend since the last snapshot.
    static func recordSpend(_ db: Database, _ usd: Double) throws {
        guard usd > 0 else { return }
        var cal = try calibration(db)
        cal.addCost(usd)
        try saveCalibration(db, cal)
    }

    /// $LE reserved by admitted-but-unfinished work: the unspent cap of every open Ultra reservation (Task 14u). Counted in
    /// every other turn's 5-hour check (`UsageGate.evaluateParts`) and in Ultra's own 7-day projection.
    public func openReservationLE() -> Double {
        (try? writer.read { db in try Store.openUltraReservationLE(db: db) }) ?? 0
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
