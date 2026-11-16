import Testing
import Foundation
import BrahmaCore
@testable import BrahmaAppModel

@MainActor @Suite(.scratch) struct SearchModelTests {
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

    // MARK: Plan ML: memory-wide owner search

    @Test func searchGroupsIncludeMemorySources() async throws {
        let w = try world()
        let paths = w.model.paths
        _ = try MessageRouter(store: w.store).post(companyId: w.acme.id, channel: "general", from: .owner, text: "checkout is slow")
        for i in 1...7 {
            _ = try w.store.createWorkItem(companyId: w.acme.id, by: .owner,
                                           draft: WorkItemDraft(type: .task, title: "Checkout step \(i)"))
        }
        _ = try MemoryIngest.run(store: w.store, companyId: w.acme.id, paths: paths, now: Store.now())
        try w.store.kbWrite(companyId: w.acme.id, by: .owner, path: "Engineering/Checkout", body: "# Checkout\n\nThe checkout flow.",
                            knownValues: [], paths: paths)
        _ = try w.store.remember(companyId: w.acme.id, by: w.ceo.id, fact: "Checkout uses Stripe", scope: .company, knownValues: [],
                                 paths: paths)
        let search = SearchModel(store: w.store)
        search.query = "checkout"
        try await search.run(companyId: w.acme.id)
        #expect(search.hits.map(\.message.text) == ["checkout is slow"])
        #expect(search.groups.map(\.title) == ["ITEMS", "HANDBOOK", "MEMORY"])
        #expect(search.groups.allSatisfy { $0.hits.count <= SearchModel.groupLimit && !$0.hits.isEmpty })
        #expect(search.groups.first { $0.title == "ITEMS" }?.hits.count == 5)
        #expect(search.groups.first { $0.title == "HANDBOOK" }?.hits.first?.ref.hasPrefix("kb:Engineering/Checkout") == true)
        #expect(search.groups.first { $0.title == "MEMORY" }?.hits.first?.ref == "mem:1")
        #expect(SearchModel.groupOrder == ["ITEMS", "ASKS", "HANDBOOK", "RESOURCES", "MEMORY"])
        // Opening a handbook hit opens the page.
        await w.model.load()
        let hit = try #require(search.groups.first { $0.title == "HANDBOOK" }?.hits.first)
        await w.model.open(memoryHit: hit)
        #expect(w.model.sidebarSelection == .handbook)
        #expect(w.model.handbook?.selection == "Engineering/Checkout")
        // A blank query clears the groups too.
        search.query = " "
        try await search.run(companyId: w.acme.id)
        #expect(search.groups.isEmpty)
    }

    @Test func staleMemoryResultsDropped() async throws {
        let w = try world()
        let paths = w.model.paths
        try w.store.kbWrite(companyId: w.acme.id, by: .owner, path: "Engineering/Alpha", body: "# Alpha\n\nalpha notes",
                            knownValues: [], paths: paths)
        try w.store.kbWrite(companyId: w.acme.id, by: .owner, path: "Engineering/Beta", body: "# Beta\n\nbeta notes",
                            knownValues: [], paths: paths)
        let gate = Gate()
        let search = SearchModel(store: w.store)
        search.beforeSearch = { query in if query == "alpha" { await gate.wait() } }
        search.query = "alpha"
        let first = Task { try await search.run(companyId: w.acme.id) }
        try await eventually { gate.isWaiting }
        search.query = "beta"
        try await search.run(companyId: w.acme.id)
        #expect(search.groups.flatMap(\.hits).map(\.ref).contains { $0.hasPrefix("kb:Engineering/Beta") })
        gate.open()
        try await first.value
        // The older run finished last; its results are dropped.
        let refs = search.groups.flatMap(\.hits).map(\.ref)
        #expect(!refs.contains { $0.hasPrefix("kb:Engineering/Alpha") })
        #expect(refs.contains { $0.hasPrefix("kb:Engineering/Beta") })
        #expect(search.isSearching == false)
    }
}

/// Holds a search until the test opens it.
final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var waiting = false
    private var opened = false
    private var continuation: CheckedContinuation<Void, Never>?

    var isWaiting: Bool { lock.withLock { waiting } }

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let resume: Bool = lock.withLock {
                if opened { return true }
                waiting = true
                continuation = c
                return false
            }
            if resume { c.resume() }
        }
    }

    func open() {
        let c: CheckedContinuation<Void, Never>? = lock.withLock {
            opened = true
            defer { continuation = nil }
            return continuation
        }
        c?.resume()
    }
}
