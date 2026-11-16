import Testing
import Foundation
import BrahmaCore
@testable import BrahmaAppModel

/// Plan ML Task 9: the Budget view (ruling h) — its sidebar row and launch target, and the WEEKLY, BY MODE and STORAGE panels.
@MainActor @Suite(.scratch) struct BudgetModelTests {
    @Test func budgetTargetAndRows() async throws {
        #expect(SelectTarget("budget") == .budget)
        let (store, paths) = try makeHome()
        let (acme, _, _, _) = try seedAcme(store, paths)
        let app = AppModel(store: store, paths: paths)
        let sizing = CountingSizing()
        app.storageSizing = sizing
        await app.load()
        #expect(app.selectedCompanyId == acme.id)
        #expect(app.budget == nil, "nothing is measured before Budget is opened")

        app.apply(.budget)
        #expect(app.sidebarSelection == .budget)
        let budget = try #require(app.budget)
        #expect(BudgetModel.panels == ["WEEKLY", "BY MODE", "STORAGE"])
        #expect(budget.paceLine == (app.paceLine ?? BudgetModel.noPace))
        #expect(budget.modeBreakdownLine == nil)
        #expect(budget.byModeText == "No spend recorded this week.")
        #expect(BudgetModel(paceLine: "7D on pace", modeBreakdownLine: "This week by mode: Standard 100%", storage: budget.storage).byModeText
                == "This week by mode: Standard 100%")

        try await eventually { budget.storage.report != nil }
        #expect(budget.storage.companyId == acme.id)
        #expect(budget.storage.rows.map(\.label) == ["DATABASE (EST.)", "WORKSPACE", "RESOURCES", "TRANSCRIPTS", "ARCHIVE", "TOTAL",
                                                     "BACKUPS (ALL COMPANIES)", "FREE DISK"])
        #expect(budget.storage.rows.first { $0.label == "WORKSPACE" }?.value == "1000 B")
        #expect(StorageModel.title == "STORAGE")
        #expect(StorageModel.footer
                == "HOT TIER: everything. Brahma keeps all records; nothing is deleted automatically. A warm archive tier comes later.")
        // The sidebar row.
        app.select(.missionControl)
        app.select(.budget)
        #expect(app.sidebarSelection == .budget)
        #expect(sizing.measurements == 1, "reopening Budget within the interval reuses the measurement")
    }
}
