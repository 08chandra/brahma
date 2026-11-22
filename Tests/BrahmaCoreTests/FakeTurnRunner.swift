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

    /// Whether `open` has been called.
    var opened: Bool { lock.withLock { isOpen } }

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

    /// `wait()` raced against `limit` (awake time): true when the gate opened, false when the limit passed first (the gate is
    /// then opened, so the waiter it left behind resumes too). For a test's helper tasks, which must end even when the gate's
    /// opener never ran (Task 10 fix round 1, I1).
    @discardableResult
    func wait(upTo limit: Duration) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask { await self.wait(); return true }
            group.addTask {
                try? await AwakeTime.sleep(for: limit)
                return false
            }
            let first = await group.next() ?? false
            group.cancelAll()
            if !first { open() }
            return first
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
        /// Held until the test opens it after this many events were yielded (a turn already running, Task 14u).
        var pauseAfter: Int?
        var pauseGate: Gate?
        /// Builds the events from the request the runner was given (its session id, say); used instead of `events` when set.
        var make: (@Sendable (TurnRequest) -> [StreamEvent])?

        init(events: [StreamEvent]? = nil, sideEffect: (@Sendable (TurnRequest) throws -> Void)? = nil,
             error: (any Error)? = nil, delay: Duration? = nil, gate: Gate? = nil, text: String? = nil,
             pauseAfter: Int? = nil, pauseGate: Gate? = nil, make: (@Sendable (TurnRequest) -> [StreamEvent])? = nil) {
            self.events = events; self.sideEffect = sideEffect; self.error = error; self.delay = delay; self.gate = gate; self.text = text
            self.pauseAfter = pauseAfter; self.pauseGate = pauseGate; self.make = make
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
    /// What `waitForTurnProcesses` reports (processes of an earlier turn it killed, and any it could not).
    var leftovers: TurnLeftovers { get { lock.withLock { _leftovers } } set { lock.withLock { _leftovers = newValue } } }
    private var _leftovers = TurnLeftovers()
    /// What `waitForTurnProcesses` throws instead, when set.
    var waitError: (any Error)? { get { lock.withLock { _waitError } } set { lock.withLock { _waitError = newValue } } }
    private var _waitError: (any Error)?
    func waitForTurnProcesses(agentId: String, records: URL) async throws -> TurnLeftovers {
        if let e = waitError { throw e }
        return leftovers
    }
    var maxConcurrent: Int { lock.withLock { _maxConcurrent } }

    /// Lingering children (Task 9c): when `childrenGate` is set, `waitForChildren` opens `childrenEntered` (if set) and waits
    /// for the gate, as the real runner waits for a `claude` that takes its time to die.
    var childrenGate: Gate? { get { lock.withLock { _childrenGate } } set { lock.withLock { _childrenGate = newValue } } }
    private var _childrenGate: Gate?
    var childrenEntered: Gate? { get { lock.withLock { _childrenEntered } } set { lock.withLock { _childrenEntered = newValue } } }
    private var _childrenEntered: Gate?

    func waitForChildren() async {
        childrenEntered?.open()
        if let gate = childrenGate { await gate.wait() }
    }

    func script(_ handle: String, _ s: Script...) {
        lock.withLock { scripts[handle, default: []].append(contentsOf: s) }
    }

    static func success(_ r: TurnRequest, text: String = "done") -> [StreamEvent] {
        [.initialized(sessionId: r.agent.sessionId, model: r.agent.model),
         .result(TurnResult(isError: false, subtype: "success", text: text, costUSD: 0.01,
                            apiErrorStatus: nil, sessionId: r.agent.sessionId))]
    }

    /// Answers `control` sessions (the zero-inference control probe, Task 14u); nil: none (the default, as 3a's fakes).
    var controlResponder: (@Sendable (TurnRequest, [JSONValue]) -> ControlTranscript?)? {
        get { lock.withLock { _controlResponder } } set { lock.withLock { _controlResponder = newValue } }
    }
    private var _controlResponder: (@Sendable (TurnRequest, [JSONValue]) -> ControlTranscript?)?
    private var _controlRequests = 0
    var controlRequests: Int { lock.withLock { _controlRequests } }

    func control(_ request: TurnRequest, messages: [JSONValue], timeout: Duration) async -> ControlTranscript? {
        guard let responder = controlResponder else { return nil }
        lock.withLock { _controlRequests += 1 }
        return responder(request, messages)
    }

    /// Called as each turn reaches the runner (a test opens a `Gate` here to know the turn is in flight).
    var onRun: (@Sendable (TurnRequest) -> Void)? { get { lock.withLock { _onRun } } set { lock.withLock { _onRun = newValue } } }
    private var _onRun: (@Sendable (TurnRequest) -> Void)?

    func run(_ request: TurnRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        onRun?(request)
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
            // A turn is a child process, not engine work: what its script does (an agent's MCP tool calls, say) runs outside the
            // engine's tasks, as it would in production (`EngineGitGuard`).
            let task = Task { await EngineGitGuard.$engine.withValue(nil) {
                // Leave the concurrency count before the stream ends, so the orchestrator never sees a stale slot.
                let leave = { self.lock.withLock { self.current -= 1 } }
                do {
                    if let delay = script.delay { try await Task.sleep(for: delay) }
                    if let gate = script.gate { await gate.wait() }
                    let events = script.make?(request) ?? script.events ?? Self.success(request, text: script.text ?? "done")
                    for (i, e) in events.enumerated() {
                        if i == script.pauseAfter, let pause = script.pauseGate { await pause.wait(); try Task.checkCancellation() }
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
            } }
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
