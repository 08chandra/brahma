import Foundation
@testable import BrahmaCore

struct FakeError: Error, CustomStringConvertible {
    var description: String
}

/// A latch a script can wait on, so a test decides when a turn finishes instead of racing a timer.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func open() {
        let toResume: [CheckedContinuation<Void, Never>] = lock.withLock {
            isOpen = true
            defer { waiters.removeAll() }
            return waiters
        }
        for w in toResume { w.resume() }
    }

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resumeNow = lock.withLock { () -> Bool in
                if isOpen { return true }
                waiters.append(c)
                return false
            }
            if resumeNow { c.resume() }
        }
    }
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
        /// Held until the test opens it (before the first event, after `delay`).
        var gate: Gate?
        /// The result text of the default success (`events == nil`); "done" when nil.
        var text: String?

        init(events: [StreamEvent]? = nil, sideEffect: (@Sendable (TurnRequest) throws -> Void)? = nil,
             error: (any Error)? = nil, delay: Duration? = nil, gate: Gate? = nil, text: String? = nil) {
            self.events = events; self.sideEffect = sideEffect; self.error = error; self.delay = delay; self.gate = gate; self.text = text
        }
    }

    private let lock = NSLock()
    private var scripts: [String: [Script]] = [:]
    private var _requests: [TurnRequest] = []
    private var current = 0
    private var _maxConcurrent = 0
    var defaultScript: Script { get { lock.withLock { _default } } set { lock.withLock { _default = newValue } } }
    private var _default = Script()
    private var totals: [String: Double] = [:]
    private var _cumulativeCosts = true
    /// The real CLI reports `total_cost_usd` cumulatively over `--resume` (probe L-4). While this is true (the default) the
    /// fake turns each scripted `costUSD` into that turn's cost and reports the session's running total, as the CLI does.
    var cumulativeCosts: Bool { get { lock.withLock { _cumulativeCosts } } set { lock.withLock { _cumulativeCosts = newValue } } }

    private func cumulative(_ event: StreamEvent) -> StreamEvent {
        guard case .result(var r) = event, let cost = r.costUSD else { return event }
        return lock.withLock {
            guard _cumulativeCosts else { return event }
            totals[r.sessionId, default: 0] += cost
            r.costUSD = totals[r.sessionId]
            return .result(r)
        }
    }

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
                    if let gate = script.gate { await gate.wait() }
                    let events = script.events ?? Self.success(request, text: script.text ?? "done")
                    for (i, e) in events.enumerated() {
                        if i == events.count - 1 { try script.sideEffect?(request) }
                        continuation.yield(self.cumulative(e))
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
