import Foundation
import BrahmaCore

/// The replay scrubber (Plan 4b Task 7b): the last `MapTimeline.window` of the company, rewound from the current agents.
/// While a replay is open, live traffic is skipped and live snapshots are only recorded; `exitReplay` applies the newest.
extension MapController {
    /// The most replay time one frame may cover, before the speed: a frame after a long gap does not leap ahead.
    static let replayMaxFrameStep: TimeInterval = 1
    /// Within this of the end, playback lands on the end and stops (date arithmetic is not exact).
    static let replayEndSlack: TimeInterval = 0.001

    /// Loads the last hour off-main and shows its start, paused at speed 1. Nothing for a synthetic or invalidated
    /// controller, one already replaying, one that has no snapshot yet, or when the history cannot be read.
    public func enterReplay() async {
        guard case .live(let store, let companyId) = source, !isInvalidated, replay == nil,
              let snapshot = lastSnapshot else { return }
        let end = clock()
        let current = snapshot.agents
        let loaded = try? await Task.detached {
            try MapHistory.load(store: store, companyId: companyId, end: end, current: current)
        }.value
        // Invalidated, or another call entered first, while the history loaded.
        guard let timeline = loaded, !isInvalidated, replay == nil else { return }
        replay = ReplayState(timeline: timeline, time: timeline.start, playing: false, speed: MapTimeline.speeds[0])
        showReplay(at: timeline.start, facts: [], now: mapNow(), emitEvents: false)
    }

    /// Shows the company as it was at `t`, clamped to the window; no events.
    public func scrub(to t: Date) {
        guard var r = replay, !isInvalidated else { return }
        let time = Swift.min(r.timeline.end, Swift.max(r.timeline.start, t))
        r.time = time
        replay = r
        showReplay(at: time, facts: [], now: mapNow(), emitEvents: false)
    }

    /// Starts or pauses playback. Playing from the end starts over from the beginning.
    public func setPlaying(_ on: Bool) {
        guard var r = replay, !isInvalidated else { return }
        if on && r.time >= r.timeline.end {
            r.time = r.timeline.start
            replay = r
            showReplay(at: r.timeline.start, facts: [], now: mapNow(), emitEvents: false)
        }
        r.playing = on
        replay = r
    }

    /// One of `MapTimeline.speeds`; any other value is ignored.
    public func setSpeed(_ s: Double) {
        guard MapTimeline.speeds.contains(s), var r = replay else { return }
        r.speed = s
        replay = r
    }

    /// Back to live: the newest recorded snapshot is applied at once, without events, and the replay's edges are cleared.
    public func exitReplay() {
        guard replay != nil else { return }
        replay = nil
        guard case .live(let store, _) = source, !isInvalidated, let snapshot = lastSnapshot else { return }
        let now = mapNow()
        model.apply(inputs(for: snapshot, store: store), now: now, emitEvents: false)
        model.setEdgeWeights([:], now: now)
    }

    /// `frame`'s replay branch: moves a playing replay on by `dt`·speed (at most `replayMaxFrameStep`·speed), feeding the
    /// facts in between and the agents as they were; at the end it stops.
    func advanceReplay(by dt: TimeInterval, now: TimeInterval) {
        guard var r = replay, r.playing else { return }
        let step = Swift.min(Self.replayMaxFrameStep, Swift.max(0, dt.isFinite ? dt : 0)) * r.speed
        guard step > 0 else { return }
        let from = r.time
        var to = from.addingTimeInterval(step)
        if to >= r.timeline.end.addingTimeInterval(-Self.replayEndSlack) {
            to = r.timeline.end
            r.playing = false
        }
        r.time = to
        replay = r
        showReplay(at: to, facts: Array(r.timeline.facts(after: from, through: to)), now: now, emitEvents: true)
    }

    /// The model at replay time `t`: the agents as they were (blocker lines only for agents blocked then), then `facts`
    /// as traffic, then the edge weights as of `t` (which already count `facts`).
    private func showReplay(at t: Date, facts: [MapFact], now: TimeInterval, emitEvents: Bool) {
        guard let r = replay, case .live(let store, _) = source, let snapshot = lastSnapshot else { return }
        var inputs = inputs(for: snapshot, store: store)
        let past = r.timeline.agents(at: t)
        let blocked = Set(past.filter { $0.state == .blocked }.map(\.id))
        inputs.agents = past
        inputs.blockers = inputs.blockers.filter { blocked.contains($0.key) }
        model.apply(inputs, now: now, emitEvents: emitEvents)
        if !facts.isEmpty { model.ingest(facts, now: now) }
        model.setEdgeWeights(r.timeline.edgeWeights(at: t), now: now)
    }
}
