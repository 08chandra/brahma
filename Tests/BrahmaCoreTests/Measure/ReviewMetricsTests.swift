import Foundation
import Testing
@testable import BrahmaCore

/// Review catch, escape and revert rates (Plan X6a Task 4; `docs/measure/metrics.md` §2–§4 and the vocabulary rows "caught in
/// review", "confirmed catch", "escaped", "revert"). Store-only: the revert detector is handed a patch-id source that runs no git
/// (its git leg is `RevertDetectorTests`), so each test owns every number.
@Suite(.scratch) struct ReviewMetricsTests {
    let now = MeasureFixtures.t0
    let day: TimeInterval = 86_400
    var window: MeasureWindow { MeasureWindow(since: now.addingTimeInterval(-60 * day), until: now) }

    func context(_ store: Store, _ company: Company, window: MeasureWindow? = nil) throws -> MeasureContext {
        guard let fresh = try store.company(id: company.id) else { throw FakeError(description: "no company") }
        return MeasureContext(store: store, git: GitWorkspace(root: URL(fileURLWithPath: fresh.workspacePath)), company: fresh,
                              window: window ?? self.window, now: now)
    }

    /// Counts the detector's patch-id requests.
    final class Calls { var n = 0 }

    /// A detector whose source runs no git: every range has an empty diff (no patch-id) except the exact inverses named, where
    /// the reverted request's inverse diff and the reverting request's forward diff share one patch-id (ruling R17 ranges).
    func detector(inverses: [(reverted: MergeRequest, by: MergeRequest)] = [], calls: Calls = Calls()) -> RevertDetector {
        var ids: [String: String] = [:]
        for (n, pair) in inverses.enumerated() {
            guard let l = pair.reverted.mergedCommit, let r = pair.by.mergedCommit else { continue }
            ids["\(l)|\(l)^1"] = "patch-\(n)"
            ids["\(r)^1|\(r)"] = "patch-\(n)"
        }
        let table = ids
        return RevertDetector(limits: .standard, source: { from, to in
            calls.n += 1
            return table["\(from)|\(to)"]
        })
    }

    func row(_ m: MetricValue, _ label: String) -> MetricValue? { m.detail.first { $0.label == label } }

    /// changesRequested → submitted → a passing check, one item.
    func confirmedCatch(_ store: Store, _ company: Company, _ item: WorkItem, at t: Date) throws {
        try MeasureFixtures.event(store, item: item, kind: .changesRequested, at: t)
        try MeasureFixtures.event(store, item: item, kind: .submitted, at: t.addingTimeInterval(600))
        try MeasureFixtures.verificationRun(store, company: company, item: item, finishedAt: t.addingTimeInterval(3600))
    }

    // MARK: Review catch

    /// A change request counts as caught only after a resubmission (`submitted` after it) that a later passing check confirmed:
    /// a submit/merge `verificationRun`, an `item`-kind `mergeRun`, or the `main` run of the batch that landed the item. A
    /// passing check with no resubmission in between is not a catch; three rounds on one item count once.
    @Test func caughtNeedsResubmission() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.company(store, name: "Acme")
        let items = try MeasureFixtures.items(store, company: acme, count: 5, now: now.addingTimeInterval(-20 * day))
        let t = now.addingTimeInterval(-10 * day)
        // [0] change request, then a passing check, never resubmitted: not caught.
        try MeasureFixtures.event(store, item: items[0], kind: .changesRequested, at: t)
        try MeasureFixtures.verificationRun(store, company: acme, item: items[0], finishedAt: t.addingTimeInterval(3600))
        // [1] confirmed by a passing submit check.
        try confirmedCatch(store, acme, items[1], at: t)
        // [2] confirmed by its item check in the merge batch.
        try MeasureFixtures.event(store, item: items[2], kind: .changesRequested, at: t)
        try MeasureFixtures.event(store, item: items[2], kind: .submitted, at: t.addingTimeInterval(600))
        let landed = try MeasureFixtures.landEach(store, company: acme, items: [items[2], items[3]],
                                                  at: [t.addingTimeInterval(7200), t.addingTimeInterval(7300)])
        try MeasureFixtures.mergeRun(store, company: acme, batch: landed[0].batch, kind: .item, request: landed[0].request,
                                     finishedAt: t.addingTimeInterval(7000))
        // [3] confirmed by the main run of the batch that landed it.
        try MeasureFixtures.setMainCheck(store, company: acme)
        try MeasureFixtures.event(store, item: items[3], kind: .changesRequested, at: t)
        try MeasureFixtures.event(store, item: items[3], kind: .submitted, at: t.addingTimeInterval(600))
        try MeasureFixtures.mergeRun(store, company: acme, batch: landed[1].batch, kind: .main, request: landed[1].request,
                                     finishedAt: t.addingTimeInterval(7100))
        // [4] three rounds, one passing check at the end: one catch.
        for round in 0..<3 {
            let r = t.addingTimeInterval(Double(round) * 1000)
            try MeasureFixtures.event(store, item: items[4], kind: .changesRequested, at: r)
            try MeasureFixtures.event(store, item: items[4], kind: .submitted, at: r.addingTimeInterval(500))
        }
        try MeasureFixtures.verificationRun(store, company: acme, item: items[4], finishedAt: t.addingTimeInterval(5000))

        let m = try ReviewMetrics.reviewCatch(context(store, acme))
        #expect(m.id == .reviewCatch && m.unit == .ratio)
        #expect(m.numerator == 4 && m.denominator == 4, "\(m)")
        #expect(m.status == .insufficient(n: 4))
        #expect(row(m, "confirmed catches")?.numerator == 4)
        #expect(row(m, "escaped")?.numerator == 0)
        #expect(row(m, "unconfirmed change requests")?.numerator == 1, "\(m.detail)")
        #expect(m.basis.contains("confirmed"), "\(m.basis)")
    }

    /// Owner ruling R7(c): a change request followed by a resubmission that no later check passed is not a catch. A check that
    /// passed before the resubmission, or one that failed after it, confirms nothing; the change request is listed as unconfirmed.
    @Test func unconfirmedCatchNotCounted() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.company(store, name: "Acme")
        let items = try MeasureFixtures.items(store, company: acme, count: 2, now: now.addingTimeInterval(-20 * day))
        let t = now.addingTimeInterval(-10 * day)
        try MeasureFixtures.verificationRun(store, company: acme, item: items[0], finishedAt: t.addingTimeInterval(-100))
        try MeasureFixtures.event(store, item: items[0], kind: .changesRequested, at: t)
        try MeasureFixtures.event(store, item: items[0], kind: .submitted, at: t.addingTimeInterval(600))
        try MeasureFixtures.verificationRun(store, company: acme, item: items[0], status: .failed, finishedAt: t.addingTimeInterval(3600))
        // [1] confirmed only after the window ended: not in this window's numerator, and not unconfirmed either.
        try MeasureFixtures.event(store, item: items[1], kind: .changesRequested, at: t)
        try MeasureFixtures.event(store, item: items[1], kind: .submitted, at: t.addingTimeInterval(600))
        try MeasureFixtures.verificationRun(store, company: acme, item: items[1], finishedAt: now.addingTimeInterval(3600))

        let m = try ReviewMetrics.reviewCatch(context(store, acme))
        #expect(m.numerator == 0 && m.denominator == 0, "\(m)")
        #expect(m.status == .insufficient(n: 0))
        #expect(m.display == "insufficient data (n=0)")
        #expect(row(m, "unconfirmed change requests")?.numerator == 1, "\(m.detail)")
        #expect(row(m, "unconfirmed change requests")?.basis.contains("not in the rate") == true)
    }

    /// 8 confirmed catches + 2 escapes is n = 10: insufficient. 16 + 4 = 20 events: `80.0% (16/20)`.
    @Test func catchRateFormula() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.company(store, name: "Acme")
        let caught = try MeasureFixtures.items(store, company: acme, count: 16, now: now.addingTimeInterval(-30 * day))
        let landed = try MeasureFixtures.items(store, company: acme, count: 4, now: now.addingTimeInterval(-30 * day))
        let bugs = try MeasureFixtures.items(store, company: acme, count: 4, now: now.addingTimeInterval(-30 * day))
        let rows = try MeasureFixtures.landEach(store, company: acme, items: landed,
                                                at: (0..<4).map { now.addingTimeInterval(-20 * day + Double($0) * 3600) })
        for (i, item) in caught.prefix(8).enumerated() { try confirmedCatch(store, acme, item, at: now.addingTimeInterval(-10 * day + Double(i) * 60)) }
        for i in 0..<2 { try MeasureFixtures.link(store, item: bugs[i], kind: .regressionOf, target: rows[i].item, at: now.addingTimeInterval(-5 * day)) }

        let few = try ReviewMetrics.reviewCatch(context(store, acme))
        #expect(few.numerator == 8 && few.denominator == 10, "\(few)")
        #expect(few.status == .insufficient(n: 10))
        #expect(few.display == "insufficient data (n=10)")

        for (i, item) in caught.suffix(8).enumerated() { try confirmedCatch(store, acme, item, at: now.addingTimeInterval(-9 * day + Double(i) * 60)) }
        for i in 2..<4 { try MeasureFixtures.link(store, item: bugs[i], kind: .regressionOf, target: rows[i].item, at: now.addingTimeInterval(-5 * day)) }
        let m = try ReviewMetrics.reviewCatch(context(store, acme))
        #expect(m.status == .ok)
        #expect(m.numerator == 16 && m.denominator == 20)
        #expect(m.display == "80.0% (16/20)")
    }

    // MARK: Escapes

    /// Escapes are keyed to the target's landing: a `regressionOf` link (whenever made) to an item landed in the window, plus a
    /// failed audit of one. An `ok` audit, and a link to an item that landed before the window, are not escapes of this window.
    @Test func escapedFromLinksAndAudits() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.company(store, name: "Acme", createdAt: now.addingTimeInterval(-200 * day))
        let landedItems = try MeasureFixtures.items(store, company: acme, count: 21, now: now.addingTimeInterval(-100 * day))
        // 20 in the window, one 70 days ago (before it).
        let at = (0..<20).map { now.addingTimeInterval(-2 * day - Double($0) * 3600) } + [now.addingTimeInterval(-70 * day)]
        let rows = try MeasureFixtures.landEach(store, company: acme, items: landedItems, at: at)
        let old = rows[20].item
        let bugs = try MeasureFixtures.items(store, company: acme, count: 2, now: now.addingTimeInterval(-day))
        try MeasureFixtures.link(store, item: bugs[0], kind: .regressionOf, target: rows[2].item, at: now.addingTimeInterval(-day))
        try MeasureFixtures.link(store, item: bugs[1], kind: .regressionOf, target: old, at: now.addingTimeInterval(-day))
        try MeasureFixtures.audit(store, item: rows[5].item, verdict: "failed", auditedAt: now.addingTimeInterval(-day))
        try MeasureFixtures.audit(store, item: rows[6].item, verdict: "ok", auditedAt: now.addingTimeInterval(-day))

        let m = try ReviewMetrics.escapeRate(context(store, acme))
        #expect(m.id == .escapeRate && m.unit == .ratio)
        #expect(m.numerator == 2 && m.denominator == 20, "\(m)")
        #expect(m.status == .ok)
        #expect(m.display == "10.0% (2/20)")
        let labels = m.detail.map(\.label)
        #expect(labels.count == 2, "\(labels)")
        #expect(labels.contains("\(bugs[0].key) regressionOf \(rows[2].item.key)"), "\(labels)")
        #expect(labels.contains("\(rows[5].item.key) failed audit"), "\(labels)")
        #expect(m.basis.contains("escapes found so far"), "\(m.basis)")
        // The same two escapes are the review-catch denominator's escaped leg.
        let c = try ReviewMetrics.reviewCatch(context(store, acme))
        #expect(c.numerator == 0 && c.denominator == 2)
    }

    /// A failed audit opens a follow-up that carries a `regressionOf` link to the audited item: one defect, one escape, one row
    /// naming both sources. A second owner-filed regression of the same item is still the same escape.
    @Test func auditAndLinkCountOnce() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.company(store, name: "Acme")
        let landedItems = try MeasureFixtures.items(store, company: acme, count: 20, now: now.addingTimeInterval(-30 * day))
        let rows = try MeasureFixtures.landEach(store, company: acme, items: landedItems,
                                                at: (0..<20).map { now.addingTimeInterval(-5 * day + Double($0) * 60) })
        let target = rows[4].item
        let extra = try MeasureFixtures.items(store, company: acme, count: 2, now: now.addingTimeInterval(-day))
        let followUp = extra[0], filed = extra[1]
        try MeasureFixtures.audit(store, item: target, verdict: "failed", auditedAt: now.addingTimeInterval(-2 * day), followUp: followUp)
        try MeasureFixtures.link(store, item: followUp, kind: .regressionOf, target: target, at: now.addingTimeInterval(-2 * day), by: "system")
        try MeasureFixtures.link(store, item: filed, kind: .regressionOf, target: target, at: now.addingTimeInterval(-day))

        let m = try ReviewMetrics.escapeRate(context(store, acme))
        #expect(m.numerator == 1 && m.denominator == 20, "\(m)")
        #expect(m.detail.count == 1, "\(m.detail.map(\.label))")
        let label = m.detail.first?.label ?? ""
        #expect(label.contains("\(followUp.key) regressionOf \(target.key)"), "\(label)")
        #expect(label.contains("\(filed.key) regressionOf \(target.key)"), "\(label)")
        #expect(label.contains("\(target.key) failed audit"), "\(label)")
        #expect(m.detail.first?.numerator == 1)
    }

    /// Links exist only since the `vX6a-measure` migration; a window that starts before it says so in the basis of every metric
    /// that reads links. A window that starts after it does not.
    @Test func preLinkHistoryStated() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.company(store, name: "Acme", createdAt: now.addingTimeInterval(-200 * day))
        let items = try MeasureFixtures.items(store, company: acme, count: 2, now: now.addingTimeInterval(-50 * day))
        try MeasureFixtures.landEach(store, company: acme, items: items, at: [now.addingTimeInterval(-40 * day), now.addingTimeInterval(-20 * day)])
        let epoch = now.addingTimeInterval(-10 * day)
        try MeasureFixtures.setLinksSince(store, epoch)
        let stated = "links since \(Store.measureDay(epoch, in: store.ownerTimeZone()))"

        let ctx = try context(store, acme)
        for m in [try ReviewMetrics.reviewCatch(ctx), try ReviewMetrics.escapeRate(ctx), try ReviewMetrics.revertRate(ctx, detector: detector())] {
            #expect(m.basis.contains(stated), "\(m.id.rawValue): \(m.basis)")
        }
        // History reaches back past the window: nothing to state.
        try MeasureFixtures.setLinksSince(store, now.addingTimeInterval(-90 * day))
        for m in [try ReviewMetrics.reviewCatch(ctx), try ReviewMetrics.escapeRate(ctx), try ReviewMetrics.revertRate(ctx, detector: detector())] {
            #expect(!m.basis.contains("links since"), "\(m.id.rawValue): \(m.basis)")
        }
    }

    // MARK: Reverts

    /// A revert both linked and detected is one revert, shown as linked; a detected-only one is shown as an exact inverse.
    @Test func revertLinkedAndDetectedNotDoubleCounted() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.company(store, name: "Acme", createdAt: now.addingTimeInterval(-200 * day))
        let items = try MeasureFixtures.items(store, company: acme, count: 22, now: now.addingTimeInterval(-50 * day))
        let rows = try MeasureFixtures.landEach(store, company: acme, items: items,
                                                at: (0..<22).map { now.addingTimeInterval(-40 * day + Double($0) * 3600) })
        try MeasureFixtures.link(store, item: rows[1].item, kind: .revertOf, target: rows[0].item, at: now.addingTimeInterval(-39 * day))
        let det = detector(inverses: [(rows[0].request, rows[1].request), (rows[2].request, rows[3].request)])

        let m = try ReviewMetrics.revertRate(context(store, acme), detector: det)
        #expect(m.id == .revertRate && m.unit == .ratio)
        #expect(m.numerator == 2 && m.denominator == 22, "\(m)")
        #expect(m.status == .ok)
        #expect(m.display == "9.1% (2/22)")
        let reverts = m.detail.map(\.label).filter { $0.contains(" reverts ") }
        #expect(reverts.count == 2, "\(reverts)")
        #expect(reverts.contains("\(rows[1].item.key) reverts \(rows[0].item.key) (linked)"), "\(reverts)")
        #expect(reverts.contains("\(rows[3].item.key) reverts \(rows[2].item.key) (exact inverse)"), "\(reverts)")
        for label in ["7 d", "14 d", "30 d"] { #expect(row(m, label)?.numerator == 2, "\(label)") }
    }

    /// Owner ruling R7(b): reverted at day 5 and at day 20 → the 7-day row counts 1, the 14-day row 1, the 30-day row 2, each over
    /// its own population of items that have had N days (an item landed 10 days ago is in the 7-day population only; one landed
    /// 20 days ago is not in the 30-day one).
    @Test func revertRateAt7And30Days() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.company(store, name: "Acme", createdAt: now.addingTimeInterval(-200 * day))
        let items = try MeasureFixtures.items(store, company: acme, count: 5, now: now.addingTimeInterval(-50 * day))
        // T1, T2 at −40 d; R1 at −35 d reverts T1 (day 5); R2 at −20 d reverts T2 (day 20); X at −10 d.
        let rows = try MeasureFixtures.landEach(store, company: acme, items: items, at: [
            now.addingTimeInterval(-40 * day), now.addingTimeInterval(-40 * day + 60), now.addingTimeInterval(-35 * day),
            now.addingTimeInterval(-20 * day + 60), now.addingTimeInterval(-10 * day),
        ])
        let t1 = rows[0].item, t2 = rows[1].item, r1 = rows[2].item, r2 = rows[3].item
        try MeasureFixtures.link(store, item: r1, kind: .revertOf, target: t1, at: now.addingTimeInterval(-36 * day))
        try MeasureFixtures.link(store, item: r2, kind: .revertOf, target: t2, at: now.addingTimeInterval(-21 * day))

        let m = try ReviewMetrics.revertRate(context(store, acme), detector: detector())
        let seven = try #require(row(m, "7 d")), fourteen = try #require(row(m, "14 d")), thirty = try #require(row(m, "30 d"))
        #expect(seven.numerator == 1 && seven.denominator == 5, "\(seven)")
        #expect(fourteen.numerator == 1 && fourteen.denominator == 4, "\(fourteen)")
        #expect(thirty.numerator == 2 && thirty.denominator == 3, "\(thirty)")
        #expect(seven.status == .insufficient(n: 5) && fourteen.status == .insufficient(n: 4) && thirty.status == .insufficient(n: 3))
        // The headline is the 14-day row.
        #expect(m.numerator == 1 && m.denominator == 4 && m.status == .insufficient(n: 4))
        #expect(m.label == "Revert rate (14 days)")
        let reverts = m.detail.map(\.label).filter { $0.contains(" reverts ") }
        #expect(Set(reverts) == ["\(r1.key) reverts \(t1.key) (linked)", "\(r2.key) reverts \(t2.key) (linked)"], "\(reverts)")
        #expect(fourteen.basis.contains("1 landed in the last 14 days excluded"), "\(fourteen.basis)")
    }

    /// Nothing landed: `not measured`. Landings too recent for any row: `not measured: no landings old enough`, and no git runs.
    /// A workspace with no repository: `not measured`, never a revert rate built from links alone.
    @Test func revertRateNotMeasuredWithoutLandings() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.company(store, name: "Acme", createdAt: now.addingTimeInterval(-200 * day))
        let calls = Calls()
        let empty = try ReviewMetrics.revertRate(context(store, acme), detector: detector(calls: calls))
        #expect(empty.status == .notMeasured(reason: "no landings in the window"))
        #expect(empty.display == "not measured: no landings in the window")
        #expect(try ReviewMetrics.escapeRate(context(store, acme)).status == .notMeasured(reason: "no landings in the window"))

        let items = try MeasureFixtures.items(store, company: acme, count: 3, now: now.addingTimeInterval(-10 * day))
        try MeasureFixtures.landEach(store, company: acme, items: items, at: (0..<3).map { now.addingTimeInterval(-3 * day + Double($0) * 60) })
        let recent = try ReviewMetrics.revertRate(context(store, acme), detector: detector(calls: calls))
        #expect(recent.status == .notMeasured(reason: "no landings old enough"), "\(recent)")
        for label in ["7 d", "14 d", "30 d"] { #expect(row(recent, label)?.status == .notMeasured(reason: "no landings old enough"), "\(label)") }
        #expect(calls.n == 0)

        // Old enough, but the company's workspace has no repository: the scan cannot run.
        let older = try MeasureFixtures.items(store, company: acme, count: 1, now: now.addingTimeInterval(-30 * day))
        try MeasureFixtures.landEach(store, company: acme, items: older, at: [now.addingTimeInterval(-20 * day)], firstNumber: 10)
        let ctx = try context(store, acme)
        let noRepo = try ReviewMetrics.revertRate(ctx, detector: RevertDetector(git: ctx.git))
        guard case .notMeasured(let reason) = noRepo.status else { Issue.record("\(noRepo.status)"); return }
        #expect(reason.contains("no repository"), "\(reason)")
    }
}
