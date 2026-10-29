import Foundation
import BrahmaCore

public struct CompanySummary: Equatable, Sendable, Identifiable {
    public var company: Company
    public var counts: StateCounts
    /// Unread in channels the owner is a member of (rail badge).
    public var unread: Int
    /// Agents blocked on the owner.
    public var waitingOnOwner: Int
    /// Asks waiting in the owner's Inbox.
    public var inboxCount: Int = 0
    /// Why nothing is running (the first stall reason); nil while anything runs.
    public var stallLine: String? = nil

    public var id: String { company.id }
    public var badge: Int { unread + waitingOnOwner + inboxCount }
    public var initials: String { CompanyInitials.of(company.name) }
}

public struct Snapshot: Equatable, Sendable {
    public var companies: [CompanySummary]
    /// Selected company's agents.
    public var agents: [Agent]
    /// All of the selected company's channels.
    public var channels: [Channel]
    /// Raw `store.unreadCounts(companyId:)` for the selected company.
    public var unreadByChannel: [String: Int]
    public var lastTurns: [String: Turn]
    public var usage: RateLimitInfo?
    /// Selected company's work, Inbox and health.
    public var work = WorkSnapshot.empty
    /// The Claude Code version the last doctor run saw (the sandbox banner names it).
    public var claudeVersion: String?

    public static let empty = Snapshot(companies: [], agents: [], channels: [], unreadByChannel: [:], lastTurns: [:], usage: nil)

    public static func load(store: Store, selectedCompanyId: String?) throws -> Snapshot {
        var summaries: [CompanySummary] = []
        for company in try store.companies() {
            let agents = try store.agents(companyId: company.id)
            let ownerChannels = try store.channels(companyId: company.id, memberId: "owner")
            let counts = try store.unreadCounts(companyId: company.id)
            let unread = ownerChannels.reduce(0) { $0 + (counts[$1.id] ?? 0) }
            let waiting = agents.filter {
                if case .owner? = $0.blocker { return $0.state == .blocked }
                return false
            }.count
            let counts2 = StateCounts(agents)
            var summary = CompanySummary(company: company, counts: counts2, unread: unread, waitingOnOwner: waiting)
            summary.inboxCount = try store.ownerWaitingCount(companyId: company.id)
            if counts2.running == 0 { summary.stallLine = try store.stallReport(companyId: company.id).reasons.first }
            summaries.append(summary)
        }
        var snap = Snapshot.empty
        snap.companies = summaries
        snap.usage = try store.latestRateLimit()
        snap.claudeVersion = try store.latestProbe()?.cliVersion
        if let id = selectedCompanyId {
            snap.agents = try store.agents(companyId: id)
            snap.channels = try store.channels(companyId: id)
            snap.unreadByChannel = try store.unreadCounts(companyId: id)
            snap.work = try WorkSnapshot.load(store: store, companyId: id)
            for a in snap.agents {
                if let t = try store.lastTurn(agentId: a.id) { snap.lastTurns[a.id] = t }
            }
        }
        return snap
    }
}
