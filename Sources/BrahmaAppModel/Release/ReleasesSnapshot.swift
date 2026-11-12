import Foundation
import BrahmaCore

/// Work › Releases for the selected company (Plan L Task 10), read off-main with the snapshot.
public struct ReleasesSnapshot: Equatable, Sendable {
    public var hosting: HostingSettings?
    public var readiness: HostingReadiness
    /// The 20 newest, newest first.
    public var releases: [Release]
    public var smokeCheck: CheckSpec?
    public var latestMainSmoke: MainSmokeRun?
    /// The key of the open red-main bug.
    public var redBugKey: String?
    /// The engine-accepted head of `main`.
    public var mainHead: String?
    /// The path-to-live scorecard (Task 13), for the PATH TO LIVE strip; nil for an unknown company.
    public var milestones: MilestoneReport?

    public static let newest = 20
    public static let empty = ReleasesSnapshot(hosting: nil, readiness: HostingReadiness(configured: false, tokenPresent: false,
                                                                                         accountPresent: false, npmPresent: false),
                                               releases: [], smokeCheck: nil, latestMainSmoke: nil, redBugKey: nil, mainHead: nil,
                                               milestones: nil)

    /// `vault` is passed through to `hostingReadiness`, which reads only secret metadata (never the vault).
    public static func load(store: Store, companyId: String, vault: (any SecretVault)? = nil) throws -> ReleasesSnapshot {
        guard let company = try store.company(id: companyId) else { return .empty }
        var r = ReleasesSnapshot.empty
        r.hosting = try store.hosting(companyId: companyId)
        r.readiness = try store.hostingReadiness(companyId: companyId, vault: vault)
        r.releases = try store.releases(companyId: companyId, limit: newest)
        r.smokeCheck = company.smokeCheck
        r.latestMainSmoke = try store.latestMainSmoke(companyId: companyId)
        r.redBugKey = try company.redBugItemId.flatMap { try store.workItem(id: $0)?.key }
        r.mainHead = company.mainCommit
        r.milestones = try CompanyMilestones.load(store: store, companyId: companyId, now: Date())
        return r
    }

    public var openCount: Int { releases.filter { $0.status.isOpen }.count }
}
