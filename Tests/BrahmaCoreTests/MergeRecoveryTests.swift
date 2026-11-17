import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// The merge journal and recovery (Plan 4a Task 2): every batch is written step by step (`mergeBatch`); a crash or the owner's
/// stop leaves it at its last step and `MergeQueue.recover` finishes or abandons it.
@Suite(.scratch, .serialized) struct MergeRecoveryTests {
    @Test func claimWritesTheBatchRow() async throws {
        let m = try MergeFixture()
        let i = try await m.approved()
        let claimed = try m.store.claimMergeBatch(companyId: m.company.id, size: 1, now: m.now)
        let r = try #require(claimed.first)
        let batchId = try #require(r.batchId)
        let batch = try #require(try m.store.mergeBatch(id: batchId))
        #expect(batch.step == .claimed && batch.number == 1 && batch.companyId == m.company.id)
        #expect(batch.requestIds == [r.id] && batch.candidates.isEmpty && batch.landedIds.isEmpty && batch.finishedAt == nil)
        #expect(try m.store.openMergeBatches(companyId: m.company.id).map(\.id) == [batch.id])
        _ = i
    }

    @Test func journalNeverMovesBackwards() async throws {
        let m = try MergeFixture()
        _ = try await m.approved()
        let r = try #require(try m.store.claimMergeBatch(companyId: m.company.id, size: 1, now: m.now).first)
        let id = try #require(r.batchId)
        try m.store.advanceBatch(id: id, to: .rebased, candidates: [r.id: "abc"], now: m.now)
        #expect(try m.store.mergeBatch(id: id)?.candidates == [r.id: "abc"])
        #expect(throws: WorkError.conflict("batch already at rebased")) { try m.store.advanceBatch(id: id, to: .claimed, now: m.now) }
        // The same step again only updates its fields.
        try m.store.advanceBatch(id: id, to: .rebased, candidates: [r.id: "def"], now: m.now)
        #expect(try m.store.mergeBatch(id: id)?.candidates == [r.id: "def"])
        try m.store.advanceBatch(id: id, to: .checked, landCommit: "def", landedIds: [r.id], now: m.now)
        let checked = try #require(try m.store.mergeBatch(id: id))
        #expect(checked.step == .checked && checked.landCommit == "def" && checked.landedIds == [r.id])
        #expect(throws: WorkError.conflict("batch already at checked")) { try m.store.advanceBatch(id: id, to: .rebased, now: m.now) }
        try m.store.advanceBatch(id: id, to: .done, error: "interrupted", now: m.now)
        let done = try #require(try m.store.mergeBatch(id: id))
        #expect(done.step == .done && done.error == "interrupted" && done.finishedAt != nil)
        #expect(try m.store.openMergeBatches(companyId: m.company.id).isEmpty)
        #expect(throws: WorkError.conflict("batch already at done")) { try m.store.advanceBatch(id: id, to: .landed, now: m.now) }
        // Nothing the journal does moves main or the recorded head.
        #expect(try m.store.company(id: m.company.id)?.mainCommit == (try m.ws.head(of: GitWorkspace.mainRef)))
    }

    @Test func stepsAreOrdered() {
        let order = MergeStep.allCases
        #expect(order.map(\.rawValue) == ["claimed", "preparing", "prepared", "rebased", "checked", "backedUp", "landing", "landed",
                                          "recorded", "cleaned", "done"])
        #expect(order == order.sorted { $0.order < $1.order })
    }
}
