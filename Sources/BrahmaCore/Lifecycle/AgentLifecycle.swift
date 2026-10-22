import Foundation
import GRDB

public enum LifecycleError: Error, Equatable { case illegal(from: AgentState, to: AgentState) }

public enum AgentLifecycle {
    private static let legal: Set<[AgentState]> = [
        [.sleeping, .ready], [.sleeping, .blocked],
        [.ready, .running], [.ready, .blocked], [.ready, .sleeping],
        [.running, .sleeping], [.running, .ready], [.running, .blocked],
        [.blocked, .ready], [.blocked, .sleeping],
    ]

    public static func canTransition(from: AgentState, to: AgentState) -> Bool {
        if to == .killed { return from != .killed }
        return legal.contains([from, to])
    }
}

extension Store {
    /// Validates, then persists the new state and a `stateChanged` event in one transaction.
    /// `paused` and `requestedBlocker` are left untouched.
    @discardableResult
    public func transition(agentId: String, to: AgentState, blocker: Blocker? = nil, now: Date = Store.now()) throws -> Agent {
        try writer.write { db in try transitionAndRelease(db: db, agentId: agentId, to: to, blocker: blocker, now: now) }
    }

    /// `transition`, plus what leaving the company does to the org (`offboard`): asks and reviews re-routed, leases marked
    /// expired, items unassigned with an auto hand-off, reports reparented, an acting CEO named, observers told.
    func transitionAndRelease(db: Database, agentId: String, to: AgentState, blocker: Blocker? = nil, now: Date) throws -> Agent {
        // Teammates blocked on an agent that is killed are released by the transition; each is told why it is awake (an
        // engine DM through the normal path), or it would have nothing to act on.
        var waiters: [Agent] = []
        if to == .killed, let target = try Agent.fetchOne(db, key: agentId) {
            waiters = try Agent.filter(Column("companyId") == target.companyId && Column("state") == AgentState.blocked.rawValue)
                .fetchAll(db).filter { $0.id != agentId && $0.blocker == .agent(agentId) }
        }
        let agent = try Store.transition(db: db, agentId: agentId, to: to, blocker: blocker, now: now)
        if to == .killed {
            try offboard(db: db, agent: agent, now: now)
            for waiter in waiters {
                try MessageRouter(store: self).sendDM(
                    db: db, companyId: waiter.companyId, from: .system, to: waiter.name,
                    text: "@\(agent.name) was removed from the company while you were waiting on them. "
                        + "Re-plan: ask someone else or continue without them.", now: now)
            }
        }
        return agent
    }

    /// Same as `transition(agentId:to:blocker:now:)`, for callers already inside a write transaction.
    @discardableResult
    static func transition(db: Database, agentId: String, to: AgentState, blocker: Blocker? = nil, now: Date) throws -> Agent {
        guard var agent = try Agent.fetchOne(db, key: agentId) else { throw StoreError.notFound }
        let from = agent.state
        guard AgentLifecycle.canTransition(from: from, to: to) else { throw LifecycleError.illegal(from: from, to: to) }
        agent.state = to
        agent.blocker = to == .blocked ? blocker : nil
        agent.readySince = to == .ready ? now : nil
        try agent.update(db)
        try ActivityEvent(companyId: agent.companyId, agentId: agent.id, turnId: nil, kind: .stateChanged,
                          text: "\(from.rawValue) -> \(to.rawValue)", createdAt: now).insert(db)
        if to == .killed { try releaseWaiters(db: db, on: agent, now: now) }
        return agent
    }

    /// Nobody may wait on a killed agent: teammates blocked on it become ready (sleeping if paused), and a
    /// pending `set_blocked` request naming it is dropped.
    private static func releaseWaiters(db: Database, on killed: Agent, now: Date) throws {
        for var other in try Agent.filter(Column("companyId") == killed.companyId).fetchAll(db) where other.id != killed.id {
            if other.requestedBlocker == .agent(killed.id) {
                other.requestedBlocker = nil
                try other.update(db, columns: ["requestedBlocker"])
            }
            if other.state == .blocked, other.blocker == .agent(killed.id) {
                try transition(db: db, agentId: other.id, to: other.paused ? .sleeping : .ready, now: now)
            }
        }
    }

    public func startTurn(agentId: String, now: Date = Store.now()) throws -> Turn {
        try writer.write { db in
            guard let agent = try Agent.fetchOne(db, key: agentId) else { throw StoreError.notFound }
            let turn = Turn(id: UUID().uuidString, agentId: agentId, companyId: agent.companyId, startedAt: now,
                            endedAt: nil, outcome: .inProgress, summary: nil, costUSD: nil)
            try turn.insert(db)
            return turn
        }
    }

    /// Records the end of a turn that is still in progress. Returns false, changing nothing, if the turn was
    /// already finished (e.g. marked interrupted by crash recovery) so a late finish cannot clobber it.
    @discardableResult
    public func finishTurn(id: String, outcome: TurnOutcome, summary: String?, costUSD: Double?, now: Date = Store.now()) throws -> Bool {
        try writer.write { db in
            try Store.finishTurn(db: db, id: id, outcome: outcome, summary: redact(summary), costUSD: costUSD, now: now)
        }
    }

    static func finishTurn(db: Database, id: String, outcome: TurnOutcome, summary: String?, costUSD: Double?, infra: Bool = false,
                           reportedStatus: String? = nil, sessionResetReason: String? = nil, now: Date) throws -> Bool {
        guard var turn = try Turn.fetchOne(db, key: id) else { throw StoreError.notFound }
        guard turn.outcome == .inProgress else { return false }
        turn.outcome = outcome; turn.summary = summary; turn.costUSD = costUSD; turn.infra = infra; turn.endedAt = now
        turn.reportedStatus = reportedStatus; turn.sessionResetReason = sessionResetReason
        try turn.update(db)
        try db.execute(sql: "DELETE FROM turnCredential WHERE turnId = ?", arguments: [id])
        try db.execute(sql: "DELETE FROM turnQuotaUsage WHERE turnId = ?", arguments: [id])
        return true
    }

    public func turnCount(agentId: String, since: Date) throws -> Int {
        try writer.read { db in
            try Turn.filter(Column("agentId") == agentId && Column("startedAt") >= since && Column("infra") == false
                             && Column("sessionResetReason") == nil).fetchCount(db)
        }
    }

    public func oldestTurnStart(agentId: String, since: Date) throws -> Date? {
        try writer.read { db in
            try Turn.filter(Column("agentId") == agentId && Column("startedAt") >= since && Column("infra") == false
                             && Column("sessionResetReason") == nil)
                .order(Column("startedAt")).fetchOne(db)?.startedAt
        }
    }

    /// Crash recovery: in-progress turns become interrupted; agents recorded running return to ready.
    /// Returns the number of agents recovered.
    public func recoverInterruptedTurns(now: Date = Store.now()) throws -> Int {
        try writer.write { db in
            try db.execute(sql: "UPDATE turn SET outcome = ?, endedAt = ? WHERE outcome = ?",
                           arguments: [TurnOutcome.interrupted.rawValue, now, TurnOutcome.inProgress.rawValue])
            try db.execute(sql: "DELETE FROM turnCredential WHERE turnId IN (SELECT id FROM turn WHERE outcome <> ?)",
                           arguments: [TurnOutcome.inProgress.rawValue])
            try db.execute(sql: "DELETE FROM turnQuotaUsage WHERE turnId IN (SELECT id FROM turn WHERE outcome <> ?)",
                           arguments: [TurnOutcome.inProgress.rawValue])
            let running = try Agent.filter(Column("state") == AgentState.running.rawValue).fetchAll(db)
            for var agent in running {
                agent.state = .ready; agent.blocker = nil; agent.readySince = now
                try agent.update(db)
                try ActivityEvent(companyId: agent.companyId, agentId: agent.id, turnId: nil, kind: .stateChanged,
                                  text: "running -> ready (recovered)", createdAt: now).insert(db)
            }
            return running.count
        }
    }

    public func appendEvent(_ e: ActivityEvent) throws {
        var event = e
        event.text = redact(e.text)
        try writer.write { db in try event.insert(db) }
    }

    public func events(afterId: Int64, companyId: String? = nil, limit: Int = 500) throws -> [ActivityEvent] {
        try writer.read { db in
            var request = ActivityEvent.filter(Column("id") > afterId)
            if let companyId { request = request.filter(Column("companyId") == companyId) }
            return try request.order(Column("id")).limit(limit).fetchAll(db)
        }
    }
}
