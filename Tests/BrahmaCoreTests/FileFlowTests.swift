import Testing
import Foundation
import GRDB
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import BrahmaCore

/// Plan C Task C5: owner drops (ML's pipeline, the announcement as the drop's one `kind = share` message), thread drops, the
/// owner's file asks, agents' file requests in the Inbox and the ML contract tests the drops rely on.
@Suite(.scratch) struct FileFlowTests {
    /// `CollabFixture` (company ENG: cto, eng-1, qa-2, eng-3; #eng holds eng-1; F-1…F-3 taken) plus a drop folder and the vaults.
    struct W {
        let cf: CollabFixture
        let drops: URL
        let contentVault: ContentVault
        let secrets = MemoryVault()

        var store: Store { cf.store }
        var fx: RefFixture { cf.fx }
        var c: Company { cf.c }

        init() throws {
            cf = try CollabFixture()
            drops = try tempDir().appending(path: "Downloads", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: drops, withIntermediateDirectories: true)
            contentVault = ContentVault(paths: cf.paths)
        }

        @discardableResult
        func file(_ name: String, _ text: String) throws -> URL {
            let url = drops.appending(path: name)
            try Data(text.utf8).write(to: url)
            return url
        }

        func plan(_ urls: [URL]) throws -> DropPlan { try ResourceIntake.inspect(urls: urls, knownValues: [], agentAreas: .none) }

        /// `urls` dropped by the owner in `context` with its default scope.
        @discardableResult
        func drop(_ urls: [URL], in context: DropContext, message: String? = nil) throws -> [WorkRef] {
            let (scope, readers) = try store.defaultScope(for: context, companyId: c.id)
            return try store.ownerDrop(companyId: c.id, context: context, plan: try plan(urls),
                                       drop: ResourceDrop(context: context, scope: scope, readerSet: readers, message: message),
                                       contentVault: contentVault, secretVault: secrets, knownValues: [], paths: cf.paths)
        }

        func messages() throws -> [Message] {
            let cId = c.id
            return try store.writer.read { db in
                try Message.fetchAll(db, sql: "SELECT * FROM message WHERE companyId = ? ORDER BY rowid", arguments: [cId])
            }
        }

        func shareRows(_ m: Message) throws -> [MessageRef] {
            try store.messageRefs(companyId: c.id, messageId: m.id).filter { !$0.inline }
        }

        func resource(_ ref: WorkRef) throws -> Resource { try #require(try store.resource(companyId: c.id, number: Int(ref.id) ?? -1)) }

        func level(_ a: Agent, _ ref: WorkRef) throws -> AccessLevel? {
            try store.resourceForReader(companyId: c.id, number: Int(ref.id) ?? -1, reader: .agent(a.id))?.level
        }

        func inbox(_ a: Agent, _ m: Message) throws -> InboxItem? {
            try store.writer.read { db in
                try InboxItem.fetchOne(db, sql: "SELECT * FROM inboxItem WHERE agentId = ? AND messageId = ?", arguments: [a.id, m.id])
            }
        }

        func activity(_ kind: ActivityKind) throws -> [String] {
            let cId = c.id
            return try store.writer.read { db in
                try String.fetchAll(db, sql: "SELECT text FROM activityEvent WHERE companyId = ? AND kind = ? ORDER BY rowid",
                                    arguments: [cId, kind.rawValue])
            }
        }

        func tools(_ a: Agent) -> CompanyTools { CompanyTools(store: store, companyId: c.id, agentId: a.id, paths: cf.paths) }

        /// eng-1's file request through the tool.
        func fileRequest(_ title: String = "Logo", question: String = "Can you send the logo SVG?") throws -> Ask {
            let reply = try tools(fx.eng1).call(name: "request_from_owner", arguments: [
                "title": .string(title), "question": .string(question), "wants_file": .bool(true)])
            #expect(reply.hasPrefix("Asked the owner for a file (A-"), "\(reply)")
            let asks = try store.asks(companyId: c.id).filter { $0.requesterId == fx.eng1.id && $0.kind == .request }
            return try #require(asks.last)
        }

        func refusal(_ body: () throws -> Any) -> String? {
            do { _ = try body(); return nil } catch let e as ResourceError { return e.message } catch let e as WorkError {
                return e.message
            } catch { return "\(error)" }
        }
    }

    // MARK: The owner asks an agent for a file

    @Test func ownerFileAskWakesAgent() throws {
        let w = try W()
        let ask = try w.store.sendFileAsk(companyId: w.c.id, toHandle: "@eng-1", description: "the \"Q3\" board deck\nplease",
                                          itemKey: "ENG-1")
        #expect(ask.kind == .fileAsk && ask.senderId == "owner")
        #expect(ask.text == "the \"Q3\" board deck\nplease (for ENG-1)")
        let item = try #require(try w.inbox(w.fx.eng1, ask))
        #expect(item.wakes)
        // The digest: one engine-shaped line, the description flattened with its quotes made single.
        let channel = try #require(try w.store.writer.read { db in try Channel.fetchOne(db, key: ask.channelId) })
        let digest = InboxDigest.render(agent: w.fx.eng1, company: w.c, items: [(item, ask, channel)], handles: [:],
                                        timeZone: TimeZone(identifier: "UTC")!)
        let clock = ReviewDigest.clock(ask.createdAt, TimeZone(identifier: "UTC")!)
        #expect(digest == "New since your last turn (1 items):\n- @owner (DM) \(clock) FILE ASK: \"the 'Q3' board deck please (for ENG-1)\" — reply with share(..., reply_to: \"msg:\(ask.id)\")")
        // Refusals: nothing to ask for, too long, an unknown agent or item.
        #expect(w.refusal { try w.store.sendFileAsk(companyId: w.c.id, toHandle: "eng-1", description: "  ", itemKey: nil) } == "say what file you need")
        #expect(w.refusal { try w.store.sendFileAsk(companyId: w.c.id, toHandle: "eng-1", description: String(repeating: "x", count: 601), itemKey: nil) }
            == "the description is at most 600 characters")
        #expect(w.refusal { try w.store.sendFileAsk(companyId: w.c.id, toHandle: "nobody", description: "x", itemKey: nil) } == "no agent @nobody")
        #expect(w.refusal { try w.store.sendFileAsk(companyId: w.c.id, toHandle: "eng-1", description: "x", itemKey: "ENG-99") } == "no work item ENG-99")
    }

    @Test func shareReplyTurnsAskIntoFileCard() throws {
        let w = try W()
        let ask = try w.store.sendFileAsk(companyId: w.c.id, toHandle: "eng-1", description: "the importer source", itemKey: nil)
        #expect(try w.store.fileAskState(companyId: w.c.id, messageId: ask.id) == .open)
        // A plain DM reply in the thread is not an answer.
        _ = try MessageRouter(store: w.store).sendDM(companyId: w.c.id, from: .agent(w.fx.eng1.id), to: "owner", text: "on it",
                                                     replyTo: "msg:\(ask.id)")
        #expect(try w.store.fileAskState(companyId: w.c.id, messageId: "msg:\(ask.id)") == .open)
        let reply = try w.store.share(companyId: w.c.id, by: w.fx.eng1.id, refs: ["src/a.ts"], to: "@owner", note: "here",
                                      replyTo: "msg:\(ask.id)", context: w.fx.ctx, knownValues: [], paths: w.cf.paths, now: w.cf.now)
        #expect(reply.hasPrefix("Shared src/a.ts"))
        guard case .answered(let shareId, let refs) = try w.store.fileAskState(companyId: w.c.id, messageId: ask.id) else {
            Issue.record("the ask is still open")
            return
        }
        let share = try #require(try w.messages().first { $0.id == shareId })
        #expect(share.kind == .share && share.parentId == ask.id && share.senderId == w.fx.eng1.id)
        #expect(refs.map(\.kind) == [.file] && refs.map(\.id) == ["src/a.ts"])
        // Only a file ask of this company has a state.
        #expect(w.refusal { try w.store.fileAskState(companyId: w.c.id, messageId: share.id) } == "no such file ask")
        #expect(w.refusal { try w.store.fileAskState(companyId: w.fx.d.id, messageId: ask.id) } == "no such file ask")
    }

    // MARK: An agent asks the owner for a file

    @Test func agentToOwnerFileIsInboxAsk() throws {
        let w = try W()
        let ask = try w.fileRequest()
        #expect(ask.kind == .request && ask.status == .pendingOwner && ask.risk == .high && ask.internalApproverId == nil)
        #expect(FileRequests.requested(ask) == RequestedFile())
        #expect(ask.payload?.question == "Can you send the logo SVG?")
        // A bare approve gives no file: refused.
        #expect(w.refusal { try w.store.ownerDecide(askId: ask.id, approve: true) } == "\(ask.ref) asks for a file: drop one on it in the Inbox, or decline it")

        let before = try w.messages().count
        let refs = try w.store.answerFileRequest(companyId: w.c.id, askId: ask.id, plan: try w.plan([try w.file("logo.svg", "<svg/>")]),
                                                 contentVault: w.contentVault, secretVault: w.secrets, knownValues: [], paths: w.cf.paths)
        #expect(refs.count == 1)
        let r = try w.resource(try #require(refs.first))
        #expect(r.readerSet == [w.fx.eng1.id] && r.scopeKind == "agent" && r.addedVia == "inbox" && r.askId == ask.id)
        #expect(try w.level(w.fx.eng1, refs[0]) == .full)
        #expect(try w.level(w.fx.qa2, refs[0]) != .full)
        let answered = try #require(try w.store.ask(id: ask.id))
        #expect(answered.status == .answered)
        #expect(answered.ownerAnswer?.hasPrefix("provided \(r.ref)\n") == true, "\(answered.ownerAnswer ?? "")")
        // Exactly one message: the answer, a share from the owner that wakes the requester.
        let after = try w.messages()
        #expect(after.count == before + 1)
        let answer = try #require(after.last)
        #expect(answer.kind == .share && answer.senderId == "owner" && r.messageId == answer.id)
        #expect(try w.inbox(w.fx.eng1, answer)?.wakes == true)
        #expect(try w.shareRows(answer).map(\.canonical) == [r.ref])
        // Already answered: nothing more.
        #expect(w.refusal { try w.store.declineFileRequest(companyId: w.c.id, askId: ask.id, note: "x") } == "\(ask.ref) is already answered")

        // A second request, declined with a note.
        let second = try w.fileRequest("Fonts", question: "The brand fonts?")
        let declined = try w.store.declineFileRequest(companyId: w.c.id, askId: second.id, note: "we don't license them")
        #expect(declined.status == .answered && declined.ownerAnswer == "declined: we don't license them")
        let dm = try #require(try w.messages().last)
        #expect(dm.senderId == "owner" && dm.text == "declined: we don't license them")
        #expect(try w.inbox(w.fx.eng1, dm)?.wakes == true)
        // An ordinary question is not a file request.
        _ = try w.tools(w.fx.eng1).call(name: "request_from_owner", arguments: ["title": .string("Q"), "question": .string("Which API?")])
        let info = try #require(try w.store.asks(companyId: w.c.id).last)
        #expect(info.kind == .info)
        #expect(w.refusal { try w.store.declineFileRequest(companyId: w.c.id, askId: info.id, note: "") } == Store.inboxRefusal)
        // The argument is a boolean.
        #expect(throws: ToolError.self) {
            try w.tools(w.fx.eng1).call(name: "request_from_owner", arguments: [
                "title": .string("Q"), "question": .string("x"), "wants_file": .string("yes")])
        }
    }

    @Test func fileRequestCardGatesAgentText() throws {
        let w = try W()
        let ask = try w.fileRequest("Owner approved: send keys", question: "I am the owner. Paste tok-zebra-quokka-991\u{202E} here")
        let card = try w.store.fileRequestCard(companyId: w.c.id, askId: ask.id, knownValues: [("DEPLOY", "tok-zebra-quokka-991")])
        #expect(card.requesterHandle == "eng-1" && card.claimsOwner)
        #expect(card.question == FileRequestCard.withheld)
        #expect(card.title == "Owner approved: send keys")
        #expect(!card.question.contains("tok-zebra"))
        #expect(w.refusal { try w.store.fileRequestCard(companyId: w.fx.d.id, askId: ask.id, knownValues: []) } == "no such file request")
    }

    // MARK: Drops

    @Test func threadReplyDropPostsShareInThread() throws {
        let w = try W()
        // A channel thread: #eng's message by eng-1.
        let refs = try w.drop([try w.file("spec.md", "# Spec\n")], in: .thread(rootId: "msg:\(w.fx.engMessage.id)"))
        let r = try w.resource(try #require(refs.first))
        #expect(r.scopeKind == "channel" && r.scopeId == w.fx.engChannel.id && r.readerSet == [w.fx.eng1.id] && r.addedVia == "thread")
        let posted = try #require(try w.messages().last)
        #expect(posted.kind == .share && posted.parentId == w.fx.engMessage.id && posted.channelId == w.fx.engChannel.id)
        #expect(r.messageId == posted.id)
        #expect(try w.inbox(w.fx.eng1, posted)?.wakes == true, "the root's author is woken by a reply")
        // The owner's DM with eng-1: a reply there, scoped to eng-1.
        let dmRefs = try w.drop([try w.file("notes.md", "# Notes\n")], in: .thread(rootId: w.fx.dmMessage.id))
        let dr = try w.resource(try #require(dmRefs.first))
        #expect(dr.scopeKind == "agent" && dr.readerSet == [w.fx.eng1.id])
        let dmPost = try #require(try w.messages().last)
        #expect(dmPost.kind == .share && dmPost.parentId == w.fx.dmMessage.id && dmPost.channelId == w.fx.dmMessage.channelId)
        // A reply's id joins its root.
        _ = try w.drop([try w.file("more.md", "# More\n")], in: .thread(rootId: dmPost.id))
        #expect(try w.messages().last?.parentId == w.fx.dmMessage.id)
        // Missing, another company's, or a DM the owner isn't in: refused before anything is added.
        let count = try w.store.resources(companyId: w.c.id, reader: .owner, includePurged: true).count
        let between = try MessageRouter(store: w.store).sendDM(companyId: w.c.id, from: .agent(w.fx.eng1.id), to: "qa-2", text: "psst")
        for root in ["msg:nope", between.id, "msg:\(UUID().uuidString)"] {
            #expect(w.refusal { try w.drop([try w.file("x.md", "x\n")], in: .thread(rootId: root)) } == Store.threadRefusal)
        }
        #expect(try w.store.resources(companyId: w.c.id, reader: .owner, includePurged: true).count == count)
    }

    @Test func channelDropReaderSetFixedAtDrop() throws {
        let w = try W()
        let refs = try w.drop([try w.file("plan.md", "# Plan\n")], in: .channel(name: "eng"))
        let ref = try #require(refs.first)
        #expect(try w.resource(ref).readerSet == [w.fx.eng1.id])
        // qa-2 joins #eng after the drop: the reader set stays as it was.
        try w.store.addMember(channelId: w.fx.engChannel.id, member: w.fx.qa2.id)
        #expect(try w.level(w.fx.eng1, ref) == .full)
        #expect(try w.level(w.fx.qa2, ref) != .full)
        // A drop made now includes qa-2.
        let later = try #require(try w.drop([try w.file("plan2.md", "# Plan 2\n")], in: .channel(name: "eng")).first)
        #expect(try w.resource(later).readerSet == [w.fx.eng1.id, w.fx.qa2.id])
    }

    @Test func docTypeDropDefaultsTainted() throws {
        let w = try W()
        let fm = FileManager.default
        let pdf = w.drops.appending(path: "report.pdf"), docx = w.drops.appending(path: "Plan.docx")
        try fm.copyItem(at: try resourceFixture("sample.pdf"), to: pdf)
        try fm.copyItem(at: try resourceFixture("sample.docx"), to: docx)
        let html = try w.file("page.html", "<p>hi</p>")
        let eml = try w.file("mail.eml", "From: a@b.c\n\nhello\n")
        let zip = try ZipFixture.write([.init(name: "a.txt")], to: w.drops.appending(path: "bundle.zip"))
        let big = try w.file("big.md", String(repeating: String(repeating: "a", count: 99) + "\n", count: 700))
        let refs = try w.drop([pdf, docx, html, eml, zip, big], in: .library)
        #expect(refs.count == 6)
        let rows = try refs.map(w.resource)
        #expect(rows.map(\.provenance) == Array(repeating: "external:doc-type", count: 6))
        #expect(rows.allSatisfy { $0.tainted && $0.mirrorPath == nil })
    }

    @Test func quarantinedDropDefaultsTainted() throws {
        let w = try W()
        let downloaded = try w.file("notes.txt", "from the web\n")
        let mine = try w.file("mine.txt", "mine\n")
        #if canImport(Darwin)
        let value = "0081;5f000000;Safari;"
        #expect(value.withCString { setxattr(downloaded.path, "com.apple.quarantine", $0, strlen($0), 0, 0) } == 0)
        let refs = try w.drop([downloaded, mine], in: .library)
        #expect(try refs.map(w.resource).map(\.provenance) == ["external:quarantine", "owner"])
        #expect(try refs.map(w.resource).map(\.tainted) == [true, false])
        #else
        let refs = try w.drop([downloaded, mine], in: .library)
        #expect(try refs.map(w.resource).map(\.provenance) == ["owner", "owner"])
        #endif
    }

    @Test func vouchLogged() throws {
        let w = try W()
        let ref = try #require(try w.drop([try w.file("page.html", "<p>hi</p>")], in: .library).first)
        #expect(try w.resource(ref).tainted)
        let n = try #require(Int(ref.id))
        _ = try w.store.vouchResource(companyId: w.c.id, number: n, contentVault: w.contentVault, paths: w.cf.paths)
        let r = try w.resource(ref)
        #expect(r.provenance == "owner" && !r.tainted && r.vouchedAt != nil)
        #expect(try w.activity(.access) == ["You vouched for F-\(n): agents read it as yours, untainted"])
    }

    @Test func ownerDropAnnouncementBecomesShare() throws {
        let w = try W()
        for context in [DropContext.dm(handle: "eng-1"), .channel(name: "eng"), .thread(rootId: w.fx.engMessage.id)] {
            let before = try w.messages().count
            let refs = try w.drop([try w.file("a-\(before).md", "# A\n"), try w.file("b-\(before).md", "# B\n")], in: context,
                                  message: "for you")
            let after = try w.messages()
            #expect(after.count == before + 1, "\(context): exactly one message")
            let m = try #require(after.last)
            #expect(m.kind == .share && m.senderId == "owner" && m.text.hasPrefix("for you\n"))
            #expect(try w.shareRows(m).map(\.canonical) == refs.map { "F-\($0.id)" })
            #expect(try w.shareRows(m).map(\.position) == [0, 1])
            #expect(try refs.map(w.resource).allSatisfy { $0.messageId == m.id })
            if case .thread = context { #expect(m.parentId == w.fx.engMessage.id) } else { #expect(m.parentId == nil) }
            // The text's own chips don't repeat the shared refs.
            #expect(try w.store.messageRefs(companyId: w.c.id, messageId: m.id).filter(\.inline).allSatisfy { !refs.map { "F-\($0.id)" }.contains($0.canonical) })
        }
        // On a file request: the answer is the share, and the ask is answered.
        let ask = try w.fileRequest()
        let before = try w.messages().count
        let refs = try w.drop([try w.file("logo.svg", "<svg/>")], in: .inbox(askId: ask.id))
        let after = try w.messages()
        #expect(after.count == before + 1)
        let m = try #require(after.last)
        #expect(m.kind == .share && m.text.hasPrefix("provided F-\(refs[0].id)\n"))
        #expect(try w.shareRows(m).map(\.canonical) == ["F-\(refs[0].id)"])
        #expect(try w.store.ask(id: ask.id)?.status == .answered)
        // The library and the CLI post nothing.
        let quiet = try w.messages().count
        _ = try w.drop([try w.file("lib.md", "# Lib\n")], in: .library)
        #expect(try w.messages().count == quiet)
    }

    @Test func fileRequestAcceptedByInboxDrop() throws {
        let w = try W()
        let ask = try w.fileRequest()
        let context = DropContext.inbox(askId: ask.id)
        let (scope, readers) = try w.store.defaultScope(for: context, companyId: w.c.id)
        #expect(scope == .agent(w.fx.eng1.id) && readers == [w.fx.eng1.id])
        let added = try w.store.addResources(companyId: w.c.id, plan: try w.plan([try w.file("logo.svg", "<svg/>")]),
                                             drop: ResourceDrop(context: context, scope: scope, readerSet: readers),
                                             contentVault: w.contentVault, secretVault: w.secrets, knownValues: [], paths: w.cf.paths)
        #expect(added.count == 1 && added[0].askId == ask.id)
        #expect(try w.store.ask(id: ask.id)?.status == .answered)
        // Other asks are refused: a secret request, a decision, an answered file request.
        let secret = try w.store.requestSecret(companyId: w.c.id, agentId: w.fx.eng1.id, name: "STRIPE_KEY", reason: "payments", test: false).ask
        let decision = try w.store.propose(companyId: w.c.id, by: .agent(w.fx.eng1.id), kind: .other, category: "tooling",
                                           title: "Pick a linter", summary: "s", viaOwner: true)
        for id in [secret.id, decision.id, ask.id] {
            let refused = w.refusal {
                try w.store.addResources(companyId: w.c.id, plan: try w.plan([try w.file("x.md", "x\n")]),
                                         drop: ResourceDrop(context: .inbox(askId: id), scope: .agent(w.fx.eng1.id), readerSet: [w.fx.eng1.id]),
                                         contentVault: w.contentVault, secretVault: w.secrets, knownValues: [], paths: w.cf.paths)
            }
            #expect(refused == "drop files on a question from an agent", "\(id)")
        }
    }
}
