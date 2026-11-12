import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// A canary whose verdict the test sets: every item passes, or `sandbox-canary` fails. Records the shapes it was asked about
/// (and whether it was given the asking turn's settings). It verifies the key it was asked about, or, with `verifiedShape`
/// set, a different shape (I3).
private final class FakeCanary: SandboxCanaryRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _passes: Bool
    private var _shapes: [String] = []
    private var _settingsShapes: [String?] = []
    private var _verifiedShape: String?
    private var _hold: (@Sendable () async -> Void)?
    init(passes: Bool) { _passes = passes }
    /// Awaited before each run reports: lets a test hold the canary until the agents it is about are all waiting for it.
    var hold: (@Sendable () async -> Void)? { get { lock.withLock { _hold } } set { lock.withLock { _hold = newValue } } }
    var passes: Bool { get { lock.withLock { _passes } } set { lock.withLock { _passes = newValue } } }
    var verifiedShape: String? { get { lock.withLock { _verifiedShape } } set { lock.withLock { _verifiedShape = newValue } } }
    var shapes: [String] { lock.withLock { _shapes } }
    var settingsShapes: [String?] { lock.withLock { _settingsShapes } }

    func run(paths: BrahmaPaths, claudePath: String, runner: any TurnRunning, key: SandboxCanaryKey,
             settings: ClaudeSettings?) async -> CanaryRun {
        let (ok, other) = lock.withLock {
            _shapes.append(key.shape); _settingsShapes.append(settings?.shape())
            return (_passes, _verifiedShape)
        }
        if let hold { await hold() }
        var verified = key
        if let other { verified.shape = other }
        return CanaryRun(items: [DoctorItem(name: "sandbox-backend", status: .pass, detail: "fake"),
                                 DoctorItem(name: "sandbox-canary", status: ok ? .pass : .fail, detail: ok ? "fake pass" : "fake leak"),
                                 DoctorItem(name: "sandbox-helpers", status: .pass, detail: "fake")],
                         verified: verified)
    }
}

/// The fake `claude` the gate fingerprints (a `stat`; it is never run). Its own body, so no other suite shares the inode.
private func fakeClaude() throws -> URL { try FakeTools.script("claude", "# DoctorSandboxTests fingerprint fixture\nexit 0") }

private struct GateWorld {
    let world: World
    let canary: FakeCanary
    let claude: URL
    let sandboxed: Company
    let eng: Agent

    init(passes: Bool, config: SchedulerConfig = World.config(), claudePath: String? = nil) throws {
        let canary = FakeCanary(passes: passes)
        let claude = try fakeClaude()
        self.canary = canary; self.claude = claude
        var gate = SandboxCanaryGate(canary: canary, runner: FakeTurnRunner(), claudePath: claudePath ?? claude.path, retryAfter: 0)
        gate.fingerprintCacheSeconds = 0
        world = try World(config: config, sandboxCanary: gate)
        sandboxed = try world.company("Vault", profile: .sandboxed)
        eng = try world.store.hire(companyId: sandboxed.id, name: "eng-1", role: "engineer", model: "sonnet")
    }

    func requests(_ a: Agent) -> [TurnRequest] { world.fake.requests.filter { $0.agent.id == a.id } }
    func rows() throws -> Int { try world.store.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sandboxCanary") ?? 0 } }
    func turnOnce() async throws {
        try world.dm(sandboxed, eng, "go")
        try await world.cycle()
    }

    /// A one-use read-free grant (a domain, `once`) the owner approved for `eng`.
    func oneUseGrant(_ domain: String = "once.example.com") throws -> Grant {
        let env = SandboxEnvironment(userHome: world.userHome, darwinUserTemp: nil, shell: "/bin/zsh")
        let tools = CompanyTools(store: world.store, companyId: sandboxed.id, agentId: eng.id)
        _ = try tools.call(name: "request_access", arguments: ["kind": .string("network_domain"), "value": .string(domain),
                                                               "reason": .string("I need it")])
        let ask = try #require(try world.store.asks(companyId: sandboxed.id).last { $0.kind == .grant })
        return try world.store.approveAccess(askId: ask.id, scope: .once, duration: .always, note: "ok", environment: env)
    }

    func grant(_ g: Grant) throws -> Grant {
        try #require(try world.store.grants(companyId: sandboxed.id, includeInactive: true).first { $0.id == g.id })
    }
}

@Suite(.scratch, .serialized) struct DoctorSandboxTests {
    @Test func canaryPassRecordsKey() async throws {
        let g = try GateWorld(passes: true)
        try await g.turnOnce()
        // The first sandboxed turn did not start: its key had no pass. The canary ran and its pass was recorded.
        #expect(g.requests(g.eng).isEmpty)
        #expect(g.canary.shapes.count == 1)
        #expect(try g.rows() == 1)
        let events = try g.world.store.events(afterId: 0, companyId: g.sandboxed.id).map(\.text)
        #expect(events.filter { $0.hasPrefix("sandbox not verified") }.count == 1)
        // Now the agent runs.
        try await g.turnOnce()
        #expect(g.requests(g.eng).count == 1)
        #expect(try g.world.turns(g.eng).last?.outcome == .succeeded)
        #expect(g.canary.shapes.count == 1, "a recorded key needs no new canary")
    }

    @Test func canaryFailureBlocksSandboxedTurns() async throws {
        let g = try GateWorld(passes: false)
        let open = try g.world.company("Open", profile: .workspace)
        let dev = try g.world.store.hire(companyId: open.id, name: "dev-1", role: "engineer", model: "sonnet")
        try g.world.dm(open, dev, "go")
        try await g.turnOnce()
        try await g.turnOnce()
        #expect(g.requests(g.eng).isEmpty, "a sandboxed agent never starts while its canary fails")
        #expect(try g.rows() == 0)
        // The pinned sandbox-check alert, keyed the way the app's banner looks for it.
        let alerts = try g.world.store.asks(companyId: g.sandboxed.id).filter {
            $0.kind == .engineAlert && $0.subjectId == EngineAlerts.askSubject(reason: EngineAlerts.sandboxCheckReason)
        }
        #expect(alerts.count == 1)
        // The Workspace company keeps running.
        #expect(g.requests(dev).count >= 1)
        #expect(try g.world.turns(dev).contains { $0.outcome == .succeeded })
        // Once the canary passes, the alert answers itself and the agent runs.
        g.canary.passes = true
        try await g.turnOnce()
        try await g.turnOnce()
        #expect(try g.rows() == 1)
        #expect(g.requests(g.eng).count == 1)
        let still = try g.world.store.asks(companyId: g.sandboxed.id).filter {
            $0.kind == .engineAlert && $0.subjectId == EngineAlerts.askSubject(reason: EngineAlerts.sandboxCheckReason) && $0.status == .pendingOwner
        }
        #expect(still.isEmpty)
    }

    @Test func fingerprintChangeRequiresNewCanary() async throws {
        let g = try GateWorld(passes: true)
        try await g.turnOnce()
        try await g.turnOnce()
        #expect(g.requests(g.eng).count == 1)
        let before = try CLIFingerprint.of(claudePath: g.claude.path)
        // A new CLI build: the fake claude's mtime changes.
        try FileManager.default.setAttributes([.modificationDate: Date(timeIntervalSinceNow: -86_400)], ofItemAtPath: g.claude.path)
        let after = try CLIFingerprint.of(claudePath: g.claude.path)
        #expect(before.key != after.key)
        try await g.turnOnce()
        #expect(g.requests(g.eng).count == 1, "blocked until the new build passed")
        #expect(g.canary.shapes.count == 2)
        try await g.turnOnce()
        #expect(g.requests(g.eng).count == 2)
        #expect(try g.rows() == 2)
    }

    /// The owner's probe file is part of the key: editing it needs a new canary pass before sandboxed agents run again.
    @Test func probeFileEditRequiresNewCanary() async throws {
        let g = try GateWorld(passes: true)
        let probes = CanaryProbes.url(paths: g.world.paths)
        try BrahmaPaths.ensurePrivateDirectory(probes.deletingLastPathComponent())
        try Data("cat \"$CANARY_HOME_FILE\"\n".utf8).write(to: probes)
        #expect(chmod(probes.path, 0o600) == 0)
        try await g.turnOnce()
        try await g.turnOnce()
        #expect(g.requests(g.eng).count == 1)
        #expect(g.canary.shapes.count == 1)
        // The owner edits the file (same place, same mode): a new key.
        try Data("cat \"$CANARY_DATA_FILE\"\n".utf8).write(to: probes)
        try await g.turnOnce()
        #expect(g.requests(g.eng).count == 1, "blocked until the edited probe file passed")
        #expect(g.canary.shapes.count == 2)
        try await g.turnOnce()
        #expect(g.requests(g.eng).count == 2)
        #expect(try g.rows() == 2)
    }

    /// The production canary in the per-launch gate without a probe file: the agent never starts, nothing is recorded, and the
    /// pinned sandbox-check alert names the reason.
    @Test func missingProbeFileBlocksAndTheAlertSaysWhy() async throws {
        let claude = try fakeClaude()
        let userHome = try tempDir()
        let canary = SandboxCanary(environment: SandboxEnvironment(userHome: userHome, darwinUserTemp: nil, shell: "/bin/zsh"),
                                   hookExecutable: "/usr/local/bin/brahma")
        let turns = FakeTurnRunner()
        var gate = SandboxCanaryGate(canary: canary, runner: turns, claudePath: claude.path, retryAfter: 0)
        gate.fingerprintCacheSeconds = 0
        let world = try World(sandboxCanary: gate)
        let company = try world.company("Vault", profile: .sandboxed)
        let eng = try world.store.hire(companyId: company.id, name: "eng-1", role: "engineer", model: "sonnet")
        try world.dm(company, eng, "go")
        try await world.cycle()
        try await world.orchestrator.waitUntilIdle(timeout: .seconds(300))
        #expect(world.fake.requests.filter { $0.agent.id == eng.id }.isEmpty)
        #expect(turns.requests.isEmpty, "no canary turn without a probe file")
        #expect(try await world.store.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sandboxCanary") ?? 0 } == 0)
        let alerts = try world.store.asks(companyId: company.id).filter {
            $0.kind == .engineAlert && $0.subjectId == EngineAlerts.askSubject(reason: EngineAlerts.sandboxCheckReason)
        }
        #expect(alerts.count == 1)
        let events = try world.store.events(afterId: 0, companyId: company.id).map(\.text)
        #expect(events.contains { $0.hasPrefix("Sandbox check failed") && $0.contains("no probes in") }, "\(events)")
    }

    @Test func newSettingsShapeRequiresCanary() async throws {
        let g = try GateWorld(passes: true)
        var plain = ClaudeSettings()
        plain.disableBundledSkills = true
        var hooked = plain
        hooked.hooks = ["PostToolUse": [HookMatcher(matcher: "Bash", hooks: [HookCommand(command: "/usr/local/bin/brahma", args: ["hook"])])]]
        #expect(plain.shape() != hooked.shape(), "a hook added is a new shape")
        let fp = try CLIFingerprint.of(claudePath: g.claude.path)
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        // The gate's key: the CLI build and the probe file (absent here), as `CanaryProbes.keyFingerprint` folds them.
        let keyed = CanaryProbes.keyFingerprint(cli: fp.key, probes: CanaryProbes.digest(paths: g.world.paths))
        try g.world.store.recordCanary(SandboxCanaryKey(fingerprint: keyed, shape: plain.shape(), osVersion: os), detail: "test")
        #expect(try g.world.store.sandboxVerified(fingerprint: keyed, shape: plain.shape(), osVersion: os))
        #expect(try !g.world.store.sandboxVerified(fingerprint: keyed, shape: hooked.shape(), osVersion: os))
        var gate = SandboxCanaryGate(canary: g.canary, runner: FakeTurnRunner(), claudePath: g.claude.path, retryAfter: 0)
        gate.fingerprintCacheSeconds = 0
        try await g.world.orchestrator.requireSandboxVerified(gate: gate, settings: plain, agent: g.eng, company: g.sandboxed)
        await #expect(throws: SandboxNotVerified.self) {
            try await g.world.orchestrator.requireSandboxVerified(gate: gate, settings: hooked, agent: g.eng, company: g.sandboxed)
        }
        try await g.world.orchestrator.waitUntilIdle(timeout: .seconds(300))
        #expect(g.canary.shapes == [hooked.shape()])
        #expect(g.canary.settingsShapes == [hooked.shape()], "the canary is given the asking turn's settings (I3)")
    }

    /// The production canary's turn is built by the real scope and compiler: its settings deny reading the owner's home, the
    /// data home and the other company's workspace; everything planted is removed afterwards.
    @Test func canaryUsesRealScope() async throws {
        let root = try tempDir()
        let paths = BrahmaPaths(home: root.appending(path: "home"), workspaces: root.appending(path: "ws"))
        let userHome = root.appending(path: "user")
        try FileManager.default.createDirectory(at: userHome, withIntermediateDirectories: true)
        let env = SandboxEnvironment(userHome: userHome, darwinUserTemp: nil, shell: "/bin/zsh")
        let p = try SandboxCanary.prepare(paths: paths, environment: env, hookExecutable: "/usr/local/bin/brahma")
        let file = try #require(p.request.settingsFilePath)
        let written = try JSONDecoder().decode(ClaudeSettings.self, from: Data(contentsOf: URL(fileURLWithPath: file)))
        #expect(written == p.settings)
        let denyRead = Set(written.sandbox?.filesystem?.denyRead ?? [])
        for dir in [userHome, paths.home, p.otherCompany] {
            #expect(denyRead.contains(dir.path) || denyRead.contains(dir.resolvedForSandbox.path), "\(dir.path)")
        }
        #expect(SandboxCanary.missingDenies(p, paths: paths, environment: env).isEmpty)
        #expect(written.hooks?["PreToolUse"] != nil, "the pre-tool hook is on")
        #expect(p.request.profile == .sandboxed)
        try TurnProfileCompiler.validate(TurnProfileCompiler.profile(for: p.request))
        for token in [p.userHomeToken, p.dataHomeToken, p.otherCompanyToken] {
            #expect(try String(contentsOf: token, encoding: .utf8) == p.token)
        }
        p.cleanup()
        for url in [p.userHomeToken, p.dataHomeToken, p.otherCompanyToken, URL(fileURLWithPath: file)] {
            #expect(!FileManager.default.fileExists(atPath: url.path), "\(url.path)")
        }
        #expect(!FileManager.default.fileExists(atPath: p.request.company.workspacePath))
    }

    /// Without the owner's probe file the production canary never passes (fail closed), so nothing is recorded and the gate
    /// stays shut; no model turn runs.
    @Test func productionCanaryWithoutProbeFileStaysBlocked() async throws {
        let root = try tempDir()
        let paths = BrahmaPaths(home: root.appending(path: "home"), workspaces: root.appending(path: "ws"))
        let userHome = root.appending(path: "user")
        try FileManager.default.createDirectory(at: userHome, withIntermediateDirectories: true)
        let canary = SandboxCanary(environment: SandboxEnvironment(userHome: userHome, darwinUserTemp: nil, shell: "/bin/zsh"),
                                   hookExecutable: "/usr/local/bin/brahma")
        let claude = try fakeClaude().path
        let key = SandboxCanaryKey(fingerprint: try CLIFingerprint.of(claudePath: claude).key, shape: "s",
                                   osVersion: ProcessInfo.processInfo.operatingSystemVersionString)
        let runner = FakeTurnRunner()
        let run = await canary.run(paths: paths, claudePath: claude, runner: runner, key: key, settings: nil)
        #expect(!run.passes(key))
        #expect(run.verified.map { !run.passes($0) } ?? true)
        let items = run.items
        #expect(Set(items.map(\.name)) == ["sandbox-backend", "sandbox-canary-local", "sandbox-canary", "sandbox-helpers"])
        #expect(!items.allSatisfy { $0.status == .pass })
        let item = try #require(items.first { $0.name == "sandbox-canary" })
        #expect(item.status == .warn); #expect(item.detail.hasPrefix("no probes in"), "the engine wrote the template: \(item.detail)")
        #expect(runner.requests.isEmpty)
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: paths.workspaces.path)) ?? []
        #expect(leftovers.isEmpty, "\(leftovers)")
    }

    @Test func turnPidRecorded() async throws {
        let w = try World()
        let c = try w.company("Acme", profile: .workspace)
        let a = try w.hire(c, "eng-1")
        w.fake.script(a.name, FakeTurnRunner.Script(events: [
            .spawned(pid: 4242),
            .initialized(sessionId: a.sessionId, model: "sonnet"),
            .result(TurnResult(isError: false, subtype: "success", text: "done", costUSD: 0.01, apiErrorStatus: nil, sessionId: a.sessionId)),
        ]))
        try w.dm(c, a)
        try await w.cycle()
        let turn = try #require(try w.turns(a).last)
        #expect(turn.pid == 4242)
        #expect(turn.outcome == .succeeded)
        #expect(try w.store.runningTurnPids().isEmpty, "an ended turn no longer counts")
    }

    // MARK: Fix round 1

    /// I1: an agent held by the gate takes no scheduler slot, so a Workspace company runs even when the held agents would
    /// otherwise fill every free slot.
    @Test func heldSandboxedAgentsDoNotStarveWorkspaceCompanies() async throws {
        let g = try GateWorld(passes: false, config: World.config(hardCap: 1))
        try await g.turnOnce()
        #expect(g.requests(g.eng).isEmpty)
        #expect(g.canary.shapes.count == 1, "the sandboxed agent's turn was gated: it is held from now on")
        let open = try g.world.company("Zed", profile: .workspace)
        let dev = try g.world.store.hire(companyId: open.id, name: "dev-1", role: "engineer", model: "sonnet")
        try g.world.dm(open, dev, "go")
        try g.world.dm(g.sandboxed, g.eng, "still there?")
        try await g.world.cycle()
        #expect(g.requests(dev).count == 1, "the Workspace agent gets the only slot on the first tick")
        #expect(g.requests(g.eng).isEmpty)
    }

    /// I2: the gate runs before the turn spends anything: a held turn keeps its one-use grant, and once the canary passed the
    /// turn that runs spends it, once.
    @Test func heldTurnKeepsItsOneUseGrant() async throws {
        let g = try GateWorld(passes: false)
        let grant = try g.oneUseGrant()
        try await g.turnOnce()
        try await g.turnOnce()
        #expect(g.requests(g.eng).isEmpty)
        var kept = try g.grant(grant)
        #expect(kept.usesLeft == 1); #expect(kept.useCount == 0)
        g.canary.passes = true
        try await g.turnOnce()
        try await g.turnOnce()
        #expect(g.requests(g.eng).count == 1)
        #expect(g.requests(g.eng).first?.sandbox?.network.allowedDomains.contains("once.example.com") == true)
        kept = try g.grant(grant)
        #expect(kept.usesLeft == 0); #expect(kept.useCount == 1)
    }

    /// I2: a turn that spent its one-use grants and then did not start (the runner failed before any event) gives them back.
    @Test func turnThatDoesNotStartGivesItsGrantsBack() async throws {
        let g = try GateWorld(passes: true)
        try await g.turnOnce()
        try await g.turnOnce()
        #expect(g.requests(g.eng).count == 1)
        let grant = try g.oneUseGrant()
        g.world.fake.script(g.eng.name, FakeTurnRunner.Script(events: [], error: TurnError.earlierTurnStillRunning(pids: [])))
        try await g.turnOnce()
        #expect(g.requests(g.eng).count == 2, "the request reached the runner")
        let kept = try g.grant(grant)
        #expect(kept.usesLeft == 1); #expect(kept.useCount == 0)
    }

    /// I3: a canary that verified a different shape than the asked key records nothing, and the turn stays held.
    @Test func canaryOfAnotherShapeRecordsNothing() async throws {
        let g = try GateWorld(passes: true)
        g.canary.verifiedShape = "some-other-shape"
        try await g.turnOnce()
        try await g.turnOnce()
        #expect(g.canary.shapes.count >= 1)
        #expect(try g.rows() == 0, "no row for the asked key")
        #expect(g.requests(g.eng).isEmpty)
        let asked = try #require(g.canary.shapes.first)
        let fp = try CLIFingerprint.of(claudePath: g.claude.path)
        #expect(try !g.world.store.sandboxVerified(fingerprint: fp.key, shape: asked,
                                                    osVersion: ProcessInfo.processInfo.operatingSystemVersionString))
        // The same canary verifying the asked key does record it.
        g.canary.verifiedShape = nil
        try await g.turnOnce()
        try await g.turnOnce()
        #expect(try g.rows() == 1)
        #expect(g.requests(g.eng).count == 1)
    }

    /// Final review M1: no canary starts while the owner's stop holds (a failing key is retried every tick here, retryAfter 0);
    /// after the resume it runs again.
    @Test func noCanaryStartsWhileStopped() async throws {
        let g = try GateWorld(passes: false)
        try await g.turnOnce()
        #expect(g.canary.shapes.count == 1)
        try g.world.store.emergencyStop(note: nil, by: "owner", now: g.world.clock.now)
        try await g.world.cycle(); try await g.world.cycle(); try await g.world.cycle()
        #expect(g.canary.shapes.count == 1, "a canary ran while stopped")
        try g.world.store.resumeAfterStop(now: g.world.clock.now)
        try await g.world.cycle()
        #expect(g.canary.shapes.count == 2, "the waiting agent's canary runs again after the resume")
    }

    /// Final review M1: a canary running when the owner presses stop is cancelled by the next tick; it is recorded neither as
    /// a pass nor as a failure (no alert), and runs again after the resume.
    @Test func stopCancelsARunningCanary() async throws {
        let g = try GateWorld(passes: true)
        let store = g.world.store, now = g.world.clock.now
        let cancelled = CallCounter()
        g.canary.hold = {
            // The owner presses stop while the canary runs; it then runs until it is cancelled (bounded).
            try? store.emergencyStop(note: nil, by: "owner", now: now)
            let deadline = AwakeTime.deadline(after: .seconds(120))
            while !Task.isCancelled, AwakeTime.now < deadline { try? await AwakeTime.sleep(for: .milliseconds(10)) }
            if Task.isCancelled { cancelled.mark() }
        }
        try g.world.dm(g.sandboxed, g.eng, "go")
        let orchestrator = g.world.orchestrator
        await orchestrator.tick()
        let deadline = AwakeTime.deadline(after: .seconds(120))
        while try store.engineStopped() == nil, AwakeTime.now < deadline { try await AwakeTime.sleep(for: .milliseconds(10)) }
        await orchestrator.tick()
        try await orchestrator.waitUntilIdle(timeout: .seconds(300))
        #expect(cancelled.isSet, "the stop did not cancel the running canary")
        #expect(try g.rows() == 0, "a canary cut short by the stop was recorded")
        let alerts = try store.asks(companyId: g.sandboxed.id).filter {
            $0.kind == .engineAlert && $0.subjectId == EngineAlerts.askSubject(reason: EngineAlerts.sandboxCheckReason)
        }
        #expect(alerts.isEmpty, "a canary cut short by the stop raised the sandbox-check alert")
        // After the resume it runs to the end and the agent starts.
        g.canary.hold = nil
        try store.resumeAfterStop(now: g.world.clock.now)
        try await g.turnOnce()
        try await g.turnOnce()
        #expect(try g.rows() == 1)
        #expect(g.requests(g.eng).count == 1)
    }

    /// M7: two agents waiting for the same key cause one canary run.
    @Test func twoAgentsOfOneKeyRunOneCanary() async throws {
        let g = try GateWorld(passes: true)
        let eng2 = try g.world.store.hire(companyId: g.sandboxed.id, name: "eng-2", role: "engineer", model: "sonnet")
        // The two turns' gates run concurrently: the canary is held until BOTH agents wait for its key (an event on the
        // engine, not a timing guess), so neither gate can see the pass early, whichever of them asked first. The hold is
        // bounded: past the backstop the canary reports anyway and the assertions below fail.
        let orchestrator = g.world.orchestrator
        g.canary.hold = {
            let deadline = AwakeTime.deadline(after: .seconds(120))
            while await orchestrator.canaryWaiting.count < 2, AwakeTime.now < deadline { try? await AwakeTime.sleep(for: .milliseconds(10)) }
        }
        try g.world.dm(g.sandboxed, eng2, "go")
        try await g.turnOnce()
        #expect(g.canary.shapes.count == 1)
        #expect(Set(g.canary.shapes).count == 1)
        #expect(g.requests(g.eng).isEmpty && g.requests(eng2).isEmpty, "both agents waited for the one canary")
        g.canary.hold = nil
        try g.world.dm(g.sandboxed, eng2, "go on")
        try await g.turnOnce()
        #expect(g.requests(g.eng).count == 1); #expect(g.requests(eng2).count == 1)
        #expect(g.canary.shapes.count == 1, "both agents ran on the one pass")
    }

    /// M7: a CLI that cannot be fingerprinted (missing) fails the turn; it never launches it.
    @Test func missingCLIFailsTheTurn() async throws {
        let missing = try tempDir().appending(path: "no-claude").path
        let g = try GateWorld(passes: true, claudePath: missing)
        try await g.turnOnce()
        #expect(g.requests(g.eng).isEmpty)
        #expect(g.canary.shapes.isEmpty, "no canary for a CLI that is not there")
        let turn = try #require(try g.world.turns(g.eng).last)
        #expect(turn.outcome != .succeeded); #expect(turn.outcome != .inProgress)
        #expect(try g.rows() == 0)
    }

    /// M2: a pass answers the sandbox-check alert only when asked to (the gate does not while another key is failing).
    @Test func recordCanaryResolvesTheAlertOnlyWhenAsked() throws {
        let store = try Store.inMemory()
        _ = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        func open() throws -> Int {
            try store.writer.read { db in
                try Ask.filter(Column("kind") == AskKind.engineAlert && Column("status") == AskStatus.pendingOwner.rawValue
                               && Column("subjectId") == EngineAlerts.askSubject(reason: EngineAlerts.sandboxCheckReason)).fetchCount(db)
            }
        }
        try EngineAlerts.raise(store: store, text: "Sandbox check failed", now: Date(), reason: EngineAlerts.sandboxCheckReason)
        #expect(try open() >= 1)
        try store.recordCanary(SandboxCanaryKey(fingerprint: "a", shape: "s", osVersion: "o"), detail: "t", resolveAlert: false)
        #expect(try open() >= 1)
        try store.recordCanary(SandboxCanaryKey(fingerprint: "b", shape: "s", osVersion: "o"), detail: "t")
        #expect(try open() == 0)
    }

    /// M6: an interrupted canary's throwaway places go at engine start; a fresh one (a canary running now) and anything not
    /// named like one stay, and a link is removed, never followed.
    @Test func staleCanaryLeftoversAreSwept() throws {
        let root = try tempDir()
        let paths = BrahmaPaths(home: root.appending(path: "home"), workspaces: root.appending(path: "ws"))
        let userHome = root.appending(path: "user")
        let fm = FileManager.default
        for d in [paths.workspaces, paths.runDir, userHome] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        let outside = root.appending(path: "outside")
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outside.appending(path: "keep.txt"))
        let stale = [paths.workspaces.appending(path: ".brahma-canary-1"), paths.runDir.appending(path: "canary-1"),
                     userHome.appending(path: ".brahma-canary-1")]
        for d in stale { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        try Data("t".utf8).write(to: stale[0].appending(path: "token"))
        let link = userHome.appending(path: ".brahma-canary-link")
        try fm.createSymbolicLink(at: link, withDestinationURL: outside)
        let unrelated = paths.workspaces.appending(path: "acme")
        try fm.createDirectory(at: unrelated, withIntermediateDirectories: true)
        // Fresh: nothing goes.
        #expect(SandboxCanary.sweepStale(paths: paths, userHome: userHome).isEmpty)
        // Two hours on: the stale ones go.
        let removed = SandboxCanary.sweepStale(paths: paths, userHome: userHome, now: Date().addingTimeInterval(7200))
        #expect(Set(removed) == Set((stale + [link]).map(\.path)))
        for d in stale + [link] { #expect(!fm.fileExists(atPath: d.path), "\(d.path)") }
        #expect(fm.fileExists(atPath: outside.appending(path: "keep.txt").path), "a link is removed, never followed")
        #expect(fm.fileExists(atPath: unrelated.path))
    }

    /// M9: a same-size copy with its modification time kept is a new fingerprint (its inode and ctime differ).
    @Test func sameSizeCopyWithMtimeKeptIsANewFingerprint() throws {
        let dir = try tempDir()
        let claude = dir.appending(path: "claude")
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: claude)
        let mtime = Date(timeIntervalSince1970: 1_700_000_000)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: claude.path)
        let before = try CLIFingerprint.of(claudePath: claude.path)
        let copy = dir.appending(path: "claude.new")
        try Data("#!/bin/sh\nexit 1\n".utf8).write(to: copy)
        try FileManager.default.setAttributes([.modificationDate: mtime], ofItemAtPath: copy.path)
        #expect(rename(copy.path, claude.path) == 0)
        let after = try CLIFingerprint.of(claudePath: claude.path)
        #expect(after.size == before.size); #expect(after.mtime == before.mtime)
        #expect(after.inode != before.inode)
        #expect(after.key != before.key)
    }
}
