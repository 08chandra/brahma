import Foundation
import GRDB

extension Orchestrator {
    func timerTaskDone(_ id: String) { timerTasks[id] = nil }

    /// The "timers" tick step. Every due timer is claimed first (a conditional UPDATE, so a fire happens once), with
    /// its next fire computed from `now`, which folds any number of missed fires into this one. Jobs then run
    /// detached and never overlap themselves; a timer whose previous run is still going is left due.
    func timersTick(now: Date, companies: [Company]) throws {
        let ids = Set(companies.map(\.id))
        if ensuredTimerCompanies != ids {
            try SystemTimers.ensure(store: store, now: now, digestTime: store.ownerPrefs().digestHourMinute)
            ensuredTimerCompanies = ids
        }
        let due = try store.dueTimers(now: now)
        guard !due.isEmpty else { return }
        let zone = store.ownerTimeZone()
        for timer in due where timerTasks[timer.id] == nil {
            let next = timer.schedule.next(after: now, timeZone: zone)
            attempt {
                switch timer.action {
                case .job(let name): try fireJob(timer, name: name, next: next, now: now)
                case .turn(let agentId, let prompt): try fireTurn(timer, agentId: agentId, prompt: prompt, next: next, now: now)
                }
            }
        }
    }

    private func fireJob(_ timer: EngineTimer, name: String, next: Date?, now: Date) throws {
        guard let job = timerJobs.job(name) else {
            try store.disableTimer(timer, reason: "unknown job \(name)", now: now)
            return
        }
        guard try store.claimFire(timerId: timer.id, expectedNext: timer.nextFireAt, now: now, next: next) else { return }
        let context = TimerContext(store: store, paths: paths, timer: timer, now: now)
        timerTasks[timer.id] = Task.detached { [self] in
            do {
                try await job(context)
            } catch {
                if !Task.isCancelled {
                    attempt { try store.logTimerError(timer, text: "timer \(timer.name) failed: \(error)", now: clock()) }
                }
            }
            await timerTaskDone(timer.id)
        }
    }

    /// Claim and DM in one transaction. A missing, other-company or killed agent disables the timer.
    private func fireTurn(_ timer: EngineTimer, agentId: String, prompt: String, next: Date?, now: Date) throws {
        let router = MessageRouter(store: store)
        try store.writer.write { db in
            guard let agent = try Agent.fetchOne(db, key: agentId), agent.companyId == timer.companyId, agent.state != .killed else {
                _ = try Store.disableTimer(db: db, timer: timer, reason: "its agent is gone", now: now)
                return
            }
            guard try Store.claimFire(db: db, timerId: timer.id, expectedNext: timer.nextFireAt, now: now, next: next) else { return }
            do {
                try db.inSavepoint {
                    try router.sendDM(db: db, companyId: agent.companyId, from: .system, to: agent.name, text: prompt, now: now)
                    return .commit
                }
            } catch {
                try Store.logTimerError(db: db, timer: timer, text: "timer \(timer.name) could not message @\(agent.name): \(error)", now: now)
            }
        }
    }
}
