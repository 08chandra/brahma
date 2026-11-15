import Testing
import Foundation
import GRDB
@testable import BrahmaCore
@testable import BrahmaAppModel

@Suite(.scratch) struct MapTimelineTests {
    let end = mapFixtureEpoch

    func at(_ seconds: TimeInterval) -> Date { end.addingTimeInterval(seconds) }
    var start: Date { at(-MapTimeline.window) }

    func agent(_ id: String, state: AgentState, createdAt: Date? = nil) -> Agent {
        Agent(id: id, companyId: "c", name: id, role: "engineer", model: "sonnet", sessionId: "s-\(id)", sessionStarted: false,
              state: state, blocker: nil, requestedBlocker: nil, paused: false, readySince: nil,
              createdAt: createdAt ?? at(-7200))
    }

    func change(_ id: String, _ from: AgentState, _ to: AgentState, _ seconds: TimeInterval) -> MapFact {
        .stateChanged(agentId: id, from: from, to: to, at: at(seconds))
    }

    func flow(_ id: Int64, from: String, to: [String], _ seconds: TimeInterval) -> MessageFlow {
        MessageFlow(rowId: id, messageId: "m\(id)", companyId: "c", senderId: from, channelId: "ch", channelName: "general",
                    channelKind: .channel, kind: "text", recipientIds: to, team: nil, createdAt: at(seconds))
    }

    @Test func rewindStates() {
        let eng = agent("eng", state: .running)
        let tl = MapTimeline.build(current: [eng], facts: [
            change("eng", .ready, .running, -600),
            change("eng", .sleeping, .ready, -1200),
        ], start: start, end: end, truncated: false)
        #expect(tl.agents(at: at(0))[0].state == .running)
        #expect(tl.agents(at: at(-900))[0].state == .ready)
        #expect(tl.agents(at: at(-1800))[0].state == .sleeping)
    }

    @Test func hiredMidWindowHidden() {
        let new = agent("new", state: .ready, createdAt: at(-300))
        let old = agent("old", state: .ready)
        let tl = MapTimeline.build(current: [old, new], facts: [.hired(agentId: "new", at: at(-300))], start: start, end: end, truncated: false)
        #expect(tl.agents(at: at(-600)).map(\.id) == ["old"])
        #expect(tl.agents(at: at(-60)).map(\.id) == ["old", "new"])
    }

    @Test func killedMidWindowShownBefore() {
        let eng = agent("eng", state: .killed)
        let tl = MapTimeline.build(current: [eng], facts: [change("eng", .running, .killed, -300)], start: start, end: end, truncated: false)
        #expect(tl.agents(at: at(-600))[0].state == .running)
        #expect(tl.agents(at: at(-60))[0].state == .killed)
    }

    @Test func pausedManagerAndTeamKeepCurrentValues() {
        var eng = agent("eng", state: .running)
        eng.paused = true; eng.managerId = "boss"; eng.team = "core"
        let tl = MapTimeline.build(current: [eng], facts: [change("eng", .ready, .running, -600)], start: start, end: end, truncated: false)
        let past = tl.agents(at: at(-900))[0]
        #expect(past.state == .ready)
        #expect(past.paused && past.managerId == "boss" && past.team == "core")
    }

    @Test func recoveredTextParsesAndJunkSkipped() throws {
        let (store, _) = try makeHome()
        let company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        let eng = try store.hire(companyId: company.id, name: "eng", role: "engineer", model: "sonnet")
        let now = Store.now()
        try store.writer.write { db in
            for (text, offset) in [("running -> ready (recovered)", -120.0), ("garbage", -100), ("ready -> exploded", -90), ("sleeping -> running", -60)] {
                try ActivityEvent(companyId: company.id, agentId: eng.id, turnId: nil, kind: .stateChanged, text: text,
                                  createdAt: now.addingTimeInterval(offset)).insert(db)
            }
        }
        let tl = try MapHistory.load(store: store, companyId: company.id, end: now, current: [eng])
        let changes = tl.facts.compactMap { fact -> (AgentState, AgentState)? in
            if case let .stateChanged(_, from, to, _) = fact { return (from, to) }
            return nil
        }
        #expect(changes.count == 2)
        #expect(changes[0] == (.running, .ready))
        #expect(changes[1] == (.sleeping, .running))
        #expect(!tl.truncated)
        #expect(tl.start == now.addingTimeInterval(-MapTimeline.window) && tl.end == now)
    }

    @Test func loadReadsMessagesHandoffsAndHires() throws {
        let (store, _) = try makeHome()
        let company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        let now = Store.now()
        let ceo = try store.hire(companyId: company.id, name: "ceo", role: "ceo", model: "sonnet")
        let cto = try store.hire(companyId: company.id, name: "cto", role: "cto", model: "sonnet")
        let router = MessageRouter(store: store)
        _ = try router.post(companyId: company.id, channel: "general", from: .agent(ceo.id), text: "@cto hi", now: now.addingTimeInterval(-500))
        _ = try router.post(companyId: company.id, channel: "general", from: .agent(ceo.id), text: "too old", now: now.addingTimeInterval(-4000))
        let item = try store.createWorkItem(companyId: company.id, by: .owner, draft: WorkItemDraft(type: .task, title: "Parse", status: .ready), now: now.addingTimeInterval(-400))
        _ = try store.writeHandoff(itemId: item.id, by: .owner, draft: HandoffDraft(goal: "Finish", toAgentId: cto.id), now: now.addingTimeInterval(-300))
        // `hire` stamps createdAt with the wall clock; make the window cover it.
        let tl = try MapHistory.load(store: store, companyId: company.id, end: Store.now().addingTimeInterval(1), current: [ceo, cto])
        var kinds: [String] = []
        for f in tl.facts {
            switch f {
            case .message: kinds.append("message")
            case .handoff: kinds.append("handoff")
            case .hired: kinds.append("hired")
            case .stateChanged: kinds.append("state")
            }
        }
        #expect(kinds.filter { $0 == "message" }.count == 1)
        #expect(kinds.filter { $0 == "handoff" }.count == 1)
        #expect(kinds.filter { $0 == "hired" }.count == 2)
        #expect(zip(tl.facts, tl.facts.dropFirst()).allSatisfy { $0.at <= $1.at })
    }

    /// Final review I5: past the limit the newest messages are kept, the flag is set and the window starts at the first
    /// message kept, so the end of the hour (the part the owner most likely wants) is complete.
    @Test func truncatedFlag() throws {
        let (store, _) = try makeHome()
        let company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        let ceo = try store.hire(companyId: company.id, name: "ceo", role: "ceo", model: "sonnet")
        let now = Store.now()
        let channelId: String = try store.writer.read { db in
            try String.fetchOne(db, sql: "SELECT id FROM channel WHERE companyId = ? LIMIT 1", arguments: [company.id])!
        }
        // 20 001 messages, one every 0.1 s, the newest 1 s before the end.
        let first = now.addingTimeInterval(-2001)
        try store.writer.write { db in
            for i in 0..<20_001 {
                try db.execute(sql: "INSERT INTO message (id, companyId, channelId, senderId, text, createdAt, taintedOrigin) VALUES (?, ?, ?, ?, 'x', ?, 0)",
                               arguments: ["m\(i)", company.id, channelId, ceo.id, first.addingTimeInterval(Double(i) / 10)])
            }
        }
        let tl = try MapHistory.load(store: store, companyId: company.id, end: now, current: [ceo])
        #expect(tl.truncated)
        let ids = tl.facts.compactMap { fact -> String? in
            if case .message(let m) = fact { return m.messageId }
            return nil
        }
        #expect(ids.count == 20_000)
        #expect(ids.first == "m1" && ids.last == "m20000", "the oldest is cut, the newest kept")
        #expect(abs(tl.start.timeIntervalSince(first.addingTimeInterval(0.1))) < 0.002, "\(tl.start)")
        #expect(tl.end == now)
    }

    /// Final review I5 (and Task 6's deferred minor): state changes past the limit keep the newest too, mark the timeline
    /// truncated, and the window starts where the kept changes start, so every state shown in it is rewound correctly.
    @Test func stateChangeOverflowKeepsTheNewestAndCutsTheStart() throws {
        let (store, _) = try makeHome()
        let company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        var eng = try store.hire(companyId: company.id, name: "eng", role: "engineer", model: "sonnet")
        let now = Store.now()
        eng.createdAt = now.addingTimeInterval(-7200)
        // ready → running → blocked → sleeping → running, one a minute; the agent is running now.
        let steps: [(AgentState, AgentState, TimeInterval)] = [
            (.ready, .running, -600), (.running, .blocked, -540), (.blocked, .sleeping, -480), (.sleeping, .running, -420),
        ]
        try store.writer.write { db in
            for (from, to, offset) in steps {
                try ActivityEvent(companyId: company.id, agentId: eng.id, turnId: nil, kind: .stateChanged,
                                  text: "\(from.rawValue) -> \(to.rawValue)", createdAt: now.addingTimeInterval(offset)).insert(db)
            }
        }
        eng.state = .running
        let tl = try MapHistory.load(store: store, companyId: company.id, end: now, current: [eng], limit: 2)
        #expect(tl.truncated)
        let kept = tl.facts.compactMap { fact -> Date? in
            if case .stateChanged(_, _, _, let at) = fact { return at }
            return nil
        }
        #expect(kept == [now.addingTimeInterval(-480), now.addingTimeInterval(-420)], "the newest two")
        #expect(tl.start == now.addingTimeInterval(-480))
        #expect(tl.agents(at: tl.start).first?.state == .sleeping)
        #expect(tl.agents(at: now.addingTimeInterval(-450)).first?.state == .sleeping)
        #expect(tl.agents(at: tl.end).first?.state == .running)

        let whole = try MapHistory.load(store: store, companyId: company.id, end: now, current: [eng], limit: 4)
        #expect(!whole.truncated)
        #expect(whole.start == now.addingTimeInterval(-MapTimeline.window))
        #expect(whole.agents(at: now.addingTimeInterval(-570)).first?.state == .running)
    }

    @Test func emptyHourIsCurrentState() {
        let current = [agent("a", state: .ready), agent("b", state: .blocked)]
        let tl = MapTimeline.build(current: current, facts: [], start: start, end: end, truncated: false)
        #expect(tl.agents(at: tl.start) == current)
        #expect(tl.edgeWeights(at: end).isEmpty)
    }

    @Test func factsSliceAndWeights() {
        let m1 = flow(1, from: "a", to: ["b"], -60)
        let m2 = flow(2, from: "b", to: ["a", "owner"], -120)
        let old = flow(3, from: "a", to: ["b"], -400)
        let tl = MapTimeline.build(current: [], facts: [.message(m1), .message(old), .message(m2)], start: start, end: end, truncated: false)
        // Sorted by time, stable.
        #expect(tl.facts.map(\.at) == [at(-400), at(-120), at(-60)])
        // (a, b] slicing.
        #expect(tl.facts(after: at(-400), through: at(-60)).count == 2)
        #expect(tl.facts(after: at(-401), through: at(-400)).count == 1)
        #expect(tl.facts(after: at(-60), through: at(0)).isEmpty)
        #expect(tl.facts(after: at(0), through: at(-100)).isEmpty)
        // Weights: m1 is one half-life old, m2 two, the 400 s old one is outside 300 s.
        let w = tl.edgeWeights(at: end)
        #expect(abs((w[EdgeKey(.agent("a"), .agent("b"))] ?? 0) - (0.5 + 0.25)) < 1e-9)
        #expect(abs((w[EdgeKey(.agent("b"), .owner)] ?? 0) - 0.25) < 1e-9)
        #expect(w.count == 2)
        // A message after t does not count; one exactly 300 s old does.
        let edge = MapTimeline.build(current: [], facts: [.message(flow(4, from: "a", to: ["b"], -300)), .message(flow(5, from: "a", to: ["b"], 10))],
                                     start: start, end: end, truncated: false)
        #expect(abs((edge.edgeWeights(at: end)[EdgeKey(.agent("b"), .agent("a"))] ?? 0) - pow(0.5, 5)) < 1e-9)
    }
}
