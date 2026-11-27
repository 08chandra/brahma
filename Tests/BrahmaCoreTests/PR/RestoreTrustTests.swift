import Foundation
import Testing
import GRDB
@testable import BrahmaCore

/// Ruling X8-20: a restore never widens the owner's trust. The trust list is kept at the intersection with the live database,
/// items imported under a removed login read untrusted again, and an issue link keeps the stricter of the two.
@Suite(.scratch) struct RestoreTrustTests {
    static let now = Date(timeIntervalSince1970: 1_800_000_000)

    /// Writes an imported item's origin the way Task 3's import will.
    static func setOrigin(_ store: Store, _ item: WorkItem, url: String, author: String, trusted: Bool) throws {
        try store.writer.write { db in
            try db.execute(sql: "UPDATE workItem SET originURL = ?, originAuthor = ?, originTrusted = ?, originId = ? WHERE id = ?",
                           arguments: [url, author, trusted, url.split(separator: "/").last.map(String.init), item.id])
        }
    }

    /// Snapshot with login A trusted and an A-origin item marked trusted; A removed live; restore: A is not trusted, the item
    /// reads untrusted, and the report names the login. B, trusted in both, stays; C, added live only, is not re-added.
    @Test func restoreNeverWidensTheTrustList() throws {
        let env = try BackupEnv()
        let acme = try env.company("Acme"), beta = try env.company("Beta")
        try env.store.addTrustedLogin("alice", companyId: acme.id, by: .owner, now: Self.now)
        try env.store.addTrustedLogin("bob", companyId: acme.id, by: .owner, now: Self.now)
        // The same login trusted in another company is that company's decision.
        try env.store.addTrustedLogin("alice", companyId: beta.id, by: .owner, now: Self.now)
        let fromAlice = try env.store.createWorkItem(companyId: acme.id, by: .owner, draft: WorkItemDraft(type: .task, title: "from alice"))
        try Self.setOrigin(env.store, fromAlice, url: "https://github.com/acme/app/issues/7", author: "alice", trusted: true)
        let fromBob = try env.store.createWorkItem(companyId: acme.id, by: .owner, draft: WorkItemDraft(type: .task, title: "from bob"))
        try Self.setOrigin(env.store, fromBob, url: "https://github.com/acme/app/issues/8", author: "bob", trusted: true)
        let betaItem = try env.store.createWorkItem(companyId: beta.id, by: .owner, draft: WorkItemDraft(type: .task, title: "beta"))
        try Self.setOrigin(env.store, betaItem, url: "https://github.com/beta/app/issues/1", author: "alice", trusted: true)
        let service = env.service()
        let snapshot = try service.snapshot(reason: .manual)
        // After the snapshot: the owner removes alice from Acme and trusts carol.
        try env.store.removeTrustedLogin("alice", companyId: acme.id, by: .owner)
        try env.store.addTrustedLogin("carol", companyId: acme.id, by: .owner, now: Self.now)
        try env.store.close()
        let outcome = try service.restore(try service.planRestore(snapshot: snapshot))
        let restored = try Store(path: env.paths.database.path, backupsDir: env.paths.backupsDir)
        #expect(try restored.trustedLogins(companyId: acme.id).map(\.login) == ["bob"], "the restore widened the trust list")
        #expect(try restored.trustedLogins(companyId: beta.id).map(\.login) == ["alice"])
        #expect(try #require(try restored.workItem(id: fromAlice.id)).originTrusted == false, "an item from the removed login stayed trusted")
        #expect(try #require(try restored.workItem(id: fromBob.id)).originTrusted == true)
        #expect(try #require(try restored.workItem(id: betaItem.id)).originTrusted == true)
        let line = "Acme: trusted login alice, removed after the snapshot, stays removed"
        #expect(outcome.warnings.contains { $0.contains(line) }, "\(outcome.warnings)")
        #expect(!outcome.warnings.contains { $0.contains("bob") }, "\(outcome.warnings)")
        #expect(try restored.engineStopped()?.note?.contains(line) == true)
    }

    /// No link is stricter than a link; a label filter is stricter than none; a link re-pointed live keeps the live target.
    @Test func restoreKeepsTheStricterIssueLink() throws {
        let env = try BackupEnv()
        let acme = try env.company("Acme"), beta = try env.company("Beta"), gamma = try env.company("Gamma")
        try env.store.setIssueLink(IssueLink(companyId: acme.id, provider: .github, target: "acme/app", label: nil, cursor: "c1"), by: .owner)
        try env.store.setIssueLink(IssueLink(companyId: beta.id, provider: .github, target: "beta/app", label: nil, cursor: "c2"), by: .owner)
        try env.store.setIssueLink(IssueLink(companyId: gamma.id, provider: .linear, target: "ENG", label: "brahma", cursor: "c3"), by: .owner)
        let service = env.service()
        let snapshot = try service.snapshot(reason: .manual)
        // After the snapshot: Acme's link is cleared, Beta's gets a label, Gamma's is re-pointed and loses its label.
        try env.store.clearIssueLink(companyId: acme.id, provider: .github, by: .owner)
        try env.store.setIssueLink(IssueLink(companyId: beta.id, provider: .github, target: "beta/app", label: "brahma", cursor: "c9"), by: .owner)
        try env.store.setIssueLink(IssueLink(companyId: gamma.id, provider: .linear, target: "OPS", label: nil, cursor: "c4"), by: .owner)
        try env.store.close()
        let outcome = try service.restore(try service.planRestore(snapshot: snapshot))
        let restored = try Store(path: env.paths.database.path, backupsDir: env.paths.backupsDir)
        #expect(try restored.issueLink(companyId: acme.id, provider: .github) == nil, "the restore re-linked a cleared issue source")
        let betaLink = try #require(try restored.issueLink(companyId: beta.id, provider: .github))
        #expect(betaLink.target == "beta/app"); #expect(betaLink.label == "brahma"); #expect(betaLink.cursor == nil, "the cursor belongs to the wider filter")
        let gammaLink = try #require(try restored.issueLink(companyId: gamma.id, provider: .linear))
        #expect(gammaLink.target == "OPS"); #expect(gammaLink.label == "brahma", "the snapshot's label filter is the narrower one"); #expect(gammaLink.cursor == nil)
        for line in ["Acme: github issue link acme/app, cleared after the snapshot, stays cleared",
                     "Beta: github issue link kept at beta/app label brahma (the snapshot had beta/app, no label)",
                     "Gamma: linear issue link kept at OPS label brahma (the snapshot had ENG label brahma)"] {
            #expect(outcome.warnings.contains { $0.contains(line) }, "\(line): \(outcome.warnings)")
        }
        // The rule itself.
        typealias L = RestoreCarry.Settings.IssueLinkSetting
        #expect(RestoreCarry.Settings.stricterIssueLink(live: nil, restored: L(target: "a", label: nil)) == nil)
        #expect(RestoreCarry.Settings.stricterIssueLink(live: L(target: "a", label: "x"), restored: nil) == nil)
        #expect(RestoreCarry.Settings.stricterIssueLink(live: L(target: "a", label: nil), restored: L(target: "a", label: "x")) == L(target: "a", label: "x"))
        #expect(RestoreCarry.Settings.stricterIssueLink(live: L(target: "a", label: "y"), restored: L(target: "a", label: "x")) == L(target: "a", label: "y"))
        #expect(RestoreCarry.Settings.stricterIssueLink(live: L(target: "b", label: nil), restored: L(target: "a", label: nil)) == L(target: "b", label: nil))
    }

    /// When the live database cannot be read, nothing it held can be trusted: the trust list is emptied and every imported item
    /// reads untrusted.
    @Test func unreadableLiveDatabaseEmptiesTheTrustList() throws {
        let env = try BackupEnv()
        let acme = try env.company("Acme")
        try env.store.addTrustedLogin("alice", companyId: acme.id, by: .owner, now: Self.now)
        let item = try env.store.createWorkItem(companyId: acme.id, by: .owner, draft: WorkItemDraft(type: .task, title: "from alice"))
        try Self.setOrigin(env.store, item, url: "https://github.com/acme/app/issues/7", author: "alice", trusted: true)
        let service = env.service()
        let snapshot = try service.snapshot(reason: .manual)
        try env.store.close()
        for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: env.paths.database.path + suffix) {
            try FileManager.default.removeItem(atPath: env.paths.database.path + suffix)
        }
        try Data(repeating: 0x5a, count: 8192).write(to: env.paths.database)
        _ = try service.restore(try service.planRestore(snapshot: snapshot))
        let restored = try Store(path: env.paths.database.path, backupsDir: env.paths.backupsDir)
        #expect(try restored.trustedLogins(companyId: acme.id).isEmpty)
        #expect(try #require(try restored.workItem(id: item.id)).originTrusted == false)
    }

    /// Plan X8 Task 2 (Ruling 22's rule): a PR landing keeps its live state and a snapshot-only one is dropped, so a restore
    /// never resumes a landing the owner abandoned; one started after the snapshot is kept for its item.
    @Test func restoreKeepsLivePRLandingState() throws {
        let env = try BackupEnv()
        let acme = try env.company("Acme")
        func item(_ t: String) throws -> WorkItem {
            try env.store.createWorkItem(companyId: acme.id, by: .owner, draft: WorkItemDraft(type: .task, title: t))
        }
        let abandoned = try item("abandoned live"), gone = try item("gone live"), later = try item("started later"), same = try item("same")
        func landing(_ i: WorkItem, _ state: PRLandingState) -> PRLanding {
            PRLanding(itemId: i.id, companyId: acme.id, branch: "brahma/\(i.key)", pushedSHA: String(repeating: "a", count: 40),
                      prNumber: 7, state: state, updatedAt: Self.now)
        }
        try env.store.upsertPRLanding(landing(abandoned, .open))
        try env.store.upsertPRLanding(landing(gone, .open))
        try env.store.upsertPRLanding(landing(same, .checksFailed))
        let service = env.service()
        let snapshot = try service.snapshot(reason: .manual)
        // After the snapshot: the owner abandons one, another's row goes, a new landing starts.
        try env.store.upsertPRLanding(landing(abandoned, .abandoned))
        try env.store.writer.write { db in try db.execute(sql: "DELETE FROM prLanding WHERE itemId = ?", arguments: [gone.id]) }
        try env.store.upsertPRLanding(landing(later, .pushed))
        try env.store.close()
        let outcome = try service.restore(try service.planRestore(snapshot: snapshot))
        let restored = try Store(path: env.paths.database.path, backupsDir: env.paths.backupsDir)
        #expect(try restored.prLanding(itemId: abandoned.id)?.state == .abandoned, "the restore resumed an abandoned landing")
        #expect(try restored.prLanding(itemId: gone.id) == nil, "a snapshot-only landing came back")
        #expect(try restored.prLanding(itemId: later.id)?.state == .pushed)
        #expect(try restored.prLanding(itemId: same.id)?.state == .checksFailed)
        #expect(try restored.openPRLandings(companyId: acme.id).map(\.itemId).sorted() == [later.id, same.id].sorted())
        for line in ["Acme: the PR landing of brahma/\(abandoned.key) stays abandoned (the snapshot had open)",
                     "Acme: the PR landing of brahma/\(gone.key), gone after the snapshot, is not resumed"] {
            #expect(outcome.warnings.contains { $0.contains(line) }, "\(line): \(outcome.warnings)")
        }
    }

    /// An unreadable live database leaves no landing state to keep: none of the snapshot's landings is resumed.
    @Test func unreadableLiveDatabaseResumesNoPRLanding() throws {
        let env = try BackupEnv()
        let acme = try env.company("Acme")
        let item = try env.store.createWorkItem(companyId: acme.id, by: .owner, draft: WorkItemDraft(type: .task, title: "t"))
        try env.store.upsertPRLanding(PRLanding(itemId: item.id, companyId: acme.id, branch: "brahma/\(item.key)",
                                                pushedSHA: String(repeating: "b", count: 40), state: .open, updatedAt: Self.now))
        let service = env.service()
        let snapshot = try service.snapshot(reason: .manual)
        try env.store.close()
        for suffix in ["-wal", "-shm"] where FileManager.default.fileExists(atPath: env.paths.database.path + suffix) {
            try FileManager.default.removeItem(atPath: env.paths.database.path + suffix)
        }
        try Data(repeating: 0x5a, count: 8192).write(to: env.paths.database)
        _ = try service.restore(try service.planRestore(snapshot: snapshot))
        let restored = try Store(path: env.paths.database.path, backupsDir: env.paths.backupsDir)
        #expect(try restored.openPRLandings(companyId: acme.id).isEmpty)
    }
}
