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

    /// In-memory: turns this orchestrator has in flight, per company. The DB `running` state is the durable record.
    private var runningByCompany: [String: Int] = [:]
    /// Agent id → its turn task.
    private var tasks: [String: Task<Void, Never>] = [:]

    static let usageRetry: TimeInterval = 15 * 60
    static let hour: TimeInterval = 3600

    public init(store: Store, runner: any TurnRunning, paths: BrahmaPaths, config: SchedulerConfig = .init(),
                mcpExecutable: String, profile: PermissionProfile = .workspace,
                clock: @escaping @Sendable () -> Date = { .now }) {
        self.store = store; self.runner = runner; self.paths = paths; self.config = config
        self.mcpExecutable = mcpExecutable; self.profile = profile; self.clock = clock
    }

    /// Crash recovery: turns left in progress by a previous run are interrupted; their agents return to ready.
    public func start() throws {
        _ = try store.recoverInterruptedTurns(now: clock())
    }

    public func runningCount() -> Int { runningByCompany.values.reduce(0, +) }

    public func waitUntilIdle(timeout: Duration) async throws {
        let deadline = ContinuousClock.now + timeout
        while !tasks.isEmpty {
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
        let inFlight = Array(tasks.values)
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

        // 2. Usage gate, per company mode.
        let info = try store.latestRateLimit()
        var decisions: [String: UsageDecision] = [:]
        for c in companies {
            let decision = UsageGate.evaluate(info, mode: c.usageMode, now: now)
            decisions[c.id] = decision
            guard case .closed(let gateUntil) = decision else { continue }
            let until = Self.usageUntil(gateUntil, now: now)
            var stopped = 0
            for a in try store.agents(companyId: c.id, states: [.ready]) {
                attempt {
                    if try store.transition(agentId: a.id, to: .blocked, blocker: .usageLimit(until: until), now: now,
                                            if: { $0.state == .ready }) != nil { stopped += 1 }
                }
            }
            if stopped > 0 {
                attempt {
                    try store.appendEvent(ActivityEvent(
                        companyId: c.id, agentId: nil, turnId: nil, kind: .usage,
                        text: "usage gate closed (\(c.usageMode.rawValue) mode) until \(until.ISO8601Format()); \(stopped) agent(s) waiting",
                        createdAt: now))
                }
            }
        }

        // 3. Per-agent turn budget over the last hour.
        let hourAgo = now.addingTimeInterval(-Self.hour)
        for a in try store.agents(states: [.ready]) where try store.turnCount(agentId: a.id, since: hourAgo) >= config.turnBudgetPerHour {
            let oldest = try store.oldestTurnStart(agentId: a.id, since: hourAgo) ?? now
            attempt {
                try store.transition(agentId: a.id, to: .blocked, blocker: .turnBudget(until: oldest.addingTimeInterval(Self.hour)),
                                     now: now, if: { $0.state == .ready })
            }
        }

        // 4. How many live agents each agent is holding up.
        let all = try store.agents()
        var blocking: [String: Int] = [:]
        for a in all where a.state != .killed {
            if case .agent(let id)? = a.blocker { blocking[id, default: 0] += 1 }
        }

        // 5. Select and launch.
        let byId = Dictionary(uniqueKeysWithValues: companies.map { ($0.id, $0) })
        let candidates = all.compactMap { a -> Candidate? in
            guard a.state == .ready, !a.paused, tasks[a.id] == nil, let c = byId[a.companyId] else { return nil }
            return Candidate(agent: a, company: c, blockingCount: blocking[a.id] ?? 0)
        }
        let selected = Scheduler.select(candidates: candidates, runningByCompany: runningByCompany, config: config,
                                        usage: { decisions[$0.id] ?? .open })
        for agent in selected { launch(agent, now: now) }
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
        var result: TurnResult?
        var lastInfo: RateLimitInfo?
        var failure: String?
        do {
            guard let company = try store.company(id: agent.companyId) else { throw StoreError.notFound }
            items = try store.pendingInbox(agentId: agent.id)
            let team = try store.agents(companyId: company.id)
            let handles = Dictionary(uniqueKeysWithValues: team.map { ($0.id, $0.name) })
            let request = TurnRequest(
                agent: agent, company: company,
                prompt: InboxDigest.render(agent: agent, company: company, items: items, handles: handles),
                appendSystemPrompt: agent.sessionStarted
                    ? nil : RolePrompt.render(agent: agent, company: company, roster: team.filter { $0.state != .killed }),
                mcpConfigPath: try MCPConfig.write(paths: paths, executable: mcpExecutable, agent: agent),
                workingDirectory: company.workspacePath, profile: profile)
            var sessionMarked = agent.sessionStarted
            for try await event in runner.run(request) {
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
            end = .failed(failure)
        } else if let r = result {
            end = .failed(r.text ?? r.subtype)
        } else {
            end = .failed("claude exited without a result")
        }
        var resetSession = false
        if case .failed(let text) = end, agent.sessionStarted {
            resetSession = Self.isSessionNotFound([text, failure, result?.text].compactMap { $0 }.joined(separator: "\n"))
        }
        attempt {
            try store.endTurn(agentId: agent.id, turn: turn, end: end, deliveredItemIds: items.compactMap(\.0.id),
                              resetSession: resetSession, now: now)
        }
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

    private nonisolated func attempt(_ body: () throws -> Void) {
        do { try body() } catch { log("\(error)") }
    }

    private nonisolated func log(_ message: String) {
        FileHandle.standardError.write(Data("brahma orchestrator: \(message)\n".utf8))
    }
}

enum TurnEnd {
    /// `usageHold`: the turn completed but also hit the usage limit; if work is pending, the agent waits until then.
    case succeeded(TurnResult, usageHold: Date?)
    case failed(String)
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
    func endTurn(agentId: String, turn: Turn, end: TurnEnd, deliveredItemIds: [Int64], resetSession: Bool = false,
                 now: Date) throws {
        try writer.write { db in
            var summary: String?
            var cost: Double?
            switch end {
            case .succeeded(let r, _): summary = r.text; cost = r.costUSD
            case .failed(let text): summary = text
            case .usageLimited(_, let text): summary = text
            case .interrupted: summary = "interrupted"
            }
            if case .succeeded = end { try Store.markDelivered(db: db, itemIds: deliveredItemIds, turnId: turn.id) }
            // False when crash recovery already closed this turn; recovery also moved the agent, so the state
            // guard below leaves it alone.
            _ = try Store.finishTurn(db: db, id: turn.id, outcome: end.outcome, summary: summary, costUSD: cost, now: now)
            guard var agent = try Agent.fetchOne(db, key: agentId) else { throw StoreError.notFound }
            var text = "@\(agent.name) turn \(end.outcome.rawValue)"
            if let summary, !summary.isEmpty { text += ": \(summary.prefix(200))" }
            try ActivityEvent(companyId: agent.companyId, agentId: agentId, turnId: turn.id, kind: .turnFinished,
                              text: text, createdAt: now).insert(db)

            switch end {
            case .succeeded: agent.consecutiveFailures = 0
            case .failed: agent.consecutiveFailures += 1
            default: break
            }
            // A requested blocker belongs to the turn that set it.
            let requested = agent.requestedBlocker
            agent.requestedBlocker = nil
            var columns = ["consecutiveFailures", "requestedBlocker"]
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
            guard agent.state == .running else { return }
            if agent.paused {
                try Store.transition(db: db, agentId: agentId, to: .sleeping, now: now)
                return
            }
            switch end {
            case .interrupted:
                try Store.transition(db: db, agentId: agentId, to: .ready, now: now)
            case .usageLimited(let until, _):
                try Store.transition(db: db, agentId: agentId, to: .blocked, blocker: .usageLimit(until: until), now: now)
            case .failed:
                let n = agent.consecutiveFailures
                try Store.transition(db: db, agentId: agentId, to: .blocked,
                                     blocker: .retry(until: now.addingTimeInterval(retryBackoff(failures: n)), failures: n), now: now)
            case .succeeded(_, let usageHold):
                // Anything still pending arrived mid-turn: the router saw `running` and did not wake us.
                let senders = try String.fetchAll(db, sql: """
                    SELECT message.senderId FROM inboxItem JOIN message ON message.id = inboxItem.messageId
                    WHERE inboxItem.agentId = ? AND inboxItem.deliveredTurnId IS NULL
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
                        return
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
        }
    }
}
