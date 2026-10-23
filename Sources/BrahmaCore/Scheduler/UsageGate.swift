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
    /// With paid overage allowed, five-hour utilization at or above this admits nothing in any mode.
    public static let overageClamp = 0.85

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
    ///
    /// `openReservationLE` (dollars of list-price-equivalent cost reserved by admitted-but-unfinished work, 0 in 3a)
    /// counts against the five-hour check at `pctPerDollar5h` each. When the account may spill into paid overage
    /// (`overageStatus == "allowed"`), no mode admits new work at `overageClamp` and above.
    public static func evaluateFiveHour(_ info: RateLimitInfo?, mode: UsageMode, now: Date,
                                        openReservationLE: Double = 0, pctPerDollar5h: Double? = nil) -> UsageDecision {
        guard let info else { return .open }
        let reset: Date?
        var util = info.fiveHourUtilization
        if let u = util, openReservationLE > 0, let per = pctPerDollar5h { util = u + openReservationLE * per }
        let limit = info.overageStatus == "allowed" ? min(threshold(mode), overageClamp) : threshold(mode)
        if isHardLimit(info) {
            reset = info.resetsAt
        } else if let util, util >= limit {
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

    public static func evaluateParts(_ info: RateLimitInfo?, mode: UsageMode, now: Date, reserve: Double = defaultReserve,
                                     openReservationLE: Double = 0, pctPerDollar5h: Double? = nil) -> Evaluation {
        let paceDecision: UsageDecision = pace(info, reserve: reserve, now: now)?.closedUntil.map { .closed(until: $0) } ?? .open
        return Evaluation(fiveHour: evaluateFiveHour(info, mode: mode, now: now, openReservationLE: openReservationLE,
                                                     pctPerDollar5h: pctPerDollar5h),
                          pace: paceDecision)
    }

    /// Five-hour gate plus weekly pacing; pacing applies in every mode.
    public static func evaluate(_ info: RateLimitInfo?, mode: UsageMode, now: Date, reserve: Double = defaultReserve) -> UsageDecision {
        evaluateParts(info, mode: mode, now: now, reserve: reserve).combined
    }
}
