import Foundation
import BrahmaCore

public enum ActivityFilter: String, CaseIterable, Sendable {
    case all, messages, turns, states, work, problems
    /// Plan C: shares, access decisions and refusals, exports and show requests (design §4.7).
    case sharing

    public var title: String {
        switch self {
        case .all: "All"
        case .messages: "Messages"
        case .turns: "Turns"
        case .states: "State changes"
        case .work: "Work"
        case .problems: "Problems"
        case .sharing: "Sharing"
        }
    }

    public func includes(_ k: ActivityKind) -> Bool {
        switch self {
        case .all: true
        case .messages: k == .message
        case .turns: k == .turnStarted || k == .turnFinished || k == .toolUse
        case .states: k == .stateChanged
        case .work: k == .work || k == .approval || k == .preview || k == .release || k == .resource || k == .merge
        case .problems: k == .usage || k == .error
        case .sharing: k == .share || k == .access || k == .export || k == .show
        }
    }
}

public enum ActivityText {
    public static func line(_ e: ActivityEvent, handles: [String: String]) -> String {
        guard e.kind == .stateChanged, let id = e.agentId else { return e.text }
        return "@\(handles[id] ?? id) " + e.text.replacingOccurrences(of: " -> ", with: " → ")
    }
}

public enum AgentBadge {
    public static func label(_ a: Agent) -> String {
        if a.state == .killed { return "killed" }
        if a.state == .running && a.paused { return "running (pausing)" }
        if a.paused { return "paused" }
        return a.state.rawValue
    }
}
