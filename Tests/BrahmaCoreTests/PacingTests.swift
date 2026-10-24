import Foundation
import Testing
@testable import BrahmaCore

private let week: TimeInterval = 7 * 86_400
private let now = Date(timeIntervalSince1970: 1_800_000_000)

/// Seven-day window `elapsed` of the way through, at `util`.
private func info(elapsed: Double = 0.5, util: Double? = 0.2, hasReset: Bool = true,
                  fiveHour: Double? = 0.1, status: String = "allowed") -> RateLimitInfo {
    RateLimitInfo(status: status, resetsAt: now.addingTimeInterval(3600), rateLimitType: "five_hour", isUsingOverage: false,
                  fiveHourUtilization: fiveHour, sevenDayUtilization: util, observedAt: now,
                  fiveHourResetsAt: now.addingTimeInterval(3600),
                  sevenDayResetsAt: hasReset ? now.addingTimeInterval(week * (1 - elapsed)) : nil)
}
private func reset(_ i: RateLimitInfo) -> Date { i.sevenDayResetsAt! }

@Suite struct PacingTests {
    @Test func burstConstant() { #expect(UsageGate.burst == 0.15) }

    @Test func paceClosesWhenAhead() {
        // elapsed .5, reserve .3: allowed = min(.7, .65 * .7) = .455
        let closed = info(util: 0.46)
        let expectedUntil = reset(closed).addingTimeInterval(-week + week * (0.46 / 0.7 - 0.15))
        #expect(UsageGate.evaluate(closed, mode: .max, now: now, reserve: 0.3) == .closed(until: expectedUntil))
        #expect(expectedUntil > now)
        #expect(UsageGate.evaluate(info(util: 0.45), mode: .max, now: now, reserve: 0.3) == .open)
    }

    @Test func pastReserveClosesUntilReset() {
        let i = info(util: 0.72)
        #expect(UsageGate.evaluate(i, mode: .max, now: now, reserve: 0.3) == .closed(until: reset(i)))
        // Late in the week the burst allowance is capped at the reserve line.
        let late = info(elapsed: 0.95, util: 0.70)
        #expect(UsageGate.evaluate(late, mode: .max, now: now, reserve: 0.3) == .closed(until: reset(late)))
        #expect(UsageGate.evaluate(info(elapsed: 0.95, util: 0.69), mode: .max, now: now, reserve: 0.3) == .open)
    }

    @Test func appliesInEveryMode() {
        for mode in UsageMode.allCases {
            let i = info(util: 0.5)
            guard case .closed = UsageGate.evaluate(i, mode: mode, now: now, reserve: 0.3) else {
                Issue.record("\(mode) should be paced"); continue
            }
        }
    }

    @Test func noSevenDayDataNoPacing() {
        #expect(UsageGate.pace(info(util: nil), reserve: 0.3, now: now) == nil)
        #expect(UsageGate.pace(info(util: 0.9, hasReset: false), reserve: 0.3, now: now) == nil)
        #expect(UsageGate.pace(nil, reserve: 0.3, now: now) == nil)
        #expect(UsageGate.evaluate(info(util: 0.9, hasReset: false), mode: .max, now: now, reserve: 0.3) == .open)
    }

    @Test func paceText() throws {
        let on = try #require(UsageGate.pace(info(util: 0.30), reserve: 0.3, now: now))
        #expect(on.text == "on pace"); #expect(on.ahead == 0); #expect(on.used == 0.30)
        #expect(abs(on.allowed - 0.455) < 1e-9)
        let ahead = try #require(UsageGate.pace(info(util: 0.555), reserve: 0.3, now: now))
        #expect(ahead.text == "ahead by 10%")
        #expect(abs(ahead.ahead - 0.1) < 1e-9)
    }

    @Test func companyReserveOverridesGlobal() {
        var config = SchedulerConfig()
        #expect(config.ownerReserve == 0.30)
        let c = Company(id: "c", name: "c", slug: "c", goal: "g", workspacePath: "/tmp", status: .running, usageMode: .max,
                        priorityWeight: 1, createdAt: now)
        #expect(config.reserve(for: c) == 0.30)
        var over = c; over.ownerReserve = 0.5
        #expect(config.reserve(for: over) == 0.5)
        config.ownerReserve = 0.2
        #expect(config.reserve(for: c) == 0.2)
        // util .46 is closed at reserve .3 but open at reserve .1 (allowed .585)
        let i = info(util: 0.46)
        #expect(UsageGate.evaluate(i, mode: .max, now: now, reserve: config.reserve(for: c)) == .open)
        #expect(UsageGate.evaluate(i, mode: .max, now: now, reserve: 0.3) != .open)
    }

    @Test func fiveHourAndPaceCombine() {
        // The five-hour limit closes until its reset (3600 s); pace closes until much later. The later wins.
        let i = info(util: 0.5, fiveHour: 0.99)
        let parts = UsageGate.evaluateParts(i, mode: .low, now: now, reserve: 0.3)
        #expect(parts.fiveHour == .closed(until: now.addingTimeInterval(3600)))
        guard case .closed(let paceUntil) = parts.pace else { Issue.record("pace should be closed"); return }
        #expect(paceUntil > now.addingTimeInterval(3600))
        #expect(UsageGate.evaluate(i, mode: .low, now: now, reserve: 0.3) == .closed(until: paceUntil))
        let onlyPace = UsageGate.evaluateParts(info(util: 0.5), mode: .max, now: now, reserve: 0.3)
        #expect(onlyPace.fiveHour == .open)
    }

    @Test func paceExemptsCriticalPath() {
        let c = Company(id: "c", name: "c", slug: "c", goal: "g", workspacePath: "/tmp", status: .running, usageMode: .max,
                        priorityWeight: 1, createdAt: now)
        func cand(_ name: String, blocking: Int) -> Candidate {
            Candidate(agent: Agent(id: name, companyId: "c", name: name, role: "engineer", model: "m", sessionId: "s",
                                   sessionStarted: false, state: .ready, blocker: nil, requestedBlocker: nil, paused: false,
                                   readySince: now, createdAt: now),
                      company: c, blockingCount: blocking)
        }
        var config = SchedulerConfig(); config.planTier = .max20x; config.safetyCap = 100
        let candidates = [cand("a", blocking: 0), cand("b", blocking: 2), cand("d", blocking: 1)]
        let picked = Scheduler.select(candidates: candidates, runningByCompany: [:], config: config, usage: { _ in .open },
                                      paceClosed: ["c"])
        #expect(picked.map(\.name) == ["b", "d"])
        let all = Scheduler.select(candidates: candidates, runningByCompany: [:], config: config, usage: { _ in .open })
        #expect(all.count == 3)
        // Five-hour limits and holds still stop everyone.
        let closed = Scheduler.select(candidates: candidates, runningByCompany: [:], config: config,
                                      usage: { _ in .closed(until: now) }, paceClosed: ["c"])
        #expect(closed.isEmpty)
        #expect(Scheduler.select(candidates: candidates, runningByCompany: [:], config: config, usage: { _ in .open },
                                 held: true, paceClosed: ["c"]).isEmpty)
    }

    /// Runs `n` windows of 5 points each, costing `$cost`, on one track.
    private func windows(_ track: inout UsageCalibration.Track, n: Int, cost: (Int) -> Double, reset: Date, start: Double = 0.10) {
        var util = start
        track.observe(util: util, resetsAt: reset)
        for i in 0..<n {
            track.addCost(cost(i))
            util += 0.05
            track.observe(util: util, resetsAt: reset)
        }
    }

    @Test func calibrationFromDeltas() {
        // Needs 10 windows; the estimate is the 80th percentile, not an average.
        var cal = UsageCalibration()
        let reset = now.addingTimeInterval(week)
        windows(&cal.week, n: 9, cost: { _ in 2.5 }, reset: reset)          // ratio .02 per dollar
        #expect(cal.week.samples.count == 9); #expect(cal.pctPerDollar == nil, "fewer than 10 windows")
        // Tenth window is the expensive outlier: ratio .05/5 = .01 per dollar (cheap spend = small ratio).
        cal.addCost(5.0); cal.observe(util: 0.10 + 10 * 0.05, resetsAt: reset)
        #expect(cal.week.samples.count == 10)
        #expect(abs(try! #require(cal.pctPerDollar) - 0.02) < 1e-9)
        // Ratios: nine at .02, then add windows at .10/$ (cheap-per-point work): p80 moves up to the high end.
        for _ in 0..<5 {
            cal.addCost(0.5); cal.observe(util: (cal.week.baselineUtil ?? 0) + 0.05, resetsAt: reset)
        }
        #expect(cal.week.samples.count == 15)
        // sorted: 1 x .01, 9 x .02, 5 x .10 -> nearest rank 12 -> .10
        #expect(abs(try! #require(cal.pctPerDollar) - 0.10) < 1e-9)
        // A new week resets the baseline without producing a sample.
        let before = cal.week.samples.count
        cal.addCost(3.0)
        cal.observe(util: 0.02, resetsAt: reset.addingTimeInterval(week))
        #expect(cal.week.samples.count == before); #expect(cal.week.cost == 0)
    }

    @Test func fiveHourCalibration() {
        var cal = UsageCalibration()
        let reset = now.addingTimeInterval(5 * 3600)
        cal.observeFiveHour(util: 0.10, resetsAt: reset)
        for i in 0..<10 {
            cal.addCost(1.0)                                         // week track gets the cost too
            cal.observeFiveHour(util: 0.10 + 0.04 * Double(i + 1), resetsAt: reset)
        }
        #expect(cal.fiveHour.samples.count == 10)
        #expect(abs(try! #require(cal.pctPerDollar5h) - 0.04) < 1e-9)
        #expect(cal.pctPerDollar == nil, "the weekly track is separate")
        // A new five-hour window starts fresh.
        cal.addCost(2); cal.observeFiveHour(util: 0.05, resetsAt: reset.addingTimeInterval(5 * 3600))
        #expect(cal.fiveHour.samples.count == 10); #expect(cal.fiveHour.baselineUtil == 0.05)
    }

    @Test func calibrationIgnoresSubPointDeltas() {
        var t = UsageCalibration.Track()
        let reset = now.addingTimeInterval(week)
        t.observe(util: 0.10, resetsAt: reset)
        t.addCost(1.0); t.observe(util: 0.11, resetsAt: reset)      // 1 point: not a window yet
        #expect(t.samples.isEmpty)
        t.addCost(1.0); t.observe(util: 0.115, resetsAt: reset)
        #expect(t.samples.isEmpty); #expect(t.cost == 2.0, "the window keeps accumulating")
        t.addCost(0.5); t.observe(util: 0.12, resetsAt: reset)      // cumulative 2 points: one window of $2.5
        #expect(t.samples.count == 1)
        #expect(abs(t.samples[0] - 0.02 / 2.5) < 1e-12)
        // No spend behind a 2-point move: still not a sample.
        t.observe(util: 0.15, resetsAt: reset)
        #expect(t.samples.count == 1)
    }

    @Test func calibrationPersistsThroughTheStore() throws {
        let store = try Store.inMemory()
        let c = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        let reset = now.addingTimeInterval(week), reset5 = now.addingTimeInterval(5 * 3600)
        func snapshot(_ util: Double, five: Double) -> RateLimitInfo {
            RateLimitInfo(status: "allowed", resetsAt: nil, rateLimitType: nil, isUsingOverage: false, fiveHourUtilization: five,
                          sevenDayUtilization: util, observedAt: now, fiveHourResetsAt: reset5, sevenDayResetsAt: reset)
        }
        try store.saveRateLimit(snapshot(0.10, five: 0.10))
        for i in 1...10 {
            try store.recordSpend(1.0)
            try store.saveRateLimit(snapshot(0.10 + 0.02 * Double(i), five: 0.10 + 0.04 * Double(i)))
        }
        let cal = try store.usageCalibration()
        #expect(abs(try #require(cal.pctPerDollar) - 0.02) < 1e-9)
        #expect(abs(try #require(cal.pctPerDollar5h) - 0.04) < 1e-9)
        // Today's spend is summed over the owner's calendar day.
        try store.setOwnerTimeZone("UTC")
        let ceo = try store.hire(companyId: c.id, name: "ceo", role: "ceo", model: "sonnet")
        let noon = Date(timeIntervalSince1970: TimeInterval(Int(1_800_000_000) - Int(1_800_000_000) % 86_400 + 12 * 3600))
        let t = try store.startTurn(agentId: ceo.id, now: noon)
        _ = try store.finishTurn(id: t.id, outcome: .succeeded, summary: nil, costUSD: 1.25, now: noon)
        let old = try store.startTurn(agentId: ceo.id, now: noon.addingTimeInterval(-86_400))
        _ = try store.finishTurn(id: old.id, outcome: .succeeded, summary: nil, costUSD: 9, now: noon.addingTimeInterval(-86_400))
        #expect(store.costToday(now: noon.addingTimeInterval(3600)) == 1.25)
    }

    @Test func paceStateAndHeadroom() throws {
        // elapsed .5, reserve .3: line .35, allowed .455, reserve line .7
        func pace(_ util: Double, per: Double? = nil) throws -> Pace {
            try #require(UsageGate.pace(info(util: util), reserve: 0.3, now: now, pctPerDollar: per))
        }
        #expect(try pace(0.20).state == .onPace)
        #expect(try pace(0.32).state == .near)
        #expect(try pace(0.40).state == .ahead)
        #expect(try pace(0.46).state == .closed)
        #expect(try pace(0.40).headroomLE == nil, "uncalibrated")
        #expect(abs(try #require(pace(0.40, per: 0.02).headroomLE) - (0.455 - 0.40) / 0.02) < 1e-9)
        #expect(try pace(0.50, per: 0.02).headroomLE == 0, "closed: nothing left")
        #expect(try pace(0.60).criticalPathExempt); #expect(try !pace(0.70).criticalPathExempt)
    }

    @Test func criticalPathNeverEntersReserve() {
        let c = Company(id: "c", name: "c", slug: "c", goal: "g", workspacePath: "/tmp", status: .running, usageMode: .max,
                        priorityWeight: 1, createdAt: now)
        let blocker = Candidate(agent: Agent(id: "b", companyId: "c", name: "b", role: "engineer", model: "m", sessionId: "s",
                                             sessionStarted: false, state: .ready, blocker: nil, requestedBlocker: nil, paused: false,
                                             readySince: now, createdAt: now), company: c, blockingCount: 3)
        var config = SchedulerConfig(); config.planTier = .max20x; config.safetyCap = 100
        #expect(Scheduler.select(candidates: [blocker], runningByCompany: [:], config: config, usage: { _ in .open },
                                 paceClosed: ["c"]).count == 1)
        #expect(Scheduler.select(candidates: [blocker], runningByCompany: [:], config: config, usage: { _ in .open },
                                 paceClosed: ["c"], paceStrict: ["c"]).isEmpty, "past the reserve line even the critical path waits")
    }

    @Test func overageAllowedClampsAllModes() {
        func i(_ five: Double, overage: String?) -> RateLimitInfo {
            RateLimitInfo(status: "allowed", resetsAt: now.addingTimeInterval(3600), rateLimitType: "five_hour", isUsingOverage: false,
                          fiveHourUtilization: five, sevenDayUtilization: nil, observedAt: now,
                          fiveHourResetsAt: now.addingTimeInterval(3600), overageStatus: overage)
        }
        for mode in UsageMode.allCases {
            #expect(UsageGate.evaluate(i(0.86, overage: "allowed"), mode: mode, now: now) == .closed(until: now.addingTimeInterval(3600)), "\(mode)")
            #expect(UsageGate.evaluate(i(0.79, overage: "allowed"), mode: mode, now: now) == .open, "\(mode)")
        }
        #expect(UsageGate.evaluate(i(0.84, overage: "allowed"), mode: .max, now: now) == .open, "just under the clamp")
        #expect(UsageGate.evaluate(i(0.84, overage: "allowed"), mode: .balanced, now: now) == .open)
        #expect(UsageGate.evaluate(i(0.86, overage: nil), mode: .max, now: now) == .open, "no overage, the max threshold stands")
        #expect(UsageGate.evaluate(i(0.86, overage: "rejected"), mode: .max, now: now) == .open)
    }

    @Test func openReservationCountsInTheFiveHourCheck() {
        let i = RateLimitInfo(status: "allowed", resetsAt: now.addingTimeInterval(3600), rateLimitType: "five_hour", isUsingOverage: false,
                              fiveHourUtilization: 0.75, sevenDayUtilization: nil, observedAt: now,
                              fiveHourResetsAt: now.addingTimeInterval(3600))
        #expect(UsageGate.evaluateFiveHour(i, mode: .low, now: now) == .open)
        #expect(UsageGate.evaluateFiveHour(i, mode: .low, now: now, openReservationLE: 5, pctPerDollar5h: 0.01) == .closed(until: now.addingTimeInterval(3600)))
        #expect(UsageGate.evaluateFiveHour(i, mode: .low, now: now, openReservationLE: 5, pctPerDollar5h: nil) == .open, "uncalibrated")
        #expect(UsageGate.evaluateFiveHour(i, mode: .low, now: now, openReservationLE: 0, pctPerDollar5h: 0.01) == .open)
    }

    @Test func proTierRowExistsAsData() {
        let pro = PlanTier.pro
        #expect(pro.modeCap(.low) == 1); #expect(pro.modeCap(.balanced) == 1); #expect(pro.modeCap(.max) == 2)
        #expect(pro.hardCap == 2); #expect(pro.seatBudget == 4)
        #expect(pro.maxRung == 2); #expect(!pro.allowsTask); #expect(!pro.allowsUltra)
        #expect(PlanTier.max5x.maxRung == nil); #expect(PlanTier.max5x.allowsUltra)
        var c = SchedulerConfig(); c.planTier = .pro
        #expect(c.effectiveHardCap == 2)
    }

    @Test func planTierMismatchWarnsOnly() throws {
        // A CLI that reports "pro" while the owner configured max5x: a WARN line, nothing else.
        let item = try #require(Doctor.planTierItem(configured: .max5x, reported: "pro"))
        #expect(item.status == .warn); #expect(item.name == "plan-tier")
        #expect(item.detail.contains("configured max5x") && item.detail.contains("pro"))
        #expect(Doctor.planTierItem(configured: .max5x, reported: "max_5x") == nil)
        #expect(Doctor.planTierItem(configured: .max20x, reported: "max_20x") == nil)
        #expect(Doctor.planTierItem(configured: .max5x, reported: nil) == nil)
        #expect(Doctor.planTierItem(configured: .max5x, reported: "enterprise")?.status == .warn)
        // The report stays ok and the configured tier is untouched: no clamp.
        let report = DoctorReport(cliVersion: "2.1.304", items: [DoctorItem(name: "version", status: .pass, detail: "x"), item],
                                  checkedAt: now, reportedSubscription: "pro")
        #expect(report.ok)
        let store = try Store.inMemory()
        #expect(store.planTier() == .max5x)
        try store.saveProbe(report)
        #expect(store.planTier() == .max5x, "a stale reported plan never overrides the setting")
        #expect(try store.latestProbe()?.reportedSubscription == "pro")
    }

}

/// Orchestrator-level behavior of the weekly pace.
@Suite struct PacingOrchestratorTests {
    private struct W {
        let store: Store; let clock = TestClock(); let fake = FakeTurnRunner(); let router: MessageRouter
        let o: Orchestrator; let c: Company
        init(tier: PlanTier = .max20x) throws {
            store = try Store.inMemory(); router = MessageRouter(store: store)
            let root = try tempDir()
            try store.setPlanTier(tier)
            var co = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: root.appending(path: "ws"))
            co.usageMode = .max; try store.updateCompany(co); c = try onWorkspaceProfile(store, co)
            o = Orchestrator(store: store, runner: fake,
                             paths: BrahmaPaths(home: root.appending(path: "h"), workspaces: root.appending(path: "ws")),
                             mcpExecutable: "/x", clock: clock.function, memory: NormalMemoryPressure(),
                             connectivity: AlwaysOnline(), disk: PlentyOfDisk(), exec: { _, _ in nil })
        }
        func cycle() async throws { await o.tick(); try await o.waitUntilIdle(timeout: .seconds(60)) }
    }

    private func usage(_ w: W, util: Double, fiveHour: Double = 0.1) throws {
        let now = w.clock.now
        try w.store.saveRateLimit(RateLimitInfo(status: "allowed", resetsAt: nil, rateLimitType: nil, isUsingOverage: false,
                                                fiveHourUtilization: fiveHour, sevenDayUtilization: util, observedAt: now,
                                                fiveHourResetsAt: now.addingTimeInterval(3600),
                                                sevenDayResetsAt: now.addingTimeInterval(3.5 * 86_400)))
    }

    @Test func paceClosedHoldsIdleWorkButNotTheCriticalPath() async throws {
        let w = try W()
        let boss = try w.store.hire(companyId: w.c.id, name: "boss", role: "engineer", model: "sonnet")
        let idle = try w.store.hire(companyId: w.c.id, name: "idle", role: "engineer", model: "sonnet")
        let waiter = try w.store.hire(companyId: w.c.id, name: "waiter", role: "engineer", model: "sonnet")
        // `waiter` is blocked on `boss`, so `boss` is on the critical path.
        _ = try w.store.transition(agentId: waiter.id, to: .blocked, blocker: .agent(boss.id), now: w.clock.now)
        for a in [boss, idle] { _ = try w.router.sendDM(companyId: w.c.id, from: .owner, to: a.name, text: "go", now: w.clock.now) }
        try usage(w, util: 0.6)
        try await w.cycle()
        #expect(w.fake.requests.map(\.agent.name) == ["boss"])
        // Nothing is persisted for the pace: the idle agent is simply still ready.
        #expect(try w.store.agent(id: idle.id)?.state == .ready)
        #expect(try w.store.agent(id: idle.id)?.blocker == nil)
        #expect(try w.store.events(afterId: 0).contains { $0.text.hasPrefix("weekly pace closed (ahead by ") })
        // Logged once, not every tick.
        try await w.cycle(); try await w.cycle()
        #expect(try w.store.events(afterId: 0).filter { $0.text.hasPrefix("weekly pace closed") }.count == 1)
    }

    @Test func fiveHourLimitStillStopsTheCriticalPath() async throws {
        let w = try W()
        let boss = try w.store.hire(companyId: w.c.id, name: "boss", role: "engineer", model: "sonnet")
        let waiter = try w.store.hire(companyId: w.c.id, name: "waiter", role: "engineer", model: "sonnet")
        _ = try w.store.transition(agentId: waiter.id, to: .blocked, blocker: .agent(boss.id), now: w.clock.now)
        _ = try w.router.sendDM(companyId: w.c.id, from: .owner, to: "boss", text: "go", now: w.clock.now)
        try usage(w, util: 0.6, fiveHour: 0.99)
        try await w.cycle()
        #expect(w.fake.requests.isEmpty)
        // The persisted blocker ends with the five-hour window, not with the (days long) pace closure.
        guard case .usageLimit(let until)? = try w.store.agent(id: boss.id)?.blocker else { Issue.record("boss should be blocked"); return }
        #expect(until <= w.clock.now.addingTimeInterval(3600 + 1))
    }

    @Test func paceReopensWhenTheShareIsRaised() async throws {
        let w = try W()
        let a = try w.store.hire(companyId: w.c.id, name: "a", role: "engineer", model: "sonnet")
        _ = try w.router.sendDM(companyId: w.c.id, from: .owner, to: "a", text: "go", now: w.clock.now)
        // 60% used at the halfway point: closed at the default 70% share (allowed 45.5%).
        try usage(w, util: 0.6)
        try await w.cycle()
        #expect(w.fake.requests.isEmpty, "paced")
        try w.store.setWeeklyShare(1.0)                      // allowed becomes 65%
        try await w.cycle()
        #expect(w.fake.requests.count == 1, "the next tick sees the new share")
        _ = a
    }

    @Test func companyReserveOverrideReopensToo() async throws {
        let w = try W()
        _ = try w.store.hire(companyId: w.c.id, name: "a", role: "engineer", model: "sonnet")
        _ = try w.router.sendDM(companyId: w.c.id, from: .owner, to: "a", text: "go", now: w.clock.now)
        try usage(w, util: 0.6)
        try await w.cycle()
        #expect(w.fake.requests.isEmpty)
        try w.store.setOwnerReserve(companyId: w.c.id, 0.0)
        try await w.cycle()
        #expect(w.fake.requests.count == 1)
    }

    @Test func becomesCriticalPathWhileBlocked() async throws {
        let w = try W()
        let boss = try w.store.hire(companyId: w.c.id, name: "boss", role: "engineer", model: "sonnet")
        let waiter = try w.store.hire(companyId: w.c.id, name: "waiter", role: "engineer", model: "sonnet")
        _ = try w.router.sendDM(companyId: w.c.id, from: .owner, to: "boss", text: "go", now: w.clock.now)
        try usage(w, util: 0.6)
        try await w.cycle()
        #expect(w.fake.requests.isEmpty, "boss is idle work while the pace is closed")
        // Now someone starts waiting on boss: it is critical path and runs on the next tick.
        _ = try w.store.transition(agentId: waiter.id, to: .blocked, blocker: .agent(boss.id), now: w.clock.now)
        try await w.cycle()
        #expect(w.fake.requests.map(\.agent.name) == ["boss"])
    }

    @Test func planTierIsAppliedEveryTick() async throws {
        let w = try W(tier: .max5x)
        w.store.writerSetUsageMode(w.c, .low)
        let names = ["a", "b", "c"]
        for n in names {
            _ = try w.store.hire(companyId: w.c.id, name: n, role: "engineer", model: "sonnet")
            _ = try w.router.sendDM(companyId: w.c.id, from: .owner, to: n, text: "go", now: w.clock.now)
        }
        let first = Gate()
        w.fake.defaultScript = .init(gate: first)
        await w.o.tick()
        #expect(await w.o.runningCount() == 1, "max5x low mode allows one turn")
        first.open()
        try await w.o.waitUntilIdle(timeout: .seconds(60))
        try w.store.setPlanTier(.max20x)
        let second = Gate()
        w.fake.defaultScript = .init(gate: second)
        await w.o.tick()
        #expect(await w.o.runningCount() == 2, "max20x low mode allows two; the third waits")
        second.open()
        try await w.o.waitUntilIdle(timeout: .seconds(60))
    }
}

struct AlwaysOnline: ConnectivityProbe { func online() async -> Bool { true } }
struct PlentyOfDisk: DiskSpace { func freeBytes(at: URL) -> Int64? { 500_000_000_000 } }

extension Store {
    func writerSetUsageMode(_ c: Company, _ mode: UsageMode) {
        var copy = c; copy.usageMode = mode
        try? updateCompany(copy)
    }
}
