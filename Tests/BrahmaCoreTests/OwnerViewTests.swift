import Testing
import Foundation
@testable import BrahmaCore

@Suite(.scratch) struct OwnerViewTests {
    private struct World {
        let store: Store, router: MessageRouter, company: Company, general: Channel
        let ceo: Agent, cto: Agent
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func at(_ s: Double) -> Date { t0.addingTimeInterval(s) }
        init() throws {
            store = try Store(path: try tempDir().appending(path: "db.sqlite").path)
            router = MessageRouter(store: store)
            company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
            ceo = try store.hire(companyId: company.id, name: "ceo", role: "r", model: "m")
            cto = try store.hire(companyId: company.id, name: "cto", role: "r", model: "m")
            general = try #require(try store.channel(companyId: company.id, name: "general"))
        }
    }

    @Test func unreadCountsChannelsAndOwnerDMsOnly() throws {
        let w = try World()
        _ = try w.router.post(companyId: w.company.id, channel: "general", from: .agent(w.ceo.id), text: "a", now: w.at(1))
        _ = try w.router.post(companyId: w.company.id, channel: "general", from: .agent(w.ceo.id), text: "b", now: w.at(2))
        let toOwner = try w.router.sendDM(companyId: w.company.id, from: .agent(w.ceo.id), to: "owner", text: "c", now: w.at(3))
        _ = try w.router.sendDM(companyId: w.company.id, from: .agent(w.ceo.id), to: "cto", text: "d", now: w.at(4))
        _ = try w.router.post(companyId: w.company.id, channel: "general", from: .owner, text: "e", now: w.at(5))
        let counts = try w.store.unreadCounts(companyId: w.company.id)
        #expect(counts == [w.general.id: 2, toOwner.channelId: 1])
    }

    @Test func markReadIsMonotonic() throws {
        let w = try World()
        for (i, t) in ["1", "2", "3"].enumerated() {
            _ = try w.router.post(companyId: w.company.id, channel: "general", from: .agent(w.ceo.id), text: t, now: w.at(Double(i + 1)))
        }
        try w.store.markRead(channelId: w.general.id, upTo: w.at(2))
        try w.store.markRead(channelId: w.general.id, upTo: w.at(1))
        #expect(try w.store.unreadCounts(companyId: w.company.id)[w.general.id] == 1)
    }

    @Test func markReadAtNewestClearsChannel() throws {
        let w = try World()
        _ = try w.router.post(companyId: w.company.id, channel: "general", from: .agent(w.ceo.id), text: "a", now: w.at(1))
        let newest = try w.router.post(companyId: w.company.id, channel: "general", from: .agent(w.ceo.id), text: "b", now: w.at(2))
        try w.store.markRead(channelId: w.general.id, upTo: newest.createdAt)
        #expect(try w.store.unreadCounts(companyId: w.company.id)[w.general.id] == nil)
    }

    @Test func updateCompanyByIdReadsFresh() throws {
        let path = try tempDir().appending(path: "db.sqlite").path
        let a = try Store(path: path), b = try Store(path: path)
        let company = try a.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        let stale = try #require(try a.company(id: company.id))
        #expect(stale.priorityWeight != 3)
        try b.updateCompany(id: company.id) { $0.priorityWeight = 3 }
        let result = try a.updateCompany(id: company.id) { $0.usageMode = .max }
        let reloaded = try #require(try a.company(id: company.id))
        #expect(result == reloaded)
        #expect(reloaded.priorityWeight == 3)
        #expect(reloaded.usageMode == .max)
    }

    @Test func updateCompanyUnknownIdThrows() throws {
        let s = try Store.inMemory()
        #expect(throws: StoreError.notFound) { try s.updateCompany(id: "nope") { _ in } }
    }

    @Test func recentEventsReturnsNewestOldestFirst() throws {
        let s = try Store.inMemory()
        let a = try s.createCompany(name: "A", goal: "g", workspacesRoot: try tempDir())
        let b = try s.createCompany(name: "B", goal: "g", workspacesRoot: try tempDir())
        let now = Store.now()
        func ev(_ c: Company, _ t: String) throws {
            try s.appendEvent(ActivityEvent(companyId: c.id, agentId: nil, turnId: nil, kind: .message, text: t, createdAt: now))
        }
        try ev(a, "a1"); try ev(b, "b1"); try ev(a, "a2"); try ev(a, "a3"); try ev(b, "b2"); try ev(a, "a4"); try ev(a, "a5")
        #expect(try s.recentEvents(companyId: a.id, limit: 3).map(\.text) == ["a3", "a4", "a5"])
    }
}
