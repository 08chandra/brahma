import Foundation
import BrahmaCore

/// The queue's limits. `MapModel.throttle` holds one; tests and the renderer may tighten it.
public struct MapThrottle: Equatable, Sendable {
    public static let standard = MapThrottle()

    public var maxActive = 150
    public var spawnPerStep = 6
    public var queueCap = 400
    /// Mention fan-out cap per message (`MapModel.ingest`).
    public var maxFanout = 12
    public var coalesceWindow = 0.5
    /// Message facts per second at which aggregate mode starts, and the rate it must fall to (exclusive) to stop.
    public var aggregateEnter = 30.0
    public var aggregateExit = 20.0

    public init() {}

    /// How long a spawned event plays, in seconds.
    public static func duration(_ k: VisualKind) -> TimeInterval {
        switch k {
        case .message: 0.9
        case .handoff: 1.4
        case .broadcast: 0.6
        case .stateChange: 0.2
        case .hire: 0.4
        case .leave: 1.5
        case .reorg: 0.4
        case .promotion: 1.2
        case .meetingStart, .meetingEnd: 0.6
        }
    }

    /// Spawn order: structural events first, hand-offs next, traffic last.
    static func priority(_ k: VisualKind) -> Int {
        switch k {
        case .leave: 0
        case .hire: 1
        case .reorg: 2
        case .promotion: 3
        case .stateChange: 4
        case .meetingStart, .meetingEnd: 5
        case .handoff: 6
        case .message: 7
        case .broadcast: 8
        }
    }

    /// Message and broadcast events: the only ones coalesced, aggregated or dropped.
    static func isTraffic(_ k: VisualKind) -> Bool {
        switch k {
        case .message, .broadcast: true
        default: false
        }
    }
}

/// Counters in visual events: `ingested` (appended to `pending` by `apply` and `ingest`, one per event) equals
/// `spawned + coalesced + aggregated + dropped + queued` at every moment. `rate` is message facts per second over the last
/// two seconds, each fact once whatever its fan-out.
public struct MapStats: Equatable, Sendable {
    public var ingested: Int
    public var spawned: Int
    public var coalesced: Int
    public var aggregated: Int
    public var dropped: Int
    public var queued: Int
    public var active: Int
    public var rate: Double
    public var aggregate: Bool
    public var lastDropAt: TimeInterval?
}

/// What `MapModel` keeps for the queue. Internal; `stats` and `active` are the public view.
struct QueueState: Sendable {
    var ingested = 0, spawned = 0, coalesced = 0, aggregated = 0, dropped = 0
    var lastDropAt: TimeInterval?
    var active: [VisualEvent] = []
    var rate = 0.0
    var aggregate = false
    var lastEdgePrune = -Double.infinity
    /// Times of the message facts, oldest first from `factHead` (a ring buffer that compacts when half of it is spent).
    private var factTimes: [TimeInterval] = []
    private var factHead = 0

    mutating func recordFact(_ t: TimeInterval) { factTimes.append(t) }

    /// Facts in `(now − 2, now]`; older ones are forgotten.
    mutating func facts(in now: TimeInterval) -> Int {
        while factHead < factTimes.count && factTimes[factHead] <= now - 2 { factHead += 1 }
        if factHead > 1024 && factHead * 2 > factTimes.count {
            factTimes.removeFirst(factHead)
            factHead = 0
        }
        return factTimes.count - factHead
    }
}

extension MapModel {
    public var stats: MapStats {
        MapStats(ingested: queue.ingested, spawned: queue.spawned, coalesced: queue.coalesced, aggregated: queue.aggregated,
                 dropped: queue.dropped, queued: pending.count, active: queue.active.count, rate: queue.rate,
                 aggregate: queue.aggregate, lastDropAt: queue.lastDropAt)
    }

    /// Drops every queued event: the map stopped, and nothing frames a stopped map. They count as dropped, so the counters
    /// still add up; no drop time is recorded (the DROPPED chip is for drops the owner could have seen).
    mutating func discardPending() {
        queue.dropped += pending.count
        pending.removeAll()
    }

    /// Events playing now; the renderer reads `start` and `duration` against map time.
    public var active: [VisualEvent] { queue.active }

    private struct CoalesceKey: Hashable {
        var broadcast: Bool
        var from: MapEndpoint
        var to: MapEndpoint?
    }

    private enum Slot { case active(Int), pending(Int) }

    /// One frame of the queue: retires finished events, measures the message rate, resolves, coalesces, aggregates, spawns
    /// by priority and drops the oldest traffic beyond the cap. Returns the events spawned by this call.
    @discardableResult
    public mutating func step(now: TimeInterval, resolve: (MapEndpoint) -> MapEndpoint, budget: Int? = nil) -> [VisualEvent] {
        // 1
        queue.active.removeAll { $0.start + $0.duration <= now }
        if now < queue.lastEdgePrune || now - queue.lastEdgePrune >= 0.5 {
            pruneEdges(now: now)
            queue.lastEdgePrune = now
        }
        // 2
        queue.rate = Double(queue.facts(in: now)) / 2
        queue.aggregate = queue.rate >= throttle.aggregateEnter || (queue.aggregate && queue.rate > throttle.aggregateExit)
        guard !pending.isEmpty else { return [] }

        // 3 and 4: one pass resolves each pending event and folds it into an earlier same-pair event inside the window.
        var index: [CoalesceKey: (slot: Slot, start: TimeInterval)] = [:]
        var activeIndexed = false
        var w = 0
        let count = pending.count
        for r in 0..<count {
            let from = resolve(pending[r].from)
            var to = pending[r].to.map(resolve)
            var kind = pending[r].kind
            switch kind {
            case .message where to == from: kind = .broadcast; to = nil
            case .handoff where to == from: to = nil
            default: break
            }
            pending[r].from = from; pending[r].to = to; pending[r].kind = kind
            var absorbed = false
            if MapThrottle.isTraffic(kind) {
                if !activeIndexed {
                    activeIndexed = true
                    for (i, e) in queue.active.enumerated() where MapThrottle.isTraffic(e.kind) {
                        index[CoalesceKey(broadcast: e.kind == .broadcast, from: e.from, to: e.to)] = (.active(i), e.start)
                    }
                }
                let key = CoalesceKey(broadcast: kind == .broadcast, from: from, to: to)
                let start = pending[r].start
                if let target = index[key], abs(start - target.start) <= throttle.coalesceWindow {
                    switch target.slot {
                    case .active(let i):
                        queue.active[i].count += 1
                        queue.active[i].label = "×\(queue.active[i].count)"
                    case .pending(let i):
                        pending[i].count += 1
                        pending[i].label = "×\(pending[i].count)"
                    }
                    queue.coalesced += 1
                    absorbed = true
                } else {
                    index[key] = (.pending(w), start)
                }
            }
            if !absorbed {
                if w != r { pending.swapAt(w, r) }
                w += 1
            }
        }
        if w < count { pending.removeLast(count - w) }

        // 5
        if queue.aggregate {
            w = 0
            let n = pending.count
            for r in 0..<n {
                if MapThrottle.isTraffic(pending[r].kind) {
                    if let to = pending[r].to { pulseEdge(EdgeKey(pending[r].from, to), now: now) }
                    queue.aggregated += 1
                } else {
                    if w != r { pending.swapAt(w, r) }
                    w += 1
                }
            }
            if w < n { pending.removeLast(n - w) }
        }

        // 6
        var spawned: [VisualEvent] = []
        let room = (budget ?? throttle.maxActive) - queue.active.count
        let n = Swift.min(throttle.spawnPerStep, room)
        if n > 0 && !pending.isEmpty {
            var picks: [(prio: Int, idx: Int)] = []
            picks.reserveCapacity(n + 1)
            for i in pending.indices {
                let p = MapThrottle.priority(pending[i].kind)
                if picks.count == n && p >= picks[n - 1].prio { continue }
                var pos = picks.count
                while pos > 0 && picks[pos - 1].prio > p { pos -= 1 }
                picks.insert((p, i), at: pos)
                if picks.count > n { picks.removeLast() }
                if picks.count == n && picks[n - 1].prio == 0 { break }
            }
            spawned.reserveCapacity(picks.count)
            for pick in picks {
                var e = pending[pick.idx]
                e.start = now
                e.duration = MapThrottle.duration(e.kind)
                spawned.append(e)
            }
            queue.active.append(contentsOf: spawned)
            queue.spawned += spawned.count
            let gone = picks.map(\.idx).sorted()
            var g = 0
            w = 0
            let m = pending.count
            for r in 0..<m {
                if g < gone.count && gone[g] == r { g += 1; continue }
                if w != r { pending.swapAt(w, r) }
                w += 1
            }
            pending.removeLast(m - w)
        }

        // 7
        var traffic = 0
        for e in pending where MapThrottle.isTraffic(e.kind) { traffic += 1 }
        var over = traffic - throttle.queueCap
        if over > 0 {
            queue.dropped += over
            queue.lastDropAt = now
            w = 0
            let m = pending.count
            for r in 0..<m {
                if over > 0 && MapThrottle.isTraffic(pending[r].kind) { over -= 1; continue }
                if w != r { pending.swapAt(w, r) }
                w += 1
            }
            pending.removeLast(m - w)
        }
        return spawned
    }
}
