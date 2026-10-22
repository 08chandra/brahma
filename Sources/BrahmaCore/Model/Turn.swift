import Foundation
import GRDB

public enum TurnOutcome: String, Codable, Sendable { case inProgress, succeeded, failed, usageLimited, interrupted }

/// What a turn is for. Stored on the turn (a notice-only turn is stored `notice`) and used by `ModelContext`.
public enum TurnKind: String, Codable, CaseIterable, Sendable, Equatable, DatabaseValueConvertible {
    case work, review, audit, notice, plan

    /// Kinds that look at finished work: they run clean-context, with no `Task`/`Agent`/`Workflow` tools.
    public var isReview: Bool { self == .review || self == .audit }
}

public struct Turn: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "turn"

    public var id: String
    public var agentId: String
    public var companyId: String
    public var startedAt: Date
    public var endedAt: Date?
    public var outcome: TurnOutcome
    public var summary: String?
    public var costUSD: Double?
    /// True when the turn failed for infrastructure reasons (network, account); never counted against the agent.
    public var infra: Bool = false
    public var kind: TurnKind = .work
    /// The item a turn is about: the item of a review, plan or item-session work turn; nil for base-session turns.
    public var itemId: String? = nil
    /// Set when the session this turn used no longer existed ("session not found"): the turn is ignored by budgets, the
    /// watchdog and facts, and the agent is ready again at once.
    public var sessionResetReason: String? = nil
    /// The last `STATUS:` line of the turn's result (`DONE`, `DONE_WITH_CONCERNS`, `BLOCKED`, `NEEDS_CONTEXT`).
    public var reportedStatus: String? = nil
    /// Why the prompt cache broke on a resume: the model or the tool set changed.
    public var cacheBreak: String? = nil
}

public enum ActivityKind: String, Codable, Sendable { case stateChanged, message, toolUse, turnStarted, turnFinished, usage, error, work, approval }

public struct ActivityEvent: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "activityEvent"

    public var id: Int64?
    public var companyId: String
    public var agentId: String?
    public var turnId: String?
    public var kind: ActivityKind
    public var text: String
    public var createdAt: Date

    public init(id: Int64? = nil, companyId: String, agentId: String?, turnId: String?, kind: ActivityKind, text: String, createdAt: Date) {
        self.id = id; self.companyId = companyId; self.agentId = agentId; self.turnId = turnId
        self.kind = kind; self.text = text; self.createdAt = createdAt
    }
}
