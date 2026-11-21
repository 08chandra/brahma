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
        w.model.apply(.artifact(number: 9))
        #expect(w.model.errorMessage == "No artifact AR-9")
        w.model.errorMessage = nil
        w.model.selectedPreviewTab = nil
        w.model.apply(.preview(name: "artifacts"))
        #expect(w.model.selectedPreviewTab == PreviewTabID.artifacts && w.model.errorMessage == nil)
        // A company-bound sheet closes with the company.
        w.model.presentedSheet = .mergeSettings
        await w.model.selectCompany(w.company.id)
        #expect(w.model.presentedSheet == nil)
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
