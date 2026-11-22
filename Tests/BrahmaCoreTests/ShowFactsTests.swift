import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Plan C Task C4b's world (on `CollabFixture`: company C, prefix ENG, `@cto`, `@eng-1`, `@qa-2`, `@eng-3`, `#eng` {eng-1}):
/// turns with `costLE` this week and last week, the 5H/7D usage, two blocked items with reasons and a blocked agent (`@cto`,
/// waiting on one of them), ENG-142 leased by eng-3 and reviewed by qa-2 (touching `src/checkout.tsx`), release `rel:1` on
/// 2026-10-10 with three items done since and one before, two pending owner asks, active sprint 3, a failing run, a red
/// main smoke with its bug, a held merge queue, and `#design` {qa-2, eng-3}. Active time is three days.
struct ShowFactsFixture {
    let cf: CollabFixture
    let files = FileIndexCache()
    let commits = CommitIndexCache()
    let item142: WorkItem, payments: WorkItem, searchBox: WorkItem, bug: WorkItem
    let doneBefore: WorkItem
    let doneSince: [WorkItem]
    let tz: TimeZone
    let weekStart: Date
    let mid: Date
    var fx: RefFixture { cf.fx }
    var store: Store { cf.store }
    var c: Company { cf.c }
    var now: Date { cf.now }

    static let day: TimeInterval = 86_400

    init() throws {
        cf = try CollabFixture()
        let s = cf.store, c = cf.c, fx = cf.fx, now = cf.now
        tz = s.ownerTimeZone()
        weekStart = try #require(SearchFilters.parse("this week", now: now, tz: tz, activeSprintStart: nil).filters.window?.start)
        mid = weekStart.addingTimeInterval(now.timeIntervalSince(weekStart) / 2)
        try s.advanceActive(companyId: c.id, by: 3 * Self.day)

        func item(_ title: String, type: WorkItemType = .task) throws -> WorkItem {
            try s.createWorkItem(companyId: c.id, by: .owner, draft: WorkItemDraft(type: type, title: title))
        }
        payments = try item("Payments")
        searchBox = try item("Search box")
        let created142 = try item("Checkout totals")
        bug = try item("Main is red: smoke check failed", type: WorkItemType("bug"))
        doneBefore = try item("Old work")
        doneSince = try [item("Cart"), item("Coupons"), item("Receipts")]
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        func day(_ d: Int) throws -> Date { try #require(cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: 12))) }
        let releaseDay = try day(10)
        let doneDates = [try day(11), try day(12), mid]
        let beforeDate = try day(5)

        let (cId, eng1Id, eng3Id, qa2Id, ctoId) = (c.id, fx.eng1.id, fx.eng3.id, fx.qa2.id, fx.cto.id)
        let (paymentsId, searchId, id142, bugId) = (payments.id, searchBox.id, created142.id, bug.id)
        let (beforeId, sinceIds) = (doneBefore.id, doneSince.map(\.id))
        let (weekStart, mid) = (weekStart, mid)
        let main = try fx.git.git(["rev-parse", "main"])
        let paymentsKey = payments.key
        try s.writer.write { db in
            // Blocked: Payments for two active days, Search box for one hour.
            try db.execute(sql: "UPDATE workItem SET status = 'blocked', blockedReason = 'waiting on the API key', blockedSinceActive = ? WHERE id = ?",
                           arguments: [1 * Self.day, paymentsId])
            try db.execute(sql: "UPDATE workItem SET status = 'blocked', blockedReason = 'needs a design', blockedSinceActive = ? WHERE id = ?",
                           arguments: [3 * Self.day - 3600, searchId])
            var cto = try #require(try Agent.fetchOne(db, key: ctoId))
            cto.state = .blocked
            cto.blocker = .workItem(id: paymentsId, key: paymentsKey)
            try cto.update(db)
            // ENG-142: leased by eng-3, reviewed by qa-2, touching src/checkout.tsx.
            try db.execute(sql: "UPDATE workItem SET key = 'ENG-142', number = 142, status = 'inProgress', ownerId = ?, reviewerId = ? WHERE id = ?",
                           arguments: [eng3Id, qa2Id, id142])
            var i142 = try #require(try WorkItem.fetchOne(db, key: id142))
            i142.touchPaths = ["src/checkout.tsx"]
            try i142.update(db)
            try WorkLease(itemId: id142, companyId: cId, agentId: eng3Id, acquiredAt: now, expiresActive: 1_000_000_000).insert(db)
            // Done: one before the release, three since.
            try db.execute(sql: "UPDATE workItem SET status = 'done', doneAt = ? WHERE id = ?", arguments: [beforeDate, beforeId])
            for (id, at) in zip(sinceIds, doneDates) {
                try db.execute(sql: "UPDATE workItem SET status = 'done', doneAt = ?, points = 2 WHERE id = ?", arguments: [at, id])
            }
            // rel:1, deployed 2026-10-10.
            try db.execute(sql: """
                INSERT INTO release (id, companyId, number, version, status, provider, project, "commit", plan, commandsHash,
                  rollbackPlan, notes, proposedById, createdAt, deployedAt) VALUES (?, ?, 1, '2.0', 'deployed', 'p', 'p', 'abc', '{}', 'h',
                  '{}', 'the launch', 'owner', ?, ?)
                """, arguments: [UUID().uuidString, cId, releaseDay, releaseDay])
            // Turns: this week eng-1 $2.00, eng-3 $1.25 + $0.50 (in the sprint), qa-2 $0.75; last week cto $10.
            func turn(_ agent: String, _ at: Date, _ le: Double) throws {
                var t = Turn(id: UUID().uuidString, agentId: agent, companyId: cId, startedAt: at, endedAt: at, outcome: .succeeded,
                             summary: "ok", costUSD: nil)
                t.costLE = le
                try t.insert(db)
            }
            try turn(eng1Id, mid, 2.0)
            try turn(eng3Id, mid, 1.25)
            try turn(qa2Id, mid, 0.75)
            try turn(eng3Id, now.addingTimeInterval(-10), 0.5)
            try turn(ctoId, weekStart.addingTimeInterval(-Self.day), 10)
            // Asks waiting on the owner: A-7 for three days, A-8 for one.
            try Ask(id: UUID().uuidString, companyId: cId, number: 7, kind: .info, risk: .low, requesterId: eng1Id,
                    title: "Pick a provider", summary: "s", status: .pendingOwner, createdActive: 0, statusSinceActive: 0,
                    createdAt: now, updatedAt: now).insert(db)
            try Ask(id: UUID().uuidString, companyId: cId, number: 8, kind: .info, risk: .low, requesterId: eng3Id,
                    title: "Approve the budget", summary: "s", status: .pendingOwner, createdActive: 2 * Self.day,
                    statusSinceActive: 2 * Self.day, createdAt: now, updatedAt: now).insert(db)
            // Sprint 3: Payments (blocked, 3 points), ENG-142 (5 points), Receipts (done, 2 points); one active day in.
            try Sprint(id: "sprint-3", companyId: cId, number: 3, team: nil, goal: "Checkout", cadence: .sprint, status: .active,
                       startedActive: 2 * Self.day, createdAt: now, startedAt: now.addingTimeInterval(-30)).insert(db)
            try db.execute(sql: "UPDATE workItem SET sprintId = 'sprint-3', points = 3 WHERE id = ?", arguments: [paymentsId])
            try db.execute(sql: "UPDATE workItem SET sprintId = 'sprint-3', points = 5 WHERE id = ?", arguments: [id142])
            try db.execute(sql: "UPDATE workItem SET sprintId = 'sprint-3' WHERE id = ?", arguments: [sinceIds[2]])
            // Runs: ENG-142's latest failed; ENG-1 failed, then passed.
            let item1 = fx.item.id
            for (id, item, status, at) in [("run-142", id142, VerificationStatus.failed, now), ("run-1a", item1, .failed, now.addingTimeInterval(-120)),
                                            ("run-1b", item1, .passed, now.addingTimeInterval(-60))] {
                try VerificationRun(id: id, companyId: cId, itemId: item, checkRevision: 0, scriptHash: "h", commit: "abc", command: "true",
                                    workingDirectory: ".", timeoutSeconds: 60, purpose: .submit, status: status,
                                    exitCode: status == .failed ? 1 : 0, createdAt: at).insert(db)
            }
            // Main is red, with its bug; the merge queue is held.
            try MainSmokeRun(companyId: cId, commit: main, status: .failed, exitCode: 2, reason: .merge, createdAt: now, finishedAt: now).insert(db)
            try db.execute(sql: "UPDATE company SET redBugItemId = ?, mergeHold = ? WHERE id = ?",
                           arguments: [bugId, Store.redMainHold, cId])
        }
        _ = try s.createChannel(companyId: c.id, name: "design", members: [fx.qa2.id, fx.eng3.id])
        try s.saveRateLimit(RateLimitInfo(status: "allowed", resetsAt: nil, rateLimitType: nil, isUsingOverage: false,
                                          fiveHourUtilization: 0.42, sevenDayUtilization: 0.35, observedAt: now,
                                          fiveHourResetsAt: now.addingTimeInterval(7200), sevenDayResetsAt: now.addingTimeInterval(4 * Self.day)))
        item142 = try #require(try s.workItem(id: created142.id))
    }

    func resolver() -> ShowResolver { ShowResolver(store: store, files: files, commits: commits) }

    func resolve(_ q: String, as reader: Reader = .owner, company: String? = nil,
                 knownValues: [(name: String, value: String)] = []) async throws -> ShowResult {
        try await resolver().resolve(q, companyId: company ?? c.id, reader: reader, knownValues: knownValues)
    }

    func answer(_ q: String, as reader: Reader = .owner, company: String? = nil,
                knownValues: [(name: String, value: String)] = []) async throws -> FactAnswer? {
        try await resolve(q, as: reader, company: company, knownValues: knownValues).answer
    }

    /// The rows a fact must never write: turns, show requests (C4c) and ref reads.
    func counts() throws -> [Int] {
        try store.writer.read { db in
            try ["turn", "showRequest", "refRead"].map { table in
                guard try db.tableExists(table) else { return 0 }
                return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
            }
        }
    }

    func tool(_ a: Agent, _ q: String, vault: (any SecretVault)? = nil) throws -> String {
        try CompanyTools(store: store, companyId: c.id, agentId: a.id, paths: cf.paths, vault: vault)
            .call(name: "search", arguments: ["query": .string(q)])
    }
}

@Suite(.scratch) struct ShowFactsTests {
    @Test(arguments: [
        ("how much usage have we spent this week", FactKind.usage), ("what's our burn this sprint", .usage),
        ("what's blocked", .blocked), ("anything stuck?", .blocked),
        ("who's on ENG-142", .whoIsOn), ("who is working on src/checkout.tsx", .whoIsOn),
        ("what shipped since 2026-10-01", .shipped), ("what got done this week", .shipped),
        ("what needs me", .pendingAsks), ("pending approvals", .pendingAsks),
        ("how's the sprint going", .sprintProgress), ("any failing checks", .failingChecks), ("is main red", .failingChecks)])
    func factualQuestionsAnsweredWithZeroTurns(_ q: String, _ k: FactKind) async throws {
        let w = try ShowFactsFixture()
        let before = try w.counts()
        let r = try await w.resolve(q)
        #expect(r.intent == .fact)
        #expect(r.answer?.kind == k, "\(q): \(String(describing: r.answer?.kind))")
        #expect(r.answer?.lines.isEmpty == false, "\(q)")
        #expect(r.answer?.query == r.normalized)
        #expect(try w.counts() == before)
    }

    @Test func everyLineCarriesRefs() async throws {
        let w = try ShowFactsFixture()
        let queries = ["how much usage have we spent this week", "what's blocked", "who's on ENG-142", "who is working on src/checkout.tsx",
                       "who is on #design", "what shipped since 2026-10-01", "pending approvals", "how's the sprint going", "is main red"]
        var kinds = Set<FactKind>()
        for q in queries {
            let a = try #require(try await w.answer(q), "\(q)")
            kinds.insert(a.kind)
            #expect(a.lines.count <= FactAnswer.maxLines)
            for line in a.lines {
                #expect(!line.refs.isEmpty, "\(q): \(line.text)")
                for ref in line.refs {
                    #expect(try w.store.resolveRef(ref, for: .owner, companyId: w.c.id).visibility == .full, "\(q): \(ref.canonical)")
                }
                #expect(!line.text.contains("\n"))
            }
        }
        #expect(kinds == Set(FactKind.allCases))
    }

    @Test func usageThisWeekNumbers() async throws {
        let w = try ShowFactsFixture()
        let a = try #require(try await w.answer("how much usage have we spent this week"))
        #expect(a.title == "USAGE · THIS WEEK · $4.50 LE", "\(a.title)")
        let text = a.lines.map(\.text)
        #expect(text.contains { $0.contains("5H 42%") && $0.contains("7D 35%") }, "\(text)")
        #expect(text.contains { $0.contains("$4.50 LE") && $0.contains("THIS WEEK") }, "\(text)")
        // Top three agents by $LE, in order; last week's $10 is outside the window.
        let agentLines = a.lines.filter { $0.refs.first?.kind == .agent }
        #expect(agentLines.map { $0.refs[0].id } == ["eng-1", "eng-3", "qa-2"], "\(agentLines.map(\.text))")
        #expect(agentLines.map(\.text) == ["@eng-1 $2.00 LE", "@eng-3 $1.75 LE", "@qa-2 $0.75 LE"])
        // The active sprint's $LE since it started, and the company's share of the week.
        #expect(a.lines.contains { $0.refs == [WorkRef(kind: .sprint, id: "3")] && $0.text.contains("$0.50 LE") }, "\(text)")
        let share = Int((w.store.weeklyShare() * 100).rounded())
        #expect(text.contains { $0.contains("\(share)% weekly share") }, "\(text)")
        // A window of its own: last week holds only cto's $10.
        let last = try #require(try await w.answer("how much did we spend last week"))
        #expect(last.title == "USAGE · LAST WEEK · $10.00 LE", "\(last.title)")
        // Fix round 1: the share is 3a's (`Pacing.pace`: share = 1 - reserve; reserve = the company's override, else
        // 1 - weeklyShare). A company reserve of 60% leaves it 40%.
        try w.store.setOwnerReserve(companyId: w.c.id, 0.6)
        let reserved = try #require(try await w.answer("how much usage have we spent this week"))
        #expect(reserved.lines.contains { $0.text.contains("of this company's 40% weekly share") }, "\(reserved.lines.map(\.text))")
    }

    @Test func blockedIncludesReasons() async throws {
        let w = try ShowFactsFixture()
        let a = try #require(try await w.answer("what's blocked"))
        #expect(a.title == "BLOCKED · 2 ITEMS, 1 AGENT", "\(a.title)")
        let payments = try #require(a.lines.first { $0.refs.first == WorkRef(kind: .item, id: w.payments.key) })
        #expect(payments.text.contains("waiting on the API key") && payments.text.contains("blocked 2d"), "\(payments.text)")
        // Oldest first.
        #expect(a.lines.first?.refs.first?.id == w.payments.key)
        #expect(a.lines.contains { $0.refs.first?.id == w.searchBox.key && $0.text.contains("blocked 1h") })
        let cto = try #require(a.lines.first { $0.refs.first == WorkRef(kind: .agent, id: "cto") })
        // Fix round 1: the agent's reason is the stall report's (`StallExplainer`), in the report's own words.
        #expect(cto.text == "@cto " + StallExplainer.agentReason(.workItem(id: w.payments.id, key: w.payments.key), ownerWord: "the owner",
                                                                 handle: { _ in nil }, timeZone: w.tz), "\(cto.text)")
        #expect(cto.text.contains("blocked on \(w.payments.key)"), "\(cto.text)")
        #expect(try w.store.stallReport(companyId: w.c.id).reasons.contains("1 agent blocked on \(w.payments.key)"))
        #expect(cto.refs.contains(WorkRef(kind: .item, id: w.payments.key)))
    }

    @Test func whoIsOnKeyNamesHolderAndReviewer() async throws {
        let w = try ShowFactsFixture()
        let a = try #require(try await w.answer("who's on ENG-142"))
        #expect(a.kind == .whoIsOn)
        let text = a.lines.map(\.text).joined(separator: "\n")
        #expect(a.lines.contains { $0.text.contains("held by @eng-3") && $0.refs.contains(WorkRef(kind: .agent, id: "eng-3")) }, "\(text)")
        #expect(a.lines.contains { $0.text.contains("reviewer @qa-2") && $0.refs.contains(WorkRef(kind: .agent, id: "qa-2")) }, "\(text)")
        #expect(a.lines.allSatisfy { $0.refs.contains(WorkRef(kind: .item, id: "ENG-142")) })
        // A path: the items whose touch paths cover it, and the last commit to it (no turn recorded it: no author).
        let p = try #require(try await w.answer("who is working on src/checkout.tsx"))
        #expect(p.lines.contains { $0.refs.first == WorkRef(kind: .item, id: "ENG-142") && $0.text.contains("@eng-3") }, "\(p.lines.map(\.text))")
        #expect(p.lines.contains { $0.refs.first?.kind == .commit && $0.text.contains("unverified author") }, "\(p.lines.map(\.text))")
        // A channel: its members with their current items.
        let ch = try #require(try await w.answer("who is on #design"))
        #expect(Set(ch.lines.compactMap { $0.refs.first(where: { $0.kind == .agent })?.id }) == ["qa-2", "eng-3"], "\(ch.lines.map(\.text))")
        #expect(ch.lines.contains { $0.text.contains("@eng-3") && $0.refs.contains(WorkRef(kind: .item, id: "ENG-142")) })
        #expect(ch.title == "WHO'S ON · 2 PEOPLE", "\(ch.title)")
    }

    @Test func shippedDefaultsToSinceLastRelease() async throws {
        let w = try ShowFactsFixture()
        let a = try #require(try await w.answer("what shipped"))
        let refs = Set(a.lines.flatMap(\.refs).map(\.canonical))
        #expect(refs.isSuperset(of: Set(["rel:1"] + w.doneSince.map(\.key))), "\(refs)")
        #expect(!refs.contains(w.doneBefore.key), "\(refs)")
        #expect(a.title.hasPrefix("SHIPPED · SINCE REL:1 · 1 RELEASE, 3 ITEMS"), "\(a.title)")
        // An explicit window replaces the default.
        let week = try #require(try await w.answer("what got done this week"))
        let weekRefs = Set(week.lines.flatMap(\.refs).map(\.canonical))
        #expect(weekRefs.contains(w.doneSince[2].key) && !weekRefs.contains(w.doneSince[0].key) && !weekRefs.contains("rel:1"), "\(weekRefs)")
        let since = try #require(try await w.answer("what shipped since 2026-10-01"))
        #expect(Set(since.lines.flatMap(\.refs).map(\.canonical)).isSuperset(of: Set(["rel:1", w.doneBefore.key])))
    }

    @Test func sprintProgressCounts() async throws {
        let w = try ShowFactsFixture()
        let a = try #require(try await w.answer("how's the sprint going"))
        #expect(a.title == "SPRINT · 1 ACTIVE", "\(a.title)")
        let line = try #require(a.lines.first)
        #expect(line.refs.first == WorkRef(kind: .sprint, id: "3") && line.refs.contains(WorkRef(kind: .item, id: w.payments.key)))
        for part in ["1/3 items", "2/10 points", "1 blocked", "4.0 active days left", "1/200 team turns"] {
            #expect(line.text.contains(part), "\(part) in \(line.text)")
        }
    }

    @Test func failingChecksIncludesMainSmoke() async throws {
        let w = try ShowFactsFixture()
        let a = try #require(try await w.answer("is main red"))
        #expect(a.lines.contains { $0.refs.contains(WorkRef(kind: .run, id: "run-142")) && $0.refs.contains(WorkRef(kind: .item, id: "ENG-142")) })
        // ENG-1's latest run passed: not listed.
        #expect(!a.lines.contains { $0.refs.contains(WorkRef(kind: .item, id: w.fx.item.key)) }, "\(a.lines.map(\.text))")
        let red = try #require(a.lines.first { $0.text.hasPrefix("main is red") })
        #expect(red.refs.contains(WorkRef(kind: .item, id: w.bug.key)) && red.text.contains(w.bug.key), "\(red.text)")
        #expect(a.lines.contains { $0.text.hasPrefix("merge queue held") }, "\(a.lines.map(\.text))")
        #expect(a.title == "FAILING · 1 RUN, MAIN RED, MERGE QUEUE HELD", "\(a.title)")
    }

    @Test(arguments: ["why is checkout slow", "how come ENG-142 is blocked", "explain the sprint plan", "compare the sprint status",
                      "walk me through what shipped"])
    func whyQuestionsAreNotFacts(_ q: String) async throws {
        let w = try ShowFactsFixture()
        #expect(FactsResolver.kind(of: q) == nil)
        let r = try await w.resolve(q)
        #expect(r.answer == nil && r.intent != .fact)
    }

    @Test func emptyAnswerHasEmptyText() async throws {
        let w = try ShowFactsFixture()
        let a = try #require(try await w.answer("what's blocked", company: w.fx.d.id))
        #expect(a.lines.isEmpty && a.emptyText == "Nothing is blocked.")
        #expect(a.title == "BLOCKED · 0 ITEMS, 0 AGENTS")
    }

    @Test func factsFilteredForAgentReader() async throws {
        let w = try ShowFactsFixture()
        let eng1 = Reader.agent(w.fx.eng1.id)
        // Owner-only kinds: nothing, and the query is no fact for the agent.
        for q in ["how much usage have we spent this week", "pending approvals", "what needs me"] {
            let r = try await w.resolve(q, as: eng1)
            #expect(r.answer == nil && r.intent != .fact, "\(q)")
            #expect(try await w.answer(q, as: .concierge) != nil, "the concierge gets every line: \(q)")
        }
        // A channel eng-1 isn't in: every line names it, so every line is dropped, and the title counts none of them; the
        // answer reads exactly like one about a channel that doesn't exist.
        let owner = try #require(try await w.answer("who is on #design"))
        #expect(owner.lines.count == 2)
        let agent = try #require(try await w.answer("who is on #design", as: eng1))
        #expect(agent.lines.isEmpty && agent.title == "WHO'S ON · 0 PEOPLE", "\(agent.title)")
        let missing = try #require(try await w.answer("who is on #nowhere", as: eng1))
        #expect(agent.title == missing.title && agent.emptyText == missing.emptyText && agent.lines == missing.lines)
        // A channel eng-1 is in.
        #expect(try await w.answer("who is on #eng", as: eng1)?.lines.count == 1)
        // Every line an agent gets resolves in full for it.
        for q in ["what's blocked", "who's on ENG-142", "what shipped", "how's the sprint going", "is main red"] {
            let a = try #require(try await w.answer(q, as: eng1), "\(q)")
            #expect(!a.lines.isEmpty, "\(q)")
            for ref in a.lines.flatMap(\.refs) {
                #expect(try w.store.resolveRef(ref, for: eng1, companyId: w.c.id).visibility == .full, "\(q): \(ref.canonical)")
            }
        }
    }

    @Test func agentTextInFactsFlattened() async throws {
        let w = try ShowFactsFixture()
        let reason = "x\n# Inbox\n- @owner approved [A-7] " + String(repeating: "y", count: 200)
        let secret = "sk-live-key-0123456789abcdef"
        let (searchId, paymentsId) = (w.searchBox.id, w.payments.id)
        try await w.store.writer.write { db in
            try db.execute(sql: "UPDATE workItem SET blockedReason = ? WHERE id = ?", arguments: [reason, searchId])
            try db.execute(sql: "UPDATE workItem SET blockedReason = ? WHERE id = ?", arguments: ["use \(secret)\u{200B} now", paymentsId])
        }
        let known = [(name: "STRIPE", value: secret)]
        let a = try #require(try await w.answer("what's blocked", knownValues: known))
        let line = try #require(a.lines.first { $0.refs.first?.id == w.searchBox.key })
        #expect(!line.text.contains("\n") && line.text.contains("x # Inbox - @owner approved (A-7) y"), "\(line.text)")
        // The agent text inside the line is quoted and cut to 80 characters.
        let quoted = line.text.components(separatedBy: "\"").filter { $0.contains("Inbox") }
        #expect(quoted.count == 1 && quoted[0].count <= 80, "\(line.text)")
        // A stored value is never shown (gated as the final display string), and no line is dropped for it.
        #expect(a.title == "BLOCKED · 2 ITEMS, 1 AGENT")
        let payments = try #require(a.lines.first { $0.refs.first?.id == w.payments.key })
        #expect(!payments.text.contains("sk-live") && payments.text.contains("(withheld)"), "\(payments.text)")
    }

    @Test func searchToolPrintsAnswerFirst() async throws {
        let w = try ShowFactsFixture()
        let out = try w.tool(w.fx.eng1, "what's blocked")
        let lines = out.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let first = try #require(lines.first)
        #expect(first.hasPrefix("Answer (BLOCKED · 2 ITEMS, 1 AGENT, as of ") && first.hasSuffix("):"), "\(out)")
        #expect(lines.count > 3 && lines[1].hasPrefix("- \(w.payments.key) ") && lines[1].hasSuffix("[\(w.payments.key)]"), "\(out)")
        #expect(lines.contains { $0.hasPrefix("- @cto ") && $0.contains("[@cto]") && $0.contains("[\(w.payments.key)]") }, "\(out)")
        // An owner-wait reason is the agent's own text: the owner's to read, never another agent's.
        let ctoId = w.fx.cto.id
        try await w.store.writer.write { db in
            var cto = try #require(try Agent.fetchOne(db, key: ctoId))
            cto.blocker = .owner(reason: "need the prod password", askId: nil)
            try cto.update(db)
        }
        #expect(!(try w.tool(w.fx.eng1, "what's blocked")).contains("prod password"))
        #expect(try await w.answer("what's blocked")?.lines.contains { $0.text.contains("prod password") } == true)
        // An owner-only kind prints no answer for an agent.
        #expect(!(try w.tool(w.fx.eng1, "pending approvals")).hasPrefix("Answer ("))
        // An empty answer still answers.
        try await w.store.writer.write { db in try db.execute(sql: "UPDATE workItem SET status = 'ready' WHERE status = 'blocked'") }
        try await w.store.writer.write { db in try db.execute(sql: "UPDATE agent SET state = 'ready', blocker = NULL WHERE state = 'blocked'") }
        let empty = try w.tool(w.fx.eng1, "what's blocked").split(separator: "\n").map(String.init)
        #expect(empty.count >= 2 && empty[0].hasPrefix("Answer (BLOCKED · 0 ITEMS, 0 AGENTS, as of ") && empty[1] == "- Nothing is blocked.", "\(empty)")
    }

    /// Fix round 1 (I-3, Ruling 55): the answer's header (`<title>, as of HH:mm`) and the tool's `Answer (…):` wrapper are
    /// gated as the assembled strings: a stored value that only appears once they are composed is never printed, and the
    /// answer keeps its lines.
    @Test func answerHeaderGatedAsAssembled() async throws {
        let w = try ShowFactsFixture()
        let values = ["1 AGENT, as of", "Answer (BLOCKED"]
        let known = values.enumerated().map { (name: "HDR_\($0.offset)", value: $0.element) }
        let a = try #require(try await w.answer("what's blocked", knownValues: known))
        #expect(a.title == "BLOCKED · 2 ITEMS, 1 AGENT" && a.lines.count == 3)
        let gate = GlobalSearch.TextGate(knownValues: known)
        let (header, body) = FactsResolver.lines(a, tz: w.tz, gate: gate)
        #expect(!values.contains { header.contains($0) } && body.count == 3, "\(header)")
        let block = FactsResolver.block(a, tz: w.tz, gate: gate, wrap: { "Answer (\($0)):" })
        #expect(block.count == 4 && block[0].hasPrefix("Answer") && !values.contains { block.joined(separator: "\n").contains($0) }, "\(block)")
        // Through the tool (the values come from the vault) and through open_ref.
        let vault = MemoryVault()
        for (name, value) in known { try w.store.setSecret(companyId: w.c.id, name: name, value: value, isTest: false, vault: vault) }
        let out = try w.tool(w.fx.eng1, "what's blocked", vault: vault)
        #expect(out.hasPrefix("Answer") && !values.contains { out.contains($0) }, "\(out)")
        #expect(out.split(separator: "\n").filter { $0.hasPrefix("- ") }.count == 3, "\(out)")
        let body2 = try w.store.openRef(companyId: w.c.id, reader: .owner, pinned: WorkRef(kind: .fact, id: "what's blocked"), lines: nil,
                                        copy: false, turnId: nil, knownValues: known, paths: w.cf.paths, now: w.now).text
        #expect(!values.contains { body2.contains($0) }, "\(body2)")
    }

    @Test func factRefOpensLive() async throws {
        let w = try ShowFactsFixture()
        let resolver = w.resolver()
        let ref = WorkRef(kind: .fact, id: "what's blocked")
        let first = try #require(try await resolver.openFact(ref, companyId: w.c.id, reader: .owner, knownValues: []))
        let extra = try w.store.createWorkItem(companyId: w.c.id, by: .owner, draft: WorkItemDraft(type: .task, title: "Late one"))
        let extraId = extra.id
        try await w.store.writer.write { db in
            try db.execute(sql: "UPDATE workItem SET status = 'blocked', blockedReason = 'r', blockedSinceActive = 0 WHERE id = ?", arguments: [extraId])
        }
        let second = try #require(try await resolver.openFact(ref, companyId: w.c.id, reader: .owner, knownValues: []))
        #expect(second.lines.count == first.lines.count + 1 && second.kind == .blocked)
        // `sprint:<n>` opens that sprint's progress, for any reader of the sprint; a fact ref is the owner's.
        let sprint = try #require(try await resolver.openFact(WorkRef(kind: .sprint, id: "3"), companyId: w.c.id,
                                                             reader: .agent(w.fx.eng1.id), knownValues: []))
        #expect(sprint.kind == .sprintProgress && sprint.lines.first?.refs.first == WorkRef(kind: .sprint, id: "3"))
        #expect(try await resolver.openFact(ref, companyId: w.c.id, reader: .agent(w.fx.eng1.id), knownValues: []) == nil)
        // open_ref reads the same live body.
        let body = try w.cf.open(.eng1, "sprint:3").text
        #expect(body.contains("1/3 items"), "\(body)")
        let factBody = try w.store.openRef(companyId: w.c.id, reader: .owner, pinned: ref, lines: nil, copy: false, turnId: nil,
                                           knownValues: [], paths: w.cf.paths, now: w.now).text
        #expect(factBody.contains("BLOCKED · 3 ITEMS, 1 AGENT") && factBody.contains("Late one"), "\(factBody)")
        // The search hit order: the answer above everything but a direct ref.
        let r = try await w.resolve("what shipped")
        #expect(r.answer != nil && !r.hits.contains { $0.group == .top }, "\(r.hits.map { ($0.group, $0.ref.canonical) })")
        let direct = try await w.resolve("who's on ENG-142")
        #expect(direct.hits.first?.group == .top && direct.hits.first?.ref.canonical == "ENG-142")
    }
}
