import Foundation

extension Orchestrator {
    /// Start-up: runs the previous process left running are queued again, and leftover check checkouts are removed.
    func recoverChecks(now: Date) throws {
        try store.recoverVerifications(now: now)
        for company in try store.companies() {
            let ws = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
            guard FileManager.default.fileExists(atPath: ws.appending(path: ".git").path) else { continue }
            store.gitWorkspace(root: ws, companyId: company.id).removeRunWorktrees()
        }
    }

    /// Once per tick, before turns are admitted: starts queued checks, at most `maxConcurrentChecks` at a time and only
    /// into slots the safety cap has free (turns and checks share it). Nothing starts under a hold or critical memory pressure.
    func startChecks(now: Date, config: SchedulerConfig, held: Bool, pressure: MemoryPressure, companies: [Company]) {
        guard !held, pressure != .critical else { return }
        for _ in 0..<5 {
            let room = config.maxConcurrentChecks - checkTasks.count
            let slots = Scheduler.freeSlots(config: config, running: runningCount(), otherChildren: checkTasks.count,
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
            await performCheck(run: begun)
            await checkEnded(runId: begun.id)
        }
        return true
    }

    func checkEnded(runId: String) { checkTasks[runId] = nil }

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
            dir = try git.addRunWorktree(runId: run.id, commit: run.commit)
            try store.setVerificationDirectory(runId: run.id, path: dir.path)
        } catch {
            git.removeRunWorktree(runId: run.id)
            couldNotRun("could not check out the submitted commit: \(error)")
            return
        }
        let holder = (try? store.lease(itemId: run.itemId))?.agentId ?? run.requestedBy
        let environment = ChildEnvironment.make(base: checkBaseEnvironment, extra: holder.map { ["BRAHMA_AGENT_ID": $0] } ?? [:],
                                                purpose: .check)
        let output = run.outputPath.map { URL(fileURLWithPath: $0) }
            ?? paths.companyDir(run.companyId).appending(path: "check-output/\(run.id).log")
        let outcome = await checkRunner.run(command: run.command, workingDirectory: dir,
                                            timeout: TimeInterval(run.timeoutSeconds), outputURL: output, environment: environment)
        git.removeRunWorktree(runId: run.id)
        if Task.isCancelled { return }
        do { try store.finishVerification(runId: run.id, outcome: outcome, now: clock()) }
        catch { log("could not record the check of run \(run.id): \(error)") }
    }
}
