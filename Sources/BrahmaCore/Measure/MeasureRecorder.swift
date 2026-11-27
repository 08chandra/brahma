import Foundation
import GRDB

/// The daily counters of `measureCounter` (`docs/measure/metrics.md`). The clock writes `activeSeconds`, the recorder the next
/// five; the owner writes
/// `ownerInterventionSeconds` (`brahma measure <co> --log-owner-minutes`), and nothing else does.
public enum MeasureCounter {
    /// Company-active seconds per day: written by the company clock (`Store.accrueActiveTime`) in the transaction that accrues
    /// them, so the counter and `companyActivity` never disagree (ruling R15).
    public static let activeSeconds = "activeSeconds"
    /// Company-active seconds with no running turn while an agent waited on usage (metrics.md §12), and the same seconds by cause.
    public static let idleActionableSeconds = "idleActionableSeconds"
    public static let idleUsageLimitSeconds = "idleUsageLimitSeconds"
    public static let idlePaceSeconds = "idlePaceSeconds"
    public static let idleReserveSeconds = "idleReserveSeconds"
    /// Owner-wide (company id `ownerWide`): usage snapshots of the owner's account observed at or past the owner reserve line.
    public static let reserveBreaches = "reserveBreaches"
    /// The owner's own logged time, in seconds (owner ruling R7(d)).
    public static let ownerInterventionSeconds = "ownerInterventionSeconds"
    /// The company id of an owner-wide counter: the usage snapshot is the owner's account, not one company's.
    public static let ownerWide = ""
}

/// The measure recorder (Plan X6a Task 5; ruling R5: a pure function over the store, called once per tick from
/// `Orchestrator.schedule(now:)` after dispatch). For every running company that had no running turn while an agent waited on
/// usage, it adds the seconds the company clock accrued this tick (the clock itself wrote them to `activeSeconds`, in its own
/// transaction) to `idleActionableSeconds` and to the counter of the cause. Once per new usage snapshot it judges the owner reserve. Nothing
/// here estimates: a tick the recorder did not see is not recorded, and the metrics say so.
public enum MeasureRecorder {
    /// What the tick decided, as `schedule(now:)` holds it after dispatch.
    public struct Tick: Sendable {
        /// The five-hour gate per company (`UsageGate.evaluateParts(…).fiveHour`); a company absent is open.
        public var decisions: [String: UsageDecision]
        /// Companies whose weekly pace is closed, and those past the owner reserve (nothing runs, not even the critical path).
        public var paceClosed: Set<String>
        public var paceStrict: Set<String>
        /// Turns running per company after this tick's launches.
        public var runningByCompany: [String: Int]
        /// The seconds each company's clock gained this tick (`Store.accrueActiveTime`'s answer).
        public var activeDelta: [String: TimeInterval]
        /// The owner-wide reserve, `1 − weeklyShare` (`SchedulerConfig.ownerReserve`). A company's own override is not used: the
        /// breach is of the owner's account, which every company shares.
        public var ownerReserve: Double

        public init(decisions: [String: UsageDecision] = [:], paceClosed: Set<String> = [], paceStrict: Set<String> = [],
                    runningByCompany: [String: Int] = [:], activeDelta: [String: TimeInterval] = [:], ownerReserve: Double) {
            self.decisions = decisions; self.paceClosed = paceClosed; self.paceStrict = paceStrict
            self.runningByCompany = runningByCompany; self.activeDelta = activeDelta; self.ownerReserve = ownerReserve
        }
    }

    /// Why a company sat idle with work waiting; one cause per tick, the first that holds.
    enum IdleCause: Equatable {
        /// An agent blocked by the five-hour gate (or ready while it is closed).
        case usageLimit
        /// A ready agent held because the owner reserve is reached (`paceStrict`).
        case reserve
        /// A ready agent held by the weekly pace (`paceClosed`).
        case pace

        var counter: String {
            switch self {
            case .usageLimit: MeasureCounter.idleUsageLimitSeconds
            case .reserve: MeasureCounter.idleReserveSeconds
            case .pace: MeasureCounter.idlePaceSeconds
            }
        }
    }

    /// `measureEpoch` names: when the recorder first ran, and the `observedAt` of the last usage snapshot it judged.
    static let recorderEpoch = "recorder"
    static let judgedSnapshotEpoch = "usageSnapshotJudged"

    /// One tick's counters, in one write transaction.
    public static func record(store: Store, companies: [Company], tick: Tick, now: Date) throws {
        let tz = store.ownerTimeZone()
        let day = Store.measureDay(now, in: tz)
        try store.writer.write { db in
            // The start of the recorder's history (owner-wide metadata, like the start of link history): a usage snapshot
            // observed before it is history the recorder never saw.
            try db.execute(sql: "INSERT OR IGNORE INTO measureEpoch (name, at) VALUES (?, ?)", arguments: [recorderEpoch, now])
            for company in companies where company.status == .running {
                // `activeSeconds` itself is written by the clock in its own transaction (`accrueActiveTime`); here only the
                // idle share of the same seconds.
                let delta = tick.activeDelta[company.id] ?? 0
                guard delta.isFinite, delta > 0 else { continue }
                guard let cause = try idleCause(db, companyId: company.id, tick: tick) else { continue }
                try Store.addCounter(db, companyId: company.id, name: MeasureCounter.idleActionableSeconds, day: day, delta: delta)
                try Store.addCounter(db, companyId: company.id, name: cause.counter, day: day, delta: delta)
            }
            try judgeSnapshot(db, ownerReserve: tick.ownerReserve, tz: tz)
        }
    }

    /// The company had no running turn and an awake agent waited on usage: blocked by the five-hour gate (its blocker persists
    /// until step 1 of a later tick lifts it), ready while the gate is closed, or ready while the pace or the reserve holds it.
    /// A closed gate with nobody waiting is not actionable; paused agents wait on the owner, not on usage. Cap closures are X1's
    /// (provider caps) and do not exist on this build.
    static func idleCause(_ db: Database, companyId: String, tick: Tick) throws -> IdleCause? {
        guard (tick.runningByCompany[companyId] ?? 0) == 0 else { return nil }
        let agents = try Agent.fetchAll(db, sql: "SELECT * FROM agent WHERE companyId = ? AND paused = 0 AND state IN ('ready', 'blocked')",
                                        arguments: [companyId])
        let ready = agents.contains { $0.state == .ready }
        let usageBlocked = agents.contains { agent in
            guard agent.state == .blocked, case .usageLimit? = agent.blocker else { return false }
            return true
        }
        var gateClosed = false
        if case .closed? = tick.decisions[companyId] { gateClosed = true }
        if usageBlocked || (gateClosed && ready) { return .usageLimit }
        if ready, tick.paceStrict.contains(companyId) { return .reserve }
        if ready, tick.paceClosed.contains(companyId) { return .pace }
        return nil
    }

    /// The owner account's usage snapshot (`usageState`, one owner-wide row: no company id) is judged once, when its `observedAt`
    /// is newer than the last one judged: seven-day utilization at or past `1 − reserve` (the scheduler's `paceStrict` line,
    /// `Pace.criticalPathExempt`) adds one breach to the owner-wide counter, on the day it was observed. A snapshot observed before
    /// the recorder first ran is marked judged and not counted.
    static func judgeSnapshot(_ db: Database, ownerReserve: Double, tz: TimeZone) throws {
        guard let info = try Store.latestRateLimit(db: db) else { return }
        if let judged = try Date.fetchOne(db, sql: "SELECT at FROM measureEpoch WHERE name = ?", arguments: [judgedSnapshotEpoch]),
           info.observedAt <= judged { return }
        try db.execute(sql: """
            INSERT INTO measureEpoch (name, at) VALUES (?, ?) ON CONFLICT (name) DO UPDATE SET at = excluded.at
            """, arguments: [judgedSnapshotEpoch, info.observedAt])
        guard let start = try Date.fetchOne(db, sql: "SELECT at FROM measureEpoch WHERE name = ?", arguments: [recorderEpoch]),
              info.observedAt >= start else { return }
        guard let used = info.sevenDayUtilization, used >= 1 - ownerReserve else { return }
        try Store.addCounter(db, companyId: MeasureCounter.ownerWide, name: MeasureCounter.reserveBreaches,
                             day: Store.measureDay(info.observedAt, in: tz), delta: 1)
    }

    /// What the tick logs about the recorder: the first failure, a failure that differs from the last, and one line when it
    /// recovers; nothing while it keeps failing the same way or keeps working (no line per tick).
    public struct FailureLog: Sendable {
        private var last: String?
        public init() {}

        /// `error`: this tick's failure, nil on success. Returns the line to log, if any.
        public mutating func note(_ error: String?) -> String? {
            defer { last = error }
            switch (last, error) {
            case (nil, nil): return nil
            case (_, let now?) where now == last: return nil
            case (_, let now?): return "measure recorder failed; this tick's measure counters were not recorded (logged again only if the error changes): \(now)"
            case (.some, nil): return "measure recorder recovered; this tick's measure counters were recorded"
            }
        }
    }

    /// When the recorder first ran, nil if it never has (owner-wide metadata).
    static func recorderStart(_ db: Database) throws -> Date? {
        try Date.fetchOne(db, sql: "SELECT at FROM measureEpoch WHERE name = ?", arguments: [recorderEpoch])
    }

    // MARK: The owner's own time

    /// The most one `--log-owner-minutes` may add: a day.
    public static let maxOwnerMinutesPerLog = 24 * 60

    /// The day an owner-time log goes to: `raw` (`YYYY-MM-DD`, a day that has begun in the owner's zone), else today there.
    public static func ownerLogDay(_ raw: String?, now: Date, tz: TimeZone) throws -> String {
        let today = Store.measureDay(now, in: tz)
        guard let raw else { return today }
        let day = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard isDay(day) else { throw MeasureError.badDay(raw) }
        // `YYYY-MM-DD` strings order as their days.
        guard day <= today else { throw MeasureError.dayAfterToday(day) }
        return day
    }

    /// A real calendar day written `YYYY-MM-DD`.
    static func isDay(_ s: String) -> Bool {
        guard s.count == 10 else { return false }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        guard let date = f.date(from: s) else { return false }
        return f.string(from: date) == s
    }
}

extension Store {
    /// Adds the owner's own `minutes` (1…1440) to the company's `ownerInterventionSeconds` for `day` (`YYYY-MM-DD`). The only
    /// source of the owner-minutes metric; Brahma never records or estimates owner time itself. Owner-only (ruling R32, the C6
    /// pattern): it takes the owner's principal, which only the owner CLI and the app can mint, and refuses in an agent process
    /// before anything else.
    public func logOwnerMinutes(companyId: String, minutes: Int, day: String, owner: OwnerPrincipal) throws {
        try ProcessRole.refuseInAgentProcess()
        _ = try requireOwner(owner)
        guard minutes > 0, minutes <= MeasureRecorder.maxOwnerMinutesPerLog else { throw MeasureError.badMinutes(minutes) }
        guard MeasureRecorder.isDay(day) else { throw MeasureError.badDay(day) }
        try writer.write { db in
            guard try Company.fetchOne(db, key: companyId) != nil else { throw MeasureError.unknownCompany(companyId) }
            try Self.upsertCounter(db, companyId: companyId, name: MeasureCounter.ownerInterventionSeconds, day: day,
                                   delta: Double(minutes) * 60)
        }
    }
}
