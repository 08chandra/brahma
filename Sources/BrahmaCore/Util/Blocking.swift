import Foundation

/// Runs blocking work (git, `waitUntilExit`, flock polling, `Thread.sleep` retries) on a thread of its own, so it never occupies
/// a Swift concurrency worker. The same pattern as `ProcessCheckRunner`: a `Thread` plus a continuation. A saturated cooperative
/// pool would otherwise stall the orchestrator's tick, every turn's stream consumption and any test waiting on them.
///
/// At most `maxConcurrent` bodies run at once (each typically one git process at a time); the others' threads wait their turn
/// on a semaphore, on their own threads, never on a concurrency worker. A body is synchronous, so it never needs a second slot.
enum Blocking {
    static let maxConcurrent = 8
    private static let slots = DispatchSemaphore(value: maxConcurrent)

    /// Runs `body` on its own thread (once a slot is free) and returns its value.
    static func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            let thread = Thread {
                slots.wait()
                let value = body()
                slots.signal()
                continuation.resume(returning: value)
            }
            thread.name = "brahma-blocking"
            thread.stackSize = 1 << 20
            thread.start()
        }
    }

    /// `run` for a body that throws.
    static func tryRun<T: Sendable>(_ body: @escaping @Sendable () throws -> T) async throws -> T {
        let result: Result<T, any Error> = await run { Result { try body() } }
        return try result.get()
    }
}
