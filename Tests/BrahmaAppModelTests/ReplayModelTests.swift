import Testing
import Foundation
import BrahmaCore
@testable import BrahmaAppModel

/// Plan ML Task 9: the replay timeline in the agent inspector (REPLAY) and the item inspector (HISTORY): the day stepper in the
/// owner's time zone, the kind filter, the bounded transcript pane and the `replay:` launch targets.
@MainActor @Suite(.scratch) struct ReplayModelTests {
    /// 2026-11-16 09:00 in New York (14:00 UTC) plus `seconds`.
    nonisolated static func at(_ seconds: TimeInterval) -> Date { Date(timeIntervalSince1970: 1_794_837_600 + seconds) }

    struct W {
        let app: AppModel, store: Store, paths: BrahmaPaths, acme: Company, eng: Agent
    }

    func world(now: Date = ReplayModelTests.at(6 * 3600)) throws -> W {
        let (store, paths) = try makeHome()
        let (acme, _, _, eng) = try seedAcme(store, paths)
        try store.setOwnerTimeZone("America/New_York")
        return W(app: AppModel(store: store, paths: paths, clock: { now }), store: store, paths: paths, acme: acme, eng: eng)
    }

    @discardableResult
    func turn(_ w: W, at start: Date, summary: String) throws -> Turn {
        let t = try w.store.startTurn(agentId: w.eng.id, now: start)
        try w.store.finishTurn(id: t.id, outcome: .succeeded, summary: summary, costUSD: nil, now: start.addingTimeInterval(60))
        return t
    }

    @Test func replayTargets() {
        #expect(SelectTarget("replay:@eng-1") == .replayAgent(handle: "eng-1", day: nil))
        #expect(SelectTarget("replay:@ENG-1/2026-11-16") == .replayAgent(handle: "eng-1", day: "2026-11-16"))
        #expect(SelectTarget("replay:inite-3") == .replayItem(key: "INITE-3"))
        #expect(SelectTarget("replay:@eng-1/16-11-2026") == nil)
        #expect(SelectTarget("replay:@") == nil)
    }

    @Test func dayStepper() async throws {
        let w = try world()
        let today = try turn(w, at: Self.at(3600), summary: "today's work")
        let yesterday = try turn(w, at: Self.at(-86_400 + 3600), summary: "yesterday's work")
        await w.app.load()
        w.app.apply(.replayAgent(handle: "eng", day: nil))
        #expect(w.app.sidebarSelection == .agents)
        #expect(w.app.selectedAgentId == w.eng.id)
        let replay = try #require(w.app.replay)
        await replay.load()
        #expect(replay.subject == .agentDay(agentId: w.eng.id, day: "2026-11-16"))
        #expect(replay.day == "2026-11-16")
        #expect(replay.entries.compactMap(\.turnId).allSatisfy { $0 == today.id })
        #expect(!replay.entries.isEmpty)
        #expect(!replay.canStepForward, "today is the newest day")

        await replay.stepDay(by: -1)
        #expect(replay.day == "2026-11-15")
        #expect(replay.subject == .agentDay(agentId: w.eng.id, day: "2026-11-15"))
        #expect(replay.entries.compactMap(\.turnId).allSatisfy { $0 == yesterday.id } && !replay.entries.isEmpty)
        #expect(replay.canStepForward)
        await replay.stepDay(by: 1)
        #expect(replay.day == "2026-11-16")
        #expect(replay.entries.contains { $0.turnId == today.id })

        // Steps follow the owner's calendar, across the end of daylight saving time (1 November 2026 in New York).
        let dst = ReplayModel(store: w.store, paths: w.paths, companyId: w.acme.id,
                              subject: .agentDay(agentId: w.eng.id, day: "2026-11-02"), timeZone: w.store.ownerTimeZone(),
                              clock: { Self.at(0) })
        await dst.stepDay(by: -1)
        #expect(dst.day == "2026-11-01")
        await dst.stepDay(by: -1)
        #expect(dst.day == "2026-10-31")

        // A launch target with a day, and the item history.
        w.app.apply(.replayAgent(handle: "eng", day: "2026-11-15"))
        #expect(w.app.replay?.day == "2026-11-15")
        let item = try w.store.createWorkItem(companyId: w.acme.id, by: .owner, draft: WorkItemDraft(type: .task, title: "Streaks"),
                                              now: Self.at(10))
        await w.app.tick(forceSnapshot: true)
        w.app.apply(.replayItem(key: item.key))
        #expect(w.app.sidebarSelection == .backlog && w.app.selectedItemKey == item.key)
        let history = try #require(w.app.replay)
        await history.load()
        #expect(history.subject == .item(itemId: item.id))
        #expect(history.day == nil)
        #expect(history.entries.contains { $0.kind == .itemEvent })
        w.app.closeReplay()
        #expect(w.app.replay == nil)
    }

    @Test func kindFilter() async throws {
        let w = try world()
        try turn(w, at: Self.at(60), summary: "work")
        _ = try MessageRouter(store: w.store).sendDM(companyId: w.acme.id, from: .owner, to: "eng", text: "hello", now: Self.at(30))
        let model = ReplayModel(store: w.store, paths: w.paths, companyId: w.acme.id,
                                subject: .agentDay(agentId: w.eng.id, day: "2026-11-16"), timeZone: w.store.ownerTimeZone(),
                                clock: { Self.at(3600) })
        await model.load()
        #expect(Set(model.entries.map(\.kind)) == [.turn, .message])
        model.kindFilter = .message
        #expect(model.entries.map(\.kind) == [.message])
        #expect(model.entries.first?.text.contains("hello") == true)
        model.kindFilter = .turn
        #expect(model.entries.count == 2 && model.entries.allSatisfy { $0.kind == .turn })
        model.kindFilter = nil
        #expect(model.entries.count == 3)
        #expect(model.allEntries.count == 3)
        #expect(ReplayKind.allCases.map(\.label) == ["TURN", "TOOL", "MESSAGE", "ITEM", "ASK", "HANDBOOK", "MEMORY", "RESOURCE",
                                                      "TRANSCRIPT"])
    }

    @Test func transcriptPaneBounded() async throws {
        let w = try world()
        let source = TranscriptSource(configDir: try tempDir().appending(path: "claude", directoryHint: .isDirectory))
        let sid = UUID().uuidString
        let file = source.projectsDir.appending(path: "-ws/\(sid).jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var text = ""
        for n in 1...2500 {
            text += #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"answer \#(n) \u001b[2J"}]}}"# + "\n"
        }
        try Data(text.utf8).write(to: file)
        let turn = try w.store.startTurn(agentId: w.eng.id, now: Self.at(0))
        let capture = TranscriptCapture(paths: w.paths, source: source, compressor: .gzip)
        guard case .captured = capture.capture(turn: turn, sessionId: sid, store: w.store, now: Self.at(5)) else {
            Issue.record("capture failed"); return
        }
        try w.store.finishTurn(id: turn.id, outcome: .succeeded, summary: "s", costUSD: nil, now: Self.at(10))
        let model = ReplayModel(store: w.store, paths: w.paths, companyId: w.acme.id,
                                subject: .agentDay(agentId: w.eng.id, day: "2026-11-16"), timeZone: w.store.ownerTimeZone(),
                                clock: { Self.at(3600) })
        await model.load()
        let entry = try #require(model.entries.first { $0.kind == .transcript })
        #expect(entry.ref == "transcript:\(turn.id)")
        let shown = await model.openTranscript(turnId: turn.id)
        let lines = shown.split(separator: "\n", omittingEmptySubsequences: false)
        #expect(lines.count <= ReplayModel.transcriptLineCap && lines.count > 1000, "\(lines.count)")
        #expect(shown.contains("answer 1 "))
        #expect(!shown.contains("answer 2500"))
        #expect(!shown.unicodeScalars.contains { $0.value < 0x20 && $0 != "\n" }, "sanitized line by line")
        #expect(model.transcript == shown && model.transcriptTurnId == turn.id && model.transcriptTruncated)
        model.closeTranscript()
        #expect(model.transcript == nil)
        // Another company's turn shows nothing of it.
        let globex = try #require(try w.store.companies().first { $0.name == "Globex" })
        let foreign = ReplayModel(store: w.store, paths: w.paths, companyId: globex.id,
                                  subject: .item(itemId: "none"), timeZone: w.store.ownerTimeZone(), clock: { Self.at(0) })
        let refused = await foreign.openTranscript(turnId: turn.id)
        #expect(!refused.contains("answer"))
        #expect(foreign.error != nil)
    }
}
