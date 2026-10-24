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
    @ObservationIgnored private let probe: @Sendable (String) async -> DoctorReport
    /// Retry's probe: always a real run, never the saved report.
    @ObservationIgnored private let freshProbe: @Sendable (String) async -> DoctorReport
    @ObservationIgnored private let tickInterval: Duration
    @ObservationIgnored private var lock: OrchestratorLock?
    @ObservationIgnored private var engineTask: Task<Void, Never>?
    @ObservationIgnored private var rememberedTools: Result<EngineTools, EngineSetupError>?

    public init(paths: BrahmaPaths, store: Store,
                makeRunner: @escaping @Sendable (String) -> any TurnRunning = { ClaudeProcessRunner(claudePath: $0) },
                config: SchedulerConfig = .init(), tickInterval: Duration = .seconds(1),
                probe: (@Sendable (String) async -> DoctorReport)? = nil,
                freshProbe: (@Sendable (String) async -> DoctorReport)? = nil,
                ownerKeyStore: any OwnerKeyStore) {
        self.ownerKeyStore = ownerKeyStore
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
                                        mcpExecutable: resolved.mcpExecutable, profile: .workspace,
                                        claudePath: resolved.claudePath)
        do {
            try await orchestrator.start()
        } catch {
            lock = nil
            status = .failed("Crash recovery failed: \(error)")
            return
        }
        let interval = tickInterval
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

    /// Cancels the engine and waits for it to wind down, but never longer than `timeout`:
    /// `runForever` ends in `waitForChildren()`, which a stuck child can keep from returning.
    public func stop(timeout: Duration = .seconds(15)) async {
        switch status {
        case .embedded:
            status = .stopping
            if let task = engineTask {
                task.cancel()
                await Self.waitBounded(task, timeout: timeout)
            }
            engineTask = nil
            lock = nil
            status = .stopped
        case .external:
            status = .stopped
        default:
            break
        }
    }

    /// Two unstructured tasks race into a resume-once continuation. A task group would wait for both children
    /// at scope exit, so it would not bound anything.
    private static func waitBounded(_ task: Task<Void, Never>, timeout: Duration) async {
        let once = ResumeOnce()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            once.install(continuation)
            Task.detached {
                await task.value
                once.fire()
            }
            let timer = Task.detached {
                // Awake time (`AwakeTime`): a Mac that sleeps while the engine winds down does not cut the wait short.
                try? await AwakeTime.sleep(for: timeout)
                once.fire()
            }
            once.onFire { timer.cancel() }
        }
    }
}

/// Resumes its continuation exactly once, whichever caller fires first.
private final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false
    private var cleanup: (@Sendable () -> Void)?

    func install(_ c: CheckedContinuation<Void, Never>) { lock.withLock { continuation = c } }

    func onFire(_ body: @escaping @Sendable () -> Void) {
        let runNow = lock.withLock { () -> Bool in
            if fired { return true }
            cleanup = body
            return false
        }
        if runNow { body() }
    }

    func fire() {
        let (c, cleanup) = lock.withLock { () -> (CheckedContinuation<Void, Never>?, (@Sendable () -> Void)?) in
            guard !fired else { return (nil, nil) }
            fired = true
            defer { continuation = nil; self.cleanup = nil }
            return (continuation, self.cleanup)
        }
        c?.resume()
        cleanup?()
    }
}
