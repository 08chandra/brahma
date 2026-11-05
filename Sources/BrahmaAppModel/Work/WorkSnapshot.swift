import Foundation
import BrahmaCore

/// One org-chart problem the owner should see (an over-span manager, a company with no root).
public struct OrgIssueRow: Equatable, Sendable, Identifiable {
    public var id: Int64
    public var kind: String
    public var detail: String
    public var agentId: String?

    public init(id: Int64, kind: String, detail: String, agentId: String? = nil) {
        self.id = id; self.kind = kind; self.detail = detail; self.agentId = agentId
    }
}

/// The selected company's work, Inbox and health, read in one pass.
public struct WorkSnapshot: Equatable, Sendable {
    /// Recent decisions stay rescindable this long.
    public static let recentDays = 14

    public var items: [WorkItem] = []
    /// Item id → its newest check run.
    public var latestRuns: [String: VerificationRun] = [:]
    public var leases: [WorkLease] = []
    /// Sprints that hold the team's one open sprint: pending approval, active and in review.
    public var openSprints: [Sprint] = []
    /// Asks waiting for the owner.
    public var inbox: [Ask] = []
    /// Policy-approved asks the owner has not acknowledged yet.
    public var fyi: [Ask] = []
    /// Approved in the last 14 days (acknowledged FYIs included): the owner can still rescind them.
    public var recentDecided: [Ask] = []
    public var stall = StallReport(running: 0, reasons: [])
    public var hold: EngineHold?
    public var orgIssues: [OrgIssueRow] = []
    public var totalItems = 0
    public var truncated = false
    /// Ask id → kind title as shown to the owner ("Brief & architecture" for a PRD in a small company).
    public var displayTitles: [String: String] = [:]
    /// Pending asks whose document changed since it was proposed.
    public var changedDocuments: Set<String> = []
    /// The pack's extra reserved categories.
    public var reservedCategories: [String] = []
    /// The 7-day pace, nil until a usage reading exists.
    public var pace: Pace?
    /// $LE by work mode over the last 7 days.
    public var costByMode: [String: Double] = [:]
    /// The Budget view's Advanced row (Task 14u): `Ultra allowance <share>% of share · used <u>%`.
    public var ultraAllowance: String?
    /// Set when the CLI reports a plan other than the configured one (the owner is asked to confirm).
    public var planMismatch: String?
    /// The owner's time zone for every calendar-facing string.
    public var timeZone: TimeZone = .current
    /// The company's workspace, where documents named by asks live.
    public var workspace: String = ""

    public static let empty = WorkSnapshot()

    public init() {}

    public static func load(store: Store, companyId: String, limit: Int = 5000) throws -> WorkSnapshot {
        var w = WorkSnapshot()
        guard let company = try store.company(id: companyId) else { return w }
        let now = Date()
        w.items = try store.workItems(companyId: companyId, filter: WorkItemFilter(limit: limit))
        w.totalItems = try store.workItemCount(companyId: companyId)
        w.truncated = w.totalItems > w.items.count
        w.latestRuns = try store.latestVerifications(companyId: companyId)
        w.leases = try store.leases(companyId: companyId)
        w.openSprints = try store.sprints(companyId: companyId, statuses: Set(SprintStatus.open))

        let asks = try store.asks(companyId: companyId, statuses: [.pendingOwner, .approved])
        w.inbox = asks.filter { $0.status == .pendingOwner }
        w.fyi = asks.filter { $0.status == .approved && $0.fyi && $0.acknowledgedAt == nil }
        let cutoff = now.addingTimeInterval(-Double(recentDays) * 86_400)
        let fyiIds = Set(w.fyi.map(\.id))
        w.recentDecided = asks.filter { $0.status == .approved && !fyiIds.contains($0.id) && ($0.ownerDecidedAt ?? $0.updatedAt) >= cutoff }
            .sorted { ($0.ownerDecidedAt ?? $0.updatedAt) > ($1.ownerDecidedAt ?? $1.updatedAt) }
        for ask in w.inbox + w.fyi + w.recentDecided {
            w.displayTitles[ask.id] = try store.displayTitle(ask)
        }
        for ask in w.inbox where try store.documentChanged(ask) { w.changedDocuments.insert(ask.id) }

        w.stall = try store.stallReport(companyId: companyId)
        w.hold = try store.engineHold()
        w.orgIssues = try store.orgIssues(companyId: companyId).compactMap { r in
            r.id.map { OrgIssueRow(id: $0, kind: r.kind, detail: r.detail, agentId: r.agentId) }
        }
        w.reservedCategories = store.catalog.pack(company.packId)?.reservedCategories ?? []
        w.timeZone = store.ownerTimeZone()
        w.workspace = company.workspacePath
        let info = try store.latestRateLimit()
        w.pace = UsageGate.pace(info, reserve: company.ownerReserve ?? (1 - store.weeklyShare()), now: now)
        w.costByMode = try store.costByMode(companyId: companyId, since: now.addingTimeInterval(-7 * 86_400))
        w.ultraAllowance = UltraAllowanceText.line(share: company.ultraShare, allowance: try store.ultraAllowance(companyId: companyId, now: now))
        if let reported = try store.latestProbe()?.reportedSubscription, let tier = PlanTier(reportedSubscription: reported),
           tier != store.planTier() {
            w.planMismatch = PlanTierText.mismatch(reported: tier, configured: store.planTier())
        }
        return w
    }
}

public enum UltraAllowanceText {
    /// `Ultra allowance 15% of share · used 40%` (`used —` until the calibration knows the share in $LE).
    public static func line(share: Double, allowance: (totalLE: Double, usedLE: Double, leftLE: Double)?) -> String {
        let used = allowance.map { $0.totalLE > 0 ? "\(Int((min(1, $0.usedLE / $0.totalLE) * 100).rounded()))%" : "100%" } ?? "—"
        return "Ultra allowance \(Int((share * 100).rounded()))% of share · used \(used)"
    }
}

public enum PlanTierText {
    public static func name(_ tier: PlanTier) -> String {
        switch tier {
        case .pro: "Pro"
        case .max5x: "Max 5x"
        case .max20x: "Max 20x"
        }
    }

    /// The plan-tier confirmation alert: Brahma keeps the lower of the two until the owner confirms.
    public static func mismatch(reported: PlanTier, configured: PlanTier) -> String {
        "Claude reports a \(name(reported)) plan, but Brahma is set to \(name(configured)). Brahma keeps the lower plan's limits "
            + "until you confirm your plan in Settings."
    }
}
