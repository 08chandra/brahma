import Foundation
import GRDB

public enum OrchestratorError: Error, Equatable {
    case idleTimeout(running: Int)
    /// The engine started git on its actor or the cooperative pool instead of in a `Blocking` body (`EngineGitGuard`): the
    /// commands, as reported by `waitUntilIdle`.
    case gitOffBlocking([String])
}

/// Global scheduler: one per machine, across all companies. Each tick unblocks, applies the usage gate and
/// turn budget, then starts turns for the agents `Scheduler.select` picks; each turn runs as a child task.
public actor Orchestrator {
    let store: Store
    let runner: any TurnRunning
    let paths: BrahmaPaths
    let config: SchedulerConfig
    let mcpExecutable: String
    /// The environment each turn's MCP config is written from (`MCPConfig.write(environment:)`): only its
    /// `BRAHMA_SECRET_STORE=file` is read, and passed to the turn's `brahma mcp` so a dev/demo home's file vault reaches it.
    /// Defaults to this process's environment; a host (the live tests) passes its own instead of changing process state.
    let mcpEnvironment: [String: String]
    /// The engine's ceiling on every turn's profile (`brahma run --profile`): nil runs each turn under its company's profile
    /// for the agent's role (`turnProfile`); a value narrows it, never widens it.
    let profileCeiling: PermissionProfile?
    /// The owner's home, the xcrun temp dir and the shell the sandboxed turns' scopes and prefixes use.
    let sandboxEnvironment: SandboxEnvironment
    let clock: @Sendable () -> Date
    let memory: any MemoryPressureSource
    let connectivity: any ConnectivityProbe
    let disk: any DiskSpace
    let exec: Doctor.Exec
    let claudePath: String
    let checkRunner: any CheckRunning
    /// The environment engine-run checks are built from (filtered by `ChildEnvironment`, purpose `.check`).
    let checkBaseEnvironment: [String: String]
    /// Whether the next turn of an agent on its leased item is a plan turn (Plan-first selection arrives with Task 14c).
    /// Forces (or forbids) a plan turn for tests; nil: Plan-first is the mode policy's (compiled once probe V-4 passed).
    let planSelector: (@Sendable (Agent, WorkItem, Company) -> Bool)?
    /// What each turn asserts about the session the CLI reports (the work modes set it; nil asserts nothing).
    let turnExpectations: @Sendable (Agent, Company) -> TurnExpectations?
    let timerJobs: TimerJobRegistry
    /// Handlers run, per company, after a restore re-adopts that company's recorded `main` (`restoreMarkerTick`).
    let restoreHooks: RestoreHooks
    /// Where secret values live; read only to reload the store's redactor. Production passes the store `PlatformSecretVault`
    /// selected (the Keychain, or a dev/demo home's file store); the library default is `UnavailableVault`, never the Keychain.
    nonisolated let vault: any SecretVault
    /// Per-turn transcript capture (`TranscriptCapture`); nil: off (the library default, as for `vault`). The app and
    /// `brahma run` pass one reading the Claude CLI's real transcript directory.
    nonisolated let transcripts: TranscriptCapture?
    /// The per-launch sandbox gate (Task 3): no sandboxed turn starts until the canary passed for the CLI build, the turn's
    /// settings shape and the macOS version. Nil: no gate (a fake runner has no CLI to verify; `Orchestrator.init` sets one for
    /// the real runner unless the host passes its own).
    nonisolated let sandboxCanary: SandboxCanaryGate?
    /// Agent id → the canary key its last turn waited for: not launched again until that key passed.
    var canaryWaiting: [String: SandboxCanaryKey] = [:]
    /// Keys whose wait was logged (once per key), and when each key's last canary failed (awake seconds).
    var canaryLogged = Set<String>()
    var canaryFailedAt: [String: Double] = [:]
    /// How many canary runs in a row did not pass, per key: the retry delay doubles with each (`canaryRetryDelay`), so a key
    /// that keeps failing does not pay for a model turn every `retryAfter`.
    var canaryFailures: [String: Int] = [:]
    /// Key text → the compiled settings of the first turn that waited for it: what that key's canary run is given (I3).
    var canarySettings: [String: ClaudeSettings] = [:]
    /// The CLI fingerprint, re-read at most every `SandboxCanaryGate.fingerprintCacheSeconds`.
    var fingerprintCache: (value: CLIFingerprint, at: Double)?
    /// The canary probe file's digest (`CanaryProbes.digest`), re-read as often as the fingerprint.
    var probesDigestCache: (value: String, at: Double)?

    /// In-memory: turns this orchestrator has in flight, per company. The DB `running` state is the durable record.
    var runningByCompany: [String: Int] = [:]
    /// Agent id → its turn task.
    var tasks: [String: Task<Void, Never>] = [:] { didSet { resumeIdleWaitersIfIdle() } }
    /// Health work that must never block a tick (doctor re-probe, `claude --version`, HTTPS probe, disk checks).
    var healthTasks: [String: Task<Void, Never>] = [:] { didSet { resumeIdleWaitersIfIdle() } }
    var health = HealthState()
    /// Git work that must never block a tick: removing worktrees, the orphan sweep, creating a dispatched item's worktree.
    var gitTasks: [String: Task<Void, Never>] = [:] { didSet { resumeIdleWaitersIfIdle() } }
    /// Run id → its check task. Checks are child processes: they count in the safety cap next to turns.
    var checkTasks: [String: Task<Void, Never>] = [:] { didSet { resumeIdleWaitersIfIdle() } }
    /// Company id → its merge task (one approved item lands at a time per company). Merges are child processes too.
    var mergeTasks: [String: Task<Void, Never>] = [:] { didSet { resumeIdleWaitersIfIdle() } }
    /// The merge queue (Plan 4a Task 1b): lands the company's queued requests, one batch per company at a time. A stop observer.
    public nonisolated let mergeQueue: MergeQueue
    /// Companies whose last merge attempt did not land (HEAD not on main, git failed): not tried again before this time.
    var mergeBackoff: [String: Date] = [:]
    /// Company id → merge attempts in a row that failed for the company's own reasons (`MergeInfrastructureError`).
    var mergeFaults: [String: Int] = [:]
    /// Merge-check run id → times its export was put back in the queue for the company's fault (`maxMergeCheckDeferrals`).
    var mergeCheckDeferrals: [String: Int] = [:]
    /// Agents the engine has just leased an item to, until their worktree exists (they are not scheduled meanwhile).
    var dispatching = Set<String>()
    /// The restore marker last ignored and left in place (it could not be removed safely): it is logged once, not every tick.
    var ignoredRestoreMarker: String?
    /// Whether this process has already expired the stale restore events (`expireStaleRestoreEvents`).
    var staleRestoreEventsExpired = false
    /// Items whose dispatch failed in git: not offered again before this time.
    var dispatchBackoff: [String: Date] = [:]
    /// Companies whose `main` changed outside Brahma: no dispatch before this time.
    var mainBlocked: [String: Date] = [:]
    var lastDispatch: Date?
    /// Consecutive lease turns that could not start for want of a worktree, per item.
    var worktreeFailures: [String: Int] = [:]
    static let maxWorktreeFailures = 3
    /// Consecutive turns per agent the runner stopped before they ran because no exact record could name their process.
    var unrecordedTurns: [String: Int] = [:]
    static let maxUnrecordedTurns = 3
    /// The reason that keys the engine alert raised after `maxUnrecordedTurns` such turns in a row.
    static let unrecordedTurnReason = "turn-record"
    var lastSweep: [String: Date] = [:]
    /// Company-active time of each company's last deadlock/aging scan.
    var lastLiveness: [String: Double] = [:]
    /// Companies whose handbook skeleton this engine has ensured since it started.
    var handbookSkeletons: Set<String> = []
    /// Company-active time of each company's last handbook refresh (auto pages and the `.brahma/kb` mirror).
    var lastHandbookRefresh: [String: Double] = [:]
    private var lastPressure: MemoryPressure = .normal
    /// Agents whose last turn failed for infrastructure reasons: not eligible before this time (fixed 15 s).
    var infraCooldown: [String: Date] = [:]
    /// Companies whose weekly-pace closure has been logged (cleared when it reopens).
    var loggedPaceClosed = Set<String>()
    /// Timer jobs in flight, by timer id (a job never overlaps itself).
    var timerTasks: [String: Task<Void, Never>] = [:] { didSet { resumeIdleWaitersIfIdle() } }
    /// Plan C Task C4c: the owner lane's concierge runs in flight (by request id), and the lane that admits them.
    var conciergeTasks: [String: Task<Void, Never>] = [:] { didSet { resumeIdleWaitersIfIdle() } }
    nonisolated let ownerLane = OwnerLane()
    /// The background reload of the store's redactor (vault reads never run on the actor: `reloadSecretsIfDue`).
    var secretsTask: Task<Void, Never>? { didSet { resumeIdleWaitersIfIdle() } }
    /// C3b Ruling 48: the pass answering turns' gate requests (`Store.serveGateRequests`), off the actor; never overlaps itself.
    var gateTask: Task<Void, Never>? { didSet { resumeIdleWaitersIfIdle() } }
    /// When the tick last swept what failed shares left (`gateTick`).
    var lastShareSweep: Date?
    /// The companies whose system timers have been ensured; a change re-runs `SystemTimers.ensure`.
    var ensuredTimerCompanies: Set<String>?
    /// Phone alerts (Task 7b): one dispatcher for the engine's life, and its pass in flight (a pass never overlaps itself).
    nonisolated let pushDispatcher: PushDispatcher
    var pushTask: Task<Void, Never>? { didSet { resumeIdleWaitersIfIdle() } }
    /// The owner's emergency stop (Task 7c): what else a stop reaches (previews, deploys, merge queues, browsers, connectors).
    /// The release executor (Plan L Task 7) and the preview runner (L-5lite-A) are always among them.
    nonisolated let stopObservers: [any EmergencyStopObserver]
    /// How a running turn's supervision waits between its reads of the stop (awake time; tests inject their own).
    nonisolated let stopPollSleep: @Sendable (Duration) async throws -> Void
    /// Whether the last tick saw the stop, and the stop (its `since`) whose observers already ran: once per stop.
    var engineStoppedNow = false
    var stopObserved: Date?
    var stopObserverTask: Task<Void, Never>? { didSet { resumeIdleWaitersIfIdle() } }
    /// Plan L previews: the runner (one for the engine's life) and its reconcile pass in flight (`previewTick`).
    let previewRunner: PreviewRunner
    var previewTask: Task<Void, Never>? { didSet { resumeIdleWaitersIfIdle() } }
    /// Whether the last preview pass was a sprint-review demo (Plan 4a Task 7): demos and reconciles alternate.
    var lastPreviewTickWasDemo = false
    /// Plan L main smokes (`smokeTick`): what they run through, one slot per company shared with a release's smoke (PR-36),
    /// and the run in flight per company.
    nonisolated let smokeChecks: SmokeChecks
    public nonisolated let smokeSlots: SmokeSlots
    var smokeTasks: [String: Task<Void, Never>] = [:] { didSet { resumeIdleWaitersIfIdle() } }
    /// Company id → when its merge smoke, re-queued after the engine's own failure (an export), may start again.
    var smokeBackoff: [String: Date] = [:]
    /// Plan L releases (`releaseTick`): the one executor that carries out approved deploys (a stop observer too), and the
    /// release in progress per company. A release's own smoke on main runs inside its task, so it is tracked with it.
    public nonisolated let releaseExecutor: ReleaseExecutor
    var releaseTasks: [String: Task<Void, Never>] = [:] { didSet { resumeIdleWaitersIfIdle() } }

    static let usageRetry: TimeInterval = 15 * 60
    static let hour: TimeInterval = 3600

    public init(store: Store, runner: any TurnRunning, paths: BrahmaPaths, config: SchedulerConfig = .init(),
                mcpExecutable: String, profile: PermissionProfile? = nil, sandboxEnvironment: SandboxEnvironment = .current,
                clock: @escaping @Sendable () -> Date = { .now },
                memory: any MemoryPressureSource = DispatchMemoryPressureSource(),
                connectivity: any ConnectivityProbe = HTTPSProbe(), disk: any DiskSpace = SystemDiskSpace(),
                exec: @escaping Doctor.Exec = Doctor.defaultExec, claudePath: String = "claude",
                checkRunner: (any CheckRunning)? = nil,
                checkBaseEnvironment: [String: String] = ProcessInfo.processInfo.environment,
                planSelector: (@Sendable (Agent, WorkItem, Company) -> Bool)? = nil,
                turnExpectations: @escaping @Sendable (Agent, Company) -> TurnExpectations? = { _, _ in nil },
                timerJobs: TimerJobRegistry = .system,
                vault: any SecretVault = UnavailableVault(),
                pushChannel: (any PushChannel)? = nil,
                restoreHooks: RestoreHooks = RestoreHooks(),
                transcripts: TranscriptCapture? = nil,
                backupTools: BackupTools = .system,
                walSleeper: @escaping WALShipper.Sleeper = { try await AwakeTime.sleep(for: $0) },
                sleepGuard: SleepGuard = .disabled,
                sandboxCanary: SandboxCanaryGate? = nil,
                stopObservers: [any EmergencyStopObserver] = [],
                stopPollSleep: @escaping @Sendable (Duration) async throws -> Void = { try await AwakeTime.sleep(for: $0) },
                previewDeps: PreviewDependencies? = nil,
                smokeChecks: SmokeChecks? = nil,
                releaseDeps: ReleaseDependencies? = nil,
                mcpEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.stopPollSleep = stopPollSleep
        let engineBlocking = Blocking()
        self.blocking = engineBlocking
        let engineId = UUID().uuidString
        self.engineId = engineId
        let slots = SmokeSlots()
        self.smokeSlots = slots
        // Releases (Plan L): the executor runs its release smoke through the same entry as `runSmoke` (this engine's slot,
        // Blocking and clock), its steps through the platform sandbox by default (`defaultReleaseDependencies`).
        // The engine's ceiling (`profile`) reaches every main smoke, release build and preview as it reaches checks (B2),
        // whichever runners the host injected.
        var smokes = smokeChecks ?? Orchestrator.defaultSmokeChecks(store: store, paths: paths, environment: checkBaseEnvironment)
        smokes.ceiling = profile
        self.smokeChecks = smokes
        let releaseDeps = releaseDeps ?? Orchestrator.defaultReleaseDependencies(store: store, paths: paths)
        let executor = ReleaseExecutor(
            store: store, paths: paths, sandbox: releaseDeps.sandbox, unsandboxed: releaseDeps.unsandboxed, vault: vault, http: releaseDeps.http,
            smoke: Orchestrator.smokeEntry(store: store, checks: smokes, slots: slots, blocking: engineBlocking, clock: clock,
                                           engineId: engineId),
            adapters: releaseDeps.adapters, sleep: releaseDeps.sleep, clock: clock, blocking: engineBlocking,
            environment: releaseDeps.environment ?? checkBaseEnvironment, ceiling: profile)
        self.releaseExecutor = executor
        // Previews (Plan L): the platform sandbox with the checks' baseline by default (`defaultPreviewDependencies`).
        let previewDeps = previewDeps ?? Orchestrator.defaultPreviewDependencies(store: store, paths: paths)
        let previews = PreviewRunner(store: store, paths: paths, deps: previewDeps,
                                     sandboxLayout: { SandboxLayout(paths: paths, company: $0, agentHandle: "preview") },
                                     timeouts: PreviewTimeouts(), memory: { memory.current != .normal }, clock: clock,
                                     blocking: engineBlocking, environment: checkBaseEnvironment, ceiling: profile, adapters: previewDeps.adapters)
        self.previewRunner = previews
        // Checks run sandboxed by default (`SandboxedCheckRunner`; Seatbelt on macOS, fail closed elsewhere).
        let checkRunner = checkRunner ?? Orchestrator.defaultCheckRunner(store: store, paths: paths, ceiling: profile)
        // The merge queue (Plan 4a): it replaced 3a's one-item merge step. It shares this engine's `Blocking`, runs its checks
        // through the same sandboxed runner, and scans a candidate for its own company's known secret values only.
        let queue = MergeQueue(store: store, paths: paths, checks: checkRunner,
                               knownValues: { [store] in store.knownSecretValues(companyId: $0) },
                               clock: clock, blocking: engineBlocking, baseEnvironment: checkBaseEnvironment)
        self.mergeQueue = queue
        // The owner's stop reaches the release executor (its steps and smokes), every preview (L-5lite-A) and the merge queue too.
        self.stopObservers = stopObservers + [executor, previews, queue]
        self.backupTools = backupTools; self.walSleeper = walSleeper; self.sleepGuard = sleepGuard
        // The engine reads the vault only in the background: never a prompt, whichever vault the host passed.
        let vault = vault.nonInteractive()
        self.pushDispatcher = PushDispatcher(store: store, vault: vault, channel: pushChannel)
        self.timerJobs = timerJobs; self.vault = vault; self.restoreHooks = restoreHooks; self.transcripts = transcripts
        self.planSelector = planSelector
        self.turnExpectations = turnExpectations
        self.store = store; self.runner = runner; self.paths = paths; self.config = config
        self.mcpExecutable = mcpExecutable; self.profileCeiling = profile; self.clock = clock
        self.mcpEnvironment = mcpEnvironment
        self.sandboxEnvironment = sandboxEnvironment
        self.memory = memory; self.connectivity = connectivity; self.disk = disk; self.exec = exec
        self.claudePath = claudePath
        // The real CLI is always gated; a fake runner only when the host asks for it.
        self.sandboxCanary = sandboxCanary ?? (runner is ClaudeProcessRunner
            ? SandboxCanaryGate(canary: SandboxCanary(environment: sandboxEnvironment,
                                                      sandbox: Orchestrator.ownerSandboxRunner(store: store, paths: paths),
                                                      hookExecutable: mcpExecutable,
                                                      baseline: Orchestrator.ownerSandboxBaseline(store: store, paths: paths)),
                                runner: runner, claudePath: claudePath)
            : nil)
        self.checkRunner = checkRunner
        self.checkBaseEnvironment = checkBaseEnvironment
        // Plan ML: a restore resets every memory cursor (every company's: the whole database was swapped), a full idempotent
        // re-scan on the next ticks.
        restoreHooks.register(afterRestore: { _ in try MemoryIngest.resetCursors(store: store) })
        // Plan 4a Task 3: the engine's restore step re-affirms the record of a company whose `main` is exactly what the restored
        // database recorded (`takeUpRestore` runs the hooks for those only; a stale pending head goes, 3a's alert closes). It
        // adopts nothing else and never moves `main` (B6, I2: `adoptMain(by: .system)` re-affirms the live head only when it is
        // the record, else refuses): a head the restored database did not record is the main guard's to restore. Git: in a
        // Blocking body.
        let blocking = self.blocking
        restoreHooks.register(afterRestore: { event in
            guard let head = event.mainHead, try store.company(id: event.companyId)?.mainCommit == head else { return }
            _ = try await blocking.tryRun { try store.adoptMain(companyId: event.companyId, by: .system) }
        })
    }

    /// Crash recovery: turns left in progress by a previous run are interrupted; their agents return to ready.
    public func start() async throws {
        try await EngineGitGuard.$engine.withValue(engineId) {
            // Raise the descriptor limit so the egress proxies' pooled sockets cannot starve the engine's own files (A-I2).
            if let raised = FileLimit.raise() { log("file descriptor limit: \(raised)") }
            // The first load of the secrets, in a Blocking body (vault reads may block; never on the actor).
            let (store, vault) = (self.store, self.vault)
            let failure: String? = await blocking.run {
                do { try store.reloadRedactorIfNeeded(vault: vault); return nil } catch { return "\(error)" }
            }
            if let failure { log("could not load secrets: \(failure)") }
            // Plan C Task C4c: concierge runs an earlier engine left open end now (their credentials with them); their requests
            // stay open until they expire.
            attempt { try store.endOrphanConciergeRuns(now: clock()) }
            // The data home lies outside every workspace and its private directories are 0700 (Task 3).
            let paths = self.paths
            let workspaces = try store.companies().map(\.workspacePath)
            try await blocking.tryRun { try DataHomeGuard.validate(paths: paths, workspacePaths: workspaces) }
            // One that cannot be made private (a link, a file) is logged, never followed; the owner sees it in the log.
            if let problem = await blocking.run({ () -> String? in
                do { try DataHomeGuard.lockDown(paths: paths); return nil } catch { return "\(error)" }
            }) { log("data home: \(problem)") }
            // What an interrupted sandbox canary left (a crash mid-run): its throwaway company, tokens and run files (M6). Only
            // with a gate: without one no canary of this engine ever ran.
            if sandboxCanary != nil {
                let userHome = sandboxEnvironment.userHome
                for removed in await blocking.run({ SandboxCanary.sweepStale(paths: paths, userHome: userHome) }) {
                    log("removed a stale sandbox canary leftover: \(removed)")
                }
            }
            // The shell prefix's backstop: only an unsandboxed process can read it (the sandbox denies the data home).
            if let sentinel = await blocking.run({ () -> String? in
                do { try Sentinel.write(paths: paths); return nil } catch { return "\(error)" }
            }) { log("could not write the sandbox sentinel: \(sentinel)") }
            // What an earlier engine's turns left behind (it crashed or was killed mid-turn): every recorded leader's session
            // and group, and every sandboxed process carrying a recorded turn's marker (B-I1).
            let records = self.turnRecordDirectory
            let leftovers = await blocking.run { () -> [String: TurnLeftovers] in
                var out: [String: TurnLeftovers] = [:]
                for agentId in TurnRecords.agentIds(in: records) {
                    out[agentId] = (try? TurnRecords.reap(agentId: agentId, in: records)) ?? TurnLeftovers(survivors: [-1])
                }
                return out
            }
            for (agentId, left) in leftovers where !left.killed.isEmpty || !left.survivors.isEmpty {
                log("an earlier engine's turn of agent \(agentId) left processes: killed \(left.killed), still running \(left.survivors)")
            }
            let now = clock()
            _ = try store.recoverInterruptedTurns(now: now)
            try await recoverChecks(now: now)
            // Main smokes an earlier engine left running: merge runs at main queued again, the rest `error` (fix I1).
            try await recoverSmokes(now: now)
            // Releases and rollbacks an earlier engine left in progress end without running again (Task 8, builder-check 5).
            try await releaseExecutor.recover(now: now)
            try await recoverMerges()
            // The merge queue's journal: a batch an earlier engine left at some step is finished or abandoned before anything is
            // claimed (the queue also does this by itself before its first batch, and after the owner's stop).
            for company in try store.companies() { await mergeQueue.recover(company: company) }
            // The engine-owned pre-commit hook of every company workspace (Task 5a); a refusal is logged, never fatal.
            let companies = try store.companies()
            for failure in await blocking.run({ () -> [String] in
                companies.compactMap { company in
                    do {
                        let layout = SandboxLayout(paths: paths, company: company, agentHandle: "engine")
                        try CompanyHooks.install(layout: layout, git: store.gitWorkspace(root: layout.workspace, companyId: company.id))
                        return nil
                    } catch { return "\(company.name): \(error)" }
                }
            }) { log("could not install the pre-commit hook: \(failure)") }
            // A taint flag file a crash left marks its agent's lab (Task 10b, I2).
            if let failure = await blocking.run({ () -> String? in
                do { try store.markLabsForTaintFlags(home: paths.home, now: now); return nil } catch { return "\(error)" }
            }) { log("could not mark the labs of leftover taint flags: \(failure)") }
            // Brahma's built-in extensions (Task 10b), materialized read-only into every workspace; a refusal is logged.
            for failure in await blocking.run({ companies.compactMap { company -> String? in
                let workspace = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
                ExtensionTry.sweepStale(paths: paths, workspace: workspace, existing: ExtensionTry.existingNames(store), now: now)
                do { try BuiltinExtensions.materialize(workspace: workspace); return nil } catch { return "\(company.name): \(error)" }
            } }) { log("could not materialize the built-in extensions: \(failure)") }
            try SystemTimers.ensure(store: store, now: now, digestTime: store.ownerPrefs().digestHourMinute)
            ensuredTimerCompanies = Set(try store.companies().map(\.id))
            startWALShipping()
        }
    }

    /// Optional Litestream WAL shipping (Task 13b): while it is switched on and this engine runs (it holds the engine lock), litestream
    /// is supervised and restarted with backoff. Without litestream installed nothing starts; the doctor says so.
    func startWALShipping() {
        guard walShipper == nil, let config = try? store.walShipping() else { return }
        guard let litestream = backupTools.litestream else {
            log("WAL shipping is on but litestream is not installed")
            return
        }
        // The stored replica is checked again (a folder may since have become a link into the data home, or lost its drive).
        let workspaces = ((try? store.companies()) ?? []).map { URL(fileURLWithPath: $0.workspacePath, isDirectory: true) }
        do { _ = try WALShipping.validateReplica(config.replica, paths: paths, workspaces: workspaces) } catch {
            log("WAL shipping is on but not started: \(error)")
            return
        }
        do { try WALShipping.config(paths: paths, replica: config.replica) } catch {
            log("WAL shipping config could not be written: \(error)")
            return
        }
        let store = self.store, clock = self.clock
        let shipper = WALShipper(executable: litestream, paths: paths, tools: backupTools, sleeper: walSleeper, note: { [self] in log($0) },
                                 onPaused: { reason in
                                     // An unproven litestream for this database, or a child whose start could not be read (Task 9c fix
                                     // rounds 2 and 3): shipping stays paused and the owner is told once a day, in engine-written text.
                                     let notice = WALShipper.pausedNotice(reason)
                                     try? BackupTargets.noticeOncePerDay(store: store, title: notice.title, body: notice.body, now: clock())
                                 })
        walShipper = shipper
        shipper.start()
    }

    /// Stops the litestream supervisor and its child. Since Task 9c the shutdown does this as a bounded step of its own
    /// (`shutdown`, on a dedicated thread); this method remains for tests. Blocking for at most `WALShipper.stopGrace` + 2 s.
    public func stopWALShipping() {
        walShipper?.stop()
        walShipper = nil
    }

    deinit { walShipper?.stop() }

    /// Keeps the Mac awake while agents run (the owner's `preventSleep`); ended with the engine (`stopSleepPrevention`).
    nonisolated let sleepGuard: SleepGuard

    /// Ends caffeinate. Since Task 9c the shutdown does this as a bounded step of its own (`shutdown`); this method remains for tests.
    public func stopSleepPrevention() async { await sleepGuard.shutdown() }

    public func runningCount() -> Int { runningByCompany.values.reduce(0, +) }

    /// Child processes that are not turns: engine-run checks, merges, main smokes and releases in progress (a deploy's build,
    /// tools and provider CLI steps). They count against the same caps as turns.
    var otherChildren: Int { checkTasks.count + mergeTasks.count + smokeTasks.count + releaseTasks.count }

    /// Previews' child processes (running servers and starts in flight): against the safety cap only, never the plan tier's
    /// hard cap (`Scheduler.freeSlots(safetyOnly:)`, Task 3 fix I1).
    var previewChildren: Int { previewRunner.activeChildren }

    /// What keeps the Mac awake: turns, checks, merges and preview starts in flight; a preview server that is merely running
    /// does not (Task 3 fix I1).
    var awakeWork: Int { runningCount() + otherChildren + previewRunner.startsInFlight }

    nonisolated let backupTools: BackupTools
    nonisolated let walSleeper: WALShipper.Sleeper
    /// The litestream supervisor, while WAL shipping is on. Not part of `isIdle`: it runs for the engine's whole life.
    var walShipper: WALShipper?

    /// This engine's limit on concurrently running blocking (git) bodies.
    let blocking: Blocking
    /// Marks this engine's tasks for `EngineGitGuard`.
    nonisolated let engineId: String

    /// Runs `body` as one of this engine's tasks (`EngineGitGuard.engine`); for the detached ones, which inherit no task-local.
    nonisolated func asEngine<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        try await EngineGitGuard.$engine.withValue(engineId, operation: body)
    }
    private var idleWaiters: [Int: CheckedContinuation<Void, any Error>] = [:]
    private var nextIdleWaiter = 0

    /// Everything the engine owns that is in flight: turns, health, git, check and merge tasks. (Whatever a tick would start
    /// next is started synchronously inside that tick, so nothing is "queued" outside these sets.)
    private var isIdle: Bool {
        tasks.isEmpty && healthTasks.isEmpty && gitTasks.isEmpty && checkTasks.isEmpty && mergeTasks.isEmpty && timerTasks.isEmpty
            && secretsTask == nil && pushTask == nil && stopObserverTask == nil && previewTask == nil && smokeTasks.isEmpty
            && releaseTasks.isEmpty && gateTask == nil && conciergeTasks.isEmpty
    }

    private func resumeIdleWaitersIfIdle() {
        guard isIdle, !idleWaiters.isEmpty else { return }
        let waiters = idleWaiters; idleWaiters = [:]
        for (_, c) in waiters { c.resume() }
    }

    private func busyDescription() -> String {
        "turns=\(tasks.keys.sorted()) health=\(healthTasks.keys.sorted()) git=\(gitTasks.keys.sorted()) checks=\(checkTasks.keys.sorted()) merges=\(mergeTasks.keys.sorted()) timers=\(timerTasks.keys.sorted()) previews=\(previewTask == nil ? "idle" : "reconciling") smokes=\(smokeTasks.keys.sorted()) releases=\(releaseTasks.keys.sorted()) secrets=\(secretsTask == nil ? "idle" : "reloading")"
    }

    private func idleWaiterTimedOut(_ id: Int) {
        guard let c = idleWaiters.removeValue(forKey: id) else { return }
        log("waitUntilIdle timed out; still running: \(busyDescription())")
        c.resume(throwing: OrchestratorError.idleTimeout(running: runningCount()))
    }

    /// The clock `waitUntilIdle`'s backstop runs on: awake time (`AwakeTime`, the suspending clock), which stands still while
    /// the Mac sleeps (as a check's timeout does). `Task.sleep(for:)` runs on the continuous clock, which counts the sleep: a
    /// wait that spans a system sleep then times out on wake with the engine's work merely frozen, not stuck.
    public static let idleBackstopClock: any Clock<Duration> = AwakeTime.clock

    /// Returns once no engine-owned work is in flight, woken by the work finishing (no polling). `timeout` is only a hang
    /// backstop, counted in awake time (`idleBackstopClock`): when it passes, the throw names (in the log) what is still running.
    public func waitUntilIdle(timeout: Duration) async throws {
        try await waitUntilIdle(timeout: timeout, clock: Self.idleBackstopClock)
    }

    /// `waitUntilIdle` with its backstop on `clock`.
    public func waitUntilIdle<C: Clock<Duration>>(timeout: Duration, clock: C) async throws {
        try await waitUntilIdleOnly(timeout: timeout, clock: clock)
        let offBlocking = EngineGitGuard.takeViolations(engine: engineId)
        if !offBlocking.isEmpty { throw OrchestratorError.gitOffBlocking(offBlocking) }
    }

    private func waitUntilIdleOnly<C: Clock<Duration>>(timeout: Duration, clock: C) async throws {
        if isIdle { return }
        let id = nextIdleWaiter; nextIdleWaiter += 1
        let backstop = Task { [weak self] in
            try? await clock.sleep(for: timeout)
            await self?.idleWaiterTimedOut(id)
        }
        defer { backstop.cancel() }
        try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, any Error>) in
            idleWaiters[id] = c
        }
    }

    /// Ticks until cancelled, then the bounded shutdown (`shutdown`): in-flight turns are cancelled and record their outcome,
    /// every preview is stopped alongside them, and nothing holds the exit past `shutdownBound`.
    public func runForever(interval: Duration = .seconds(1), shutdownBound: Duration = EngineShutdown.bound) async {
        while !Task.isCancelled {
            await tick()
            try? await Task.sleep(for: interval)
        }
        _ = await shutdown(bound: shutdownBound)
    }

    /// The engine is stopping (Plan 4a Task 9c). Every task in flight is cancelled (a turn's `claude` gets SIGTERM and, after
    /// `killGrace`, SIGKILL) and waited for; `previewRunner.stopAll()` (every preview's process group stopped, recorded `engine
    /// stopped`; the next engine starts them again), the runner's `waitForChildren`, litestream's stop (SIGTERM, then SIGKILL
    /// after the grace, on its own thread so it never blocks the actor) and caffeinate's run at the same time, all under one
    /// bound (`EngineShutdown.run`, fix round 1 I2: nothing runs before the clock starts). Past the bound the shutdown logs
    /// what was still running, by engine-written name (task kinds and engine ids only), kills every process group the engine
    /// recorded (`EngineShutdown.killEngineProcesses`, fix round 1 M1) and returns anyway. Returns those names (tests read them).
    @discardableResult
    func shutdown(bound: Duration = EngineShutdown.bound) async -> [String] {
        let shipper = walShipper
        walShipper = nil
        var steps: [EngineShutdown.Step] = []
        if let shipper { steps.append(EngineShutdown.Step(name: "litestream") { await EngineShutdown.onThread { shipper.stop() } }) }
        steps.append(EngineShutdown.Step(name: "sleep guard") { [sleepGuard] in await sleepGuard.shutdown() })
        func add(_ name: String, _ task: Task<Void, Never>?) {
            guard let task else { return }
            task.cancel()
            steps.append(EngineShutdown.Step(name: name) { await task.value })
        }
        for (agentId, t) in tasks { add("turn of agent \(agentId)", t) }
        for (key, t) in healthTasks { add("health \(key)", t) }
        for (key, t) in gitTasks { add("git \(key)", t) }
        for (runId, t) in checkTasks { add("check \(runId)", t) }
        for (companyId, t) in mergeTasks { add("merge \(companyId)", t) }
        for (timerId, t) in timerTasks { add("timer \(timerId)", t) }
        for (companyId, t) in smokeTasks { add("smoke \(companyId)", t) }
        for (companyId, t) in releaseTasks { add("release \(companyId)", t) }
        for (requestId, t) in conciergeTasks { add("concierge \(requestId)", t) }
        add("secrets reload", secretsTask)
        add("push", pushTask)
        add("stop observers", stopObserverTask)
        add("preview pass", previewTask)
        steps.append(EngineShutdown.Step(name: "previews") { [previewRunner] in await previewRunner.stopAll() })
        steps.append(EngineShutdown.Step(name: "turn children") { [runner] in await runner.waitForChildren() })
        let left = await EngineShutdown.run(steps, bound: bound)
        if !left.isEmpty {
            let killed = EngineShutdown.killEngineProcesses(store: store, paths: paths)
            log("shutdown bound of \(EngineShutdown.seconds(bound)) passed; still running: \(left.sorted().joined(separator: ", ")); "
                + "killed \(killed.groups.terminated.count) recorded process group(s)\(killed.litestream.map { "; \($0)" } ?? ""); exiting anyway")
        }
        return left
    }

    /// Synchronous on the actor (no suspension points), so ticks never interleave with each other.
    public func tick() async {
        EngineGitGuard.$engine.withValue(engineId) {
            do {
                try schedule(now: clock())
            } catch {
                log("tick failed: \(error)")
            }
        }
    }

    private func schedule(now: Date) throws {
        // The owner's emergency stop, first: running turns and checks are cancelled and nothing below admits anything.
        let stopped = try store.engineStopped()
        enforceStop(stopped, now: now)
        // Secrets another process added or removed: reloaded in the background (a Blocking body, non-interactive reads, with
        // backoff after failures); until then admission is held.
        let secretsPending = reloadSecretsIfDue()
        // Active time first, so everything below sees the same clock; then health, which may start or end a hold.
        try store.accrueActiveTime(now: now)
        try healthTick(now: now)
        // Fail closed on secrets: until every secret's value is loaded into the redactor (`Store.secretsHeld`), nothing that
        // would let an agent write text starts: no turn, check, merge or dispatch. The reload logged which secret failed.
        let held = try stopped != nil || store.engineHold() != nil || store.secretsHeld || secretsPending
        let pressure = memory.current
        logPressure(pressure, now: now)
        // The owner's plan tier and weekly share apply from the next tick after they are changed.
        var cfg = config
        cfg.planTier = store.planTier()
        cfg.ownerReserve = 1 - store.weeklyShare()
        let companies = try store.companies()
        // Turns, checks and merges in flight keep the Mac awake (and for a minute after the last one), if the owner allows it.
        sleepGuard.update(running: awakeWork, enabled: (try? store.ownerPrefs().preventSleep) ?? false, now: now)
        let calibration = try store.usageCalibration()
        // Ultra reservations a dead engine left open are released, charged in full (Task 14u), before they are counted.
        attempt { try store.releaseOrphanUltraReservations(now: now) }
        let reservedLE = store.openReservationLE()

        // Leases: reap the expired ones and killed holders' (removing their worktrees), sweep orphaned worktrees, and hand
        // ready items to idle individual contributors. Nothing here waits on git.
        let reaped = try store.reapLeases(now: now)
        // Handbook page leases past their active-time expiry, or of killed holders (Plan ML).
        attempt { try store.reapKBLeases(now: now) }
        leaseMaintenance(now: now, companies: companies, reaped: stopped == nil ? reaped : [], held: held)
        // Test-key uses whose lease or item status no longer carries them are closed (Task 4-wire; injection checks the
        // live lease and status as well).
        try store.sweepSecretUses(now: now)

        // A restore left its marker: re-adopt every repository's main (never waits on git). Held while the owner's stop holds.
        if stopped == nil { restoreMarkerTick(companies: companies) }

        // Sleeping agents whose debounced work notices have come due.
        attempt { try store.wakeDueNotices(now: now) }

        // Pending reviews: blocked reviewers wake for them, paused reviewers' reviews are re-routed after a day.
        attempt { _ = try store.sweepReviews(now: now) }

        // Open asks: expiry, owner reminders, internal aging and paused-approver rerouting (company-active time).
        attempt { _ = try store.sweepAsks(now: now) }

        // Plan C Task C4c: open show requests past an active hour expire.
        for c in companies { attempt { _ = try store.sweepShowRequests(companyId: c.id, now: now) } }

        // Sprints (company-active time): timeboxes, then engine standups (system posts, no LLM turns, nobody wakes).
        attempt { _ = try store.enforceTimeboxes(now: now) }
        attempt { _ = try store.postStandups(now: now) }

        // Deadlocks and item aging, every `Liveness.scanInterval` company-active seconds (a frozen clock never rescans).
        for c in companies {
            let active = store.activeNow(companyId: c.id)
            guard active - (lastLiveness[c.id] ?? -.infinity) >= Liveness.scanInterval else { continue }
            lastLiveness[c.id] = active
            attempt { try store.sweepLiveness(companyId: c.id, now: now) }
        }

        // Company memory (Plan ML): new messages, items, asks, decisions, hand-offs and retros are indexed from restore-safe
        // cursors. Held by the owner's stop (caught up on resume) and while secrets are unloaded (ingest redacts, fail closed).
        if stopped == nil, !store.secretsHeld {
            for c in companies { attempt { try MemoryIngest.run(store: store, companyId: c.id, paths: paths, now: now) } }
        }
        // C3b: turns' gate requests (Ruling 48), answered outside every turn's sandbox, and every `shareSweepInterval` the
        // sweep of what a share made and never posted (Rulings 43 and 49: copies, snapshots, share refs); both run git, so
        // off the actor.
        gateTick(companies: companies.map(\.id), now: now)
        // The pack's handbook sections, once per company per engine start (companies made before Plan ML get theirs here).
        for c in companies where !handbookSkeletons.contains(c.id) {
            do {
                try store.ensureHandbookSkeleton(companyId: c.id, now: now)
                handbookSkeletons.insert(c.id)
            } catch {
                log("handbook skeleton for \(c.id) failed (retried next tick): \(error)")
            }
        }

        // Handbook refresh (Plan ML): every `AutoPages.interval` company-active seconds per company, the engine-rendered pages
        // and then the agent-readable `.brahma/kb` mirror. Held like ingest: by the owner's stop and while secrets are unloaded
        // (both redact). A failure leaves an activity line; a link planted in the mirror raises the engine-file alert. The
        // `.brahma/resources` mirror is swept with it (Task 6c): tampered files are put back from the vault.
        if !HandbookRefresh.isHeld(stopped: stopped != nil, secretsHeld: store.secretsHeld) {
            for c in companies {
                let active = store.activeNow(companyId: c.id)
                guard HandbookRefresh.isDue(active: active, last: lastHandbookRefresh[c.id]) else { continue }
                lastHandbookRefresh[c.id] = active
                HandbookRefresh.run(store: store, company: c, now: now, contentVault: ContentVault(paths: paths))
            }
        }

        // Audits of auto-merges (9c): every waiting sample is routed to an auditor (a cheap read when there is nothing to do).
        for c in companies where c.status == .running { attempt { try store.scheduleAudit(companyId: c.id, now: now) } }

        // 1. Timed blockers that have expired.
        for a in try store.agents(states: [.blocked]) {
            let until: Date
            switch a.blocker {
            case .usageLimit(let u)?, .turnBudget(let u)?, .retry(let u, _)?: until = u
            default: continue
            }
            guard until <= now else { continue }
            attempt { try store.transition(agentId: a.id, to: .ready, now: now) { $0.state == .blocked && $0.blocker == a.blocker } }
        }

        // 1b. Timers that are due (jobs run detached; a `.turn` timer sends its agent a system DM).
        attempt { try timersTick(now: now, companies: companies) }

        // 1c. Phone alerts: a detached pass that sends what the delivery plan asks for (see `PushDispatcher`).
        pushTick(now: now)

        // 2. How many live agents each agent is holding up.
        let all = try store.agents()
        var blocking: [String: Int] = (try? store.blockingCounts()) ?? [:]
        for a in all where a.state != .killed {
            if case .agent(let id)? = a.blocker { blocking[id, default: 0] += 1 }
        }
        // A pending review or audit is the critical path for the reviewer: the item (and everything behind it) waits on it.
        for (id, n) in (try? store.pendingReviewCounts()) ?? [:] { blocking[id, default: 0] += n }

        // 3. Usage gate per company. The five-hour limits close a company to everyone and are persisted as blockers
        //    (their reset is a fact). The weekly pace is NOT persisted: it is re-evaluated every tick and applied in
        //    `select`, so raising the share, a company reserve or the plan tier reopens work at once and an agent that
        //    becomes critical-path is admitted without waiting for a stored blocker to expire.
        let info = try store.latestRateLimit()
        var decisions: [String: UsageDecision] = [:]
        var paceClosed = Set<String>()
        var paceStrict = Set<String>()
        for c in companies {
            let reserve = cfg.reserve(for: c)
            let parts = UsageGate.evaluateParts(info, mode: c.usageMode, now: now, reserve: reserve,
                                                openReservationLE: reservedLE, pctPerDollar5h: calibration.pctPerDollar5h)
            if case .closed(let gateUntil) = parts.fiveHour {
                decisions[c.id] = parts.fiveHour
                let until = Self.usageUntil(gateUntil, now: now)
                var stopped = 0
                for a in try store.agents(companyId: c.id, states: [.ready]) {
                    attempt {
                        if try store.transition(agentId: a.id, to: .blocked, blocker: .usageLimit(until: until), now: now,
                                                if: { $0.state == .ready }) != nil { stopped += 1 }
                    }
                }
                if stopped > 0 {
                    attempt {
                        try store.appendEvent(ActivityEvent(
                            companyId: c.id, agentId: nil, turnId: nil, kind: .usage,
                            text: "usage gate closed (\(c.usageMode.rawValue) mode) until \(until.ISO8601Format()); \(stopped) agent(s) waiting",
                            createdAt: now))
                    }
                }
            }
            if case .closed(let paceUntil) = parts.pace {
                paceClosed.insert(c.id)
                // Past the owner's reserve nothing runs, not even the critical path.
                if let pace = UsageGate.pace(info, reserve: reserve, now: now), !pace.criticalPathExempt { paceStrict.insert(c.id) }
                if loggedPaceClosed.insert(c.id).inserted {
                    let text = UsageGate.pace(info, reserve: reserve, now: now)?.text ?? "ahead"
                    attempt {
                        try store.appendEvent(ActivityEvent(
                            companyId: c.id, agentId: nil, turnId: nil, kind: .usage,
                            text: "weekly pace closed (\(text), \(Int((reserve * 100).rounded()))% reserved) until about \(paceUntil.ISO8601Format()); only work others wait on runs",
                            createdAt: now))
                    }
                }
            }
            if !paceClosed.contains(c.id) { loggedPaceClosed.remove(c.id) }
        }

        // 4. Per-agent turn budget over the last hour (infrastructure failures don't count).
        let hourAgo = now.addingTimeInterval(-Self.hour)
        for a in try store.agents(states: [.ready]) where try store.turnCount(agentId: a.id, since: hourAgo) >= cfg.turnBudgetPerHour {
            let oldest = try store.oldestTurnStart(agentId: a.id, since: hourAgo) ?? now
            attempt {
                try store.transition(agentId: a.id, to: .blocked, blocker: .turnBudget(until: oldest.addingTimeInterval(Self.hour)),
                                     now: now, if: { $0.state == .ready })
            }
        }

        // 5. Engine-run checks first (cheap, and they unblock reviews), then select and launch turns around them.
        startChecks(now: now, config: cfg, held: held, pressure: pressure, companies: companies)
        // 5a. The main guard (Plan 4a Task 3): for every company, `main` is where the queue left it, before the merge step.
        mainGuardTick(now: now, held: held, companies: companies)
        startMerges(now: now, config: cfg, held: held, pressure: pressure, companies: companies)
        // 5b. Previews (Plan L): one reconcile pass at a time, after the merge step.
        previewTick(held: held)
        // 5c. The smoke check on main (Plan L): queue a run for a new main, run queued ones one at a time per company.
        smokeTick(now: now, config: cfg, held: held, pressure: pressure, companies: companies)
        // 5d. Releases (Plan L): an approved deploy is carried out once, after the main smoke step.
        releaseTick(now: now, config: cfg, held: held, pressure: pressure, companies: companies)

        infraCooldown = infraCooldown.filter { $0.value > now }
        let byId = Dictionary(uniqueKeysWithValues: companies.map { ($0.id, $0) })
        let ready = try store.agents(states: [.ready])
        // The holder of an item whose merge is running gets no work turn until the merge ends.
        let mergingHolders = (try? store.agentsLockedOutByMerges()) ?? []
        // Agents waiting for a sandbox canary get no slot (I1): otherwise they would win fair share every tick and be dropped
        // at launch, starving the Workspace and Full companies. From memory, no I/O.
        let canaryHeldIds = canaryTick(ready: ready, companies: byId)
        let candidates = ready.compactMap { a -> Candidate? in
            guard !a.paused, tasks[a.id] == nil, !dispatching.contains(a.id), infraCooldown[a.id] == nil, !mergingHolders.contains(a.id),
                  !canaryHeldIds.contains(a.id), let c = byId[a.companyId] else { return nil }
            return Candidate(agent: a, company: c, blockingCount: blocking[a.id] ?? 0)
        }
        let selected = Scheduler.select(candidates: candidates, runningByCompany: runningByCompany, config: cfg,
                                        usage: { decisions[$0.id] ?? .open }, otherChildren: otherChildren,
                                        safetyOnly: previewChildren + conciergeTasks.count, pressure: pressure,
                                        held: held, paceClosed: paceClosed, paceStrict: paceStrict,
                                        ownerRequestAgentIds: (try? store.ownerRequestAgentIds()) ?? [])
        for agent in selected { launch(agent, now: now) }

        // 5e. Plan C Task C4c: the owner lane (the concierge), outside mode concurrency, under the gate, the hold, the stop and
        //     the safety cap.
        conciergeTick(cfg: cfg, decisions: decisions, paceStrict: paceStrict, held: held, pressure: pressure)

        // 6. Engine dispatch, after admission: only into the slots admission left over, and only for companies whose gate,
        //    pace and concurrency cap would let a new agent run. Leases are never reserved for agents admission would refuse.
        if !held {
            let free = Scheduler.freeSlots(config: cfg, running: runningCount(), otherChildren: otherChildren,
                                           safetyOnly: previewChildren + conciergeTasks.count,
                                           pressure: pressure, held: held)
            var companyFree: [String: Int] = [:]
            for c in companies where c.status == .running && (decisions[c.id] ?? .open) == .open && !paceClosed.contains(c.id) {
                companyFree[c.id] = max(cfg.modeCap(c.usageMode) - (runningByCompany[c.id] ?? 0), 0)
            }
            dispatchTick(now: now, companies: companies, skipping: Set(reaped.map(\.itemId)), freeSlots: free, companyFree: companyFree)
        }
    }

    /// Starts the background redactor reload when one is due (never more than one at a time). Returns whether the redactor
    /// is behind the database, in which case admission is held this tick.
    private func reloadSecretsIfDue() -> Bool {
        let needed = (try? store.secretsReloadNeeded()) ?? true
        guard needed else { return false }
        if secretsTask == nil, (try? store.redactorReloadDue()) ?? false {
            let (store, vault, blocking) = (self.store, self.vault, self.blocking)
            secretsTask = Task.detached { [self] in
                let failure: String? = await blocking.run {
                    do { try store.reloadRedactorIfNeeded(vault: vault); return nil } catch { return "\(error)" }
                }
                if let failure { log("could not reload secrets: \(failure)") }
                await secretsReloadDone()
            }
        }
        return true
    }

    private func secretsReloadDone() { secretsTask = nil }

    /// Starts the pass that answers turns' gate requests when one is pending and none runs (Ruling 48). The helpers run under
    /// the owner's sandbox runner (`Orchestrator.gateArchives`), in this engine's process tree, never a turn's.
    private func gateTick(companies: [String], now: Date) {
        guard gateTask == nil else { return }
        let pending = (try? store.writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT EXISTS(SELECT 1 FROM gateRequest WHERE status = 'pending')") ?? false
        }) ?? false
        let sweep = lastShareSweep.map { now.timeIntervalSince($0) >= Self.shareSweepInterval || now < $0 } ?? true
        guard pending || sweep else { return }
        if sweep { lastShareSweep = now }
        let (store, paths, vault, blocking) = (self.store, self.paths, self.vault.nonInteractive(), self.blocking)
        gateTask = Task.detached { [self] in   // scope-escape: the engine's gate pass and share sweep
            let failures: [String] = await blocking.run {
                var failures: [String] = []
                if pending {
                    do {
                        try store.serveGateRequests(archives: { Orchestrator.gateArchives(store: store, paths: paths, companyId: $0) },
                                                    knownValues: { try store.knownSecretValues(companyId: $0, vault: vault) },
                                                    paths: paths, now: Store.now())
                    } catch { failures.append("gate requests failed: \(error)") }
                }
                if sweep {
                    for c in companies {
                        do { try store.sweepShareOrphans(companyId: c, paths: paths, now: now) } catch {
                            failures.append("share sweep of \(c) failed: \(error)")
                        }
                    }
                }
                return failures
            }
            for f in failures { log(f) }
            await gateDone()
        }
    }

    /// How often the tick sweeps what failed shares left (wall-clock seconds between passes).
    static let shareSweepInterval: TimeInterval = 60

    private func gateDone() { gateTask = nil }

    /// The engine's archive reader for gate requests: `unzip` and the PDF helper (`brahma-pdf` beside the engine's binary)
    /// under the owner's sandbox runner, each read in a fresh private vault temp directory. Where no sandbox or helper
    /// exists it refuses what it can't read (fail closed).
    public nonisolated static func gateArchives(store: Store, paths: BrahmaPaths, companyId: String) -> any ArchiveReader {
        let vault = Vault(paths: paths, companyId: companyId, content: ContentVault(paths: paths))
        let executable = Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0])
        return SandboxedUnzipReader(runner: Orchestrator.ownerSandboxRunner(store: store, paths: paths), scratch: { try vault.makeTempDir() },
                                    pdfHelper: SandboxedPDFReader.locate(executable: executable))
    }

    private func logPressure(_ level: MemoryPressure, now: Date) {
        guard level != lastPressure else { return }
        lastPressure = level
        let effect = level == .critical ? "paused" : level == .warning ? "limited" : "resumed"
        for c in (try? store.companies()) ?? [] {
            attempt {
                try store.appendEvent(ActivityEvent(companyId: c.id, agentId: nil, turnId: nil, kind: .usage,
                                                    text: "memory pressure \(level.rawValue): new turns \(effect)", createdAt: now))
            }
        }
    }

    private func launch(_ agent: Agent, now: Date) {
        // Waiting for a sandbox canary (Task 3): stays ready, no turn, until its key passed.
        if canaryHeld(agent) { return }
        // No empty turns: nothing to answer, no due notice, no review, no lease to keep working on. No process is started.
        if (try? store.hasActionableWork(agentId: agent.id)) == false {
            attempt { try store.transition(agentId: agent.id, to: .sleeping, now: now, if: { $0.state == .ready && !$0.paused }) }
            return
        }
        let started: (Agent, Turn)
        do {
            guard let s = try store.beginTurn(agentId: agent.id, now: now) else { return }
            started = s
        } catch {
            log("could not start turn for \(agent.id): \(error)")
            return
        }
        let (running, turn) = started
        runningByCompany[running.companyId, default: 0] += 1
        // The task inherits actor isolation, so it cannot run (or end) before this method returns.
        tasks[running.id] = Task {
            // The turn's supervision re-reads the owner's stop every second (`EmergencyStop.pollInterval`): a stop cancels the
            // turn even before the next tick sees it. Whichever ends first ends the other; the turn always runs to its record.
            await withTaskGroup(of: Void.self) { group in
                group.addTask { await self.performTurn(agent: running, turn: turn) }
                group.addTask { await self.waitForStop() }
                await group.next()
                group.cancelAll()
            }
            self.turnEnded(agentId: running.id, companyId: running.companyId)
        }
    }

    /// Runs on every exit path: `performTurn` never throws and runs to completion even when cancelled.
    private func turnEnded(agentId: String, companyId: String) {
        tasks[agentId] = nil
        let n = (runningByCompany[companyId] ?? 1) - 1
        runningByCompany[companyId] = n > 0 ? n : nil
    }

    // MARK: Turn (off the actor)

    /// A session change a turn needs (I2): decided while the turn is prepared, written only once it passed the sandbox gate.
    enum SessionChange { case forceFresh, reset }

    /// The MCP config path of the provisional request the sandbox gate compiles (the real file is written after the gate; the
    /// settings shape ignores strings).
    static let gateMCPPlaceholder = "/dev/null"

    private nonisolated func performTurn(agent: Agent, turn: Turn) async {
        var ctx: TurnContext?
        var state = TurnStreamState()
        var abortReason: String?
        var initModel: String?
        var sentRequest: TurnRequest?
        var lastInfo: RateLimitInfo?
        var failure: String?
        var runnerError: (any Error)?
        var worktreeUnavailable: WorktreeUnavailable?
        var isReview = false
        // The session this turn runs in, whether it resumed one, and what it ran with.
        var scope = SessionScope.base
        var wasResume = false
        var mounts: [ExtensionMount] = []
        var mountSetHash: String?
        var workingDirectory = ""
        var toolsKey = ""
        var usedModel = agent.model
        var keepModel = false
        var sawInit = false
        var plan: PlanWatch?
        var modeDecision: ModeDecision?
        var notLaunched: ModeNotLaunched?
        var sandboxUnverified = false
        // The one-use grants this turn spent, and whether its process started: a turn that spent grants and then did not
        // launch gives them back (I2).
        var spentGrants: [String] = []
        var launched = false
        // A leaseholder's work turn: continuity of its item's branch is checked at the start (the head must be the recorded one)
        // and the head is recorded again at the end (scan (a), Task 4-wire). `held`: continuity held at the start.
        var leaseHead: (git: GitWorkspace, item: WorkItem, held: Bool)?
        // Plan C2a: the head of every item branch the agent holds as the turn starts (where its turn-end taint record starts).
        var heldAtStart: [String: String] = [:]
        // P2 R4-3: every item the agent holds as the turn starts, from its leases (not git: an item whose branch head can't
        // be read then is held all the same) and the turn's own lease; the turn-end mark and record take each of them.
        var heldItemsAtStart: Set<String> = []
        // Task 10: the turn's taint (marked once, from the stream's backup path) and the workspace whose lab is recorded at the end.
        var taintMarked = false
        var recordedSources: Set<String> = []
        var labWorkspace: URL?
        // S30 (10b): the turn end could not write the lab mark: the session keeps its taint and its flag file.
        var labMarkUnwritten = false
        // S33 (10b): the lab's commits as the turn launches; its end records clean (after an owner's clear) only what is new.
        var labAtStart: Set<String>?
        // Task 14u: the Ultra run this turn was admitted for (reserved once it passed the sandbox gate), the watchdog's
        // agent-count kill, and the turn's leader (for its SIGINT).
        var ultraPlan: UltraPlan?
        var ultraReserved = false
        // Plan C Task C4c: a show turn's requests were taken, its session's earlier total, and its soft-cap stop.
        var showBound = false
        var showCostBefore = 0.0
        var showCapped = false
        var agentCapped = false
        var leaderPid: Int32?
        do {
            guard let company = try store.company(id: agent.companyId) else { throw StoreError.notFound }
            labWorkspace = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
            // Nothing of the agent's earlier turns may still run, whatever the profile (M1): this turn waits for their sweep
            // and kills what they (or an earlier engine's) left before any of its own work.
            try await settleEarlierTurns(agent: agent, company: company, turnId: turn.id)
            let template = store.catalog.template(role: agent.role, pack: company.packId)
            let store = self.store
            // Plan C Task C4c: an owner's show request comes first: an itemless `.show` turn that handles only the request(s).
            let showRequests = try store.showRequestsAwaitingTurn(agentId: agent.id)
            let showTurn = !showRequests.isEmpty
            // A pending review is its own clean-context turn: no inbox, no notices, a fresh session.
            let review = showTurn ? nil : try await blocking.tryRun { try Self.prepareReview(store: store, agent: agent, company: company) }
            // Otherwise a batched audit of auto-merges (9c) is the same kind of clean-context turn.
            let audit = review == nil && !showTurn
                ? try await blocking.tryRun { try Self.prepareAudit(store: store, agent: agent, company: company) } : nil
            isReview = review != nil || audit != nil
            var turnPrompt = ""
            var sent = agent
            // The company's profile for this role, under the engine's ceiling.
            let profile = turnProfile(agent: agent, company: company)
            var sandboxed: SandboxedTurn?
            // The system prompt is byte-stable per agent and role: the roster, items and times ride in the orientation.
            var systemPrompt = RolePrompt.render(agent: agent, company: company, template: template, sandboxed: profile == .sandboxed)
            // `ModePolicy.select` decides each turn's mode, model and effort from the role, the item's effective spec, the company's
            // usage mode and the pressure on the plan (design §3.2).
            let deciding = (try? store.askModelContext(agentId: agent.id)) ?? ModelContext()
            var kind = TurnKind.work
            workingDirectory = company.workspacePath
            var addDirs: [String] = []
            var cacheBreak: String?
            var slotModel: String?
            var slotTools: String?
            var sessionTokens = 0
            toolsKey = "work:" + template.companyTools.joined(separator: ",")
            var planDirectory: String?
            var facts: ItemModeFacts?
            var itemBudget = false
            // A session change this turn needs, decided here and written only once the turn passed the sandbox gate (I2): a
            // turn that does not launch keeps the agent's session.
            var sessionChange: SessionChange?

            if let review {
                sent.sessionId = UUID().uuidString
                sent.sessionStarted = false
                systemPrompt += "\n\n" + ReviewDigest.instructions(worktree: review.worktree.path)
                turnPrompt = review.digest
                workingDirectory = review.worktree.path
                addDirs = [review.worktree.path]
                facts = try? store.itemModeFacts(itemId: review.item.id, holderId: nil)
                if profile == .sandboxed {
                    // The review runs in the reviewer's lab and reads the worktree (read-only).
                    let prepared = try await prepareSandbox(agent: agent, company: company, kind: .review, item: review.item, turnId: turn.id)
                    sandboxed = prepared
                    workingDirectory = prepared.scope.cwd.path
                    addDirs = prepared.scope.readOnlyDirs.map(\.path)
                }
            } else if let audit {
                sent.sessionId = UUID().uuidString
                sent.sessionStarted = false
                systemPrompt += "\n\n" + AuditDigest.instructions
                turnPrompt = audit.digest
                toolsKey = "audit"
                if profile == .sandboxed {
                    let prepared = try await prepareSandbox(agent: agent, company: company, kind: .audit, item: nil, turnId: turn.id)
                    sandboxed = prepared
                    workingDirectory = prepared.scope.cwd.path
                    addDirs = prepared.scope.readOnlyDirs.map(\.path)
                }
            } else {
                // Reads the item's recent commits (git): off the cooperative pool.
                let paths = self.paths
                var c = try await blocking.tryRun { try TurnContext.load(store: store, paths: paths, agent: agent, company: company) }
                if showTurn {
                    // Plan C Task C4c: the request is the turn's only inbox content. No item, lease, notice or message is shown,
                    // and nothing is delivered (the rest waits for the next ordinary turn); the turn reads no relayed text.
                    c.item = nil; c.lease = nil; c.playbook = nil
                    c.inbox = []; c.inboxOverflow = 0; c.channelCounts = []; c.threadRoots = [:]; c.attachments = [:]
                    c.notices = []; c.collapsedNotices = 0; c.inboxItemIds = []; c.quietItemIds = []; c.noticeIds = []
                    c.pendingReviewCount = 0; c.newResources = []
                    c.relayedTaint = try store.importTaint(companyId: company.id)
                }
                let workspace = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
                var checkout: URL?
                var git: GitWorkspace?
                // A leaseholder works inside its item's worktree (with the shared `.brahma` directory); everyone else in the workspace.
                if c.lease != nil, let leased = c.item {
                    let g = store.gitWorkspace(root: workspace, companyId: company.id)
                    let wt = g.worktreePath(key: leased.key)
                    if !g.hasCheckout(key: leased.key) {
                        let key = leased.key
                        do {
                            try await blocking.tryRun { try g.addWorktree(key: key) }
                            store.noteWorktreeSetupSuccess(companyId: company.id, now: clock())
                        } catch {
                            // Never run a leaseholder's turn outside its worktree: the turn does not start.
                            throw WorktreeUnavailable(itemId: leased.id, key: leased.key, reason: "\(error)")
                        }
                    }
                    await clearWorktreeFailures(itemId: leased.id)
                    workingDirectory = wt.path
                    addDirs = [wt.path, workspace.appending(path: ".brahma", directoryHint: .isDirectory).path]
                    checkout = wt
                    git = g
                    if c.lease?.agentId == agent.id {
                        // The branch must be where the engine left it (git, off the cooperative pool); a move outside the holder's
                        // turns flags the item and refuses its submits until a manager re-adopts it.
                        let now = clock()
                        let held = try await blocking.tryRun {
                            try store.checkBranchContinuity(item: leased, agent: agent, head: try g.head(of: g.branchRef(key: leased.key)), now: now)
                        }
                        leaseHead = (g, leased, held)
                    }
                }
                heldAtStart = await blocking.run { store.leaseHeads(agentId: agent.id, workspace: workspace) }
                heldItemsAtStart = Set(heldAtStart.keys)
                if let lease = c.lease, lease.agentId == agent.id { heldItemsAtStart.insert(lease.itemId) }
                do { heldItemsAtStart.formUnion(try store.leases(agentId: agent.id).map(\.itemId)) } catch {
                    self.log("could not read the leases \(agent.name) holds at turn start: \(error)")
                }
                // Only work updates to read and nothing to answer: a notice-only turn (cheapest model for `auto` agents). A
                // leaseholder's updates are its work, so its turns stay work turns.
                if c.onlyNotices, c.lease == nil { kind = .notice }
                if showTurn { kind = .show }
                scope = kind == .notice ? .base : c.scope
                if scope != c.scope {
                    c.recentSummaries = (try? store.recentTurnSummaries(agentId: agent.id, scope: scope)) ?? []
                    c.summariesOmitted = (try? store.recentTurnSummariesTainted(agentId: agent.id, scope: scope)) ?? 0
                }
                if let itemId = scope.itemId {
                    // A leaseholder's failed checks and review rejections may raise the item's floor before this turn picks
                    // its rung (design §3.3), so the fix turn already runs at it.
                    if c.lease != nil, let g = git {
                        // Its `nameStatus` diffs are git: off the cooperative pool.
                        let now = clock()
                        await blocking.run { self.escalate(itemId: itemId, agent: agent, git: g, now: now) }
                    }
                    facts = try? store.itemModeFacts(itemId: itemId, holderId: c.lease?.agentId ?? agent.id)
                    itemBudget = c.lease?.agentId == agent.id && c.lease?.itemId == itemId
                        && facts.map { Self.budgetApplies($0.item) } == true
                }

                // Plan-first (design §2.4): only on a clean worktree, so the write barrier can tell. The selection is the mode
                // policy's (compiled only once probe V-4 passed); tests may force it.
                var planGit: (head: String, barrier: GitWorkspace.PlanBarrier)?
                if kind == .work, let leased = c.item, let git, let checkout,
                   planSelector.map({ $0(agent, leased, company) })
                    ?? ModePolicy.select(modeInputs(kind: .work, agent: agent, company: company, template: template, deciding: deciding,
                                                    facts: facts, hasItem: true, itemBudget: itemBudget, sessionModel: nil,
                                                    sessionTokens: 0)).planFirst {
                    let key = leased.key
                    planGit = await blocking.run { () -> (head: String, barrier: GitWorkspace.PlanBarrier)? in
                        guard (try? git.isDirty(in: checkout)) == false, let head = try? git.headCommit(in: checkout),
                              let barrier = try? git.planBarrier(key: key, in: checkout) else { return nil }
                        return (head, barrier)
                    }
                }
                if let leased = c.item, let git, let checkout, let (head, barrier) = planGit,
                   let dir = Self.planDirectory(workspace: workspace, key: leased.key, store: store, companyId: company.id) {
                    kind = .plan
                    planDirectory = dir.path
                    // A plan turn reads the code (its working directory) and writes only into the plans directory.
                    addDirs = [dir.path]
                    toolsKey = "plan:" + template.companyTools.joined(separator: ",")
                    plan = PlanWatch(git: git, worktree: checkout, preHead: head, itemId: leased.id, key: leased.key, directory: dir,
                                     barrier: barrier)
                }

                // The extension parts this turn mounts (Task 5a): the pack's suggestions, the company's overrides and the agent's
                // extension grants, rehashed; their declared egress joins the scope below. Blocking (it hashes the trees).
                let mountKind = kind, mountItemId = scope.itemId
                mounts = try await blocking.tryRun {
                    let grants = GrantResolver.inputs(try store.activeGrants(agent: agent, itemId: mountItemId, kind: mountKind))
                    return try ExtensionLibrary.mounts(company: company, role: agent.role, agent: agent, grants: grants, profile: profile,
                                                       kind: mountKind, store: store, paths: paths, now: self.clock())
                }
                // A sandboxed turn runs where its scope says (the item worktree for a leaseholder, the plans directory for a plan
                // turn, else the lab), computed before the session is chosen so its stored cwd is the one the turn uses.
                if profile == .sandboxed {
                    let prepared = try await prepareSandbox(agent: agent, company: company, kind: kind,
                                                            item: checkout != nil ? c.item : nil, turnId: turn.id,
                                                            extraDomains: ExtensionLibrary.agentNetwork(mounts))
                    sandboxed = prepared
                    workingDirectory = prepared.scope.cwd.path
                    addDirs = prepared.scope.readOnlyDirs.map(\.path)
                    toolsKey += "|sandboxed"
                }

                // The mount set is frozen per session (Task 5a): a different set on this turn forces a fresh session, never --resume.
                var slot = try store.sessionSlot(agent: agent, scope: scope)
                mountSetHash = ExtensionLibrary.mountSetHash(mounts)
                if slot.started, (slot.mountSetHash ?? ExtensionLibrary.mountSetHash([])) != mountSetHash {
                    // Decided as the fresh slot `forceFreshSession` leaves; written after the gate (`sessionChange`).
                    sessionChange = .forceFresh
                    slot.started = false; slot.cwd = nil; slot.model = nil; slot.tools = nil; slot.endedAt = nil
                    slot.lastTurnId = nil; slot.mountSetHash = nil
                }
                // Warm-only resume: a cold or large session starts over with the role card, the orientation and Continuity.
                slotModel = slot.model
                slotTools = slot.tools
                let transcript = store.sessionTranscriptTokens(turnId: slot.lastTurnId)
                let decision = SessionPolicy.decide(
                    started: slot.started, storedCwd: slot.cwd, cwd: workingDirectory, endedAt: slot.endedAt,
                    tokens: transcript, now: clock())
                switch decision {
                case .resume:
                    sent.sessionId = slot.sessionId
                    sent.sessionStarted = true
                    wasResume = true
                    sessionTokens = transcript ?? 0
                case .fresh(let reason):
                    // A reset is written after the gate (`sessionChange`), which then sets the new session id.
                    if reason != .new, sessionChange == nil { sessionChange = .reset }
                    sent.sessionId = slot.sessionId
                    sent.sessionStarted = false
                    c.fresh = true
                    slotModel = nil
                    slotTools = nil
                }
                if showTurn {
                    // The request's text is gated against the stored values (fail closed: an unreadable vault fails the turn).
                    let (companyId, vault) = (company.id, self.vault)
                    let known = try await blocking.tryRun { try store.allKnownSecretValues(companyId: companyId, vault: vault) }
                    turnPrompt = TurnDigest.renderShow(c, requests: showRequests, gate: GlobalSearch.TextGate(knownValues: known))
                } else {
                    turnPrompt = TurnDigest.render(c, agent: agent, company: company)
                }
                ctx = c
            }

            // The model of an (agent, item) session is fixed after its first work turn; the effort may vary.
            let fixedModel = wasResume && scope.itemId != nil && review == nil ? slotModel : nil
            var inputs = modeInputs(kind: review != nil ? .review : audit != nil ? .audit : kind, agent: agent, company: company, template: template,
                                    deciding: deciding, facts: facts, hasItem: review != nil || scope.itemId != nil,
                                    itemBudget: review == nil && itemBudget, sessionModel: fixedModel, sessionTokens: sessionTokens)
            // Task 14u: the item's approved Ultra run is admitted (eligible, every hard gate, a fresh get_usage) or refused.
            let ultra = await ultraPreflight(kind: review != nil ? .review : audit != nil ? .audit : kind, itemBudget: review == nil && itemBudget,
                                             facts: facts, inputs: inputs, agent: agent, company: company, profile: profile,
                                             relayedTaint: ctx?.relayedTaint != nil)
            if showTurn { inputs.showDirectRefsOnly = showRequests.allSatisfy { store.showCandidatesAreDirect($0, company: company) } }
            inputs.ultraTrigger = ultra.trigger
            inputs.ultra = ultra.plan?.admission
            inputs.ultraRefusal = ultra.refusal
            ultraPlan = ultra.plan
            var mode = ModePolicy.select(inputs)
            if review != nil, inputs.reviewSpendCapped, let f = facts {
                attempt { try store.noteReviewSpendCap(item: f.item, now: clock()) }
            }
            if let refusal = mode.refusal { throw ModeNotLaunched(reason: refusal, overBudgetItem: nil) }
            if !mode.launch, review == nil {
                throw ModeNotLaunched(reason: mode.reason, overBudgetItem: scope.itemId)
            }
            var model = mode.model
            sent.model = model
            usedModel = model
            modeDecision = mode
            // An explicit escalation to Opus re-pins the session's model; otherwise an item session keeps the one it has.
            keepModel = scope.itemId != nil && agent.model == "auto" && !mode.cacheBreak
            if wasResume {
                var changes: [String] = []
                if let old = slotModel, old != model { changes.append("model \(old) -> \(model)") }
                if let old = slotTools, old != toolsKey { changes.append("tools changed") }
                if !changes.isEmpty { cacheBreak = changes.joined(separator: "; ") }
            }
            /// Task 14u: the turn re-selects without a fan-out shape it may not use after all (its canary key, a refused
            /// reservation, taint found at launch); everything chosen from the decision follows it.
            func adopt(_ i: ModeInputs) throws {
                inputs = i
                mode = ModePolicy.select(inputs)
                if !mode.launch, review == nil { throw ModeNotLaunched(reason: mode.reason, overBudgetItem: scope.itemId) }
                model = mode.model
                sent.model = model
                usedModel = model
                modeDecision = mode
                keepModel = scope.itemId != nil && agent.model == "auto" && !mode.cacheBreak
            }
            func dropUltra(_ why: String) throws {
                ultraPlan = nil
                var i = inputs
                i.ultra = nil
                i.ultraRefusal = why
                try adopt(i)
            }

            // The turn's request; `mcpConfigPath` is the one string not known before the gate (the shape ignores strings).
            let settingsFile = SettingsFile.path(paths: paths, agentId: agent.id)
            func turnRequest(mcpConfigPath: String) throws -> TurnRequest {
                var request = TurnRequest(
                    agent: sent, company: company, prompt: turnPrompt, appendSystemPrompt: systemPrompt,
                    mcpConfigPath: mcpConfigPath,
                    workingDirectory: workingDirectory, profile: profile, addDirs: addDirs,
                    environment: ["BRAHMA_AGENT_ID": agent.id, "BRAHMA_HOME": paths.home.path,
                                  "BRAHMA_WORKSPACES": paths.workspaces.path])
                request.kind = review != nil ? .review : audit != nil ? .audit : kind
                request.mounts = mounts.map(\.url)
                request.planDirectory = planDirectory
                request.mode = mode
                request.hookExecutable = mcpExecutable
                request.turnRecordDirectory = turnRecordDirectory
                request.expectations = turnExpectations(agent, company)
                    ?? TurnProfileCompiler.expectations(for: mode, agents: store.recordedBuiltinAgents())
                // The settings travel in a file only the engine can read or write (`<runDir>/<agentId>.settings.json`, 0600).
                request.settingsFilePath = settingsFile.path
                // Task 10: every turn records its taint through the PostToolUse hook; the pre-tool hook reads it back.
                request.postToolHook = TaintPolicy.postToolHook(executable: mcpExecutable, database: paths.database.path, agentId: agent.id)
                request.taintFlagFile = TaintFlag.url(home: paths.home, agentId: agent.id)?.path
                request.taintDatabase = paths.database.path
                // Task 14u: a Task turn keeps its web tools only once F7-agents passed for this CLI build.
                request.taskWebTools = passedProbeGates(.sandboxedTask, fingerprint: probeFingerprint()).contains("F7-agents")
                if let sandboxed {
                    request.sandbox = sandboxed.scope
                    request.shellPrefix = sandboxed.shellPrefix.path
                    request.containmentMarker = sandboxed.marker
                } else if profile == .workspace {
                    request.deniedPaths = try workspaceDeniedPaths(company: company, agent: agent)
                }
                return request
            }
            // The per-launch sandbox gate (Task 3, I2), before anything of the turn is consumed or created: no one-use grant
            // spent, no session reset, no credential, no MCP file. The shape is the one this turn would run with.
            let gate = profile == .sandboxed ? sandboxCanary : nil
            // Task 14u: a fan-out shape (Task, Ultra) runs only once its own canary key passed. Until then this turn falls back
            // to the computed rung without it (the shape's canary is asked for in the background); the agent never waits on it.
            // Run again after any later re-selection (fix round 2, N1): a computed rung that fans out falls back the same way.
            func settleFanOut() async throws {
                guard let gate else { return }
                for _ in 0..<2 {
                    guard let launch = CanaryShape.launch(mode) else { break }
                    let settings = TurnProfileCompiler.profile(for: try turnRequest(mcpConfigPath: Self.gateMCPPlaceholder)).settings
                    if await fanOutVerified(gate: gate, settings: settings, launch: launch, company: company) { break }
                    if mode.workflow != nil { ultraPlan = nil }
                    try adopt(Self.withoutFanOut(inputs, launch: launch))
                }
            }
            try await settleFanOut()
            var gatedShape: String?
            if let gate {
                let settings = TurnProfileCompiler.profile(for: try turnRequest(mcpConfigPath: Self.gateMCPPlaceholder)).settings
                try await requireSandboxVerified(gate: gate, settings: settings, agent: agent, company: company, launch: CanaryShape.launch(mode))
                gatedShape = CanaryShape.key(settings, launch: CanaryShape.launch(mode))
            }
            // The turn launches: its one-use grants are spent now, never by a turn that does not run. A turn that does not
            // launch after all gives them back (`spentGrants`, below).
            if var prepared = sandboxed, !prepared.grants.isEmpty {
                let asked = prepared.grants.count
                try await consumeSandboxGrants(&prepared, agent: agent, company: company, item: prepared.item, turnId: turn.id)
                spentGrants = prepared.grants.map(\.id)
                sandboxed = prepared
                addDirs = prepared.scope.readOnlyDirs.map(\.path)
                // A grant lost meanwhile rebuilt the scope: its shape is gated again before anything else is created.
                if prepared.grants.count != asked, let gate {
                    let settings = TurnProfileCompiler.profile(for: try turnRequest(mcpConfigPath: Self.gateMCPPlaceholder)).settings
                    try await requireSandboxVerified(gate: gate, settings: settings, agent: agent, company: company,
                                                     launch: CanaryShape.launch(mode))
                    gatedShape = CanaryShape.key(settings, launch: CanaryShape.launch(mode))
                }
            }
            // Task 14u: the admitted Ultra run is reserved now (its approval consumed, the item's budget raised by its cap once,
            // its extra slots held), and its digest line names who approved it.
            // The count gates are judged again in the reserving transaction (S28): a run that lost a race runs the computed rung.
            let promptBeforeUltra = turnPrompt
            if let plan = ultraPlan, mode.workflow != nil, let itemId = scope.itemId {
                do {
                    try await reserveUltraRun(plan, turnId: turn.id, company: company, itemId: itemId)
                    ultraReserved = true
                    if let w = mode.workflow { turnPrompt += "\n\n" + UltraDigest.line(w) }
                } catch let refusal as UltraRefusal {
                    try dropUltra(refusal.reason)
                    try await settleFanOut()
                }
            } else {
                ultraPlan = nil
            }
            // Fix round 1, I2: gate 10 again, right before anything of the launch is created. The taint this turn takes at launch
            // (what a tainted session wrote, the fan-out pre-taint while V-1 is unproven) or the session already has refuses the
            // run: its reservation is released uncharged (the approval kept) and the computed rung runs; its shape is gated again
            // by the backstop below.
            if ultraReserved, let plan = ultraPlan {
                let probe = TurnProfileCompiler.profile(for: try turnRequest(mcpConfigPath: Self.gateMCPPlaceholder))
                var fanOut = Set(probe.tools ?? probe.allowedTools)
                fanOut.insert("Workflow")
                let preTainted = TaintPolicy.preTaint(tools: fanOut, network: sandboxed?.scope.network, hookVerified: await postToolGateVerified())
                let flagged = TaintFlag.url(home: paths.home, agentId: agent.id).map(TaintFlag.exists) ?? true
                let stored = ((try? store.agent(id: agent.id)) ?? nil)?.sessionTainted ?? true
                if ctx?.relayedTaint != nil || preTainted || flagged || stored {
                    await endUltraRun(plan, turnId: turn.id, companyId: company.id, launched: false)
                    ultraReserved = false
                    turnPrompt = promptBeforeUltra
                    try dropUltra("the session read outside content")
                    try await settleFanOut()
                }
            }
            // The session change decided above, now that the turn launches.
            switch sessionChange {
            case .forceFresh?:
                try store.forceFreshSession(agentId: agent.id, itemId: scope.itemId, reason: "mounts changed", now: clock())
                try store.applyPendingSessionReset(agentId: agent.id, turnId: turn.id, scope: scope)
                sent.sessionId = try store.sessionSlot(agent: try store.agent(id: agent.id) ?? agent, scope: scope).sessionId
            case .reset?:
                try store.resetSession(agentId: agent.id, scope: scope)
                sent.sessionId = try store.sessionSlot(agent: try store.agent(id: agent.id) ?? agent, scope: scope).sessionId
            case nil:
                break
            }
            // A reason an earlier turn left (Task 10's taint reset, B-M12): only a turn of its own scope takes it. Review and audit
            // turns run in throwaway sessions and leave it pending.
            if review == nil, audit == nil, sessionChange != .forceFresh {
                try store.applyPendingSessionReset(agentId: agent.id, turnId: turn.id, scope: scope)
            }

            let turnToken: String
            if let review {
                try store.setTurnContext(turnId: turn.id, kind: .review, itemId: review.item.id)
                turnToken = try store.issueTurnCredential(turnId: turn.id, kind: "review", itemId: review.item.id)
            } else if let audit {
                try store.bindAuditTurn(turnId: turn.id, agentId: agent.id, itemIds: audit.itemIds)
                turnToken = try store.issueTurnCredential(turnId: turn.id, kind: "audit")
            } else {
                if kind != .work || scope.itemId != nil { try store.setTurnContext(turnId: turn.id, kind: kind, itemId: scope.itemId) }
                if let cacheBreak { try store.setTurnCacheBreak(turnId: turn.id, cacheBreak) }
                // A plan turn's server offers the read-mostly surface: its credential says so.
                // The mode's quotas ride on the credential row; `brahma mcp` enforces them from there.
                turnToken = kind == .plan
                    ? try store.issueTurnCredential(turnId: turn.id, kind: "plan", itemId: scope.itemId, quotas: mode.quotas)
                    : try store.issueTurnCredential(turnId: turn.id, quotas: mode.quotas)
            }
            try store.setTurnMode(turnId: turn.id, decision: mode)
            var request = try turnRequest(
                mcpConfigPath: try MCPConfig.write(paths: paths, executable: mcpExecutable, agent: agent, turnToken: turnToken,
                                                   reviewItem: review?.item.key, audit: audit != nil,
                                                   environment: mcpEnvironment))
            // The test keys the holder took with `use_secret` (Task 4-wire): only a work turn on the leased item, applied by the
            // runner after `ChildEnvironment`'s drop step; a plan, review, audit or notice turn gets none. Read after the sandbox
            // gate (a read, nothing consumed), never part of the gated shape.
            // Never on an Ultra turn (fix round 2, N5): its workflow agents share the parent's environment and MCP server.
            if kind == .work, mode.workflow == nil, let leased = leaseHead?.item {
                request.secrets = try store.injectableSecrets(agentId: agent.id, itemId: leased.id)
            }
            let compiled = TurnProfileCompiler.profile(for: request)
            // Backstop: the shape that runs is the shape that was gated (they differ only if a string-free field changed).
            if let gate, CanaryShape.key(compiled.settings, launch: CanaryShape.launch(mode)) != gatedShape {
                try await requireSandboxVerified(gate: gate, settings: compiled.settings, agent: agent, company: company,
                                                 launch: CanaryShape.launch(mode))
            }
            // Plan L Task 14 (fix round 1, S1): every turn of an imported company the owner has not trusted (work, plan, review,
            // audit) reads the imported tree, so it is tainted at launch with the import's source, wherever it was scheduled from.
            if let imported = try store.importTaint(companyId: company.id) {
                try markTaintedOrFlag(agent: agent, source: imported)
                taintMarked = true
            }
            // Pre-taint (Task 10, F4): a turn that can fan out is tainted at launch until this CLI build passed V-1 (PostToolUse
            // fires for sub-agent and workflow calls), unless it has no network and no web tools.
            var builtins = Set(compiled.tools ?? compiled.allowedTools)
            if compiled.settings.enableWorkflows == true { builtins.insert("Workflow") }
            if !builtins.isDisjoint(with: ["Task", "Agent", "Workflow"]) {
                let verified = await postToolGateVerified()
                if TaintPolicy.preTaint(tools: builtins, network: sandboxed?.scope.network, hookVerified: verified) {
                    try markTaintedOrFlag(agent: agent, source: TaintPolicy.preTaintSource)
                    taintMarked = true
                }
            }
            // I2: the turn reads what a tainted session wrote (a message, a work notice, the item's hand-off or review notes).
            if !taintMarked, let relayed = ctx?.relayedTaint {
                try markTaintedOrFlag(agent: agent, source: relayed)
                taintMarked = true
            }
            // S19: a review or audit of marked work is tainted at launch too (its verdict tool stays exempt).
            if !taintMarked, let review, review.untrusted {
                try markTaintedOrFlag(agent: agent, source: "relayed: \(review.item.key) under review")
                taintMarked = true
            }
            if !taintMarked, let audit, audit.untrusted {
                try markTaintedOrFlag(agent: agent, source: TaintPolicy.auditRelaySource)
                taintMarked = true
            }
            let settingsText = try TurnProfileCompiler.settingsJSON(compiled)
            try await blocking.tryRun { try SettingsFile.write(settingsText, to: settingsFile) }
            // A review session is never recorded as the agent's own.
            var sessionMarked = wasResume || review != nil || audit != nil
            sentRequest = request
            if let labWorkspace {
                let (store, handle, companyId) = (self.store, agent.name, agent.companyId)
                labAtStart = await blocking.run {
                    LabProvenance.commitSet(store: store, workspace: labWorkspace, handle: handle, companyId: companyId)
                }
            }
            // Plan C Task C4c: the show turn takes its requests (and their DMs) as it starts; its session's cost so far is what
            // its soft cap is measured past (the CLI's total is cumulative over `--resume`).
            if showTurn {
                try store.bindShowTurn(turnId: turn.id, agentId: agent.id, requestIds: showRequests.map(\.id))
                showBound = true
                showCostBefore = wasResume ? store.sessionCostBefore(sessionId: sent.sessionId, turnId: turn.id) : 0
            }
            let showCalibration = showTurn ? ((try? store.usageCalibration()) ?? UsageCalibration()) : UsageCalibration()
            // Leaving the loop early (`break`) drops the stream, which terminates the child process.
            do {
                events: for try await event in runner.run(request) {
                    launched = true
                    state.apply(event)
                    switch event {
                    case .initialized(_, let reported):
                        sawInit = true
                        initModel = reported
                        if !sessionMarked {
                            try store.markSessionStarted(agentId: agent.id, scope: scope, cwd: workingDirectory, model: model, tools: toolsKey,
                                                         mountSetHash: mountSetHash)
                            sessionMarked = true
                        }
                    case .initInfo(let info):
                        if let why = TurnAudit.initViolation(info, expectations: request.expectations) {
                            abortReason = why
                            break events
                        }
                    case .rateLimit(let info):
                        // A garbled event parses as "unknown"; saving it would close the gate for everyone.
                        guard info.status != "unknown" else { continue }
                        lastInfo = info
                        try store.saveRateLimit(info)
                    case .spawned(let pid):
                        leaderPid = pid
                        try store.setTurnPid(turnId: turn.id, pid: pid)
                    case .taskProgress:
                        // Task 14u, the watchdog's agent-count kill: past the variant's distinct workflow agents the turn is
                        // stopped (SIGINT to its leader, then its whole group as the stream is dropped) and charged its cap.
                        if let w = mode.workflow, state.workflowAgentIds.count > w.variant.agentKill {
                            agentCapped = true
                            Self.interruptLeader(leaderPid)
                            break events
                        }
                    case .sandboxNote(let text):
                        try store.appendEvent(ActivityEvent(companyId: agent.companyId, agentId: agent.id, turnId: turn.id,
                                                            kind: .error, text: text, createdAt: clock()))
                    case .result(let r) where showTurn:
                        // Plan C Task C4c: a show turn past its soft cap (`ShowTurnCaps.softCap5h` of 5H) is stopped.
                        if let total = r.costUSD,
                           ShowCost.share5h(max(0, total - showCostBefore), calibration: showCalibration) > ShowTurnCaps.softCap5h {
                            showCapped = true
                            break events
                        }
                    case .toolCall(let name, let input):
                        // The backup taint path (Task 10): every tool call, the sub-agents' and workflow agents' included. Every
                        // source is recorded, not only the first (2d): a verdict's exemption depends on all of them.
                        let companyId = agent.companyId
                        if let source = TaintPolicy.source(toolName: name, toolInput: input, publisher: { id in
                            (try? store.extensionPublisher(companyId: companyId, extId: id)) ?? nil
                        }), recordedSources.insert(source).inserted {
                            try markTaintedOrFlag(agent: agent, source: source)
                            taintMarked = true
                        }
                    case .toolUse(let name, _):
                        // Company tools log their own event from the MCP server.
                        guard !name.hasPrefix("mcp__company__") else { continue }
                        try store.appendEvent(ActivityEvent(companyId: agent.companyId, agentId: agent.id, turnId: turn.id,
                                                            kind: .toolUse, text: "@\(agent.name) \(name)", createdAt: clock()))
                    default:
                        break
                    }
                }
            } catch { runnerError = error; throw error }
        } catch let e as WorktreeUnavailable {
            worktreeUnavailable = e
        } catch let e as ModeNotLaunched {
            notLaunched = e
        } catch is SandboxNotVerified {
            sandboxUnverified = true
        } catch {
            failure = String(describing: error)
        }
        // The runner stopped the child it had just spawned because no exact record could name it (its start time unreadable,
        // or its leader record unwritable). Its `.spawned` event made it look launched, but the turn never ran (Task 9c fix
        // round 4): for every account it was not launched. Its one-use grants are given back, an Ultra turn gets no charge
        // floor and keeps its approval, and the item is charged nothing. Taint and the lab still treat it as launched (fail
        // closed: a process did exist).
        let unrecorded: Bool
        switch runnerError as? TurnError {
        case .startNotRecorded?, .leaderNotRecorded?: unrecorded = true
        default: unrecorded = false
        }
        let ran = launched && !unrecorded
        if !ran, !spentGrants.isEmpty {
            let ids = spentGrants
            attempt { try store.restoreGrants(ids: ids) }
            log("@\(agent.name)'s turn did not start: its one-use grants were given back")
        }

        let now = clock()
        // The last result of the turn (the usage of all of them added up).
        let result = state.result
        // Only a rejection or overage is a limit; `allowed_warning` (any window) is not.
        let limited = lastInfo.map(UsageGate.isHardLimit) ?? false
        let end: TurnEnd
        // Set where the turn ends on the fixed infrastructure delay with no infrastructure class (a missing worktree, a turn
        // that could not be recorded): the delay outlives `noteOutcome` (it would otherwise retry on the very next tick).
        var infraDelayed = false
        // The hold for an active usage limit; HTTP 429 with no rejecting rate-limit event records one so the gate closes for
        // every company.
        func noteUsageLimit() -> Date {
            let until = Self.usageUntil(limited ? lastInfo?.resetsAt : nil, now: now)
            if !limited {
                attempt {
                    try store.saveRateLimit(RateLimitInfo(status: "rejected", resetsAt: until, rateLimitType: nil,
                                                          isUsingOverage: false, fiveHourUtilization: nil,
                                                          sevenDayUtilization: nil, observedAt: now))
                }
            }
            return until
        }
        if sandboxUnverified {
            // Nothing was started: the agent is ready again with no penalty and waits for the canary (`canaryHeld`).
            end = .interrupted()
        } else if let notLaunched {
            // Nothing was started. The no-launch rule blocks the item over budget (its lease goes back, the manager is told) and
            // the agent is ready again with no penalty; a model outside the allowlist is the owner's to fix.
            if let itemId = notLaunched.overBudgetItem {
                attempt { try store.blockOverBudget(itemId: itemId, agentId: agent.id, now: now) }
                end = .interrupted()
            } else {
                if agent.consecutiveFailures == 0 {
                    attempt {
                        try EngineAlerts.raise(store: store, text: "@\(agent.name)'s turns do not start: \(notLaunched.reason). Set an "
                                               + "allowed model (haiku, sonnet, opus or auto).", now: now, reason: "model-pin",
                                               scope: .company(agent.companyId))
                    }
                }
                end = .failed(notLaunched.reason)
            }
        } else if let unavailable = worktreeUnavailable, unavailable.review {
            // A reviewer holds no lease: the missing worktree is an undecided review attempt (three of them escalate), and the
            // agent waits out the short fixed infrastructure delay. The engine's own fault: the owner hears of it.
            store.noteWorktreeSetupFailure(companyId: agent.companyId, what: "the worktree of \(unavailable.key) for its review",
                                           error: WorktreeSetupError(reason: unavailable.reason), now: now)
            attempt { try store.noteReviewWorktreeFailure(itemId: unavailable.itemId, agentId: agent.id, reason: unavailable.reason, now: now) }
            await setInfraCooldown(agentId: agent.id, until: now.addingTimeInterval(EngineHealth.infraCooldown))
            infraDelayed = true
            end = .interrupted()
        } else if let unavailable = worktreeUnavailable {
            // Not the agent's fault and nothing ran: back to ready after the short fixed infrastructure delay. After
            // `maxWorktreeFailures` in a row the lease is given back instead of retrying for its whole lifetime. The engine's
            // own fault: the owner hears of it.
            store.noteWorktreeSetupFailure(companyId: agent.companyId, what: "the worktree of \(unavailable.key) for @\(agent.name)'s turn",
                                           error: WorktreeSetupError(reason: unavailable.reason), now: now)
            if await noteWorktreeFailure(itemId: unavailable.itemId) >= Self.maxWorktreeFailures {
                await clearWorktreeFailures(itemId: unavailable.itemId)
                attempt {
                    try store.appendEvent(ActivityEvent(
                        companyId: agent.companyId, agentId: agent.id, turnId: turn.id, kind: .error,
                        text: "@\(agent.name) turn not started: the worktree of \(unavailable.key) is missing and could not be created "
                            + "(\(Self.maxWorktreeFailures) tries): \(unavailable.reason); lease released",
                        createdAt: now))
                    try store.releaseLease(itemId: unavailable.itemId, agentId: agent.id,
                                           note: "the worktree could not be created", now: now)
                }
            } else {
                log("worktree of \(unavailable.key) unavailable for @\(agent.name): \(unavailable.reason)")
            }
            await setInfraCooldown(agentId: agent.id, until: now.addingTimeInterval(EngineHealth.infraCooldown))
            infraDelayed = true
            end = .interrupted()
        } else if Task.isCancelled {
            end = .interrupted(partial: result)
        } else if abortReason != nil {
            end = .interrupted()
        } else if agentCapped || showCapped {
            end = .interrupted(partial: result)
        } else if unrecorded {
            // Nothing ran: the runner killed the child it had just spawned because no exact record could name it (Task 9c fix
            // rounds 3 and 4). The engine's fault, not the agent's: `interrupted`, so no charge to the agent or the item (no
            // failure count, no backoff, the lease kept, nothing spent: `ran` above). It is retried after the short fixed
            // infrastructure delay, never on the next tick, and after `maxUnrecordedTurns` in a row the owner is alerted.
            let why = if case .startNotRecorded? = runnerError as? TurnError {
                "the start time of its process could not be read, so the engine could not record it"
            } else {
                "the engine could not write the record of its process"
            }
            attempt {
                try store.appendEvent(ActivityEvent(
                    companyId: agent.companyId, agentId: agent.id, turnId: turn.id, kind: .error,
                    text: "@\(agent.name)'s turn was stopped before it ran: \(why); it is retried in "
                        + "\(Int(EngineHealth.infraCooldown)) s",
                    createdAt: now))
            }
            await setInfraCooldown(agentId: agent.id, until: now.addingTimeInterval(EngineHealth.infraCooldown))
            infraDelayed = true
            end = .interrupted()
        } else if case .interrupted? = runnerError as? TurnError {
            // SIGTERM, or killed with background work pending (even after an early result): not the agent's doing.
            end = .interrupted(partial: result)
        } else if case .timedOut? = runnerError as? TurnError {
            // The engine's own wall clock killed it (even after an early result, with background work still pending): never a
            // success. Under an active usage limit it is held until the reset (not the agent's fault); otherwise it failed like
            // any other timeout (normal backoff) and its usage is still booked and budgeted.
            if limited || result?.apiErrorStatus == 429 {
                end = .usageLimited(until: noteUsageLimit(), summary: result?.text)
            } else {
                end = .failed(failure ?? "timed out", nil, partial: result)
            }
        } else if let r = result, !r.isError {
            // A completed turn always counts, even if it also hit the limit: re-running it would repeat its posts.
            end = .succeeded(r, usageHold: limited ? Self.usageUntil(lastInfo?.resetsAt, now: now) : nil)
        } else if let r = result, r.stopReason != nil {
            // A controlled stop (`--max-turns`, `--max-budget-usd`) is the engine's own cap, decided before the infrastructure
            // classifier ever sees the text: not infra, no backoff, counted in the item's usage and judged normally.
            end = .capped(r, usageHold: limited ? Self.usageUntil(lastInfo?.resetsAt, now: now) : nil)
        } else if result?.apiErrorStatus == 429 || limited {
            end = .usageLimited(until: noteUsageLimit(), summary: result?.text)
        } else if let failure {
            // Only the runner's launch error is classifiable; a timeout or "exited without a result" carries stderr.
            var input: InfraInput?
            if let runnerError, !(runnerError is TurnError) { input = InfraInput(text: failure, status: nil) }
            end = .failed(failure, input, partial: result)
        } else if let r = result {
            end = .failed(r.text ?? r.subtype, InfraInput(text: r.text ?? "", status: r.apiErrorStatus, subtype: r.subtype), partial: r)
        } else {
            end = .failed("claude exited without a result")
        }

        // A plan turn must not have changed the worktree: the engine checks and resets before anything else looks at it (git,
        // off the cooperative pool).
        if let plan { await blocking.run { self.finishPlanTurn(plan, agent: agent, end: end, now: now) } }
        // The holder's own commits of this turn become the recorded head when they descend from it (or a submit the engine
        // accepted recorded a new one); a rewrite that was not submitted in this turn flags the branch instead. Only when
        // continuity held at the start, and only while the agent still holds the lease (git, off the cooperative pool).
        if let leaseHead, leaseHead.held {
            let (store, git, key) = (self.store, leaseHead.git, leaseHead.item.key)
            await blocking.run {
                do {
                    guard let head = try git.head(of: git.branchRef(key: key)) else { return }
                    try store.recordTurnEndHead(item: leaseHead.item, agent: agent, head: head,
                                                isDescendant: { try git.isAncestor($0, of: head) }, now: now)
                } catch { self.log("could not record the head of \(key): \(error)") }
            }
        }

        // Plan C2a: a turn of a session that read outside content records the commits it made on every item branch it touched
        // (rulings 4 and 6: what it held as it started, everything it claimed during the turn, even released since, and what it
        // holds now; `recordTurnTaints`). The taint is the session's now (ML's `currentTaint`, so a resumed turn that read
        // nothing itself still counts; unreadable: tainted), read before any fresh-session reset below. Git, off the
        // cooperative pool.
        if launched {
            let (store, paths, turnId, started, leasedItem) = (self.store, self.paths, turn.id, heldAtStart, leaseHead?.item.id)
            let held = Array(heldItemsAtStart)
            await blocking.run {
                let source: String?
                do { source = try store.currentTaint(agentId: agent.id, paths: paths) } catch { source = "session" }
                guard let source else { return }
                store.recordTurnTaints(companyId: agent.companyId, agentId: agent.id, turnId: turnId, heldAtStart: started,
                                       heldItemsAtStart: held, leasedItemId: leasedItem, source: source, now: now)
            }
        }

        // Plan C4b (controller ruling): every launched turn records the commits it made on the item branches it held or claimed
        // (`recordTurnCommits`), the only source of commit authorship. Git, off the cooperative pool.
        if launched {
            let (store, turnId, started) = (self.store, turn.id, heldAtStart)
            await blocking.run {
                store.recordTurnCommits(companyId: agent.companyId, agentId: agent.id, turnId: turnId, heldAtStart: started, now: now)
            }
        }

        // A resumed session that no longer exists: it is reset and the agent is ready again at once (no penalty). The next
        // turn starts a fresh session. A fresh session that is "not found" again is an ordinary failure.
        var sessionLost: SessionScope?
        if case .failed(let text, _, _) = end, wasResume, !isReview,
           Self.isSessionNotFound([text, failure, result?.text].compactMap { $0 }.joined(separator: "\n")) {
            sessionLost = scope
        }
        // An infrastructure failure puts the agent on its fixed cooldown before the turn is recorded, so there is no
        // moment at which it is `ready` and eligible again.
        if case .failed(_, let input?, _) = end, EngineHealth.classify(input) != .none {
            await setInfraCooldown(agentId: agent.id, until: now.addingTimeInterval(EngineHealth.infraCooldown))
        }
        let use = !isReview && (wasResume || sawInit)
            ? SessionUse(scope: scope, model: keepModel ? nil : usedModel, tools: toolsKey, cwd: workingDirectory) : nil
        var infra = InfraClass.none
        let telemetry = TurnTelemetry(
            toolSignature: state.toolSignature, workflowAgents: state.workflowAgentIds.count,
            subagentsSpawned: state.subagentsSpawned,
            modeNote: state.effortCapRequested.map { "effort '\($0)' exceeded the org cap and was lowered" },
            observation: state.observation,
            modeModel: modeDecision?.model, modeEffort: modeDecision?.effort,
            stopReason: agentCapped ? UltraAccounting.agentCapStop : nil,
            chargeAtLeastLE: ultraReserved && ran
                ? Self.ultraChargeFloor(ultraPlan, end: end, runnerError: runnerError, agentCapped: agentCapped) : nil,
            releasesUltra: ultraReserved && ran)
        attempt {
            infra = try store.endTurn(agentId: agent.id, turn: turn, end: end,
                                      deliveredItemIds: (ctx?.inboxItemIds ?? []) + (ctx?.quietItemIds ?? []),
                                      deliveredNoticeIds: ctx?.noticeIds ?? [], sessionReset: sessionLost, sessionUse: use,
                                      telemetry: telemetry, taintHome: paths.home, now: now)
        }
        // Plan C Task C4c: the show turn's cost lands on its requests; one it left open is answered by its DM to the owner, or
        // expires (a soft-cap stop says so).
        if showBound {
            let ownCost = ((try? store.turn(id: turn.id)) ?? nil)?.costUSD ?? result?.costUSD.map { max(0, $0 - showCostBefore) }
            attempt {
                if showCapped { try store.expireShowTurn(turnId: turn.id, agentId: agent.id, reason: "stopped past its soft cap of \(Int(ShowTurnCaps.softCap5h))% of 5H", now: now) }
                try store.finishShowTurn(turnId: turn.id, agentId: agent.id, startedAt: turn.startedAt, costUSD: ownCost, now: now)
            }
        }
        // Task 10: the lab's new commits are recorded with the session's taint state, then a fresh session a refused high-risk
        // call asked for is applied (both flags and the flag file cleared). Git, off the cooperative pool.
        // A tainted session marks every item it holds at turn end, leases taken mid-turn included (S21), and (Plan C Ruling 20)
        // every item the turn touched and released: held as it started (R4-3: from its leases, whether or not git could read
        // the branch head then, and its own lease), or in its claim log. The hook flag is read under `paths`.
        if launched, !isReview {
            attempt {
                try store.markHeldItemsIfTainted(agentId: agent.id, turnId: turn.id, heldAtStart: Array(heldItemsAtStart), home: paths.home)
            }
        }
        if launched, let labWorkspace {
            let (store, handle, turnId, ended, start) = (self.store, agent.name, turn.id, now, labAtStart)
            // The row OR the flag file (10b, I2); a tainted turn's lab is marked here, before the flag can be cleared below. S30: when
            // that could not be written, the session keeps its taint and its flag file (no clear below): fail closed.
            let tainted: Bool
            do { tainted = try store.turnEndTaint(agentId: agent.id, home: paths.home, now: ended) } catch {
                tainted = true
                labMarkUnwritten = true
                log("@\(agent.name)'s lab mark could not be written (\(error)); its session stays tainted")
            }
            let outcome = await blocking.run {
                LabProvenance.record(store: store, workspace: labWorkspace, handle: handle, companyId: agent.companyId,
                                     agentId: agent.id, turnId: turnId, tainted: tainted, now: ended, startCommits: start)
            }
            if case .refused(let why) = outcome { log("@\(agent.name)'s lab commits were not recorded (tainted instead): \(why)") }
        }
        if !labMarkUnwritten { attempt { try store.clearTaintIfRequested(agentId: agent.id, scope: scope, now: now) } }
        // S19: a review or audit runs in a throwaway session. Taint it took there is recorded on the turn and on what it wrote;
        // it does not outlive the session when the agent's own session was clean before.
        if isReview, !agent.sessionTainted { attempt { try store.endThrowawaySessionTaint(agentId: agent.id) } }
        // Task 13a: the turn's slice of the Claude session transcript, redacted and stored. Never fails the turn.
        if let transcripts, let sessionId = state.result?.sessionId ?? state.inits.last?.sessionId ?? (sawInit ? sentRequest?.agent.sessionId : nil) {
            let (store, turn, ended) = (self.store, turn, now)
            _ = await blocking.run { transcripts.capture(turn: turn, sessionId: sessionId, store: store, now: ended) }
        }
        if let why = abortReason {
            // The hold first, on its own (S4 fix round 1, M9): an alert that throws never skips it.
            attempt { try store.holdForDoctor(agentId: agent.id, reason: why, now: now) }
            attempt {
                try EngineAlerts.raise(store: store, text: "A turn of @\(agent.name) was stopped at start: \(why). Its next turn "
                                       + "waits until `brahma doctor` passes again.", now: now, reason: "init", scope: .allCompanies(.cli))
            }
        } else if let r = result, let sentRequest {
            auditResult(r, request: sentRequest, initModel: initModel, agent: agent, turn: turn, now: now)
        }
        if let requested = state.effortCapRequested {
            attempt {
                try store.appendEvent(ActivityEvent(
                    companyId: agent.companyId, agentId: agent.id, turnId: turn.id, kind: .usage,
                    text: "@\(agent.name) asked for effort '\(requested)', which exceeds the org cap; the turn ran at the cap",
                    createdAt: now))
            }
        }
        if ultraReserved, let plan = ultraPlan {
            await endUltraRun(plan, turnId: turn.id, companyId: agent.companyId, launched: ran)
        }
        // A persistent cause (the process table or the run directory failing the engine) would retry forever, every 15 s:
        // after `maxUnrecordedTurns` such turns in a row the owner hears of it once (engine-written text only).
        if await noteUnrecordedTurn(agentId: agent.id, unrecorded) == Self.maxUnrecordedTurns {
            attempt {
                try EngineAlerts.raise(
                    store: store,
                    text: "@\(agent.name)'s last \(Self.maxUnrecordedTurns) turns were stopped before they ran: the engine could not "
                        + "record their process (its start time could not be read, or the record could not be written). It keeps "
                        + "retrying every \(Int(EngineHealth.infraCooldown)) s. If this goes on, relaunch Brahma.",
                    now: now, reason: Self.unrecordedTurnReason, scope: .company(agent.companyId))
            }
        }
        let outcome = end.outcome
        await noteOutcome(agentId: agent.id, infra: infra, interrupted: outcome == .interrupted, keepCooldown: infraDelayed, now: now)
    }

    /// `markTainted`, and when that write fails the flag file (fail closed, M2) before the error ends the turn.
    nonisolated func markTaintedOrFlag(agent: Agent, source: String) throws {
        do { try store.markTainted(agentId: agent.id, source: source, now: clock()) } catch {
            TaintFlag.write(home: paths.home, agentId: agent.id, source: TaintPolicy.hookErrorSource)
            throw error
        }
    }

    /// The write barrier of a plan turn: the worktree must be clean and `HEAD` where it was. Otherwise the engine resets it,
    /// records `planTurnWrote` and does not count the plan. A good plan is read from the plans directory (else the result
    /// text) and recorded as `planWritten`.
    private nonisolated func finishPlanTurn(_ plan: PlanWatch, agent: Agent, end: TurnEnd, now: Date) {
        var wrote: [String] = []
        let dirty = (try? plan.git.isDirty(in: plan.worktree)) ?? true
        let head = try? plan.git.headCommit(in: plan.worktree)
        if dirty { wrote.append("uncommitted changes") }
        if head != plan.preHead { wrote.append("a commit") }
        // Ignored files and the repository's own config and hooks are put back as well.
        // A barrier that cannot tell (a listing failed, timed out or was cut) fails closed: the turn counts as a write.
        do { wrote += try plan.git.enforcePlanBarrier(plan.barrier, key: plan.key, in: plan.worktree) }
        catch let e as GitWorkspace.PlanBarrierError { wrote += e.found; wrote.append(e.description) }
        catch { wrote.append("barrier check failed: \(error)") }
        if !wrote.isEmpty {
            attempt { try plan.git.resetHard(in: plan.worktree, to: plan.preHead) }
            let shown = wrote.count > Self.maxBarrierFindings
                ? wrote.prefix(Self.maxBarrierFindings) + ["\(wrote.count - Self.maxBarrierFindings) more"] : wrote[...]
            let detail = String(shown.joined(separator: ", ").prefix(Self.maxBarrierDetail))
            attempt { try store.recordPlanTurnWrote(itemId: plan.itemId, agentId: agent.id, detail: detail, now: now) }
            return
        }
        guard case .succeeded(let r, _) = end else { return }
        let text = Self.readPlan(in: plan.directory) ?? String((r.text ?? "").prefix(Self.maxPlanBytes))
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        attempt { try store.recordPlan(itemId: plan.itemId, agentId: agent.id, text: text, now: now) }
    }

    static let maxPlanBytes = 64 * 1024
    static let maxBarrierFindings = 20
    static let maxBarrierDetail = 2000

    /// `<ws>/.brahma/plans/<KEY>/`, a real directory inside the workspace (`EngineFiles`); nil when any part of it is a link
    /// or not a directory (a plan directory the agent redirected is never used; with `store` the owner is alerted).
    nonisolated static func planDirectory(workspace: URL, key: String, store: Store? = nil, companyId: String? = nil) -> URL? {
        do { return try EngineFiles.directory(workspace: workspace, ".brahma/plans/\(key)") } catch {
            if let refused = error as? UnsafeEngineFile, let store, let companyId { store.alertEngineFile(refused, companyId: companyId) }
            return nil
        }
    }

    /// The newest plan file: only regular, non-symlink, single-link `.md` files of this user (`EngineFiles.copyProblem`, S7)
    /// that really sit in `directory`, at most `maxPlanBytes` of it. The file is opened without following a link and must
    /// still be the file that was checked.
    nonisolated static func readPlan(in directory: URL, limit: Int = maxPlanBytes) -> String? {
        let fm = FileManager.default
        guard (try? fm.attributesOfItem(atPath: directory.path))?[.type] as? FileAttributeType == .typeDirectory else { return nil }
        let base = directory.resolvingSymlinksInPath().standardizedFileURL.path
        var best: (url: URL, mtime: timespec, device: dev_t, inode: ino_t)?
        for name in (try? fm.contentsOfDirectory(atPath: directory.path)) ?? [] where name.hasSuffix(".md") {
            let url = directory.appending(path: name)
            var st = stat()
            guard lstat(url.path, &st) == 0, EngineFiles.copyProblem(st) == nil,
                  url.resolvingSymlinksInPath().standardizedFileURL.deletingLastPathComponent().path == base else { continue }
            let m = st.st_mtimespec
            if let b = best, (m.tv_sec, m.tv_nsec) <= (b.mtime.tv_sec, b.mtime.tv_nsec) { continue }
            best = (url, m, st.st_dev, st.st_ino)
        }
        guard let best else { return nil }
        let fd = open(best.url.path, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard fd >= 0 else { return nil }
        let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        defer { try? handle.close() }
        var st = stat()
        guard fstat(fd, &st) == 0, EngineFiles.copyProblem(st) == nil,
              st.st_dev == best.device, st.st_ino == best.inode else { return nil }
        guard let data = try? handle.read(upToCount: limit) else { return nil }
        let text = String(decoding: data, as: UTF8.self)
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text
    }

    /// `claude --resume` of a session it never persisted fails the same way forever; spot that so the next turn
    /// starts a fresh session instead.
    static func isSessionNotFound(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("no conversation found") || (t.contains("session") && t.contains("not found"))
    }

    /// When a usage-limited agent may try again: the real reset if it is still ahead, else `usageRetry` from now,
    /// so a missing or stale (past) `resetsAt` cannot unblock it on the next tick and re-hit the limit every tick.
    static func usageUntil(_ resetsAt: Date?, now: Date) -> Date {
        if let resetsAt, resetsAt > now { return resetsAt }
        return now.addingTimeInterval(usageRetry)
    }

    nonisolated func attempt(_ body: () throws -> Void) {
        do { try body() } catch { log("\(error)") }
    }

    nonisolated func log(_ message: String) {
        FileHandle.standardError.write(Data("brahma orchestrator: \(message)\n".utf8))
    }
}

/// What a plan turn needs afterwards: where to look for a write and where to go back to.
struct PlanWatch {
    var git: GitWorkspace
    var worktree: URL
    var preHead: String
    var itemId: String
    var key: String
    var directory: URL
    var barrier: GitWorkspace.PlanBarrier
}

/// The session a turn used, remembered when the turn ends (warm rule, size rule, cache-break detection).
struct SessionUse: Sendable {
    var scope: SessionScope
    /// Nil keeps the stored model (an item session's model is fixed).
    var model: String?
    var tools: String
    var cwd: String
}

/// A leaseholder's worktree is missing and could not be recreated.
struct WorktreeUnavailable: Error { var itemId: String; var key: String; var reason: String; var review = false }

/// What a worktree that could not be made came to, as text (`WorktreeUnavailable.reason`), for the owner's alert.
struct WorktreeSetupError: Error, CustomStringConvertible { var reason: String; var description: String { reason } }

enum TurnEnd {
    /// `usageHold`: the turn completed but also hit the usage limit; if work is pending, the agent waits until then.
    case succeeded(TurnResult, usageHold: Date?)
    /// The summary, and the error text the infrastructure classifier may read (an error `result` event or a launch error).
    /// `partial`: the result the turn did print (an error result, or an early result before an engine wall-clock kill). Its
    /// tokens and cost are still recorded and the budget step runs; the turn stays failed.
    case failed(String, InfraInput? = nil, partial: TurnResult? = nil)
    /// A controlled stop: the engine's own `--max-turns` or `--max-budget-usd` ended the turn. It did its work, so it is
    /// delivered, billed and budgeted like a success, but recorded `failed` with a `stopReason`; it never counts against the
    /// agent (no backoff) and is never infrastructure.
    case capped(TurnResult, usageHold: Date?)
    case usageLimited(until: Date, summary: String?)
    /// Stopped before it finished (SIGTERM, a kill with background work pending). An engine wall-clock kill is a `failed` timeout. `partial` is the early
    /// result, whose tokens and cost are still recorded. Never counted against the agent.
    case interrupted(partial: TurnResult? = nil)

    var outcome: TurnOutcome {
        switch self {
        case .succeeded: .succeeded
        case .failed, .capped: .failed
        case .usageLimited: .usageLimited
        case .interrupted: .interrupted
        }
    }
}

/// Retry backoff after `failures` consecutive failed turns: 30 s doubling, capped at 30 min.
func retryBackoff(failures: Int) -> TimeInterval {
    let exponent = min(max(failures - 1, 0), 10)
    return min(30 * Double(1 << exponent), 30 * 60)
}

extension Store {
    /// Transitions only if the freshly read agent still satisfies `condition`, in one transaction.
    @discardableResult
    func transition(agentId: String, to: AgentState, blocker: Blocker? = nil, now: Date,
                    if condition: (Agent) -> Bool) throws -> Agent? {
        try writer.write { db in
            guard let a = try Agent.fetchOne(db, key: agentId), condition(a) else { return nil }
            return try transitionAndRelease(db: db, agentId: agentId, to: to, blocker: blocker, now: now)
        }
    }

    /// ready → running, a new in-progress turn and a `turnStarted` event, atomically. Nil if the agent is no
    /// longer ready (or was paused) by the time the write runs, or while the owner's purge holds the company's
    /// `PurgeFence` (C2b fix round 1: the turn is recorded under the fence held shared, so a purge's running-turn check
    /// and its git prune never race a turn start; the agent stays ready and starts on a later tick).
    func beginTurn(agentId: String, now: Date) throws -> (Agent, Turn)? {
        guard let home = dataHome ?? refHooks.fenceHome else { return try beginTurnRecord(agentId: agentId, now: now) }
        guard let companyId = try writer.read({ db in
            try String.fetchOne(db, sql: "SELECT companyId FROM agent WHERE id = ?", arguments: [agentId])
        }) else { return nil }
        return try PurgeFence.withShared(home: home, companyId: companyId, wait: .zero) {
            try beginTurnRecord(agentId: agentId, now: now)
        } ?? nil
    }

    private func beginTurnRecord(agentId: String, now: Date) throws -> (Agent, Turn)? {
        try writer.write { db in
            guard let a = try Agent.fetchOne(db, key: agentId), a.state == .ready, !a.paused else { return nil }
            let agent = try Store.transition(db: db, agentId: agentId, to: .running, now: now)
            var turn = Turn(id: UUID().uuidString, agentId: agentId, companyId: agent.companyId, startedAt: now,
                            endedAt: nil, outcome: .inProgress, summary: nil, costUSD: nil)
            try turn.insert(db)
            // A pending fresh-session reason is applied once the turn's scope is known (`performTurn`, B-M12).
            try ActivityEvent(companyId: agent.companyId, agentId: agentId, turnId: turn.id, kind: .turnStarted,
                              text: "@\(agent.name) turn started", createdAt: now).insert(db)
            return (agent, turn)
        }
    }

    func markSessionStarted(agentId: String) throws {
        try writer.write { db in
            _ = try Agent.filter(key: agentId).updateAll(db, Column("sessionStarted").set(to: true))
        }
    }

    /// Records the turn outcome and moves the agent on, in one transaction, so a message that arrives while the
    /// turn ends either lands before the pending-inbox check or wakes the agent from its new state.
    /// `sessionReset`: the resumed session no longer exists. It is reset (a new id, so the next turn starts over with
    /// `--session-id`, the role prompt and the orientation), the turn is recorded `failed` with `sessionResetReason`, and the
    /// agent is `ready` again at once: no backoff, `consecutiveFailures` unchanged, the inbox undelivered. Budgets, the watchdog
    /// and facts ignore the turn. `sessionUse`: the session the turn ran in, noted for the next turn's warm and size rules.
    /// `taintHome`: the data home whose taint flag files the episode's taint reads (nil: the store's own).
    ///
    /// A failure whose error text classifies as network/account is recorded `failed` with `infra = true`: the agent
    /// goes back to `ready` with no backoff, `consecutiveFailures` is unchanged and the inbox stays undelivered.
    /// The 5th consecutive infra failure of one agent is recorded as an ordinary failure. Returns the infra class
    /// that was applied (`.none` for everything else).
    @discardableResult
    func endTurn(agentId: String, turn: Turn, end: TurnEnd, deliveredItemIds: [Int64], deliveredNoticeIds: [Int64] = [],
                 sessionReset: SessionScope? = nil, sessionUse: SessionUse? = nil, telemetry: TurnTelemetry = TurnTelemetry(),
                 taintHome: URL? = nil, now: Date) throws -> InfraClass {
        try writer.write { db in
            var summary: String?
            var cost: Double?
            var infraClass = InfraClass.none
            switch end {
            case .succeeded(let r, _): summary = try redact(r.text)
            case .capped(let r, _): summary = try redact(r.text ?? r.subtype as String?)
            case .failed(let text, let input, _):
                summary = try redact(text)
                if let input { infraClass = EngineHealth.classify(input) }
            case .usageLimited(_, let text): summary = try redact(text)
            case .interrupted: summary = "interrupted"
            }
            // The result's total is cumulative over `--resume`: the turn's own cost is the difference (Task 14a, L-4).
            let accounting = try Store.accounting(db: db, turnId: turn.id, end: end)
            cost = accounting.cost
            var completed = false
            switch end {
            case .succeeded, .capped: completed = true
            default: break
            }
            if completed {
                try Store.markDelivered(db: db, itemIds: deliveredItemIds, turnId: turn.id)
                try Store.markNoticesDelivered(db: db, ids: deliveredNoticeIds, turnId: turn.id)
            }
            guard var agent = try Agent.fetchOne(db, key: agentId) else { throw StoreError.notFound }
            // The 5th infra failure in a row is an ordinary failure; any non-infra outcome resets the count.
            if infraClass != .none {
                if agent.consecutiveInfraFailures + 1 >= EngineHealth.maxConsecutiveInfra {
                    infraClass = .none
                    agent.consecutiveInfraFailures = 0
                } else {
                    agent.consecutiveInfraFailures += 1
                }
            } else {
                agent.consecutiveInfraFailures = 0
            }
            // A session that is gone is no penalty, unless the failure is an infrastructure one.
            let lostScope = infraClass == .none ? sessionReset : nil
            var reported: String?
            if case .succeeded(let r, _) = end { reported = TurnStatus.parse(r.text) }
            // False when crash recovery already closed this turn; recovery also moved the agent, so the state
            // guard below leaves it alone.
            let closed = try Store.finishTurn(db: db, id: turn.id, outcome: end.outcome, summary: summary, costUSD: cost,
                                              infra: infraClass != .none, reportedStatus: reported,
                                              sessionResetReason: lostScope == nil ? nil : "session not found", now: now)
            if closed, lostScope == nil, let use = sessionUse {
                try Store.noteSessionTurn(db: db, agentId: agentId, scope: use.scope, turnId: turn.id, endedAt: now,
                                          model: use.model, tools: use.tools, cwd: use.cwd)
            }
            if closed, let cost { try Store.recordSpend(db, cost) }
            // Plan ML: the turn's episode, before any fresh-session reset (the orchestrator's `clearTaintIfRequested` runs after
            // this transaction), with the session's taint as it stands now. Never fails the turn end; a failure leaves an
            // `error` activity line.
            if closed {
                EpisodeRecorder.nonFatal(db: db, companyId: agent.companyId, agentId: agentId,
                                         what: "the episode of @\(agent.name)'s turn", now: now) {
                    guard let ended = try Turn.fetchOne(db, key: turn.id) else { throw StoreError.notFound }
                    let taint: String?
                    // Unreadable: tainted (fail closed).
                    do { taint = try Store.currentTaint(db: db, agentId: agentId, home: taintHome ?? dataHome) } catch { taint = "session" }
                    // The turn's item, else the item the agent holds.
                    let itemKey = try String.fetchOne(db, sql: """
                        SELECT key FROM workItem WHERE id = COALESCE(?, (SELECT itemId FROM workLease WHERE agentId = ? ORDER BY acquiredAt DESC LIMIT 1))
                        """, arguments: [ended.itemId, agentId])
                    try EpisodeRecorder.turnEnded(db: db, turn: ended, agent: agent, itemKey: itemKey, taint: taint, now: now)
                }
            }
            var watchdogBlock: Blocker?
            var budgeted = completed
            if case .failed(_, _, let partial) = end, partial != nil { budgeted = true }
            if closed {
                try Store.writeAccounting(db: db, turnId: turn.id, accounting: accounting, telemetry: telemetry, end: end,
                                          resetSession: lostScope != nil)
                try noteReviewTurnEnd(db: db, turnId: turn.id, agent: agent, end: end, infra: infraClass != .none, now: now)
                // Budget step (Task 14a): a counted work turn can take its item over its tier's budget. Review turns, session
                // resets and infrastructure failures are never budgeted.
                if infraClass == .none, lostScope == nil, budgeted { try budgetStep(db: db, turnId: turn.id, agent: agent, now: now) }
                // Watchdog step (14b): completed turns (controlled stops included) are judged; infrastructure failures and session
                // resets never are.
                if infraClass == .none, lostScope == nil, completed {
                    let observation = telemetry.observation ?? TurnObservation(signature: telemetry.toolSignature)
                    watchdogBlock = try watchdogStep(db: db, turnId: turn.id, agent: agent, observation: observation, now: now)
                }
            }
            var text = "@\(agent.name) turn \(end.outcome.rawValue)"
            if let summary, !summary.isEmpty { text += ": \(summary.prefix(200))" }
            try ActivityEvent(companyId: agent.companyId, agentId: agentId, turnId: turn.id, kind: .turnFinished,
                              text: text, createdAt: now).insert(db)

            switch end {
            case .succeeded, .capped: agent.consecutiveFailures = 0
            case .failed: if infraClass == .none, lostScope == nil { agent.consecutiveFailures += 1 }
            default: break
            }
            // A requested blocker belongs to the turn that set it.
            let requested = agent.requestedBlocker
            agent.requestedBlocker = nil
            let columns = ["consecutiveFailures", "consecutiveInfraFailures", "requestedBlocker"]
            if let lostScope {
                try Store.resetSession(db: db, agentId: agentId, scope: lostScope)
                try ActivityEvent(companyId: agent.companyId, agentId: agentId, turnId: turn.id, kind: .error,
                                  text: "@\(agent.name) session not found; next turn starts a fresh session",
                                  createdAt: now).insert(db)
            }
            try agent.update(db, columns: columns)

            // Killed (or otherwise moved) mid-turn: the turn is recorded, the state is left alone.
            guard agent.state == .running else { return infraClass }
            if completed { try Store.renewLeases(db: db, agentId: agentId, now: now) }
            if agent.paused {
                try Store.transition(db: db, agentId: agentId, to: .sleeping, now: now)
                return infraClass
            }
            switch end {
            case .interrupted:
                try Store.transition(db: db, agentId: agentId, to: .ready, now: now)
            case .usageLimited(let until, _):
                try Store.transition(db: db, agentId: agentId, to: .blocked, blocker: .usageLimit(until: until), now: now)
            case .failed where infraClass != .none || lostScope != nil:
                // Not the agent's fault: ready again at once (the orchestrator adds a fixed cooldown), no backoff.
                try Store.transition(db: db, agentId: agentId, to: .ready, now: now)
            case .failed:
                let n = agent.consecutiveFailures
                try Store.transition(db: db, agentId: agentId, to: .blocked,
                                     blocker: .retry(until: now.addingTimeInterval(retryBackoff(failures: n)), failures: n), now: now)
            case .succeeded where watchdogBlock != nil, .capped where watchdogBlock != nil:
                // The watchdog took the work back: the agent waits for whoever was told.
                try Store.transition(db: db, agentId: agentId, to: .blocked, blocker: watchdogBlock, now: now)
            case .succeeded(_, let usageHold), .capped(_, let usageHold):
                // Anything still pending arrived mid-turn: the router saw `running` and did not wake us.
                let senders = try String.fetchAll(db, sql: """
                    SELECT message.senderId FROM inboxItem JOIN message ON message.id = inboxItem.messageId
                    WHERE inboxItem.agentId = ? AND inboxItem.deliveredTurnId IS NULL AND inboxItem.wakes = 1
                    """, arguments: [agentId])
                var answered = false
                if let blocker = requested {
                    switch blocker {
                    case .agent(let id): answered = senders.contains(id)
                    case .owner: answered = senders.contains("owner")
                    default: break
                    }
                    // Still waiting on someone: when they answer, the usage gate re-checks before the next turn.
                    if !answered {
                        try Store.transition(db: db, agentId: agentId, to: .blocked, blocker: blocker, now: now)
                        return infraClass
                    }
                }
                if senders.isEmpty, !(try Store.hasPendingWork(db: db, agentId: agentId)) {
                    // Nothing left to do: sleep; a new message wakes it and the usage gate holds it if still closed.
                    try Store.transition(db: db, agentId: agentId, to: .sleeping, now: now)
                } else if let usageHold {
                    try Store.transition(db: db, agentId: agentId, to: .blocked, blocker: .usageLimit(until: usageHold), now: now)
                } else {
                    try Store.transition(db: db, agentId: agentId, to: .ready, now: now)
                }
            }
            return infraClass
        }
    }
}
