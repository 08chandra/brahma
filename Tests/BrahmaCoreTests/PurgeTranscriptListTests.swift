import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Final-review I-3: a purge lists, conservatively, every captured transcript of a turn by an agent in the resource's reader
/// set that ran while it existed (reads of the mirror or the vault through a shell leave no record), besides the reads it
/// tracks. The activity line, the CLI and the app say those transcripts "may" contain it, and `brahma transcript` prints the
/// app pane's purge notice (refs only).
@Suite(.scratch) struct PurgeTranscriptListTests {
    typealias W = ResourceStoreTests.W

    /// A turn of `a` over `[start, end]` (nil: still running), with a captured transcript when `captured`.
    @discardableResult
    private func turn(_ w: W, _ a: Agent, start: Date, end: Date?, captured: Bool = true) throws -> String {
        let id = UUID().uuidString
        try w.store.writer.write { db in
            try Turn(id: id, agentId: a.id, companyId: w.company.id, startedAt: start, endedAt: end,
                     outcome: end == nil ? .inProgress : .succeeded, summary: nil, costUSD: nil).insert(db)
            if captured {
                try TurnTranscript(turnId: id, companyId: w.company.id, agentId: a.id, sessionId: "s-\(id)",
                                   path: "transcripts/\(w.company.id)/\(a.id)/s/\(id).jsonl.gz", byteStart: 0, byteEnd: 10,
                                   codec: "gz", sha: "0", capturedAt: end ?? start).insert(db)
            }
        }
        return id
    }

    private func purge(_ w: W, _ n: Int, now: Date) throws -> PurgeReport {
        try w.store.purgeResource(companyId: w.company.id, number: n, backups: [], contentVault: w.contentVault, paths: w.paths,
                                  now: now)
    }

    @Test func readersTranscriptsWhileItExistedAreListed() throws {
        let w = try W()
        let t0 = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 86_400).rounded(.down))
        let company = try #require(try w.add([try w.file("plan.md", "the MARMOT plan\n")], now: t0).first)
        #expect(company.mirrorPath != nil, "mirrored: agents can cat it")
        try w.add([try w.file("private.md", "eng-1 only\n")], ResourceDrop(scope: .agent(w.eng1.id)), now: t0)

        // eng-1 never recalls either (no tracked read), but its captured turn ran while they existed.
        let eng1 = try turn(w, w.eng1, start: t0.addingTimeInterval(60), end: t0.addingTimeInterval(120))
        let eng2 = try turn(w, w.eng2, start: t0.addingTimeInterval(200), end: t0.addingTimeInterval(300))
        // Started before the add, ended after it: it ran while the file existed.
        let straddle = try turn(w, w.eng3, start: t0.addingTimeInterval(-30), end: t0.addingTimeInterval(30))
        // Still running at the purge.
        let running = try turn(w, w.mgr, start: t0.addingTimeInterval(400), end: nil)
        // Not listed: ended before the add; no transcript; started after the purge.
        try turn(w, w.eng3, start: t0.addingTimeInterval(-200), end: t0.addingTimeInterval(-100))
        try turn(w, w.eng2, start: t0.addingTimeInterval(500), end: t0.addingTimeInterval(600), captured: false)
        let now = t0.addingTimeInterval(3000)
        try turn(w, w.eng1, start: now.addingTimeInterval(10), end: now.addingTimeInterval(20))

        // An agent outside the reader set is not listed: eng-2 can't read eng-1's private file.
        let scoped = try purge(w, 2, now: now)
        #expect(!scoped.transcripts.contains(eng2)); #expect(!scoped.transcripts.contains(straddle))
        #expect(scoped.transcripts.contains(eng1))

        let report = try purge(w, 1, now: now)
        #expect(Set(report.transcripts) == [eng1, eng2, straddle, running])
        #expect(report.transcripts.count == 4)
        #expect(try w.activity().contains {
            $0.kind == .resource && $0.text == "Purged F-1 (0 backups and 4 transcripts made since it was added may still contain it; "
                + "reads through an agent's shell or the mirror are not tracked one by one)"
        })
        // The pane's notice follows from the list: refs only.
        #expect(try Replay.transcriptNotice(store: w.store, companyId: w.company.id, turnId: eng2)
                == Replay.purgedTranscriptNotice + " ([purged F-1])")
        #expect(try Replay.transcriptNotice(store: w.store, companyId: w.company.id, turnId: eng1)
                == Replay.purgedTranscriptNotice + " ([purged F-1], [purged F-2])")
    }

    @Test func trackedReadsStillListedFirst() throws {
        let w = try W()
        let t0 = Date(timeIntervalSince1970: (Date().timeIntervalSince1970 - 3_600).rounded(.down))
        try w.add([try w.file("notes.md", "the OSPREY notes\n")], now: t0)
        // A tracked recall in a captured turn.
        let read = try ResourcePurgeTests.running(w, w.eng1)
        #expect(w.recall(w.eng1, "F-1").contains("OSPREY"))
        try ResourcePurgeTests.captured(w, read, w.eng1)
        try ResourcePurgeTests.endTurn(w, read)
        let other = try turn(w, w.eng2, start: t0.addingTimeInterval(10), end: t0.addingTimeInterval(20))
        let report = try purge(w, 1, now: Store.now())
        #expect(report.transcripts.first == read, "the tracked read leads the list")
        #expect(Set(report.transcripts) == [read, other]); #expect(report.transcripts.count == 2)
    }

    /// `brahma resource purge` says "may", names Claude's own logs, and `brahma transcript` prints the app pane's notice
    /// (on stderr with --raw), never the purged name.
    @Test func cliPrintsTheNotice() throws {
        let home = try OwnerTestHome()
        let paths = ownerPaths(home.url)
        let turnId: String
        do {
            let store = try Store(path: paths.database.path, backupsDir: paths.backupsDir)
            let company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: paths.workspaces)
            let agent = try store.hire(companyId: company.id, name: "eng-1", role: "engineer", model: "sonnet")
            let drops = try tempDir()
            let file = drops.appending(path: "WOMBAT-plan.md")
            try Data("the plan\n".utf8).write(to: file)
            let plan = try ResourceIntake.inspect(urls: [file], knownValues: [], agentAreas: .none)
            _ = try store.addResources(companyId: company.id, plan: plan, drop: ResourceDrop(), contentVault: ContentVault(paths: paths),
                                       secretVault: MemoryVault(), knownValues: [], paths: paths, now: Store.now().addingTimeInterval(-60))
            // A captured turn of a reader, with no tracked read.
            let source = TranscriptSource(configDir: home.url.appending(path: "claude", directoryHint: .isDirectory))
            let capture = TranscriptCapture(paths: paths, source: source, compressor: .gzip)
            let sid = UUID().uuidString
            let log = source.projectsDir.appending(path: "-ws/\(sid).jsonl")
            try FileManager.default.createDirectory(at: log.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((#"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"read it"}]}}"# + "\n").utf8)
                .write(to: log)
            let turn = try store.startTurn(agentId: agent.id)
            guard case .captured = capture.capture(turn: turn, sessionId: sid, store: store) else {
                Issue.record("capture failed"); return
            }
            _ = try store.finishTurn(id: turn.id, outcome: .succeeded, summary: nil, costUSD: nil)
            turnId = turn.id
            try store.close()
        }

        let purged = try runBrahma(["resource", "Acme", "purge", "F-1", "--yes"], home: home.url)
        #expect(purged.status == 0, "\(purged.stderr)")
        #expect(purged.stdout.contains("purged F-1; 0 backups and 1 transcripts made since it was added may still contain it; "
                                       + "reads through an agent's shell or the mirror are not tracked one by one"), "\(purged.stdout)")
        #expect(purged.stdout.contains("transcript of turn \(turnId) may contain purged content"), "\(purged.stdout)")
        #expect(purged.stdout.contains("~/.claude/projects are not scrubbed"), "\(purged.stdout)")
        let list = try runBrahma(["resource", "Acme", "list"], home: home.url)
        #expect(list.stdout.contains("(0 backups and 1 transcripts may still contain it)"), "\(list.stdout)")

        let shown = try runBrahma(["transcript", "Acme", turnId], home: home.url)
        #expect(shown.status == 0, "\(shown.stderr)")
        #expect(shown.stdout.contains(Replay.purgedTranscriptNotice + " ([purged F-1])"), "\(shown.stdout)")
        #expect(shown.stdout.contains("read it"))
        #expect(!shown.stdout.contains("WOMBAT") && !shown.stderr.contains("WOMBAT"))
        let raw = try runBrahma(["transcript", "Acme", turnId, "--raw"], home: home.url)
        #expect(raw.status == 0, "\(raw.stderr)")
        #expect(!raw.stdout.contains(Replay.purgedTranscriptNotice), "stdout stays the stored JSON lines")
        #expect(raw.stderr.contains(Replay.purgedTranscriptNotice + " ([purged F-1])"), "\(raw.stderr)")
        // By handle: the same notice over the same turn.
        let byHandle = try runBrahma(["transcript", "Acme", "@eng-1"], home: home.url)
        #expect(byHandle.stdout.contains(Replay.purgedTranscriptNotice))
    }
}
