import Foundation
@testable import BrahmaCore

struct FakeError: Error, CustomStringConvertible {
    var description: String
}

/// Scripted `TurnRunning` for orchestrator tests. Each agent handle has a queue of scripts, one per turn;
/// when the queue is empty the default script (a clean success) runs.
final class FakeTurnRunner: TurnRunning, @unchecked Sendable {
    struct Script: Sendable {
        /// `nil` means: `.initialized` then a successful `.result`.
        var events: [StreamEvent]?
        /// Runs mid-stream: after all events but the last.
        var sideEffect: (@Sendable (TurnRequest) throws -> Void)?
        /// Thrown after all events.
        var error: (any Error)?
        /// Simulated work before the first event.
        var delay: Duration?

        init(events: [StreamEvent]? = nil, sideEffect: (@Sendable (TurnRequest) throws -> Void)? = nil,
             error: (any Error)? = nil, delay: Duration? = nil) {
            self.events = events; self.sideEffect = sideEffect; self.error = error; self.delay = delay
        }
    }

    private let lock = NSLock()
    private var scripts: [String: [Script]] = [:]
    private var _requests: [TurnRequest] = []
    private var current = 0
    private var _maxConcurrent = 0
    var defaultScript: Script { get { lock.withLock { _default } } set { lock.withLock { _default = newValue } } }
    private var _default = Script()

    var requests: [TurnRequest] { lock.withLock { _requests } }
    var maxConcurrent: Int { lock.withLock { _maxConcurrent } }

    func script(_ handle: String, _ s: Script...) {
        lock.withLock { scripts[handle, default: []].append(contentsOf: s) }
    }

    static func success(_ r: TurnRequest, text: String = "done") -> [StreamEvent] {
        [.initialized(sessionId: r.agent.sessionId, model: r.agent.model),
         .result(TurnResult(isError: false, subtype: "success", text: text, costUSD: 0.01,
                            apiErrorStatus: nil, sessionId: r.agent.sessionId))]
    }

    func run(_ request: TurnRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        let script: Script = lock.withLock {
            _requests.append(request)
            current += 1
            _maxConcurrent = max(_maxConcurrent, current)
            if var queue = scripts[request.agent.name], !queue.isEmpty {
                let s = queue.removeFirst()
                scripts[request.agent.name] = queue
                return s
            }
            return _default
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                // Leave the concurrency count before the stream ends, so the orchestrator never sees a stale slot.
                let leave = { self.lock.withLock { self.current -= 1 } }
                do {
                    if let delay = script.delay { try await Task.sleep(for: delay) }
                    let events = script.events ?? Self.success(request)
                    for (i, e) in events.enumerated() {
                        if i == events.count - 1 { try script.sideEffect?(request) }
                        continuation.yield(e)
                    }
                    if events.isEmpty { try script.sideEffect?(request) }
                    if let error = script.error { throw error }
                    leave()
                    continuation.finish()
                } catch {
                    leave()
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

/// Mutable injected clock. Values stay on whole seconds so date arithmetic is exact and survives a database
/// round trip (millisecond-precision text columns and JSON-encoded blockers).
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Date
    init(_ start: Date = Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down))) { value = start }
    var now: Date { lock.withLock { value } }
    func advance(_ seconds: TimeInterval) { lock.withLock { value = value.addingTimeInterval(seconds) } }
    var function: @Sendable () -> Date { { [self] in now } }
}
