import Foundation
import BrahmaCore

public enum FormError: Error, Equatable { case invalid(String) }

/// The sheet over the main window. `id` is stable: each case that was once a `String` raw value keeps that string.
public enum AppSheet: Identifiable, Hashable, Sendable {
    case newCompany, hire, newItem
    /// The owner adds an open seat under `managerHandle`, or under the Board when nil (Plan 4b, the map's context menu).
    case vacancy(managerHandle: String?)
    /// The owner fills the open seat `handle` (the map's cleaned vacancy id), after the paid-agent preview.
    case fillVacancy(handle: String)

    public var id: String {
        switch self {
        case .newCompany: "newCompany"
        case .hire: "hire"
        case .newItem: "newItem"
        case .vacancy(let managerHandle): "vacancy:\(managerHandle ?? "board")"
        case .fillVacancy(let handle): "fill:\(handle)"
        }
    }

    /// Bound to the company (and map) it was opened for: dismissed when the selected company changes.
    var isCompanyBound: Bool {
        switch self {
        case .vacancy, .fillVacancy: true
        case .newCompany, .hire, .newItem: false
        }
    }
}

/// What a new company's org would look like, before anything is created.
public struct OrgPreview: Equatable, Sendable {
    /// The full org tree, one line per agent (vacant seats marked), exactly as `brahma company create --dry-run` prints it.
    public var lines: [String]
    public var total: Int
    /// Agents hired now; the rest are vacancies filled when work calls for them.
    public var seated: Int
    public var vacant: Int
    /// "Org sizes over 50 are experimental." when it applies.
    public var warning: String?
}

public struct CompanyForm: Equatable, Sendable {
    public var name = ""
    public var goal = ""
    /// Agents in the full org shape: 0 for an empty company, otherwise 5 to 500.
    public var agentCount = 6
    public var packId = "software"
    public var usageMode: UsageMode = .balanced

    public static let agentCountMessage = "Agents must be 0 (add them later) or 5–500"
    public static let experimentalThreshold = 50
    public static let experimentalWarning = "Org sizes over 50 are experimental."

    public init(name: String = "", goal: String = "", agentCount: Int = 6, packId: String = "software") {
        self.name = name
        self.goal = goal
        self.agentCount = agentCount
        self.packId = packId
    }

    public var warning: String? { agentCount > Self.experimentalThreshold ? Self.experimentalWarning : nil }

    public func validate() -> String? {
        if name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Name is required" }
        if goal.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return "Goal is required" }
        if agentCount != 0, !OrgGenerator.range.contains(agentCount) { return Self.agentCountMessage }
        return nil
    }

    /// The org this form would create, from the same generator and staffing the store uses. Nil for an empty company or a
    /// count out of range; `seatBudget` is `Store.seatBudget()` (the plan tier).
    public func preview(catalog: PackCatalog, seatBudget: Int = PlanTier.max5x.seatBudget) -> OrgPreview? {
        guard agentCount > 0, OrgGenerator.range.contains(agentCount), let pack = catalog.pack(packId) else { return nil }
        guard let plan = try? OrgGenerator.generate(goal: goal, count: agentCount, pack: pack) else { return nil }
        let staffed = OrgGenerator.staff(plan: plan, pack: pack, readyWidth: 0, seatBudget: seatBudget)
        return OrgPreview(lines: plan.treeLines(vacant: Set(staffed.vacancies.map(\.handle))), total: plan.agents.count,
                          seated: staffed.seated.agents.count, vacant: staffed.vacancies.count, warning: warning)
    }
}
