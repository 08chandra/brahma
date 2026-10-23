import Testing
import Foundation
@testable import BrahmaCore

/// Writes an executable `#!/bin/sh` script standing in for `claude`.
private func fakeClaude(_ body: String) throws -> (script: URL, dir: URL) {
    let dir = try tempDir()
    let url = dir.appending(path: "fake-claude")
    try ("#!/bin/sh\n" + body + "\n").write(to: url, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
    return (url, dir)
}

private func request(in dir: URL) -> TurnRequest {
    let agent = Agent(id: "a1", companyId: "c1", name: "ceo", role: "ceo", model: "sonnet", sessionId: "s1",
                      sessionStarted: false, state: .running, blocker: nil, requestedBlocker: nil, paused: false,
                      readySince: nil, createdAt: Date(timeIntervalSince1970: 0))
    let company = Company(id: "c1", name: "Acme", slug: "acme", goal: "g", workspacePath: dir.path, status: .running,
                          usageMode: .low, priorityWeight: 1, createdAt: Date(timeIntervalSince1970: 0))
    return TurnRequest(agent: agent, company: company, prompt: "SECRET PROMPT", appendSystemPrompt: "ROLE",
                       mcpConfigPath: "/tmp/x.mcp.json", workingDirectory: dir.path, profile: .workspace)
}

private func collect(_ stream: AsyncThrowingStream<StreamEvent, Error>) async throws -> [StreamEvent] {
    var out: [StreamEvent] = []
    for try await e in stream { out.append(e) }
    return out
}

@Suite(.serialized) struct TurnRunnerTests {
    @Test func runsExecutableFeedsPromptOnStdinAndParsesStdout() async throws {
        let fixture = try #require(Bundle.module.url(forResource: "stream-success", withExtension: "jsonl",
                                                     subdirectory: "Fixtures"))
        let (script, dir) = try fakeClaude("""
            cat > stdin.txt
            for a in "$@"; do echo "$a"; done > args.txt
            echo "not json"
            cat '\(fixture.path)'
            """)
        let runner = ClaudeProcessRunner(claudePath: script.path)
        let events = try await collect(runner.run(request(in: dir)))
        #expect(events.count == 5, "init, its details, assistant text, rate limit, result")
        guard case .initialized(let session, _) = events.first else { Issue.record("no init"); return }
        #expect(session == "7081f66a-b7b1-4f6f-96e7-c690d4b0cec0")
        guard case .result(let r) = events.last else { Issue.record("no result"); return }
        #expect(r.isError == false); #expect(r.text == "ok")
        #expect(try String(contentsOf: dir.appending(path: "stdin.txt"), encoding: .utf8) == "SECRET PROMPT")
        let args = try String(contentsOf: dir.appending(path: "args.txt"), encoding: .utf8)
        #expect(args.contains("--append-system-prompt\nROLE\n"))
        #expect(!args.contains("SECRET PROMPT"))
    }

    @Test func exitWithoutResultThrowsWithStderrTail() async throws {
        let (script, dir) = try fakeClaude("""
            cat > /dev/null
            echo '{"type":"system","subtype":"init","session_id":"s1","model":"m"}'
            echo "something went wrong" >&2
            exit 3
            """)
        let runner = ClaudeProcessRunner(claudePath: script.path)
        var seen: [StreamEvent] = []
        do {
            for try await e in runner.run(request(in: dir)) { seen.append(e) }
            Issue.record("expected an error")
        } catch let TurnError.exitedWithoutResult(code, stderrTail) {
            #expect(code == 3)
            #expect(stderrTail.contains("something went wrong"))
        }
        #expect(seen == [.initialized(sessionId: "s1", model: "m"),
                         .initInfo(InitInfo(sessionId: "s1", model: "m", tools: [], agents: []))])
    }

    @Test func timeoutKillsProcess() async throws {
        let (script, dir) = try fakeClaude("""
            echo $$ > pid.txt
            cat > /dev/null
            exec sleep 30
            """)
        // The wall clock fires only once the script has started (its pid is written): no race against a real timer.
        let pidFile = dir.appending(path: "pid.txt")
        var runner = ClaudeProcessRunner(claudePath: script.path, maxTurnDuration: .seconds(900))
        runner.wallClockSleep = { _ in
            while !(((try? String(contentsOf: pidFile, encoding: .utf8)) ?? "").contains("\n")) {
                try await Task.sleep(for: .milliseconds(10))
            }
        }
        await #expect(throws: TurnError.timedOut) { _ = try await collect(runner.run(request(in: dir))) }
        let pid = try #require(Int32(try String(contentsOf: dir.appending(path: "pid.txt"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) == -1)
    }

    @Test func waitForChildrenReturnsOnlyAfterCancelledChildIsReaped() async throws {
        let (script, dir) = try fakeClaude("""
            echo $$ > pid.txt
            cat > /dev/null
            exec sleep 30
            """)
        let runner = ClaudeProcessRunner(claudePath: script.path)
        let req = request(in: dir)
        let turn = Task { _ = try? await collect(runner.run(req)) }
        let pidFile = dir.appending(path: "pid.txt")
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: pidFile.path) {
            try await Task.sleep(for: .milliseconds(25))
        }
        try await Task.sleep(for: .milliseconds(100))
        turn.cancel()
        await turn.value
        await runner.waitForChildren()
        let pid = try #require(Int32(try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) == -1)
    }

    @Test func waitForChildrenFromCancelledTaskStillWaitsWithoutSpinning() async throws {
        let (script, dir) = try fakeClaude("""
            echo $$ > pid.txt
            cat > /dev/null
            trap '' TERM
            sleep 2
            """)
        let runner = ClaudeProcessRunner(claudePath: script.path)
        let req = request(in: dir)
        let turn = Task { _ = try? await collect(runner.run(req)) }
        let pidFile = dir.appending(path: "pid.txt")
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: pidFile.path) {
            try await Task.sleep(for: .milliseconds(25))
        }
        turn.cancel()
        await turn.value
        let start = ContinuousClock.now
        let polls = PollCounter()
        let waiter = Task { await runner.waitForChildren(pollInterval: .milliseconds(20)) { polls.increment() } }
        waiter.cancel()
        await waiter.value
        let elapsed = ContinuousClock.now - start
        // The child ignores SIGTERM until its sleep ends or the 5 s kill grace: an early return would leave it alive, which
        // the check of its pid below observes (no assertion on how long the wait took).
        // A busy-spinning waiter would poll thousands of times; a sleeping one about once per 20 ms.
        // Structural, not CPU time: clock() measures the whole test process, which runs suites in parallel.
        #expect(polls.value <= Int(elapsed / .milliseconds(20)) * 2 + 5)
        let pid = try #require(Int32(try String(contentsOf: pidFile, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(kill(pid, 0) == -1)
    }
}

private final class PollCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }

    @Test func spawnedEnvironmentCarriesOnlyEngineClaudeVars() async throws {
        let (script, dir) = try fakeClaude("""
            cat > /dev/null
            env > env.txt
            echo '{"type":"system","subtype":"init","session_id":"s1","model":"m"}'
            echo '{"type":"result","subtype":"success","is_error":false,"result":"ok","session_id":"s1"}'
            """)
        let runner = ClaudeProcessRunner(claudePath: script.path, baseEnvironment: [
            "PATH": "/usr/bin:/bin", "HOME": "/tmp", "CLAUDE_CODE_EFFORT_LEVEL": "max", "MAX_THINKING_TOKENS": "63999",
            "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
        ])
        var req = request(in: dir)
        req.environment = ["BRAHMA_AGENT_ID": "a1", "CLAUDE_CODE_EFFORT_LEVEL": "low", "CLAUDE_CODE_DISABLE_FAST_MODE": "1"]
        _ = try await collect(runner.run(req))
        let env = try String(contentsOf: dir.appending(path: "env.txt"), encoding: .utf8)
        #expect(env.contains("CLAUDE_CODE_DISABLE_FAST_MODE=1"), "an engine control on the allowlist passes")
        // The effort travels as --effort; CLAUDE_CODE_EFFORT_LEVEL would override it and is never passed, engine-set or not (W1).
        #expect(!env.contains("CLAUDE_CODE_EFFORT_LEVEL"))
        #expect(!env.contains("MAX_THINKING_TOKENS")); #expect(!env.contains("EXPERIMENTAL_AGENT_TEAMS"))
    }

    @Test func turnEnvironmentCarriesAgentIdWithoutDev() async throws {
        let (script, dir) = try fakeClaude("""
            cat > /dev/null
            env > env.txt
            echo '{"type":"system","subtype":"init","session_id":"s1","model":"m"}'
            echo '{"type":"result","subtype":"success","is_error":false,"result":"ok","session_id":"s1"}'
            """)
        let runner = ClaudeProcessRunner(claudePath: script.path, baseEnvironment: [
            "PATH": "/usr/bin:/bin", "HOME": "/tmp", "FAKE_SECRET_TOKEN": "s3cret", "BRAHMA_DEV": "1", "RANDOM_VAR": "x",
        ])
        var req = request(in: dir)
        req.environment = ["BRAHMA_AGENT_ID": "a1"]
        _ = try await collect(runner.run(req))
        let env = try String(contentsOf: dir.appending(path: "env.txt"), encoding: .utf8)
        #expect(env.contains("BRAHMA_AGENT_ID=a1"))
        #expect(!env.contains("FAKE_SECRET_TOKEN")); #expect(!env.contains("BRAHMA_DEV")); #expect(!env.contains("RANDOM_VAR"))
        #expect(env.contains("PATH=/usr/bin:/bin"))
    }
}
