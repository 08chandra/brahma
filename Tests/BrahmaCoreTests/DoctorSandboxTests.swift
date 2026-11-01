import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// A canary whose verdict the test sets: every item passes, or `sandbox-canary` fails. Records the shapes it was asked about.
private final class FakeCanary: SandboxCanaryRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var _passes: Bool
    private var _shapes: [String] = []
    init(passes: Bool) { _passes = passes }
    var passes: Bool { get { lock.withLock { _passes } } set { lock.withLock { _passes = newValue } } }
    var shapes: [String] { lock.withLock { _shapes } }

    func run(paths: BrahmaPaths, claudePath: String, runner: any TurnRunning, shape: String) async -> [DoctorItem] {
        let ok = lock.withLock { _shapes.append(shape); return _passes }
        return [DoctorItem(name: "sandbox-backend", status: .pass, detail: "fake"),
                DoctorItem(name: "sandbox-canary", status: ok ? .pass : .fail, detail: ok ? "fake pass" : "fake leak"),
                DoctorItem(name: "sandbox-helpers", status: .pass, detail: "fake")]
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

    init(passes: Bool) throws {
        let canary = FakeCanary(passes: passes)
        let claude = try fakeClaude()
        self.canary = canary; self.claude = claude
        var gate = SandboxCanaryGate(canary: canary, runner: FakeTurnRunner(), claudePath: claude.path, retryAfter: 0)
        gate.fingerprintCacheSeconds = 0
        world = try World(sandboxCanary: gate)
        sandboxed = try world.company("Vault", profile: .sandboxed)
        eng = try world.store.hire(companyId: sandboxed.id, name: "eng-1", role: "engineer", model: "sonnet")
    }

    func requests(_ a: Agent) -> [TurnRequest] { world.fake.requests.filter { $0.agent.id == a.id } }
    func rows() throws -> Int { try world.store.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM sandboxCanary") ?? 0 } }
    func turnOnce() async throws {
        try world.dm(sandboxed, eng, "go")
        try await world.cycle()
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

    @Test func newSettingsShapeRequiresCanary() async throws {
        let g = try GateWorld(passes: true)
        var plain = ClaudeSettings()
        plain.disableBundledSkills = true
        var hooked = plain
        hooked.hooks = ["PostToolUse": [HookMatcher(matcher: "Bash", hooks: [HookCommand(command: "/usr/local/bin/brahma", args: ["hook"])])]]
        #expect(plain.shape() != hooked.shape(), "a hook added is a new shape")
        let fp = try CLIFingerprint.of(claudePath: g.claude.path)
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        try g.world.store.recordCanary(SandboxCanaryKey(fingerprint: fp.key, shape: plain.shape(), osVersion: os), detail: "test")
        #expect(try g.world.store.sandboxVerified(fingerprint: fp.key, shape: plain.shape(), osVersion: os))
        #expect(try !g.world.store.sandboxVerified(fingerprint: fp.key, shape: hooked.shape(), osVersion: os))
        var gate = SandboxCanaryGate(canary: g.canary, runner: FakeTurnRunner(), claudePath: g.claude.path, retryAfter: 0)
        gate.fingerprintCacheSeconds = 0
        try await g.world.orchestrator.requireSandboxVerified(gate: gate, shape: plain.shape(), agent: g.eng, company: g.sandboxed)
        await #expect(throws: SandboxNotVerified.self) {
            try await g.world.orchestrator.requireSandboxVerified(gate: gate, shape: hooked.shape(), agent: g.eng, company: g.sandboxed)
        }
        try await g.world.orchestrator.waitUntilIdle(timeout: .seconds(30))
        #expect(g.canary.shapes == [hooked.shape()])
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

    /// Until the owner's ruling is built, the production canary never passes, so nothing is recorded and the gate stays shut.
    @Test func productionCanaryIsPendingOwner() async throws {
        let root = try tempDir()
        let paths = BrahmaPaths(home: root.appending(path: "home"), workspaces: root.appending(path: "ws"))
        let userHome = root.appending(path: "user")
        try FileManager.default.createDirectory(at: userHome, withIntermediateDirectories: true)
        let canary = SandboxCanary(environment: SandboxEnvironment(userHome: userHome, darwinUserTemp: nil, shell: "/bin/zsh"),
                                   hookExecutable: "/usr/local/bin/brahma")
        let items = await canary.run(paths: paths, claudePath: try fakeClaude().path, runner: FakeTurnRunner(), shape: "s")
        #expect(Set(items.map(\.name)) == ["sandbox-backend", "sandbox-canary", "sandbox-helpers"])
        #expect(!items.allSatisfy { $0.status == .pass })
        let item = try #require(items.first { $0.name == "sandbox-canary" })
        #expect(item.status == .warn); #expect(item.detail.contains(SandboxCanary.pendingOwnerDecision))
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
}
