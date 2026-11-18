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

    // MARK: 3a's one-item merge step: unreachable since Plan 4a Task 1b
    //
    // The merge queue (`MergeQueue`, Plan 4a) replaced the step below. Nothing calls `startThe3aMergeStep` any more; it and
    // `performMerge` stay in the tree, untouched, until Task 3 removes them with the main guard that still shares their
    // helpers (`companyMergeFault`, `mergeStopped`, `holdMerges`).

    /// 3a's step: the merge of each company's oldest approved item, one per company. Unreachable (see above).
    func startThe3aMergeStep(now: Date, config: SchedulerConfig, held: Bool, pressure: MemoryPressure, companies: [Company]) {
        guard !held, pressure != .critical else { return }
        mergeBackoff = mergeBackoff.filter { $0.value > now }
        for company in companies where company.status == .running && mergeTasks[company.id] == nil && mergeBackoff[company.id] == nil {
            let slots = Scheduler.freeSlots(config: config, running: runningCount(), otherChildren: otherChildren, safetyOnly: previewChildren,
                                            pressure: pressure, held: held)
            guard slots > 0 else { return }
            guard let item = try? store.nextPendingMerge(companyId: company.id) else { continue }
            do { try store.beginMerging(itemId: item.id) } catch {
                log("could not start the merge of \(item.key): \(error)")
                continue
            }
            mergeTasks[company.id] = Task.detached { [self] in
                await asEngine { await performMerge(company: company, item: item) }
                await mergeEnded(companyId: company.id)
            }
        }
    }

    func mergeEnded(companyId: String) { mergeTasks[companyId] = nil }

    /// Where a merge's git children are recorded for the owner's stop (`ChildGroups`, kind `merge`).
    nonisolated var mergeChildGroups: ChildGroups { ChildGroups(dir: ChildGroups.directory(runDir: paths.runDir), kind: "merge") }

    /// A merge the owner's stop cut short: one engine event in the company's feed; the item stays `pending` (requeued by
    /// `endMerging`), with no backoff, no failure count and no company fault.
    nonisolated func mergeStopped(company: Company, item: WorkItem, error: any Error) {
        log("the merge of \(item.key) was stopped by the owner before main moved (\(error))")
        do {
            try store.appendEvent(ActivityEvent(companyId: company.id, agentId: nil, turnId: nil, kind: .error,
                                                text: "the merge of \(item.key) was stopped by the owner before main moved; it keeps its approval and merges after the resume",
                                                createdAt: clock()))
        } catch { log("could not record the stopped merge of \(item.key): \(error)") }
    }

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

    /// The git work for one approved item, then its recording (`finishMerge`), all off the actor. A merge that could not run
    /// (a hold) is not tried again for `mergeRetry` seconds; its item stays `pending`. A merge that failed for the company's
    /// own reasons (main's lock, moving main, the merge repository, a quarantine: `MergeInfrastructureError`) is held the same
    /// way and never counts against the item (`companyMergeFault`). Any other failure counts against the item; after
    /// `Store.maxMergeFailures` the item goes back to its holder and the company's queue moves on.
    nonisolated func performMerge(company: Company, item: WorkItem) async {
        defer {
            do { try store.endMerging(itemId: item.id) } catch { log("could not end the merge of \(item.key): \(error)") }
        }
        do {
            let (store, now, groups) = (self.store, clock(), mergeChildGroups)
            if Task.isCancelled, (try? store.engineStopped()) != nil { throw StoppedByOwner() }
            guard let result = try await blocking.tryRun({ try store.performMerge(item: item, company: company, now: now, childGroups: groups) }) else {
                await holdMerges(companyId: company.id, until: clock().addingTimeInterval(Self.mergeRetry))
                return
            }
            await companyMergeRan(companyId: company.id)
            // Recording a landing also removes the item's worktree and branch and looks at the other branches (git).
            let finished = clock()
            try await blocking.tryRun { try store.finishMerge(itemId: item.id, result: result, now: finished) }
        } catch let error where error is StoppedByOwner || (try? store.engineStopped()) != nil {
            // The owner's stop (S15): seen before a ref moved, or its signal killed the merge's git. Nothing moved; the item
            // keeps its approval and its place and merges after the resume, never charged to it or to the company.
            mergeStopped(company: company, item: item, error: error)
        } catch let error where Self.isCompanyMergeFault(error) {
            log("could not merge \(item.key) (\(company.name)'s merge step failed): \(error)")
            let version = await blocking.run { GitWorkspace.installedGitVersion }
            await companyMergeFault(company: company, item: item, error: Self.companyFault(error), gitVersion: version)
        } catch {
            log("could not merge \(item.key): \(error)")
            let returned = (try? store.noteMergeFailure(itemId: item.id, error: "\(error)", now: clock())) ?? false
            if !returned { await holdMerges(companyId: company.id, until: clock().addingTimeInterval(Self.mergeRetry)) }
        }
    }
}
