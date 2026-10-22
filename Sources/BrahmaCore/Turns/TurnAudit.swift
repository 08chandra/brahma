import Foundation

/// What the engine expects the CLI to report for one turn. Nil on a `TurnRequest` means "no expectation" (Plan 1 turns);
/// the work-modes compiler (14c) fills it from the mode: no `Task` when sub-agents are off, `Workflow` only on Ultra.
public struct TurnExpectations: Equatable, Sendable {
    /// The exact set the init `agents` list must equal (nil: not checked).
    public var agents: Set<String>?
    /// Tools that must not be in the init `tools` list.
    public var forbiddenTools: Set<String>
    /// Tools that must be there.
    public var requiredTools: Set<String>
    /// Extra model ids a turn may bill besides its main and fallback model (a forced sub-agent worker).
    public var extraModels: Set<String>

    public init(agents: Set<String>? = nil, forbiddenTools: Set<String> = [], requiredTools: Set<String> = [],
                extraModels: Set<String> = []) {
        self.agents = agents; self.forbiddenTools = forbiddenTools; self.requiredTools = requiredTools
        self.extraModels = extraModels
    }
}

/// The engine's per-turn assertions (design §4.5.7 and §3.8.8).
public enum TurnAudit {
    /// The documented safety-fallback models: recorded, never alerted on.
    public static let safetyFallbackModels: Set<String> = ["claude-opus-5", "claude-opus-4-8"]

    /// Why the turn must be aborted right after its init line, or nil.
    public static func initViolation(_ info: InitInfo, expectations: TurnExpectations?) -> String? {
        guard let e = expectations else { return nil }
        if let agents = e.agents, Set(info.agents) != agents {
            let extra = Set(info.agents).subtracting(agents).sorted(), missing = agents.subtracting(info.agents).sorted()
            var parts: [String] = []
            if !extra.isEmpty { parts.append("unexpected agents \(extra.joined(separator: ", "))") }
            if !missing.isEmpty { parts.append("missing agents \(missing.joined(separator: ", "))") }
            return "the session lists " + parts.joined(separator: " and ")
        }
        let tools = Set(info.tools)
        let forbidden = tools.intersection(e.forbiddenTools).sorted()
        if !forbidden.isEmpty { return "the session offers tools this mode forbids: \(forbidden.joined(separator: ", "))" }
        let missing = e.requiredTools.subtracting(tools).sorted()
        if !missing.isEmpty { return "the session lacks tools this mode needs: \(missing.joined(separator: ", "))" }
        return nil
    }

    public struct Findings: Equatable, Sendable {
        /// `fast_mode_state` was not `off`, or `usage.speed` was not `standard`.
        public var fastMode: String?
        /// Models that billed and are neither the main model, the fallback, a forced worker nor a safety fallback.
        public var unexpectedModels: [String] = []
        /// Safety-fallback models that billed: recorded only.
        public var safetyFallbacks: [String] = []
        public var isClean: Bool { fastMode == nil && unexpectedModels.isEmpty }
    }

    /// `main` and `fallback` are the aliases or ids the request named (`sonnet`, `claude-sonnet-5-5`); `initModel` is the
    /// resolved id from the init line. `modelUsage` is cumulative over `--resume` (probe L-4), so `previouslySeen` names the
    /// models earlier turns of the same session already billed: they were judged then and are not judged again.
    public static func findings(result: TurnResult, initModel: String?, main: String, fallback: String,
                                expectations: TurnExpectations?, previouslySeen: Set<String> = []) -> Findings {
        var f = Findings()
        if let state = result.fastModeState, state != "off" { f.fastMode = "fast_mode_state is \(state)" }
        else if let speed = result.speed, speed != "standard" { f.fastMode = "usage.speed is \(speed)" }
        let allowed = [initModel, main, fallback].compactMap { $0?.lowercased() } + (expectations?.extraModels ?? []).map { $0.lowercased() }
        let seen = Set(previouslySeen.map { $0.lowercased() })
        for model in result.modelsUsed {
            let m = model.lowercased()
            if seen.contains(m) { continue }
            if safetyFallbackModels.contains(m) { f.safetyFallbacks.append(model); continue }
            if !allowed.contains(where: { matches(model: m, allowed: $0) }) { f.unexpectedModels.append(model) }
        }
        return f
    }

    /// `allowed` may be a full id or a family alias (`haiku`, `sonnet`, `opus`).
    static func matches(model: String, allowed: String) -> Bool {
        model == allowed || model.hasPrefix(allowed + "-") || model.contains("-\(allowed)-") || model.hasSuffix("-\(allowed)")
    }

    /// `Effort 'max' exceeds the cap` on stderr: the effort the engine asked for.
    public static func effortCap(in stderr: String) -> String? {
        guard let range = stderr.range(of: #"Effort '([A-Za-z]+)' exceeds the cap"#, options: .regularExpression) else { return nil }
        let line = stderr[range]
        guard let open = line.firstIndex(of: "'"), let close = line[line.index(after: open)...].firstIndex(of: "'") else { return nil }
        return String(line[line.index(after: open)..<close])
    }
}
