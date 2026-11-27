import Foundation
import Testing
import GRDB
@testable import BrahmaCore

/// Plan C Task C7b: live sharing end to end (real haiku turns, Balanced mode, tier `max5x`, a $5 cost abort over the run).
/// Owner-run only: `BRAHMA_LIVE=1 swift test --filter LiveCollabTests`. The vault is a `MemoryVault` in this process; the turns'
/// `brahma mcp` children read the temp home's file vault (`mcpEnvironment`), never a Keychain.
@Suite(.scratch, .serialized, .enabled(if: ProcessInfo.processInfo.environment["BRAHMA_LIVE"] == "1"))
struct LiveCollabTests {
    static let costAbortUSD = 5.0
    static let landingPage = """
        <!doctype html>
        <html lang="en"><head><meta charset="utf-8"><title>Habit tracker</title></head>
        <body><h1>Habit tracker</h1><p>Daily streaks, reminders and a weekly summary.</p></body></html>

        """

    /// A small Initech: @devops-1 and @qa-1 (haiku), the landing page committed on `main` and accepted, Workspace profile (no
    /// sandbox canary in a temp home), Balanced mode, no weekly reserve (pacing depends on the real account).
    struct World {
        let root: URL
        let paths: BrahmaPaths
        let store: Store
        let company: Company
        let devops: Agent
        let qa: Agent
        let orchestrator: Orchestrator

        init() throws {
            root = try tempDir()
            paths = BrahmaPaths(home: root.appending(path: "home"), workspaces: root.appending(path: "ws"))
            try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
            store = try Store(path: paths.database.path)
            try store.setPlanTier(.max5x)
            var c = try store.createCompany(name: "Initech", goal: "Build a habit tracker", workspacesRoot: paths.workspaces)
            c.usageMode = .balanced
            c.ownerReserve = -1
            try store.updateCompany(c)
            let userHome = root.appending(path: "user", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: userHome, withIntermediateDirectories: true)
            try store.updateSandbox(companyId: c.id, SandboxPatch(profile: .workspace), userHome: userHome)
            company = try store.company(id: c.id) ?? c
            devops = try store.hire(companyId: company.id, name: "devops-1", role: "devops", model: "haiku")
            qa = try store.hire(companyId: company.id, name: "qa-1", role: "engineer", model: "haiku")
            let ws = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
            try LiveCollabTests.landingPage.write(to: ws.appending(path: "index.html"), atomically: true, encoding: .utf8)
            try Self.git(["add", "index.html"], in: ws)
            try Self.git(["-c", "user.name=Brahma", "-c", "user.email=engine@brahma.local", "-c", "commit.gpgsign=false",
                          "commit", "-q", "-m", "Habit tracker landing page"], in: ws)
            _ = try store.acceptMainCommit(companyId: company.id)
            let mcp = Bundle.module.bundleURL.deletingLastPathComponent().appending(path: "brahma")
            try #require(FileManager.default.isExecutableFile(atPath: mcp.path), "build the brahma product first")
            orchestrator = Orchestrator(store: store, runner: ClaudeProcessRunner(maxTurnDuration: .seconds(150)), paths: paths,
                                        mcpExecutable: mcp.path, vault: MemoryVault(),
                                        mcpEnvironment: [SecretStore.environmentVariable: "file"])
        }

        static func git(_ args: [String], in dir: URL) throws {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/git")
            p.arguments = ["-C", dir.path] + args
            p.standardOutput = FileHandle.nullDevice
            p.standardError = FileHandle.nullDevice
            try p.run(); p.waitUntilExit()
            guard p.terminationStatus == 0 else { throw CocoaError(.fileWriteUnknown) }
        }

        /// What the run has cost so far: every turn plus every concierge request.
        func spentUSD() throws -> Double {
            try store.writer.read { db in
                (try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(costUSD), 0) FROM turn WHERE companyId = ?", arguments: [company.id]) ?? 0)
                    + (try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(costUSD), 0) FROM showRequest WHERE companyId = ?",
                                           arguments: [company.id]) ?? 0)
            }
        }

        func idle(_ agent: Agent) throws -> Bool {
            try store.writer.read { db in
                try Turn.filter(Column("agentId") == agent.id && Column("outcome") == TurnOutcome.inProgress.rawValue).fetchCount(db) == 0
            }
        }

        /// Polls `done` every 2 s until it holds; nil when it did, else why it stopped (the deadline or the cost abort).
        func waitFor(_ what: String, seconds: Int = 240, _ done: () throws -> Bool) async throws -> String? {
            let deadline = AwakeTime.now + .seconds(seconds)
            while AwakeTime.now < deadline {
                if try done() { return nil }
                let spent = try spentUSD()
                if spent > LiveCollabTests.costAbortUSD { return String(format: "cost abort at $%.2f waiting for %@", spent, what) }
                try await Task.sleep(for: .seconds(2))
            }
            return "timed out waiting for \(what)"
        }

        func dm(_ a: String, _ b: String) throws -> [Message] {
            guard let ch = try store.channel(companyId: company.id, name: "dm:" + [a, b].sorted().joined(separator: ":")) else { return [] }
            return try store.messages(channelId: ch.id, limit: 50)
        }

        /// Runs the engine around `body`; on any failure the company is stopped and every child of this run is signalled.
        func running(_ body: () async throws -> String?) async throws {
            try await orchestrator.start()
            let loop = Task { await orchestrator.runForever(interval: .milliseconds(500)) }
            let failure: String?
            do { failure = try await body() } catch {
                _ = try? store.emergencyStop(note: "LiveCollabTests: \(error)", by: "owner", now: Store.now())
                loop.cancel()
                _ = await LiveRunMonitor.bounded(30, { await loop.value })
                _ = LiveRunMonitor.killLeftovers(store: store, root: root)
                throw error
            }
            if let failure { _ = try? store.emergencyStop(note: "LiveCollabTests: \(failure)", by: "owner", now: Store.now()) }
            loop.cancel()
            _ = await LiveRunMonitor.bounded(30, { await loop.value })
            _ = LiveRunMonitor.killLeftovers(store: store, root: root)
            print(String(format: "COLLAB spent $%.4f", (try? spentUSD()) ?? -1))
            if let failure {
                let events = (try? store.events(afterId: 0).map(\.text).joined(separator: "\n")) ?? ""
                Issue.record("\(failure). Events:\n\(events)")
            }
        }
    }

    /// The design's first sharing story: @devops-1 shares `index.html:1-20` with @qa-1 (a pinned `messageRef` row), the share
    /// reaches qa-1 as a one-line chip, and qa-1 reads it through `open_ref` (a `refRead` row) and replies with its <title>.
    @Test(.timeLimit(.minutes(10)))
    func agentSharesAndColleagueOpens() async throws {
        let w = try World()
        let router = MessageRouter(store: w.store)
        try await w.running {
            _ = try router.sendDM(companyId: w.company.id, from: .owner, to: "devops-1",
                                  text: "Share index.html lines 1-20 with @qa-1 using the share tool (refs [\"index.html:1-20\"], to \"@qa-1\"), then stop.")
            var share: Message?
            if let why = try await w.waitFor("@devops-1's share to @qa-1", {
                share = try w.dm("devops-1", "qa-1").first { $0.senderId == w.devops.id && $0.kind == .share }
                return share != nil
            }) { return why }
            let rows = try w.store.messageRefs(companyId: w.company.id, messageId: share!.id)
            #expect(rows.contains { $0.canonical.hasPrefix("index.html") && $0.rev != nil }, "rows: \(rows.map(\.canonical))")
            let chip = try w.store.attachmentLines(companyId: w.company.id, messageId: share!.id, reader: .agent(w.qa.id))
            #expect(chip.count == 1 && chip[0].contains("index.html"), "qa-1's chip: \(chip)")
            if let why = try await w.waitFor("@qa-1 idle after the share", { try w.idle(w.qa) }) { return why }

            let asked = try router.sendDM(companyId: w.company.id, from: .owner, to: "qa-1",
                                          text: "Use open_ref on the file @devops-1 sent you and reply to me with the text of its <title> element.")
            if let why = try await w.waitFor("@qa-1's reply holding the title", {
                try w.dm("owner", "qa-1").contains { $0.senderId == w.qa.id && $0.createdAt >= asked.createdAt && $0.text.contains("Habit tracker") }
            }) { return why }
            let reads = try await w.store.writer.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM refRead WHERE companyId = ? AND readerId = ? AND via = 'open_ref' AND canonical LIKE 'index.html%'",
                                 arguments: [w.company.id, w.qa.id]) ?? 0
            }
            #expect(reads >= 1, "no refRead row for qa-1's open_ref")
            return try await w.waitFor("both idle", { try w.idle(w.qa) && w.idle(w.devops) })
        }
    }

    /// A snapshot from a tainted session taints its live reader: @devops-1 reads a web page, writes a lab note and shares it
    /// with @qa-1 (no reply_to); qa-1's `open_ref` marks its session tainted, and a later decide-class tool is refused.
    @Test(.timeLimit(.minutes(10)))
    func taintedSnapshotTaintsLiveReader() async throws {
        let w = try World()
        let router = MessageRouter(store: w.store)
        try await w.running {
            _ = try router.sendDM(companyId: w.company.id, from: .owner, to: "devops-1", text: """
                Use WebFetch to read https://docs.swift.org/swift-book/ and write a two-line summary to the file \
                .brahma/labs/devops-1/notes/swift-book.md. Then share that file with @qa-1 using the share tool \
                (refs [".brahma/labs/devops-1/notes/swift-book.md"], to "@qa-1", no reply_to), then stop.
                """)
            var share: Message?
            if let why = try await w.waitFor("@devops-1's lab-note share", {
                share = try w.dm("devops-1", "qa-1").first { $0.senderId == w.devops.id && $0.kind == .share }
                return share != nil
            }) { return why }
            // The share carries the sender's session taint (WebFetch marks it through the engine's hook).
            let sender = try #require(try w.store.agent(id: w.devops.id))
            #expect(sender.sessionTainted || share!.fromTaintedSession, "@devops-1's session was not tainted by the web read")
            if let why = try await w.waitFor("@qa-1 idle after the share", { try w.idle(w.qa) }) { return why }

            #expect(try w.store.agent(id: w.qa.id)?.sessionTainted == false, "qa-1 was tainted before reading anything")
            _ = try router.sendDM(companyId: w.company.id, from: .owner, to: "qa-1",
                                  text: "Use open_ref on the note @devops-1 shared with you, then reply to me with one sentence about it.")
            if let why = try await w.waitFor("@qa-1 tainted by the snapshot", {
                try w.store.agent(id: w.qa.id)?.sessionTainted == true
            }) { return why }
            let refused: String
            do {
                _ = try CompanyTools(store: w.store, companyId: w.company.id, agentId: w.qa.id)
                    .call(name: "decide", arguments: ["ask": .string("A-1"), "approve": .bool(true), "note": .string("ok")])
                refused = ""
            } catch let e as ToolError {
                refused = e.message
            }
            #expect(refused.contains("read outside content") && refused.contains("decide"), "decide was not refused under taint: \(refused)")
            return try await w.waitFor("both idle", { try w.idle(w.qa) && w.idle(w.devops) })
        }
    }
}
