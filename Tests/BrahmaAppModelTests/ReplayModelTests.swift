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
        #expect(foreign.transcript == nil && foreign.transcriptTurnId == turn.id)
        #expect(foreign.transcriptError == "no transcript was captured for that turn")
        #expect(foreign.error == nil, "the pane carries its own error")
    }

    /// Captures a one-record transcript for a new turn of @eng and returns the turn and the captured row.
    func captured(_ w: W, at start: Date, text: String) throws -> (Turn, TurnTranscript) {
        let source = TranscriptSource(configDir: try tempDir().appending(path: "claude", directoryHint: .isDirectory))
        let sid = UUID().uuidString
        let file = source.projectsDir.appending(path: "-ws/\(sid).jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data((#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"\#(text)"}]}}"# + "\n").utf8)
            .write(to: file)
        let turn = try w.store.startTurn(agentId: w.eng.id, now: start)
        let capture = TranscriptCapture(paths: w.paths, source: source, compressor: .gzip)
        guard case .captured = capture.capture(turn: turn, sessionId: sid, store: w.store, now: start.addingTimeInterval(5)) else {
            throw WorkError.invalid("capture failed")
        }
        try w.store.finishTurn(id: turn.id, outcome: .succeeded, summary: "s", costUSD: nil, now: start.addingTimeInterval(10))
        return (turn, try #require(try w.store.transcript(turnId: turn.id)))
    }

    /// Fix round 1 (review Important 1): a transcript that can't be read opens the pane with the reason, even though the
    /// timeline has lines (a hash mismatch is a tamper signal; a missing or corrupt file is a loss).
    @Test func failedTranscriptOpenShowsPaneError() async throws {
        let w = try world()
        let (turn, row) = try captured(w, at: Self.at(0), text: "the real answer")
        let model = ReplayModel(store: w.store, paths: w.paths, companyId: w.acme.id,
                                subject: .agentDay(agentId: w.eng.id, day: "2026-11-16"), timeZone: w.store.ownerTimeZone(),
                                clock: { Self.at(3600) })
        await model.load()
        #expect(model.entries.contains { $0.kind == .transcript }, "the timeline is not empty")
        let file = w.paths.home.appending(path: row.path)

        // Tampered: valid gzip of other bytes.
        let other = try Compressor.gzip.compress(Data("{\"type\":\"assistant\"}\n".utf8), workDir: w.paths.tmpDir)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
        try other.write(to: file)
        #expect(await model.openTranscript(turnId: turn.id) == "")
        #expect(model.transcriptTurnId == turn.id, "the pane opens")
        #expect(model.transcript == nil && !model.transcriptTruncated && model.transcriptNotice == nil)
        #expect(model.transcriptError?.contains("does not match its recorded hash") == true, "\(model.transcriptError ?? "nil")")
        #expect(model.error == nil)

        // Corrupt: not gzip at all.
        try Data("not a gzip stream".utf8).write(to: file)
        await model.openTranscript(turnId: turn.id)
        #expect(model.transcriptTurnId == turn.id && model.transcript == nil)
        #expect(model.transcriptError != nil)

        // Missing.
        try FileManager.default.removeItem(at: file)
        await model.openTranscript(turnId: turn.id)
        #expect(model.transcriptTurnId == turn.id && model.transcript == nil)
        #expect(model.transcriptError != nil)

        // Closing clears it; a good transcript clears an earlier error.
        model.closeTranscript()
        #expect(model.transcriptTurnId == nil && model.transcriptError == nil)
        let (good, _) = try captured(w, at: Self.at(600), text: "a good answer")
        await model.openTranscript(turnId: turn.id)
        #expect(model.transcriptError != nil)
        #expect(await model.openTranscript(turnId: good.id).contains("a good answer"))
        #expect(model.transcriptError == nil && model.transcriptTurnId == good.id)
    }

    /// Fix round 1 (controller ruling): a transcript a purge report lists opens with a notice that it may still hold the purged
    /// content, naming the resource by its ref only.
    @Test func purgeFlaggedTranscriptShowsNotice() async throws {
        let w = try world()
        let (flagged, _) = try captured(w, at: Self.at(0), text: "I read the plan")
        let (clean, _) = try captured(w, at: Self.at(600), text: "nothing purged here")
        let report = String(decoding: try JSONEncoder().encode(PurgeReport(backups: [], transcripts: [flagged.id])), as: UTF8.self)
        try await w.store.writer.write { db in
            try Resource(companyId: w.acme.id, number: 7, kind: .file, displayName: "SECRETPLANNAME.md", scopeKind: "company",
                         scopeId: nil, readerSet: nil, provenance: "owner", tainted: false, addedVia: "library",
                         purgedAt: Self.at(900), purgeReport: report, createdAt: Self.at(-60), updatedAt: Self.at(900)).insert(db)
        }
        let model = ReplayModel(store: w.store, paths: w.paths, companyId: w.acme.id,
                                subject: .agentDay(agentId: w.eng.id, day: "2026-11-16"), timeZone: w.store.ownerTimeZone(),
                                clock: { Self.at(3600) })
        #expect(await model.openTranscript(turnId: flagged.id).contains("I read the plan"))
        let notice = try #require(model.transcriptNotice)
        #expect(notice == Replay.purgedTranscriptNotice + " ([purged F-7])")
        #expect(notice == "This transcript was captured while a since-purged resource existed; it may still contain that content. ([purged F-7])")
        #expect(!notice.contains("SECRETPLANNAME"))
        #expect(model.transcriptError == nil)

        #expect(await model.openTranscript(turnId: clean.id).contains("nothing purged here"))
        #expect(model.transcriptNotice == nil, "a transcript no purge report lists has no notice")
        model.closeTranscript()
        #expect(model.transcriptNotice == nil)
    }
}
