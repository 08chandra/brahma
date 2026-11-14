import Testing
import Foundation
@testable import BrahmaAppModel

/// The frame-interval summary the `--map-bench` harness prints. Pure arithmetic; nothing here touches a store.
@Suite(.scratch) struct FrameStatsTests {
    @Test func fpsMeanP95Max() {
        // 99 frames at 60 Hz and one 50 ms hitch.
        let intervals = Array(repeating: 1.0 / 60, count: 99) + [0.05]
        let s = FrameStats.make(intervals: intervals)
        #expect(s.frames == 100)
        // Nearest rank 95 of 100 sorted intervals is still a 60 Hz one: the single hitch is the 100th.
        #expect(abs(s.p95Ms - 1000.0 / 60) < 1e-9)
        #expect(abs(s.maxMs - 50) < 1e-9)
        let meanMs = (99.0 / 60 + 0.05) / 100 * 1000
        #expect(abs(s.meanMs - meanMs) < 1e-9)
        #expect(abs(s.fps - 1000 / meanMs) < 1e-9)
    }

    @Test func nearestRankPicksTheRankedSample() {
        // 20 samples of 1…20 ms: rank ceil(0.95 × 20) = 19, so p95 is 19 ms, not the max.
        let s = FrameStats.make(intervals: (1...20).reversed().map { Double($0) / 1000 })
        #expect(s.frames == 20)
        #expect(abs(s.p95Ms - 19) < 1e-9)
        #expect(abs(s.maxMs - 20) < 1e-9)
        // One sample is its own p95 and max.
        let one = FrameStats.make(intervals: [0.02])
        #expect(one.frames == 1 && abs(one.p95Ms - 20) < 1e-9 && abs(one.maxMs - 20) < 1e-9 && abs(one.fps - 50) < 1e-9)
    }

    @Test func emptyIsAllZeros() {
        #expect(FrameStats.make(intervals: []) == FrameStats(frames: 0, fps: 0, meanMs: 0, p95Ms: 0, maxMs: 0))
    }
}
