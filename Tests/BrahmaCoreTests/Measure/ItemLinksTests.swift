import Foundation
import Testing
import GRDB
@testable import BrahmaCore

/// Item links (`regressionOf`, `revertOf`), the shared landing query and the daily measure counters (Plan X6a Task 2, migration
/// `vX6a-measure`). Store-only.
@Suite(.scratch) struct ItemLinksTests {
    static let t0 = MeasureFixtures.t0
    static let utc = TimeZone(identifier: "UTC")!

    /// A company with `landed` items landed in one batch (ids 1…landed) and `open` more items that never landed.
    struct Rig {
        let store: Store
        let company: Company
        let landed: [WorkItem]
        let open: [WorkItem]
        var window: MeasureWindow { MeasureWindow(since: ItemLinksTests.t0.addingTimeInterval(-30 * 86_400), until: ItemLinksTests.t0.addingTimeInterval(86_400)) }

        init(_ shared: Store? = nil, name: String = "Acme", landed: Int = 1, open: Int = 1) throws {
            store = try shared ?? Store.inMemory()
            company = try MeasureFixtures.company(store, name: name)
            let all = try MeasureFixtures.items(store, company: company, count: landed + open, now: ItemLinksTests.t0.addingTimeInterval(-5 * 86_400))
            self.landed = Array(all.prefix(landed))
            self.open = Array(all.dropFirst(landed))
            if landed > 0 {
                try MeasureFixtures.land(store, company: company, items: self.landed, number: 1,
                                         enqueuedAt: ItemLinksTests.t0.addingTimeInterval(-2 * 86_400), landedAt: ItemLinksTests.t0.addingTimeInterval(-86_400))
            }
        }
    }

    @Test func linkRoundTrip() throws {
        let r = try Rig()
        let target = r.landed[0], item = r.open[0]
        try r.store.linkItem(companyId: r.company.id, itemKey: item.key, kind: .regressionOf, targetKey: target.key, by: "owner", now: Self.t0)
        let links = try r.store.itemLinks(companyId: r.company.id, kind: .regressionOf, in: r.window)
        #expect(links == [ItemLink(companyId: r.company.id, itemId: item.id, kind: .regressionOf, targetId: target.id, createdBy: "owner", createdAt: Self.t0)])
        // The same link twice is one link (the primary key), not an error; the key is matched case-insensitively.
        try r.store.linkItem(companyId: r.company.id, itemKey: item.key.lowercased(), kind: .regressionOf, targetKey: target.key.lowercased(), by: "owner",
                             now: Self.t0.addingTimeInterval(60))
        #expect(try r.store.itemLinks(companyId: r.company.id, kind: .regressionOf, in: r.window).count == 1)
        // Kinds are separate; the window is on `createdAt`.
        #expect(try r.store.itemLinks(companyId: r.company.id, kind: .revertOf, in: r.window).isEmpty)
        try r.store.linkItem(companyId: r.company.id, itemKey: item.key, kind: .revertOf, targetKey: target.key, by: "owner", now: Self.t0)
        #expect(try r.store.itemLinks(companyId: r.company.id, kind: .revertOf, in: r.window).map(\.targetId) == [target.id])
        let before = MeasureWindow(since: Self.t0.addingTimeInterval(-10), until: Self.t0)
        #expect(try r.store.itemLinks(companyId: r.company.id, kind: .regressionOf, in: before).isEmpty)
        // Another company sharing the store never sees them.
        let other = try MeasureFixtures.company(r.store, name: "Zeta")
        #expect(try r.store.itemLinks(companyId: other.id, kind: .regressionOf, in: r.window).isEmpty)
    }

    @Test func crossCompanyTargetNotFound() throws {
        let store = try Store.inMemory()
        let acme = try Rig(store, name: "Acme", landed: 0, open: 1)
        let zeta = try Rig(store, name: "Zeta", landed: 1, open: 0)
        let zetaKey = zeta.landed[0].key
        #expect(zetaKey.hasPrefix("ZETA-"))
        // Zeta's landed item is not in Acme: not found, never "has not landed".
        #expect(throws: WorkError.notFound("no such work item \(zetaKey)")) {
            try store.linkItem(companyId: acme.company.id, itemKey: acme.open[0].key, kind: .regressionOf, targetKey: zetaKey, by: "owner", now: Self.t0)
        }
        #expect(throws: WorkError.notFound("no such work item ACME-99")) {
            try store.linkItem(companyId: acme.company.id, itemKey: acme.open[0].key, kind: .revertOf, targetKey: "acme-99", by: "owner", now: Self.t0)
        }
        // An unknown source item is not found either.
        #expect(throws: WorkError.notFound("no such work item ACME-98")) {
            try store.linkItem(companyId: acme.company.id, itemKey: "ACME-98", kind: .revertOf, targetKey: zetaKey, by: "owner", now: Self.t0)
        }
        #expect(try store.itemLinks(companyId: acme.company.id, kind: .regressionOf, in: acme.window).isEmpty)
        #expect(try store.itemLinks(companyId: zeta.company.id, kind: .regressionOf, in: zeta.window).isEmpty)
    }

    @Test func unlandedTargetRefused() throws {
        let r = try Rig(landed: 1, open: 2)
        let open = r.open[0], other = r.open[1]
        #expect(throws: WorkError.invalid("\(open.key) has not landed; only landed items can regress or be reverted")) {
            try r.store.linkItem(companyId: r.company.id, itemKey: other.key, kind: .regressionOf, targetKey: open.key, by: "owner", now: Self.t0)
        }
        // A batch that reached `checked` (landCommit written, main not moved) is not a landing either.
        let checked = try MeasureFixtures.land(r.store, company: r.company, items: [open], number: 2, enqueuedAt: Self.t0, landedAt: Self.t0, step: .checked)
        #expect(checked.batch.landCommit != nil)
        #expect(throws: WorkError.invalid("\(open.key) has not landed; only landed items can regress or be reverted")) {
            try r.store.linkItem(companyId: r.company.id, itemKey: other.key, kind: .revertOf, targetKey: open.key, by: "owner", now: Self.t0)
        }
        #expect(try r.store.hasLanded(companyId: r.company.id, itemId: open.id) == false)
        #expect(try r.store.hasLanded(companyId: r.company.id, itemId: r.landed[0].id) == true)
        // The source item need not have landed: an open bug can be a regression of a landed item.
        try r.store.linkItem(companyId: r.company.id, itemKey: other.key, kind: .regressionOf, targetKey: r.landed[0].key, by: "owner", now: Self.t0)
        #expect(try r.store.itemLinks(companyId: r.company.id, kind: .regressionOf, in: r.window).count == 1)
    }

    @Test func selfLinkRefused() throws {
        let r = try Rig()
        let landed = r.landed[0]
        for kind in ItemLinkKind.allCases {
            #expect(throws: WorkError.invalid("\(landed.key) cannot be a \(kind.phrase) itself")) {
                try r.store.linkItem(companyId: r.company.id, itemKey: landed.key, kind: kind, targetKey: landed.key.lowercased(), by: "owner", now: Self.t0)
            }
            #expect(try r.store.itemLinks(companyId: r.company.id, kind: kind, in: r.window).isEmpty)
        }
    }

    @Test func auditFollowUpLinksRegression() throws {
        let store = try Store.inMemory()
        let company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        let eng = try store.hire(companyId: company.id, name: "eng", role: "engineer", model: "m")
        let rev = try store.hire(companyId: company.id, name: "rev", role: "engineer", model: "m")
        let item = try store.createWorkItem(companyId: company.id, by: .owner, draft: WorkItemDraft(type: .task, title: "Landed", status: .ready), now: Self.t0)
        try MeasureFixtures.land(store, company: company, items: [item], number: 1, enqueuedAt: Self.t0, landedAt: Self.t0)
        try store.writer.write { db in
            try ReviewAudit(itemId: item.id, companyId: company.id, sampledActive: 0, authorId: eng.id, mergedCommit: "abc", auditorId: rev.id).insert(db)
        }
        let turn = try store.startTurn(agentId: rev.id, now: Self.t0)
        try store.bindAuditTurn(turnId: turn.id, agentId: rev.id, itemIds: [item.id])
        let sample = try store.recordAudit(turnId: turn.id, agentId: rev.id, companyId: company.id, key: item.key, ok: false, notes: "broken",
                                           now: Self.t0.addingTimeInterval(60))
        let followUpId = try #require(sample.followUpId)
        let window = MeasureWindow(since: Self.t0, until: Self.t0.addingTimeInterval(3600))
        let links = try store.itemLinks(companyId: company.id, kind: .regressionOf, in: window)
        #expect(links == [ItemLink(companyId: company.id, itemId: followUpId, kind: .regressionOf, targetId: item.id, createdBy: "system",
                                   createdAt: Self.t0.addingTimeInterval(60))])
        #expect(try store.itemLinks(companyId: company.id, kind: .revertOf, in: window).isEmpty)
        // An owner filing the same regression later is the same link: it dedupes on the landed item.
        let followUp = try #require(try store.workItem(id: followUpId))
        try store.linkItem(companyId: company.id, itemKey: followUp.key, kind: .regressionOf, targetKey: item.key, by: "owner", now: Self.t0.addingTimeInterval(120))
        #expect(try store.itemLinks(companyId: company.id, kind: .regressionOf, in: window).count == 1)
    }

    @Test func countersSumByWindow() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.company(store, name: "Acme")
        let zeta = try MeasureFixtures.company(store, name: "Zeta")
        try store.addCounter(companyId: acme.id, name: "activeSeconds", day: "2026-11-01", delta: 10)
        try store.addCounter(companyId: acme.id, name: "activeSeconds", day: "2026-11-01", delta: 5)
        try store.addCounter(companyId: acme.id, name: "activeSeconds", day: "2026-11-02", delta: 100)
        try store.addCounter(companyId: acme.id, name: "activeSeconds", day: "2026-11-03", delta: 1000)
        try store.addCounter(companyId: acme.id, name: "idleActionableSeconds", day: "2026-11-02", delta: 7)
        try store.addCounter(companyId: zeta.id, name: "activeSeconds", day: "2026-11-02", delta: 50_000)
        func day(_ s: String, _ hms: String = "00:00:00") -> Date {
            let f = DateFormatter(); f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = Self.utc; f.dateFormat = "yyyy-MM-dd HH:mm:ss"
            return f.date(from: "\(s) \(hms)")!
        }
        // A day whose string falls inside the window counts, whatever the clock time of the window's ends.
        #expect(try store.counters(companyId: acme.id, name: "activeSeconds", in: MeasureWindow(since: day("2026-11-01"), until: day("2026-11-03", "12:00:00")), tz: Self.utc) == 1115)
        #expect(try store.counters(companyId: acme.id, name: "activeSeconds", in: MeasureWindow(since: day("2026-11-01", "23:59:00"), until: day("2026-11-02", "00:01:00")), tz: Self.utc) == 115)
        #expect(try store.counters(companyId: acme.id, name: "activeSeconds", in: MeasureWindow(since: day("2026-11-02"), until: day("2026-11-02", "06:00:00")), tz: Self.utc) == 100)
        // A window that ends exactly at midnight does not reach into that day.
        #expect(try store.counters(companyId: acme.id, name: "activeSeconds", in: MeasureWindow(since: day("2026-11-01"), until: day("2026-11-03")), tz: Self.utc) == 115)
        // Nothing recorded is zero, by name and by company; a window before any counter is zero.
        #expect(try store.counters(companyId: acme.id, name: "idleActionableSeconds", in: MeasureWindow(since: day("2026-11-01"), until: day("2026-11-04")), tz: Self.utc) == 7)
        #expect(try store.counters(companyId: acme.id, name: "reserveBreaches", in: MeasureWindow(since: day("2026-11-01"), until: day("2026-11-04")), tz: Self.utc) == 0)
        #expect(try store.counters(companyId: acme.id, name: "activeSeconds", in: MeasureWindow(since: day("2026-10-01"), until: day("2026-10-31")), tz: Self.utc) == 0)
        #expect(try store.counters(companyId: zeta.id, name: "activeSeconds", in: MeasureWindow(since: day("2026-11-01"), until: day("2026-11-04")), tz: Self.utc) == 50_000)
        // The day string is the owner's calendar day: the same instant is a different day in Tokyo.
        let late = day("2026-11-01", "20:00:00")   // 2026-11-02 05:00 in Asia/Tokyo
        #expect(Store.measureDay(late, in: Self.utc) == "2026-11-01")
        #expect(Store.measureDay(late, in: TimeZone(identifier: "Asia/Tokyo")!) == "2026-11-02")
        // The owner's zone is the default.
        try store.setOwnerTimeZone("UTC")
        #expect(try store.counters(companyId: acme.id, name: "activeSeconds", in: MeasureWindow(since: day("2026-11-01"), until: day("2026-11-04"))) == 1115)
    }

    @Test func landingsFollowRequestIds() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.company(store, name: "Acme")
        let items = try MeasureFixtures.items(store, company: acme, count: 6, now: Self.t0.addingTimeInterval(-10 * 86_400))
        // Batch 1: two items landed together, two days ago.
        let b1 = try MeasureFixtures.land(store, company: acme, items: [items[0], items[1]], number: 1, enqueuedAt: Self.t0.addingTimeInterval(-3 * 86_400),
                                          landedAt: Self.t0.addingTimeInterval(-2 * 86_400))
        // Batch 2: landed yesterday, still at `recorded` (finishedAt not stamped: the landing time is `updatedAt`).
        let b2 = try MeasureFixtures.land(store, company: acme, items: [items[2]], number: 2, enqueuedAt: Self.t0.addingTimeInterval(-2 * 86_400),
                                          landedAt: Self.t0.addingTimeInterval(-86_400), step: .recorded)
        try store.writer.write { db in try db.execute(sql: "UPDATE mergeBatch SET finishedAt = NULL WHERE id = ?", arguments: [b2.batch.id]) }
        // Excluded: a `checked` batch (landCommit written, main not moved) and a `done` batch with no landCommit (nothing landed).
        try MeasureFixtures.land(store, company: acme, items: [items[3]], number: 3, enqueuedAt: Self.t0, landedAt: Self.t0, step: .checked)
        let empty = try MeasureFixtures.land(store, company: acme, items: [items[4]], number: 4, enqueuedAt: Self.t0, landedAt: Self.t0)
        try store.writer.write { db in try db.execute(sql: "UPDATE mergeBatch SET landCommit = NULL, landedIds = '[]' WHERE id = ?", arguments: [empty.batch.id]) }
        // Another company's landing.
        let zeta = try MeasureFixtures.company(store, name: "Zeta")
        let zItems = try MeasureFixtures.items(store, company: zeta, count: 1, now: Self.t0.addingTimeInterval(-10 * 86_400))
        try MeasureFixtures.land(store, company: zeta, items: zItems, number: 1, enqueuedAt: Self.t0.addingTimeInterval(-3 * 86_400), landedAt: Self.t0.addingTimeInterval(-2 * 86_400))

        let window = MeasureWindow(since: Self.t0.addingTimeInterval(-7 * 86_400), until: Self.t0)
        let landings = try store.landings(companyId: acme.id, in: window)
        #expect(landings.map(\.number) == [1, 2])
        let first = try #require(landings.first)
        #expect(first.batchId == b1.batch.id && first.landCommit == b1.batch.landCommit && first.baseCommit == b1.batch.base)
        #expect(first.finishedAt == Self.t0.addingTimeInterval(-2 * 86_400))
        // landedIds are request ids: the items come through `mergeRequest.itemId`, the merged commit through `candidates[requestId]`.
        #expect(first.items.map(\.requestId) == b1.requests.map(\.id))
        #expect(first.items.map(\.itemId) == [items[0].id, items[1].id])
        #expect(first.items.map(\.key) == [items[0].key, items[1].key])
        #expect(first.items.map(\.mergedCommit) == b1.requests.map { b1.batch.candidates[$0.id] })
        #expect(first.items.allSatisfy { $0.landedAt == Self.t0.addingTimeInterval(-2 * 86_400) })
        let second = landings[1]
        #expect(second.finishedAt == Self.t0.addingTimeInterval(-86_400), "no finishedAt: the landing time is updatedAt")
        #expect(second.items.map(\.itemId) == [items[2].id])
        // The window is on the landing time.
        #expect(try store.landings(companyId: acme.id, in: MeasureWindow(since: Self.t0.addingTimeInterval(-36 * 3600), until: Self.t0)).map(\.number) == [2])
        #expect(try store.landings(companyId: acme.id, in: MeasureWindow(since: Self.t0, until: Self.t0.addingTimeInterval(86_400))).isEmpty)
        // hasLanded agrees.
        #expect(try store.hasLanded(companyId: acme.id, itemId: items[1].id))
        #expect(try store.hasLanded(companyId: acme.id, itemId: items[2].id))
        #expect(!(try store.hasLanded(companyId: acme.id, itemId: items[3].id)))
        #expect(!(try store.hasLanded(companyId: acme.id, itemId: items[4].id)))
        #expect(!(try store.hasLanded(companyId: acme.id, itemId: items[5].id)))
        #expect(!(try store.hasLanded(companyId: acme.id, itemId: zItems[0].id)), "another company's landing is not this company's")
        #expect(try store.landings(companyId: zeta.id, in: window).flatMap(\.items).map(\.itemId) == [zItems[0].id])
    }

    /// Ruling R24: `landCommit` and `landedIds` are written at `checked`, before `main` moves, and the post-`checked` abort paths
    /// (stopped, main moved, blocked, off main, a git error, recovery abandoning the batch) finish the batch to `done` with both
    /// still set and requeue its requests. A request is a landed item only when it is `merged` with `batchId` = that batch; a
    /// batch with no such request is not a landing.
    @Test func abandonedBatchIsNotALanding() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.company(store, name: "Acme")
        let items = try MeasureFixtures.items(store, company: acme, count: 3, now: Self.t0.addingTimeInterval(-10 * 86_400))
        // Batch 1 reached `checked`, then was abandoned to `done`: its requests went back to `queued` (batchId cleared).
        let abandoned = try MeasureFixtures.land(store, company: acme, items: [items[0], items[1]], number: 1,
                                                 enqueuedAt: Self.t0.addingTimeInterval(-3 * 86_400), landedAt: Self.t0.addingTimeInterval(-2 * 86_400))
        try store.writer.write { db in
            try db.execute(sql: "UPDATE mergeRequest SET status = 'queued', batchId = NULL, finishedAt = NULL WHERE batchId = ?",
                           arguments: [abandoned.batch.id])
        }
        // Batch 2 landed one item of a request whose status is merged but whose batchId names another batch: not this batch's item.
        let other = try MeasureFixtures.land(store, company: acme, items: [items[2]], number: 2,
                                             enqueuedAt: Self.t0.addingTimeInterval(-3 * 86_400), landedAt: Self.t0.addingTimeInterval(-86_400))
        try store.writer.write { db in
            try db.execute(sql: "UPDATE mergeRequest SET batchId = ? WHERE id = ?", arguments: [UUID().uuidString, other.requests[0].id])
        }

        let window = MeasureWindow(since: Self.t0.addingTimeInterval(-7 * 86_400), until: Self.t0)
        #expect(try store.landings(companyId: acme.id, in: window).isEmpty)
        #expect(!(try store.hasLanded(companyId: acme.id, itemId: items[0].id)))
        #expect(!(try store.hasLanded(companyId: acme.id, itemId: items[1].id)))
        #expect(!(try store.hasLanded(companyId: acme.id, itemId: items[2].id)))
    }
}
