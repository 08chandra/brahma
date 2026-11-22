import Testing
import Foundation
@testable import BrahmaCore

/// Plan C Task C4a: the Show bar's filters, parsed by plain code from the stripped query. Now is Wednesday 2026-10-21 15:00
/// in the owner's `America/Los_Angeles`.
@Suite(.scratch) struct SearchFiltersTests {
    static let tz = TimeZone(identifier: "America/Los_Angeles")!
    static func date(_ y: Int, _ m: Int, _ d: Int, _ h: Int = 0) -> Date {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = tz
        return cal.date(from: DateComponents(year: y, month: m, day: d, hour: h))!
    }
    static let now = date(2026, 10, 21, 15)

    static func parse(_ q: String, sprint: Date? = nil) -> (rest: String, filters: SearchFilters) {
        SearchFilters.parse(q, now: now, tz: tz, activeSprintStart: sprint)
    }

    @Test(arguments: [
        ("blocked by @eng-3 this week", "", ["BLOCKED", "BY @ENG-3", "THIS WEEK"]),
        ("kind:commit checkout", "checkout", ["KIND:COMMIT"]),
        ("in:#eng flaky test", "flaky test", ["IN #ENG"]),
        ("release since 2026-10-01", "release", ["SINCE 2026-10-01"]),
        ("@eng-3", "@eng-3", [])])
    func filtersParse(_ q: String, _ rest: String, _ chips: [String]) {
        let parsed = Self.parse(q)
        #expect(parsed.rest == rest)
        #expect(parsed.filters.chips == chips)
    }

    @Test func thisWeekStartsMondayOwnerTZ() {
        let f = Self.parse("this week").filters
        let window = try? #require(f.window)
        #expect(window?.start == Self.date(2026, 10, 19))
        #expect(window?.end == Self.now)
        #expect(window?.label == "THIS WEEK")
        // Last week: the Monday before, up to this Monday.
        let last = Self.parse("last week").filters.window
        #expect(last?.start == Self.date(2026, 10, 12) && last?.end == Self.date(2026, 10, 19) && last?.label == "LAST WEEK")
        #expect(Self.parse("today").filters.window?.start == Self.date(2026, 10, 21))
        let y = Self.parse("yesterday").filters.window
        #expect(y?.start == Self.date(2026, 10, 20) && y?.end == Self.date(2026, 10, 21))
        #expect(Self.parse("this month").filters.window?.start == Self.date(2026, 10, 1))
        #expect(Self.parse("since 2026-10-01").filters.window?.start == Self.date(2026, 10, 1))
    }

    @Test func bareStatusWordSetsKinds() {
        let (rest, f) = Self.parse("blocked")
        #expect(rest == "" && f.status == "blocked")
        #expect(f.kinds == [.item, .agent, .ask, .run])
        // Not the whole query: the status only.
        let mixed = Self.parse("blocked checkout")
        #expect(mixed.rest == "checkout" && mixed.filters.status == "blocked" && mixed.filters.kinds.isEmpty)
        #expect(Self.parse("in review").filters.status == "in review")
        #expect(Self.parse("is:done payments").filters.status == "done")
        #expect(Self.parse("is:done payments").rest == "payments")
        #expect(Self.parse("is:nonsense").rest == "is:nonsense")
    }

    @Test func lastNDaysCapped() {
        let capped = Self.parse("last 900 days")
        #expect(capped.filters.window == nil && capped.rest == "last 900 days")
        let week = Self.parse("last 7 days checkout")
        #expect(week.rest == "checkout")
        #expect(week.filters.window?.label == "LAST 7 DAYS")
        #expect(week.filters.window?.start == Self.date(2026, 10, 14, 15))
        #expect(Self.parse("last 365 days").filters.window != nil)
    }

    @Test func kindAliasesActorsAndChannels() {
        #expect(Self.parse("kind:msg x").filters.kinds == [.message])
        #expect(Self.parse("kind:decision kind:doc kind:page kind:mem kind:rel").filters.kinds == [.ask, .kb, .memory, .release])
        #expect(Self.parse("kind:").rest == "kind:")
        #expect(Self.parse("kind:bogus x").rest == "kind:bogus x")
        #expect(Self.parse("from @qa-2 hello").filters.actor == "qa-2")
        #expect(Self.parse("@eng-3's commits").filters.actor == "eng-3")
        #expect(Self.parse("by @owner").filters.actor == "owner")
        #expect(Self.parse("by @owner").filters.chips == ["BY @OWNER"])
        // `by @` still being typed: neither a filter nor text.
        #expect(Self.parse("by @").rest == "" && Self.parse("by @").filters.isEmpty)
        #expect(Self.parse("by @Bad!").rest == "by @Bad!")
        #expect(Self.parse("in:#eng").filters.channel == "eng")
        #expect(Self.parse("since 2026-13-40").filters.window == nil)
        // `this sprint` needs an active sprint.
        #expect(Self.parse("this sprint").filters.window == nil)
        let sprint = Self.parse("this sprint", sprint: Self.date(2026, 10, 15))
        #expect(sprint.filters.window?.start == Self.date(2026, 10, 15) && sprint.filters.chips == ["THIS SPRINT"])
        // Codable round trip (chips are derived).
        let f = Self.parse("blocked by @eng-3 this week kind:item in:#eng").filters
        let back = try? JSONDecoder().decode(SearchFilters.self, from: JSONEncoder().encode(f))
        #expect(back == f)
        #expect(f.chips == ["BLOCKED", "BY @ENG-3", "THIS WEEK", "KIND:ITEM", "IN #ENG"])
    }

    @Test func normalizeStripsFillerControlsAndLength() {
        #expect(ShowQuery.normalize("show me the landing page on mobile").stripped == "landing page mobile")
        #expect(ShowQuery.normalize("Can I see the checkout?").stripped == "checkout")
        #expect(ShowQuery.normalize("search for flaky tests please").stripped == "flaky tests")
        #expect(ShowQuery.normalize("\u{202E}x").normalized == "x")
        #expect(ShowQuery.normalize("a\u{0007}b").normalized == "ab")
        #expect(ShowQuery.normalize(String(repeating: "a", count: 5000)).normalized.count == ShowQuery.maxQuery)
        #expect(ShowQuery.normalize("???").stripped == "")
        #expect(ShowQuery.normalize("show me").stripped == "")
        // Filler only as whole words.
        #expect(ShowQuery.normalize("theme options").stripped == "theme options")
    }
}
