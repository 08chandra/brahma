import Foundation

/// A `Clock` that moves only when `advance(by:)` is called: it stands for a clock that stands still, such as the suspending
/// clock while the Mac sleeps. Sleepers wake once the clock has been advanced to their deadline, or when cancelled.
final class ManualClock: Clock, @unchecked Sendable {
    struct Instant: InstantProtocol {
        var offset: Duration
        func advanced(by d: Duration) -> Instant { Instant(offset: offset + d) }
        func duration(to other: Instant) -> Duration { other.offset - offset }
        static func < (a: Instant, b: Instant) -> Bool { a.offset < b.offset }
    }

    private struct Sleeper { var deadline: Instant; var continuation: CheckedContinuation<Void, any Error> }

    private let lock = NSLock()
    private var current = Instant(offset: .zero)
    private var sleepers: [UUID: Sleeper] = [:]

    var now: Instant { lock.withLock { current } }
    var minimumResolution: Duration { .nanoseconds(1) }
    /// Sleepers not yet woken.
    var sleeping: Int { lock.withLock { sleepers.count } }

    func sleep(until deadline: Instant, tolerance: Duration?) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                let resumeNow: Bool = lock.withLock {
                    if Task.isCancelled || deadline <= current { return true }
                    sleepers[id] = Sleeper(deadline: deadline, continuation: c)
                    return false
                }
                if resumeNow { Task.isCancelled ? c.resume(throwing: CancellationError()) : c.resume() }
            }
        } onCancel: {
            let c = lock.withLock { sleepers.removeValue(forKey: id)?.continuation }
            c?.resume(throwing: CancellationError())
        }
    }

    func advance(by d: Duration) {
        let due: [CheckedContinuation<Void, any Error>] = lock.withLock {
            current = current.advanced(by: d)
            let ready = sleepers.filter { $0.value.deadline <= current }
            for key in ready.keys { sleepers[key] = nil }
            return ready.values.map(\.continuation)
        }
        for c in due { c.resume() }
    }
}
