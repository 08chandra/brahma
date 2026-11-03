import Foundation

extension Orchestrator {
    /// First step of every tick (Task 7c). While the owner's stop holds: every running turn is cancelled (its process group
    /// gets SIGTERM, then SIGKILL after `ClaudeProcessRunner.killGrace`) and recorded `interrupted`, as at quit; every running
    /// check is cancelled and recorded `inconclusive` (`performCheck`); the observers run once per stop. Admission is held by
    /// the caller (`held`), and active time stands still (`accrueActiveTime`).
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

    /// A check cut short: by the owner's stop it is recorded `inconclusive` (retried after the resume, never counted against the
    /// item's agents); by shutdown it is left `running` and queued again at the next start.
    nonisolated func checkCancelled(run: VerificationRun) {
        guard (try? store.engineStopped()) != nil else { return }
        do {
            try store.finishVerification(runId: run.id, outcome: CheckOutcome(exitCode: nil, timedOut: false, tail: "stopped by the owner"),
                                         now: clock())
        } catch { log("could not record the stopped check of run \(run.id): \(error)") }
    }
}
