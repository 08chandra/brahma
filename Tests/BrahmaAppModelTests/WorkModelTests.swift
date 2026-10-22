import Testing
import Foundation
import BrahmaCore
@testable import BrahmaAppModel

private let passing = DoctorReport(cliVersion: "2.1.306", items: [DoctorItem(name: "probe", status: .pass, detail: "ok")],
                                   checkedAt: Date())
private let failing = DoctorReport(cliVersion: "2.1.306", items: [DoctorItem(name: "probe", status: .fail, detail: "not logged in")],
                                   checkedAt: Date())

@MainActor @Suite struct WorkModelTests {
    @Test func ownerCreatesAndEditsItem() async throws {
        let w = try await WorkWorld.make()
        let epic = try w.item("Epic", type: .epic)
        var form = ItemForm()
        form.title = "Add login"
        form.type = "story"
        form.description = "Users sign in"
        form.checkCommand = "swift test --filter Login"
        form.priority = 1
        form.tier = .s
        form.assignee = "@eng-1"
        form.reviewer = "eng-2"
        form.parentKey = epic.key.lowercased()
        form.startReady = true
        let created = try #require(await w.model.createItem(form))
        #expect(w.model.errorMessage == nil)
        #expect(created.authorId == "owner" && created.status == .ready && created.priority == 1 && created.tier == .s)
        #expect(created.ownerId == w.eng.id && created.reviewerId == w.eng2.id && created.parentId == epic.id)
        #expect(created.checkSpec?.command == "swift test --filter Login")
        #expect(w.model.selectedItemKey == created.key)
        #expect(w.model.selectedItem?.id == created.id)

        // Editing changes only what changed: the check keeps its revision.
        var edit = ItemForm(item: created, handles: w.model.handles, parentKey: epic.key)
        edit.title = "Add login page"
        edit.priority = 0
        edit.intensity = .thorough
        let updated = try #require(await w.model.updateItem(key: created.key, edit))
        #expect(updated.title == "Add login page" && updated.priority == 0 && updated.intensity == .thorough)
        #expect(updated.checkRevision == created.checkRevision)
        #expect(updated.ownerId == w.eng.id)
        let moved = try #require(await w.model.moveItem(key: created.key, to: .backlog))
        #expect(moved.status == .backlog)
        let prioritized = try #require(await w.model.setPriority(key: created.key, 3))
        #expect(prioritized.priority == 3)
        let intense = try #require(await w.model.setIntensity(key: created.key, .auto))
        #expect(intense.intensity == .auto)
        #expect(w.model.backlogRows.contains { $0.key == created.key && $0.depth == 1 })

        // A form that fails validation never reaches the store.
        var bad = ItemForm()
        bad.title = " "
        #expect(await w.model.createItem(bad) == nil)
        #expect(w.model.errorMessage == "Title is required")
    }

    @Test func ownerCannotMoveToDone() async throws {
        let w = try await WorkWorld.make()
        let item = try w.item("Ready one", status: .ready)
        for target in [WorkItemStatus.done, .inReview] {
            w.model.errorMessage = nil
            #expect(await w.model.moveItem(key: item.key, to: target) == nil)
            #expect(w.model.errorMessage != nil)
            #expect(try w.store.workItem(id: item.id)?.status == .ready)
        }
        w.model.errorMessage = nil
        #expect(await w.model.moveItem(key: item.key, to: .blocked)?.status == .blocked)
        #expect(await w.model.moveItem(key: item.key, to: .ready)?.status == .ready)
        #expect(w.model.errorMessage == nil)
    }

    @Test func setManagerSurfacesOrgError() async throws {
        let w = try await WorkWorld.make()
        await w.model.setManager(agentId: w.eng.id, managerId: w.cto.id)
        await w.model.setManager(agentId: w.cto.id, managerId: w.ceo.id)
        #expect(w.model.errorMessage == nil)
        #expect(w.model.detail(agentId: w.eng.id)?.managerHandle == "cto")
        #expect(w.model.detail(agentId: w.cto.id)?.reportCount == 1)
        // A loop is refused with a plain sentence.
        await w.model.setManager(agentId: w.ceo.id, managerId: w.eng.id)
        #expect(w.model.errorMessage == "That would make a reporting loop: a manager cannot report to someone below them.")
        // A killed manager is refused.
        w.model.errorMessage = nil
        await w.model.kill(agentId: w.eng2.id)
        await w.model.setManager(agentId: w.cto.id, managerId: w.eng2.id)
        #expect(w.model.errorMessage == "That manager has left the company.")
        // The span limit names the manager.
        w.model.errorMessage = nil
        for i in 0..<7 { _ = try w.store.hire(companyId: w.company.id, name: "dev-\(i)", role: "engineer", model: "sonnet", managerId: w.ceo.id) }
        await w.model.tick(forceSnapshot: true)
        await w.model.setManager(agentId: w.eng.id, managerId: w.ceo.id)
        #expect(w.model.errorMessage?.hasPrefix("@ceo would have") == true)
        #expect(w.model.errorMessage?.hasSuffix("direct reports; the limit is 7.") == true)
    }

    @Test func selectItemTarget() async throws {
        let w = try await WorkWorld.make()
        let item = try w.item("Find me")
        await w.refresh()
        #expect(SelectTarget("backlog") == .backlog && SelectTarget("board") == .board && SelectTarget("inbox") == .inbox)
        #expect(SelectTarget("item:acme-3") == .item(key: "ACME-3"))
        #expect(SelectTarget("new-item") == .sheet(.newItem))
        #expect(SelectTarget("item:") == nil)
        w.model.apply(.item(key: item.key))
        #expect(w.model.sidebarSelection == .backlog)
        #expect(w.model.selectedItemKey == item.key)
        #expect(w.model.selectedItem?.title == "Find me")
        w.model.apply(.board); #expect(w.model.sidebarSelection == .board)
        w.model.apply(.inbox); #expect(w.model.sidebarSelection == .inbox)
        #expect(w.model.chat == nil)
        // Switching company forgets the open item.
        let other = try w.store.createCompany(name: "Other", goal: "g", workspacesRoot: w.paths.workspaces)
        await w.model.selectCompany(other.id)
        #expect(w.model.selectedItemKey == nil)
        let parsed = LaunchOptions.parse(["brahma", "--select", "item:acme-9"])
        #expect(parsed.select == .item(key: "ACME-9"))
    }

    @Test func snapshotTruncationIsVisible() async throws {
        let w = try await WorkWorld.make()
        for i in 1...3 { try w.item("Item \(i)") }
        let limited = try WorkSnapshot.load(store: w.store, companyId: w.company.id, limit: 2)
        #expect(limited.items.count == 2 && limited.totalItems == 3 && limited.truncated)
        let full = try WorkSnapshot.load(store: w.store, companyId: w.company.id)
        #expect(full.items.count == 3 && full.totalItems == 3 && !full.truncated)
        #expect(full.timeZone == w.store.ownerTimeZone())
        #expect(w.model.ownerTimeZone == w.store.ownerTimeZone())
    }

    @Test func retryEngineClearsAccountHold() async throws {
        let w = try await WorkWorld.make()
        let tools = Result<EngineTools, EngineSetupError>.success(EngineTools(claudePath: "claude", mcpExecutable: "/tmp/brahma"))
        let ok = EngineHost(paths: w.paths, store: w.store, makeRunner: { _ in StubRunner(mode: .hangUntilCancelled) },
                            tickInterval: .milliseconds(50), probe: { _ in passing }, ownerKeyStore: InMemoryOwnerKeyStore())
        await ok.start(tools: tools)
        w.model.engine = ok
        try w.store.setHold(reason: .account, detail: "logged out", now: Date())
        await w.refresh()
        #expect(w.model.work.hold?.reason == .account)
        await w.model.retryEngine()
        #expect(w.model.errorMessage == nil)
        #expect(try w.store.engineHold() == nil)
        #expect(w.model.work.hold == nil && w.model.holdBanner == nil)
        await ok.stop()
    }

    @Test func retryEngineKeepsHoldWhenDoctorFails() async throws {
        let w = try await WorkWorld.make()
        let tools = Result<EngineTools, EngineSetupError>.success(EngineTools(claudePath: "claude", mcpExecutable: "/tmp/brahma"))
        let host = EngineHost(paths: w.paths, store: w.store, makeRunner: { _ in StubRunner(mode: .hangUntilCancelled) },
                              tickInterval: .milliseconds(50), probe: { _ in failing }, ownerKeyStore: InMemoryOwnerKeyStore())
        await host.start(tools: tools)   // the failed probe leaves it .failed but remembers where Claude is
        w.model.engine = host
        try w.store.setHold(reason: .cli, detail: "2.1.306 → 2.1.307", now: Date())
        await w.model.retryEngine()
        #expect(w.model.errorMessage?.hasPrefix("Claude Code check failed: not logged in") == true)
        #expect(try w.store.engineHold()?.reason == .cli)
    }
}
