import Foundation
import BrahmaCore

public struct StateCounts: Equatable, Sendable {
    public var running = 0, ready = 0, blocked = 0, sleeping = 0, killed = 0

    public init(_ agents: [Agent]) {
        for a in agents {
            switch a.state {
            case .running: running += 1
            case .ready: ready += 1
            case .blocked: blocked += 1
            case .sleeping: sleeping += 1
            case .killed: killed += 1
            }
        }
    }

    public var total: Int { running + ready + blocked + sleeping + killed }

    public var line: String { "\(running) running · \(ready) ready · \(blocked) blocked · \(sleeping) sleeping" }
}

public enum ChannelTitle {
    public static func title(_ c: Channel) -> String {
        switch c.kind {
        case .channel:
            return "#" + c.name
        case .dm:
            let parts = c.name.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            let handles = parts.first == "dm" ? Array(parts.dropFirst()) : parts
            let others = handles.filter { $0 != "owner" }
            // The engine's own conversation reads "system", not "@system": it is not an agent.
            return (others.isEmpty ? handles : others).map { $0 == "system" ? $0 : "@" + $0 }.joined(separator: " · ")
        }
    }
}

public enum TimeText {
    private static func format(_ d: Date, _ pattern: String, _ timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = pattern
        return f.string(from: d)
    }

    public static func hm(_ d: Date, timeZone: TimeZone = .current) -> String { format(d, "HH:mm", timeZone) }
    public static func hms(_ d: Date, timeZone: TimeZone = .current) -> String { format(d, "HH:mm:ss", timeZone) }
}

public enum UsageText {
    public static func line(_ info: RateLimitInfo?, now: Date, timeZone: TimeZone = .current) -> String {
        guard let info else { return "Usage: no data yet" }
        func pct(_ v: Double?) -> String { v.map { "\(Int(($0 * 100).rounded()))%" } ?? "n/a" }
        var s = "5h \(pct(info.fiveHourUtilization)) · 7d \(pct(info.sevenDayUtilization))"
        if let reset = info.resetsAt, reset > now { s += " · resets \(TimeText.hm(reset, timeZone: timeZone))" }
        return s
    }

    public static func gateLine(_ info: RateLimitInfo?, mode: UsageMode, now: Date, timeZone: TimeZone = .current) -> String? {
        guard case .closed(let until) = UsageGate.evaluate(info, mode: mode, now: now) else { return nil }
        return "Usage limit — new turns resume at \(TimeText.hm(until, timeZone: timeZone))"
    }
}

public enum BlockerText {
    public static func describe(_ b: Blocker?, handles: [String: String], timeZone: TimeZone = .current) -> String {
        switch b {
        case nil: return ""
        case .agent(let id): return "Waiting on @\(handles[id] ?? id)"
        case .owner(let reason): return "Waiting on you: \(reason)"
        case .workItem(_, let key): return "Waiting on \(key)"
        case .usageLimit(let until): return "Usage limit until \(TimeText.hm(until, timeZone: timeZone))"
        case .turnBudget(let until): return "Turn budget until \(TimeText.hm(until, timeZone: timeZone))"
        case .retry(let until, let failures):
            return "Retrying after failure \(failures) at \(TimeText.hm(until, timeZone: timeZone))"
        }
    }
}

public enum CompanyInitials {
    public static func of(_ name: String) -> String {
        let letters = name.split(whereSeparator: \.isWhitespace).prefix(2).compactMap { $0.first }
        return letters.isEmpty ? "?" : String(letters).uppercased()
    }
}
