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

    @Test func calibrationFromDeltas() {
        var cal = UsageCalibration()
        #expect(cal.pctPerDollar == nil)
        let reset = now.addingTimeInterval(week)
        cal.observe(util: 0.10, resetsAt: reset)
        cal.addCost(2.0)
        cal.observe(util: 0.14, resetsAt: reset)
        #expect(abs(try! #require(cal.pctPerDollar) - 0.02) < 1e-12)
        // A smaller delta than the quantum keeps accumulating.
        cal.addCost(0.5)
        cal.observe(util: 0.145, resetsAt: reset)
        #expect(abs(try! #require(cal.pctPerDollar) - 0.02) < 1e-12)
        cal.addCost(0.5)
        cal.observe(util: 0.16, resetsAt: reset)     // delta .02 over $1 -> sample .02
        #expect(abs(try! #require(cal.pctPerDollar) - 0.02) < 1e-12)
        // EMA: a sample of .05/$ moves the estimate 30% of the way.
        cal.addCost(1.0)
        cal.observe(util: 0.21, resetsAt: reset)
        #expect(abs(try! #require(cal.pctPerDollar) - (0.3 * 0.05 + 0.7 * 0.02)) < 1e-12)
        // A new week resets the baseline without producing a sample.
        let before = cal.pctPerDollar
        cal.addCost(3.0)
        cal.observe(util: 0.02, resetsAt: reset.addingTimeInterval(week))
        #expect(cal.pctPerDollar == before)
        #expect(cal.cost == 0)
    }

    @Test func calibrationPersistsThroughTheStore() throws {
        let store = try Store.inMemory()
        let c = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        let reset = now.addingTimeInterval(week)
        func snapshot(_ util: Double) -> RateLimitInfo {
            RateLimitInfo(status: "allowed", resetsAt: nil, rateLimitType: nil, isUsingOverage: false, fiveHourUtilization: 0.1,
                          sevenDayUtilization: util, observedAt: now, sevenDayResetsAt: reset)
        }
        try store.saveRateLimit(snapshot(0.10))
        try store.recordSpend(0.5)
        try store.recordSpend(0.5)
        try store.saveRateLimit(snapshot(0.12))
        #expect(abs(try #require(store.usageCalibration().pctPerDollar) - 0.02) < 1e-12)
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
            co.usageMode = .max; try store.updateCompany(co); c = co
            o = Orchestrator(store: store, runner: fake,
                             paths: BrahmaPaths(home: root.appending(path: "h"), workspaces: root.appending(path: "ws")),
                             mcpExecutable: "/x", clock: clock.function, memory: NormalMemoryPressure(),
                             connectivity: AlwaysOnline(), disk: PlentyOfDisk(), exec: { _, _ in nil })
        }
        func cycle() async throws { await o.tick(); try await o.waitUntilIdle(timeout: .seconds(5)) }
    }

    @Test func paceClosedBlocksIdleWorkButNotTheCriticalPath() async throws {
        let w = try W()
        let boss = try w.store.hire(companyId: w.c.id, name: "boss", role: "engineer", model: "sonnet")
        let idle = try w.store.hire(companyId: w.c.id, name: "idle", role: "engineer", model: "sonnet")
        let waiter = try w.store.hire(companyId: w.c.id, name: "waiter", role: "engineer", model: "sonnet")
        // `waiter` is blocked on `boss`, so `boss` is on the critical path.
        _ = try w.store.transition(agentId: waiter.id, to: .blocked, blocker: .agent(boss.id), now: w.clock.now)
        for a in [boss, idle] { _ = try w.router.sendDM(companyId: w.c.id, from: .owner, to: a.name, text: "go", now: w.clock.now) }
        let now = w.clock.now
        try w.store.saveRateLimit(RateLimitInfo(status: "allowed", resetsAt: nil, rateLimitType: nil, isUsingOverage: false,
                                                fiveHourUtilization: 0.1, sevenDayUtilization: 0.6, observedAt: now,
                                                sevenDayResetsAt: now.addingTimeInterval(3.5 * 86_400)))
        try await w.cycle()
        #expect(w.fake.requests.map(\.agent.name) == ["boss"])
        guard case .usageLimit? = try w.store.agent(id: idle.id)?.blocker else { Issue.record("idle should wait for the pace"); return }
        #expect(try w.store.events(afterId: 0).contains { $0.text.hasPrefix("weekly pace closed (ahead by ") })
    }

    @Test func fiveHourLimitStillStopsTheCriticalPath() async throws {
        let w = try W()
        let boss = try w.store.hire(companyId: w.c.id, name: "boss", role: "engineer", model: "sonnet")
        let waiter = try w.store.hire(companyId: w.c.id, name: "waiter", role: "engineer", model: "sonnet")
        _ = try w.store.transition(agentId: waiter.id, to: .blocked, blocker: .agent(boss.id), now: w.clock.now)
        _ = try w.router.sendDM(companyId: w.c.id, from: .owner, to: "boss", text: "go", now: w.clock.now)
        let now = w.clock.now
        try w.store.saveRateLimit(RateLimitInfo(status: "allowed", resetsAt: now.addingTimeInterval(3600), rateLimitType: "five_hour",
                                                isUsingOverage: false, fiveHourUtilization: 0.99, sevenDayUtilization: 0.6,
                                                observedAt: now, fiveHourResetsAt: now.addingTimeInterval(3600),
                                                sevenDayResetsAt: now.addingTimeInterval(3.5 * 86_400)))
        try await w.cycle()
        #expect(w.fake.requests.isEmpty)
    }

    @Test func paceReopensWhenTheShareIsRaised() async throws {
        let w = try W()
        let a = try w.store.hire(companyId: w.c.id, name: "a", role: "engineer", model: "sonnet")
        _ = try w.router.sendDM(companyId: w.c.id, from: .owner, to: "a", text: "go", now: w.clock.now)
        let now = w.clock.now
        // 60% used at the halfway point: closed at the default 70% share (allowed 45.5%), open at 100% share.
        try w.store.saveRateLimit(RateLimitInfo(status: "allowed", resetsAt: nil, rateLimitType: nil, isUsingOverage: false,
                                                fiveHourUtilization: 0.1, sevenDayUtilization: 0.6, observedAt: now,
                                                sevenDayResetsAt: now.addingTimeInterval(3.5 * 86_400)))
        try w.store.setWeeklyShare(1.0)
        try await w.cycle()
        #expect(w.fake.requests.count == 1)
        _ = a
    }

    @Test func planTierIsAppliedEveryTick() async throws {
        let w = try W(tier: .max5x)
        w.store.writerSetUsageMode(w.c, .low)
        let names = ["a", "b", "c"]
        for n in names {
            _ = try w.store.hire(companyId: w.c.id, name: n, role: "engineer", model: "sonnet")
            _ = try w.router.sendDM(companyId: w.c.id, from: .owner, to: n, text: "go", now: w.clock.now)
        }
        w.fake.defaultScript = .init(delay: .milliseconds(100))
        await w.o.tick()
        #expect(await w.o.runningCount() == 1, "max5x low mode allows one turn")
        try await w.o.waitUntilIdle(timeout: .seconds(5))
        try w.store.setPlanTier(.max20x)
        await w.o.tick()
        #expect(await w.o.runningCount() == 2, "max20x low mode allows two; the third waits")
        try await w.o.waitUntilIdle(timeout: .seconds(5))
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
