import Foundation
import Testing
import GRDB
@testable import BrahmaCore

/// Work modes end to end through the orchestrator (Task 14c): the decision on the request and the turn, the no-launch rule,
/// escalation, the review spend cap and the floor reset.
@Suite(.scratch) struct WorkModeTests {
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
        // Read the live credential mid-turn (it is deleted when the turn ends).
        let seen = Locked<ModeQuotas?>(nil)
        var script = Self.result()
        script.sideEffect = { [store = m.store] r in
            let config = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: r.mcpConfigPath))) as? [String: Any]
            let server = (config?["mcpServers"] as? [String: Any])?["company"] as? [String: Any]
            let token = (server?["env"] as? [String: String])?[MCPConfig.tokenVariable] ?? ""
            seen.set(store.turnCredentialContext(token: token, companyId: r.company.id, agentId: r.agent.id)?.quotas)
        }
        try await m.turn(script)
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
        // The mode's quotas ride on the turn's credential row, not in the MCP config's env.
        let config = try Data(contentsOf: URL(fileURLWithPath: r.mcpConfigPath))
        #expect(!String(decoding: config, as: UTF8.self).contains("QUOTA"))
        #expect(seen.get() == ModeCaps.standard.quotas)
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

    /// Fix 1 C1: once its item is blocked over budget, the assignee's later turns are no longer the item's leaseholder turns: they
    /// launch without the item's budget, answer the inbox, and do not loop.
    @Test func overBudgetAssigneeStillAnswersDMs() async throws {
        let m = try M()
        let item = try m.leased(tier: .s)
        try await m.store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO turn (id, agentId, companyId, startedAt, endedAt, outcome, kind, itemId, costLE, costUSD)
                VALUES ('old', ?, ?, ?, ?, 'succeeded', 'work', ?, 2.9, 2.9)
                """, arguments: [m.eng.id, m.c.id, m.w.clock.now, m.w.clock.now, item.id])
        }
        try await m.turn(Self.result())
        #expect(try m.item(item).status == .blocked)
        let mine = { m.w.fake.requests.filter { $0.agent.id == m.eng.id } }
        let launched = mine().count
        // The DM is still unanswered; the next turns run (no item budget applies) and deliver it.
        for _ in 0..<2 {
            m.w.clock.advance(120)
            try await m.w.cycle()
        }
        #expect(mine().count == launched + 1, "the agent answers its DM once")
        let last = try #require(mine().last)
        #expect(last.prompt.contains("please do it"))
        #expect(try m.store.pendingInbox(agentId: m.eng.id).isEmpty)
        let rows = try m.w.turns(m.eng).count
        for _ in 0..<3 {
            m.w.clock.advance(120)
            try await m.w.cycle()
        }
        #expect(try m.w.turns(m.eng).count == rows, "no turn-row loop")
        #expect(try m.item(item).status == .blocked)
    }

    /// Fix 1 Q2: risk keywords and paths in a spec only its implementer wrote do not escalate; review flags (engine-owned) do.
    @Test func untrustedRiskTagsDoNotEscalate() async throws {
        let m = try M()
        let item = try m.store.createWorkItem(companyId: m.c.id, by: .agent(m.eng.id), draft: WorkItemDraft(
            type: .task, title: "security migration exploit", description: "migrate the auth token injection",
            checkSpec: CheckSpec(command: "true", paths: ["Package.swift", ".env", "db/migrations/x"]), tier: .m,
            status: .ready), now: m.w.clock.now)
        _ = try m.store.claimLease(itemId: item.id, agentId: m.eng.id, now: m.w.clock.now)
        let facts = try #require(try m.store.itemModeFacts(itemId: item.id, holderId: m.eng.id))
        #expect(facts.riskTags.isEmpty, "\(facts.riskTags)")
        try await m.turn(Self.result())
        let d = try #require(m.w.fake.requests.last?.mode)
        #expect(d.rung == .r1); #expect(d.mode == .standard)
        // Engine-owned review flags still count, trusted or not.
        try await m.store.writer.write { db in
            try db.execute(sql: "UPDATE workItem SET reviewFlags = ? WHERE id = ?", arguments: ["[\"flaky check\"]", item.id])
        }
        #expect(try m.store.itemModeFacts(itemId: item.id, holderId: m.eng.id)?.riskTags == ["flagged"])
        // A manager's confirmation makes the whole spec count.
        try await m.store.writer.write { db in
            try db.execute(sql: "UPDATE workItem SET specConfirmedBy = ? WHERE id = ?", arguments: ["\(m.mgr.id):manager", item.id])
        }
        let trusted = try #require(try m.store.itemModeFacts(itemId: item.id, holderId: m.eng.id))
        #expect(trusted.riskTags.isSuperset(of: ["hotPath", "sensitivePath", "migration", "securityLabel", "flagged"]))
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

/// A value shared with a `@Sendable` fake-runner side effect.
private final class Locked<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: T
    init(_ v: T) { value = v }
    func get() -> T { lock.withLock { value } }
    func set(_ v: T) { lock.withLock { value = v } }
}
