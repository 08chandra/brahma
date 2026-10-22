import Foundation
import Testing
import GRDB
@testable import BrahmaCore

private final class StubProbe: ConnectivityProbe, @unchecked Sendable {
    private let lock = NSLock(); private var _online = false; private var _calls = 0
    var online: Bool { get { lock.withLock { _online } } set { lock.withLock { _online = newValue } } }
    var calls: Int { lock.withLock { _calls } }
    func online() async -> Bool { lock.withLock { _calls += 1; return _online } }
}

private final class StubDisk: DiskSpace, @unchecked Sendable {
    private let lock = NSLock(); private var perPath: [String: Int64] = [:]; private var all: Int64? = 100 * gb
    func set(_ bytes: Int64?) { lock.withLock { all = bytes; perPath = [:] } }
    func set(_ bytes: Int64, suffix: String) { lock.withLock { perPath[suffix] = bytes } }
    func freeBytes(at url: URL) -> Int64? {
        lock.withLock { perPath.first { url.path.hasSuffix($0.key) }?.value ?? all }
    }
}

private final class StubExec: @unchecked Sendable {
    private let lock = NSLock(); private var _version = "2.1.304 (Claude Code)"
    var version: String { get { lock.withLock { _version } } set { lock.withLock { _version = newValue } } }
    var exec: Doctor.Exec {
        let help = Doctor.requiredFlags.map { "  \($0) <value>" }.joined(separator: "\n")
        return { [self] _, args in args == ["--version"] ? version : args == ["--help"] ? help : nil }
    }
}

private let gb: Int64 = 1_000_000_000
private let networkText = "API Error: Unable to connect: getaddrinfo ENOTFOUND api.anthropic.com"
private let loginText = "Invalid API key · Please run /login"

private func failure(_ r: TurnRequest, _ text: String, status: Int? = nil) -> [StreamEvent] {
    [.initialized(sessionId: r.agent.sessionId, model: r.agent.model),
     .result(TurnResult(isError: true, subtype: "error_during_execution", text: text, costUSD: nil,
                        apiErrorStatus: status, sessionId: r.agent.sessionId))]
}
private func failing(_ text: String, status: Int? = nil, delay: Duration? = nil) -> FakeTurnRunner.Script {
    // Events depend on the request, but a script is built before it exists; the session id only has to be non-empty.
    .init(events: [.initialized(sessionId: "s", model: "m"),
                   .result(TurnResult(isError: true, subtype: "error_during_execution", text: text, costUSD: nil,
                                      apiErrorStatus: status, sessionId: "s"))], delay: delay)
}

private struct HWorld {
    let store: Store
    let router: MessageRouter
    let clock = TestClock()
    let fake = FakeTurnRunner()
    let probe = StubProbe()
    let disk = StubDisk()
    let exec = StubExec()
    let paths: BrahmaPaths
    let orchestrator: Orchestrator
    let company: Company

    init() throws {
        store = try Store.inMemory()
        router = MessageRouter(store: store)
        let root = try tempDir()
        paths = BrahmaPaths(home: root.appending(path: "home"), workspaces: root.appending(path: "ws"))
        try store.setPlanTier(.max20x)
        var c = try store.createCompany(name: "Acme", goal: "Ship it", workspacesRoot: paths.workspaces)
        c.usageMode = .max
        try store.updateCompany(c)
        company = c
        try store.saveProbe(DoctorReport(cliVersion: "2.1.304", items: [DoctorItem(name: "version", status: .pass, detail: "2.1.304")],
                                         checkedAt: clock.now))
        orchestrator = Orchestrator(store: store, runner: fake, paths: paths, mcpExecutable: "/usr/local/bin/brahma",
                                    clock: clock.function, connectivity: probe, disk: disk, exec: exec.exec)
    }

    func hire(_ name: String) throws -> Agent { try store.hire(companyId: company.id, name: name, role: "engineer", model: "sonnet") }
    func agent(_ a: Agent) throws -> Agent { try #require(try store.agent(id: a.id)) }
    func dm(_ a: Agent) throws { _ = try router.sendDM(companyId: company.id, from: .owner, to: a.name, text: "do it", now: clock.now) }
    func turns(_ a: Agent) throws -> [Turn] {
        try store.writer.read { db in try Turn.filter(Column("agentId") == a.id).order(Column("startedAt"), Column.rowID).fetchAll(db) }
    }
    func cycle() async throws {
        await orchestrator.tick()
        try await orchestrator.waitUntilIdle(timeout: .seconds(10))
    }
    func alerts() throws -> [Message] {
        guard let ch = try store.channel(companyId: company.id, name: "dm:owner:system") else { return [] }
        return try store.messages(channelId: ch.id, limit: 50)
    }
    func events(_ kind: ActivityKind) throws -> [String] {
        try store.events(afterId: 0).filter { $0.kind == kind }.map(\.text)
    }
    func hold() throws -> EngineHold? { try store.engineHold() }
}

@Suite struct HealthTests {
    @Test func classifyTable() {
        let net = ["getaddrinfo ENOTFOUND x", "connect ECONNREFUSED 1.2.3.4", "read ECONNRESET", "ETIMEDOUT", "Network is unreachable",
                   "TypeError: fetch failed", "socket hang up"]
        for t in net { #expect(EngineHealth.classify(text: t, apiErrorStatus: nil) == .network, "\(t)") }
        for s in [500, 502, 503, 529, 599] { #expect(EngineHealth.classify(text: "", apiErrorStatus: s) == .network) }
        let acct = ["Not logged in", "please run /login", "Invalid API key", "authentication_error", "Your subscription has expired",
                    "Credit balance is too low"]
        for t in acct { #expect(EngineHealth.classify(text: t, apiErrorStatus: nil) == .account, "\(t)") }
        #expect(EngineHealth.classify(text: "", apiErrorStatus: 401) == .account)
        #expect(EngineHealth.classify(text: "", apiErrorStatus: 403) == .account)
        #expect(EngineHealth.classify(text: "I could not find the file", apiErrorStatus: nil) == .none)
        #expect(EngineHealth.classify(text: "", apiErrorStatus: 400) == .none)
        #expect(EngineHealth.classify(text: "", apiErrorStatus: 429) == .none)
        #expect(EngineHealth.classify(text: "ENOTFOUND", apiErrorStatus: nil) == .network, "case-insensitive")
    }

    @Test func networkFailuresHoldAndRecover() async throws {
        let w = try HWorld()
        let agents = try ["a", "b", "c"].map { try w.hire($0) }
        for a in agents { w.fake.script(a.name, failing(networkText)); try w.dm(a) }
        try await w.cycle()                                       // three failures, concurrently
        #expect(try w.hold() == nil)                              // the rule is evaluated in the next tick
        try await w.cycle()
        let hold = try #require(try w.hold())
        #expect(hold.reason == .network)
        #expect(w.fake.requests.count == 3, "no turn was launched while held")
        for _ in 0..<3 { w.clock.advance(20); try await w.cycle() }
        #expect(w.fake.requests.count == 3)
        #expect(try w.events(.error).contains { $0.hasPrefix("engine paused: network — ") })
        // Offline probes keep the hold.
        w.clock.advance(60); try await w.cycle(); try await w.cycle()
        #expect(try w.hold()?.reason == .network)
        #expect(w.probe.calls >= 1)
        // Online: cleared and agents run again.
        w.probe.online = true
        w.clock.advance(60); try await w.cycle(); try await w.cycle()
        #expect(try w.hold() == nil)
        try await w.orchestrator.waitUntilIdle(timeout: .seconds(10))
        #expect(w.fake.requests.count == 6)
        #expect(try w.events(.usage).contains("engine resumed"))
        for a in agents { #expect(try w.turns(a).map(\.outcome) == [.failed, .succeeded]) }
    }

    @Test func infraFailuresNotCountedAgainstAgent() async throws {
        let w = try HWorld(); let a = try w.hire("ceo")
        w.fake.script("ceo", failing(networkText)); try w.dm(a)
        try await w.cycle()
        let after = try w.agent(a)
        #expect(after.consecutiveFailures == 0)
        #expect(after.state == .ready)
        #expect(after.blocker == nil, "no retry backoff")
        #expect(after.consecutiveInfraFailures == 1)
        let turn = try #require(try w.turns(a).first)
        #expect(turn.outcome == .failed); #expect(turn.infra)
        #expect(try w.store.pendingInbox(agentId: a.id).count == 1, "the inbox stays undelivered")
        #expect(try w.store.turnCount(agentId: a.id, since: w.clock.now.addingTimeInterval(-3600)) == 0, "no turn budget used")
        // Eligible again after a fixed 15 s, not before.
        w.clock.advance(10); try await w.cycle()
        #expect(w.fake.requests.count == 1)
        w.clock.advance(6); try await w.cycle()
        #expect(w.fake.requests.count == 2)
        let ok = try w.agent(a)
        #expect(ok.consecutiveInfraFailures == 0, "any non-infra outcome resets the counter")
        #expect(try w.store.pendingInbox(agentId: a.id).isEmpty)
    }

    @Test func fifthConsecutiveInfraFailureIsOrdinary() throws {
        let store = try Store.inMemory()
        let c = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        let a = try store.hire(companyId: c.id, name: "ceo", role: "ceo", model: "sonnet")
        var t = Date(timeIntervalSince1970: 1_800_000_000)
        func fail() throws -> (InfraClass, Turn) {
            if try #require(try store.agent(id: a.id)).state != .ready { try store.transition(agentId: a.id, to: .ready, now: t) }
            let (_, turn) = try #require(try store.beginTurn(agentId: a.id, now: t))
            t.addTimeInterval(1)
            let cls = try store.endTurn(agentId: a.id, turn: turn,
                                        end: .failed("boom", InfraInput(text: networkText, status: nil)),
                                        deliveredItemIds: [], now: t)
            return (cls, try #require(try store.writer.read { try Turn.fetchOne($0, key: turn.id) }))
        }
        for i in 1...4 {
            let (cls, turn) = try fail()
            #expect(cls == .network); #expect(turn.infra, "failure \(i)")
        }
        #expect(try #require(try store.agent(id: a.id)).consecutiveInfraFailures == 4)
        let (cls, turn) = try fail()
        #expect(cls == .none); #expect(!turn.infra)
        let agent = try #require(try store.agent(id: a.id))
        #expect(agent.consecutiveInfraFailures == 0); #expect(agent.consecutiveFailures == 1)
        guard case .retry(_, let failures)? = agent.blocker else { Issue.record("expected normal backoff"); return }
        #expect(failures == 1)
    }

    @Test func classificationIgnoresStderrAndAssistantText() async throws {
        let w = try HWorld(); let a = try w.hire("ceo")
        // The runner exits without a result and its stderr mentions the network: that is not a classified error.
        w.fake.script("ceo", .init(events: [], error: TurnError.exitedWithoutResult(code: 1, stderrTail: "getaddrinfo ENOTFOUND")))
        try w.dm(a); try await w.cycle()
        var turn = try #require(try w.turns(a).first)
        #expect(turn.outcome == .failed); #expect(!turn.infra)
        #expect(try w.agent(a).consecutiveFailures == 1)
        // A successful result whose text talks about ENOTFOUND is a success.
        let b = try w.hire("cto")
        w.fake.script("cto", .init(events: [.initialized(sessionId: "s", model: "m"),
            .result(TurnResult(isError: false, subtype: "success", text: "fixed the ENOTFOUND bug", costUSD: 0.01, apiErrorStatus: nil, sessionId: "s"))]))
        try w.dm(b); try await w.cycle()
        turn = try #require(try w.turns(b).first)
        #expect(turn.outcome == .succeeded); #expect(!turn.infra)
        // A launch error that reads as a network problem is infrastructure.
        let c = try w.hire("cpo")
        w.fake.script("cpo", .init(events: [], error: FakeError(description: "fetch failed")))
        try w.dm(c); try await w.cycle()
        turn = try #require(try w.turns(c).first)
        #expect(turn.infra)
    }

    @Test func budgetCappedTurnsAreNeverInfra() async throws {
        // Classification part of budgetCappedTurnsCountTowardItemBudget (the accounting half is in BudgetTests).
        #expect(EngineHealth.classify(InfraInput(text: "fetch failed", status: nil, subtype: "error_max_budget_usd")) == .none)
        #expect(EngineHealth.classify(InfraInput(text: "getaddrinfo ENOTFOUND", status: 503, subtype: "error_max_turns")) == .none)
        #expect(EngineHealth.classify(InfraInput(text: "fetch failed", status: nil, subtype: "error_during_execution")) == .network)
        let w = try HWorld(); let a = try w.hire("ceo")
        w.fake.script("ceo", .init(events: [.initialized(sessionId: "s", model: "m"),
            .result(TurnResult(isError: true, subtype: "error_max_budget_usd", text: "Reached the budget; last call: fetch failed",
                               costUSD: 1.5, apiErrorStatus: nil, sessionId: "s"))]))
        try w.dm(a); try await w.cycle()
        let turn = try #require(try w.turns(a).first)
        #expect(turn.outcome == .failed); #expect(!turn.infra); #expect(turn.stopReason == "budgetCap")
        // Task 14a: a controlled stop is the engine's own cap, so it is never counted against the agent: no backoff.
        #expect(try w.agent(a).consecutiveFailures == 0)
        #expect(try w.agent(a).blocker == nil)
        try await w.cycle()
        #expect(try w.hold() == nil)
    }

    @Test func accountFailureHoldsAndAlertsOnce() async throws {
        let w = try HWorld()
        let agents = try ["a", "b", "c"].map { try w.hire($0) }
        for a in agents.prefix(2) { w.fake.script(a.name, failing(loginText)); try w.dm(a) }
        try await w.cycle()
        try await w.cycle()
        let hold = try #require(try w.hold())
        #expect(hold.reason == .account)
        let alerts = try w.alerts()
        #expect(alerts.count == 1)
        #expect(alerts[0].senderId == "system")
        #expect(alerts[0].text == "Claude Code is logged out or the plan changed. Log in with `claude`, then run `brahma doctor` (or press Retry in the app).")
        // Stays held; no repeat alert.
        try w.dm(agents[2])
        for _ in 0..<3 { w.clock.advance(700); try await w.cycle() }
        #expect(try w.hold()?.reason == .account)
        #expect(try w.alerts().count == 1)
        #expect(w.fake.requests.count == 2)
        // A probe that finds the network fine does not clear an account hold.
        w.probe.online = true
        w.clock.advance(120); try await w.cycle(); try await w.cycle()
        #expect(try w.hold()?.reason == .account)
        // A passing doctor does.
        try w.store.clearHoldAfterDoctor(now: w.clock.now)
        #expect(try w.hold() == nil)
        try await w.cycle()
        #expect(w.fake.requests.count >= 3)
    }

    @Test func accountStreakNeedsConsecutiveFailures() async throws {
        let w = try HWorld(); let a = try w.hire("ceo")
        w.fake.script("ceo", failing(loginText), .init(), failing(loginText))
        for _ in 0..<3 { try w.dm(a); try await w.cycle(); w.clock.advance(20) }
        try await w.cycle()
        #expect(try w.hold() == nil, "a success in between resets the streak")
        #expect(w.fake.requests.count == 4, "the third failure left the agent eligible again, not held")
    }

    @Test func cliChangeReprobes() async throws {
        let w = try HWorld()
        w.fake.script("probe",
                      .init(events: [.initialized(sessionId: "s", model: "haiku"),
                                     .rateLimit(RateLimitInfo(status: "allowed", resetsAt: nil, rateLimitType: "five_hour", isUsingOverage: false,
                                                              fiveHourUtilization: 0.1, sevenDayUtilization: 0.1, observedAt: w.clock.now)),
                                     .result(TurnResult(isError: false, subtype: "success", text: "OK", costUSD: 0.001, apiErrorStatus: nil, sessionId: "s", hasUsage: true))]),
                      .init(events: [.initialized(sessionId: "s", model: "haiku"),
                                     .result(TurnResult(isError: false, subtype: "success", text: "BRAHMA-PROBE-7", costUSD: 0.001, apiErrorStatus: nil, sessionId: "s", hasUsage: true))]))
        try await w.cycle()                                       // first tick only starts the clock
        // Same version after 600 s: nothing happens.
        w.clock.advance(600); try await w.cycle(); try await w.cycle()
        #expect(try w.hold() == nil)
        #expect(w.fake.requests.isEmpty)
        // The CLI auto-updates.
        w.exec.version = "2.1.306 (Claude Code)"
        w.clock.advance(600); try await w.cycle()                 // version check runs
        try await w.cycle()                                       // sees the change: hold cli, re-probe runs
        #expect(try w.hold()?.reason == .cli)
        #expect(try w.events(.error).contains { $0.hasPrefix("engine paused: cli — ") })
        try await w.cycle()                                       // consumes the passing report
        #expect(try w.hold() == nil)
        #expect(try w.store.latestProbe()?.cliVersion == "2.1.306")
        #expect(try w.store.latestProbe()?.ok == true)
        #expect(w.fake.requests.count == 2, "exactly one doctor probe (two turns)")
        #expect(try w.alerts().isEmpty)
    }

    @Test func cliChangeWithFailingProbeKeepsHoldAndAlerts() async throws {
        let w = try HWorld()
        w.fake.script("probe", failing("something is badly wrong"))
        try await w.cycle()
        w.exec.version = "2.2.0 (Claude Code)"
        w.clock.advance(600); try await w.cycle(); try await w.cycle(); try await w.cycle()
        #expect(try w.hold()?.reason == .cli)
        let alerts = try w.alerts()
        #expect(alerts.count == 1)
        #expect(alerts[0].text.contains("probe turn returned an error"))
        // It does not re-probe every interval: the failing report is the new baseline until doctor passes.
        w.clock.advance(600); try await w.cycle(); try await w.cycle(); try await w.cycle()
        #expect(w.fake.requests.count == 1)
        #expect(try w.alerts().count == 1)
        #expect(try w.hold()?.reason == .cli)
    }

    @Test func lowDiskHolds() async throws {
        let w = try HWorld(); let a = try w.hire("ceo")
        w.disk.set(4 * gb)
        try await w.cycle(); try await w.cycle()
        let hold = try #require(try w.hold())
        #expect(hold.reason == .disk)
        #expect(try w.alerts().map(\.text) == ["Disk space is low (4.0 GB free). Free space; Brahma resumes at 6 GB."])
        try w.dm(a); try await w.cycle()
        #expect(w.fake.requests.isEmpty)
        // 5.5 GB: still held (hysteresis).
        w.disk.set(Int64(5.5 * Double(gb)))
        w.clock.advance(60); try await w.cycle(); try await w.cycle()
        #expect(try w.hold()?.reason == .disk)
        // 6 GB: cleared and the agent runs.
        w.disk.set(6 * gb)
        w.clock.advance(60); try await w.cycle(); try await w.cycle()
        #expect(try w.hold() == nil)
        try await w.cycle()
        #expect(w.fake.requests.count == 1)
        #expect(try w.alerts().count == 1)
    }

    @Test func lowDiskUsesTheSmallestOfHomeAndWorkspaces() async throws {
        let w = try HWorld()
        w.disk.set(50 * gb); w.disk.set(3 * gb, suffix: "ws")
        try await w.cycle(); try await w.cycle()
        #expect(try w.hold()?.reason == .disk)
    }

    @Test func activeClockFrozenDuringHold() async throws {
        let w = try HWorld(); let id = w.company.id
        try await w.cycle()
        w.clock.advance(30); try await w.cycle()
        #expect(w.store.activeNow(companyId: id) == 30)
        try w.store.setHold(reason: .disk, detail: "test", now: w.clock.now)
        w.disk.set(1 * gb)
        for _ in 0..<3 { w.clock.advance(30); try await w.cycle() }
        #expect(w.store.activeNow(companyId: id) == 30, "frozen while held")
        w.disk.set(50 * gb)
        w.clock.advance(60); try await w.cycle(); try await w.cycle()
        #expect(try w.hold() == nil)
        let frozenAt = w.store.activeNow(companyId: id)
        w.clock.advance(30); try await w.cycle()
        #expect(w.store.activeNow(companyId: id) == frozenAt + 30)
    }

    @Test func holdPrecedence() async throws {
        // Store level: account > cli > disk > network, one hold at a time.
        let store = try Store.inMemory()
        _ = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        #expect(try store.setHold(reason: .network, detail: "n", now: t))
        #expect(try store.setHold(reason: .disk, detail: "d", now: t))
        #expect(try store.setHold(reason: .cli, detail: "c", now: t))
        #expect(try store.setHold(reason: .account, detail: "a", now: t))
        #expect(try !store.setHold(reason: .cli, detail: "c2", now: t))
        #expect(try !store.setHold(reason: .network, detail: "n2", now: t))
        #expect(try !store.setHold(reason: .account, detail: "a2", now: t), "same reason is not a change")
        #expect(try store.engineHold()?.reason == .account)
        #expect(try store.engineHold()?.detail == "a")
        try store.clearHold(now: t, onlyIf: .disk)
        #expect(try store.engineHold()?.reason == .account)
        try store.clearHold(now: t)
        #expect(try store.engineHold() == nil)

        // Orchestrator level: a network hold, then two in-flight account failures.
        let w = try HWorld()
        let net = try ["n1", "n2", "n3"].map { try w.hire($0) }
        let acct = try ["x1", "x2"].map { try w.hire($0) }
        for a in net { w.fake.script(a.name, failing(networkText)); try w.dm(a) }
        for a in acct { w.fake.script(a.name, failing(loginText, delay: .milliseconds(1500))); try w.dm(a) }
        await w.orchestrator.tick()
        let deadline = ContinuousClock.now + .seconds(5)
        while try net.contains(where: { try w.turns($0).first?.outcome != .failed }), ContinuousClock.now < deadline {
            try await Task.sleep(for: .milliseconds(10))
        }
        await w.orchestrator.tick()
        #expect(try w.hold()?.reason == .network)
        try await w.orchestrator.waitUntilIdle(timeout: .seconds(10))
        await w.orchestrator.tick()
        #expect(try w.hold()?.reason == .account)
        #expect(try w.alerts().count == 1)
    }

    @Test func doctorCommandPathClearsNonDiskHolds() throws {
        let store = try Store.inMemory()
        _ = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        let t = Date(timeIntervalSince1970: 1_800_000_000)
        try store.setHold(reason: .disk, detail: "d", now: t)
        try store.clearHoldAfterDoctor(now: t)
        #expect(try store.engineHold()?.reason == .disk, "a passing doctor says nothing about free space")
        try store.setHold(reason: .account, detail: "a", now: t)
        try store.clearHoldAfterDoctor(now: t)
        #expect(try store.engineHold() == nil)
    }

    @Test func holdBlocksSchedulerEvenWithPaceExemption() async throws {
        let w = try HWorld(); let a = try w.hire("ceo")
        try w.store.setHold(reason: .account, detail: "x", now: w.clock.now)
        try w.dm(a); try await w.cycle()
        #expect(w.fake.requests.isEmpty)
    }
}
