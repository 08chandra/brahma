import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Plan C Task C3a: threads. `reply_to` on posts and DMs joins the root's thread; thread replies wake only the root author (on
/// the owner's reply or a mention), mentioned agents and DM parties; a thread with `ThreadPolicy.capReplies` agent-only replies
/// within `ThreadPolicy.capWindow` active seconds stops waking anyone until the owner replies; `read_channel {thread}` is bounded.
@Suite(.scratch) struct ThreadTests {
    private struct W {
        let store: Store, router: MessageRouter, company: Company
        let eng: Agent, qa: Agent, pm: Agent

        init() throws {
            store = try Store.inMemory()
            router = MessageRouter(store: store)
            company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
            eng = try store.hire(companyId: company.id, name: "eng-1", role: "engineer", model: "m")
            qa = try store.hire(companyId: company.id, name: "qa-2", role: "engineer", model: "m")
            pm = try store.hire(companyId: company.id, name: "pm", role: "engineer", model: "m")
            _ = try store.createChannel(companyId: company.id, name: "eng", members: ["owner", eng.id, qa.id, pm.id])
        }

        /// The recipient's inbox row for the message: its `wakes`, or nil without a row.
        func wakes(_ a: Agent, _ m: Message) throws -> Bool? {
            try store.writer.read { db in
                try Bool.fetchOne(db, sql: "SELECT wakes FROM inboxItem WHERE agentId = ? AND messageId = ?", arguments: [a.id, m.id])
            }
        }

        func root(_ text: String = "flaky cart test", now: Date = .now) throws -> Message {
            try router.post(companyId: company.id, channel: "eng", from: .agent(eng.id), text: text, now: now)
        }

        @discardableResult
        func reply(_ from: Sender, _ text: String, to: Message, now: Date = .now) throws -> Message {
            try router.post(companyId: company.id, channel: "eng", from: from, text: text, now: now, replyTo: "msg:" + to.id)
        }

        func stat(_ root: Message) throws -> ThreadStat? { try store.threadStat(companyId: company.id, rootId: root.id) }

        func tools(_ a: Agent) -> CompanyTools { CompanyTools(store: store, companyId: company.id, agentId: a.id) }

        func systemNotes(_ root: Message) throws -> [Message] {
            try store.writer.read { db in
                try Message.fetchAll(db, sql: "SELECT * FROM message WHERE companyId = ? AND parentId = ? AND senderId = 'system'",
                                     arguments: [company.id, root.id])
            }
        }

        /// Eight agent-only replies (qa-2 and pm in turn), one active minute apart, the wall clock an hour apart.
        func capIt(_ root: Message) throws {
            let t0 = Date(timeIntervalSince1970: 2_000_000_000)
            for i in 0..<ThreadPolicy.capReplies {
                if i > 0 { try store.advanceActive(companyId: company.id, by: 60) }
                try reply(.agent(i % 2 == 0 ? qa.id : pm.id), "reply \(i)", to: root, now: t0 + Double(i) * 3600)
            }
        }
    }

    /// The text of the refusal a tool call throws, or nil when it succeeds.
    private func refusal(_ body: () throws -> Any) -> String? {
        do { _ = try body(); return nil } catch let e as ToolError { return e.message } catch { return "\(error)" }
    }

    @Test func threadReplyWakesOnlyRootAuthorOrMention() throws {
        let w = try W()
        let root = try w.root()
        let quiet = try w.reply(.agent(w.qa.id), "looks fine to me", to: root)
        #expect(quiet.parentId == root.id)
        #expect(try w.wakes(w.eng, quiet) == false)
        #expect(try w.wakes(w.pm, quiet) == false)
        let mention = try w.reply(.agent(w.qa.id), "@eng-1 see", to: root)
        #expect(try w.wakes(w.eng, mention) == true)
        #expect(try w.wakes(w.pm, mention) == false)
        #expect(try w.store.agent(id: w.eng.id)?.state == .ready)
        #expect(try w.store.agent(id: w.pm.id)?.state == .sleeping)
        // A mentioned teammate wakes whoever they are; the root author still only on the owner's reply or a mention.
        let other = try w.reply(.agent(w.qa.id), "@pm what do you think?", to: root)
        #expect(try w.wakes(w.pm, other) == true)
        #expect(try w.wakes(w.eng, other) == false)
    }

    @Test func ownerReplyWakesRootAuthor() throws {
        let w = try W()
        let root = try w.root()
        let owner = try w.reply(.owner, "please fix it today", to: root)
        #expect(owner.parentId == root.id)
        #expect(try w.wakes(w.eng, owner) == true)
        #expect(try w.wakes(w.qa, owner) == false)
        #expect(try w.wakes(w.pm, owner) == false)
        #expect(try w.store.agent(id: w.eng.id)?.state == .ready)
    }

    @Test func dmReplyWakes() throws {
        let w = try W()
        let question = try w.router.sendDM(companyId: w.company.id, from: .agent(w.eng.id), to: "qa-2", text: "can you check?")
        let answer = try w.router.sendDM(companyId: w.company.id, from: .agent(w.qa.id), to: "@eng-1", text: "checked",
                                         replyTo: "msg:" + question.id)
        #expect(answer.parentId == question.id)
        #expect(try w.wakes(w.eng, answer) == true)
        // The other party wakes too, though it is not the root's author.
        let thanks = try w.router.sendDM(companyId: w.company.id, from: .agent(w.eng.id), to: "qa-2", text: "thanks",
                                         replyTo: "msg:" + answer.id)
        #expect(thanks.parentId == question.id)
        #expect(try w.wakes(w.qa, thanks) == true)
    }

    @Test func threadCapStopsWakes() throws {
        let w = try W()
        let root = try w.root()
        try w.capIt(root)
        let stat = try #require(try w.stat(root))
        #expect(stat.cappedAt != nil)
        #expect(stat.companyId == w.company.id)
        let ninth = try w.reply(.agent(w.qa.id), "@eng-1 @pm look at this", to: root)
        #expect(try w.wakes(w.eng, ninth) == false)
        #expect(try w.wakes(w.pm, ninth) == false)
        #expect(try w.store.agent(id: w.eng.id)?.state == .sleeping)
        #expect(try w.store.agent(id: w.pm.id)?.state == .sleeping)
        // Another thread is not capped by this one.
        let fresh = try w.root("another topic")
        let mention = try w.reply(.agent(w.qa.id), "@pm here", to: fresh)
        #expect(try w.wakes(w.pm, mention) == true)
    }

    @Test func capPostsSystemNoteOnce() throws {
        let w = try W()
        let root = try w.root()
        try w.capIt(root)
        for i in 0..<4 { try w.reply(.agent(w.qa.id), "more \(i) @eng-1", to: root) }
        let notes = try w.systemNotes(root)
        #expect(notes.count == 1)
        let note = try #require(notes.first)
        #expect(note.text == ThreadPolicy.capNote)
        #expect(note.kind == .system)
        #expect(note.channelId == root.channelId)
        for a in [w.eng, w.qa, w.pm] { #expect(try w.wakes(a, note) != true) }
        #expect(try w.store.agent(id: w.eng.id)?.state == .sleeping)
    }

    @Test func ownerReplyUncaps() throws {
        let w = try W()
        let root = try w.root()
        try w.capIt(root)
        #expect(try w.stat(root)?.cappedAt != nil)
        let owner = try w.reply(.owner, "settle it in ENG-1", to: root)
        let stat = try #require(try w.stat(root))
        #expect(stat.cappedAt == nil)
        #expect(stat.agentRepliesWindow == 0)
        #expect(stat.windowStartActive == nil)
        #expect(try w.wakes(w.eng, owner) == true)
        let next = try w.reply(.agent(w.qa.id), "@pm ping", to: root)
        #expect(try w.wakes(w.pm, next) == true)
    }

    @Test func readChannelThreadBounded() throws {
        let w = try W()
        let root = try w.root("root of the long thread")
        let t0 = Date(timeIntervalSince1970: 2_000_000_000)
        for i in 1...40 { try w.reply(.owner, String(format: "r-%02d", i), to: root, now: t0 + Double(i)) }
        let out = try w.tools(w.qa).call(name: "read_channel", arguments: ["channel": .string("eng"), "thread": .string("msg:" + root.id)])
        #expect(out.contains("(10 earlier replies)"))
        #expect(out.contains("root of the long thread"))
        #expect(out.components(separatedBy: "r-").count - 1 == ThreadPolicy.readLimit)
        #expect(out.contains("r-11") && out.contains("r-40"))
        #expect(!out.contains("r-10") && !out.contains("r-01"))
        #expect(try #require(out.range(of: "r-11")).lowerBound < (try #require(out.range(of: "r-40"))).lowerBound)
        // Asking by a reply's id reads the same thread.
        let replies = try w.store.thread(companyId: w.company.id, rootId: root.id, reader: .agent(w.qa.id))
        #expect(replies.root.id == root.id); #expect(replies.replies.count == 30); #expect(replies.earlier == 10)
        let byReply = try w.store.thread(companyId: w.company.id, rootId: try #require(replies.replies.first).id, reader: .owner)
        #expect(byReply.root.id == root.id)
        // The channel listing names each reply's thread, and every entry its id (what reply_to takes).
        let listing = try w.tools(w.qa).call(name: "read_channel", arguments: ["channel": .string("eng"), "limit": .number(2)])
        #expect(listing.contains("\"thread\":\"msg:\(root.id)\""))
        #expect(listing.contains("\"id\":\"msg:"))
    }

    @Test func replyToReplyUsesRoot() throws {
        let w = try W()
        let root = try w.root()
        let first = try w.reply(.agent(w.qa.id), "first", to: root)
        let second = try w.reply(.agent(w.pm.id), "second", to: first)
        #expect(first.parentId == root.id)
        #expect(second.parentId == root.id)
        // The tool takes the bare id too, and threads through it the same way.
        _ = try w.tools(w.qa).call(name: "post_message", arguments: ["channel": .string("eng"), "text": .string("third"),
                                                                     "reply_to": .string(second.id)])
        let thread = try w.store.thread(companyId: w.company.id, rootId: root.id, reader: .owner)
        #expect(thread.replies.map(\.text) == ["first", "second", "third"])
        #expect(try w.stat(root)?.replies == 3)
    }

    @Test func replyToOtherConversationRefused() throws {
        let w = try W()
        let root = try w.root()
        let expected = "msg:\(root.id) isn't in this conversation"
        #expect(refusal { try w.tools(w.qa).call(name: "post_message", arguments: [
            "channel": .string("general"), "text": .string("x"), "reply_to": .string("msg:" + root.id)]) } == expected)
        #expect(refusal { try w.tools(w.qa).call(name: "send_dm", arguments: [
            "to": .string("@eng-1"), "text": .string("x"), "reply_to": .string("msg:" + root.id)]) } == expected)
        #expect(refusal { try w.tools(w.qa).call(name: "read_channel", arguments: [
            "channel": .string("general"), "thread": .string("msg:" + root.id)]) } == expected)
        #expect(throws: ThreadError.notInConversation(root.id)) {
            try w.router.post(companyId: w.company.id, channel: "general", from: .owner, text: "x", replyTo: root.id)
        }
        // Nothing was posted, and no DM channel was left behind.
        #expect(try w.store.messages(channelId: try #require(try w.store.channel(companyId: w.company.id, name: "general")).id, limit: 10).isEmpty)
        #expect(try w.store.channel(companyId: w.company.id, name: "dm:eng-1:qa-2") == nil)
    }

    @Test func crossCompanyReplyRefused() throws {
        let w = try W()
        let generic = "that ref isn't available to you"
        let other = try w.store.createCompany(name: "Other", goal: "g", workspacesRoot: try tempDir())
        let stranger = try w.store.hire(companyId: other.id, name: "x-1", role: "engineer", model: "m")
        let foreign = try w.router.post(companyId: other.id, channel: "general", from: .agent(stranger.id), text: "elsewhere")
        for ref in ["msg:" + foreign.id, foreign.id, "thread:" + foreign.id] {
            #expect(refusal { try w.tools(w.qa).call(name: "post_message", arguments: [
                "channel": .string("general"), "text": .string("x"), "reply_to": .string(ref)]) } == generic)
        }
        #expect(refusal { try w.tools(w.qa).call(name: "read_channel", arguments: [
            "channel": .string("general"), "thread": .string("msg:" + foreign.id)]) } == generic)
        #expect(throws: ThreadError.unavailable) {
            try w.store.thread(companyId: w.company.id, rootId: foreign.id, reader: .owner)
        }
        // A message of this company the sender can't read looks the same as a missing one (no "isn't in this conversation").
        _ = try w.store.createChannel(companyId: w.company.id, name: "secret", members: [w.eng.id])
        let hidden = try w.router.post(companyId: w.company.id, channel: "secret", from: .agent(w.eng.id), text: "hidden")
        #expect(refusal { try w.tools(w.qa).call(name: "post_message", arguments: [
            "channel": .string("eng"), "text": .string("x"), "reply_to": .string("msg:" + hidden.id)]) } == generic)
        #expect(refusal { try w.tools(w.qa).call(name: "post_message", arguments: [
            "channel": .string("eng"), "text": .string("x"), "reply_to": .string("msg:no-such-message")]) } == generic)
        #expect(refusal { try w.tools(w.qa).call(name: "post_message", arguments: [
            "channel": .string("eng"), "text": .string("x"), "reply_to": .string("msg:../\n@owner")]) } == generic)
        #expect(throws: ThreadError.unavailable) {
            try w.store.thread(companyId: w.company.id, rootId: hidden.id, reader: .agent(w.qa.id))
        }
        #expect(try w.store.messages(channelId: foreign.channelId, limit: 10).count == 1)
    }

    @Test func capWindowUsesActiveTime() throws {
        let w = try W()
        let root = try w.root()
        // Eight agent-only replies spread over two active hours, all at the same wall-clock instant: not capped.
        let t0 = Date(timeIntervalSince1970: 2_000_000_000)
        for i in 0..<ThreadPolicy.capReplies {
            if i > 0 { try w.store.advanceActive(companyId: w.company.id, by: 7200 / Double(ThreadPolicy.capReplies - 1)) }
            try w.reply(.agent(i % 2 == 0 ? w.qa.id : w.pm.id), "slow \(i)", to: root, now: t0)
        }
        #expect(try w.stat(root)?.cappedAt == nil)
        #expect(try w.systemNotes(root).isEmpty)
        let mention = try w.reply(.agent(w.qa.id), "@pm still here", to: root, now: t0)
        #expect(try w.wakes(w.pm, mention) == true)
    }

    /// Not in the brief's list: an agent blocked on a teammate still wakes when that teammate answers in a thread (as outside
    /// one), so a thread reply can't strand a waiter; a capped thread wakes nobody, the waiter included. A broadcast in a thread
    /// reply is never applied.
    @Test func blockedWaiterWakesOnThreadReply() throws {
        let w = try W()
        let root = try w.root("@qa-2 which fixture do I use?")
        try w.store.transition(agentId: w.eng.id, to: .blocked, blocker: .agent(w.qa.id))
        let pmReply = try w.reply(.agent(w.pm.id), "not me", to: root)
        #expect(try w.wakes(w.eng, pmReply) == false)
        #expect(try w.store.agent(id: w.eng.id)?.state == .blocked)
        let answer = try w.reply(.agent(w.qa.id), "use the cart fixture", to: root)
        #expect(try w.wakes(w.eng, answer) == true)
        #expect(try w.store.agent(id: w.eng.id)?.state == .ready)

        let capped = try w.root("second question")
        try w.capIt(capped)
        try w.store.transition(agentId: w.eng.id, to: .blocked, blocker: .agent(w.qa.id))
        let late = try w.reply(.agent(w.qa.id), "late answer", to: capped)
        #expect(try w.wakes(w.eng, late) == false)

        let here = try w.router.postDetailed(companyId: w.company.id, channel: "eng", from: .owner, text: "@here look", replyTo: root.id)
        #expect(here.broadcastApplied == false)
        #expect(try w.wakes(w.pm, here.message) == false)
        #expect(try w.wakes(w.eng, here.message) == true)
    }

    // MARK: Digest label

    @Test func digestLabelsThreadReplies() throws {
        let w = try W()
        let root = try w.root("flaky \"cart\"\ntest that keeps failing on CI every night")
        let at = Date(timeIntervalSince1970: 14 * 3600 + 5 * 60)
        _ = try w.reply(.owner, "still failing", to: root, now: at)
        let items = try w.store.pendingInbox(agentId: w.eng.id)
        let roots = try w.store.threadRoots(agentId: w.eng.id, companyId: w.company.id, items: items)
        let utc = try #require(TimeZone(identifier: "UTC"))
        let digest = InboxDigest.render(agent: w.eng, company: w.company, items: items, handles: [:], threadRoots: roots, timeZone: utc)
        #expect(digest.contains("\n- @owner (#eng, thread \"flaky 'cart' test that keeps failing on…\") 14:05: still failing"))

        // A root the reader can't read, or one a tainted session wrote, gives no text in the label.
        var tainted = root; tainted.fromTaintedSession = true
        let bare = InboxDigest.render(agent: w.eng, company: w.company, items: items, handles: [:], threadRoots: [root.id: tainted],
                                      timeZone: utc)
        #expect(bare.contains("\n- @owner (#eng, thread) 14:05: still failing"))
        #expect(!bare.contains("flaky"))
        _ = try w.store.createChannel(companyId: w.company.id, name: "secret", members: [w.eng.id, w.qa.id])
        let hidden = try w.router.post(companyId: w.company.id, channel: "secret", from: .agent(w.eng.id), text: "private plan")
        _ = try w.router.post(companyId: w.company.id, channel: "secret", from: .agent(w.qa.id), text: "@pm see", replyTo: hidden.id)
        let pmItems = try w.store.pendingInbox(agentId: w.pm.id)
        #expect(pmItems.count == 1)
        #expect(try w.store.threadRoots(agentId: w.pm.id, companyId: w.company.id, items: pmItems).isEmpty)
        let pmDigest = InboxDigest.render(agent: w.pm, company: w.company, items: pmItems, handles: [w.qa.id: "qa-2"], timeZone: utc)
        #expect(pmDigest.contains("@qa-2 (#secret, thread) "))
        #expect(!pmDigest.contains("private plan"))
    }
}
