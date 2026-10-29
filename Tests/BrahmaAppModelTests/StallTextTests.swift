import Testing
import Foundation
import BrahmaCore
@testable import BrahmaAppModel

@MainActor @Suite(.scratch) struct StallTextTests {
    @Test func stallLineOnlyWhenNothingRunning() async throws {
        let w = try await WorkWorld.make()
        // Nothing runs: the first reason is shown, in the company summary and for the selected company.
        let line = try #require(w.model.stallLine)
        #expect(line == w.model.selectedCompany?.stallLine)
        #expect(line == "no Ready items in the backlog")
        _ = try w.store.transition(agentId: w.eng.id, to: .ready)
        _ = try w.store.transition(agentId: w.eng.id, to: .running)
        await w.refresh()
        #expect(w.model.stallLine == nil)
        #expect(w.model.selectedCompany?.stallLine == nil)
        // A hold is the first reason once nothing runs again.
        _ = try w.store.transition(agentId: w.eng.id, to: .sleeping)
        try w.store.setHold(reason: .account, detail: "logged out", now: Date())
        await w.refresh()
        #expect(w.model.stallLine?.hasPrefix("engine paused: account (logged out) since ") == true)
        #expect(w.model.holdBanner == "Claude Code is logged out or the plan changed. Log in with claude in Terminal, then press Retry.")
        #expect(w.model.canRetryEngine)
    }

    @Test func menuBarShowsStall() async throws {
        let w = try await WorkWorld.make()
        let menu = w.model.menuBar
        #expect(menu.stall == "no Ready items in the backlog")
        #expect(menu.rows.first?.stallLine == "no Ready items in the backlog")
        _ = try w.store.transition(agentId: w.eng.id, to: .ready)
        _ = try w.store.transition(agentId: w.eng.id, to: .running)
        await w.refresh()
        #expect(w.model.menuBar.stall == nil)
        #expect(w.model.menuBar.rows.first?.stallLine == nil)
    }

    @Test func pausedCompanyStallIsNotShownAsAProblemInTheMenuSummary() async throws {
        let w = try await WorkWorld.make()
        await w.model.setCompanyRunning(false, companyId: w.company.id)
        // The row says "Paused"; the summary stall line is for running companies that are stuck.
        #expect(w.model.menuBar.rows.first?.statusText == "Paused")
        #expect(w.model.menuBar.stall == nil)
    }
}
