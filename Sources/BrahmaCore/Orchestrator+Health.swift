import Foundation

/// What the health rules have seen so far. Lives on the orchestrator actor; background checks write their result
/// here and the next tick reads it.
struct HealthState {
    var networkFailures: [Date] = []
    var accountStreak = 0
    var lastCliCheck: Date?
    var lastDiskCheck: Date?
    var versionReady = false
    var version: String?
    var doctorReport: DoctorReport?
    var diskReady = false
    var minFreeBytes: Int64?
    var online: Bool?
}

extension Orchestrator {
    // MARK: Called by finished turns

    /// A turn ended. Counts infrastructure failures for the network and account rules and starts the agent's
    /// fixed cooldown; any other outcome breaks an account streak. `keepCooldown`: the turn set the fixed delay itself with no
    /// infrastructure class (a missing worktree, a turn that could not be recorded), so it stands.
    func noteOutcome(agentId: String, infra: InfraClass, interrupted: Bool, keepCooldown: Bool = false, now: Date) {
        switch infra {
        case .network:
            health.networkFailures.append(now)
            health.accountStreak = 0
        case .account:
            health.accountStreak += 1
        case .none:
            if !interrupted { health.accountStreak = 0 }
        }
        // The cooldown itself is set before the turn is recorded (`setInfraCooldown`).
        if infra == .none, !keepCooldown { infraCooldown[agentId] = nil }
    }

    /// Counts the agent's turns in a row that were stopped because they could not be recorded (any other turn end resets it);
    /// returns the count.
    func noteUnrecordedTurn(agentId: String, _ unrecorded: Bool) -> Int {
        guard unrecorded else { unrecordedTurns[agentId] = nil; return 0 }
        unrecordedTurns[agentId, default: 0] += 1
        return unrecordedTurns[agentId] ?? 0
    }

    // MARK: Background results

    func setInfraCooldown(agentId: String, until: Date) { infraCooldown[agentId] = until }
    func setVersion(_ v: String?) { health.version = v; health.versionReady = true }
    func setDoctorReport(_ r: DoctorReport) { health.doctorReport = r }
    func setDisk(_ free: Int64?) { health.minFreeBytes = free; health.diskReady = true }
    func setOnline(_ o: Bool) { health.online = o }
    private func healthTaskDone(_ key: String) { healthTasks[key] = nil }

    private func spawn(_ key: String, _ body: @escaping @Sendable () async -> Void) {
        guard healthTasks[key] == nil else { return }
        healthTasks[key] = Task.detached { [self] in
            await asEngine { await body() }
            await healthTaskDone(key)
        }
    }

    // MARK: The rules, once per tick

    /// Reads finished background work, applies the hold rules and starts due checks. Never waits on anything slow.
    func healthTick(now: Date) throws {
        // 1. Results of earlier background checks.
        if let report = health.doctorReport {
            health.doctorReport = nil
            try store.saveProbe(report)
            if report.ok {
                try store.resolveDoctorAlerts(now: now)
                try store.clearHold(now: now, onlyIf: .cli)
            } else {
                let first = report.items.first { $0.status == .fail }
                try EngineAlerts.raise(store: store, text: "Claude Code check failed: \(first?.detail ?? "unknown problem")", now: now)
            }
        }
        if health.versionReady {
            health.versionReady = false
            if let v = health.version, let saved = try store.latestProbe(), let old = saved.cliVersion, old != v,
               try store.engineHold()?.reason != .account {
                try store.setHold(reason: .cli, detail: "Claude Code changed from \(old) to \(v); re-checking", now: now)
                startDoctor()
            }
        }
        if health.diskReady {
            health.diskReady = false
            if let free = health.minFreeBytes {
                if free < EngineHealth.diskHoldBytes {
                    let gb = String(format: "%.1f", Double(free) / 1_000_000_000)
                    if try store.setHold(reason: .disk, detail: "\(gb) GB free", now: now) {
                        try EngineAlerts.raise(store: store, text: "Disk space is low (\(gb) GB free). Free space; Brahma resumes at 6 GB.", now: now, reason: HoldReason.disk.rawValue)
                    }
                } else if free >= EngineHealth.diskReleaseBytes {
                    try store.clearHold(now: now, onlyIf: .disk)
                }
            }
        }
        if let online = health.online {
            health.online = nil
            if online {
                try store.clearHold(now: now, onlyIf: .network)
                health.networkFailures = []
            }
        }

        // 2. Failure rules.
        health.networkFailures.removeAll { now.timeIntervalSince($0) > EngineHealth.networkWindow }
        if health.networkFailures.count >= EngineHealth.networkFailuresToHold {
            try store.setHold(reason: .network, detail: "\(health.networkFailures.count) turns couldn't reach the API in 5 minutes", now: now)
        }
        if health.accountStreak >= EngineHealth.accountFailuresToHold {
            health.accountStreak = 0
            if try store.setHold(reason: .account, detail: "Claude Code is logged out or the plan changed", now: now) {
                try EngineAlerts.raise(store: store, text: "Claude Code is logged out or the plan changed. Log in with `claude`, then run `brahma doctor` (or press Retry in the app).", now: now, reason: HoldReason.account.rawValue)
            }
        }

        // 3. Background checks that are due.
        let hold = try store.engineHold()
        if hold?.reason == .network, let next = hold?.nextProbeAt, now >= next, healthTasks["probe"] == nil {
            try store.scheduleNextProbe(at: now.addingTimeInterval(EngineHealth.probeInterval))
            let probe = connectivity
            spawn("probe") { [self] in await setOnline(await probe.online()) }
        }
        if health.lastCliCheck == nil { health.lastCliCheck = now }
        if let last = health.lastCliCheck, now.timeIntervalSince(last) >= EngineHealth.cliCheckInterval,
           healthTasks["cli"] == nil, healthTasks["doctor"] == nil {
            health.lastCliCheck = now
            let (path, exec) = (claudePath, self.exec)
            spawn("cli") { [self] in await setVersion(await Doctor.cliVersion(claudePath: path, exec: exec)) }
        }
        if health.lastDiskCheck.map({ now.timeIntervalSince($0) >= EngineHealth.diskCheckInterval }) ?? true, healthTasks["disk"] == nil {
            health.lastDiskCheck = now
            let (disk, urls) = (self.disk, [paths.home, paths.workspaces])
            spawn("disk") { [self] in await setDisk(urls.compactMap { disk.freeBytes(at: $0) }.min()) }
        }
    }

    private func startDoctor() {
        let (path, exec, runner, now, helper) = (claudePath, self.exec, self.runner, clock(), mcpExecutable)
        spawn("doctor") { [self] in
            await setDoctorReport(await Doctor.run(claudePath: path, runner: runner, exec: exec, now: now, hookExecutable: helper))
        }
    }
}
