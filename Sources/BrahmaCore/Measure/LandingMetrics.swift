import Foundation
import GRDB

/// The landing metrics of `brahma measure` (Plan X6a Task 3): green-main (`docs/measure/metrics.md` §1, ruling R17), first-pass (§7)
/// and queue health (§8). Every landing comes from `Store.landings` (the one landing query, rulings R13/R20/R24), read in the same
/// transaction as the runs and facts joined to it; every other query is `WHERE companyId = ?` with bound parameters. Nothing here estimates: a landing without the record a metric needs is excluded and
/// counted in the basis, never scored.
public enum LandingMetrics {
    // MARK: Green-main

    /// Landings after which the main check passed on the first run ÷ landings judged. The source rule (ruling R17):
    /// 1. If the batch has a `main`-kind `mergeRun` (recorded only when `company.mainCheck` is set), the landing is green when the
    ///    run at `candidateCommit = landCommit`, `attempt = 1` passed and was not flaky. A pass on a later attempt, a flaky pass or a
    ///    failure is not green.
    /// 2. Otherwise the batch's own verification judges it: the `item`-kind runs at `landCommit` for the landed requests, each
    ///    passed at `attempt = 1`, un-flaky, with no re-run. (`mainAtBase` runs tell a red main from a red candidate and never judge
    ///    a landing; a `verificationRun` with purpose `merge` is 3a's per-item re-check after a rebase, not the batch's.)
    /// 3. Either way, a `mainSmokeRun` with `reason = 'merge'` at `landCommit` that `failed` makes the landing not green; `error`
    ///    (superseded, could not run) says nothing.
    /// A landing with neither a `main` nor an `item` run is excluded from the denominator and counted in the basis.
    public static func greenMain(_ ctx: MeasureContext) throws -> MetricValue {
        try ctx.store.writer.read { db in
            let landings = try Store.landings(db, companyId: ctx.companyId, in: ctx.window)
            guard !landings.isEmpty else { return .notMeasured(.greenMain, reason: "no landings in the window") }
            var green = 0, byMain = 0, byVerification = 0, unjudged = 0
            var detail: [MetricValue] = []
            for landing in landings {
                guard var verdict = try checkVerdict(db, companyId: ctx.companyId, landing: landing) else {
                    unjudged += 1
                    continue
                }
                switch verdict.source {
                case .mainRuns: byMain += 1
                case .itemRuns: byVerification += 1
                }
                if try mergeSmokeFailed(db, companyId: ctx.companyId, commit: landing.landCommit) {
                    verdict.reasons.append("merge smoke failed")
                }
                if verdict.reasons.isEmpty {
                    green += 1
                } else {
                    // One row per non-green landing; its value is that one landing.
                    detail.append(.count(.greenMain, label: "M-\(landing.number): \(verdict.reasons.joined(separator: "; "))", 1,
                                         basis: "not green; landed \(landing.landCommit.prefix(7)) at \(MeasureReport.iso(landing.finishedAt))"))
                }
            }
            let judged = byMain + byVerification
            guard judged > 0 else {
                return .notMeasured(.greenMain, reason: "no check run recorded for the \(plural(landings.count, "landing")) in the window",
                                    basis: "landings in the window (\(landings.count)); a landing is judged by its main check run, else by "
                                        + "its item check runs at the land commit")
            }
            let source: String
            switch (byMain, byVerification) {
            case (_, 0): source = "main check runs"
            case (0, _):
                // Whether a main check is configured now says nothing about when these batches ran; the runs are the record.
                source = "no main check run recorded; verification runs (item checks at the land commit)"
            default: source = "main check runs for \(byMain), verification runs (item checks at the land commit) for \(byVerification)"
            }
            var basis = "landings in the window judged by \(source) (\(judged)); a failed merge smoke of the land commit counts against"
            if unjudged > 0 { basis += "; \(plural(unjudged, "landing")) with no check run excluded" }
            return .rate(.greenMain, numerator: Double(green), denominator: Double(judged), unit: .ratio, basis: basis, detail: detail)
        }
    }

    enum CheckSource { case mainRuns, itemRuns }

    struct CheckVerdict {
        var source: CheckSource
        /// Empty when the checks say green.
        var reasons: [String]
    }

    /// Step 1 or 2 of the source rule; nil when the batch has no run of either kind.
    static func checkVerdict(_ db: Database, companyId: String, landing: Landing) throws -> CheckVerdict? {
        let mainRuns = try MergeRun.fetchAll(db, sql: """
            SELECT * FROM mergeRun WHERE companyId = ? AND batchId = ? AND kind = 'main' ORDER BY attempt, finishedAt
            """, arguments: [companyId, landing.batchId])
        if !mainRuns.isEmpty {
            let atLand = mainRuns.filter { $0.candidateCommit == landing.landCommit }
            return CheckVerdict(source: .mainRuns, reasons: firstAttemptVerdict(atLand, what: "main run").map { [$0] } ?? [])
        }
        let itemRuns = try MergeRun.fetchAll(db, sql: """
            SELECT * FROM mergeRun WHERE companyId = ? AND batchId = ? AND kind = 'item' AND candidateCommit = ? ORDER BY attempt, finishedAt
            """, arguments: [companyId, landing.batchId, landing.landCommit])
        guard !itemRuns.isEmpty else { return nil }
        var reasons: [String] = []
        for item in landing.items {
            let own = itemRuns.filter { $0.requestId == item.requestId }
            // A landed item with no check of its own (no `checkSpec`) is not evidence either way.
            guard !own.isEmpty else { continue }
            if let why = firstAttemptVerdict(own, what: "item check of \(item.key)") { reasons.append(why) }
        }
        return CheckVerdict(source: .itemRuns, reasons: reasons)
    }

    /// Why the runs of one check at one candidate are not a clean first pass; nil when they are.
    static func firstAttemptVerdict(_ runs: [MergeRun], what: String) -> String? {
        guard let first = runs.first(where: { $0.attempt == 1 }) else { return "no first-attempt \(what) for the land commit" }
        if let later = runs.first(where: { $0.attempt > 1 && $0.status == .passed }) {
            return later.flaky ? "\(what) flaky (passed on attempt \(later.attempt))" : "\(what) passed on attempt \(later.attempt)"
        }
        if first.status == .passed { return first.flaky ? "\(what) flaky" : nil }
        switch first.status {
        case .failed: return "\(what) failed"
        case .timedOut: return "\(what) timed out"
        case .some(let other): return "\(what) \(other.rawValue)"
        case .none: return "\(what) has no status"
        }
    }

    /// True when the `merge` smoke of `commit` failed (`error` and an absent row say nothing).
    static func mergeSmokeFailed(_ db: Database, companyId: String, commit: String) throws -> Bool {
        let failed = try Int.fetchOne(db, sql: """
            SELECT COUNT(*) FROM mainSmokeRun WHERE companyId = ? AND "commit" = ? AND reason = 'merge' AND status = 'failed'
            """, arguments: [companyId, commit])
        return (failed ?? 0) > 0
    }

    // MARK: First-pass

    /// `itemFact.firstPass` over the landed items in the window that have a fact row (metrics.md §7). Items without one are excluded
    /// and counted in the basis; the detail shows the check failures and review rejections the facts recorded.
    public static func firstPass(_ ctx: MeasureContext) throws -> MetricValue {
        try ctx.store.writer.read { db in
            let landings = try Store.landings(db, companyId: ctx.companyId, in: ctx.window)
            guard !landings.isEmpty else { return .notMeasured(.firstPass, reason: "no landings in the window") }
            var seen = Set<String>()
            let itemIds = landings.flatMap(\.items).map(\.itemId).filter { seen.insert($0).inserted }
            var facts = 0, passed = 0, failedRuns = 0, rejections = 0
            for chunk in chunks(itemIds) {
                let marks = chunk.map { _ in "?" }.joined(separator: ", ")
                for row in try Row.fetchAll(db, sql: """
                    SELECT firstPass, failedRuns, reviewRejections FROM itemFact WHERE companyId = ? AND itemId IN (\(marks))
                    """, arguments: StatementArguments([ctx.companyId]) + StatementArguments(chunk)) {
                    facts += 1
                    if row["firstPass"] as Bool { passed += 1 }
                    failedRuns += row["failedRuns"] as Int
                    rejections += row["reviewRejections"] as Int
                }
            }
            let missing = itemIds.count - facts
            guard facts > 0 else {
                return .notMeasured(.firstPass, reason: "no itemFact row for the \(plural(itemIds.count, "landed item")) in the window")
            }
            var basis = "landed items in the window with an itemFact row (\(facts))"
            if missing > 0 { basis += "; \(plural(missing, "landed item")) without a fact row excluded" }
            let detail: [MetricValue] = [
                .count(.firstPass, label: "check failures", Double(failedRuns),
                       basis: "Σ itemFact.failedRuns over the \(facts) landed items with a fact row"),
                .count(.firstPass, label: "review rejections", Double(rejections),
                       basis: "Σ itemFact.reviewRejections over the \(facts) landed items with a fact row"),
            ]
            return .rate(.firstPass, numerator: Double(passed), denominator: Double(facts), unit: .ratio, basis: basis, detail: detail)
        }
    }

    // MARK: Queue health

    /// The headline is the count of merged requests whose landing is in the window. Detail (metrics.md §8): approval → land median and
    /// p95 (nearest rank) in wall seconds from `mergeRequest.enqueuedAt` to the item's landing time (`mergeRequest.finishedAt`, else
    /// the batch's). Ruling R15 falls back to wall seconds with the basis stated: `companyActivity` is a running total and the
    /// `activeSeconds` counter is daily, so no record gives one request's company-active seconds, and none is estimated. Then bisect
    /// isolations and the flake rate over `mergeRun` and `verificationRun`.
    public static func queueHealth(_ ctx: MeasureContext) throws -> MetricValue {
        try ctx.store.writer.read { db in
            let landings = try Store.landings(db, companyId: ctx.companyId, in: ctx.window)
            let landed = landings.flatMap { landing in landing.items.map { (item: $0, landedAt: $0.landedAt) } }
            var detail = try durations(db, ctx: ctx, landed: landed)
            detail.append(try bisectIsolations(db, ctx: ctx))
            detail.append(try flakeRate(db, ctx: ctx))
            return .count(.queueHealth, Double(landed.count),
                          basis: "merged requests of the landings whose batch finishedAt (else updatedAt) is in the window, from "
                              + "\(plural(landings.count, "landing")); the durations end at each request's finishedAt (else the batch's)",
                          detail: detail)
        }
    }

    /// Approval → land, median and p95, as two `seconds` rows; `not measured` with no merged request.
    static func durations(_ db: Database, ctx: MeasureContext, landed: [(item: LandedItem, landedAt: Date)]) throws -> [MetricValue] {
        guard !landed.isEmpty else {
            return [.notMeasured(.queueHealth, label: "approval → land", reason: "no merged requests in the window")]
        }
        var enqueued: [String: Date] = [:]
        for chunk in chunks(landed.map(\.item.requestId)) {
            let marks = chunk.map { _ in "?" }.joined(separator: ", ")
            for row in try Row.fetchAll(db, sql: "SELECT id, enqueuedAt FROM mergeRequest WHERE companyId = ? AND id IN (\(marks))",
                                        arguments: StatementArguments([ctx.companyId]) + StatementArguments(chunk)) {
                enqueued[row["id"]] = row["enqueuedAt"]
            }
        }
        var seconds: [Double] = []
        var excluded = 0
        for entry in landed {
            // A request enqueued after its landing (a clock that moved) is excluded, never clamped.
            guard let at = enqueued[entry.item.requestId], at <= entry.landedAt else { excluded += 1; continue }
            seconds.append(entry.landedAt.timeIntervalSince(at))
        }
        guard !seconds.isEmpty else {
            return [.notMeasured(.queueHealth, label: "approval → land", reason: "no merged request with a usable enqueue time",
                                 basis: "\(excluded) excluded (enqueued after the landing or no enqueue time)")]
        }
        seconds.sort()
        var basis = "wall seconds (company-active time is recorded per day, not per request) from mergeRequest.enqueuedAt to the "
            + "landing (mergeRequest.finishedAt, else the batch's); n=\(seconds.count)"
        if excluded > 0 { basis += "; \(excluded) excluded (enqueued after the landing or no enqueue time)" }
        return [
            .seconds(.queueHealth, label: "approval → land, median", median(seconds), basis: basis),
            .seconds(.queueHealth, label: "approval → land, p95", nearestRank(seconds, 0.95), basis: basis),
        ]
    }

    /// Requests the bisection bounced for a failed item or main check out of a batch of two or more checked candidates, by bounce
    /// time (metrics.md §8). The size is `mergeBatch.candidates` (the members that rebased and were checked, written at `rebased`),
    /// not `requestIds`, which also holds requests bounced on a conflict before any check. A request bounced from a batch of one
    /// checked candidate, or for a conflict or a secret, is not an isolation.
    static func bisectIsolations(_ db: Database, ctx: MeasureContext) throws -> MetricValue {
        let bounced = try Row.fetchAll(db, sql: """
            SELECT id, batchId FROM mergeRequest
            WHERE companyId = ? AND status = 'bounced' AND failure IN ('itemCheckFailed', 'mainCheckFailed') AND batchId IS NOT NULL
              AND finishedAt >= ? AND finishedAt < ?
            """, arguments: [ctx.companyId, ctx.window.since, ctx.window.until])
        let batchIds = Array(Set(bounced.map { $0["batchId"] as String }))
        var sizes: [String: Int] = [:]
        for chunk in chunks(batchIds) {
            let marks = chunk.map { _ in "?" }.joined(separator: ", ")
            for b in try MergeBatch.fetchAll(db, sql: "SELECT * FROM mergeBatch WHERE companyId = ? AND id IN (\(marks))",
                                             arguments: StatementArguments([ctx.companyId]) + StatementArguments(chunk)) {
                sizes[b.id] = b.candidates.count
            }
        }
        var isolated = 0, alone = 0
        for row in bounced {
            if (sizes[row["batchId"] as String] ?? 0) >= 2 { isolated += 1 } else { alone += 1 }
        }
        var basis = "requests bounced for a failed item or main check from a batch of ≥ 2 checked candidates, by bounce time"
        if alone > 0 { basis += "; \(alone) bounced from a batch of one checked candidate (not an isolation)" }
        return .count(.queueHealth, label: "bisect isolations", Double(isolated), basis: basis)
    }

    /// Flaky ÷ finished runs (`passed`, `failed`, `timedOut`) finishing in the window over `mergeRun` (`main`, `item`) and
    /// `verificationRun`.
    static func flakeRate(_ db: Database, ctx: MeasureContext) throws -> MetricValue {
        let args: StatementArguments = [ctx.companyId, ctx.window.since, ctx.window.until]
        let merge = try Row.fetchOne(db, sql: """
            SELECT COUNT(*) AS n, COALESCE(SUM(CASE WHEN flaky THEN 1 ELSE 0 END), 0) AS flaky FROM mergeRun
            WHERE companyId = ? AND kind IN ('main', 'item') AND status IN ('passed', 'failed', 'timedOut') AND finishedAt >= ? AND finishedAt < ?
            """, arguments: args)
        let verify = try Row.fetchOne(db, sql: """
            SELECT COUNT(*) AS n, COALESCE(SUM(CASE WHEN flaky THEN 1 ELSE 0 END), 0) AS flaky FROM verificationRun
            WHERE companyId = ? AND status IN ('passed', 'failed', 'timedOut') AND finishedAt >= ? AND finishedAt < ?
            """, arguments: args)
        let mergeN = merge.map { $0["n"] as Int } ?? 0, mergeFlaky = merge.map { $0["flaky"] as Int } ?? 0
        let verifyN = verify.map { $0["n"] as Int } ?? 0, verifyFlaky = verify.map { $0["flaky"] as Int } ?? 0
        let finished = mergeN + verifyN
        let basis = "flaky ÷ finished runs (passed, failed, timedOut) finishing in the window: mergeRun (main, item) \(mergeFlaky)/\(mergeN) "
            + "+ verificationRun \(verifyFlaky)/\(verifyN)"
        guard finished > 0 else { return .notMeasured(.queueHealth, label: "flake rate", reason: "no finished check run in the window", basis: basis) }
        return .rate(.queueHealth, label: "flake rate", numerator: Double(mergeFlaky + verifyFlaky), denominator: Double(finished),
                     unit: .ratio, basis: basis)
    }

    // MARK: Helpers

    /// The median of sorted values: the middle one, or the mean of the two middle ones.
    static func median(_ sorted: [Double]) -> Double {
        precondition(!sorted.isEmpty)
        let mid = sorted.count / 2
        return sorted.count % 2 == 1 ? sorted[mid] : (sorted[mid - 1] + sorted[mid]) / 2
    }

    /// The nearest-rank percentile of sorted values: the value at rank ⌈p·n⌉ (1-based); `1…40` at 0.95 is 38.
    static func nearestRank(_ sorted: [Double], _ p: Double) -> Double {
        precondition(!sorted.isEmpty)
        let rank = Int((p * Double(sorted.count)).rounded(.up))
        return sorted[max(0, min(sorted.count - 1, rank - 1))]
    }

    /// `IN (…)` lists in chunks: SQLite's bound-parameter limit is 999 on older builds.
    static func chunks(_ ids: [String], size: Int = 500) -> [[String]] {
        stride(from: 0, to: ids.count, by: size).map { Array(ids[$0..<min($0 + size, ids.count)]) }
    }

    static func plural(_ n: Int, _ noun: String) -> String { "\(n) \(noun)\(n == 1 ? "" : "s")" }
}
