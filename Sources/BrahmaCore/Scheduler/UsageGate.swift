import Foundation

public enum UsageDecision: Equatable, Sendable {
    case open
    case closed(until: Date)
}

public enum UsageGate {
    /// How long a closure with no future reset time lasts, counted from when the usage info was observed.
    public static let fallback: TimeInterval = 15 * 60
    /// Weekly owner reserve when nothing else is set (`SchedulerConfig.ownerReserve`).
    public static let defaultReserve = 0.30
    /// Headroom above a straight-line spend, as a fraction of the week, so a burst of real work is not choked.
    public static let burst = 0.15

    public static func threshold(_ m: UsageMode) -> Double {
        switch m {
        case .low: return 0.80
        case .balanced: return 0.90
        case .max: return 0.97
        }
    }

    /// True when the info means "stop now": the request was rejected, or paid overage is in use.
    /// `allowed_warning` is not a limit: Claude Code emits it past soft thresholds (seven-day included).
    public static func isHardLimit(_ info: RateLimitInfo) -> Bool {
        info.status == "rejected" || info.isUsingOverage
    }

    /// The five-hour rule only. Hard limit (rejected or overage): closed until `resetsAt`. Otherwise, five-hour
    /// utilization at or above the mode threshold: closed until the five-hour window resets. With no reset, or one
    /// already past when the info was observed, closed until `observedAt + fallback`; info older than that is
    /// stale and the gate opens, so a probe turn can refresh it.
    public static func evaluateFiveHour(_ info: RateLimitInfo?, mode: UsageMode, now: Date) -> UsageDecision {
        guard let info else { return .open }
        let reset: Date?
        if isHardLimit(info) {
            reset = info.resetsAt
        } else if let util = info.fiveHourUtilization, util >= threshold(mode) {
            reset = info.fiveHourResetsAt ?? (info.rateLimitType == "five_hour" ? info.resetsAt : nil)
        } else {
            return .open
        }
        // A reset that was still ahead when observed is authoritative; once it passes, the window has rolled over.
        let until: Date
        if let reset, reset > info.observedAt { until = reset } else { until = info.observedAt.addingTimeInterval(fallback) }
        return until > now ? .closed(until: until) : .open
    }

    public struct Evaluation: Equatable, Sendable {
        public var fiveHour: UsageDecision
        public var pace: UsageDecision

        /// Closed if either part is; when both are, until the later one.
        public var combined: UsageDecision {
            switch (fiveHour, pace) {
            case (.closed(let a), .closed(let b)): .closed(until: max(a, b))
            case (.closed, _): fiveHour
            case (_, .closed): pace
            default: .open
            }
        }
    }

    public static func evaluateParts(_ info: RateLimitInfo?, mode: UsageMode, now: Date,
                                     reserve: Double = defaultReserve) -> Evaluation {
        let paceDecision: UsageDecision = pace(info, reserve: reserve, now: now)?.closedUntil.map { .closed(until: $0) } ?? .open
        return Evaluation(fiveHour: evaluateFiveHour(info, mode: mode, now: now), pace: paceDecision)
    }

    /// Five-hour gate plus weekly pacing; pacing applies in every mode.
    public static func evaluate(_ info: RateLimitInfo?, mode: UsageMode, now: Date, reserve: Double = defaultReserve) -> UsageDecision {
        evaluateParts(info, mode: mode, now: now, reserve: reserve).combined
    }
}
