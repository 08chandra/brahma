import Testing
import Foundation
import BrahmaCore
@testable import BrahmaAppModel

@MainActor @Suite(.scratch) struct AgentActionsTests {
    func world() async throws -> (model: AppModel, store: Store, ceo: Agent) {
        let (store, paths) = try makeHome()
        let (_, ceo, _, _) = try seedAcme(store, paths)
        let model = AppModel(store: store, paths: paths)
        await model.load()
        return (model, store, ceo)
    }

    @Test(arguments: [("", "engineer", "Handle is required"), ("owner", "engineer", "@owner is reserved"),
                      ("-bad", "engineer", "Handles use a–z, 0–9, - and _ (up to 32, starting with a letter or digit)"),
                      ("ceo", "engineer", "@ceo already exists"), ("qa1", "  ", "Role is required")])
    func hireValidation(handle: String, role: String, message: String) {
        let form = HireForm(handle: handle, role: role)
        #expect(form.validate(existingHandles: ["ceo"]) == message)
    }

    @Test func validFormHasNoMessageAndNormalizesHandle() {
        let form = HireForm(handle: "  @QA1 ", role: "qa", model: .haiku)
        #expect(form.normalizedHandle == "qa1")
        #expect(form.validate(existingHandles: ["ceo"]) == nil)
    }

    @Test func hireCreatesSleepingAgentAndSelectsIt() async throws {
        let w = try await world()
        let agent = try await w.model.hire(HireForm(handle: "@QA1", role: "qa", model: .haiku))
        #expect(agent.name == "qa1")
        #expect(agent.model == "haiku")
        #expect(agent.state == .sleeping)
        #expect(w.model.selectedAgentId == agent.id)
        #expect(w.model.snapshot.agents.contains { $0.id == agent.id })
    }

    @Test func hireStoreDuplicateMapsMessage() async throws {
        let w = try await world()
        let form = HireForm(handle: "qa2", role: "qa")
        #expect(form.validate(existingHandles: Set(w.model.snapshot.agents.map(\.name))) == nil)
        _ = try w.store.hire(companyId: w.ceo.companyId, name: "qa2", role: "qa", model: "haiku")
        await #expect(throws: FormError.invalid("@qa2 already exists")) { try await w.model.hire(form) }
    }

    @Test func pauseWakeKill() async throws {
        let w = try await world()
        await w.model.setAgentPaused(w.ceo.id, true)
        var d = try #require(w.model.detail(agentId: w.ceo.id))
        #expect(d.agent.state == .sleeping && d.agent.paused)
        #expect(d.canWake && !d.canPause)
        await w.model.setAgentPaused(w.ceo.id, false)
        d = try #require(w.model.detail(agentId: w.ceo.id))
        #expect(d.agent.state == .ready && !d.agent.paused)
        await w.model.kill(agentId: w.ceo.id)
        d = try #require(w.model.detail(agentId: w.ceo.id))
        #expect(d.agent.state == .killed)
        #expect(!d.canPause && !d.canWake && !d.canKill)
        #expect(d.stateLabel == "killed")
    }

    @Test func pauseRunningAgentShowsPausing() async throws {
        let w = try await world()
        _ = try w.store.transition(agentId: w.ceo.id, to: .running)
        await w.model.tick(forceSnapshot: true)
        await w.model.setAgentPaused(w.ceo.id, true)
        #expect(w.model.detail(agentId: w.ceo.id)?.stateLabel == "running (pausing)")
    }

    @Test func killTwiceSetsError() async throws {
        let w = try await world()
        await w.model.kill(agentId: w.ceo.id)
        #expect(w.model.errorMessage == nil)
        await w.model.kill(agentId: w.ceo.id)
        #expect(w.model.errorMessage == "@ceo is already killed")
    }

    @Test func detailLastTurnLine() async throws {
        let w = try await world()
        let gmt = try #require(TimeZone(identifier: "GMT"))
        #expect(w.model.detail(agentId: w.ceo.id, timeZone: gmt)?.lastTurnLine == "No turns yet")
        let t0 = Date(timeIntervalSince1970: 1_700_000_000)  // 2023-11-14 22:13:20 GMT
        let turn = try w.store.startTurn(agentId: w.ceo.id, now: t0)
        await w.model.tick(forceSnapshot: true)
        #expect(w.model.detail(agentId: w.ceo.id, timeZone: gmt)?.lastTurnLine == "in progress since 22:13")
        _ = try w.store.finishTurn(id: turn.id, outcome: .succeeded, summary: "Did it", costUSD: nil,
                                   now: t0.addingTimeInterval(60 * 49))
        await w.model.tick(forceSnapshot: true)
        let d = try #require(w.model.detail(agentId: w.ceo.id, timeZone: gmt))
        #expect(d.lastTurnLine == "succeeded at 23:02")
        #expect(d.lastTurnSummary == "Did it")
    }
}
