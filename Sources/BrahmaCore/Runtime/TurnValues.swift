import Foundation

public struct RateLimitInfo: Codable, Equatable, Sendable {
    public var status: String
    public var resetsAt: Date?
    public var rateLimitType: String?
    public var isUsingOverage: Bool
    public var fiveHourUtilization: Double?
    public var sevenDayUtilization: Double?
    public var observedAt: Date
    /// Per-window resets (`unifiedWindows.<window>.resetsAt`). The top-level `resetsAt` belongs to whichever
    /// window `rateLimitType` names, so the five-hour threshold rule must use `fiveHourResetsAt`.
    public var fiveHourResetsAt: Date?
    public var sevenDayResetsAt: Date?
    /// `allowed` when the account may spill into paid overage (doctor warns on it).
    public var overageStatus: String? = nil

    public init(status: String, resetsAt: Date?, rateLimitType: String?, isUsingOverage: Bool,
                fiveHourUtilization: Double?, sevenDayUtilization: Double?, observedAt: Date,
                fiveHourResetsAt: Date? = nil, sevenDayResetsAt: Date? = nil, overageStatus: String? = nil) {
        self.overageStatus = overageStatus
        self.status = status
        self.resetsAt = resetsAt
        self.rateLimitType = rateLimitType
        self.isUsingOverage = isUsingOverage
        self.fiveHourUtilization = fiveHourUtilization
        self.sevenDayUtilization = sevenDayUtilization
        self.observedAt = observedAt
        self.fiveHourResetsAt = fiveHourResetsAt
        self.sevenDayResetsAt = sevenDayResetsAt
    }
}

/// Token counts of one turn (the result's `usage`, summed over a turn's results).
public struct TurnUsage: Codable, Equatable, Sendable {
    public var inputTokens: Int
    public var outputTokens: Int
    public var cacheReadTokens: Int
    public var cacheCreationTokens: Int

    public init(inputTokens: Int = 0, outputTokens: Int = 0, cacheReadTokens: Int = 0, cacheCreationTokens: Int = 0) {
        self.inputTokens = inputTokens; self.outputTokens = outputTokens
        self.cacheReadTokens = cacheReadTokens; self.cacheCreationTokens = cacheCreationTokens
    }

    /// What tier budgets count: input, output and cache creation. Cache reads re-read the same context on every call
    /// and would charge a long conversation many times over.
    public var counted: Int { inputTokens + outputTokens + cacheCreationTokens }

    public static func + (a: TurnUsage, b: TurnUsage) -> TurnUsage {
        TurnUsage(inputTokens: a.inputTokens + b.inputTokens, outputTokens: a.outputTokens + b.outputTokens,
                  cacheReadTokens: a.cacheReadTokens + b.cacheReadTokens,
                  cacheCreationTokens: a.cacheCreationTokens + b.cacheCreationTokens)
    }
}

public struct TurnResult: Equatable, Sendable {
    public var isError: Bool
    public var subtype: String
    public var text: String?
    /// The result's `total_cost_usd`. Per process for a fresh session but **cumulative over `--resume`** (probe L-4):
    /// a turn's own cost is this total minus the session's previous total (`Store.endTurn` does that subtraction).
    public var costUSD: Double?
    public var apiErrorStatus: Int?
    public var sessionId: String
    /// The result line carried a `usage` object.
    public var hasUsage: Bool = false
    public var usage: TurnUsage? = nil
    /// The result's `terminal_reason` (`completed`, `max_turns`, `budget_exhausted`, ...).
    public var terminalReason: String? = nil
    /// `fast_mode_state` and `usage.speed`: the engine asserts `off` and `standard` on every turn.
    public var fastModeState: String? = nil
    public var speed: String? = nil
    /// The keys of `modelUsage` (every model that billed during the turn).
    public var modelsUsed: [String] = []
    /// `subagent_stats.spawned`.
    public var subagentsSpawned: Int? = nil

    public init(isError: Bool, subtype: String, text: String?, costUSD: Double?,
                apiErrorStatus: Int?, sessionId: String, hasUsage: Bool = false, usage: TurnUsage? = nil,
                terminalReason: String? = nil, fastModeState: String? = nil, speed: String? = nil,
                modelsUsed: [String] = [], subagentsSpawned: Int? = nil) {
        self.hasUsage = hasUsage
        self.isError = isError
        self.subtype = subtype
        self.text = text
        self.costUSD = costUSD
        self.apiErrorStatus = apiErrorStatus
        self.sessionId = sessionId
        self.usage = usage
        self.terminalReason = terminalReason
        self.fastModeState = fastModeState
        self.speed = speed
        self.modelsUsed = modelsUsed
        self.subagentsSpawned = subagentsSpawned
    }

    /// `turnCap` / `budgetCap` when the engine's own caps ended the turn (a controlled stop, not a failure), else nil.
    public var stopReason: String? { TurnStop.reason(forSubtype: subtype) }
}

/// Controlled stops: the engine's own `--max-turns` and `--max-budget-usd` caps doing their job.
public enum TurnStop {
    public static let turnCap = "turnCap"
    public static let budgetCap = "budgetCap"
    /// The next turn starts a fresh session; the failed one is not counted.
    public static let sessionReset = "sessionReset"

    public static func reason(forSubtype subtype: String) -> String? {
        switch subtype {
        case "error_max_turns": turnCap
        case "error_max_budget_usd": budgetCap
        default: nil
        }
    }
}

/// What the `system/init` line says about the session, for the engine's per-turn assertions.
public struct InitInfo: Equatable, Sendable {
    public var sessionId: String
    public var model: String
    public var tools: [String]
    public var agents: [String]
    /// The init line's `skills` (namespaced `<plugin>:<skill>` for mounted extensions; 10b records them for `ext try`).
    public var skills: [String] = []

    public init(sessionId: String, model: String, tools: [String], agents: [String], skills: [String] = []) {
        self.sessionId = sessionId; self.model = model; self.tools = tools; self.agents = agents; self.skills = skills
    }
}

/// One agent of a workflow, from `task_progress.workflow_progress[]`.
public struct WorkflowAgentInfo: Equatable, Sendable {
    public var agentId: String
    public var label: String?
    public var state: String?
    public var tokens: Int?

    public init(agentId: String, label: String? = nil, state: String? = nil, tokens: Int? = nil) {
        self.agentId = agentId; self.label = label; self.state = state; self.tokens = tokens
    }
}
