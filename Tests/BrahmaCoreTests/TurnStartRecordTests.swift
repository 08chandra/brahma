import Testing
import Foundation
@testable import BrahmaCore

/// No turn runs without an exact-start record (Task 9c fix rounds 3 and 4): a start time that cannot be read right after the
/// spawn kills the child at once (the runner's own unreaped child), the turn ends `startNotRecorded`, and the engine books it as
/// its own fault and as not launched: nothing charged to the agent or the item, its one-use grants given back, an Ultra run's
/// approval kept and no cap charged. It is retried after the fixed 15 s infrastructure delay (`EngineHealth.infraCooldown`),
/// not on the next tick, and the third such turn in a row raises an engine alert. A leader record that cannot be written
/// (`leaderNotRecorded`) is booked the same way.
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

    /// What the real runner yields before it throws: `.spawned` (so the engine has seen a launch) and the owner note.
    static func unrecordedScript(_ error: TurnError = .startNotRecorded) -> FakeTurnRunner.Script {
        FakeTurnRunner.Script(events: [.spawned(pid: 999_999), .sandboxNote("the start time of the turn's process could not be read")],
                              error: error)
    }

    /// The engine's side: the turn is `interrupted` (not charged: no consecutive failure, no backoff, the agent back to ready),
    /// the owner sees an engine-written error event, and the scheduler retries only after the infrastructure delay.
    @Test func engineBooksItAsInfrastructureNotCharged() async throws {
        let w = try World()
        let company = try w.company("Acme")
        let agent = try w.hire(company, "eng")
        w.fake.script("eng", Self.unrecordedScript())
        try w.dm(company, agent)
        try await w.cycle()
        let turn = try #require(try w.turns(agent).last)
        #expect(turn.outcome == .interrupted)
        #expect(turn.costLE == nil || turn.costLE == 0)
        let after = try w.agent(agent)
        #expect(after.state == .ready && after.consecutiveFailures == 0)
        let events = try w.store.events(afterId: 0, companyId: company.id)
        #expect(events.contains { $0.kind == .error && $0.text.contains("start time of its process could not be read") })
        #expect(after.blocker == nil, "no backoff")
        // No spin: the next tick does not retry it ...
        try await w.cycle()
        #expect(w.fake.requests.count == 1, "not retried before the infrastructure delay")
        // ... the tick after the delay does, with the default (succeeding) script this time.
        w.clock.advance(EngineHealth.infraCooldown + 1)
        try await w.cycle()
        #expect(w.fake.requests.count == 2, "retried after the delay")
        #expect(try w.turns(agent).last?.outcome == .succeeded)
    }

    /// A leader record that cannot be written is booked the same way: not a failure of the agent, the delay, no charge.
    @Test func leaderNotRecordedIsBookedTheSameWay() async throws {
        let w = try World()
        let company = try w.company("Acme")
        let agent = try w.hire(company, "eng")
        w.fake.script("eng", Self.unrecordedScript(.leaderNotRecorded(reason: "disk full")))
        try w.dm(company, agent)
        try await w.cycle()
        #expect(try w.turns(agent).last?.outcome == .interrupted)
        let after = try w.agent(agent)
        #expect(after.state == .ready && after.consecutiveFailures == 0 && after.blocker == nil)
        #expect(try w.store.events(afterId: 0, companyId: company.id).contains {
            $0.kind == .error && $0.text.contains("could not write the record of its process")
        })
        try await w.cycle()
        #expect(w.fake.requests.count == 1, "not retried before the infrastructure delay")
    }

    /// Three in a row raise one engine alert for the owner; a turn that runs resets the count.
    @Test func thirdUnrecordedTurnInARowAlertsTheOwner() async throws {
        let w = try World()
        let company = try w.company("Acme")
        let agent = try w.hire(company, "eng")
        func alerts() throws -> [Ask] {
            try w.store.asks(companyId: company.id).filter {
                $0.kind == .engineAlert && $0.subjectId == EngineAlerts.askSubject(reason: Orchestrator.unrecordedTurnReason)
            }
        }
        // Two, then a turn that runs: no alert, and the count starts again.
        w.fake.script("eng", Self.unrecordedScript(), Self.unrecordedScript(), FakeTurnRunner.Script(),
                      Self.unrecordedScript(), Self.unrecordedScript(), Self.unrecordedScript())
        try w.dm(company, agent)
        for n in 1...3 {
            try await w.cycle()
            #expect(w.fake.requests.count == n)
            #expect(try alerts().isEmpty, "no alert after \(n)")
            w.clock.advance(EngineHealth.infraCooldown + 1)
        }
        #expect(try w.turns(agent).last?.outcome == .succeeded)
        try w.dm(company, agent)
        for n in 1...3 {
            try await w.cycle()
            #expect(w.fake.requests.count == 3 + n)
            #expect(try w.turns(agent).last?.outcome == .interrupted)
            #expect(try alerts().count == (n == 3 ? 1 : 0), "after \(n) in a row")
            w.clock.advance(EngineHealth.infraCooldown + 1)
        }
        let alert = try #require(try alerts().first)
        #expect(alert.status == .pendingOwner)
        let dms = try #require(try w.store.channel(companyId: company.id, name: "dm:owner:system"))
        #expect(try w.store.messages(channelId: dms.id, limit: 50).contains { $0.text.contains("@eng's last 3 turns were stopped before they ran") })
    }

    /// A one-use grant the turn spent at launch is given back: the turn never ran, so it is not used up.
    @Test func unrecordedTurnGivesItsOneUseGrantBack() async throws {
        let g = try GrantWorld()
        let grant = try g.grant("network_domain", "once.example.com", scope: .once, duration: .always)
        g.world.fake.script(g.eng.name, Self.unrecordedScript())
        let first = try await g.nextScope()
        #expect(first.network.allowedDomains.contains("once.example.com"), "the turn launched with the grant")
        #expect(try g.world.turns(g.eng).last?.outcome == .interrupted)
        let kept = try #require(try g.store.grants(companyId: g.company.id, includeInactive: true).first { $0.id == grant.id })
        #expect(kept.usesLeft == 1, "given back, not spent")
        // The retry, after the delay, still carries it, and only then is it used.
        g.world.clock.advance(EngineHealth.infraCooldown + 1)
        try await g.world.cycle()
        let retry = try #require(g.world.fake.requests.last { $0.agent.id == g.eng.id })
        #expect(g.world.fake.requests.filter { $0.agent.id == g.eng.id }.count == 2)
        #expect(retry.sandbox?.network.allowedDomains.contains("once.example.com") == true)
        #expect(try g.store.grants(companyId: g.company.id, includeInactive: true).first { $0.id == grant.id }?.usesLeft == 0)
    }

    /// An Ultra turn that was never recorded is charged nothing: no cap, no reservation left, the item's budget as it was, and
    /// the owner's approval still waiting for the next turn.
    @Test func unrecordedUltraTurnIsNotChargedAndKeepsItsApproval() async throws {
        let u = try UltraWorld(tag: "unrecordedUltraTurnIsNotCharged")
        try u.approveRun()
        u.scriptUltra(error: TurnError.startNotRecorded) { _ in
            [.spawned(pid: UltraWorld.fakePid), .sandboxNote("the start time of the turn's process could not be read")]
        }
        try await u.runToUltraTurn()
        let r = try #require(u.g.requests().last)
        #expect(r.mode?.mode == .ultra, "the turn launched as Ultra")
        let t = try u.lastTurn()
        #expect(t.mode == "ultra"); #expect(t.outcome == .interrupted)
        #expect(t.costLE == nil || t.costLE == 0, "no cap charged")
        #expect(try u.store.ultraReservation(turnId: t.id) == nil, "the reservation was cancelled, not released at a cost")
        #expect(u.store.openReservationLE() == 0)
        let item = try #require(try u.store.workItem(id: u.item.id))
        #expect(item.budgetBoostLE == 0, "the item's budget as it was")
        #expect(item.intensity == .ultra)
        #expect(try u.store.pendingUltraRun(itemId: u.item.id) != nil, "the approval is kept")
        let usage = try u.store.itemUsage(itemId: u.item.id)
        #expect(usage.turns == 0); #expect(usage.costLE == 0)
        #expect(await u.world.orchestrator.companyRunning(u.company.id) == 0, "its extra slots are free again")
        // The retry, after the delay, runs the approved Ultra run.
        u.scriptUltraSuccess(cost: 2.5)
        u.world.clock.advance(EngineHealth.infraCooldown + 1)
        try await u.runToUltraTurn()
        let next = try u.lastTurn()
        #expect(next.mode == "ultra"); #expect(next.outcome == .succeeded); #expect(next.costLE == 2.5)
        #expect(try u.reservation(next).actualLE == 2.5)
    }
}
