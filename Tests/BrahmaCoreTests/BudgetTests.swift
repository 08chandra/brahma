import Foundation
import Testing
import GRDB
@testable import BrahmaCore

/// Token and cost accounting, per-item budgets, the tier model and the turn-level assertions (Task 14a).
@Suite(.scratch) struct BudgetTests {
    /// A company with a real git workspace, a manager and an engineer who reports to her.
    private struct B {
        let w: World
        let c: Company
        let mgr: Agent
        let eng: Agent
        var store: Store { w.store }

        init(model: String = "sonnet") throws {
            w = try World()
            c = try w.company("Acme")
            mgr = try w.hire(c, "mgr", role: "manager")
            eng = try w.store.hire(companyId: c.id, name: "eng", role: "engineer", model: model, managerId: mgr.id)
        }

        /// A started task of the given tier, leased to the engineer.
        @discardableResult
        func leased(tier: EffortTier = .s, confirmed: Bool = true) throws -> WorkItem {
            let item = try store.createWorkItem(companyId: c.id, by: .owner, draft: WorkItemDraft(
                type: .task, title: "Do it", checkSpec: CheckSpec(command: "true", paths: ["src/a"]), tier: tier, status: .ready),
                                                now: w.clock.now)
            _ = try store.claimLease(itemId: item.id, agentId: eng.id, now: w.clock.now)
            if !confirmed {
                try store.writer.write { db in try db.execute(sql: "UPDATE workItem SET specConfirmedBy = NULL WHERE id = ?", arguments: [item.id]) }
            }
            return try fresh(item)
        }

        func fresh(_ i: WorkItem) throws -> WorkItem { try #require(try store.workItem(id: i.id)) }
        func turns(_ a: Agent) throws -> [Turn] { try w.turns(a) }

        /// One engineer turn: a message wakes it, the script runs, the cycle waits for it.
        func turn(_ script: FakeTurnRunner.Script) async throws {
            w.fake.script(eng.name, script)
            try w.dm(c, eng)
            w.clock.advance(1)
            try await w.cycle()
        }

        func dms(to a: Agent) throws -> [String] { try store.pendingInbox(agentId: a.id).map(\.1.text) }

        /// Every budget escalation the engine ever sent (delivered or not).
        func escalations() throws -> [String] {
            try store.writer.read { try String.fetchAll($0, sql: "SELECT text FROM message WHERE senderId = 'system' AND text LIKE '%over its tier%'") }
        }
    }

    private static func result(tokens: TurnUsage? = nil, cost: Double? = 0.01, subtype: String = "success", error: Bool = false,
                               text: String = "done", session: String = "s-eng", models: [String] = [],
                               fast: String? = nil) -> StreamEvent {
        .result(TurnResult(isError: error, subtype: subtype, text: text, costUSD: cost, apiErrorStatus: nil, sessionId: session,
                           hasUsage: tokens != nil, usage: tokens, fastModeState: fast, speed: fast == nil ? nil : "standard",
                           modelsUsed: models))
    }

    private static func script(_ events: StreamEvent...) -> FakeTurnRunner.Script {
        .init(events: [.initialized(sessionId: "s-eng", model: "claude-sonnet-5-5")] + events)
    }

    private static let big = TurnUsage(inputTokens: 350_000, outputTokens: 100, cacheReadTokens: 1_000_000, cacheCreationTokens: 50)

    // MARK: Accounting

    @Test func usageRecordedPerTurn() async throws {
        let b = try B()
        b.w.fake.cumulativeCosts = false   // scripted totals are raw, as the CLI reports them
        let item = try b.leased(tier: .m)
        let usage = TurnUsage(inputTokens: 10, outputTokens: 20, cacheReadTokens: 1000, cacheCreationTokens: 300)
        try await b.turn(Self.script(Self.result(tokens: usage, cost: 0.10)))
        try await b.turn(Self.script(Self.result(tokens: usage, cost: 0.25)))   // cumulative over --resume
        let turns = try b.turns(b.eng)
        #expect(turns.count == 2)
        #expect(turns[0].inputTokens == 10); #expect(turns[0].outputTokens == 20)
        #expect(turns[0].cacheReadTokens == 1000); #expect(turns[0].cacheCreationTokens == 300)
        #expect(turns[0].itemId == item.id); #expect(turns[0].kind == .work)
        #expect(turns[0].sessionId == "s-eng")
        #expect(turns[0].sessionTotalUSD == 0.10); #expect(turns[1].sessionTotalUSD == 0.25)
        // L-4: a turn's own cost is the cumulative total less the session's previous total.
        #expect(abs(try #require(turns[0].costLE) - 0.10) < 1e-9)
        #expect(abs(try #require(turns[1].costLE) - 0.15) < 1e-9)
        #expect(turns[1].costUSD == turns[1].costLE)
        let used = try b.store.itemUsage(itemId: item.id)
        #expect(used.turns == 2); #expect(used.tokens == 2 * 330)
        #expect(abs(used.costLE - 0.25) < 1e-9)
        #expect(abs(b.store.costToday(now: b.w.clock.now) - 0.25) < 1e-9, "the day's spend is not double-counted")
    }

    @Test func resumeTotalNotDoubleCountedInSpend() async throws {
        let b = try B()
        b.w.fake.cumulativeCosts = false
        try b.leased(tier: .m)
        let cal0 = try b.store.usageCalibration()
        _ = cal0
        for total in [0.10, 0.25, 0.30] { try await b.turn(Self.script(Self.result(cost: total))) }
        let sum = try b.turns(b.eng).compactMap(\.costUSD).reduce(0, +)
        #expect(abs(sum - 0.30) < 1e-9, "the three turns add up to the last total, not to 0.65")
    }

    // MARK: Tier model

    @Test func tierLUsesOpusForAutoAgents() async throws {
        #expect(TierBudget.of(.l).model == "opus"); #expect(TierBudget.of(.s).model == nil); #expect(TierBudget.of(.m).model == nil)
        // `ModePolicy.select` (Task 14c) replaced `ModelPolicy.resolve`: a confirmed tier L work turn is R3 on opus (opus-low
        // in the Low usage mode), tiers S and M stay on Sonnet, and a pinned model is kept.
        func resolve(_ model: String, tier: EffortTier?, kind: TurnKind = .work, mode: UsageMode = .low) -> String {
            var i = ModeInputs()
            i.agentModel = model; i.roleModel = mode == .low ? "haiku" : "sonnet"; i.usageMode = mode
            i.turnKind = kind; i.hasItem = true; i.tier = tier
            return ModePolicy.select(i).model
        }
        #expect(resolve("auto", tier: .l) == "opus"); #expect(resolve("auto", tier: .l, mode: .balanced) == "opus")
        #expect(resolve("auto", tier: .m) == "sonnet"); #expect(resolve("auto", tier: .s) == "sonnet")
        #expect(resolve("haiku", tier: .l) == "haiku", "an explicit model is kept")
        #expect(resolve("auto", tier: .s, kind: .review) == "sonnet", "review turns are Standard on sonnet")
        #expect(resolve("auto", tier: .l, kind: .review, mode: .balanced) == "opus", "a tier L review is Deep R3")
        // End to end: the request an auto agent's turn is sent with.
        let b = try B(model: "auto")
        try b.leased(tier: .l)
        try await b.turn(Self.script(Self.result()))
        #expect(b.w.fake.requests.last?.agent.model == "opus")
    }

    @Test func agentAuthoredTierLNotOpusUntilConfirmed() async throws {
        let b = try B(model: "auto")
        let item = try b.leased(tier: .l, confirmed: false)
        try await b.turn(Self.script(Self.result()))
        #expect(b.w.fake.requests.last?.agent.model != "opus", "an unconfirmed spec cannot buy the better model")
        _ = try b.store.confirmSpec(id: item.id, by: .owner, now: b.w.clock.now)
        // The model of a warm (agent, item) session is fixed (Task 10); the next fresh session picks the tier's model.
        try await b.turn(Self.script(Self.result()))
        #expect(b.w.fake.requests.last?.agent.model != "opus", "a warm item session keeps its model")
        b.w.clock.advance(SessionPolicy.warmSeconds + 1)
        try await b.turn(Self.script(Self.result()))
        #expect(b.w.fake.requests.last?.agent.model == "opus")
    }

    // MARK: Budget

    @Test func overBudgetBlocksItemAndEscalatesOnce() async throws {
        let b = try B()
        let item = try b.leased(tier: .s)
        try await b.turn(Self.script(Self.result(tokens: Self.big, cost: 0.5)))
        let blocked = try b.fresh(item)
        #expect(blocked.status == .blocked)
        #expect(blocked.blockedReason == "over budget: 1/6 turns, 350k/300k tokens, $0.50/$3.00")
        #expect(blocked.stopReason == "budget")
        #expect(try b.store.lease(itemId: item.id) == nil, "the lease is released")
        let kinds = try b.store.itemEvents(itemId: item.id).map(\.kind)
        #expect(kinds.filter { $0 == .budgetExceeded }.count == 1)
        #expect(kinds.contains(.statusChanged)); #expect(kinds.contains(.leaseReleased))
        let dms = try b.dms(to: b.mgr)
        #expect(dms == ["\(item.key) (@eng) is over its tier S budget: 1/6 turns, 350k/300k tokens, $0.50/$3.00. "
            + BudgetText.escalationAdvice])
        let dm = try #require(try b.store.pendingInbox(agentId: b.mgr.id).first)
        #expect(dm.1.senderId == "system")
        // The engineer's next turn does not repeat the escalation.
        try await b.turn(Self.script(Self.result(tokens: Self.big, cost: 0.5)))
        #expect(try b.escalations().count == 1)
        #expect(try b.store.itemEvents(itemId: item.id).filter { $0.kind == .budgetExceeded }.count == 1)
    }

    @Test func overBudgetByTurnsAndByCost() async throws {
        let b = try B()
        let item = try b.leased(tier: .s)
        // Each turn makes progress (a notes edit), so the watchdog (14b) stays out of it.
        let (store, eng, clock) = (b.store, b.eng, b.w.clock)
        func working() -> FakeTurnRunner.Script {
            var s = Self.script(Self.result(tokens: TurnUsage(inputTokens: 100), cost: 0.01))
            s.sideEffect = { _ in
                _ = try store.updateWorkItem(id: item.id, by: .agent(eng.id), patch: WorkItemPatch(notes: "step \(clock.now)"), now: clock.now)
            }
            return s
        }
        for _ in 0..<6 { try await b.turn(working()) }
        #expect(try b.fresh(item).status == .inProgress, "six turns are within tier S")
        try await b.turn(working())
        let blocked = try b.fresh(item)
        #expect(blocked.status == .blocked)
        #expect(blocked.blockedReason?.hasPrefix("over budget: 7/6 turns") == true)
        // Cost alone is enough: a fresh M item over its $10 cap.
        let b2 = try B()
        let pricey = try b2.leased(tier: .m)
        try await b2.turn(Self.script(Self.result(tokens: TurnUsage(inputTokens: 10), cost: 10.5)))
        let again = try b2.fresh(pricey)
        #expect(again.status == .blocked); #expect(again.blockedReason?.contains("$10.50/$10.00") == true)
    }

    @Test func budgetTextShowsWeekShareOnceCalibrated() {
        let usage = ItemUsage(turns: 7, tokens: 350_000, costLE: 4)
        let text = BudgetText.parts(usage: usage, budget: .small, costCapLE: 3, pctPerDollar: 0.01)
        #expect(text == "7/6 turns, 350k/300k tokens, $4.00/$3.00, ≈4% of week")
        #expect(!BudgetText.parts(usage: usage, budget: .small, costCapLE: 3, pctPerDollar: nil).contains("week"))
    }

    @Test func overBudgetItemNotSelfResumed() async throws {
        let b = try B()
        let item = try b.leased(tier: .s)
        try await b.turn(Self.script(Self.result(tokens: Self.big)))
        let refusal = "\(item.key) is over budget; ask your manager to raise the tier or reassign it"
        for target in [WorkItemStatus.ready, .inProgress] {
            #expect(throws: WorkError.self) {
                _ = try b.store.updateWorkItem(id: item.id, by: .agent(b.eng.id), patch: WorkItemPatch(status: target), now: b.w.clock.now)
            }
        }
        do {
            _ = try b.store.updateWorkItem(id: item.id, by: .agent(b.eng.id), patch: WorkItemPatch(status: .ready), now: b.w.clock.now)
            Issue.record("the assignee unblocked an over-budget item")
        } catch let e as WorkError { #expect(e == .forbidden(refusal)) }
        #expect(try b.fresh(item).status == .blocked)
        // The manager raises the tier and unblocks it; the owner could as well.
        _ = try b.store.updateWorkItem(id: item.id, by: .agent(b.mgr.id), patch: WorkItemPatch(tier: .m), now: b.w.clock.now)
        let ready = try b.store.updateWorkItem(id: item.id, by: .agent(b.mgr.id), patch: WorkItemPatch(status: .ready), now: b.w.clock.now)
        #expect(ready.status == .ready); #expect(ready.stopReason == nil)
    }

    @Test func stopReasonRecordedAndShown() async throws {
        let b = try B()
        let item = try b.leased(tier: .s)
        #expect(try b.fresh(item).stopReason == nil)
        try await b.turn(Self.script(Self.result(tokens: Self.big)))
        #expect(try b.fresh(item).stopReason == "budget")
        let tools = CompanyTools(store: b.store, companyId: b.c.id, agentId: b.mgr.id)
        let shown = try tools.call(name: "show_work_item", arguments: ["key": .string(item.key)])
        #expect(shown.contains("\"stopped\":\"budget\""), "\(shown)")
        // The next claim clears it.
        _ = try b.store.updateWorkItem(id: item.id, by: .owner, patch: WorkItemPatch(status: .ready), now: b.w.clock.now)
        _ = try b.store.claimLease(itemId: item.id, agentId: b.eng.id, now: b.w.clock.now)
        #expect(try b.fresh(item).stopReason == nil)
    }

    @Test func ownerCanUnblockOverBudgetItem() async throws {
        let b = try B()
        let item = try b.leased(tier: .s)
        try await b.turn(Self.script(Self.result(tokens: Self.big)))
        let ready = try b.store.updateWorkItem(id: item.id, by: .owner, patch: WorkItemPatch(status: .ready), now: b.w.clock.now)
        #expect(ready.status == .ready)
    }

    @Test func reviewTurnsDoNotCountAgainstBudget() async throws {
        let b = try B()
        let item = try b.leased(tier: .s)
        let store = b.store, eng = b.eng
        var review = Self.script(Self.result(tokens: Self.big, cost: 5))
        review.sideEffect = { _ in
            // The review path (Task 9) records its kind and item before the turn runs; the same call does it here.
            let id = try #require(try store.writer.read { try String.fetchOne($0, sql: "SELECT id FROM turn WHERE agentId = ? AND outcome = 'inProgress'", arguments: [eng.id]) })
            try store.setTurnContext(turnId: id, kind: .review, itemId: item.id)
        }
        try await b.turn(review)
        #expect(try b.fresh(item).status == .inProgress, "a review turn never blocks the item")
        let used = try b.store.itemUsage(itemId: item.id)
        #expect(used == ItemUsage(), "and is not part of its usage")
        #expect(try b.dms(to: b.mgr).isEmpty)
    }

    @Test func infraTurnsNotCounted() throws {
        let b = try B()
        let item = try b.leased(tier: .s)
        func row(_ n: Int, infra: Bool = false, reset: String? = nil, kind: TurnKind = .work, outcome: TurnOutcome = .succeeded, cost: Double = 1) throws {
            var t = Turn(id: "t\(n)", agentId: b.eng.id, companyId: b.c.id, startedAt: b.w.clock.now, endedAt: b.w.clock.now,
                         outcome: outcome, summary: nil, costUSD: cost, infra: infra)
            t.itemId = item.id; t.kind = kind; t.inputTokens = 1000; t.costLE = cost; t.sessionResetReason = reset
            try b.store.writer.write { try t.insert($0) }
        }
        try row(1)
        try row(2, infra: true)
        try row(3, reset: "session not found")
        try row(4, kind: .review)
        try row(5, outcome: .usageLimited, cost: 0)
        try row(6, outcome: .interrupted, cost: 2)
        let used = try b.store.itemUsage(itemId: item.id)
        #expect(used.turns == 1, "only the ordinary work turn is a turn")
        #expect(used.tokens == 1000 + 1000 + 1000, "usage-limited and interrupted turns still carry their tokens")
        #expect(abs(used.costLE - 3) < 1e-9)
    }

    @Test func infraFailureTurnIsNotBudgetedAndNotCounted() async throws {
        let b = try B()
        let item = try b.leased(tier: .s)
        let netText = "API Error: Unable to connect: getaddrinfo ENOTFOUND api.anthropic.com"
        try await b.turn(.init(events: [.initialized(sessionId: "s", model: "m"),
            .result(TurnResult(isError: true, subtype: "error_during_execution", text: netText, costUSD: nil,
                               apiErrorStatus: nil, sessionId: "s"))]))
        let turn = try #require(try b.turns(b.eng).first)
        #expect(turn.infra)
        #expect(try b.store.itemUsage(itemId: item.id) == ItemUsage())
        #expect(try b.fresh(item).status == .inProgress)
    }

    // MARK: Controlled stops

    @Test func maxTurnsIsControlledStop() async throws {
        let b = try B()
        let item = try b.leased(tier: .s)
        // Text that would classify as network if the infrastructure classifier saw it first.
        let capped = Self.result(tokens: TurnUsage(inputTokens: 5, outputTokens: 7, cacheCreationTokens: 90), cost: 0.2,
                                 subtype: "error_max_turns", error: true, text: "Reached maximum number of turns (3); last call: fetch failed")
        try await b.turn(Self.script(capped))
        let turn = try #require(try b.turns(b.eng).first)
        #expect(turn.outcome == .failed); #expect(!turn.infra); #expect(turn.stopReason == "turnCap")
        let agent = try b.w.agent(b.eng)
        #expect(agent.consecutiveFailures == 0); #expect(agent.blocker == nil, "no backoff")
        #expect(agent.state != .blocked)
        let used = try b.store.itemUsage(itemId: item.id)
        #expect(used.turns == 1); #expect(used.tokens == 102); #expect(abs(used.costLE - 0.2) < 1e-9)
        #expect(try b.store.engineHold() == nil)
        // The turn's inbox was delivered, as for a success.
        #expect(try b.w.pending(b.eng) == 0)
    }

    @Test func maxBudgetIsControlledStop() async throws {
        let b = try B()
        let item = try b.leased(tier: .s)
        let capped = Self.result(tokens: Self.big, cost: 0.7, subtype: "error_max_budget_usd", error: true,
                                 text: "Reached maximum budget ($0.05); last call: ENOTFOUND")
        try await b.turn(Self.script(capped))
        let turn = try #require(try b.turns(b.eng).first)
        #expect(turn.stopReason == "budgetCap"); #expect(!turn.infra); #expect(turn.outcome == .failed)
        #expect(try b.w.agent(b.eng).consecutiveFailures == 0)
        // Budget and watchdog do not skip a capped turn: it took the item over its tier.
        #expect(try b.fresh(item).status == .blocked)
        #expect(try b.fresh(item).stopReason == "budget")
        #expect(try b.store.engineHold() == nil)
    }

    @Test func sigtermWithoutResultInterrupted() async throws {
        let b = try B()
        try b.leased(tier: .m)
        try await b.turn(.init(events: [.initialized(sessionId: "s", model: "m")], error: TurnError.interrupted(pendingTasks: 0)))
        let turn = try #require(try b.turns(b.eng).first)
        #expect(turn.outcome == .interrupted); #expect(!turn.infra)
        let agent = try b.w.agent(b.eng)
        #expect(agent.consecutiveFailures == 0); #expect(agent.blocker == nil)
        // A real wait-for-input, not a penalty: the agent is ready again at once.
        #expect(agent.state == .ready)
    }

    @Test func killedWithPendingWorkflowRecordsThePartialResult() async throws {
        let b = try B()
        b.w.fake.cumulativeCosts = false
        let item = try b.leased(tier: .m)
        let early = Self.result(tokens: TurnUsage(inputTokens: 3, outputTokens: 40, cacheCreationTokens: 600), cost: 0.5,
                                text: "The workflow is still running")
        try await b.turn(.init(events: [.initialized(sessionId: "s-eng", model: "m"), .taskStarted(taskId: "w1", taskType: "local_workflow", spawnDepth: nil), early],
                               error: TurnError.interrupted(pendingTasks: 1)))
        let turn = try #require(try b.turns(b.eng).first)
        #expect(turn.outcome == .interrupted, "an early result does not make a killed turn a success")
        #expect(abs(try #require(turn.costLE) - 0.5) < 1e-9)
        #expect(turn.outputTokens == 40)
        #expect(try b.w.agent(b.eng).consecutiveFailures == 0)
        let used = try b.store.itemUsage(itemId: item.id)
        #expect(used.turns == 0, "an interrupted turn is not a turn"); #expect(used.tokens == 643)
        // The workflow's agents are counted on the turn.
        #expect(turn.workflowAgents == 0)
    }

    @Test func fanOutCountersRecorded() async throws {
        let b = try B()
        try b.leased(tier: .m)
        try await b.turn(.init(events: [
            .initialized(sessionId: "s-eng", model: "m"),
            .taskStarted(taskId: "sub", taskType: "local_agent", spawnDepth: 1),
            .taskStarted(taskId: "wf", taskType: "local_workflow", spawnDepth: nil),
            .taskProgress(taskId: "wf", totalTokens: 10, toolUses: 1,
                          agents: [WorkflowAgentInfo(agentId: "a1"), WorkflowAgentInfo(agentId: "a2"), WorkflowAgentInfo(agentId: "a1")]),
            .toolUse(name: "Bash", inputDigest: "d1"), .toolUse(name: "Read", inputDigest: "d2"),
            .taskNotification(taskId: "sub", status: "completed"), .taskNotification(taskId: "wf", status: "completed"),
            Self.result()]))
        let turn = try #require(try b.turns(b.eng).first)
        #expect(turn.subagentsSpawned == 1); #expect(turn.workflowAgents == 2)
        #expect(turn.toolSignature == StableHash.fnv1a64("Bash:d1\nRead:d2"))
        #expect(turn.outcome == .succeeded)
    }

    // MARK: Per-turn assertions

    private func alertTexts(_ b: B) throws -> [String] {
        guard let channel = try b.store.channel(companyId: b.c.id, name: "dm:owner:system") else { return [] }
        return try b.store.messages(channelId: channel.id, limit: 20).map(\.text)
    }

    @Test func unexpectedModelInModelUsageAlerts() async throws {
        let b = try B()
        try await b.turn(Self.script(Self.result(models: ["claude-sonnet-5-5", "claude-fable-5-0"])))
        let alerts = try alertTexts(b)
        #expect(alerts.count == 1); #expect(alerts[0].contains("unexpected model (claude-fable-5-0)"))
        let agent = try b.w.agent(b.eng)
        #expect(agent.state == .blocked)
        guard case .owner(let reason, _)? = agent.blocker else { Issue.record("expected an owner blocker"); return }
        #expect(reason.hasPrefix("doctor re-run needed: unexpected model"))
        // A passing doctor lets it run again.
        try b.store.clearHoldAfterDoctor(now: b.w.clock.now)
        #expect(try b.w.agent(b.eng).state == .ready)
    }

    @Test func mainAndFallbackModelsAreExpected() async throws {
        let b = try B()
        // `sonnet` is the request's model and the fallback; the init line resolved it. Haiku is not named anywhere.
        try await b.turn(Self.script(Self.result(models: ["claude-sonnet-5-5"])))
        #expect(try alertTexts(b).isEmpty)
        #expect(try b.w.agent(b.eng).state != .blocked)
    }

    @Test func safetyFallbackModelRecordedOnly() async throws {
        let b = try B()
        try await b.turn(Self.script(Self.result(models: ["claude-sonnet-5-5", "claude-opus-5"])))
        #expect(try alertTexts(b).isEmpty, "no alert")
        #expect(try b.w.agent(b.eng).state != .blocked)
        let recorded = try b.w.store.events(afterId: 0).filter { $0.kind == .usage }.map(\.text)
        #expect(recorded.contains { $0.contains("safety-fallback model claude-opus-5") })
    }

    @Test func fastModeIsAnAlert() async throws {
        let b = try B()
        try await b.turn(Self.script(Self.result(models: ["claude-sonnet-5-5"], fast: "on")))
        let alerts = try alertTexts(b)
        #expect(alerts.count == 1); #expect(alerts[0].contains("Fast mode is not off"))
    }

    @Test func effortCapWarningRecorded() async throws {
        let b = try B()
        try await b.turn(Self.script(.effortCapped(requested: "max"), Self.result()))
        let turn = try #require(try b.turns(b.eng).first)
        #expect(turn.modeReason?.hasSuffix("; effort 'max' exceeded the org cap and was lowered") == true, "after the mode's own reasons")
        let recorded = try b.w.store.events(afterId: 0).filter { $0.kind == .usage }.map(\.text)
        #expect(recorded.contains { $0.contains("effort 'max'") })
    }

    @Test func initAgentsMismatchAborts() async throws {
        let w = try World()
        let c = try w.company("Acme")
        let eng = try w.hire(c, "eng", role: "engineer")
        let orch = Orchestrator(store: w.store, runner: w.fake, paths: w.paths, mcpExecutable: "/usr/local/bin/brahma",
                                clock: w.clock.function, memory: DispatchMemoryPressureSource(), checkRunner: w.checks,
                                turnExpectations: { _, _ in TurnExpectations(agents: ["claude", "Explore"], forbiddenTools: ["Task"]) })
        let info = InitInfo(sessionId: "s", model: "claude-sonnet-5-5", tools: ["Bash", "Task"], agents: ["claude", "Explore", "general-purpose"])
        w.fake.script("eng", .init(events: [.initialized(sessionId: "s", model: "claude-sonnet-5-5"), .initInfo(info),
                                              Self.result(session: "s")]))
        try w.dm(c, eng)
        await orch.tick()
        try await orch.waitUntilIdle(timeout: .seconds(300))
        let turn = try #require(try w.turns(eng).first)
        #expect(turn.outcome == .interrupted, "the turn was stopped at its init line")
        #expect(turn.costUSD == nil)
        let agent = try w.agent(eng)
        #expect(agent.consecutiveFailures == 0)
        #expect(agent.state == .blocked)
        let channel = try #require(try w.store.channel(companyId: c.id, name: "dm:owner:system"))
        let alerts = try w.store.messages(channelId: channel.id, limit: 10).map(\.text)
        #expect(alerts.count == 1); #expect(alerts[0].contains("unexpected agents general-purpose"))
        // A matching session is not disturbed.
        #expect(TurnAudit.initViolation(InitInfo(sessionId: "s", model: "m", tools: ["Bash"], agents: ["claude", "Explore"]),
                                        expectations: TurnExpectations(agents: ["claude", "Explore"], forbiddenTools: ["Task"])) == nil)
        #expect(TurnAudit.initViolation(info, expectations: nil) == nil)
        #expect(TurnAudit.initViolation(InitInfo(sessionId: "s", model: "m", tools: ["Bash", "Task"], agents: []),
                                        expectations: TurnExpectations(forbiddenTools: ["Task"]))?.contains("Task") == true)
    }

    // MARK: Fix round 1 (14a review)

    /// I1: an item claimed in the middle of a turn is attributed to that turn and counted.
    @Test func midTurnClaimAttributesTheTurn() async throws {
        let b = try B()
        let item = try b.store.createWorkItem(companyId: b.c.id, by: .owner, draft: WorkItemDraft(
            type: .task, title: "Do it", checkSpec: CheckSpec(command: "true", paths: ["src/a"]), tier: .s, status: .ready),
                                              now: b.w.clock.now)
        let store = b.store, itemId = item.id, engId = b.eng.id, now = b.w.clock.now
        var script = Self.script(Self.result(tokens: Self.big, cost: 0.5))
        script.sideEffect = { _ in _ = try store.claimLease(itemId: itemId, agentId: engId, now: now) }
        try await b.turn(script)
        let turn = try #require(try b.turns(b.eng).first)
        #expect(turn.itemId == item.id, "the claim turn is attributed to the item it claimed")
        let used = try b.store.itemUsage(itemId: item.id)
        #expect(used.turns == 1); #expect(used.tokens == 350_150)
        #expect(try b.fresh(item).status == .blocked, "and it counts toward the item's budget")
        #expect(try b.fresh(item).stopReason == "budget")
    }

    /// I2: `modelUsage` is cumulative over `--resume`; a model only a previous turn of the session billed is not new.
    @Test func resumedSessionWithChangingModelIsNotAlerted() async throws {
        let b = try B()
        // Turn 1 ran haiku (a notice turn); turn 2 resumes the session on the main model: modelUsage holds both.
        try await b.turn(.init(events: [.initialized(sessionId: "s-eng", model: "claude-haiku-5-5"),
                                        Self.result(models: ["claude-haiku-5-5"])]))
        try await b.turn(Self.script(Self.result(models: ["claude-haiku-5-5", "claude-sonnet-5-5"])))
        #expect(try alertTexts(b).isEmpty)
        #expect(try b.w.agent(b.eng).state != .blocked)
        // A model nobody expected, new in a later turn of the same session, still alerts.
        try await b.turn(Self.script(Self.result(models: ["claude-haiku-5-5", "claude-sonnet-5-5", "claude-fable-5-0"])))
        let alerts = try alertTexts(b)
        #expect(alerts.count == 1); #expect(alerts[0].contains("claude-fable-5-0")); #expect(!alerts[0].contains("haiku"))
        #expect(try b.w.agent(b.eng).state == .blocked)
    }

    @Test func auditSkipsModelsAlreadySeenInTheSession() {
        let result = TurnResult(isError: false, subtype: "success", text: "x", costUSD: nil, apiErrorStatus: nil, sessionId: "s",
                                modelsUsed: ["claude-haiku-5-5", "claude-sonnet-5-5"])
        let fresh = TurnAudit.findings(result: result, initModel: "claude-sonnet-5-5", main: "sonnet", fallback: "sonnet", expectations: nil)
        #expect(fresh.unexpectedModels == ["claude-haiku-5-5"])
        let resumed = TurnAudit.findings(result: result, initModel: "claude-sonnet-5-5", main: "sonnet", fallback: "sonnet",
                                         expectations: nil, previouslySeen: ["claude-haiku-5-5"])
        #expect(resumed.unexpectedModels.isEmpty)
    }

    /// I3: an engine wall-clock kill is a timeout: failed, normal backoff, budgeted with its usage.
    @Test func wallClockKillWithPendingWorkIsATimeout() async throws {
        let b = try B()
        b.w.fake.cumulativeCosts = false
        let item = try b.leased(tier: .m)
        let early = Self.result(tokens: TurnUsage(inputTokens: 3, outputTokens: 40, cacheCreationTokens: 600), cost: 0.5)
        try await b.turn(.init(events: [.initialized(sessionId: "s-eng", model: "m"),
                                        .taskStarted(taskId: "w1", taskType: "local_workflow", spawnDepth: nil), early],
                               error: TurnError.timedOut))
        let turn = try #require(try b.turns(b.eng).first)
        #expect(turn.outcome == .failed); #expect(!turn.infra)
        #expect(abs(try #require(turn.costLE) - 0.5) < 1e-9); #expect(turn.outputTokens == 40)
        let agent = try b.w.agent(b.eng)
        #expect(agent.consecutiveFailures == 1)
        guard case .retry? = agent.blocker else { Issue.record("expected the normal retry backoff, got \(String(describing: agent.blocker))"); return }
        let used = try b.store.itemUsage(itemId: item.id)
        #expect(used.turns == 1); #expect(used.tokens == 643)
    }

    @Test func wallClockKillRunsTheBudgetStep() async throws {
        let b = try B()
        let item = try b.leased(tier: .s)
        try await b.turn(.init(events: [.initialized(sessionId: "s-eng", model: "m"),
                                        .taskStarted(taskId: "w1", taskType: "local_workflow", spawnDepth: nil),
                                        Self.result(tokens: Self.big, cost: 0.5)],
                               error: TurnError.timedOut))
        #expect(try b.fresh(item).status == .blocked); #expect(try b.fresh(item).stopReason == "budget")
    }

    /// m1: a failed turn with an error result keeps its tokens and cost, so the next resumed turn's delta is its own.
    @Test func failedTurnWithErrorResultRecordsUsageAndCost() async throws {
        let b = try B()
        b.w.fake.cumulativeCosts = false
        let item = try b.leased(tier: .m)
        let usage = TurnUsage(inputTokens: 5, outputTokens: 7, cacheCreationTokens: 90)
        try await b.turn(Self.script(Self.result(tokens: usage, cost: 0.3, subtype: "error_during_execution", error: true, text: "boom")))
        b.w.clock.advance(120)   // past the retry backoff of the failed turn
        try await b.turn(Self.script(Self.result(tokens: usage, cost: 0.5)))
        let turns = try b.turns(b.eng)
        try #require(turns.count == 2)
        #expect(turns[0].outcome == .failed)
        #expect(abs(try #require(turns[0].costLE) - 0.3) < 1e-9); #expect(turns[0].inputTokens == 5)
        #expect(abs(try #require(turns[1].costLE) - 0.2) < 1e-9, "the second turn pays only its own share")
        #expect(abs(try b.store.itemUsage(itemId: item.id).costLE - 0.5) < 1e-9)
    }

    /// m2: the escalation says usage is per item, so an unblock needs a raise, a boost, a split or a reassignment.
    @Test func budgetDMExplainsPerItemUsage() async throws {
        let b = try B()
        try b.leased(tier: .s)
        try await b.turn(Self.script(Self.result(tokens: Self.big, cost: 0.5)))
        let text = try #require(try b.escalations().first)
        #expect(text.contains("Raise the tier or boost the budget, split the item or reassign it"))
        #expect(text.contains("per item"))
    }

    // MARK: Migration

    @Test func migrationAddsTurnAndItemColumns() throws {
        let store = try Store.inMemory()
        let turnColumns = Set(try store.writer.read { try $0.columns(in: "turn").map(\.name) })
        for name in ["kind", "itemId", "sessionResetReason", "sessionId", "sessionTotalUSD", "inputTokens", "outputTokens",
                     "cacheReadTokens", "cacheCreationTokens", "toolSignature", "mode", "rung", "effort", "modeReason", "stopReason",
                     "subagentsSpawned", "workflowAgents", "costLE", "modelsUsed"] {
            #expect(turnColumns.contains(name), "turn.\(name)")
        }
        #expect(try store.writer.read { try $0.columns(in: "workItem").map(\.name) }.contains("stopReason"))
        #expect(TierBudget.of(.s) == TierBudget(maxTurns: 6, maxTokens: 300_000, maxCostLE: 3, model: nil))
        #expect(TierBudget.of(.m) == TierBudget(maxTurns: 15, maxTokens: 1_000_000, maxCostLE: 10, model: nil))
        #expect(TierBudget.of(.l) == TierBudget(maxTurns: 30, maxTokens: 3_000_000, maxCostLE: 40, model: "opus"))
    }
}
