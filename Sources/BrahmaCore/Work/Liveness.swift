import Foundation

/// Pinned numbers of the liveness checks. Every duration is company-active seconds (`Store.activeNow`): a paused company,
/// an engine hold or a closed app never ages anything.
public enum Liveness {
    public static let day: TimeInterval = 86_400
    /// An `inProgress` item without a lease, untouched this long: its owner's manager is told (level 1), then the next ancestor
    /// or the owner (level 2).
    public static let itemAging: [TimeInterval] = [1 * day, 3 * day]
    /// A deadlock still present after this long goes to the owner.
    public static let deadlockOwnerAfter: TimeInterval = 1 * day
    /// The wait-for graph is rebuilt at most this often per company.
    public static let scanInterval: TimeInterval = 60
    /// Items blocked longer than this are listed by the stall explainer.
    public static let blockedLong: TimeInterval = 3 * day
}

// MARK: Wait-for graph

/// `from` waits for `to`; `via` is the item key the wait goes through, when there is one.
public struct WaitEdge: Hashable, Sendable {
    public var from: String
    public var to: String
    public var via: String?

    public init(from: String, to: String, via: String? = nil) { self.from = from; self.to = to; self.via = via }
}

public enum WaitForGraph {
    /// Most cycles reported per scan (the graph is tiny; this only bounds a pathological one).
    static let maxCycles = 50

    /// Every simple cycle, each listed once, starting at its smallest node and following the edges
    /// (`[a, b]` means a waits for b and b waits for a). A node waiting on itself is not a cycle.
    public static func cycles(edges: [WaitEdge]) -> [[String]] {
        var next: [String: [String]] = [:]
        for e in edges where e.from != e.to {
            if !(next[e.from]?.contains(e.to) ?? false) { next[e.from, default: []].append(e.to) }
        }
        for key in next.keys { next[key]?.sort() }
        var found: [[String]] = []
        for start in next.keys.sorted() {
            var path = [start]
            var onPath: Set<String> = [start]
            func walk(_ node: String) {
                guard found.count < maxCycles else { return }
                for n in next[node] ?? [] {
                    if n == start { found.append(path); continue }
                    // Only nodes above the start, so each cycle is found from its smallest member only.
                    guard n > start, !onPath.contains(n) else { continue }
                    path.append(n); onPath.insert(n)
                    walk(n)
                    path.removeLast(); onPath.remove(n)
                }
            }
            walk(start)
        }
        return found
    }

    /// The same cycle however it is rotated: the sorted member ids joined.
    public static func signature(_ cycle: [String]) -> String { cycle.sorted().joined(separator: ",") }
}

// MARK: Stall explainer

public struct StallReport: Equatable, Sendable {
    public var running: Int
    public var reasons: [String]

    public init(running: Int, reasons: [String]) { self.running = running; self.reasons = reasons }
}

public struct StallHold: Equatable, Sendable {
    public var reason: String
    public var detail: String
    public var since: Date

    public init(reason: String, detail: String, since: Date) { self.reason = reason; self.detail = detail; self.since = since }
}

/// Agents blocked on the same thing: `target` is `@handle`, an item key, `you` or `usage limit`.
public struct StallBlockerGroup: Equatable, Sendable {
    public var target: String
    public var count: Int

    public init(target: String, count: Int) { self.target = target; self.count = count }
}

/// Everything the explainer needs, already read from the store.
public struct StallInput: Equatable, Sendable {
    public var running: Int = 0
    public var companyPaused: Bool = false
    /// When the owner stopped everything (Task 7c), nil while not stopped; rendered first, before the hold.
    public var stoppedSince: Date? = nil
    public var hold: StallHold? = nil
    public var doctorOk: Bool = true
    public var doctorDetail: String = ""
    /// The five-hour part of the usage gate.
    public var usage: UsageDecision = .open
    public var pace: Pace? = nil
    /// The account may spill into paid extra usage (`overageStatus == "allowed"`): every mode is clamped (Task 14c).
    public var overageAllowed: Bool = false
    public var memory: MemoryPressure = .normal
    /// Agents per state (`ready`, `running`, ...).
    public var stateCounts: [String: Int] = [:]
    public var blockerGroups: [StallBlockerGroup] = []
    public var ownerAskCount: Int = 0
    /// Company-active seconds the oldest owner ask has waited.
    public var oldestOwnerAsk: TimeInterval = 0
    /// Open deadlocks, each as the handles around the cycle.
    public var deadlocks: [[String]] = []
    public var readyItems: Int = 0
    /// Ready items the dispatch pass skips because they overlap an item in progress or in review, or share a hot path with one,
    /// and the refusal text of the first (for example "ACME-4 overlaps ACME-2 (src/a); wait until it merges").
    public var readyHeldBack: Int = 0
    public var readyHeldBackExample: String? = nil
    public var idleAgents: Int = 0
    public var longBlockedCount: Int = 0
    public var oldestBlockedKey: String? = nil
    public var oldestBlockedAge: TimeInterval = 0

    public init() {}
}

public enum StallExplainer {
    /// The stall line while extra usage is on (W11): every mode is clamped to R1, no sub-agents and no Ultra.
    public static let overageText = "deep modes and Ultra are off while extra usage is on"

    /// `5m`, `5h`, `2d`: the largest whole unit.
    public static func age(_ seconds: TimeInterval) -> String {
        if seconds >= Liveness.day { return "\(Int(seconds / Liveness.day))d" }
        if seconds >= 3600 { return "\(Int(seconds / 3600))h" }
        return "\(max(1, Int(seconds / 60)))m"
    }

    /// Why nothing (or little) is running, most decisive reason first. Pure: the same input gives the same lines.
    public static func explain(_ input: StallInput, timeZone: TimeZone, now: Date) -> StallReport {
        func format(_ pattern: String, _ date: Date) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = timeZone
            f.dateFormat = pattern
            return f.string(from: date)
        }
        func plural(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? one : many }
        var reasons: [String] = []
        if let since = input.stoppedSince { reasons.append(EmergencyStop.stallReason(since: since, timeZone: timeZone)) }
        if let hold = input.hold {
            reasons.append("engine paused: \(hold.reason) (\(hold.detail)) since \(format("HH:mm", hold.since))")
        }
        if input.companyPaused { reasons.append("company is paused") }
        if !input.doctorOk { reasons.append("Claude Code check failing: \(input.doctorDetail)") }
        if case .closed(let until) = input.usage { reasons.append("usage limit (5-hour) until \(format("HH:mm", until))") }
        if let pace = input.pace, let until = pace.closedUntil {
            reasons.append("weekly pace: \(pace.text) — resumes about \(format("EEE HH:mm", until))")
        }
        if input.overageAllowed { reasons.append(StallExplainer.overageText) }
        if input.memory != .normal { reasons.append("memory pressure \(input.memory.rawValue)") }
        if input.ownerAskCount > 0 {
            let k = input.ownerAskCount
            reasons.append("\(k) \(plural(k, "ask waits", "asks wait")) for you (oldest \(age(input.oldestOwnerAsk)))")
        }
        let groups = input.blockerGroups.filter { $0.count > 0 }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.target < $1.target }.prefix(3)
        for g in groups {
            reasons.append("\(g.count) \(plural(g.count, "agent", "agents")) blocked on \(g.target)")
        }
        for cycle in input.deadlocks where !cycle.isEmpty {
            reasons.append("deadlock: " + (cycle + [cycle[0]]).map { "@\($0)" }.joined(separator: " → "))
        }
        if input.longBlockedCount > 0, let key = input.oldestBlockedKey {
            let k = input.longBlockedCount
            reasons.append("\(k) \(plural(k, "item", "items")) blocked over 3 days (oldest \(key), \(age(input.oldestBlockedAge)))")
        }
        if input.readyItems > 0 {
            if input.readyHeldBack > 0 {
                let k = input.readyHeldBack
                reasons.append("\(k) Ready \(plural(k, "item waits", "items wait")) for others to merge (path overlap or a shared hot path)"
                               + (input.readyHeldBackExample.map { ": \($0)" } ?? ""))
            }
            // With an idle agent the next dispatch pass hands them out: that is not a stall.
            let free = input.readyItems - input.readyHeldBack
            if input.idleAgents == 0, free > 0 {
                reasons.append("\(free) Ready \(plural(free, "item", "items")) and no idle agent picked them up")
            }
        } else {
            reasons.append("no Ready items in the backlog")
        }
        return StallReport(running: input.running, reasons: reasons)
    }
}

extension StallExplainer {
    /// What one blocked agent waits on, as the stall report groups it (`StallInput.blockerGroups`): `@<handle>` (`@?` when
    /// unknown), the item key, `ownerWord` (`you` in the owner's report) or `usage limit`; nil for a blocker the report
    /// doesn't group (a turn budget, a retry, none).
    public static func blockerTarget(_ blocker: Blocker?, ownerWord: String, handle: (String) throws -> String?) rethrows -> String? {
        switch blocker {
        case .agent(let id)?: "@" + (try handle(id) ?? "?")
        case .workItem(_, let key)?: key
        case .owner?: ownerWord
        case .usageLimit?: "usage limit"
        default: nil
        }
    }

    /// Plan C Task C4b: one blocked agent's reason in the stall report's words: `blocked on <target>` (`blockerTarget`), with
    /// the time a usage limit lifts; a turn budget or a retry with its time; `blocked` when nothing is recorded. A time is
    /// `HH:mm` on `now`'s day and `yyyy-MM-dd` otherwise (owner time zone). Engine text only: an owner-wait's own reason
    /// (agent text) is the caller's to add, for the readers allowed it.
    public static func agentReason(_ blocker: Blocker?, ownerWord: String, handle: (String) throws -> String?, timeZone: TimeZone,
                                   now: Date) rethrows -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        func stamp(_ d: Date) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = timeZone
            f.dateFormat = cal.isDate(d, inSameDayAs: now) ? "HH:mm" : "yyyy-MM-dd"
            return f.string(from: d)
        }
        switch blocker {
        case .usageLimit(let until)?: return "blocked on usage limit until \(stamp(until))"
        case .turnBudget(let until)?: return "blocked on turn budget until \(stamp(until))"
        case .retry(let until, let failures)?:
            return "blocked: retrying at \(stamp(until)) after \(failures) \(failures == 1 ? "failure" : "failures")"
        default:
            return try blockerTarget(blocker, ownerWord: ownerWord, handle: handle).map { "blocked on \($0)" } ?? "blocked"
        }
    }
}
