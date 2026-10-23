import Foundation

/// Runs blocking work (git, `waitUntilExit`, flock polling, `Thread.sleep` retries) on a thread of its own, so it never occupies
/// a Swift concurrency worker. The same pattern as `ProcessCheckRunner`: a `Thread` plus a continuation. A saturated cooperative
/// pool would otherwise stall the orchestrator's tick, every turn's stream consumption and any test waiting on them.
enum Blocking {
    /// Runs `body` on its own thread and returns its value.
    static func run<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
        await withCheckedContinuation { (continuation: CheckedContinuation<T, Never>) in
            let thread = Thread { continuation.resume(returning: body()) }
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
