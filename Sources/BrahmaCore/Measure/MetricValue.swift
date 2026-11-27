import Foundation

/// The identity of one metric of `brahma measure` (Plan X6a). The fifteen ids are the twelve of the design spec (§8.6.1) and the
/// owner's three additions of 2026-11-24; `all` is their fixed order, the order of the report's table.
public struct MetricId: RawRepresentable, Hashable, Codable, Sendable {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let greenMain = MetricId(rawValue: "greenMain")
    public static let revertRate = MetricId(rawValue: "revertRate")
    public static let reviewCatch = MetricId(rawValue: "reviewCatch")
    public static let escapeRate = MetricId(rawValue: "escapeRate")
    public static let usagePerLanded = MetricId(rawValue: "usagePerLanded")
    public static let ownerTouches = MetricId(rawValue: "ownerTouches")
    public static let firstPass = MetricId(rawValue: "firstPass")
    public static let queueHealth = MetricId(rawValue: "queueHealth")
    public static let safety = MetricId(rawValue: "safety")
    public static let nonCode = MetricId(rawValue: "nonCode")
    public static let modelRanking = MetricId(rawValue: "modelRanking")
    public static let idleActionable = MetricId(rawValue: "idleActionable")
    // Owner additions (2026-11-24).
    public static let itemsPerDollar = MetricId(rawValue: "itemsPerDollar")
    public static let itemsPerPlanHour = MetricId(rawValue: "itemsPerPlanHour")
    public static let ownerMinutes = MetricId(rawValue: "ownerMinutes")

    /// Every metric, in the order the report lists them.
    public static let all: [MetricId] = [
        .greenMain, .revertRate, .reviewCatch, .escapeRate, .usagePerLanded, .ownerTouches, .firstPass, .queueHealth, .safety,
        .nonCode, .modelRanking, .idleActionable, .itemsPerDollar, .itemsPerPlanHour, .ownerMinutes,
    ]

    /// The owner-facing name (`docs/measure/metrics.md`); an unknown id shows its raw value.
    public var label: String {
        switch self {
        case .greenMain: return "Green-main rate"
        case .revertRate: return "Revert rate (14 days)"
        case .reviewCatch: return "Review catch rate"
        case .escapeRate: return "Escape rate"
        case .usagePerLanded: return "Usage per landed item"
        case .ownerTouches: return "Owner touches per landed item"
        case .firstPass: return "First-pass rate"
        case .queueHealth: return "Queue health"
        case .safety: return "Safety"
        case .nonCode: return "Non-code acceptance"
        case .modelRanking: return "Model ranking per role"
        case .idleActionable: return "Idle while actionable"
        case .itemsPerDollar: return "Landed items per $LE"
        case .itemsPerPlanHour: return "Landed items per plan-hour"
        case .ownerMinutes: return "Owner minutes per landed item"
        default: return rawValue
        }
    }
}

/// How a metric's numerator and denominator read. Rates (`ratio`, `usd`, `perUSD`, `perHour`) need `MetricValue.minEvents` in the
/// denominator before a value is shown; `count` and `seconds` are plain numbers and are never insufficient.
public enum MetricUnit: String, Codable, Sendable {
    /// numerator ÷ denominator as a percentage: `97.4% (38/39)`.
    case ratio
    /// $ per landed item: `$1.20 per landed item (24.00/20)`.
    case usd
    /// a plain count, with an optional target: `0 (target 0)`.
    case count
    /// a duration in seconds: `20.5 s`.
    case seconds
    /// items per $LE: `0.83 per $LE (20/24.00)`.
    case perUSD
    /// items per company-active hour: `1.22 per plan-hour (30/24.50)`.
    case perHour

    /// Whether `minEvents` applies.
    public var isRate: Bool {
        switch self {
        case .ratio, .usd, .perUSD, .perHour: return true
        case .count, .seconds: return false
        }
    }
}

/// Exactly one per metric (`docs/measure/metrics.md`, "Status vocabulary").
public enum MetricStatus: Codable, Equatable, Sendable {
    /// Measured; the value and its denominator are shown.
    case ok
    /// A rate whose denominator has fewer than `MetricValue.minEvents` events; `n` is that denominator.
    case insufficient(n: Int)
    /// The source does not exist on this build (a column, table or feature not merged; a company setting that is off).
    case notApplicable(reason: String)
    /// The source exists but nothing was recorded (no owner-time log, no landing in the window, a recorder not running).
    case notMeasured(reason: String)
}

/// One measured number with its denominator, its basis (what was counted and what was left out) and its detail rows.
/// `display` is the only way a number reaches the owner: it never divides by zero, never shows a rate over fewer than
/// `minEvents` events, and shows every refusal with its reason.
public struct MetricValue: Codable, Equatable, Sendable {
    public var id: MetricId
    public var label: String
    public var numerator: Double
    public var denominator: Double
    public var unit: MetricUnit
    public var basis: String
    public var detail: [MetricValue]
    public var status: MetricStatus
    /// For counts: the owner's target (`0 (target 0)`); nil for every other unit.
    public var target: Double?

    /// A rate over fewer events than this is `insufficient data`.
    public static let minEvents = 20

    public init(id: MetricId, label: String, numerator: Double, denominator: Double, unit: MetricUnit, basis: String,
                detail: [MetricValue] = [], status: MetricStatus, target: Double? = nil) {
        self.id = id; self.label = label; self.numerator = numerator; self.denominator = denominator; self.unit = unit
        self.basis = basis; self.detail = detail; self.status = status; self.target = target
    }

    // MARK: Constructors (the only way a metric function should build a value)

    /// A rate: `ok` from `minEvents` events, else `insufficient(n:)`. The events are the denominator for `ratio` and `usd` (landings,
    /// landed items) and the NUMERATOR for the inverted units `perUSD` and `perHour` (landed items over dollars or hours; controller
    /// ruling, fix round 1); `events` overrides that when a metric counts something else. A non-finite number is never an event.
    public static func rate(_ id: MetricId, label: String? = nil, numerator: Double, denominator: Double, unit: MetricUnit,
                            basis: String, detail: [MetricValue] = [], events: Int? = nil) -> MetricValue {
        precondition(unit.isRate, "rate(…) takes a rate unit; use count(…) or seconds(…)")
        let counted = events.map(Double.init) ?? (unit == .perUSD || unit == .perHour ? numerator : denominator)
        let finite = counted.isFinite && numerator.isFinite && denominator.isFinite
        let n = finite ? max(0, Int(counted.rounded(.down))) : 0
        let status: MetricStatus = n >= minEvents ? .ok : .insufficient(n: n)
        return MetricValue(id: id, label: label ?? id.label, numerator: numerator, denominator: denominator, unit: unit, basis: basis,
                           detail: detail, status: status)
    }

    /// A count (`ok` always; a count of 0 prints `0`), with an optional target.
    public static func count(_ id: MetricId, label: String? = nil, _ n: Double, basis: String, target: Double? = nil,
                             detail: [MetricValue] = []) -> MetricValue {
        MetricValue(id: id, label: label ?? id.label, numerator: n, denominator: 0, unit: .count, basis: basis, detail: detail,
                    status: .ok, target: target)
    }

    /// A duration in seconds (`ok` always).
    public static func seconds(_ id: MetricId, label: String? = nil, _ seconds: Double, basis: String, detail: [MetricValue] = [])
        -> MetricValue {
        MetricValue(id: id, label: label ?? id.label, numerator: seconds, denominator: 0, unit: .seconds, basis: basis, detail: detail,
                    status: .ok)
    }

    /// The source does not exist on this build.
    public static func notApplicable(_ id: MetricId, label: String? = nil, reason: String, basis: String = "",
                                     detail: [MetricValue] = []) -> MetricValue {
        MetricValue(id: id, label: label ?? id.label, numerator: 0, denominator: 0, unit: .count, basis: basis, detail: detail,
                    status: .notApplicable(reason: reason))
    }

    /// The source exists but nothing was recorded.
    public static func notMeasured(_ id: MetricId, label: String? = nil, reason: String, basis: String = "",
                                   detail: [MetricValue] = []) -> MetricValue {
        MetricValue(id: id, label: label ?? id.label, numerator: 0, denominator: 0, unit: .count, basis: basis, detail: detail,
                    status: .notMeasured(reason: reason))
    }

    // MARK: Display

    /// The owner-facing value. A rate always carries its raw pair in parentheses; a rate over a zero denominator is shown as
    /// insufficient whatever its status says, so nothing here ever divides by zero.
    public var display: String {
        switch status {
        case .insufficient(let n): return "insufficient data (n=\(n))"
        case .notApplicable(let reason): return "not applicable: \(reason)"
        case .notMeasured(let reason): return "not measured: \(reason)"
        case .ok: break
        }
        switch unit {
        case .count:
            let n = Self.plain(numerator)
            return target.map { "\(n) (target \(Self.plain($0)))" } ?? n
        case .seconds:
            return "\(Self.plain(numerator)) s"
        case .ratio, .usd, .perUSD, .perHour:
            guard denominator > 0, numerator.isFinite, denominator.isFinite else { return "insufficient data (n=0)" }
            let q = numerator / denominator
            switch unit {
            case .ratio: return "\(Self.fixed(q * 100, 1))% (\(Self.pair(numerator, denominator)))"
            case .usd: return "$\(Self.fixed(q, 2)) per landed item (\(Self.fixed(numerator, 2))/\(Self.plain(denominator)))"
            case .perUSD: return "\(Self.fixed(q, 2)) per $LE (\(Self.plain(numerator))/\(Self.fixed(denominator, 2)))"
            case .perHour: return "\(Self.fixed(q, 2)) per plan-hour (\(Self.plain(numerator))/\(Self.fixed(denominator, 2)))"
            case .count, .seconds: return Self.plain(numerator)
            }
        }
    }

    /// `38/39` when both are whole, else both with two decimals.
    static func pair(_ n: Double, _ d: Double) -> String {
        n.isFinite && d.isFinite && n == n.rounded() && d == d.rounded() ? "\(Int(n))/\(Int(d))" : "\(fixed(n, 2))/\(fixed(d, 2))"
    }

    /// A whole number as an integer, else with up to two decimals (`20.5`, `0.75`). A non-finite number prints `0`: `Int(Double)` traps.
    static func plain(_ x: Double) -> String {
        guard x.isFinite else { return "0" }
        if x == x.rounded() { return "\(Int(x))" }
        var s = fixed(x, 2)
        while s.hasSuffix("0") { s.removeLast() }
        if s.hasSuffix(".") { s.removeLast() }
        return s
    }

    /// Fixed decimals, always with a `.` (never the process locale); a non-finite number prints `0`.
    static func fixed(_ x: Double, _ decimals: Int) -> String { x.isFinite ? String(format: "%.\(decimals)f", locale: nil, x) : "0" }
}
