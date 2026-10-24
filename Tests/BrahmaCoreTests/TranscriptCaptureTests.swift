import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Task 13a: per-turn transcript capture. The source directory is always a temp dir: the owner's real `~/.claude` is never read.
@Suite struct TranscriptCaptureTests {
    static let zstdPath: String? = Compressor.findZstd()

    struct Rig {
        let root: URL
        let paths: BrahmaPaths
        let store: Store
        let source: TranscriptSource
        let company: Company
        let agent: Agent
        let capture: TranscriptCapture

        init(compressor: Compressor = .gzip) throws {
            root = try tempDir()
            paths = ownerPaths(root)
            try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
            store = try Store.inMemory()
            source = TranscriptSource(configDir: root.appending(path: "claude", directoryHint: .isDirectory))
            company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: paths.workspaces)
            agent = try store.hire(companyId: company.id, name: "ceo", role: "CEO", model: "sonnet")
            capture = TranscriptCapture(paths: paths, source: source, compressor: compressor)
        }

        func file(_ sessionId: String, project: String = "-work-acme") -> URL {
            source.projectsDir.appending(path: "\(project)/\(sessionId).jsonl")
        }

        func write(_ sessionId: String, _ text: String, append: Bool = false, project: String = "-work-acme") throws {
            let url = file(sessionId, project: project)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if append, let handle = try? FileHandle(forWritingTo: url) {
                defer { try? handle.close() }
                try handle.seekToEnd()
                try handle.write(contentsOf: Data(text.utf8))
            } else {
                try Data(text.utf8).write(to: url)
            }
        }

        func turn() throws -> Turn { try store.startTurn(agentId: agent.id) }

        func row(_ turn: Turn) throws -> TurnTranscript? { try store.transcript(turnId: turn.id) }

        func activity() throws -> [String] {
            try store.events(afterId: 0, limit: 500).filter { $0.companyId == company.id }.map(\.text)
        }

        func content(_ row: TurnTranscript) throws -> String { String(decoding: try capture.read(row), as: UTF8.self) }
    }

    static func line(_ n: Int) -> String { #"{"type":"user","n":\#(n),"message":{"content":"hello \#(n)"}}"# + "\n" }

    @Test func capturesNewSessionWholeFile() throws {
        let rig = try Rig()
        let sid = UUID().uuidString
        try rig.write(sid, Self.line(1) + Self.line(2))
        let turn = try rig.turn()
        let outcome = rig.capture.capture(turn: turn, sessionId: sid, store: rig.store, now: Date(timeIntervalSince1970: 1_781_107_200))
        guard case .captured(let row) = outcome else { Issue.record("not captured: \(outcome)"); return }
        #expect(row.byteStart == 0)
        #expect(row.byteEnd == Int64((Self.line(1) + Self.line(2)).utf8.count))
        #expect(row.codec == "gz")
        #expect(row.sessionId == sid && row.companyId == rig.company.id && row.agentId == rig.agent.id)
        #expect(row.path == "transcripts/\(rig.company.id)/\(rig.agent.id)/\(sid)/\(turn.id).jsonl.gz")
        #expect(try rig.content(row) == Self.line(1) + Self.line(2))
        let stored = rig.paths.home.appending(path: row.path)
        var st = stat()
        #expect(stat(stored.path, &st) == 0 && st.st_mode & 0o777 == 0o600)
        #expect(try rig.row(turn) == row)
    }

    @Test func resumedSessionCapturesOnlyAppended() throws {
        let rig = try Rig()
        let sid = UUID().uuidString
        try rig.write(sid, Self.line(1))
        let t1 = try rig.turn()
        _ = rig.capture.capture(turn: t1, sessionId: sid, store: rig.store)
        try rig.write(sid, Self.line(2) + Self.line(3), append: true)
        let t2 = try rig.turn()
        guard case .captured(let second) = rig.capture.capture(turn: t2, sessionId: sid, store: rig.store) else {
            Issue.record("second turn not captured"); return
        }
        #expect(second.byteStart == Int64(Self.line(1).utf8.count))
        #expect(try rig.content(second) == Self.line(2) + Self.line(3))
        let first = try #require(try rig.row(t1))
        #expect(try rig.content(first) == Self.line(1))
        // Nothing appended since: no row.
        let t3 = try rig.turn()
        #expect(rig.capture.capture(turn: t3, sessionId: sid, store: rig.store) == .nothingNew)
        #expect(try rig.row(t3) == nil)
    }

    @Test func partialLastLineDeferred() throws {
        let rig = try Rig()
        let sid = UUID().uuidString
        let partial = #"{"type":"assistant","n":2,"mess"#
        try rig.write(sid, Self.line(1) + partial)
        let t1 = try rig.turn()
        guard case .captured(let first) = rig.capture.capture(turn: t1, sessionId: sid, store: rig.store) else {
            Issue.record("not captured"); return
        }
        #expect(first.byteEnd == Int64(Self.line(1).utf8.count))            // up to the last newline
        #expect(try rig.content(first) == Self.line(1))
        // The writer finishes the line; the next turn picks it up whole.
        try rig.write(sid, #"age":{"content":"x"}}"# + "\n", append: true)
        let t2 = try rig.turn()
        guard case .captured(let second) = rig.capture.capture(turn: t2, sessionId: sid, store: rig.store) else {
            Issue.record("second not captured"); return
        }
        #expect(second.byteStart == first.byteEnd)
        #expect(try rig.content(second) == partial + #"age":{"content":"x"}}"# + "\n")
        // Only a partial line in the file: nothing to capture, nothing lost.
        let other = UUID().uuidString
        try rig.write(other, partial)
        #expect(rig.capture.capture(turn: try rig.turn(), sessionId: other, store: rig.store) == .nothingNew)
    }

    @Test func truncatedFileResetsToZero() throws {
        let rig = try Rig()
        let sid = UUID().uuidString
        try rig.write(sid, Self.line(1) + Self.line(2) + Self.line(3))
        _ = rig.capture.capture(turn: try rig.turn(), sessionId: sid, store: rig.store)
        // The file was rotated: now shorter than the stored byteEnd.
        try rig.write(sid, Self.line(9))
        let t2 = try rig.turn()
        guard case .captured(let row) = rig.capture.capture(turn: t2, sessionId: sid, store: rig.store) else {
            Issue.record("not captured"); return
        }
        #expect(row.byteStart == 0)
        #expect(try rig.content(row) == Self.line(9))
        #expect(try rig.activity().contains("transcript for session \(sid) was truncated or rotated; captured from the start"))
    }

    @Test func secretsRedactedInDecodedJSON() throws {
        let rig = try Rig()
        // A value whose quote and slash are JSON-escaped on disk, and that also appears (escaped again) inside a tool_result string.
        let value = #"pa"ss/word-1234567890"#
        rig.store.redactor.update([("STRIPE_KEY", value)], version: "1:x")
        let sid = UUID().uuidString
        let escapedOnDisk = #"pa\"ss\/word-1234567890"#
        let inner = #"{\"k\":\"pa\\\"ss\/word-1234567890\"}"#
        let line = #"{"type":"user","message":{"content":[{"type":"tool_result","content":"\#(inner)"},{"type":"text","text":"key \#(escapedOnDisk) end"}]},"big":12345678901234567}"# + "\n"
        let clean = Self.line(7)
        try rig.write(sid, line + clean)
        guard case .captured(let row) = rig.capture.capture(turn: try rig.turn(), sessionId: sid, store: rig.store) else {
            Issue.record("not captured"); return
        }
        let text = try rig.content(row)
        #expect(!text.contains("ss/word-1234567890") && !text.contains(#"ss\/word-1234567890"#))
        #expect(!text.contains(value))
        #expect(text.contains("[redacted STRIPE_KEY]"))
        // Every line still parses, and a line with nothing to redact is kept byte for byte.
        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        #expect(lines.count == 2)
        for l in lines { _ = try JSONSerialization.jsonObject(with: Data(l.utf8)) }
        #expect(String(lines[1]) + "\n" == clean)
        // The stored file holds no plain value either (compressed or not).
        let stored = try Data(contentsOf: rig.paths.home.appending(path: row.path))
        #expect(stored.range(of: Data(value.utf8)) == nil)
    }

    @Test func linesThatDoNotParseAreRedactedAsRawText() throws {
        let rig = try Rig()
        rig.store.redactor.update([("TOKEN_X", "tok-abcdefgh12345")], version: "1:x")
        let sid = UUID().uuidString
        try rig.write(sid, "not json tok-abcdefgh12345 tail\n" + Self.line(1))
        guard case .captured(let row) = rig.capture.capture(turn: try rig.turn(), sessionId: sid, store: rig.store) else {
            Issue.record("not captured"); return
        }
        #expect(try rig.content(row) == "not json [redacted TOKEN_X] tail\n" + Self.line(1))
    }

    @Test func heldRedactorWritesNothingAndLogsOnce() throws {
        let rig = try Rig()
        let sid = UUID().uuidString
        try rig.write(sid, Self.line(1))
        rig.store.redactor.install(loaded: [:], failed: ["STRIPE_KEY"], version: nil)
        #expect(rig.store.secretsHeld)
        let t1 = try rig.turn()
        #expect(rig.capture.capture(turn: t1, sessionId: sid, store: rig.store) == .held)
        #expect(rig.capture.capture(turn: try rig.turn(), sessionId: sid, store: rig.store) == .held)
        #expect(try rig.row(t1) == nil)
        #expect(!FileManager.default.fileExists(atPath: rig.paths.transcriptsDir.path))
        #expect(try rig.activity().filter { $0.contains("secrets are not loaded") }.count == 1)
        // Loaded again: the next capture continues from the stored position (none yet), so nothing is lost.
        rig.store.redactor.update([], version: "0:")
        guard case .captured(let row) = rig.capture.capture(turn: try rig.turn(), sessionId: sid, store: rig.store) else {
            Issue.record("not captured after the redactor loaded"); return
        }
        #expect(row.byteStart == 0)
        #expect(try rig.content(row) == Self.line(1))
    }

    @Test func missingTranscriptRecordsNothing() throws {
        let rig = try Rig()
        let sid = UUID().uuidString
        let turn = try rig.turn()
        #expect(rig.capture.capture(turn: turn, sessionId: sid, store: rig.store) == .missing)
        #expect(try rig.row(turn) == nil)
        #expect(try rig.activity().contains { $0.contains("no transcript") && $0.contains(sid) })
        // A name that is not a session id never reaches the file system.
        #expect(rig.capture.capture(turn: turn, sessionId: "../../etc/passwd", store: rig.store) == .missing)
    }

    @Test func newestProjectFileWins() throws {
        let rig = try Rig()
        let sid = UUID().uuidString
        try rig.write(sid, Self.line(1), project: "-old")
        try rig.write(sid, Self.line(2), project: "-new")
        let past = Date(timeIntervalSinceNow: -3600)
        try FileManager.default.setAttributes([.modificationDate: past], ofItemAtPath: rig.file(sid, project: "-old").path)
        guard case .captured(let row) = rig.capture.capture(turn: try rig.turn(), sessionId: sid, store: rig.store) else {
            Issue.record("not captured"); return
        }
        #expect(try rig.content(row) == Self.line(2))
    }

    @Test func gzipFallbackRoundTrips() throws {
        let data = Data((0..<2000).map { "line \($0) of the transcript\n" }.joined().utf8)
        let work = try tempDir()
        let packed = try Compressor.gzip.compress(data, workDir: work)
        #expect(packed.count < data.count)
        #expect(try Compressor.gzip.decompress(packed, workDir: work) == data)
        #expect(Compressor.gzip.fileExtension == "gz")
        // A tool that is missing falls back to gzip.
        #expect(Compressor.zstdOrGzip(zstdPath: nil) == .gzip)
        // Nothing is left behind in the work directory.
        #expect(try FileManager.default.contentsOfDirectory(atPath: work.path).isEmpty)
        // Empty input.
        #expect(try Compressor.gzip.decompress(try Compressor.gzip.compress(Data(), workDir: work), workDir: work) == Data())
    }

    @Test(.enabled(if: TranscriptCaptureTests.zstdPath != nil))
    func zstdRoundTrips() throws {
        let path = try #require(Self.zstdPath)
        let compressor = Compressor.zstd(path: path)
        let data = Data((0..<2000).map { "line \($0) of the transcript\n" }.joined().utf8)
        let work = try tempDir()
        let packed = try compressor.compress(data, workDir: work)
        #expect(packed.count < data.count)
        #expect(try compressor.decompress(packed, workDir: work) == data)
        #expect(compressor.fileExtension == "zst")
        #expect(Compressor.zstdOrGzip(zstdPath: path) == compressor)
        // End to end: the stored file has the .zst suffix.
        let rig = try Rig(compressor: compressor)
        let sid = UUID().uuidString
        try rig.write(sid, Self.line(1))
        guard case .captured(let row) = rig.capture.capture(turn: try rig.turn(), sessionId: sid, store: rig.store) else {
            Issue.record("not captured"); return
        }
        #expect(row.codec == "zst" && row.path.hasSuffix(".jsonl.zst"))
        #expect(try rig.content(row) == Self.line(1))
    }

    @Test func endTurnCaptures() async throws {
        let source = TranscriptSource(configDir: try tempDir().appending(path: "claude", directoryHint: .isDirectory))
        let w = try World(transcriptSource: source)
        let c = try w.company("Acme"); let ceo = try w.hire(c, "ceo")
        // The turn "runs claude": its session file appears where the CLI writes it.
        w.fake.script("ceo", .init(sideEffect: { req in
            let url = source.projectsDir.appending(path: "-ws-acme/\(req.agent.sessionId).jsonl")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data((TranscriptCaptureTests.line(1) + TranscriptCaptureTests.line(2)).utf8).write(to: url)
        }))
        try w.dm(c, ceo)
        try await w.cycle()
        let turn = try #require(try w.turns(ceo).first)
        #expect(turn.outcome == .succeeded)
        let row = try #require(try w.store.transcript(turnId: turn.id))
        #expect(row.agentId == ceo.id && row.companyId == c.id)
        #expect(row.byteStart == 0 && row.byteEnd > 0)
        let stored = w.paths.home.appending(path: row.path)
        #expect(FileManager.default.fileExists(atPath: stored.path))
        // A turn whose transcript never appears still ends normally.
        try w.dm(c, ceo, "again")
        w.fake.script("ceo", .init())
        w.clock.advance(3600)
        try await w.cycle()
        let turns = try w.turns(ceo)
        #expect(turns.count == 2 && turns.allSatisfy { $0.outcome == .succeeded })
    }
}
