import Foundation

public enum TurnKind: String, Sendable, Equatable { case work, review, notice }

public struct ModelContext: Sendable, Equatable {
    public var decidingArchitecture = false
    public var decidingPRD = false
    public var turnKind: TurnKind = .work

    public init(decidingArchitecture: Bool = false, decidingPRD: Bool = false, turnKind: TurnKind = .work) {
        self.decidingArchitecture = decidingArchitecture
        self.decidingPRD = decidingPRD
        self.turnKind = turnKind
    }
}

public enum ModelPolicy {
    /// An explicit model is kept. `auto` picks opus for architecture and PRD decisions, sonnet for review turns,
    /// haiku for notice-only turns, and otherwise the role's default for the company's usage mode.
    public static func resolve(agentModel: String, role: RoleTemplate, mode: UsageMode, context: ModelContext) -> String {
        guard agentModel == "auto" else { return agentModel }
        if context.decidingArchitecture || context.decidingPRD { return "opus" }
        switch context.turnKind {
        case .review: return "sonnet"
        case .notice: return "haiku"
        case .work: return role.models[mode.rawValue] ?? "sonnet"
        }
    }
}
