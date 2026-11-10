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
    // `milestones: MilestoneReport?` arrives with Task 13 (the type does not exist yet).

    public static let newest = 20
    public static let empty = ReleasesSnapshot(hosting: nil, readiness: HostingReadiness(configured: false, tokenPresent: false,
                                                                                         accountPresent: false, npmPresent: false),
                                               releases: [], smokeCheck: nil, latestMainSmoke: nil, redBugKey: nil, mainHead: nil)

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
        return r
    }

    public var openCount: Int { releases.filter { $0.status.isOpen }.count }
}
