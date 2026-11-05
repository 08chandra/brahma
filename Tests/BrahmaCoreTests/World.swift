import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// The in-turn stop poll's sleeper for orchestrator tests (Task 7c fix round 1, I2): a wait ends only when a test calls
/// `step()` (one waiter per step) or the wait is cancelled, so no World test runs a wall-clock poll. `waiting` lets a test
/// wait until a poll is parked, on an event, not a timer.
final class PollSteps: @unchecked Sendable {
    private let lock = NSLock()
    private var waiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    private var parked: [CheckedContinuation<Void, Never>] = []

    func sleep(_ duration: Duration) async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
                let (cancelled, notify) = lock.withLock { () -> (Bool, [CheckedContinuation<Void, Never>]) in
                    // Cancelled before it parked (the handler ran first and found nothing to end): ends at once.
                    if Task.isCancelled { return (true, []) }
                    waiters[id] = c
                    defer { parked.removeAll() }
                    return (false, parked)
                }
                if cancelled { c.resume(throwing: CancellationError()) }
                for p in notify { p.resume() }
            }
        } onCancel: {
            let c = lock.withLock { waiters.removeValue(forKey: id) }
            c?.resume(throwing: CancellationError())
        }
    }

    /// Ends every parked wait: each poll reads the stop once.
    func step() {
        let all = lock.withLock { () -> [CheckedContinuation<Void, any Error>] in
            defer { waiters.removeAll() }
            return Array(waiters.values)
        }
        for c in all { c.resume() }
    }

    /// Returns once at least one poll is parked.
    func waiting() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if !waiters.isEmpty { return true }
                parked.append(c)
                return false
            }
            if now { c.resume() }
        }
    }
}

/// A store, router, fake runner and orchestrator on a throwaway home, for orchestrator-level tests.
struct World {
    let store: Store
    let router: MessageRouter
    let clock = TestClock()
    let fake = FakeTurnRunner()
    let checks = FakeCheckRunner()
    /// The in-turn stop poll: parked until a test steps it (I2).
    let stopPoll = PollSteps()
    let paths: BrahmaPaths
    let orchestrator: Orchestrator

    /// The owner's home the sandboxed turns' scopes protect: a temp dir, never the real one.
    let userHome: URL

    init(store: Store? = nil, config: SchedulerConfig = World.config(), memory: (any MemoryPressureSource)? = nil,
         checkEnvironment: [String: String]? = nil, checkRunner: (any CheckRunning)? = nil,
         planSelector: @escaping @Sendable (Agent, WorkItem, Company) -> Bool = { _, _, _ in false },
         vault: any SecretVault = MemoryVault(), profile: PermissionProfile? = nil,
         transcriptSource: TranscriptSource? = nil, sleepGuard: SleepGuard = .disabled,
         canSeeSandboxes: @escaping @Sendable () -> Bool = { true }, sandboxCanary: SandboxCanaryGate? = nil,
         stopObservers: [any EmergencyStopObserver] = []) throws {
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
                                    sleepGuard: sleepGuard, sandboxCanary: sandboxCanary, stopObservers: stopObservers,
                                    stopPollSleep: stopPoll.sleep)
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
        try await orchestrator.waitUntilIdle(timeout: .seconds(300))
    }
}
