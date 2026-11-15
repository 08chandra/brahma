import Testing
import Foundation
import Metal
@testable import BrahmaAppModel
@testable import BrahmaMapKit

/// Nonisolated, so a trait can read it.
private enum PerfGate {
    static let enabled = ProcessInfo.processInfo.environment["BRAHMA_PERF"] == "1" && MTLCreateSystemDefaultDevice() != nil
}

/// Offscreen frame-time checks for the org chart (`BRAHMA_PERF=1 swift test -c release --filter MapPerfTests`). Each run drives a
/// synthetic company through `MapBench` at a fixed 1/60 s step and prints one `MAP BENCH` line; the assertion is the 60 fps
/// budget (16.7 ms at the 95th percentile). Off by default: timings are meaningless in a debug build or on a loaded machine.
@Suite(.scratch) struct MapPerfTests {
    static let budgetMs = 16.7

    @Test(.enabled(if: PerfGate.enabled, "needs BRAHMA_PERF=1 and a Metal device"))
    @MainActor func sixtyFpsAt300DefaultCollapse() {
        let r = MapBench.run(agents: 300)
        print(r.line)
        #expect(r.frames > 0)
        #expect(r.p95Ms <= Self.budgetMs, "p95 \(r.p95Ms) ms: \(r.line)")
    }

    @Test(.enabled(if: PerfGate.enabled, "needs BRAHMA_PERF=1 and a Metal device"))
    @MainActor func sixtyFpsAt300FullyExpanded() {
        let r = MapBench.run(agents: 300, expandAll: true)
        print(r.line)
        #expect(r.frames > 0)
        #expect(r.p95Ms <= Self.budgetMs, "p95 \(r.p95Ms) ms: \(r.line)")
    }

    @Test(.enabled(if: PerfGate.enabled, "needs BRAHMA_PERF=1 and a Metal device"))
    @MainActor func aggregateFallbackAt600() {
        // The org generator tops out at `OrgGenerator.range` (500), so 600 is clamped: the line says `agents=500`.
        let r = MapBench.run(agents: 600, rate: 120)
        print(r.line)
        #expect(r.frames > 0)
        #expect(r.aggregateSeconds > 0, "120 msg/s never switched the queue to aggregate mode: \(r.line)")
        #expect(r.p95Ms <= Self.budgetMs, "p95 \(r.p95Ms) ms: \(r.line)")
    }
}
