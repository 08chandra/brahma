import Testing
import Foundation
@testable import BrahmaCore

/// No turn runs without an exact-start record (Task 9c fix round 3): a start time that cannot be read right after the spawn
/// kills the child at once (the runner's own unreaped child), the turn ends `startNotRecorded`, and the engine books it as its
/// own fault: not charged, retried after the infrastructure delay.
@Suite(.scratch, .serialized) struct TurnStartRecordTests {
    private func request(in dir: URL, records: URL) -> TurnRequest {
        let agent = Agent(id: "a1-\(UUID().uuidString)", companyId: "c1", name: "ceo", role: "ceo", model: "sonnet", sessionId: "s1",
                          sessionStarted: false, state: .running, blocker: nil, requestedBlocker: nil, paused: false,
                          readySince: nil, createdAt: Date(timeIntervalSince1970: 0))
        let company = Company(id: "c1", name: "Acme", slug: "acme", goal: "g", workspacePath: dir.path, status: .running,
                              usageMode: .low, priorityWeight: 1, createdAt: Date(timeIntervalSince1970: 0))
        var r = TurnRequest(agent: agent, company: company, prompt: "P", appendSystemPrompt: "ROLE",
                            mcpConfigPath: "/tmp/x.mcp.json", workingDirectory: dir.path, profile: .workspace)
        r.turnRecordDirectory = records
        return r
    }

    private final class Probed: @unchecked Sendable {
        private let lock = NSLock()
        private var _pids: [pid_t] = []
        func add(_ pid: pid_t) { lock.withLock { _pids.append(pid) } }
        var pids: [pid_t] { lock.withLock { _pids } }
    }

    /// Through the seam: the read fails, the child is dead before it could print, the stream ends `startNotRecorded`, and the
    /// run directory keeps no record of the agent (the placeholder went with the reaped child).
    @Test func unreadableStartKillsTheChildAndRecordsNothing() async throws {
        let script = try FakeTools.script("fake-claude", """
            cat > /dev/null
            echo '{"type":"system","subtype":"init","session_id":"s1","model":"m","tools":[],"agents":[]}'
            exec sleep 30
            """)
        let dir = try tempDir()
        let records = dir.appending(path: "turns", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: records, withIntermediateDirectories: true)
        let probed = Probed()
        var runner = ClaudeProcessRunner(claudePath: script.path, maxTurnDuration: .seconds(60))
        runner.startTimeProbe = { pid in probed.add(pid); return nil }
        let r = request(in: dir, records: records)
        var events: [StreamEvent] = []
        var thrown: (any Error)?
        do { for try await e in runner.run(r) { events.append(e) } } catch { thrown = error }
        #expect(thrown as? TurnError == .startNotRecorded)
        guard case .spawned(let pid)? = events.first else { Issue.record("no spawned event: \(events)"); return }
        #expect(probed.pids == [pid], "the seam saw the one child")
        #expect(kill(pid, 0) != 0, "the child is gone (reaped by the runner)")
        #expect(!events.contains { if case .initialized = $0 { return true } else { return false } }, "nothing of its output counted")
        #expect(events.contains { if case .sandboxNote(let t) = $0 { return t.contains("could not be read") } else { return false } })
        #expect(try TurnRecords.load(agentId: r.agent.id, in: records).isEmpty, "no record names a process whose start was never proven")
        await runner.waitForChildren()
    }

    /// The engine's side: the turn is `interrupted` (not charged: no consecutive failure, no backoff, the agent back to ready),
    /// the owner sees an engine-written error event, and the scheduler retries on the next tick.
    @Test func engineBooksItAsInfrastructureNotCharged() async throws {
        let w = try World()
        let company = try w.company("Acme")
        let agent = try w.hire(company, "eng")
        w.fake.script("eng", FakeTurnRunner.Script(events: [], error: TurnError.startNotRecorded))
        try w.dm(company, agent)
        try await w.cycle()
        let turn = try #require(try w.turns(agent).last)
        #expect(turn.outcome == .interrupted)
        let after = try w.agent(agent)
        #expect(after.state == .ready && after.consecutiveFailures == 0)
        let events = try w.store.events(afterId: 0, companyId: company.id)
        #expect(events.contains { $0.kind == .error && $0.text.contains("start time of its process could not be read") })
        #expect(after.blocker == nil, "no backoff")
        // Retried on the next tick, with the default (succeeding) script this time.
        try await w.cycle()
        #expect(w.fake.requests.count == 2, "retried")
        #expect(try w.turns(agent).last?.outcome == .succeeded)
    }
}
