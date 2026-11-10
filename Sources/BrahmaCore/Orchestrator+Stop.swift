import Foundation

extension Orchestrator {
    /// First step of every tick (Task 7c). While the owner's stop holds: every running turn is cancelled (its process group
    /// gets SIGTERM, then SIGKILL after `ClaudeProcessRunner.killGrace`) and recorded `interrupted`, as at quit; every running
    /// check is cancelled (its group is killed) and put back in the queue as it was, no attempt counted (`checkCancelled`); an
    /// Ultra turn's process group goes with it, its workflow agents included, and the run is charged its full cap (F6, Task
    /// 14u: `UltraAccounting.charge`, released through its reservation when the turn is recorded);
    /// every merge and every git task is cancelled, and each re-reads the stop before it changes anything (a merge right
    /// before each ref it moves: `Store.performMerge`); the observers run once per stop. Admission is held by the caller
    /// (`held`; the restore-marker step and lease git wait too), and active time stands still (`accrueActiveTime`).
    func enforceStop(_ stop: EngineStopRow?, now: Date) {
        guard let stop else {
            if engineStoppedNow { log("resumed after the owner's stop") }
            engineStoppedNow = false
            stopObserved = nil
            return
        }
        if !engineStoppedNow { log("stopped by the owner (\(stop.by)) since \(stop.since.ISO8601Format())") }
        engineStoppedNow = true
        for t in tasks.values { t.cancel() }
        for t in checkTasks.values { t.cancel() }
        for t in mergeTasks.values { t.cancel() }
        // Every git task changes state (worktrees and their auto-commits, a dispatch's branch, a restore's re-adoption).
        for t in gitTasks.values { t.cancel() }
        // A sandbox canary runs `claude` (final review M1); none starts again until the resume (`scheduleCanary`).
        cancelCanaries()
        guard stopObserved != stop.since, stopObserverTask == nil else { return }
        stopObserved = stop.since
        let observers = stopObservers
        guard !observers.isEmpty else { return }
        let reason = "stopped by the owner" + (stop.note.map { ": \($0)" } ?? "")
        stopObserverTask = Task.detached { [self] in
            await withTaskGroup(of: Void.self) { group in
                for o in observers { group.addTask { await o.stopAll(reason: reason) } }
            }
            await stopObserversDone()
        }
    }

    func stopObserversDone() { stopObserverTask = nil }

    /// A running turn's supervision: returns once the owner's stop is seen (read every `EmergencyStop.pollInterval`), or when
    /// cancelled (the turn ended first).
    nonisolated func waitForStop() async {
        while !Task.isCancelled {
            do { try await stopPollSleep(EmergencyStop.pollInterval) } catch { return }
            if Task.isCancelled { return }
            if (try? store.engineStopped()) != nil { return }
        }
    }

    /// A check cut short: by the owner's stop the same run goes back to the queue as it was (fix round 1, I1): not an
    /// attempt, no inconclusive count, no delay, so it runs right after the resume and a merge check keeps its pending merge;
    /// by shutdown it is left `running` and queued again at the next start.
    nonisolated func checkCancelled(run: VerificationRun) {
        guard stoppedNow else { return }
        do { try store.requeueStoppedVerification(runId: run.id) }
        catch { log("could not put the stopped check of run \(run.id) back in the queue: \(error)") }
    }

    /// Where a check's process group is recorded for the owner's stop (`ChildGroups`, kind `check`).
    nonisolated var checkChildGroups: ChildGroups { ChildGroups(dir: ChildGroups.directory(runDir: paths.runDir), kind: "check") }

    /// Whether the owner's stop holds right now (a database error reads as not stopped: nothing is held by mistake).
    nonisolated var stoppedNow: Bool { (try? store.engineStopped()) != nil }
}
