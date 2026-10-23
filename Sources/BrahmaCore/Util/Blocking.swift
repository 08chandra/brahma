import Foundation

/// Runs blocking work (git, `waitUntilExit`, flock polling, `Thread.sleep` retries) on a thread of its own, so it never occupies
/// a Swift concurrency worker. A saturated cooperative pool would otherwise stall the orchestrator's tick, every turn's stream
/// consumption and any test waiting on them.
///
/// One `Blocking` per engine (the Orchestrator owns it): at most `maxConcurrent` bodies of that engine run at once, so engines
/// in one process (parallel test engines, the app plus a CLI) never starve each other. A body's thread is started only once it
/// holds a slot; the others wait as queued closures, not as parked threads.
final class Blocking: @unchecked Sendable {
    static let maxConcurrent = 8
    private let lock = NSLock()
    private var free: Int
    private var queue: [@Sendable () -> Void] = []

    init(maxConcurrent: Int = Blocking.maxConcurrent) { free = maxConcurrent }

    private func acquire(_ start: @escaping @Sendable () -> Void) {
        lock.lock()
        if free > 0 { free -= 1; lock.unlock(); start() } else { queue.append(start); lock.unlock() }
    }

    private func release() {
        lock.lock()
        if queue.isEmpty { free += 1; lock.unlock() } else { let next = queue.removeFirst(); lock.unlock(); next() }
    }

    /// Runs `body` on its own thread (started once a slot is free) and returns its value.
    func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            acquire {
                let thread = Thread { [self] in
                    let value = body()
                    release()
                    continuation.resume(returning: value)
                }
                thread.name = "brahma-blocking"
                thread.stackSize = 1 << 20
                thread.start()
            }
        }
    }

    /// `run` for a body that throws.
    func tryRun<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        let result: Result<T, any Error> = await run { Result { try body() } }
        return try result.get()
    }
}
