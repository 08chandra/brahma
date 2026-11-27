import Foundation
import GRDB

/// The usage metrics of `brahma measure` (Plan X6a Task 5): usage per landed item (`docs/measure/metrics.md` §5), owner touches
/// (§6), safety (§9), non-code acceptance (§10), model ranking per role (§11, `ModelRanking.swift`), idle while actionable (§12),
/// landed items per $LE and per plan-hour (§13, owner ruling R7(a)) and owner minutes per landed item (§14, owner ruling R7(d)).
///
/// Landings come from `Store.landings` through `ReviewMetrics.landedItems` (the one landing query, rulings R13/R20/R24), indexed
/// once and read in the same snapshot as the rows joined to them: one `writer.read` per metric. Every query is `WHERE companyId = ?`
/// with bound parameters, except three owner-wide records that have no company: `sandboxCanary` (one sandbox per Mac), the
/// `reserveBreaches` counter under company id "" (the usage snapshot is the owner's account) and `measureEpoch` (when the
/// recorder began); each says `owner-wide` in its basis. X1 is not merged (ruling R4): every gateway leg is
/// `not applicable: X1 gateway columns absent`. Detail rows are labelled with engine words, roles and model families, never with
/// agent-written text. Nothing is estimated.
public enum UsageMetrics {
    static let gatewayAbsent = "X1 gateway columns absent"
    static let gatewayBasis = "ruling R4: turn.meteredUSD, itemFact.meteredUSD, gatewayCharge and providerCap are X1's and not merged, "
        + "so every turn on this build is a subscription turn; its costUSD/costLE is the subscription leg, never a gateway dollar"
    static let noLandings = "no landings in the window"
    static let noFacts = "no item facts for the landed items in the window"
    static let noActive = "no active-seconds records in window"

    // MARK: Usage per landed item

    /// Σ `itemFact.costLE` ÷ landed items with a fact (the one denominator of every leg); review $LE beside it; turns, tokens and
    /// awake seconds per landed item; the gateway leg not applicable.
    public static func usagePerLanded(_ ctx: MeasureContext) throws -> MetricValue {
        try ctx.store.writer.read { db in
            let landed = try ReviewMetrics.landedItems(db, companyId: ctx.companyId, in: ctx.window)
            guard !landed.isEmpty else { return .notMeasured(.usagePerLanded, reason: noLandings) }
            let facts = try Self.facts(db, companyId: ctx.companyId, itemIds: Array(landed.keys))
            guard !facts.isEmpty else {
                return .notMeasured(.usagePerLanded, reason: noFacts,
                                    basis: "\(LandingMetrics.plural(landed.count, "landed item")) in the window, none with an item fact")
            }
            let rows = Array(facts.values)
            let n = Double(rows.count)
            let cost = rows.reduce(0) { $0 + $1.costLE }, reviewCost = rows.reduce(0) { $0 + $1.reviewCostLE }
            let turns = rows.reduce(0) { $0 + Double($1.turnsUsed) }, tokens = rows.reduce(0) { $0 + Double($1.tokensUsed) }
            let awake = rows.reduce(0) { $0 + Double($1.cycleActiveSeconds ?? 0) }
            let neverClaimed = rows.filter { $0.cycleActiveSeconds == nil }.count
            var basis = "$LE (subscription): Σ itemFact.costLE of the landed items in the window with an item fact (\(rows.count)) ÷ "
                + "those items; review $LE shown beside it; one denominator for every leg; $ (gateway) not applicable (\(gatewayAbsent))"
            basis += excludedWithoutFact(landed.count - rows.count)
            var awakeBasis = "Σ itemFact.cycleActiveSeconds (company-active seconds from first claim to completion) ÷ the same items"
            if neverClaimed > 0 { awakeBasis += "; \(LandingMetrics.plural(neverClaimed, "item")) never claimed contribute 0" }
            let detail: [MetricValue] = [
                .rate(.usagePerLanded, label: "$LE (subscription)", numerator: cost, denominator: n, unit: .usd,
                      basis: "Σ itemFact.costLE (the item's counted work turns) ÷ landed items with a fact"),
                .rate(.usagePerLanded, label: "review $LE (subscription)", numerator: reviewCost, denominator: n, unit: .usd,
                      basis: "Σ itemFact.reviewCostLE (review turns, not in costLE) ÷ the same items"),
                .notApplicable(.usagePerLanded, label: "$ (gateway)", reason: gatewayAbsent, basis: gatewayBasis),
                .rate(.usagePerLanded, label: "turns", numerator: turns, denominator: n, unit: .perItem,
                      basis: "Σ itemFact.turnsUsed (work turns; infra failures and session resets excluded) ÷ the same items"),
                .rate(.usagePerLanded, label: "tokens", numerator: tokens, denominator: n, unit: .perItem,
                      basis: "Σ itemFact.tokensUsed (input + output + cache creation; ultra turns and cache reads excluded) ÷ the same items"),
                .rate(.usagePerLanded, label: "awake seconds", numerator: awake, denominator: n, unit: .perItem, basis: awakeBasis),
            ]
            return .rate(.usagePerLanded, numerator: cost, denominator: n, unit: .usd, basis: basis, detail: detail)
        }
    }

    // MARK: Owner touches

    /// (Asks the owner decided in the window + the owner's own messages in the window) ÷ landed items in the window.
    public static func ownerTouches(_ ctx: MeasureContext) throws -> MetricValue {
        try ctx.store.writer.read { db in
            let w = ctx.window
            let landed = try ReviewMetrics.landedItems(db, companyId: ctx.companyId, in: w)
            // An access preset also stamps ownerDecidedAt (`decidedBy = 'preset:…'`): only `owner` is the owner's own touch.
            let asks = try count(db, """
                SELECT COUNT(*) FROM ask WHERE companyId = ? AND decidedBy = 'owner' AND ownerDecidedAt >= ? AND ownerDecidedAt < ?
                """, [ctx.companyId, w.since, w.until])
            let messages = try count(db, """
                SELECT COUNT(*) FROM message WHERE companyId = ? AND senderId = 'owner' AND kind <> 'system' AND createdAt >= ? AND createdAt < ?
                """, [ctx.companyId, w.since, w.until])
            // `commented` only: a review comment also writes a `commented` beside its `reviewComment` (C5b), one comment.
            let comments = try count(db, """
                SELECT COUNT(*) FROM workItemEvent
                WHERE companyId = ? AND actorId = 'owner' AND kind = 'commented' AND createdAt >= ? AND createdAt < ?
                """, [ctx.companyId, w.since, w.until])
            let detail: [MetricValue] = [
                .count(.ownerTouches, label: "inbox decisions", Double(asks),
                       basis: "asks with ownerDecidedAt in the window and decidedBy = owner (not policy, preset or internal decisions)"),
                .count(.ownerTouches, label: "owner messages", Double(messages),
                       basis: "messages from the owner created in the window (engine lines excluded)"),
                .count(.ownerTouches, label: "owner comments on items", Double(comments),
                       basis: "the owner's comments on work items in the window; listed, not in the rate"),
            ]
            let basis = "inbox decisions (\(asks)) + owner messages (\(messages)) in the window ÷ landed items in the window (\(landed.count)); "
                + "engine-alert acknowledgements and owner comments on items are not touches"
            guard !landed.isEmpty else { return .notMeasured(.ownerTouches, reason: noLandings, basis: basis, detail: detail) }
            return .rate(.ownerTouches, numerator: Double(asks + messages), denominator: Double(landed.count), unit: .perItem,
                         basis: basis, detail: detail)
        }
    }

    // MARK: Safety

    /// The two target-0 rows of `safety` the mission subset also shows (`MissionReport`), by their label.
    static let wastedLabel = "turns wasted on rate limits"
    static let breachesLabel = "reserve breaches"

    /// Counts with targets, never rates. The headline is the measured target-0 events (reserve breaches, turns wasted on rate
    /// limits); every row is shown with its own source, and a row with no source says so.
    public static func safety(_ ctx: MeasureContext) throws -> MetricValue {
        let tz = ctx.store.ownerTimeZone()
        return try ctx.store.writer.read { db in
            let (id, w) = (MetricId.safety, ctx.window)
            // Exactly the refusal's own reason (ruling R33): the owner's trust-import writes `trustImport`.
            let taint = try count(db, """
                SELECT COUNT(*) FROM turn WHERE companyId = ? AND freshSessionReason = 'tainted' AND startedAt >= ? AND startedAt < ?
                """, [ctx.companyId, w.since, w.until])
            let access = try count(db, "SELECT COUNT(*) FROM accessRefusal WHERE companyId = ? AND createdAt >= ? AND createdAt < ?",
                                   [ctx.companyId, w.since, w.until])
            let dlp = try count(db, """
                SELECT COUNT(*) FROM mergeRequest WHERE companyId = ? AND failure = 'secretFound' AND finishedAt >= ? AND finishedAt < ?
                """, [ctx.companyId, w.since, w.until])
            // Owner-wide: `sandboxCanary` has no company id (one sandbox check per Mac and CLI, shared by every company).
            let canary = try count(db, "SELECT COUNT(*) FROM sandboxCanary WHERE passedAt >= ? AND passedAt < ?", [w.since, w.until])
            let wasted = try count(db, """
                SELECT COUNT(*) FROM turn WHERE companyId = ? AND outcome = 'usageLimited' AND startedAt >= ? AND startedAt < ?
                """, [ctx.companyId, w.since, w.until])

            let breaches: MetricValue
            var breachCount: Double? = nil
            if let start = try MeasureRecorder.recorderStart(db) {
                // Owner-wide counter, company id "": the usage snapshot is the owner's account.
                let total = try Store.counterTotal(db, companyId: MeasureCounter.ownerWide, name: MeasureCounter.reserveBreaches, in: w, tz: tz)
                var basis = "owner-wide: usage snapshots of the owner's account observed at or past the owner reserve line "
                    + "(seven-day utilization ≥ 1 − reserve), one per new snapshot, shown in every company's report"
                if start > w.since { basis += "; recorded since \(Store.measureDay(start, in: tz))" }
                breaches = .count(id, label: breachesLabel, total.sum, basis: basis, target: 0)
                breachCount = total.sum
            } else {
                breaches = .notMeasured(id, label: breachesLabel, reason: "recorder not running",
                                        basis: "owner-wide; the measure recorder has never run on this database")
            }
            let detail: [MetricValue] = [
                .count(id, label: "taint refusals", Double(taint),
                       basis: "turns started fresh after a refused high-risk call under taint (freshSessionReason = tainted); one per refused turn, "
                        + "not per call; the owner's trust-import resets carry their own reason (trustImport) and are not counted, but "
                        + "trust-import resets recorded before vX6a stored 'tainted' and are counted"),
                .count(id, label: "access refusals", Double(access), basis: "refused request_access calls (accessRefusal)"),
                .count(id, label: "DLP hits", Double(dlp), basis: "merge requests bounced for a secret (failure = secretFound)"),
                .count(id, label: "canary passes", Double(canary),
                       basis: "owner-wide: sandbox canary passes in the window (sandboxCanary has no company; a re-pass replaces the earlier row)"),
                .notApplicable(id, label: "canary failures", reason: "canary failures are not recorded (sandboxCanary keeps passes only)"),
                breaches,
                .notApplicable(id, label: "cap overruns",
                               reason: "no cap-overrun record (X1 providerCap and gatewayCharge absent; the scheduler never admits above a mode cap)"),
                .count(id, label: wastedLabel, Double(wasted),
                       basis: "turns the rate limit rejected (outcome = usageLimited)", target: 0),
                .notApplicable(id, label: "channel refusals", reason: "channels (X4) absent"),
            ]
            var basis = "target-0 events in the window: turns wasted on rate limits (\(wasted))"
            if let breachCount { basis += " + reserve breaches (owner-wide, \(MetricValue.plain(breachCount)))" }
            else { basis += "; reserve breaches not measured (recorder not running)" }
            basis += "; cap overruns not applicable; the other rows are counts without a target"
            return .count(id, Double(wasted) + (breachCount ?? 0), basis: basis, target: 0, detail: detail)
        }
    }

    // MARK: Non-code acceptance

    /// Owner sign-off on `landGate: owner` items and rubric pass rate need item types and checks this build does not have (X3):
    /// not applicable. The owner's gate decisions are shown as detail, approved of decided per kind, never as the rate.
    public static func nonCode(_ ctx: MeasureContext) throws -> MetricValue {
        try ctx.store.writer.read { db in
            let gates = AskKind.gates.map(\.rawValue)
            let marks = gates.map { _ in "?" }.joined(separator: ", ")
            let rows = try Row.fetchAll(db, sql: """
                SELECT kind, status FROM ask
                WHERE companyId = ? AND decidedBy = 'owner' AND ownerDecidedAt >= ? AND ownerDecidedAt < ? AND kind IN (\(marks))
                """, arguments: [ctx.companyId, ctx.window.since, ctx.window.until] + StatementArguments(gates))
            var decided: [String: Int] = [:], approved: [String: Int] = [:]
            for row in rows {
                let kind: String = row["kind"]
                decided[kind, default: 0] += 1
                if (row["status"] as String) == AskStatus.approved.rawValue { approved[kind, default: 0] += 1 }
            }
            // Engine-owned kind names, in the gate order.
            let detail = gates.compactMap { kind -> MetricValue? in
                guard let n = decided[kind] else { return nil }
                let yes = approved[kind] ?? 0
                return .count(.nonCode, label: "\(kind) gate asks approved", Double(yes),
                              basis: "\(yes) of \(n) decided by the owner in the window; detail only, not the metric")
            }
            return .notApplicable(.nonCode, reason: "landGate items and rubric checks absent",
                                  basis: "owner sign-off on landGate: owner items and the rubric pass rate need item types and checks this "
                                      + "build does not have (X3); the owner's gate decisions are shown as detail",
                                  detail: detail)
        }
    }

    // MARK: Idle while actionable

    /// Σ `idleActionableSeconds` ÷ Σ `activeSeconds` over the window's days, both kept by the measure recorder (ruling R15).
    public static func idleActionable(_ ctx: MeasureContext) throws -> MetricValue {
        let tz = ctx.store.ownerTimeZone()
        return try ctx.store.writer.read { db in
            let active = try Store.counterTotal(db, companyId: ctx.companyId, name: MeasureCounter.activeSeconds, in: ctx.window, tz: tz)
            guard active.rows > 0 else {
                return .notMeasured(.idleActionable, reason: noActive,
                                    basis: "the measure recorder keeps company-active seconds per day; no day of the window has a record")
            }
            func seconds(_ name: String) throws -> Double {
                try Store.counterTotal(db, companyId: ctx.companyId, name: name, in: ctx.window, tz: tz).sum
            }
            let idle = try seconds(MeasureCounter.idleActionableSeconds)
            var basis = "company-active seconds with no running turn while an agent waited on usage (blocked by the five-hour gate, or "
                + "ready but held by the weekly pace or the owner reserve) ÷ company-active seconds, from the recorder's daily counters "
                + "; n = days with active-seconds records (\(active.rows)); cap closures (X1) absent"
            basis += try recordedSince(db, companyId: ctx.companyId, window: ctx.window, tz: tz)
            let detail: [MetricValue] = [
                .seconds(.idleActionable, label: "five-hour gate", try seconds(MeasureCounter.idleUsageLimitSeconds),
                         basis: "an agent blocked by the five-hour usage gate (usageLimit)"),
                .seconds(.idleActionable, label: "weekly pace", try seconds(MeasureCounter.idlePaceSeconds),
                         basis: "a ready agent held by the weekly pace (paceClosed)"),
                .seconds(.idleActionable, label: "owner reserve", try seconds(MeasureCounter.idleReserveSeconds),
                         basis: "a ready agent held because the owner reserve is reached (paceStrict)"),
            ]
            // Ruling R32: the events are the recorded days, not the seconds.
            return .rate(.idleActionable, numerator: idle, denominator: active.sum, unit: .ratio, basis: basis, detail: detail, events: active.rows)
        }
    }

    // MARK: Items per $LE and per plan-hour

    /// Landed items with a fact ÷ Σ their `itemFact.costLE`, labelled `$LE (subscription)`; the gateway leg not applicable.
    public static func itemsPerDollar(_ ctx: MeasureContext) throws -> MetricValue {
        try ctx.store.writer.read { db in
            let landed = try ReviewMetrics.landedItems(db, companyId: ctx.companyId, in: ctx.window)
            let gateway = MetricValue.notApplicable(.itemsPerDollar, label: "$ (gateway)", reason: gatewayAbsent, basis: gatewayBasis)
            guard !landed.isEmpty else { return .notMeasured(.itemsPerDollar, reason: noLandings, detail: [gateway]) }
            let facts = try Self.facts(db, companyId: ctx.companyId, itemIds: Array(landed.keys))
            let cost = facts.values.reduce(0) { $0 + $1.costLE }
            var basis = "$LE (subscription): landed items in the window with an item fact (\(facts.count)) ÷ Σ itemFact.costLE of those "
                + "items (\(MetricValue.fixed(cost, 2)))"
            basis += excludedWithoutFact(landed.count - facts.count)
            guard cost > 0, cost.isFinite else {
                return .notMeasured(.itemsPerDollar, reason: "no cost recorded for the landed items", basis: basis, detail: [gateway])
            }
            let n = Double(facts.count)
            let detail: [MetricValue] = [
                .rate(.itemsPerDollar, label: "$LE (subscription)", numerator: n, denominator: cost, unit: .perUSD,
                      basis: "landed items with a fact ÷ their Σ itemFact.costLE"),
                gateway,
            ]
            return .rate(.itemsPerDollar, numerator: n, denominator: cost, unit: .perUSD, basis: basis, detail: detail)
        }
    }

    /// Landed items ÷ company-active hours, both over the window, the hours from the recorder's daily `activeSeconds` (ruling
    /// R15). An item landed before company-active time was first recorded is excluded (its hours were never counted).
    public static func itemsPerPlanHour(_ ctx: MeasureContext) throws -> MetricValue {
        let tz = ctx.store.ownerTimeZone()
        return try ctx.store.writer.read { db in
            let active = try Store.counterTotal(db, companyId: ctx.companyId, name: MeasureCounter.activeSeconds, in: ctx.window, tz: tz)
            guard active.rows > 0 else {
                return .notMeasured(.itemsPerPlanHour, reason: noActive,
                                    basis: "a plan-hour is an hour the company was awake (company-active), kept per day by the measure "
                                        + "recorder; no day of the window has a record")
            }
            let landed = try ReviewMetrics.landedItems(db, companyId: ctx.companyId, in: ctx.window)
            guard !landed.isEmpty else { return .notMeasured(.itemsPerPlanHour, reason: noLandings) }
            let firstDay = try Store.firstCounterDay(db, companyId: ctx.companyId, name: MeasureCounter.activeSeconds)
            let recordedFrom = firstDay.flatMap { dayStart($0, tz: tz) } ?? ctx.window.since
            let counted = landed.values.filter { $0.landedAt >= recordedFrom }.count
            let before = landed.count - counted
            let hours = active.sum / 3600
            var basis = "landed items in the window (\(counted)) ÷ company-active hours in the window (\(MetricValue.fixed(hours, 2)), from "
                + "the recorder's daily counters, \(LandingMetrics.plural(active.rows, "day"))); a plan-hour is never wall-clock"
            if before > 0 {
                basis += "; \(LandingMetrics.plural(before, "landed item")) before company-active time was recorded excluded"
            }
            basis += try recordedSince(db, companyId: ctx.companyId, window: ctx.window, tz: tz)
            return .rate(.itemsPerPlanHour, numerator: Double(counted), denominator: hours, unit: .perHour, basis: basis)
        }
    }

    // MARK: Owner minutes

    /// Σ the owner's logged minutes in the window ÷ landed items in the window. A count of the owner's own log: never
    /// insufficient; with no log in the window, not measured.
    public static func ownerMinutes(_ ctx: MeasureContext) throws -> MetricValue {
        let tz = ctx.store.ownerTimeZone()
        return try ctx.store.writer.read { db in
            let logged = try Store.counterTotal(db, companyId: ctx.companyId, name: MeasureCounter.ownerInterventionSeconds, in: ctx.window, tz: tz)
            let source = "the only source is the owner's own log (brahma measure <company> --log-owner-minutes <n> [--day YYYY-MM-DD]); "
                + "Brahma never records or estimates owner time"
            guard logged.rows > 0 else { return .notMeasured(.ownerMinutes, reason: "no owner-time records", basis: source) }
            let minutes = logged.sum / 60
            let landed = try ReviewMetrics.landedItems(db, companyId: ctx.companyId, in: ctx.window)
            let detail: [MetricValue] = [
                .count(.ownerMinutes, label: "owner minutes logged", minutes,
                       basis: "owner-logged minutes on \(LandingMetrics.plural(logged.rows, "day")) of the window"),
            ]
            let basis = "owner-logged minutes in the window (\(MetricValue.plain(minutes))) ÷ landed items in the window (\(landed.count)); "
                + "a count of the owner's own log, never insufficient; \(source)"
            guard !landed.isEmpty else { return .notMeasured(.ownerMinutes, reason: noLandings, basis: basis, detail: detail) }
            return MetricValue(id: .ownerMinutes, label: MetricId.ownerMinutes.label, numerator: minutes, denominator: Double(landed.count),
                               unit: .perItem, basis: basis, detail: detail, status: .ok)
        }
    }

    // MARK: Shared reads

    /// The `itemFact` columns the usage metrics read.
    struct Fact {
        var itemId: String
        var ownerId: String?
        var reviewerId: String?
        var firstPass: Bool
        var reworkRounds: Int
        var reviewRejections: Int
        var turnsUsed: Int
        var tokensUsed: Int
        var cycleActiveSeconds: Int?
        var costLE: Double
        var reviewCostLE: Double
    }

    /// The facts of `itemIds` (the company's own), by item id.
    static func facts(_ db: Database, companyId: String, itemIds: [String]) throws -> [String: Fact] {
        var facts: [String: Fact] = [:]
        for chunk in LandingMetrics.chunks(itemIds.sorted()) {
            let marks = chunk.map { _ in "?" }.joined(separator: ", ")
            for row in try Row.fetchAll(db, sql: """
                SELECT itemId, ownerId, reviewerId, firstPass, reworkRounds, reviewRejections, turnsUsed, tokensUsed, cycleActiveSeconds,
                       costLE, reviewCostLE
                FROM itemFact WHERE companyId = ? AND itemId IN (\(marks))
                """, arguments: StatementArguments([companyId]) + StatementArguments(chunk)) {
                let f = Fact(itemId: row["itemId"], ownerId: row["ownerId"], reviewerId: row["reviewerId"], firstPass: row["firstPass"],
                             reworkRounds: row["reworkRounds"], reviewRejections: row["reviewRejections"], turnsUsed: row["turnsUsed"], tokensUsed: row["tokensUsed"],
                             cycleActiveSeconds: row["cycleActiveSeconds"], costLE: row["costLE"], reviewCostLE: row["reviewCostLE"])
                facts[f.itemId] = f
            }
        }
        return facts
    }

    /// `SELECT COUNT(*) …` with bound arguments; a query that yields no row is 0.
    static func count(_ db: Database, _ sql: String, _ arguments: StatementArguments) throws -> Int {
        try Int.fetchOne(db, sql: sql, arguments: arguments) ?? 0
    }

    /// `; <n> landed item(s) without an item fact excluded`, or nothing.
    static func excludedWithoutFact(_ n: Int) -> String {
        n > 0 ? "; \(LandingMetrics.plural(n, "landed item")) without an item fact excluded" : ""
    }

    /// `; active seconds recorded since <day>` when the recorder's first day is after the window's first day, else nothing.
    static func recordedSince(_ db: Database, companyId: String, window: MeasureWindow, tz: TimeZone) throws -> String {
        guard let first = try Store.firstCounterDay(db, companyId: companyId, name: MeasureCounter.activeSeconds),
              first > Store.measureDay(window.since, in: tz) else { return "" }
        return "; active seconds recorded since \(first) (the measure recorder, vX6a)"
    }

    /// Midnight of `day` (`YYYY-MM-DD`) in `tz`; nil for a malformed day.
    static func dayStart(_ day: String, tz: TimeZone) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = tz
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        return f.date(from: day)
    }
}
