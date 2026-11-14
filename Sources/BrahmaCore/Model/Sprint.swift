import Foundation
import GRDB

/// How a sprint decides it is complete. Packs pick a default (`IndustryPack.defaultCadence`); a plan may name another.
public enum CadenceKind: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case sprint, milestone
}

/// The items a cadence looks at: everything committed to the sprint, and its milestone item (if any).
public struct SprintProgress: Equatable, Sendable {
    public var items: [WorkItem]
    public var milestoneItemId: String?

    public var done: Int { items.filter { $0.status == .done }.count }
    public var total: Int { items.count }
}

/// A completion rule. New cadences (stage-gates, ...) conform to this and are listed in `Cadences`.
public protocol Cadence: Sendable {
    var kind: CadenceKind { get }
    func isComplete(_ progress: SprintProgress) -> Bool
}

public enum Cadences {
    /// Complete when every committed item is done.
    public struct AllItems: Cadence {
        public var kind: CadenceKind { .sprint }
        public func isComplete(_ p: SprintProgress) -> Bool { !p.items.isEmpty && p.items.allSatisfy { $0.status == .done } }
    }

    /// Complete when the milestone item is done, whatever else is still open (it carries over).
    public struct Milestone: Cadence {
        public var kind: CadenceKind { .milestone }
        public func isComplete(_ p: SprintProgress) -> Bool {
            guard let id = p.milestoneItemId else { return false }
            return p.items.contains { $0.id == id && $0.status == .done }
        }
    }

    public static func of(_ kind: CadenceKind) -> any Cadence {
        switch kind {
        case .sprint: AllItems()
        case .milestone: Milestone()
        }
    }
}

public enum SprintStatus: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case pendingApproval, active, review, closed, rejected

    /// Statuses that hold the team's one open sprint.
    public static let open: [SprintStatus] = [.pendingApproval, .active, .review]
    public var isOpen: Bool { Self.open.contains(self) }
}

/// A timeboxed batch of committed work for a team (or, with no team, the company). Planned with `plan_sprint`, which files
/// a `sprintPlan` ask; approved → `active`; complete or past its timebox → `review`; `close_sprint` → `closed`.
public struct Sprint: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "sprint"

    /// Engine standups: one per this many company-active seconds of an active sprint.
    public static let standupInterval: TimeInterval = 86_400
    public static let defaultTimeboxDays = 5
    public static let defaultTimeboxTurns = 200
    static let day: TimeInterval = 86_400

    public var id: String
    public var companyId: String
    /// Per company: "Sprint <number>".
    public var number: Int
    /// nil: a company-wide sprint.
    public var team: String?
    public var goal: String
    public var cadence: CadenceKind
    public var status: SprintStatus
    public var milestoneItemId: String?
    /// The `sprintPlan` ask.
    public var askId: String?
    public var timeboxDays: Int = Sprint.defaultTimeboxDays
    public var timeboxTurns: Int = Sprint.defaultTimeboxTurns
    public var startedActive: Double?
    public var lastStandupActive: Double?
    public var createdAt: Date
    public var startedAt: Date?
    public var closedAt: Date?
    public var summary: String?
    /// Who planned it: the lead that is told when it completes or reaches its timebox.
    public var leadId: String?
    /// Who closed it and so wrote its summary (`actor.id`: an agent id or `"owner"`); nil for sprints closed before Plan ML
    /// recorded it (their summary's author is unknown, and treated as untrusted).
    public var closedById: String? = nil

    public var name: String { "Sprint \(number)" }
    /// "core" or "company".
    public var scopeLabel: String { team ?? "company" }
}
