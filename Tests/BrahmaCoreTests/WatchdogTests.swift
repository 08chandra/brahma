import Foundation
import Testing
import GRDB
@testable import BrahmaCore

/// The watchdog, its loop guards and the failed-check guard (Task 14b).
@Suite(.serialized) struct WatchdogTests {
    /// A company with a manager and an engineer who reports to her.
    private struct W {
        let w: World
        let c: Company
        let mgr: Agent
        let eng: Agent
        var store: Store { w.store }

        init() throws {
            w = try World()
            c = try w.company("Acme")
            mgr = try w.hire(c, "mgr", role: "manager")
            eng = try w.store.hire(companyId: c.id, name: "eng", role: "engineer", model: "sonnet", managerId: mgr.id)
        }

        @discardableResult
        func leased(_ agent: Agent? = nil, type: WorkItemType = .task) throws -> WorkItem {
            let item = try store.createWorkItem(companyId: c.id, by: .owner, draft: WorkItemDraft(
                type: type, title: "Do it", checkSpec: CheckSpec(command: "true", paths: ["src/a"]), tier: .l, status: .ready),
                                                now: w.clock.now)
            _ = try store.claimLease(itemId: item.id, agentId: (agent ?? eng).id, now: w.clock.now)
            return try fresh(item)
        }

        func fresh(_ i: WorkItem) throws -> WorkItem { try #require(try store.workItem(id: i.id)) }
        func agent(_ a: Agent) throws -> Agent { try w.agent(a) }

        /// One turn of `agent`: a message wakes it, the script runs, the cycle waits for it.
        func turn(_ agent: Agent? = nil, _ script: FakeTurnRunner.Script = .init()) async throws {
            let a = agent ?? eng
            w.fake.script(a.name, script)
            if try self.agent(a).state == .sleeping || self.agent(a).state == .ready { try w.dm(c, a) }
            w.clock.advance(1)
            try await w.cycle()
        }

        func systemDMs(to handle: String) throws -> [String] {
            try store.writer.read { db in
                try String.fetchAll(db, sql: """
                    SELECT m.text FROM message m JOIN channel ch ON ch.id = m.channelId
                    WHERE m.senderId = 'system' AND ch.kind = 'dm' AND ch.name = ? ORDER BY m.rowid
                    """, arguments: ["dm:" + ["system", handle].sorted().joined(separator: ":")])
            }
        }
    }

    private static func tools(_ calls: [String], results: [String] = []) -> FakeTurnRunner.Script {
        var events: [StreamEvent] = [.initialized(sessionId: "s", model: "claude-sonnet-5-5")]
        for c in calls { events.append(.toolUse(name: "Bash", inputDigest: c)) }
        for r in results { events.append(.toolResult(digest: r)) }
        events.append(.result(TurnResult(isError: false, subtype: "success", text: "done", costUSD: 0.01, apiErrorStatus: nil,
                                         sessionId: "s")))
        return .init(events: events)
    }

    // MARK: The pure rule

    struct Row: Sendable, CustomTestStringConvertible {
        var name: String
        var progressed = false
        var hasWork = true
        var previous = 0
        var signatures: [String?] = []
        var calls = 0
        var results = 0
        var verdict: WatchdogVerdict
        var count: Int
        var testDescription: String { name }
    }

    static let table: [Row] = [
        Row(name: "repeated calls", calls: 5, verdict: .escalate("loop: the same tool call 5 times in a row"), count: 0),
        Row(name: "repeated calls even with progress", progressed: true, calls: 6,
            verdict: .escalate("loop: the same tool call 6 times in a row"), count: 0),
        Row(name: "repeated results", results: 5, verdict: .escalate("loop: the same tool result 5 times in a row"), count: 0),
        Row(name: "four repeats are fine", previous: 1, calls: 4, results: 4, verdict: .ok, count: 2),
        Row(name: "identical signatures", signatures: ["a", "a", "a"], verdict: .escalate("loop: identical tool calls in 3 turns"), count: 0),
        Row(name: "identical signatures with progress", progressed: true, signatures: ["a", "a", "a"], verdict: .ok, count: 0),
        Row(name: "nil signatures are no loop", previous: 0, signatures: [nil, nil, nil], verdict: .ok, count: 1),
        Row(name: "two identical is no loop", signatures: ["a", "a"], verdict: .ok, count: 1),
        Row(name: "a different one breaks it", signatures: ["a", "a", "b"], verdict: .ok, count: 1),
        Row(name: "progress resets", progressed: true, previous: 4, verdict: .ok, count: 0),
        Row(name: "no work resets", hasWork: false, previous: 4, verdict: .ok, count: 0),
        Row(name: "counts up", previous: 0, verdict: .ok, count: 1),
        Row(name: "nudge at 3", previous: 2, verdict: .nudge(3), count: 3),
        Row(name: "after the nudge", previous: 3, verdict: .ok, count: 4),
        Row(name: "escalate at 5", previous: 4, verdict: .escalate("no work-item progress in 5 turns"), count: 0),
        Row(name: "escalate past 5", previous: 7, verdict: .escalate("no work-item progress in 8 turns"), count: 0),
    ]

    @Test(arguments: table) func evaluateTable(_ row: Row) {
        let r = Watchdog.evaluate(progressed: row.progressed, hasWork: row.hasWork, previousCount: row.previous,
                                  recentSignatures: row.signatures,
                                  observation: TurnObservation(maxRepeatedCall: row.calls, maxRepeatedResult: row.results),
                                  config: WatchdogConfig())
        #expect(r.verdict == row.verdict); #expect(r.count == row.count)
    }

    @Test func pinnedConfig() {
        let c = WatchdogConfig.standard
        #expect(c == WatchdogConfig(nudgeAfter: 3, escalateAfter: 5, repeatLimit: 5, signatureTurns: 3))
        #expect(Watchdog.failedCheckLimit == 3)
        #expect(TurnObservation.longestRun(["a", "b", "b", "b", "a"]) == 3); #expect(TurnObservation.longestRun([]) == 0)
    }

    // MARK: End to end

    @Test func nudgeThenEscalateWithReassign() async throws {
        let t = try W()
        let item = try t.leased()
        for _ in 0..<2 { try await t.turn() }
        #expect(try t.agent(t.eng).turnsWithoutProgress == 2)
        #expect(try t.systemDMs(to: "eng").isEmpty)
        try await t.turn()
        let nudge = "Watchdog: 3 turns without work-item progress. Update your item, write a hand-off, or call set_blocked with what you need."
        #expect(try t.systemDMs(to: "eng") == [nudge])
        try await t.turn()
        #expect(try t.agent(t.eng).turnsWithoutProgress == 4)
        try await t.turn()
        let back = try t.fresh(item)
        #expect(back.status == .ready); #expect(back.ownerId == nil); #expect(back.stopReason == "no-progress")
        #expect(try t.store.lease(itemId: item.id) == nil)
        #expect(try t.store.itemEvents(itemId: item.id).contains { $0.kind == .watchdog })
        #expect(try t.systemDMs(to: "mgr") == ["Watchdog: @eng — no work-item progress in 5 turns. \(item.key) is back in Ready; "
            + "reassign it or talk to @eng."])
        let eng = try t.agent(t.eng)
        #expect(eng.state == .blocked); #expect(eng.blocker == .agent(t.mgr.id)); #expect(eng.turnsWithoutProgress == 0)
        // The manager reassigns it; the next claim clears the stop.
        let eng2 = try t.store.hire(companyId: t.c.id, name: "eng2", role: "engineer", model: "sonnet", managerId: t.mgr.id)
        _ = try t.store.updateWorkItem(id: item.id, by: .agent(t.mgr.id), patch: WorkItemPatch(ownerId: .some(eng2.id)), now: t.w.clock.now)
        _ = try t.store.claimLease(itemId: item.id, agentId: eng2.id, now: t.w.clock.now)
        #expect(try t.fresh(item).stopReason == nil)
        // The manager's reply wakes the engineer.
        _ = try t.w.router.sendDM(companyId: t.c.id, from: .agent(t.mgr.id), to: "eng", text: "take a break", now: t.w.clock.now)
        #expect(try t.agent(t.eng).state == .ready)
    }

    @Test func repeatedToolCallsTriggerLoop() async throws {
        let t = try W()
        let item = try t.leased()
        try await t.turn(nil, Self.tools(Array(repeating: "ls", count: 5)))
        #expect(try t.fresh(item).stopReason == "loop")
        #expect(try t.systemDMs(to: "mgr").first?.hasPrefix("Watchdog: @eng — loop: the same tool call 5 times in a row.") == true)
        // The same signature three turns running (each turn fine on its own).
        let t2 = try W()
        let other = try t2.leased()
        try await t2.turn(nil, Self.tools(["ls", "pwd"]))
        try await t2.turn(nil, Self.tools(["ls", "pwd"]))
        #expect(try t2.fresh(other).stopReason == nil)
        try await t2.turn(nil, Self.tools(["ls", "pwd"]))
        #expect(try t2.fresh(other).stopReason == "loop")
        #expect(try t2.systemDMs(to: "mgr").first?.contains("loop: identical tool calls in 3 turns") == true)
        // Identical results.
        let t3 = try W()
        let third = try t3.leased()
        try await t3.turn(nil, Self.tools(["a", "b", "c", "d", "e"], results: Array(repeating: "same", count: 5)))
        #expect(try t3.fresh(third).stopReason == "loop")
    }

    @Test func progressResetsCounter() async throws {
        let t = try W()
        let item = try t.leased()
        try await t.turn(); try await t.turn()
        #expect(try t.agent(t.eng).turnsWithoutProgress == 2)
        let (store, eng, clock) = (t.store, t.eng, t.w.clock)
        try await t.turn(nil, .init(sideEffect: { _ in
            _ = try store.updateWorkItem(id: item.id, by: .agent(eng.id), patch: WorkItemPatch(notes: "halfway"), now: clock.now)
        }))
        #expect(try t.agent(t.eng).turnsWithoutProgress == 0)
        // A hand-off or an ask counts too: an ask proposed in the turn.
        try await t.turn(); try await t.turn()
        #expect(try t.agent(t.eng).turnsWithoutProgress == 2)
        try await t.turn(nil, .init(sideEffect: { _ in
            _ = try store.updateWorkItem(id: item.id, by: .agent(eng.id), patch: WorkItemPatch(status: .blocked, blockedReason: "need the API key"),
                                         now: clock.now)
        }))
        #expect(try t.agent(t.eng).turnsWithoutProgress == 0)
        #expect(try t.fresh(item).stopReason == nil)
    }

    @Test func executiveEscalatesToOwner() async throws {
        let t = try W()
        let ceo = try t.store.hire(companyId: t.c.id, name: "ceo", role: "ceo", model: "sonnet")
        let spike = try t.leased(ceo, type: .spike)
        for _ in 0..<5 { try await t.turn(ceo) }
        let back = try t.fresh(spike)
        #expect(back.status == .ready); #expect(back.stopReason == "no-progress")
        let ceoNow = try t.agent(ceo)
        #expect(ceoNow.state == .blocked)
        guard case .owner(let reason, _)? = ceoNow.blocker else { Issue.record("blocked on the owner, not \(String(describing: ceoNow.blocker))"); return }
        #expect(reason == "watchdog: no work-item progress in 5 turns")
        let toOwner = try await t.store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT m.text FROM message m JOIN channel ch ON ch.id = m.channelId WHERE ch.name = 'dm:owner:system'")
        }
        #expect(toOwner.contains("Watchdog: @ceo — no work-item progress in 5 turns. \(spike.key) is back in Ready; reassign it or talk to @ceo."))
    }

    @Test func noWorkNoCounter() async throws {
        let t = try W()
        for _ in 0..<6 { try await t.turn() }
        #expect(try t.agent(t.eng).turnsWithoutProgress == 0)
        #expect(try t.systemDMs(to: "eng").isEmpty); #expect(try t.systemDMs(to: "mgr").isEmpty)
        #expect(try t.agent(t.eng).state != .blocked)
    }

    @Test func escalatesPastKilledManager() async throws {
        let t = try W()
        let director = try t.store.hire(companyId: t.c.id, name: "dir", role: "manager", model: "sonnet")
        try await t.store.writer.write { db in
            try db.execute(sql: "UPDATE agent SET managerId = ? WHERE id = ?", arguments: [director.id, t.mgr.id])
            try db.execute(sql: "UPDATE agent SET state = 'killed' WHERE id = ?", arguments: [t.mgr.id])
        }
        let item = try t.leased()
        for _ in 0..<5 { try await t.turn() }
        #expect(try t.fresh(item).stopReason == "no-progress")
        #expect(try t.systemDMs(to: "mgr").isEmpty)
        #expect(try t.systemDMs(to: "dir").first?.hasPrefix("Watchdog: @eng — no work-item progress in 5 turns.") == true)
        #expect(try t.agent(t.eng).blocker == .agent(director.id))
        #expect(try t.agent(director).state == .ready || t.agent(director).state == .running, "the alert wakes the ancestor")
    }

    @Test func infraAndSessionResetTurnsAreNotJudged() async throws {
        let t = try W()
        _ = try t.leased()
        try await t.turn(); try await t.turn()
        let infra = FakeTurnRunner.Script(events: [.initialized(sessionId: "s", model: "m")],
                                          error: FakeError(description: "getaddrinfo ENOTFOUND api.anthropic.com"))
        try await t.turn(nil, infra)
        #expect(try t.w.turns(t.eng).last?.infra == true)
        #expect(try t.agent(t.eng).turnsWithoutProgress == 2, "an infrastructure failure is never counted")
    }

    // MARK: Loop guard on checks and stop reasons

    @Test func threeFailedChecksEscalate() async throws {
        let t = try W()
        let item = try t.leased()
        let root = URL(fileURLWithPath: t.c.workspacePath, isDirectory: true)
        let wt = GitWorkspace(root: root).worktreePath(key: item.key)
        let tools = CompanyTools(store: t.store, companyId: t.c.id, agentId: t.eng.id)
        // Let the engine make the worktree (the engineer's first turn), then submit three times; every check fails twice
        // (the flake re-run), so each submission is one failed outcome.
        try await t.turn()
        for round in 1...3 {
            #expect(FileManager.default.fileExists(atPath: wt.path), "round \(round)")
            try FileManager.default.createDirectory(at: wt.appending(path: "src/a"), withIntermediateDirectories: true)
            try "round \(round)".write(to: wt.appending(path: "src/a/work\(round).txt"), atomically: true, encoding: .utf8)
            _ = try tools.call(name: "submit_for_review", arguments: ["key": .string(item.key), "summary": .string("try \(round)")])
            t.w.checks.enqueue(FakeCheckRunner.fail(), FakeCheckRunner.fail())
            for _ in 0..<6 where try t.fresh(item).status == .inReview {
                t.w.clock.advance(1)
                try await t.w.cycle()
            }
            if round < 3 {
                #expect(try t.fresh(item).status == .inProgress, "round \(round) is returned to its holder")
                #expect(try t.fresh(item).failedChecksSinceClaim == round)
            }
        }
        let back = try t.fresh(item)
        #expect(back.status == .ready); #expect(back.ownerId == nil); #expect(back.stopReason == "failed-checks")
        #expect(try t.store.lease(itemId: item.id) == nil)
        #expect(try t.systemDMs(to: "mgr").contains("Watchdog: @eng — 3 failed checks on \(item.key). \(item.key) is back in Ready; "
            + "reassign it or talk to @eng."))
        let eng = try t.agent(t.eng)
        #expect(eng.state == .blocked); #expect(eng.blocker == .agent(t.mgr.id))
    }

    @Test func inconclusiveChecksDoNotCountTowardLoopGuard() throws {
        let t = try W()
        let item = try t.leased()
        try t.store.writer.write { db in
            try t.store.noteFailedCheck(db: db, itemId: item.id, holderId: t.eng.id, now: t.w.clock.now)
            try t.store.noteFailedCheck(db: db, itemId: item.id, holderId: t.eng.id, now: t.w.clock.now)
        }
        #expect(try t.fresh(item).failedChecksSinceClaim == 2)
        // A new claim starts the count over.
        _ = try t.store.releaseLease(itemId: item.id, agentId: t.eng.id, note: nil, now: t.w.clock.now)
        _ = try t.store.claimLease(itemId: item.id, agentId: t.eng.id, now: t.w.clock.now)
        #expect(try t.fresh(item).failedChecksSinceClaim == 0)
    }

    @Test func stopReasonRecorded() async throws {
        let t = try W()
        let item = try t.leased()
        for _ in 0..<5 { try await t.turn() }
        #expect(try t.fresh(item).stopReason == "no-progress")
        let shown = try CompanyTools(store: t.store, companyId: t.c.id, agentId: t.mgr.id)
            .call(name: "show_work_item", arguments: ["key": .string(item.key)])
        #expect(shown.contains("\"stopped\":\"no-progress\""), "\(shown)")
        // The orientation shows it to whoever has the item next, with the budget line.
        let eng2 = try t.store.hire(companyId: t.c.id, name: "eng2", role: "engineer", model: "sonnet", managerId: t.mgr.id)
        try await t.store.writer.write { db in try db.execute(sql: "UPDATE workItem SET ownerId = ?, status = 'inProgress' WHERE id = ?",
                                                        arguments: [eng2.id, item.id]) }
        let fresh = try t.agent(eng2)
        let company = try #require(try t.store.company(id: t.c.id))
        let text = TurnDigest.render(try TurnContext.load(store: t.store, paths: t.w.paths, agent: fresh, company: company),
                                     agent: fresh, company: company)
        #expect(text.contains("Stopped: no-progress"), "\(text)")
        #expect(text.contains("Budget (tier L): 5/30 turns, 0k/3000k tokens, $0.05/$40.00"), "\(text)")
        _ = try t.store.claimLease(itemId: item.id, agentId: eng2.id, now: t.w.clock.now)
        #expect(try t.fresh(item).stopReason == nil)
    }
}
