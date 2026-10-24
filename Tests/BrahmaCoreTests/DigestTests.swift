import Testing
import Foundation
import GRDB
@testable import BrahmaCore

@Suite struct DigestTests {
    private static func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
    private static let la = TimeZone(identifier: "America/Los_Angeles")!
    private static let utc = TimeZone(identifier: "UTC")!

    private struct W {
        let store: Store, company: Company, paths: BrahmaPaths
        let now = DigestTests.date("2026-10-21T15:00:00Z")   // a Wednesday

        init() throws {
            store = try Store.inMemory()
            try store.setOwnerTimeZone("America/Los_Angeles")
            let root = try tempDir()
            paths = BrahmaPaths(home: root.appending(path: "home"), workspaces: root.appending(path: "ws"))
            company = try store.createCompany(name: "Acme", goal: "Ship it", workspacesRoot: paths.workspaces)
        }

        func hire(_ name: String, team: String? = nil) throws -> Agent {
            try store.hire(companyId: company.id, name: name, role: "engineer", model: "sonnet", team: team)
        }

        @discardableResult
        func item(_ title: String, _ status: WorkItemStatus = .backlog, reason: String? = nil, doneAt: Date? = nil) throws -> WorkItem {
            let i = try store.createWorkItem(companyId: company.id, by: .owner, draft: WorkItemDraft(type: .task, title: title), now: now)
            try store.writer.write { db in
                try db.execute(sql: "UPDATE workItem SET status = ?, blockedReason = ?, doneAt = ? WHERE id = ?",
                               arguments: [status.rawValue, reason, doneAt, i.id])
            }
            return i
        }

        @discardableResult
        func ask(_ title: String, kind: AskKind = .other) throws -> Ask {
            try store.propose(companyId: company.id, by: .system, kind: kind, category: kind == .other ? "general" : nil, title: title, summary: "why", viaOwner: true, now: now)
        }

        func turn(_ agent: Agent, at: Date, kind: TurnKind = .work, mode: String? = nil, itemId: String? = nil, costLE: Double? = nil,
                  usd: Double? = nil, tokens: Int = 0, outcome: TurnOutcome = .succeeded) throws {
            var t = Turn(id: UUID().uuidString, agentId: agent.id, companyId: company.id, startedAt: at, endedAt: at.addingTimeInterval(60),
                         outcome: outcome, summary: nil, costUSD: usd)
            t.kind = kind; t.mode = mode; t.itemId = itemId; t.costLE = costLE; t.inputTokens = tokens
            try store.writer.write { db in try t.insert(db) }
        }

        func build(since: Date? = nil, tz: TimeZone = DigestTests.la) throws -> Digest {
            try DigestBuilder.build(store: store, companyId: company.id, since: since ?? now.addingTimeInterval(-86_400), now: now, tz: tz)
        }

        func runDailyJob() async throws {
            try SystemTimers.ensure(store: store, now: now)
            let timer = try #require(try store.timers(companyId: nil).first { $0.name == "digest.daily" && $0.companyId == company.id })
            try await DigestJobs.daily(TimerContext(store: store, paths: paths, timer: timer, now: now, blocking: Blocking()))
        }
    }

    @Test func digestSectionsAndCounts() throws {
        let w = try W()
        let web = try w.hire("web-1", team: "web")
        let ops = try w.hire("ops-1", team: "ops")
        let stale = try w.item("Stale thing")                    // created at active 0, never touched again
        try w.store.advanceActive(companyId: w.company.id, by: 8 * 86_400)
        let done1 = try w.item("Shipped", .done, doneAt: w.now.addingTimeInterval(-3600))
        try w.item("Working", .inProgress)
        try w.item("Waiting", .inReview)
        try w.item("Stuck", .blocked, reason: "needs a database")
        try w.ask("Pick a name", kind: .other)
        try w.ask("Approve the PRD", kind: .prd)
        try w.turn(ops, at: w.now.addingTimeInterval(-3600), usd: 0.5, tokens: 2500)    // ops worked today; web did not

        let d = try w.build()
        #expect(!d.isEmpty)
        #expect(d.notificationBody == "2 need you · 1 done · 1 turns this week")
        let md = d.markdown
        #expect(md.hasPrefix("# Acme — Wed 21 Oct\n"))
        let sections = ["## Needs you", "## Progress", "## This week"].compactMap { md.range(of: $0)?.lowerBound }
        #expect(sections.count == 3 && sections == sections.sorted())
        #expect(md.contains("**Decision** (1)") && md.contains("**Idea / PRD** (1)"))
        #expect(md.contains("- Done: 1 (\(done1.key))"))
        #expect(md.contains("- In progress: 1"))
        #expect(md.contains("- Awaiting review: 1"))
        #expect(md.contains("- Blocked: 1 — ") && md.contains("needs a database"))
        // The stale item saw no event for 7+ active days; the items created after the clock moved did.
        #expect(md.contains("- Untouched 7+ active days: 1 (\(stale.key))"))
        #expect(md.contains("- Team gone quiet: web"))
        #expect(!md.contains("Team gone quiet: ops"))
        #expect(md.contains("- 1 turns · 2k tokens · $0.50"))
        _ = web
    }

    @Test func digestWithoutAsksSaysNothingWaiting() throws {
        let w = try W()
        _ = try w.item("Working", .inProgress)
        let md = try w.build().markdown
        #expect(md.contains("Nothing waiting on you."))
        #expect(!md.contains("## Needs you"))
    }

    @Test func weekStartsMondayInOwnerTZ() throws {
        let now = Self.date("2026-10-26T05:00:00Z")           // Mon 05:00 UTC, still Sunday evening in Los Angeles
        #expect(DigestBuilder.weekStart(now: now, tz: Self.utc) == Self.date("2026-10-26T00:00:00Z"))
        #expect(DigestBuilder.weekStart(now: now, tz: Self.la) == Self.date("2026-10-19T07:00:00Z"))   // Mon 00:00 PDT

        let w = try W()
        let a = try w.hire("web-1")
        try w.turn(a, at: Self.date("2026-10-25T20:00:00Z"))   // Sunday afternoon in Los Angeles
        func turns(_ tz: TimeZone) throws -> Int {
            try DigestBuilder.build(store: w.store, companyId: w.company.id, since: now.addingTimeInterval(-86_400), now: now, tz: tz).weekTurns
        }
        #expect(try turns(Self.la) == 1)
        #expect(try turns(Self.utc) == 0)
    }

    @Test func agentTextEscaped() throws {
        let w = try W()
        try w.ask("[click me](http://evil.example) *bold*\n# Fake heading | `code`")
        try w.item("Hostile", .blocked, reason: "<b>see</b>\n## Injected")
        let md = try w.build().markdown
        #expect(md.contains("\\[click me\\](http://evil.example) \\*bold\\* \\# Fake heading \\| \\`code\\`"))
        #expect(md.contains("\\<b\\>see\\</b\\> \\#\\# Injected"))
        #expect(!md.split(separator: "\n").contains { $0.hasPrefix("# Fake") || $0.hasPrefix("## Injected") })
        #expect(MarkdownEscape.inline("a\r\nb\tc") == "a b c")
        #expect(MarkdownEscape.inline(String(repeating: "x", count: 500)).count == MarkdownEscape.defaultLimit + 1)
    }

    @Test func emptyDayStoresNothing() async throws {
        let w = try W()
        #expect(try w.build().isEmpty)
        try await w.runDailyJob()
        #expect(try w.store.latestDigest(companyId: w.company.id) == nil)
        #expect(try w.store.allNotices().allSatisfy { $0.kind != .digest })
    }

    @Test func dailyJobStoresAndNotifies() async throws {
        let w = try W()
        try w.ask("Pick a name")
        _ = try w.item("Shipped", .done, doneAt: w.now.addingTimeInterval(-60))
        try await w.runDailyJob()
        let stored = try #require(try w.store.latestDigest(companyId: w.company.id))
        #expect(stored.periodEnd == w.now)
        #expect(stored.periodStart == w.now.addingTimeInterval(-86_400))     // no earlier digest: the last 24 hours
        #expect(stored.markdown.contains("Pick a name"))
        #expect(try w.store.lastDigestEnd(companyId: w.company.id) == w.now)
        let notice = try #require(try w.store.allNotices().first { $0.kind == .digest })
        #expect(notice.title == "Acme daily digest")
        #expect(notice.body == "1 need you · 1 done · 0 turns this week")
        #expect(notice.companyId == w.company.id)
    }

    @Test func previewDoesNotStore() throws {
        let w = try W()
        try w.ask("Pick a name")
        let preview = try w.build()
        #expect(!preview.isEmpty && preview.markdown.contains("Pick a name"))
        #expect(try w.store.latestDigest(companyId: w.company.id) == nil)
        #expect(try w.store.allNotices().isEmpty)
        // Only an explicit save stores it, and later digests start where it ended.
        try w.store.saveDigest(companyId: w.company.id, digest: preview, now: w.now)
        #expect(try w.store.lastDigestEnd(companyId: w.company.id) == w.now)
    }

    @Test func digestShowsModeSplitAndUltraLine() throws {
        let w = try W()
        let a = try w.hire("web-1")
        let item = try w.item("Big one", .inProgress)
        let t = w.now.addingTimeInterval(-7200)
        try w.turn(a, at: t, mode: "quick", costLE: 2)
        try w.turn(a, at: t, mode: "standard", costLE: 6)
        try w.turn(a, at: t, mode: "deep", costLE: 2)
        var d = try w.build()
        #expect(d.markdown.contains("- By mode: Quick 20% · Standard 60% · Deep 20% · Plan 0% · Ultra 0%"))
        #expect(!d.markdown.contains("- Ultra:"))                              // no Ultra runs: the line is omitted

        try w.turn(a, at: t, mode: "ultra", itemId: item.id, costLE: 3)
        try w.turn(a, at: t.addingTimeInterval(60), mode: "ultra", itemId: item.id, costLE: 1.5, outcome: .interrupted)
        d = try w.build()
        #expect(d.markdown.contains("Ultra 31%"))                              // 4.5 of 14.5 list-equivalent dollars
        #expect(d.markdown.contains("- Ultra: 2 runs, $4.50 LE, \(item.key) (interrupted)"))
        // A digest that starts after those runs does not list them again.
        d = try w.build(since: w.now.addingTimeInterval(-60))
        #expect(!d.markdown.contains("- Ultra:"))
        // No costed turns, no split line.
        let empty = try W()
        #expect(!(try empty.build().markdown.contains("By mode")))
    }
}
