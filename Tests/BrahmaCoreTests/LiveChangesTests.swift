import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Plan C Task C5b: `LiveChanges` — recomputes on the refresh interval while observed, yields only on change, one recompute
/// per interval per (item, compare) across observers and nudges, the idle interval when the holder isn't running, and
/// nothing once the last observer is gone.
@Suite(.scratch) struct LiveChangesTests {
    /// A clock that moves only when told to; `Task.sleep(for:clock:)` on it waits for `advance`.
    final class ManualClock: Clock, @unchecked Sendable {
        struct Instant: InstantProtocol, Hashable {
            typealias Duration = Swift.Duration
            var offset: Duration
            func advanced(by duration: Duration) -> Instant { Instant(offset: offset + duration) }
            func duration(to other: Instant) -> Duration { other.offset - offset }
            static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
        }
        private let lock = NSLock()
        private var current = Instant(offset: .zero)
        private var waiting: [(deadline: Instant, continuation: CheckedContinuation<Void, any Error>)] = []
        var now: Instant { lock.withLock { current } }
        var minimumResolution: Duration { .zero }
        var sleepers: Int { lock.withLock { waiting.count } }
        func sleep(until deadline: Instant, tolerance: Duration?) async throws {
            try await withTaskCancellationHandler {
                try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                    let due: Bool = lock.withLock {
                        if deadline <= current { return true }
                        waiting.append((deadline, c))
                        return false
                    }
                    if due { c.resume() }
                }
            } onCancel: {
                let cancelled: [CheckedContinuation<Void, any Error>] = lock.withLock {
                    let all = waiting.map(\.continuation)
                    waiting.removeAll()
                    return all
                }
                cancelled.forEach { $0.resume(throwing: CancellationError()) }
            }
        }
        func advance(by duration: Duration) {
            let due: [CheckedContinuation<Void, any Error>] = lock.withLock {
                current = current.advanced(by: duration)
                let fired = waiting.filter { $0.deadline <= current }.map(\.continuation)
                waiting.removeAll { $0.deadline <= current }
                return fired
            }
            due.forEach { $0.resume() }
        }
        /// Waits (real time, bounded) until `n` tasks sleep on this clock.
        func waitForSleepers(_ n: Int = 1) async {
            for _ in 0..<2000 where sleepers < n { try? await Task.sleep(for: .milliseconds(5)) }
        }
    }

    struct Harness {
        let f: ChangesFixture
        let clock: ManualClock
        let live: LiveChanges
        init() throws {
            f = try ChangesFixture()
            clock = ManualClock()
            live = LiveChanges(store: f.store, clock: clock)
        }
        func watch(as who: RefFixture.Who = .owner, compare: CompareMode = .main) async -> AsyncStream<ChangesSnapshot> {
            await live.watch(companyId: f.c.id, key: "ENG-1", compare: compare, reader: f.fx.reader(who), knownValues: [])
        }
        func stats() async -> LiveChanges.Stats { await live.stats(companyId: f.c.id, key: "ENG-1", compare: .main) }
        /// Waits (real time, bounded) until the recompute count reaches `n`.
        func waitForRecomputes(_ n: Int) async {
            for _ in 0..<2000 where await stats().recomputes < n { try? await Task.sleep(for: .milliseconds(5)) }
        }
        func setHolder(_ state: AgentState) throws {
            let id = f.fx.eng1.id
            try f.store.writer.write { db in try db.execute(sql: "UPDATE agent SET state = ? WHERE id = ?", arguments: [state.rawValue, id]) }
        }
    }

    @Test func liveDiffUpdatesWithin2s() async throws {
        #expect(ChangesLimits.refreshInterval == .seconds(2))
        #expect(ChangesLimits.idleInterval == .seconds(10))
        let h = try Harness()
        try h.setHolder(.running)
        let stream = await h.watch()
        var it = stream.makeAsyncIterator()
        let first = try #require(await it.next())
        #expect(first.patch.contains("+five") && !first.patch.contains("+six"))
        await h.clock.waitForSleepers()
        try h.f.fx.git.write("src/a.ts", "one\nTWO\nthree\nfour\nfive\nsix\n", in: h.f.wt)
        h.clock.advance(by: .seconds(2))
        let second = try #require(await it.next())
        #expect(second.patch.contains("+six") && second.patchHash != first.patchHash)
        #expect(await h.stats().recomputes == 2)
    }

    @Test func noYieldWithoutChange() async throws {
        let h = try Harness()
        try h.setHolder(.running)
        let stream = await h.watch()
        var it = stream.makeAsyncIterator()
        _ = try #require(await it.next())
        for n in 2...4 {
            await h.clock.waitForSleepers()
            h.clock.advance(by: .seconds(2))
            await h.waitForRecomputes(n)
        }
        let s = await h.stats()
        #expect(s.recomputes == 4 && s.yields == 1)
    }

    @Test func rateLimitedAcrossObservers() async throws {
        let h = try Harness()
        try h.setHolder(.running)
        let a = await h.watch(), b = await h.watch(as: .qa2)
        var ia = a.makeAsyncIterator(), ib = b.makeAsyncIterator()
        _ = try #require(await ia.next())
        _ = try #require(await ib.next())
        #expect(await h.stats().recomputes == 1)
        await h.clock.waitForSleepers()
        for _ in 0..<20 { await h.live.nudge(key: "ENG-1") }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await h.stats().recomputes == 1, "a nudge never recomputes before the interval")
        await h.clock.waitForSleepers()
        h.clock.advance(by: .seconds(2))
        await h.waitForRecomputes(2)
        #expect(await h.stats().recomputes == 2)
        // A nudge after the interval has passed since the last compute recomputes at once, and only once.
        await h.clock.waitForSleepers()
        h.clock.advance(by: .seconds(1))
        try? await Task.sleep(for: .milliseconds(50))
        #expect(await h.stats().recomputes == 2)
        h.clock.advance(by: .seconds(1))
        await h.waitForRecomputes(3)
        await h.clock.waitForSleepers()
        for _ in 0..<5 { await h.live.nudge(key: "ENG-1") }
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await h.stats().recomputes == 3)
    }

    @Test func idleIntervalWhenHolderNotRunning() async throws {
        let h = try Harness()
        try h.setHolder(.ready)
        let stream = await h.watch()
        var it = stream.makeAsyncIterator()
        _ = try #require(await it.next())
        await h.clock.waitForSleepers()
        h.clock.advance(by: .seconds(2))
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await h.stats().recomputes == 1, "the idle interval applies while the holder isn't running")
        h.clock.advance(by: .seconds(8))
        await h.waitForRecomputes(2)
        #expect(await h.stats().recomputes == 2)
        // A nudge while idle still waits for the refresh interval since the last compute.
        await h.clock.waitForSleepers()
        await h.live.nudge(key: "ENG-1")
        try? await Task.sleep(for: .milliseconds(100))
        #expect(await h.stats().recomputes == 2)
        await h.clock.waitForSleepers()
        h.clock.advance(by: .seconds(2))
        await h.waitForRecomputes(3)
        #expect(await h.stats().recomputes == 3)
    }

    @Test func stopsWhenUnobserved() async throws {
        let h = try Harness()
        try h.setHolder(.running)
        let runner = PassthroughRecordingRunner()
        h.f.store.refHooks.setGitRunner(runner)
        defer { h.f.store.refHooks.setGitRunner(nil) }
        let consumer = Task {
            var seen = 0
            for await _ in await h.watch() { seen += 1 }
            return seen
        }
        await h.waitForRecomputes(1)
        await h.clock.waitForSleepers()
        consumer.cancel()
        let seen = await consumer.value
        #expect(seen == 1)
        for _ in 0..<50 where await h.live.isWatching(companyId: h.f.c.id, key: "ENG-1", compare: .main) { try? await Task.sleep(for: .milliseconds(5)) }
        let calls = runner.calls.count
        await h.live.nudge(key: "ENG-1")
        h.clock.advance(by: .seconds(30))
        try? await Task.sleep(for: .milliseconds(150))
        #expect(runner.calls.count == calls, "no git call after the last observer left")
        #expect(await h.stats().recomputes == 0, "the watch is gone")
        #expect(h.clock.sleepers == 0)
    }
}
