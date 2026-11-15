import Foundation
import BrahmaCore

/// One hour of company history for the map's replay scrubber (Plan 4b Task 6): the facts in `[start, end)` plus the
/// agents as they are now. Past states are rewound from the current ones; everything else about an agent (paused,
/// manager, team) keeps its current value.
public struct MapTimeline: Equatable, Sendable {
    public static let window: TimeInterval = 3600
    public static let speeds: [Double] = [1, 4, 16]

    /// Messages older than this no longer light an edge.
    static let weightSpan: TimeInterval = 300
    /// An edge's weight halves every minute.
    static let halfLife: TimeInterval = 60

    public var start: Date
    public var end: Date
    /// Ascending by `at`; equal times keep their input order.
    public var facts: [MapFact]
    public var current: [Agent]
    /// More messages or state changes fell in the hour than the loader reads: the newest are kept and `start` moved up to
    /// where they begin (the start of the hour is cut).
    public var truncated: Bool

    public static func build(current: [Agent], facts: [MapFact], start: Date, end: Date, truncated: Bool) -> MapTimeline {
        let sorted = facts.enumerated().sorted { l, r in
            l.element.at != r.element.at ? l.element.at < r.element.at : l.offset < r.offset
        }.map(\.element)
        return MapTimeline(start: start, end: end, facts: sorted, current: current, truncated: truncated)
    }

    /// The agents that existed at `t`, in current order, with the state they had then.
    public func agents(at t: Date) -> [Agent] {
        var out = current.filter { $0.createdAt <= t }
        var index: [String: Int] = [:]
        for (i, a) in out.enumerated() { index[a.id] = i }
        var i = facts.count
        while i > 0, facts[i - 1].at > t {
            i -= 1
            if case let .stateChanged(agentId, from, _, _) = facts[i], let k = index[agentId] { out[k].state = from }
        }
        return out
    }

    /// The facts with `a < at <= b`.
    public func facts(after a: Date, through b: Date) -> ArraySlice<MapFact> {
        let lo = firstIndex { $0.at > a }
        let hi = firstIndex { $0.at > b }
        return lo < hi ? facts[lo..<hi] : []
    }

    /// Per unordered pair, the sum of `0.5^((t − at)/60)` over message pairs sent in `[t − 300, t]`.
    public func edgeWeights(at t: Date) -> [EdgeKey: Double] {
        var weights: [EdgeKey: Double] = [:]
        let lo = firstIndex { $0.at >= t.addingTimeInterval(-Self.weightSpan) }
        let hi = firstIndex { $0.at > t }
        guard lo < hi else { return weights }
        for fact in facts[lo..<hi] {
            guard case .message(let m) = fact else { continue }
            let w = pow(0.5, t.timeIntervalSince(m.createdAt) / Self.halfLife)
            let from = Self.endpoint(m.senderId)
            for r in m.recipientIds { weights[EdgeKey(from, Self.endpoint(r)), default: 0] += w }
        }
        return weights
    }

    private static func endpoint(_ id: String) -> MapEndpoint { id == "owner" ? .owner : .agent(id) }

    /// Binary search over the sorted facts: the first index whose fact satisfies the monotone predicate.
    private func firstIndex(where p: (MapFact) -> Bool) -> Int {
        var lo = 0, hi = facts.count
        while lo < hi {
            let mid = (lo + hi) / 2
            if p(facts[mid]) { hi = mid } else { lo = mid + 1 }
        }
        return lo
    }
}

public enum MapHistory {
    /// `[end − 3600, end)` in one read transaction per feed: messages, hand-offs, state changes, plus a `.hired` fact for
    /// each agent created in the window. When messages or state changes exceed `limit`, the newest are kept and the window
    /// starts at the oldest one kept (of either feed, whichever is later): states before it could not be rewound
    /// correctly, and the scrubber offers no stretch with missing traffic.
    public static func load(store: Store, companyId: String, end: Date, current: [Agent],
                            limit: Int = 20_000) throws -> MapTimeline {
        var start = end.addingTimeInterval(-MapTimeline.window)
        let messages = try store.messageFlows(companyId: companyId, since: start, until: end, limit: limit)
        let handoffs = try store.handoffFlows(companyId: companyId, since: start, until: end)
        let changes = try store.events(companyId: companyId, kinds: [.stateChanged], since: start, until: end, limit: limit)
        let events = changes.events
        if messages.truncated, let cut = messages.flows.map(\.createdAt).min() { start = max(start, cut) }
        if changes.truncated, let cut = events.map(\.createdAt).min() { start = max(start, cut) }

        var facts: [MapFact] = messages.flows.map(MapFact.message)
        facts += handoffs.map(MapFact.handoff)
        for e in events {
            guard let agentId = e.agentId, let (from, to) = parseTransition(e.text) else { continue }
            facts.append(.stateChanged(agentId: agentId, from: from, to: to, at: e.createdAt))
        }
        for a in current where a.createdAt >= start && a.createdAt < end {
            facts.append(.hired(agentId: a.id, at: a.createdAt))
        }
        if messages.truncated || changes.truncated { facts.removeAll { $0.at < start } }
        return MapTimeline.build(current: current, facts: facts, start: start, end: end,
                                 truncated: messages.truncated || changes.truncated)
    }

    private static let pattern = "^(ready|running|blocked|sleeping|killed) -> (ready|running|blocked|sleeping|killed)"

    /// `"running -> ready (recovered)"` parses; the suffix is ignored and anything else is nil.
    static func parseTransition(_ text: String) -> (AgentState, AgentState)? {
        guard let regex = try? Regex(pattern), let m = text.prefixMatch(of: regex),
              let f = m.output[1].substring, let t = m.output[2].substring,
              let from = AgentState(rawValue: String(f)), let to = AgentState(rawValue: String(t)) else { return nil }
        return (from, to)
    }
}
