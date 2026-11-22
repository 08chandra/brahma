import Testing
import Foundation
import Metal
import BrahmaCore
import BrahmaAppModel
import BrahmaMapKit

/// Nonisolated, so a trait can read it.
private enum PerfGate {
    #if DEBUG
    static let enabled = false   // timings only mean something in a release build
    #else
    static let enabled = ProcessInfo.processInfo.environment["BRAHMA_PERF"] == "1" && MTLCreateSystemDefaultDevice() != nil
    #endif
}

/// Offscreen frame-time checks for the org chart and the office. Run them with
/// `BRAHMA_PERF=1 swift test -c release -Xswiftc -enable-testing --filter MapPerfTests` (the other test files use `@testable`,
/// which a release build only allows with `-enable-testing`). Each run drives a synthetic company through `MapBench` at a
/// fixed 1/60 s step and prints one `MAP BENCH` line; the assertion is the 60 fps budget (16.7 ms at the 95th percentile).
/// Skipped by default: timings mean nothing in a debug build or on a loaded machine.
@Suite(.scratch) struct MapPerfTests {
    static let budgetMs = 16.7

    /// A run empties its defaults suite when it ends (final review M1): nothing of `brahma.mapbench` stays behind.
    @MainActor static var benchDefaultsCleared: Bool {
        UserDefaults.standard.persistentDomain(forName: MapBench.suiteName)?.isEmpty ?? true
    }

    @Test(.enabled(if: PerfGate.enabled, "needs BRAHMA_PERF=1 and a Metal device"))
    @MainActor func sixtyFpsAt300DefaultCollapse() {
        let r = MapBench.run(agents: 300)
        print(r.line)
        #expect(Self.benchDefaultsCleared, "the run left values in its defaults suite")
        #expect(r.frames > 0)
        #expect(r.p95Ms <= Self.budgetMs, "p95 \(r.p95Ms) ms: \(r.line)")
    }

    @Test(.enabled(if: PerfGate.enabled, "needs BRAHMA_PERF=1 and a Metal device"))
    @MainActor func sixtyFpsAt300FullyExpanded() {
        let r = MapBench.run(agents: 300, expandAll: true)
        print(r.line)
        #expect(Self.benchDefaultsCleared, "the run left values in its defaults suite")
        #expect(r.frames > 0)
        #expect(r.p95Ms <= Self.budgetMs, "p95 \(r.p95Ms) ms: \(r.line)")
    }

    @Test(.enabled(if: PerfGate.enabled, "needs BRAHMA_PERF=1 and a Metal device"))
    @MainActor func aggregateFallbackAt600() {
        // The org generator tops out at `OrgGenerator.range` (500), so 600 is clamped: the line says `agents=500`.
        let r = MapBench.run(agents: 600, rate: 120)
        print(r.line)
        #expect(Self.benchDefaultsCleared, "the run left values in its defaults suite")
        #expect(r.agents == OrgGenerator.range.upperBound, "the generator's range changed: \(r.line)")
        #expect(r.frames > 0)
        #expect(r.aggregateSeconds > 0, "120 msg/s never switched the queue to aggregate mode: \(r.line)")
        #expect(r.p95Ms <= Self.budgetMs, "p95 \(r.p95Ms) ms: \(r.line)")
    }

    /// Every run above is in aggregate mode (rate over 30 msg/s), so this one stays under the 20 msg/s exit threshold with no
    /// bursts: message particles are spawned, pooled and drawn on every frame (up to `maxActive`) with every card open.
    @Test(.enabled(if: PerfGate.enabled, "needs BRAHMA_PERF=1, a release build and a Metal device"))
    @MainActor func sixtyFpsAt300WithParticles() {
        let r = MapBench.run(agents: 300, rate: 15, burst: nil, expandAll: true)
        print(r.line)
        #expect(Self.benchDefaultsCleared, "the run left values in its defaults suite")
        #expect(r.frames > 0)
        #expect(r.aggregateSeconds == 0, "aggregate mode ran, so the particle path was not what was measured: \(r.line)")
        #expect(r.p95Ms <= Self.budgetMs, "p95 \(r.p95Ms) ms: \(r.line)")
    }

    // MARK: Office (spec §8; LOD by living agents: full ≤ 50, static ≤ 150, desk-only above)

    /// Full detail (walks, typing, strolls, glow pulse) at 50 msg/s with a 200-message burst every 10 s.
    @Test(.enabled(if: PerfGate.enabled, "needs BRAHMA_PERF=1, a release build and a Metal device"))
    @MainActor func officeSixtyFpsAt50Bursts() {
        let r = MapBench.run(agents: 50, mode: .office)
        print(r.line)
        #expect(Self.benchDefaultsCleared, "the run left values in its defaults suite")
        #expect(r.mode == .office)
        #expect(r.officeLOD == .full, "the row measured another level of detail: \(r.line)")
        #expect(r.frames > 0)
        #expect(r.p95Ms <= Self.budgetMs, "p95 \(r.p95Ms) ms: \(r.line)")
    }

    /// Full detail under the aggregate threshold with no bursts: every message is a note flown from the pool.
    @Test(.enabled(if: PerfGate.enabled, "needs BRAHMA_PERF=1, a release build and a Metal device"))
    @MainActor func officeSixtyFpsAt50Particles() {
        let r = MapBench.run(agents: 50, mode: .office, rate: 15, burst: nil)
        print(r.line)
        #expect(Self.benchDefaultsCleared, "the run left values in its defaults suite")
        #expect(r.mode == .office)
        #expect(r.officeLOD == .full, "the row measured another level of detail: \(r.line)")
        #expect(r.frames > 0)
        #expect(r.aggregateSeconds == 0, "aggregate mode ran, so the note path was not what was measured: \(r.line)")
        #expect(r.p95Ms <= Self.budgetMs, "p95 \(r.p95Ms) ms: \(r.line)")
    }

    /// Static LOD: figures but no walks, typing frames, strolls or pulse.
    @Test(.enabled(if: PerfGate.enabled, "needs BRAHMA_PERF=1, a release build and a Metal device"))
    @MainActor func officeAt150Static() {
        let r = MapBench.run(agents: 150, mode: .office)
        print(r.line)
        #expect(Self.benchDefaultsCleared, "the run left values in its defaults suite")
        #expect(r.mode == .office)
        #expect(r.officeLOD == .staticFigures, "the row measured another level of detail: \(r.line)")
        #expect(r.frames > 0)
        #expect(r.p95Ms <= Self.budgetMs, "p95 \(r.p95Ms) ms: \(r.line)")
    }

    /// Desk-state-only LOD: no figures, desks show state by light, notes are dots.
    @Test(.enabled(if: PerfGate.enabled, "needs BRAHMA_PERF=1, a release build and a Metal device"))
    @MainActor func officeAt300DeskOnly() {
        let r = MapBench.run(agents: 300, mode: .office)
        print(r.line)
        #expect(Self.benchDefaultsCleared, "the run left values in its defaults suite")
        #expect(r.mode == .office)
        #expect(r.officeLOD == .deskOnly, "the row measured another level of detail: \(r.line)")
        #expect(r.frames > 0)
        #expect(r.p95Ms <= Self.budgetMs, "p95 \(r.p95Ms) ms: \(r.line)")
    }
}
