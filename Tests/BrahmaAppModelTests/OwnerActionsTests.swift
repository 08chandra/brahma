import Testing
import Foundation
import GRDB
import BrahmaCore
@testable import BrahmaAppModel

/// Task 16a: what the owner can do from the backlog, the board and the inspector.
@MainActor @Suite struct OwnerActionsTests {
    private let all: [WorkItemStatus] = [.backlog, .ready, .inProgress, .inReview, .blocked, .done]

    @Test func everyOfferedMoveIsAcceptedByTheStore() async throws {
        let w = try await WorkWorld.make()
        var checked = 0
        for from in all {
            for target in OwnerMoves.targets(from: from) {
                let item = try w.item("\(from.rawValue) to \(target.rawValue)", status: .backlog)
                try w.setStatus(item, from)
                w.model.errorMessage = nil
                let moved = await w.model.moveItem(key: item.key, to: target)
                #expect(moved?.status == target, "\(from.rawValue) -> \(target.rawValue) was offered but refused: \(w.model.errorMessage ?? "-")")
                checked += 1
            }
        }
        #expect(checked == all.map { OwnerMoves.targets(from: $0).count }.reduce(0, +))
    }

    @Test func inReviewAndDoneAreNeverOffered() {
        for from in all {
            #expect(!OwnerMoves.targets(from: from).contains(.inReview), "\(from.rawValue)")
            #expect(!OwnerMoves.targets(from: from).contains(.done), "\(from.rawValue)")
            #expect(!OwnerMoves.allows(from: from, to: .inReview)); #expect(!OwnerMoves.allows(from: from, to: .done))
        }
    }

    @Test func itemDetailLoadsEventsDependenciesAndTheWorktreePath() async throws {
        let w = try await WorkWorld.make()
        let dep = try w.item("First", status: .ready)
        let item = try w.item("Second", status: .ready)
        try w.setStatus(item, .inProgress)
        try w.store.addDependency(itemId: item.id, dependsOn: dep.id, by: .owner)
        let epic = try w.item("Epic", type: .epic)
        _ = try w.store.updateWorkItem(id: item.id, by: .owner, patch: WorkItemPatch(parentId: .some(epic.id)))
        let fresh = try #require(try w.store.workItem(id: item.id))
        let detail = try ItemDetail.load(store: w.store, item: fresh, handles: w.model.handles, workspace: w.company.workspacePath)
        #expect(detail.key == item.key)
        #expect(detail.dependencies.map(\.key) == [dep.key])
        #expect(detail.parentKey == epic.key)
        #expect(!detail.events.isEmpty); #expect(detail.events.count <= ItemDetail.eventLimit)
        #expect(detail.branch == "item/\(item.key)")
        // The path is the git layer's, not a literal.
        let expected = GitWorkspace(root: URL(fileURLWithPath: w.company.workspacePath, isDirectory: true)).worktreePath(key: item.key).path
        #expect(detail.worktree == expected)
        // A backlog item without a lease or branch shows neither.
        let backlog = try w.item("Idle")
        let quiet = try ItemDetail.load(store: w.store, item: backlog, handles: [:], workspace: w.company.workspacePath)
        #expect(quiet.branch == nil); #expect(quiet.worktree == nil)
        // Through the model, off the main actor.
        await w.refresh()
        let viaModel = await w.model.itemDetail(key: item.key)
        #expect(viaModel?.worktree == expected)
    }

    @Test func autoMergeToggleGoesThroughTheStoreAndRevokes() async throws {
        let w = try await WorkWorld.make()
        #expect(w.model.autoMergeSmall == false, "off by default")
        await w.model.setAutoMergeSmall(true)
        #expect(w.model.autoMergeSmall == true)
        #expect(try w.store.company(id: w.company.id)?.autoMergeSmall == true)
        // An auto-approved item waiting to land is taken back when the owner switches it off.
        let item = try w.item("Small change", status: .ready)
        try await w.store.writer.write { db in
            try db.execute(sql: """
                UPDATE workItem SET status = 'inReview', autoApproved = 1, mergeState = 'pending', reviewRound = 1, reviewedRound = 1
                WHERE id = ?
                """, arguments: [item.id])
        }
        await w.model.setAutoMergeSmall(false)
        #expect(w.model.autoMergeSmall == false)
        let after = try #require(try w.store.workItem(id: item.id))
        #expect(after.autoApproved == false); #expect(after.mergeState == .none); #expect(after.reviewedRound == 0)
    }

    @Test func confirmReportedPlanTakesTheReportedTier() async throws {
        let w = try await WorkWorld.make()
        try w.store.setPlanTier(.max20x)
        try w.store.saveProbe(DoctorReport(cliVersion: "2.1.306", items: [DoctorItem(name: "probe", status: .pass, detail: "ok")],
                                           checkedAt: Date(), reportedSubscription: "pro"))
        await w.model.confirmReportedPlan()
        #expect(w.store.planTier() == .pro)
        #expect(w.model.errorMessage == nil)
        // A subscription the engine cannot map changes nothing.
        try w.store.saveProbe(DoctorReport(cliVersion: "2.1.306", items: [], checkedAt: Date(), reportedSubscription: "enterprise"))
        await w.model.confirmReportedPlan()
        #expect(w.store.planTier() == .pro)
    }

    @Test func afterTickRunsAfterEveryTick() async throws {
        let w = try await WorkWorld.make()
        var runs = 0
        w.model.afterTick = { runs += 1 }
        await w.model.tick()
        await w.model.tick(forceSnapshot: true)
        #expect(runs == 2)
        w.model.afterTick = nil
        await w.model.tick()
        #expect(runs == 2)
    }
}
