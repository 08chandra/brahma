import Foundation
import Testing
import BrahmaCore
@testable import BrahmaAppModel

/// Plan ML Task 7: the Resources library (rows, chips, the purge note) and the owner's actions on it.
@MainActor @Suite(.scratch) struct ResourcesPresentationTests {
    struct W {
        let store: Store, paths: BrahmaPaths, company: Company, eng: Agent, vault: MemoryVault, content: ContentVault
        let drops: URL

        init() throws {
            let (store, paths) = try makeHome()
            let (acme, _, _, eng) = try seedAcme(store, paths)
            try store.setOwnerTimeZone("UTC")
            self.store = store; self.paths = paths; company = acme; self.eng = eng
            vault = MemoryVault(); content = ContentVault(paths: paths)
            drops = try tempDir()
        }

        @discardableResult
        func add(_ name: String, _ text: String, _ drop: ResourceDrop = ResourceDrop(), now: Date = Store.now()) throws -> [Resource] {
            let url = drops.appending(path: name)
            try Data(text.utf8).write(to: url)
            let plan = try ResourceIntake.inspect(urls: [url], knownValues: [], agentAreas: .none)
            return try store.addResources(companyId: company.id, plan: plan, drop: drop, contentVault: content, secretVault: vault,
                                          knownValues: [], paths: paths, now: now, owner: .test)
        }
    }

    @Test func rowsChipsAndPurgeNote() throws {
        let w = try W()
        try w.add("notes.md", "# notes\n")                                                             // F-1 FROM YOU
        try w.add("report.pdf", "%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\n%%EOF\n")             // F-2 EXTERNAL
        try w.add("aws.txt", "key = AKIAIOSFODNN7EXAMPLE\n", ResourceDrop(secretChoice: .uploadRedacted))  // F-3 REDACTED
        try w.add("keep.txt", "key = AKIAIOSFODNN7EXAMPLE\n", ResourceDrop(scope: .agent(w.eng.id), secretChoice: .uploadAnyway))
        try w.store.addLink(companyId: w.company.id, url: "https://example.com/docs?q=1", drop: ResourceDrop(), contentVault: w.content, owner: .test)
        // Explicit times (the purge flags backups taken in [added, purged]; `Date()` against the store's millisecond-rounded
        // clock could fall either side): one backup before F-6 was added, one between its add and its purge.
        let added = Store.now().addingTimeInterval(60)
        try w.add("gone.md", "bye\n", now: added)                                                      // F-6, purged below
        let report = try w.store.purgeResource(
            companyId: w.company.id, number: 6,
            backups: [(name: "brahma-old", takenAt: added.addingTimeInterval(-30)), (name: "brahma-a", takenAt: added.addingTimeInterval(30))],
            contentVault: w.content, paths: w.paths, now: added.addingTimeInterval(60), owner: .test)
        #expect(report.backups == ["brahma-a"])

        let rows = try ResourcesSnapshot.load(store: w.store, companyId: w.company.id)
        #expect(rows.map(\.ref) == ["F-1", "F-2", "F-3", "F-4", "F-5", "F-6"])
        #expect(rows[0].name == "notes.md")
        #expect(rows[0].kindLabel == "MD")
        #expect(rows[0].sizeText == "8 B")
        #expect(rows[0].scopeLabel == "company")
        #expect(rows[0].trustChip == .fromYou)
        #expect(rows[0].scanChip == nil)
        #expect(rows[0].mirrorPath == ".brahma/resources/company/F-1.md")
        #expect(rows[0].sha12.count == 12)
        #expect(rows[0].readersText == "everyone in the company")
        #expect(rows[0].addedText.count == "yyyy-MM-dd HH:mm".count)
        #expect(!rows[0].isPurged)
        #expect(rows[0].canPurge && rows[0].canChangeScope && !rows[0].canVouch)
        #expect(rows[1].trustChip == .external(reason: "PDF from outside (document type)"))
        #expect(rows[1].canVouch)
        #expect(rows[1].mirrorPath == nil)
        #expect(rows[2].scanChip == "REDACTED")
        #expect(rows[3].scanChip == "FLAGGED")
        #expect(rows[3].scopeLabel == "agent @eng")
        #expect(rows[3].readersText == "@eng")
        // The owner's view shows a link's host and path, never fetched.
        #expect(rows[4].kindLabel == "LINK")
        #expect(rows[4].name == "example.com/docs")
        #expect(rows[4].sizeText == "—")
        // A purged row is a tombstone.
        #expect(rows[5].isPurged)
        #expect(rows[5].name == "[purged]")
        #expect(!rows[5].canPurge && !rows[5].canVouch && !rows[5].canChangeScope)
        #expect(ResourcesPresentation.purgeNote(rows[5]) == "1 backups and 0 transcripts may contain purged content (reads through an "
                + "agent's shell or the mirror are not tracked one by one) · delete or re-create")
        #expect(ResourcesPresentation.purgeNote(rows[0]) == nil)
        #expect(ResourcesPresentation.purgeConfirmText("F-6")
                == "Purge F-6? This deletes the file and its search text. Backups made since it was added still contain it, and transcripts made since then may.")
    }

    @Test func purgeNeedsConfirm() async throws {
        let w = try W()
        let app = AppModel(store: w.store, paths: w.paths)
        await app.load()
        try w.add("notes.md", "# notes\n")
        await app.tick(forceSnapshot: true)
        #expect(app.resourceRows.map(\.ref) == ["F-1"])

        // Without the view's confirmation nothing is purged.
        await app.purge(resource: "F-1")
        #expect(try w.store.resource(companyId: w.company.id, number: 1)?.purgedAt == nil)
        #expect(app.errorMessage != nil)
        app.errorMessage = nil

        app.confirmPurge = "F-1"
        await app.purge(resource: "F-1")
        #expect(app.errorMessage == nil)
        #expect(app.confirmPurge == nil)
        #expect(try w.store.resource(companyId: w.company.id, number: 1)?.purgedAt != nil)
        #expect(app.resourceRows.first?.isPurged == true)
    }

    @Test func ownerVouchAndScope() async throws {
        let w = try W()
        let app = AppModel(store: w.store, paths: w.paths)
        await app.load()
        try w.add("report.pdf", "%PDF-1.4\n1 0 obj\n<< /Type /Catalog >>\nendobj\n%%EOF\n")
        await app.vouch(resource: "F-1")
        #expect(app.resourceRows.first?.trustChip == .fromYou)
        await app.setScope(resource: "F-1", .team("payments"))
        #expect(app.resourceRows.first?.scopeLabel == "team payments")
        await app.setScope(resource: "F-1", .company)
        #expect(app.resourceRows.first?.scopeLabel == "company")
        #expect(app.errorMessage == nil)
    }

    @Test func selectResourcesTarget() throws {
        #expect(SelectTarget("resources") == .resources)
        let (store, paths) = try makeHome()
        try seedAcme(store, paths)
        let app = AppModel(store: store, paths: paths)
        app.apply(.resources)
        #expect(app.sidebarSelection == .resources)
    }
}
