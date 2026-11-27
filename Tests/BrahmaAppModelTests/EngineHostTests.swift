import Testing
import Foundation
import BrahmaCore
@testable import BrahmaAppModel

private let passingReport = DoctorReport(cliVersion: "2.1.306", items: [DoctorItem(name: "probe", status: .pass, detail: "ok")],
                                         checkedAt: Date())

@MainActor @Suite(.scratch) struct EngineHostTests {
    let tools = Result<EngineTools, EngineSetupError>.success(EngineTools(claudePath: "claude", mcpExecutable: "/tmp/brahma"))

    func host(_ paths: BrahmaPaths, _ store: Store, _ runner: StubRunner = StubRunner(mode: .succeed)) -> EngineHost {
        EngineHost(paths: paths, store: store, makeRunner: { _ in runner }, tickInterval: .milliseconds(10),
                   probe: { _ in passingReport }, ownerKeyStore: InMemoryOwnerKeyStore())
    }

    /// INT-I3: the engine rebuilt after a restore carries the app's secret vault, never the unavailable default.
    @Test func rebuiltEngineKeepsTheSecretVault() throws {
        let (store, paths) = try makeHome()
        let vault = MemoryVault()
        let rebuilt = EngineHost.rebuilt(paths: paths, store: store, ownerKeyStore: InMemoryOwnerKeyStore(), secretVault: vault)
        #expect((rebuilt.secretVault as? MemoryVault) === vault)
        #expect(!(rebuilt.secretVault is UnavailableVault))
    }

    @Test func failedProbeDoesNotTakeLock() async throws {
        let (store, paths) = try makeHome()
        let failing = DoctorReport(cliVersion: "2.1.306", items: [
            DoctorItem(name: "version", status: .pass, detail: "ok"),
            DoctorItem(name: "probe", status: .fail, detail: "no result line"),
        ], checkedAt: Date())
        let h = EngineHost(paths: paths, store: store, makeRunner: { _ in StubRunner(mode: .succeed) },
                           tickInterval: .milliseconds(10), probe: { _ in failing },
                           ownerKeyStore: InMemoryOwnerKeyStore())
        await h.start(tools: tools)
        #expect(h.status == .failed("Claude Code check failed: no result line. Run brahma doctor in Terminal for details."))
        // The lock was never taken: another host can embed at once.
        let h2 = host(paths, store)
        await h2.start(tools: tools)
        #expect(h2.status == .embedded)
        await h2.stop()
    }

    @Test func appLaunchCreatesVerifiedOwnerKey() async throws {
        let (store, paths) = try makeHome()
        let keys = InMemoryOwnerKeyStore()
        let h = EngineHost(paths: paths, store: store, makeRunner: { _ in StubRunner(mode: .succeed) },
                           tickInterval: .milliseconds(10), probe: { _ in passingReport }, ownerKeyStore: keys)
        await h.start(tools: tools)
        #expect(OwnerKey.verify(paths: paths, store: keys))
        let first = try String(contentsOf: OwnerKey.url(paths: paths), encoding: .utf8)
        await h.stop()
        await h.start(tools: tools)   // a valid key is kept
        #expect(try String(contentsOf: OwnerKey.url(paths: paths), encoding: .utf8) == first)
        await h.stop()
    }

    @Test func appLaunchNeverReplacesAnInvalidKey() async throws {
        let (store, paths) = try makeHome()
        let keys = InMemoryOwnerKeyStore()
        try OwnerKey.create(paths: paths, store: keys)
        keys.removeHash(for: paths)   // the key file exists but cannot be verified
        let before = try String(contentsOf: OwnerKey.url(paths: paths), encoding: .utf8)
        let h = EngineHost(paths: paths, store: store, makeRunner: { _ in StubRunner(mode: .succeed) },
                           tickInterval: .milliseconds(10), probe: { _ in passingReport }, ownerKeyStore: keys)
        await h.start(tools: tools)
        await h.stop()
        #expect(try String(contentsOf: OwnerKey.url(paths: paths), encoding: .utf8) == before)
        #expect(!OwnerKey.verify(paths: paths, store: keys))
    }

    @Test func rotationNeedsUserPresence() async throws {
        let (_, paths) = try makeHome()
        let keys = InMemoryOwnerKeyStore()
        try OwnerKey.create(paths: paths, store: keys)
        keys.removeHash(for: paths)   // lost hash: only the app, with user presence, can recover
        let before = try String(contentsOf: OwnerKey.url(paths: paths), encoding: .utf8)
        await #expect(throws: OwnerKeyRotationError.notAuthorized) {
            try await OwnerKeyRotation(authenticate: { _ in false }).rotate(paths: paths, store: keys)
        }
        #expect(try String(contentsOf: OwnerKey.url(paths: paths), encoding: .utf8) == before)
        try await OwnerKeyRotation(authenticate: { _ in true }).rotate(paths: paths, store: keys)
        #expect(OwnerKey.verify(paths: paths, store: keys))
        #expect(try String(contentsOf: OwnerKey.url(paths: paths), encoding: .utf8) != before)
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

    /// Final review #5: the takeover poll (`retryTakeover`, every ~5 s on the main actor) tries the lock once, with no busy
    /// retries, so a held lock never stalls the main actor for the 5 × 20 ms the launch's retries take; the launch keeps them.
    @Test func takeoverPollDoesNotRetryTheLock() async throws {
        let (store, paths) = try makeHome()
        let h1 = host(paths, store), h2 = host(paths, store)
        var asked: [Int] = []
        h2.acquireLock = { paths, retries in
            asked.append(retries)
            return try OrchestratorLock.acquire(paths: paths, busyRetries: retries)
        }
        await h1.start(tools: tools)
        await h2.start(tools: tools)
        #expect(h2.status == .external)
        let started = AwakeTime.uptime()
        await h2.retryTakeover()
        #expect(h2.status == .external)
        #expect(AwakeTime.uptime() - started < 5, "hang guard")
        await h1.stop()
        await h2.retryTakeover()
        #expect(h2.status == .embedded)
        #expect(asked == [OrchestratorLock.busyRetries, 0, 0], "\(asked)")
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
        try await eventually {
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
        let start = AwakeTime.now
        await h.stop(timeout: .milliseconds(300))
        #expect(AwakeTime.now - start < .seconds(60), "hang guard")
        #expect(h.status == .stopped)
    }

    @Test func stopReleasesLockForCLI() async throws {
        let (store, paths) = try makeHome()
        let h = host(paths, store)
        await h.start(tools: tools)
        #expect(h.status == .embedded)
        await h.stop()
        #expect(h.status == .stopped)
        // The CLI can take the lock once the host has let it go (asked again until it can, never against a fixed delay).
        try await eventually { (try? OrchestratorLock.acquire(paths: paths)) != nil }
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

    /// Task 9c: a second quit request while `stop` waits on children that never go ends the wait at once (the groups the
    /// engine recorded are killed first; the stub spawned none, so nothing is signalled) and the host is stopped.
    @Test func forceStopEndsAPendingStopAtOnce() async throws {
        let (store, paths) = try makeHome()
        let h = host(paths, store, StubRunner(mode: .succeed, childrenNeverExit: true))
        await h.start(tools: tools)
        #expect(h.status == .embedded)
        let stopping = Task { await h.stop(timeout: .seconds(60)) }
        try await eventually(timeout: .seconds(10)) { h.status == .stopping }
        let killed = try #require(h.forceStop())
        #expect(killed.groups.terminated.isEmpty)
        await stopping.value   // returns only because forceStop ended the wait: the children never go
        #expect(h.status == .stopped)
    }

    /// Fix round 1, I1: a host that is not the engine (`.external`: a terminal `brahma run`, here `h1`, owns the processes)
    /// signals nothing and writes nothing on `forceStop`; the other engine's running turn stays running.
    @Test func forceStopWhenNotTheEngineSignalsNothing() async throws {
        let (store, paths) = try makeHome()
        let (acme, ceo, _, _) = try seedAcme(store, paths)
        try dmCeo(store, acme)
        let h1 = host(paths, store, StubRunner(mode: .hangUntilCancelled)), h2 = host(paths, store)
        await h1.start(tools: tools)
        try await eventually { try store.agent(id: ceo.id)?.state == .running }
        await h2.start(tools: tools)
        #expect(h2.status == .external)
        #expect(h2.forceStop() == nil)
        #expect(try store.agent(id: ceo.id)?.state == .running, "the other engine's turn is untouched")
        #expect(try store.lastTurn(agentId: ceo.id)?.outcome == .inProgress)
        let stopped = host(paths, store)
        #expect(stopped.status == .stopped && stopped.forceStop() == nil)
        await h2.stop()
        await h1.stop()
        #expect(try store.agent(id: ceo.id)?.state == .ready)
    }
}
