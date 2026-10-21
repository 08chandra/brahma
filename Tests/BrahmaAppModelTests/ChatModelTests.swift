import Testing
import Foundation
import BrahmaCore
@testable import BrahmaAppModel

@MainActor @Suite struct ChatModelTests {
    func world() throws -> (store: Store, paths: BrahmaPaths, acme: Company, ceo: Agent, cto: Agent, general: Channel) {
        let (store, paths) = try makeHome()
        let (acme, ceo, cto, _) = try seedAcme(store, paths)
        let general = try #require(try store.channel(companyId: acme.id, name: "general"))
        return (store, paths, acme, ceo, cto, general)
    }

    @Test func loadsChannelOldestFirstWithHandles() async throws {
        let w = try world()
        let r = MessageRouter(store: w.store)
        let t0 = Date(timeIntervalSince1970: 1_000)
        _ = try r.post(companyId: w.acme.id, channel: "general", from: .agent(w.ceo.id), text: "one", now: t0)
        _ = try r.post(companyId: w.acme.id, channel: "general", from: .owner, text: "two", now: t0 + 1)
        _ = try r.post(companyId: w.acme.id, channel: "general", from: .agent(w.cto.id), text: "three", now: t0 + 2)
        let chat = ChatModel(store: w.store, companyId: w.acme.id, target: .channel(id: w.general.id))
        await chat.refresh()
        #expect(chat.messages.map(\.senderHandle) == ["ceo", "owner", "cto"])
        #expect(chat.messages.map(\.isOwner) == [false, true, false])
        #expect(chat.title == "#general")
        #expect(chat.handles == ["ceo", "cto", "eng"])
        #expect(chat.readOnlyReason == nil)
    }

    @Test func sendPostsAsOwnerAndClearsDraft() async throws {
        let w = try world()
        let chat = ChatModel(store: w.store, companyId: w.acme.id, target: .channel(id: w.general.id))
        await chat.refresh()
        chat.draft = "  @ceo hi  "
        #expect(await chat.send())
        let last = try #require(chat.messages.last)
        #expect(last.message.senderId == "owner")
        #expect(last.message.text == "@ceo hi")
        #expect(try w.store.pendingInbox(agentId: w.ceo.id).count == 1)
        #expect(chat.draft == "")
        #expect(chat.sendError == nil)
    }

    @Test func concurrentSendsPostOnce() async throws {
        let w = try world()
        let chat = ChatModel(store: w.store, companyId: w.acme.id, target: .channel(id: w.general.id))
        await chat.refresh()
        chat.draft = "@ceo once"
        async let first = chat.send()
        async let second = chat.send()
        let results = await [first, second]
        #expect(results.filter { $0 }.count == 1)
        #expect(try w.store.messages(channelId: w.general.id, limit: 10).count == 1)
        #expect(try w.store.pendingInbox(agentId: w.ceo.id).count == 1)
        #expect(chat.draft == "")
    }

    @Test func textTypedDuringSendIsKept() async throws {
        let w = try world()
        let chat = ChatModel(store: w.store, companyId: w.acme.id, target: .channel(id: w.general.id))
        await chat.refresh()
        chat.draft = "first"
        let sending = Task { await chat.send() }
        await Task.yield()
        chat.draft = "second"
        #expect(await sending.value)
        #expect(chat.draft == "second")
        #expect(try w.store.messages(channelId: w.general.id, limit: 10).map(\.text) == ["first"])
    }

    @Test func sendBeforeLoadDoesNothing() async throws {
        let w = try world()
        let chat = ChatModel(store: w.store, companyId: w.acme.id, target: .channel(id: w.general.id))
        chat.draft = "too early"
        #expect(await chat.send() == false)
        #expect(chat.sendError == nil)
        #expect(chat.draft == "too early")
        #expect(try w.store.messages(channelId: w.general.id, limit: 10).isEmpty)
    }

    @Test func blankDraftDoesNothing() async throws {
        let w = try world()
        let chat = ChatModel(store: w.store, companyId: w.acme.id, target: .channel(id: w.general.id))
        await chat.refresh()
        chat.draft = " \n"
        #expect(await chat.send() == false)
        #expect(chat.messages.count == 0)
        #expect(try w.store.messages(channelId: w.general.id, limit: 10).isEmpty)
    }

    @Test func dmWithoutChannelCreatesItOnFirstSend() async throws {
        let w = try world()
        let chat = ChatModel(store: w.store, companyId: w.acme.id, target: .dm(handle: "cto"))
        await chat.refresh()
        #expect(chat.channel == nil)
        #expect(chat.title == "@cto")
        #expect(chat.placeholder == "Message @cto")
        chat.draft = "hello"
        #expect(await chat.send())
        #expect(chat.channel?.name == "dm:cto:owner")
        #expect(chat.messages.count == 1)
    }

    @Test func agentConversationIsReadOnly() async throws {
        let w = try world()
        let m = try MessageRouter(store: w.store).sendDM(companyId: w.acme.id, from: .agent(w.ceo.id), to: "cto", text: "psst")
        let chat = ChatModel(store: w.store, companyId: w.acme.id, target: .channel(id: m.channelId))
        await chat.refresh()
        #expect(chat.readOnlyReason == "Agents' private conversation — read only.")
        chat.draft = "x"
        #expect(await chat.send() == false)
        #expect(chat.messages.count == 1)
    }

    @Test func killedAgentDMIsReadOnly() async throws {
        let w = try world()
        _ = try w.store.transition(agentId: w.cto.id, to: .killed)
        let chat = ChatModel(store: w.store, companyId: w.acme.id, target: .dm(handle: "cto"))
        await chat.refresh()
        #expect(chat.readOnlyReason == "@cto was killed — history is read only.")
        #expect(!chat.handles.contains("cto"))
    }

    @Test func unknownAgentDMIsReadOnly() async throws {
        let w = try world()
        let chat = ChatModel(store: w.store, companyId: w.acme.id, target: .dm(handle: "ghost"))
        await chat.refresh()
        #expect(chat.readOnlyReason == "No agent @ghost in this company.")
    }

    @Test func missingChannelIsReadOnly() async throws {
        let w = try world()
        let chat = ChatModel(store: w.store, companyId: w.acme.id, target: .channel(id: "missing"))
        await chat.refresh()
        #expect(chat.readOnlyReason == "This conversation no longer exists.")
    }

    @Test func loadEarlierPages() async throws {
        let w = try world()
        let r = MessageRouter(store: w.store)
        let t0 = Date(timeIntervalSince1970: 1_000)
        for i in 0..<250 {
            _ = try r.post(companyId: w.acme.id, channel: "general", from: .agent(w.ceo.id), text: "m\(i)", now: t0 + Double(i))
        }
        let chat = ChatModel(store: w.store, companyId: w.acme.id, target: .channel(id: w.general.id))
        await chat.refresh()
        #expect(chat.messages.count == 200)
        #expect(chat.hasEarlier)
        #expect(chat.messages.first?.message.text == "m50")
        await chat.loadEarlier()
        #expect(chat.messages.count == 250)
        #expect(!chat.hasEarlier)
        #expect(chat.messages.first?.message.text == "m0")
        await chat.refresh()
        #expect(chat.messages.count == 250)
        #expect(!chat.hasEarlier)
    }

    @Test func ensureLoadedPagesUntilPresent() async throws {
        let w = try world()
        let r = MessageRouter(store: w.store)
        let t0 = Date(timeIntervalSince1970: 1_000)
        var firstId = ""
        for i in 0..<250 {
            let m = try r.post(companyId: w.acme.id, channel: "general", from: .agent(w.ceo.id), text: "m\(i)", now: t0 + Double(i))
            if i == 0 { firstId = m.id }
        }
        let chat = ChatModel(store: w.store, companyId: w.acme.id, target: .channel(id: w.general.id))
        await chat.ensureLoaded(messageId: firstId)
        #expect(chat.messages.count == 250)
        #expect(chat.messages.first?.id == firstId)
        await chat.refresh()
        #expect(chat.messages.count == 250)
    }

    @Test func markReadClearsUnread() async throws {
        let w = try world()
        let r = MessageRouter(store: w.store)
        _ = try r.post(companyId: w.acme.id, channel: "general", from: .agent(w.ceo.id), text: "a")
        _ = try r.post(companyId: w.acme.id, channel: "general", from: .agent(w.ceo.id), text: "b")
        #expect(try w.store.unreadCounts(companyId: w.acme.id)[w.general.id] == 2)
        let chat = ChatModel(store: w.store, companyId: w.acme.id, target: .channel(id: w.general.id))
        await chat.refresh()
        await chat.markRead()
        #expect(try w.store.unreadCounts(companyId: w.acme.id)[w.general.id] == nil)
    }

    @Test func mentionSuggestionsFollowDraft() async throws {
        let w = try world()
        let chat = ChatModel(store: w.store, companyId: w.acme.id, target: .channel(id: w.general.id))
        await chat.refresh()
        chat.draft = "hi @c"
        #expect(chat.mentionSuggestions == ["ceo", "cto"])
        chat.acceptMention("cto")
        #expect(chat.draft == "hi @cto ")
        #expect(chat.mentionSuggestions.isEmpty)
    }

    @Test func tickRefreshesOpenChatOnMessageEvent() async throws {
        let w = try world()
        let model = AppModel(store: w.store, paths: w.paths)
        await model.load()
        model.select(.channel(id: w.general.id))
        let chat = try #require(model.chat)
        await chat.refresh()
        let before = chat.messages.count
        let other = try Store(path: w.paths.database.path)
        _ = try MessageRouter(store: other).post(companyId: w.acme.id, channel: "general", from: .agent(w.ceo.id), text: "live")
        await model.tick()
        #expect(chat.messages.count == before + 1)
        model.select(.agents)
        #expect(model.chat == nil)
    }
}
