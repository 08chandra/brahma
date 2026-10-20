import Testing
import Foundation
@testable import AgentCompanyCore

private func makeAgent(_ s: Store, state: AgentState) throws -> Agent {
    let c = try s.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
    let a = try s.hire(companyId: c.id, name: "bob", role: "dev", model: "sonnet")
    switch state {
    case .sleeping: return a
    case .ready: return try s.transition(agentId: a.id, to: .ready)
    case .running:
        _ = try s.transition(agentId: a.id, to: .ready)
        return try s.transition(agentId: a.id, to: .running)
    case .blocked: return try s.transition(agentId: a.id, to: .blocked, blocker: .owner(reason: "x"))
    case .killed: return try s.transition(agentId: a.id, to: .killed)
    }
}

@Test func pausingRunningAgentOnlySetsFlag() throws {
    let s = try Store.inMemory(); let a = try makeAgent(s, state: .running)
    let r = try s.setPaused(agentId: a.id, true)
    #expect(r.paused); #expect(r.state == .running)
}

@Test(arguments: [AgentState.ready, .blocked, .sleeping])
func pausingIdleAgentSleepsIt(state: AgentState) throws {
    let s = try Store.inMemory(); let a = try makeAgent(s, state: state)
    let r = try s.setPaused(agentId: a.id, true)
    #expect(r.paused); #expect(r.state == .sleeping); #expect(r.blocker == nil)
}

@Test(arguments: [AgentState.sleeping, .blocked])
func wakingMovesToReadyAndClearsPause(state: AgentState) throws {
    let s = try Store.inMemory(); let a = try makeAgent(s, state: state)
    _ = try s.setPaused(agentId: a.id, true)
    let r = try s.setPaused(agentId: a.id, false)
    #expect(!r.paused); #expect(r.state == .ready); #expect(r.readySince != nil)
}

@Test func pauseFlipDoesNotClobberOtherColumns() throws {
    let s = try Store.inMemory(); let a = try makeAgent(s, state: .running)
    // Another process changes a column after the CLI read the agent.
    var other = try #require(try s.agent(id: a.id)); other.consecutiveFailures = 3; try s.save(other)
    let r = try s.setPaused(agentId: a.id, true)
    #expect(r.consecutiveFailures == 3)
}

@Test func killedAgentIsLeftAlone() throws {
    let s = try Store.inMemory(); let a = try makeAgent(s, state: .killed)
    let r = try s.setPaused(agentId: a.id, false)
    #expect(r.state == .killed); #expect(!r.paused)
}

@Test func lastTurnAndMaxEventId() throws {
    let s = try Store.inMemory(); let a = try makeAgent(s, state: .ready)
    #expect(try s.lastTurn(agentId: a.id) == nil)
    let t = try s.startTurn(agentId: a.id)
    #expect(try s.lastTurn(agentId: a.id)?.id == t.id)
    #expect(try s.maxEventId() == (try s.events(afterId: 0).last?.id ?? 0))
}
