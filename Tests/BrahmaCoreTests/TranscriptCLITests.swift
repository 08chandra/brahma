import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Task 13a: `brahma transcript` and `brahma restore --at/--with-files`, run as subprocesses on a throwaway home.
@Suite struct TranscriptCLITests {
    private func iso(_ date: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: date)
    }

    private struct Seeded {
        let home: OwnerTestHome
        let paths: BrahmaPaths
        let turns: [Turn]
        let agentId: String
    }

    /// A home with one company, one agent and three captured turns of one session.
    private func seed() throws -> Seeded {
        let home = try OwnerTestHome()
        let paths = ownerPaths(home.url)
        let store = try Store(path: paths.database.path, backupsDir: paths.backupsDir)
        let company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: paths.workspaces)
        let agent = try store.hire(companyId: company.id, name: "ceo", role: "CEO", model: "sonnet")
        let source = TranscriptSource(configDir: home.url.appending(path: "claude", directoryHint: .isDirectory))
        let capture = TranscriptCapture(paths: paths, source: source, compressor: .gzip)
        let sid = UUID().uuidString
        let file = source.projectsDir.appending(path: "-ws/\(sid).jsonl")
        try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
        var turns: [Turn] = []
        for n in 1...3 {
            let text = n == 1
                ? #"{"type":"user","message":{"role":"user","content":"hello \#(n) \u001b[31mRED"}}"# + "\n"
                : #"{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"answer \#(n)"},{"type":"tool_use","name":"Bash","input":{"command":"ls"}}]}}"# + "\n"
            if let handle = try? FileHandle(forWritingTo: file) {
                try handle.seekToEnd(); try handle.write(contentsOf: Data(text.utf8)); try handle.close()
            } else {
                try Data(text.utf8).write(to: file)
            }
            let turn = try store.startTurn(agentId: agent.id, now: Date(timeIntervalSince1970: 1_781_107_200 + Double(n)))
            guard case .captured = capture.capture(turn: turn, sessionId: sid, store: store) else {
                Issue.record("seed capture failed"); throw CocoaError(.fileReadUnknown)
            }
            turns.append(turn)
        }
        try store.close()
        return Seeded(home: home, paths: paths, turns: turns, agentId: agent.id)
    }

    @Test func transcriptByTurnAndByHandle() throws {
        let s = try seed()
        let byTurn = try runBrahma(["transcript", "acme", s.turns[0].id], home: s.home.url)
        #expect(byTurn.status == 0, "\(byTurn.stderr)")
        #expect(byTurn.stdout.contains("hello 1"))
        #expect(!byTurn.stdout.contains("\u{1b}"), "terminal control characters from agent text are neutralised")
        // A unique prefix of the id works too.
        let prefix = try runBrahma(["transcript", "acme", String(s.turns[1].id.prefix(8))], home: s.home.url)
        #expect(prefix.status == 0 && prefix.stdout.contains("answer 2") && prefix.stdout.contains("Bash"), "\(prefix.stderr)")

        let handle = try runBrahma(["transcript", "acme", "@ceo"], home: s.home.url)
        #expect(handle.status == 0 && handle.stdout.contains("answer 3") && !handle.stdout.contains("answer 2"), "\(handle.stderr)")
        let last2 = try runBrahma(["transcript", "acme", "@ceo", "--last", "2"], home: s.home.url)
        #expect(last2.stdout.contains("answer 2") && last2.stdout.contains("answer 3") && !last2.stdout.contains("hello 1"))
        let raw = try runBrahma(["transcript", "acme", s.turns[1].id, "--raw"], home: s.home.url)
        #expect(raw.stdout.contains(#""type":"assistant""#))
        #expect(try runBrahma(["transcript", "acme", "@nobody"], home: s.home.url).status != 0)
        #expect(try runBrahma(["transcript", "acme", "zzzz"], home: s.home.url).status != 0)
    }

    @Test func transcriptIsReadOnlyAndOwnerOnly() throws {
        let s = try seed()
        // The transcript files and every other file of the data home are untouched (the database, run/ and tmp/ are the engine's own).
        func tree() throws -> [String] { try snapshotOfTree(s.paths.home).filter { !$0.hasPrefix("brahma.sqlite") && !$0.hasPrefix("tmp") && !$0.hasPrefix("run") } }
        let before = try tree()
        let shown = try runBrahma(["transcript", "acme", "@ceo", "--last", "3"], home: s.home.url)
        #expect(shown.status == 0, "\(shown.stderr)")
        #expect(try tree() == before)
        let agent = try runBrahma(["transcript", "acme", "@ceo"], home: s.home.url, extra: ["BRAHMA_AGENT_ID": s.agentId])
        #expect(agent.status != 0 && agent.stderr.contains("owner commands"))
        let noOwner = try OwnerTestHome(initOwner: false)
        #expect(try runBrahma(["transcript", "acme", "@ceo"], home: noOwner.url).status != 0)
    }

    @Test func restoreAtPicksTheNewestSnapshotAtOrBefore() throws {
        let home = try OwnerTestHome()
        let paths = ownerPaths(home.url)
        let start = Date(timeIntervalSince1970: 1_781_107_200)
        let store = try Store(path: paths.database.path, backupsDir: paths.backupsDir)
        _ = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: paths.workspaces)
        var service = BackupService(paths: paths, writer: store.writer)
        let clock = StepClock(start)
        service.now = { clock.next() }
        let urls = try (0..<3).map { _ in try service.snapshot(reason: .manual) }
        try store.close()

        let at = try runBrahma(["restore", "--at", iso(start.addingTimeInterval(1.5)), "--dry-run"], home: home.url)
        #expect(at.status == 0, "\(at.stderr)")
        #expect(at.stdout.contains("would restore \(urls[1].lastPathComponent)"), "\(at.stdout)")
        let exact = try runBrahma(["restore", "--at", iso(start.addingTimeInterval(2)), "--dry-run"], home: home.url)
        #expect(exact.stdout.contains("would restore \(urls[2].lastPathComponent)"))
        let tooEarly = try runBrahma(["restore", "--at", iso(start.addingTimeInterval(-60)), "--dry-run"], home: home.url)
        #expect(tooEarly.status != 0)
        #expect(try runBrahma(["restore", "--at", "yesterday-ish", "--dry-run"], home: home.url).status != 0)
        #expect(try runBrahma(["restore", "--at", iso(start), "--latest", "--dry-run"], home: home.url).status != 0)

        // --with-files names the data-home snapshot it would bring back, or refuses when there is none.
        let none = try runBrahma(["restore", "--at", iso(start.addingTimeInterval(1.5)), "--with-files", "--dry-run"], home: home.url)
        #expect(none.status != 0 && none.stderr.contains("data-home snapshot"), "\(none.stderr)")
        try Data("memo".utf8).write(to: paths.home.appending(path: "notes.md"))
        let info = try HomeSnapshot.take(paths: paths, now: start.addingTimeInterval(0.5)).info
        let with = try runBrahma(["restore", "--at", iso(start.addingTimeInterval(1.5)), "--with-files", "--dry-run"], home: home.url)
        #expect(with.status == 0 && with.stdout.contains(info.url.lastPathComponent), "\(with.stdout) \(with.stderr)")
    }

    /// m6 (13a fix round 1): a real `restore --with-files` (not only `--dry-run`) names the data-home snapshot it put back and
    /// how much older than the database snapshot it is, and reports an entry it refused.
    @Test func restoreWithFilesNamesTheHomeSnapshotAndItsAge() throws {
        let home = try OwnerTestHome()
        let paths = ownerPaths(home.url)
        let start = Date(timeIntervalSince1970: 1_781_107_200)
        let store = try Store(path: paths.database.path, backupsDir: paths.backupsDir)
        _ = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: paths.workspaces)
        var service = BackupService(paths: paths, writer: store.writer)
        service.now = { start }
        _ = try service.snapshot(reason: .manual)
        try store.close()
        let notes = paths.home.appending(path: "notes/today.md")
        try FileManager.default.createDirectory(at: notes.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("v1".utf8).write(to: notes)
        try FileManager.default.createDirectory(at: paths.home.appending(path: "linked"), withIntermediateDirectories: true)
        try Data("l1".utf8).write(to: paths.home.appending(path: "linked/file.md"))
        let info = try HomeSnapshot.take(paths: paths, now: start.addingTimeInterval(-(5 * 3600 + 7 * 60))).info
        try Data("v2".utf8).write(to: notes)
        let outside = home.url.appending(path: "outside-target", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.removeItem(at: paths.home.appending(path: "linked"))
        try FileManager.default.createSymbolicLink(at: paths.home.appending(path: "linked"), withDestinationURL: outside)

        let run = try runBrahma(["restore", "--at", iso(start.addingTimeInterval(1)), "--with-files"], home: home.url)
        #expect(run.status == 0, "\(run.stdout) \(run.stderr)")
        #expect(run.stdout.contains("files from \(info.name)"), "\(run.stdout)")
        #expect(run.stdout.components(separatedBy: ": 1 restored").count == 2 && !run.stdout.contains("files restored"), "\(run.stdout)")
        #expect(run.stdout.contains("5h 7m before the database snapshot"), "\(run.stdout)")
        #expect(run.stdout.contains("warning: not restored: linked/file.md"), "\(run.stdout)")
        #expect(try String(contentsOf: notes, encoding: .utf8) == "v1")
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).isEmpty)
    }
}
