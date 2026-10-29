import Testing
import Foundation
@testable import BrahmaCore

@Suite(.scratch) struct TimerScheduleTests {
    let ny = TimeZone(identifier: "America/New_York")!

    func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    @Test func dailyNextIsTodayOrTomorrow() {
        let schedule = TimerSchedule.daily(hour: 8, minute: 0)
        // 07:00 New York (EDT) -> 08:00 the same day; 09:00 -> 08:00 the next day.
        #expect(schedule.next(after: date("2026-06-10T07:00:00-04:00"), timeZone: ny) == date("2026-06-10T08:00:00-04:00"))
        #expect(schedule.next(after: date("2026-06-10T09:00:00-04:00"), timeZone: ny) == date("2026-06-11T08:00:00-04:00"))
        // Strictly after: the instant itself does not count.
        #expect(schedule.next(after: date("2026-06-10T08:00:00-04:00"), timeZone: ny) == date("2026-06-11T08:00:00-04:00"))
        // The same instant is a different local time elsewhere.
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        #expect(schedule.next(after: date("2026-06-10T07:00:00-04:00"), timeZone: tokyo) == date("2026-06-11T08:00:00+09:00"))
    }

    @Test func dailyAcrossDSTFiresOnce() {
        // Fall back 2026-11-01: 01:30 happens twice in New York. The timer fires at the first one only.
        let fall = TimerSchedule.daily(hour: 1, minute: 30)
        let first = fall.next(after: date("2026-11-01T00:00:00-04:00"), timeZone: ny)
        #expect(first == date("2026-11-01T01:30:00-04:00"))
        let second = fall.next(after: first!, timeZone: ny)
        #expect(second == date("2026-11-02T01:30:00-05:00"))

        // Spring forward 2027-03-14: 02:30 does not exist; it fires at 03:00 once, then 02:30 on the 15th.
        let spring = TimerSchedule.daily(hour: 2, minute: 30)
        let gap = spring.next(after: date("2027-03-14T00:00:00-05:00"), timeZone: ny)
        #expect(gap == date("2027-03-14T03:00:00-04:00"))
        #expect(spring.next(after: gap!, timeZone: ny) == date("2027-03-15T02:30:00-04:00"))
    }

    @Test func weekly() {
        // Weekday uses Calendar numbering: 1 is Sunday, 2 is Monday.
        let schedule = TimerSchedule.weekly(weekday: 2, hour: 9, minute: 0)
        // Wednesday 2026-06-10 -> Monday 2026-06-15.
        #expect(schedule.next(after: date("2026-06-10T12:00:00-04:00"), timeZone: ny) == date("2026-06-15T09:00:00-04:00"))
        // Monday 08:00 -> that morning; Monday 09:00 -> the next Monday.
        #expect(schedule.next(after: date("2026-06-15T08:00:00-04:00"), timeZone: ny) == date("2026-06-15T09:00:00-04:00"))
        #expect(schedule.next(after: date("2026-06-15T09:00:00-04:00"), timeZone: ny) == date("2026-06-22T09:00:00-04:00"))
    }

    @Test func everyClampsTo60() {
        let t = date("2026-06-10T12:00:00-04:00")
        #expect(TimerSchedule.every(seconds: 1).next(after: t, timeZone: ny) == t.addingTimeInterval(60))
        #expect(TimerSchedule.every(seconds: -5).next(after: t, timeZone: ny) == t.addingTimeInterval(60))
        #expect(TimerSchedule.every(seconds: 3600).next(after: t, timeZone: ny) == t.addingTimeInterval(3600))
    }

    @Test func onceExpires() {
        let at = date("2026-06-10T12:00:00-04:00")
        let schedule = TimerSchedule.once(at: at)
        #expect(schedule.next(after: at.addingTimeInterval(-1), timeZone: ny) == at)
        #expect(schedule.next(after: at, timeZone: ny) == nil)
        #expect(schedule.next(after: at.addingTimeInterval(3600), timeZone: ny) == nil)
    }

    @Test func codableRoundTrip() throws {
        let all: [TimerSchedule] = [.once(at: date("2026-06-10T12:00:00-04:00")), .daily(hour: 3, minute: 30),
                                    .weekly(weekday: 7, hour: 1, minute: 2), .every(seconds: 90)]
        for s in all {
            #expect(try JSONDecoder().decode(TimerSchedule.self, from: JSONEncoder().encode(s)) == s)
        }
        let actions: [TimerAction] = [.job("backup.hourly"), .turn(agentId: "a1", prompt: "wake up")]
        for a in actions {
            #expect(try JSONDecoder().decode(TimerAction.self, from: JSONEncoder().encode(a)) == a)
        }
    }
}
