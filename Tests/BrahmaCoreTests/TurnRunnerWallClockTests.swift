import Testing
import Foundation
@testable import BrahmaCore

/// The shared `#!/bin/sh` script standing in for `claude` (one per body per process), and a working directory for the turn.
private func fakeClaude(_ body: String) throws -> (script: URL, dir: URL) {
    (try FakeTools.script("fake-claude", body), try tempDir())
}

private func request(in dir: URL, wallClock: Duration? = nil) -> TurnRequest {
    // Its own agent id per request: the runner's turn registry is process-wide and keyed by agent id (see TurnRunnerTests).
    let agent = Agent(id: "a1-\(UUID().uuidString)", companyId: "c1", name: "ceo", role: "ceo", model: "sonnet", sessionId: "s1",
                      sessionStarted: false, state: .running, blocker: nil, requestedBlocker: nil, paused: false,
                      readySince: nil, createdAt: Date(timeIntervalSince1970: 0))
    let company = Company(id: "c1", name: "Acme", slug: "acme", goal: "g", workspacePath: dir.path, status: .running,
                          usageMode: .low, priorityWeight: 1, createdAt: Date(timeIntervalSince1970: 0))
    var r = TurnRequest(agent: agent, company: company, prompt: "P", appendSystemPrompt: "ROLE",
                        mcpConfigPath: "/tmp/x.mcp.json", workingDirectory: dir.path, profile: .workspace)
    r.wallClock = wallClock
    return r
}

private func collect(_ stream: AsyncThrowingStream<StreamEvent, Error>) async throws -> [StreamEvent] {
    var out: [StreamEvent] = []
    for try await e in stream { out.append(e) }
    return out
}

private let initLine = #"{"type":"system","subtype":"init","session_id":"s1","model":"claude-haiku-5-5","tools":["Bash"],"agents":["Explore"]}"#
private let resultLine = #"{"type":"result","subtype":"success","is_error":false,"result":"early","session_id":"s1","total_cost_usd":0.5}"#

/// A wall-clock seam that fires once `marker` exists (the script has printed everything the test needs the engine to read).
private func fireWhenExists(_ marker: URL) -> @Sendable (Duration) async throws -> Void {
    { _ in
        while !FileManager.default.fileExists(atPath: marker.path) { try await Task.sleep(for: .milliseconds(10)) }
    }
}

/// Records the wall clock the runner asked for, then fires at once (`fires`) or never (until cancelled).
private final class AskedClocks: @unchecked Sendable {
    private let lock = NSLock()
    private var asked: [Duration] = []
    var values: [Duration] { lock.withLock { asked } }
    func seam(fires: Bool) -> @Sendable (Duration) async throws -> Void {
        { [self] d in
            lock.withLock { asked.append(d) }
            if !fires { try await Task.sleep(for: .seconds(3600)) }
        }
    }
}

/// Task 14a, W7: per-request wall clock, pending background work and signals, with a fake `claude` script.
@Suite(.scratch, .serialized) struct TurnRunnerWallClockTests {
    @Test func deepTurnNotKilledAt15Min() async throws {
        // The runner-wide limit (the Plan 1 fallback, 900 s in production) is 1 s here; the request's own wall clock wins.
        let (script, dir) = try fakeClaude("""
            cat > /dev/null
            echo '\(initLine)'
            sleep 2.5
            echo '\(resultLine)'
            """)
        let quiet = AskedClocks()
        var runner = ClaudeProcessRunner(claudePath: script.path, maxTurnDuration: .seconds(1))
        runner.wallClockSleep = quiet.seam(fires: false)
        let events = try await collect(runner.run(request(in: dir, wallClock: .seconds(30))))
        guard case .result(let r)? = events.last else { Issue.record("no result: \(events)"); return }
        #expect(r.text == "early")
        #expect(quiet.values == [.seconds(30)], "the request's own wall clock, not the runner's 1 s")
        // And the fallback still applies to a request that names no wall clock.
        let firing = AskedClocks()
        runner.wallClockSleep = firing.seam(fires: true)
        await #expect(throws: TurnError.timedOut) { _ = try await collect(runner.run(request(in: dir))) }
        #expect(firing.values == [.seconds(1)])
    }

    @Test func wallClockKillsAtTheRequestsOwnLimit() async throws {
        let (script, dir) = try fakeClaude("""
            cat > /dev/null
            exec sleep 30
            """)
        let asked = AskedClocks()
        var runner = ClaudeProcessRunner(claudePath: script.path, maxTurnDuration: .seconds(60))
        runner.wallClockSleep = asked.seam(fires: true)
        await #expect(throws: TurnError.timedOut) { _ = try await collect(runner.run(request(in: dir, wallClock: .seconds(1)))) }
        #expect(asked.values == [.seconds(1)], "the request's own limit (1 s), not the runner's 60 s")
    }

    @Test func wallClockKillWithPendingWorkflowIsATimeoutDespiteEarlyResult() async throws {
        // Constructed: the first 17 lines are a real workflow recording (init, `task_started`, a non-empty
        // `background_tasks_changed`); the early `result` line is added, as the design observed (the first result said "still running").
        // The engine's own wall clock killed it: a timeout (failed, backed off), not an interruption.
        let cut = try #require(Bundle.module.url(forResource: "stream-workflow-cut17", withExtension: "jsonl", subdirectory: "Fixtures"))
        let (script, dir) = try fakeClaude("""
            cat > /dev/null
            cat '\(cut.path)'
            echo '\(resultLine)'
            touch printed
            exec sleep 30
            """)
        var runner = ClaudeProcessRunner(claudePath: script.path, maxTurnDuration: .seconds(900))
        runner.wallClockSleep = fireWhenExists(dir.appending(path: "printed"))
        var seen: [StreamEvent] = []
        do {
            for try await e in runner.run(request(in: dir)) { seen.append(e) }
            Issue.record("a killed turn with a workflow pending is not a success")
        } catch TurnError.timedOut {
        }
        #expect(seen.contains { if case .result = $0 { true } else { false } }, "the early result was seen")
    }

    @Test func sigtermWithPendingWorkflowIsInterruptedDespiteEarlyResult() async throws {
        let cut = try #require(Bundle.module.url(forResource: "stream-workflow-cut17", withExtension: "jsonl", subdirectory: "Fixtures"))
        let (script, dir) = try fakeClaude("""
            cat > /dev/null
            cat '\(cut.path)'
            echo '\(resultLine)'
            kill -TERM $$
            sleep 5
            """)
        let runner = ClaudeProcessRunner(claudePath: script.path, maxTurnDuration: .seconds(30))
        do {
            _ = try await collect(runner.run(request(in: dir)))
            Issue.record("a terminated turn with a workflow pending is not a success")
        } catch let TurnError.interrupted(pending) {
            #expect(pending == 1)
        }
    }

    @Test func earlyResultWithNothingPendingIsStillAuthoritative() async throws {
        let (script, dir) = try fakeClaude("""
            cat > /dev/null
            echo '\(initLine)'
            echo '\(resultLine)'
            touch printed
            exec sleep 30
            """)
        var runner = ClaudeProcessRunner(claudePath: script.path, maxTurnDuration: .seconds(900))
        runner.wallClockSleep = fireWhenExists(dir.appending(path: "printed"))
        let events = try await collect(runner.run(request(in: dir)))
        guard case .result? = events.last else { Issue.record("no result: \(events)"); return }
    }

    @Test func sigtermWithoutResultInterrupted() async throws {
        let (script, dir) = try fakeClaude("""
            cat > /dev/null
            echo '\(initLine)'
            kill -TERM $$
            sleep 5
            """)
        let runner = ClaudeProcessRunner(claudePath: script.path)
        await #expect(throws: TurnError.interrupted(pendingTasks: 0)) { _ = try await collect(runner.run(request(in: dir))) }
        let (wrapped, dir2) = try fakeClaude("""
            cat > /dev/null
            exit 143
            """)
        await #expect(throws: TurnError.interrupted(pendingTasks: 0)) {
            _ = try await collect(ClaudeProcessRunner(claudePath: wrapped.path).run(request(in: dir2)))
        }
        // Any other exit without a result is still an error with the stderr tail.
        let (broken, dir3) = try fakeClaude("cat > /dev/null\nexit 1")
        do {
            _ = try await collect(ClaudeProcessRunner(claudePath: broken.path).run(request(in: dir3)))
            Issue.record("expected an error")
        } catch TurnError.exitedWithoutResult(let code, _) { #expect(code == 1) }
    }

    @Test func effortCapWarningRecorded() async throws {
        let (script, dir) = try fakeClaude("""
            cat > /dev/null
            echo "Effort 'max' exceeds the cap" >&2
            echo '\(initLine)'
            echo '\(resultLine)'
            """)
        let events = try await collect(ClaudeProcessRunner(claudePath: script.path).run(request(in: dir)))
        #expect(events.contains(.effortCapped(requested: "max")))
        var state = TurnStreamState()
        for e in events { state.apply(e) }
        #expect(state.effortCapRequested == "max")
    }

    @Test func toolBlocksReachTheStream() async throws {
        let fixture = try #require(Bundle.module.url(forResource: "stream-tools", withExtension: "jsonl", subdirectory: "Fixtures"))
        let (script, dir) = try fakeClaude("cat > /dev/null\ncat '\(fixture.path)'")
        let events = try await collect(ClaudeProcessRunner(claudePath: script.path).run(request(in: dir)))
        #expect(events.filter { if case .toolUse = $0 { true } else { false } }.count == 1)
        #expect(events.filter { if case .toolResult = $0 { true } else { false } }.count == 1)
        var state = TurnStreamState()
        for e in events { state.apply(e) }
        #expect(state.toolSignature != nil)
    }
}
