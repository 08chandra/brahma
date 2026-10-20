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
        try writer.write { db in
            guard var agent = try Agent.fetchOne(db, key: agentId) else { throw StoreError.notFound }
            let from = agent.state
            guard AgentLifecycle.canTransition(from: from, to: to) else { throw LifecycleError.illegal(from: from, to: to) }
            agent.state = to
            agent.blocker = to == .blocked ? blocker : nil
            agent.readySince = to == .ready ? now : nil
            try agent.update(db)
            try ActivityEvent(companyId: agent.companyId, agentId: agent.id, turnId: nil, kind: .stateChanged,
                              text: "\(from.rawValue) -> \(to.rawValue)", createdAt: now).insert(db)
            return agent
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

    public func finishTurn(id: String, outcome: TurnOutcome, summary: String?, costUSD: Double?, now: Date = Store.now()) throws {
        try writer.write { db in
            guard var turn = try Turn.fetchOne(db, key: id) else { throw StoreError.notFound }
            turn.outcome = outcome; turn.summary = summary; turn.costUSD = costUSD; turn.endedAt = now
            try turn.update(db)
        }
    }

    public func turnCount(agentId: String, since: Date) throws -> Int {
        try writer.read { db in
            try Turn.filter(Column("agentId") == agentId && Column("startedAt") >= since).fetchCount(db)
        }
    }

    public func oldestTurnStart(agentId: String, since: Date) throws -> Date? {
        try writer.read { db in
            try Turn.filter(Column("agentId") == agentId && Column("startedAt") >= since)
                .order(Column("startedAt")).fetchOne(db)?.startedAt
        }
    }

    /// Crash recovery: in-progress turns become interrupted; agents recorded running return to ready.
    /// Returns the number of agents recovered.
    public func recoverInterruptedTurns(now: Date = Store.now()) throws -> Int {
        try writer.write { db in
            try db.execute(sql: "UPDATE turn SET outcome = ?, endedAt = ? WHERE outcome = ?",
                           arguments: [TurnOutcome.interrupted.rawValue, now, TurnOutcome.inProgress.rawValue])
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
        try writer.write { db in try e.insert(db) }
    }

    public func events(afterId: Int64, companyId: String? = nil, limit: Int = 500) throws -> [ActivityEvent] {
        try writer.read { db in
            var request = ActivityEvent.filter(Column("id") > afterId)
            if let companyId { request = request.filter(Column("companyId") == companyId) }
            return try request.order(Column("id")).limit(limit).fetchAll(db)
        }
    }
}
