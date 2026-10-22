import Foundation
import Testing
import GRDB
@testable import BrahmaCore

/// Work modes end to end through the orchestrator (Task 14c): the decision on the request and the turn, the no-launch rule,
/// escalation, the review spend cap and the floor reset.
@Suite struct WorkModeTests {
    private struct M {
        let w: World
        let c: Company
        let mgr: Agent
        let eng: Agent
        var store: Store { w.store }

        init(model: String = "auto", mode: UsageMode = .balanced) throws {
            w = try World()
            c = try w.company("Acme", mode: mode)
            mgr = try w.hire(c, "mgr", role: "manager")
            eng = try w.store.hire(companyId: c.id, name: "eng", role: "engineer", model: model, managerId: mgr.id)
        }

        @discardableResult
        func leased(tier: EffortTier = .s, priority: Int = 2, paths: [String] = ["src/a"]) throws -> WorkItem {
            let item = try store.createWorkItem(companyId: c.id, by: .owner, draft: WorkItemDraft(
                type: .task, title: "Do it", checkSpec: CheckSpec(command: "true", paths: paths), priority: priority, tier: tier,
                status: .ready), now: w.clock.now)
            _ = try store.claimLease(itemId: item.id, agentId: eng.id, now: w.clock.now)
            return try #require(try store.workItem(id: item.id))
        }

        func turn(_ script: FakeTurnRunner.Script = .init()) async throws {
            w.fake.script(eng.name, script)
            try w.dm(c, eng)
            w.clock.advance(1)
            try await w.cycle()
        }

        func lastTurn() throws -> Turn { try #require(try w.turns(eng).last) }
        func item(_ i: WorkItem) throws -> WorkItem { try #require(try store.workItem(id: i.id)) }

        /// A failed submission: two failing runs (the run and its re-run) of `commit`.
        func failedSubmission(_ item: WorkItem, commit: String, status: VerificationStatus = .failed) throws {
            try store.writer.write { db in
                for attempt in 1...2 {
                    try VerificationRun(id: UUID().uuidString, companyId: item.companyId, itemId: item.id, checkRevision: item.checkRevision,
                                        scriptHash: "h", commit: commit, command: "true", workingDirectory: "/tmp", timeoutSeconds: 60,
                                        purpose: .submit, attempt: attempt, status: status, createdAt: w.clock.now).insert(db)
                }
            }
        }
    }

    private static func result(cost: Double = 0.05) -> FakeTurnRunner.Script {
        .init(events: [.initialized(sessionId: "s-eng", model: "claude-sonnet-5-5"),
                       .result(TurnResult(isError: false, subtype: "success", text: "done", costUSD: cost, apiErrorStatus: nil,
                                          sessionId: "s-eng"))])
    }

    @Test func turnCarriesAndRecordsTheDecision() async throws {
        let m = try M()
        try m.leased(tier: .s)
        try await m.turn(Self.result())
        let r = try #require(m.w.fake.requests.last)
        let d = try #require(r.mode)
        #expect(d.mode == .standard); #expect(d.model == "sonnet"); #expect(r.agent.model == "sonnet")
        let args = ClaudeCommand.arguments(for: r)
        #expect(args.contains("--effort")); #expect(args[args.firstIndex(of: "--effort")! + 1] == "medium")
        #expect(args[args.firstIndex(of: "--max-turns")! + 1] == "40")
        #expect(r.hookCommand == "'/usr/local/bin/brahma' hook pre-tool")
        #expect(TurnProfileCompiler.profile(for: r).wallClock == .seconds(1200))
        #expect(r.expectations?.forbiddenTools.contains("Task") == true)
        let t = try m.lastTurn()
        #expect(t.mode == "standard"); #expect(t.rung == 1); #expect(t.effort == "medium")
        #expect(t.modeReason?.contains("tier S: R1") == true)
        // The per-turn MCP config carries the mode's quotas.
        let config = try Data(contentsOf: URL(fileURLWithPath: r.mcpConfigPath))
        let text = String(decoding: config, as: UTF8.self)
        #expect(text.contains("\"BRAHMA_MCP_QUOTA_POSTS\":\"10\""))
    }

    @Test func costByModeRecorded() async throws {
        let m = try M()
        try m.leased(tier: .s)
        try await m.turn(Self.result(cost: 0.25))
        let byMode = try m.store.costByMode(companyId: m.c.id, since: Date(timeIntervalSince1970: 0))
        #expect(abs((byMode["standard"] ?? 0) - 0.25) < 1e-9)
        // The rung's cost calibration learns from the turn.
        let cal = try m.store.modeCalibration()
        #expect(cal.samples["sonnet/medium"] == 1)
    }

    @Test func noticeTurnIsQuickHaiku() async throws {
        let m = try M()
        // A work notice and nothing to answer: a notice turn.
        let item = try m.store.createWorkItem(companyId: m.c.id, by: .owner, draft: WorkItemDraft(type: .task, title: "FYI"),
                                              now: m.w.clock.now)
        _ = try m.store.commentWorkItem(id: item.id, by: .agent(m.mgr.id), text: "@eng have a look", now: m.w.clock.now)
        m.w.clock.advance(1)
        try await m.w.cycle()
        let r = try #require(m.w.fake.requests.last)
        #expect(r.mode?.mode == .quick); #expect(r.agent.model == "haiku"); #expect(r.mode?.effort == .low)
    }

    @Test func belowQuickEstimateIsNotLaunchedAndBlocks() async throws {
        let m = try M()
        let item = try m.leased(tier: .s)
        // Spend all but $0.10 of the tier S $3 budget.
        try await m.store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO turn (id, agentId, companyId, startedAt, endedAt, outcome, kind, itemId, costLE, costUSD)
                VALUES ('old', ?, ?, ?, ?, 'succeeded', 'work', ?, 2.9, 2.9)
                """, arguments: [m.eng.id, m.c.id, m.w.clock.now, m.w.clock.now, item.id])
        }
        let before = m.w.fake.requests.count
        try await m.turn(Self.result())
        #expect(m.w.fake.requests.count == before, "no process is started")
        let blocked = try m.item(item)
        #expect(blocked.status == .blocked); #expect(blocked.stopReason == "budget")
        #expect(blocked.blockedReason?.hasPrefix("over budget") == true)
    }

    @Test func refusedPinIsNotLaunched() async throws {
        let m = try M(model: "fable")
        try m.leased(tier: .s)
        try await m.turn(Self.result())
        #expect(m.w.fake.requests.isEmpty)
        let t = try m.lastTurn()
        #expect(t.outcome == .failed); #expect(t.summary?.contains("not allowed in Brahma turns") == true)
    }

    @Test func twoCountedFailuresRaiseTheFloor() async throws {
        let m = try M()
        let item = try m.leased(tier: .s)
        try m.failedSubmission(item, commit: "1111111")
        try m.failedSubmission(item, commit: "1111111")   // an identical resubmit
        try await m.turn(Self.result())
        #expect(try m.item(item).rungFloor == 0, "one counted failure (the resubmit is the same commit)")
        try m.failedSubmission(item, commit: "2222222")
        try await m.turn(Self.result())
        let raised = try m.item(item)
        #expect(raised.rungFloor == 2)
        #expect(m.w.fake.requests.last?.mode?.effort == .high, "the fix turn already runs at the raised floor")
        let events = try m.store.itemEvents(itemId: item.id).filter { $0.kind == .modeEscalated }
        #expect(events.count == 1); #expect(events.first?.actorId == "system")
        // Once per claim.
        try m.failedSubmission(item, commit: "3333333")
        try await m.turn(Self.result())
        #expect(try m.item(item).rungFloor == 2)
    }

    @Test func flakyAndInconclusiveRunsDoNotRaiseTheFloor() async throws {
        let m = try M()
        let item = try m.leased(tier: .s)
        try m.failedSubmission(item, commit: "aaaaaaa", status: .inconclusive)
        try m.failedSubmission(item, commit: "bbbbbbb", status: .inconclusive)
        try await m.turn(Self.result())
        #expect(try m.item(item).rungFloor == 0)
    }

    @Test func doneResetsTheFloor() throws {
        let m = try M()
        let item = try m.leased(tier: .s)
        try m.store.writer.write { db in try db.execute(sql: "UPDATE workItem SET rungFloor = 3 WHERE id = ?", arguments: [item.id]) }
        try m.store.writer.write { db in _ = try m.store.engineSetStatus(db: db, itemId: item.id, to: .done, now: m.w.clock.now) }
        #expect(try m.item(item).rungFloor == 0)
    }

    @Test func reviewSpendCapDropsToStandard() throws {
        let m = try M()
        let item = try m.leased(tier: .l)
        try m.store.writer.write { db in try db.execute(sql: "UPDATE workItem SET specConfirmedBy = 'owner:owner' WHERE id = ?", arguments: [item.id]) }
        #expect(try !m.store.reviewSpendCapped(item: m.item(item)))
        // Tier L is $40: past $10 of review spend, reviews drop to Standard and the manager hears about it once.
        try m.store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO turn (id, agentId, companyId, startedAt, endedAt, outcome, kind, itemId, costLE, costUSD)
                VALUES ('r1', ?, ?, ?, ?, 'succeeded', 'review', ?, 10.5, 10.5)
                """, arguments: [m.mgr.id, m.c.id, m.w.clock.now, m.w.clock.now, item.id])
        }
        let current = try m.item(item)
        #expect(try m.store.reviewSpendCapped(item: current))
        var i = ModeInputs(); i.turnKind = .review; i.tier = .l; i.reviewSpendCapped = true
        let d = ModePolicy.select(i)
        #expect(d.mode == .standard); #expect(d.model == "sonnet"); #expect(d.reason.contains("review spend"))
        try m.store.noteReviewSpendCap(item: current, now: m.w.clock.now)
        try m.store.noteReviewSpendCap(item: current, now: m.w.clock.now)
        let dms = try m.store.writer.read { try String.fetchAll($0, sql: "SELECT text FROM message WHERE text LIKE '%review spend%'") }
        #expect(dms.count == 1)
    }

    @Test func overageStallText() throws {
        var input = StallInput()
        input.overageAllowed = true
        let r = StallExplainer.explain(input, timeZone: .gmt, now: Date())
        #expect(r.reasons.contains("deep modes and Ultra are off while extra usage is on"))
    }
}
