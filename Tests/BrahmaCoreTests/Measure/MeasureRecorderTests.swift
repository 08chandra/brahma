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

        let all = [blocked, nobody, busy, paced, reserved, pausedOnly]
        let closed = UsageDecision.closed(until: t0.addingTimeInterval(600))
        let tick = MeasureRecorder.Tick(
            decisions: [blocked.id: closed, nobody.id: closed, busy.id: closed],
            paceClosed: [paced.id, reserved.id, pausedOnly.id], paceStrict: [reserved.id],
            runningByCompany: [busy.id: 1],
            activeDelta: Dictionary(uniqueKeysWithValues: all.map { ($0.id, 30.0) }), ownerReserve: 0.3)
        try MeasureRecorder.record(store: s, companies: all, tick: tick, now: t0)

        for c in all { #expect(try count(s, c, MeasureCounter.activeSeconds) == 30, "\(c.name)") }
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

    /// Each tick adds what the company clock accrued for the company this tick to that day's `activeSeconds` (owner's calendar);
    /// a tick after midnight goes to the new day.
    @Test func activeSecondsAccruedPerTick() throws {
        let s = try store()
        let acme = try MeasureFixtures.company(s, name: "Acme")
        let midnight = Date(timeIntervalSince1970: 1_700_006_400)   // 2023-11-15T00:00:00Z
        for (delta, at) in [(60.0, -120.0), (60, -60), (15, -1), (20, 19)] {
            try MeasureRecorder.record(store: s, companies: [acme], tick: MeasureRecorder.Tick(activeDelta: [acme.id: delta], ownerReserve: 0.3),
                                       now: midnight.addingTimeInterval(at))
        }
        let day1 = MeasureWindow(since: midnight.addingTimeInterval(-86_400), until: midnight)
        let day2 = MeasureWindow(since: midnight, until: midnight.addingTimeInterval(86_400))
        #expect(try s.counters(companyId: acme.id, name: MeasureCounter.activeSeconds, in: day1, tz: Self.utc) == 135)
        #expect(try s.counters(companyId: acme.id, name: MeasureCounter.activeSeconds, in: day2, tz: Self.utc) == 20)
        // No running turn, nobody waiting: no idle seconds.
        #expect(try count(s, acme, MeasureCounter.idleActionableSeconds) == 0)
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
}
