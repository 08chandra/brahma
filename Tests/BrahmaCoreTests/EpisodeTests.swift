import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Plan ML Task 2: engine-recorded episodes at turn end and item completion.
@Suite(.scratch, .serialized) struct EpisodeTests {
    /// Acme on the orchestrator: mgr-1 ← {eng-1, eng-2}. The owner's zone is UTC.
    private struct O {
        let world: World
        var store: Store { world.store }
        let company: Company
        let mgr: Agent, eng: Agent, eng2: Agent

        init() throws {
            world = try World()
            company = try world.company("Acme")
            try world.store.setOwnerTimeZone("UTC")
            mgr = try world.hire(company, "mgr-1", role: "manager")
            eng = try world.store.hire(companyId: company.id, name: "eng-1", role: "engineer", model: "sonnet", managerId: mgr.id)
            eng2 = try world.store.hire(companyId: company.id, name: "eng-2", role: "engineer", model: "sonnet", managerId: mgr.id)
        }

        func entries(_ a: Agent) throws -> [MemoryEntry] {
            try store.writer.read { db in
                try MemoryEntry.filter(Column("companyId") == company.id && Column("accessId") == a.id).order(Column("number")).fetchAll(db)
            }
        }

        func doc(_ e: MemoryEntry) throws -> Row? {
            try store.writer.read { db in
                try Row.fetchOne(db, sql: "SELECT * FROM memoryDoc WHERE companyId = ? AND source = 'memory' AND sourceId = ?",
                                 arguments: [company.id, e.id])
            }
        }

        func turn(_ a: Agent, _ script: FakeTurnRunner.Script) async throws {
            world.fake.script(a.name, script)
            try world.dm(company, a)
            try await world.cycle()
        }

        func search(_ reader: Reader, _ q: String) throws -> [MemoryHit] {
            try MemoryIndex(store: store).search(companyId: company.id, scope: reader, query: q, now: world.clock.now)
        }

        /// Clears a failure's backoff, so the next DM runs a turn at once.
        func makeReady(_ a: Agent) throws {
            try store.writer.write { db in
                try db.execute(sql: "UPDATE agent SET state = 'ready', blocker = NULL WHERE id = ?", arguments: [a.id])
            }
        }

        func sessionId(_ a: Agent) throws -> String { try world.agent(a).sessionId }

        /// A successful turn whose stream reads a web page first (the orchestrator's backup marks the taint).
        func webFetch(_ a: Agent, text: String) throws -> FakeTurnRunner.Script {
            let sid = try sessionId(a)
            return .init(events: [.initialized(sessionId: sid, model: "sonnet"),
                                  .toolCall(name: "WebFetch", input: ["url": .string("https://example.com")]),
                                  .result(TurnResult(isError: false, subtype: "success", text: text, costUSD: 0.01, apiErrorStatus: nil,
                                                     sessionId: sid))])
        }
    }

    @Test func workTurnRecordsEpisode() async throws {
        let o = try O()
        try await o.turn(o.eng, .init(text: "Implemented the ledger export"))
        let turn = try #require(try o.world.turns(o.eng).last)
        let entries = try o.entries(o.eng)
        #expect(entries.count == 1)
        let e = try #require(entries.first)
        #expect(e.kind == .episodic); #expect(e.type == .episode)
        #expect(e.accessKind == "agent"); #expect(e.accessId == o.eng.id)
        #expect(e.fact == "no item · \(turn.kind.rawValue): Implemented the ledger export")
        #expect(e.factHash == MemoryEntry.factHash(e.fact))
        #expect(e.authorId == "system"); #expect(e.provenance == "engine"); #expect(e.confidence == 1)
        #expect(e.turnId == turn.id); #expect(e.itemId == nil); #expect(!e.tainted); #expect(e.taintReason == nil)

        let d = try #require(try o.doc(e))
        #expect(d["ref"] == "mem:\(e.number)"); #expect(d["ref"] == e.ref)
        #expect(d["title"] == "Episode \(MemoryIngest.stamp(e.createdAt, zone: TimeZone(identifier: "UTC")!)) no item")
        #expect(d["body"] == e.fact); #expect(d["accessKind"] == "agent"); #expect(d["accessId"] == o.eng.id)
        #expect(d["provenance"] == "engine"); #expect(d["tainted"] == false)

        // A long summary is flattened and capped at 600 characters.
        let long = (0..<200).map { "word\($0)" }.joined(separator: "\n")
        try await o.turn(o.eng, .init(text: long))
        let second = try #require(try o.entries(o.eng).last)
        #expect(second.number == e.number + 1)
        #expect(second.fact.count == EpisodeRecorder.maxChars); #expect(second.fact.hasSuffix("…")); #expect(!second.fact.contains("\n"))
    }

    @Test func infraFailureRecordsNothing() async throws {
        let o = try O()
        try await o.turn(o.eng, .init(events: [.initialized(sessionId: try o.sessionId(o.eng), model: "sonnet")],
                                      error: FakeError(description: "getaddrinfo ENOTFOUND api.anthropic.com")))
        #expect(try o.world.turns(o.eng).last?.infra == true)
        #expect(try o.entries(o.eng).isEmpty)
        // Nor an ordinary failure, nor a success that said nothing (each after the cooldown and backoff have passed).
        o.world.clock.advance(3600); try o.makeReady(o.eng)
        try await o.turn(o.eng, .init(events: [], error: FakeError(description: "boom")))
        #expect(try o.world.turns(o.eng).count == 2)
        #expect(try o.world.turns(o.eng).last?.outcome == .failed); #expect(try o.world.turns(o.eng).last?.infra == false)
        o.world.clock.advance(3600); try o.makeReady(o.eng)
        try await o.turn(o.eng, .init(text: "  \n "))
        #expect(try o.world.turns(o.eng).count == 3)
        #expect(try o.world.turns(o.eng).last?.outcome == .succeeded)
        #expect(try o.entries(o.eng).isEmpty)
    }

    @Test func episodePrivateToAgentSummaryForManager() async throws {
        let o = try O()
        try await o.turn(o.eng, .init(text: "Tuned the flamingo cache"))
        let e = try #require(try o.entries(o.eng).first)

        let own = try o.search(.agent(o.eng.id), "flamingo")
        #expect(own.map(\.ref) == [e.ref]); #expect(own.first?.level == .full); #expect(own.first?.snippet != nil)
        #expect(try o.search(.owner, "flamingo").map(\.ref) == [e.ref])
        // The manager matches the engine-built title only, and sees no text.
        #expect(try o.search(.agent(o.mgr.id), "flamingo").isEmpty)
        let summary = try o.search(.agent(o.mgr.id), "Episode").filter { $0.ref == e.ref }
        #expect(summary.count == 1); #expect(summary.first?.level == .summary); #expect(summary.first?.snippet == nil)
        #expect(summary.first?.title.hasPrefix("Episode ") == true)
        let read = try MemoryIndex(store: o.store).document(companyId: o.company.id, scope: .agent(o.mgr.id), ref: e.ref, now: o.world.clock.now)
        #expect(read?.hit.level == .summary); #expect(read?.text.contains("flamingo") == false)
        // A peer sees nothing at all.
        #expect(try o.search(.agent(o.eng2.id), "Episode").filter { $0.ref == e.ref }.isEmpty)
        #expect(try o.search(.agent(o.eng2.id), "flamingo").isEmpty)
        #expect(try MemoryIndex(store: o.store).document(companyId: o.company.id, scope: .agent(o.eng2.id), ref: e.ref,
                                                         now: o.world.clock.now) == nil)
    }

    @Test func secondTurnOfTaintedSessionIsTainted() async throws {
        let o = try O()
        try await o.turn(o.eng, try o.webFetch(o.eng, text: "Read the vendor page"))
        #expect(try o.world.agent(o.eng).sessionTainted)
        try await o.turn(o.eng, .init(text: "Wrote the integration"))
        let turns = try o.world.turns(o.eng)
        #expect(turns.count == 2)
        let source = try #require(turns.first?.taintSource)
        #expect(turns.first?.taintedAt != nil); #expect(turns.last?.taintedAt == nil, "the resumed turn read nothing itself")
        let entries = try o.entries(o.eng)
        #expect(entries.count == 2)
        for e in entries {
            #expect(e.tainted); #expect(e.taintReason == "written by a session that read \(source)")
            #expect(try o.doc(e)?["tainted"] == true)
        }
        // Tainted: its hit carries neither title nor snippet.
        let hit = try #require(try o.search(.agent(o.eng.id), "integration").first)
        #expect(hit.tainted); #expect(hit.snippet == nil)
    }

    @Test func episodeRecordedBeforeFreshSessionClearsTaint() async throws {
        let o = try O()
        let (store, aid) = (o.store, o.eng.id)
        // What a refused high-risk call does mid-turn: the session is tainted and asks for a fresh one at the turn's end.
        try await o.turn(o.eng, .init(sideEffect: { _ in
            try store.markTainted(agentId: aid, source: "WebFetch")
            try store.requestFreshSession(agentId: aid)
        }, text: "Summarized the vendor page"))
        let after = try o.world.agent(o.eng)
        #expect(!after.sessionTainted); #expect(!after.freshSessionRequested)
        let first = try #require(try o.entries(o.eng).first)
        #expect(first.tainted); #expect(first.taintReason == "written by a session that read WebFetch")
        // The fresh session's turn is clean.
        try await o.turn(o.eng, .init(text: "Started over cleanly"))
        #expect(try o.world.turns(o.eng).last?.freshSessionReason == "tainted")
        let second = try #require(try o.entries(o.eng).last)
        #expect(second.number == first.number + 1); #expect(!second.tainted)
    }

    @Test func itemCompletionRecordedWithoutMergedCommit() throws {
        let store = try Store.inMemory()
        let company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        try store.setOwnerTimeZone("UTC")
        let eng = try store.hire(companyId: company.id, name: "eng-1", role: "engineer", model: "sonnet")
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        func item(_ title: String, type: WorkItemType = .task, merged: String? = nil, tainted: Bool = false) throws -> WorkItem {
            let i = try store.createWorkItem(companyId: company.id, by: .owner, draft: WorkItemDraft(type: type, title: title, ownerId: eng.id), now: t)
            try store.writer.write { db in
                try db.execute(sql: "UPDATE workItem SET mergedCommit = ?, taintedOrigin = ? WHERE id = ?", arguments: [merged, tainted, i.id])
                try store.engineSetStatus(db: db, itemId: i.id, to: .done, now: t.addingTimeInterval(60))
            }
            return i
        }
        func entries() throws -> [MemoryEntry] {
            try store.writer.read { db in try MemoryEntry.filter(Column("companyId") == company.id).order(Column("number")).fetchAll(db) }
        }

        let plain = try item("Export the ledger")
        var all = try entries()
        #expect(all.count == 1)
        let e = try #require(all.first)
        #expect(e.fact == "Finished \(plain.key) Export the ledger")
        #expect(e.kind == .episodic); #expect(e.type == .episode); #expect(e.accessKind == "agent"); #expect(e.accessId == eng.id)
        #expect(e.itemId == plain.id); #expect(e.turnId == nil); #expect(e.authorId == "system"); #expect(!e.tainted)
        let doc = try store.writer.read { db in
            try Row.fetchOne(db, sql: "SELECT * FROM memoryDoc WHERE companyId = ? AND source = 'memory' AND sourceId = ?",
                             arguments: [company.id, e.id])
        }
        #expect(doc?["title"] == "Episode 2027-01-15 08:01 \(plain.key)"); #expect(doc?["ref"] == e.ref)

        let merged = try item(String(repeating: "Long title ", count: 12), merged: "abcdef1234567890")
        all = try entries()
        #expect(all.count == 2)
        let m = try #require(all.last)
        #expect(m.fact.hasPrefix("Finished \(merged.key) Long title")); #expect(m.fact.hasSuffix("… (merged abcdef1)"))
        #expect(m.fact.count == "Finished \(merged.key) ".count + 80 + " (merged abcdef1)".count)

        // A container did no work of its own; an item a tainted session worked on keeps the mark.
        _ = try item("The epic", type: .epic)
        #expect(try entries().count == 2)
        _ = try item("Tainted work", tainted: true)
        let tainted = try #require(try entries().last)
        #expect(tainted.tainted); #expect(tainted.taintReason == "written by a session that read outside content")
    }
}
