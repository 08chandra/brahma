import Testing
import Foundation
@testable import BrahmaCore

@Test(arguments: [(AgentState.sleeping, AgentState.ready, true), (.ready, .running, true), (.running, .blocked, true),
                  (.blocked, .ready, true), (.sleeping, .running, false), (.killed, .ready, false), (.ready, .ready, false),
                  (.running, .killed, true), (.killed, .killed, false)])
func transitionTable(from: AgentState, to: AgentState, ok: Bool) {
    #expect(AgentLifecycle.canTransition(from: from, to: to) == ok)
}

private func makeAgent(_ s: Store) throws -> Agent {
    let c = try s.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
    return try s.hire(companyId: c.id, name: "bob", role: "dev", model: "sonnet")
}

@Test func illegalTransitionThrowsAndPersistsNothing() throws {
    let s = try Store.inMemory(); let a = try makeAgent(s)
    #expect(throws: LifecycleError.illegal(from: .sleeping, to: .running)) {
        try s.transition(agentId: a.id, to: .running)
    }
    #expect(try s.agent(id: a.id)?.state == .sleeping)
    #expect(try s.events(afterId: 0).isEmpty)
}

@Test func enteringReadyStampsReadySinceAndClearsBlocker() throws {
    let s = try Store.inMemory(); var a = try makeAgent(s)
    let t0 = Store.now()
    a.state = .blocked; a.blocker = .retry(until: t0, failures: 1); try s.save(a)
    let t1 = Store.now().addingTimeInterval(5)
    let r = try s.transition(agentId: a.id, to: .ready, now: t1)
    #expect(r.blocker == nil); #expect(r.readySince == t1)
    #expect(try s.agent(id: a.id) == r)
    let blocked = try s.transition(agentId: a.id, to: .blocked, blocker: .owner(reason: "x"), now: t1)
    #expect(blocked.blocker == .owner(reason: "x")); #expect(blocked.readySince == nil)
    let evs = try s.events(afterId: 0)
    #expect(evs.count == 2); #expect(evs.allSatisfy { $0.kind == .stateChanged && $0.agentId == a.id })
}

@Test func transitionKeepsPausedAndRequestedBlocker() throws {
    let s = try Store.inMemory(); var a = try makeAgent(s)
    a.paused = true; a.requestedBlocker = .agent("x"); try s.save(a)
    let r = try s.transition(agentId: a.id, to: .ready)
    #expect(r.paused); #expect(r.requestedBlocker == .agent("x"))
}

@Test func recoverInterruptedTurns() throws {
    let dir = try tempDir(); let path = dir.appending(path: "t.sqlite").path
    let s = try Store(path: path); let a = try makeAgent(s)
    _ = try s.transition(agentId: a.id, to: .ready)
    _ = try s.transition(agentId: a.id, to: .running)
    let turn = try s.startTurn(agentId: a.id)
    let s2 = try Store(path: path)
    #expect(try s2.recoverInterruptedTurns() == 1)
    #expect(try s2.agent(id: a.id)?.state == .ready)
    #expect(try s2.agent(id: a.id)?.readySince != nil)
    let t = try s2.writer.read { db in try Turn.fetchOne(db, key: turn.id) }
    #expect(t?.outcome == .interrupted); #expect(t?.endedAt != nil)
    #expect(try s2.recoverInterruptedTurns() == 0)
}

@Test func turnCountSince() throws {
    let s = try Store.inMemory(); let a = try makeAgent(s)
    let t = Store.now()
    for m in [90.0, 30, 5] { _ = try s.startTurn(agentId: a.id, now: t.addingTimeInterval(-m * 60)) }
    #expect(try s.turnCount(agentId: a.id, since: t.addingTimeInterval(-3600)) == 2)
    #expect(try s.oldestTurnStart(agentId: a.id, since: t.addingTimeInterval(-3600)) == t.addingTimeInterval(-30 * 60))
    #expect(try s.oldestTurnStart(agentId: a.id, since: t) == nil)
}

@Test func finishTurnRecordsOutcome() throws {
    let s = try Store.inMemory(); let a = try makeAgent(s)
    let turn = try s.startTurn(agentId: a.id)
    #expect(turn.outcome == .inProgress)
    let end = Store.now().addingTimeInterval(3)
    try s.finishTurn(id: turn.id, outcome: .succeeded, summary: "done", costUSD: 0.12, now: end)
    let t = try s.writer.read { db in try Turn.fetchOne(db, key: turn.id) }
    #expect(t?.outcome == .succeeded); #expect(t?.summary == "done"); #expect(t?.costUSD == 0.12); #expect(t?.endedAt == end)
}

@Test func finishTurnOnlyUpdatesInProgressTurns() throws {
    let s = try Store.inMemory(); let a = try makeAgent(s)
    let turn = try s.startTurn(agentId: a.id)
    _ = try s.recoverInterruptedTurns()
    #expect(try s.finishTurn(id: turn.id, outcome: .succeeded, summary: "late", costUSD: 1) == false)
    let t = try s.writer.read { db in try Turn.fetchOne(db, key: turn.id) }
    #expect(t?.outcome == .interrupted); #expect(t?.summary == nil)
    let live = try s.startTurn(agentId: a.id)
    #expect(try s.finishTurn(id: live.id, outcome: .succeeded, summary: "ok", costUSD: 1))
    #expect(try s.writer.read { db in try Turn.fetchOne(db, key: live.id) }?.outcome == .succeeded)
}

@Test func eventsFilterAndPaginate() throws {
    let s = try Store.inMemory()
    let c1 = try s.createCompany(name: "A", goal: "g", workspacesRoot: try tempDir())
    let c2 = try s.createCompany(name: "B", goal: "g", workspacesRoot: try tempDir())
    for (i, c) in [c1, c2, c1].enumerated() {
        try s.appendEvent(ActivityEvent(id: nil, companyId: c.id, agentId: nil, turnId: nil, kind: .message, text: "m\(i)", createdAt: Store.now()))
    }
    let all = try s.events(afterId: 0)
    #expect(all.map(\.text) == ["m0", "m1", "m2"])
    #expect(try s.events(afterId: all[0].id!).map(\.text) == ["m1", "m2"])
    #expect(try s.events(afterId: 0, companyId: c1.id).map(\.text) == ["m0", "m2"])
    #expect(try s.events(afterId: 0, limit: 1).count == 1)
}
