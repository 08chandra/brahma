import Foundation
import Testing
import BrahmaCore
@testable import BrahmaAppModel

@MainActor @Suite(.scratch) struct TurnStreamTests {
    static func ev(_ id: Int64, agent: String = "a1", turn: String? = "t1", _ kind: ActivityKind = .toolUse, _ text: String = "x") -> ActivityEvent {
        var e = ActivityEvent(companyId: "c", agentId: agent, turnId: turn, kind: kind, text: text,
                              createdAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(id)))
        e.id = id
        return e
    }

    @Test func filtersToOneAgent() {
        let events = [Self.ev(1, .turnStarted), Self.ev(2, agent: "a2", .toolUse, "other"), Self.ev(3, .message, "hi"),
                      Self.ev(4, turn: "t0", .toolUse), Self.ev(5, .stateChanged), Self.ev(6, .turnFinished)]
        let lines = TurnStream.lines(events: events, agentId: "a1", turnId: "t1", timeZone: TimeZone(identifier: "UTC")!)
        #expect(lines.map(\.id) == [1, 3, 6])
        #expect(lines.first?.time == "08:00:01")
        #expect(TurnStream.lines(events: events, agentId: "a1", turnId: nil).isEmpty)
    }

    @Test func capsAt200() {
        let events = (1...250).map { Self.ev(Int64($0)) }.reversed()
        let lines = TurnStream.lines(events: Array(events), agentId: "a1", turnId: "t1")
        #expect(lines.count == TurnStream.maxLines && TurnStream.maxLines == 200)
        #expect(lines.first?.id == 51 && lines.last?.id == 250)
    }

    @Test func agentTextVerbatim() {
        let hostile = "**bold** <script>alert(1)</script> \u{1B}[31m [x](javascript:1)"
        let lines = TurnStream.lines(events: [Self.ev(1, .message, hostile)], agentId: "a1", turnId: "t1")
        #expect(lines.first?.text == hostile)
    }

    @Test func runningTurnElseLatest() async throws {
        let w = try await WorkWorld.make()
        let t0 = Date()
        let done = try w.store.startTurn(agentId: w.eng.id, now: t0.addingTimeInterval(-60))
        _ = try w.store.finishTurn(id: done.id, outcome: .succeeded, summary: "ok", costUSD: nil, now: t0.addingTimeInterval(-30))
        try await w.store.writer.write { db in
            try ActivityEvent(companyId: w.company.id, agentId: w.eng.id, turnId: done.id, kind: .message, text: "finished work",
                              createdAt: t0.addingTimeInterval(-40)).insert(db)
        }
        w.model.observeTurnStream(agentId: w.eng.id)
        await w.model.refreshTurnStream()
        var s = w.model.turnStream(agentId: w.eng.id)
        #expect(s.turnId == done.id && !s.running && s.lines.map(\.text) == ["finished work"])

        let running = try w.store.startTurn(agentId: w.eng.id, now: t0)
        try await w.store.writer.write { db in
            try ActivityEvent(companyId: w.company.id, agentId: w.eng.id, turnId: running.id, kind: .toolUse, text: "Read a.swift",
                              createdAt: t0).insert(db)
        }
        await w.model.tick(forceSnapshot: true)
        s = w.model.turnStream(agentId: w.eng.id)
        #expect(s.turnId == running.id && s.running && s.lines.map(\.text) == ["Read a.swift"])
        // Another agent's stream is not loaded.
        #expect(w.model.turnStream(agentId: w.cto.id).lines.isEmpty)
        w.model.stopObservingTurnStream()
        #expect(w.model.turnStream(agentId: w.eng.id).lines.isEmpty)
    }
}
