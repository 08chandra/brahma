import Foundation
import Testing
import GRDB
@testable import BrahmaCore

/// Usage per landed item, owner touches, safety, non-code acceptance, model ranking, idle while actionable, items per $LE and per
/// plan-hour, owner minutes (Plan X6a Task 5; `docs/measure/metrics.md` §5, §6, §9–§14). X1 is not merged (ruling R4): every
/// gateway leg is `not applicable: X1 gateway columns absent`. Store-only.
@Suite(.scratch) struct UsageMetricsTests {
    let t0 = MeasureFixtures.t0
    let day: TimeInterval = 86_400
    static let utc = TimeZone(identifier: "UTC")!

    func ctx(_ store: Store, _ company: Company, since: Date? = nil, until: Date? = nil) throws -> MeasureContext {
        try store.setOwnerTimeZone("UTC")
        let window = MeasureWindow(since: since ?? company.createdAt, until: until ?? t0)
        return MeasureContext(store: store, git: GitWorkspace(root: URL(fileURLWithPath: company.workspacePath)), company: company,
                              window: window, now: until ?? t0)
    }

    func row(_ m: MetricValue, _ label: String) throws -> MetricValue {
        try #require(m.detail.first { $0.label == label }, "no detail row '\(label)' in \(m.detail.map(\.label))")
    }

    /// One more landed item with no fact row (a container, or done before facts existed), landed at `at`.
    func landWithoutFact(_ store: Store, _ company: Company, number: Int, at: Date) throws -> WorkItem {
        let item = try MeasureFixtures.items(store, company: company, count: 1, now: at.addingTimeInterval(-day))[0]
        try MeasureFixtures.land(store, company: company, items: [item], number: number, enqueuedAt: at.addingTimeInterval(-600), landedAt: at)
        return item
    }

    // MARK: Usage per landed item

    /// The subscription leg is Σ itemFact.costLE ÷ landed items with a fact; review $LE is shown beside it; the gateway leg is not
    /// applicable (X1). Turns, tokens and awake seconds share the one denominator; a landed item with no fact is excluded from
    /// every leg with the basis saying so.
    @Test func splitsSubscriptionAndGateway() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.seed(store, name: "Acme", landed: 24, now: t0)
        _ = try landWithoutFact(store, acme, number: 2, at: t0.addingTimeInterval(-3 * day))
        let m = try UsageMetrics.usagePerLanded(try ctx(store, acme))
        #expect(m.id == .usagePerLanded && m.unit == .usd)
        #expect(m.status == .ok, "\(m.display)")
        #expect(m.numerator == 300 && m.denominator == 24)      // Σ 1…24
        #expect(m.display == "$12.50 per landed item (300.00/24)")
        #expect(m.basis.contains("$LE (subscription)"), "\(m.basis)")
        #expect(m.basis.contains("1 landed item without an item fact excluded"), "\(m.basis)")

        let sub = try row(m, "$LE (subscription)")
        #expect(sub.status == .ok && sub.numerator == 300 && sub.denominator == 24 && sub.unit == .usd)
        let review = try row(m, "review $LE (subscription)")
        #expect(abs(review.numerator - 2.4) < 1e-9 && review.denominator == 24)
        let gateway = try row(m, "$ (gateway)")
        #expect(gateway.status == .notApplicable(reason: "X1 gateway columns absent"))
        #expect(gateway.display == "not applicable: X1 gateway columns absent")
        let turns = try row(m, "turns")
        #expect(turns.unit == .perItem && turns.numerator == 48 && turns.denominator == 24 && turns.status == .ok)
        #expect(turns.display == "2.00 per landed item (48/24)")
        #expect(try row(m, "tokens").numerator == 24_000)
        let awake = try row(m, "awake seconds")
        #expect(awake.numerator == 14_400 && awake.denominator == 24)

        // Nothing landed: not measured. Landed but no facts: not measured, with why.
        let empty = try Store.inMemory()
        let bare = try MeasureFixtures.company(empty, name: "Bare", createdAt: t0.addingTimeInterval(-30 * day))
        #expect(try UsageMetrics.usagePerLanded(try ctx(empty, bare)).status == .notMeasured(reason: "no landings in the window"))
        _ = try landWithoutFact(empty, bare, number: 1, at: t0.addingTimeInterval(-2 * day))
        #expect(try UsageMetrics.usagePerLanded(try ctx(empty, bare)).status
                == .notMeasured(reason: "no item facts for the landed items in the window"))
    }

    /// Final review #7: a never-claimed item has no awake time (`cycleActiveSeconds` null). It is left out of the awake-seconds
    /// row's denominator, never counted as 0, and the basis says how many; the other legs keep every item with a fact.
    @Test func awakeSecondsExcludeNeverClaimed() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.seed(store, name: "Acme", landed: 24, now: t0)   // 600 s each
        try store.writer.write { db in
            try db.execute(sql: """
                UPDATE itemFact SET cycleActiveSeconds = NULL
                WHERE companyId = ? AND itemId IN (SELECT itemId FROM itemFact WHERE companyId = ? ORDER BY itemId LIMIT 4)
                """, arguments: [acme.id, acme.id])
        }
        let m = try UsageMetrics.usagePerLanded(try ctx(store, acme))
        #expect(m.denominator == 24)
        #expect(try row(m, "turns").denominator == 24)
        let awake = try row(m, "awake seconds")
        #expect(awake.numerator == 12_000 && awake.denominator == 20, "\(awake)")
        #expect(awake.status == .ok && awake.display == "600.00 per landed item (12000/20)", "\(awake.display)")
        #expect(awake.basis.contains("4 items never claimed (no awake time recorded) excluded"), "\(awake.basis)")
    }

    /// Ruling R4: X1's metered columns do not exist, so no turn is a gateway turn. Every gateway leg (usage, items per dollar,
    /// model ranking's routed model) says `not applicable: X1 gateway columns absent` with that basis; a turn's own costUSD never
    /// becomes a gateway dollar.
    @Test func preGatewayTurnsExcludedWithBasis() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.seed(store, name: "Acme", landed: 20, now: t0)
        let eng = try MeasureFixtures.agent(store, company: acme, name: "eng")
        try store.writer.write { db in
            var t = Turn(id: UUID().uuidString, agentId: eng.id, companyId: acme.id, startedAt: t0.addingTimeInterval(-day),
                         endedAt: t0.addingTimeInterval(-day + 60), outcome: .succeeded, summary: nil, costUSD: 9.99)
            t.costLE = 9.99
            try t.insert(db)
        }
        let c = try ctx(store, acme)
        let usage = try row(try UsageMetrics.usagePerLanded(c), "$ (gateway)")
        #expect(usage.status == .notApplicable(reason: "X1 gateway columns absent"))
        #expect(usage.basis.contains("ruling R4"), "\(usage.basis)")
        #expect(usage.basis.contains("subscription"), "\(usage.basis)")
        #expect(usage.numerator == 0)
        let perDollar = try row(try UsageMetrics.itemsPerDollar(c), "$ (gateway)")
        #expect(perDollar.status == .notApplicable(reason: "X1 gateway columns absent"))
        let routed = try row(try UsageMetrics.modelRanking(c), "routed model and provider")
        #expect(routed.status == .notApplicable(reason: "X1 gateway columns absent"))
    }

    // MARK: Owner touches

    /// Asks the owner decided in the window (`decidedBy = 'owner'`) plus the owner's own messages (not engine lines) ÷ landed
    /// items. Preset and internal decisions, decisions outside the window, other senders and other companies are not touches;
    /// owner comments on items are listed, not counted.
    @Test func ownerTouchesCountsDecisionsAndMessages() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.seed(store, name: "Acme", landed: 20, now: t0)
        let zeta = try MeasureFixtures.seed(store, name: "Zeta", landed: 1, now: t0)
        let inWindow = t0.addingTimeInterval(-2 * day), before = t0.addingTimeInterval(-15 * day)
        for n in 1...3 { try MeasureFixtures.ask(store, company: acme, number: n, decidedAt: inWindow) }
        try MeasureFixtures.ask(store, company: acme, number: 4, decidedBy: "preset:readonly-web-engineers", decidedAt: inWindow)
        try MeasureFixtures.ask(store, company: acme, number: 5, decidedBy: "@cto", decidedAt: nil)
        try MeasureFixtures.ask(store, company: acme, number: 6, decidedAt: before)
        try MeasureFixtures.ask(store, company: zeta, number: 1, decidedAt: inWindow)
        try MeasureFixtures.message(store, company: acme, senderId: "owner", at: inWindow)
        try MeasureFixtures.message(store, company: acme, senderId: "owner", kind: .share, at: inWindow)
        try MeasureFixtures.message(store, company: acme, senderId: "owner", kind: .system, at: inWindow)
        try MeasureFixtures.message(store, company: acme, senderId: "system", at: inWindow)
        try MeasureFixtures.message(store, company: acme, senderId: "agent-1", at: inWindow)
        try MeasureFixtures.message(store, company: acme, senderId: "owner", at: before)
        try MeasureFixtures.message(store, company: zeta, senderId: "owner", at: inWindow)
        let landed = try store.workItems(companyId: acme.id)[0]
        try MeasureFixtures.event(store, item: landed, kind: .commented, at: inWindow, actor: "owner")
        // C5b writes a `reviewComment` beside every `commented`: one comment, not two.
        try MeasureFixtures.event(store, item: landed, kind: .reviewComment, at: inWindow, actor: "owner")

        let m = try UsageMetrics.ownerTouches(try ctx(store, acme, since: t0.addingTimeInterval(-10 * day)))
        #expect(m.unit == .perItem && m.status == .ok, "\(m.display)")
        #expect(m.numerator == 5 && m.denominator == 20)
        #expect(m.display == "0.25 per landed item (5/20)")
        #expect(try row(m, "inbox decisions").numerator == 3)
        #expect(try row(m, "owner messages").numerator == 2)
        let comments = try row(m, "owner comments on items")
        #expect(comments.numerator == 1 && comments.basis.contains("not in the rate"), "\(comments.basis)")
    }

    // MARK: Safety

    /// Cap overruns need a cap and the charges against it: X1's `providerCap` and `gatewayCharge`. Neither exists on this tree, and
    /// the scheduler never admits above a mode cap, so the row is not applicable (never a 0).
    @Test func capOverrunNotApplicableWithoutCapRecords() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.seed(store, name: "Acme", landed: 1, now: t0)
        let m = try UsageMetrics.safety(try ctx(store, acme))
        let cap = try row(m, "cap overruns")
        guard case .notApplicable(let reason) = cap.status else { Issue.record("\(cap.status)"); return }
        #expect(reason.contains("no cap-overrun record"), "\(reason)")
        #expect(cap.target == nil && cap.numerator == 0)
    }

    /// Turns rejected by the rate limit (`outcome = usageLimited`) in the window, target 0; the other safety rows count their own
    /// records (taint refusals per turn, access refusals, DLP bounces, owner-wide canary passes, owner-wide reserve breaches).
    @Test func rateLimitWastedTurnsCounted() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.company(store, name: "Acme", createdAt: t0.addingTimeInterval(-30 * day))
        let zeta = try MeasureFixtures.company(store, name: "Zeta", createdAt: t0.addingTimeInterval(-30 * day))
        let eng = try MeasureFixtures.agent(store, company: acme, name: "eng")
        let zed = try MeasureFixtures.agent(store, company: zeta, name: "zed")
        let inWindow = t0.addingTimeInterval(-day), before = t0.addingTimeInterval(-20 * day)
        try MeasureFixtures.turn(store, agent: eng, outcome: .usageLimited, at: inWindow)
        try MeasureFixtures.turn(store, agent: eng, outcome: .usageLimited, at: inWindow.addingTimeInterval(60))
        try MeasureFixtures.turn(store, agent: eng, outcome: .usageLimited, at: before)
        try MeasureFixtures.turn(store, agent: eng, outcome: .succeeded, at: inWindow)
        try MeasureFixtures.turn(store, agent: eng, freshSessionReason: "tainted", at: inWindow)
        try MeasureFixtures.turn(store, agent: zed, outcome: .usageLimited, at: inWindow)
        try MeasureFixtures.accessRefusal(store, company: acme, agent: eng, at: inWindow)
        try MeasureFixtures.accessRefusal(store, company: zeta, agent: zed, at: inWindow)
        let items = try MeasureFixtures.items(store, company: acme, count: 2, now: before)
        let (batch, _) = try MeasureFixtures.land(store, company: acme, items: [items[0]], number: 1, enqueuedAt: inWindow, landedAt: inWindow)
        try MeasureFixtures.bounce(store, company: acme, batch: batch, item: items[1], number: 900, failure: .secretFound,
                                   enqueuedAt: inWindow, bouncedAt: inWindow)
        try MeasureFixtures.canaryPass(store, key: "k1", at: inWindow)
        try MeasureFixtures.canaryPass(store, key: "k2", at: before)
        // One reserve breach observed by the recorder in the window.
        try MeasureFixtures.usage(store, sevenDay: 0.9, observedAt: inWindow)
        try MeasureRecorder.record(store: store, companies: [], tick: MeasureRecorder.Tick(ownerReserve: 0.3), now: inWindow)

        let m = try UsageMetrics.safety(try ctx(store, acme, since: t0.addingTimeInterval(-10 * day)))
        let wasted = try row(m, "turns wasted on rate limits")
        #expect(wasted.numerator == 2 && wasted.target == 0 && wasted.status == .ok)
        #expect(wasted.display == "2 (target 0)")
        #expect(try row(m, "taint refusals").numerator == 1)
        #expect(try row(m, "taint refusals").basis.contains("one per refused turn, not per call"))
        #expect(try row(m, "access refusals").numerator == 1)
        #expect(try row(m, "DLP hits").numerator == 1)
        let canary = try row(m, "canary passes")
        #expect(canary.numerator == 1 && canary.basis.contains("owner-wide"), "\(canary.basis)")
        #expect(try row(m, "canary failures").status == .notApplicable(reason: "canary failures are not recorded (sandboxCanary keeps passes only)"))
        let breaches = try row(m, "reserve breaches")
        #expect(breaches.numerator == 1 && breaches.target == 0 && breaches.status == .ok)
        #expect(breaches.basis.contains("owner-wide"), "\(breaches.basis)")
        // The headline: the measured target-0 events (breaches + wasted turns).
        #expect(m.unit == .count && m.numerator == 3 && m.target == 0 && m.status == .ok)

        // Before the recorder ever ran, reserve breaches are not measured (a 0 would claim a record nobody kept).
        let fresh = try Store.inMemory()
        let bare = try MeasureFixtures.company(fresh, name: "Bare", createdAt: t0.addingTimeInterval(-30 * day))
        let none = try row(try UsageMetrics.safety(try ctx(fresh, bare)), "reserve breaches")
        #expect(none.status == .notMeasured(reason: "recorder not running"))
    }

    /// Channel refusals need X4's Approved channels: not applicable. Non-code acceptance needs `landGate` items and rubric checks:
    /// not applicable, with the owner's gate decisions shown as detail (approved of decided, per kind), never as the rate.
    @Test func channelsNotApplicable() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.seed(store, name: "Acme", landed: 1, now: t0)
        let safety = try UsageMetrics.safety(try ctx(store, acme))
        #expect(try row(safety, "channel refusals").status == .notApplicable(reason: "channels (X4) absent"))

        let inWindow = t0.addingTimeInterval(-day)
        try MeasureFixtures.ask(store, company: acme, number: 1, kind: .prd, status: .approved, decidedAt: inWindow)
        try MeasureFixtures.ask(store, company: acme, number: 2, kind: .prd, status: .rejected, decidedAt: inWindow)
        try MeasureFixtures.ask(store, company: acme, number: 3, kind: .release, status: .approved, decidedAt: inWindow)
        try MeasureFixtures.ask(store, company: acme, number: 4, kind: .info, status: .answered, decidedAt: inWindow)
        try MeasureFixtures.ask(store, company: acme, number: 5, kind: .prd, status: .approved, decidedBy: "policy:auto", decidedAt: inWindow)
        let nonCode = try UsageMetrics.nonCode(try ctx(store, acme))
        #expect(nonCode.status == .notApplicable(reason: "landGate items and rubric checks absent"))
        let prd = try row(nonCode, "prd gate asks approved")
        #expect(prd.numerator == 1 && prd.basis.contains("1 of 2 decided by the owner"), "\(prd.basis)")
        #expect(try row(nonCode, "release gate asks approved").numerator == 1)
        #expect(!nonCode.detail.contains { $0.label.hasPrefix("info") })
    }

    // MARK: Model ranking

    /// An item is attributed to its assignee's role and to the model family that ran most of its work turns (`turn.modelsUsed`;
    /// a background haiku beside another family is not the turn's model); with no turn naming one, to the agent's model. A tie
    /// is no majority: excluded and counted. Each (role, model) row carries its own n.
    @Test func modelRankingAttributesByMajority() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.company(store, name: "Acme", createdAt: t0.addingTimeInterval(-30 * day))
        let eng = try MeasureFixtures.agent(store, company: acme, name: "eng", role: "engineer", model: "sonnet")
        let rev = try MeasureFixtures.agent(store, company: acme, name: "rev", role: "reviewer", model: "opus")
        let items = try MeasureFixtures.items(store, company: acme, count: 5, now: t0.addingTimeInterval(-10 * day))
        let at = t0.addingTimeInterval(-5 * day)
        // 1: two opus turns, one sonnet → opus.
        for m in ["claude-opus-5-5", "claude-opus-5-5,claude-haiku-5-5", "claude-sonnet-5-5"] {
            try MeasureFixtures.turn(store, agent: eng, item: items[0], modelsUsed: m, at: at)
        }
        // 2: a background haiku beside sonnet is a sonnet turn.
        try MeasureFixtures.turn(store, agent: eng, item: items[1], modelsUsed: "claude-haiku-5-5,claude-sonnet-5-5", at: at)
        // 3: no turn names a model → the agent's model (sonnet). A review turn is never the item's work.
        try MeasureFixtures.turn(store, agent: rev, item: items[2], kind: .review, modelsUsed: "claude-opus-5-5", at: at)
        // 4: one opus, one sonnet → no majority.
        try MeasureFixtures.turn(store, agent: eng, item: items[3], modelsUsed: "claude-opus-5-5", at: at)
        try MeasureFixtures.turn(store, agent: eng, item: items[3], modelsUsed: "claude-sonnet-5-5", at: at)
        // 5: its only turn names two families (cumulative over a resume): ambiguous, excluded — never the agent's current model.
        try MeasureFixtures.turn(store, agent: eng, item: items[4], modelsUsed: "claude-opus-5-5,claude-sonnet-5-5", at: at)
        // Item 2's second sonnet turn runs after its first submit (below); a rate-limited opus turn is not a counted turn.
        try MeasureFixtures.turn(store, agent: eng, item: items[1], modelsUsed: "claude-sonnet-5-5", at: at.addingTimeInterval(250))
        try MeasureFixtures.turn(store, agent: eng, item: items[1], outcome: .usageLimited, modelsUsed: "claude-opus-5-5", at: at.addingTimeInterval(260))
        try MeasureFixtures.turn(store, agent: eng, item: items[1], outcome: .usageLimited, modelsUsed: "claude-opus-5-5", at: at.addingTimeInterval(270))
        try MeasureFixtures.landEach(store, company: acme, items: items, at: Array(repeating: t0.addingTimeInterval(-4 * day), count: 5))
        for (i, item) in items.enumerated() {
            try MeasureFixtures.fact(store, item: item, firstPass: i != 1, costLE: 2, reviewRejections: i, ownerId: eng.id, reviewerId: rev.id,
                                     reworkRounds: i)
        }
        // Item 2 was caught in review and confirmed: the reviewer's catch.
        try MeasureFixtures.event(store, item: items[1], kind: .changesRequested, at: at.addingTimeInterval(100), actor: rev.id)
        try MeasureFixtures.event(store, item: items[1], kind: .submitted, at: at.addingTimeInterval(200), actor: eng.id)
        try MeasureFixtures.verificationRun(store, company: acme, item: items[1], finishedAt: at.addingTimeInterval(300))

        let m = try UsageMetrics.modelRanking(try ctx(store, acme))
        #expect(m.status == .ok, "\(m.display)")
        #expect(m.numerator == 3, "three items attributed")
        #expect(m.basis.contains("2 landed items with no majority model excluded"), "\(m.basis)")
        #expect(m.basis.contains("1 by the agent's model"), "\(m.basis)")
        let opus = try row(m, "engineer · opus")
        #expect(opus.numerator == 1)
        let sonnet = try row(m, "engineer · sonnet")
        #expect(sonnet.numerator == 2)
        let firstPass = try #require(sonnet.detail.first { $0.label == "first-pass" })
        #expect(firstPass.numerator == 1 && firstPass.denominator == 2 && firstPass.status == .insufficient(n: 2))
        let rework = try #require(sonnet.detail.first { $0.label == "rework rounds" })
        #expect(rework.numerator == 3 && rework.denominator == 2 && rework.unit == .perItem)   // items 2 (1) and 3 (2)
        let cost = try #require(sonnet.detail.first { $0.label == "$LE (subscription)" })
        #expect(cost.numerator == 4 && cost.denominator == 2 && cost.unit == .usd)
        let rejections = try #require(sonnet.detail.first { $0.label == "review rejections" })
        #expect(rejections.numerator == 3 && rejections.denominator == 2 && rejections.unit == .perItem)  // items 2 (1) and 3 (2)
        let after = try #require(sonnet.detail.first { $0.label == "turns after first submit" })
        #expect(after.numerator == 1 && after.denominator == 2 && after.unit == .perItem, "\(after)")
        // The reviewer's row: its catches over the items it reviewed (caught + escaped).
        let reviewer = try row(m, "reviewer · opus")
        let catchRate = try #require(reviewer.detail.first { $0.label == "review catch (as reviewer)" })
        #expect(catchRate.numerator == 1 && catchRate.denominator == 1 && catchRate.status == .insufficient(n: 1))
        // Labels are roles and model families only.
        #expect(m.detail.allSatisfy { !$0.label.contains("Item ") })
    }

    /// Final review #4(e): model ranking walks every landed item; a cancelled run (the app left the company or window) stops in
    /// that loop with `CancellationError`, never finishes the scan.
    @Test func modelRankingStopsWhenCancelled() async throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.seed(store, name: "Acme", landed: 3, now: t0)
        let c = try ctx(store, acme)
        let task = Task.detached { () throws -> MetricValue in  // scope-escape: cancels itself and ranks an in-memory store; no scratch dirs
            withUnsafeCurrentTask { $0?.cancel() }
            return try UsageMetrics.modelRanking(c)
        }
        await #expect(throws: CancellationError.self) { try await task.value }
    }

    /// Final review #9: the reviewer row counts a confirmed catch whenever it was confirmed up to the window's end, even before
    /// the window began (the item landed in the window); the review catch rate counts only catches confirmed in the window.
    /// One confirmed-catch rule serves both.
    @Test func reviewerCatchesUseOneRuleWithTheirOwnWindow() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.company(store, name: "Acme", createdAt: t0.addingTimeInterval(-30 * day))
        let eng = try MeasureFixtures.agent(store, company: acme, name: "eng", role: "engineer", model: "sonnet")
        let rev = try MeasureFixtures.agent(store, company: acme, name: "rev", role: "reviewer", model: "opus")
        let item = try MeasureFixtures.items(store, company: acme, count: 1, now: t0.addingTimeInterval(-20 * day))[0]
        let at = t0.addingTimeInterval(-15 * day)
        try MeasureFixtures.event(store, item: item, kind: .changesRequested, at: at, actor: rev.id)
        try MeasureFixtures.event(store, item: item, kind: .submitted, at: at.addingTimeInterval(100), actor: eng.id)
        try MeasureFixtures.verificationRun(store, company: acme, item: item, finishedAt: at.addingTimeInterval(200))
        try MeasureFixtures.landEach(store, company: acme, items: [item], at: [t0.addingTimeInterval(-4 * day)])
        try MeasureFixtures.fact(store, item: item, ownerId: eng.id, reviewerId: rev.id)
        let c = try ctx(store, acme, since: t0.addingTimeInterval(-10 * day))
        let ranking = try UsageMetrics.modelRanking(c)
        let catchRate = try #require(try row(ranking, "reviewer · opus").detail.first { $0.label == "review catch (as reviewer)" })
        #expect(catchRate.numerator == 1 && catchRate.denominator == 1, "\(catchRate)")
        let review = try ReviewMetrics.reviewCatch(c)
        #expect(try row(review, "confirmed catches").numerator == 0, "confirmed before the window began")
        #expect(try ReviewMetrics.reviewCatch(try ctx(store, acme)).detail.first { $0.label == "confirmed catches" }?.numerator == 1)
    }

    /// An agent whose model is not one of the three families is ranked under that model (as a safe token); an `auto` agent with no
    /// turn naming a model is excluded with that reason, never "no model recorded".
    @Test func modelRankingUnknownAndAutoModels() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.company(store, name: "Acme", createdAt: t0.addingTimeInterval(-30 * day))
        let odd = try MeasureFixtures.agent(store, company: acme, name: "odd", role: "engineer", model: "mystery-1")
        let auto = try MeasureFixtures.agent(store, company: acme, name: "auto", role: "engineer", model: "auto")
        let items = try MeasureFixtures.items(store, company: acme, count: 2, now: t0.addingTimeInterval(-10 * day))
        try MeasureFixtures.landEach(store, company: acme, items: items, at: [t0.addingTimeInterval(-4 * day), t0.addingTimeInterval(-4 * day)])
        try MeasureFixtures.fact(store, item: items[0], ownerId: odd.id)
        try MeasureFixtures.fact(store, item: items[1], ownerId: auto.id)
        let m = try UsageMetrics.modelRanking(try ctx(store, acme))
        #expect(try row(m, "engineer · mystery-1").numerator == 1)
        #expect(m.basis.contains("1 landed item whose agent's model is auto and no turn named a model excluded"), "\(m.basis)")
        #expect(!m.basis.contains("no model recorded"), "\(m.basis)")
    }

    /// `brahma company trust-import` ends the company's tainted sessions with its own reason, `trustImport` (ruling R33), so a
    /// taint refusal is exactly `freshSessionReason = tainted`. Through the real flow: the pending base-scope reason waits past an
    /// item-scope turn and lands on the next base-scope turn as `trustImport` — no refusal. A refused call under taint
    /// (`requestFreshSession`, then the turn's end) lands `tainted` on the agent's next turn — one refusal.
    @Test func taintRefusalsAreExactNotTrustImport() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.company(store, name: "Acme", createdAt: t0.addingTimeInterval(-30 * day))
        let eng = try MeasureFixtures.agent(store, company: acme, name: "eng")
        let item = try MeasureFixtures.items(store, company: acme, count: 1, now: t0.addingTimeInterval(-10 * day))[0]
        let base = t0.addingTimeInterval(-5 * day)
        try store.writer.write { db in try Store.markImported(db, companyId: acme.id, source: "import: example.com", now: base) }
        try store.markTainted(agentId: eng.id, source: "import: example.com", now: base)
        #expect(try store.trustImport(companyId: acme.id, now: base.addingTimeInterval(600)) != nil)
        // An item-scope turn: the base-scope reason stays pending.
        let itemTurn = try MeasureFixtures.turn(store, agent: eng, item: item, at: base.addingTimeInterval(1200))
        #expect(try store.applyPendingSessionReset(agentId: eng.id, turnId: itemTurn.id, scope: .item(item.id)) == nil)
        // The next base-scope turn carries the owner's reset.
        let baseTurn = try MeasureFixtures.turn(store, agent: eng, at: base.addingTimeInterval(1800))
        #expect(try store.applyPendingSessionReset(agentId: eng.id, turnId: baseTurn.id, scope: .base) == "trustImport")
        let afterTrust = try row(try UsageMetrics.safety(try ctx(store, acme)), "taint refusals")
        #expect(afterTrust.numerator == 0)
        #expect(afterTrust.basis.contains("trust-import resets recorded before"), "\(afterTrust.basis)")

        // A real refusal: a high-risk call refused under taint, the turn's end forces the fresh session, the next turn carries it.
        try store.requestFreshSession(agentId: eng.id)
        #expect(try store.clearTaintIfRequested(agentId: eng.id, scope: .base, now: base.addingTimeInterval(2000)))
        let refusedNext = try MeasureFixtures.turn(store, agent: eng, at: base.addingTimeInterval(2400))
        #expect(try store.applyPendingSessionReset(agentId: eng.id, turnId: refusedNext.id, scope: .base) == "tainted")
        #expect(try row(try UsageMetrics.safety(try ctx(store, acme)), "taint refusals").numerator == 1)
    }

    /// Owner minutes are the owner's alone (ruling R32): an agent process holding no principal can't log them, and the generic
    /// counter write refuses the owner's counter.
    @Test func ownerMinutesNeedTheOwner() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.company(store, name: "Acme")
        let owner = try OwnerPrincipal.mint()
        #expect(throws: WorkError.self) {
            try OwnerPrincipal.simulatingAgentProcess {
                try store.logOwnerMinutes(companyId: acme.id, minutes: 10, day: "2026-11-01", owner: owner)
            }
        }
        #expect(throws: WorkError.self) {
            try store.addCounter(companyId: acme.id, name: MeasureCounter.ownerInterventionSeconds, day: "2026-11-01", delta: 600)
        }
        #expect(throws: WorkError.self) {
            try store.writer.write { db in
                try Store.addCounter(db, companyId: acme.id, name: MeasureCounter.ownerInterventionSeconds, day: "2026-11-01", delta: 600)
            }
        }
        #expect(try MeasureFixtures.counter(store, companyId: acme.id, MeasureCounter.ownerInterventionSeconds) == 0)
        try store.logOwnerMinutes(companyId: acme.id, minutes: 10, day: "2026-11-01", owner: owner)
        #expect(try MeasureFixtures.counter(store, companyId: acme.id, MeasureCounter.ownerInterventionSeconds) == 600)
    }

    // MARK: Idle while actionable, items per $LE and per plan-hour

    /// Idle-while-actionable seconds ÷ company-active seconds from the recorder's daily counters, by cause. With no active-seconds
    /// record in the window both idle and plan-hour metrics are not measured (ruling R15), never 0.
    @Test func idleAndPlanHourFromCounters() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.seed(store, name: "Acme", landed: 1, now: t0)
        let c = try ctx(store, acme, since: t0.addingTimeInterval(-10 * day))
        #expect(try UsageMetrics.idleActionable(c).status == .notMeasured(reason: "no active-seconds records in window"))
        #expect(try UsageMetrics.itemsPerPlanHour(c).status == .notMeasured(reason: "no active-seconds records in window"))
        let d = Store.measureDay(t0.addingTimeInterval(-6 * day), in: Self.utc)
        try store.addCounter(companyId: acme.id, name: MeasureCounter.activeSeconds, day: d, delta: 1000)
        try store.addCounter(companyId: acme.id, name: MeasureCounter.idleActionableSeconds, day: d, delta: 250)
        try store.addCounter(companyId: acme.id, name: MeasureCounter.idleUsageLimitSeconds, day: d, delta: 200)
        try store.addCounter(companyId: acme.id, name: MeasureCounter.idlePaceSeconds, day: d, delta: 50)
        // Outside the window: not counted.
        try store.addCounter(companyId: acme.id, name: MeasureCounter.activeSeconds,
                             day: Store.measureDay(t0.addingTimeInterval(-20 * day), in: Self.utc), delta: 9999)
        let idle = try UsageMetrics.idleActionable(c)
        // Ruling R32: n is the days with an active-seconds record, not seconds.
        #expect(idle.status == .insufficient(n: 1) && idle.numerator == 250 && idle.denominator == 1000 && idle.unit == .ratio)
        #expect(idle.basis.contains("n = days with active-seconds records (1)"), "\(idle.basis)")
        // Final review #11: the one known under-count is stated.
        #expect(idle.basis.contains("a tick whose scheduling failed after its active seconds were counted records no idle seconds"),
                "\(idle.basis)")
        #expect(try row(idle, "five-hour gate").numerator == 200)
        #expect(try row(idle, "weekly pace").numerator == 50)
        #expect(try row(idle, "owner reserve").numerator == 0)
        // Twenty recorded days: measured.
        let long = try MeasureFixtures.company(store, name: "Long", createdAt: t0.addingTimeInterval(-30 * day))
        for n in 1...20 {
            try store.addCounter(companyId: long.id, name: MeasureCounter.activeSeconds,
                                 day: Store.measureDay(t0.addingTimeInterval(-Double(n) * day), in: Self.utc), delta: 50)
        }
        try store.addCounter(companyId: long.id, name: MeasureCounter.idleActionableSeconds, day: d, delta: 250)
        let longer = try UsageMetrics.idleActionable(try ctx(store, long, since: t0.addingTimeInterval(-25 * day)))
        #expect(longer.status == .ok, "\(longer.display) \(longer.basis)")
        #expect(longer.display == "25.0% (250/1000)")
    }

    /// Landed items ÷ Σ itemFact.costLE ($LE, subscription) and ÷ company-active hours. An item without a fact has no cost and is
    /// excluded from items per $LE; an item landed before company-active time was recorded is excluded from items per plan-hour.
    @Test func itemsPerDollarAndPlanHour() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.seed(store, name: "Acme", landed: 24, now: t0)        // landed t0 - 4 d, costs 1…24
        _ = try landWithoutFact(store, acme, number: 2, at: t0.addingTimeInterval(-20 * day))
        try store.addCounter(companyId: acme.id, name: MeasureCounter.activeSeconds,
                             day: Store.measureDay(t0.addingTimeInterval(-5 * day), in: Self.utc), delta: 43_200)
        let c = try ctx(store, acme)
        let perDollar = try UsageMetrics.itemsPerDollar(c)
        #expect(perDollar.unit == .perUSD && perDollar.status == .ok, "\(perDollar.display)")
        #expect(perDollar.numerator == 24 && perDollar.denominator == 300)
        #expect(perDollar.display == "0.08 per $LE (24/300.00)")
        #expect(perDollar.basis.contains("$LE (subscription)") && perDollar.basis.contains("1 landed item without an item fact excluded"),
                "\(perDollar.basis)")
        #expect(try row(perDollar, "$LE (subscription)").numerator == 24)
        let perHour = try UsageMetrics.itemsPerPlanHour(c)
        #expect(perHour.unit == .perHour && perHour.status == .ok, "\(perHour.display)")
        #expect(perHour.numerator == 24 && perHour.denominator == 12)
        #expect(perHour.display == "2.00 per plan-hour (24/12.00)")
        #expect(perHour.basis.contains("1 landed item before company-active time was recorded excluded"), "\(perHour.basis)")
    }

    /// No cost on the landed items (facts with costLE 0, or no facts): items per $LE is not measured, never infinite. Nothing landed:
    /// not measured.
    @Test func itemsPerDollarNotMeasuredWithoutCost() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.company(store, name: "Acme", createdAt: t0.addingTimeInterval(-30 * day))
        #expect(try UsageMetrics.itemsPerDollar(try ctx(store, acme)).status == .notMeasured(reason: "no landings in the window"))
        let items = try MeasureFixtures.items(store, company: acme, count: 2, now: t0.addingTimeInterval(-10 * day))
        try MeasureFixtures.land(store, company: acme, items: items, number: 1, enqueuedAt: t0.addingTimeInterval(-3 * day),
                                 landedAt: t0.addingTimeInterval(-2 * day))
        #expect(try UsageMetrics.itemsPerDollar(try ctx(store, acme)).status
                == .notMeasured(reason: "no cost recorded for the landed items"))
        for item in items { try MeasureFixtures.fact(store, item: item, costLE: 0) }
        let m = try UsageMetrics.itemsPerDollar(try ctx(store, acme))
        #expect(m.status == .notMeasured(reason: "no cost recorded for the landed items"))
        #expect(m.display == "not measured: no cost recorded for the landed items")
    }

    // MARK: Owner minutes

    /// The only source is the owner's own log: with no rows in the window, not measured (owner ruling R7(d)).
    @Test func ownerMinutesNotMeasuredWithoutRecords() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.seed(store, name: "Acme", landed: 20, now: t0)
        let zeta = try MeasureFixtures.seed(store, name: "Zeta", landed: 1, now: t0)
        // Another company's log and a log before the window are not this window's records.
        try store.logOwnerMinutes(companyId: zeta.id, minutes: 30, day: Store.measureDay(t0.addingTimeInterval(-day), in: Self.utc), owner: try OwnerPrincipal.mint())
        try store.logOwnerMinutes(companyId: acme.id, minutes: 30, day: Store.measureDay(t0.addingTimeInterval(-20 * day), in: Self.utc), owner: try OwnerPrincipal.mint())
        let m = try UsageMetrics.ownerMinutes(try ctx(store, acme, since: t0.addingTimeInterval(-10 * day)))
        #expect(m.status == .notMeasured(reason: "no owner-time records"))
        #expect(m.display == "not measured: no owner-time records")
    }

    /// Σ ownerInterventionSeconds ÷ 60 ÷ landed items in the window: a rate under the 20-event rule, n = landed items (ruling R44);
    /// 5 landed items are `insufficient data (n=5)`, with the logged minutes still shown in the detail.
    @Test func ownerMinutesPerItemFromLog() throws {
        let store = try Store.inMemory()
        let acme = try MeasureFixtures.seed(store, name: "Acme", landed: 30, now: t0)
        try store.logOwnerMinutes(companyId: acme.id, minutes: 30, day: Store.measureDay(t0.addingTimeInterval(-2 * day), in: Self.utc), owner: try OwnerPrincipal.mint())
        try store.logOwnerMinutes(companyId: acme.id, minutes: 15, day: Store.measureDay(t0.addingTimeInterval(-3 * day), in: Self.utc), owner: try OwnerPrincipal.mint())
        try store.logOwnerMinutes(companyId: acme.id, minutes: 100, day: Store.measureDay(t0.addingTimeInterval(-20 * day), in: Self.utc), owner: try OwnerPrincipal.mint())
        #expect(try MeasureFixtures.counter(store, companyId: acme.id, MeasureCounter.ownerInterventionSeconds) == 145 * 60)
        let m = try UsageMetrics.ownerMinutes(try ctx(store, acme, since: t0.addingTimeInterval(-10 * day)))
        #expect(m.status == .ok && m.unit == .perItem)
        #expect(m.numerator == 45 && m.denominator == 30)
        #expect(m.display == "1.50 per landed item (45/30)")
        #expect(m.basis.contains("owner-logged"), "\(m.basis)")

        let small = try MeasureFixtures.seed(store, name: "Small", landed: 5, now: t0)
        try store.logOwnerMinutes(companyId: small.id, minutes: 10, day: Store.measureDay(t0.addingTimeInterval(-day), in: Self.utc), owner: try OwnerPrincipal.mint())
        let few = try UsageMetrics.ownerMinutes(try ctx(store, small, since: t0.addingTimeInterval(-10 * day)))
        #expect(few.status == .insufficient(n: 5) && few.display == "insufficient data (n=5)", "\(few.display)")
        #expect(few.numerator == 10 && few.denominator == 5)
        #expect(try row(few, "owner minutes logged").numerator == 10)
        #expect(try row(few, "owner minutes logged").display == "10")
        // Exactly twenty landed items: measured.
        let twenty = try MeasureFixtures.seed(store, name: "Twenty", landed: 20, now: t0)
        try store.logOwnerMinutes(companyId: twenty.id, minutes: 30, day: Store.measureDay(t0.addingTimeInterval(-day), in: Self.utc), owner: try OwnerPrincipal.mint())
        let enough = try UsageMetrics.ownerMinutes(try ctx(store, twenty, since: t0.addingTimeInterval(-10 * day)))
        #expect(enough.status == .ok && enough.display == "1.50 per landed item (30/20)", "\(enough.display)")
        // Logged minutes with no landing: not measured, the minutes shown in the detail.
        let idle = try MeasureFixtures.company(store, name: "Idle", createdAt: t0.addingTimeInterval(-30 * day))
        try store.logOwnerMinutes(companyId: idle.id, minutes: 20, day: Store.measureDay(t0.addingTimeInterval(-day), in: Self.utc), owner: try OwnerPrincipal.mint())
        let none = try UsageMetrics.ownerMinutes(try ctx(store, idle))
        #expect(none.status == .notMeasured(reason: "no landings in the window"))
        #expect(try row(none, "owner minutes logged").numerator == 20)
        // A log is a positive number of minutes on a real day.
        #expect(throws: MeasureError.self) { try store.logOwnerMinutes(companyId: idle.id, minutes: 0, day: "2026-11-01", owner: try OwnerPrincipal.mint()) }
        #expect(throws: MeasureError.self) { try store.logOwnerMinutes(companyId: idle.id, minutes: 10, day: "2026-13-01", owner: try OwnerPrincipal.mint()) }
    }
}
