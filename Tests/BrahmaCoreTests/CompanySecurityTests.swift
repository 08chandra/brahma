import Testing
import Foundation
@testable import BrahmaCore

/// S35: every stored property of `Company` is classified for restores, either security-relevant (with a strictness order,
/// `CompanySecurity.fields`) or not (`CompanySecurity.notSecurityRelevant`, with a reason). A new property in neither list
/// fails here, so nobody adds an owner switch that a restore silently rolls back.
@Suite(.scratch) struct CompanySecurityTests {
    @Test func everyCompanyPropertyIsClassified() throws {
        let store = try Store.inMemory()
        let company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        let stored = Set(Mirror(reflecting: company).children.compactMap(\.label))
        #expect(!stored.isEmpty)
        let secure = CompanySecurity.fields.map(\.name)
        let other = Set(CompanySecurity.notSecurityRelevant.keys)
        #expect(Set(secure).count == secure.count, "a security field is listed twice")
        #expect(Set(secure).isDisjoint(with: other), "a field is in both lists: \(Set(secure).intersection(other).sorted())")
        let classified = Set(secure).union(other)
        #expect(stored.subtracting(classified).isEmpty, "unclassified Company properties: \(stored.subtracting(classified).sorted())")
        #expect(classified.subtracting(stored).isEmpty, "classified names that are not Company properties: \(classified.subtracting(stored).sorted())")
    }

    /// Each order runs strictest to loosest: the stricter value always wins, whichever database holds it.
    @Test func theStricterValueWinsBothWays() throws {
        let store = try Store.inMemory()
        var strict = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        strict.autonomy = .everything; strict.permissionProfile = .sandboxed; strict.roleProfiles = ["engineer": .sandboxed]
        strict.allowLocalBinding = false; strict.autoMergeSmall = false; strict.status = .paused
        strict.allowedDomains = ["a.example.com"]; strict.webDomains = []; strict.toolchainReadPaths = []
        var loose = strict
        loose.autonomy = .auto; loose.permissionProfile = .full; loose.roleProfiles = ["engineer": .full, "designer": .workspace]
        loose.allowLocalBinding = true; loose.autoMergeSmall = true; loose.status = .running
        loose.allowedDomains = ["a.example.com", "b.example.com"]; loose.webDomains = ["docs.example.com"]; loose.toolchainReadPaths = ["~/sdk"]
        for (live, restored) in [(strict, loose), (loose, strict)] {
            let (merged, _) = CompanySecurity.stricter(live: live, restored: restored)
            #expect(merged.autonomy == .everything); #expect(merged.permissionProfile == .sandboxed)
            #expect(merged.profile(forRole: "engineer") == .sandboxed); #expect(merged.profile(forRole: "designer") == .sandboxed)
            #expect(!merged.allowLocalBinding); #expect(!merged.autoMergeSmall); #expect(merged.status == .paused)
            #expect(merged.allowedDomains == ["a.example.com"]); #expect(merged.webDomains.isEmpty); #expect(merged.toolchainReadPaths.isEmpty)
        }
        let (_, lines) = CompanySecurity.stricter(live: strict, restored: loose)
        #expect(lines.contains("autonomy kept at everything (the snapshot had auto)"), "\(lines)")
        #expect(CompanySecurity.stricter(live: loose, restored: strict).1.isEmpty, "nothing to report when the snapshot is stricter")
    }
}
