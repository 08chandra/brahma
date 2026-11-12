import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Plan 4b Task 1a: the read-only, company-scoped feeds the live map polls (messages, hand-offs, activity events).
/// Coverage of `message.kind` values and thread replies (`kindsAndThreadRepliesAreDrawn`, the kind = 'system' half of
/// `systemRowsExcluded`) is deferred until Collab-MVP adds message.kind/parentId.
@Suite(.scratch) struct MapFeedTests {
    private struct F {
        let store: Store
        let router: MessageRouter
        let acme: Company, globex: Company
        let ceo: Agent, cto: Agent, eng: Agent, gx: Agent
        let t0 = Store.now()

        init() throws {
            store = try Store.inMemory()
            router = MessageRouter(store: store)
            acme = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
            globex = try store.createCompany(name: "Globex", goal: "g", workspacesRoot: try tempDir())
            ceo = try store.hire(companyId: acme.id, name: "ceo", role: "r", model: "m")
            cto = try store.hire(companyId: acme.id, name: "cto", role: "r", model: "m")
            eng = try store.hire(companyId: acme.id, name: "eng", role: "r", model: "m")
            gx = try store.hire(companyId: globex.id, name: "gx", role: "r", model: "m")
        }

        func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

        @discardableResult
        func post(_ from: Sender, _ text: String, in channel: String = "general", company: Company? = nil, at: Date? = nil) throws -> Message {
            try router.post(companyId: (company ?? acme).id, channel: channel, from: from, text: text, now: at ?? t0)
        }
        @discardableResult
        func dm(_ from: Sender, to: String, _ text: String, company: Company? = nil, at: Date? = nil) throws -> Message {
            try router.sendDM(companyId: (company ?? acme).id, from: from, to: to, text: text, now: at ?? t0)
        }
        func live(_ company: Company? = nil, after: Int64 = 0, limit: Int = 500) throws -> [MessageFlow] {
            try store.messageFlows(companyId: (company ?? acme).id, afterRowId: after, limit: limit)
        }
        func flow(for message: Message) throws -> MessageFlow {
            try #require(try live(try #require(try store.company(id: message.companyId))).first { $0.messageId == message.id })
        }
        func item(_ company: Company) throws -> WorkItem {
            try store.createWorkItem(companyId: company.id, by: .owner, draft: WorkItemDraft(type: .task, title: "Parse", status: .ready), now: t0)
        }
    }

    @Test func dmFlowHasOtherMember() throws {
        let f = try F()
        let m = try f.dm(.owner, to: "cto", "hello")
        let flow = try f.flow(for: m)
        #expect(flow.senderId == "owner")
        #expect(flow.recipientIds == [f.cto.id])
        #expect(flow.channelKind == .dm)
        #expect(flow.kind == "text")
        #expect(flow.companyId == f.acme.id)
        #expect(flow.team == nil)
        #expect(flow.createdAt == f.t0)
        // An agent's DM to the owner points back at the owner.
        let back = try f.dm(.agent(f.cto.id), to: "owner", "hi")
        #expect(try f.flow(for: back).recipientIds == ["owner"])
    }

    @Test func channelFlowRecipientsAreMentions() throws {
        let f = try F()
        let m = try f.post(.agent(f.ceo.id), "@cto and @eng and @nobody")
        let flow = try f.flow(for: m)
        #expect(flow.recipientIds == [f.cto.id, f.eng.id])
        #expect(flow.channelKind == .channel)
        #expect(flow.channelName == "general")
        #expect(flow.senderId == f.ceo.id)
        // Mention order is kept.
        #expect(try f.flow(for: try f.post(.agent(f.ceo.id), "@eng then @cto")).recipientIds == [f.eng.id, f.cto.id])
        // A self-mention and a bare post resolve to nobody but the others.
        #expect(try f.flow(for: try f.post(.agent(f.ceo.id), "@ceo @cto")).recipientIds == [f.cto.id])
        #expect(try f.flow(for: try f.post(.agent(f.ceo.id), "no mentions")).recipientIds.isEmpty)
        // A killed agent is no longer a recipient.
        _ = try f.store.transition(agentId: f.eng.id, to: .killed)
        #expect(try f.flow(for: try f.post(.agent(f.ceo.id), "@cto and @eng")).recipientIds == [f.cto.id])
    }

    @Test func teamChannelSetsTeam() throws {
        let f = try F()
        _ = try f.store.createChannel(companyId: f.acme.id, name: "team-core", members: [f.ceo.id, f.cto.id])
        let core = try f.post(.agent(f.ceo.id), "@cto standup", in: "team-core")
        let general = try f.post(.agent(f.ceo.id), "@cto standup")
        #expect(try f.flow(for: core).team == "core")
        #expect(try f.flow(for: core).channelName == "team-core")
        #expect(try f.flow(for: general).team == nil)
    }

    @Test func cursorPagingIsAscendingAndExclusive() throws {
        let f = try F()
        var ids: [String] = []
        for i in 0..<5 { ids.append(try f.post(.agent(f.ceo.id), "m\(i)", at: f.at(Double(i))).id) }
        let all = try f.live()
        #expect(all.map(\.messageId) == ids)
        #expect(all.map(\.rowId) == all.map(\.rowId).sorted())
        let page = try f.live(after: all[0].rowId, limit: 2)
        #expect(page.map(\.messageId) == [ids[1], ids[2]])
        #expect(try f.live(after: all[4].rowId).isEmpty)
        #expect(try f.store.maxMessageRowId(companyId: f.acme.id) == all[4].rowId)
    }

    @Test func rangeQueriesAreHalfOpenAndTruncate() throws {
        let f = try F()
        let a = try f.post(.agent(f.ceo.id), "a", at: f.at(0))
        let b = try f.post(.agent(f.ceo.id), "b", at: f.at(1))
        _ = try f.post(.agent(f.ceo.id), "c", at: f.at(2))
        let r = try f.store.messageFlows(companyId: f.acme.id, since: f.at(0), until: f.at(2))
        #expect(r.flows.map(\.messageId) == [a.id, b.id])
        #expect(!r.truncated)
        let short = try f.store.messageFlows(companyId: f.acme.id, since: f.at(0), until: f.at(2), limit: 1)
        #expect(short.flows.map(\.messageId) == [a.id])
        #expect(short.truncated)
        #expect(try f.store.messageFlows(companyId: f.acme.id, since: f.at(2), until: f.at(2)).flows.isEmpty)
        #expect(try f.store.messageFlows(companyId: f.acme.id, since: f.at(1), until: f.at(10)).flows.count == 2)
    }

    @Test func systemRowsExcluded() throws {
        let f = try F()
        let before = try f.store.maxMessageRowId(companyId: f.acme.id)
        let ok = try f.post(.agent(f.ceo.id), "@cto real", at: f.at(0))
        var systemRowId: Int64 = 0
        try f.store.writer.write { db in
            let sys = try f.router.post(db: db, companyId: f.acme.id, channel: "general", from: .system, text: "@cto build is red", now: f.at(1))
            try f.router.sendDM(db: db, companyId: f.acme.id, from: .system, to: "cto", text: "look", now: f.at(1))
            systemRowId = try Int64.fetchOne(db, sql: "SELECT rowid FROM message WHERE id = ?", arguments: [sys.message.id]) ?? 0
        }
        // deferred until Collab-MVP adds message.kind/parentId: an agent post updated to kind 'system' is also excluded.
        let live = try f.live(after: before)
        #expect(live.map(\.messageId) == [ok.id])
        #expect(live.allSatisfy { $0.senderId != "system" })
        let range = try f.store.messageFlows(companyId: f.acme.id, since: f.at(0), until: f.at(10))
        #expect(range.flows.map(\.messageId) == [ok.id])
        // The cursor still advances past them: a cursor at a system row's rowid, or at the company max (which is the brief's
        // plain reverse rowid scan, so it sits past the system rows), reads nothing until real traffic arrives.
        let okRow = try f.flow(for: ok).rowId
        #expect(systemRowId > okRow)
        let max = try f.store.maxMessageRowId(companyId: f.acme.id)
        #expect(max >= systemRowId)
        #expect(try f.live(after: systemRowId).isEmpty)
        #expect(try f.live(after: max).isEmpty)
        let after = try f.post(.agent(f.ceo.id), "later", at: f.at(2))
        #expect(try f.live(after: systemRowId).map(\.messageId) == [after.id])
        #expect(try f.live(after: max).map(\.messageId) == [after.id])
        // maxMessageRowId ignores them: it is never pulled below a real row by them, and a later real row moves it.
        let afterRow = try f.flow(for: after).rowId
        #expect(try f.store.maxMessageRowId(companyId: f.acme.id) == afterRow)
    }

    @Test func handoffFeed() throws {
        let f = try F()
        #expect(try f.store.handoffFlows(companyId: f.acme.id, afterRowId: 0).isEmpty)
        #expect(try f.store.maxHandoffRowId(companyId: f.acme.id) == 0)
        let item = try f.item(f.acme)
        let h = try f.store.writeHandoff(itemId: item.id, by: .owner, draft: HandoffDraft(goal: "Finish", toAgentId: f.cto.id), now: f.at(1))
        let flows = try f.store.handoffFlows(companyId: f.acme.id, afterRowId: 0)
        #expect(flows.count == 1)
        let flow = try #require(flows.first)
        #expect(flow.id == h.id)
        #expect(flow.itemKey == item.key)
        #expect(flow.authorId == "owner")
        #expect(flow.toAgentId == f.cto.id)
        #expect(flow.createdAt == f.at(1))
        #expect(flow.rowId > 0)
        #expect(try f.store.maxHandoffRowId(companyId: f.acme.id) == flow.rowId)
        #expect(try f.store.handoffFlows(companyId: f.acme.id, afterRowId: flow.rowId).isEmpty)
        // Ranges are half-open on createdAt.
        #expect(try f.store.handoffFlows(companyId: f.acme.id, since: f.at(0), until: f.at(1)).isEmpty)
        #expect(try f.store.handoffFlows(companyId: f.acme.id, since: f.at(1), until: f.at(2)).map(\.id) == [h.id])
    }

    @Test func eventsFilteredByKindAndCompany() throws {
        let f = try F()
        let since = f.at(100)
        try f.store.appendEvent(ActivityEvent(companyId: f.acme.id, agentId: f.ceo.id, turnId: nil, kind: .stateChanged, text: "a", createdAt: f.at(100)))
        try f.store.appendEvent(ActivityEvent(companyId: f.acme.id, agentId: f.ceo.id, turnId: nil, kind: .toolUse, text: "b", createdAt: f.at(101)))
        try f.store.appendEvent(ActivityEvent(companyId: f.globex.id, agentId: f.gx.id, turnId: nil, kind: .stateChanged, text: "c", createdAt: f.at(100)))
        try f.store.appendEvent(ActivityEvent(companyId: f.acme.id, agentId: f.ceo.id, turnId: nil, kind: .stateChanged, text: "d", createdAt: f.at(110)))
        let events = try f.store.events(companyId: f.acme.id, kinds: [.stateChanged], since: since, until: f.at(110))
        #expect(events.map(\.text) == ["a"])
        #expect(try f.store.events(companyId: f.acme.id, kinds: [.stateChanged, .toolUse], since: since, until: f.at(111)).map(\.text) == ["a", "b", "d"])
        #expect(try f.store.events(companyId: f.acme.id, kinds: [.stateChanged], since: since, until: f.at(111), limit: 1).map(\.text) == ["a"])
        #expect(try f.store.events(companyId: f.acme.id, kinds: [], since: since, until: f.at(111)).isEmpty)
        #expect(try f.store.events(companyId: f.globex.id, kinds: [.stateChanged], since: since, until: f.at(111)).map(\.text) == ["c"])
    }

    @Test func feedsAreCompanyScoped() throws {
        let f = try F()
        let acmeMsg = try f.post(.agent(f.ceo.id), "@cto @gx hi", at: f.at(0))
        let acmeMax = try f.store.maxMessageRowId(companyId: f.acme.id)
        let acmeHandoffMax = try f.store.maxHandoffRowId(companyId: f.acme.id)
        let gxDM = try f.dm(.owner, to: "gx", "hello", company: f.globex, at: f.at(1))
        let gxPost = try f.post(.agent(f.gx.id), "@gx @cto hi", company: f.globex, at: f.at(1))
        let gxItem = try f.item(f.globex)
        let gxHandoff = try f.store.writeHandoff(itemId: gxItem.id, by: .owner, draft: HandoffDraft(goal: "Go", toAgentId: f.gx.id), now: f.at(1))

        // Acme's feeds do not see Globex rows, and its cursors do not move.
        let acmeLive = try f.live()
        #expect(acmeLive.map(\.messageId) == [acmeMsg.id])
        #expect(acmeLive.allSatisfy { $0.companyId == f.acme.id })
        #expect(try f.store.messageFlows(companyId: f.acme.id, since: f.at(0), until: f.at(10)).flows.map(\.messageId) == [acmeMsg.id])
        #expect(try f.store.maxMessageRowId(companyId: f.acme.id) == acmeMax)
        #expect(try f.store.handoffFlows(companyId: f.acme.id, afterRowId: 0).isEmpty)
        #expect(try f.store.handoffFlows(companyId: f.acme.id, since: f.at(0), until: f.at(10)).isEmpty)
        #expect(try f.store.maxHandoffRowId(companyId: f.acme.id) == acmeHandoffMax)
        // An @handle that exists only in Globex resolves to no Acme recipient, and vice versa.
        #expect(try f.flow(for: acmeMsg).recipientIds == [f.cto.id])
        #expect(try f.flow(for: gxPost).recipientIds.isEmpty)

        // Globex's own feeds contain its rows.
        let gxLive = try f.live(f.globex)
        #expect(Set(gxLive.map(\.messageId)) == [gxDM.id, gxPost.id])
        #expect(gxLive.allSatisfy { $0.companyId == f.globex.id })
        #expect(try f.flow(for: gxDM).recipientIds == [f.gx.id])
        #expect(try f.store.maxMessageRowId(companyId: f.globex.id) == gxLive.last?.rowId)
        #expect(try f.store.maxMessageRowId(companyId: f.globex.id) > acmeMax)
        let gxHandoffs = try f.store.handoffFlows(companyId: f.globex.id, afterRowId: 0)
        #expect(gxHandoffs.map(\.id) == [gxHandoff.id])
        #expect(gxHandoffs.first?.itemKey == gxItem.key)
        #expect(try f.store.maxHandoffRowId(companyId: f.globex.id) == gxHandoffs.first?.rowId)
    }
}
