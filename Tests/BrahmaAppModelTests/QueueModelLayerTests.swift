import Foundation
import Testing
import GRDB
@testable import BrahmaCore
@testable import BrahmaAppModel

/// Plan 4a Task 8b: the app model over the merge queue and the artifacts (snapshot, owner actions, launch targets).
@MainActor @Suite(.scratch) struct QueueModelLayerTests {
    static func publish(_ w: WorkWorld, _ name: String = "thing.html", title: String = "Thing") throws -> Artifact {
        let ws = URL(fileURLWithPath: w.company.workspacePath, isDirectory: true)
        try Data("<h1>hi</h1>".utf8).write(to: ws.appending(path: name))
        return try w.store.publishArtifact(companyId: w.company.id, by: .owner, sourcePath: name, title: title, itemKey: nil, baseDirectory: ws)
    }

    @discardableResult
    static func request(_ w: WorkWorld, _ item: WorkItem, number: Int, status: MergeRequestStatus, failure: MergeFailure? = nil) throws -> MergeRequest {
        var r = MergeRequest(companyId: w.company.id, itemId: item.id, number: number, status: status, headCommit: "feedface1234567", enqueuedAt: Date())
        r.failure = failure
        if !status.isOpen { r.finishedAt = Date() }
        try w.store.writer.write { db in try r.insert(db) }
        return r
    }

    /// An approved item waiting to merge (what `requestMergeRetry` requires), set the way the engine would.
    static func markVerified(_ w: WorkWorld, _ item: WorkItem) throws {
        try w.store.writer.write { db in
            try db.execute(sql: "UPDATE workItem SET status = 'inReview', verifiedCommit = 'feedface1234567', verifiedRevision = 1 WHERE id = ?",
                           arguments: [item.id])
        }
    }

    @Test func snapshotCarriesMergeAndArtifacts() async throws {
        let w = try await WorkWorld.make()
        await w.refresh()
        #expect(w.model.previewTabs.isEmpty && w.model.snapshot.preview.artifacts.isEmpty)
        #expect(w.model.snapshot.merge.settings == MergeSettings() && w.model.snapshot.merge.hold == nil)
        #expect(w.model.snapshot.merge.mainCommit == (try w.store.company(id: w.company.id))?.mainCommit)
        #expect(w.model.mergeRows.isEmpty && w.model.mergeHeader.title == "QUEUE IDLE")

        let a = try Self.publish(w)
        await w.refresh()
        #expect(w.model.snapshot.preview.artifacts.map(\.id) == [a.id])
        #expect(w.model.previewTabs.map(\.title) == ["ARTIFACTS"])
        #expect(w.model.previewBody == .artifact(a, all: [a]))
        // The stored path is relative to the workspace: the file body is rooted in the workspace's copy.
        let ws = URL(fileURLWithPath: w.company.workspacePath, isDirectory: true)
        let body = try #require(w.model.fileBody(for: a))
        #expect(a.storedPath == ".brahma/artifacts/1-thing")
        #expect(body.root == ws.appending(path: a.storedPath, directoryHint: .isDirectory))
        #expect(a.entryFile == "thing.html")
        #expect(body.url == body.root.appending(path: a.entryFile, directoryHint: .notDirectory))
        #expect(body.mode == .web && body.bytes == 11)
        #expect(w.model.snapshot.preview.fileBodies[a.id] == body)

        w.model.selectArtifact(a)
        #expect(w.model.selectedPreviewTab == PreviewTabID.artifacts && w.model.selectedArtifactId == a.id)
        await w.model.deleteArtifact(a)
        #expect(w.model.errorMessage == nil)
        #expect(w.model.snapshot.preview.artifacts.isEmpty && w.model.previewTabs.isEmpty)
        #expect(w.model.selectedArtifactId == nil)
        #expect(!FileManager.default.fileExists(atPath: body.root.path))
    }

    @Test func saveMergeSettingsPersists() async throws {
        let w = try await WorkWorld.make()
        await w.refresh()
        var form = w.model.mergeSettingsForm
        #expect(form.batchSize == "1" && form.strategy == .ff)
        form.batchSize = "3"
        form.strategy = .merge
        form.mainCheckCommand = "swift test"
        form.timeoutSeconds = "120"
        await w.model.saveMergeSettings(form)
        #expect(w.model.errorMessage == nil)
        let saved = MergeSettings(mainCheck: CheckSpec(command: "swift test", timeoutSeconds: 120), batchSize: 3, strategy: .merge)
        #expect(try w.store.mergeSettings(companyId: w.company.id) == saved)
        #expect(w.model.snapshot.merge.settings == saved)
        #expect(w.model.mergeSettingsForm.mainCheckCommand == "swift test")
        // The form's own rule stops a bad batch size before the store sees it.
        form.batchSize = "0"
        await w.model.saveMergeSettings(form)
        #expect(w.model.errorMessage == "Batch size must be 1–8")
        #expect(try w.store.mergeSettings(companyId: w.company.id) == saved)
    }

    @Test func retryAndResume() async throws {
        let w = try await WorkWorld.make()
        let item = try w.item("Ship it")
        try Self.markVerified(w, item)
        let failed = try Self.request(w, item, number: 1, status: .failed, failure: .engineError)
        try w.store.setMergeHold(companyId: w.company.id, reason: "main is red")
        await w.refresh()
        #expect(w.model.mergeRows.map(\.ref) == ["M-1"] && w.model.mergeRows[0].canRetry)
        #expect(w.model.mergeHeader.title == "QUEUE HELD" && w.model.mergeHeader.detail == "main is red")

        await w.model.retryMerge(requestId: failed.id)
        #expect(w.model.errorMessage == nil)
        #expect(w.model.snapshot.merge.open.map(\.number) == [2] && w.model.snapshot.merge.recent.map(\.number) == [1])
        #expect(w.model.mergeRows.map(\.ref) == ["M-2", "M-1"])
        // A second retry of the same request is refused in the store's words.
        await w.model.retryMerge(requestId: failed.id)
        #expect(w.model.errorMessage == "\(item.key) already has a merge in the queue")

        await w.model.resumeMergeQueue()
        #expect(w.model.snapshot.merge.hold == nil)
        #expect(try w.store.company(id: w.company.id)?.mergeHold == nil)
        #expect(w.model.mergeHeader.title == "1 IN QUEUE")
    }

    @Test func itemMergeLoads() async throws {
        let w = try await WorkWorld.make()
        let item = try w.item("Queued thing")
        try Self.request(w, item, number: 1, status: .queued)
        await w.refresh()
        let loaded = await w.model.itemMerge(itemKey: item.key)
        let m = try #require(loaded)
        #expect(m.request.number == 1 && m.position == 1)
        let unknown = await w.model.itemMerge(itemKey: "ACME-999")
        #expect(unknown == nil)
        let other = try w.item("Nothing queued")
        let none = await w.model.itemMerge(itemKey: other.key)
        #expect(none == nil)
    }

    @Test func selectTargets() async throws {
        #expect(SelectTarget("merge") == .mergeQueue)
        #expect(SelectTarget("merge-settings") == .sheet(.mergeSettings))
        #expect(SelectTarget("preview:artifacts") == .preview(name: "artifacts"))
        #expect(SelectTarget("artifact:AR-3") == .artifact(number: 3))
        #expect(SelectTarget("artifact:ar-12") == .artifact(number: 12))
        #expect(SelectTarget("artifact:7") == .artifact(number: 7))
        #expect(SelectTarget("artifact:A-3") == nil)
        #expect(SelectTarget("artifact:AR-0") == nil)
        #expect(SelectTarget("artifact:") == nil)
        #expect(AppSheet.mergeSettings.id == "mergeSettings")

        let w = try await WorkWorld.make()
        let a = try Self.publish(w)
        await w.refresh()
        w.model.apply(.mergeQueue)
        #expect(w.model.sidebarSelection == .mergeQueue && w.model.chat == nil)
        w.model.apply(.sheet(.mergeSettings))
        #expect(w.model.presentedSheet == .mergeSettings)
        w.model.apply(.artifact(number: 1))
        #expect(w.model.sidebarSelection == .missionControl)
        #expect(w.model.selectedPreviewTab == PreviewTabID.artifacts && w.model.selectedArtifactId == a.id)
        #expect(w.model.previewBody == .artifact(a, all: [a]))
        await w.model.openArtifact(number: 9)
        #expect(w.model.errorMessage == "No artifact AR-9")
        #expect(w.model.selectedArtifactId == a.id, "a miss keeps the selection")
        w.model.errorMessage = nil
        w.model.selectedPreviewTab = nil
        w.model.apply(.preview(name: "artifacts"))
        #expect(w.model.selectedPreviewTab == PreviewTabID.artifacts && w.model.errorMessage == nil)
        // A company-bound sheet closes with the company.
        w.model.presentedSheet = .mergeSettings
        await w.model.selectCompany(w.company.id)
        #expect(w.model.presentedSheet == nil)
    }

    /// An artifact row without a copy on disk (the publish rate would stop 25 real publishes in one test).
    @discardableResult
    static func insertArtifact(_ w: WorkWorld, number: Int) throws -> Artifact {
        let a = Artifact(id: "ar\(number)", companyId: w.company.id, number: number, title: "Thing \(number)", kind: .html,
                         storedPath: ".brahma/artifacts/\(number)-thing", entryFile: "thing.html", sourcePath: "x", publishedById: "owner",
                         itemId: nil, bytes: 11, createdAt: Date(timeIntervalSince1970: 1_800_000_000 + Double(number)))
        try w.store.writer.write { db in try a.insert(db) }
        return a
    }

    @Test func mergeHistoryIsBoundedAndOpenRowsNeverFallOut() async throws {
        let w = try await WorkWorld.make()
        let item = try w.item("Old but queued")
        // The oldest request is still open; two dozen newer ones closed since.
        let old = try Self.request(w, item, number: 1, status: .queued)
        for n in 2...25 { try Self.request(w, item, number: n, status: .merged) }
        await w.refresh()
        #expect(w.model.snapshot.merge.open.map(\.number) == [1])
        #expect(w.model.snapshot.merge.recent.map(\.number) == Array((6...25).reversed()))
        #expect(w.model.snapshot.merge.recent.count == MergeSnapshot.recentShown)
        #expect(w.model.openMergeCount == 1 && w.model.mergeHeader.title == "1 IN QUEUE")
        let rows = w.model.mergeRows
        #expect(rows.count == 21 && rows.first?.id == old.id && rows.first?.position == 1)
        #expect(rows.dropFirst().map(\.ref) == (6...25).reversed().map { "M-\($0)" })
    }

    @Test func artifactOlderThanTheNewestTwentyIsLookedUpAndPinned() async throws {
        let w = try await WorkWorld.make()
        var all: [Artifact] = []
        for n in 1...25 { all.append(try Self.insertArtifact(w, number: n)) }
        await w.refresh()
        let newest = w.model.snapshot.preview.artifacts
        #expect(newest.map(\.number) == Array((6...25).reversed()))
        #expect(w.model.previewTabs.map(\.title) == ["ARTIFACTS"])
        // In the snapshot: shown at once, synchronously.
        w.model.apply(.artifact(number: 25))
        #expect(w.model.selectedArtifactId == "ar25")
        // Older than the newest 20: found in the Store and pinned; the body shows it and the list carries it.
        await w.model.openArtifact(number: 3)
        #expect(w.model.errorMessage == nil)
        #expect(w.model.selectedArtifactId == "ar3" && w.model.selectedPreviewTab == PreviewTabID.artifacts)
        #expect(w.model.previewBody == .artifact(all[2], all: newest + [all[2]]))
        let ws = URL(fileURLWithPath: w.company.workspacePath, isDirectory: true)
        let body = try #require(w.model.fileBody(for: all[2]))
        #expect(body.root == ws.appending(path: ".brahma/artifacts/3-thing", directoryHint: .isDirectory) && body.mode == .web && body.bytes == 0)
        #expect(w.model.previewTabs.count == 1, "the pin adds no tab")
        // Only a number the company never used is "No artifact"; the pin stays.
        await w.model.openArtifact(number: 99)
        #expect(w.model.errorMessage == "No artifact AR-99")
        #expect(w.model.selectedArtifactId == "ar3" && w.model.previewBody == .artifact(all[2], all: newest + [all[2]]))
        // The pin is per company.
        await w.model.selectCompany(w.company.id)
        #expect(w.model.previewBody == .artifact(all[24], all: newest))
    }

    @Test func openAPIAndDemoOutputReachTheBodiesEndToEnd() async throws {
        let w = try await WorkWorld.make()
        let layout = EngineLayout(workspace: URL(fileURLWithPath: w.company.workspacePath, isDirectory: true))
        try FileManager.default.createDirectory(at: layout.previewLogs, withIntermediateDirectories: true)

        // A ran CLI demo: its sealed output reaches `.terminal` through the core's hardened reader.
        let demo = try w.store.upsertPreviewSurface(companyId: w.company.id, by: .owner,
                                                    PreviewDraft(name: "demo", kind: "cli", run: nil, url: nil, demo: "./demo"))
        try Data("hello\n\u{1B}[32mworld\u{1B}[0m\n".utf8).write(to: layout.previewOutput(name: "demo"))
        try w.store.savePreviewState(PreviewState(surfaceId: demo.id, companyId: w.company.id, status: .ran, commit: "abcdef1234567",
                                                  message: "exit 0", updatedAt: Date(), outputPath: layout.previewOutput(name: "demo").path))

        // A running backend: its log tail and the engine's OpenAPI copy, parsed by the model after the refresh.
        let api = try w.store.upsertPreviewSurface(companyId: w.company.id, by: .owner,
                                                   PreviewDraft(name: "api", kind: "backend", run: "node server", url: "http://127.0.0.1:{port}/"))
        try Data("listening\n".utf8).write(to: layout.previewLog(name: "api"))
        try Data(#"{"openapi":"3.0.0","paths":{"/health":{"get":{"summary":"Liveness"}}}}"#.utf8).write(to: layout.previewOpenAPI(name: "api"))
        func running(commit: String) throws {
            try w.store.savePreviewState(PreviewState(surfaceId: api.id, companyId: w.company.id, status: .running, commit: commit,
                                                      resolvedURL: "http://127.0.0.1:47100/", logPath: layout.previewLog(name: "api").path,
                                                      startedAt: Date(), updatedAt: Date()))
        }
        try running(commit: "1111111aaaaaaa")
        await w.refresh()
        let demoTab = PreviewTabID.surface(demo.id), apiTab = PreviewTabID.surface(api.id)
        /// Waits for the parse to land (up to 20 s), then asserts, so a failure names the body shown.
        func settle(_ tab: String, _ expected: PreviewBody) async {
            let deadline = SuspendingClock.now + .seconds(20)
            while w.model.previewBody(forTab: tab) != expected, SuspendingClock.now < deadline {
                try? await Task.sleep(for: .milliseconds(20))
            }
            #expect(w.model.previewBody(forTab: tab) == expected)
        }
        #expect(w.model.previewBody(forTab: demoTab) == .terminal(lines: ["hello", "\u{1B}[32mworld\u{1B}[0m"], footer: "exit 0 · abcdef1"))
        #expect(w.model.snapshot.preview.openAPICopies[api.id] == OpenAPICopy(layout: layout, name: "api"))
        let parsed = PreviewBody.backend(smoke: [], logTail: ["listening"],
                                         operations: [OpenAPIOperation(method: "GET", path: "/health", summary: "Liveness")])
        await settle(apiTab, parsed)

        // A copy that is not OpenAPI (a new start re-reads it): a distinct status, not an empty table.
        try Data("not json".utf8).write(to: layout.previewOpenAPI(name: "api"))
        try running(commit: "2222222bbbbbbb")
        await w.refresh()
        await settle(apiTab, .status(title: "CAN'T SHOW THIS FILE", detail: "the OpenAPI file couldn't be read", logTail: []))

        // A link planted at the copy's name is not the engine's copy: not discovered (the snapshot lstat's for a regular file),
        // never read, and the backend shows with no operations rather than what the link points at.
        try FileManager.default.removeItem(at: layout.previewOpenAPI(name: "api"))
        let elsewhere = try tempDir().appending(path: "spec.json")
        try Data(#"{"paths":{"/x":{"get":{}}}}"#.utf8).write(to: elsewhere)
        try FileManager.default.createSymbolicLink(at: layout.previewOpenAPI(name: "api"), withDestinationURL: elsewhere)
        try running(commit: "3333333ccccccc")
        await w.refresh()
        #expect(w.model.snapshot.preview.openAPICopies[api.id] == nil)
        await settle(apiTab, .backend(smoke: [], logTail: ["listening"], operations: []))
        #expect(w.model.openAPICache[api.id] == nil, "nothing to parse, nothing cached")

        // The parse timeout, on a manual clock: `RendererCaps.parse(clock:)` times the body out, and the body says so.
        try FileManager.default.removeItem(at: layout.previewOpenAPI(name: "api"))
        try Data(#"{"paths":{}}"#.utf8).write(to: layout.previewOpenAPI(name: "api"))
        let clock = ArtifactParsingTests.ManualClock()
        w.model.openAPIParser = { _ in
            try await RendererCaps.parse(clock: clock) { () -> [OpenAPIOperation]? in
                let deadline = Date().addingTimeInterval(10)
                while Date() < deadline {
                    if Task.isCancelled { return nil }
                    Thread.sleep(forTimeInterval: 0.01)
                }
                return []
            }
        }
        try running(commit: "4444444ddddddd")
        await w.refresh()
        #expect(w.model.previewBody(forTab: apiTab) == .backend(smoke: [], logTail: ["listening"], operations: []), "loading shows the live state")
        try await eventually { clock.sleepers == 1 }
        clock.advance(by: RendererCaps.parseTimeout)
        await settle(apiTab, .status(title: "CAN'T SHOW THIS FILE", detail: "it took too long to read", logTail: []))
    }

    @Test func phoneFrameOverrideToggles() async throws {
        let w = try await WorkWorld.make()
        #expect(w.model.phoneFrame(for: "ar1", detected: .phone))
        #expect(!w.model.phoneFrame(for: "ar1", detected: .plain))
        w.model.setPhoneFrame(false, artifactId: "ar1")
        #expect(!w.model.phoneFrame(for: "ar1", detected: .phone))
        w.model.setPhoneFrame(true, artifactId: "ar2")
        #expect(w.model.phoneFrame(for: "ar2", detected: .plain))
        #expect(w.model.phoneFrameOverride == ["ar1": false, "ar2": true])
        // Another artifact keeps the detected layout.
        #expect(w.model.phoneFrame(for: "ar3", detected: .phone) && !w.model.phoneFrame(for: "ar3", detected: .plain))
        // The overrides are per company.
        await w.model.selectCompany(w.company.id)
        #expect(w.model.phoneFrameOverride.isEmpty)
    }
}
