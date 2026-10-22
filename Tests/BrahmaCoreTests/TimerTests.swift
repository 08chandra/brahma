import Testing
import Foundation
import GRDB
@testable import BrahmaCore

private actor Counter {
    var count = 0
    var started = 0
    func hit() { count += 1 }
    func start() { started += 1 }
}

/// A job that parks until `open()` is called.
private actor Gate {
    private var continuation: CheckedContinuation<Void, Never>?
    private var isOpen = false
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { continuation = $0 }
    }
    func open() { isOpen = true; continuation?.resume(); continuation = nil }
}

private struct World {
    let store: Store
    let clock = TestClock()
    let fake = FakeTurnRunner()
    let paths: BrahmaPaths
    let orchestrator: Orchestrator

    init(jobs: TimerJobRegistry = .system) throws {
        store = try Store.inMemory()
        try store.setOwnerTimeZone("America/New_York")
        let root = try tempDir()
        paths = BrahmaPaths(home: root.appending(path: "home"), workspaces: root.appending(path: "ws"))
        orchestrator = Orchestrator(store: store, runner: fake, paths: paths, mcpExecutable: "/usr/local/bin/brahma",
                                    clock: clock.function, timerJobs: jobs)
    }

    func company(_ name: String = "Acme") throws -> Company {
        try store.createCompany(name: name, goal: "Ship it", workspacesRoot: paths.workspaces)
    }

    func cycle() async throws {
        await orchestrator.tick()
        try await orchestrator.waitUntilIdle(timeout: .seconds(5))
    }

    func timer(_ name: String, in companyId: String?) throws -> EngineTimer {
        try #require(try store.timers(companyId: nil).first { $0.name == name && $0.companyId == companyId })
    }

    func turns(_ agent: Agent) throws -> [Turn] {
        try store.writer.read { db in try Turn.filter(Column("agentId") == agent.id).fetchAll(db) }
    }

    func messages() throws -> [Message] {
        try store.writer.read { db in try Message.fetchAll(db) }
    }

    func errors(_ companyId: String) throws -> [ActivityEvent] {
        try store.events(afterId: 0, companyId: companyId).filter { $0.kind == .error }
    }
}

@Suite struct TimerTests {
    @Test func jobFiresAndReschedules() async throws {
        let counter = Counter()
        var jobs = TimerJobRegistry.system
        jobs.register("test.count") { _ in await counter.hit() }
        let w = try World(jobs: jobs)
        let c = try w.company()
        let t0 = w.clock.now
        _ = try w.store.upsertTimer(companyId: c.id, name: "count", action: .job("test.count"),
                                    schedule: .every(seconds: 300), now: t0)
        try await w.cycle()
        #expect(await counter.count == 0)          // not due yet

        w.clock.advance(301)
        try await w.cycle()
        #expect(await counter.count == 1)
        let fired = try w.timer("count", in: c.id)
        #expect(fired.lastFiredAt == w.clock.now)
        #expect(fired.nextFireAt == w.clock.now.addingTimeInterval(300))
        #expect(fired.enabled)

        try await w.cycle()                        // same instant: already claimed
        #expect(await counter.count == 1)
        w.clock.advance(300)
        try await w.cycle()
        #expect(await counter.count == 2)
    }

    @Test func missedFiresCoalesce() async throws {
        let counter = Counter()
        var jobs = TimerJobRegistry.system
        jobs.register("test.count") { _ in await counter.hit() }
        let w = try World(jobs: jobs)
        let c = try w.company()
        _ = try w.store.upsertTimer(companyId: c.id, name: "count", action: .job("test.count"),
                                    schedule: .every(seconds: 60), now: w.clock.now)
        w.clock.advance(3600)                      // an hour asleep: sixty missed fires
        try await w.cycle()
        #expect(await counter.count == 1)
        #expect(try w.timer("count", in: c.id).nextFireAt == w.clock.now.addingTimeInterval(60))
        try await w.cycle()
        #expect(await counter.count == 1)
    }

    @Test func raceClaimsOnce() async throws {
        let store = try Store.inMemory()
        let c = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let t = try store.upsertTimer(companyId: c.id, name: "t", action: .job("x"), schedule: .every(seconds: 60), now: now)
        let due = now.addingTimeInterval(61)
        let next = now.addingTimeInterval(121)
        let wins = await withTaskGroup(of: Bool.self) { group in
            for _ in 0..<8 {
                group.addTask {
                    (try? store.claimFire(timerId: t.id, expectedNext: t.nextFireAt, now: due, next: next)) ?? false
                }
            }
            var n = 0
            for await won in group where won { n += 1 }
            return n
        }
        #expect(wins == 1)
        let after = try #require(try store.timers(companyId: nil).first)
        #expect(after.lastFiredAt == due)
        #expect(after.nextFireAt == next)
    }

    @Test func onceTimerFiresThenDisables() async throws {
        let counter = Counter()
        var jobs = TimerJobRegistry.system
        jobs.register("test.count") { _ in await counter.hit() }
        let w = try World(jobs: jobs)
        let c = try w.company()
        _ = try w.store.upsertTimer(companyId: c.id, name: "once", action: .job("test.count"),
                                    schedule: .once(at: w.clock.now.addingTimeInterval(10)), now: w.clock.now)
        w.clock.advance(11)
        try await w.cycle()
        try await w.cycle()
        #expect(await counter.count == 1)
        #expect(try w.timer("once", in: c.id).enabled == false)
    }

    @Test func turnTimerWakesAgent() async throws {
        let w = try World()
        let c = try w.company()
        let ceo = try w.store.hire(companyId: c.id, name: "ceo", role: "ceo", model: "sonnet")
        #expect(ceo.state == .sleeping)
        _ = try w.store.upsertTimer(companyId: c.id, name: "standup", action: .turn(agentId: ceo.id, prompt: "Run the weekly review."),
                                    schedule: .daily(hour: 9, minute: 0), now: w.clock.now)
        let due = try w.timer("standup", in: c.id).nextFireAt
        w.clock.advance(due.timeIntervalSince(w.clock.now) + 1)
        try await w.cycle()

        #expect(try w.turns(ceo).count == 1)
        let prompt = try #require(w.fake.requests.first?.prompt)
        #expect(prompt.contains("Run the weekly review."))
        let message = try #require(try w.messages().first)
        #expect(message.senderId == "system")
        #expect(message.text == "Run the weekly review.")
        let timer = try w.timer("standup", in: c.id)
        #expect(timer.enabled)
        #expect(timer.nextFireAt > w.clock.now)
    }

    @Test func killedAgentDisablesTurnTimer() async throws {
        let w = try World()
        let c = try w.company()
        let ceo = try w.store.hire(companyId: c.id, name: "ceo", role: "ceo", model: "sonnet")
        _ = try w.store.upsertTimer(companyId: c.id, name: "standup", action: .turn(agentId: ceo.id, prompt: "Hello"),
                                    schedule: .every(seconds: 60), now: w.clock.now)
        _ = try w.store.transition(agentId: ceo.id, to: .killed, now: w.clock.now)
        w.clock.advance(61)
        try await w.cycle()
        #expect(try w.timer("standup", in: c.id).enabled == false)
        #expect(try w.messages().isEmpty)
        #expect(w.fake.requests.isEmpty)
        #expect(try w.errors(c.id).contains { $0.text.contains("standup") })
    }

    @Test func failingJobLogsAndContinues() async throws {
        let counter = Counter()
        var jobs = TimerJobRegistry.system
        jobs.register("test.fail") { _ in await counter.hit(); throw FakeError(description: "disk on fire") }
        let w = try World(jobs: jobs)
        let c = try w.company()
        _ = try w.store.upsertTimer(companyId: c.id, name: "flaky", action: .job("test.fail"),
                                    schedule: .every(seconds: 60), now: w.clock.now)
        w.clock.advance(61)
        try await w.cycle()
        #expect(await counter.count == 1)
        let logged = try w.errors(c.id)
        #expect(logged.count == 1)
        #expect(logged.first?.text.contains("flaky") == true)
        #expect(logged.first?.text.contains("disk on fire") == true)
        // Still enabled and rescheduled: it fires again next time.
        #expect(try w.timer("flaky", in: c.id).enabled)
        w.clock.advance(60)
        try await w.cycle()
        #expect(await counter.count == 2)
    }

    @Test func unknownJobLogsOnceAndDisables() async throws {
        let w = try World()
        let c = try w.company()
        _ = try w.store.upsertTimer(companyId: c.id, name: "ghost", action: .job("no.such.job"),
                                    schedule: .every(seconds: 60), now: w.clock.now)
        w.clock.advance(61)
        try await w.cycle()
        w.clock.advance(61)
        try await w.cycle()
        #expect(try w.timer("ghost", in: c.id).enabled == false)
        #expect(try w.errors(c.id).filter { $0.text.contains("no.such.job") }.count == 1)
    }

    @Test func jobsDoNotOverlap() async throws {
        let counter = Counter()
        let gate = Gate()
        var jobs = TimerJobRegistry.system
        jobs.register("test.slow") { _ in await counter.start(); await gate.wait() }
        let w = try World(jobs: jobs)
        let c = try w.company()
        _ = try w.store.upsertTimer(companyId: c.id, name: "slow", action: .job("test.slow"),
                                    schedule: .every(seconds: 60), now: w.clock.now)
        w.clock.advance(61)
        await w.orchestrator.tick()                // starts the job; the tick itself does not wait for it
        while await counter.started == 0 { try await Task.sleep(for: .milliseconds(5)) }
        w.clock.advance(120)
        await w.orchestrator.tick()                // due again, but the first run is still going
        #expect(await counter.started == 1)
        await gate.open()
        try await w.orchestrator.waitUntilIdle(timeout: .seconds(5))
        await w.orchestrator.tick()                // now it may run again
        while await counter.started < 2 { try await Task.sleep(for: .milliseconds(5)) }
        try await w.orchestrator.waitUntilIdle(timeout: .seconds(5))
        #expect(await counter.started == 2)
    }

    @Test func systemTimersEnsured() async throws {
        let store = try Store.inMemory()
        try store.setOwnerTimeZone("America/New_York")
        let a = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        let b = try store.createCompany(name: "Beta", goal: "g", workspacesRoot: try tempDir())
        // 2026-06-10 12:00 EDT
        let now = Date(timeIntervalSince1970: 1_781_107_200)
        try SystemTimers.ensure(store: store, now: now)
        let all = try store.timers(companyId: nil)
        #expect(Set(all.map(\.name)) == ["backup.hourly", "backup.repos", "backup.home", "backup.targets", "digest.daily"])
        #expect(all.count == 6)                    // four global timers + a digest per company
        #expect(all.filter { $0.name == "digest.daily" }.map(\.companyId).sorted { ($0 ?? "") < ($1 ?? "") }
                == [a.id, b.id].sorted())
        let hourly = try #require(all.first { $0.name == "backup.hourly" })
        #expect(hourly.companyId == nil)
        #expect(hourly.schedule == .every(seconds: 3600))
        #expect(hourly.action == .job("backup.hourly"))
        #expect(try #require(all.first { $0.name == "backup.repos" }).schedule == .daily(hour: 3, minute: 30))
        #expect(try #require(all.first { $0.name == "backup.home" }).schedule == .daily(hour: 4, minute: 0))
        #expect(try #require(all.first { $0.name == "backup.targets" }).schedule == .daily(hour: 4, minute: 30))
        let digest = try #require(all.first { $0.name == "digest.daily" && $0.companyId == a.id })
        #expect(digest.schedule == .daily(hour: 8, minute: 0))
        // Next 08:00 New York after 12:00 on the 10th is the 11th.
        #expect(digest.nextFireAt == Date(timeIntervalSince1970: 1_781_107_200 + 20 * 3600))

        // Idempotent: nothing moves, nothing duplicates.
        try SystemTimers.ensure(store: store, now: now.addingTimeInterval(7200))
        #expect(try store.timers(companyId: nil) == all)

        // A new company gets its digest; a changed digest time moves only the digest.
        let c = try store.createCompany(name: "Cyan", goal: "g", workspacesRoot: try tempDir())
        try SystemTimers.ensure(store: store, now: now, digestTime: (hour: 7, minute: 30))
        let again = try store.timers(companyId: nil)
        #expect(again.count == 7)
        #expect(again.filter { $0.name == "digest.daily" }.allSatisfy { $0.schedule == .daily(hour: 7, minute: 30) })
        #expect(again.contains { $0.name == "digest.daily" && $0.companyId == c.id })
        #expect(again.first { $0.name == "backup.home" } == all.first { $0.name == "backup.home" })
    }

    @Test func startEnsuresSystemTimersAndTickRunsNoOpJobs() async throws {
        let w = try World()
        let c = try w.company()
        try await w.orchestrator.start()
        let names = try w.store.timers(companyId: c.id).map(\.name)
        #expect(names.contains("backup.hourly") && names.contains("digest.daily"))
        w.clock.advance(3601)
        try await w.cycle()                        // the no-op system jobs run without logging anything
        #expect(try w.errors(c.id).isEmpty)
        #expect(try w.timer("backup.hourly", in: nil).lastFiredAt == w.clock.now)
    }

    @Test func timersForCompanyIncludeGlobalOnes() throws {
        let store = try Store.inMemory()
        let a = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        let b = try store.createCompany(name: "Beta", goal: "g", workspacesRoot: try tempDir())
        try SystemTimers.ensure(store: store, now: Date(timeIntervalSince1970: 1_781_107_200))
        let names = try store.timers(companyId: a.id).map(\.name)
        #expect(names.filter { $0 == "digest.daily" }.count == 1)
        #expect(names.contains("backup.hourly"))
        #expect(try store.timers(companyId: b.id).allSatisfy { $0.companyId == nil || $0.companyId == b.id })
    }

    @Test func timersCommandListsReadOnly() throws {
        let url = brahmaExecutableURL()
        try #require(FileManager.default.isExecutableFile(atPath: url.path), "build the brahma product first")
        let root = try tempDir()
        let paths = ownerPaths(root)
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        let store = try Store(path: paths.database.path)
        try store.setOwnerTimeZone("America/New_York")
        let c = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: paths.workspaces)
        let now = Date(timeIntervalSince1970: 1_781_107_200)
        try SystemTimers.ensure(store: store, now: now)
        _ = try store.upsertTimer(companyId: c.id, name: "evil\u{1B}[31m", action: .job("x"), schedule: .weekly(weekday: 2, hour: 9, minute: 0), now: now)

        func run(_ args: [String]) throws -> (Int32, String) {
            let p = Process()
            p.executableURL = url
            p.arguments = args
            p.environment = ["BRAHMA_HOME": paths.home.path, "BRAHMA_WORKSPACES": paths.workspaces.path, "PATH": "/usr/bin:/bin"]
            let out = Pipe()
            p.standardOutput = out
            p.standardError = FileHandle.nullDevice
            p.standardInput = FileHandle.nullDevice
            try p.run()
            let data = out.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            return (p.terminationStatus, String(decoding: data, as: UTF8.self))
        }
        let all = try run(["timers"])
        #expect(all.0 == 0)
        #expect(all.1.contains("backup.hourly") && all.1.contains("every 1h") && all.1.contains("2026-06-10 13:00"))
        #expect(all.1.contains("digest.daily") && all.1.contains("daily 08:00") && all.1.contains("2026-06-11 08:00"))
        #expect(all.1.contains("weekly Mon 09:00") && all.1.contains("never"))
        #expect(!all.1.contains("\u{1B}"))
        let one = try run(["timers", "acme"])
        #expect(one.0 == 0 && one.1.contains("backup.hourly") && one.1.contains("acme"))
        #expect(try run(["timers", "nosuch"]).0 != 0)
        #expect(try store.timers(companyId: nil).count == 6)   // listing changed nothing
    }
}
