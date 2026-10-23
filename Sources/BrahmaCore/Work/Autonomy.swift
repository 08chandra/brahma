import Foundation
import GRDB

/// How much the owner wants to be asked.
public enum AutonomyPreset: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case everything, important, auto

    public var title: String {
        switch self {
        case .everything: "Ask me everything"
        case .important: "Ask me what matters"
        case .auto: "Auto"
        }
    }
}

/// What the owner does with an ask: approve it, or only be told (FYI).
public enum OwnerRole: String, Sendable, Equatable { case approve, fyi }

public enum AutonomyPolicy {
    /// The table, in order:
    /// ```
    /// reserved category (any kind)       → approve under every preset
    /// info, engineAlert, reserved kinds  → approve (needs the owner) under every preset
    /// goal-changing decision             → approve under every preset
    /// everything:  every decision kind   → approve
    /// important:   prd, architecture, release → approve; sprintPlan → fyi; other, boost → risk == .high ? approve : fyi
    /// auto:        every decision kind   → fyi
    /// ```
    public static func ownerRole(kind: AskKind, risk: AskRisk, category: String?, preset: AutonomyPreset, pack: IndustryPack?,
                                 decisionClass: DecisionClass = .taste) -> OwnerRole {
        ownerRole(kind: kind, risk: risk, category: category, preset: preset, extraReserved: pack?.reservedCategories ?? [],
                  decisionClass: decisionClass)
    }

    static func ownerRole(kind: AskKind, risk: AskRisk, category: String?, preset: AutonomyPreset, extraReserved: [String],
                          decisionClass: DecisionClass = .taste) -> OwnerRole {
        if ReservedMatters.isReserved(category, extra: extraReserved) { return .approve }
        if !kind.isDecision || kind.isReservedKind { return .approve }
        if decisionClass == .goalChanging { return .approve }
        switch preset {
        case .everything: return .approve
        case .auto: return .fyi
        case .important:
            switch kind {
            case .prd, .architecture, .release: return .approve
            case .sprintPlan: return .fyi
            default: return risk == .high ? .approve : .fyi
            }
        }
    }
}
