import Testing
import Foundation
import BrahmaCore
@testable import BrahmaAppModel

@MainActor @Suite struct SearchModelTests {
    func world() throws -> (model: AppModel, store: Store, acme: Company, ceo: Agent, general: Channel) {
        let (store, paths) = try makeHome()
        let (acme, ceo, _, _) = try seedAcme(store, paths)
        let general = try #require(try store.channel(companyId: acme.id, name: "general"))
        return (AppModel(store: store, paths: paths), store, acme, ceo, general)
    }

    @Test func findsAcrossChannelsAndDMs() async throws {
        let w = try world()
        let r = MessageRouter(store: w.store)
        _ = try r.post(companyId: w.acme.id, channel: "general", from: .agent(w.ceo.id), text: "stripe webhooks")
        _ = try r.sendDM(companyId: w.acme.id, from: .agent(w.ceo.id), to: "owner", text: "stripe keys")
        let search = SearchModel(store: w.store)
        search.query = "stripe"
        try await search.run(companyId: w.acme.id)
        #expect(search.hits.count == 2)
        #expect(Set(search.hits.map(\.channelTitle)) == ["#general", "@ceo"])
        #expect(Set(search.hits.map(\.target)) == [.channel(id: w.general.id), .dm(handle: "ceo")])
        #expect(Set(search.hits.map(\.senderHandle)) == ["ceo"])
        #expect(search.isSearching == false)
    }

    @Test func blankQueryClears() async throws {
        let w = try world()
        _ = try MessageRouter(store: w.store).post(companyId: w.acme.id, channel: "general", from: .owner, text: "stripe")
        let search = SearchModel(store: w.store)
        search.query = "stripe"
        try await search.run(companyId: w.acme.id)
        #expect(search.hits.count == 1)
        search.query = "   "
        try await search.run(companyId: w.acme.id)
        #expect(search.hits == [])
    }

    @Test func ftsSyntaxIsSafe() async throws {
        let w = try world()
        await w.model.load()
        w.model.search.query = "\"stripe AND ("
        await w.model.runSearch()
        #expect(w.model.errorMessage == nil)
    }

    @Test func scopedToCompany() async throws {
        let w = try world()
        let globex = try #require(try w.store.companies().first { $0.name == "Globex" })
        _ = try MessageRouter(store: w.store).post(companyId: globex.id, channel: "general", from: .owner, text: "stripe in globex")
        _ = try MessageRouter(store: w.store).post(companyId: w.acme.id, channel: "general", from: .owner, text: "stripe in acme")
        let search = SearchModel(store: w.store)
        search.query = "stripe"
        try await search.run(companyId: w.acme.id)
        #expect(search.hits.map(\.message.text) == ["stripe in acme"])
    }

    @Test func openHitSelectsConversationAndHighlights() async throws {
        let w = try world()
        await w.model.load()
        let m = try MessageRouter(store: w.store).sendDM(companyId: w.acme.id, from: .agent(w.ceo.id), to: "owner", text: "stripe keys")
        w.model.search.query = "stripe"
        await w.model.runSearch()
        let hit = try #require(w.model.search.hits.first)
        await w.model.open(hit)
        #expect(w.model.sidebarSelection == hit.target)
        #expect(w.model.sidebarSelection == .dm(handle: "ceo"))
        #expect(w.model.highlightedMessageId == m.id)
        #expect(w.model.search.query == "")
        #expect(w.model.chat?.messages.contains { $0.id == m.id } == true)
    }

    @Test func openOldHitLoadsEarlierPages() async throws {
        let w = try world()
        await w.model.load()
        let r = MessageRouter(store: w.store)
        let t0 = Date(timeIntervalSince1970: 1_000)
        var ids: [String] = []
        for i in 0..<450 {
            let text = i == 9 ? "needle message" : "filler \(i)"
            ids.append(try r.post(companyId: w.acme.id, channel: "general", from: .owner, text: text, now: t0 + Double(i)).id)
        }
        w.model.search.query = "needle"
        await w.model.runSearch()
        let hit = try #require(w.model.search.hits.first)
        #expect(hit.id == ids[9])
        await w.model.open(hit)
        #expect(w.model.chat?.messages.contains { $0.id == ids[9] } == true)
        #expect(w.model.highlightedMessageId == ids[9])
    }
}
