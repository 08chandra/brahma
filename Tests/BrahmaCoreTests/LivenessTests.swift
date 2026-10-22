import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// The stall explainer, deadlock detection and item aging (Task 12).
@Suite struct LivenessTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)   // Fri 2027-01-15 08:00 UTC
    static let utc = TimeZone(identifier: "UTC")!

    private struct W {
        let store: Store
        let company: Company
        let cto: Agent, m1: Agent, m2: Agent, e1: Agent, e2: Agent, e5: Agent
        var now: Date { LivenessTests.now }

        init() throws {
            let s = try Store.inMemory()
            let c = try s.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
            store = s; company = c
            func hire(_ n: String, _ role: String, _ m: Agent? = nil) throws -> Agent {
                try s.hire(companyId: c.id, name: n, role: role, model: "sonnet", managerId: m?.id)
            }
            cto = try hire("cto", "cto")
            m1 = try hire("mgr-1", "manager", cto); m2 = try hire("mgr-2", "manager", cto)
            e1 = try hire("eng-1", "engineer", m1); e2 = try hire("eng-2", "engineer", m1); e5 = try hire("eng-5", "engineer", m2)
        }

        func fresh(_ a: Agent) throws -> Agent { try #require(try store.agent(id: a.id)) }
        func wait(_ a: Agent, on b: Agent) throws {
            _ = try store.transition(agentId: a.id, to: .blocked, blocker: .agent(b.id), now: now)
        }
        func unblock(_ a: Agent) throws { _ = try store.transition(agentId: a.id, to: .ready, now: now) }
        func sweep() throws { try store.sweepLiveness(companyId: company.id, now: now) }
        func dms(_ a: String, _ b: String = "system") throws -> [String] {
            guard let ch = try store.channel(companyId: company.id, name: "dm:" + [a, b].sorted().joined(separator: ":")) else { return [] }
            return try store.messages(channelId: ch.id, limit: 100).map(\.text)
        }
        func sleep(_ a: Agent) throws { _ = try store.transition(agentId: a.id, to: .sleeping, now: now) }
    }

    // MARK: Explainer

    @Test func explainerOrderAndCopy() {
        var input = StallInput()
        input.running = 0
        input.stopped = true
        input.hold = StallHold(reason: "network", detail: "3 failures in 5 min", since: Self.now)
        input.companyPaused = true
        input.doctorOk = false; input.doctorDetail = "flags: --fallback-model missing"
        input.usage = .closed(until: Self.now.addingTimeInterval(3600))
        input.pace = Pace(allowed: 0.40, used: 0.52, ahead: 0.12, closedUntil: Self.now.addingTimeInterval(90_000))
        input.memory = .critical
        input.ownerAskCount = 3; input.oldestOwnerAsk = 2 * 86_400 + 100
        input.blockerGroups = [StallBlockerGroup(target: "you", count: 1), StallBlockerGroup(target: "@eng-1", count: 4),
                               StallBlockerGroup(target: "ACME-3", count: 2), StallBlockerGroup(target: "usage limit", count: 2),
                               StallBlockerGroup(target: "@zed", count: 1)]
        input.deadlocks = [["eng-1", "eng-5"]]
        input.longBlockedCount = 2; input.oldestBlockedKey = "ACME-9"; input.oldestBlockedAge = 5 * 3600
        input.readyItems = 3; input.idleAgents = 0
        let report = StallExplainer.explain(input, timeZone: Self.utc, now: Self.now)
        #expect(report.running == 0)
        #expect(report.reasons == [
            "stopped by the owner",
            "engine paused: network (3 failures in 5 min) since 08:00",
            "company is paused",
            "Claude Code check failing: flags: --fallback-model missing",
            "usage limit (5-hour) until 09:00",
            "weekly pace: ahead by 12% — resumes about Sat 09:00",
            "memory pressure critical",
            "3 asks wait for you (oldest 2d)",
            "4 agents blocked on @eng-1",
            "2 agents blocked on ACME-3",
            "2 agents blocked on usage limit",
            "deadlock: @eng-1 → @eng-5 → @eng-1",
            "2 items blocked over 3 days (oldest ACME-9, 5h)",
            "3 Ready items and no idle agent picked them up",
        ])
        var quiet = StallInput()
        quiet.ownerAskCount = 1; quiet.oldestOwnerAsk = 600
        quiet.blockerGroups = [StallBlockerGroup(target: "@a", count: 1)]
        let small = StallExplainer.explain(quiet, timeZone: Self.utc, now: Self.now)
        #expect(small.reasons == ["1 ask waits for you (oldest 10m)", "1 agent blocked on @a", "no Ready items in the backlog"])
    }

    @Test func explainerHoldFirst() {
        var input = StallInput()
        input.hold = StallHold(reason: "account", detail: "not logged in", since: Self.now)
        input.companyPaused = true; input.readyItems = 1
        #expect(StallExplainer.explain(input, timeZone: Self.utc, now: Self.now).reasons.first
                == "engine paused: account (not logged in) since 08:00")
        input.stopped = true
        #expect(StallExplainer.explain(input, timeZone: Self.utc, now: Self.now).reasons.prefix(2)
                == ["stopped by the owner", "engine paused: account (not logged in) since 08:00"])
    }

    @Test func storeStallReportReadsTheCompany() throws {
        let w = try W()
        #expect(try w.store.stallReport(companyId: w.company.id, now: w.now).reasons == ["no Ready items in the backlog"])
        var c = w.company; c.status = .paused
        try w.store.updateCompany(c)
        _ = try w.store.setHold(reason: .network, detail: "offline", now: w.now)
        try w.wait(w.e1, on: w.e5)
        let report = try w.store.stallReport(companyId: w.company.id, now: w.now, memory: .warning)
        #expect(report.running == 0)
        #expect(report.reasons.first?.hasPrefix("engine paused: network (offline) since ") == true)
        #expect(report.reasons.contains("company is paused"))
        #expect(report.reasons.contains("memory pressure warning"))
        #expect(report.reasons.contains("1 agent blocked on @eng-5"))
    }

    // MARK: Wait-for graph

    @Test func waitForCycleDetected() {
        let edges = [WaitEdge(from: "b", to: "c"), WaitEdge(from: "a", to: "b", via: "K-1"), WaitEdge(from: "c", to: "a"),
                     WaitEdge(from: "x", to: "a"), WaitEdge(from: "p", to: "q"), WaitEdge(from: "q", to: "p"), WaitEdge(from: "s", to: "s")]
        let cycles = WaitForGraph.cycles(edges: edges)
        #expect(cycles == [["a", "b", "c"], ["p", "q"]])
        #expect(WaitForGraph.signature(["c", "a", "b"]) == "a,b,c")
        #expect(WaitForGraph.cycles(edges: [WaitEdge(from: "a", to: "b"), WaitEdge(from: "b", to: "c")]).isEmpty)
    }

    @Test func deadlockEscalatesToLowestCommonManager() throws {
        // Across teams: the cto.
        let w = try W()
        try w.wait(w.e1, on: w.e5); try w.wait(w.e5, on: w.e1)
        try w.sweep()
        let told = try w.dms("cto")
        #expect(told.count == 1)
        #expect(told[0] == "Deadlock: @eng-1 waits on @eng-5, @eng-5 waits on @eng-1. Break it by answering one of them or reassigning.")
        #expect(try w.fresh(w.cto).state == .ready)
        #expect(try w.store.openDeadlocks(companyId: w.company.id).first?.escalatedTo == w.cto.id)
        try w.sweep()
        #expect(try w.dms("cto").count == 1)   // once
        #expect(try w.store.openDeadlocks(companyId: w.company.id).count == 1)

        // Within a team: that team's manager.
        let v = try W()
        try v.wait(v.e1, on: v.e2); try v.wait(v.e2, on: v.e1)
        try v.sweep()
        #expect(try v.dms("mgr-1").count == 1); #expect(try v.dms("cto").isEmpty); #expect(try v.dms("owner").isEmpty)
    }

    @Test func deadlockWithoutManagerGoesToTheOwner() throws {
        let w = try W()
        let a = try w.store.hire(companyId: w.company.id, name: "solo-1", role: "engineer", model: "sonnet")
        let b = try w.store.hire(companyId: w.company.id, name: "solo-2", role: "engineer", model: "sonnet")
        try w.wait(a, on: b); try w.wait(b, on: a)
        try w.sweep()
        #expect(try w.dms("owner").count == 1)
        #expect(try w.store.openDeadlocks(companyId: w.company.id).first?.ownerEscalated == true)
    }

    @Test func deadlockOwnerAfterOneActiveDay() throws {
        let w = try W()
        try w.wait(w.e1, on: w.e2); try w.wait(w.e2, on: w.e1)
        try w.sweep()
        #expect(try w.dms("owner").isEmpty)
        try w.store.advanceActive(companyId: w.company.id, by: Liveness.deadlockOwnerAfter - 60)
        try w.sweep()
        #expect(try w.dms("owner").isEmpty)
        try w.store.advanceActive(companyId: w.company.id, by: 120)
        try w.sweep()
        let owner = try w.dms("owner")
        #expect(owner.count == 1); #expect(owner[0].hasPrefix("Deadlock unresolved after 1d: Deadlock: @eng-1 waits on @eng-2"))
        try w.sweep()
        #expect(try w.dms("owner").count == 1)
    }

    @Test func deadlockResolvedWhenBroken() throws {
        let w = try W()
        try w.wait(w.e1, on: w.e2); try w.wait(w.e2, on: w.e1)
        try w.sweep()
        #expect(try w.store.openDeadlocks(companyId: w.company.id).count == 1)
        try w.unblock(w.e2)
        try w.sweep()
        #expect(try w.store.openDeadlocks(companyId: w.company.id).isEmpty)
        let row = try w.store.writer.read { db in try DeadlockRecord.fetchOne(db) }
        #expect(row?.resolvedAt != nil)
        // The same wait later is a new deadlock.
        try w.wait(w.e2, on: w.e1)
        try w.sweep()
        #expect(try w.store.openDeadlocks(companyId: w.company.id).count == 1)
    }

    @Test func itemDependencyWaitFormsACycle() throws {
        let w = try W()
        func make(_ owner: Agent) throws -> WorkItem {
            try w.store.createWorkItem(companyId: w.company.id, by: .owner, draft: WorkItemDraft(
                type: .task, title: "t", checkSpec: CheckSpec(command: "true", paths: ["p/\(owner.name)"]), ownerId: owner.id, status: .ready),
                                       now: w.now)
        }
        let a = try make(w.e1), b = try make(w.e2)
        // e1 holds A and waits (blocked) on item B, owned by e2; e2 waits on e1.
        _ = try w.store.transition(agentId: w.e1.id, to: .blocked, blocker: .workItem(id: b.id, key: b.key), now: w.now)
        try w.wait(w.e2, on: w.e1)
        _ = a
        try w.sweep()
        #expect(try w.dms("mgr-1").first?.contains("(via \(b.key))") == true)
    }

    @Test func tickRunsTheDeadlockScan() async throws {
        let world = try World()
        let c = try world.company("Acme")
        let boss = try world.hire(c, "boss", role: "manager")
        let a = try world.store.hire(companyId: c.id, name: "eng-1", role: "engineer", model: "sonnet", managerId: boss.id)
        let b = try world.store.hire(companyId: c.id, name: "eng-2", role: "engineer", model: "sonnet", managerId: boss.id)
        _ = try world.store.transition(agentId: a.id, to: .blocked, blocker: .agent(b.id), now: world.clock.now)
        _ = try world.store.transition(agentId: b.id, to: .blocked, blocker: .agent(a.id), now: world.clock.now)
        await world.orchestrator.tick()
        #expect(try world.store.openDeadlocks(companyId: c.id).count == 1)
        // Rescanned only after `Liveness.scanInterval` active seconds.
        try world.store.advanceActive(companyId: c.id, by: 10)
        _ = try world.store.transition(agentId: b.id, to: .ready, now: world.clock.now)
        await world.orchestrator.tick()
        #expect(try world.store.openDeadlocks(companyId: c.id).count == 1)
        try world.store.advanceActive(companyId: c.id, by: Liveness.scanInterval)
        await world.orchestrator.tick()
        #expect(try world.store.openDeadlocks(companyId: c.id).isEmpty)
    }

    // MARK: Aging

    private func inProgressItem(_ w: W, owner: Agent) throws -> WorkItem {
        let item = try w.store.createWorkItem(companyId: w.company.id, by: .owner, draft: WorkItemDraft(
            type: .task, title: "t", checkSpec: CheckSpec(command: "true", paths: ["p"]), ownerId: owner.id, status: .ready), now: w.now)
        try w.store.writer.write { db in try db.execute(sql: "UPDATE workItem SET status = 'inProgress' WHERE id = ?", arguments: [item.id]) }
        return item
    }

    @Test func itemAgingNotifiesOncePerLevel() throws {
        let w = try W()
        let item = try inProgressItem(w, owner: w.e1)
        try w.sweep()
        #expect(try w.dms("mgr-1").isEmpty)
        try w.store.advanceActive(companyId: w.company.id, by: Liveness.itemAging[0])
        try w.sweep(); try w.sweep()
        let first = try w.dms("mgr-1")
        #expect(first.count == 1); #expect(first[0].contains(item.key)); #expect(first[0].contains("@eng-1")); #expect(try w.dms("cto").isEmpty)
        #expect(try w.store.itemEvents(itemId: item.id).filter { $0.kind == .aging }.count == 1)
        try w.store.advanceActive(companyId: w.company.id, by: Liveness.itemAging[1] - Liveness.itemAging[0])
        try w.sweep(); try w.sweep()
        #expect(try w.dms("mgr-1").count == 1)
        #expect(try w.dms("cto").count == 1)
        #expect(try w.store.itemEvents(itemId: item.id).filter { $0.kind == .aging }.count == 2)
        // A change starts the clock over: the notices are forgotten and fire again later.
        _ = try w.store.commentWorkItem(id: item.id, by: .owner, text: "still on it", now: w.now)
        try w.sweep()
        let rows = try w.store.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM agingNotice") }
        #expect(rows == 0)
        try w.store.advanceActive(companyId: w.company.id, by: Liveness.itemAging[0])
        try w.sweep()
        #expect(try w.dms("mgr-1").count == 2)
    }

    @Test func leasedItemsDoNotAge() throws {
        let w = try W()
        let item = try inProgressItem(w, owner: w.e1)
        try w.store.writer.write { db in
            try WorkLease(itemId: item.id, companyId: w.company.id, agentId: w.e1.id, acquiredAt: w.now, expiresActive: 1e9).insert(db)
        }
        try w.store.advanceActive(companyId: w.company.id, by: Liveness.itemAging[1] + 1)
        try w.sweep()
        #expect(try w.dms("mgr-1").isEmpty); #expect(try w.dms("cto").isEmpty)
    }

    @Test func pausedTimeDoesNotAge() throws {
        let w = try W()
        _ = try inProgressItem(w, owner: w.e1)
        try w.store.accrueActiveTime(now: w.now)
        var c = w.company; c.status = .paused
        try w.store.updateCompany(c)
        // Two wall-clock days pass while the company is paused: no active time accrues.
        try w.store.accrueActiveTime(now: w.now.addingTimeInterval(2 * 86_400))
        c.status = .running
        try w.store.updateCompany(c)
        try w.store.accrueActiveTime(now: w.now.addingTimeInterval(2 * 86_400 + 30))
        #expect(w.store.activeNow(companyId: w.company.id) <= 30)
        try w.sweep()
        #expect(try w.dms("mgr-1").isEmpty)
        // An engine hold freezes it too, even with active time already past the line.
        try w.store.advanceActive(companyId: w.company.id, by: Liveness.itemAging[0])
        _ = try w.store.setHold(reason: .network, detail: "offline", now: w.now)
        try w.sweep()
        #expect(try w.dms("mgr-1").isEmpty)
        try w.store.clearHold(now: w.now)
        try w.sweep()
        #expect(try w.dms("mgr-1").count == 1)
    }
}
