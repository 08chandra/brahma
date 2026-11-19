import Foundation

extension Orchestrator {
    /// Seconds before a company whose merge could not run (the checkout is not on `main`, git failed) is tried again.
    static let mergeRetry: TimeInterval = 60

    /// Once per tick, after the checks: starts the merge queue's next batch for each company that has a queued request (or an
    /// approval with none, which the queue measures first), one batch per company, into slots the safety cap has free (a batch
    /// counts in `otherChildren`). Nothing starts under a hold, critical memory pressure, the owner's stop, a held queue or a
    /// paused company. A batch that put its request back without landing anything is not tried again for `mergeRetry` seconds.
    func startMerges(now: Date, config: SchedulerConfig, held: Bool, pressure: MemoryPressure, companies: [Company]) {
        guard !held, pressure != .critical, !stoppedNow else { return }
        mergeBackoff = mergeBackoff.filter { $0.value > now }
        for company in companies where company.status == .running && (company.mergeHold == nil || Store.liftsItself(company.mergeHold)) && mergeTasks[company.id] == nil
            && mergeBackoff[company.id] == nil {
            let slots = Scheduler.freeSlots(config: config, running: runningCount(), otherChildren: otherChildren, safetyOnly: previewChildren,
                                            pressure: pressure, held: held)
            guard slots > 0 else { return }
            guard (try? store.hasMergeWork(companyId: company.id)) == true else { continue }
            let queue = mergeQueue
            mergeTasks[company.id] = Task.detached { [self] in
                await asEngine {
                    // (A request the owner's stop put back is no fault: it merges right after the resume.)
                    if let outcome = await queue.runNextBatch(company: company), outcome.merged.isEmpty,
                       !outcome.requeued.isEmpty || outcome.held != nil, (try? store.engineStopped()) == nil {
                        await holdMerges(companyId: company.id, until: clock().addingTimeInterval(Self.mergeRetry))
                    }
                }
                await mergeEnded(companyId: company.id)
            }
        }
    }

    /// Once per tick, before the merges: the main guard (`MainGuard.check`) for every company, running or paused, whose
    /// workspace is a repository, off the actor (one git task per company; a company whose batch this engine is running is
    /// left to the batch). Nothing starts under a hold or the owner's stop. Never waits on git.
    func mainGuardTick(now: Date, held: Bool, companies: [Company]) {
        guard !held, !stoppedNow else { return }
        let (store, blocking, paths) = (self.store, self.blocking, self.paths)
        for company in companies where mergeTasks[company.id] == nil {
            let key = "main-guard:\(company.id)"
            guard gitTasks[key] == nil else { continue }
            spawnGit(key) { [self] in
                let result: Result<MainGuardResult, any Error> = await blocking.run {
                    let root = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
                    guard FileManager.default.fileExists(atPath: root.appending(path: ".git").path) else { return .success(.skipped) }
                    do {
                        let git = store.gitWorkspace(root: root, companyId: company.id)
                        return .success(try MainGuard.check(company: company, store: store, git: git, paths: paths, now: now))
                    } catch { return .failure(error) }
                }
                switch result {
                case .success(.restored(let ref, let to)):
                    log("main guard: \(company.name): main restored to \(to.prefix(7)); the other tip is saved as \(ref)")
                case .success:
                    break
                case .failure(let error):
                    log("main guard: \(company.name): \(error)")
                }
            }
        }
    }

    func mergeEnded(companyId: String) { mergeTasks[companyId] = nil }

    func holdMerges(companyId: String, until: Date) { mergeBackoff[companyId] = until }

    /// Crash recovery: no merge runs at start-up. Reads `main` and the installed git's version (git: off the cooperative pool).
    func recoverMerges() async throws {
        let store = self.store
        try await blocking.tryRun { try store.recoverMerges() }
    }

    /// A merge of the company failed for the company's own reasons (the engine's own steps: locks, moving main, the engine's
    /// merge repository, main's history): held for `mergeRetry`. Such a fault is never charged to an item: the item at the head
    /// of the queue keeps its verified commit, its approval and its place, and the queue waits for the fault to clear. After
    /// `Store.maxMergeFailures` of them in a row the owner gets one engine alert (resolved when a merge lands).
    /// `streak` names the run of faults counted (the company's landings; a merge check's export counts on its own, so landings
    /// of other items in between never hide its faults).
    func companyMergeFault(company: Company, item: WorkItem, error: MergeInfrastructureError, streak: String? = nil,
                           gitVersion: String?) {
        let now = clock()
        holdMerges(companyId: company.id, until: now.addingTimeInterval(Self.mergeRetry))
        let key = streak ?? company.id
        let count = (mergeFaults[key] ?? 0) + 1
        mergeFaults[key] = count
        guard count == Store.maxMergeFailures else { return }
        do {
            try EngineAlerts.raise(
                store: store, text: "\(company.name): merges into main are held (\(Store.flat("\(error)", max: 300))); "
                    + "\(count) attempts in a row failed for Brahma's own reasons (git \(gitVersion ?? "version unknown")). "
                    + "\(item.key) keeps its approval and its place in the queue; Brahma tries again every minute and the queue moves "
                    + "as soon as the fault clears.",
                now: now, reason: Store.mergeHoldAlertReason(company.id))
        } catch {
            log("could not raise the merge hold alert: \(error)")
        }
    }

    func companyMergeRan(companyId: String) { mergeFaults[companyId] = nil }
    func companyMergeRan(streak: String) { mergeFaults[streak] = nil }

    /// The company's fault, not the item's: the engine's own merge steps (`MergeInfrastructureError`), or git refused to run
    /// at all because a repository's config is not one the engine runs git with (nothing ran; its own alert).
    nonisolated static func isCompanyMergeFault(_ error: any Error) -> Bool {
        if error is MergeInfrastructureError { return true }
        if let git = error as? GitError, git.isRepositoryRefusal { return true }
        return false
    }

    nonisolated static func companyFault(_ error: any Error) -> MergeInfrastructureError {
        error as? MergeInfrastructureError ?? MergeInfrastructureError(underlying: error)
    }
}
