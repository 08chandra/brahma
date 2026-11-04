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
    func smokeTick(now: Date, config: SchedulerConfig, held: Bool, pressure: MemoryPressure, companies: [Company]) {
        // L-5lite: skip while engineStopped (EmergencyStopObserver, PR-35 part 5s).
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
    /// slot (PR-36) and runs with this engine's `Blocking` and clock (`Store.runSmoke`).
    public func runSmoke(companyId: String, commit: String, reason: MainSmokeReason, releaseId: String? = nil) async throws -> MainSmokeRun {
        let (engineStore, checks, slots, blocking, clock) = (self.store, smokeChecks, smokeSlots, self.blocking, self.clock)
        return try await asEngine {
            try await slots.withSlot(companyId) {
                try await engineStore.runSmoke(companyId: companyId, commit: commit, reason: reason, releaseId: releaseId,
                                               checks: checks, blocking: blocking, clock: clock)
            }
        }
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
