import Testing
import Foundation
@testable import BrahmaCore
@testable import BrahmaAppModel

@Suite struct FormattingTests {
    let day = Date(timeIntervalSince1970: TimeInterval(1_799_971_200)) // 00:00 GMT
    func at(_ h: Int, _ m: Int = 0) -> Date { day.addingTimeInterval(Double(h * 3600 + m * 60)) }

    func agent(_ state: AgentState, blocker: Blocker? = nil) -> Agent {
        Agent(id: UUID().uuidString, companyId: "c", name: "a", role: "r", model: "m", sessionId: "s",
              sessionStarted: false, state: state, blocker: blocker, requestedBlocker: nil, paused: false,
              readySince: nil, createdAt: day)
    }
    func info(status: String = "allowed", f: Double?, s: Double?, resets: Date?, observed: Date? = nil) -> RateLimitInfo {
        RateLimitInfo(status: status, resetsAt: resets, rateLimitType: nil, isUsingOverage: false,
                      fiveHourUtilization: f, sevenDayUtilization: s, observedAt: observed ?? at(9),
                      fiveHourResetsAt: nil, sevenDayResetsAt: nil)
    }

    @Test func stateCountsLine() {
        let c = StateCounts([agent(.running), agent(.ready), agent(.ready), agent(.blocked), agent(.sleeping), agent(.killed)])
        #expect(c.line == "1 running · 2 ready · 1 blocked · 1 sleeping")
        #expect(c.killed == 1)
        #expect(c.total == 6)
    }

    @Test func usageLineFormats() {
        let now = at(10)
        #expect(UsageText.line(nil, now: now, timeZone: .gmt) == "Usage: no data yet")
        #expect(UsageText.line(info(f: 0.38, s: 0.12, resets: at(14)), now: now, timeZone: .gmt) == "5h 38% · 7d 12% · resets 14:00")
        #expect(UsageText.line(info(f: nil, s: nil, resets: nil), now: now, timeZone: .gmt) == "5h n/a · 7d n/a")
        #expect(UsageText.line(info(f: 0.38, s: 0.12, resets: at(8)), now: now, timeZone: .gmt) == "5h 38% · 7d 12%")
    }

    @Test func usageGateLine() {
        let now = at(10)
        let rejected = info(status: "rejected", f: 0.5, s: 0.5, resets: at(14))
        #expect(UsageText.gateLine(rejected, mode: .low, now: now, timeZone: .gmt) == "Usage limit — new turns resume at 14:00")
        var hot = info(f: 0.85, s: 0.1, resets: nil, observed: at(10))
        hot.fiveHourResetsAt = at(13)
        #expect(UsageText.gateLine(hot, mode: .low, now: now, timeZone: .gmt) != nil)
        #expect(UsageText.gateLine(hot, mode: .max, now: now, timeZone: .gmt) == nil)
        #expect(UsageText.gateLine(info(f: 0.1, s: 0.1, resets: nil), mode: .low, now: now, timeZone: .gmt) == nil)
        #expect(UsageText.gateLine(nil, mode: .low, now: now, timeZone: .gmt) == nil)
    }

    @Test func blockerText() {
        let handles = ["cto-id": "cto"]
        func d(_ b: Blocker?) -> String { BlockerText.describe(b, handles: handles, timeZone: .gmt) }
        #expect(d(.agent("cto-id")) == "Waiting on @cto")
        #expect(d(.owner(reason: "key")) == "Waiting on you: key")
        #expect(d(.usageLimit(until: at(14))) == "Usage limit until 14:00")
        #expect(d(.turnBudget(until: at(15))) == "Turn budget until 15:00")
        #expect(d(.retry(until: at(16), failures: 2)) == "Retrying after failure 2 at 16:00")
        #expect(d(nil) == "")
    }

    @Test func companyInitials() {
        #expect(CompanyInitials.of("Acme Labs") == "AL")
        #expect(CompanyInitials.of("acme") == "A")
        #expect(CompanyInitials.of("  ") == "?")
        #expect(CompanyInitials.of("über cool co") == "ÜC")
    }

    @Test func channelTitles() {
        func ch(_ n: String, _ k: ChannelKind) -> Channel { Channel(id: n, companyId: "c", name: n, kind: k, createdAt: day) }
        #expect(ChannelTitle.title(ch("general", .channel)) == "#general")
        #expect(ChannelTitle.title(ch("dm:ceo:owner", .dm)) == "@ceo")
        #expect(ChannelTitle.title(ch("dm:ceo:cto", .dm)) == "@ceo · @cto")
    }

    @Test func timeText() {
        let d = at(9, 5).addingTimeInterval(7)
        #expect(TimeText.hm(d, timeZone: .gmt) == "09:05")
        #expect(TimeText.hms(d, timeZone: .gmt) == "09:05:07")
    }

    @Test func formValidation() {
        #expect(CompanyForm(name: " ", goal: "g").validate() == "Name is required")
        #expect(CompanyForm(name: "n", goal: " ").validate() == "Goal is required")
        #expect(CompanyForm(name: "n", goal: "g").validate() == nil)
    }
}
