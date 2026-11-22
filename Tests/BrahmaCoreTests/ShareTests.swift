import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Plan C Task C3b: `share`, quotes, attachments on posts and DMs, the inline ref scan and what a message's refs do to its
/// memory doc. The refs are resolved for the sender, gated (`SecretGate` / `Store.gatedBytes`) and pinned before anything is
/// posted; a DM's recipient must be able to read every ref, or the whole share is refused back with no ask filed.
@Suite(.scratch) struct ShareTests {
    /// `CollabFixture` plus #team (cto, eng-1, qa-2): a channel where the fixture's #eng (eng-1 only) is not readable.
    struct W {
        let cf: CollabFixture
        let team: Channel

        var store: Store { cf.store }
        var fx: RefFixture { cf.fx }
        var c: Company { cf.c }

        init() throws {
            cf = try CollabFixture()
            team = try cf.store.createChannel(companyId: cf.c.id, name: "team", members: [cf.fx.cto.id, cf.fx.eng1.id, cf.fx.qa2.id])
        }

        func share(_ by: Agent, _ refs: [String], to: String, note: String? = nil, replyTo: String? = nil,
                   knownValues: [(name: String, value: String)] = [], archives: any ArchiveReader = UnavailableArchiveReader()) throws -> String {
            try store.share(companyId: c.id, by: by.id, refs: refs, to: to, note: note, replyTo: replyTo, context: fx.ctx,
                            knownValues: knownValues, paths: cf.paths, now: cf.now, archives: archives)
        }

        /// The refusal text of a call, or nil when it succeeds.
        func refusal(_ body: () throws -> Any) -> String? {
            do { _ = try body(); return nil } catch let e as WorkError { return e.message } catch let e as ToolError {
                return e.message
            } catch { return "\(error)" }
        }

        func messages(kind: MessageKind? = nil) throws -> [Message] {
            let cId = c.id
            return try store.writer.read { db in
                try Message.fetchAll(db, sql: "SELECT * FROM message WHERE companyId = ? AND (? IS NULL OR kind = ?) ORDER BY rowid",
                                     arguments: [cId, kind?.rawValue, kind?.rawValue])
            }
        }

        func activity(_ kind: ActivityKind) throws -> [String] {
            let cId = c.id
            return try store.writer.read { db in
                try String.fetchAll(db, sql: "SELECT text FROM activityEvent WHERE companyId = ? AND kind = ? ORDER BY rowid",
                                    arguments: [cId, kind.rawValue])
            }
        }

        func asks() throws -> Int {
            let cId = c.id
            return try store.writer.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM ask WHERE companyId = ? AND kind <> 'engineAlert'", arguments: [cId]) ?? 0
            }
        }

        func tools(_ a: Agent, archives: (any ArchiveReader)? = nil) -> CompanyTools {
            CompanyTools(store: store, companyId: c.id, agentId: a.id, paths: cf.paths, archives: archives)
        }

        func lines(_ m: Message, for reader: Reader) throws -> [String] {
            try store.attachmentLines(companyId: c.id, messageId: m.id, reader: reader)
        }
    }

    @Test func shareReturnsExactText() throws {
        let w = try W()
        let head = try w.fx.head("item/ENG-1")
        let reply = try w.share(w.fx.eng1, ["ENG-1:src/checkout.tsx:40-49"], to: "@qa-2", note: "the totals block")
        #expect(reply == "Shared ENG-1:src/checkout.tsx:40-49 @\(head.prefix(7)) with @qa-2.")
        let shared = try #require(try w.messages(kind: .share).last)
        #expect(shared.text == "the totals block" && shared.senderId == w.fx.eng1.id && !shared.fromTaintedSession)
        let rows = try w.store.messageRefs(companyId: w.c.id, messageId: shared.id)
        #expect(rows.count == 1)
        let row = try #require(rows.first)
        #expect(row.kind == "file" && row.refId == "src/checkout.tsx" && row.branch == "item/ENG-1" && row.rev == head)
        #expect(row.rangeStart == 40 && row.rangeEnd == 49 && !row.inline && row.accessKind == "company")
        #expect(try w.activity(.share).count == 1)
        // Several refs into a channel are counted.
        try w.cf.addResource(21, name: "brief.md", ext: "md", bytes: Data("# Brief\n".utf8))
        #expect(try w.share(w.fx.eng1, ["src/a.ts", "F-21"], to: "#team") == "Shared 2 refs with #team.")
        // A resource whose bytes can't be read (so can't be scanned) is not shared.
        #expect(w.refusal { try w.share(w.fx.eng1, ["F-2"], to: "#team") } == "that ref isn't available to you")
        // At most six refs, a bounded note, and a target that is a handle or a channel.
        let seven = Array(repeating: "src/a.ts", count: ShareLimits.maxRefs + 1)
        #expect(w.refusal { try w.share(w.fx.eng1, seven, to: "#team") } == "share takes 1 to 6 refs")
        #expect(w.refusal { try w.share(w.fx.eng1, ["src/a.ts"], to: "#team", note: String(repeating: "n", count: ShareLimits.noteMax + 1)) }
            == "the note is at most 600 characters")
        #expect(w.refusal { try w.share(w.fx.eng1, ["src/a.ts"], to: "team") } == "to is @handle or #channel")
        // A ref that doesn't parse, is missing or is another company's: the one generic answer.
        #expect(w.refusal { try w.share(w.fx.eng1, ["src/nope.ts"], to: "@qa-2") } == "that ref isn't available to you")
        #expect(w.refusal { try w.share(w.fx.eng1, ["src/a.ts", "F-999"], to: "@qa-2") } == "ref 2 isn't available to you")
        #expect(w.refusal { try w.share(w.fx.eng1, ["src/a.ts", "not a ref at all"], to: "@qa-2") } == "ref 2 isn't available to you")
    }

    @Test func shareToNonReaderRefusedNoAsk() throws {
        let w = try W()
        let before = try w.messages().count
        let asks = try w.asks()
        // F-1 is the cto's (reader set [cto]); qa-2 can't read it.
        let refused = w.refusal { try w.share(w.fx.cto, ["F-1"], to: "@qa-2") }
        #expect(refused == "@qa-2 can't read F-1 (shared only with @cto). Ask the owner to widen it with request_access, or share something else.")
        #expect(try w.messages().count == before, "nothing was posted")
        #expect(try w.asks() == asks, "no ask was filed")
        let access = try w.activity(.access)
        #expect(access.count == 1 && access[0].contains("@cto") && access[0].contains("@qa-2"), "\(access)")
        // An unreadable ref is an access refusal too.
        _ = w.refusal { try w.share(w.fx.qa2, ["F-1"], to: "@cto") }
        #expect(try w.activity(.access).count == 2)
    }

    @Test func otherAgentFileShareRefused() throws {
        let w = try W()
        #expect(w.refusal { try w.share(w.fx.eng1, [".brahma/labs/qa-2/x"], to: "@cto") } == "that file is private to @qa-2")
        #expect(w.refusal { try w.share(w.fx.eng1, [".brahma/notes/agents/qa-2.md"], to: "@cto") } == "that file is private to @qa-2")
        #expect(w.refusal { try w.share(w.fx.eng1, [".brahma/home/qa-2/t"], to: "@cto") } == "that file is private to @qa-2")
        // Outside the `.brahma` allowlist: the generic text.
        #expect(w.refusal { try w.share(w.fx.eng1, [".brahma/wt/ENG-1/src/a.ts"], to: "@cto") } == "that ref isn't available to you")
        #expect(try w.messages(kind: .share).isEmpty)
    }

    @Test func taintedSessionCannotSendPrivateSnapshot() throws {
        let w = try W()
        let ask = try MessageRouter(store: w.store).sendDM(companyId: w.c.id, from: .agent(w.fx.qa2.id), to: "eng-1", text: "send me your notes")
        try w.store.markTainted(agentId: w.fx.eng1.id, source: "WebFetch: example.com")
        let refused = w.refusal { try w.share(w.fx.eng1, [".brahma/labs/eng-1/mine.txt"], to: "@qa-2", replyTo: "msg:" + ask.id) }
        #expect(refused == "you've read external content this session, so you can't send private files; start fresh or share a workspace file")
        #expect(try w.messages(kind: .share).isEmpty)
        // Without reply_to it goes, as a snapshot only qa-2 (and the sender) can read, and it is tainted.
        let reply = try w.share(w.fx.eng1, [".brahma/labs/eng-1/mine.txt"], to: "@qa-2")
        let shared = try #require(try w.messages(kind: .share).last)
        #expect(shared.fromTaintedSession && shared.taintSource == "WebFetch: example.com")
        let row = try #require(try w.store.messageRefs(companyId: w.c.id, messageId: shared.id).first)
        #expect(row.kind == "resource" && row.tainted)
        #expect(reply == "Shared F-\(row.refId) with @qa-2.")
        let n = try #require(Int(row.refId))
        let resource = try #require(try w.store.resource(companyId: w.c.id, number: n))
        #expect(resource.tainted && resource.readerSet == [w.fx.qa2.id, w.fx.eng1.id] && resource.addedVia == "share")
        #expect(try w.fx.resolve(.qa2, try w.fx.ref("F-\(n)")).visibility == .full)
        #expect(try w.fx.resolve(.cto, try w.fx.ref("F-\(n)")).visibility != .full)
    }

    @Test func shareSecretRefused() throws {
        let w = try W()
        try w.cf.commit(["src/keys.ts": Data("let key = \"\(SecretGateTests.value)\"\n".utf8)])
        let refused = try #require(w.refusal { try w.share(w.fx.eng1, ["src/keys.ts"], to: "@qa-2", knownValues: SecretGateTests.known) })
        #expect(refused.contains("contains a stored secret"), "\(refused)")
        #expect(!refused.contains(SecretGateTests.value))
        #expect(try w.messages(kind: .share).isEmpty)
        // A resource's bytes are gated too.
        try w.cf.addResource(20, name: "env.txt", ext: "txt", bytes: Data("STRIPE=\(SecretGateTests.value)\n".utf8))
        let again = try #require(w.refusal { try w.share(w.fx.eng1, ["F-20"], to: "#team", knownValues: SecretGateTests.known) })
        #expect(again.contains("contains a stored secret"), "\(again)")
        #expect(try w.messages(kind: .share).isEmpty)
    }

    @Test func itemBranchPinSurvivesMergeAndBranchDelete() throws {
        let w = try W()
        let git = w.fx.git
        let original = try w.fx.head("item/ENG-1")
        _ = try w.share(w.fx.eng1, ["ENG-1:src/a.ts"], to: "@qa-2")
        let shared = try #require(try w.messages(kind: .share).last)
        let row = try #require(try w.store.messageRefs(companyId: w.c.id, messageId: shared.id).first)
        #expect(row.rev == original)
        // A commit pin off main is held by its share ref.
        #expect(try git.git(["rev-parse", "refs/brahma/shares/\(row.id)"]) == original)
        // The item merges as a new commit on main, its branch is deleted and git prunes.
        try w.cf.commit(["other.txt": Data("x\n".utf8)])
        try git.git(["checkout", "-q", "main"])
        try git.git(["cherry-pick", original])
        try git.git(["branch", "-D", "item/ENG-1"])
        try git.git(["reflog", "expire", "--expire=now", "--all"])
        try git.git(["gc", "-q", "--prune=now"])
        #expect(try git.git(["cat-file", "-t", original]) == "commit", "the share ref kept the shared commit")
        let pinned = try #require(row.workRef)
        let out = try w.cf.open(.qa2, pinned: pinned)
        #expect(out.text.components(separatedBy: "\n").dropFirst() == ["    | one", "    | TWO", "    | three"])
        let resolved = try w.store.resolveRef(pinned, for: .agent(w.fx.qa2.id), companyId: w.c.id)
        #expect(resolved.visibility == .full)
        let newer = try #require(resolved.newer)
        let main = try w.fx.head("main")
        #expect(newer.branch == nil && newer.rev == main && newer.id == "src/a.ts")
        // The text form a reader is given opens it too (the share ref makes its commit reachable).
        let text = try w.cf.open(.qa2, "ENG-1:src/a.ts@\(original.prefix(7))")
        #expect(text.text.contains("    | TWO"))
    }

    @Test func quoteIsVerified() throws {
        let w = try W()
        let router = MessageRouter(store: w.store)
        try w.store.addMember(channelId: w.fx.engChannel.id, member: w.fx.cto.id)
        let source = try router.post(companyId: w.c.id, channel: "eng", from: .agent(w.fx.eng1.id), text: "deploy freeze starts at 5pm")
        _ = try w.share(w.fx.eng1, ["msg:\(source.id)"], to: "#team", note: "fyi")
        let quote = try #require(try w.messages(kind: .share).last)
        // cto reads #eng: the source text, as stored, under the engine's chip.
        let cto = try w.lines(quote, for: .agent(w.fx.cto.id))
        #expect(cto.first == "[quote msg:\(source.id) · @eng-1 in #eng · verified]", "\(cto)")
        #expect(cto.contains("    | deploy freeze starts at 5pm"))
        // qa-2 is not in #eng: a locked chip, nothing of the text.
        let qa = try w.lines(quote, for: .agent(w.fx.qa2.id))
        #expect(qa == ["[locked message · ask the owner]"])
        // An edit to nothing: the quote is the source row's text, never the sharer's words.
        #expect(!quote.text.contains("deploy freeze"))
    }

    @Test func quoteOfOwnerDmLockedElsewhere() throws {
        let w = try W()
        let dm = w.fx.dmMessage   // owner → eng-1 "private hello"
        _ = try w.share(w.fx.eng1, ["msg:\(dm.id)"], to: "#team")
        let elsewhere = try #require(try w.messages(kind: .share).last)
        for reader in [w.fx.qa2, w.fx.cto, w.fx.eng1] {
            #expect(try w.lines(elsewhere, for: .agent(reader.id)) == ["[locked message · ask the owner]"], "@\(reader.name)")
        }
        // Into another DM: the recipient can't read it, so the share is refused back.
        let refused = try #require(w.refusal { try w.share(w.fx.eng1, ["msg:\(dm.id)"], to: "@qa-2") })
        #expect(refused.hasPrefix("@qa-2 can't read msg:\(dm.id)"), "\(refused)")
        // Into the same DM: allowed, and both parties read the quote.
        _ = try w.share(w.fx.eng1, ["msg:\(dm.id)"], to: "@owner", note: "re this")
        let same = try #require(try w.messages(kind: .share).last)
        #expect(same.channelId == dm.channelId)
        #expect(try w.lines(same, for: .agent(w.fx.eng1.id)).contains("    | private hello"))
        #expect(try w.lines(same, for: .owner).contains("    | private hello"))
    }

    @Test func laterJoinerCannotReadEarlierChannelDrop() throws {
        let w = try W()
        // The owner dropped F-30 into #team when cto and eng-1 were its members (qa-2 joins later).
        try w.cf.addResource(30, name: "roadmap.md", ext: "md", bytes: Data("# Roadmap\n".utf8), scopeKind: "channel", scopeId: w.team.id,
                             readerSet: [w.fx.cto.id, w.fx.eng1.id])
        let qa = try w.fx.resolve(.qa2, try w.fx.ref("F-30"))
        #expect(qa.visibility == .locked(approverRole: "owner") && qa.title.isEmpty)
        _ = try w.share(w.fx.eng1, ["F-30"], to: "#team")
        let m = try #require(try w.messages(kind: .share).last)
        #expect(try w.lines(m, for: .agent(w.fx.qa2.id)) == ["[locked resource · ask the owner]"])
        #expect(try w.lines(m, for: .agent(w.fx.cto.id)).first?.contains("· F-30 \"roadmap.md\"") == true)
        // And qa-2 can't open it.
        #expect(w.cf.failure { try w.cf.open(.qa2, "F-30") } == "that ref isn't available to you")
    }

    @Test func systemMessagesNotScanned() throws {
        let w = try W()
        let router = MessageRouter(store: w.store)
        let system = try router.post(companyId: w.c.id, channel: "team", from: .system, text: "A-5 approved; see ENG-1 and src/a.ts")
        #expect(try w.store.messageRefs(companyId: w.c.id, messageId: system.id).isEmpty)
        // The same words from an agent become inline chips (refs it can't read at all are not rows of their own).
        let agent = try router.post(companyId: w.c.id, channel: "team", from: .agent(w.fx.eng1.id), text: "see ENG-1 and src/a.ts, not src/zz.ts")
        let rows = try w.store.messageRefs(companyId: w.c.id, messageId: agent.id)
        #expect(rows.map(\.canonical) == ["ENG-1", "src/a.ts@\(try w.fx.head())"])
        #expect(rows.allSatisfy { $0.inline })
        // No share ref is made for an inline chip.
        #expect(try w.fx.git.git(["for-each-ref", "refs/brahma/shares/"]).isEmpty)
    }

    @Test func attachmentsOnPostMessage() throws {
        let w = try W()
        try w.cf.addResource(21, name: "brief.md", ext: "md", bytes: Data("# Brief\n".utf8))
        let tools = w.tools(w.fx.eng1)
        let reply = try tools.call(name: "post_message", arguments: [
            "channel": .string("team"), "text": .string("the checkout code"),
            "attachments": .array([.string("src/checkout.tsx:1-10"), .string("F-21")]),
        ])
        #expect(reply == "Posted to #team with 2 attachments.")
        let m = try #require(try w.messages().last)
        #expect(m.kind == .text && m.text == "the checkout code")
        let rows = try w.store.messageRefs(companyId: w.c.id, messageId: m.id)
        #expect(rows.map(\.canonical) == ["src/checkout.tsx:1-10@\(try w.fx.head())", "F-21"])
        #expect(rows.allSatisfy { !$0.inline })
        // A DM's attachments: the recipient must be able to read each one.
        let refused = w.refusal { try w.tools(w.fx.cto).call(name: "send_dm", arguments: [
            "to": .string("@qa-2"), "text": .string("plan"), "attachments": .array([.string("F-1")]),
        ]) }
        #expect(refused?.hasPrefix("@qa-2 can't read F-1") == true, "\(refused ?? "")")
        let dm = try w.tools(w.fx.eng1).call(name: "send_dm", arguments: [
            "to": .string("@qa-2"), "text": .string("here"), "attachments": .array([.string("src/a.ts")]),
        ])
        #expect(dm == "Sent DM to @qa-2 with 1 attachment.")
        // More than six are refused.
        let many = JSONValue.array(Array(repeating: .string("src/a.ts"), count: 7))
        #expect(w.refusal { try tools.call(name: "post_message", arguments: ["channel": .string("team"), "text": .string("x"), "attachments": many]) }
            == "attachments takes at most 6 refs")
    }

    @Test func shareAndOpenRefTools() throws {
        let w = try W()
        let head = try w.fx.head("item/ENG-1")
        let reply = try w.tools(w.fx.eng1).call(name: "share", arguments: [
            "refs": .array([.string("ENG-1:src/a.ts")]), "to": .string("@qa-2"), "note": .string("look"),
        ])
        #expect(reply == "Shared ENG-1:src/a.ts @\(head.prefix(7)) with @qa-2.")
        let out = try w.tools(w.fx.qa2).call(name: "open_ref", arguments: ["ref": .string("ENG-1:src/a.ts@\(head.prefix(7))"), "lines": .string("2-3")])
        #expect(out == "[file ENG-1:src/a.ts @\(head.prefix(7)) · 3 lines · TypeScript]\n    | TWO\n    | three")
        #expect(w.refusal { try w.tools(w.fx.qa2).call(name: "open_ref", arguments: ["ref": .string(".brahma/labs/eng-1/mine.txt")]) }
            == "that ref isn't available to you")
        // The owner-only paths are no agent tool.
        #expect(!CompanyToolNames.all.contains { $0.contains("purge") || $0.lowercased().contains("original") })
        #expect(CompanyToolNames.base.contains("share") && CompanyToolNames.base.contains("open_ref"))
    }

    /// Controller note (C2b-carry, Ruling 41): bytes are served through `Store.gatedBytes`, so a PDF the owner vouched for is
    /// shared and opened as its flattened copy, never as the original.
    @Test func vouchedPDFIsServedFlattened() throws {
        let w = try W()
        let reader = UnverifiedPDFReader(parts: [PDFPart(kind: .pageText, data: Data("page".utf8))])
        let pdf = Data("%PDF-1.4 an anomalous pdf\n%%EOF\n".utf8)
        try w.cf.addResource(40, name: "plan.pdf", ext: "pdf", bytes: pdf)
        // Unvouched: refused (its structure couldn't be verified), both to share and to open.
        let refused = try #require(w.refusal { try w.share(w.fx.eng1, ["F-40"], to: "#team", archives: reader) })
        #expect(refused.hasPrefix("this PDF's structure couldn't be verified"), "\(refused)")
        _ = try w.store.vouchFile(companyId: w.c.id, canonical: "F-40", sha256: SHA256.hex(pdf), now: w.cf.now)
        #expect(try w.share(w.fx.eng1, ["F-40"], to: "#team", archives: reader) == "Shared F-40 with #team.")
        let copy = try w.store.openRef(companyId: w.c.id, reader: .agent(w.fx.qa2.id), ref: "F-40", lines: nil, copy: true, turnId: nil,
                                       context: w.fx.ctx, knownValues: [], paths: w.cf.paths, now: w.cf.now, archives: reader)
        let path = try #require(copy.materializedPath)
        let bytes = try Data(contentsOf: w.cf.workspace.appending(path: path))
        #expect(bytes != pdf && bytes.starts(with: UnverifiedPDFReader.copyMark), "the original was served")
    }

    @Test func messageIngestTakesAttachmentSensitivity() throws {
        let w = try W()
        _ = try w.store.kbWrite(companyId: w.c.id, by: .owner, path: "Eng/Plans",
                                body: "# Plans\n\nOpen.\n\n## Comp bands [restricted: cto]\n\nBands.\n", knownValues: [])
        let router = MessageRouter(store: w.store)
        let restricted = try w.store.postWithAttachments(companyId: w.c.id, by: w.fx.cto.id, to: "#team", text: "the quarterly ocelot numbers",
                                                         attachments: ["kb:Eng/Plans#comp-bands"], replyTo: nil, context: w.fx.ctx,
                                                         knownValues: [], paths: w.cf.paths, now: w.cf.now)
        let row = try #require(try w.store.messageRefs(companyId: w.c.id, messageId: restricted.id).first)
        #expect(row.sensitivity == "restricted" && row.restrictions == #"[["cto"]]"#)
        let plain = try w.store.postWithAttachments(companyId: w.c.id, by: w.fx.eng1.id, to: "#team", text: "a plain ocelot note",
                                                    attachments: ["src/a.ts"], replyTo: nil, context: w.fx.ctx, knownValues: [],
                                                    paths: w.cf.paths, now: w.cf.now)
        _ = try router.post(companyId: w.c.id, channel: "team", from: .agent(w.fx.eng1.id), text: "nothing attached")
        try MemoryIngest.run(store: w.store, companyId: w.c.id, paths: w.cf.paths, now: w.cf.now.addingTimeInterval(60))
        let docs = try w.store.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT * FROM memoryDoc WHERE companyId = ? AND source = 'message'", arguments: [w.c.id])
        }
        let doc = try #require(docs.first { ($0["sourceId"] as String) == restricted.id })
        #expect(doc["sensitivity"] == "restricted" && doc["restrictions"] == #"[["cto"]]"#)
        let other = try #require(docs.first { ($0["sourceId"] as String) == plain.id })
        #expect(other["sensitivity"] == "normal")
        let index = MemoryIndex(store: w.store)
        let later = w.cf.now.addingTimeInterval(120)
        let engHits = try index.search(companyId: w.c.id, scope: .agent(w.fx.eng1.id), query: "ocelot", now: later).map(\.ref)
        #expect(engHits == ["msg:\(plain.id)"], "eng-1 has no cto role: \(engHits)")
        #expect(try index.search(companyId: w.c.id, scope: .owner, query: "quarterly ocelot", now: later).map(\.ref).contains("msg:\(restricted.id)"))
        #expect(try index.search(companyId: w.c.id, scope: .agent(w.fx.cto.id), query: "quarterly ocelot", now: later).map(\.ref)
            .contains("msg:\(restricted.id)"))
    }

    @Test func taintedSessionMessageIngestedTainted() throws {
        let w = try W()
        // eng-1 is in turn 2 of a tainted session: its agent row says so, but no turn row records when (taintAt sees nothing).
        let eng = w.fx.eng1.id
        try w.store.writer.write { db in
            try db.execute(sql: "UPDATE agent SET sessionTainted = 1, taintSources = 'WebFetch' WHERE id = ?", arguments: [eng])
        }
        #expect(try w.store.taintAt(agentId: eng, at: w.cf.now) == nil)
        let m = try MessageRouter(store: w.store).post(companyId: w.c.id, channel: "team", from: .agent(eng), text: "the heron findings",
                                                         now: w.cf.now)
        #expect(m.fromTaintedSession && m.taintSource == "WebFetch")
        try MemoryIngest.run(store: w.store, companyId: w.c.id, paths: w.cf.paths, now: w.cf.now.addingTimeInterval(60))
        let doc = try #require(try w.store.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM memoryDoc WHERE companyId = ? AND source = 'message' AND sourceId = ?",
                             arguments: [w.c.id, m.id])
        })
        #expect(doc["tainted"] == true && doc["taintReason"] == "written by a session that read WebFetch")
        let out = try w.tools(w.fx.qa2).call(name: "search_memory", arguments: ["query": .string("heron")])
        #expect(out.contains("msg:\(m.id)") && !out.contains("the heron findings"), "\(out)")
    }

    // MARK: Fix round 1

    /// The share copies (private snapshots, redacted copies) of the company: `resource` rows added by a share.
    private func shareCopies(_ w: W) throws -> [Resource] {
        let cId = w.c.id
        return try w.store.writer.read { db in
            try Resource.fetchAll(db, sql: "SELECT * FROM resource WHERE companyId = ? AND addedVia = 'share'", arguments: [cId])
        }
    }

    /// I-1 (Ruling 43): a refused share leaves nothing readable behind: every ref is gated before any snapshot or copy is
    /// made, and whatever a later step made is removed (rows, vault files, index docs, share refs).
    @Test func refusedShareLeavesNoSnapshot() throws {
        let w = try W()
        try w.cf.commit(["src/keys.ts": Data("let key = \"\(SecretGateTests.value)\"\n".utf8)])
        let refused = try #require(w.refusal { try w.share(w.fx.eng1, [".brahma/labs/eng-1/mine.txt", "src/keys.ts"], to: "@qa-2",
                                                            knownValues: SecretGateTests.known) })
        #expect(refused.contains("contains a stored secret"), "\(refused)")
        #expect(try shareCopies(w).isEmpty, "the snapshot of the first ref was made before the second was gated")
        #expect(try w.store.newResourceLines(agent: try #require(try w.store.agent(id: w.fx.qa2.id))).isEmpty)
        // A step after the snapshot fails (the second ref's share ref can't be written): the snapshot is removed again.
        w.store.refHooks.setGitRunner(UpdateRefFailingRunner())
        defer { w.store.refHooks.setGitRunner(nil) }
        _ = w.refusal { try w.share(w.fx.eng1, [".brahma/labs/eng-1/mine.txt", "ENG-1:src/a.ts"], to: "@qa-2") }
        #expect(try shareCopies(w).isEmpty)
        w.store.refHooks.setGitRunner(nil)
        // The post itself fails after everything was made: nothing remains, no share ref either.
        w.store.refHooks.setFailSharePost(true)
        _ = w.refusal { try w.share(w.fx.eng1, [".brahma/labs/eng-1/mine.txt", "ENG-1:src/a.ts"], to: "@qa-2") }
        w.store.refHooks.setFailSharePost(false)
        #expect(try shareCopies(w).isEmpty)
        #expect(try w.fx.git.git(["for-each-ref", "refs/brahma/shares/"]).isEmpty)
        #expect(try w.messages(kind: .share).isEmpty)
        let docs = try w.store.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memoryDoc WHERE companyId = ? AND source = 'resource'", arguments: [w.c.id])
        }
        #expect(docs == 0)
        // A share that goes keeps its snapshot.
        _ = try w.share(w.fx.eng1, [".brahma/labs/eng-1/mine.txt"], to: "@qa-2")
        #expect(try shareCopies(w).count == 1)
    }

    /// I-1: a copy no share message points at (a crash between the snapshot and the post) is swept at a later tick, after
    /// `ShareLimits.orphanGrace`; one a message points at, or one younger than the grace, stays.
    @Test func orphanShareCopiesSwept() throws {
        let w = try W()
        _ = try w.share(w.fx.eng1, [".brahma/labs/eng-1/mine.txt"], to: "@qa-2")
        let kept = try #require(try shareCopies(w).first)
        let old = w.cf.now.addingTimeInterval(-2 * ShareLimits.orphanGrace)
        let orphan = try w.store.vaultShareCopy(companyId: w.c.id, data: Data("left behind\n".utf8), fileName: "left.txt", sourceDetail: "left.txt",
                                                scope: .agent(w.fx.eng1.id), readerSet: [w.fx.eng1.id, w.fx.qa2.id], futureHolders: false,
                                                provenance: .agent(w.fx.eng1.id), taint: nil, secretScan: .none, paths: w.cf.paths, now: old)
        let fresh = try w.store.vaultShareCopy(companyId: w.c.id, data: Data("in flight\n".utf8), fileName: "fresh.txt", sourceDetail: "fresh.txt",
                                               scope: .agent(w.fx.eng1.id), readerSet: [w.fx.eng1.id], futureHolders: false,
                                               provenance: .agent(w.fx.eng1.id), taint: nil, secretScan: .none, paths: w.cf.paths, now: w.cf.now)
        let cId = w.c.id
        try w.store.writer.write { db in try db.execute(sql: "UPDATE resource SET createdAt = ? WHERE companyId = ? AND number = ?",
                                                        arguments: [old, cId, kept.number]) }
        let orphanPath = try #require(try w.store.resource(companyId: cId, number: orphan)?.vaultPath)
        #expect(try w.store.sweepShareOrphans(companyId: cId, paths: w.cf.paths, now: w.cf.now) == 1)
        #expect(try w.store.resource(companyId: cId, number: orphan) == nil)
        #expect(!FileManager.default.fileExists(atPath: w.cf.vault.root.appending(path: orphanPath).path))
        #expect(try w.store.resource(companyId: cId, number: kept.number) != nil, "a shared copy was swept")
        #expect(try w.store.resource(companyId: cId, number: fresh) != nil, "an in-flight copy was swept")
        #expect(w.cf.failure { try w.cf.open(.qa2, "F-\(orphan)") } == "that ref isn't available to you")
    }

    /// I-2: what an agent shares is never listed as a new resource "from the owner" (the share message delivers it).
    @Test func agentShareNotListedAsOwnerResource() throws {
        let w = try W()
        _ = try w.share(w.fx.eng1, [".brahma/labs/eng-1/mine.txt"], to: "@qa-2")
        // A worktree file with a secret pattern is shared as a redacted company copy.
        let wt = try w.fx.git.ws.addWorktree(key: "ENG-1")
        try w.fx.git.write("src/a.ts", "key = \(SecretGateTests.aws)\n", in: wt)
        _ = try w.share(w.fx.eng1, ["ENG-1:src/a.ts@worktree"], to: "#team")
        #expect(try shareCopies(w).count == 2)
        for agent in [w.fx.qa2, w.fx.cto, w.fx.eng3] {
            let lines = try w.store.newResourceLines(agent: try #require(try w.store.agent(id: agent.id)))
            #expect(lines.isEmpty, "@\(agent.name): \(lines)")
        }
        // An owner drop is still listed.
        try w.cf.addResource(50, name: "owner.md", ext: "md", bytes: Data("x\n".utf8))
        let cId = w.c.id
        try w.store.writer.write { db in
            try db.execute(sql: "UPDATE resource SET createdAt = ? WHERE companyId = ? AND number = 50", arguments: [Date().addingTimeInterval(60), cId])
        }
        #expect(try w.store.newResourceLines(agent: try #require(try w.store.agent(id: w.fx.qa2.id))).contains { $0.contains("from the owner") })
    }

    /// I-3: an engine failure (git, the vault, the database) reaches the agent only as the generic text; the detail goes to
    /// the owner's activity feed.
    @Test func engineFailuresAreGeneric() throws {
        let w = try W()
        w.store.refHooks.setGitRunner(UpdateRefFailingRunner())
        defer { w.store.refHooks.setGitRunner(nil) }
        #expect(w.refusal { try w.share(w.fx.eng1, ["ENG-1:src/a.ts"], to: "@qa-2") } == "that ref isn't available to you")
        #expect(w.refusal { try w.share(w.fx.eng1, ["src/a.ts", "ENG-1:src/a.ts"], to: "@qa-2") } == "ref 2 isn't available to you")
        let viaTool = w.refusal { try w.tools(w.fx.eng1).call(name: "share", arguments: [
            "refs": .array([.string("ENG-1:src/a.ts")]), "to": .string("@qa-2"),
        ]) }
        #expect(viaTool == "that ref isn't available to you")
        #expect(try w.activity(.error).contains { $0.contains("injected") }, "the detail is the owner's")
        // A failing post (the database) is generic too.
        w.store.refHooks.setGitRunner(nil)
        w.store.refHooks.setFailSharePost(true)
        defer { w.store.refHooks.setFailSharePost(false) }
        #expect(w.refusal { try w.share(w.fx.eng1, ["src/a.ts"], to: "@qa-2") } == "that ref isn't available to you")
        #expect(w.refusal { try w.tools(w.fx.eng1).call(name: "post_message", arguments: [
            "channel": .string("team"), "text": .string("x"), "attachments": .array([.string("src/a.ts")]),
        ]) } == "that ref isn't available to you")
    }

    // MARK: Fix round 2 (Ruling 49)

    /// A pin that fails after it wrote its share ref leaves no share ref behind.
    @Test func failedPinLeavesNoShareRef() throws {
        let w = try W()
        let wt = try w.fx.git.ws.addWorktree(key: "ENG-1")
        try w.fx.git.write("src/a.ts", "work in progress\n", in: wt)
        w.store.refHooks.setFailAfterShareRef(true)
        defer { w.store.refHooks.setFailAfterShareRef(false) }
        #expect(w.refusal { try w.share(w.fx.eng1, ["ENG-1:src/a.ts@worktree"], to: "@qa-2") } == "that ref isn't available to you")
        #expect(try w.fx.git.git(["for-each-ref", "refs/brahma/shares/"]).isEmpty)
        #expect(try w.messages(kind: .share).isEmpty)
    }

    /// The tick's sweep also removes share refs no `messageRef` row names, once older than the grace.
    @Test func orphanShareRefsSwept() throws {
        let w = try W()
        _ = try w.share(w.fx.eng1, ["ENG-1:src/a.ts"], to: "@qa-2")
        let kept = try #require(try w.fx.git.git(["for-each-ref", "--format=%(refname)", "refs/brahma/shares/"]).split(separator: "\n").first)
        let head = try w.fx.head("item/ENG-1")
        let old = Store.shareRowId(now: w.cf.now.addingTimeInterval(-2 * ShareLimits.orphanGrace))
        let fresh = Store.shareRowId(now: w.cf.now)
        try w.fx.git.git(["update-ref", "refs/brahma/shares/\(old)", head])
        try w.fx.git.git(["update-ref", "refs/brahma/shares/\(fresh)", head])
        _ = try w.store.sweepShareOrphans(companyId: w.c.id, paths: w.cf.paths, now: w.cf.now)
        let left = Set(try w.fx.git.git(["for-each-ref", "--format=%(refname)", "refs/brahma/shares/"]).split(separator: "\n").map(String.init))
        #expect(!left.contains("refs/brahma/shares/\(old)"), "an orphan share ref older than the grace stayed")
        #expect(left.contains("refs/brahma/shares/\(fresh)"), "an in-flight share ref was swept")
        #expect(left.contains(String(kept)), "a referenced share ref was swept")
        // The referenced one stays even once it is old: its row names it.
        _ = try w.store.sweepShareOrphans(companyId: w.c.id, paths: w.cf.paths, now: w.cf.now.addingTimeInterval(10 * ShareLimits.orphanGrace))
        let later = Set(try w.fx.git.git(["for-each-ref", "--format=%(refname)", "refs/brahma/shares/"]).split(separator: "\n").map(String.init))
        #expect(later == [String(kept)])
    }

    /// N-1: a failure after the refs were prepared (reading the channel or the inline refs) removes the snapshot again.
    @Test func failureAfterPreparationLeavesNothing() throws {
        let w = try W()
        w.store.refHooks.setAfterSharePrepared { throw SafeGitError.io("injected: the channel can't be read") }
        defer { w.store.refHooks.setAfterSharePrepared(nil) }
        #expect(w.refusal { try w.share(w.fx.eng1, [".brahma/labs/eng-1/mine.txt", "ENG-1:src/a.ts"], to: "#team") } == "that ref isn't available to you")
        #expect(try shareCopies(w).isEmpty)
        #expect(try w.fx.git.git(["for-each-ref", "refs/brahma/shares/"]).isEmpty)
    }

    /// M-1: step 4 gates the whole bytes (past the shown cap), so a large file with a secret refuses the share before an
    /// earlier ref's snapshot exists.
    @Test func largeSecretFileRefusedBeforeSnapshot() throws {
        let w = try W()
        let big = String(repeating: "x", count: SafeGit.maxTextBytes + 10) + "\nkey = \(SecretGateTests.value)\n"
        try w.cf.commit(["src/big.txt": Data(big.utf8)])
        let refused = try #require(w.refusal { try w.share(w.fx.eng1, [".brahma/labs/eng-1/mine.txt", "src/big.txt"], to: "@qa-2",
                                                            knownValues: SecretGateTests.known) })
        #expect(refused.contains("contains a stored secret"), "\(refused)")
        #expect(try shareCopies(w).isEmpty)
    }

    /// M-2: a copy is stamped when it is made, and the sweep re-checks in its deleting transaction that nothing points at it.
    @Test func sweepSparesCopiesInFlight() throws {
        let w = try W()
        let started = w.cf.now.addingTimeInterval(-2 * ShareLimits.orphanGrace)
        _ = try w.store.share(companyId: w.c.id, by: w.fx.eng1.id, refs: [".brahma/labs/eng-1/mine.txt"], to: "@qa-2", note: nil, replyTo: nil,
                              context: w.fx.ctx, knownValues: [], paths: w.cf.paths, now: started)
        let copy = try #require(try shareCopies(w).first)
        #expect(copy.createdAt > started.addingTimeInterval(ShareLimits.orphanGrace), "stamped with the share's start")
        // Even when old, a copy a row names is never deleted (the delete re-checks).
        let cId = w.c.id
        try w.store.writer.write { db in try db.execute(sql: "UPDATE resource SET createdAt = ? WHERE companyId = ? AND number = ?",
                                                        arguments: [started, cId, copy.number]) }
        w.store.discardShareArtifacts(companyId: cId, [.resource(copy.number)], paths: w.cf.paths, now: w.cf.now, onlyOrphans: true)
        #expect(try w.store.resource(companyId: cId, number: copy.number) != nil)
    }

    @Test func everyToolClassified() {
        #expect(Set(CompanyToolNames.all).subtracting(TaintPolicy.taintSafeTools) == TaintPolicy.reviewedHighRisk)
        #expect(TaintPolicy.taintSafeTools.contains("share") && TaintPolicy.taintSafeTools.contains("open_ref"))
    }
}

/// A git runner that fails `update-ref` (writing a share ref) and runs every other call for real.
struct UpdateRefFailingRunner: GitProcessRunning {
    func run(args: [String], env: [String: String], stdin: Data?, timeout: Duration, outputCap: Int) throws -> (status: Int32, stdout: Data, stderr: Data) {
        try run(args: args, env: env, stdin: stdin, timeout: timeout, outputCap: outputCap, workTreeDescriptor: nil)
    }
    func run(args: [String], env: [String: String], stdin: Data?, timeout: Duration, outputCap: Int, workTreeDescriptor: Int32?) throws -> (status: Int32, stdout: Data, stderr: Data) {
        if args.contains("update-ref") { return (128, Data(), Data("fatal: injected update-ref failure\n".utf8)) }
        return try LiveGitRunner().run(args: args, env: env, stdin: stdin, timeout: timeout, outputCap: outputCap, workTreeDescriptor: workTreeDescriptor)
    }
}
