import Foundation
import Observation
import BrahmaCore

public enum EngineStatus: Equatable, Sendable {
    case starting, embedded, external, stopping, stopped
    case failed(String)

    public var label: String {
        switch self {
        case .starting: "starting"
        case .embedded: "embedded"
        case .external: "external"
        case .stopping: "stopping"
        case .stopped: "stopped"
        case .failed: "failed"
        }
    }
}

public struct EngineTools: Equatable, Sendable {
    public var claudePath: String
    public var mcpExecutable: String

    public init(claudePath: String, mcpExecutable: String) {
        self.claudePath = claudePath
        self.mcpExecutable = mcpExecutable
    }
}

public enum EngineSetupError: Error, Equatable {
    case claudeNotFound
    case helperMissing(path: String)

    public var message: String {
        switch self {
        case .claudeNotFound:
            "Can't find the claude CLI. Install Claude Code, or set BRAHMA_CLAUDE to its path, then relaunch Brahma."
        case .helperMissing(let path):
            "Brahma's helper tool is missing at \(path). Rebuild the app with scripts/make-app.sh."
        }
    }
}

/// Hosts the Plan 1 `Orchestrator` inside the app while holding the per-home `OrchestratorLock`.
@MainActor @Observable
public final class EngineHost {
    public private(set) var status: EngineStatus = .stopped

    @ObservationIgnored private let paths: BrahmaPaths
    @ObservationIgnored private let store: Store
    @ObservationIgnored private let makeRunner: @Sendable (String) -> any TurnRunning
    @ObservationIgnored private let config: SchedulerConfig
    @ObservationIgnored private let ownerKeyStore: any OwnerKeyStore
    /// Where secret values live, for the engine's redactor: the app passes the vault `PlatformSecretVault` chose (the
    /// Keychain, or a dev/demo home's file store). The default is `UnavailableVault`, never the Keychain.
    /// The vault the engine reloads secrets from (non-interactive inside the Orchestrator). Internal for tests.
    @ObservationIgnored let secretVault: any SecretVault
    @ObservationIgnored private let probe: @Sendable (String) async -> DoctorReport
    /// Retry's probe: always a real run, never the saved report.
    @ObservationIgnored private let freshProbe: @Sendable (String) async -> DoctorReport
    @ObservationIgnored private let tickInterval: Duration
    @ObservationIgnored private var lock: OrchestratorLock?
    @ObservationIgnored private var engineTask: Task<Void, Never>?
    /// The running orchestrator, so `stop` can end its litestream directly.
    @ObservationIgnored private var engine: Orchestrator?
    @ObservationIgnored private var rememberedTools: Result<EngineTools, EngineSetupError>?
    /// The bounded wait of the `stop` in progress, so a second quit request can end it at once (`forceStop`).
    @ObservationIgnored private var pendingStop: ResumeOnce?
    /// Set by `forceStop` while a stop is pending: the stop's own backstop then kills nothing twice.
    @ObservationIgnored private var forced = false

    /// The engine the app builds again after a restore (the model has a new store). It carries the same owner key store and
    /// the same secret vault as the first engine, so the restarted engine's redactor still loads the company's secrets and
    /// never falls back to an unavailable vault (INT-I3).
    public static func rebuilt(paths: BrahmaPaths, store: Store, ownerKeyStore: any OwnerKeyStore,
                               secretVault: any SecretVault) -> EngineHost {
        EngineHost(paths: paths, store: store, ownerKeyStore: ownerKeyStore, secretVault: secretVault)
    }

    public init(paths: BrahmaPaths, store: Store,
                makeRunner: @escaping @Sendable (String) -> any TurnRunning = { ClaudeProcessRunner(claudePath: $0) },
                config: SchedulerConfig = .init(), tickInterval: Duration = .seconds(1),
                probe: (@Sendable (String) async -> DoctorReport)? = nil,
                freshProbe: (@Sendable (String) async -> DoctorReport)? = nil,
                ownerKeyStore: any OwnerKeyStore, secretVault: any SecretVault = UnavailableVault()) {
        self.ownerKeyStore = ownerKeyStore
        self.secretVault = secretVault
        self.probe = probe ?? { [store] path in
            await Doctor.ensure(store: store, claudePath: path, runner: ClaudeProcessRunner(claudePath: path))
        }
        // An injected probe stands for the doctor in tests; otherwise Retry runs the real one and saves its report.
        self.freshProbe = freshProbe ?? probe ?? { [store] path in
            let report = await Doctor.run(claudePath: path, runner: ClaudeProcessRunner(claudePath: path))
            try? store.saveProbe(report)
            return report
        }
        self.paths = paths
        self.store = store
        self.makeRunner = makeRunner
        self.config = config
        self.tickInterval = tickInterval
    }

    public func start(tools: Result<EngineTools, EngineSetupError>) async {
        guard status != .embedded else { return }
        rememberedTools = tools
        // Owner CLI commands are default-deny without a verified owner key; only the app and `brahma owner init` create it.
        try? OwnerKey.ensure(paths: paths, store: ownerKeyStore)
        let resolved: EngineTools
        switch tools {
        case .failure(let error):
            status = .failed(error.message)
            return
        case .success(let t):
            resolved = t
        }
        status = .starting
        let report = await probe(resolved.claudePath)
        if let bad = report.items.first(where: { $0.status == .fail }) {
            status = .failed("Claude Code check failed: \(bad.detail). Run brahma doctor in Terminal for details.")
            return
        }
        let acquired: OrchestratorLock
        do {
            acquired = try OrchestratorLock.acquire(paths: paths)
        } catch OrchestratorLockError.alreadyRunning {
            status = .external
            return
        } catch OrchestratorLockError.cannotOpen(let code) {
            status = .failed("Can't open the engine lock in \(paths.home.path) (errno \(code)).")
            return
        } catch {
            status = .failed("Can't take the engine lock: \(error)")
            return
        }
        lock = acquired
        let orchestrator = Orchestrator(store: store, runner: makeRunner(resolved.claudePath), paths: paths, config: config,
                                        mcpExecutable: resolved.mcpExecutable, profile: nil,
                                        claudePath: resolved.claudePath, vault: secretVault,
                                        transcripts: TranscriptCapture(paths: paths, source: .fromEnvironment()),
                                        sleepGuard: SleepGuard(launcher: CaffeinateProcess.launcher()))
        do {
            try await orchestrator.start()
        } catch {
            lock = nil
            status = .failed("Crash recovery failed: \(error)")
            return
        }
        let interval = tickInterval
        engine = orchestrator
        engineTask = Task.detached { await orchestrator.runForever(interval: interval) }
        status = .embedded
    }

    /// The Retry button: runs the doctor again (not the saved report). Nil when Claude Code was never located.
    public func recheck() async -> DoctorReport? {
        guard case .success(let tools)? = rememberedTools else { return nil }
        return await freshProbe(tools.claudePath)
    }

    /// Re-attempts the lock while a terminal `brahma run` holds it.
    public func retryTakeover() async {
        guard status == .external, let tools = rememberedTools else { return }
        await start(tools: tools)
    }

    /// How long `stop` waits for the engine by default: the engine bounds its own shutdown at `EngineShutdown.bound` (litestream
    /// and caffeinate included) and logs what was still running; this backstop sits 2 s behind it, so the engine's own log line
    /// comes first. The backstop's clock starts before anything is awaited (fix round 1, I2).
    public static let stopTimeout: Duration = EngineShutdown.bound + .seconds(2)

    /// Cancels the engine and waits for it to wind down, but never longer than `timeout`: the engine's shutdown is bounded
    /// (`Orchestrator.shutdown`, Task 9c) and this wait is the backstop behind it. When the backstop fires first (the engine's
    /// loop never reached its own shutdown), the engine's recorded process groups and its litestream are killed here
    /// (`EngineShutdown.killEngineProcesses`), as the engine's own expired bound would.
    public func stop(timeout: Duration = stopTimeout) async {
        switch status {
        case .embedded:
            // Installed before anything is awaited, so a `forceStop` at any point of the stop ends the wait below.
            let once = ResumeOnce()
            pendingStop = once
            status = .stopping
            if let task = engineTask {
                task.cancel()
                let returned = await Self.waitBounded(task, timeout: timeout, once: once)
                if !returned, !forced {
                    let killed = EngineShutdown.killEngineProcesses(store: store, paths: paths)
                    FileHandle.standardError.write(Data(("brahma: the engine did not stop within \(EngineShutdown.seconds(timeout)); "
                        + "killed \(killed.groups.terminated.count) recorded process group(s)\(killed.litestream.map { "; \($0)" } ?? "")\n").utf8))
                }
            }
            pendingStop = nil
            forced = false
            engineTask = nil
            engine = nil
            lock = nil
            status = .stopped
        case .external:
            status = .stopped
        default:
            break
        }
    }

    /// A second quit request while `stop` runs (Task 9c, the owner's second SIGTERM or SIGINT). Only when this host holds the
    /// engine lock (`.embedded` or `.stopping`; fix round 1 I1): every process group this engine recorded (turns, checks,
    /// merges, previews; each start-time checked) is signalled with SIGKILL right behind SIGTERM, its litestream with them,
    /// the in-progress turns are recorded `interrupted` (`EngineShutdown.force`), and the pending `stop` returns at once
    /// instead of waiting out its bound. In every other state (`.external`: a terminal `brahma run` owns those processes;
    /// `.starting`: the lock is not held and the database's in-progress rows are an earlier engine's) nothing is signalled and
    /// nothing is written; a pending wait is still ended. Returns what was killed, nil when this host is not the engine.
    @discardableResult
    public func forceStop() -> EngineShutdown.Killed? {
        defer { pendingStop?.fire() }
        guard status == .embedded || status == .stopping else { return nil }
        forced = true
        return EngineShutdown.force(store: store, paths: paths)
    }

    /// The engine's task races a hard timer (a dedicated thread, `ResumeOnce.fire(afterAwake:)`) into `once`, which
    /// `forceStop` can fire too. A task group would wait for both children at scope exit, so it would not bound anything.
    /// True when the engine returned by itself.
    private static func waitBounded(_ task: Task<Void, Never>, timeout: Duration, once: ResumeOnce) async -> Bool {
        let returned = Returned()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            once.install(continuation)
            Task.detached {
                await task.value
                returned.set()
                once.fire()
            }
            // Awake time (`AwakeTime`): a Mac that sleeps while the engine winds down does not cut the wait short.
            once.fire(afterAwake: timeout)
        }
        return returned.value
    }

    private final class Returned: @unchecked Sendable {
        private let lock = NSLock()
        private var flag = false
        func set() { lock.withLock { flag = true } }
        var value: Bool { lock.withLock { flag } }
    }
}
