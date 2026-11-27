import Foundation
import GRDB
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Runs every company's preview surfaces from `main` (Plan L Task 3). Each start is a fresh `.git`-free engine export of the
/// company's engine-accepted `main` (`company.mainCommit`, PR-22) under the data home, keyed by surface, commit and start
/// (`EngineLayout.previewRunId`, PR-16), never shared and deleted when the run stops; its build and server run through
/// 5-lite's `SandboxedRunner` with `PreviewPolicy.server` (writes only its run, listens only on its own loopback port), except
/// that a Full company's preview runs unsandboxed exactly when its checks would (PR-5: its setter, resolved from the surface
/// record the start runs with `PrincipalResolver.resolve(holding: .preview(surface))`, and the live company narrow to Full
/// under the ceiling; S6, S6-c1, S6-c2). The start's policies are built from the live company that resolution read, and a
/// sprint demo resolves the run's surface again before it runs (`redecided`).
///
/// `reconcile` is one pass over every company (the orchestrator's "preview" tick step runs it as a tracked task, PR-6):
/// - a paused company's surfaces are stopped (`stopped`);
/// - under memory pressure no build or start begins (`"waiting: memory pressure"`);
/// - when `main` has moved and the new head has been seen for `debounce` seconds, running surfaces restart on it;
/// - a surface changed since its start, or flagged by the owner or its setter (`restartRequestedAt`), restarts alone;
/// - a dead server is restarted after `backoff[exits - 1]`; the `crashLimit`-th exit within `crashWindow` is `failed`;
/// - a removed surface's process is stopped;
/// - starts run one at a time engine-wide (`maxConcurrentBuilds`), in company then `position` order, each a tracked task that
///   writes `building` → `starting` → the adapter's result;
/// - a failed start sends one system DM to its setter (an agent) with the engine's reason and the log's path, never the
///   log's text, and an activity line; a successful one an activity line.
/// The first pass of a runner treats every `building`, `starting` or `running` record as an earlier engine's: its process
/// group is killed when the recorded pid is still that group's leader with exactly the start time recorded at the spawn
/// (`pidStart`, final review I2), the surface becomes `stopped` and is started again from a fresh export (the engine's
/// startup sweep deleted every export).
///
/// The owner's emergency stop (5-lite 7c, L-5lite-A): the runner is one of the engine's stop observers. `stopAll(reason:)`
/// stops every surface of every company (`"stopped by the owner"`); while `store.engineStopped()` holds (or cannot be read)
/// `reconcile` starts and restarts nothing; the first pass after the resume starts them again as on engine start.
///
/// Plan 4a Task 4: every kind starts through its injected adapter (`adapters`, by default `PreviewAdapters.defaults`; a kind
/// without one, or whose adapter is not available here, is `unavailable`), under its kind's policy
/// (`PreviewPolicy.forKind`); kinds without a URL get port 0. A `ran` result (a one-shot demo) is terminal: no crash
/// tracking, re-run only when `main` moves, it changes or a restart is flagged. Every stop of a run calls its adapter's
/// `stop` (a Simulator app, a macOS app), the owner's stop included. An iOS surface runs only with the owner's approval
/// (`outsideSandboxApprovedAt`, set only by `applySimulatorApprovalEffects`): until then it is `unavailable`, its run (if
/// any) stopped, and the engine files the owner ask once (`Store.requestSimulatorApproval`); the approval is read again
/// right before the adapter starts.
public actor PreviewRunner: EmergencyStopObserver {
    public static let debounce: TimeInterval = 5
    public static let crashWindow: TimeInterval = 300
    public static let crashLimit = 3
    public static let backoff: [TimeInterval] = [2, 10, 30]
    public static let maxConcurrentBuilds = 1

    static let crashLoopMessage = "exited 3 times in 5 minutes; restart it or wait for the next merge"
    static let pressureMessage = "waiting: memory pressure"
    static let pausedMessage = "company paused"
    static let engineRestartedMessage = "engine restarted"
    static let unsafeAppDataMessage = "its app data directory is not safe to use"
    /// A kind this engine has no adapter for.
    static func noAdapterMessage(_ kind: PreviewKind) -> String { "\(kind.title) previews are not available on this engine yet" }
    public static let shutdownMessage = "engine stopped"
    /// What every surface the owner's stop reached records (the owner's note stays in the stop's own activity line).
    public static let ownerStopMessage = "stopped by the owner"

    let store: Store
    let paths: BrahmaPaths
    nonisolated let deps: PreviewDependencies
    let sandboxLayout: @Sendable (Company) -> SandboxLayout
    let timeouts: PreviewTimeouts
    let memory: @Sendable () -> Bool
    let clock: @Sendable () -> Date
    let blocking: Blocking
    let baseEnvironment: [String: String]
    /// The engine's ceiling on every profile (`brahma run --profile`, `Orchestrator.profileCeiling`): narrows the Full-mode
    /// route of every preview (B2); nil is no ceiling.
    let ceiling: PermissionProfile?
    /// The adapter of each kind (Plan 4a fix 5: injected).
    nonisolated let adapters: [PreviewKind: any PreviewAdapter]
    /// Each kind's `availability()`, asked once per runner.
    private var availabilityCache: [PreviewKind: String?] = [:]

    /// Starts in flight whose server is not spawned yet (a build, an export): child work next to `deps.processes`.
    private nonisolated let pending = PendingStarts()
    /// Surface id → its start task.
    private var starts: [String: Task<Void, Never>] = [:]
    /// Surface id → the run it has now (its export and, once spawned, its process). Read by the sprint demo (`demo(sprint:)`).
    var runs: [String: Run] = [:]
    /// Company id → the `main` last seen and when it was first seen (the debounce).
    private var mainSeen: [String: (commit: String, at: Date)] = [:]
    /// Surface id → when a crashed server may start again.
    private var restartAt: [String: Date] = [:]
    private var startCounter = 0
    private var recovered = false
    /// While `stopAll` runs, `reconcile` (and the sprint demo) does nothing.
    var stopping = 0
    /// Bumped by every `stopAll` (Task 3 M1): a pass that began before it brings nothing up after it (`launch` and the
    /// pass's own writes check that the epoch they started in is still current).
    var stopEpoch = 0
    /// The sprint-review demo in flight (Plan 4a Task 7), cancelled by `stop` like the starts (fix round 1, I1).
    var demoTask: Task<DemoOutcome?, Never>?
    /// Sprint id → how many times its demo's results could not be recorded (fix round 1, M6; `maxDemoAttempts`).
    var demoAttempts: [String: Int] = [:]
    /// Tests only: makes the demo's record step throw.
    var demoRecordFailure: (any Error)?
    /// After this many record failures the engine gives the sprint up: one `failed` row and a post that it failed.
    static let maxDemoAttempts = 3

    func failDemoRecords(with error: (any Error)?) { demoRecordFailure = error }

    #if DEBUG
    /// Tests only (S6-c1): runs just before a start resolves its surface's principals, after the surface was read for the start,
    /// so a test can change the stored surface in between. Not in a release build (M-b).
    var beforeResolve: (@Sendable (PreviewSurface) -> Void)?
    func setBeforeResolve(_ probe: (@Sendable (PreviewSurface) -> Void)?) { beforeResolve = probe }
    #endif

    struct Run: Sendable {
        var company: Company
        var runId: String
        var pid: Int32?
        var kind: PreviewKind = .web
        /// The start's context once it is built (what the adapter's `stop` is given).
        var context: PreviewContext? = nil
        var simulatorId: String? = nil
    }

    /// `adapters` nil: `PreviewAdapters.defaults(deps)`. `ceiling` nil: no engine ceiling (a host without `brahma run --profile`).
    public init(store: Store, paths: BrahmaPaths, deps: PreviewDependencies, sandboxLayout: @escaping @Sendable (Company) -> SandboxLayout,
                timeouts: PreviewTimeouts = .init(), memory: @escaping @Sendable () -> Bool, clock: @escaping @Sendable () -> Date = Store.now,
                adapters: [PreviewKind: any PreviewAdapter]? = nil, ceiling: PermissionProfile? = nil) {
        self.init(store: store, paths: paths, deps: deps, sandboxLayout: sandboxLayout, timeouts: timeouts, memory: memory, clock: clock,
                  blocking: Blocking(), environment: ProcessInfo.processInfo.environment, ceiling: ceiling, adapters: adapters)
    }

    init(store: Store, paths: BrahmaPaths, deps: PreviewDependencies, sandboxLayout: @escaping @Sendable (Company) -> SandboxLayout,
         timeouts: PreviewTimeouts, memory: @escaping @Sendable () -> Bool, clock: @escaping @Sendable () -> Date, blocking: Blocking,
         environment: [String: String], ceiling: PermissionProfile?, adapters: [PreviewKind: any PreviewAdapter]? = nil) {
        self.store = store; self.paths = paths; self.deps = deps; self.sandboxLayout = sandboxLayout; self.timeouts = timeouts
        self.memory = memory; self.clock = clock; self.blocking = blocking; self.baseEnvironment = environment; self.ceiling = ceiling
        self.adapters = adapters ?? PreviewAdapters.defaults(deps)
    }

    /// Non-turn child work previews hold for the safety cap: every running server plus every start not yet spawned.
    public nonisolated var activeChildren: Int { deps.processes.count + pending.count }
    /// Starts in flight that have not spawned their server yet (exports, builds): what keeps the Mac awake for previews.
    public nonisolated var startsInFlight: Int { pending.count }

    // MARK: The pass

    public func reconcile(now: Date) async { await reconcile(now: now, settledCompany: nil) }

    /// `settledCompany`: that company's moved `main` counts as past its debounce (the sprint-review demo wants its current
    /// `main` now; every other company keeps the debounce, fix round 1 M3).
    func reconcile(now: Date, settledCompany: String?) async {
        guard stopping == 0 else { return }
        let epoch = stopEpoch
        if !recovered {
            recovered = true
            await recover(now: now)
        }
        // The owner's stop (PR-35 3s): while it holds nothing starts or restarts. Fail closed: a stop that cannot be read
        // is taken as one.
        guard stopping == 0, epoch == stopEpoch, !ownerStopHolds else { return }
        guard let companies = try? store.companies() else { return }
        let pressured = memory()
        var present = Set<String>()
        for company in companies {
            guard let surfaces = try? store.previewSurfaces(companyId: company.id),
                  let states = try? store.previewStates(companyId: company.id) else { continue }
            present.formUnion(surfaces.map(\.id))
            if company.status == .paused {
                for surface in surfaces where starts[surface.id] != nil || runs[surface.id] != nil
                    || [.building, .starting, .running].contains(states[surface.id]?.status ?? .idle) {
                    await stopSurface(surface.id, message: Self.pausedMessage, now: now)
                    guard epoch == stopEpoch else { return }
                }
                continue
            }
            guard let main = company.mainCommit else { continue }
            if mainSeen[company.id]?.commit != main { mainSeen[company.id] = (main, now) }
            let mainSettled = settledCompany == company.id || now.timeIntervalSince(mainSeen[company.id]?.at ?? now) >= Self.debounce
            for surface in surfaces {
                guard let kind = surface.previewKind, kind != .artifact else { continue }
                let state = states[surface.id] ?? PreviewState(surfaceId: surface.id, companyId: company.id, updatedAt: now)
                // The iOS gate (fix 4): no Simulator preview runs, or keeps running, without the owner's approval.
                if kind == .ios, surface.outsideSandboxApprovedAt == nil {
                    await holdForOwner(surface: surface, state: state, now: now)
                    guard epoch == stopEpoch else { return }
                    continue
                }
                guard starts[surface.id] == nil else { continue }
                if await noticeExit(surface: surface, company: company, state: state, epoch: epoch, now: now) {
                    guard epoch == stopEpoch else { return }
                    continue
                }
                guard let fresh = wantsStart(surface: surface, state: state, main: main, mainSettled: mainSettled, now: now) else { continue }
                if pressured {
                    if state.message != Self.pressureMessage {
                        _ = try? store.updatePreviewState(surfaceId: surface.id, now: now) { $0.message = Self.pressureMessage }
                    }
                    continue
                }
                guard starts.count < Self.maxConcurrentBuilds else { continue }
                launch(company: company, surface: surface, commit: main, fresh: fresh, epoch: epoch, now: now)
            }
        }
        for id in Array(runs.keys) where !present.contains(id) && starts[id] == nil {
            await stopRun(id)
            guard epoch == stopEpoch else { return }
        }
        restartAt = restartAt.filter { present.contains($0.key) }
    }

    /// Whether the owner's stop holds now; a database error reads as stopped (nothing starts by mistake).
    var ownerStopHolds: Bool {
        do { return try store.engineStopped() != nil } catch { return true }
    }

    /// Nil: leave it. Otherwise start it; `true` when the start is a new one (main moved, changed or flagged, never started),
    /// which clears its crash record, `false` for a restart after a crash, a pause or a stop.
    private func wantsStart(surface: PreviewSurface, state: PreviewState, main: String, mainSettled: Bool, now: Date) -> Bool? {
        let changed = state.restartRequestedAt != nil || state.startedAt.map { surface.updatedAt > $0 } == true
        let moved = state.commit != nil && state.commit != main
        if changed || (moved && mainSettled) { return true }
        if isLive(surface.id) { return nil }
        switch state.status {
        case .failed, .unavailable, .ran:
            return nil                               // until main moves, it changes, or it is flagged
        default:
            if moved { return nil }                  // the debounce
            if state.commit == nil { return true }   // never started
            if let at = restartAt[surface.id] { return now >= at ? false : nil }
            return false
        }
    }

    /// A run with a process is live while it is alive; a started run with none to watch (a Simulator app, a finished demo)
    /// stays as it is until it is stopped or restarted.
    private func isLive(_ id: String) -> Bool {
        guard let run = runs[id] else { return false }
        guard let pid = run.pid else { return run.context != nil && starts[id] == nil }
        guard let process = deps.processes.process(pid) else { return false }
        return process.isAlive()
    }

    /// A server of ours that ended on its own: its exit is recorded, then it restarts after the backoff or, at the crash
    /// limit, fails. Returns whether it handled one.
    /// A `stopAll` meanwhile (`epoch` no longer current) leaves its record as the stop wrote it.
    private func noticeExit(surface: PreviewSurface, company: Company, state: PreviewState, epoch: Int, now: Date) async -> Bool {
        guard let run = runs[surface.id], let pid = run.pid, let process = deps.processes.process(pid), !process.isAlive() else { return false }
        let code = await WebAdapter.exitCode(process)
        await stopRun(surface.id)
        guard epoch == stopEpoch else { return true }
        let exits = (state.exits + [now]).filter { now.timeIntervalSince($0) < Self.crashWindow }
        if exits.count >= Self.crashLimit {
            restartAt[surface.id] = nil
            _ = try? store.updatePreviewState(surfaceId: surface.id, now: now) {
                $0.status = .failed; $0.message = Self.crashLoopMessage; $0.exits = exits; $0.pid = nil; $0.resolvedURL = nil
            }
            notifyFailure(company: company, surface: surface, commit: state.commit ?? company.mainCommit ?? "", message: Self.crashLoopMessage, now: now)
        } else {
            let delay = Self.backoff[min(exits.count - 1, Self.backoff.count - 1)]
            restartAt[surface.id] = now.addingTimeInterval(delay)
            _ = try? store.updatePreviewState(surfaceId: surface.id, now: now) {
                $0.status = .stopped; $0.message = "exited (exit \(code)); restarting in \(Int(delay)) s"; $0.exits = exits; $0.pid = nil
                $0.resolvedURL = nil
            }
        }
        return true
    }

    // MARK: The iOS gate

    /// An iOS surface without the owner's approval: its start or run (a Simulator app) is stopped, the engine's owner ask is
    /// filed once, and it is `unavailable` with why. A kind with no adapter here, or one not available on this machine, says
    /// that instead and files nothing (there is nothing to approve yet).
    private func holdForOwner(surface: PreviewSurface, state: PreviewState, now: Date) async {
        let id = surface.id
        if starts[id] != nil || runs[id] != nil { await stopSurface(id, message: SimulatorApproval.waitingMessage, now: now) }
        let message: String
        if let why = await unavailableReason(.ios) {
            message = why
        } else {
            do {
                let ask = try store.requestSimulatorApproval(surfaceId: id, now: now)
                message = ask.map { !$0.status.isPending } == true ? SimulatorApproval.declinedMessage : SimulatorApproval.waitingMessage
            } catch {
                message = SimulatorApproval.waitingMessage
            }
        }
        guard state.status != .unavailable || state.message != message || state.pid != nil || state.simulatorId != nil else { return }
        _ = try? store.updatePreviewState(surfaceId: id, now: now) {
            $0.status = .unavailable; $0.message = message; $0.pid = nil; $0.resolvedURL = nil; $0.simulatorId = nil
        }
    }

    /// Why `kind` cannot start here: no adapter, or its adapter's `availability()` (asked once per runner, off the actor's
    /// thread). Nil when it can.
    private func unavailableReason(_ kind: PreviewKind) async -> String? {
        guard let adapter = adapters[kind] else { return Self.noAdapterMessage(kind) }
        if let cached = availabilityCache[kind] { return cached }
        let reason = await blocking.run { adapter.availability() }
        availabilityCache[kind] = .some(reason)
        return reason
    }

    // MARK: Starts

    /// Nothing is launched by a pass that a `stopAll` overtook (`epoch`), while one runs, or while the owner's stop holds
    /// (Task 3 M1).
    private func launch(company: Company, surface: PreviewSurface, commit: String, fresh: Bool, epoch: Int, now: Date) {
        guard epoch == stopEpoch, stopping == 0, !ownerStopHolds else { return }
        startCounter += 1
        let n = startCounter
        restartAt[surface.id] = nil
        pending.insert(surface.id)
        starts[surface.id] = Task {
            await self.perform(company: company, surface: surface, commit: commit, fresh: fresh, start: n, epoch: epoch, now: now)
            self.startEnded(surface.id)
        }
    }

    private func startEnded(_ id: String) {
        starts[id] = nil
        pending.remove(id)
    }

    /// Waits for every start in flight (tests; the sprint demo; and `stopAll`, after cancelling them). Returns as soon as the
    /// caller is cancelled (fix round 2, N1: the owner's stop cancels the demo waiting here and the starts it waits for; a
    /// cancelled waiter never cancels the starts itself).
    public func waitForStarts() async {
        while !Task.isCancelled, let task = starts.values.first {
            await withTaskGroup(of: Void.self) { group in
                group.addTask { _ = await task.value }
                group.addTask { try? await Task.sleep(for: .seconds(86_400)) }   // ends at once when the waiter is cancelled
                await group.next()
                group.cancelAll()
            }
        }
    }

    /// `epoch`: the stop epoch the start was launched in. A start that ends after a `stopAll` (cancelled, or the epoch moved)
    /// is torn down, never recorded running (fix round 2, N1).
    private func perform(company: Company, surface: PreviewSurface, commit: String, fresh: Bool, start n: Int, epoch: Int, now: Date) async {
        await stopRun(surface.id)
        let id = surface.id
        let sandbox = sandboxLayout(company)
        let layout = EngineLayout(workspace: sandbox.workspace)
        let logURL = layout.previewLog(name: surface.name)
        // A failure is recorded against this start (its commit, its start time, the flag cleared), so the same surface at
        // the same main is not tried, and its setter not told, again on every pass.
        func finish(_ status: PreviewStatus, _ message: String?, _ update: PreviewUpdate? = nil) {
            _ = try? store.updatePreviewState(surfaceId: id, now: clock()) {
                $0.status = status; $0.message = message; $0.pid = nil; $0.resolvedURL = nil
                $0.commit = commit; $0.startedAt = now; $0.restartRequestedAt = nil; $0.logPath = logURL.path
                $0.simulatorId = nil; $0.smokeResults = update?.smokeResults ?? []; $0.outputPath = update?.outputPath
            }
            if status == .failed { notifyFailure(company: company, surface: surface, commit: commit, message: message ?? "failed", now: clock()) }
        }
        guard let kind = surface.previewKind, kind != .artifact else {
            finish(.failed, PreviewSurface.kindRefusal)
            return
        }
        if let why = await unavailableReason(kind) {
            finish(.unavailable, why)
            return
        }
        // Kinds without a URL get port 0 (`PORT=0`) and record none.
        let port: Int
        if kind.usesURL {
            do { port = try PortAllocator.port(for: surface, store: store) } catch {
                finish(.failed, Store.flat(Self.text(error), max: 200))
                return
            }
        } else {
            port = 0
        }
        // The port is recorded (reserved) in the same write that moves the surface to building.
        let started = try? store.updatePreviewState(surfaceId: id, now: now) {
            $0.status = surface.build == nil ? .starting : .building
            $0.commit = commit; $0.port = kind.usesURL ? port : nil; $0.startedAt = now; $0.restartRequestedAt = nil; $0.pid = nil
            $0.message = nil; $0.resolvedURL = nil; $0.logPath = logURL.path
            $0.simulatorId = nil; $0.smokeResults = []; $0.outputPath = nil
            if fresh { $0.exits = [] }
        }
        guard started != nil else { return }        // removed meanwhile
        let runId: String
        do { runId = try EngineLayout.previewRunId(surfaceId: id, commit: commit, start: n) } catch {
            finish(.failed, Self.text(error))
            return
        }
        let (engineStore, workspace) = (self.store, layout.workspace)
        let sha7 = String(commit.prefix(7))
        // The logs directory is walked (no link followed) and the export made, both git/file work off the pool.
        let exported: Result<URL, ExportFailure> = await blocking.run {
            do { try EngineFiles.directory(workspace: workspace, ".brahma/preview/logs") } catch {
                return .failure(ExportFailure(message: "its log directory is not safe to use"))
            }
            do { return .success(try EngineExport.export(store: engineStore, company: company, runId: runId, commit: commit)) } catch {
                return .failure(ExportFailure(message: "could not export \(sha7)"))
            }
        }
        let run: URL
        switch exported {
        case .success(let dir): run = dir
        case .failure(let f):
            await blocking.run { EngineExport.remove(store: engineStore, company: company, runId: runId) }
            finish(.failed, f.message)
            return
        }
        runs[id] = Run(company: company, runId: runId, pid: nil, kind: kind)
        if Task.isCancelled { await stopRun(id); return }
        guard let adapter = adapters[kind] else {    // checked above; the table never changes
            await stopRun(id)
            finish(.unavailable, Self.noAdapterMessage(kind))
            return
        }
        // The iOS gate, again at the last moment: the approval is read now, and the approved surface is what starts.
        var surface = surface
        if kind == .ios {
            guard let current = try? store.previewSurface(companyId: company.id, id: id), current.previewKind == .ios,
                  current.outsideSandboxApprovedAt != nil else {
                await stopRun(id)
                finish(.unavailable, SimulatorApproval.waitingMessage)
                return
            }
            surface = current
        }
        // A macOS app's data place, made (link-safe) before its policy names it (fix round 1, I1).
        if kind == .macos {
            let name = surface.name
            let prepared = await blocking.run { (try? PreviewPolicy.prepareAppData(layout, surface: name)) != nil }
            guard prepared else {
                await stopRun(id)
                finish(.failed, Self.unsafeAppDataMessage)
                return
            }
        }
        // The surface's subject principals, resolved once for this start (S6), from the surface record whose commands this
        // start runs (S6-c1): its own setter, and only while the stored surface still has that setter and those commands.
        // Unsandboxed only when the setter and the company narrow to Full under the ceiling; in a Full company an unconfirmed
        // setter runs sandboxed with the B1 line. A surface changed or removed since it was read: nothing runs on the stale
        // record; the start goes back to idle with a restart requested (no failure, no notice, no B1 line), and the next pass
        // starts the current surface under its own setter.
        // S6-c2: the surface supplies only the commands and who set them. The profiles (the company's, the setter's role) and
        // every policy input (domains, local binding, read paths) are the live company's, read at the resolution (`live`);
        // a live company that cannot be read, or whose sandbox layout (workspace, slug) is not the one this start exported
        // into, takes the same abort.
        #if DEBUG
        beforeResolve?(surface)
        #endif
        let principals: PrincipalSet
        let live: Company
        switch PrincipalResolver(store: engineStore, ceiling: ceiling).resolve(holding: .preview(surface)) {
        case .allow(let resolved, _) where resolved.company.id == company.id && sandboxLayout(resolved.company) == sandbox:
            (principals, live) = (resolved.principals, resolved.company)
        case .allow, .deny:
            await stopRun(id)
            do {
                _ = try store.updatePreviewState(surfaceId: id, now: clock()) {
                    $0.status = .idle; $0.message = nil; $0.pid = nil; $0.resolvedURL = nil; $0.restartRequestedAt = now
                }
            } catch {
                FileHandle.standardError.write(Data("brahma preview: could not request a restart of a changed surface (\(error))\n".utf8))
            }
            return
        }
        PrincipalResolver.noteSandboxed(principals, store: engineStore, subject: "Preview \(surface.name)", kind: .preview, now: clock())
        let policies = PreviewPolicy.forKind(kind, layout: layout, run: run, company: live, sandbox: sandbox, port: port,
                                             surface: surface.name)
        var environment = PreviewContext.environment(base: baseEnvironment, port: port)
        if kind == .ios || kind == .macos { environment["BRAHMA_DERIVED_DATA"] = PreviewPolicy.derivedData(run: run).path }
        let context = PreviewContext(surface: surface, company: live, layout: layout, run: run, commit: commit, port: port,
                                     policy: policies.policy, environment: environment, logURL: logURL, timeouts: timeouts,
                                     outputURL: layout.previewOutput(name: surface.name), appPolicy: policies.appPolicy,
                                     unsandboxed: principals.runsUnsandboxed,
                                     onSpawn: { pid, start in await self.spawned(id, pid: pid, start: start) }, redactor: engineStore.redactor)
        runs[id]?.context = context
        let update = await adapter.start(context)
        if Task.isCancelled || epoch != stopEpoch || update.status == .stopped {
            // What the start left (a pid, a device) is recorded on the run so `stopRun` reaches it. (O1: the fallback is read
            // before the run is modified; an optional-chained assignment would read `runs` inside its own modify access.)
            let pid = update.process ?? runs[id]?.pid
            runs[id]?.pid = pid
            runs[id]?.simulatorId = update.simulatorId
            await stopRun(id)
            return
        }
        guard update.status == .running || update.status == .ran else {
            await stopRun(id)
            finish(update.status, update.message, update)
            return
        }
        // Running (a server, a macOS app with its pid, a Simulator app with its device) or ran (terminal: its export stays
        // until the next start or stop, no process is watched).
        runs[id]?.pid = update.process
        runs[id]?.simulatorId = update.simulatorId
        let saved = try? store.updatePreviewState(surfaceId: id, now: clock()) {
            $0.status = update.status; $0.pid = update.process; $0.resolvedURL = update.resolvedURL; $0.message = update.message
            $0.simulatorId = update.simulatorId; $0.smokeResults = update.smokeResults; $0.outputPath = update.outputPath
        }
        guard saved != nil else {                    // removed while it started
            await stopRun(id)
            return
        }
        let text: String
        if update.status == .ran {
            text = "Preview \(surface.name) ran at \(commit.prefix(7))" + (update.message.map { ": " + Store.flat($0, max: 120) } ?? "")
        } else if let url = update.resolvedURL {
            text = "Preview \(surface.name) running at \(Store.flat(url, max: 120))"
        } else {
            text = "Preview \(surface.name) running at \(commit.prefix(7))"
        }
        _ = try? store.appendEvent(ActivityEvent(companyId: company.id, agentId: nil, turnId: nil, kind: .preview, text: text, createdAt: clock()))
    }

    struct ExportFailure: Error, Sendable { var message: String }

    /// C7 (S6-c2): a sprint demo runs a new command in a run started earlier, so it never reuses the start's decision. The
    /// run's surface is resolved again (`resolve(holding:)`, against the live records), and the demo's context takes the
    /// Full route, the policies and the company from that resolution. Nil (the demo is skipped) when the stored surface no
    /// longer matches the run's, the live company cannot be read, or its sandbox layout is not the run's. No B1 line: the
    /// start wrote the surface's.
    func redecided(_ context: PreviewContext, kind: PreviewKind) -> PreviewContext? {
        let resolved: PrincipalResolver.Resolved
        switch PrincipalResolver(store: store, ceiling: ceiling).resolve(holding: .preview(context.surface)) {
        case .allow(let r, _) where r.company.id == context.company.id: resolved = r
        case .allow, .deny: return nil
        }
        let sandbox = sandboxLayout(resolved.company)
        guard sandbox == sandboxLayout(context.company) else { return nil }
        let policies = PreviewPolicy.forKind(kind, layout: context.layout, run: context.run, company: resolved.company, sandbox: sandbox,
                                             port: context.port, surface: context.surface.name)
        var c = context
        c.company = resolved.company
        c.policy = policies.policy
        c.appPolicy = policies.appPolicy
        c.unsandboxed = resolved.principals.runsUnsandboxed
        return c
    }

    /// The adapter spawned the server (or app): its pid and its exact start time, read while it was unreaped (final review I2).
    private func spawned(_ id: String, pid: Int32, start: Double) {
        pending.remove(id)
        runs[id]?.pid = pid
        _ = try? store.updatePreviewState(surfaceId: id, now: clock()) { $0.status = .starting; $0.pid = pid; $0.pidStart = start }
    }

    static func text(_ error: any Error) -> String {
        (error as? WorkError)?.message ?? "\(error)"
    }

    /// The failure notice: an activity line, and one system DM to the setter when that is a live agent of the company. Only
    /// engine-composed text: the surface name (a validated token), the commit, the engine's reason and the log's path.
    private func notifyFailure(company: Company, surface: PreviewSurface, commit: String, message: String, now: Date) {
        let text = "Preview \(surface.name) failed at \(commit.prefix(7)): \(message)"
        let log = EngineLayout(workspace: sandboxLayout(company).workspace).previewLog(name: surface.name).path
        let store = self.store
        do {
            try store.writer.write { db in
                try ActivityEvent(companyId: company.id, agentId: nil, turnId: nil, kind: .preview, text: text, createdAt: now).insert(db)
                guard surface.setById != "owner", let agent = try Agent.fetchOne(db, key: surface.setById),
                      agent.companyId == company.id, agent.state != .killed else { return }
                try MessageRouter(store: store).sendDM(db: db, companyId: company.id, from: .system, to: agent.name,
                                                       text: "\(text). Log: \(log).", now: now)
            }
        } catch {
            FileHandle.standardError.write(Data("brahma preview: could not record the failure of \(surface.name): \(error)\n".utf8))
        }
    }

    // MARK: Stops

    /// Stops what the run's adapter started (`stop`: a Simulator app, a macOS app, a server), terminates the run's process
    /// group (if any is still in the table) and deletes its export.
    private func stopRun(_ id: String) async {
        guard let run = runs.removeValue(forKey: id) else { return }
        if let context = run.context, let adapter = adapters[run.kind] {
            let state = PreviewState(surfaceId: id, companyId: run.company.id, status: .running, commit: context.commit,
                                     port: context.port, pid: run.pid, updatedAt: clock(), simulatorId: run.simulatorId)
            await adapter.stop(context, state: state)
        }
        if let pid = run.pid, let process = deps.processes.process(pid) {
            await process.terminate(grace: WebAdapter.stopGrace)
            deps.processes.remove(pid)
        }
        let store = self.store
        await blocking.run { EngineExport.remove(store: store, company: run.company, runId: run.runId) }
    }

    /// Stops a surface (its start, its process) and records `stopped` with `message` when it was building, starting or running.
    private func stopSurface(_ id: String, message: String, now: Date) async {
        if let task = starts[id] {
            task.cancel()
            await task.value
        }
        await stopRun(id)
        restartAt[id] = nil
        try? store.markPreviewStopped(surfaceId: id, message: message, now: now)
    }

    /// The engine shutting down: every surface stopped, recorded `"engine stopped"` (the next engine starts them again).
    public func stopAll() async { await stop(message: Self.shutdownMessage) }

    /// The owner's emergency stop (`EmergencyStopObserver`; the engine runs it once per stop): every surface of every company
    /// stopped, recorded exactly `"stopped by the owner"` whatever note `reason` carries. While the stop holds `reconcile`
    /// starts nothing; the first pass after the resume starts them again.
    public func stopAll(reason: String) async { await stop(message: Self.ownerStopMessage) }

    /// Stops every surface of every company: starts cancelled (again, until none is left: Task 3 M1), process groups
    /// terminated (every run's, then anything still in the process registry), exports deleted, and every building, starting
    /// or running record `stopped` with `message`. Nothing starts while it runs, and a pass that began before it starts
    /// nothing after it (`stopEpoch`); a later `reconcile` starts them again.
    private func stop(message: String) async {
        stopping += 1
        stopEpoch += 1
        defer { stopping -= 1 }
        // The starts and a sprint demo in flight (its reconcile passes, a running demo command) are cancelled together, then
        // awaited: the demo returns as soon as it is cancelled (`waitForStarts`), and no start is waited out (fix round 1 I1,
        // fix round 2 N1).
        for task in starts.values { task.cancel() }
        if let demo = demoTask {
            demo.cancel()
            _ = await demo.value
        }
        while !starts.isEmpty {
            for task in starts.values { task.cancel() }
            await waitForStarts()
        }
        for id in Array(runs.keys) { await stopRun(id) }
        // A server whose run a pass in flight is stopping right now (its exit notice) is no longer in `runs`.
        for process in deps.processes.all {
            await process.terminate(grace: WebAdapter.stopGrace)
            deps.processes.remove(process.pid)
        }
        restartAt = [:]
        let now = clock()
        for company in (try? store.companies()) ?? [] {
            for id in ((try? store.previewStates(companyId: company.id)) ?? [:]).keys {
                try? store.markPreviewStopped(surfaceId: id, message: message, now: now)
            }
        }
    }

    // MARK: Engine start

    /// Every record an earlier engine left building, starting or running: its group is killed if it still is that record's
    /// (`orphanGroup`), and it becomes `stopped`, so this pass starts it again. A Simulator device an earlier engine left
    /// (Task 7, obligation b): the recorded `simulatorId` is shut down and cleared, and every booted `Brahma …` device is shut
    /// down too (`shutdownLeftovers`; the owner's own simulators are never touched).
    private func recover(now: Date) async {
        let simulator = deps.simulator
        for company in (try? store.companies()) ?? [] {
            for state in ((try? store.previewStates(companyId: company.id)) ?? [:]).values {
                if let udid = state.simulatorId {
                    await blocking.run { _ = try? simulator.shutdown(udid) }
                    _ = try? store.updatePreviewState(surfaceId: state.surfaceId, now: now) { $0.simulatorId = nil }
                }
                guard [.building, .starting, .running].contains(state.status) else { continue }
                // Signalled only while the recorded pid is still exactly the process the engine spawned (a legacy record
                // without `pidStart` never is); the record becomes `stopped` either way.
                if let pid = state.pid, Self.orphanGroup(pid: pid, pidStart: state.pidStart) {
                    killpg(pid, SIGTERM)
                    let deadline = AwakeTime.deadline(after: WebAdapter.stopGrace)
                    while AwakeTime.now < deadline, Self.orphanGroup(pid: pid, pidStart: state.pidStart) {
                        try? await AwakeTime.sleep(for: .milliseconds(50))
                    }
                    if Self.orphanGroup(pid: pid, pidStart: state.pidStart) { killpg(pid, SIGKILL) }
                }
                _ = try? store.updatePreviewState(surfaceId: state.surfaceId, now: now) {
                    $0.status = .stopped; $0.message = Self.engineRestartedMessage; $0.pid = nil; $0.resolvedURL = nil; $0.simulatorId = nil
                }
            }
        }
        await blocking.run { _ = try? simulator.shutdownLeftovers() }
    }

    /// Whether `pid` is still exactly the process the engine spawned: the leader of its own process group, ours, alive, and
    /// started at exactly `pidStart`, the start time read at the spawn while the child was unreaped (final review I2; the
    /// rule turns, child groups and litestream follow). A recycled pid has another start, so it is never signalled, and a
    /// record without `pidStart` (an older engine's) proves nothing, so it never is either. Off Darwin nothing is claimed.
    static func orphanGroup(pid: Int32, pidStart: Double?) -> Bool {
        #if canImport(Darwin)
        guard pid > 1, let pidStart, let entry = ProcessTable.entry(pid), entry.pgid == pid, entry.uid == getuid(), !entry.isZombie
        else { return false }
        return entry.start == pidStart
        #else
        return false
        #endif
    }
}

/// The surfaces whose start is in flight and not spawned yet. Lock-protected (read by the orchestrator synchronously).
final class PendingStarts: @unchecked Sendable {
    private let lock = NSLock()
    private var ids = Set<String>()
    func insert(_ id: String) { lock.withLock { _ = ids.insert(id) } }
    func remove(_ id: String) { lock.withLock { _ = ids.remove(id) } }
    var count: Int { lock.withLock { ids.count } }
}
