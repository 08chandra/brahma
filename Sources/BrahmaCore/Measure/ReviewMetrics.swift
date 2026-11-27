import Foundation
import GRDB

/// The review metrics of `brahma measure` (Plan X6a Task 4): review catch rate (`docs/measure/metrics.md` §3, owner ruling R7(c):
/// confirmed catches only), escape rate (§4) and revert rate (§2, owner ruling R7(b): 7, 14 and 30 days, headline 14). Landings
/// come from `Store.landings` (the one landing query, rulings R13/R20/R24), read once per metric and indexed by item; every other
/// query is `WHERE companyId = ?` with bound parameters, except the owner-wide start of link history (`measureEpoch`). Detail rows
/// name items by key only (engine-owned), never by title. Nothing is estimated: what a record cannot say is excluded and counted
/// in the basis, or the metric is `not measured`.
public enum ReviewMetrics {
    static let day: TimeInterval = 86_400
    /// The revert-rate rows (owner ruling R7(b)); `headlineDays` is the spec's.
    static let revertDays = [7, 14, 30]
    static let headlineDays = 14

    // MARK: Review catch

    /// Confirmed catches ÷ (confirmed catches + escaped). A catch is a `changesRequested` event followed by a later `submitted`
    /// event on the same item and then a passing check of that item finishing after the resubmission: a `verificationRun`
    /// (`submit` or `merge`) that passed, an `item`-kind `mergeRun` that passed, or a passed `main`-kind `mergeRun` of the batch
    /// that merged the item (main runs exist only while `company.mainCheck` was set, so the runs are the record, not the current
    /// setting). An item counts once, in the window of its confirming check. Escapes are §4's, keyed to the target's landing.
    /// Change requests in the window with no confirmed resubmission are listed in the detail, not in the rate.
    public static func reviewCatch(_ ctx: MeasureContext) throws -> MetricValue {
        let tz = ctx.store.ownerTimeZone()
        return try ctx.store.writer.read { db in
            let landed = try landedItems(db, companyId: ctx.companyId, in: ctx.window)
            let escaped = try escapes(db, companyId: ctx.companyId, landed: landed)
            let (caught, unconfirmed) = try catches(db, ctx: ctx)
            var basis = "confirmed catches: items with a changesRequested, a later submitted and then a passing check of the item "
                + "(submit or merge verification, item merge run, or its landing batch's main run) finishing in the window, one per "
                + "item (\(caught)); plus escapes found so far whose target item landed in the window, one per target "
                + "(\(escaped.count)); a catch is windowed on its confirming check, an escape on its target's landing; unconfirmed "
                + "change requests are not in the rate"
            if let history = linkHistory(try linksSince(db), window: ctx.window, tz: tz) { basis += "; \(history)" }
            let detail: [MetricValue] = [
                .count(.reviewCatch, label: "confirmed catches", Double(caught),
                       basis: "items whose change request was resubmitted and then confirmed by a passing check in the window"),
                .count(.reviewCatch, label: "escaped", Double(escaped.count),
                       basis: "regressionOf links and failed audits whose target item landed in the window, one per target"),
                .count(.reviewCatch, label: "unconfirmed change requests", Double(unconfirmed),
                       basis: "changesRequested events in the window with no later submitted followed by a passing check; not in the rate"),
            ]
            // Ruling R27/R28: nothing landed, nothing caught, nothing escaped — no data, whatever unconfirmed requests exist.
            if caught == 0, escaped.isEmpty, landed.isEmpty {
                return .notMeasured(.reviewCatch, reason: "no landings or review events in the window", basis: basis, detail: detail)
            }
            return .rate(.reviewCatch, numerator: Double(caught), denominator: Double(caught + escaped.count), unit: .ratio,
                         basis: basis, detail: detail)
        }
    }

    /// The items with a confirmed catch whose confirming check finished in the window, and the change requests made in the
    /// window that no resubmission and passing check has confirmed.
    static func catches(_ db: Database, ctx: MeasureContext) throws -> (caught: Int, unconfirmed: Int) {
        let found = try confirmedCatches(db, companyId: ctx.companyId, itemIds: nil, window: ctx.window)
        return (found.caught.count, found.unconfirmed)
    }

    /// The one confirmed-catch rule (metrics.md vocabulary), shared by the review catch rate and model ranking's reviewer rows
    /// (final review #9). Every `changesRequested` event created before `window.until` is a round; the round is confirmed by
    /// the earliest passing check of the item (`passingChecks`, any time) that finished after the next `submitted` event. An
    /// item is caught, once, when one of its rounds was confirmed in the window; a round requested in the window with no
    /// resubmission and passing check is unconfirmed. `itemIds` nil reads every item of the company. The review catch rate
    /// passes its own window; model ranking passes everything up to the report's end, because a catch confirmed before the
    /// window began still says something about a reviewer whose item landed in it.
    static func confirmedCatches(_ db: Database, companyId: String, itemIds: [String]?, window: MeasureWindow) throws
        -> (caught: Set<String>, unconfirmed: Int) {
        var events: [String: [(requested: Bool, at: Date)]] = [:]
        let select = """
            SELECT itemId, kind, createdAt FROM workItemEvent
            WHERE companyId = ? AND kind IN ('changesRequested', 'submitted') AND createdAt < ?
            """
        func collect(_ sql: String, _ arguments: StatementArguments) throws {
            for row in try Row.fetchAll(db, sql: sql + " ORDER BY itemId, createdAt, id", arguments: arguments) {
                events[row["itemId"] as String, default: []].append(
                    (requested: (row["kind"] as String) == WorkEventKind.changesRequested.rawValue, at: row["createdAt"] as Date))
            }
        }
        if let itemIds {
            for chunk in LandingMetrics.chunks(itemIds) {
                let marks = chunk.map { _ in "?" }.joined(separator: ", ")
                try collect(select + " AND itemId IN (\(marks))", [companyId, window.until] + StatementArguments(chunk))
            }
        } else {
            try collect(select, [companyId, window.until])
        }
        let candidates = events.filter { $0.value.contains { $0.requested } }.keys.sorted()
        let passed = try passingChecks(db, companyId: companyId, itemIds: candidates)
        var caught: Set<String> = [], unconfirmed = 0
        for itemId in candidates {
            let sequence = events[itemId, default: []]
            for (i, event) in sequence.enumerated() where event.requested {
                let resubmitted = sequence[(i + 1)...].first { !$0.requested }
                if let confirmed = resubmitted.flatMap({ s in passed[itemId, default: []].filter { $0 > s.at }.min() }) {
                    if confirmed >= window.since, confirmed < window.until { caught.insert(itemId) }
                } else if event.at >= window.since {
                    unconfirmed += 1
                }
            }
        }
        return (caught, unconfirmed)
    }

    /// Finish times of the passing checks of each item (any time up to now): verification runs, item merge runs, and the main
    /// run at the land commit of the batch that merged it (R23: a bisected batch's runs at other candidates never judge it).
    static func passingChecks(_ db: Database, companyId: String, itemIds: [String]) throws -> [String: [Date]] {
        var passed: [String: [Date]] = [:]
        for chunk in LandingMetrics.chunks(itemIds) {
            let marks = chunk.map { _ in "?" }.joined(separator: ", ")
            let args = StatementArguments([companyId]) + StatementArguments(chunk)
            for sql in [
                """
                SELECT itemId, finishedAt FROM verificationRun
                WHERE companyId = ? AND status = 'passed' AND purpose IN ('submit', 'merge') AND finishedAt IS NOT NULL AND itemId IN (\(marks))
                """,
                """
                SELECT itemId, finishedAt FROM mergeRun
                WHERE companyId = ? AND kind = 'item' AND status = 'passed' AND finishedAt IS NOT NULL AND itemId IN (\(marks))
                """,
                """
                SELECT r.itemId AS itemId, m.finishedAt AS finishedAt FROM mergeRun m
                JOIN mergeRequest r ON r.batchId = m.batchId AND r.companyId = m.companyId
                WHERE m.companyId = ? AND m.kind = 'main' AND m.status = 'passed' AND m.finishedAt IS NOT NULL
                  AND m.candidateCommit = (SELECT b.landCommit FROM mergeBatch b WHERE b.id = m.batchId AND b.companyId = m.companyId)
                  AND r.status = 'merged' AND r.itemId IN (\(marks))
                """,
            ] {
                for row in try Row.fetchAll(db, sql: sql, arguments: args) {
                    passed[row["itemId"] as String, default: []].append(row["finishedAt"] as Date)
                }
            }
        }
        return passed
    }

    // MARK: Escapes

    /// One escaped defect: a landed item of the window with a `regressionOf` link to it or a failed audit of it (both whenever
    /// recorded), every source named.
    struct Escape {
        var target: LandedEntry
        var sources: [String]
        var label: String { sources.joined(separator: "; ") }
    }

    /// Escaped defects ÷ landed items in the window, keyed to the target item's landing time.
    public static func escapeRate(_ ctx: MeasureContext) throws -> MetricValue {
        let tz = ctx.store.ownerTimeZone()
        return try ctx.store.writer.read { db in
            let landed = try landedItems(db, companyId: ctx.companyId, in: ctx.window)
            guard !landed.isEmpty else { return .notMeasured(.escapeRate, reason: "no landings in the window") }
            let escaped = try escapes(db, companyId: ctx.companyId, landed: landed)
            var basis = "escapes found so far: regressionOf links and failed audits (whenever recorded) whose target item landed in "
                + "the window, one per target item, ÷ landed items in the window (\(landed.count))"
            if let history = linkHistory(try linksSince(db), window: ctx.window, tz: tz) { basis += "; \(history)" }
            let detail = escaped.map { e in
                MetricValue.count(.escapeRate, label: e.label, 1, basis: "landed \(MeasureReport.iso(e.target.landedAt))")
            }
            return .rate(.escapeRate, numerator: Double(escaped.count), denominator: Double(landed.count), unit: .ratio, basis: basis,
                         detail: detail)
        }
    }

    /// The window's escapes, deduplicated by target (a failed audit and its follow-up's `regressionOf` link are one defect), in
    /// landing order.
    static func escapes(_ db: Database, companyId: String, landed: [String: LandedEntry]) throws -> [Escape] {
        var sources: [String: [String]] = [:]
        let links = try Row.fetchAll(db, sql: """
            SELECT itemId, targetId FROM workItemLink WHERE companyId = ? AND kind = ? ORDER BY createdAt, itemId
            """, arguments: [companyId, ItemLinkKind.regressionOf.rawValue]).filter { landed[$0["targetId"] as String] != nil }
        let keys = try itemKeys(db, companyId: companyId, ids: Array(Set(links.map { $0["itemId"] as String })))
        for link in links {
            let targetId: String = link["targetId"], itemId: String = link["itemId"]
            guard let target = landed[targetId] else { continue }
            // The escape is the target's; a linking item with no key row (cannot happen while the foreign key holds) is named by id.
            let name = keys[itemId] ?? itemId
            sources[targetId, default: []].append("\(name) \(ItemLinkKind.regressionOf.rawValue) \(target.key)")
        }
        // `reviewAudit.verdict` stores `failed` (ruling R14).
        for itemId in try String.fetchAll(db, sql: "SELECT DISTINCT itemId FROM reviewAudit WHERE companyId = ? AND verdict = 'failed' ORDER BY itemId",
                                          arguments: [companyId]) {
            guard let target = landed[itemId] else { continue }
            sources[itemId, default: []].append("\(target.key) failed audit")
        }
        return sources.compactMap { targetId, named -> Escape? in landed[targetId].map { Escape(target: $0, sources: named) } }
            .sorted { ($0.target.landedAt, $0.target.key) < ($1.target.landedAt, $1.target.key) }
    }

    // MARK: Reverts

    /// Landed items reverted within N days ÷ landed items that have had N days, for N = 7, 14, 30 (headline 14). A revert is a
    /// `revertOf` link whose item landed within N days after the target, or an exact inverse the detector found (a later landing
    /// within N days whose forward patch-id is the target's inverse one). Both for one pair are one revert, shown as linked.
    /// Items the detector could not read (no merged commit, a commit git cannot read, past a scan bound) are excluded from every
    /// row with the basis stated; a detector that cannot run at all makes the metric `not measured`.
    public static func revertRate(_ ctx: MeasureContext, detector: RevertDetector) throws -> MetricValue {
        let tz = ctx.store.ownerTimeZone()
        // One store snapshot; git runs after it, outside the read transaction.
        let (landed, links, since) = try ctx.store.writer.read { db -> ([String: LandedEntry], [(itemId: String, targetId: String)], Date?) in
            let landed = try landedItems(db, companyId: ctx.companyId, in: ctx.window)
            let links = try Row.fetchAll(db, sql: """
                SELECT itemId, targetId FROM workItemLink WHERE companyId = ? AND kind = ? ORDER BY createdAt, itemId
                """, arguments: [ctx.companyId, ItemLinkKind.revertOf.rawValue]).map { (itemId: $0["itemId"] as String, targetId: $0["targetId"] as String) }
            return (landed, links, try linksSince(db))
        }
        guard !landed.isEmpty else { return .notMeasured(.revertRate, reason: "no landings in the window") }
        let history = linkHistory(since, window: ctx.window, tz: tz)
        func age(_ entry: LandedEntry) -> TimeInterval { ctx.now.timeIntervalSince(entry.landedAt) }
        let shortest = Double(revertDays.min() ?? headlineDays) * day
        let entries = landed.values.sorted { ($0.landedAt, $0.key) < ($1.landedAt, $1.key) }

        // No item has had even the shortest span: no row can be measured, and no git needs to run.
        let windowStart = Store.measureDay(ctx.window.since, in: tz)
        func tooYoung(_ days: Int) -> String { "no landings at least \(days) d old in the window (window starts \(windowStart))" }
        guard entries.contains(where: { age($0) >= shortest }) else {
            let rows = revertDays.map { days in
                MetricValue.notMeasured(.revertRate, label: "\(days) d", reason: tooYoung(days),
                                        basis: "no landed item in the window landed \(days) days or more before now")
            }
            return .notMeasured(.revertRate, reason: tooYoung(headlineDays),
                                basis: "no landed item in the window landed \(headlineDays) days or more before now (\(LandingMetrics.plural(entries.count, "landed item")) in the window)",
                                detail: rows)
        }

        var ranges: [LandedRange] = []
        var noCommit: [String] = []
        for entry in entries {
            if let merged = entry.mergedCommit { ranges.append(LandedRange(itemId: entry.itemId, merged: merged, landedAt: entry.landedAt)) }
            else { noCommit.append(entry.itemId) }
        }
        let scan: RevertDetector.Scan
        do {
            scan = try detector.inversePairs(ranges)
        } catch let error as RevertDetector.SourceError {
            return .notMeasured(.revertRate, reason: "revert scan could not run: \(error)",
                                basis: "revert rate needs the company workspace's own repository to read landed commits")
        }
        let excluded = Set(noCommit).union(scan.unreadable).union(scan.notScanned)

        // target → reverting item → how it was found.
        var reverts: [String: [String: (linked: Bool, detected: Bool)]] = [:]
        for link in links {
            guard let target = landed[link.targetId], let by = landed[link.itemId], by.landedAt >= target.landedAt else { continue }
            reverts[link.targetId, default: [:]][link.itemId, default: (false, false)].linked = true
        }
        for pair in scan.pairs { reverts[pair.reverted, default: [:]][pair.by, default: (false, false)].detected = true }

        /// The earliest revert of `target` and how long after its landing it landed.
        func firstRevert(_ target: LandedEntry) -> (by: LandedEntry, delay: TimeInterval, linked: Bool, detected: Bool)? {
            (reverts[target.itemId] ?? [:]).compactMap { byId, how in
                landed[byId].map { (by: $0, delay: $0.landedAt.timeIntervalSince(target.landedAt), linked: how.linked, detected: how.detected) }
            }.min { ($0.delay, $0.by.key) < ($1.delay, $1.by.key) }
        }

        var counted: Set<String> = []
        func row(days: Int, id: MetricId, label: String) -> MetricValue {
            let span = Double(days) * day
            let readable = entries.filter { !excluded.contains($0.itemId) }
            let population = readable.filter { age($0) >= span }
            let tooRecent = readable.count - population.count
            var basis = "landed items in the window that have had \(days) days to be reverted (\(population.count))"
            if tooRecent > 0 { basis += "; \(tooRecent) landed in the last \(days) days excluded" }
            guard !population.isEmpty else {
                // Ruling R28: say why — none that old in the window, or none of those readable.
                let unreadableOld = entries.filter { excluded.contains($0.itemId) && age($0) >= span }.count
                let reason = unreadableOld > 0 ? "no readable landings at least \(days) d old (\(unreadableOld) excluded)" : tooYoung(days)
                return .notMeasured(id, label: label, reason: reason, basis: basis)
            }
            let hits = population.filter { entry in
                guard let first = firstRevert(entry) else { return false }
                return first.delay <= span
            }
            counted.formUnion(hits.map(\.itemId))
            return .rate(id, label: label, numerator: Double(hits.count), denominator: Double(population.count), unit: .ratio, basis: basis)
        }
        let rows = revertDays.map { row(days: $0, id: .revertRate, label: "\($0) d") }
        let headline = row(days: headlineDays, id: .revertRate, label: MetricId.revertRate.label)

        var basis = headline.basis + "; a revert is a revertOf link whose item landed within \(headlineDays) days after the target, or "
            + "an exact inverse (stable patch-id of <merged>^1..<merged>) of a later landing within \(headlineDays) days; one per item"
        if !noCommit.isEmpty { basis += "; \(LandingMetrics.plural(noCommit.count, "landed item")) without a merged commit excluded" }
        if !scan.unreadable.isEmpty { basis += "; \(LandingMetrics.plural(scan.unreadable.count, "landed item")) whose commits git could not read excluded" }
        if let stopped = scan.basis { basis += "; \(stopped): \(LandingMetrics.plural(scan.notScanned.count, "landed item")) not scanned excluded" }
        if let history { basis += "; \(history)" }

        let revertRows = entries.filter { counted.contains($0.itemId) }.compactMap { target -> MetricValue? in
            guard let first = firstRevert(target) else { return nil }
            var why = "landed \(MetricValue.plain(first.delay / day)) days after \(target.key)"
            if first.linked, first.detected { why += "; also an exact inverse" }
            return .count(.revertRate, label: "\(first.by.key) reverts \(target.key) (\(first.linked ? "linked" : "exact inverse"))", 1, basis: why)
        }
        var value = headline
        value.basis = basis
        value.detail = rows + revertRows
        return value
    }

    // MARK: Shared reads

    /// A landed item of the window: its first landing there (`Store.landings`, the one landing query), keyed by item id.
    struct LandedEntry {
        var itemId: String
        var key: String
        var mergedCommit: String?
        var landedAt: Date
    }

    /// The window's landed items, indexed once (Task 2's minor: never `hasLanded` per item).
    static func landedItems(_ db: Database, companyId: String, in window: MeasureWindow) throws -> [String: LandedEntry] {
        var index: [String: LandedEntry] = [:]
        for landing in try Store.landings(db, companyId: companyId, in: window) {
            for item in landing.items {
                if let seen = index[item.itemId], seen.landedAt <= item.landedAt { continue }
                index[item.itemId] = LandedEntry(itemId: item.itemId, key: item.key, mergedCommit: item.mergedCommit, landedAt: item.landedAt)
            }
        }
        return index
    }

    /// `workItem.key` by id, within the company.
    static func itemKeys(_ db: Database, companyId: String, ids: [String]) throws -> [String: String] {
        var keys: [String: String] = [:]
        for chunk in LandingMetrics.chunks(ids) {
            let marks = chunk.map { _ in "?" }.joined(separator: ", ")
            for row in try Row.fetchAll(db, sql: "SELECT id, key FROM workItem WHERE companyId = ? AND id IN (\(marks))",
                                        arguments: StatementArguments([companyId]) + StatementArguments(chunk)) {
                keys[row["id"]] = row["key"]
            }
        }
        return keys
    }

    /// When link history began (`measureEpoch`, written by the `vX6a-measure-epoch` migration). Owner-wide: the links table came
    /// into existence once for the whole database, so this one row has no company.
    static func linksSince(_ db: Database) throws -> Date? {
        try Date.fetchOne(db, sql: "SELECT at FROM measureEpoch WHERE name = 'links'")
    }

    /// `links since <day> (vX6a-measure); …` when the window starts before link history; nil when history covers the window.
    static func linkHistory(_ since: Date?, window: MeasureWindow, tz: TimeZone) -> String? {
        guard let since else { return "the start of link history is not recorded" }
        guard since > window.since else { return nil }
        return "links since \(Store.measureDay(since, in: tz)) (vX6a-measure); the window starts before it, and a defect or revert "
            + "of that time is counted only if it was linked later"
    }
}
