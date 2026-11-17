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

    // MARK: Fixtures

    func queue(_ m: MergeFixture) -> MergeQueue {
        MergeQueue(store: m.store, paths: m.world.paths, checks: m.world.checks, knownValues: { _ in [] }, clock: { m.now })
    }
    @discardableResult
    func batch(_ q: MergeQueue, _ m: MergeFixture) async throws -> MergeBatchOutcome? {
        await q.runNextBatch(company: try #require(try m.store.company(id: m.company.id)))
    }
    func main(_ m: MergeFixture) throws -> String { try #require(try m.ws.head(of: GitWorkspace.mainRef)) }
    func request(_ m: MergeFixture, _ i: WorkItem) throws -> MergeRequest { try #require(try m.store.latestMergeRequest(itemId: i.id)) }

    /// Two items verified and approved (M-1, M-2 queued, the batch size 2); the engine has not run a merge tick since.
    func twoApproved(_ m: MergeFixture) async throws -> [WorkItem] {
        let a = try m.item("First"), b = try m.item("Second")
        for (i, who, file) in [(a, m.eng, "src/a.txt"), (b, m.eng2, "src/b.txt")] {
            _ = try m.tools(who).call(name: "claim_lease", arguments: ["key": .string(i.key)])
            try m.write(file, "work for \(i.key)", in: m.ws.worktreePath(key: i.key))
            _ = try m.tools(who).call(name: "submit_for_review", arguments: ["key": .string(i.key), "summary": .string("done")])
        }
        try await m.cycle()
        try m.approve(try m.fresh(a)); try m.approve(try m.fresh(b))
        try m.exec("UPDATE company SET mergeBatchSize = 2 WHERE id = ?", [m.company.id])
        return [try m.fresh(a), try m.fresh(b)]
    }

    func mergedEvents(_ m: MergeFixture, _ i: WorkItem) throws -> Int { try m.kinds(i).filter { $0 == .merged }.count }

    /// Everything a finished batch promises, whichever way it got there.
    func expectLanded(_ m: MergeFixture, _ items: [WorkItem], sourceLocation: SourceLocation = #_sourceLocation) throws {
        let tip = try main(m)
        for i in items {
            let item = try m.fresh(i)
            #expect(item.status == .done && item.mergedCommit != nil, "\(i.key) is done", sourceLocation: sourceLocation)
            #expect(try request(m, i).status == .merged && request(m, i).mergedCommit == item.mergedCommit, sourceLocation: sourceLocation)
            #expect(try mergedEvents(m, i) == 1, "one merged event for \(i.key)", sourceLocation: sourceLocation)
            #expect(!m.ws.hasCheckout(key: i.key), "the worktree of \(i.key) is gone", sourceLocation: sourceLocation)
        }
        #expect(try m.store.company(id: m.company.id)?.mainCommit == tip, sourceLocation: sourceLocation)
        #expect(try m.store.company(id: m.company.id)?.pendingMainCommit == nil, sourceLocation: sourceLocation)
        #expect(try m.store.openMergeBatches(companyId: m.company.id).isEmpty, sourceLocation: sourceLocation)
    }

    // MARK: Recovery

    /// The engine stops right after each journal step (a crash); a restarted queue recovers; the end state is the same however far
    /// the batch got: each item merged once, its worktree gone, `main` and the recorded head equal, every batch finished.
    @Test(arguments: MergeStep.allCases.filter { $0 != .done })
    func resumesFromEveryStep(step: MergeStep) async throws {
        let m = try MergeFixture()
        let items = try await twoApproved(m)
        let base = try main(m)
        let q = queue(m)
        if step == .preparing || step == .prepared {
            // The queue never writes these (S1): a row that has one is seeded. Its commit is not adopted.
            let rs = try m.store.claimMergeBatch(companyId: m.company.id, size: 2, now: m.now)
            let id = try #require(rs.first?.batchId)
            let stray = try #require(try m.head(items[0]))
            try m.exec("UPDATE mergeBatch SET step = ?, expectedParent = ?, preparedCommit = ? WHERE id = ?", [step.rawValue, base, stray, id])
        } else {
            m.store.journalProbe.set { $0 == step.rawValue }
            try await batch(q, m)
            m.store.journalProbe.set(nil)
        }
        let open = try m.store.openMergeBatches(companyId: m.company.id)
        #expect(open.count == 1 && open.first?.step == step, "stopped right after \(step.rawValue)")
        // A restart: a fresh queue recovers.
        let q2 = queue(m)
        let company = try #require(try m.store.company(id: m.company.id))
        #expect(await q2.recover(company: company) == 1)
        #expect(try m.store.openMergeBatches(companyId: m.company.id).isEmpty)
        let journal = try #require(try m.store.mergeBatches(companyId: m.company.id).first)
        if step.order < MergeStep.backedUp.order {
            // Nothing had moved: both back in the queue, uncounted, main untouched.
            #expect(try main(m) == base && (try m.store.company(id: m.company.id)?.mainCommit) == base)
            for i in items {
                let r = try request(m, i)
                #expect(r.status == .queued && r.requeues == 0 && r.inconclusive == 0 && r.batchId == nil)
                #expect(try m.fresh(i).status == .inReview && (try m.fresh(i).mergeState) == .pending)
            }
            #expect(journal.step == .done && journal.error == "interrupted")
            let next = try #require(try await batch(q2, m))
            #expect(next.merged.count == 2)
        } else {
            // `main` was about to move or had moved: the landing is finished, not redone.
            #expect(journal.step == .done && journal.error == nil)
            #expect(try await batch(q2, m) == nil)
        }
        try expectLanded(m, items)
        let all = try m.store.mergeBatches(companyId: m.company.id)
        #expect(all.allSatisfy { $0.step == .done })
        // The pre-merge ref names where main was.
        if step.order >= MergeStep.backedUp.order {
            #expect(try m.ws.head(of: "refs/brahma/pre-merge/\(try request(m, items[0]).number)") == base)
        }
    }

    /// `main` moved but the move was not journaled (a crash between the compare-and-swap and the `landed` row): the batch is
    /// still at `landing`; recovery sees the candidate in `main` and goes on from `landed`.
    @Test func crashBetweenTheMoveAndTheJournal() async throws {
        let m = try MergeFixture()
        let items = try await twoApproved(m)
        m.store.journalProbe.set { $0 == "moved" }
        try await batch(queue(m), m)
        m.store.journalProbe.set(nil)
        let open = try #require(try m.store.openMergeBatches(companyId: m.company.id).first)
        #expect(open.step == .landing)
        let landCommit = try #require(open.landCommit)
        #expect(try main(m) == landCommit, "main had moved")
        #expect(try m.store.company(id: m.company.id)?.mainCommit != landCommit, "but was not recorded")
        let q = queue(m)
        #expect(await q.recover(company: try #require(try m.store.company(id: m.company.id))) == 1)
        try expectLanded(m, items)
    }

    /// An unexpected `preparing` or `prepared` row (the retired unattributed-changes commit) is abandoned: nothing is adopted as
    /// `main`, the recorded head is not moved, the requests are queued again.
    @Test func unexpectedPreparingRowMovesNothing() async throws {
        let m = try MergeFixture()
        let items = try await twoApproved(m)
        let base = try main(m)
        let stray = try #require(try m.head(items[1]))
        for step in [MergeStep.preparing, .prepared] {
            let rs = try m.store.claimMergeBatch(companyId: m.company.id, size: 2, now: m.now)
            let id = try #require(rs.first?.batchId)
            try m.exec("UPDATE mergeBatch SET step = ?, expectedParent = ?, preparedCommit = ?, base = ? WHERE id = ?", [step.rawValue, base, stray, base, id])
            #expect(await queue(m).recover(company: try #require(try m.store.company(id: m.company.id))) == 1)
            #expect(try main(m) == base)
            #expect(try m.store.company(id: m.company.id)?.mainCommit == base)
            #expect(try m.store.company(id: m.company.id)?.pendingMainCommit == nil)
            #expect(try items.allSatisfy { try request(m, $0).status == .queued })
        }
    }

    /// Recovery finishes a landing once: a second recovery finds nothing, and the item has one merged event and one activity line.
    @Test func landedCandidateRecordedOnce() async throws {
        let m = try MergeFixture()
        let items = try await twoApproved(m)
        m.store.journalProbe.set { $0 == "landed" }
        try await batch(queue(m), m)
        m.store.journalProbe.set(nil)
        let q = queue(m)
        let company = try #require(try m.store.company(id: m.company.id))
        #expect(await q.recover(company: company) == 1)
        #expect(await q.recover(company: company) == 0)
        try expectLanded(m, items)
        let lines = try m.activity(.merge).filter { $0.text.contains("merged into main") }
        #expect(lines.count == 2, "one line per item")
    }

    @Test func engineErrorRetriesThenFails() async throws {
        let m = try MergeFixture()
        let i = try await m.approved()
        // A commit git does not have: every attempt fails in git, not in the item.
        try m.exec("UPDATE mergeRequest SET headCommit = ? WHERE itemId = ?", [String(repeating: "1", count: 40), i.id])
        let q = queue(m)
        for attempt in 1...2 {
            let outcome = try #require(try await batch(q, m))
            let r = try request(m, i)
            #expect(outcome.requeued == [r.id] && r.status == .queued && r.attempts == attempt && r.requeues == 0)
        }
        let last = try #require(try await batch(q, m))
        let r = try request(m, i)
        #expect(last.failed == [r.id] && r.status == .failed && r.detail?.hasPrefix("git failed 3 times") == true)
        #expect(try m.fresh(i).mergeState == .none)
        #expect(try m.store.openMergeBatches(companyId: m.company.id).isEmpty)
    }

    /// The owner's stop at `checked` leaves the batch there; after the resume the first thing the queue does is recover, then it
    /// lands what was queued.
    @Test func stopResumesFromJournal() async throws {
        let m = try MergeFixture()
        let items = try await twoApproved(m)
        let (store, now) = (m.store, m.now)
        store.journalProbe.set { label in
            if label == "checked" { _ = try? store.emergencyStop(note: nil, by: "owner", now: now) }
            return false
        }
        let q = queue(m)
        let first = try #require(try await batch(q, m))
        store.journalProbe.set(nil)
        #expect(first.merged.isEmpty)
        await q.stopAll(reason: "owner")
        let open = try #require(try m.store.openMergeBatches(companyId: m.company.id).first)
        #expect(open.step == .checked, "left at its last journaled step")
        #expect(try items.allSatisfy { try request(m, $0).status == .queued && request(m, $0).requeues == 0 })
        // Stopped: nothing is claimed or recovered.
        #expect(try await batch(q, m) == nil)
        #expect(try m.store.openMergeBatches(companyId: m.company.id).count == 1)
        try m.store.resumeAfterStop(now: m.now)
        let second = try #require(try await batch(q, m))
        #expect(second.merged.count == 2)
        try expectLanded(m, items)
        let all = try m.store.mergeBatches(companyId: m.company.id)
        #expect(all.count == 2 && all.contains { $0.error == "interrupted" })
    }

    /// A request left `running` or `landing` with no batch row (older engine, lost journal) is queued again at recovery.
    @Test func orphanRunningRequestsAreRequeued() async throws {
        let m = try MergeFixture()
        let i = try await m.approved()
        try m.exec("UPDATE mergeRequest SET status = 'landing' WHERE itemId = ?", [i.id])
        try m.exec("UPDATE workItem SET mergeState = 'verifying' WHERE id = ?", [i.id])
        #expect(await queue(m).recover(company: try #require(try m.store.company(id: m.company.id))) == 0)
        let r = try request(m, i)
        #expect(r.status == .queued && r.requeues == 0)
        #expect(try m.fresh(i).mergeState == .pending)
    }

    /// `Orchestrator.start()` recovers the journal before anything is scheduled.
    @Test func engineStartRecoversTheJournal() async throws {
        let m = try MergeFixture()
        let items = try await twoApproved(m)
        let rs = try m.store.claimMergeBatch(companyId: m.company.id, size: 2, now: m.now)
        let id = try #require(rs.first?.batchId)
        try m.store.advanceBatch(id: id, to: .rebased, candidates: [:], now: m.now)
        try await m.world.orchestrator.start()
        let batch = try #require(try m.store.mergeBatch(id: id))
        #expect(batch.step == .done && batch.error == "interrupted")
        #expect(try items.allSatisfy { try request(m, $0).status == .queued })
    }

    @Test func stepsAreOrdered() {
        let order = MergeStep.allCases
        #expect(order.map(\.rawValue) == ["claimed", "preparing", "prepared", "rebased", "checked", "backedUp", "landing", "landed",
                                          "recorded", "cleaned", "done"])
        #expect(order == order.sorted { $0.order < $1.order })
    }
}
