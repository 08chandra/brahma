import Foundation
import Testing
import GRDB
@testable import BrahmaCore

/// A sandboxed company whose engineer holds a confirmed tier-L item with an approved Ultra run, and an engine for which every
/// hard gate holds: max20x (so a day allows several runs) confirmed by the CLI's `max`, calibrated, on pace, the Ultra probe
/// gates recorded for the fake CLI build (V-9 as the owner's future probe would), a fake `claude` answering `get_usage`.
private struct UltraWorld {
    let g: GatedWorld
    var world: World { g.world }
    var store: Store { g.store }
    var company: Company { g.company }
    var eng: Agent { g.eng }
    let item: WorkItem
    static let fakePid: Int32 = 999_999

    init(tag: String, fiveHour: Double = 0.30, hookVerified: Bool = true) throws {
        g = try GatedWorld(mode: .max, tag: tag)
        let now = g.world.clock.now
        try g.store.setPlanTier(.max20x)
        try g.store.saveProbe(DoctorReport(cliVersion: nil, items: [], checkedAt: now, reportedSubscription: "max"))
        try g.store.saveRateLimit(RateLimitInfo(status: "allowed", resetsAt: nil, rateLimitType: nil, isUsingOverage: false,
                                                fiveHourUtilization: fiveHour, sevenDayUtilization: 0.20, observedAt: now,
                                                fiveHourResetsAt: now.addingTimeInterval(3 * 3600),
                                                sevenDayResetsAt: now.addingTimeInterval(3 * 86_400)))
        try g.store.writer.write { db in
            var cal = UsageCalibration()
            cal.week.samples = Array(repeating: 0.001, count: 10)
            cal.fiveHour.samples = Array(repeating: 0.01, count: 10)
            try Store.saveCalibration(db, cal)
        }
        try g.record(UltraGate.requiredGates, .ultra)
        if hookVerified { try g.record(["V-1"], .sandboxedTask) }   // no pre-taint: PostToolUse is verified for this build
        let usage = #"{"type":"control_response","response":{"subtype":"success","request_id":"cu","response":{"subscription_type":"max","rate_limits":{"five_hour":{"utilization":\#(Int(fiveHour * 100)),"resets_at":"2030-01-01T00:00:00Z"},"seven_day":{"utilization":20},"extra_usage":{"is_enabled":false}}}}}"#
        g.world.fake.controlResponder = { _, _ in ControlTranscript(exitStatus: nil, lines: [usage]) }
        var item = try g.store.createWorkItem(companyId: g.company.id, by: .owner, draft: WorkItemDraft(
            type: .task, title: "Broad audit", acceptanceCriteria: "ok", checkSpec: CheckSpec(command: "true", paths: ["src/a"]),
            status: .ready), now: now)
        try g.store.writer.write { db in
            try db.execute(sql: "UPDATE workItem SET tier = 'l', specConfirmedBy = 'owner:owner' WHERE id = ?", arguments: [item.id])
        }
        _ = try CompanyTools(store: g.store, companyId: g.company.id, agentId: g.eng.id).call(name: "claim_lease", arguments: ["key": .string(item.key)])
        item = try #require(try g.store.workItem(id: item.id))
        self.item = item
    }

    /// The owner's Ultra intensity on the item: one approved full Ultra run.
    func approveRun() throws {
        _ = try store.updateWorkItem(id: item.id, by: .owner, patch: WorkItemPatch(intensity: .ultra), now: world.clock.now)
    }

    /// Queues the agent's next turn, its events built from the request the runner is given.
    func scriptUltra(error: (any Error)? = nil, pauseAfter: Int? = nil, pause: Gate? = nil,
                     _ events: @escaping @Sendable (TurnRequest) -> [StreamEvent]) {
        world.fake.script(eng.name, FakeTurnRunner.Script(error: error, pauseAfter: pauseAfter, pauseGate: pause, make: events))
    }

    func scriptUltraSuccess(cost: Double) {
        scriptUltra { r in Self.start(r) + [Self.result(r, cost: cost)] }
    }

    static func start(_ r: TurnRequest, tools: [String] = BrahmaToolsForUltra.tools) -> [StreamEvent] {
        [.spawned(pid: fakePid), .initialized(sessionId: r.agent.sessionId, model: "claude-sonnet-5-5"),
         .initInfo(InitInfo(sessionId: r.agent.sessionId, model: "claude-sonnet-5-5", tools: tools, agents: []))]
    }

    static func result(_ r: TurnRequest, cost: Double, models: [String] = ["claude-sonnet-5-5"]) -> StreamEvent {
        .result(TurnResult(isError: false, subtype: "success", text: "done", costUSD: cost, apiErrorStatus: nil,
                           sessionId: r.agent.sessionId, modelsUsed: models))
    }

    func lastTurn() throws -> Turn { try #require(try world.turns(eng).last) }
    func reservation(_ t: Turn) throws -> UltraReservation { try #require(try store.ultraReservation(turnId: t.id)) }

    /// Runs the engine until the agent's next turn reached the runner (the plain and the Ultra shape's canary keys pass first).
    func runToUltraTurn() async throws {
        try await g.runUntilTurn(rounds: 10)
    }
}

/// The init tools an Ultra session offers.
enum BrahmaToolsForUltra {
    static let tools = BuiltinTools.ultra + ["mcp__company__post"]
}

@Suite(.scratch, .serialized) struct UltraAccountingTests {
    @Test func reservationReleasedToActual() async throws {
        let u = try UltraWorld(tag: "reservationReleasedToActual")
        try u.approveRun()
        u.scriptUltraSuccess(cost: 2.5)
        try await u.runToUltraTurn()
        let r = try #require(u.g.requests().last)
        #expect(r.mode?.mode == .ultra); #expect(r.mode?.workflow?.variant == .full); #expect(r.mode?.workflow?.approver == .owner)
        #expect(r.prompt.contains("This turn is opted into multi-agent orchestration (approved by: owner)"))
        let compiled = TurnProfileCompiler.profile(for: r)
        #expect(compiled.settings.enableWorkflows == true); #expect(compiled.tools == BuiltinTools.ultraBeforeF7, "no F7 yet")
        #expect(u.world.fake.controlRequests >= 1, "a fresh get_usage was taken before admission")
        let t = try u.lastTurn()
        #expect(t.mode == "ultra"); #expect(t.rung == 5); #expect(t.outcome == .succeeded)
        #expect(t.costLE == 2.5)
        let res = try u.reservation(t)
        #expect(res.releasedAt != nil); #expect(res.actualLE == 2.5); #expect(res.capLE == 15); #expect(res.approvedBy == "owner")
        let item = try #require(try u.store.workItem(id: u.item.id))
        #expect(item.budgetBoostLE == 15, "the approval added its cap to the item once"); #expect(item.intensity == .auto)
        #expect(u.store.openReservationLE() == 0)
        #expect(await u.world.orchestrator.companyRunning(u.company.id) == 0, "its extra slots are free again")
        // The next turn is no Ultra: the one run was used.
        u.world.fake.script(u.eng.name, FakeTurnRunner.Script())
        try u.world.dm(u.company, u.eng, "next")
        try await u.world.cycle()
        #expect(try u.lastTurn().mode != "ultra")
    }

    @Test func interruptedUltraChargesFullCap() async throws {
        let u = try UltraWorld(tag: "interruptedUltraChargesFullCap")
        try u.approveRun()
        u.scriptUltra(error: TurnError.interrupted(pendingTasks: 1)) { r in UltraWorld.start(r) + [UltraWorld.result(r, cost: 1.0)] }
        try await u.runToUltraTurn()
        let t = try u.lastTurn()
        #expect(t.mode == "ultra"); #expect(t.outcome == .interrupted)
        #expect(t.costLE == 15, "killed with work pending: charged max(its cost, the cap)")
        #expect(try u.reservation(t).actualLE == 15)
        #expect(UltraAccounting.charge(cost: 20, cap: 15, killed: true) == 20)
        #expect(UltraAccounting.charge(cost: 3, cap: 15, killed: false) == 3)
        // SIGTERM with no result is charged the cap too.
        let v = try UltraWorld(tag: "interruptedUltraChargesFullCap-143")
        try v.approveRun()
        v.scriptUltra(error: TurnError.interrupted(pendingTasks: 0)) { r in UltraWorld.start(r) }
        try await v.runToUltraTurn()
        #expect(try v.lastTurn().costLE == 15); #expect(try v.reservation(try v.lastTurn()).actualLE == 15)
    }

    @Test func emergencyStopKillsUltraGroupAndCharges() async throws {
        let u = try UltraWorld(tag: "emergencyStopKillsUltraGroupAndCharges")
        // A first run makes both canary keys pass; the second Ultra turn is the one stopped.
        try u.approveRun()
        u.scriptUltraSuccess(cost: 1)
        try await u.runToUltraTurn()
        #expect(try u.lastTurn().mode == "ultra")
        try u.approveRun()
        let pause = Gate()
        let arrived = Gate()
        u.world.fake.onRun = { _ in arrived.open() }
        u.scriptUltra(pauseAfter: 3, pause: pause) { r in UltraWorld.start(r) + [UltraWorld.result(r, cost: 2)] }
        try u.world.dm(u.company, u.eng, "go")
        await u.world.orchestrator.tick()
        await arrived.wait()
        await u.world.stopPoll.waiting()
        #expect(u.store.openReservationLE() == 15, "reserved while it runs")
        try u.store.emergencyStop(note: nil, by: "owner", now: u.world.clock.now)
        u.world.stopPoll.step()
        try await u.world.orchestrator.waitUntilIdle(timeout: .seconds(30))
        pause.open()
        let t = try u.lastTurn()
        #expect(t.mode == "ultra"); #expect(t.outcome == .interrupted)
        #expect(t.costLE == 15, "stopped by the owner: charged its cap")
        // Its leader (the group the stop signals, workflow agents included: `EmergencyStop.recordedGroups`) was recorded.
        #expect(t.pid == UltraWorld.fakePid)
        #expect(try u.reservation(t).actualLE == 15); #expect(u.store.openReservationLE() == 0)
        try u.store.resumeAfterStop(now: u.world.clock.now)
    }

    @Test func agentCountKill() async throws {
        let u = try UltraWorld(tag: "agentCountKill")
        try u.approveRun()
        let agents = (1...11).map { WorkflowAgentInfo(agentId: "wa\($0)") }
        u.scriptUltra { r in
            UltraWorld.start(r) + [.taskStarted(taskId: "w1", taskType: "local_workflow", spawnDepth: 1),
                                   .taskProgress(taskId: "w1", totalTokens: 100, toolUses: 3, agents: Array(agents.prefix(10))),
                                   .taskProgress(taskId: "w1", totalTokens: 200, toolUses: 6, agents: agents),
                                   UltraWorld.result(r, cost: 3)]
        }
        try await u.runToUltraTurn()
        let t = try u.lastTurn()
        #expect(t.mode == "ultra"); #expect(t.outcome == .interrupted)
        #expect(t.stopReason == UltraAccounting.agentCapStop)
        #expect(t.costLE == 15); #expect(try u.reservation(t).actualLE == 15)
        #expect(UltraVariant.full.agentKill == 10); #expect(UltraVariant.small.agentKill == 5)
    }

    @Test func unexpectedModelInModelUsageAlerts() async throws {
        let u = try UltraWorld(tag: "unexpectedModelInModelUsageAlerts")
        try u.approveRun()
        u.scriptUltra { r in UltraWorld.start(r) + [UltraWorld.result(r, cost: 2, models: ["claude-sonnet-5-5", "claude-haiku-5-5", "claude-opus-4-8"])] }
        try await u.runToUltraTurn()
        #expect(try u.lastTurn().mode == "ultra")
        let alerts = try u.store.asks(companyId: u.company.id).filter { $0.kind == .engineAlert && $0.summary.contains("unexpected model") }
        #expect(alerts.count == 1); #expect(alerts.first?.summary.contains("claude-haiku-5-5") == true)
        #expect(alerts.first?.summary.contains("claude-opus-4-8") == false, "a safety fallback is recorded only")
        guard case .owner(let reason, _)? = try u.store.agent(id: u.eng.id)?.blocker else { Issue.record("not held"); return }
        #expect(reason.hasPrefix(Store.doctorHoldPrefix), "its next turn waits for the doctor")
        // The forced Sonnet worker is expected.
        #expect(TurnAudit.findings(result: TurnResult(isError: false, subtype: "success", text: nil, costUSD: 1, apiErrorStatus: nil,
                                                      sessionId: "s", modelsUsed: ["claude-opus-5-5", "claude-sonnet-5-5"]),
                                   initModel: "claude-opus-5-5", main: "opus", fallback: "opus",
                                   expectations: TurnProfileCompiler.expectations(for: ultraDecision(sessionModel: "opus"), agents: nil)).isClean)
    }

    @Test func ultraCountsInWeeklyPace() async throws {
        // An open reservation is in Ultra's own 7-day projection and in every other turn's 5-hour check.
        var g = passingUltraGates(); g.allowedWeek = 0.216
        #expect(UltraGate.admit(.full, g) == .success(.full))
        g.openReservationLE = 4
        #expect(UltraGate.failures(.full, g).first?.gate == 5)
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let info = RateLimitInfo(status: "allowed", resetsAt: nil, rateLimitType: nil, isUsingOverage: false, fiveHourUtilization: 0.80,
                                 sevenDayUtilization: 0.1, observedAt: now, fiveHourResetsAt: now.addingTimeInterval(3600))
        #expect(UsageGate.evaluateFiveHour(info, mode: .max, now: now) == .open)
        #expect(UsageGate.evaluateFiveHour(info, mode: .max, now: now, openReservationLE: 15, pctPerDollar5h: 0.012) != .open)
        // After the run its $LE is ordinary $LE: in the week's spend by mode and the calibration's spend.
        let u = try UltraWorld(tag: "ultraCountsInWeeklyPace")
        try u.approveRun()
        let spentBefore = try u.store.usageCalibration().week.cost
        u.scriptUltraSuccess(cost: 3)
        try await u.runToUltraTurn()
        #expect(try u.lastTurn().mode == "ultra")
        #expect(try u.store.costByMode(companyId: u.company.id, since: u.world.clock.now.addingTimeInterval(-86_400))["ultra"] == 3)
        #expect(try u.store.usageCalibration().week.cost - spentBefore >= 3 - 1e-9)
    }

    /// Fix round 1, I2: a turn that reads what a tainted session wrote is tainted at launch, so gate 10 refuses Ultra at
    /// admission; nothing is reserved and the approval waits.
    @Test func relayedTaintRefusesUltraAtAdmission() async throws {
        let u = try UltraWorld(tag: "relayedTaintRefusesUltraAtAdmission")
        try u.approveRun()
        let mgr = try u.store.hire(companyId: u.company.id, name: "mgr", role: "manager", model: "sonnet")
        try u.store.markTainted(agentId: mgr.id, source: "WebFetch(example.com)", now: u.world.clock.now)
        _ = try u.world.router.sendDM(companyId: u.company.id, from: .agent(mgr.id), to: u.eng.name, text: "see this", now: u.world.clock.now)
        u.world.fake.script(u.eng.name, FakeTurnRunner.Script())
        try await u.runToUltraTurn()
        let t = try u.lastTurn()
        #expect(t.mode != "ultra"); #expect(t.modeReason?.contains("Ultra not admitted: the session read outside content") == true)
        #expect(try u.store.ultraReservations(companyId: u.company.id).isEmpty)
        #expect(try u.store.pendingUltraRun(itemId: u.item.id) != nil)
    }

    /// Fix round 1, I2: taint found right before launch (here the fan-out pre-taint: V-1 is recorded for the Ultra shape but the
    /// PostToolUse hook gate is not) releases the reservation uncharged and runs the computed rung.
    @Test func launchTaintReleasesTheReservationAndFallsBack() async throws {
        let u = try UltraWorld(tag: "launchTaintReleasesTheReservation", hookVerified: false)
        try u.approveRun()
        u.world.fake.script(u.eng.name, FakeTurnRunner.Script())
        try await u.runToUltraTurn()
        let t = try u.lastTurn()
        #expect(t.mode != "ultra"); #expect(t.modeReason?.contains("Ultra not admitted: the session read outside content") == true)
        #expect(try u.store.ultraReservations(companyId: u.company.id).isEmpty, "released uncharged")
        #expect(try u.store.workItem(id: u.item.id)?.budgetBoostLE == 0)
        #expect(try u.store.pendingUltraRun(itemId: u.item.id) != nil, "the approval is kept")
        #expect(await u.world.orchestrator.companyRunning(u.company.id) == 0)
        #expect(!(u.g.requests().last?.prompt.contains("multi-agent orchestration") ?? true), "no Ultra digest line")
    }

    @Test func refusedUltraRunsTheComputedRungAndKeepsTheApproval() async throws {
        // Five-hour use above 60% in the fresh reading: the turn runs Deep and records why; the approval waits.
        let u = try UltraWorld(tag: "refusedUltraRunsTheComputedRung", fiveHour: 0.65)
        try u.approveRun()
        u.world.fake.script(u.eng.name, FakeTurnRunner.Script())
        try await u.runToUltraTurn()
        let t = try u.lastTurn()
        #expect(t.mode != "ultra"); #expect(t.modeReason?.contains("Ultra not admitted: 5-hour use 65% is above 60%") == true)
        #expect(try u.store.pendingUltraRun(itemId: u.item.id) != nil)
        #expect(try u.store.ultraReservations(companyId: u.company.id).isEmpty)
        #expect(try u.store.workItem(id: u.item.id)?.budgetBoostLE == 0)
    }
}
