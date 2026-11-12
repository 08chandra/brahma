import Foundation

/// Where a piece of company knowledge came from: the owner, an agent, the engine itself, or something outside the company
/// (a web page, a dropped file). Stored as `raw` (`owner`, `agent:<id>`, `engine`, `external:<detail>`).
public enum Provenance: Codable, Hashable, Sendable {
    case owner
    case agent(String)
    case engine
    case external(String)

    public var raw: String {
        switch self {
        case .owner: "owner"
        case .agent(let id): "agent:\(id)"
        case .engine: "engine"
        case .external(let detail): "external:\(detail)"
        }
    }

    public init?(raw: String) {
        switch raw {
        case "owner": self = .owner
        case "engine": self = .engine
        default:
            if raw.hasPrefix("agent:"), raw.count > "agent:".count {
                self = .agent(String(raw.dropFirst("agent:".count)))
            } else if raw.hasPrefix("external:") {
                self = .external(String(raw.dropFirst("external:".count)))
            } else {
                return nil
            }
        }
    }
}
