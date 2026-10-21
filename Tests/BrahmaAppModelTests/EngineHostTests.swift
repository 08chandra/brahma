import Testing
import Foundation
import BrahmaCore
@testable import BrahmaAppModel

@MainActor @Suite struct EngineHostTests {
    let tools = Result<EngineTools, EngineSetupError>.success(EngineTools(claudePath: "claude", mcpExecutable: "/tmp/brahma"))

    func host(_ paths: BrahmaPaths, _ store: Store, _ runner: StubRunner = StubRunner(mode: .succeed)) -> EngineHost {
        EngineHost(paths: paths, store: store, makeRunner: { _ in runner }, tickInterval: .milliseconds(10))
    }

    func dmCeo(_ store: Store, _ acme: Company) throws {
        _ = try MessageRouter(store: store).sendDM(companyId: acme.id, from: .owner, to: "ceo", text: "hello")
    }

    @Test func firstHostEmbedsSecondIsExternal() async throws {
        let (store, paths) = try makeHome()
        let h1 = host(paths, store), h2 = host(paths, store)
        await h1.start(tools: tools)
        #expect(h1.status == .embedded)
        await h2.start(tools: tools)
        #expect(h2.status == .external)
        await h2.stop()
        await h1.stop()
        #expect(h1.status == .stopped && h2.status == .stopped)
    }

    @Test func externalTakesOverWhenLockFrees() async throws {
        let (store, paths) = try makeHome()
        let h1 = host(paths, store), h2 = host(paths, store)
        await h1.start(tools: tools)
        await h2.start(tools: tools)
        #expect(h2.status == .external)
        await h1.stop()
        await h2.retryTakeover()
        #expect(h2.status == .embedded)
        await h2.stop()
    }

    @Test func stopInterruptsTurnAndReturnsAgentReady() async throws {
        let (store, paths) = try makeHome()
        let (acme, ceo, _, _) = try seedAcme(store, paths)
        try dmCeo(store, acme)
        let h = host(paths, store, StubRunner(mode: .hangUntilCancelled))
        await h.start(tools: tools)
        try await eventually { try store.agent(id: ceo.id)?.state == .running }
        await h.stop()
        #expect(h.status == .stopped)
        #expect(try store.agent(id: ceo.id)?.state == .ready)
        #expect(try store.lastTurn(agentId: ceo.id)?.outcome == .interrupted)
        #expect(try store.pendingInbox(agentId: ceo.id).count == 1)
    }

    @Test func relaunchResumesInterruptedAgent() async throws {
        let (store, paths) = try makeHome()
        let (acme, ceo, _, _) = try seedAcme(store, paths)
        try dmCeo(store, acme)
        let h = host(paths, store, StubRunner(mode: .hangUntilCancelled))
        await h.start(tools: tools)
        try await eventually { try store.agent(id: ceo.id)?.state == .running }
        await h.stop()
        let h2 = host(paths, store, StubRunner(mode: .succeed))
        await h2.start(tools: tools)
        try await eventually(timeout: .seconds(5)) {
            try store.agent(id: ceo.id)?.state == .sleeping && store.lastTurn(agentId: ceo.id)?.outcome == .succeeded
        }
        #expect(try store.pendingInbox(agentId: ceo.id).isEmpty)
        await h2.stop()
    }

    @Test func stopIsBoundedWhenChildrenNeverExit() async throws {
        let (store, paths) = try makeHome()
        let (acme, ceo, _, _) = try seedAcme(store, paths)
        try dmCeo(store, acme)
        let h = host(paths, store, StubRunner(mode: .hangUntilCancelled, childrenNeverExit: true))
        await h.start(tools: tools)
        try await eventually { try store.agent(id: ceo.id)?.state == .running }
        let start = ContinuousClock.now
        await h.stop(timeout: .milliseconds(300))
        #expect(ContinuousClock.now - start < .seconds(2))
        #expect(h.status == .stopped)
    }

    @Test func stopReleasesLockForCLI() async throws {
        let (store, paths) = try makeHome()
        let h = host(paths, store)
        await h.start(tools: tools)
        await h.stop()
        _ = try OrchestratorLock.acquire(paths: paths)
    }

    @Test func missingToolsFailWithoutTakingLock() async throws {
        let (store, paths) = try makeHome()
        let h = host(paths, store)
        await h.start(tools: .failure(.claudeNotFound))
        #expect(h.status == .failed("Can't find the claude CLI. Install Claude Code, or set BRAHMA_CLAUDE to its path, then relaunch Brahma."))
        do {
            _ = try OrchestratorLock.acquire(paths: paths)
        }
        let h2 = host(paths, store)
        await h2.start(tools: .failure(.helperMissing(path: "/x/brahma")))
        guard case .failed(let msg) = h2.status else { Issue.record("expected failed"); return }
        #expect(msg.contains("/x/brahma"))
    }

    @Test func stopNeverTouchesCompanyStatus() async throws {
        let (store, paths) = try makeHome()
        let (acme, _, _, _) = try seedAcme(store, paths)
        _ = try store.updateCompany(id: acme.id) { $0.status = .running }
        let h = host(paths, store)
        await h.start(tools: tools)
        await h.stop()
        #expect(try store.company(id: acme.id)?.status == .running)
    }
}
