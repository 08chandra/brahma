import Foundation
import GRDB

public enum AgentState: String, Codable, Sendable { case ready, running, blocked, sleeping, killed }

public enum Blocker: Codable, Equatable, Sendable {
    case agent(String)
    /// Waiting on the owner. `askId` links the wait to an open ask of the same company; only the engine sets it (`set_blocked`
    /// with an `ask` it validated), never parsed from the reason. Owner-notice urgency counts these links.
    case owner(reason: String, askId: String? = nil)
    case usageLimit(until: Date)
    case turnBudget(until: Date)
    case retry(until: Date, failures: Int)
    /// Waiting for a work item to be done (CLI: `waiting on <key>`).
    case workItem(id: String, key: String)
}

public struct Agent: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "agent"

    public var id: String
    public var companyId: String
    /// Handle: unique per company, lowercase.
    public var name: String
    public var role: String
    public var model: String
    /// UUID string.
    public var sessionId: String
    public var sessionStarted: Bool
    public var state: AgentState
    public var blocker: Blocker?
    public var requestedBlocker: Blocker?
    public var paused: Bool
    public var readySince: Date?
    public var createdAt: Date
    /// Failed turns in a row; drives retry backoff. Reset by a successful turn.
    public var consecutiveFailures: Int = 0
    /// Infrastructure failures in a row (not counted in `consecutiveFailures`); the 5th is recorded as an ordinary failure.
    public var consecutiveInfraFailures: Int = 0
    /// Reporting line. Nil for the root, or when the manager was removed.
    public var managerId: String? = nil
    public var team: String? = nil
    /// Hook for the trust ladder (Plan 3b).
    public var trustLevel: String = "T1"
    /// Company-active time of the last wake caused by a work notice; managers and executives are debounced from it.
    public var lastNoticeWakeActive: Double? = nil
    /// Company-active time when the owner paused the agent; nil while awake. Ask rerouting reads it.
    public var pausedActive: Double? = nil
    /// What the agent's base session (turns without a current item) ran with last; see `SessionMeta`.
    public var sessionMeta: SessionMeta? = nil
    /// "ceo" while the agent acts as the company's CEO after the CEO left (Task 12); it then counts as covering `ceo` for routing.
    public var actingRole: String? = nil
    /// Set when an audit of one of the agent's auto-merged items failed (9c): its changes always get a review turn.
    public var fullReview: Bool = false
    /// Judged work turns in a row without work-item progress (the watchdog, 14b).
    public var turnsWithoutProgress: Int = 0
    /// A `freshSessionReason` waiting for the next turn (`Store.forceFreshSession`, Task 5a); `startTurn` moves it onto the turn.
    public var pendingSessionReset: String? = nil
    /// The session scope `pendingSessionReset` belongs to ('' the base session, else the item id); nil: any (B-M12).
    public var pendingSessionResetScope: String? = nil
    /// The agent's session read outside content (Task 10, `Store.markTainted`): its high-risk company tools are refused.
    public var sessionTainted: Bool = false
    /// A high-risk call was refused under taint: the turn's end starts a fresh session (`Store.clearTaintIfRequested`).
    public var freshSessionRequested: Bool = false
}

/// The facts about a session the engine compares on the next turn: where it ran, with which model and tools, and when and
/// how it last ended. Stored as JSON on the agent (base session) and as columns on `agentSession` (item sessions).
public struct SessionMeta: Codable, Equatable, Sendable {
    public var cwd: String?
    public var model: String?
    public var tools: String?
    public var endedAt: Double?
    public var lastTurnId: String?
    /// The frozen mount set (`ExtensionLibrary.mountSetHash`) of the session; a different set forces a fresh session.
    public var mountSetHash: String? = nil

    public init(cwd: String? = nil, model: String? = nil, tools: String? = nil, endedAt: Double? = nil, lastTurnId: String? = nil,
                mountSetHash: String? = nil) {
        self.cwd = cwd; self.model = model; self.tools = tools; self.endedAt = endedAt; self.lastTurnId = lastTurnId
        self.mountSetHash = mountSetHash
    }
}

/// Tie-break weight among a company's ready agents: leadership first. Reads the built-in role catalog.
public func roleWeight(_ role: String) -> Int { PackCatalog.builtin.roleWeight(role) }
