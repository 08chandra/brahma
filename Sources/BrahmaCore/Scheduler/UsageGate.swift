import Foundation

public enum UsageDecision: Equatable, Sendable {
    case open
    case closed(until: Date)
}

public enum UsageGate {
    /// How long a closure with no future reset time lasts, counted from when the usage info was observed.
    public static let fallback: TimeInterval = 15 * 60

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

    /// Hard limit (rejected or overage): closed until `resetsAt`. Otherwise, five-hour utilization at or above the
    /// mode threshold: closed until the five-hour window resets. With no reset, or one already past when the info
    /// was observed, closed until `observedAt + fallback`; info older than that is stale and the gate opens, so a
    /// probe turn can refresh it.
    public static func evaluate(_ info: RateLimitInfo?, mode: UsageMode, now: Date) -> UsageDecision {
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
}
