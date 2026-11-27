import Testing
import Foundation
import GRDB
@testable import BrahmaCore
@testable import BrahmaAppModel

@MainActor @Suite(.scratch) struct ShowBarModelTests {
    nonisolated static func hit(_ canonical: String, kind: WorkRefKind = .item, group: ShowGroup = .top, score: Double = 1, inlineOnly: Bool = false) -> ShowHit {
        ShowHit(ref: WorkRef(kind: kind, id: canonical), title: canonical, subtitle: "", snippet: nil, at: nil, group: group, score: score,
                kind: nil, inlineOnly: inlineOnly)
    }

    nonisolated static func result(_ q: String, hits: [ShowHit], intent: ShowIntent = .lookup, answer: FactAnswer? = nil,
                       filters: SearchFilters = SearchFilters(), totals: [ShowGroup: Int] = [:]) -> ShowResult {
        ShowResult(normalized: q, stripped: q, filters: filters, answer: answer, hits: hits, topScore: hits.map(\.score).max() ?? 0,
                   intent: intent, groupTotals: totals)
    }

    nonisolated static let concierge = RoutedTarget(target: .concierge, reason: ShowRouting.conciergeReason, busy: false)

    /// A backend whose results are canned per query; `delay` holds some of them.
    nonisolated static func canned(_ results: [String: ShowResult], delays: [String: Duration] = [:],
                       targets: [RoutedTarget] = [concierge]) -> ShowBarBackend {
        ShowBarBackend(
            resolve: { q in
                if let d = delays[q] { try await Task.sleep(for: d) }
                guard let r = results[q] else { return result(q, hits: [], intent: .request) }
                return r
            },
            targets: { _, _, _, _ in targets },
            askLine: { t in
                switch t.target {
                case .concierge: return "Ask Brahma · quick · ~0.1% of 5H"
                case .agent(let id): return "Ask @\(id) · \(t.reason) · ~1% of 5H" + (t.busy ? " · busy: answers after its current turn" : "")
                }
            },
            logMiss: { _, _ in })
    }

    /// A world with every search group seeded under the token `zebra42`.
    @MainActor struct World {
        let w: RefWorld
        let zebra: Agent
        let files = FileIndexCache()
        let commits = CommitIndexCache()

        init() throws {
            w = try RefWorld()
            let s = w.store, c = w.company, now = w.now
            let router = MessageRouter(store: s)
            _ = try s.createWorkItem(companyId: c.id, by: .owner, draft: WorkItemDraft(type: .task, title: "zebra42 checkout"))
            _ = try router.post(companyId: c.id, channel: "general", from: .owner, text: "zebra42 hello team")
            zebra = try s.hire(companyId: c.id, name: "zebra42", role: "engineer", model: "sonnet")
            _ = try s.kbWrite(companyId: c.id, by: .owner, path: "Eng/Zebra", body: "# Zebra\n\nzebra42 handbook text\n", knownValues: [])
            _ = try s.remember(companyId: c.id, by: w.eng1.id, fact: "zebra42 deploys on fridays", scope: .company, knownValues: [])
            try RefWorld.write("src/zebra42.ts", "export const z = 42\n", in: w.workspace)
            try RefWorld.write("docs/zebra42-notes.md", "# zebra42 notes\n", in: w.workspace)
            try RefWorld.git(["add", "-A"], in: w.workspace)
            try RefWorld.git(["commit", "-q", "-m", "zebra42: add the zebra file"], in: w.workspace)
            let main = try w.head()
            try w.seedResource(number: 9, name: "zebra42.md", bytes: Data("zebra42 resource text\n".utf8), provenance: "owner")
            let (cId, eng1Id, itemId, eng3Id, ctoId) = (c.id, w.eng1.id, w.item.id, w.eng3.id, w.cto.id)
            try s.writer.write { db in
                try db.execute(sql: "UPDATE company SET mainCommit = ? WHERE id = ?", arguments: [main, cId])
                _ = try s.ingest(db: db, MemoryIngestDoc(companyId: cId, source: .resource, sourceId: "res-9", ref: "F-9", title: "zebra42.md",
                                                         body: "zebra42 resource text", access: .company, provenance: .owner, createdAt: now), now: now)
                try Ask(id: UUID().uuidString, companyId: cId, number: 7, kind: .info, risk: .low, requesterId: eng1Id,
                        title: "zebra42 question", summary: "which zebra42?", status: .pendingOwner, createdActive: 0,
                        statusSinceActive: 0, createdAt: now, updatedAt: now).insert(db)
                try db.execute(sql: """
                    INSERT INTO release (id, companyId, number, version, status, provider, project, "commit", plan, commandsHash,
                      rollbackPlan, notes, proposedById, createdAt) VALUES (?, ?, 1, '1.0', 'deployed', 'p', 'p', 'abc', '{}', 'h', '{}',
                      'zebra42 launch', 'owner', ?)
                    """, arguments: [UUID().uuidString, cId, now])
                try Sprint(id: UUID().uuidString, companyId: cId, number: 1, team: nil, goal: "zebra42 goal", cadence: .sprint,
                           status: .active, createdAt: now).insert(db)
                try ActivityEvent(companyId: cId, agentId: nil, turnId: nil, kind: .merge, text: "ENG-1 merged zebra42 fix", createdAt: now).insert(db)
                try PreviewSurface(id: UUID().uuidString, companyId: cId, name: "zebra42", position: 0, build: nil, run: "npm start",
                                   url: "http://127.0.0.1:{port}/", smoke: [SmokeRequest(method: "GET", path: "/zebra42")],
                                   setById: "owner", createdAt: now, updatedAt: now).insert(db)
                // ENG-1: leased by @eng-3 (idle), reviewed by @cto, blocked on the owner: the fact and the routing rules have a subject.
                try db.execute(sql: "UPDATE workItem SET status = 'blocked', blockedReason = 'waiting on zebra42 keys', ownerId = ?, reviewerId = ? WHERE id = ?",
                               arguments: [eng3Id, ctoId, itemId])
                try WorkLease(itemId: itemId, companyId: cId, agentId: eng3Id, acquiredAt: now, expiresActive: 1_000_000_000).insert(db)
            }
            _ = try MemoryIngest.run(store: s, companyId: c.id, paths: w.paths, now: now)
        }

        func model() -> ShowBarModel {
            ShowBarModel(backend: .live(store: w.store, companyId: w.company.id, files: files, commits: commits, knownValues: { [] }))
        }

        func count(_ table: String) throws -> Int { try w.count(table) }
    }

    nonisolated static func headers(_ rows: [ShowRow]) -> [String] {
        rows.compactMap { if case .header(let h) = $0 { return h } else { return nil } }
    }

    // MARK: Tests

    @Test func staleShowResultsDropped() async throws {
        let backend = Self.canned(["ch": Self.result("ch", hits: [Self.hit("CH-1")]), "che": Self.result("che", hits: [Self.hit("CHE-2")])],
                                  delays: ["ch": .milliseconds(600)])
        let model = ShowBarModel(backend: backend)
        async let first: Void = model.update(query: "ch")
        try await Task.sleep(for: .milliseconds(150))
        async let second: Void = model.update(query: "che")
        _ = await (first, second)
        #expect(model.query == "che")
        #expect(model.rows.contains { if case .hit(let h) = $0 { return h.ref.id == "CHE-2" } else { return false } })
        #expect(!model.rows.contains { if case .hit(let h) = $0 { return h.ref.id == "CH-1" } else { return false } })
        #expect(model.generation == 2)
        #expect(ShowBarModel.debounce == .milliseconds(80))
    }

    @Test func groupsAndAskRowLast() async throws {
        let world = try World()
        let model = world.model()
        await model.update(query: "zebra42")
        let rows = model.rows
        guard case .ask(let text)? = rows.last else {
            Issue.record("last row is \(String(describing: rows.last))")
            return
        }
        #expect(text == "Ask Brahma · quick · ~0.1% of 5H")
        #expect(rows.filter { if case .ask = $0 { return true } else { return false } }.count == 1)
        let allowed: Set<String> = ["TOP HIT", "ANSWER", "ITEMS", "ASKS", "FILES", "COMMITS", "ARTIFACTS & RESOURCES", "HANDBOOK", "MEMORY",
                                    "MESSAGES", "PEOPLE", "RELEASES", "SPRINTS", "ACTIVITY", "PREVIEWS"]
        let headers = Self.headers(rows)
        #expect(!headers.isEmpty && headers.allSatisfy(allowed.contains))
        #expect(Set(headers).count == headers.count)
        // At most 5 hits under each header.
        var current = "", perGroup: [String: Int] = [:]
        for row in rows {
            switch row {
            case .header(let h): current = h
            case .hit: perGroup[current, default: 0] += 1
            default: break
            }
        }
        #expect(perGroup.values.allSatisfy { $0 <= ShowResolver.groupLimit })
        #expect(perGroup.values.allSatisfy { $0 > 0 })
        // Nothing was asked or spent.
        #expect(try world.count("showRequest") == 0)
        #expect(try world.count("turn") == 0)
    }

    @Test func enterOpensTopHitAtZeroCost() async throws {
        let world = try World()
        let model = world.model()
        let before = try (world.count("showRequest"), world.count("refRead"), world.count("turn"))
        await model.update(query: "ENG-1")
        #expect(model.result?.intent == .lookup)
        #expect(model.rows.first == .header("TOP HIT"))
        #expect(model.selection == 1)
        let action = model.handle(.enter)
        guard case .open(let opened) = action else {
            Issue.record("expected .open, got \(action)")
            return
        }
        #expect(opened.ref.canonical == "ENG-1" && opened.origin == .owner && opened.kindChip == "ITEM")
        #expect(!opened.title.isEmpty)
        #expect(try (world.count("showRequest"), world.count("refRead"), world.count("turn")) == before)
        // The model alone never opens an inline-only hit.
        let inline = ShowBarModel(backend: Self.canned(["x": Self.result("x", hits: [Self.hit("fact:activity:9", kind: .fact, inlineOnly: true)])]))
        await inline.update(query: "x")
        #expect(inline.selection == 1)
        #expect(inline.handle(.enter) == .none)
    }

    @Test func askRequiresVisibleEnter() async throws {
        let world = try World()
        let model = world.model()
        await model.update(query: "why is checkout slow on mobile")
        #expect(model.result?.intent == .request)
        guard case .ask? = model.rows.indices.contains(model.selection) ? model.rows[model.selection] : nil else {
            Issue.record("selection \(model.selection) is not the ASK row: \(model.rows)")
            return
        }
        #expect(try world.count("showRequest") == 0)
        // Up and down never land on a header; Escape closes without asking.
        _ = model.handle(.up)
        #expect(model.rows.indices.contains(model.selection))
        if case .header = model.rows[model.selection] { Issue.record("selection landed on a header") }
        #expect(model.handle(.escape) == .close)
        #expect(try world.count("showRequest") == 0)
        await model.update(query: "why is checkout slow on mobile")
        let action = model.handle(.enter)
        guard case .ask(let draft) = action else {
            Issue.record("expected .ask, got \(action)")
            return
        }
        #expect(draft.query == "why is checkout slow on mobile" && draft.kind == .show && draft.attachedRef == nil)
        #expect(draft.target == model.askTarget)
        // The model itself sent nothing: the app's `submitAsk` does, after the owner's Enter.
        #expect(try world.count("showRequest") == 0)
        #expect(try world.count("turn") == 0)
    }

    @Test func cmdEnterAlwaysAsksOptEnterOpensSteps() async throws {
        let model = ShowBarModel(backend: Self.canned([
            "two": Self.result("two", hits: [Self.hit("ENG-1"), Self.hit("ENG-2", score: 0.9), Self.hit("src/a.ts", kind: .file, group: .files, score: 0.5)]),
        ]))
        await model.update(query: "two")
        #expect(model.selection == 1)
        guard case .ask(let draft) = model.handle(.cmdEnter) else {
            Issue.record("⌘Enter did not ask")
            return
        }
        #expect(draft.query == "two")
        #expect(model.handle(.optEnter) == .openSteps([WorkRef(kind: .item, id: "ENG-1"), WorkRef(kind: .item, id: "ENG-2")]))
        // Moving the selection to a group hit and pressing Enter opens that hit.
        _ = model.handle(.down)
        _ = model.handle(.down)
        if case .open(let o) = model.handle(.enter) { #expect(o.ref.id == "src/a.ts" && o.kindChip == "FILE") } else { Issue.record("not open") }
        // One top candidate: ⌥Enter opens it alone.
        let one = ShowBarModel(backend: Self.canned(["one": Self.result("one", hits: [Self.hit("ENG-1")])]))
        await one.update(query: "one")
        if case .open(let o) = one.handle(.optEnter) { #expect(o.ref.id == "ENG-1") } else { Issue.record("⌥Enter with one candidate did not open it") }
        // Choosing Ask while candidates exist logs a miss.
        let misses = Misses()
        var backend = Self.canned(["two": Self.result("two", hits: [Self.hit("ENG-1")])])
        backend.logMiss = { q, score in await misses.add(q, score) }
        let missing = ShowBarModel(backend: backend)
        await missing.update(query: "two")
        _ = missing.handle(.cmdEnter)
        for _ in 0..<100 where await misses.all.count != 1 { try await Task.sleep(for: .milliseconds(20)) }
        #expect(await misses.all.first?.0 == "two")
    }

    actor Misses {
        var all: [(String, Double)] = []
        func add(_ q: String, _ s: Double) { all.append((q, s)) }
    }

    @Test func tabCyclesTargets() async throws {
        let world = try World()
        let model = world.model()
        await model.update(query: "ENG-1")
        #expect(model.askTarget.target == .concierge)
        #expect(model.targets.count >= 2, "\(model.targets)")
        let names = model.targets.compactMap { t -> String? in if case .agent(let id) = t.target { return id } else { return nil } }
        #expect(names.contains(world.w.eng3.id))
        #expect(model.targets.dropFirst().allSatisfy { !$0.reason.isEmpty })
        #expect(model.handle(.tab) == .none)
        #expect(model.askTarget.target == .agent(world.w.eng3.id))
        if case .ask(let line)? = model.rows.last { #expect(line.hasPrefix("Ask @eng-3 · ") && line.contains("% of 5H")) } else { Issue.record("no ask row") }
        for _ in 1..<model.targets.count { _ = model.handle(.tab) }
        #expect(model.askTarget.target == .concierge)
        if case .ask(let line)? = model.rows.last { #expect(line == "Ask Brahma · quick · ~0.1% of 5H") } else { Issue.record("no ask row") }
        // An explicit @handle in the query is the default target.
        await model.update(query: "@cto what is ENG-1")
        #expect(model.askTarget.target == .agent(world.w.cto.id))
        #expect(model.askTarget.reason.hasPrefix("you asked @"))
    }

    @Test func answerRowFirstForFacts() async throws {
        let world = try World()
        let model = world.model()
        await model.update(query: "what's blocked")
        #expect(model.result?.intent == .fact)
        #expect(model.rows.count >= 3)
        #expect(model.rows[0] == .header("ANSWER"))
        guard case .answer(let a) = model.rows[1] else {
            Issue.record("rows[1] is \(model.rows[1])")
            return
        }
        #expect(a.kind == .blocked)
        #expect(model.selection == 1)
        let action = model.handle(.enter)
        guard case .open(let opened) = action else {
            Issue.record("expected .open, got \(action)")
            return
        }
        #expect(opened.ref.kind == .fact && opened.ref.id == a.query && opened.kindChip == "FACT")
        #expect(try world.count("showRequest") == 0)
        if case .ask? = model.rows.last {} else { Issue.record("ASK is not last") }
    }

    @Test func filterChipsShown() async throws {
        let world = try World()
        let model = world.model()
        await model.update(query: "blocked by @eng-3 this week")
        #expect(model.filterChips == ["BLOCKED", "BY @ENG-3", "THIS WEEK"])
        let gen = model.generation
        await model.removeFilterChip("BY @ENG-3")
        #expect(model.generation > gen)
        #expect(model.query == "blocked this week")
        #expect(model.filterChips == ["BLOCKED", "THIS WEEK"])
        await model.removeFilterChip("THIS WEEK")
        // A bare status word alone also sets the kinds (SearchFilters): BLOCKED stays first.
        #expect(model.filterChips.first == "BLOCKED")
        // A query of at most 300 characters reaches the resolver.
        await model.update(query: String(repeating: "x", count: 5_000))
        #expect(model.result?.normalized.count ?? 0 <= ShowResolver.maxQuery)
        if case .ask? = model.rows.last {} else { Issue.record("ASK is not last") }
    }

    @Test func everyGroupCanAppear() async throws {
        let world = try World()
        let model = world.model()
        var seen = Set<String>()
        for q in ["zebra42", "ENG-1", "what's blocked", "@zebra42", "zebra42 question", "zebra42 launch", "zebra42 goal",
                  "zebra42 hello", "zebra42 fix", "Eng/Zebra", "src/zebra42.ts", "zebra42.md", "zebra42 deploys"] {
            await model.update(query: q)
            seen.formUnion(Self.headers(model.rows))
        }
        let all: Set<String> = ["TOP HIT", "ANSWER", "ITEMS", "ASKS", "FILES", "COMMITS", "ARTIFACTS & RESOURCES", "HANDBOOK", "MEMORY",
                                "MESSAGES", "PEOPLE", "RELEASES", "SPRINTS", "ACTIVITY", "PREVIEWS"]
        #expect(all.subtracting(seen).isEmpty, "missing \(all.subtracting(seen))")
        #expect(seen.subtracting(all).isEmpty, "unknown \(seen.subtracting(all))")
        // A See-all row names the message total when more messages than shown match.
        let totals = ShowBarModel(backend: Self.canned(["m": Self.result("m", hits: [Self.hit("msg:1", kind: .message, group: .messages, score: 0.7)],
                                                                                   totals: [.messages: 9])]))
        await totals.update(query: "m")
        #expect(totals.rows.contains(.seeAll(9)))
        #expect(totals.handle(.down) == .none)
        var found = false
        for _ in 0..<5 {
            if case .seeAll = totals.rows[totals.selection] { found = true; break }
            _ = totals.handle(.down)
        }
        #expect(found)
        #expect(totals.handle(.enter) == .seeAll("m"))
    }

    @Test func refusesWithoutKnownValues() async throws {
        let world = try World()
        struct Unreadable: Error {}
        let model = ShowBarModel(backend: .live(store: world.w.store, companyId: world.w.company.id, files: world.files, commits: world.commits,
                                                knownValues: { throw Unreadable() }))
        await model.update(query: "zebra42")
        #expect(model.error != nil)
        #expect(!model.rows.contains { if case .hit = $0 { return true } else { return false } })
        if case .ask? = model.rows.last {} else { Issue.record("ASK is not last") }
    }
}
