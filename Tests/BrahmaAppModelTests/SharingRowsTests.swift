import Testing
import Foundation
import BrahmaCore
@testable import BrahmaAppModel

@MainActor @Suite(.scratch) struct SharingRowsTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let utc = TimeZone(identifier: "UTC")!

    static func event(_ kind: ActivityKind, _ text: String, agent: String? = nil, at: Date = t0) -> ActivityEvent {
        ActivityEvent(id: Int64(at.timeIntervalSince1970), companyId: "c", agentId: agent, turnId: nil, kind: kind, text: text, createdAt: at)
    }

    @Test func sharingFilterKinds() {
        #expect(ActivityFilter.sharing.title == "Sharing")
        for k in [ActivityKind.share, .access, .export, .show] { #expect(ActivityFilter.sharing.includes(k)) }
        for k in [ActivityKind.message, .work, .toolUse, .error, .merge] { #expect(!ActivityFilter.sharing.includes(k)) }
        #expect(ActivityFilter.allCases.contains(.sharing))
        let events = [
            Self.event(.share, "@eng-1 shared src/a.ts @abc1234 with #general", agent: "a1"),
            Self.event(.message, "#general @eng-1: hi", agent: "a1", at: Self.t0 + 1),
            Self.event(.access, "@eng-3's share to @qa-2 was refused: that ref isn't available to you", agent: "a3", at: Self.t0 + 2),
            Self.event(.export, "ownerExport src/a.ts", at: Self.t0 + 3),
            Self.event(.show, "show request 3 to @eng-3 (reviewer of ENG-1)", agent: "a3", at: Self.t0 + 4),
        ]
        let rows = SharingRows.make(events: events, reads: nil, handles: ["a1": "eng-1", "a3": "eng-3"], timeZone: Self.utc)
        #expect(rows.count == 4)
        let share = try! #require(rows.first { $0.result == "shared" })
        #expect(share.from == "@eng-1" && share.to == "#general" && share.ref == "src/a.ts @abc1234" && share.session == "")
        #expect(share.when.count == "2027-01-15 08:00".count)
        let export = try! #require(rows.first { $0.result == "exported" })
        #expect(export.from == "owner" && export.ref == "src/a.ts" && export.to == "disk")
        let show = try! #require(rows.first { $0.result == "show request" })
        #expect(show.from == "owner" && show.to == "@eng-3")
        let access = try! #require(rows.first { $0.result == "access" })
        #expect(access.from == "@eng-3" && access.ref.contains("refused"))
        // Newest first.
        #expect(rows.first?.result == "show request")
    }

    @Test func readsToggleAddsRows() {
        let events = [Self.event(.share, "@eng-1 shared ENG-1 with @eng-3", agent: "a1")]
        let reads = [
            RefRead(companyId: "c", readerKind: "agent", readerId: "a3", canonical: "ENG-1", rev: nil, bytes: 120, tainted: false, via: "open_ref",
                    turnId: "t1", createdAt: Self.t0 + 10),
            RefRead(companyId: "c", readerKind: "owner", readerId: nil, canonical: "src/a.ts", rev: "abc1234def", bytes: 9, tainted: true, via: "tab",
                    turnId: nil, createdAt: Self.t0 + 20),
            RefRead(companyId: "c", readerKind: "concierge", readerId: nil, canonical: "F-1", rev: nil, bytes: 9, tainted: false, via: "open_ref",
                    turnId: nil, createdAt: Self.t0 + 30),
        ]
        let without = SharingRows.make(events: events, reads: nil, handles: ["a1": "eng-1", "a3": "eng-3"], timeZone: Self.utc)
        #expect(without.count == 1)
        let with = SharingRows.make(events: events, reads: reads, handles: ["a1": "eng-1", "a3": "eng-3"], timeZone: Self.utc)
        #expect(with.count == 4)
        let agentRead = try! #require(with.first { $0.ref == "ENG-1" && $0.result.hasPrefix("read") })
        #expect(agentRead.from == "@eng-3" && agentRead.result == "read · open_ref" && agentRead.session == "clean" && agentRead.to == "")
        let ownerRead = try! #require(with.first { $0.ref.hasPrefix("src/a.ts") })
        #expect(ownerRead.from == "owner" && ownerRead.ref == "src/a.ts @abc1234" && ownerRead.result == "read · tab" && ownerRead.session == "tainted")
        let concierge = try! #require(with.first { $0.ref == "F-1" })
        #expect(concierge.from == "Brahma")
        #expect(with.map(\.at) == with.map(\.at).sorted(by: >))
    }
}
