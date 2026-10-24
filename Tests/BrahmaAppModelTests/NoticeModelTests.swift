import Testing
import Foundation
import BrahmaCore
@testable import BrahmaAppModel

/// Records banners; `accept` false plays a poster the system refuses (not authorized).
@MainActor
final class FakePoster: NotificationPosting {
    var posted: [PostedNotice] = []
    var accept = true
    func post(_ notice: PostedNotice) async -> Bool {
        guard accept else { return false }
        posted.append(notice)
        return true
    }
}

@MainActor @Suite struct NoticeModelTests {
    @Test func tickPostsAndMarks() async throws {
        let w = try await WorkWorld.make()
        var prefs = OwnerPrefs.defaults; prefs.quietEnabled = false
        try w.store.updateOwnerPrefs(prefs)
        let a = try w.ask(title: "First"), b = try w.ask(title: "Second")
        try w.store.notifyOwner(companyId: w.company.id, title: "Backup", body: "done")
        let noticeId = try #require(w.store.undeliveredNotices().first?.id)
        let poster = FakePoster()
        w.model.poster = poster

        // Delivery runs on every 4th tick only.
        for _ in 0..<(AppModel.deliveryEvery - 1) { await w.model.tick() }
        #expect(poster.posted.isEmpty)
        await w.model.tick()
        #expect(Set(poster.posted.map(\.id)) == ["ask-\(a.id)-0", "ask-\(b.id)-0", "notice-\(noticeId)"])
        let ask = try #require(poster.posted.first { $0.id == "ask-\(a.id)-0" })
        #expect(ask.target == "ask:\(a.id)" && ask.companyId == w.company.id && ask.title.hasPrefix("Acme: "))
        #expect(try w.store.dueAskNotices().isEmpty && w.store.undeliveredNotices().isEmpty)

        // Marked: four more ticks post nothing new.
        for _ in 0..<AppModel.deliveryEvery { await w.model.tick() }
        #expect(poster.posted.count == 3)

        // A refused post marks nothing; the banner is planned again once the poster accepts.
        let c = try w.ask(title: "Third")
        poster.accept = false
        try await w.model.deliverNotices()
        #expect(try w.store.dueAskNotices().map(\.ask.id) == [c.id])
        poster.accept = true
        await w.model.deliverNotices()
        #expect(poster.posted.last?.id == "ask-\(c.id)-0")
        #expect(try w.store.dueAskNotices().isEmpty)

        // With no poster nothing is delivered or marked.
        let d = try w.ask(title: "Fourth")
        w.model.poster = nil
        await w.model.deliverNotices()
        #expect(try w.store.dueAskNotices().map(\.ask.id) == [d.id])
    }

    @Test func quietHoursHoldBannersAtTheModel() async throws {
        let w = try await WorkWorld.make()
        var prefs = OwnerPrefs.defaults
        // A window that is always quiet right now: starts a minute ago, ends a minute from now (owner zone).
        let tz = w.store.ownerTimeZone()
        var cal = Calendar(identifier: .gregorian); cal.timeZone = tz
        func hm(_ d: Date) -> String { let c = cal.dateComponents([.hour, .minute], from: d); return String(format: "%02d:%02d", c.hour!, c.minute!) }
        prefs.quietStart = hm(Date().addingTimeInterval(-600)); prefs.quietEnd = hm(Date().addingTimeInterval(600))
        try w.store.updateOwnerPrefs(prefs)
        let a = try w.ask(title: "Later")
        let poster = FakePoster()
        w.model.poster = poster
        await w.model.deliverNotices()
        #expect(poster.posted.isEmpty)
        #expect(try w.store.dueAskNotices().map(\.ask.id) == [a.id])
    }

    @Test func menuBadgeCountsPendingAsks() async throws {
        let w = try await WorkWorld.make()
        let other = try w.store.createCompany(name: "Globex", goal: "g", workspacesRoot: w.paths.workspaces)
        let agent = try w.store.hire(companyId: other.id, name: "eng", role: "engineer", model: "sonnet")
        try w.ask(title: "One"); try w.ask(title: "Two")
        try w.store.propose(companyId: other.id, by: .agent(agent.id), kind: .other, risk: .high, category: "general", title: "Three",
                            summary: "s", payload: nil, viaOwner: true)
        await w.refresh()
        #expect(w.model.menuBar.badge == 3)
        #expect(MenuBarSummary.make(companies: [], engine: nil).badge == 0)
        await w.model.decide(askId: try #require(w.store.asks(companyId: w.company.id).first).id, approve: true)
        await w.refresh()
        #expect(w.model.menuBar.badge == 2)
    }

    @Test func askTargetSelectsInbox() async throws {
        #expect(SelectTarget("ask:AbC-1") == .ask(id: "AbC-1"))
        let w = try await WorkWorld.make()
        w.model.apply(.ask(id: "x1"))
        #expect(w.model.sidebarSelection == .inbox && w.model.highlightedAskId == "x1")
    }
}
