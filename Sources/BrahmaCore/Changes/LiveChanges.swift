import Foundation

/// Plan C Task C5b: live changes streams. One recompute loop per (company, item, compare) while at least one observer
/// streams it: every `interval` while the holder is running, every `idle` when it isn't; a `nudge` (the app's FSEvents
/// trigger) asks for an early recompute but never breaks the one-per-`interval` rate; the loop stops when the last observer
/// cancels. Each observer gets the snapshot for its own reader (access checked each cycle) and known values, and only when
/// its `patchHash` changes. The git work runs in a detached task (never on the engine actor's executor, never with its
/// task-local engine id).
public actor LiveChanges {
    public struct Stats: Equatable, Sendable {
        public var recomputes = 0
        public var yields = 0
    }

    struct Key: Hashable, Sendable {
        let companyId: String, key: String, compare: CompareMode
    }

    final class Observer {
        let id = UUID()
        let reader: Reader
        let knownValues: [(name: String, value: String)]
        let continuation: AsyncStream<ChangesSnapshot>.Continuation
        var lastHash: String?
        init(reader: Reader, knownValues: [(name: String, value: String)], continuation: AsyncStream<ChangesSnapshot>.Continuation) {
            self.reader = reader; self.knownValues = knownValues; self.continuation = continuation
        }
    }

    final class Watch {
        var observers: [Observer] = []
        var sleeper: Task<Void, any Error>?
        var nudged = false
        var lastRaw: RawChanges?
        var stats = Stats()
        var loop: Task<Void, Never>?
    }

    private let store: Store
    private let interval: Duration
    private let idle: Duration
    private let clock: LiveClock
    private var watches: [Key: Watch] = [:]

    public init(store: Store, interval: Duration = ChangesLimits.refreshInterval, idle: Duration = ChangesLimits.idleInterval,
                clock: any Clock<Duration> = ContinuousClock()) {
        self.store = store; self.interval = interval; self.idle = idle
        self.clock = LiveClock(clock)
    }

    /// A stream of snapshots for `reader`: the first as soon as it is computed, then one per change. It ends when the reader
    /// can't read the compare (refused or missing) or when it is cancelled.
    public func watch(companyId: String, key: String, compare: CompareMode, reader: Reader,
                      knownValues: [(name: String, value: String)]) -> AsyncStream<ChangesSnapshot> {
        let id = Key(companyId: companyId, key: key, compare: compare)
        var made: Observer?
        let stream = AsyncStream<ChangesSnapshot> { continuation in
            made = Observer(reader: reader, knownValues: knownValues, continuation: continuation)
        }
        guard let observer = made else { return stream }
        let observerId = observer.id
        observer.continuation.onTermination = { [weak self] _ in
            Task { [weak self] in await self?.remove(id, observerId) }
        }
        let watch = watches[id] ?? Watch()
        watch.observers.append(observer)
        watches[id] = watch
        if let raw = watch.lastRaw {
            // A joiner mid-cycle gets the last computed state at once (for its own reader and values).
            if (try? store.checkChangesAccess(companyId: companyId, key: key, compare: compare, reader: reader)) == nil {
                observer.continuation.finish()
            } else {
                deliver(raw, to: observer, watch: watch, now: Store.now())
            }
        }
        if watch.loop == nil {
            watch.loop = Task { [weak self] in await self?.run(id) }
        }
        return stream
    }

    /// Asks for an early recompute of every watch of `key` (any company, any compare), within the rate limit.
    public func nudge(key: String) {
        for (id, watch) in watches where id.key == key {
            watch.nudged = true
            watch.sleeper?.cancel()
        }
    }

    public func stats(companyId: String, key: String, compare: CompareMode) -> Stats {
        watches[Key(companyId: companyId, key: key, compare: compare)]?.stats ?? Stats()
    }

    public func isWatching(companyId: String, key: String, compare: CompareMode) -> Bool {
        watches[Key(companyId: companyId, key: key, compare: compare)] != nil
    }

    // MARK: The loop

    private func remove(_ id: Key, _ observerId: UUID) {
        guard let watch = watches[id] else { return }
        watch.observers.removeAll { $0.id == observerId }
        if watch.observers.isEmpty { watch.sleeper?.cancel() }
    }

    private func run(_ id: Key) async {
        while let watch = watches[id], !watch.observers.isEmpty {
            await recompute(id, watch: watch)
            watch.nudged = false
            // Sleep until the next due time; a nudge wakes the sleep early, but the recompute waits out `interval` since the
            // last one (the rate limit), whatever the cadence in force.
            let cadence = holderRunning(id) ? interval : idle
            let computed = clock.now()
            var remaining = cadence
            while remaining > .zero {
                guard let current = watches[id], !current.observers.isEmpty else { break }
                let sleep = clock.sleep, wait = remaining
                let sleeper = Task { try await sleep(wait) }
                current.sleeper = sleeper
                let woke = (try? await sleeper.value) != nil
                current.sleeper = nil
                let elapsed = clock.now() - computed
                if woke { break }
                guard current.nudged else { remaining = max(cadence - elapsed, .zero); continue }
                if elapsed >= interval { break }
                remaining = interval - elapsed
            }
        }
        if let watch = watches[id] {
            for observer in watch.observers { observer.continuation.finish() }
            watches.removeValue(forKey: id)
        }
    }

    private func recompute(_ id: Key, watch: Watch) async {
        let store = self.store
        // Off this actor and free of any engine task-local: a detached task runs the git work.
        let result = await Task.detached(priority: .utility) { () -> Result<RawChanges, any Error> in
            do { return .success(try store.changesRaw(companyId: id.companyId, key: id.key, compare: id.compare)) }
            catch { return .failure(error) }
        }.value
        watch.stats.recomputes += 1
        switch result {
        case .failure:
            // The item or its worktree is gone (or refused): every observer's stream ends.
            for observer in watch.observers { observer.continuation.finish() }
            watch.observers.removeAll()
        case .success(let raw):
            watch.lastRaw = raw
            let now = Store.now()
            for observer in watch.observers {
                if (try? store.checkChangesAccess(companyId: id.companyId, key: id.key, compare: id.compare, reader: observer.reader)) == nil {
                    observer.continuation.finish()
                    continue
                }
                deliver(raw, to: observer, watch: watch, now: now)
            }
        }
    }

    private func deliver(_ raw: RawChanges, to observer: Observer, watch: Watch, now: Date) {
        let snapshot = Store.finishChanges(raw, knownValues: observer.knownValues, now: now)
        guard snapshot.patchHash != observer.lastHash else { return }
        observer.lastHash = snapshot.patchHash
        watch.stats.yields += 1
        observer.continuation.yield(snapshot)
    }

    /// Whether the item's lease holder is running a turn now (engine records; a missing lease or agent reads as not running).
    private func holderRunning(_ id: Key) -> Bool {
        guard let lease = try? store.lease(companyId: id.companyId, key: id.key), let agent = try? store.agent(id: lease.agentId),
              agent.companyId == id.companyId else { return false }
        return agent.state == .running
    }
}

/// The loop's view of a clock (sleeps and elapsed time), opened once from the `any Clock<Duration>` the actor was given.
struct LiveClock: Sendable {
    let sleep: @Sendable (Duration) async throws -> Void
    /// Elapsed since the clock was wrapped.
    let now: @Sendable () -> Duration

    init<C: Clock<Duration>>(_ clock: C) {
        let start = clock.now
        sleep = { try await clock.sleep(for: $0, tolerance: nil) }
        now = { start.duration(to: clock.now) }
    }
}
