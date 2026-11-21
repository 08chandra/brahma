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
    /// The owner's emergency stop (Task 7c), across every company; nil while not stopped.
    public var stop: EngineStopRow?
    /// The owner's time zone (`Store.ownerTimeZone`): the stop's time is shown in it, as `brahma status` and the stall reason do.
    public var ownerTimeZone: TimeZone = .current
    /// Selected company's preview surfaces, states and live site (Plan L).
    public var preview = PreviewSnapshot.empty
    /// Selected company's Work › Releases.
    public var releases = ReleasesSnapshot.empty
    /// Pending `deploy` ask id → its release (the deploy cards).
    public var deployReleases: [String: Release] = [:]
    /// Selected company's Work › Resources (Plan ML), purged tombstones included.
    public var resources: [ResourceRow] = []
    /// Selected company's Work › Merge queue (Plan 4a).
    public var merge = MergeSnapshot.empty

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
        snap.stop = try store.engineStopped()
        snap.ownerTimeZone = store.ownerTimeZone()
        if let id = selectedCompanyId {
            snap.agents = try store.agents(companyId: id)
            snap.channels = try store.channels(companyId: id)
            snap.unreadByChannel = try store.unreadCounts(companyId: id)
            snap.work = try WorkSnapshot.load(store: store, companyId: id)
            if let company = summaries.first(where: { $0.id == id })?.company {
                snap.preview = try PreviewSnapshot.load(store: store, company: company)
                snap.releases = try ReleasesSnapshot.load(store: store, companyId: id)
                snap.resources = try ResourcesSnapshot.load(store: store, companyId: id)
                snap.merge = try MergeSnapshot.load(store: store, companyId: id)
                let deployAsks = Set(snap.work.inbox.filter { $0.kind == .deploy }.map(\.id))
                if !deployAsks.isEmpty {
                    for r in try store.releases(companyId: id) { if let a = r.askId, deployAsks.contains(a) { snap.deployReleases[a] = r } }
                }
            }
            for a in snap.agents {
                if let t = try store.lastTurn(agentId: a.id) { snap.lastTurns[a.id] = t }
            }
        }
        return snap
    }
}
