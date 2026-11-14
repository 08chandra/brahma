import Foundation

extension Orchestrator {
    /// The tick's "main smoke" step (Plan L Task 5, PR-6), per company:
    /// - when the company has a smoke check and its engine-accepted `main` (`company.mainCommit`, PR-22) has no `merge` run,
    ///   one is queued (a newer queued run supersedes older queued ones, `Store.queueSmoke`);
    /// - the newest queued run is executed as a tracked detached task (`smokeTasks`, counted in `otherChildren`), one at a
    ///   time per company: it holds the company's `smokeSlots` slot, which a release's own smoke shares (PR-36). All git and
    ///   file work of a run happens inside this engine's `Blocking`.
    /// Starts are gated like checks and merges (fix I2): nothing starts under a hold or critical memory pressure, only into a
    /// slot `Scheduler.freeSlots` has free, never in a paused company, and not while a company's re-queued run backs off.
    /// While the owner's stop holds (this tick's read, `engineStoppedNow`) the step is skipped entirely: nothing is queued or
    /// started (PR-35 5s); a run in flight was cancelled by `enforceStop`.
    func smokeTick(now: Date, config: SchedulerConfig, held: Bool, pressure: MemoryPressure, companies: [Company]) {
        guard !engineStoppedNow else { return }
        smokeBackoff = smokeBackoff.filter { $0.value > now }
        for company in companies {
            attempt { try self.store.queueMergeSmokeIfNeeded(companyId: company.id, now: now) }
            guard !held, pressure != .critical, company.status == .running, smokeTasks[company.id] == nil,
                  smokeBackoff[company.id] == nil else { continue }
            let slots = Scheduler.freeSlots(config: config, running: runningCount(), otherChildren: otherChildren, safetyOnly: previewChildren,
                                            pressure: pressure, held: held)
            guard slots > 0 else { return }
            guard let next = try? self.store.nextQueuedSmoke(companyId: company.id) else { continue }
            let (engineStore, checks, slots2, blocking, clock) = (self.store, smokeChecks, smokeSlots, self.blocking, self.clock)
            let companyId = company.id
            smokeTasks[companyId] = Task.detached { [self] in
                let requeued: Bool = await asEngine {
                    await slots2.withSlot(companyId) {
                        do {
                            let run = try await engineStore.executeSmoke(runId: next.id, checks: checks, blocking: blocking, clock: clock)
                            return run.status == .queued && !Task.isCancelled
                        } catch {
                            self.log("the smoke run \(next.id) of \(companyId) could not be recorded: \(error)")
                            return false
                        }
                    }
                }
                await smokeEnded(companyId: companyId, requeued: requeued)
            }
        }
    }

    func smokeEnded(companyId: String, requeued: Bool) {
        if requeued { smokeBackoff[companyId] = clock().addingTimeInterval(Self.mergeRetry) }
        smokeTasks[companyId] = nil
    }

    /// A smoke run of the company's engine-accepted main outside the tick (Task 7's release smoke): holds the company's smoke
    /// slot (PR-36) and runs with this engine's `Blocking` and clock (`Store.runSmoke`). `acceptedMain` (release runs only):
    /// the engine-accepted main the caller checked `commit` is an ancestor of.
    public func runSmoke(companyId: String, commit: String, reason: MainSmokeReason, releaseId: String? = nil,
                         acceptedMain: String? = nil) async throws -> MainSmokeRun {
        try await Self.smokeEntry(store: store, checks: smokeChecks, slots: smokeSlots, blocking: blocking, clock: clock,
                                  engineId: engineId)(companyId, commit, reason, releaseId, acceptedMain)
    }

    /// `runSmoke` as a value, built from this engine's parts only (no reference to the orchestrator): what the release
    /// executor runs its release smoke through (carried-forward ruling 1), so both share one path, slot, `Blocking` and clock.
    ///
    /// Final-review I1: a release smoke usually waits for the slot behind the merge smoke of the newest `main`, and agents
    /// keep merging meanwhile. Inside the slot the engine-accepted main is read again; when it moved, the release's commit
    /// must still be its ancestor (`merge-base --is-ancestor`, else `"<sha7> is no longer on the engine-accepted main"`), and
    /// the smoke runs with that main as `acceptedMain`. A merge landing between that read and the claiming write is retried
    /// the same way, up to `ReleasePolicy.mainMovedAttempts` times.
    static func smokeEntry(store: Store, checks: SmokeChecks, slots: SmokeSlots, blocking: Blocking,
                           clock: @escaping @Sendable () -> Date, engineId: String)
        -> @Sendable (String, String, MainSmokeReason, String?, String?) async throws -> MainSmokeRun {
        { companyId, commit, reason, releaseId, acceptedMain in
            try await EngineGitGuard.$engine.withValue(engineId) {
                try await slots.withSlot(companyId) {
                    guard reason == .release, var accepted = acceptedMain else {
                        return try await store.runSmoke(companyId: companyId, commit: commit, reason: reason, releaseId: releaseId,
                                                        acceptedMain: acceptedMain, checks: checks, blocking: blocking, clock: clock)
                    }
                    var attempt = 0
                    while true {
                        attempt += 1
                        if let company = try store.company(id: companyId), let current = company.mainCommit, current != accepted {
                            let root = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
                            let onMain = await blocking.run {
                                (try? store.gitWorkspace(root: root, companyId: companyId).isAncestor(commit, of: current)) ?? false
                            }
                            guard onMain else { throw WorkError.invalid(Store.noLongerOnMain(commit)) }
                            accepted = current
                        }
                        do {
                            return try await store.runSmoke(companyId: companyId, commit: commit, reason: reason, releaseId: releaseId,
                                                            acceptedMain: accepted, checks: checks, blocking: blocking, clock: clock)
                        } catch let e as WorkError where e == .invalid(Store.notMain(commit)) && attempt < ReleasePolicy.mainMovedAttempts {
                            continue
                        }
                    }
                }
            }
        }
    }

    /// The tick's "release" step (Plan L Tasks 7 and 8, PR-6), after the main smoke: each company with an approved release or
    /// a requested rollback, and none in progress, gets one tracked detached task (`releaseTasks`, counted in `otherChildren` and `isIdle`) that runs
    /// `ReleaseExecutor.advance(companyId:now:)`; the release's own smoke on main runs inside it. Starts are gated like
    /// smokes: nothing under a hold (the owner's stop included; the executor's claim also refuses while it holds) or critical
    /// memory pressure, only into a free slot. A paused company is admitted only for a requested rollback, and then
    /// rollback-only (`advance(rollbackOnly: true)`): a deploy never starts in a paused company (Task 8 fix I1).
    func releaseTick(now: Date, config: SchedulerConfig, held: Bool, pressure: MemoryPressure, companies: [Company]) {
        guard !held, pressure != .critical else { return }
        let waiting = (try? store.companiesWithReleaseWork()) ?? []
        guard !waiting.isEmpty else { return }
        let rollbacks = (try? store.companiesWithRequestedRollback()) ?? []
        for company in companies where waiting.contains(company.id) && releaseTasks[company.id] == nil {
            let rollbackOnly = company.status != .running
            if rollbackOnly && !rollbacks.contains(company.id) { continue }
            let slots = Scheduler.freeSlots(config: config, running: runningCount(), otherChildren: otherChildren, safetyOnly: previewChildren,
                                            pressure: pressure, held: held)
            guard slots > 0 else { return }
            let (executor, clock, companyId) = (releaseExecutor, self.clock, company.id)
            releaseTasks[companyId] = Task.detached { [self] in
                await asEngine { await executor.advance(companyId: companyId, now: clock(), rollbackOnly: rollbackOnly) }
                await releaseEnded(companyId: companyId)
            }
        }
    }

    func releaseEnded(companyId: String) { releaseTasks[companyId] = nil }

    /// The default release runners: the platform sandbox (Seatbelt on macOS, else fail closed) with the checks' baseline for
    /// every step a release runs sandboxed (always the tools install and the provider CLI), the plain group runner for a Full
    /// company's build (as its checks run, PR-5), the real HTTP probe (no redirects) and the production adapters.
    static func defaultReleaseDependencies(store: Store, paths: BrahmaPaths) -> ReleaseDependencies {
        let baseline: @Sendable () -> SandboxBaseline = { checkBaseline(store: store, paths: paths) }
        let sandbox = SandboxRunners.platformDefault(baseline: baseline, proxies: EgressProxyPool(), onStraggler: { report in
            let pids = (report.killed + report.survivors).map(String.init).joined(separator: ", ")
            FileHandle.standardError.write(Data("brahma orchestrator: a release step left processes outside its group (pid \(pids))\n".utf8))
        })
        return ReleaseDependencies(sandbox: sandbox, unsandboxed: UnsandboxedPreviewRunner(), http: URLSessionHTTPProbe(),
                                   adapters: HostingAdapters.production)
    }

    /// Start-up (fix I1): runs an earlier engine left running are re-queued (merge runs at main) or recorded `error`
    /// (`Store.recoverSmokes`); each one's stale export is removed and its raw log scrubbed (or removed when it cannot be).
    func recoverSmokes(now: Date) async throws {
        let left = try store.recoverSmokes(now: now)
        guard !left.isEmpty else { return }
        let engineStore = store
        let companies = Dictionary(uniqueKeysWithValues: try store.companies().map { ($0.id, $0) })
        await blocking.run {
            for run in left {
                if let company = companies[run.companyId] { EngineExport.remove(store: engineStore, company: company, runId: run.runId) }
                if let path = run.outputPath { _ = engineStore.scrubOrRemoveSmokeLog(URL(fileURLWithPath: path)) }
            }
        }
    }

    /// The default smoke runners: the platform sandbox (Seatbelt on macOS, else fail closed) with the checks' baseline
    /// (`checkBaseline`), and the plain group runner for a Full company's smokes (as its checks run, PR-5).
    static func defaultSmokeChecks(store: Store, paths: BrahmaPaths, environment: [String: String]) -> SmokeChecks {
        let baseline: @Sendable () -> SandboxBaseline = { checkBaseline(store: store, paths: paths) }
        let sandbox = SandboxRunners.platformDefault(baseline: baseline, proxies: EgressProxyPool(), onStraggler: { report in
            let pids = (report.killed + report.survivors).map(String.init).joined(separator: ", ")
            FileHandle.standardError.write(Data("brahma orchestrator: a main smoke left processes outside its group (pid \(pids))\n".utf8))
        })
        return SmokeChecks(sandbox: sandbox, unsandboxed: UnsandboxedPreviewRunner(), paths: paths, environment: environment)
    }
}
