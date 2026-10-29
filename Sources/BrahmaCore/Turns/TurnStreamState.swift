import Foundation

/// What a turn's event stream adds up to. The runner and the orchestrator both feed it, so a turn is read one way:
/// - several `system/init` and `result` events are accepted; the **last** result is the outcome, and the token usage of
///   all results is summed (each result reports the usage since the previous one, `total_cost_usd` is cumulative);
/// - background work (workflows, sub-agents) is tracked: a process that ends while it is pending did not finish the turn,
///   whatever result it printed early.
public struct TurnStreamState: Equatable, Sendable {
    public private(set) var inits: [InitInfo] = []
    public private(set) var result: TurnResult?
    public private(set) var resultCount = 0
    /// Task ids started and not yet finished (`task_started` / `task_notification` / `background_tasks_changed`).
    public private(set) var pendingTasks: Set<String> = []
    /// Sub-agents and other non-workflow tasks started, by id.
    public private(set) var subagentIds: Set<String> = []
    /// Distinct workflow agents seen in `workflow_progress`.
    public private(set) var workflowAgentIds: Set<String> = []
    public private(set) var maxSpawnDepth = 0
    /// Every tool call (name and input digest) and tool result digest, in order.
    public private(set) var toolCalls: [String] = []
    public private(set) var toolResults: [String] = []
    public private(set) var effortCapRequested: String?

    public init() {}

    public var hasPendingWork: Bool { !pendingTasks.isEmpty }
    public var sawResult: Bool { result != nil }

    /// Hash of the ordered tool calls of the turn (name and input digest), for the loop guard.
    public var toolSignature: String? {
        toolCalls.isEmpty ? nil : StableHash.fnv1a64(toolCalls.joined(separator: "\n"))
    }

    /// What the watchdog's loop guard reads from the turn.
    public var observation: TurnObservation {
        TurnObservation(maxRepeatedCall: TurnObservation.longestRun(toolCalls),
                        maxRepeatedResult: TurnObservation.longestRun(toolResults), signature: toolSignature)
    }

    /// Sub-agents the turn spawned: the CLI's own count when the result carries one, else the tasks seen.
    public var subagentsSpawned: Int { max(result?.subagentsSpawned ?? 0, subagentIds.count) }

    public mutating func apply(_ event: StreamEvent) {
        switch event {
        case .initInfo(let info):
            inits.append(info)
        case .toolUse(let name, let digest):
            toolCalls.append("\(name):\(digest)")
        case .toolResult(let digest):
            toolResults.append(digest)
        case .result(var r):
            let earlier = result?.usage
            if let u = r.usage, let earlier { r.usage = earlier + u }
            else if r.usage == nil { r.usage = earlier }
            result = r
            resultCount += 1
        case .taskStarted(let id, let type, let depth):
            pendingTasks.insert(id)
            if type != "local_workflow" { subagentIds.insert(id) }
            if let depth { maxSpawnDepth = max(maxSpawnDepth, depth) }
        case .taskProgress(_, _, _, let agents):
            for a in agents { workflowAgentIds.insert(a.agentId) }
        case .taskNotification(let id, _):
            pendingTasks.remove(id)
        case .backgroundTasks(let ids):
            pendingTasks = Set(ids)
        case .effortCapped(let requested):
            effortCapRequested = requested
        case .initialized, .assistantText, .rateLimit, .other, .sandboxNote:
            break
        }
    }
}
