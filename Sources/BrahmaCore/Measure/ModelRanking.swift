import Foundation
import GRDB

/// Model ranking per role (`docs/measure/metrics.md` §11, spec decision 20; Plan X6a Task 5). Every query is `WHERE companyId = ?`
/// in one read snapshot; landings come from `ReviewMetrics.landedItems`. X1 is not merged (ruling R4): a model is the subscription
/// family (`haiku`, `sonnet`, `opus`) named by `turn.modelsUsed` or the agent's `model`; routed model and provider are
/// `not applicable`. Labels are roles and model families only, cut to a safe token.
extension UsageMetrics {
    /// A (role, model family) pair.
    struct Pair: Hashable, Comparable {
        var role: String
        var model: String
        var label: String { "\(role) · \(model)" }
        static func < (a: Pair, b: Pair) -> Bool { (a.role, a.model) < (b.role, b.model) }
    }

    /// Whose model an item (or a review) ran on.
    enum Attribution: Equatable {
        /// The family, and whether it came from the agent's model because no turn named one.
        case family(String, byAgent: Bool)
        /// Two families ran the same number of turns, or every turn that named a model named several (cumulative over a resume):
        /// no majority, not attributed — never the agent's current model.
        case noMajority
        /// No turn named a model and the agent's model is `auto` (it has no model of its own).
        case unknown
    }

    /// Per (role, model): landed items attributed (n), first-pass rate, rework rounds and $LE (subscription) per landed item, and —
    /// for the pair as reviewer — confirmed catches ÷ (catches + escapes) over the items it reviewed. An item belongs to its
    /// assignee's role (`itemFact.ownerId` → `agent.role`) and to the family that ran most of its work turns.
    public static func modelRanking(_ ctx: MeasureContext) throws -> MetricValue {
        try ctx.store.writer.read { db in
            let id = MetricId.modelRanking
            let routed = MetricValue.notApplicable(id, label: "routed model and provider", reason: gatewayAbsent, basis: gatewayBasis)
            let landed = try ReviewMetrics.landedItems(db, companyId: ctx.companyId, in: ctx.window)
            guard !landed.isEmpty else { return .notMeasured(id, reason: noLandings, detail: [routed]) }
            let facts = try Self.facts(db, companyId: ctx.companyId, itemIds: Array(landed.keys))
            guard !facts.isEmpty else { return .notMeasured(id, reason: noFacts, detail: [routed]) }
            let itemIds = facts.keys.sorted()
            let agents = Dictionary(uniqueKeysWithValues: try Agent.fetchAll(db, sql: "SELECT * FROM agent WHERE companyId = ?",
                                                                             arguments: [ctx.companyId]).map { ($0.id, $0) })
            let work = try turnModels(db, companyId: ctx.companyId, itemIds: itemIds, kind: .work)
            let firstSubmit = try firstSubmits(db, companyId: ctx.companyId, itemIds: itemIds)
            let reviews = try turnModels(db, companyId: ctx.companyId, itemIds: itemIds, kind: .review)
            let reviewers = try reviewerFallback(db, companyId: ctx.companyId, itemIds: itemIds, agents: agents)
            let caught = try confirmedCatches(db, companyId: ctx.companyId, itemIds: itemIds, until: ctx.window.until)
            let escaped = Set(try ReviewMetrics.escapes(db, companyId: ctx.companyId, landed: landed).map(\.target.itemId))

            var owned: [Pair: [Fact]] = [:]
            var byAgent = 0, noOwner = 0, noMajority = 0, unknown = 0
            var reviewed: [Pair: (caught: Int, escaped: Int)] = [:]
            var reviewNoMajority = 0
            for itemId in itemIds {
                guard let fact = facts[itemId] else { continue }
                if let ownerId = fact.ownerId, let owner = agents[ownerId] {
                    switch attribute(work[itemId, default: []].map(\.models), agentModel: owner.model) {
                    case .family(let family, let fromAgent):
                        owned[Pair(role: token(owner.role), model: family), default: []].append(fact)
                        if fromAgent { byAgent += 1 }
                    case .noMajority: noMajority += 1
                    case .unknown: unknown += 1
                    }
                } else {
                    noOwner += 1
                }
                // The reviewer side: only items with a confirmed catch or an escape say anything about a review.
                let isCaught = caught.contains(itemId), isEscaped = escaped.contains(itemId)
                guard isCaught || isEscaped, let reviewerId = fact.reviewerId ?? reviewers[itemId], let reviewer = agents[reviewerId] else { continue }
                let own = reviews[itemId, default: []].filter { $0.agentId == reviewerId }.map(\.models)
                guard case .family(let family, _) = attribute(own, agentModel: reviewer.model) else { reviewNoMajority += 1; continue }
                let pair = Pair(role: token(reviewer.role), model: family)
                var tally = reviewed[pair] ?? (0, 0)
                if isCaught { tally.caught += 1 }
                if isEscaped { tally.escaped += 1 }
                reviewed[pair] = tally
            }

            var detail: [MetricValue] = []
            for pair in Set(owned.keys).union(reviewed.keys).sorted() {
                let items = owned[pair] ?? []
                let n = Double(items.count)
                var rows: [MetricValue] = []
                if !items.isEmpty {
                    rows.append(.rate(id, label: "first-pass", numerator: Double(items.filter(\.firstPass).count), denominator: n, unit: .ratio,
                                      basis: "itemFact.firstPass over the pair's landed items"))
                    rows.append(.rate(id, label: "rework rounds", numerator: Double(items.reduce(0) { $0 + $1.reworkRounds }), denominator: n,
                                      unit: .perItem, basis: "Σ itemFact.reworkRounds ÷ the pair's landed items"))
                    rows.append(.rate(id, label: "review rejections", numerator: Double(items.reduce(0) { $0 + $1.reviewRejections }),
                                      denominator: n, unit: .perItem, basis: "Σ itemFact.reviewRejections ÷ the pair's landed items"))
                    let after = items.reduce(0) { total, fact in
                        guard let submitted = firstSubmit[fact.itemId] else { return total }
                        return total + work[fact.itemId, default: []].filter { $0.startedAt > submitted }.count
                    }
                    rows.append(.rate(id, label: "turns after first submit", numerator: Double(after), denominator: n, unit: .perItem,
                                      basis: "counted work turns started after the item's first submitted event ÷ the pair's landed items"))
                    rows.append(.rate(id, label: "$LE (subscription)", numerator: items.reduce(0) { $0 + $1.costLE }, denominator: n,
                                      unit: .usd, basis: "Σ itemFact.costLE ÷ the pair's landed items"))
                }
                if let r = reviewed[pair] {
                    rows.append(.rate(id, label: "review catch (as reviewer)", numerator: Double(r.caught), denominator: Double(r.caught + r.escaped),
                                      unit: .ratio, basis: "items it reviewed (itemFact.reviewerId, else the review event's actor) with a "
                                        + "confirmed catch ÷ those caught or escaped (\(r.caught) caught, \(r.escaped) escaped)"))
                }
                detail.append(.count(id, label: pair.label, n, basis: "landed items attributed to the pair (n=\(items.count))", detail: rows))
            }
            detail.append(routed)

            let attributed = owned.values.reduce(0) { $0 + $1.count }
            var basis = "landed items in the window with an item fact (\(facts.count)) attributed to their assignee's role and to the model "
                + "family that ran most of their work turns (turn.modelsUsed; a background haiku beside another family is not counted; "
                + "with no turn naming a model, the agent's model): \(attributed), \(byAgent) by the agent's model; each pair's rates "
                + "carry their own n"
            basis += excludedWithoutFact(landed.count - facts.count)
            if noOwner > 0 { basis += "; \(LandingMetrics.plural(noOwner, "landed item")) with no assignee recorded excluded" }
            if noMajority > 0 { basis += "; \(LandingMetrics.plural(noMajority, "landed item")) with no majority model excluded" }
            if unknown > 0 {
                basis += "; \(LandingMetrics.plural(unknown, "landed item")) whose agent's model is auto and no turn named a model excluded"
            }
            if reviewNoMajority > 0 { basis += "; \(LandingMetrics.plural(reviewNoMajority, "review")) with no majority model left out of the reviewer rows" }
            return .count(id, Double(attributed), basis: basis, detail: detail)
        }
    }

    /// The majority family of `turns` (each a `modelsUsed` value). Only when no turn names any model, the agent's model (a known
    /// family, or any other model as its safe token); an `auto` agent then has none.
    static func attribute(_ turns: [String?], agentModel: String) -> Attribution {
        var tally: [String: Int] = [:]
        var named = false
        for models in turns {
            if let models, !models.trimmingCharacters(in: .whitespaces).isEmpty { named = true }
            if let family = turnFamily(models) { tally[family, default: 0] += 1 }
        }
        if let top = tally.values.max() {
            let leaders = tally.filter { $0.value == top }.keys.sorted()
            guard leaders.count == 1, let family = leaders.first else { return .noMajority }
            return .family(family, byAgent: false)
        }
        // Turns named models but none a single family: ambiguous, not the agent's (perhaps since changed) model.
        if named { return .noMajority }
        let family = ModelAllowlist.family(agentModel.trimmingCharacters(in: .whitespaces))
        guard !family.isEmpty, family != "auto" else { return .unknown }
        return .family(token(family), byAgent: true)
    }

    /// The one family a turn ran on: its `modelsUsed` families, less a background `haiku` beside another family; nil when the turn
    /// names none, or several (cumulative over `--resume`, so it cannot be split).
    static func turnFamily(_ modelsUsed: String?) -> String? {
        guard let modelsUsed else { return nil }
        let families = Set(modelsUsed.split(separator: ",").map { token(ModelAllowlist.family($0.trimmingCharacters(in: .whitespaces))) }
            .filter { !$0.isEmpty })
        let main = families.count > 1 ? families.subtracting(["haiku"]) : families
        return main.count == 1 ? main.first : nil
    }

    /// A role or model name as a detail label shows it: letters, digits, space, `.`, `_`, `-`, at most 40 characters.
    static func token(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789 ._-")
        let kept = String(raw.filter { allowed.contains($0) }.prefix(40))
        return kept.isEmpty ? "unnamed" : kept
    }

    /// The company's counted turns of `kind` about each item — the turns `itemFact.turnsUsed` counts: outcome succeeded or failed,
    /// no infra failure, no session reset — with their agent, `modelsUsed` and start.
    static func turnModels(_ db: Database, companyId: String, itemIds: [String], kind: TurnKind)
        throws -> [String: [(agentId: String, models: String?, startedAt: Date)]] {
        var out: [String: [(agentId: String, models: String?, startedAt: Date)]] = [:]
        for chunk in LandingMetrics.chunks(itemIds) {
            let marks = chunk.map { _ in "?" }.joined(separator: ", ")
            for row in try Row.fetchAll(db, sql: """
                SELECT itemId, agentId, modelsUsed, startedAt FROM turn
                WHERE companyId = ? AND kind = ? AND infra = 0 AND sessionResetReason IS NULL
                  AND (stopReason IS NULL OR stopReason <> 'sessionReset') AND outcome IN ('succeeded', 'failed') AND itemId IN (\(marks))
                ORDER BY startedAt, id
                """, arguments: StatementArguments([companyId, kind.rawValue]) + StatementArguments(chunk)) {
                out[row["itemId"] as String, default: []].append((agentId: row["agentId"], models: row["modelsUsed"], startedAt: row["startedAt"]))
            }
        }
        return out
    }

    /// The time of each item's first `submitted` event.
    static func firstSubmits(_ db: Database, companyId: String, itemIds: [String]) throws -> [String: Date] {
        var out: [String: Date] = [:]
        for chunk in LandingMetrics.chunks(itemIds) {
            let marks = chunk.map { _ in "?" }.joined(separator: ", ")
            for row in try Row.fetchAll(db, sql: """
                SELECT itemId, MIN(createdAt) AS firstAt FROM workItemEvent
                WHERE companyId = ? AND kind = 'submitted' AND itemId IN (\(marks)) GROUP BY itemId
                """, arguments: StatementArguments([companyId]) + StatementArguments(chunk)) {
                out[row["itemId"] as String] = row["firstAt"] as Date
            }
        }
        return out
    }

    /// For items whose fact names no reviewer: the agent of the company that wrote the item's last review event.
    static func reviewerFallback(_ db: Database, companyId: String, itemIds: [String], agents: [String: Agent]) throws -> [String: String] {
        var out: [String: String] = [:]
        for chunk in LandingMetrics.chunks(itemIds) {
            let marks = chunk.map { _ in "?" }.joined(separator: ", ")
            for row in try Row.fetchAll(db, sql: """
                SELECT itemId, actorId FROM workItemEvent
                WHERE companyId = ? AND kind IN ('reviewApproved', 'changesRequested') AND itemId IN (\(marks))
                ORDER BY createdAt, id
                """, arguments: StatementArguments([companyId]) + StatementArguments(chunk)) {
                let actor: String = row["actorId"]
                if agents[actor] != nil { out[row["itemId"] as String] = actor }
            }
        }
        return out
    }

    /// The items with a confirmed catch (metrics.md vocabulary: a `changesRequested`, a later `submitted`, then a passing check of
    /// the item after it), whenever up to `until`.
    static func confirmedCatches(_ db: Database, companyId: String, itemIds: [String], until: Date) throws -> Set<String> {
        var events: [String: [(requested: Bool, at: Date)]] = [:]
        for chunk in LandingMetrics.chunks(itemIds) {
            let marks = chunk.map { _ in "?" }.joined(separator: ", ")
            for row in try Row.fetchAll(db, sql: """
                SELECT itemId, kind, createdAt FROM workItemEvent
                WHERE companyId = ? AND kind IN ('changesRequested', 'submitted') AND createdAt < ? AND itemId IN (\(marks))
                ORDER BY createdAt, id
                """, arguments: [companyId, until] + StatementArguments(chunk)) {
                events[row["itemId"] as String, default: []].append(
                    (requested: (row["kind"] as String) == WorkEventKind.changesRequested.rawValue, at: row["createdAt"] as Date))
            }
        }
        let candidates = events.filter { $0.value.contains { $0.requested } }.keys.sorted()
        let passed = try ReviewMetrics.passingChecks(db, companyId: companyId, itemIds: candidates)
        var caught: Set<String> = []
        for itemId in candidates {
            let sequence = events[itemId, default: []]
            for (i, event) in sequence.enumerated() where event.requested {
                guard let resubmitted = sequence[(i + 1)...].first(where: { !$0.requested }) else { continue }
                if passed[itemId, default: []].contains(where: { $0 > resubmitted.at && $0 < until }) { caught.insert(itemId); break }
            }
        }
        return caught
    }
}
