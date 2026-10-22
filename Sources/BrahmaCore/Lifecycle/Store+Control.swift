import Foundation
import GRDB

extension Store {
    /// Owner pause/wake. Flips only the `paused` column (MCP processes write other columns concurrently).
    /// Pausing a running agent just sets the flag: the orchestrator sleeps it at turn end. Pausing a ready or
    /// blocked agent also moves it to sleeping. Waking clears the flag and moves sleeping/blocked agents to ready.
    /// A killed agent is left untouched. Returns the agent as written.
    @discardableResult
    public func setPaused(agentId: String, _ paused: Bool, now: Date = Store.now()) throws -> Agent {
        try writer.write { db in
            guard let current = try Agent.fetchOne(db, key: agentId) else { throw StoreError.notFound }
            guard current.state != .killed else { return current }
            _ = try Agent.filter(key: agentId).updateAll(db, Column("paused").set(to: paused))
            // The pause start in company-active time, for ask rerouting; cleared on wake.
            if paused != current.paused || !paused {
                let since: Double? = paused ? try Store.activeNow(db: db, companyId: current.companyId) : nil
                _ = try Agent.filter(key: agentId).updateAll(db, Column("pausedActive").set(to: since))
            }
            if paused {
                if current.state == .ready || current.state == .blocked {
                    return try Store.transition(db: db, agentId: agentId, to: .sleeping, now: now)
                }
            } else if current.state == .sleeping || current.state == .blocked {
                return try Store.transition(db: db, agentId: agentId, to: .ready, now: now)
            }
            return try Agent.fetchOne(db, key: agentId) ?? current
        }
    }

    public func lastTurn(agentId: String) throws -> Turn? {
        try writer.read { db in
            try Turn.filter(Column("agentId") == agentId).order(Column("startedAt").desc, Column.rowID.desc).fetchOne(db)
        }
    }

    /// Highest activity event id, 0 when there are none.
    public func maxEventId() throws -> Int64 {
        try writer.read { db in try Int64.fetchOne(db, sql: "SELECT MAX(id) FROM activityEvent") ?? 0 }
    }
}
