import Foundation
import Testing
import GRDB
@testable import BrahmaCore
@testable import BrahmaAppModel

/// Plan C Task C7b: the Show bar, cited answers and the CHANGES tab end to end, over real haiku turns and concierge runs
/// (Balanced mode, tier `max5x`, a $5 cost abort over the run). Owner-run only: `BRAHMA_LIVE=1 swift test --filter
/// LiveShowBarTests`. The app model's vault is a `MemoryVault` (the test `AppModel`); the turns' `brahma mcp` children read
/// the temp home's file vault (`mcpEnvironment`), never a Keychain.
@MainActor @Suite(.scratch, .serialized, .enabled(if: ProcessInfo.processInfo.environment["BRAHMA_LIVE"] == "1"))
struct LiveShowBarTests {
    nonisolated static let costAbortUSD = 5.0

    /// A seeded company "Eng" (keys `ENG-<n>`): @devops-1 (haiku), ENG-1 "Checkout flow" with a failed check run (`run:1`),
    /// `src/index.html` ("Habit tracker") on `main`, the web preview surface (L's seed: python's http.server), an artifact
    /// AR-1 and an ask A-1. The app model has the company selected; the engine runs only inside `running`.
    @MainActor struct World {
        let root: URL
        let paths: BrahmaPaths
        let store: Store
        let company: Company
        let devops: Agent
        let model: AppModel
        let orchestrator: Orchestrator

        static func make() async throws -> World {
            let root = try tempDir()
            let paths = BrahmaPaths(home: root.appending(path: "home"), workspaces: root.appending(path: "ws"))
            try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
            try FileManager.default.createDirectory(at: paths.workspaces, withIntermediateDirectories: true)
            let store = try Store(path: paths.database.path)
            try store.setPlanTier(.max5x)
            var c = try store.createCompany(name: "Eng", goal: "Build a habit tracker", workspacesRoot: paths.workspaces)
            c.usageMode = .balanced
            c.ownerReserve = -1
            try store.updateCompany(c)
            let userHome = root.appending(path: "user", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: userHome, withIntermediateDirectories: true)
            try store.updateSandbox(companyId: c.id, SandboxPatch(profile: .workspace), userHome: userHome)
            let company = try store.company(id: c.id) ?? c
            let devops = try store.hire(companyId: company.id, name: "devops-1", role: "devops", model: "haiku")

            let ws = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
            try FileManager.default.createDirectory(at: ws.appending(path: "src"), withIntermediateDirectories: true)
            try """
                <!doctype html>
                <html lang="en"><head><meta charset="utf-8"><title>Habit tracker</title></head>
                <body><h1>Habit tracker</h1><p>Daily streaks, reminders and a weekly summary.</p></body></html>

                """.write(to: ws.appending(path: "src/index.html"), atomically: true, encoding: .utf8)
            try git(["add", "src/index.html"], in: ws)
            try git(["-c", "user.name=Brahma", "-c", "user.email=engine@brahma.local", "-c", "commit.gpgsign=false",
                     "commit", "-q", "-m", "Habit tracker landing page"], in: ws)
            _ = try store.acceptMainCommit(companyId: company.id)
            _ = try store.upsertPreviewSurface(companyId: company.id, by: .owner, PreviewDraft(
                name: "web", run: "python3 -m http.server {port} --bind 127.0.0.1", url: "http://127.0.0.1:{port}/"))
            let item = try store.createWorkItem(companyId: company.id, by: .owner, draft: WorkItemDraft(
                type: "task", title: "Checkout flow", description: "Checkout is slow on the payment step", ownerId: devops.id))
            try #require(item.key == "ENG-1", "item key \(item.key)")
            try Data("<h1>Landing mock</h1>".utf8).write(to: ws.appending(path: "mock.html"))
            _ = try store.publishArtifact(companyId: company.id, by: .owner, sourcePath: "mock.html", title: "Landing mock", itemKey: nil,
                                          baseDirectory: ws)
            _ = try store.propose(companyId: company.id, by: .agent(devops.id), kind: .other, risk: .high, category: "general",
                                  title: "Pick a payment provider", summary: "checkout needs one", payload: nil, viaOwner: true,
                                  quotaExempt: .devHook)
            let (cId, itemId) = (company.id, item.id)
            try await store.writer.write { db in
                try VerificationRun(id: "1", companyId: cId, itemId: itemId, checkRevision: 0, scriptHash: "h", commit: "abc", command: "true",
                                    workingDirectory: ".", timeoutSeconds: 60, purpose: .submit, status: .failed, exitCode: 1,
                                    outputTail: "checkout test timed out after 30 s", createdAt: Store.now()).insert(db)
            }

            let mcp = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
                .appending(path: ".build/debug/brahma")
            try #require(FileManager.default.isExecutableFile(atPath: mcp.path), "build the brahma product first (\(mcp.path))")
            let orchestrator = Orchestrator(store: store, runner: ClaudeProcessRunner(maxTurnDuration: .seconds(150)), paths: paths,
                                            mcpExecutable: mcp.path, vault: MemoryVault(),
                                            mcpEnvironment: [SecretStore.environmentVariable: "file"])
            let model = AppModel(store: store, paths: paths)
            await model.load()
            await model.selectCompany(company.id)
            return World(root: root, paths: paths, store: store, company: company, devops: devops, model: model, orchestrator: orchestrator)
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

        func count(_ table: String) throws -> Int {
            try store.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table) WHERE companyId = ?", arguments: [company.id]) ?? 0 }
        }

        func spentUSD() throws -> Double {
            try store.writer.read { db in
                (try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(costUSD), 0) FROM turn WHERE companyId = ?", arguments: [company.id]) ?? 0)
                    + (try Double.fetchOne(db, sql: "SELECT COALESCE(SUM(costUSD), 0) FROM showRequest WHERE companyId = ?",
                                           arguments: [company.id]) ?? 0)
            }
        }

        func idle() throws -> Bool {
            try store.writer.read { db in
                try Turn.filter(Column("companyId") == company.id && Column("outcome") == TurnOutcome.inProgress.rawValue).fetchCount(db) == 0
            }
        }

        /// Polls `done` every `every` (refreshing the model's collab state first) until it holds; nil when it did, else why not.
        func waitFor(_ what: String, seconds: Int = 240, every: Duration = .seconds(1), _ done: () async throws -> Bool) async throws -> String? {
            let deadline = AwakeTime.now + .seconds(seconds)
            while AwakeTime.now < deadline {
                await model.refreshCollab()
                if try await done() { return nil }
                let spent = try spentUSD()
                if spent > LiveShowBarTests.costAbortUSD { return String(format: "cost abort at $%.2f waiting for %@", spent, what) }
                try await Task.sleep(for: every)
            }
            return "timed out waiting for \(what)"
        }

        /// Types `query` into the bar, waits out the debounce, presses Enter and applies what it produced.
        func enter(_ query: String) async -> ShowAction {
            model.openShow(presentation: .bar)
            await model.showBar.update(query: query)
            let action = model.showBar.handle(.enter)
            await model.perform(action)
            return action
        }

        /// Runs the engine around `body`; on a failure the company is stopped and every child of this run is signalled.
        func running(_ body: () async throws -> String?) async throws {
            try await orchestrator.start()
            let engine = orchestrator
            let loop = Task.detached { await engine.runForever(interval: .milliseconds(500)) }  // scope-escape: the engine loop; makes no scratch dirs
            var failure: String?
            do { failure = try await body() } catch { failure = "\(error)" }
            if failure != nil { _ = try? store.emergencyStop(note: "LiveShowBarTests: \(failure!)", by: "owner", now: Store.now()) }
            loop.cancel()
            await loop.value
            print(String(format: "SHOWBAR spent $%.4f", (try? spentUSD()) ?? -1))
            if let failure {
                let events = (try? store.events(afterId: 0).map(\.text).joined(separator: "\n")) ?? ""
                Issue.record("\(failure). Events:\n\(events)")
            }
        }
    }

    // MARK: Show me

    /// "show me the landing page on mobile" opens `preview:web@iphone` with no turn; "why is checkout slow" preselects ASK, and
    /// Enter files one concierge request whose answer opens in the OPENED slot with its steps (at most one concierge run).
    @Test(.timeLimit(.minutes(8)))
    func showMeEndToEnd() async throws {
        let w = try await World.make()
        try await w.running {
            _ = await w.enter("show me the landing page on mobile")
            let opened = w.model.previewNav.opened?.ref
            #expect(opened?.kind == .preview && opened?.canonical == "preview:web@iphone", "opened \(opened?.canonical ?? "nothing")")
            #expect(try w.count("turn") == 0 && w.count("showRequest") == 0)

            w.model.openShow(presentation: .bar)
            await w.model.showBar.update(query: "why is checkout slow")
            let rows = w.model.showBar.rows
            guard rows.indices.contains(w.model.showBar.selection), case .ask = rows[w.model.showBar.selection] else {
                return "ASK is not preselected for a why-question: \(rows)"
            }
            await w.model.perform(w.model.showBar.handle(.enter))
            #expect(try w.count("showRequest") == 1)
            if let why = try await w.waitFor("the concierge's answer to open", {
                if case .showAnswer(_, _, let concierge)? = w.model.previewNav.opened?.origin { return concierge }
                return false
            }) { return why }
            #expect(try w.count("conciergeRun") <= 1)
            #expect(try w.count("turn") == 0, "an agent turn ran for a concierge question")
            let answer = try #require(w.model.previewNav.opened)
            if let steps = answer.steps { #expect(steps.first == answer.ref) }
            return nil
        }
    }

    /// The fact questions answer from the database: an ANSWER card each, no turn and no show request.
    @Test(.timeLimit(.minutes(3)))
    func factQuestionsUseNoTurns() async throws {
        let w = try await World.make()
        for q in ["what's blocked", "what shipped this week", "how's the sprint going"] {
            w.model.openShow(presentation: .bar)
            await w.model.showBar.update(query: q)
            #expect(w.model.showBar.rows.contains { if case .answer = $0 { true } else { false } }, "no ANSWER card for \"\(q)\"")
        }
        #expect(try w.count("turn") == 0)
        #expect(try w.count("showRequest") == 0)
    }

    /// Ask Brahma's answer carries at least one ref; the stored verdict is `CitationCheck.verify`'s, and the OPENED header shows
    /// UNVERIFIED exactly when it is false.
    @Test(.timeLimit(.minutes(8)))
    func conciergeAnswerIsCited() async throws {
        let w = try await World.make()
        try await w.running {
            w.model.openShow(presentation: .bar)
            await w.model.showBar.update(query: "what did the team get done today and what looks risky")
            await w.model.perform(w.model.showBar.handle(.cmdEnter))
            var answerId: String?
            if let why = try await w.waitFor("the concierge's answer", {
                answerId = try w.store.writer.read { db in
                    try String.fetchOne(db, sql: "SELECT answerMessageId FROM showRequest WHERE companyId = ? AND status = 'answered'",
                                        arguments: [w.company.id])
                }
                return answerId != nil && w.model.openedBody != nil
            }) { return why }
            #expect(try w.count("conciergeRun") == 1)
            let id = try #require(answerId)
            let message = try #require(try await w.store.writer.read { db in
                try Message.fetchOne(db, sql: "SELECT * FROM message WHERE id = ?", arguments: [id])
            })
            let refs = try w.store.messageRefs(companyId: w.company.id, messageId: message.id)
            #expect(refs.count >= 1, "the answer cites no ref")
            let verdict = CitationCheck.verify(note: message.text, refCount: refs.count).verified
            #expect(message.answerVerified == verdict)
            let unverified = w.model.openedBody?.header.chips.contains { $0.text == "UNVERIFIED" } ?? false
            #expect(unverified == !verdict, "UNVERIFIED chip \(unverified), verdict \(verdict)")
            return nil
        }
    }

    // MARK: CHANGES

    /// @devops-1 edits `src/index.html` in its item worktree and answers an owner request with `show(refs: ["wt:@devops-1"])`:
    /// the answer opens the live CHANGES diff, the board row's +/− grows within 2 s of each edit, and an owner line comment
    /// reaches the agent as an item comment (and the DM with the quoted hunk).
    @Test(.timeLimit(.minutes(10)))
    func liveChangesEndToEnd() async throws {
        let w = try await World.make()
        let item = try w.store.createWorkItem(companyId: w.company.id, by: .owner, draft: WorkItemDraft(
            type: "task", title: "Mobile footer", description: "Add a footer to src/index.html", ownerId: w.devops.id, status: .ready))
        _ = try CompanyTools(store: w.store, companyId: w.company.id, agentId: w.devops.id)
            .call(name: "claim_lease", arguments: ["key": .string(item.key)])
        let wtFile = URL(fileURLWithPath: w.company.workspacePath).appending(path: ".brahma/wt/\(item.key)/src/index.html")
        try #require(FileManager.default.fileExists(atPath: wtFile.path), "no worktree for \(item.key)")
        w.model.select(.missionControl)
        w.model.selectPreviewTab(PreviewTabID.changes)

        try await w.running {
            await w.model.submitAsk(ShowAskDraft(
                query: "edit src/index.html in your \(item.key) worktree: add three footer lines, one Edit call each, then show me wt:@devops-1",
                kind: .show, target: RoutedTarget(target: .agent(w.devops.id), reason: "holder of \(item.key)", busy: false), attachedRef: nil))
            #expect(try w.count("showRequest") == 1)

            // Each change of the worktree file must reach the board row within 2 s (sampled every 250 ms).
            var lastBytes = try? Data(contentsOf: wtFile)
            var lastStat = w.model.changes?.board.first { $0.key == item.key }.map { $0.added + $0.removed } ?? 0
            var pending: Date?
            var lags: [TimeInterval] = []
            var grew: [Int] = []
            if let why = try await w.waitFor("the show answer to open the CHANGES diff", every: .milliseconds(250), {
                let bytes = try? Data(contentsOf: wtFile)
                if bytes != lastBytes { lastBytes = bytes; if pending == nil { pending = Date() } }
                let stat = w.model.changes?.board.first { $0.key == item.key }.map { $0.added + $0.removed } ?? 0
                if stat != lastStat {
                    if let t0 = pending { lags.append(Date().timeIntervalSince(t0)); pending = nil }
                    grew.append(stat)
                    lastStat = stat
                }
                if case .changes(let key, _)? = w.model.openedBody?.content { return key == item.key }
                return false
            }) { return why }
            #expect(!grew.isEmpty && grew == grew.sorted(), "the board row's +/− did not grow as it edited: \(grew)")
            #expect(lags.allSatisfy { $0 <= 2.5 }, "board lag after an edit: \(lags)")
            if let why = try await w.waitFor("@devops-1 idle", { try w.idle() }) { return why }

            // The owner's line comment.
            let changes = try #require(w.model.changes)
            changes.select(item.key)
            if let why = try await w.waitFor("the live diff", { changes.diff != nil }) { return why }
            var anchor: DiffAnchor?
            outer: for (h, hunk) in (changes.diff?.files.first?.hunks ?? []).enumerated() {
                for i in hunk.lines.indices {
                    if let a = changes.anchor(fileIndex: 0, hunk: h, index: i, side: "new") { anchor = a; break outer }
                }
            }
            let a = try #require(anchor, "no commentable line")
            let posted = await w.model.submitReview(ReviewDraft(anchor: a, text: "Keep the footer to one line on mobile."), key: item.key,
                                                    compare: .main)
            #expect(posted, "\(w.model.errorMessage ?? "")")
            let events = try await w.store.writer.read { db in
                try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workItemEvent WHERE itemId = ? AND kind = 'reviewComment'", arguments: [item.id]) ?? 0
            }
            #expect(events == 1, "no reviewComment item event for the holder")
            let dm = try w.store.channel(companyId: w.company.id, name: "dm:devops-1:owner")
            let quoted = try dm.map { try w.store.messages(channelId: $0.id, limit: 20) } ?? []
            #expect(quoted.contains { $0.senderId == "owner" && $0.text.contains("Owner review comment") })
            // The review never touched the agent's file.
            #expect(try Data(contentsOf: wtFile) == lastBytes)
            return nil
        }
    }

    /// Direct refs open with no turn and no show request.
    @Test(.timeLimit(.minutes(3)))
    func noTurnForDirectRefs() async throws {
        let w = try await World.make()
        for q in ["ENG-1", "src/index.html", "AR-1", "A-1", "@devops-1", "run:1"] {
            let action = await w.enter(q)
            guard case .open = action else { Issue.record("\"\(q)\" did not open: \(action)"); continue }
        }
        #expect(try w.count("turn") == 0)
        #expect(try w.count("showRequest") == 0)
    }
}
