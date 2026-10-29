import Testing
import Foundation
@testable import BrahmaCore

@Suite(.scratch) struct QuietHoursTests {
    let ny = TimeZone(identifier: "America/New_York")!

    func date(_ iso: String) -> Date {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: iso)!
    }

    @Test func wrapsMidnight() throws {
        let q = QuietHours(startHour: 22, startMinute: 0, endHour: 8, endMinute: 0)
        for (iso, quiet) in [
            ("2026-06-10T21:59:00-04:00", false), ("2026-06-10T22:00:00-04:00", true), ("2026-06-10T23:59:00-04:00", true),
            ("2026-06-11T00:00:00-04:00", true), ("2026-06-11T07:59:00-04:00", true), ("2026-06-11T08:00:00-04:00", false),
            ("2026-06-11T12:00:00-04:00", false),
        ] {
            #expect(q.contains(date(iso), tz: ny) == quiet, "\(iso)")
        }
        // The same instant is a different local time elsewhere.
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        #expect(!q.contains(date("2026-06-10T21:00:00-04:00"), tz: tokyo))       // 10:00 the next day in Tokyo
        #expect(q.contains(date("2026-06-10T10:00:00-04:00"), tz: tokyo))        // 23:00 in Tokyo
        // The end after 23:00 is 08:00 the next morning; after 07:00 it is 08:00 the same morning; after 08:00 the next day.
        #expect(q.nextEnd(after: date("2026-06-10T23:00:00-04:00"), tz: ny) == date("2026-06-11T08:00:00-04:00"))
        #expect(q.nextEnd(after: date("2026-06-11T07:00:00-04:00"), tz: ny) == date("2026-06-11T08:00:00-04:00"))
        #expect(q.nextEnd(after: date("2026-06-11T08:00:00-04:00"), tz: ny) == date("2026-06-12T08:00:00-04:00"))

        // A window inside one day behaves the same way without wrapping.
        let day = QuietHours(startHour: 13, startMinute: 0, endHour: 15, endMinute: 30)
        #expect(day.contains(date("2026-06-10T13:00:00-04:00"), tz: ny))
        #expect(day.contains(date("2026-06-10T15:29:00-04:00"), tz: ny))
        #expect(!day.contains(date("2026-06-10T15:30:00-04:00"), tz: ny))
        #expect(!day.contains(date("2026-06-10T12:59:00-04:00"), tz: ny))
    }

    @Test func sameStartEndNeverQuiet() {
        let q = QuietHours(startHour: 22, startMinute: 0, endHour: 22, endMinute: 0)
        for iso in ["2026-06-10T00:00:00-04:00", "2026-06-10T12:00:00-04:00", "2026-06-10T22:00:00-04:00", "2026-06-10T23:30:00-04:00"] {
            #expect(!q.contains(date(iso), tz: ny), "\(iso)")
        }
        #expect(q.nextEnd(after: date("2026-06-10T12:00:00-04:00"), tz: ny) == nil)
    }

    @Test func dstNight() {
        let q = QuietHours(startHour: 22, startMinute: 0, endHour: 8, endMinute: 0)
        // Fall back 2026-11-01: 01:30 happens twice and the night is nine hours long; both are quiet and the end is still 08:00.
        #expect(q.contains(date("2026-11-01T01:30:00-04:00"), tz: ny))
        #expect(q.contains(date("2026-11-01T01:30:00-05:00"), tz: ny))
        #expect(q.contains(date("2026-11-01T07:59:00-05:00"), tz: ny))
        #expect(!q.contains(date("2026-11-01T08:00:00-05:00"), tz: ny))
        #expect(q.nextEnd(after: date("2026-10-31T23:00:00-04:00"), tz: ny) == date("2026-11-01T08:00:00-05:00"))
        #expect(q.nextEnd(after: date("2026-11-01T01:45:00-05:00"), tz: ny) == date("2026-11-01T08:00:00-05:00"))

        // Spring forward 2027-03-14: 02:00-03:00 does not exist; the night is seven hours long and ends at 08:00 EDT.
        #expect(q.contains(date("2027-03-14T03:30:00-04:00"), tz: ny))
        #expect(!q.contains(date("2027-03-14T08:00:00-04:00"), tz: ny))
        #expect(q.nextEnd(after: date("2027-03-13T23:00:00-05:00"), tz: ny) == date("2027-03-14T08:00:00-04:00"))
        // An end time inside the missing hour resolves to the first valid instant after it.
        let gap = QuietHours(startHour: 1, startMinute: 0, endHour: 2, endMinute: 30)
        #expect(gap.nextEnd(after: date("2027-03-14T01:30:00-05:00"), tz: ny) == date("2027-03-14T03:00:00-04:00"))
    }
}
