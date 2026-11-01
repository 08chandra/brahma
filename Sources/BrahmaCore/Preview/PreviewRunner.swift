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
/// that a Full company's preview runs unsandboxed exactly when its checks would (PR-5, `unsandboxed(store:company:surface:)`).
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
/// group is killed when the recorded pid is still that group's leader with a start time inside the record (3a's
/// `ProcessTable`, PR-4), the surface becomes `stopped` and is started again from a fresh export (the engine's startup sweep
/// deleted every export).
public actor PreviewRunner {
    public static let debounce: TimeInterval = 5
    public static let crashWindow: TimeInterval = 300
    public static let crashLimit = 3
    public static let backoff: [TimeInterval] = [2, 10, 30]
    public static let maxConcurrentBuilds = 1

    static let crashLoopMessage = "exited 3 times in 5 minutes; restart it or wait for the next merge"
    static let pressureMessage = "waiting: memory pressure"
    static let pausedMessage = "company paused"
    static let engineRestartedMessage = "engine restarted"
    public static let shutdownMessage = "engine stopped"

    let store: Store
    let paths: BrahmaPaths
    nonisolated let deps: PreviewDependencies
    let sandboxLayout: @Sendable (Company) -> SandboxLayout
    let timeouts: PreviewTimeouts
    let memory: @Sendable () -> Bool
    let clock: @Sendable () -> Date
    let blocking: Blocking
    let baseEnvironment: [String: String]

    /// Starts in flight whose server is not spawned yet (a build, an export): child work next to `deps.processes`.
    private nonisolated let pending = PendingStarts()
    /// Surface id → its start task.
    private var starts: [String: Task<Void, Never>] = [:]
    /// Surface id → the run it has now (its export and, once spawned, its process).
    private var runs: [String: Run] = [:]
    /// Company id → the `main` last seen and when it was first seen (the debounce).
    private var mainSeen: [String: (commit: String, at: Date)] = [:]
    /// Surface id → when a crashed server may start again.
    private var restartAt: [String: Date] = [:]
    private var startCounter = 0
    private var recovered = false
    /// While `stopAll` runs, `reconcile` does nothing.
    private var stopping = 0

    struct Run: Sendable {
        var company: Company
        var runId: String
        var pid: Int32?
    }

    public init(store: Store, paths: BrahmaPaths, deps: PreviewDependencies, sandboxLayout: @escaping @Sendable (Company) -> SandboxLayout,
                timeouts: PreviewTimeouts = .init(), memory: @escaping @Sendable () -> Bool, clock: @escaping @Sendable () -> Date = Store.now) {
        self.init(store: store, paths: paths, deps: deps, sandboxLayout: sandboxLayout, timeouts: timeouts, memory: memory, clock: clock,
                  blocking: Blocking(), environment: ProcessInfo.processInfo.environment)
    }

    init(store: Store, paths: BrahmaPaths, deps: PreviewDependencies, sandboxLayout: @escaping @Sendable (Company) -> SandboxLayout,
         timeouts: PreviewTimeouts, memory: @escaping @Sendable () -> Bool, clock: @escaping @Sendable () -> Date, blocking: Blocking,
         environment: [String: String]) {
        self.store = store; self.paths = paths; self.deps = deps; self.sandboxLayout = sandboxLayout; self.timeouts = timeouts
        self.memory = memory; self.clock = clock; self.blocking = blocking; self.baseEnvironment = environment
    }

    /// Non-turn child work previews hold for the safety cap: every running server plus every start not yet spawned.
    public nonisolated var activeChildren: Int { deps.processes.count + pending.count }

    // MARK: The pass

    public func reconcile(now: Date) async {
        guard stopping == 0 else { return }
        if !recovered {
            recovered = true
            await recover(now: now)
        }
        // L-5lite: while `store.engineStopped()` is non-nil nothing starts or restarts here (EmergencyStopObserver, PR-35 3s).
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
                }
                continue
            }
            guard let main = company.mainCommit else { continue }
            if mainSeen[company.id]?.commit != main { mainSeen[company.id] = (main, now) }
            let mainSettled = now.timeIntervalSince(mainSeen[company.id]?.at ?? now) >= Self.debounce
            for surface in surfaces where starts[surface.id] == nil && surface.previewKind == .web {
                let state = states[surface.id] ?? PreviewState(surfaceId: surface.id, companyId: company.id, updatedAt: now)
                if await noticeExit(surface: surface, company: company, state: state, now: now) { continue }
                guard let fresh = wantsStart(surface: surface, state: state, main: main, mainSettled: mainSettled, now: now) else { continue }
                if pressured {
                    if state.message != Self.pressureMessage {
                        _ = try? store.updatePreviewState(surfaceId: surface.id, now: now) { $0.message = Self.pressureMessage }
                    }
                    continue
                }
                guard starts.count < Self.maxConcurrentBuilds else { continue }
                launch(company: company, surface: surface, commit: main, fresh: fresh, now: now)
            }
        }
        for id in Array(runs.keys) where !present.contains(id) && starts[id] == nil { await stopRun(id) }
        restartAt = restartAt.filter { present.contains($0.key) }
    }

    /// Nil: leave it. Otherwise start it; `true` when the start is a new one (main moved, changed or flagged, never started),
    /// which clears its crash record, `false` for a restart after a crash, a pause or a stop.
    private func wantsStart(surface: PreviewSurface, state: PreviewState, main: String, mainSettled: Bool, now: Date) -> Bool? {
        let changed = state.restartRequestedAt != nil || state.startedAt.map { surface.updatedAt > $0 } == true
        let moved = state.commit != nil && state.commit != main
        if changed || (moved && mainSettled) { return true }
        if isLive(surface.id) { return nil }
        switch state.status {
        case .failed, .unavailable:
            return nil                               // until main moves, it changes, or it is flagged
        default:
            if moved { return nil }                  // the debounce
            if state.commit == nil { return true }   // never started
            if let at = restartAt[surface.id] { return now >= at ? false : nil }
            return false
        }
    }

    private func isLive(_ id: String) -> Bool {
        guard let pid = runs[id]?.pid, let process = deps.processes.process(pid) else { return false }
        return process.isAlive()
    }

    /// A server of ours that ended on its own: its exit is recorded, then it restarts after the backoff or, at the crash
    /// limit, fails. Returns whether it handled one.
    private func noticeExit(surface: PreviewSurface, company: Company, state: PreviewState, now: Date) async -> Bool {
        guard let run = runs[surface.id], let pid = run.pid, let process = deps.processes.process(pid), !process.isAlive() else { return false }
        let code = await WebAdapter.exitCode(process)
        await stopRun(surface.id)
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

    // MARK: Starts

    private func launch(company: Company, surface: PreviewSurface, commit: String, fresh: Bool, now: Date) {
        startCounter += 1
        let n = startCounter
        restartAt[surface.id] = nil
        pending.insert(surface.id)
        starts[surface.id] = Task {
            await self.perform(company: company, surface: surface, commit: commit, fresh: fresh, start: n, now: now)
            self.startEnded(surface.id)
        }
    }

    private func startEnded(_ id: String) {
        starts[id] = nil
        pending.remove(id)
    }

    /// Waits for every start in flight (tests; and `stopAll`, after cancelling them).
    public func waitForStarts() async {
        while let task = starts.values.first { await task.value }
    }

    private func perform(company: Company, surface: PreviewSurface, commit: String, fresh: Bool, start n: Int, now: Date) async {
        await stopRun(surface.id)
        let id = surface.id
        let layout = EngineLayout(workspace: sandboxLayout(company).workspace)
        let logURL = layout.previewLog(name: surface.name)
        // A failure is recorded against this start (its commit, its start time, the flag cleared), so the same surface at
        // the same main is not tried, and its setter not told, again on every pass.
        func finish(_ status: PreviewStatus, _ message: String?) {
            _ = try? store.updatePreviewState(surfaceId: id, now: clock()) {
                $0.status = status; $0.message = message; $0.pid = nil; $0.resolvedURL = nil
                $0.commit = commit; $0.startedAt = now; $0.restartRequestedAt = nil; $0.logPath = logURL.path
            }
            if status == .failed { notifyFailure(company: company, surface: surface, commit: commit, message: message ?? "failed", now: clock()) }
        }
        let port: Int
        do { port = try PortAllocator.port(for: surface, store: store) } catch {
            finish(.failed, Store.flat(Self.text(error), max: 200))
            return
        }
        // The port is recorded (reserved) in the same write that moves the surface to building.
        let started = try? store.updatePreviewState(surfaceId: id, now: now) {
            $0.status = surface.build == nil ? .starting : .building
            $0.commit = commit; $0.port = port; $0.startedAt = now; $0.restartRequestedAt = nil; $0.pid = nil; $0.message = nil
            $0.resolvedURL = nil; $0.logPath = logURL.path
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
        runs[id] = Run(company: company, runId: runId, pid: nil)
        if Task.isCancelled { await stopRun(id); return }
        var deps = self.deps
        if Self.unsandboxed(store: engineStore, company: company, surface: surface) { deps.sandbox = deps.unsandboxed }
        let context = PreviewContext(surface: surface, company: company, layout: layout, run: run, commit: commit, port: port,
                                     policy: PreviewPolicy.server(layout, run: run, company: company, port: port),
                                     environment: PreviewContext.environment(base: baseEnvironment, port: port), logURL: logURL,
                                     timeouts: timeouts)
        let update = await WebAdapter.startServer(context, deps: deps, onSpawn: { pid in await self.spawned(id, pid: pid) })
        if Task.isCancelled || update.status == .stopped {
            await stopRun(id)
            return
        }
        guard update.status == .running, let pid = update.process else {
            await stopRun(id)
            finish(update.status, update.message)
            return
        }
        runs[id]?.pid = pid
        let saved = try? store.updatePreviewState(surfaceId: id, now: clock()) {
            $0.status = .running; $0.pid = pid; $0.resolvedURL = update.resolvedURL; $0.message = nil
        }
        guard saved != nil else {                    // removed while it started
            await stopRun(id)
            return
        }
        _ = try? store.appendEvent(ActivityEvent(companyId: company.id, agentId: nil, turnId: nil, kind: .preview,
                                                 text: "Preview \(surface.name) running at \(Store.flat(update.resolvedURL ?? "", max: 120))",
                                                 createdAt: clock()))
    }

    struct ExportFailure: Error, Sendable { var message: String }

    private func spawned(_ id: String, pid: Int32) {
        pending.remove(id)
        runs[id]?.pid = pid
        _ = try? store.updatePreviewState(surfaceId: id, now: clock()) { $0.status = .starting; $0.pid = pid }
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

    /// Terminates the run's process group (if any) and deletes its export.
    private func stopRun(_ id: String) async {
        guard let run = runs.removeValue(forKey: id) else { return }
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

    public func stopAll() async { await stopAll(reason: Self.shutdownMessage) }

    /// Stops every surface of every company: starts cancelled, process groups terminated, exports deleted, and every
    /// building, starting or running record `stopped` with `reason` (`"stopped by the owner"` for the emergency stop, once
    /// 5-lite's `EmergencyStopObserver` exists: L-5lite). Nothing starts while it runs; a later `reconcile` starts them again.
    public func stopAll(reason: String) async {
        stopping += 1
        defer { stopping -= 1 }
        for task in starts.values { task.cancel() }
        await waitForStarts()
        for id in Array(runs.keys) { await stopRun(id) }
        restartAt = [:]
        let now = clock()
        for company in (try? store.companies()) ?? [] {
            for id in ((try? store.previewStates(companyId: company.id)) ?? [:]).keys {
                try? store.markPreviewStopped(surfaceId: id, message: reason, now: now)
            }
        }
    }

    // MARK: Engine start

    /// Every record an earlier engine left building, starting or running: its group is killed if it still is that record's
    /// (`orphanGroup`), and it becomes `stopped`, so this pass starts it again.
    private func recover(now: Date) async {
        for company in (try? store.companies()) ?? [] {
            for state in ((try? store.previewStates(companyId: company.id)) ?? [:]).values
            where [.building, .starting, .running].contains(state.status) {
                if let pid = state.pid, Self.orphanGroup(pid: pid, startedAt: state.startedAt, updatedAt: state.updatedAt) {
                    killpg(pid, SIGTERM)
                    let deadline = AwakeTime.deadline(after: WebAdapter.stopGrace)
                    while AwakeTime.now < deadline, Self.orphanGroup(pid: pid, startedAt: state.startedAt, updatedAt: state.updatedAt) {
                        try? await AwakeTime.sleep(for: .milliseconds(50))
                    }
                    if Self.orphanGroup(pid: pid, startedAt: state.startedAt, updatedAt: state.updatedAt) { killpg(pid, SIGKILL) }
                }
                _ = try? store.updatePreviewState(surfaceId: state.surfaceId, now: now) {
                    $0.status = .stopped; $0.message = Self.engineRestartedMessage; $0.pid = nil; $0.resolvedURL = nil
                }
            }
        }
    }

    /// Whether `pid` is still the leader of its own process group, ours, alive, and started between the record's start and
    /// its last write (3a's `ProcessTable`, PR-4: pgid and start time, so a recycled pid is never signalled). Off Darwin the
    /// table's start times are not wall-clock, so nothing is claimed.
    static func orphanGroup(pid: Int32, startedAt: Date?, updatedAt: Date) -> Bool {
        #if canImport(Darwin)
        guard pid > 1, let startedAt, let entry = ProcessTable.entry(pid), entry.pgid == pid, entry.uid == getuid(), !entry.isZombie
        else { return false }
        return entry.start >= startedAt.timeIntervalSince1970 - 2 && entry.start <= updatedAt.timeIntervalSince1970 + 2
        #else
        return false
        #endif
    }

    // MARK: Routing (PR-5)

    /// A Full company's preview runs unsandboxed exactly when its checks would (`Orchestrator.checkRoute`): the company runs
    /// Full and so does the role of the agent who set the surface (an owner-set surface follows the company).
    static func unsandboxed(store: Store, company: Company, surface: PreviewSurface) -> Bool {
        guard company.permissionProfile == .full else { return false }
        let role = surface.setById == "owner" ? nil : (try? store.agent(id: surface.setById))?.role
        return role.map { company.profile(forRole: $0) == .full } ?? true
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

/// The runner a Full company's previews use (PR-5: as its checks run unsandboxed): `/bin/sh -c` in its own process group
/// through 3a's helpers (`GroupRun`, `ProcessGroupChild`, `OutputCapture`), the policy unenforced.
public struct UnsandboxedPreviewRunner: SandboxedRunner {
    public init() {}

    public func run(command: String, cwd: URL, environment: [String: String], timeout: Duration, outputURL: URL,
                    policy: SandboxPolicy) async -> CheckOutcome {
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let cancel = GroupRun.CancelFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CheckOutcome, Never>) in
                let thread = Thread {
                    continuation.resume(returning: GroupRun.run(
                        executable: "/bin/sh", arguments: ["/bin/sh", "-c", command], workingDirectory: cwd, timeout: seconds,
                        outputURL: outputURL, environment: environment, termGrace: 5, clock: { AwakeTime.uptime() }, cancel: cancel))
                }
                thread.name = "brahma-preview-build"
                thread.start()
            }
        } onCancel: { cancel.set() }
    }

    public func spawn(command: String, cwd: URL, environment: [String: String], logURL: URL, policy: SandboxPolicy) throws -> any SandboxedProcess {
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = open(logURL.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw SandboxError.invalidPath("cannot open the log \(logURL.path)") }
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { close(file); throw SandboxError.invalidPath("no pipe for the log") }
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC); _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        let child: ProcessGroupChild
        do {
            child = try ProcessGroupChild.spawn(executable: "/bin/sh", arguments: ["/bin/sh", "-c", command], environment: environment,
                                                workingDirectory: cwd, output: fds[1])
        } catch {
            close(fds[0]); close(fds[1]); close(file)
            throw error
        }
        close(fds[1])
        return PlainGroupProcess(child: child, capture: OutputCapture(readEnd: fds[0], file: file, cap: ProcessCheckRunner.outputCap,
                                                                      tailBytes: 4096, marker: ProcessCheckRunner.truncationMarker))
    }
}

/// A process `UnsandboxedPreviewRunner.spawn` started: a reaper thread waits for the leader without reaping it, ends the
/// output capture, then reaps it (`ProcessGroupChild.finish`), so no signal is sent after the reap.
final class PlainGroupProcess: SandboxedProcess, @unchecked Sendable {
    let child: ProcessGroupChild
    private let reaped = DispatchSemaphore(value: 0)

    init(child: ProcessGroupChild, capture: OutputCapture) {
        self.child = child
        let thread = Thread { [child, capture, reaped] in
            child.finish()
            _ = capture.finish(drain: 2)
            reaped.signal()
        }
        thread.name = "brahma-preview-reaper"
        thread.start()
    }

    var pid: Int32 { child.pid }
    func isAlive() -> Bool { !child.hasExited() }

    func exitStatus() -> Int32? {
        guard child.hasExited() else { return nil }
        return ProcessGroupChild.exitCode(child.finish())
    }

    func terminate(grace: Duration) async {
        if !child.hasExited() {
            child.signalGroup(SIGTERM)
            let deadline = AwakeTime.deadline(after: grace)
            while !child.hasExited(), AwakeTime.now < deadline { try? await AwakeTime.sleep(for: .milliseconds(20)) }
            if !child.hasExited() { child.signalGroup(SIGKILL) }
        }
        let reaped = self.reaped
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                reaped.wait()
                reaped.signal()
                continuation.resume()
            }
        }
    }
}
