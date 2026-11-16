import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Final-review I-2: the orientation's "New resources" window starts at the agent's previous turn's START (when that turn's
/// orientation was built), so a library or CLI drop made while a turn runs reaches that agent's next orientation.
@Suite(.scratch) struct NewResourcesWindowTests {
    typealias W = ResourceStoreTests.W

    private func lines(_ w: W, _ a: Agent) throws -> [String] {
        try w.store.newResourceLines(agent: try #require(try w.store.agent(id: a.id)))
    }

    private func refs(_ lines: [String]) -> [String] {
        lines.compactMap { $0.split(separator: " ").dropFirst().first.map(String.init) }
    }

    @Test func dropDuringRunningTurnReachesNextOrientation() throws {
        let w = try W()
        let t0 = Store.now()
        try w.add([try w.file("before.md", "before\n")], ResourceDrop(context: .library), now: t0.addingTimeInterval(5))

        // Turn 1 starts and its orientation is built: it lists what came before.
        let turn1 = try w.store.startTurn(agentId: w.eng1.id, now: t0.addingTimeInterval(10))
        #expect(refs(try lines(w, w.eng1)) == ["F-1"])
        // While it runs, the owner drops from the library and from the CLI.
        try w.add([try w.file("during.md", "during\n")], ResourceDrop(context: .library), now: t0.addingTimeInterval(20))
        try w.add([try w.file("cli.md", "cli\n")], ResourceDrop(context: .cli), now: t0.addingTimeInterval(25))
        _ = try w.store.finishTurn(id: turn1.id, outcome: .succeeded, summary: nil, costUSD: nil, now: t0.addingTimeInterval(30))

        // Turn 2 starts (its own row is running, with no end): both drops are new to it; the earlier one is not.
        let turn2 = try w.store.startTurn(agentId: w.eng1.id, now: t0.addingTimeInterval(40))
        #expect(refs(try lines(w, w.eng1)) == ["F-2", "F-3"])
        let agent = try #require(try w.store.agent(id: w.eng1.id))
        let context = try TurnContext.load(store: w.store, paths: w.paths, agent: agent, company: w.company)
        #expect(refs(context.newResources) == ["F-2", "F-3"])
        #expect(context.newResources.contains { $0.contains("\"during.md\"") && $0.contains("from the owner") })
        let text = TurnDigest.render(context, agent: agent, company: w.company)
        #expect(text.contains("## New resources (2)"), Comment(rawValue: text))

        // A drop made between turn 2's start and its end is listed by turn 3; the earlier ones are not repeated again.
        try w.add([try w.file("late.md", "late\n")], ResourceDrop(context: .cli), now: t0.addingTimeInterval(45))
        _ = try w.store.finishTurn(id: turn2.id, outcome: .succeeded, summary: nil, costUSD: nil, now: t0.addingTimeInterval(50))
        _ = try w.store.startTurn(agentId: w.eng1.id, now: t0.addingTimeInterval(60))
        #expect(refs(try lines(w, w.eng1)) == ["F-4"])
    }

    /// Repetition is the accepted cost: a drop made after a turn started but before it ended can be listed by that turn
    /// (when its orientation was built after the drop) and by the next one. Never a silent miss.
    @Test func windowIsKeyedOnStartNotEnd() throws {
        let w = try W()
        let t0 = Store.now()
        try w.store.writer.write { db in
            try Turn(id: "t-prev", agentId: w.eng2.id, companyId: w.company.id, startedAt: t0.addingTimeInterval(10),
                     endedAt: t0.addingTimeInterval(100), outcome: .succeeded, summary: nil, costUSD: nil).insert(db)
        }
        try w.add([try w.file("at-start.md", "x\n")], now: t0.addingTimeInterval(10))     // when the orientation was built
        try w.add([try w.file("mid.md", "y\n")], now: t0.addingTimeInterval(50))          // while the turn ran
        #expect(refs(try lines(w, w.eng2)) == ["F-2"])
    }
}
