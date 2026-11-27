import Foundation
import Testing
@testable import BrahmaCore

/// The landing metrics of `brahma measure` (Plan X6a Task 3): green-main (metrics.md §1, ruling R17), first-pass (§7) and queue
/// health (§8). Store-only fixtures: every row the metrics read is written by `MeasureFixtures`, so each test owns its numbers.
/// A rate needs `MetricValue.minEvents` (20) events: the tests that assert a percentage seed 20 or more landings; the one that
/// seeds fewer asserts `insufficient`.
@Suite(.scratch) struct LandingMetricsTests {
    let now = MeasureFixtures.t0
    var window: MeasureWindow { MeasureWindow(since: now.addingTimeInterval(-30 * 86_400), until: now) }

    func context(_ store: Store, _ company: Company) throws -> MeasureContext {
        guard let fresh = try store.company(id: company.id) else { throw FakeError(description: "no company") }
        return MeasureContext(store: store, git: GitWorkspace(root: URL(fileURLWithPath: fresh.workspacePath)), company: fresh,
                              window: window, now: now)
    }

    /// `count` landings of one item each, numbered 1…count, landed one hour apart ending a day before `now`; each request was
    /// enqueued `queuedFor` seconds before it landed.
    func landings(_ store: Store, _ company: Company, count: Int, queuedFor: (Int) -> TimeInterval = { _ in 600 })
        throws -> [(batch: MergeBatch, request: MergeRequest, item: WorkItem)] {
        let items = try MeasureFixtures.items(store, company: company, count: count, now: now.addingTimeInterval(-10 * 86_400))
        return try items.enumerated().map { i, item in
            let landedAt = now.addingTimeInterval(-86_400 - Double(count - i) * 3600)
            let (batch, requests) = try MeasureFixtures.land(store, company: company, items: [item], number: i + 1,
                                                             enqueuedAt: landedAt.addingTimeInterval(-queuedFor(i + 1)), landedAt: landedAt)
            return (batch, requests[0], item)
        }
    }

    /// Every landing gets a passed, first-attempt, un-flaky `main` run at its land commit.
    func mainPasses(_ store: Store, _ company: Company, _ rows: [(batch: MergeBatch, request: MergeRequest, item: WorkItem)],
                    except: Set<Int> = []) throws {
        for row in rows where !except.contains(row.batch.number) {
            try MeasureFixtures.mergeRun(store, company: company, batch: row.batch, kind: .main, finishedAt: row.batch.finishedAt ?? now)
        }
    }

    func detailLabels(_ m: MetricValue) -> [String] { m.detail.map(\.label) }

    // MARK: green-main

    /// A main run that passed only on its second attempt is not green: the first attempt is the one that counts.
    @Test func greenMainCountsFirstAttemptOnly() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.company(store, name: "Acme")
        try MeasureFixtures.setMainCheck(store, company: acme)
        let rows = try landings(store, acme, count: 20)
        try mainPasses(store, acme, rows, except: [20])
        let late = rows[19]
        let t = late.batch.finishedAt ?? now
        try MeasureFixtures.mergeRun(store, company: acme, batch: late.batch, kind: .main, attempt: 1, status: .failed, finishedAt: t.addingTimeInterval(-60))
        try MeasureFixtures.mergeRun(store, company: acme, batch: late.batch, kind: .main, attempt: 2, status: .passed, finishedAt: t)

        let m = try LandingMetrics.greenMain(context(store, acme))
        #expect(m.id == .greenMain && m.unit == .ratio)
        #expect(m.status == .ok)
        #expect(m.numerator == 19 && m.denominator == 20)
        #expect(m.display == "95.0% (19/20)")
        #expect(detailLabels(m) == ["M-20: main run passed on attempt 2"], "\(detailLabels(m))")
        #expect(m.basis.contains("main check runs"), "\(m.basis)")
    }

    /// A pass flagged flaky (failed, then passed on the re-run) is not green, and the detail says so.
    @Test func flakyMainIsNotGreen() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.company(store, name: "Acme")
        try MeasureFixtures.setMainCheck(store, company: acme)
        let rows = try landings(store, acme, count: 20)
        try mainPasses(store, acme, rows, except: [7])
        let flaky = rows[6]
        let t = flaky.batch.finishedAt ?? now
        try MeasureFixtures.mergeRun(store, company: acme, batch: flaky.batch, kind: .main, attempt: 1, status: .failed, finishedAt: t.addingTimeInterval(-60))
        try MeasureFixtures.mergeRun(store, company: acme, batch: flaky.batch, kind: .main, attempt: 2, flaky: true, status: .passed, finishedAt: t)

        let m = try LandingMetrics.greenMain(context(store, acme))
        #expect(m.status == .ok)
        #expect(m.numerator == 19 && m.denominator == 20)
        let labels = detailLabels(m)
        #expect(labels.count == 1 && labels[0].hasPrefix("M-7: ") && labels[0].contains("flaky"), "\(labels)")
    }

    /// A failed `merge` smoke of the land commit makes an otherwise green landing not green. A failed smoke for another reason
    /// (`release`), a smoke at `error` (superseded, could not run) and a smoke of another commit say nothing.
    @Test func failedMergeSmokeIsNotGreen() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.company(store, name: "Acme")
        try MeasureFixtures.setMainCheck(store, company: acme)
        let rows = try landings(store, acme, count: 20)
        try mainPasses(store, acme, rows)
        func land(_ n: Int) -> String { rows[n - 1].batch.landCommit ?? "" }
        try MeasureFixtures.mainSmokeRun(store, company: acme, commit: land(3), status: .failed, finishedAt: now.addingTimeInterval(-3600))
        try MeasureFixtures.mainSmokeRun(store, company: acme, commit: land(4), status: .failed, reason: .release, finishedAt: now.addingTimeInterval(-3600))
        try MeasureFixtures.mainSmokeRun(store, company: acme, commit: land(5), status: .error, finishedAt: now.addingTimeInterval(-3600))
        try MeasureFixtures.mainSmokeRun(store, company: acme, commit: land(6), status: .passed, finishedAt: now.addingTimeInterval(-3600))
        try MeasureFixtures.mainSmokeRun(store, company: acme, commit: String(repeating: "f", count: 40), status: .failed, finishedAt: now.addingTimeInterval(-3600))

        let m = try LandingMetrics.greenMain(context(store, acme))
        #expect(m.status == .ok)
        #expect(m.numerator == 19 && m.denominator == 20)
        #expect(detailLabels(m) == ["M-3: merge smoke failed"], "\(detailLabels(m))")
    }

    /// With no smoke check configured (no `mainSmokeRun` rows at all) the main run alone decides: every landing is green.
    @Test func noSmokeConfiguredUsesMainRunOnly() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.company(store, name: "Acme")
        try MeasureFixtures.setMainCheck(store, company: acme)
        let rows = try landings(store, acme, count: 20)
        try mainPasses(store, acme, rows)

        let m = try LandingMetrics.greenMain(context(store, acme))
        #expect(m.status == .ok)
        #expect(m.display == "100.0% (20/20)")
        #expect(m.detail.isEmpty)
        #expect(m.basis.contains("main check runs") && !m.basis.contains("verification runs"), "\(m.basis)")
    }

    /// Ruling R17: with no main check configured a landing is judged by the batch's own verification — the `item`-kind runs at the
    /// land commit — passed first attempt, un-flaky; the basis names the source. A landing with no check run at all is excluded,
    /// never counted as green or red.
    @Test func noMainCheckUsesVerificationRuns() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.company(store, name: "Acme")
        let rows = try landings(store, acme, count: 22)
        for row in rows.prefix(20) {
            let t = row.batch.finishedAt ?? now
            if row.batch.number == 11 {
                try MeasureFixtures.mergeRun(store, company: acme, batch: row.batch, kind: .item, request: row.request, attempt: 1, status: .failed, finishedAt: t.addingTimeInterval(-60))
                try MeasureFixtures.mergeRun(store, company: acme, batch: row.batch, kind: .item, request: row.request, attempt: 2, flaky: true, status: .passed, finishedAt: t)
            } else {
                try MeasureFixtures.mergeRun(store, company: acme, batch: row.batch, kind: .item, request: row.request, finishedAt: t)
            }
            // `mainAtBase` runs tell a red main from a red candidate; they never judge a landing.
            try MeasureFixtures.mergeRun(store, company: acme, batch: row.batch, kind: .mainAtBase, candidateCommit: row.batch.base, status: .failed, finishedAt: t)
        }
        // Landings 21 and 22 have no run recorded at all.

        let m = try LandingMetrics.greenMain(context(store, acme))
        #expect(m.status == .ok)
        #expect(m.numerator == 19 && m.denominator == 20, "\(m.display)")
        #expect(m.basis.contains("no main check configured; verification runs"), "\(m.basis)")
        #expect(m.basis.contains("2 landings with no check run excluded"), "\(m.basis)")
        let labels = detailLabels(m)
        #expect(labels.count == 1 && labels[0].hasPrefix("M-11: ") && labels[0].contains("flaky"), "\(labels)")
    }

    /// Fewer than 20 landings: the count is shown as insufficient, never a percentage. No landings: not measured.
    @Test func fewLandingsAreInsufficient() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.company(store, name: "Acme")
        try MeasureFixtures.setMainCheck(store, company: acme)
        let none = try LandingMetrics.greenMain(context(store, acme))
        #expect(none.status == .notMeasured(reason: "no landings in the window"))

        let rows = try landings(store, acme, count: 3)
        try mainPasses(store, acme, rows)
        let m = try LandingMetrics.greenMain(context(store, acme))
        #expect(m.status == .insufficient(n: 3))
        #expect(m.display == "insufficient data (n=3)")
        #expect(m.numerator == 3 && m.denominator == 3)
    }

    // MARK: first-pass

    /// `itemFact.firstPass` over the landed items that have a fact row; a landed item without one is excluded and counted in the
    /// basis. The detail shows the check failures and review rejections behind the rate.
    @Test func firstPassFromFacts() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.company(store, name: "Acme")
        let items = try MeasureFixtures.items(store, company: acme, count: 25, now: now.addingTimeInterval(-10 * 86_400))
        let landedAt = now.addingTimeInterval(-2 * 86_400)
        try MeasureFixtures.land(store, company: acme, items: items, number: 1, enqueuedAt: landedAt.addingTimeInterval(-600), landedAt: landedAt)
        for (i, item) in items.enumerated() where i < 24 {
            try MeasureFixtures.fact(store, item: item, firstPass: i < 16, reviewRejections: i >= 20 ? 2 : 0, completedAt: landedAt)
        }
        // An item of another company with a fact never counts.
        let zeta = try MeasureFixtures.seed(store, name: "Zeta", landed: 4, now: now)
        #expect(zeta.id != acme.id)

        let m = try LandingMetrics.firstPass(context(store, acme))
        #expect(m.id == .firstPass && m.unit == .ratio)
        #expect(m.status == .ok)
        #expect(m.numerator == 16 && m.denominator == 24)
        #expect(m.display == "66.7% (16/24)")
        #expect(m.basis.contains("1 landed item without a fact row excluded"), "\(m.basis)")
        let failures = m.detail.first { $0.label == "check failures" }
        let rejections = m.detail.first { $0.label == "review rejections" }
        #expect(failures?.numerator == 8 && failures?.unit == .count, "\(String(describing: failures))")
        #expect(rejections?.numerator == 8 && rejections?.unit == .count, "\(String(describing: rejections))")
    }

    // MARK: queue health

    /// Durations 1…40 s from `enqueuedAt` to the landing: median 20.5, p95 (nearest rank) 38. A request enqueued after its landing
    /// is excluded from the durations and counted in the basis; wall seconds, stated (ruling R15).
    @Test func queueMedianAndP95() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.company(store, name: "Acme")
        _ = try landings(store, acme, count: 41) { n in n <= 40 ? Double(n) : -5 }

        let m = try LandingMetrics.queueHealth(context(store, acme))
        #expect(m.id == .queueHealth && m.unit == .count && m.status == .ok)
        #expect(m.numerator == 41, "merged requests in the window")
        let median = m.detail.first { $0.label.contains("median") }
        let p95 = m.detail.first { $0.label.contains("p95") }
        #expect(median?.unit == .seconds && median?.numerator == 20.5, "\(String(describing: median))")
        #expect(p95?.unit == .seconds && p95?.numerator == 38, "\(String(describing: p95))")
        #expect(median?.display == "20.5 s" && p95?.display == "38 s")
        for row in [median, p95] {
            #expect(row?.basis.contains("wall seconds (company-active time is recorded per day, not per request)") == true, "\(row?.basis ?? "nil")")
            #expect(row?.basis.contains("n=40") == true, "\(row?.basis ?? "nil")")
            #expect(row?.basis.contains("1 excluded") == true, "\(row?.basis ?? "nil")")
        }
    }

    /// A request bounced for a failed item or main check out of a batch of two or more is an isolation. One bounced alone, or
    /// bounced for a conflict, is not.
    @Test func bisectIsolationsCounted() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.company(store, name: "Acme")
        let items = try MeasureFixtures.items(store, company: acme, count: 6, now: now.addingTimeInterval(-10 * 86_400))
        let t = now.addingTimeInterval(-2 * 86_400)
        // Batch 1: two landed, one isolated for its item check.
        let (b1, _) = try MeasureFixtures.land(store, company: acme, items: [items[0], items[1]], number: 1, enqueuedAt: t.addingTimeInterval(-600), landedAt: t)
        try MeasureFixtures.bounce(store, company: acme, batch: b1, item: items[2], number: 103, failure: .itemCheckFailed, enqueuedAt: t.addingTimeInterval(-600), bouncedAt: t)
        // Batch 2: one landed, one isolated because the main check went red with it in.
        let (b2, _) = try MeasureFixtures.land(store, company: acme, items: [items[3]], number: 2, enqueuedAt: t.addingTimeInterval(-600), landedAt: t.addingTimeInterval(3600))
        try MeasureFixtures.bounce(store, company: acme, batch: b2, item: items[4], number: 202, failure: .mainCheckFailed, enqueuedAt: t.addingTimeInterval(-600), bouncedAt: t.addingTimeInterval(3600))
        // Batch 3: a lone request bounced for a conflict (no bisection), and a lone bounce of a batch of one.
        var lone = MergeBatch(companyId: acme.id, number: 3, step: .done, requestIds: [], startedAt: t)
        lone.updatedAt = t.addingTimeInterval(7200); lone.finishedAt = t.addingTimeInterval(7200)
        let loneRow = lone
        try store.writer.write { db in try loneRow.insert(db) }
        try MeasureFixtures.bounce(store, company: acme, batch: lone, item: items[5], number: 301, failure: .itemCheckFailed, enqueuedAt: t, bouncedAt: t.addingTimeInterval(7200))
        try MeasureFixtures.bounce(store, company: acme, batch: b1, item: items[5], number: 104, failure: .conflict, enqueuedAt: t, bouncedAt: t)

        let m = try LandingMetrics.queueHealth(context(store, acme))
        #expect(m.numerator == 3, "merged requests")
        let isolations = m.detail.first { $0.label == "bisect isolations" }
        #expect(isolations?.unit == .count && isolations?.status == .ok)
        #expect(isolations?.numerator == 2, "\(String(describing: isolations))")
    }

    /// Flaky ÷ finished runs over both tables: `mergeRun` (`main`, `item`; never `mainAtBase`) and `verificationRun`; `inconclusive`
    /// and `error` runs are not finished; a run outside the window does not count.
    @Test func flakeRateAcrossBothRunTables() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.company(store, name: "Acme")
        let rows = try landings(store, acme, count: 2)
        let t = now.addingTimeInterval(-86_400)
        let (b, r) = (rows[0].batch, rows[0].request)
        // 12 finished merge runs, 2 flaky.
        for i in 0..<12 {
            try MeasureFixtures.mergeRun(store, company: acme, batch: b, kind: i % 2 == 0 ? .main : .item, request: i % 2 == 0 ? nil : r,
                                         attempt: i < 2 ? 2 : 1, flaky: i < 2, status: i == 5 ? .failed : (i == 6 ? .timedOut : .passed), finishedAt: t)
        }
        // Not counted: a flaky mainAtBase run, an inconclusive run, an error run, a run before the window.
        try MeasureFixtures.mergeRun(store, company: acme, batch: b, kind: .mainAtBase, flaky: true, finishedAt: t)
        try MeasureFixtures.mergeRun(store, company: acme, batch: b, kind: .item, request: r, status: .inconclusive, finishedAt: t)
        try MeasureFixtures.mergeRun(store, company: acme, batch: b, kind: .main, status: .error, finishedAt: t)
        try MeasureFixtures.mergeRun(store, company: acme, batch: b, kind: .main, flaky: true, finishedAt: now.addingTimeInterval(-40 * 86_400))
        // 10 finished verification runs, 1 flaky; one inconclusive and one of another company do not count.
        for i in 0..<10 {
            try MeasureFixtures.verificationRun(store, company: acme, item: rows[1].item, purpose: i < 5 ? .submit : .merge,
                                                status: i == 3 ? .failed : .passed, attempt: i == 0 ? 2 : 1, flaky: i == 0, finishedAt: t)
        }
        try MeasureFixtures.verificationRun(store, company: acme, item: rows[1].item, status: .inconclusive, finishedAt: t)
        let zeta = try MeasureFixtures.company(store, name: "Zeta")
        let zItems = try MeasureFixtures.items(store, company: zeta, count: 1)
        try MeasureFixtures.verificationRun(store, company: zeta, item: zItems[0], flaky: true, finishedAt: t)

        let m = try LandingMetrics.queueHealth(context(store, acme))
        let flake = m.detail.first { $0.label == "flake rate" }
        #expect(flake?.unit == .ratio && flake?.status == .ok, "\(String(describing: flake))")
        #expect(flake?.numerator == 3 && flake?.denominator == 22, "\(String(describing: flake))")
        #expect(flake?.display == "13.6% (3/22)")
        #expect(flake?.basis.contains("mergeRun") == true && flake?.basis.contains("verificationRun") == true, "\(flake?.basis ?? "nil")")
    }

    /// Queue health with nothing landed: a count of 0 (counts are never insufficient), durations not measured.
    @Test func queueHealthWithNoLandings() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.company(store, name: "Acme")
        let m = try LandingMetrics.queueHealth(context(store, acme))
        #expect(m.status == .ok && m.numerator == 0 && m.display == "0")
        let durations = m.detail.first { $0.label.contains("approval") }
        #expect(durations?.status == .notMeasured(reason: "no merged requests in the window"), "\(String(describing: durations))")
    }

    // MARK: wiring

    /// The three functions are the report's for their ids; every other id still has an entry.
    @Test func reportWiresLandingMetrics() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.seed(store, name: "Acme", landed: 24, now: now)
        let report = try Measure.report(store: store, git: GitWorkspace(root: URL(fileURLWithPath: acme.workspacePath)),
                                        companyId: acme.id, window: window, now: now)
        let byId = Dictionary(uniqueKeysWithValues: report.metrics.map { ($0.id, $0) })
        #expect(byId[.firstPass] == (try LandingMetrics.firstPass(context(store, acme))))
        #expect(byId[.greenMain] == (try LandingMetrics.greenMain(context(store, acme))))
        #expect(byId[.queueHealth] == (try LandingMetrics.queueHealth(context(store, acme))))
        #expect(byId[.firstPass]?.status == .ok)
        #expect(byId[.firstPass]?.numerator == 12 && byId[.firstPass]?.denominator == 24)
        for id in MetricId.all { #expect(Measure.functions[id] != nil, "\(id.rawValue)") }
    }
}
