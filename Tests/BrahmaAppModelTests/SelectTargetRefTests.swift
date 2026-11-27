import Testing
import Foundation
@testable import BrahmaCore
@testable import BrahmaAppModel

@MainActor @Suite(.scratch) struct SelectTargetRefTests {
    @Test func deepLinkIsViewOnly() async throws {
        #expect(SelectTarget("ref:C/ENG-142") == .ref(companyId: "C", canonical: "ENG-142"))
        #expect(SelectTarget("ref:C/src/a.ts:40-88@worktree") == .ref(companyId: "C", canonical: "src/a.ts:40-88@worktree"))
        #expect(SelectTarget("ref:C/fact:what's blocked") == .ref(companyId: "C", canonical: "fact:what's blocked"))
        #expect(SelectTarget("ref:ENG-142") == nil)
        #expect(SelectTarget("ref:C/") == nil)
        #expect(SelectTarget("ref:/ENG-142") == nil)
        #expect(SelectTarget("ref:") == nil)
        #expect(LaunchOptions.parse(["/x", "--select", "ref:C/ENG-142"]).select == .ref(companyId: "C", canonical: "ENG-142"))

        let w = try RefWorld()
        let app = await w.app()
        let before = try ["showRequest", "message", "accessGrant", "turn", "refRead"].map { try w.count($0) }
        app.apply(.ref(companyId: w.company.id, canonical: w.item.key))
        try await eventually { app.previewNav.opened?.ref.canonical == w.item.key }
        #expect(app.selectedCompanyId == w.company.id)
        #expect(app.previewNav.opened?.origin == .owner)
        #expect(app.selectedPreviewTab == PreviewTabID.ref)
        try await eventually { app.openedBody != nil }
        // A deep link only selects the company and opens the ref: nothing is asked, shared, granted or spent. The only new row
        // is the read of the opened ref itself.
        let after = try ["showRequest", "message", "accessGrant", "turn", "refRead"].map { try w.count($0) }
        #expect(Array(after.prefix(4)) == Array(before.prefix(4)))
        #expect(after[4] >= before[4])
        // `fact:` works through the deep link (`allowInternal`).
        app.apply(.ref(companyId: w.company.id, canonical: "fact:what's blocked"))
        try await eventually { app.previewNav.opened?.ref.kind == .fact }
        // An unknown company is refused and opens nothing new.
        let opened = app.previewNav.opened
        app.apply(.ref(companyId: "no-such-company", canonical: "ENG-1"))
        try await Task.sleep(for: .milliseconds(200))
        #expect(app.previewNav.opened == opened)
        #expect(app.errorMessage != nil)
    }

    @Test func findTargetNeverAsks() async throws {
        #expect(SelectTarget("find:why is checkout slow") == .find("why is checkout slow"))
        #expect(SelectTarget("find:") == nil)
        let w = try RefWorld()
        let app = await w.app()
        app.apply(.find("why is checkout slow"))
        #expect(app.showBar.isOpen && app.showBar.presentation == .overlay)
        #expect(app.showBar.query == "why is checkout slow")
        try await eventually { app.showBar.result != nil }
        guard case .ask? = app.showBar.rows.indices.contains(app.showBar.selection) ? app.showBar.rows[app.showBar.selection] : nil else {
            Issue.record("ASK is not selected: \(app.showBar.rows)")
            return
        }
        #expect(try w.count("showRequest") == 0)
        #expect(try w.count("turn") == 0)
    }

    @Test func submitAskCreatesOneRequest() async throws {
        let w = try RefWorld()
        let app = await w.app()
        app.apply(.find("why is checkout slow"))
        try await eventually { app.showBar.result != nil }
        guard case .ask(let draft) = app.showBar.handle(.enter) else {
            Issue.record("Enter on the ASK row did not ask")
            return
        }
        #expect(try w.count("showRequest") == 0)
        await app.submitAsk(draft)
        #expect(try w.count("showRequest") == 1)
        #expect(app.waitingChips.count == 1)
        #expect(app.waitingChips.first?.text.hasPrefix("Brahma") == true)
        #expect(!app.showBar.isOpen)
        #expect(app.ownerRequestsBudgetLine.hasPrefix("OWNER REQUESTS · "))
        if let id = app.waitingChips.first?.requestId {
            await app.cancelShowRequest(id)
            #expect(app.waitingChips.isEmpty)
            #expect(try w.store.showRequest(companyId: w.company.id, id: id)?.status == .cancelled)
        }
    }
}
