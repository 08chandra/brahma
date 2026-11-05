import Foundation
import GRDB

/// Which of an agent's sessions a turn belongs to: the base session (turns without a current item) or the session of one item.
public enum SessionScope: Equatable, Sendable {
    case base
    case item(String)

    public var itemId: String? {
        if case .item(let id) = self { return id }
        return nil
    }
}

/// When a stored session may be resumed. A resume is cheap only while the prompt cache is warm and the transcript is small;
/// otherwise a fresh session that starts from the role card, the orientation and a Continuity block costs less and is clearer.
public enum SessionPolicy {
    /// A session whose last turn ended this many wall seconds ago or more is cold (the prompt cache lives about 3600 s).
    public static let warmSeconds: TimeInterval = 3000
    /// A session whose last turn read, wrote or cached this many tokens or more is too large to carry on.
    public static let maxResumeTokens = 60_000

    public enum Reason: String, Equatable, Sendable { case new, cold, large, cwdChanged }

    public enum Decision: Equatable, Sendable {
        case resume
        case fresh(Reason)
    }

    /// `tokens` is the last turn's input + cache-read + cache-creation count when the engine recorded it (Task 14), else nil
    /// and the time rule alone applies. An unknown end time counts as cold; an unknown working directory matches anything.
    public static func decide(started: Bool, storedCwd: String?, cwd: String, endedAt: Date?, tokens: Int?, now: Date) -> Decision {
        guard started else { return .fresh(.new) }
        if let storedCwd, storedCwd != cwd { return .fresh(.cwdChanged) }
        guard let endedAt, now.timeIntervalSince(endedAt) < warmSeconds else { return .fresh(.cold) }
        if let tokens, tokens >= maxResumeTokens { return .fresh(.large) }
        return .resume
    }
}

/// An agent's session for one item.
public struct ItemSession: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "agentSession"

    public var agentId: String
    public var itemId: String
    public var sessionId: String
    public var started: Bool = false
    /// The working directory of the turns of this session; a turn elsewhere starts a fresh session.
    public var cwd: String? = nil
    /// Fixed after the session's first work turn (the effort may vary, the model does not).
    public var sessionModel: String? = nil
    /// The tool set and permission mode of the last turn, to tell a cache break.
    public var sessionTools: String? = nil
    public var lastEndedAt: Date? = nil
    public var lastTurnId: String? = nil
    public var createdAt: Date
    /// The frozen mount set of the session (Task 5a).
    public var mountSetHash: String? = nil
}

/// The state of one session as the orchestrator needs it, whichever table it lives in.
public struct SessionSlot: Equatable, Sendable {
    public var scope: SessionScope
    public var sessionId: String
    public var started: Bool
    public var cwd: String?
    public var model: String?
    public var tools: String?
    public var endedAt: Date?
    public var lastTurnId: String?
    public var mountSetHash: String? = nil
}

extension Store {
    // MARK: Item sessions

    /// The agent's session for the item; created fresh (a new id, not started) the first time.
    public func itemSession(agentId: String, itemId: String, now: Date = Store.now()) throws -> ItemSession {
        try writer.write { db in
            if let existing = try ItemSession.filter(Column("agentId") == agentId && Column("itemId") == itemId).fetchOne(db) {
                return existing
            }
            let created = ItemSession(agentId: agentId, itemId: itemId, sessionId: UUID().uuidString, createdAt: now)
            try created.insert(db)
            return created
        }
    }

    public func markItemSessionStarted(agentId: String, itemId: String, cwd: String? = nil, model: String? = nil,
                                       tools: String? = nil, mountSetHash: String? = nil) throws {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE agentSession SET started = 1, cwd = COALESCE(?, cwd), sessionModel = COALESCE(sessionModel, ?),
                sessionTools = COALESCE(?, sessionTools), mountSetHash = COALESCE(?, mountSetHash) WHERE agentId = ? AND itemId = ?
                """, arguments: [cwd, model, tools, mountSetHash, agentId, itemId])
        }
    }

    /// A new session id, not started: the next turn for this item starts over with the role card and the orientation.
    public func resetItemSession(agentId: String, itemId: String) throws {
        try writer.write { db in try Store.resetItemSession(db: db, agentId: agentId, itemId: itemId) }
    }

    static func resetItemSession(db: Database, agentId: String, itemId: String) throws {
        try db.execute(sql: """
            UPDATE agentSession SET sessionId = ?, started = 0, cwd = NULL, sessionModel = NULL, sessionTools = NULL,
            lastEndedAt = NULL, lastTurnId = NULL WHERE agentId = ? AND itemId = ?
            """, arguments: [UUID().uuidString, agentId, itemId])
    }

    // MARK: Either kind

    func sessionSlot(agent: Agent, scope: SessionScope) throws -> SessionSlot {
        switch scope {
        case .base:
            let m = agent.sessionMeta
            return SessionSlot(scope: scope, sessionId: agent.sessionId, started: agent.sessionStarted, cwd: m?.cwd, model: m?.model,
                               tools: m?.tools, endedAt: m?.endedAt.map { Date(timeIntervalSince1970: $0) }, lastTurnId: m?.lastTurnId,
                               mountSetHash: m?.mountSetHash)
        case .item(let itemId):
            let s = try itemSession(agentId: agent.id, itemId: itemId)
            return SessionSlot(scope: scope, sessionId: s.sessionId, started: s.started, cwd: s.cwd, model: s.sessionModel,
                               tools: s.sessionTools, endedAt: s.lastEndedAt, lastTurnId: s.lastTurnId, mountSetHash: s.mountSetHash)
        }
    }

    func markSessionStarted(agentId: String, scope: SessionScope, cwd: String, model: String, tools: String, mountSetHash: String? = nil) throws {
        switch scope {
        case .item(let itemId):
            try markItemSessionStarted(agentId: agentId, itemId: itemId, cwd: cwd, model: model, tools: tools, mountSetHash: mountSetHash)
        case .base:
            try writer.write { db in
                guard var agent = try Agent.fetchOne(db, key: agentId) else { return }
                var meta = agent.sessionMeta ?? SessionMeta()
                meta.cwd = cwd; meta.model = model; meta.tools = tools
                if let mountSetHash { meta.mountSetHash = mountSetHash }
                agent.sessionMeta = meta
                agent.sessionStarted = true
                try agent.update(db, columns: ["sessionMeta", "sessionStarted"])
            }
        }
    }

    /// Gives the session a new id and forgets what it ran with.
    static func resetSession(db: Database, agentId: String, scope: SessionScope) throws {
        switch scope {
        case .item(let itemId):
            try resetItemSession(db: db, agentId: agentId, itemId: itemId)
        case .base:
            guard var agent = try Agent.fetchOne(db, key: agentId) else { return }
            agent.sessionId = UUID().uuidString
            agent.sessionStarted = false
            agent.sessionMeta = nil
            try agent.update(db, columns: ["sessionId", "sessionStarted", "sessionMeta"])
        }
    }

    func resetSession(agentId: String, scope: SessionScope) throws {
        try writer.write { db in try Store.resetSession(db: db, agentId: agentId, scope: scope) }
    }

    /// A turn that used the session has ended: remember when, which turn, and what it ran with (for the warm rule, the size
    /// rule and cache-break detection). `model` nil keeps the stored model (an item session's model is fixed).
    static func noteSessionTurn(db: Database, agentId: String, scope: SessionScope, turnId: String, endedAt: Date,
                                model: String?, tools: String, cwd: String) throws {
        switch scope {
        case .item(let itemId):
            try db.execute(sql: """
                UPDATE agentSession SET lastEndedAt = ?, lastTurnId = ?, sessionTools = ?, cwd = ?,
                sessionModel = COALESCE(?, sessionModel) WHERE agentId = ? AND itemId = ? AND started = 1
                """, arguments: [endedAt, turnId, tools, cwd, model, agentId, itemId])
        case .base:
            guard var agent = try Agent.fetchOne(db, key: agentId), agent.sessionStarted else { return }
            var meta = agent.sessionMeta ?? SessionMeta()
            meta.endedAt = endedAt.timeIntervalSince1970; meta.lastTurnId = turnId; meta.tools = tools; meta.cwd = cwd
            if let model { meta.model = model }
            agent.sessionMeta = meta
            try agent.update(db, columns: ["sessionMeta"])
        }
    }

    // MARK: Size and continuity

    /// The transcript size estimate of a session: the input, cache-read and cache-creation tokens Task 14a recorded on its last
    /// turn. Nil when the turn is unknown or it recorded no usage.
    func sessionTranscriptTokens(turnId: String?) -> Int? {
        guard let turnId else { return nil }
        return try? writer.read { db -> Int? in
            let sum = try Int.fetchOne(db, sql: "SELECT inputTokens + cacheReadTokens + cacheCreationTokens FROM turn WHERE id = ?",
                                       arguments: [turnId]) ?? 0
            return sum > 0 ? sum : nil
        }
    }

    /// Summaries of the newest `limit` succeeded work turns of the scope, oldest first. Turns that only lost their session do
    /// not count.
    func recentTurnSummaries(agentId: String, scope: SessionScope, limit: Int = 3) throws -> [String] {
        try writer.read { db in
            let itemClause = scope.itemId == nil ? "itemId IS NULL" : "itemId = ?"
            var args: [DatabaseValueConvertible] = [agentId]
            if let id = scope.itemId { args.append(id) }
            args.append(limit)
            // F1: a summary a tainted turn wrote is left out (`recentTurnSummariesTainted` counts them for the engine's line).
            let rows = try Row.fetchAll(db, sql: """
                SELECT COALESCE(summary, '') AS summary, taintedAt IS NOT NULL AS tainted FROM turn WHERE agentId = ? AND \(itemClause)
                AND outcome = 'succeeded' AND kind IN ('work', 'plan', 'notice') AND sessionResetReason IS NULL AND summary IS NOT NULL
                AND summary <> '' ORDER BY startedAt DESC, rowid DESC LIMIT ?
                """, arguments: StatementArguments(args))
            return rows.filter { !($0["tainted"] as Bool? ?? true) }.map { $0["summary"] as String }.reversed()
        }
    }

    /// How many of the newest `limit` summaries `recentTurnSummaries` left out: written by turns that read outside content.
    func recentTurnSummariesTainted(agentId: String, scope: SessionScope, limit: Int = 3) throws -> Int {
        try writer.read { db in
            let itemClause = scope.itemId == nil ? "itemId IS NULL" : "itemId = ?"
            var args: [DatabaseValueConvertible] = [agentId]
            if let id = scope.itemId { args.append(id) }
            args.append(limit)
            let rows = try Bool.fetchAll(db, sql: """
                SELECT taintedAt IS NOT NULL FROM turn WHERE agentId = ? AND \(itemClause) AND outcome = 'succeeded'
                AND kind IN ('work', 'plan', 'notice') AND sessionResetReason IS NULL AND summary IS NOT NULL AND summary <> ''
                ORDER BY startedAt DESC, rowid DESC LIMIT ?
                """, arguments: StatementArguments(args))
            return rows.filter { $0 }.count
        }
    }

    // MARK: Plan turns

    /// A plan turn's plan: an item event (`planWritten`), quoted into the next orientation and the Continuity block. The
    /// assignee's manager gets it as an FYI that never wakes.
    func recordPlan(itemId: String, agentId: String, text: String, now: Date = Store.now()) throws {
        try writer.write { db in
            guard let item = try WorkItem.fetchOne(db, key: itemId), let agent = try Agent.fetchOne(db, key: agentId) else { return }
            try recordItemEvent(db: db, item: item, actor: agentId, kind: .planWritten, text: String(text.prefix(Store.maxPlanText)),
                                alsoNotify: [agent.managerId].compactMap { $0 }, now: now)
        }
    }

    /// A plan turn changed the worktree: the engine reset it, does not count the plan and tells the manager (else the owner).
    func recordPlanTurnWrote(itemId: String, agentId: String, detail: String, now: Date = Store.now()) throws {
        try writer.write { db in
            guard let item = try WorkItem.fetchOne(db, key: itemId), let agent = try Agent.fetchOne(db, key: agentId) else { return }
            try recordItemEvent(db: db, item: item, actor: "system", kind: .planTurnWrote,
                                text: "@\(agent.name)'s plan turn changed the worktree (\(detail)); the engine reset it and ignored the plan", now: now)
            var target = "owner"
            if let m = agent.managerId, let manager = try Agent.fetchOne(db, key: m), manager.state != .killed { target = manager.name }
            try MessageRouter(store: self).sendDM(db: db, companyId: item.companyId, from: .system, to: target,
                                                  text: "@\(agent.name)'s plan turn on \(item.key) changed the worktree; the engine reset it. "
                                                      + "The plan was not counted.", now: now)
        }
    }

    static let maxPlanText = 6000

    // MARK: Turn bookkeeping

    func setTurnCacheBreak(turnId: String, _ reason: String) throws {
        try writer.write { db in try db.execute(sql: "UPDATE turn SET cacheBreak = ? WHERE id = ?", arguments: [reason, turnId]) }
    }
}

/// The `STATUS:` line a turn ends with (see `OperatingRules`).
public enum TurnStatus {
    public static let all = ["DONE", "DONE_WITH_CONCERNS", "BLOCKED", "NEEDS_CONTEXT"]

    /// The value of the last `STATUS:` line of a result when it names one of the four statuses; nil otherwise.
    public static func parse(_ text: String?) -> String? {
        guard let text else { return nil }
        for line in text.components(separatedBy: .newlines).reversed() {
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("STATUS:") else { continue }
            let value = t.dropFirst("STATUS:".count).trimmingCharacters(in: .whitespaces)
            return all.contains(value) ? value : nil
        }
        return nil
    }

    /// The agent says it cannot go on without something from someone.
    public static func isBlocked(_ status: String?) -> Bool { status == "BLOCKED" || status == "NEEDS_CONTEXT" }
}
