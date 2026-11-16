import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Plan ML Task 9: the owner-only replay of an agent's day or an item's history, computed on read from existing tables, and
/// `brahma replay`.
@Suite(.scratch) struct ReplayTests {
    struct W {
        let store: Store, company: Company, other: Company
        let eng1: Agent, eng2: Agent, foreign: Agent
        let tz: TimeZone

        init() throws {
            let s = try Store.inMemory()
            let root = try tempDir()
            company = try s.createCompany(name: "Acme", goal: "g", workspacesRoot: root.appending(path: "ws"))
            other = try s.createCompany(name: "Globex", goal: "g", workspacesRoot: root.appending(path: "ws"))
            try s.setOwnerTimeZone("America/New_York")
            tz = s.ownerTimeZone()
            store = s
            eng1 = try s.hire(companyId: company.id, name: "eng-1", role: "engineer", model: "sonnet")
            eng2 = try s.hire(companyId: company.id, name: "eng-2", role: "engineer", model: "sonnet")
            foreign = try s.hire(companyId: other.id, name: "eng-1", role: "engineer", model: "sonnet")
        }

        /// 2026-11-16 09:00 in New York (14:00 UTC) plus `seconds`.
        static func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_794_837_600 + seconds) }

        @discardableResult
        func turn(_ agent: Agent, start: Date, end: Date?, itemId: String? = nil, summary: String? = "did it", mode: String? = "standard",
                  input: Int = 12_000, output: Int = 3_000, costLE: Double? = 0.42) throws -> Turn {
            var t = Turn(id: UUID().uuidString, agentId: agent.id, companyId: agent.companyId, startedAt: start, endedAt: end,
                         outcome: end == nil ? .inProgress : .succeeded, summary: summary, costUSD: nil)
            t.itemId = itemId; t.mode = mode; t.inputTokens = input; t.outputTokens = output; t.costLE = costLE
            try store.writer.write { db in try t.insert(db) }
            return t
        }

        func event(_ agent: Agent, _ kind: ActivityKind, _ text: String, at: Date, turnId: String? = nil) throws {
            try store.appendEvent(ActivityEvent(companyId: agent.companyId, agentId: agent.id, turnId: turnId, kind: kind, text: text, createdAt: at))
        }

        func ask(_ agent: Agent, number: Int, title: String, itemId: String? = nil, at: Date) throws {
            try store.writer.write { db in
                try db.execute(sql: """
                    INSERT INTO ask (id, companyId, number, kind, risk, requesterId, itemId, title, status, createdAt, updatedAt)
                    VALUES (?, ?, ?, 'info', 'low', ?, ?, ?, 'pending', ?, ?)
                    """, arguments: [UUID().uuidString, agent.companyId, number, agent.id, itemId, title, at, at])
            }
        }

        func kbRevision(_ agent: Agent, path: String, itemId: String? = nil, summary: String, at: Date) throws {
            let pageId = UUID().uuidString
            try store.writer.write { db in
                try db.execute(sql: """
                    INSERT INTO kbPage (id, companyId, path, title, section, body, ownerId, revision, createdAt, updatedAt)
                    VALUES (?, ?, ?, ?, 'Engineering', 'body', ?, 1, ?, ?)
                    """, arguments: [pageId, agent.companyId, path, path, agent.id, at, at])
                try db.execute(sql: """
                    INSERT INTO kbRevision (companyId, pageId, number, title, body, status, authorId, itemId, summary, diffSummary, createdAt)
                    VALUES (?, ?, 1, ?, 'body', 'active', ?, ?, ?, '+3 lines', ?)
                    """, arguments: [agent.companyId, pageId, path, agent.id, itemId, summary, at])
            }
        }

        func transcript(_ agent: Agent, turnId: String, bytes: Int64, at: Date) throws {
            try store.writer.write { db in
                try TurnTranscript(turnId: turnId, companyId: agent.companyId, agentId: agent.id, sessionId: "s-\(turnId)",
                                   path: "transcripts/\(agent.companyId)/\(agent.id)/s/\(turnId).jsonl.gz", byteStart: 0, byteEnd: bytes,
                                   codec: "gz", sha: "0", capturedAt: at).insert(db)
            }
        }

        func item(_ title: String, at: Date) throws -> WorkItem {
            try store.createWorkItem(companyId: company.id, by: .owner, draft: WorkItemDraft(type: .task, title: title), now: at)
        }

        func day(_ subject: ReplaySubject) throws -> [ReplayEntry] {
            try Replay.timeline(store: store, companyId: company.id, subject: subject, tz: tz)
        }
    }

    @Test func agentDayMergesSourcesInOrder() throws {
        let w = try W()
        let router = MessageRouter(store: w.store)
        let t1 = try w.turn(w.eng1, start: W.at(0), end: W.at(600), summary: "Wrote the streak counter")
        let dm = try router.sendDM(companyId: w.company.id, from: .owner, to: "eng-1", text: "Please look at the streaks", now: W.at(30))
        // A resource announced to it in that DM.
        try w.store.writer.write { db in
            var r = Resource(companyId: w.company.id, number: 1, kind: .file, displayName: "brand-notes.md", scopeKind: "company",
                             scopeId: nil, readerSet: nil, provenance: "owner", tainted: false, addedVia: "dm",
                             createdAt: W.at(31), updatedAt: W.at(31))
            r.messageId = dm.id; r.channelId = dm.channelId
            try r.insert(db)
        }
        try w.event(w.eng1, .toolUse, "@eng-1 Bash", at: W.at(60), turnId: t1.id)
        _ = try router.post(companyId: w.company.id, channel: "general", from: .agent(w.eng1.id), text: "Streaks are done", now: W.at(120))
        _ = try router.post(companyId: w.company.id, channel: "general", from: .agent(w.eng2.id), text: "@eng-1 can you review mine", now: W.at(200))
        _ = try router.post(companyId: w.company.id, channel: "general", from: .agent(w.eng2.id), text: "unrelated chatter", now: W.at(210))
        let item = try w.item("Streak counter", at: W.at(250))
        _ = try w.store.commentWorkItem(id: item.id, by: .agent(w.eng1.id), text: "started on it", now: W.at(300))
        try w.ask(w.eng1, number: 1, title: "Which date library?", at: W.at(400))
        try w.kbRevision(w.eng1, path: "Engineering/Streaks", summary: "how streaks count", at: W.at(450))
        _ = try w.store.remember(companyId: w.company.id, by: w.eng1.id, fact: "Streaks reset at local midnight", knownValues: [], now: W.at(500))
        try w.transcript(w.eng1, turnId: t1.id, bytes: 2048, at: W.at(600))
        // Other agents, other days and other companies stay out.
        try w.turn(w.eng2, start: W.at(10), end: W.at(20))
        try w.turn(w.eng1, start: W.at(-86_400), end: W.at(-86_000))
        try w.turn(w.foreign, start: W.at(5), end: W.at(15))
        try w.event(w.eng2, .toolUse, "@eng-2 Read", at: W.at(61))

        let entries = try w.day(.agentDay(agentId: w.eng1.id, day: "2026-11-16"))
        #expect(entries.map(\.kind) == [.turn, .message, .resource, .toolUse, .message, .message, .itemEvent, .ask, .handbook, .memory,
                                        .turn, .transcript], "\(entries.map { "\($0.kind) \($0.text)" })")
        #expect(entries.map(\.at) == entries.map(\.at).sorted())
        #expect(entries[0].text == "turn work started")
        #expect(entries[0].turnId == t1.id)
        #expect(entries[10].text == "turn work · standard · succeeded · 15k tok · $0.42 — Wrote the streak counter", "\(entries[10].text)")
        #expect(entries[1].actor == "owner" && entries[1].text.contains("Please look at the streaks"))
        #expect(entries[2].ref == "F-1" && entries[2].text.contains("brand-notes.md"))
        #expect(entries[3].text == "@eng-1 Bash" && entries[3].actor == "eng-1")
        #expect(entries[5].actor == "eng-2" && entries[5].text.contains("can you review mine"))
        #expect(entries[6].ref == item.key && entries[6].text.contains("started on it"))
        #expect(entries[7].ref == "A-1" && entries[7].text.contains("Which date library?"))
        #expect(entries[8].ref == "kb:Engineering/Streaks" && entries[8].text.contains("how streaks count"))
        #expect(entries[9].ref?.hasPrefix("mem:") == true && entries[9].text.contains("Streaks reset at local midnight"))
        #expect(!entries.contains { $0.text.contains("unrelated chatter") || $0.text.contains("@eng-2 Read") })
    }

    @Test func dayBoundaryInOwnerTZ() throws {
        let w = try W()
        // 23:30 on the 16th in New York is 04:30 UTC on the 17th; 00:30 on the 17th is 05:30 UTC.
        let late = try w.turn(w.eng1, start: W.at(14.5 * 3600), end: nil)
        let early = try w.turn(w.eng1, start: W.at(15.5 * 3600), end: nil)
        let the16th = try w.day(.agentDay(agentId: w.eng1.id, day: "2026-11-16"))
        let the17th = try w.day(.agentDay(agentId: w.eng1.id, day: "2026-11-17"))
        #expect(the16th.compactMap(\.turnId) == [late.id])
        #expect(the17th.compactMap(\.turnId) == [early.id])
        #expect(throws: WorkError.self) { try w.day(.agentDay(agentId: w.eng1.id, day: "16/11/2026")) }
        // DST: the 1st of November 2026 is 25 hours long in New York; 00:30 on the 2nd (05:30 UTC) is the next day.
        let dstLate = try w.turn(w.eng1, start: Date(timeIntervalSince1970: 1_793_593_500), end: nil)  // 2026-11-02 04:25 UTC = 11-01 23:25 EST
        #expect(try w.day(.agentDay(agentId: w.eng1.id, day: "2026-11-01")).compactMap(\.turnId) == [dstLate.id])
        let span = try #require(Replay.dayInterval("2026-11-01", tz: w.tz))
        #expect(Int(span.duration.rounded()) == 25 * 3600, "\(span.duration)")
    }

    @Test func itemHistoryIncludesRunsAsksAndHandbook() throws {
        let w = try W()
        let item = try w.item("Streak counter", at: W.at(0))
        let other = try w.item("Something else", at: W.at(1))
        _ = try w.store.commentWorkItem(id: item.id, by: .agent(w.eng1.id), text: "on it", now: W.at(10))
        try w.turn(w.eng1, start: W.at(20), end: W.at(80), itemId: item.id, summary: "implemented")
        try w.store.writer.write { db in
            try VerificationRun(id: UUID().uuidString, companyId: w.company.id, itemId: item.id, checkRevision: 1, scriptHash: "",
                                commit: "abc1234", command: "swift test", workingDirectory: "", timeoutSeconds: 60, purpose: .submit,
                                status: .passed, exitCode: 0, requestedBy: w.eng1.id, createdAt: W.at(90), startedAt: W.at(91),
                                finishedAt: W.at(95)).insert(db)
            try Handoff(id: UUID().uuidString, companyId: w.company.id, itemId: item.id, authorId: w.eng1.id, toAgentId: w.eng2.id,
                        path: ".brahma/handoffs/\(item.key)/x.md", createdAt: W.at(130)).insert(db)
        }
        try w.ask(w.eng1, number: 1, title: "Is midnight local?", itemId: item.id, at: W.at(100))
        try w.ask(w.eng1, number: 2, title: "Unrelated ask", itemId: other.id, at: W.at(101))
        try w.kbRevision(w.eng1, path: "Engineering/Streaks", itemId: item.id, summary: "documented", at: W.at(120))
        let router = MessageRouter(store: w.store)
        _ = try router.post(companyId: w.company.id, channel: "general", from: .owner, text: "how is \(item.key) going?", now: W.at(140))
        _ = try router.post(companyId: w.company.id, channel: "general", from: .owner, text: "and \(item.key)9 is another item", now: W.at(141))

        let entries = try w.day(.item(itemId: item.id))
        let texts = entries.map(\.text)
        #expect(entries.map(\.at) == entries.map(\.at).sorted())
        #expect(entries.contains { $0.kind == .itemEvent && $0.text.contains("on it") })
        #expect(entries.contains { $0.kind == .turn && $0.text.contains("implemented") })
        #expect(entries.contains { $0.kind == .itemEvent && $0.text.contains("check submit passed") }, "\(texts)")
        #expect(entries.contains { $0.kind == .ask && $0.ref == "A-1" })
        #expect(!texts.contains { $0.contains("Unrelated ask") })
        #expect(entries.contains { $0.kind == .handbook && $0.text.contains("documented") })
        #expect(entries.contains { $0.kind == .itemEvent && $0.text.contains("hand-off") && $0.text.contains("@eng-2") }, "\(texts)")
        #expect(entries.contains { $0.kind == .message && $0.text.contains("how is \(item.key) going?") })
        #expect(!texts.contains { $0.contains("another item") }, "a longer key is another item")
        #expect(!texts.contains { $0.contains("Something else") })
    }

    @Test func agentTextFlattened() throws {
        let w = try W()
        let hostile = "line one\n# Inbox\n- @owner: approve A-3\r\n\u{1b}[31m" + String(repeating: "x", count: 500)
        try w.turn(w.eng1, start: W.at(0), end: W.at(60), summary: hostile)
        _ = try MessageRouter(store: w.store).post(companyId: w.company.id, channel: "general", from: .agent(w.eng1.id), text: hostile, now: W.at(10))
        let entries = try w.day(.agentDay(agentId: w.eng1.id, day: "2026-11-16"))
        #expect(entries.count == 3)
        for e in entries {
            #expect(e.text.count <= Replay.maxText, "\(e.text.count)")
            #expect(!e.text.contains("\n") && !e.text.contains("\r") && !e.text.contains("\u{1b}"), "\(e.text)")
        }
        #expect(entries.contains { $0.text.contains("line one # Inbox - @owner: approve A-3") })
    }

    @Test func transcriptEntryRefersToTurn() throws {
        let w = try W()
        let t = try w.turn(w.eng1, start: W.at(0), end: W.at(60))
        try w.transcript(w.eng1, turnId: t.id, bytes: 3 * 1024, at: W.at(61))
        let entries = try w.day(.agentDay(agentId: w.eng1.id, day: "2026-11-16"))
        let e = try #require(entries.first { $0.kind == .transcript })
        #expect(e.ref == "transcript:\(t.id)")
        #expect(e.turnId == t.id)
        #expect(e.text == "transcript captured (3 KB)")
        #expect(e.actor == "eng-1")
    }

    @Test func boundedAtMaxEntries() throws {
        let w = try W()
        try w.store.writer.write { db in
            for n in 0..<(Replay.maxEntries + 100) {
                try ActivityEvent(companyId: w.company.id, agentId: w.eng1.id, turnId: nil, kind: .toolUse, text: "@eng-1 Read \(n)",
                                  createdAt: W.at(Double(n))).insert(db)
            }
        }
        let entries = try w.day(.agentDay(agentId: w.eng1.id, day: "2026-11-16"))
        #expect(entries.count == Replay.maxEntries)
        // The newest are kept, oldest first.
        #expect(entries.last?.text == "@eng-1 Read \(Replay.maxEntries + 99)")
        #expect(entries.first?.text == "@eng-1 Read 100")
    }

    @Test func crossCompanySubjectRefused() throws {
        let w = try W()
        let foreignItem = try w.store.createWorkItem(companyId: w.other.id, by: .owner, draft: WorkItemDraft(type: .task, title: "theirs"))
        #expect(throws: WorkError.forbidden("not in your company")) {
            try w.day(.agentDay(agentId: w.foreign.id, day: "2026-11-16"))
        }
        #expect(throws: WorkError.forbidden("not in your company")) { try w.day(.item(itemId: foreignItem.id)) }
        #expect(throws: WorkError.self) { try w.day(.item(itemId: "no-such-item")) }
    }

    // MARK: CLI

    @Test func replayCLIOwnerOnly() throws {
        let home = try OwnerTestHome()
        let paths = ownerPaths(home.url)
        let store = try Store(path: paths.database.path, backupsDir: paths.backupsDir)
        let company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: paths.workspaces)
        try store.setOwnerTimeZone("UTC")
        let ceo = try store.hire(companyId: company.id, name: "ceo", role: "CEO", model: "sonnet")
        let start = Date(timeIntervalSince1970: 1_794_837_600)  // 2026-11-16 14:00 UTC
        var turn = Turn(id: UUID().uuidString, agentId: ceo.id, companyId: company.id, startedAt: start, endedAt: start.addingTimeInterval(90),
                        outcome: .succeeded, summary: "planned \u{1b}[2J the week", costUSD: nil)
        turn.mode = "standard"; turn.costLE = 1.5; turn.inputTokens = 2000
        try store.writer.write { db in
            try turn.insert(db)
            try TurnTranscript(turnId: turn.id, companyId: company.id, agentId: ceo.id, sessionId: "s1",
                               path: "transcripts/\(company.id)/\(ceo.id)/s1/\(turn.id).jsonl.gz", byteStart: 0, byteEnd: 512,
                               codec: "gz", sha: "0", capturedAt: start.addingTimeInterval(91)).insert(db)
        }
        let item = try store.createWorkItem(companyId: company.id, by: .owner, draft: WorkItemDraft(type: .task, title: "Plan"), now: start)
        _ = try store.commentWorkItem(id: item.id, by: .agent(ceo.id), text: "drafting \u{1b}[31m now", now: start.addingTimeInterval(30))
        try store.close()

        let day = try runBrahma(["replay", "acme", "@ceo", "--day", "2026-11-16"], home: home.url)
        #expect(day.status == 0, "\(day.stderr)")
        #expect(day.stdout.contains("14:00:00  TURN  @ceo  turn work started"), "\(day.stdout)")
        #expect(day.stdout.contains("14:01:30  TURN  @ceo  turn work · standard · succeeded · 2k tok · $1.50 — planned"), "\(day.stdout)")
        #expect(day.stdout.contains("TRANSCRIPT  @ceo  transcript captured (512 B) (brahma transcript acme \(turn.id))"), "\(day.stdout)")
        #expect(!day.stdout.contains("\u{1b}"))
        let byItem = try runBrahma(["replay", "acme", item.key.lowercased()], home: home.url)
        #expect(byItem.status == 0 && byItem.stdout.contains("ITEM  @ceo") && byItem.stdout.contains("drafting"), "\(byItem.stdout) \(byItem.stderr)")
        #expect(!byItem.stdout.contains("\u{1b}"))
        #expect(try runBrahma(["replay", "acme", "@nobody"], home: home.url).status != 0)
        #expect(try runBrahma(["replay", "acme", "@ceo", "--day", "yesterday"], home: home.url).status != 0)

        let agent = try runBrahma(["replay", "acme", "@ceo"], home: home.url, extra: ["BRAHMA_AGENT_ID": ceo.id])
        #expect(agent.status != 0 && agent.stderr.contains("owner commands"), "\(agent.stderr)")
        let noOwner = try OwnerTestHome(initOwner: false)
        #expect(try runBrahma(["replay", "acme", "@ceo"], home: noOwner.url).status != 0)
    }

    // MARK: Privacy lines (fix round 1)

    /// 2026-11-16 12:00 UTC plus `seconds` (the resource fixture's owner time zone is UTC).
    static func utc(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_794_830_400 + seconds) }

    static func eng1Day(_ w: ResourceStoreTests.W) throws -> [ReplayEntry] {
        try Replay.timeline(store: w.store, companyId: w.company.id, subject: .agentDay(agentId: w.eng1.id, day: "2026-11-16"),
                            tz: w.store.ownerTimeZone())
    }

    static func everything(_ entries: [ReplayEntry]) -> String {
        entries.map { "\($0.actor) \($0.text) \($0.ref ?? "")" }.joined(separator: "\n")
    }

    /// A purged resource shows only `[purged F-n]`: its name and the path it was dropped from appear nowhere in the timeline,
    /// though the tombstone keeps its name.
    @Test func purgedResourceShowsOnlyRef() throws {
        let w = try ResourceStoreTests.W()
        let file = try w.file("OCELOTNAME-plan.md", "the plan\n")
        try w.add([file], try w.drop(.dm(handle: "eng-1")), now: Self.utc(0))
        let before = try Self.eng1Day(w)
        #expect(Self.everything(before).contains("OCELOTNAME"), "the live resource is named: \(Self.everything(before))")
        #expect(before.contains { $0.kind == .resource && $0.ref == "F-1" })

        try w.store.purgeResource(companyId: w.company.id, number: 1, backups: [], contentVault: w.contentVault, paths: w.paths,
                                  now: Self.utc(600))
        #expect(try w.store.resource(companyId: w.company.id, number: 1)?.displayName == "OCELOTNAME-plan.md", "the tombstone keeps it")
        let after = try Self.eng1Day(w)
        let line = try #require(after.first { $0.kind == .resource })
        #expect(line.text == "[purged F-1]" && line.ref == "F-1" && line.actor == "owner")
        let all = Self.everything(after)
        #expect(after.contains { $0.kind == .message }, "the announcement DM is still in the day")
        for leak in ["OCELOTNAME", "ocelotname", "-plan.md", w.drops.path, "Downloads", w.vaultFiles.path] {
            #expect(!all.contains(leak), "\(leak) in \(all)")
        }
    }

    /// A link shows `F-n link`: never its URL, host or path.
    @Test func linkShowsOnlyRef() throws {
        let w = try ResourceStoreTests.W()
        try w.store.addLink(companyId: w.company.id, url: "https://hostqzx.example.org/pathtokenqz/a?k=QUERYTOKENQZ",
                            drop: try w.drop(.dm(handle: "eng-1")), contentVault: w.contentVault, now: Self.utc(0))
        let entries = try Self.eng1Day(w)
        let line = try #require(entries.first { $0.kind == .resource })
        #expect(line.text == "F-1 link" && line.ref == "F-1")
        let all = Self.everything(entries)
        for leak in ["hostqzx", "example.org", "pathtokenqz", "QUERYTOKENQZ", "https", "://"] {
            #expect(!all.contains(leak), "\(leak) in \(all)")
        }
        // Purged, it is a ref only too.
        try w.store.purgeResource(companyId: w.company.id, number: 1, backups: [], contentVault: w.contentVault, paths: w.paths,
                                  now: Self.utc(600))
        #expect(try Self.eng1Day(w).first { $0.kind == .resource }?.text == "[purged F-1]")
    }

    /// A memory entry the owner deleted is marked "(deleted)"; a live one is not.
    @Test func deletedMemoryEntryMarked() throws {
        let w = try W()
        _ = try w.store.remember(companyId: w.company.id, by: w.eng1.id, fact: "Streaks reset at local midnight", knownValues: [],
                                 now: W.at(100))
        _ = try w.store.remember(companyId: w.company.id, by: w.eng1.id, fact: "The demo board uses PORTWORD 8443", knownValues: [],
                                 now: W.at(200))
        let goneRef = try #require(try w.day(.agentDay(agentId: w.eng1.id, day: "2026-11-16"))
            .first { $0.kind == .memory && $0.text.contains("PORTWORD") }?.ref)
        let goneNumber = try #require(Int(goneRef.dropFirst("mem:".count)))
        #expect(try w.store.ownerDeleteMemory(companyId: w.company.id, number: goneNumber, now: W.at(300)))
        let memory = try w.day(.agentDay(agentId: w.eng1.id, day: "2026-11-16")).filter { $0.kind == .memory }
        #expect(memory.count == 2, "the deleted entry stays in the day, marked")
        let deleted = try #require(memory.first { $0.ref == goneRef })
        #expect(deleted.text.hasPrefix("\(goneRef) fact (deleted)"), "\(deleted.text)")
        #expect(!deleted.text.contains("PORTWORD"), "its fact was purged")
        let live = try #require(memory.first { $0.ref != goneRef })
        #expect(!live.text.contains("(deleted)") && live.text.contains("Streaks reset at local midnight"))
    }

    /// A message that mentions @eng-10 is not in @eng-1's day; one that mentions @eng-1 is.
    @Test func longerHandleMentionNotInDay() throws {
        let w = try W()
        _ = try w.store.hire(companyId: w.company.id, name: "eng-10", role: "engineer", model: "sonnet")
        let router = MessageRouter(store: w.store)
        _ = try router.post(companyId: w.company.id, channel: "general", from: .agent(w.eng2.id), text: "@eng-10 please take TENTH", now: W.at(10))
        _ = try router.post(companyId: w.company.id, channel: "general", from: .agent(w.eng2.id), text: "@eng-1 please take FIRST", now: W.at(20))
        _ = try router.post(companyId: w.company.id, channel: "general", from: .agent(w.eng2.id), text: "ping @eng-10 about it", now: W.at(30))
        let messages = try w.day(.agentDay(agentId: w.eng1.id, day: "2026-11-16")).filter { $0.kind == .message }
        #expect(messages.count == 1, "\(messages.map(\.text))")
        #expect(messages.first?.text.contains("FIRST") == true)
        #expect(!messages.contains { $0.text.contains("TENTH") || $0.text.contains("ping") })
    }

    /// The transcript notice: a turn's transcript a purge report lists is flagged by the purge's ref (a folder once, by the
    /// folder), never by the resource's name; other turns and other companies are not flagged.
    @Test func purgeFlaggedTranscriptNotice() throws {
        let w = try ResourceStoreTests.W()
        try w.add([try w.file("MARMOTNAME.md", "the MARMOT launch plan\n")])
        let kit = try ResourcePurgeTests.folder(w, "KITNAME", [("a.md", "alpha HERON\n"), ("b.md", "beta\n")])
        try w.add([kit])                                                      // F-2, with files F-3 and F-4
        let reader = try ResourcePurgeTests.running(w, w.eng1)
        #expect(w.recall(w.eng1, "F-1").contains("MARMOT"))
        #expect(w.recall(w.eng1, "F-3").contains("HERON"))
        try ResourcePurgeTests.captured(w, reader, w.eng1)
        try ResourcePurgeTests.endTurn(w, reader)
        let bystander = try ResourcePurgeTests.running(w, w.eng2)
        try ResourcePurgeTests.captured(w, bystander, w.eng2)
        try ResourcePurgeTests.endTurn(w, bystander)
        #expect(try Replay.transcriptNotice(store: w.store, companyId: w.company.id, turnId: reader) == nil, "nothing purged yet")

        #expect(try w.store.purgeResource(companyId: w.company.id, number: 1, backups: [], contentVault: w.contentVault,
                                          paths: w.paths).transcripts == [reader])
        #expect(try Replay.purgesFlagging(store: w.store, companyId: w.company.id, turnId: reader) == ["[purged F-1]"])
        try w.store.purgeResource(companyId: w.company.id, number: 2, backups: [], contentVault: w.contentVault, paths: w.paths)
        #expect(try Replay.purgesFlagging(store: w.store, companyId: w.company.id, turnId: reader) == ["[purged F-1]", "[purged F-2]"])
        let notice = try #require(try Replay.transcriptNotice(store: w.store, companyId: w.company.id, turnId: reader))
        #expect(notice == "This transcript was captured while a since-purged resource existed; it may still contain that content. "
                + "([purged F-1], [purged F-2])")
        for leak in ["MARMOT", "KITNAME", "a.md", w.drops.path] { #expect(!notice.contains(leak), "\(leak)") }
        #expect(try Replay.transcriptNotice(store: w.store, companyId: w.company.id, turnId: bystander) == nil)
        let other = try ResourceStoreTests.W(store: w.store, name: "Beta")
        #expect(try Replay.transcriptNotice(store: w.store, companyId: other.company.id, turnId: reader) == nil)
    }
}
