import Foundation
import Testing
import GRDB
import BrahmaCore
@testable import BrahmaAppModel

@MainActor @Suite(.scratch) struct LiveModelLayerTests {
    @discardableResult
    static func release(_ w: WorkWorld, _ number: Int, _ status: ReleaseStatus, _ change: (inout Release) -> Void = { _ in }) throws -> Release {
        let r = try ReleaseFixtures.release(number, status, companyId: w.company.id, proposer: w.eng.id, change)
        try w.store.writer.write { db in try r.insert(db) }
        return r
    }

    static func webSurface(_ w: WorkWorld) throws -> PreviewSurface {
        try w.store.upsertPreviewSurface(companyId: w.company.id, by: .owner,
                                         PreviewDraft(name: "web", run: "npm start", url: "http://127.0.0.1:{port}/"))
    }

    @Test func snapshotCarriesPreviewAndReleases() async throws {
        let w = try await WorkWorld.make()
        let surface = try Self.webSurface(w)
        try Self.release(w, 1, .deployed) { $0.productionURL = "https://acme.pages.dev" }
        await w.refresh()
        #expect(w.model.snapshot.preview.surfaces.map(\.id) == [surface.id])
        #expect(w.model.snapshot.preview.live == URL(string: "https://acme.pages.dev"))
        #expect(w.model.previewTabs.map(\.title) == ["WEB", "LIVE"])
        #expect(w.model.selectedPreviewTab == nil)
        // No running surface: the default selection is LIVE.
        #expect(w.model.previewBody == .web(url: URL(string: "https://acme.pages.dev")!, origin: URL(string: "https://acme.pages.dev")!,
                                            builtBy: "R-1"))
        #expect(w.model.previewBody(forTab: PreviewTabID.surface(surface.id)) == .status(title: "WEB STOPPED", detail: nil, logTail: []))
        #expect(w.model.releaseRows.map(\.ref) == ["R-1"])
        #expect(w.model.snapshot.releases.hosting == nil)
        #expect(w.model.mainHealth.title == "NO SMOKE CHECK")

        var form = HostingForm(w.model.snapshot.releases.hosting, companySlug: w.company.slug)
        form.productionURL = "https://acme.pages.dev"
        await w.model.saveHosting(form)
        #expect(w.model.errorMessage == nil)
        #expect(w.model.snapshot.releases.hosting?.productionURL == "https://acme.pages.dev")
        form.productionURL = "http://nope"
        await w.model.saveHosting(form)
        #expect(w.model.errorMessage == "production URL must start with https://")
    }

    @Test func snapshotLoadsLogTailThroughCore() async throws {
        let w = try await WorkWorld.make()
        let surface = try Self.webSurface(w)
        let layout = EngineLayout(workspace: URL(fileURLWithPath: w.company.workspacePath, isDirectory: true))
        try FileManager.default.createDirectory(at: layout.previewLogs, withIntermediateDirectories: true)
        let lines = (1...50).map { "build line \($0)" }
        try (lines.joined(separator: "\n") + "\n").write(to: layout.previewLog(name: "web"), atomically: true, encoding: .utf8)
        let state = PreviewState(surfaceId: surface.id, companyId: w.company.id, status: .building, commit: "abcdef1234567",
                                 logPath: layout.previewLog(name: "web").path, updatedAt: Date())
        try w.store.savePreviewState(state)
        await w.refresh()
        #expect(w.model.previewBody(forTab: PreviewTabID.surface(surface.id))
                == .status(title: "BUILDING WEB AT abcdef1", detail: nil, logTail: Array(lines.suffix(40))))

        // A symlinked logs directory is refused by the core reader: no tail.
        let elsewhere = try tempDir()
        try FileManager.default.copyItem(at: layout.previewLog(name: "web"), to: elsewhere.appending(path: "web.log"))
        try FileManager.default.removeItem(at: layout.previewLogs)
        try FileManager.default.createSymbolicLink(at: layout.previewLogs, withDestinationURL: elsewhere)
        await w.refresh()
        #expect(w.model.snapshot.preview.logTails[state.logPath!] == [])
        #expect(w.model.previewBody(forTab: PreviewTabID.surface(surface.id))
                == .status(title: "BUILDING WEB AT abcdef1", detail: nil, logTail: []))
    }

    @Test func approveDeployFromApp() async throws {
        let w = try await WorkWorld.make()
        let ask = try w.store.propose(companyId: w.company.id, by: .agent(w.eng.id), kind: .deploy, risk: .high, title: "Deploy 0.1.0",
                                      summary: "notes", payload: AskPayload(proposal: "wrangler pages deploy dist"), viaOwner: true,
                                      quotaExempt: .devHook)
        let r = try Self.release(w, 1, .proposed) { $0.askId = ask.id }
        await w.refresh()
        let card = try #require(w.model.deployCard(for: ask.id))
        #expect(card.commands == "wrangler pages deploy dist" && card.version == "release 0.1.0")
        await w.model.approveDeploy(askId: ask.id)
        #expect(w.model.errorMessage == nil)
        #expect(try w.store.release(companyId: w.company.id, ref: r.ref)?.status == .approved)
        #expect(try w.store.ask(id: ask.id)?.status == .approved)
        #expect(w.model.deployCard(for: ask.id) == nil)
    }

    @Test func rollbackFromApp() async throws {
        let w = try await WorkWorld.make()
        try Self.release(w, 1, .deployed)
        await w.refresh()
        #expect(w.model.releaseRows.first?.canRollBack == true)
        await w.model.rollback(releaseRef: "R-1")
        #expect(w.model.errorMessage == nil)
        #expect(try w.store.release(companyId: w.company.id, ref: "R-1")?.rollbackStatus == .requested)
        #expect(w.model.releaseRows.first?.rollbackTitle == "ROLLBACK REQUESTED")

        let w2 = try await WorkWorld.make()
        try Self.release(w2, 1, .proposed)
        await w2.refresh()
        await w2.model.rollback(releaseRef: "R-1")
        #expect(w2.model.errorMessage == "R-1 is proposed; only deployed, interrupted or failed releases roll back")
    }

    @Test func completeHumanTaskFromApp() async throws {
        let w = try await WorkWorld.make()
        let vault = MemoryVault()
        w.model.ownerSecretVault = vault
        let ask = try w.store.fileTemplateTask(companyId: w.company.id, requesterId: "system", template: .stripeTestKeys)
        await w.refresh()
        let card = try #require(w.model.humanTaskCard(for: ask.id))
        var form = HumanTaskForm(values: [:])
        await w.model.completeHumanTask(askId: ask.id, form: form)
        #expect(w.model.errorMessage == "Test secret key is required")
        w.model.errorMessage = nil
        form.values = ["STRIPE_TEST_SECRET_KEY": "sk_test_51abcdefghijklmnop", "STRIPE_TEST_PUBLISHABLE_KEY": "pk_test_51abcdefghijklmnop"]
        #expect(form.validate(card) == nil)
        await w.model.completeHumanTask(askId: ask.id, form: form)
        #expect(w.model.errorMessage == nil)
        #expect(try w.store.ask(id: ask.id)?.status == .answered)
        #expect(try vault.value(companyId: w.company.id, name: "STRIPE_TEST_SECRET_KEY") == "sk_test_51abcdefghijklmnop")
        #expect(w.model.humanTaskCard(for: ask.id) == nil)

        let other = try w.store.fileTemplateTask(companyId: w.company.id, requesterId: "system", template: .launchPost,
                                                 args: ["text": "We launched"])
        await w.refresh()
        await w.model.declineHumanTask(askId: other.id, note: "not yet")
        #expect(try w.store.ask(id: other.id)?.status == .rejected)
    }

    @Test func restartWritesFlag() async throws {
        let w = try await WorkWorld.make()
        let surface = try Self.webSurface(w)
        await w.refresh()
        await w.model.restartPreview(surfaceId: surface.id)
        #expect(w.model.errorMessage == nil)
        #expect(try w.store.previewStates(companyId: w.company.id)[surface.id]?.restartRequestedAt != nil)
    }

    @Test func selectTargets() async throws {
        #expect(SelectTarget("releases") == .releases)
        #expect(SelectTarget("preview:WEB") == .preview(name: "web"))
        #expect(SelectTarget("preview:") == nil)
        let w = try await WorkWorld.make()
        let surface = try Self.webSurface(w)
        await w.refresh()
        w.model.apply(.releases)
        #expect(w.model.sidebarSelection == .releases)
        w.model.apply(.preview(name: "web"))
        #expect(w.model.sidebarSelection == .missionControl)
        #expect(w.model.selectedPreviewTab == PreviewTabID.surface(surface.id))
        w.model.apply(.preview(name: "live"))
        #expect(w.model.selectedPreviewTab == PreviewTabID.live)
        w.model.apply(.preview(name: "nope"))
        #expect(w.model.errorMessage == "No preview nope")
        // Releases sit under Work; the chip counts open releases.
        try Self.release(w, 1, .proposed)
        await w.refresh()
        #expect(w.model.openReleaseCount == 1)
    }
}
