import Testing
import Foundation
@testable import BrahmaCore

private struct World {
    let store: Store; let router: MessageRouter; let company: Company
    let ceo: Agent, cto: Agent, eng: Agent
    init(path: String? = nil) throws {
        store = try path.map { try Store(path: $0) } ?? Store.inMemory()
        router = MessageRouter(store: store)
        company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        ceo = try store.hire(companyId: company.id, name: "ceo", role: "r", model: "m")
        cto = try store.hire(companyId: company.id, name: "cto", role: "r", model: "m")
        eng = try store.hire(companyId: company.id, name: "eng1", role: "r", model: "m")
    }
    func pending(_ a: Agent) throws -> Int { try store.pendingInbox(agentId: a.id).count }
    func state(_ a: Agent) throws -> AgentState { try store.agent(id: a.id)!.state }
}

@Test func generalExistsWithOwnerAndHiredAgents() throws {
    let w = try World()
    let g = try #require(try w.store.channel(companyId: w.company.id, name: "#General"))
    #expect(Set(try w.store.members(channelId: g.id)) == ["owner", w.ceo.id, w.cto.id, w.eng.id])
    #expect(throws: StoreError.duplicateName) { try w.store.createChannel(companyId: w.company.id, name: "#GENERAL", members: []) }
}

@Test func channelPostFansOutToMembersExceptSender() throws {
    let w = try World()
    _ = try w.router.post(companyId: w.company.id, channel: "general", from: .agent(w.ceo.id), text: "hello")
    // Membership no longer wakes: every member gets an inbox item, but a quiet one (counted, not delivered).
    #expect(try w.pending(w.cto) == 0); #expect(try w.pending(w.eng) == 0); #expect(try w.pending(w.ceo) == 0)
    #expect(try w.store.pendingChannelCounts(agentId: w.cto.id).map(\.count) == [1])
    #expect(try w.store.pendingChannelCounts(agentId: w.eng.id).map(\.count) == [1])
    #expect(try w.store.pendingChannelCounts(agentId: w.ceo.id).isEmpty)
    #expect(try w.state(w.cto) == .sleeping)
    let ev = try w.store.events(afterId: 0).last { $0.kind == .message }
    #expect(ev?.text == "#general @ceo: hello")
}

@Test func postWakesSleepingButNotPaused() throws {
    let w = try World()
    var eng = w.eng; eng.paused = true; try w.store.save(eng)
    _ = try w.router.post(companyId: w.company.id, channel: "general", from: .agent(w.ceo.id), text: "@cto @eng1 hi")
    #expect(try w.state(w.cto) == .ready)
    #expect(try w.state(w.eng) == .sleeping); #expect(try w.pending(w.eng) == 1)
}

@Test func mentionReachesNonMember() throws {
    let w = try World()
    let ch = try w.store.createChannel(companyId: w.company.id, name: "exec", members: [w.ceo.id, w.cto.id])
    _ = try w.router.post(companyId: w.company.id, channel: "exec", from: .agent(w.ceo.id), text: "@Eng1, ping")
    #expect(try w.pending(w.eng) == 1)
    #expect(!(try w.store.members(channelId: ch.id)).contains(w.eng.id))
}

@Test func mentionParsing() {
    #expect(MessageRouter.mentions(in: "hi @a, @B-2. mail x@y.com @owner!") == ["a", "b-2", "owner"])
}

@Test func postErrors() throws {
    let w = try World()
    #expect(throws: RouterError.unknownChannel("nope")) { try w.router.post(companyId: w.company.id, channel: "nope", from: .owner, text: "x") }
    _ = try w.store.createChannel(companyId: w.company.id, name: "exec", members: [w.ceo.id])
    #expect(throws: RouterError.notAMember) { try w.router.post(companyId: w.company.id, channel: "exec", from: .agent(w.cto.id), text: "x") }
    #expect(throws: RouterError.unknownAgent("zed")) { try w.router.sendDM(companyId: w.company.id, from: .owner, to: "zed", text: "x") }
}

@Test func dmCreatesSortedChannelOnce() throws {
    let w = try World()
    _ = try w.router.sendDM(companyId: w.company.id, from: .agent(w.cto.id), to: "ceo", text: "a")
    _ = try w.router.sendDM(companyId: w.company.id, from: .agent(w.ceo.id), to: "cto", text: "b")
    let dms = try w.store.channels(companyId: w.company.id).filter { $0.kind == .dm }
    #expect(dms.map(\.name) == ["dm:ceo:cto"])
    #expect(try w.store.messages(channelId: dms[0].id, limit: 10).map(\.text) == ["a", "b"])
    #expect(try w.pending(w.ceo) == 1); #expect(try w.pending(w.cto) == 1); #expect(try w.pending(w.eng) == 0)
}

@Test func replyUnblocksAgentWaitingOnSender() throws {
    let w = try World()
    try w.store.transition(agentId: w.eng.id, to: .blocked, blocker: .agent(w.cto.id))
    try w.store.transition(agentId: w.ceo.id, to: .blocked, blocker: .agent(w.cto.id))
    _ = try w.router.sendDM(companyId: w.company.id, from: .agent(w.cto.id), to: "eng1", text: "done")
    #expect(try w.state(w.eng) == .ready)
    #expect(try w.state(w.ceo) == .blocked)
}

@Test func blockedOnOtherAgentIsNotWokenByStranger() throws {
    let w = try World()
    try w.store.transition(agentId: w.eng.id, to: .blocked, blocker: .agent(w.cto.id))
    _ = try w.router.sendDM(companyId: w.company.id, from: .agent(w.ceo.id), to: "eng1", text: "yo")
    #expect(try w.state(w.eng) == .blocked); #expect(try w.pending(w.eng) == 1)
}

@Test func ownerMessageUnblocksOwnerBlocker() throws {
    let w = try World()
    try w.store.transition(agentId: w.eng.id, to: .blocked, blocker: .owner(reason: "key"))
    _ = try w.router.sendDM(companyId: w.company.id, from: .agent(w.cto.id), to: "eng1", text: "x")
    #expect(try w.state(w.eng) == .blocked)
    _ = try w.router.sendDM(companyId: w.company.id, from: .owner, to: "eng1", text: "here is the key")
    #expect(try w.state(w.eng) == .ready)
}

@Test func markDeliveredOnlyAffectsGivenItems() throws {
    let w = try World()
    _ = try w.router.post(companyId: w.company.id, channel: "general", from: .agent(w.ceo.id), text: "@cto one")
    _ = try w.router.post(companyId: w.company.id, channel: "general", from: .agent(w.ceo.id), text: "@cto two")
    let items = try w.store.pendingInbox(agentId: w.cto.id)
    #expect(items.map { $0.1.text } == ["@cto one", "@cto two"])
    try w.store.markDelivered(itemIds: [items[0].0.id!], turnId: "t1")
    #expect(try w.store.pendingInbox(agentId: w.cto.id).map { $0.1.text } == ["@cto two"])
    #expect(try w.pending(w.eng) == 0)
    #expect(try w.store.pendingChannelCounts(agentId: w.eng.id).map(\.count) == [2])
}

@Test func searchFindsByWord() throws {
    let w = try World()
    _ = try w.router.post(companyId: w.company.id, channel: "general", from: .owner, text: "stripe webhooks please")
    _ = try w.router.post(companyId: w.company.id, channel: "general", from: .owner, text: "unrelated")
    #expect(try w.store.searchMessages(companyId: w.company.id, query: "webhooks").map(\.text) == ["stripe webhooks please"])
    #expect(try w.store.searchMessages(companyId: w.company.id, query: "\"( AND").isEmpty)
}

@Test func invalidSendersAreRejectedAndCreateNothing() throws {
    let w = try World()
    let other = try w.store.createCompany(name: "Other", goal: "g", workspacesRoot: try tempDir())
    let stranger = try w.store.hire(companyId: other.id, name: "evil", role: "r", model: "m")
    try w.store.transition(agentId: w.eng.id, to: .killed)
    let before = try w.store.events(afterId: 0).count
    #expect(throws: RouterError.invalidSender) {
        try w.router.post(companyId: w.company.id, channel: "general", from: .agent(stranger.id), text: "x")
    }
    #expect(throws: RouterError.invalidSender) {
        try w.router.sendDM(companyId: w.company.id, from: .agent(stranger.id), to: "ceo", text: "x")
    }
    #expect(throws: RouterError.invalidSender) {
        try w.router.post(companyId: w.company.id, channel: "general", from: .agent(w.eng.id), text: "x")
    }
    #expect(throws: RouterError.invalidSender) {
        try w.router.sendDM(companyId: w.company.id, from: .agent(w.eng.id), to: "ceo", text: "x")
    }
    #expect(throws: RouterError.invalidSender) {
        try w.router.post(companyId: w.company.id, channel: "general", from: .agent("nope"), text: "x")
    }
    let g = try #require(try w.store.channel(companyId: w.company.id, name: "general"))
    #expect(try w.store.messages(channelId: g.id, limit: 10).isEmpty)
    #expect(try w.pending(w.ceo) == 0)
    #expect(try w.store.channels(companyId: w.company.id).filter { $0.kind == .dm }.isEmpty)
    #expect(try w.store.events(afterId: 0).count == before)
}

@Test func selfDMIsRejected() throws {
    let w = try World()
    #expect(throws: RouterError.invalidSender) { try w.router.sendDM(companyId: w.company.id, from: .agent(w.cto.id), to: "cto", text: "x") }
    #expect(throws: RouterError.invalidSender) { try w.router.sendDM(companyId: w.company.id, from: .owner, to: "@owner", text: "x") }
    #expect(try w.store.channels(companyId: w.company.id).filter { $0.kind == .dm }.isEmpty)
}

@Test func concurrentWritersDoNotLock() async throws {
    let path = try tempDir().appending(path: "c.sqlite").path
    let w = try World(path: path)
    let stores = try (0..<8).map { _ in try Store(path: path) }
    let companyId = w.company.id
    try await withThrowingTaskGroup(of: Void.self) { group in
        for (i, s) in stores.enumerated() {
            group.addTask {
                let r = MessageRouter(store: s)
                for n in 0..<50 { _ = try r.post(companyId: companyId, channel: "general", from: .owner, text: "w\(i) m\(n)") }
            }
        }
        try await group.waitForAll()
    }
    let g = try #require(try w.store.channel(companyId: companyId, name: "general"))
    #expect(try w.store.messages(channelId: g.id, limit: 1000).count == 400)
}

@Test func sendDMCannotReuseNonDMOrWrongMemberChannel() throws {
    let w = try World()
    // A squatted non-DM channel occupying the DM name must not be reused.
    try w.store.writer.write { db in
        try Store.insertChannel(db, companyId: w.company.id, name: "dm:cto:owner", kind: .channel,
                                members: [w.eng.id], now: Date())
    }
    #expect(throws: RouterError.invalidChannel("dm:cto:owner")) {
        try w.router.sendDM(companyId: w.company.id, from: .agent(w.cto.id), to: "owner", text: "secret")
    }
    // A DM-kind channel with an extra member is also rejected.
    try w.store.writer.write { db in
        try Store.insertChannel(db, companyId: w.company.id, name: "dm:ceo:cto", kind: .dm,
                                members: [w.ceo.id, w.cto.id, w.eng.id], now: Date())
    }
    #expect(throws: RouterError.invalidChannel("dm:ceo:cto")) {
        try w.router.sendDM(companyId: w.company.id, from: .agent(w.ceo.id), to: "cto", text: "x")
    }
    #expect(try w.pending(w.eng) == 0)
}
