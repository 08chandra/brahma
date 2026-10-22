import Foundation
import Testing
@testable import BrahmaCore

private let now = Date(timeIntervalSince1970: 1_800_000_000)

private func company(_ name: String, mode: UsageMode = .max) -> Company {
    Company(id: name, name: name, slug: name, goal: "g", workspacePath: "/tmp/\(name)", status: .running,
            usageMode: mode, priorityWeight: 1, createdAt: now)
}
private func many(_ c: Company, _ n: Int) -> [Candidate] {
    (0..<n).map { i in
        Candidate(agent: Agent(id: "\(c.id)-\(i)", companyId: c.id, name: "a\(i)", role: "engineer", model: "m", sessionId: "s",
                               sessionStarted: false, state: .ready, blocker: nil, requestedBlocker: nil, paused: false,
                               readySince: now.addingTimeInterval(Double(i)), createdAt: now),
                  company: c, blockingCount: 0)
    }
}
private func config(hard: Int = 16, safety: Int = 100) -> SchedulerConfig {
    var c = SchedulerConfig(); c.planTier = .max20x; c.hardCap = hard; c.safetyCap = safety; return c
}
private let open: @Sendable (Company) -> UsageDecision = { _ in .open }

@Suite struct AdmissionTests {
    @Test func tierCaps() {
        var c = SchedulerConfig()
        #expect(c.planTier == .max5x)
        #expect(c.modeCap(.low) == 1); #expect(c.modeCap(.balanced) == 3); #expect(c.modeCap(.max) == 8)
        #expect(c.effectiveHardCap == 8)
        c.planTier = .max20x
        #expect(c.modeCap(.low) == 2); #expect(c.modeCap(.balanced) == 6); #expect(c.modeCap(.max) == 16)
        #expect(c.effectiveHardCap == 16)
        c.hardCap = 4
        #expect(c.effectiveHardCap == 4); #expect(c.modeCap(.max) == 4)
    }

    @Test func warningHalvesCap() {
        let a = company("a")
        #expect(Scheduler.select(candidates: many(a, 20), runningByCompany: [:], config: config(hard: 12), usage: open).count == 12)
        #expect(Scheduler.select(candidates: many(a, 20), runningByCompany: [:], config: config(hard: 12), usage: open,
                                 pressure: .warning).count == 6)
        // Halving applies to the cap, so work already running counts against the smaller number.
        #expect(Scheduler.select(candidates: many(a, 20), runningByCompany: ["a": 4], config: config(hard: 12), usage: open,
                                 pressure: .warning).count == 2)
        #expect(Scheduler.select(candidates: many(a, 20), runningByCompany: ["a": 6], config: config(hard: 12), usage: open,
                                 pressure: .warning).isEmpty)
        // Never halves to zero.
        #expect(Scheduler.select(candidates: many(a, 3), runningByCompany: [:], config: config(hard: 1), usage: open,
                                 pressure: .warning).count == 1)
    }

    @Test func criticalAdmitsNothing() {
        let a = company("a")
        #expect(Scheduler.select(candidates: many(a, 5), runningByCompany: [:], config: config(), usage: open,
                                 pressure: .critical).isEmpty)
    }

    @Test func otherChildrenCountAgainstCap() {
        let a = company("a")
        #expect(Scheduler.select(candidates: many(a, 20), runningByCompany: [:], config: config(hard: 10), usage: open,
                                 otherChildren: 3).count == 7)
        #expect(Scheduler.select(candidates: many(a, 20), runningByCompany: ["a": 2], config: config(hard: 10), usage: open,
                                 otherChildren: 3).count == 5)
        #expect(Scheduler.select(candidates: many(a, 20), runningByCompany: [:], config: config(hard: 10), usage: open,
                                 otherChildren: 10).isEmpty)
        #expect(Scheduler.select(candidates: many(a, 20), runningByCompany: [:], config: config(hard: 10, safety: 4), usage: open,
                                 otherChildren: 1).count == 3)
    }

    @Test func heldAdmitsNothing() {
        let a = company("a")
        #expect(Scheduler.select(candidates: many(a, 5), runningByCompany: [:], config: config(), usage: open, held: true).isEmpty)
    }

    @Test func pressureChangeLogged() async throws {
        let store = try Store.inMemory()
        let root = try tempDir()
        let c = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: root.appending(path: "ws"))
        let memory = StubMemory()
        let clock = TestClock()
        let o = Orchestrator(store: store, runner: FakeTurnRunner(),
                             paths: BrahmaPaths(home: root.appending(path: "h"), workspaces: root.appending(path: "ws")),
                             mcpExecutable: "/x", clock: clock.function, memory: memory)
        func usageTexts() throws -> [String] {
            try store.events(afterId: 0).filter { $0.companyId == c.id && $0.kind == .usage }.map(\.text)
        }
        await o.tick()
        #expect(try usageTexts().filter { $0.hasPrefix("memory pressure") }.isEmpty, "no change, no log")
        memory.set(.warning); await o.tick(); await o.tick()
        memory.set(.critical); await o.tick()
        memory.set(.normal); await o.tick()
        #expect(try usageTexts().filter { $0.hasPrefix("memory pressure") } == [
            "memory pressure warning: new turns limited",
            "memory pressure critical: new turns paused",
            "memory pressure normal: new turns resumed",
        ])
    }

    @Test func criticalPressureStopsOrchestratorLaunches() async throws {
        let store = try Store.inMemory()
        let root = try tempDir()
        let c = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: root.appending(path: "ws"))
        let ceo = try store.hire(companyId: c.id, name: "ceo", role: "ceo", model: "sonnet")
        let fake = FakeTurnRunner(); let memory = StubMemory(.critical); let clock = TestClock()
        let o = Orchestrator(store: store, runner: fake, paths: BrahmaPaths(home: root.appending(path: "h"), workspaces: root.appending(path: "ws")),
                             mcpExecutable: "/x", clock: clock.function, memory: memory)
        _ = try MessageRouter(store: store).sendDM(companyId: c.id, from: .owner, to: "ceo", text: "go", now: clock.now)
        await o.tick(); try await o.waitUntilIdle(timeout: .seconds(5))
        #expect(fake.requests.isEmpty)
        memory.set(.normal); await o.tick(); try await o.waitUntilIdle(timeout: .seconds(5))
        #expect(fake.requests.count == 1)
        _ = ceo
    }
}

final class StubMemory: MemoryPressureSource, @unchecked Sendable {
    private let lock = NSLock(); private var level: MemoryPressure
    init(_ level: MemoryPressure = .normal) { self.level = level }
    func set(_ l: MemoryPressure) { lock.withLock { level = l } }
    var current: MemoryPressure { lock.withLock { level } }
}
