import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Plan C Task C4a fix round 4 (Ruling 57, R4-1 and R4-2): company memory is matched, ranked and cut into snippets only on
/// its vault-blanked shadow, for global search and for the agent-facing memory tools (`search_memory`, `recall(query:)`,
/// `search_kb`). A stored value's own tokens answer exactly like random text, and a value stored after a doc was indexed
/// re-blanks it.
@Suite(.scratch) struct MemoryShadowTests {
    /// The value under test: ten characters (redacted, `Redactor.minLength` is 8) whose middle piece is a 4-digit word.
    static let value = "kx-4821-vq"
    static let control = "kx-7356-vq"

    /// Twelve short messages hold the value; three longer ones hold "4821" as a visible word, three "7356". Indexed before
    /// the value is stored.
    static func world() throws -> SearchFixture {
        let w = try SearchFixture()
        let router = MessageRouter(store: w.store)
        for n in 0..<12 { _ = try router.post(companyId: w.c.id, channel: "general", from: .owner, text: "\(value) n\(n)") }
        for code in ["4821", "7356"] {
            for n in 0..<3 {
                _ = try router.post(companyId: w.c.id, channel: "general", from: .owner,
                                    text: "locker code \(code) for the review room and the long hallway door m\(n)")
            }
        }
        try w.ingest()
        return w
    }

    static func store(_ w: SearchFixture, _ value: String, name: String = "PIN_KEY", vault: MemoryVault) throws -> [(name: String, value: String)] {
        try w.store.setSecret(companyId: w.c.id, name: name, value: value, isTest: false, vault: vault)
        return try w.store.knownSecretValues(companyId: w.c.id, vault: vault)
    }

    /// R4-1: ten and more docs holding the value never crowd out a visible hit, and bm25 never counts them: querying the
    /// value's 4-digit word, or the value itself, answers exactly like a random 4-digit number (same hits, order, scores,
    /// totals), for the owner and an agent.
    @Test func exactSecretAnswersLikeARandomNumber() async throws {
        let w = try Self.world()
        let known = try Self.store(w, Self.value, vault: MemoryVault())
        for reader in [Reader.owner, .agent(w.fx.qa2.id)] {
            for (q, r) in [("4821", "7356"), (Self.value, Self.control), ("4821 locker", "7356 locker")] {
                let a = try await w.resolve(q, as: reader, knownValues: known)
                let b = try await w.resolve(r, as: reader, knownValues: known)
                #expect(Self.normalized(a) == Self.normalized(b), "\(reader) \(q): \(Self.normalized(a)) vs \(Self.normalized(b))")
                #expect(a.groupTotals == b.groupTotals, "\(reader) \(q): \(a.groupTotals) vs \(b.groupTotals)")
            }
            let hits = try await w.resolve("4821", as: reader, knownValues: known).hits.filter { $0.kind == .message }
            #expect(hits.count == 3, "\(reader): \(hits.map(\.ref.canonical))")
        }
    }

    /// `GlobalSearchTests.normalized`, with activity line ids folded out too (each message posted writes one).
    static func normalized(_ r: ShowResult) -> [String] {
        GlobalSearchTests.normalized(r).map {
            $0.replacingOccurrences(of: #"fact:activity:\d+"#, with: "fact:activity:", options: .regularExpression)
        }
    }

    /// R4-1: the shadow follows the vault. A doc indexed (and searched) before its value was stored is re-blanked once the
    /// value is stored; a rotated value un-blanks the old one and blanks the new; a removed value un-blanks.
    @Test func vaultChangesReblankTheShadow() async throws {
        let w = try Self.world()
        let s = w.store, cId = w.c.id
        func messages(_ q: String, _ known: [(name: String, value: String)]) async throws -> Int {
            try await w.resolve(q, knownValues: known).groupTotals[.messages] ?? 0
        }
        func shadowHolds(_ text: String) throws -> Bool {
            try s.writer.read { db in
                try Int.fetchOne(db, sql: """
                    SELECT COUNT(*) FROM memoryShadow WHERE companyId = ? AND (instr(body, ?) > 0 OR instr(title, ?) > 0)
                    """, arguments: [cId, text, text]) ?? 0
            } > 0
        }
        // Searched before the value is a secret: the value's docs are visible text (at most `MemoryPolicy.maxHits` per call).
        #expect(try await messages("4821", []) == MemoryPolicy.maxHits)
        #expect(try shadowHolds(Self.value))
        let vault = MemoryVault()
        let stored = try Self.store(w, Self.value, vault: vault)
        #expect(try await messages("4821", stored) == 3)
        #expect(try !shadowHolds(Self.value))
        // Rotated: the old value is ordinary text again, the new one is blanked.
        let rotated = try Self.store(w, "locker code 7356", vault: vault)
        #expect(try await messages("4821", rotated) == MemoryPolicy.maxHits)
        #expect(try await messages("7356", rotated) == 0)
        // Removed.
        try s.deleteSecret(companyId: cId, name: "PIN_KEY", vault: vault)
        #expect(try await messages("7356", []) == 3)
        #expect(try shadowHolds(Self.value))
    }

    /// A doc changed after the shadow was built is never matched on its old text, and its old text leaves the shadow at once.
    @Test func changedDocLeavesTheShadowAtOnce() async throws {
        let w = try Self.world()
        let s = w.store, cId = w.c.id, now = w.now
        let doc = MemoryIngestDoc(companyId: cId, source: .resource, sourceId: "res-shadow", ref: "F-9", title: "shadow doc",
                                  body: "heliotrope text", access: .company, provenance: .owner, createdAt: now)
        try s.ingest(doc, now: now)
        #expect(try await w.resolve("heliotrope").groupTotals[.artifactsResources] == 1)
        var changed = doc
        changed.body = "other text"
        try s.ingest(changed, now: now)
        let left = try await s.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM memoryShadow WHERE companyId = ? AND instr(body, 'heliotrope') > 0",
                             arguments: [cId]) ?? 0
        }
        #expect(left == 0)
        #expect(try await w.resolve("heliotrope").groupTotals[.artifactsResources] == nil)
        // A purge takes the doc's text out of the shadow's index segments too.
        try s.ingest(MemoryIngestDoc(companyId: cId, source: .resource, sourceId: "res-plume", ref: "F-9", title: "plume doc",
                                     body: "marmotplume text", access: .company, provenance: .owner, createdAt: now), now: now)
        #expect(try await w.resolve("marmotplume").groupTotals[.artifactsResources] == 1)
        try s.purgeMemoryDocs(companyId: cId, source: .resource, sourceIds: ["res-plume"], now: now)
        let blocks = try await s.writer.read { db in
            try Data.fetchAll(db, sql: "SELECT block FROM memoryShadowFts_data WHERE block IS NOT NULL")
        }
        #expect(!blocks.contains { $0.range(of: Data("marmotplume".utf8)) != nil })
        #expect(try await w.resolve("marmotplume").groupTotals[.artifactsResources] == nil)
    }

    /// R4-2: `search_memory`, `recall(query:)` and `search_kb` match and cut snippets only on visible text: a value stored
    /// after its doc was indexed is never matched, never quoted, and the query is never echoed back (the reply's redactor would
    /// otherwise answer whether the query was a stored value).
    @Test func memoryToolsMatchAndShowOnlyVisibleText() async throws {
        let w = try Self.world()
        let s = w.store, c = w.c, fx = w.fx
        _ = try s.kbWrite(companyId: c.id, by: .owner, path: "Eng/Locker", body: "# Locker\n\nlocker \(Self.value) door\n", knownValues: [])
        guard case .created = try s.remember(companyId: c.id, by: fx.eng1.id, fact: "door \(Self.value) locker", scope: .company,
                                             knownValues: []) else { Issue.record("remember"); return }
        try w.ingest()
        let vault = MemoryVault()
        _ = try Self.store(w, Self.value, vault: vault)
        _ = try s.reloadRedactorIfNeeded(vault: vault)
        let tools = CompanyTools(store: s, companyId: c.id, agentId: fx.qa2.id, paths: w.cf.paths, vault: vault, diagnostics: { _ in })
        func call(_ name: String, _ q: String) throws -> String { try tools.call(name: name, arguments: ["query": .string(q)]) }

        for name in ["search_memory", "recall", "search_kb"] {
            for q in [Self.value, "4821", "locker", "kx", "door"] {
                let out = try call(name, q)
                #expect(!out.contains(Self.value) && !out.contains("[redacted"), "\(name) \(q): \(out)")
            }
            // The value's own words match nothing the control doesn't.
            let a = try call(name, Self.value), b = try call(name, Self.control)
            #expect(a == b, "\(name): \(a) vs \(b)")
        }
        // search_memory: "4821" finds the three visible docs, as "7356" does.
        let four = try call("search_memory", "4821"), seven = try call("search_memory", "7356")
        #expect(four.hasPrefix("3 result(s)") && seven.hasPrefix("3 result(s)"), "\(four)\n\(seven)")
        // A visible word of a doc holding the value still finds it, without a snippet of it.
        let kb = try call("search_kb", "locker")
        #expect(kb.contains("kb:Eng/Locker") && !kb.contains("    | "), "\(kb)")
        let recalled = try call("recall", "locker")
        #expect(recalled.contains("mem:") && !recalled.contains("    | "), "\(recalled)")
        #expect(try call("search_kb", "4821").hasPrefix("No results you can read"))
    }
    /// Final wave B1 item 9 (Ruling on C4a r4 concern 2): `recall(ref:)` and `kb_read` never echo the agent's own text through
    /// the redactor. A ref, path or section that equals a stored value answers exactly like a random one: no "[redacted NAME]"
    /// confirms a guess.
    @Test func missingRefAnswersNeverEchoAGuess() async throws {
        let w = try Self.world()
        let s = w.store, c = w.c, fx = w.fx
        _ = try s.kbWrite(companyId: c.id, by: .owner, path: "Eng/Locker", body: "# Locker\n\n## Door\n\nlocker door\n", knownValues: [])
        let vault = MemoryVault()
        _ = try Self.store(w, Self.value, vault: vault)
        _ = try s.reloadRedactorIfNeeded(vault: vault)
        let tools = CompanyTools(store: s, companyId: c.id, agentId: fx.qa2.id, paths: w.cf.paths, vault: vault, diagnostics: { _ in })
        func call(_ name: String, _ args: [String: JSONValue]) -> String {
            do { return try tools.call(name: name, arguments: args) } catch { return "error: \(error)" }
        }
        let cases: [(String, (String) -> [String: JSONValue])] = [
            ("recall", { ["ref": .string("mem:\($0)")] }),
            ("recall", { ["ref": .string($0)] }),
            ("recall", { ["ref": .string("kb:\($0)")] }),
            ("kb_read", { ["path": .string($0)] }),
            ("kb_read", { ["path": .string("Eng/\($0)")] }),
            ("kb_read", { ["path": .string("Eng/Locker"), "section": .string($0)] }),
        ]
        for (name, args) in cases {
            let guess = call(name, args(Self.value)), random = call(name, args(Self.control))
            #expect(!guess.contains("[redacted") && !guess.contains(Self.value), "\(name): \(guess)")
            #expect(guess == random, "\(name): \(guess) vs \(random)")
        }
    }
}
