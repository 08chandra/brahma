import Foundation
import BrahmaCore

public enum AgentModelChoice: String, CaseIterable, Sendable {
    /// The engine picks the model for each turn from the work (the default for pack roles).
    case auto, opus, sonnet, haiku

    public var title: String {
        switch self {
        case .auto: "Auto"
        case .opus: "Opus"
        case .sonnet: "Sonnet"
        case .haiku: "Haiku"
        }
    }
}

public struct HireForm: Equatable, Sendable {
    public var handle = ""
    public var role = "engineer"
    public var model: AgentModelChoice = .sonnet

    public static let roleSuggestions = ["ceo", "cto", "cpo", "architect", "manager", "engineer", "designer", "qa"]

    /// The role ids of the company's industry pack, falling back to the built-in suggestions.
    public static func roles(catalog: PackCatalog, packId: String) -> [String] {
        guard let pack = catalog.pack(packId), !pack.roles.isEmpty else { return roleSuggestions }
        return pack.roles.map(\.id)
    }

    public init(handle: String = "", role: String = "engineer", model: AgentModelChoice = .sonnet) {
        self.handle = handle
        self.role = role
        self.model = model
    }

    /// Trimmed, leading "@" dropped, lowercased.
    public var normalizedHandle: String {
        var h = handle.trimmingCharacters(in: .whitespacesAndNewlines)
        if h.hasPrefix("@") { h.removeFirst() }
        return h.lowercased()
    }

    public var trimmedRole: String { role.trimmingCharacters(in: .whitespacesAndNewlines) }

    public static let formatMessage = "Handles use a–z, 0–9, - and _ (up to 32, starting with a letter or digit)"

    public func validate(existingHandles: Set<String>) -> String? {
        let h = normalizedHandle
        if h.isEmpty { return "Handle is required" }
        if h == "owner" { return "@owner is reserved" }
        if h.range(of: "^[a-z0-9][a-z0-9_-]{0,31}$", options: .regularExpression) == nil { return Self.formatMessage }
        if existingHandles.contains(h) { return "@\(h) already exists" }
        if trimmedRole.isEmpty { return "Role is required" }
        return nil
    }
}
