import Foundation

extension Orchestrator {
    /// Times one merge-check run is put back in the queue because its export failed for Brahma's own reasons before it is
    /// recorded inconclusive (and so retried, then returned, through the usual inconclusive path).
    static let maxMergeCheckDeferrals = 10

    /// Start-up: runs the previous process left running are queued again, and leftover check checkouts are removed (git,
    /// off the cooperative pool: `Blocking`).
    func recoverChecks(now: Date) async throws {
        try store.recoverVerifications(now: now)
        for company in try store.companies() {
            let ws = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
            guard FileManager.default.fileExists(atPath: ws.appending(path: ".git").path) else { continue }
            let git = store.gitWorkspace(root: ws, companyId: company.id)
            await blocking.run { git.removeRunWorktrees() }
        }
    }

    /// Once per tick, before turns are admitted: starts queued checks, at most `maxConcurrentChecks` at a time and only
    /// into slots the safety cap has free (turns and checks share it). Nothing starts under a hold or critical memory pressure.
    func startChecks(now: Date, config: SchedulerConfig, held: Bool, pressure: MemoryPressure, companies: [Company]) {
        guard !held, pressure != .critical else { return }
        for _ in 0..<5 {
            let room = config.maxConcurrentChecks - checkTasks.count
            let slots = Scheduler.freeSlots(config: config, running: runningCount(), otherChildren: otherChildren, safetyOnly: previewChildren,
                                            pressure: pressure, held: held)
            let want = min(room, slots)
            guard want > 0, let runs = try? store.queuedVerifications(limit: want), !runs.isEmpty else { return }
            for run in runs {
                // A run that turned stale while queued is recorded as superseded and takes no slot.
                _ = launchCheck(run, now: now)
            }
        }
    }

    private func launchCheck(_ run: VerificationRun, now: Date) -> Bool {
        let output = paths.companyDir(run.companyId).appending(path: "check-output/\(run.id).log")
        guard let begun = try? store.beginVerification(runId: run.id, outputPath: output.path, now: now) else { return false }
        checkTasks[run.id] = Task.detached { [self] in
            await asEngine { await performCheck(run: begun) }
            await checkEnded(runId: begun.id)
        }
        return true
    }

    func checkEnded(runId: String) { checkTasks[runId] = nil }

    /// One more deferral of this merge-check run for the company's fault; how many it has had.
    func noteMergeCheckDeferral(runId: String) -> Int {
        let n = (mergeCheckDeferrals[runId] ?? 0) + 1
        mergeCheckDeferrals[runId] = n
        return n
    }

    func mergeCheckDeferralsEnded(runId: String) { mergeCheckDeferrals[runId] = nil }

    /// A merge check's export worked: the company's export streak is over, and its hold alert resolves unless its landings
    /// are still failing for the company's own reasons (A1).
    func mergeCheckExported(company: Company) {
        companyMergeRan(streak: "check:\(company.id)")
        guard (mergeFaults[company.id] ?? 0) < Store.maxMergeFailures else { return }
        do { try store.resolveMergeHoldAlert(companyId: company.id, now: clock()) } catch {
            log("could not resolve the merge hold alert of \(company.name): \(error)")
        }
    }

    /// One run, off the actor: refuse it if its saved scripts were changed, check out the exact commit in a clean detached
    /// worktree, run the command there with a scoped environment, remove the checkout, record the outcome. A run cut short
    /// by shutdown is left `running` and queued again at the next start.
    nonisolated func performCheck(run: VerificationRun) async {
        guard let company = try? store.company(id: run.companyId) else { return }
        let ws = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        let git = store.gitWorkspace(root: ws, companyId: company.id)
        func couldNotRun(_ why: String) {
            do { try store.finishVerification(runId: run.id, outcome: CheckOutcome(exitCode: nil, timedOut: false, tail: why), now: clock()) }
            catch { log("could not record the check of run \(run.id): \(error)") }
        }
        do {
            if let file = try store.snapshotTamper(itemId: run.itemId, revision: run.checkRevision) {
                try store.refuseVerification(runId: run.id, file: file, now: clock())
                return
            }
        } catch {
            couldNotRun("could not verify the check snapshot: \(error)")
            return
        }
        let dir: URL
        do {
            // A merge check runs on a `.git`-free export made by the engine's own repository, under the data home
            // (`<home>/run/exports/<runId>`); a submission's in a detached worktree there too (`<home>/run/checkouts/<runId>`).
            let (store, now) = (self.store, clock())
            let (runId, commit, purpose) = (run.id, run.commit, run.purpose)
            dir = try await blocking.tryRun {
                purpose == .merge
                    ? try git.addEngineExport(runId: runId, commit: commit, tamper: { store.reportMergeTamper(company: company, removed: $0, now: now) })
                    : try git.addRunWorktree(runId: runId, commit: commit)
            }
            try store.setVerificationDirectory(runId: run.id, path: dir.path)
            store.noteWorktreeSetupSuccess(companyId: company.id, now: clock())
        } catch let refused as UnexportableTree where run.purpose == .merge {
            // The item's own tree cannot be written out (A1): its fault, so it goes back to its holder with the reason.
            await blocking.run { git.removeRunWorktree(runId: run.id) }
            await mergeCheckDeferralsEnded(runId: run.id)
            log("the merge check of \(run.commit.prefix(7)) could not be exported: \(refused.reason)")
            do { try store.returnUnexportable(runId: run.id, reason: refused.reason, now: clock()) } catch {
                log("could not record the merge check of run \(run.id): \(error)")
            }
            return
        } catch let error where run.purpose == .merge && Orchestrator.isCompanyMergeFault(error) {
            // The engine's own machinery, not the item: held and retried, never charged to the item (`companyMergeFault`).
            // A run deferred `maxMergeCheckDeferrals` times is recorded inconclusive (retried, then returned as uncheckable).
            await blocking.run { git.removeRunWorktree(runId: run.id) }
            log("could not export \(run.commit.prefix(7)) for its merge check (\(company.name)'s merge step failed): \(error)")
            let deferrals = await noteMergeCheckDeferral(runId: run.id)
            if deferrals > Self.maxMergeCheckDeferrals {
                await mergeCheckDeferralsEnded(runId: run.id)
                couldNotRun("its export for the merge check failed \(deferrals) times for Brahma's own reasons: \(error)")
            } else {
                do { try store.deferVerification(runId: run.id, delay: Self.mergeRetry) } catch {
                    log("could not put the merge check of run \(run.id) back in the queue: \(error)")
                }
            }
            if let item = try? await store.writer.read({ try WorkItem.fetchOne($0, key: run.itemId) }) {
                let version = await blocking.run { GitWorkspace.installedGitVersion }
                await companyMergeFault(company: company, item: item, error: Orchestrator.companyFault(error), streak: "check:\(company.id)",
                                        gitVersion: version)
            }
            return
        } catch {
            // The engine could not set up the checkout: its own fault, loud (log and owner alert), and the run is recorded
            // inconclusive (retried, never counted against the item), never passed or failed.
            await blocking.run { git.removeRunWorktree(runId: run.id) }
            if run.purpose == .merge { await mergeCheckDeferralsEnded(runId: run.id) }
            store.noteWorktreeSetupFailure(companyId: company.id, what: "the checkout for the check of \(run.commit.prefix(7))",
                                           error: error, now: clock())
            couldNotRun("could not check out the submitted commit: \(error)")
            return
        }
        if run.purpose == .merge {
            await mergeCheckDeferralsEnded(runId: run.id)
            await mergeCheckExported(company: company)
        }
        let holder = (try? store.lease(itemId: run.itemId))?.agentId ?? run.requestedBy
        let environment = ChildEnvironment.make(base: checkBaseEnvironment, extra: holder.map { ["BRAHMA_AGENT_ID": $0] } ?? [:],
                                                purpose: .check)
        let output = run.outputPath.map { URL(fileURLWithPath: $0) }
            ?? paths.companyDir(run.companyId).appending(path: "check-output/\(run.id).log")
        let outcome = await checkRunner.run(command: run.command, workingDirectory: dir,
                                            timeout: TimeInterval(run.timeoutSeconds), outputURL: output, environment: environment)
        await blocking.run { git.removeRunWorktree(runId: run.id) }
        if Task.isCancelled { return }
        // Risk-tiered review: a clean submit pass is measured (engine-recorded commits only) before it is recorded.
        let passed = outcome.exitCode == 0 && !outcome.timedOut
        let assessing = self.store
        let autoMerge = passed && run.purpose == .submit ? await blocking.run { assessing.assessAutoMerge(run: run, git: git) } : nil
        do { try store.finishVerification(runId: run.id, outcome: outcome, autoMerge: autoMerge, now: clock()) }
        catch { log("could not record the check of run \(run.id): \(error)") }
    }
}
