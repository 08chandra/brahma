import Foundation
import GRDB

public enum OrchestratorError: Error, Equatable {
    case idleTimeout(running: Int)
}

/// Global scheduler: one per machine, across all companies. Each tick unblocks, applies the usage gate and
/// turn budget, then starts turns for the agents `Scheduler.select` picks; each turn runs as a child task.
public actor Orchestrator {
    let store: Store
    let runner: any TurnRunning
    let paths: BrahmaPaths
    let config: SchedulerConfig
    let mcpExecutable: String
    let profile: PermissionProfile
    let clock: @Sendable () -> Date
    let memory: any MemoryPressureSource
    let connectivity: any ConnectivityProbe
    let disk: any DiskSpace
    let exec: Doctor.Exec
    let claudePath: String

    /// In-memory: turns this orchestrator has in flight, per company. The DB `running` state is the durable record.
    private var runningByCompany: [String: Int] = [:]
    /// Agent id → its turn task.
    private var tasks: [String: Task<Void, Never>] = [:]
    /// Health work that must never block a tick (doctor re-probe, `claude --version`, HTTPS probe, disk checks).
    var healthTasks: [String: Task<Void, Never>] = [:]
    var health = HealthState()
    private var lastPressure: MemoryPressure = .normal
    /// Agents whose last turn failed for infrastructure reasons: not eligible before this time (fixed 15 s).
    var infraCooldown: [String: Date] = [:]

    static let usageRetry: TimeInterval = 15 * 60
    static let hour: TimeInterval = 3600

    public init(store: Store, runner: any TurnRunning, paths: BrahmaPaths, config: SchedulerConfig = .init(),
                mcpExecutable: String, profile: PermissionProfile = .workspace,
                clock: @escaping @Sendable () -> Date = { .now },
                memory: any MemoryPressureSource = DispatchMemoryPressureSource(),
                connectivity: any ConnectivityProbe = HTTPSProbe(), disk: any DiskSpace = SystemDiskSpace(),
                exec: @escaping Doctor.Exec = Doctor.defaultExec, claudePath: String = "claude") {
        self.store = store; self.runner = runner; self.paths = paths; self.config = config
        self.mcpExecutable = mcpExecutable; self.profile = profile; self.clock = clock
        self.memory = memory; self.connectivity = connectivity; self.disk = disk; self.exec = exec
        self.claudePath = claudePath
    }

    /// Crash recovery: turns left in progress by a previous run are interrupted; their agents return to ready.
    public func start() throws {
        _ = try store.recoverInterruptedTurns(now: clock())
    }

    public func runningCount() -> Int { runningByCompany.values.reduce(0, +) }

    public func waitUntilIdle(timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while !tasks.isEmpty || !healthTasks.isEmpty {
            guard ContinuousClock.now < deadline else { throw OrchestratorError.idleTimeout(running: runningCount()) }
            try await Task.sleep(for: .milliseconds(5))
        }
    }

    /// Ticks until cancelled, then cancels in-flight turns and waits for them to record their outcome.
    public func runForever(interval: Duration = .seconds(1)) async {
        while !Task.isCancelled {
            await tick()
            try? await Task.sleep(for: interval)
        }
        let inFlight = Array(tasks.values) + Array(healthTasks.values)
        for t in inFlight { t.cancel() }
        for t in inFlight { await t.value }
        await runner.waitForChildren()
    }

    /// Synchronous on the actor (no suspension points), so ticks never interleave with each other.
    public func tick() async {
        do {
            try schedule(now: clock())
        } catch {
            log("tick failed: \(error)")
        }
    }

    private func schedule(now: Date) throws {
        // Active time first, so everything below sees the same clock; then health, which may start or end a hold.
        try store.accrueActiveTime(now: now)
        try healthTick(now: now)
        let held = try store.engineHold() != nil
        let pressure = memory.current
        logPressure(pressure, now: now)
        // The owner's plan tier and weekly share apply from the next tick after they are changed.
        var cfg = config
        cfg.planTier = store.planTier()
        cfg.ownerReserve = 1 - store.weeklyShare()
        let companies = try store.companies()

        // 1. Timed blockers that have expired.
        for a in try store.agents(states: [.blocked]) {
            let until: Date
            switch a.blocker {
            case .usageLimit(let u)?, .turnBudget(let u)?, .retry(let u, _)?: until = u
            default: continue
            }
            guard until <= now else { continue }
            attempt { try store.transition(agentId: a.id, to: .ready, now: now) { $0.state == .blocked && $0.blocker == a.blocker } }
        }

        // 2. How many live agents each agent is holding up.
        let all = try store.agents()
        var blocking: [String: Int] = [:]
        for a in all where a.state != .killed {
            if case .agent(let id)? = a.blocker { blocking[id, default: 0] += 1 }
        }

        // 3. Usage gate per company: the five-hour limits close a company to everyone; the weekly pace closes it
        //    to everyone except agents that others are waiting on (the critical path).
        let info = try store.latestRateLimit()
        var decisions: [String: UsageDecision] = [:]
        var paceClosed = Set<String>()
        for c in companies {
            let reserve = cfg.reserve(for: c)
            let parts = UsageGate.evaluateParts(info, mode: c.usageMode, now: now, reserve: reserve)
            let exempt: Bool
            let gateUntil: Date
            let why: String
            switch (parts.fiveHour, parts.pace) {
            case (.closed, _):
                guard case .closed(let u) = parts.combined else { continue }
                decisions[c.id] = parts.combined
                exempt = false; gateUntil = u
                why = "usage gate closed (\(c.usageMode.rawValue) mode)"
            case (_, .closed(let u)):
                paceClosed.insert(c.id)
                exempt = true; gateUntil = u
                let text = UsageGate.pace(info, reserve: reserve, now: now)?.text ?? "ahead"
                why = "weekly pace closed (\(text), \(Int((reserve * 100).rounded()))% reserved)"
            default:
                continue
            }
            let until = Self.usageUntil(gateUntil, now: now)
            var stopped = 0
            for a in try store.agents(companyId: c.id, states: [.ready]) where !(exempt && (blocking[a.id] ?? 0) > 0) {
                attempt {
                    if try store.transition(agentId: a.id, to: .blocked, blocker: .usageLimit(until: until), now: now,
                                            if: { $0.state == .ready }) != nil { stopped += 1 }
                }
            }
            if stopped > 0 {
                attempt {
                    try store.appendEvent(ActivityEvent(
                        companyId: c.id, agentId: nil, turnId: nil, kind: .usage,
                        text: "\(why) until \(until.ISO8601Format()); \(stopped) agent(s) waiting",
                        createdAt: now))
                }
            }
        }

        // 4. Per-agent turn budget over the last hour (infrastructure failures don't count).
        let hourAgo = now.addingTimeInterval(-Self.hour)
        for a in try store.agents(states: [.ready]) where try store.turnCount(agentId: a.id, since: hourAgo) >= cfg.turnBudgetPerHour {
            let oldest = try store.oldestTurnStart(agentId: a.id, since: hourAgo) ?? now
            attempt {
                try store.transition(agentId: a.id, to: .blocked, blocker: .turnBudget(until: oldest.addingTimeInterval(Self.hour)),
                                     now: now, if: { $0.state == .ready })
            }
        }

        // 5. Select and launch.
        infraCooldown = infraCooldown.filter { $0.value > now }
        let byId = Dictionary(uniqueKeysWithValues: companies.map { ($0.id, $0) })
        let ready = try store.agents(states: [.ready])
        let candidates = ready.compactMap { a -> Candidate? in
            guard !a.paused, tasks[a.id] == nil, infraCooldown[a.id] == nil, let c = byId[a.companyId] else { return nil }
            return Candidate(agent: a, company: c, blockingCount: blocking[a.id] ?? 0)
        }
        let selected = Scheduler.select(candidates: candidates, runningByCompany: runningByCompany, config: cfg,
                                        usage: { decisions[$0.id] ?? .open }, otherChildren: 0, pressure: pressure,
                                        held: held, paceClosed: paceClosed)
        for agent in selected { launch(agent, now: now) }
    }

    private func logPressure(_ level: MemoryPressure, now: Date) {
        guard level != lastPressure else { return }
        lastPressure = level
        let effect = level == .critical ? "paused" : level == .warning ? "limited" : "resumed"
        for c in (try? store.companies()) ?? [] {
            attempt {
                try store.appendEvent(ActivityEvent(companyId: c.id, agentId: nil, turnId: nil, kind: .usage,
                                                    text: "memory pressure \(level.rawValue): new turns \(effect)", createdAt: now))
            }
        }
    }

    private func launch(_ agent: Agent, now: Date) {
        let started: (Agent, Turn)
        do {
            guard let s = try store.beginTurn(agentId: agent.id, now: now) else { return }
            started = s
        } catch {
            log("could not start turn for \(agent.id): \(error)")
            return
        }
        let (running, turn) = started
        runningByCompany[running.companyId, default: 0] += 1
        // The task inherits actor isolation, so it cannot run (or end) before this method returns.
        tasks[running.id] = Task {
            await self.performTurn(agent: running, turn: turn)
            self.turnEnded(agentId: running.id, companyId: running.companyId)
        }
    }

    /// Runs on every exit path: `performTurn` never throws and runs to completion even when cancelled.
    private func turnEnded(agentId: String, companyId: String) {
        tasks[agentId] = nil
        let n = (runningByCompany[companyId] ?? 1) - 1
        runningByCompany[companyId] = n > 0 ? n : nil
    }

    // MARK: Turn (off the actor)

    private nonisolated func performTurn(agent: Agent, turn: Turn) async {
        var items: [(InboxItem, Message, Channel)] = []
        var quietIds: [Int64] = []
        var result: TurnResult?
        var lastInfo: RateLimitInfo?
        var failure: String?
        var runnerError: (any Error)?
        do {
            guard let company = try store.company(id: agent.companyId) else { throw StoreError.notFound }
            items = try store.pendingInbox(agentId: agent.id)
            let quiet = try store.pendingQuietItems(agentId: agent.id)
            quietIds = quiet.map(\.id)
            let team = try store.agents(companyId: company.id)
            let handles = Dictionary(uniqueKeysWithValues: team.map { ($0.id, $0.name) })
            // `auto` resolves per turn from the role, the company's usage mode and the kind of turn (Tasks 10 and 14 set the context).
            var sent = agent
            sent.model = ModelPolicy.resolve(
                agentModel: agent.model, role: store.catalog.template(role: agent.role, pack: company.packId),
                mode: company.usageMode, context: ModelContext())
            let turnToken = try store.issueTurnCredential(turnId: turn.id)
            let request = TurnRequest(
                agent: sent, company: company,
                prompt: InboxDigest.render(agent: agent, company: company, items: items, handles: handles,
                                            unread: Store.channelCounts(quiet)),
                appendSystemPrompt: RolePrompt.render(agent: agent, company: company),
                mcpConfigPath: try MCPConfig.write(paths: paths, executable: mcpExecutable, agent: agent, turnToken: turnToken),
                workingDirectory: company.workspacePath, profile: profile,
                environment: ["BRAHMA_AGENT_ID": agent.id, "BRAHMA_HOME": paths.home.path,
                              "BRAHMA_WORKSPACES": paths.workspaces.path])
            var sessionMarked = agent.sessionStarted
            var iterator = runner.run(request).makeAsyncIterator()
            while true {
                let event: StreamEvent?
                do { event = try await iterator.next() } catch { runnerError = error; throw error }
                guard let event else { break }
                switch event {
                case .initialized:
                    if !sessionMarked { try store.markSessionStarted(agentId: agent.id); sessionMarked = true }
                case .rateLimit(let info):
                    // A garbled event parses as "unknown"; saving it would close the gate for everyone.
                    guard info.status != "unknown" else { continue }
                    lastInfo = info
                    try store.saveRateLimit(info)
                case .toolUse(let name):
                    // Company tools log their own event from the MCP server.
                    guard !name.hasPrefix("mcp__company__") else { continue }
                    try store.appendEvent(ActivityEvent(companyId: agent.companyId, agentId: agent.id, turnId: turn.id,
                                                        kind: .toolUse, text: "@\(agent.name) \(name)", createdAt: clock()))
                case .result(let r):
                    result = r
                default:
                    break
                }
            }
        } catch {
            failure = String(describing: error)
        }

        let now = clock()
        // Only a rejection or overage is a limit; `allowed_warning` (any window) is not.
        let limited = lastInfo.map(UsageGate.isHardLimit) ?? false
        let end: TurnEnd
        if Task.isCancelled {
            end = .interrupted
        } else if let r = result, !r.isError {
            // A completed turn always counts, even if it also hit the limit: re-running it would repeat its posts.
            end = .succeeded(r, usageHold: limited ? Self.usageUntil(lastInfo?.resetsAt, now: now) : nil)
        } else if result?.apiErrorStatus == 429 || limited {
            let until = Self.usageUntil(limited ? lastInfo?.resetsAt : nil, now: now)
            if !limited {
                // HTTP 429 with no rejecting rate-limit event: record one so the gate closes for every company.
                attempt {
                    try store.saveRateLimit(RateLimitInfo(status: "rejected", resetsAt: until, rateLimitType: nil,
                                                          isUsingOverage: false, fiveHourUtilization: nil,
                                                          sevenDayUtilization: nil, observedAt: now))
                }
            }
            end = .usageLimited(until: until, summary: result?.text)
        } else if let failure {
            // Only the runner's launch error is classifiable; a timeout or "exited without a result" carries stderr.
            var input: InfraInput?
            if let runnerError, !(runnerError is TurnError) { input = InfraInput(text: failure, status: nil) }
            end = .failed(failure, input)
        } else if let r = result {
            end = .failed(r.text ?? r.subtype, InfraInput(text: r.text ?? "", status: r.apiErrorStatus))
        } else {
            end = .failed("claude exited without a result")
        }
        var resetSession = false
        if case .failed(let text, _) = end, agent.sessionStarted {
            resetSession = Self.isSessionNotFound([text, failure, result?.text].compactMap { $0 }.joined(separator: "\n"))
        }
        var infra = InfraClass.none
        attempt {
            infra = try store.endTurn(agentId: agent.id, turn: turn, end: end, deliveredItemIds: items.compactMap(\.0.id) + quietIds,
                                      resetSession: resetSession, now: now)
        }
        let outcome = end.outcome
        await noteOutcome(agentId: agent.id, infra: infra, interrupted: outcome == .interrupted, now: now)
    }

    /// `claude --resume` of a session it never persisted fails the same way forever; spot that so the next turn
    /// starts a fresh session instead.
    static func isSessionNotFound(_ text: String) -> Bool {
        let t = text.lowercased()
        return t.contains("no conversation found") || (t.contains("session") && t.contains("not found"))
    }

    /// When a usage-limited agent may try again: the real reset if it is still ahead, else `usageRetry` from now,
    /// so a missing or stale (past) `resetsAt` cannot unblock it on the next tick and re-hit the limit every tick.
    static func usageUntil(_ resetsAt: Date?, now: Date) -> Date {
        if let resetsAt, resetsAt > now { return resetsAt }
        return now.addingTimeInterval(usageRetry)
    }

    nonisolated func attempt(_ body: () throws -> Void) {
        do { try body() } catch { log("\(error)") }
    }

    nonisolated func log(_ message: String) {
        FileHandle.standardError.write(Data("brahma orchestrator: \(message)\n".utf8))
    }
}

enum TurnEnd {
    /// `usageHold`: the turn completed but also hit the usage limit; if work is pending, the agent waits until then.
    case succeeded(TurnResult, usageHold: Date?)
    /// The summary, and the error text the infrastructure classifier may read (an error `result` event or a launch error).
    case failed(String, InfraInput? = nil)
    case usageLimited(until: Date, summary: String?)
    case interrupted

    var outcome: TurnOutcome {
        switch self {
        case .succeeded: .succeeded
        case .failed: .failed
        case .usageLimited: .usageLimited
        case .interrupted: .interrupted
        }
    }
}

/// Retry backoff after `failures` consecutive failed turns: 30 s doubling, capped at 30 min.
func retryBackoff(failures: Int) -> TimeInterval {
    let exponent = min(max(failures - 1, 0), 10)
    return min(30 * Double(1 << exponent), 30 * 60)
}

extension Store {
    /// Transitions only if the freshly read agent still satisfies `condition`, in one transaction.
    @discardableResult
    func transition(agentId: String, to: AgentState, blocker: Blocker? = nil, now: Date,
                    if condition: (Agent) -> Bool) throws -> Agent? {
        try writer.write { db in
            guard let a = try Agent.fetchOne(db, key: agentId), condition(a) else { return nil }
            return try Store.transition(db: db, agentId: agentId, to: to, blocker: blocker, now: now)
        }
    }

    /// ready → running, a new in-progress turn and a `turnStarted` event, atomically. Nil if the agent is no
    /// longer ready (or was paused) by the time the write runs.
    func beginTurn(agentId: String, now: Date) throws -> (Agent, Turn)? {
        try writer.write { db in
            guard let a = try Agent.fetchOne(db, key: agentId), a.state == .ready, !a.paused else { return nil }
            let agent = try Store.transition(db: db, agentId: agentId, to: .running, now: now)
            let turn = Turn(id: UUID().uuidString, agentId: agentId, companyId: agent.companyId, startedAt: now,
                            endedAt: nil, outcome: .inProgress, summary: nil, costUSD: nil)
            try turn.insert(db)
            try ActivityEvent(companyId: agent.companyId, agentId: agentId, turnId: turn.id, kind: .turnStarted,
                              text: "@\(agent.name) turn started", createdAt: now).insert(db)
            return (agent, turn)
        }
    }

    func markSessionStarted(agentId: String) throws {
        try writer.write { db in
            _ = try Agent.filter(key: agentId).updateAll(db, Column("sessionStarted").set(to: true))
        }
    }

    /// Records the turn outcome and moves the agent on, in one transaction, so a message that arrives while the
    /// turn ends either lands before the pending-inbox check or wakes the agent from its new state.
    /// `resetSession`: the resumed session no longer exists; give the agent a fresh session id so its next turn
    /// starts over with `--session-id` and the role prompt.
    ///
    /// A failure whose error text classifies as network/account is recorded `failed` with `infra = true`: the agent
    /// goes back to `ready` with no backoff, `consecutiveFailures` is unchanged and the inbox stays undelivered.
    /// The 5th consecutive infra failure of one agent is recorded as an ordinary failure. Returns the infra class
    /// that was applied (`.none` for everything else).
    @discardableResult
    func endTurn(agentId: String, turn: Turn, end: TurnEnd, deliveredItemIds: [Int64], resetSession: Bool = false,
                 now: Date) throws -> InfraClass {
        try writer.write { db in
            var summary: String?
            var cost: Double?
            var infraClass = InfraClass.none
            switch end {
            case .succeeded(let r, _): summary = r.text; cost = r.costUSD
            case .failed(let text, let input):
                summary = text
                if let input { infraClass = EngineHealth.classify(text: input.text, apiErrorStatus: input.status) }
            case .usageLimited(_, let text): summary = text
            case .interrupted: summary = "interrupted"
            }
            if case .succeeded = end { try Store.markDelivered(db: db, itemIds: deliveredItemIds, turnId: turn.id) }
            guard var agent = try Agent.fetchOne(db, key: agentId) else { throw StoreError.notFound }
            // The 5th infra failure in a row is an ordinary failure; any non-infra outcome resets the count.
            if infraClass != .none {
                if agent.consecutiveInfraFailures + 1 >= EngineHealth.maxConsecutiveInfra {
                    infraClass = .none
                    agent.consecutiveInfraFailures = 0
                } else {
                    agent.consecutiveInfraFailures += 1
                }
            } else {
                agent.consecutiveInfraFailures = 0
            }
            // False when crash recovery already closed this turn; recovery also moved the agent, so the state
            // guard below leaves it alone.
            let closed = try Store.finishTurn(db: db, id: turn.id, outcome: end.outcome, summary: summary, costUSD: cost,
                                              infra: infraClass != .none, now: now)
            if closed, let cost { try Store.recordSpend(db, cost) }
            var text = "@\(agent.name) turn \(end.outcome.rawValue)"
            if let summary, !summary.isEmpty { text += ": \(summary.prefix(200))" }
            try ActivityEvent(companyId: agent.companyId, agentId: agentId, turnId: turn.id, kind: .turnFinished,
                              text: text, createdAt: now).insert(db)

            switch end {
            case .succeeded: agent.consecutiveFailures = 0
            case .failed: if infraClass == .none { agent.consecutiveFailures += 1 }
            default: break
            }
            // A requested blocker belongs to the turn that set it.
            let requested = agent.requestedBlocker
            agent.requestedBlocker = nil
            var columns = ["consecutiveFailures", "consecutiveInfraFailures", "requestedBlocker"]
            if resetSession {
                agent.sessionId = UUID().uuidString
                agent.sessionStarted = false
                columns += ["sessionId", "sessionStarted"]
                try ActivityEvent(companyId: agent.companyId, agentId: agentId, turnId: turn.id, kind: .error,
                                  text: "@\(agent.name) session not found; next turn starts a fresh session",
                                  createdAt: now).insert(db)
            }
            try agent.update(db, columns: columns)

            // Killed (or otherwise moved) mid-turn: the turn is recorded, the state is left alone.
            guard agent.state == .running else { return infraClass }
            if agent.paused {
                try Store.transition(db: db, agentId: agentId, to: .sleeping, now: now)
                return infraClass
            }
            switch end {
            case .interrupted:
                try Store.transition(db: db, agentId: agentId, to: .ready, now: now)
            case .usageLimited(let until, _):
                try Store.transition(db: db, agentId: agentId, to: .blocked, blocker: .usageLimit(until: until), now: now)
            case .failed where infraClass != .none:
                // Not the agent's fault: ready again at once (the orchestrator adds a fixed cooldown), no backoff.
                try Store.transition(db: db, agentId: agentId, to: .ready, now: now)
            case .failed:
                let n = agent.consecutiveFailures
                try Store.transition(db: db, agentId: agentId, to: .blocked,
                                     blocker: .retry(until: now.addingTimeInterval(retryBackoff(failures: n)), failures: n), now: now)
            case .succeeded(_, let usageHold):
                // Anything still pending arrived mid-turn: the router saw `running` and did not wake us.
                let senders = try String.fetchAll(db, sql: """
                    SELECT message.senderId FROM inboxItem JOIN message ON message.id = inboxItem.messageId
                    WHERE inboxItem.agentId = ? AND inboxItem.deliveredTurnId IS NULL AND inboxItem.wakes = 1
                    """, arguments: [agentId])
                var answered = false
                if let blocker = requested {
                    switch blocker {
                    case .agent(let id): answered = senders.contains(id)
                    case .owner: answered = senders.contains("owner")
                    default: break
                    }
                    // Still waiting on someone: when they answer, the usage gate re-checks before the next turn.
                    if !answered {
                        try Store.transition(db: db, agentId: agentId, to: .blocked, blocker: blocker, now: now)
                        return infraClass
                    }
                }
                if senders.isEmpty {
                    // Nothing left to do: sleep; a new message wakes it and the usage gate holds it if still closed.
                    try Store.transition(db: db, agentId: agentId, to: .sleeping, now: now)
                } else if let usageHold {
                    try Store.transition(db: db, agentId: agentId, to: .blocked, blocker: .usageLimit(until: usageHold), now: now)
                } else {
                    try Store.transition(db: db, agentId: agentId, to: .ready, now: now)
                }
            }
            return infraClass
        }
    }
}
