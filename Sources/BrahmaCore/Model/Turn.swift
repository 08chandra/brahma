import Foundation
import GRDB

public enum TurnOutcome: String, Codable, Sendable { case inProgress, succeeded, failed, usageLimited, interrupted }

/// What a turn is for. Stored on the turn (a notice-only turn is stored `notice`) and used by `ModelContext`.
public enum TurnKind: String, Codable, CaseIterable, Sendable, Equatable, DatabaseValueConvertible {
    case work, review, audit, notice, plan
    /// Plan C Task C4c: an itemless turn that answers the owner's show request(s) only (`ShowTurnCaps`); the rest of the
    /// agent's inbox waits for its next ordinary turn.
    case show

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
    /// Set when the turn started a fresh session on purpose ("mounts changed", a Task 10 reset): a counted work turn, unlike a
    /// `sessionResetReason` turn (Task 5a fix round 1, B-I3).
    public var freshSessionReason: String? = nil
    /// When the turn first read outside content, and what it was (`TaintPolicy.source`; Task 10).
    public var taintedAt: Date? = nil
    public var taintSource: String? = nil
    /// The last `STATUS:` line of the turn's result (`DONE`, `DONE_WITH_CONCERNS`, `BLOCKED`, `NEEDS_CONTEXT`).
    public var reportedStatus: String? = nil
    /// Why the prompt cache broke on a resume: the model or the tool set changed.
    public var cacheBreak: String? = nil
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
    /// The turn's process (the CLI it spawned), recorded right after the spawn (`StreamEvent.spawned`, `v5-owner-guard`).
    public var pid: Int32? = nil

    /// Tokens that count against a tier: input, output and cache creation. Cache reads are the same context re-read on
    /// every call and would charge a long conversation many times over, so they stay out.
    public var countedTokens: Int { inputTokens + outputTokens + cacheCreationTokens }
}

/// What an activity line is about. `preview` and `release` are Plan L's (preview surfaces; releases and deploys); `resource`
/// is Plan ML's (owner resources added, vouched, rescoped or purged); `merge` is Plan 4a's (the merge queue landed an item).
public enum ActivityKind: String, Codable, Sendable {
    case stateChanged, message, toolUse, turnStarted, turnFinished, usage, error, work, approval, preview, release, resource, merge
    /// Plan C: shares, access decisions and refusals (vouches, purges), exports and show requests.
    case share, access, export, show
}

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
