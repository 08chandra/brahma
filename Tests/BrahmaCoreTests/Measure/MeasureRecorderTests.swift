import Foundation
import Testing
import GRDB
@testable import BrahmaCore

/// The measure recorder (Plan X6a Task 5, ruling R5: a pure function the tick calls once after dispatch). It keeps the daily
/// counters nothing else records: company-active seconds (ruling R15), idle-while-actionable seconds by cause, and the owner-wide
/// reserve breaches (company id `""`). Tests drive it directly with store fixtures; `orchestratorRecordsEachTick` checks the wiring.
@Suite(.scratch) struct MeasureRecorderTests {
    let t0 = MeasureFixtures.t0
    static let utc = TimeZone(identifier: "UTC")!

    func store() throws -> Store {
        let s = try Store.inMemory()
        try s.setOwnerTimeZone("UTC")
        return s
    }

    func count(_ store: Store, _ company: Company, _ name: String) throws -> Double {
        try MeasureFixtures.counter(store, companyId: company.id, name)
    }

    /// A company with no running turn accrues idle-while-actionable seconds only while somebody waits on usage: an agent blocked by
    /// the five-hour gate, or a ready agent held by the weekly pace or the reserve. A closed gate with nobody waiting, or a company
    /// with a turn running, accrues active seconds only.
    @Test func accruesOnlyWhenActionable() throws {
        let s = try store()
        let blocked = try MeasureFixtures.company(s, name: "Blocked")
        try MeasureFixtures.agent(s, company: blocked, name: "eng", state: .blocked, blocker: .usageLimit(until: t0.addingTimeInterval(600)))
        let nobody = try MeasureFixtures.company(s, name: "Nobody")
        try MeasureFixtures.agent(s, company: nobody, name: "eng", state: .sleeping)
        try MeasureFixtures.agent(s, company: nobody, name: "boss", state: .blocked, blocker: .owner(reason: "waiting on the owner"))
        let busy = try MeasureFixtures.company(s, name: "Busy")
        try MeasureFixtures.agent(s, company: busy, name: "eng", state: .blocked, blocker: .usageLimit(until: t0.addingTimeInterval(600)))
        let paced = try MeasureFixtures.company(s, name: "Paced")
        try MeasureFixtures.agent(s, company: paced, name: "eng", state: .ready)
        let reserved = try MeasureFixtures.company(s, name: "Reserved")
        try MeasureFixtures.agent(s, company: reserved, name: "eng", state: .ready)
        let pausedOnly = try MeasureFixtures.company(s, name: "PausedOnly")
        try MeasureFixtures.agent(s, company: pausedOnly, name: "eng", state: .ready, paused: true)
        // The gate closed this tick, and the agent is still ready (not yet moved to blocked): it waits on usage.
        let gateReady = try MeasureFixtures.company(s, name: "GateReady")
        try MeasureFixtures.agent(s, company: gateReady, name: "eng", state: .ready)

        let all = [blocked, nobody, busy, paced, reserved, pausedOnly, gateReady]
        let closed = UsageDecision.closed(until: t0.addingTimeInterval(600))
        let tick = MeasureRecorder.Tick(
            decisions: [blocked.id: closed, nobody.id: closed, busy.id: closed, gateReady.id: closed],
            paceClosed: [paced.id, reserved.id, pausedOnly.id], paceStrict: [reserved.id],
            runningByCompany: [busy.id: 1],
            activeDelta: Dictionary(uniqueKeysWithValues: all.map { ($0.id, 30.0) }), ownerReserve: 0.3)
        try MeasureRecorder.record(store: s, companies: all, tick: tick, now: t0)

        // Active seconds are the clock's own write (`accrueActiveTime`), never the recorder's.
        for c in all { #expect(try count(s, c, MeasureCounter.activeSeconds) == 0, "\(c.name)") }
        #expect(try count(s, gateReady, MeasureCounter.idleUsageLimitSeconds) == 30)
        #expect(try count(s, blocked, MeasureCounter.idleActionableSeconds) == 30)
        #expect(try count(s, blocked, MeasureCounter.idleUsageLimitSeconds) == 30)
        #expect(try count(s, nobody, MeasureCounter.idleActionableSeconds) == 0, "a closed gate with nobody waiting is not actionable")
        #expect(try count(s, busy, MeasureCounter.idleActionableSeconds) == 0, "a running turn: not idle")
        #expect(try count(s, paced, MeasureCounter.idleActionableSeconds) == 30)
        #expect(try count(s, paced, MeasureCounter.idlePaceSeconds) == 30)
        #expect(try count(s, reserved, MeasureCounter.idleActionableSeconds) == 30)
        #expect(try count(s, reserved, MeasureCounter.idleReserveSeconds) == 30)
        #expect(try count(s, reserved, MeasureCounter.idlePaceSeconds) == 0, "one cause per tick")
        #expect(try count(s, pausedOnly, MeasureCounter.idleActionableSeconds) == 0, "a paused agent is not waiting on usage")

        // The gate reopened but the blocked agent's blocker has not been lifted yet: it still waits on usage.
        try MeasureRecorder.record(store: s, companies: [blocked], tick: MeasureRecorder.Tick(activeDelta: [blocked.id: 10], ownerReserve: 0.3),
                                   now: t0.addingTimeInterval(10))
        #expect(try count(s, blocked, MeasureCounter.idleActionableSeconds) == 40)
    }

    /// The owner account's usage snapshot is judged once, when it is new (by `observedAt`): at or past `1 − reserve` it adds one
    /// owner-wide breach under company id `""`. The same snapshot on later ticks, a snapshot under the line, and a snapshot older
    /// than the recorder's first run add nothing; no company's own counter is touched.
    @Test func breachCountedOncePerSnapshot() throws {
        let s = try store()
        let acme = try MeasureFixtures.company(s, name: "Acme")
        let tick = MeasureRecorder.Tick(ownerReserve: 0.3)
        // Observed before the recorder first ran: history the recorder never saw, not counted.
        try MeasureFixtures.usage(s, sevenDay: 0.95, observedAt: t0.addingTimeInterval(-3600))
        try MeasureRecorder.record(store: s, companies: [acme], tick: tick, now: t0)
        #expect(try MeasureFixtures.counter(s, companyId: "", MeasureCounter.reserveBreaches) == 0)

        try MeasureFixtures.usage(s, sevenDay: 0.75, observedAt: t0.addingTimeInterval(60))
        for n in 1...3 { try MeasureRecorder.record(store: s, companies: [acme], tick: tick, now: t0.addingTimeInterval(60 + Double(n))) }
        #expect(try MeasureFixtures.counter(s, companyId: "", MeasureCounter.reserveBreaches) == 1)
        try MeasureFixtures.usage(s, sevenDay: 0.70, observedAt: t0.addingTimeInterval(120))   // exactly at the line
        try MeasureRecorder.record(store: s, companies: [acme], tick: tick, now: t0.addingTimeInterval(121))
        #expect(try MeasureFixtures.counter(s, companyId: "", MeasureCounter.reserveBreaches) == 2)
        try MeasureFixtures.usage(s, sevenDay: 0.5, observedAt: t0.addingTimeInterval(180))
        try MeasureRecorder.record(store: s, companies: [acme], tick: tick, now: t0.addingTimeInterval(181))
        // A snapshot without seven-day utilization says nothing about the reserve.
        try MeasureFixtures.usage(s, sevenDay: nil, observedAt: t0.addingTimeInterval(240))
        try MeasureRecorder.record(store: s, companies: [acme], tick: tick, now: t0.addingTimeInterval(241))
        #expect(try MeasureFixtures.counter(s, companyId: "", MeasureCounter.reserveBreaches) == 2)
        #expect(try count(s, acme, MeasureCounter.reserveBreaches) == 0)
        // A larger owner reserve moves the line down: 0.65 ≥ 1 − 0.4.
        try MeasureFixtures.usage(s, sevenDay: 0.65, observedAt: t0.addingTimeInterval(300))
        try MeasureRecorder.record(store: s, companies: [], tick: MeasureRecorder.Tick(ownerReserve: 0.4), now: t0.addingTimeInterval(301))
        #expect(try MeasureFixtures.counter(s, companyId: "", MeasureCounter.reserveBreaches) == 3)
    }

    /// A company that is not running accrues nothing, whatever it is waiting on; a running company whose clock did not move (an
    /// engine hold, the owner's stop) accrues nothing either.
    @Test func stoppedCompanyDoesNotAccrue() throws {
        let s = try store()
        var paused = try MeasureFixtures.company(s, name: "Paused")
        paused.status = .paused
        try s.updateCompany(paused)
        try MeasureFixtures.agent(s, company: paused, name: "eng", state: .blocked, blocker: .usageLimit(until: t0.addingTimeInterval(600)))
        let held = try MeasureFixtures.company(s, name: "Held")
        try MeasureFixtures.agent(s, company: held, name: "eng", state: .blocked, blocker: .usageLimit(until: t0.addingTimeInterval(600)))
        let closed = UsageDecision.closed(until: t0.addingTimeInterval(600))
        try MeasureRecorder.record(store: s, companies: [paused, held],
                                   tick: MeasureRecorder.Tick(decisions: [paused.id: closed, held.id: closed],
                                                              activeDelta: [paused.id: 30, held.id: 0], ownerReserve: 0.3),
                                   now: t0)
        let rows = try s.writer.read { db in
            try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM measureCounter WHERE companyId IN (?, ?)", arguments: [paused.id, held.id]) ?? -1
        }
        #expect(rows == 0)
    }

    /// The company clock writes each tick's accrued seconds to that day's `activeSeconds` (owner's calendar) in its own
    /// transaction, so the counter always equals what `companyActivity` gained, whatever happens later in the tick; a tick after
    /// midnight goes to the new day; a paused company gains nothing.
    @Test func activeSecondsAccruedPerTick() throws {
        let s = try store()
        let acme = try MeasureFixtures.company(s, name: "Acme")
        var paused = try MeasureFixtures.company(s, name: "Paused")
        paused.status = .paused
        try s.updateCompany(paused)
        let midnight = Date(timeIntervalSince1970: 1_700_006_400)   // 2023-11-15T00:00:00Z
        var gained: [Double] = []
        for at in [-121.0, -61, -1, 19] {
            let delta = try s.accrueActiveTime(now: midnight.addingTimeInterval(at))
            gained.append(delta[acme.id] ?? -1)
            #expect(delta[paused.id] == 0)
        }
        #expect(gained == [0, 60, 60, 20])
        let day1 = MeasureWindow(since: midnight.addingTimeInterval(-86_400), until: midnight)
        let day2 = MeasureWindow(since: midnight, until: midnight.addingTimeInterval(86_400))
        #expect(try s.counters(companyId: acme.id, name: MeasureCounter.activeSeconds, in: day1, tz: Self.utc) == 120)
        #expect(try s.counters(companyId: acme.id, name: MeasureCounter.activeSeconds, in: day2, tz: Self.utc) == 20)
        #expect(try MeasureFixtures.counter(s, companyId: acme.id, MeasureCounter.activeSeconds) == s.activeNow(companyId: acme.id))
        #expect(try MeasureFixtures.counter(s, companyId: paused.id, MeasureCounter.activeSeconds) == 0)
        // The recorder adds no active seconds of its own.
        try MeasureRecorder.record(store: s, companies: [acme], tick: MeasureRecorder.Tick(activeDelta: [acme.id: 20], ownerReserve: 0.3),
                                   now: midnight.addingTimeInterval(19))
        #expect(try MeasureFixtures.counter(s, companyId: acme.id, MeasureCounter.activeSeconds) == 140)
    }

    /// The engine calls the recorder once per tick, after dispatch, with the seconds the company clock accrued that tick.
    @Test func orchestratorRecordsEachTick() async throws {
        let w = try World()
        try w.store.setOwnerTimeZone("UTC")
        let c = try w.company("Acme")
        await w.orchestrator.tick()
        w.clock.advance(30)
        await w.orchestrator.tick()
        w.clock.advance(90)   // one tick gap counts at most 60 s
        await w.orchestrator.tick()
        #expect(try MeasureFixtures.counter(w.store, companyId: c.id, MeasureCounter.activeSeconds) == 90)
        #expect(abs(w.store.activeNow(companyId: c.id) - 90) < 1e-9, "the counter is what the clock accrued, never more")
    }

    /// The recorder runs after dispatch: a company held by the weekly pace whose critical-path agent was admitted this tick has a
    /// running turn, so the tick is not idle.
    @Test func launchTickIsNotIdle() async throws {
        let w = try World()
        try w.store.setOwnerTimeZone("UTC")
        let c = try w.company("Acme")
        let eng = try w.hire(c, "eng")
        let waiter = try w.hire(c, "waiter")
        try await w.store.writer.write { db in
            guard var a = try Agent.fetchOne(db, key: waiter.id) else { throw FakeError(description: "no agent") }
            a.state = .blocked
            a.blocker = .agent(eng.id)
            try a.update(db)
        }
        // Weekly pace closed (half the week used at its start), the reserve untouched: only the critical path runs.
        try w.store.saveRateLimit(RateLimitInfo(status: "allowed", resetsAt: nil, rateLimitType: nil, isUsingOverage: false,
                                                fiveHourUtilization: 0.1, sevenDayUtilization: 0.5, observedAt: w.clock.now,
                                                fiveHourResetsAt: w.clock.now.addingTimeInterval(3600),
                                                sevenDayResetsAt: w.clock.now.addingTimeInterval(7 * 86_400)))
        await w.orchestrator.tick()
        w.clock.advance(30)
        try w.dm(c, eng)
        try await w.cycle()
        #expect(try w.turns(eng).count == 1, "the critical-path agent was admitted under the closed pace")
        #expect(try MeasureFixtures.counter(w.store, companyId: c.id, MeasureCounter.activeSeconds) == 30)
        #expect(try MeasureFixtures.counter(w.store, companyId: c.id, MeasureCounter.idleActionableSeconds) == 0)
    }

    /// The tick's log line for the recorder: the first failure, a changed failure, and one recovery line; never once per tick.
    @Test func failureLoggedOnChangeOnly() {
        var log = MeasureRecorder.FailureLog()
        #expect(log.note(nil) == nil)
        #expect(log.note("disk I/O error")?.contains("disk I/O error") == true)
        #expect(log.note("disk I/O error") == nil)
        #expect(log.note("database is locked")?.contains("database is locked") == true)
        #expect(log.note(nil) == "measure recorder recovered; this tick's measure counters were recorded")
        #expect(log.note(nil) == nil)
    }

    /// `vX6a-measure-owner-counters` rebuilds `measureCounter` without the company reference: rows are copied, an owner-wide row
    /// (company id "") is allowed, and deleting a company removes its rows while the owner-wide rows stay.
    @Test func ownerCountersMigrationKeepsRowsAndCascade() throws {
        let db = try DatabaseQueue()
        let migrator = Migrations.migrator()
        try migrator.migrate(db, upTo: "vX6a-measure-epoch")
        let acme = Company(id: "c-acme", name: "Acme", slug: "acme", goal: "g", workspacePath: "/nonexistent", status: .running,
                           usageMode: .balanced, priorityWeight: 1, createdAt: t0)
        try db.write { db in
            try acme.insert(db)
            try db.execute(sql: "INSERT INTO measureCounter (companyId, name, day, value) VALUES ('c-acme', 'activeSeconds', '2026-11-01', 42)")
            #expect(throws: (any Error).self) {
                try db.execute(sql: "INSERT INTO measureCounter (companyId, name, day, value) VALUES ('', 'reserveBreaches', '2026-11-01', 1)")
            }
        }
        try migrator.migrate(db)
        try db.write { db in
            #expect(try Double.fetchOne(db, sql: "SELECT value FROM measureCounter WHERE companyId = 'c-acme'") == 42)
            try Store.addCounter(db, companyId: MeasureCounter.ownerWide, name: MeasureCounter.reserveBreaches, day: "2026-11-01", delta: 1)
            try db.execute(sql: "DELETE FROM company WHERE id = 'c-acme'")
            #expect(try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM measureCounter WHERE companyId = 'c-acme'") == 0)
            #expect(try Double.fetchOne(db, sql: "SELECT value FROM measureCounter WHERE companyId = ''") == 1)
        }
    }
}
