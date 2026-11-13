import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Plan ML Task 2: auto-ingest of messages, items, asks, decisions, hand-offs and retros from restore-safe cursors.
@Suite(.scratch) struct MemoryIngestTests {
    /// Acme: mgr-1 ← {eng-1, eng-2} (team payments). The owner's zone is UTC so titles are fixed text.
    struct W {
        let store: Store, company: Company, paths: BrahmaPaths
        let mgr: Agent, eng1: Agent, eng2: Agent
        let t0 = Date(timeIntervalSince1970: 1_800_000_000)   // 2027-01-15 08:00:00 UTC
        var index: MemoryIndex { MemoryIndex(store: store) }
        var router: MessageRouter { MessageRouter(store: store) }

        init(store: Store? = nil, name: String = "Acme") throws {
            let s = try store ?? Store.inMemory()
            let root = try tempDir()
            let c = try s.createCompany(name: name, goal: "g", workspacesRoot: root.appending(path: "ws"))
            try s.setOwnerTimeZone("UTC")
            self.store = s; company = c
            paths = BrahmaPaths(home: root.appending(path: "home"), workspaces: root.appending(path: "ws"))
            mgr = try s.hire(companyId: c.id, name: "mgr-1", role: "manager", model: "sonnet")
            eng1 = try s.hire(companyId: c.id, name: "eng-1", role: "engineer", model: "sonnet", managerId: mgr.id, team: "payments")
            eng2 = try s.hire(companyId: c.id, name: "eng-2", role: "engineer", model: "sonnet", managerId: mgr.id, team: "payments")
        }

        func at(_ seconds: TimeInterval) -> Date { t0.addingTimeInterval(seconds) }

        @discardableResult
        func run(at seconds: TimeInterval = 3600) throws -> Int {
            try MemoryIngest.run(store: store, companyId: company.id, paths: paths, now: at(seconds))
        }

        func search(_ reader: Reader, _ q: String) throws -> [MemoryHit] {
            try index.search(companyId: company.id, scope: reader, query: q, now: at(7200))
        }

        func refs(_ reader: Reader, _ q: String) throws -> [String] { try search(reader, q).map(\.ref).sorted() }

        func agent(_ a: Agent) -> Reader { .agent(a.id) }

        func doc(_ source: MemorySource, _ sourceId: String) throws -> Row? {
            try store.writer.read { db in
                try Row.fetchOne(db, sql: "SELECT * FROM memoryDoc WHERE companyId = ? AND source = ? AND sourceId = ?",
                                 arguments: [company.id, source.rawValue, sourceId])
            }
        }

        func docs(_ source: MemorySource? = nil) throws -> [Row] {
            try store.writer.read { db in
                try Row.fetchAll(db, sql: "SELECT * FROM memoryDoc WHERE companyId = ? AND (? IS NULL OR source = ?) ORDER BY id",
                                 arguments: [company.id, source?.rawValue, source?.rawValue])
            }
        }

        func activity(_ text: String) throws -> Int {
            try store.writer.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM activityEvent WHERE companyId = ? AND text = ?",
                                 arguments: [company.id, text]) ?? 0
            }
        }

        /// A turn row of `agent` that started at `start`, optionally tainted at `taintedAt` and/or starting a fresh session.
        func turn(_ agent: Agent, start: TimeInterval, taintedAt: TimeInterval? = nil, source: String? = nil, fresh: String? = nil) throws {
            try store.writer.write { db in
                var t = Turn(id: UUID().uuidString, agentId: agent.id, companyId: company.id, startedAt: at(start),
                             endedAt: at(start + 30), outcome: .succeeded, summary: "ok", costUSD: nil)
                t.taintedAt = taintedAt.map(at); t.taintSource = source; t.freshSessionReason = fresh
                try t.insert(db)
            }
        }

        func vacuum(into url: URL) throws {
            try store.writer.writeWithoutTransaction { db in try db.execute(sql: "VACUUM INTO ?", arguments: [url.path]) }
        }

        /// The messages indexed with "ocelot" in their text (all of them: search returns at most `MemoryPolicy.maxHits`).
        func ocelots() throws -> [String] {
            try docs(.message).filter { ($0["body"] as String).contains("ocelot") }.map { $0["sourceId"] as String }.sorted()
        }

        func cursorPositions() throws -> [String] {
            try store.writer.read { db in
                try String.fetchAll(db, sql: "SELECT position FROM memoryCursor WHERE companyId = ?", arguments: [company.id])
            }
        }

        func handoffsDir(_ key: String) -> URL {
            URL(fileURLWithPath: company.workspacePath).appending(path: ".brahma/handoffs/\(key)", directoryHint: .isDirectory)
        }

        func insertHandoff(item: WorkItem, path: URL, at seconds: TimeInterval) throws -> Handoff {
            let h = Handoff(id: UUID().uuidString, companyId: company.id, itemId: item.id, authorId: "owner", toAgentId: nil,
                            path: path.path, createdAt: at(seconds))
            try store.writer.write { db in try h.insert(db) }
            return h
        }
    }

    // MARK: Messages

    @Test func messageIngestKeepsChannelClass() throws {
        let w = try W()
        let general = try w.router.post(companyId: w.company.id, channel: "general", from: .agent(w.eng1.id), text: "the falcon release", now: w.at(0))
        let dm = try w.router.sendDM(companyId: w.company.id, from: .owner, to: "eng-2", text: "a quiet falcon", now: w.at(60))
        #expect(try w.run() == 2)

        let g = try #require(try w.doc(.message, general.id))
        #expect(g["ref"] == "msg:\(general.id)")
        #expect(g["title"] == "#general @eng-1 2027-01-15 08:00")
        #expect(g["body"] == "the falcon release")
        #expect(g["accessKind"] == "channel"); #expect(g["accessId"] == general.channelId)
        #expect(g["sensitivity"] == "normal"); #expect(g["provenance"] == "agent:\(w.eng1.id)"); #expect(g["authorId"] == w.eng1.id)
        #expect(g["tainted"] == false)

        let d = try #require(try w.doc(.message, dm.id))
        #expect(d["title"] == "DM @eng-2 · @owner 2027-01-15 08:01")
        #expect(d["accessKind"] == "dm"); #expect(d["accessId"] == dm.channelId)
        #expect(d["provenance"] == "owner")

        // Members of #general read the post; only the DM's parties read the DM.
        #expect(try w.refs(w.agent(w.eng2), "falcon") == ["msg:\(dm.id)", "msg:\(general.id)"].sorted())
        #expect(try w.refs(w.agent(w.mgr), "falcon") == ["msg:\(general.id)"])
    }

    @Test func dmShareNotRecallableByOthers() throws {
        let w = try W()
        let m = try w.router.sendDM(companyId: w.company.id, from: .owner, to: "eng-1", text: "the vendor code is ORCHID", now: w.at(0))
        try w.run()
        #expect(try w.refs(w.agent(w.eng1), "ORCHID") == ["msg:\(m.id)"])
        #expect(try w.refs(.owner, "ORCHID") == ["msg:\(m.id)"])
        #expect(try w.search(w.agent(w.eng2), "ORCHID").isEmpty)
        #expect(try w.search(w.agent(w.mgr), "ORCHID").isEmpty, "a manager never reads its report's DMs")
        #expect(try w.index.document(companyId: w.company.id, scope: w.agent(w.eng2), ref: "msg:\(m.id)", now: w.at(7200)) == nil)
    }

    @Test func channelMessageVisibleToMembersOnly() throws {
        let w = try W()
        _ = try w.store.createChannel(companyId: w.company.id, name: "skunkworks", members: [w.eng1.id, w.mgr.id, "owner"])
        let m = try w.router.post(companyId: w.company.id, channel: "skunkworks", from: .agent(w.eng1.id), text: "the walrus prototype",
                                  now: w.at(0))
        try w.run()
        #expect(try w.refs(w.agent(w.eng1), "walrus") == ["msg:\(m.id)"])
        #expect(try w.refs(w.agent(w.mgr), "walrus") == ["msg:\(m.id)"])
        #expect(try w.refs(.owner, "walrus") == ["msg:\(m.id)"])
        #expect(try w.search(w.agent(w.eng2), "walrus").isEmpty)
        #expect(try #require(try w.doc(.message, m.id))["title"] == "#skunkworks @eng-1 2027-01-15 08:00")
    }

    // MARK: Asks

    @Test func infoAskAnswerNotSearchableByOthers() throws {
        let w = try W()
        let ask = try w.store.requestFromOwner(companyId: w.company.id, by: .agent(w.eng1.id), title: "Vendor code",
                                               question: "Which vendor code do we use?", now: w.at(0))
        _ = try w.store.ownerAnswer(askId: ask.id, text: "ORCHID", now: w.at(60))
        try w.run()

        #expect(try w.search(w.agent(w.eng2), "ORCHID").isEmpty)
        #expect(try w.search(w.agent(w.mgr), "ORCHID").isEmpty)
        // The requester finds the answer through the owner's DM, never through the owner's part of the ask.
        let mine = try w.search(w.agent(w.eng1), "ORCHID")
        #expect(!mine.isEmpty); #expect(mine.allSatisfy { $0.source == .message })
        #expect(try w.refs(.owner, "ORCHID").contains(ask.ref))

        let main = try #require(try w.doc(.ask, ask.id))
        #expect(main["ref"] == ask.ref); #expect(main["accessKind"] == "agent"); #expect(main["accessId"] == w.eng1.id)
        #expect((main["title"] as String) == "\(ask.ref) Question: Vendor code")
        #expect(!(main["body"] as String).contains("ORCHID"))
        #expect((main["body"] as String).contains("answered by owner"))
        let owner = try #require(try w.doc(.ask, "\(ask.id)#owner"))
        #expect(owner["ref"] == ask.ref); #expect(owner["accessKind"] == "owner"); #expect(owner["title"] == "\(ask.ref) owner note")
        #expect(owner["body"] == "ORCHID"); #expect(owner["provenance"] == "owner")

        // Another agent's recall of the ask: the same answer as a ref that does not exist.
        #expect(try w.index.document(companyId: w.company.id, scope: w.agent(w.eng2), ref: ask.ref, now: w.at(7200)) == nil)
        #expect(try w.index.document(companyId: w.company.id, scope: w.agent(w.eng2), ref: "A-999", now: w.at(7200)) == nil)
        #expect(try w.index.document(companyId: w.company.id, scope: w.agent(w.eng1), ref: ask.ref, now: w.at(7200)) != nil)
    }

    @Test func askReadableByRequesterAndApproverOnly() throws {
        let w = try W()
        var ask = try w.store.propose(companyId: w.company.id, by: .agent(w.eng1.id), kind: .other, category: "tooling",
                                      title: "Adopt the narwhal linter", summary: "narwhal catches the bugs we keep shipping",
                                      payload: AskPayload(question: "Can we adopt it?", options: [AskOption(label: "Adopt", pros: "fewer bugs", cons: "setup")],
                                                          recommendation: "Adopt", proposal: "add narwhal to CI"),
                                      now: w.at(0))
        if ask.internalApproverId == nil {
            // The approver as the preset routes it (a manager); set here when this company's preset routes elsewhere.
            try w.store.writer.write { db in
                try db.execute(sql: "UPDATE ask SET internalApproverId = ?, updatedAt = ? WHERE id = ?", arguments: [w.mgr.id, w.at(10), ask.id])
            }
            ask = try #require(try w.store.writer.read { db in try Ask.fetchOne(db, key: ask.id) })
        }
        try w.run()
        let row = try #require(try w.doc(.ask, ask.id))
        #expect(row["accessKind"] == "agent"); #expect(row["accessId"] == w.eng1.id)
        let readers = try JSONDecoder().decode([String].self, from: Data(((row["readerSet"] as String?) ?? "[]").utf8))
        #expect(Set(readers) == [w.eng1.id, try #require(ask.internalApproverId)])
        let body: String = row["body"]
        for part in ["narwhal catches the bugs", "Can we adopt it?", "add narwhal to CI", "Adopt: fewer bugs / setup", "Adopt"] {
            #expect(body.contains(part), "\(part)")
        }
        #expect(try w.refs(w.agent(w.eng1), "narwhal") == [ask.ref])
        #expect(try w.refs(.owner, "narwhal").contains(ask.ref))
        #expect(try w.search(w.agent(w.eng2), "narwhal").isEmpty)
        if ask.internalApproverId == w.mgr.id { #expect(try w.refs(w.agent(w.mgr), "narwhal") == [ask.ref]) }

        // An agent that decides it joins the readers (decidedBy "@eng-2").
        try w.store.writer.write { db in
            try db.execute(sql: "UPDATE ask SET decidedBy = '@eng-2', status = 'approved', updatedAt = ? WHERE id = ?",
                           arguments: [w.at(120), ask.id])
        }
        try w.run(at: 7200)
        #expect(try w.refs(w.agent(w.eng2), "narwhal") == [ask.ref])
        #expect((try #require(try w.doc(.ask, ask.id))["body"] as String).contains("approved by @eng-2"))
    }

    @Test func systemAskOwnerOnly() throws {
        let w = try W()
        let ask = try w.store.propose(companyId: w.company.id, by: .system, kind: .other, category: "money",
                                      title: "Raise the heron budget", summary: "the heron spend doubled", now: w.at(0))
        try w.run()
        let row = try #require(try w.doc(.ask, ask.id))
        #expect(row["accessKind"] == "owner"); #expect(row["readerSet"] == nil as String?); #expect(row["provenance"] == "engine")
        #expect(try w.refs(.owner, "heron").contains(ask.ref))
        for a in [w.mgr, w.eng1, w.eng2] { #expect(try w.search(w.agent(a), "heron").isEmpty) }
    }

    @Test func terminationAskIsOwnerOnly() throws {
        let w = try W()
        let ask = try w.store.propose(companyId: w.company.id, by: .agent(w.mgr.id), kind: .other, category: "termination",
                                      title: "Part ways with eng-2", summary: "the otter incidents keep happening", now: w.at(0))
        try w.run()
        let row = try #require(try w.doc(.ask, ask.id))
        #expect(row["sensitivity"] == "hr-perf")
        #expect(try w.refs(.owner, "otter") == [ask.ref])
        // Not even the requester: hr-perf docs are the owner's.
        for a in [w.mgr, w.eng1, w.eng2] { #expect(try w.search(w.agent(a), "otter").isEmpty) }
        #expect(try w.index.document(companyId: w.company.id, scope: w.agent(w.mgr), ref: ask.ref, now: w.at(7200)) == nil)
    }

    // MARK: Items, decisions, retros

    @Test func itemReingestedOnNewEvent() throws {
        let w = try W()
        let item = try w.store.createWorkItem(companyId: w.company.id, by: .agent(w.eng1.id), draft: WorkItemDraft(
            type: .task, title: "Export the ledger", description: "CSV export of the ledger", acceptanceCriteria: "a file per month"),
            now: w.at(0))
        try w.run()
        let first = try #require(try w.doc(.item, item.id))
        #expect(first["ref"] == MemoryRefs.canonicalItemRef(item.key))
        #expect(first["title"] == "\(item.key) Export the ledger")
        #expect((first["body"] as String) == "CSV export of the ledger\n\nAcceptance criteria:\na file per month")
        #expect(first["accessKind"] == "company"); #expect(first["itemId"] == item.id)
        #expect(try w.search(w.agent(w.eng2), "pelican").isEmpty)

        _ = try w.store.commentWorkItem(id: item.id, by: .agent(w.eng2.id), text: "try the pelican approach", now: w.at(600))
        try w.run(at: 7200)
        #expect(try w.refs(w.agent(w.eng2), "pelican") == [MemoryRefs.canonicalItemRef(item.key)])
        let second = try #require(try w.doc(.item, item.id))
        #expect(second["id"] as Int64 == first["id"] as Int64, "the same doc, updated")
        #expect((second["body"] as String).hasSuffix("try the pelican approach"))
    }

    @Test func mechanicalDecisionIngested() throws {
        let w = try W()
        try w.store.recordMechanicalDecision(companyId: w.company.id, by: .agent(w.eng1.id), kind: .other, category: "process",
                                             title: "Use squash merges", summary: "cleaner history", now: w.at(0))
        try w.run()
        let docs = try w.docs(.decision)
        #expect(docs.count == 1)
        let d = try #require(docs.first)
        let id: String = d["sourceId"]
        #expect(d["ref"] == "decision:\(id)")
        #expect(d["title"] == "Recorded decision 2027-01-15")
        #expect(d["body"] == "Decision by @eng-1: Use squash merges")
        #expect(d["accessKind"] == "company"); #expect(d["provenance"] == "agent:\(w.eng1.id)")
        #expect(try w.refs(w.agent(w.eng2), "squash") == ["decision:\(id)"])
        // Other approval lines are not decisions; the cursor moved past them.
        try w.store.appendEvent(ActivityEvent(companyId: w.company.id, agentId: nil, turnId: nil, kind: .approval,
                                              text: "Approved: something else", createdAt: w.at(60)))
        try w.run(at: 7200)
        #expect(try w.docs(.decision).count == 1)
    }

    @Test func retroIngestedOnClose() throws {
        let w = try W()
        let sprint = Sprint(id: UUID().uuidString, companyId: w.company.id, number: 1, team: nil, goal: "ship", cadence: .sprint,
                            status: .active, milestoneItemId: nil, askId: nil, createdAt: w.at(0), startedAt: w.at(0), closedAt: nil,
                            summary: nil, leadId: w.mgr.id)
        try w.store.writer.write { db in try sprint.insert(db) }
        try w.run()
        #expect(try w.docs(.retro).isEmpty, "an open sprint has no retro")
        _ = try w.store.closeSprint(sprintId: sprint.id, by: .owner, summary: "The heron cache paid off", lessons: "", now: w.at(600))
        try w.run(at: 7200)
        let d = try #require(try w.doc(.retro, sprint.id))
        #expect(d["ref"] == "sprint:1"); #expect(d["title"] == "Sprint 1 retro"); #expect(d["accessKind"] == "company")
        #expect((d["body"] as String).contains("The heron cache paid off"))
        #expect(try w.refs(w.agent(w.eng2), "heron").contains("sprint:1"))
    }

    // MARK: Hand-offs

    @Test func handoffFileIngestedSafely() throws {
        let w = try W()
        let item = try w.store.createWorkItem(companyId: w.company.id, by: .owner, draft: WorkItemDraft(type: .task, title: "Hand me"), now: w.at(0))
        let h = try w.store.writeHandoff(itemId: item.id, by: .owner, draft: HandoffDraft(goal: "finish the albatross parser"), now: w.at(10))
        // A link planted in the hand-off directory, pointing outside it.
        let outside = try tempDir().appending(path: "secret.md")
        try Data("the albatross secret outside".utf8).write(to: outside)
        let link = w.handoffsDir(item.key).appending(path: "zz-link.md")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        _ = try w.insertHandoff(item: item, path: link, at: 20)

        try w.run()
        let docs = try w.docs(.handoff)
        #expect(docs.count == 1)
        let d = try #require(try w.doc(.handoff, h.id))
        let name = URL(fileURLWithPath: h.path).lastPathComponent
        #expect(d["ref"] == "handoff:\(item.key)/\(name)")
        #expect(d["title"] == "Hand-off \(item.key) from @owner 2027-01-15")
        #expect((d["body"] as String).contains("finish the albatross parser"))
        #expect(!(try dumpDatabase(w.store)).contains("albatross secret outside"))
        let line = "skipped hand-off \(link.path): not a regular single-link file inside .brahma/handoffs"
        #expect(try w.activity(line) == 1)
        // Re-reads (the overlap, a re-scan) skip it again without another line.
        try w.run(at: 3601)
        try MemoryIngest.resetCursors(store: w.store, companyId: w.company.id)
        try w.run(at: 3602)
        #expect(try w.activity(line) == 1)
        #expect(try w.docs(.handoff).count == 1)
    }

    @Test func handoffHardLinkSkipped() throws {
        let w = try W()
        let item = try w.store.createWorkItem(companyId: w.company.id, by: .owner, draft: WorkItemDraft(type: .task, title: "Hand me"), now: w.at(0))
        let h = try w.store.writeHandoff(itemId: item.id, by: .owner, draft: HandoffDraft(goal: "the kestrel plan"), now: w.at(10))
        let second = w.handoffsDir(item.key).appending(path: "zz-hard.md")
        try FileManager.default.linkItem(at: URL(fileURLWithPath: h.path), to: second)
        let extra = try w.insertHandoff(item: item, path: second, at: 20)
        try w.run()
        // Both names of a file with two links are refused: neither is indexed.
        #expect(try w.docs(.handoff).isEmpty)
        #expect(try w.activity("skipped hand-off \(extra.path): not a regular single-link file inside .brahma/handoffs") == 1)
        #expect(try w.activity("skipped hand-off \(h.path): not a regular single-link file inside .brahma/handoffs") == 1)
        #expect(try w.search(.owner, "kestrel").isEmpty)
    }

    @Test func taintedSessionHandoffIngestedTainted() throws {
        let w = try W()
        let item = try w.store.createWorkItem(companyId: w.company.id, by: .owner, draft: WorkItemDraft(
            type: .task, title: "Hand me", ownerId: w.eng1.id), now: w.at(0))
        // Turn 1 read outside content; turn 2 resumed the same session (no taint of its own) and wrote the hand-off.
        try w.turn(w.eng1, start: 100, taintedAt: 110, source: "WebFetch")
        try w.turn(w.eng1, start: 200)
        let tainted = try w.store.writeHandoff(itemId: item.id, by: .agent(w.eng1.id), draft: HandoffDraft(goal: "the ibis notes"),
                                               now: w.at(210))
        #expect(try w.store.taintAt(agentId: w.eng1.id, at: w.at(210)) == "WebFetch")
        #expect(try w.store.taintAt(agentId: w.eng1.id, at: w.at(105)) == nil, "before the taint")
        // Turn 3 started a fresh session: what it writes is clean again.
        try w.turn(w.eng1, start: 300, fresh: "tainted")
        let clean = try w.store.writeHandoff(itemId: item.id, by: .agent(w.eng1.id), draft: HandoffDraft(goal: "the egret notes"),
                                             now: w.at(310))
        #expect(try w.store.taintAt(agentId: w.eng1.id, at: w.at(310)) == nil)

        try w.run()
        let t = try #require(try w.doc(.handoff, tainted.id))
        #expect(t["tainted"] == true); #expect(t["taintReason"] == "written by a session that read WebFetch")
        let c = try #require(try w.doc(.handoff, clean.id))
        #expect(c["tainted"] == false); #expect(c["taintReason"] == nil as String?)
        // A tainted hit shows neither its title nor a snippet.
        let hit = try #require(try w.search(.owner, "ibis").first)
        #expect(hit.tainted); #expect(hit.snippet == nil); #expect(hit.title.hasSuffix("(untrusted)"))
    }

    // MARK: Cursors

    @Test func ingestIsIdempotent() throws {
        let w = try W()
        for i in 0..<5 {
            _ = try w.router.post(companyId: w.company.id, channel: "general", from: .owner, text: "note \(i) on the lynx", now: w.at(Double(i)))
        }
        _ = try w.store.createWorkItem(companyId: w.company.id, by: .owner, draft: WorkItemDraft(type: .task, title: "Lynx work"), now: w.at(10))
        try w.run()
        let before = try w.docs().map { "\($0["id"] as Int64)|\($0["updatedAt"] as String)" }
        #expect(before.count == 6)
        let cursors = try w.store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT source || '=' || position FROM memoryCursor WHERE companyId = ? ORDER BY source",
                                arguments: [w.company.id])
        }
        // Pair cursors are "<ISO-8601 ms>|<id>"; id cursors are integers.
        for c in cursors where c.hasPrefix("message=") || c.hasPrefix("item=") {
            #expect(c.range(of: #"=\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\|.+$"#, options: .regularExpression) != nil, "\(c)")
        }
        #expect(cursors.contains { $0.range(of: #"^itemEvent=\d+$"#, options: .regularExpression) != nil })
        // Again (inside the overlap), and after a full re-scan: nothing changes, nothing is duplicated.
        try w.run(at: 3700)
        try MemoryIngest.resetCursors(store: w.store, companyId: w.company.id)
        try w.run(at: 3800)
        #expect(try w.docs().map { "\($0["id"] as Int64)|\($0["updatedAt"] as String)" } == before)
        try w.store.writer.write { db in try db.execute(sql: "INSERT INTO memoryFts(memoryFts) VALUES('integrity-check')") }
    }

    @Test func cursorsSurviveVacuumRestore() async throws {
        let dir = try tempDir()
        let db = dir.appending(path: "brahma.db")
        var store = try Store(path: db.path)
        var w = try W(store: store)
        for i in 0..<50 {
            _ = try w.router.post(companyId: w.company.id, channel: "general", from: .owner, text: "old message \(i)", now: w.at(Double(i)))
        }
        try w.run()
        #expect(try w.docs(.message).count == 50)
        // A snapshot as the backups take it (VACUUM INTO renumbers a TEXT table's rowids), restored over the database.
        let snapshot = dir.appending(path: "snap.db")
        try w.vacuum(into: snapshot)
        try store.close()
        for suffix in ["", "-wal", "-shm"] { try? FileManager.default.removeItem(atPath: db.path + suffix) }
        try FileManager.default.moveItem(at: snapshot, to: db)
        store = try Store(path: db.path)
        let company = try #require(try store.company(id: w.company.id))
        w = W(reopened: store, from: w)

        // The engine's restore hook resets the company's cursors.
        let hooks = RestoreHooks()
        _ = Orchestrator(store: store, runner: FakeTurnRunner(), paths: w.paths, mcpExecutable: "/usr/local/bin/brahma",
                         restoreHooks: hooks)
        #expect(hooks.afterRestore.count == 1)
        for hook in hooks.afterRestore {
            try await hook(RestoreEvent(companyId: company.id, companyName: company.name, workspace: URL(fileURLWithPath: company.workspacePath),
                                        mainHead: nil, snapshotName: "snap.db"))
        }
        #expect(try w.cursorPositions().allSatisfy(\.isEmpty))

        var fresh: [Message] = []
        for i in 0..<3 {
            fresh.append(try w.router.post(companyId: w.company.id, channel: "general", from: .owner, text: "new ocelot \(i)",
                                           now: w.at(5000 + Double(i))))
        }
        try w.run(at: 6000)
        #expect(try w.docs(.message).count == 53)
        #expect(try w.ocelots() == fresh.map(\.id).sorted())
        // And without the reset: three more after a second snapshot cycle are all found from the kept cursor.
        for i in 3..<6 {
            fresh.append(try w.router.post(companyId: w.company.id, channel: "general", from: .owner, text: "new ocelot \(i)",
                                           now: w.at(9000 + Double(i))))
        }
        try w.run(at: 9100)
        #expect(try w.ocelots() == fresh.map(\.id).sorted())
        #expect(try w.docs(.message).count == 56)
    }

    @Test func cursorsResumeAfterStop() async throws {
        let world = try World()
        let company = try world.company("Acme")
        let eng = try world.hire(company, "eng-1", role: "engineer")
        func indexed(_ q: String) throws -> Int {
            try MemoryIndex(store: world.store).search(companyId: company.id, scope: .owner, query: q, now: world.clock.now).count
        }
        _ = try world.router.post(companyId: company.id, channel: "general", from: .agent(eng.id), text: "the first gecko", now: world.clock.now)
        await world.orchestrator.tick()
        #expect(try indexed("gecko") == 1)

        // The owner's stop holds ingest; the resume catches up from the kept cursor, however long the stop lasted.
        _ = try world.store.emergencyStop(note: nil, by: "owner", now: world.clock.now)
        world.clock.advance(7200)
        _ = try world.router.post(companyId: company.id, channel: "general", from: .owner, text: "the second gecko", now: world.clock.now)
        await world.orchestrator.tick()
        #expect(try indexed("gecko") == 1)
        world.clock.advance(7200)
        _ = try world.store.resumeAfterStop(now: world.clock.now)
        await world.orchestrator.tick()
        try await world.orchestrator.waitUntilIdle(timeout: .seconds(300))
        #expect(try indexed("gecko") == 2)
    }

    @Test func crossCompanyIngestIsolated() throws {
        let a = try W()
        let b = try W(store: a.store, name: "Beta")
        let ma = try a.router.post(companyId: a.company.id, channel: "general", from: .owner, text: "alpha lemur", now: a.at(0))
        let mb = try b.router.post(companyId: b.company.id, channel: "general", from: .owner, text: "beta lemur", now: b.at(0))
        try a.run()
        #expect(try a.docs().map { $0["sourceId"] as String } == [ma.id])
        #expect(try b.docs().isEmpty, "running A indexes nothing of B")
        let cursors = try a.store.writer.read { db in try String.fetchAll(db, sql: "SELECT DISTINCT companyId FROM memoryCursor") }
        #expect(cursors == [a.company.id])
        try b.run()
        #expect(try b.docs().map { $0["sourceId"] as String } == [mb.id])
        #expect(try a.refs(.owner, "lemur") == ["msg:\(ma.id)"])
        #expect(try b.refs(.owner, "lemur") == ["msg:\(mb.id)"])
        // An agent of A cannot search B.
        #expect(throws: WorkError.forbidden("not in your company")) {
            try b.index.search(companyId: b.company.id, scope: .agent(a.eng1.id), query: "lemur", now: b.at(7200))
        }
        // Resetting B's cursors leaves A's alone.
        try MemoryIngest.resetCursors(store: a.store, companyId: b.company.id)
        #expect(try a.store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT position FROM memoryCursor WHERE companyId = ?", arguments: [a.company.id])
        }.allSatisfy { !$0.isEmpty })
    }
}

extension MemoryIngestTests.W {
    /// The same company and agents on a reopened store.
    init(reopened store: Store, from w: MemoryIngestTests.W) {
        self.store = store; company = w.company; paths = w.paths; mgr = w.mgr; eng1 = w.eng1; eng2 = w.eng2
    }
}
