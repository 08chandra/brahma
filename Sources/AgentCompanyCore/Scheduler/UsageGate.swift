import Foundation

public enum UsageDecision: Equatable, Sendable {
    case open
    case closed(until: Date)
}

public enum UsageGate {
    public static func threshold(_ m: UsageMode) -> Double {
        switch m {
        case .low: return 0.80
        case .balanced: return 0.90
        case .max: return 0.97
        }
    }

    /// Closed when status is not "allowed", overage is in use, or five-hour utilization reaches the mode threshold.
    /// A `resetsAt` already in the past means the window has rolled over: open.
    public static func evaluate(_ info: RateLimitInfo?, mode: UsageMode, now: Date) -> UsageDecision {
        guard let info else { return .open }
        let closes = info.status != "allowed"
            || info.isUsingOverage
            || (info.fiveHourUtilization.map { $0 >= threshold(mode) } ?? false)
        guard closes else { return .open }
        guard let resetsAt = info.resetsAt else { return .closed(until: now.addingTimeInterval(15 * 60)) }
        return resetsAt <= now ? .open : .closed(until: resetsAt)
    }
}
