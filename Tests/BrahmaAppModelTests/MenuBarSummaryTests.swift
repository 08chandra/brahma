import Testing
import Foundation
import BrahmaCore
@testable import BrahmaAppModel

@MainActor @Suite(.scratch) struct MenuBarSummaryTests {
    private func counts(running: Int, ready: Int) -> StateCounts {
        var c = StateCounts([])
        c.running = running
        c.ready = ready
        return c
    }

    private func pair() throws -> [CompanySummary] {
        let (store, paths) = try makeHome()
        var acme = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: paths.workspaces)
        var globex = try store.createCompany(name: "Globex", goal: "g", workspacesRoot: paths.workspaces)
        acme.status = .running
        globex.status = .paused
        return [
            CompanySummary(company: acme, counts: counts(running: 2, ready: 1), unread: 2, waitingOnOwner: 1),
            CompanySummary(company: globex, counts: counts(running: 0, ready: 3), unread: 3, waitingOnOwner: 0),
        ]
    }

    @Test func totalsAcrossCompanies() throws {
        let both = try pair()
        #expect(MenuBarSummary.make(companies: both, engine: nil).totals == "2 running · 4 ready across 2 companies")
        #expect(MenuBarSummary.make(companies: [both[0]], engine: nil).totals == "2 running · 1 ready across 1 company")
        #expect(MenuBarSummary.make(companies: both, engine: nil).anyRunningAgents)
        #expect(!MenuBarSummary.make(companies: [both[1]], engine: nil).anyRunningAgents)
    }

    @Test func pendingSumsWaitingAndUnread() throws {
        #expect(MenuBarSummary.make(companies: try pair(), engine: nil).pending == "1 waiting on you · 5 unread")
    }

    @Test func rowsToggleTitles() throws {
        let rows = MenuBarSummary.make(companies: try pair(), engine: nil).rows
        #expect(rows.map(\.toggleTitle) == ["Pause Acme", "Resume Globex"])
        #expect(rows.map(\.statusText) == ["Running · 2 running · 1 ready", "Paused"])
        #expect(rows.map(\.isRunning) == [true, false])
    }

    @Test(arguments: [(EngineStatus?.some(.embedded), "Engine: running in Brahma"),
                      (.some(.external), "Engine: running in terminal (brahma run)"),
                      (.some(.starting), "Engine: starting…"),
                      (.some(.stopped), "Engine: stopped"),
                      (.some(.stopping), "Engine: stopping…"),
                      (.some(.failed("x")), "Engine: stopped — x"),
                      (nil, "Engine: not started")])
    func engineLines(status: EngineStatus?, line: String) {
        #expect(MenuBarSummary.make(companies: [], engine: status).engine == line)
    }

    @Test func noCompanies() {
        #expect(MenuBarSummary.make(companies: [], engine: nil).totals == "No companies yet")
    }

    @Test func menuToggleDoesNotTouchOtherCompanies() async throws {
        let (store, paths) = try makeHome()
        let acme = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: paths.workspaces)
        let globex = try store.createCompany(name: "Globex", goal: "g", workspacesRoot: paths.workspaces)
        let model = AppModel(store: store, paths: paths)
        await model.load()
        await model.setCompanyRunning(false, companyId: globex.id)
        #expect(try store.company(id: globex.id)?.status == .paused)
        #expect(try store.company(id: acme.id)?.status == acme.status)
        let rows = model.menuBar.rows
        #expect(rows.first { $0.id == acme.id }?.toggleTitle == "Pause Acme")
        #expect(rows.first { $0.id == globex.id }?.toggleTitle == "Resume Globex")
    }

    /// Task 7c: the menu offers STOP EVERYTHING; while stopped it shows the stop line and Resume, and the app shows the banner.
    @Test func emergencyStopAndResume() async throws {
        let (store, paths) = try makeHome()
        _ = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: paths.workspaces)
        let model = AppModel(store: store, paths: paths)
        await model.load()
        #expect(!model.menuBar.stopped && model.menuBar.stopLine == nil && model.stopBanner == nil)
        await model.stopEverything()
        #expect(try store.engineStopped()?.by == "app")
        #expect(model.isStopped)
        #expect(model.menuBar.stopped)
        #expect(model.menuBar.stopLine?.hasPrefix("STOPPED by the owner since ") == true)
        #expect(model.stopBanner == "Everything is stopped. Resume when you're ready.")
        await model.resumeAfterStop()
        #expect(try store.engineStopped() == nil)
        #expect(!model.isStopped && model.stopBanner == nil && !model.menuBar.stopped)

        let row = EngineStopRow(since: Date(timeIntervalSince1970: 0), by: "cli", note: nil)
        let utc = try #require(TimeZone(identifier: "UTC"))
        #expect(MenuBarSummary.make(companies: [], engine: nil, stop: row, timeZone: utc).stopLine == "STOPPED by the owner since 00:00")
    }
}
