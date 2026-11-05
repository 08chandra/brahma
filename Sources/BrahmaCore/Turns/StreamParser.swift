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

public enum StreamEvent: Equatable, Sendable {
    case initialized(sessionId: String, model: String)
    /// The rest of the init line (tools, agents), right after `.initialized`.
    case initInfo(InitInfo)
    case assistantText(String)
    /// One `tool_use` block. `inputDigest` is a hash of the input with keys sorted, so key order never matters.
    case toolUse(name: String, inputDigest: String)
    /// The same `tool_use` block with its input (Task 10's backup taint), right after its `.toolUse`; a sub-agent's blocks (they
    /// carry `parent_tool_use_id`) too. A name-only event (`task_progress.last_tool_name`, `workflow_progress[].lastToolName`)
    /// has an empty input.
    case toolCall(name: String, input: [String: JSONValue])
    /// One `tool_result` block: a hash of its content (and error flag).
    case toolResult(digest: String)
    case rateLimit(RateLimitInfo)
    case result(TurnResult)
    /// Fan-out: a sub-agent or workflow started (`task_started`).
    case taskStarted(taskId: String, taskType: String?, spawnDepth: Int?)
    /// `task_progress`, with the workflow's agents when it carried `workflow_progress`.
    case taskProgress(taskId: String, totalTokens: Int?, toolUses: Int?, agents: [WorkflowAgentInfo])
    case taskNotification(taskId: String, status: String?)
    /// `background_tasks_changed`: the full list of tasks still running.
    case backgroundTasks(taskIds: [String])
    /// Produced by the runner from stderr: `Effort '<x>' exceeds the cap`.
    case effortCapped(requested: String)
    /// Produced by the runner: something about the turn's sandbox the engine should log (a grant read path dropped at spawn).
    case sandboxNote(String)
    /// Produced by the runner right after it started the CLI: the turn's process (Task 3, `Store.setTurnPid`).
    case spawned(pid: Int32)
    /// Produced by the runner only when the request asks for it (`TurnRequest.emitRawLines`, the sandbox canary): one stdout
    /// line as printed, before its parsed events.
    case raw(String)
    case other(type: String)
}

/// Turns one line of `claude -p --output-format stream-json --verbose` output into typed events.
public enum StreamParser {
    /// The first event of the line (the one-event API).
    public static func parse(line: String, now: Date = .now) -> StreamEvent? {
        parseAll(line: line, now: now)?.first
    }

    /// Every event on the line: all `tool_use` blocks of an assistant message, all `tool_result` blocks of a user message,
    /// the init line's details. Nil when the line is not JSON.
    public static func parseAll(line: String, now: Date = .now) -> [StreamEvent]? {
        guard let object = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
              let type = object["type"] as? String else {
            return nil
        }
        switch type {
        case "system":
            return parseSystem(object)
        case "assistant":
            return parseAssistant(object)
        case "user":
            let results = parseToolResults(object)
            return results.isEmpty ? [.other(type: type)] : results
        case "rate_limit_event":
            return [parseRateLimit(object, now: now)]
        case "result":
            return [parseResult(object)]
        default:
            return [.other(type: type)]
        }
    }

    private static func parseSystem(_ object: [String: Any]) -> [StreamEvent] {
        let other: [StreamEvent] = [.other(type: "system")]
        switch object["subtype"] as? String {
        case "init":
            guard let sessionId = object["session_id"] as? String, let model = object["model"] as? String else { return other }
            let info = InitInfo(sessionId: sessionId, model: model,
                                tools: (object["tools"] as? [Any])?.compactMap { $0 as? String } ?? [],
                                agents: (object["agents"] as? [Any])?.compactMap { $0 as? String } ?? [],
                                skills: (object["skills"] as? [Any])?.compactMap { $0 as? String } ?? [])
            return [.initialized(sessionId: sessionId, model: model), .initInfo(info)]
        case "task_started":
            guard let id = object["task_id"] as? String else { return other }
            return [.taskStarted(taskId: id, taskType: object["task_type"] as? String,
                                 spawnDepth: (object["spawn_depth"] as? NSNumber)?.intValue)]
        case "task_progress":
            guard let id = object["task_id"] as? String else { return other }
            let usage = object["usage"] as? [String: Any]
            let agents: [WorkflowAgentInfo] = (object["workflow_progress"] as? [[String: Any]] ?? []).compactMap { a in
                guard (a["type"] as? String ?? "workflow_agent") == "workflow_agent" else { return nil }
                // A queued agent has no `agentId` yet; it counts once it starts.
                guard let agentId = a["agentId"] as? String else { return nil }
                return WorkflowAgentInfo(agentId: agentId, label: a["label"] as? String, state: a["state"] as? String,
                                         tokens: (a["tokens"] as? NSNumber)?.intValue)
            }
            // The sub-agent's or workflow agents' latest tool, by name only (Task 10's backup taint reads it).
            var names: [String] = []
            if let last = object["last_tool_name"] as? String { names.append(last) }
            for a in object["workflow_progress"] as? [[String: Any]] ?? [] {
                if let last = a["lastToolName"] as? String, !names.contains(last) { names.append(last) }
            }
            return [.taskProgress(taskId: id, totalTokens: (usage?["total_tokens"] as? NSNumber)?.intValue,
                                  toolUses: (usage?["tool_uses"] as? NSNumber)?.intValue, agents: agents)]
                + names.map { .toolCall(name: $0, input: [:]) }
        case "task_notification":
            guard let id = object["task_id"] as? String else { return other }
            return [.taskNotification(taskId: id, status: object["status"] as? String)]
        case "background_tasks_changed":
            let tasks = object["tasks"] as? [[String: Any]] ?? []
            return [.backgroundTasks(taskIds: tasks.compactMap { $0["task_id"] as? String })]
        default:
            return other
        }
    }

    private static func parseAssistant(_ object: [String: Any]) -> [StreamEvent] {
        let blocks = (object["message"] as? [String: Any])?["content"] as? [[String: Any]] ?? []
        let uses: [StreamEvent] = blocks.flatMap { block -> [StreamEvent] in
            guard block["type"] as? String == "tool_use", let name = block["name"] as? String else { return [] }
            return [.toolUse(name: name, inputDigest: digest(of: block["input"] ?? [String: Any]())),
                    .toolCall(name: name, input: JSONValue.from(block["input"]).objectValue ?? [:])]
        }
        if !uses.isEmpty { return uses }
        let text = blocks
            .filter { $0["type"] as? String == "text" }
            .compactMap { $0["text"] as? String }
            .joined()
        return [text.isEmpty ? .other(type: "assistant") : .assistantText(text)]
    }

    private static func parseToolResults(_ object: [String: Any]) -> [StreamEvent] {
        let content = (object["message"] as? [String: Any])?["content"]
        guard let blocks = content as? [[String: Any]] else { return [] }
        return blocks.compactMap { block in
            guard block["type"] as? String == "tool_result" else { return nil }
            let isError = block["is_error"] as? Bool ?? false
            return .toolResult(digest: digest(of: ["error": isError, "content": block["content"] ?? ""] as [String: Any]))
        }
    }

    /// FNV-1a of the JSON with sorted keys.
    static func digest(of value: Any) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys, .fragmentsAllowed])) ?? Data()
        return StableHash.fnv1a64(data)
    }

    private static func parseRateLimit(_ object: [String: Any], now: Date) -> StreamEvent {
        let info = object["rate_limit_info"] as? [String: Any] ?? [:]
        let windows = info["unifiedWindows"] as? [String: Any] ?? [:]
        let fiveHour = windows["five_hour"] as? [String: Any]
        let sevenDay = windows["seven_day"] as? [String: Any]
        return .rateLimit(RateLimitInfo(
            status: info["status"] as? String ?? "unknown",
            resetsAt: number(info["resetsAt"]).map { Date(timeIntervalSince1970: $0) },
            rateLimitType: info["rateLimitType"] as? String,
            isUsingOverage: info["isUsingOverage"] as? Bool ?? false,
            fiveHourUtilization: number(fiveHour?["utilization"]),
            sevenDayUtilization: number(sevenDay?["utilization"]),
            observedAt: now,
            fiveHourResetsAt: number(fiveHour?["resetsAt"]).map { Date(timeIntervalSince1970: $0) },
            sevenDayResetsAt: number(sevenDay?["resetsAt"]).map { Date(timeIntervalSince1970: $0) },
            overageStatus: info["overageStatus"] as? String
        ))
    }

    private static func parseResult(_ object: [String: Any]) -> StreamEvent {
        // An error result may carry no `result` text, only `errors` (e.g. "No conversation found with session ID").
        let errors = (object["errors"] as? [Any])?.compactMap { $0 as? String } ?? []
        let usageObject = object["usage"] as? [String: Any]
        func tokens(_ key: String) -> Int { (usageObject?[key] as? NSNumber)?.intValue ?? 0 }
        let usage = usageObject.map { _ in
            TurnUsage(inputTokens: tokens("input_tokens"), outputTokens: tokens("output_tokens"),
                      cacheReadTokens: tokens("cache_read_input_tokens"), cacheCreationTokens: tokens("cache_creation_input_tokens"))
        }
        let modelUsage = object["modelUsage"] as? [String: Any] ?? [:]
        return .result(TurnResult(
            isError: object["is_error"] as? Bool ?? false,
            subtype: object["subtype"] as? String ?? "",
            text: object["result"] as? String ?? (errors.isEmpty ? nil : errors.joined(separator: "; ")),
            costUSD: number(object["total_cost_usd"]),
            apiErrorStatus: (object["api_error_status"] as? NSNumber)?.intValue,
            sessionId: object["session_id"] as? String ?? "",
            hasUsage: usageObject != nil,
            usage: usage,
            terminalReason: object["terminal_reason"] as? String,
            fastModeState: object["fast_mode_state"] as? String,
            speed: usageObject?["speed"] as? String,
            modelsUsed: modelUsage.keys.sorted(),
            subagentsSpawned: ((object["subagent_stats"] as? [String: Any])?["spawned"] as? NSNumber)?.intValue
        ))
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}
