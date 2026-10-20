import Testing
import Foundation
@testable import AgentCompanyCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func info(status: String = "allowed", resetsAt: Date? = now.addingTimeInterval(3600), overage: Bool = false,
                  util: Double? = 0.1) -> RateLimitInfo {
    RateLimitInfo(status: status, resetsAt: resetsAt, rateLimitType: "five_hour", isUsingOverage: overage,
                  fiveHourUtilization: util, sevenDayUtilization: 0.2, observedAt: now)
}

private func company(_ name: String, mode: UsageMode = .max, weight: Int = 1, status: CompanyStatus = .running) -> Company {
    Company(id: name, name: name, slug: name, goal: "g", workspacePath: "/tmp/\(name)", status: status,
            usageMode: mode, priorityWeight: weight, createdAt: now)
}

private func cand(_ c: Company, _ name: String, role: String = "engineer", blocking: Int = 0, ready: TimeInterval = 0) -> Candidate {
    Candidate(agent: Agent(id: "\(c.id)-\(name)", companyId: c.id, name: name, role: role, model: "m", sessionId: "s",
                           sessionStarted: false, state: .ready, blocker: nil, requestedBlocker: nil, paused: false,
                           readySince: now.addingTimeInterval(ready), createdAt: now),
              company: c, blockingCount: blocking)
}

private func many(_ c: Company, _ n: Int) -> [Candidate] { (0..<n).map { cand(c, "a\($0)", ready: Double($0)) } }

private func config(hard: Int = 16, safety: Int = 100) -> SchedulerConfig {
    var c = SchedulerConfig(); c.hardCap = hard; c.safetyCap = safety; return c
}

private let open: @Sendable (Company) -> UsageDecision = { _ in .open }

@Test func thresholdsPerMode() {
    #expect(UsageGate.threshold(.low) == 0.80); #expect(UsageGate.threshold(.balanced) == 0.90)
    #expect(UsageGate.threshold(.max) == 0.97)
}

@Test func gateClosesOnRejectedOverageOrHighUtilization() {
    let reset = now.addingTimeInterval(3600)
    #expect(UsageGate.evaluate(info(status: "rejected"), mode: .max, now: now) == .closed(until: reset))
    #expect(UsageGate.evaluate(info(overage: true), mode: .max, now: now) == .closed(until: reset))
    #expect(UsageGate.evaluate(info(util: 0.85), mode: .low, now: now) == .closed(until: reset))
    #expect(UsageGate.evaluate(info(util: 0.85), mode: .max, now: now) == .open)
    #expect(UsageGate.evaluate(info(util: 0.80), mode: .low, now: now) == .closed(until: reset))
    #expect(UsageGate.evaluate(info(status: "rejected", resetsAt: now.addingTimeInterval(-1)), mode: .max, now: now) == .open)
    #expect(UsageGate.evaluate(info(resetsAt: now.addingTimeInterval(-1), overage: true), mode: .max, now: now) == .open)
    #expect(UsageGate.evaluate(info(resetsAt: now.addingTimeInterval(-1), util: 0.99), mode: .low, now: now) == .open)
    #expect(UsageGate.evaluate(nil, mode: .low, now: now) == .open)
    #expect(UsageGate.evaluate(info(status: "rejected", resetsAt: nil), mode: .max, now: now)
            == .closed(until: now.addingTimeInterval(900)))
    #expect(UsageGate.evaluate(info(resetsAt: nil, util: nil), mode: .low, now: now) == .open)
}

@Test func rateLimitPersistsAsSingleRow() throws {
    let s = try Store.inMemory()
    #expect(try s.latestRateLimit() == nil)
    let t = Store.now()
    let a = RateLimitInfo(status: "allowed", resetsAt: t.addingTimeInterval(60), rateLimitType: "five_hour",
                          isUsingOverage: false, fiveHourUtilization: 0.5, sevenDayUtilization: nil, observedAt: t)
    try s.saveRateLimit(a)
    #expect(try s.latestRateLimit() == a)
    var b = a; b.status = "rejected"; b.resetsAt = nil; b.isUsingOverage = true
    try s.saveRateLimit(b)
    #expect(try s.latestRateLimit() == b)
    #expect(try s.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM usageState") } == 1)
}

@Test func safetyCapFor24GiB() {
    #expect(SafetyCap.compute(physicalMemoryBytes: 25_769_803_776) == 42)
    #expect(SafetyCap.compute(physicalMemoryBytes: 1) == 1)
    #expect(SafetyCap.current >= 1)
}

@Test func roleWeights() {
    #expect(["ceo", "cto", "cpo"].allSatisfy { roleWeight($0) == 3 })
    #expect(roleWeight("architect") == 2); #expect(roleWeight("manager") == 1); #expect(roleWeight("engineer") == 0)
}

@Test func modeCaps() {
    let c = config(hard: 9)
    #expect(c.modeCap(.low) == 2); #expect(c.modeCap(.balanced) == 6); #expect(c.modeCap(.max) == 9)
}

@Test func respectsModeCaps() {
    let a = company("a", mode: .low)
    #expect(Scheduler.select(candidates: many(a, 5), runningByCompany: [:], config: config(), usage: open).count == 2)
}

@Test func respectsGlobalCapAcrossCompanies() {
    let a = company("a"), b = company("b")
    let r = Scheduler.select(candidates: many(a, 10) + many(b, 10), runningByCompany: [:], config: config(hard: 4), usage: open)
    #expect(r.count == 4)
    #expect(r.filter { $0.companyId == "a" }.count == 2)
}

@Test func safetyCapAlsoLimits() {
    let a = company("a")
    #expect(Scheduler.select(candidates: many(a, 10), runningByCompany: [:], config: config(hard: 8, safety: 3), usage: open).count == 3)
    #expect(Scheduler.select(candidates: many(a, 10), runningByCompany: ["a": 3], config: config(hard: 8, safety: 3), usage: open).isEmpty)
}

@Test func weightedRoundRobin() {
    let a = company("a", weight: 2), b = company("b", weight: 1)
    let r = Scheduler.select(candidates: many(a, 20) + many(b, 20), runningByCompany: [:], config: config(hard: 6), usage: open)
    #expect(r.filter { $0.companyId == "a" }.count == 4)
    #expect(r.filter { $0.companyId == "b" }.count == 2)
}

@Test func pausedCompanyAndClosedGateGetNothing() {
    let p = company("p", status: .paused), c = company("c")
    #expect(Scheduler.select(candidates: many(p, 3), runningByCompany: [:], config: config(), usage: open).isEmpty)
    let closed: (Company) -> UsageDecision = { _ in .closed(until: now) }
    #expect(Scheduler.select(candidates: many(c, 3), runningByCompany: [:], config: config(), usage: closed).isEmpty)
}

@Test func priorityOrderWithinCompany() {
    let a = company("a")
    let r = Scheduler.select(candidates: [
        cand(a, "ceo", role: "ceo"), cand(a, "eng", blocking: 2), cand(a, "old", ready: -50), cand(a, "new", ready: 50),
        cand(a, "arch", role: "architect", ready: 5),
    ], runningByCompany: [:], config: config(hard: 16), usage: open)
    #expect(r.map(\.name) == ["eng", "ceo", "arch", "old", "new"])
}

@Test func alreadyRunningCountsAgainstCaps() {
    let a = company("a", mode: .low)
    #expect(Scheduler.select(candidates: many(a, 5), runningByCompany: ["a": 2], config: config(), usage: open).isEmpty)
    #expect(Scheduler.select(candidates: many(a, 5), runningByCompany: ["a": 1], config: config(), usage: open).count == 1)
}

@Test func equalRatioTieBreaksByCompanyName() {
    let a = company("a"), b = company("b")
    let r = Scheduler.select(candidates: many(b, 3) + many(a, 3), runningByCompany: [:], config: config(hard: 1), usage: open)
    #expect(r.map(\.companyId) == ["a"])
}
