import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// A store, router, fake runner and orchestrator on a throwaway home, for orchestrator-level tests.
struct World {
    let store: Store
    let router: MessageRouter
    let clock = TestClock()
    let fake = FakeTurnRunner()
    let checks = FakeCheckRunner()
    let paths: BrahmaPaths
    let orchestrator: Orchestrator

    /// The owner's home the sandboxed turns' scopes protect: a temp dir, never the real one.
    let userHome: URL

    init(store: Store? = nil, config: SchedulerConfig = World.config(), memory: (any MemoryPressureSource)? = nil,
         checkEnvironment: [String: String]? = nil, checkRunner: (any CheckRunning)? = nil,
         planSelector: @escaping @Sendable (Agent, WorkItem, Company) -> Bool = { _, _, _ in false },
         vault: any SecretVault = MemoryVault(), profile: PermissionProfile? = nil,
         transcriptSource: TranscriptSource? = nil, sleepGuard: SleepGuard = .disabled,
         canSeeSandboxes: @escaping @Sendable () -> Bool = { true }, previewDeps: PreviewDependencies = .fake()) throws {
        self.store = try store ?? Store.inMemory()
        try self.store.setPlanTier(.max20x)   // Plan 1 tests assume the 2/6/16 mode caps
        router = MessageRouter(store: self.store)
        let root = try tempDir()
        let worldPaths = BrahmaPaths(home: root.appending(path: "home"), workspaces: root.appending(path: "ws"))
        paths = worldPaths
        userHome = root.appending(path: "user")
        try FileManager.default.createDirectory(at: userHome, withIntermediateDirectories: true)
        orchestrator = Orchestrator(store: self.store, runner: fake, paths: paths, config: config,
                                    mcpExecutable: "/usr/local/bin/brahma", profile: profile,
                                    sandboxEnvironment: SandboxEnvironment(userHome: userHome, darwinUserTemp: nil, shell: "/bin/zsh",
                                                                          canSeeSandboxes: canSeeSandboxes),
                                    clock: clock.function,
                                    memory: memory ?? DispatchMemoryPressureSource(), checkRunner: checkRunner ?? checks,
                                    checkBaseEnvironment: checkEnvironment ?? ProcessInfo.processInfo.environment,
                                    planSelector: planSelector, vault: vault,
                                    transcripts: transcriptSource.map { TranscriptCapture(paths: worldPaths, source: $0, compressor: .gzip) },
                                    sleepGuard: sleepGuard, previewDeps: previewDeps)
    }

    static func config(hardCap: Int = 16, turnBudget: Int = 30) -> SchedulerConfig {
        var c = SchedulerConfig()
        c.hardCap = hardCap
        c.safetyCap = 64
        c.turnBudgetPerHour = turnBudget
        return c
    }

    /// 3a's orchestration tests run their companies on the Workspace profile; the Sandboxed profile (the default for new
    /// companies) has its own tests (`SandboxTurnTests`).
    func company(_ name: String, mode: UsageMode = .low, profile: PermissionProfile = .workspace) throws -> Company {
        var c = try store.createCompany(name: name, goal: "Ship it", workspacesRoot: paths.workspaces)
        c.usageMode = mode
        try store.updateCompany(c)
        if profile != c.permissionProfile {
            try store.updateSandbox(companyId: c.id, SandboxPatch(profile: profile), userHome: userHome)
        }
        return try store.company(id: c.id) ?? c
    }

    func hire(_ c: Company, _ name: String, role: String? = nil) throws -> Agent {
        try store.hire(companyId: c.id, name: name, role: role ?? name, model: "sonnet")
    }

    func agent(_ a: Agent) throws -> Agent { try #require(try store.agent(id: a.id)) }
    func pending(_ a: Agent) throws -> Int { try store.pendingInbox(agentId: a.id).count }

    func turns(_ a: Agent) throws -> [Turn] {
        try store.writer.read { db in
            try Turn.filter(Column("agentId") == a.id).order(Column("startedAt"), Column.rowID).fetchAll(db)
        }
    }

    func dm(_ c: Company, _ to: Agent, _ text: String = "please do it") throws {
        _ = try router.sendDM(companyId: c.id, from: .owner, to: to.name, text: text, now: clock.now)
    }

    /// One tick, then wait for every turn it started.
    func cycle() async throws {
        await orchestrator.tick()
        try await orchestrator.waitUntilIdle(timeout: .seconds(60))
    }
}
