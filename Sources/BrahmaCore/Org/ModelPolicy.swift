import Foundation

public struct ModelContext: Sendable, Equatable {
    public var decidingArchitecture = false
    public var decidingPRD = false
    public var turnKind: TurnKind = .work
    /// A review of a tier L item or of one with review flags: worth the strongest model.
    public var deepReview = false

    public init(decidingArchitecture: Bool = false, decidingPRD: Bool = false, turnKind: TurnKind = .work, deepReview: Bool = false) {
        self.decidingArchitecture = decidingArchitecture
        self.decidingPRD = decidingPRD
        self.turnKind = turnKind
        self.deepReview = deepReview
    }
}

public enum ModelPolicy {
    /// An explicit model is kept. `auto` picks opus for architecture and PRD decisions, sonnet for review and audit turns (opus for tier L or flagged items),
    /// haiku for notice-only turns, and otherwise the role's default for the company's usage mode.
    public static func resolve(agentModel: String, role: RoleTemplate, mode: UsageMode, context: ModelContext) -> String {
        guard agentModel == "auto" else { return agentModel }
        if context.decidingArchitecture || context.decidingPRD { return "opus" }
        switch context.turnKind {
        case .review, .audit: return context.deepReview ? "opus" : "sonnet"
        case .notice: return "haiku"
        case .work, .plan: return role.models[mode.rawValue] ?? "sonnet"
        }
    }
}
