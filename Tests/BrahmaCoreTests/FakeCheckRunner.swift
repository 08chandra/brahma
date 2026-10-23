import Foundation
@testable import BrahmaCore

/// Scripted `CheckRunning` for orchestrator tests. Outcomes are taken from the queue (a pass when it is empty) unless the
/// hook returns one; every call is recorded. `gate(true)` holds runs until `gate(false)`.
final class FakeCheckRunner: CheckRunning, @unchecked Sendable {
    struct Call: Sendable {
        var command: String
        var workingDirectory: URL
        var timeout: TimeInterval
        var outputURL: URL
        var environment: [String: String]
    }
    typealias Hook = @Sendable (Call) async -> CheckOutcome?

    static let pass = CheckOutcome(exitCode: 0, timedOut: false, tail: "all good")
    static func fail(_ tail: String = "1 test failed", code: Int32 = 1) -> CheckOutcome {
        CheckOutcome(exitCode: code, timedOut: false, tail: tail)
    }
    static let timeout = CheckOutcome(exitCode: nil, timedOut: true, tail: "still running")

    private let lock = NSLock()
    private var queue: [CheckOutcome] = []
    private var _calls: [Call] = []
    private var hook: Hook?
    private var gated = false
    private var current = 0
    private var _maxConcurrent = 0

    var calls: [Call] { lock.withLock { _calls } }
    var maxConcurrent: Int { lock.withLock { _maxConcurrent } }
    var inFlight: Int { lock.withLock { current } }

    func enqueue(_ outcomes: CheckOutcome...) { lock.withLock { queue.append(contentsOf: outcomes) } }
    func onRun(_ h: Hook?) { lock.withLock { hook = h } }
    func gate(_ on: Bool) { lock.withLock { gated = on } }

    func run(command: String, workingDirectory: URL, timeout: TimeInterval, outputURL: URL,
             environment: [String: String]) async -> CheckOutcome {
        let call = Call(command: command, workingDirectory: workingDirectory, timeout: timeout, outputURL: outputURL,
                        environment: environment)
        let h: Hook? = lock.withLock {
            _calls.append(call)
            current += 1
            _maxConcurrent = max(_maxConcurrent, current)
            return hook
        }
        defer { lock.withLock { current -= 1 } }
        while lock.withLock({ gated }) { try? await Task.sleep(for: .milliseconds(5)) }
        var outcome = await h?(call)
        if outcome == nil { outcome = lock.withLock { queue.isEmpty ? nil : queue.removeFirst() } }
        let result = outcome ?? Self.pass
        try? FileManager.default.createDirectory(at: outputURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? result.tail.write(to: outputURL, atomically: true, encoding: .utf8)
        return result
    }
}
