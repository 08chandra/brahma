import Testing
import Foundation
import GRDB
@testable import BrahmaCore

@Suite struct WakeTests {
    private let software = PackCatalog.builtin.pack("software")!

    private struct World {
        let store: Store, router: MessageRouter, company: Company, agents: [Agent]
        func agent(_ handle: String) throws -> Agent { try #require(agents.first { $0.name == handle }) }
        func ready() throws -> [String] {
            try store.agents(companyId: company.id).filter { $0.state == .ready }.map(\.name).sorted()
        }
        func inboxRows(wakes: Bool) throws -> Int {
            try store.writer.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM inboxItem WHERE wakes = ?", arguments: [wakes]) ?? 0
            }
        }
    }

    private func world(count: Int = 300) throws -> World {
        let store = try Store.inMemory()
        let company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        let plan = try OrgGenerator.generate(goal: "g", count: count, pack: software)
        let agents = try store.applyOrg(companyId: company.id, plan: plan, pack: software)
        return World(store: store, router: MessageRouter(store: store), company: company, agents: agents)
    }

    @Test func generalPostWakesNobodyAt300() throws {
        let w = try world()
        #expect(w.agents.count == 300)
        _ = try w.router.post(companyId: w.company.id, channel: "general", from: .owner, text: "hello everyone")
        #expect(try w.ready().isEmpty)
        #expect(try w.inboxRows(wakes: false) == 300); #expect(try w.inboxRows(wakes: true) == 0)
        for a in w.agents.prefix(20) { #expect(try w.store.pendingInbox(agentId: a.id).isEmpty) }
        _ = try w.router.post(companyId: w.company.id, channel: "general", from: .agent(try w.agent("eng-1").id), text: "fyi")
        #expect(try w.ready().isEmpty)
    }

    @Test func mentionWakesExactlyOne() throws {
        let w = try world()
        _ = try w.router.post(companyId: w.company.id, channel: "general", from: .owner, text: "@eng-7 please look")
        #expect(try w.ready() == ["eng-7"])
        let pending = try w.store.pendingInbox(agentId: try w.agent("eng-7").id)
        #expect(pending.count == 1 && pending[0].0.wakes)
        #expect(try w.store.pendingInbox(agentId: try w.agent("eng-8").id).isEmpty)
    }

    @Test func dmAlwaysWakes() throws {
        let w = try world()
        _ = try w.router.sendDM(companyId: w.company.id, from: .agent(try w.agent("eng-1").id), to: "eng-2", text: "hi")
        _ = try w.router.sendDM(companyId: w.company.id, from: .owner, to: "eng-3", text: "hi")
        #expect(try w.ready() == ["eng-2", "eng-3"])
    }

    @Test func broadcastRules() throws {
        let w = try world()
        let lead = try w.agent("mgr-1")
        let team = try #require(lead.team)
        let teammates = w.agents.filter { $0.team == team && $0.id != lead.id }.map(\.name).sorted()
        #expect(teammates.count > 1)
        let r = try w.router.postDetailed(companyId: w.company.id, channel: "general", from: .agent(lead.id), text: "@team standup")
        #expect(r.broadcastApplied == true); #expect(r.broadcastRefusal == nil)
        #expect(try w.ready() == teammates)

        // An engineer's @here is refused, and still wakes nobody (the message is posted).
        let w2 = try world()
        let eng = try w2.agent("eng-1")
        let refused = try w2.router.postDetailed(companyId: w2.company.id, channel: "general", from: .agent(eng.id), text: "@here urgent")
        #expect(refused.broadcastApplied == false)
        #expect(refused.broadcastRefusal == "@here was not applied: only managers and executives can broadcast, 2 per hour.")
        #expect(try w2.ready().isEmpty)
        let refusedTeam = try w2.router.postDetailed(companyId: w2.company.id, channel: "general", from: .agent(eng.id), text: "@team urgent")
        #expect(refusedTeam.broadcastRefusal == "@team was not applied: only managers and executives can broadcast, 2 per hour.")
        let plain = try w2.router.postDetailed(companyId: w2.company.id, channel: "general", from: .agent(eng.id), text: "nothing")
        #expect(plain.broadcastApplied == nil && plain.broadcastRefusal == nil)

        // The owner's @here wakes everyone, with no limit.
        for _ in 0..<3 {
            let o = try w2.router.postDetailed(companyId: w2.company.id, channel: "general", from: .owner, text: "@here all hands")
            #expect(o.broadcastApplied == true)
        }
        #expect(try w2.ready().count == 300)
    }

    @Test func broadcastRateLimited() throws {
        let w = try world(count: 30)
        let lead = try w.agent("mgr-1")
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)
        func shout(_ at: TimeInterval) throws -> PostResult {
            try w.router.postDetailed(companyId: w.company.id, channel: "general", from: .agent(lead.id), text: "@here go", now: t0 + at)
        }
        #expect(try shout(0).broadcastApplied == true)
        #expect(try shout(10).broadcastApplied == true)
        try w.store.writer.write { db in try db.execute(sql: "UPDATE agent SET state = 'sleeping'") }
        let third = try shout(20)
        #expect(third.broadcastApplied == false)
        #expect(try w.ready().isEmpty)
        #expect(try shout(3601).broadcastApplied == true)
        #expect(try w.ready().count == 29)
    }

    @Test func systemPostsNeverWake() throws {
        let w = try world(count: 30)
        let r = try w.router.postDetailed(companyId: w.company.id, channel: "general", from: .system, text: "@eng-1 @here maintenance")
        #expect(r.message.senderId == "system")
        #expect(try w.ready().isEmpty)
        #expect(try w.inboxRows(wakes: true) == 0)
        #expect(WakePolicy.broadcast(in: "@here and @team") == .here)
        // A system DM wakes its recipient.
        _ = try w.router.sendDM(companyId: w.company.id, from: .system, to: "eng-2", text: "note")
        #expect(try w.ready() == ["eng-2"])
        let dm = try #require(try w.store.channel(companyId: w.company.id, name: "dm:eng-2:system"))
        #expect(dm.kind == .dm)
    }

    @Test func blockedOnSenderStillWakes() throws {
        let w = try world(count: 30)
        let a = try w.agent("eng-1"), b = try w.agent("eng-2")
        try w.store.transition(agentId: a.id, to: .blocked, blocker: .agent(b.id))
        _ = try w.router.post(companyId: w.company.id, channel: "general", from: .agent(b.id), text: "done")
        #expect(try w.store.agent(id: a.id)?.state == .ready)
        let wakes = try w.store.writer.read { db in
            try Bool.fetchOne(db, sql: "SELECT wakes FROM inboxItem WHERE agentId = ?", arguments: [a.id])
        }
        #expect(wakes == true)
    }

    @Test func unreadChannelLineAndDelivery() async throws {
        let store = try Store.inMemory()
        let company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        let ceo = try store.hire(companyId: company.id, name: "ceo", role: "ceo", model: "auto")
        let cto = try store.hire(companyId: company.id, name: "cto", role: "cto", model: "auto")
        let router = MessageRouter(store: store)
        _ = try store.createChannel(companyId: company.id, name: "team-1", members: [ceo.id, cto.id])
        for i in 0..<12 { _ = try router.post(companyId: company.id, channel: "general", from: .owner, text: "g\(i)") }
        for i in 0..<3 { _ = try router.post(companyId: company.id, channel: "team-1", from: .agent(cto.id), text: "t\(i)") }
        _ = try router.sendDM(companyId: company.id, from: .owner, to: "ceo", text: "direct")
        let counts = try store.pendingChannelCounts(agentId: ceo.id)
        #expect(counts.map(\.channel) == ["general", "team-1"]); #expect(counts.map(\.count) == [12, 3])
        let items = try store.pendingInbox(agentId: ceo.id)
        #expect(items.map { $0.1.text } == ["direct"])
        let digest = InboxDigest.render(agent: ceo, company: company, items: items, handles: [:], unread: counts)
        #expect(digest.contains("Unread in channels (not addressed to you): #general 12, #team-1 3 — use read_channel if relevant."))
        let none = InboxDigest.render(agent: ceo, company: company, items: items, handles: [:], unread: [])
        #expect(!none.contains("Unread in channels"))
        let many = (1...12).map { (channel: "c\($0)", count: 1) }
        #expect(InboxDigest.render(agent: ceo, company: company, items: items, handles: [:], unread: many).contains("c10 1"))
        #expect(!InboxDigest.render(agent: ceo, company: company, items: items, handles: [:], unread: many).contains("c11"))

        // A successful turn marks every item present at turn start delivered, waking or not.
        let (_, turn) = try #require(try store.beginTurn(agentId: ceo.id, now: Store.now()))
        let quiet = try store.pendingQuietItemIds(agentId: ceo.id)
        #expect(quiet.count == 15)
        try store.endTurn(agentId: ceo.id, turn: turn, end: .succeeded(TurnResult(isError: false, subtype: "success", text: "ok", costUSD: nil, apiErrorStatus: nil, sessionId: "s"), usageHold: nil),
                          deliveredItemIds: items.compactMap(\.0.id) + quiet, now: Store.now())
        #expect(try store.pendingChannelCounts(agentId: ceo.id).isEmpty)
        #expect(try store.pendingInbox(agentId: ceo.id).isEmpty)
        // Nothing waking is left, so the agent sleeps.
        #expect(try store.agent(id: ceo.id)?.state == .sleeping)
    }

    @Test func reservedBroadcastHandles() throws {
        let s = try Store.inMemory()
        let c = try s.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        for h in ["here", "team", "HERE", "Team"] {
            #expect(throws: StoreError.invalidName) { try s.hire(companyId: c.id, name: h, role: "x", model: "auto") }
        }
    }
}
