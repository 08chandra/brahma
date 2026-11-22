import Testing
import Foundation
@testable import BrahmaCore
@testable import BrahmaAppModel

/// The throttled event queue (`MapModel.step`), the synthetic company and its traffic. Pure value code; nothing here
/// touches a store or any secret storage.
@MainActor
@Suite(.scratch) struct MapQueueTests {
    let software = SoftwarePack.pack
    let t0: TimeInterval = 1_000
    let id: (MapEndpoint) -> MapEndpoint = { $0 }

    func inputs(_ agents: [Agent], vacancies: [Vacancy] = [], meetings: [Meeting] = []) -> MapInputs {
        MapInputs(agents: agents, pack: software, vacancies: vacancies, meetings: meetings)
    }

    func small() -> (m: MapModel, agents: [Agent]) {
        let agents = agentsFromPlan(plan(30, pack: software))
        var m = MapModel()
        m.apply(inputs(agents), now: t0)
        return (m, agents)
    }

    func big(_ n: Int = 300) -> (m: MapModel, agents: [Agent]) {
        let c = SyntheticCompany.make(agents: n)
        var m = MapModel()
        m.apply(MapInputs(agents: c.agents, pack: c.pack, currentItems: c.currentItems, blockers: c.blockers,
                          vacancies: c.vacancies, meetings: c.meetings), now: t0)
        return (m, c.agents)
    }

    func dm(_ from: String, _ to: [String]) -> MapFact {
        .message(MessageFlow(rowId: 1, messageId: "m", companyId: "c", senderId: from, channelId: "ch",
                             channelName: "dm:\(from)", channelKind: .dm, kind: "text", recipientIds: to, team: nil,
                             createdAt: mapFixtureEpoch))
    }

    func post(from: String, mentions: [String]) -> MapFact {
        .message(MessageFlow(rowId: 1, messageId: "m", companyId: "c", senderId: from, channelId: "ch",
                             channelName: "team-x", channelKind: .channel, kind: "text", recipientIds: mentions, team: "x",
                             createdAt: mapFixtureEpoch))
    }

    func conserved(_ m: MapModel) -> Bool {
        let s = m.stats
        return s.ingested == s.spawned + s.coalesced + s.aggregated + s.dropped + s.queued
    }

    static func isTraffic(_ k: VisualKind) -> Bool {
        switch k {
        case .message, .broadcast: true
        default: false
        }
    }

    /// `count` distinct sender → recipient pairs over `agents` (count ≤ 29 × agents.count).
    func pairs(_ agents: [Agent], _ count: Int) -> [MapFact] {
        let n = agents.count
        return (0..<count).map { i in dm(agents[i % n].id, [agents[(i % n + 1 + i / n) % n].id]) }
    }

    // MARK: - Queue

    @Test func spawnBudgetPerStep() {
        var (m, agents) = small()
        m.ingest(pairs(agents, 50), now: t0)
        #expect(m.stats.ingested == 50)
        #expect(m.step(now: t0, resolve: id).count == 6)
        #expect(m.step(now: t0 + 0.016, resolve: id).count == 6)
        #expect(m.stats.spawned == 12)
        #expect(m.stats.queued == 38)
        #expect(m.step(now: t0 + 0.03, resolve: id, budget: 14).count == 2)   // 14 - 12 active
        #expect(conserved(m))
    }

    @Test func coalescesSamePair() {
        var (m, agents) = small()
        let a = agents[3].id, b = agents[4].id
        for i in 0..<5 { m.ingest([dm(a, [b])], now: t0 + Double(i) * 0.075) }
        let spawned = m.step(now: t0 + 0.3, resolve: id)
        #expect(spawned.count == 1)
        #expect(spawned[0].count == 5)
        #expect(spawned[0].label == "×5")
        #expect(m.stats.coalesced == 4)
        #expect(conserved(m))
    }

    @Test func coalescesIntoAnActiveEvent() {
        var (m, agents) = small()
        let a = agents[3].id, b = agents[4].id
        m.ingest([dm(a, [b])], now: t0)
        #expect(m.step(now: t0, resolve: id).count == 1)
        for i in 1...4 { m.ingest([dm(a, [b])], now: t0 + Double(i) * 0.1) }
        #expect(m.step(now: t0 + 0.4, resolve: id).isEmpty)
        #expect(m.active.count == 1)
        #expect(m.active[0].count == 5)
        #expect(m.active[0].label == "×5")
        // A later one is outside the window: a new event.
        m.ingest([dm(a, [b])], now: t0 + 0.8)
        #expect(m.step(now: t0 + 0.8, resolve: id).count == 1)
        #expect(conserved(m))
    }

    @Test func structuralBeforeMessages() {
        var (m, agents) = small()
        m.ingest(pairs(agents, 10), now: t0)
        var next = agents
        next[5].state = .killed
        m.apply(inputs(next), now: t0)
        let spawned = m.step(now: t0, resolve: id)
        #expect(spawned.first?.kind == .leave)
        #expect(spawned.dropFirst().allSatisfy { $0.kind == .message })
    }

    @Test func burstOf2000StaysBounded() {
        var (m, agents) = big(300)
        var rng = SplitMix64(seed: 7)
        // 2000 message events at under 30 message facts per second: 167 facts each naming 12 agents. The backlog outgrows
        // the 150 active cap and the oldest messages are dropped.
        func fact() -> MapFact {
            let s = agents.randomElement(using: &rng)!
            var to: [String] = []
            while to.count < 12 { let r = agents.randomElement(using: &rng)!.id; if r != s.id, !to.contains(r) { to.append(r) } }
            return post(from: s.id, mentions: to)
        }
        var maxQueued = 0, maxActive = 0
        for step in 0..<600 {
            let t = t0 + Double(step) / 60
            if step % 30 == 0 && step < 400 { m.ingest((0..<13).map { _ in fact() }, now: t) }
            _ = m.step(now: t, resolve: id)
            maxQueued = max(maxQueued, m.stats.queued); maxActive = max(maxActive, m.stats.active)
            #expect(conserved(m))
        }
        #expect(m.stats.ingested >= 2000)
        #expect(maxQueued <= 400)
        #expect(maxActive <= 150)
        #expect(m.stats.dropped > 0)
        #expect(m.stats.lastDropAt != nil)
        #expect(!m.stats.aggregate)

        // 2000 facts at once is a rate of 1000/s: aggregate mode swallows them; nothing is left over the cap.
        var burst = big(300).m
        burst.ingest((0..<2000).map { _ in dm(agents.randomElement(using: &rng)!.id, [agents.randomElement(using: &rng)!.id]) },
                     now: t0)
        for step in 0..<600 {
            _ = burst.step(now: t0 + Double(step) / 60, resolve: id)
            #expect(burst.stats.queued <= 400)
            #expect(burst.stats.active <= 150)
            #expect(conserved(burst))
        }
        #expect(burst.stats.aggregated > 0)
    }

    @Test func mentionStormFansOutCapped() {
        var (m, agents) = big(300)
        let mentions = agents.dropFirst().prefix(300).map(\.id)
        m.ingest([post(from: agents[0].id, mentions: Array(mentions))], now: t0)
        #expect(m.stats.ingested == 13)
        var kinds: [VisualKind] = []
        for step in 0..<5 { kinds += m.step(now: t0 + Double(step) / 60, resolve: id).map(\.kind) }
        #expect(kinds.filter { $0 == .message }.count == 12)
        #expect(kinds.filter { $0 == .broadcast }.count == 1)
        #expect(kinds.last == .broadcast)
    }

    /// Feeds `perSecond` DM facts per second in 100 ms ticks (fractional rates carry) over `seconds`.
    func feed(_ m: inout MapModel, agents: [Agent], perSecond: Double, seconds: Double, from start: TimeInterval,
              spawnedMessages: inout Int) {
        var carry = 0.0, i = Int(start * 10)
        for tick in 0..<Int(seconds * 10) {
            let t = start + Double(tick) * 0.1
            carry += perSecond / 10
            var facts: [MapFact] = []
            while carry >= 1 { carry -= 1; i += 1; facts.append(dm(agents[i % 30].id, [agents[(i * 3 + 1) % 29 + 1].id])) }
            m.ingest(facts, now: t)
            spawnedMessages += m.step(now: t + 0.05, resolve: id).filter { $0.kind == .message }.count
        }
    }

    @Test func aggregateHysteresis() {
        var (m, agents) = small()
        var spawned = 0
        feed(&m, agents: agents, perSecond: 40, seconds: 2, from: t0, spawnedMessages: &spawned)
        spawned = 0
        feed(&m, agents: agents, perSecond: 40, seconds: 1, from: t0 + 2, spawnedMessages: &spawned)
        #expect(m.stats.aggregate)
        #expect(m.stats.rate >= 30)
        #expect(spawned == 0)
        #expect(m.stats.aggregated > 0)
        #expect(m.edges(now: t0 + 2.95).contains { $0.pulse > 0.99 })

        feed(&m, agents: agents, perSecond: 25, seconds: 3, from: t0 + 3, spawnedMessages: &spawned)
        #expect(m.stats.aggregate)                      // 25 > 20: still on
        #expect(m.stats.rate > 20 && m.stats.rate < 30)
        #expect(spawned == 0)

        feed(&m, agents: agents, perSecond: 15, seconds: 3, from: t0 + 6, spawnedMessages: &spawned)
        #expect(!m.stats.aggregate)
        #expect(spawned > 0)
        #expect(conserved(m))

        // One fact fanning out to 12 recipients: 12 events, rate contribution 1 / 2 s.
        var (f, fa) = small()
        f.ingest([post(from: fa[0].id, mentions: fa.dropFirst().prefix(12).map(\.id))], now: t0)
        #expect(f.stats.ingested == 12)
        _ = f.step(now: t0, resolve: id)
        #expect(f.stats.rate == 0.5)
    }

    @Test func rateCountsMessagesOnce() {
        var (m, agents) = big(300)
        var rng = SplitMix64(seed: 3)
        for tick in 0..<50 {                                     // 5 s at 20 facts/s, 12 mentions each
            let t = t0 + Double(tick) * 0.1
            let facts = (0..<2).map { _ -> MapFact in
                let s = agents.randomElement(using: &rng)!
                var to: [String] = []
                while to.count < 12 { let r = agents.randomElement(using: &rng)!.id; if r != s.id, !to.contains(r) { to.append(r) } }
                return post(from: s.id, mentions: to)
            }
            m.ingest(facts, now: t)
            _ = m.step(now: t + 0.05, resolve: id)
            #expect(!m.stats.aggregate)
        }
        #expect(m.stats.rate >= 19 && m.stats.rate <= 20.5)
        #expect(m.stats.ingested >= 1200)
        #expect(conserved(m))
    }

    @Test func structuralNeverDropped() {
        let all = SyntheticCompany.make(agents: 500).agents
        var m = MapModel()
        let before = Array(all.prefix(300))
        m.apply(inputs(before), now: t0)
        var after = all
        for i in 0..<300 {
            switch i % 3 {
            case 0: after[i].state = .killed
            case 1: after[i].state = after[i].state == .running ? .ready : .running
            default: break
            }
        }
        m.apply(inputs(after), now: t0)
        let structural = m.pendingCount
        #expect(structural >= 300)

        var rng = SplitMix64(seed: 11)
        var spawnedStructural = 0
        for step in 0..<1200 {
            let t = t0 + Double(step) / 60
            if step % 30 == 0 && step < 450 {
                m.ingest((0..<13).map { _ in
                    let s = all.randomElement(using: &rng)!
                    var to: [String] = []
                    while to.count < 12 { let r = all.randomElement(using: &rng)!.id; if r != s.id, !to.contains(r) { to.append(r) } }
                    return post(from: s.id, mentions: to)
                }, now: t)
            }
            spawnedStructural += m.step(now: t, resolve: id).filter { !Self.isTraffic($0.kind) && $0.kind != .handoff }.count
            #expect(conserved(m))
        }
        #expect(spawnedStructural == structural)
        #expect(m.stats.dropped > 0)                  // messages were dropped, and only messages
        #expect(m.stats.queued == 0)
        #expect(m.stats.spawned + m.stats.coalesced + m.stats.aggregated + m.stats.dropped == m.stats.ingested)
    }

    @Test func phaseChangeIsStructural() throws {
        var (m, agents) = small()
        var i = inputs(agents)
        i.itemPhases = [agents[4].id: .working]
        m.apply(i, now: t0)
        // 40 message facts (20/s: below aggregate mode) against a cap of 10.
        m.throttle.queueCap = 10
        m.ingest(pairs(agents, 40), now: t0)
        i.itemPhases = [agents[4].id: .checking]
        m.apply(i, now: t0)
        #expect(MapThrottle.duration(.phaseChange(from: .working, to: .checking)) == 0.2)
        #expect(MapThrottle.priority(.phaseChange(from: .working, to: .checking)) == MapThrottle.priority(.stateChange(from: .ready, to: .running)))
        #expect(!MapThrottle.isTraffic(.phaseChange(from: .checking, to: .merging)))

        // Nothing spawns (no room): the queue is cut to its cap, traffic only.
        #expect(m.step(now: t0, resolve: id, budget: 0).isEmpty)
        #expect(m.stats.dropped == 30)
        #expect(!m.stats.aggregate)
        #expect(m.pending.contains { $0.kind == .phaseChange(from: .working, to: .checking) })
        let spawned = m.step(now: t0 + 0.1, resolve: id)
        let first = try #require(spawned.first)
        #expect(first.kind == .phaseChange(from: .working, to: .checking))
        #expect(first.from == .agent(agents[4].id))
        #expect(first.duration == 0.2)
        #expect(spawned.dropFirst().allSatisfy { $0.kind == .message })
        #expect(conserved(m))
    }

    @Test func hiddenPairBecomesBroadcast() {
        var (m, agents) = small()
        let manager = agents[1]
        let a = agents[10].id, b = agents[11].id
        m.ingest([dm(a, [b])], now: t0)
        let spawned = m.step(now: t0, resolve: { _ in .agent(manager.id) })
        #expect(spawned.count == 1)
        #expect(spawned[0].kind == .broadcast)
        #expect(spawned[0].from == .agent(manager.id))
        #expect(spawned[0].to == nil)
    }

    @Test func applyPruneIsCountedAsDropped() {
        var (m, agents) = small()
        let gone = agents[7]
        m.ingest([dm(agents[2].id, [gone.id]), dm(gone.id, [agents[3].id])], now: t0)
        var next = agents
        next[8].state = .killed                                   // structural event naming a survivor
        next[7].state = .running
        m.apply(inputs(next), now: t0 + 1)
        #expect(m.stats.ingested == 4)
        next.remove(at: 7)
        m.apply(inputs(next), now: t0 + 2)
        #expect(m.stats.dropped == 3)                              // two DMs and the state change of the removed agent
        #expect(m.stats.lastDropAt == t0 + 2)
        #expect(conserved(m))
    }

    @Test func everyEventAccounted() {
        let c = SyntheticCompany.make(agents: 300)
        var m = MapModel()
        m.apply(MapInputs(agents: c.agents, pack: c.pack, currentItems: c.currentItems, blockers: c.blockers,
                          vacancies: c.vacancies, meetings: c.meetings), now: 0)
        var traffic = SyntheticTraffic(seed: 5)
        var agents = c.agents
        let epoch = mapFixtureEpoch
        var lastPoll = 0.0
        var removed = false
        for step in 0..<3600 {
            let t = Double(step) / 60
            if t - lastPoll >= 0.5 {
                let facts = traffic.facts(from: epoch.addingTimeInterval(lastPoll), to: epoch.addingTimeInterval(t), agents: agents,
                                          rate: 50)
                m.ingest(facts, now: t)
                lastPoll = t
            }
            if step == 1200 {                                      // org changes: states flip, hires appear
                for i in stride(from: 3, to: agents.count, by: 11) { agents[i].state = .running }
                m.apply(inputs(agents), now: t)
            }
            if step == 2400 && !removed {                          // an agent leaves the company with events pending
                removed = true
                let gone = agents.remove(at: 40)
                m.ingest([dm(agents[3].id, [gone.id]), dm(gone.id, [agents[5].id])], now: t)
                let dropped = m.stats.dropped, queued = m.pendingCount
                m.apply(inputs(agents), now: t)
                #expect(m.stats.dropped >= dropped + 2)
                #expect(m.stats.lastDropAt == t)
                #expect(m.pendingCount <= queued - 2)
                #expect(conserved(m))
            }
            _ = m.step(now: t, resolve: id)
            #expect(conserved(m))
        }
        #expect(m.stats.ingested > 3000)
    }

    // MARK: - Synthetic company

    @Test func syntheticIsDeterministic() {
        let a = SyntheticCompany.make(agents: 300, seed: 42), b = SyntheticCompany.make(agents: 300, seed: 42)
        #expect(a.agents == b.agents)
        #expect(a.vacancies == b.vacancies)
        #expect(a.meetings == b.meetings)
        #expect(a.currentItems == b.currentItems)
        #expect(a.blockers == b.blockers)
        #expect(a.agents.filter { $0.role == "ceo" }.count == 1)
        #expect(a.agents.filter { $0.role == a.pack.org.director }.count >= 1)
        let killed = a.agents.filter { $0.state == .killed }.count
        #expect((10...20).contains(killed))                        // 5 % of 300
        #expect(a.vacancies.count == 12)
        #expect(a.vacancies.allSatisfy { $0.source == .org })
        #expect(a.meetings.count == 1)
        #expect(a.meetings[0].kind == .sprintPlanning)
        #expect(a.meetings[0].title == "SPRINT 1 PLANNING")
        #expect(a.meetings[0].participantIds.count >= 2)
        #expect((100...140).contains(a.currentItems.count))        // about 40 %
        let blocked = a.agents.filter { $0.state == .blocked }
        #expect(!blocked.isEmpty)
        #expect(blocked.allSatisfy { !(a.blockers[$0.id] ?? "").isEmpty })
        #expect(a.blockers.count == blocked.count)
        #expect(a.agents.allSatisfy { $0.companyId == "demo" })
        #expect(a.agents.compactMap(\.team).allSatisfy { $0.hasPrefix("team-") })
        #expect(Set(a.agents.map(\.id)).count == a.agents.count)
        #expect(a.agents.filter { $0.state == .running }.count > 60)
        let c = SyntheticCompany.make(agents: 300, seed: 43)
        #expect(c.agents != a.agents)

        #expect(SyntheticCompany.make(agents: 9000).agents.count == 500)
        #expect(SyntheticCompany.make(agents: 0).agents.count == 5)
        #expect(SyntheticCompany.make(agents: -3).agents.count == 5)
    }

    @Test func syntheticOfficeFacets() {
        let a = SyntheticCompany.make(agents: 300, seed: 42), b = SyntheticCompany.make(agents: 300, seed: 42)
        #expect(a.itemPhases == b.itemPhases)
        #expect(a.reviewing == b.reviewing)
        #expect(a.people == b.people)
        #expect(a.openAsks == 3)
        // Every running agent with an item has a phase, and nobody else.
        let byId = Dictionary(uniqueKeysWithValues: a.agents.map { ($0.id, $0) })
        let running = Set(a.agents.filter { $0.state == .running && a.currentItems[$0.id] != nil }.map(\.id))
        #expect(Set(a.itemPhases.keys) == running)
        func count(_ p: MapItemPhase) -> Int { a.itemPhases.values.filter { $0 == p }.count }
        let n = Double(running.count)
        #expect(count(.inReview) == Int((n * 0.15).rounded()))
        #expect(count(.checking) == Int((n * 0.10).rounded()))
        #expect(count(.merging) == Int((n * 0.10).rounded()))
        #expect(count(.failed) == Int((n * 0.05).rounded()))
        #expect(count(.passed) == 0)
        #expect(count(.working) == running.count - count(.inReview) - count(.checking) - count(.merging) - count(.failed))
        // One living teammate reviews each in-review item.
        #expect(!a.reviewing.isEmpty && a.reviewing.count <= count(.inReview))
        for r in a.reviewing {
            let reviewer = byId[r]!
            #expect(reviewer.state != .killed)
            #expect(a.itemPhases.contains { $0.value == .inReview && byId[$0.key]?.team == reviewer.team && $0.key != r })
        }
        // Perks: 10 % of the agents, one or two each, from the set.
        #expect(a.people.perks.count == Int((Double(a.agents.count) * 0.1).rounded()))
        #expect(a.people.perks.values.allSatisfy { (1...2).contains($0.count) })
        #expect(a.people.perks.values.joined().allSatisfy { ["☕", "🍜", "🏆", "🔥", "⭐"].contains($0) })
        #expect(a.people.trust.isEmpty && a.people.meters.isEmpty && a.people.dotted.isEmpty && a.people.vacancies.isEmpty)
    }

    @Test func syntheticTrafficShapeAndDeterminism() {
        let c = SyntheticCompany.make(agents: 300)
        let byId = Dictionary(uniqueKeysWithValues: c.agents.map { ($0.id, $0) })
        var t1 = SyntheticTraffic(seed: 9), t2 = SyntheticTraffic(seed: 9)
        let from = mapFixtureEpoch.addingTimeInterval(5), to = mapFixtureEpoch.addingTimeInterval(25)   // crosses a 10 s burst
        let f1 = t1.facts(from: from, to: to, agents: c.agents, rate: 50), f2 = t2.facts(from: from, to: to, agents: c.agents, rate: 50)
        #expect(f1 == f2)
        #expect(f1.count >= 1000 + 200)
        #expect(f1.allSatisfy { $0.at >= from && $0.at <= to })
        var msgs = 0, handoffs = 0, within = 0, up = 0, across = 0
        for f in f1 {
            switch f {
            case .handoff: handoffs += 1
            case .message(let m):
                msgs += 1
                #expect(m.kind == "text")
                guard let s = byId[m.senderId] else { Issue.record("unknown sender"); continue }
                #expect(s.state != .killed)
                let r = m.recipientIds.compactMap { byId[$0] }
                if let first = r.first {
                    if first.id == s.managerId { up += 1 } else if first.team == s.team { within += 1 } else { across += 1 }
                } else { within += 1 }                              // a team post with no mention
            default: Issue.record("unexpected fact")
            }
        }
        let total = Double(f1.count)
        #expect(abs(Double(handoffs) / total - 0.05) < 0.03)
        #expect(Double(within) / Double(max(1, msgs)) > 0.65)
        #expect(Double(up) / Double(max(1, msgs)) > 0.08)
        #expect(Double(across) / Double(max(1, msgs)) < 0.12)
        // No burst without one in the window.
        var t3 = SyntheticTraffic(seed: 9)
        let quiet = t3.facts(from: mapFixtureEpoch.addingTimeInterval(11), to: mapFixtureEpoch.addingTimeInterval(13), agents: c.agents,
                             rate: 50, burst: nil)
        #expect(quiet.count >= 95 && quiet.count <= 105)
        var t4 = SyntheticTraffic(seed: 1)
        #expect(t4.facts(from: from, to: to, agents: [], rate: 50).isEmpty)
    }

    @Test(.enabled(if: ProcessInfo.processInfo.environment["BRAHMA_PERF"] == "1"))
    func stepCostAt300() {
        let c = SyntheticCompany.make(agents: 300)
        var m = MapModel()
        m.apply(MapInputs(agents: c.agents, pack: c.pack, vacancies: c.vacancies, meetings: c.meetings), now: 0)
        var traffic = SyntheticTraffic(seed: 5)
        let clock = SuspendingClock()
        var total = 0.0, worst = 0.0, lastPoll = 0.0
        let steps = 3600
        for step in 0..<steps {
            let t = Double(step) / 60
            if t - lastPoll >= 0.5 {
                m.ingest(traffic.facts(from: mapFixtureEpoch.addingTimeInterval(lastPoll), to: mapFixtureEpoch.addingTimeInterval(t),
                                       agents: c.agents, rate: 50), now: t)
                lastPoll = t
            }
            let d = clock.measure { _ = m.step(now: t, resolve: { $0 }) }
            let ms = Double(d.components.attoseconds) / 1e15 + Double(d.components.seconds) * 1000
            total += ms; worst = max(worst, ms)
        }
        let mean = total / Double(steps)
        print("stepCostAt300: mean \(mean) ms, max \(worst) ms over \(steps) steps; stats \(m.stats)")
        #expect(mean < 0.3)
        #expect(worst < 2)
    }
}
