import Testing
import Foundation
@testable import AgentCompanyCore

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

@Suite struct TurnRunnerTests {
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
        #expect(events.count == 4)
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
        #expect(seen == [.initialized(sessionId: "s1", model: "m")])
    }

    @Test func timeoutKillsProcess() async throws {
        let (script, dir) = try fakeClaude("""
            echo $$ > pid.txt
            cat > /dev/null
            exec sleep 30
            """)
        // Long enough for the script to start under a loaded parallel test run.
        let runner = ClaudeProcessRunner(claudePath: script.path, maxTurnDuration: .seconds(1))
        let start = ContinuousClock.now
        await #expect(throws: TurnError.timedOut) { _ = try await collect(runner.run(request(in: dir))) }
        #expect(ContinuousClock.now - start < .seconds(5))
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
}
