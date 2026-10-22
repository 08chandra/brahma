import Foundation
import GRDB

public enum TurnOutcome: String, Codable, Sendable { case inProgress, succeeded, failed, usageLimited, interrupted }

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
    /// `work` (default), `review`, `audit`, `notice` or `plan` (Task 9 owns the enum; stored as its raw value).
    public var kind: String = "work"
    /// The work item this turn worked on (its lease, else its owned in-progress item); nil for turns without an item.
    public var itemId: String? = nil
    /// Set when the session no longer existed and the next turn starts over; such a turn is never counted (Task 10).
    public var sessionResetReason: String? = nil
    /// The session the result belongs to, and the raw `total_cost_usd` it reported. That total is cumulative over
    /// `--resume` (probe L-4), so `costUSD`/`costLE` hold this turn's own share: the total minus the previous total.
    public var sessionId: String? = nil
    public var sessionTotalUSD: Double? = nil
    public var inputTokens: Int = 0
    public var outputTokens: Int = 0
    public var cacheReadTokens: Int = 0
    public var cacheCreationTokens: Int = 0
    /// Digest of the turn's tool calls, for the loop guard of 14b.
    public var toolSignature: String? = nil
    /// Work modes (14c fills mode, rung, effort and modeReason; 14a records the rest).
    public var mode: String? = nil
    public var rung: Int? = nil
    public var effort: String? = nil
    public var modeReason: String? = nil
    /// `turnCap`, `budgetCap` or `sessionReset`: why the turn stopped when it was not an ordinary end.
    public var stopReason: String? = nil
    public var subagentsSpawned: Int = 0
    public var workflowAgents: Int = 0
    /// The result's `modelUsage` keys, comma-joined. Cumulative over `--resume`, so the audit compares it with the
    /// session's earlier turns.
    public var modelsUsed: String? = nil
    /// This turn's cost in `total_cost_usd` list-equivalent dollars.
    public var costLE: Double? = nil

    /// Tokens that count against a tier: input, output and cache creation. Cache reads are the same context re-read on
    /// every call and would charge a long conversation many times over, so they stay out.
    public var countedTokens: Int { inputTokens + outputTokens + cacheCreationTokens }
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
