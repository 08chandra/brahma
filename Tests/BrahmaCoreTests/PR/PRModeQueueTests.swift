import Foundation
import Testing
import GRDB
@testable import BrahmaCore

/// The merge queue in PR mode (Plan X8 Task 2, spec §8.5.1): one request per batch, rebased and checked onto the fetched remote
/// `main`, the checked commit handed to the PR landing machine, local `main` never moved, the journal ending
/// `handedToPR` → `done`.
@Suite(.scratch, .serialized) struct PRModeQueueTests {
    /// Records each hand-off.
    final class FakeLanding: PRLandingBeginning, @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [(itemId: String, sha: String)] = []
        var begins: [(itemId: String, sha: String)] { lock.withLock { seen } }
        func begin(item: WorkItem, verifiedSHA: String) async { lock.withLock { seen.append((item.id, verifiedSHA)) } }
    }

    /// Answers with the tip `next` gives (it may plant a commit first), and counts the fetches.
    final class FakeRemoteMain: RemoteMainFetching, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        let next: @Sendable () throws -> String
        init(tip: String) { next = { tip } }
        init(_ next: @escaping @Sendable () throws -> String) { self.next = next }
        var fetches: Int { lock.withLock { count } }
        func fetch(companyId: String) async throws -> FetchResult {
            lock.withLock { count += 1 }
            let tip = try next()
            return FetchResult(newTip: tip, commits: [tip], rewound: false)
        }
    }

    func queue(_ m: MergeFixture, landing: FakeLanding?, fetch: FakeRemoteMain?) async -> MergeQueue {
        let q = MergeQueue(store: m.store, paths: m.world.paths, checks: m.world.checks, knownValues: { _ in [] }, clock: { m.now })
        await q.wirePR(landing: landing, remoteMain: fetch)
        return q
    }
    func company(_ m: MergeFixture) throws -> Company { try #require(try m.store.company(id: m.company.id)) }
    func main(_ m: MergeFixture) throws -> String { try #require(try m.ws.head(of: GitWorkspace.mainRef)) }
    func request(_ m: MergeFixture, _ i: WorkItem) throws -> MergeRequest { try #require(try m.store.latestMergeRequest(itemId: i.id)) }
    func setPR(_ m: MergeFixture) throws { try m.store.setLanding(.pr, engineMerge: false, companyId: m.company.id, by: .owner) }

    /// Two items verified and approved, the company's batch size 2 and in PR mode; no merge tick has run since.
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
        try setPR(m)
        return [try m.fresh(a), try m.fresh(b)]
    }

    /// A teammate's commit on top of `parent`, as the fetch would bring it: under the engine's remote-main ref, not on `main`.
    static func remoteCommit(_ m: MergeFixture, parent: String, file: String) throws -> String {
        let fx = GitFixture(existing: m.root)
        let sha = try fx.plantCommit(parent: parent, path: file, text: "from a teammate\n", message: "teammate's change")
        try fx.git(["update-ref", "refs/brahma/remote/main", sha])
        return sha
    }

    @Test func prModeBatchSizeIsOne() async throws {
        let m = try MergeFixture()
        let items = try await twoApproved(m)
        let base = try main(m)
        #expect(try company(m).mergeBatchSize == 2, "the knob says 2")
        // Through the engine itself: the orchestrator's queue, wired, run by a tick.
        let landing = FakeLanding()
        await m.world.orchestrator.mergeQueue.wirePR(landing: landing, remoteMain: FakeRemoteMain(tip: base))
        try await m.cycle()
        #expect(landing.begins.map(\.itemId) == [items[0].id], "one request per batch")
        let first = try #require(try m.store.mergeBatches(companyId: m.company.id).first)
        #expect(first.requestIds == [try request(m, items[0]).id] && first.step == .done && first.error == nil)
        #expect(try request(m, items[0]).status == .handedToPR && request(m, items[1]).status == .queued)
        // A hand-off is progress: the company is not backed off, so the next tick takes the second item.
        #expect(await m.world.orchestrator.mergeBackoff[m.company.id] == nil)
        try await m.cycle()
        #expect(landing.begins.map(\.itemId) == items.map(\.id))
        #expect(try m.store.mergeBatches(companyId: m.company.id).allSatisfy { $0.requestIds.count == 1 && $0.step == .done })
        #expect(try main(m) == base)
        // Nothing left for the queue: the handed-off requests are not work, and not orphans to put back.
        #expect(try !m.store.hasMergeWork(companyId: m.company.id))
        #expect(try m.store.orphanedMergeRequestIds(companyId: m.company.id).isEmpty)
        #expect(try m.store.unqueuedApprovals(companyId: m.company.id).isEmpty, "a handed-off approval is never adopted again")
    }

    /// Spec §8.5.1 step 2: the batch base is the fetched remote `main`, not local `main`.
    @Test func rebasesOntoFetchedRemoteMain() async throws {
        let m = try MergeFixture()
        let items = try await twoApproved(m)
        let base = try main(m)
        let landing = FakeLanding()
        let fetch = FakeRemoteMain { try Self.remoteCommit(m, parent: base, file: "upstream.txt") }
        let q = await queue(m, landing: landing, fetch: fetch)
        let outcome = try #require(await q.runNextBatch(company: try company(m)))
        #expect(outcome.handedToPR == [try request(m, items[0]).id] && outcome.merged.isEmpty, "\(outcome)")
        #expect(fetch.fetches == 1)
        let tip = try m.ws.head(of: "refs/brahma/remote/main")
        let handed = try #require(landing.begins.first)
        let fx = GitFixture(existing: m.root)
        #expect(try fx.git(["rev-parse", "\(handed.sha)^"]) == tip, "the verified commit sits on the fetched tip")
        #expect(try fx.git(["show", "\(handed.sha):upstream.txt"]) == "from a teammate")
        #expect(try fx.git(["show", "\(handed.sha):src/a.txt"]) == "work for \(items[0].key)")
        let batch = try #require(try m.store.mergeBatches(companyId: m.company.id).first)
        #expect(batch.base == tip && batch.landCommit == handed.sha)
        #expect(try request(m, items[0]).baseCommit == tip && request(m, items[0]).candidateCommit == handed.sha)
        #expect(try main(m) == base, "local main is not the base and does not move")
    }

    @Test func localMainNeverCommittedInPRMode() async throws {
        let m = try MergeFixture()
        let items = try await twoApproved(m)
        let base = try main(m)
        let recorded = try company(m).mainCommit
        // Unwired: the queue holds, claims nothing, lands nothing locally.
        let bare = await queue(m, landing: nil, fetch: nil)
        let held = try #require(await bare.runNextBatch(company: try company(m)))
        #expect(held.held == "PR landing unavailable: no landing machine" && held.merged.isEmpty && held.handedToPR.isEmpty)
        #expect(try company(m).mergeHold == "PR landing unavailable: no landing machine")
        #expect(try request(m, items[0]).status == .queued && main(m) == base)
        let halfWired = await queue(m, landing: FakeLanding(), fetch: nil)
        try m.store.setMergeHold(companyId: m.company.id, reason: nil, now: m.now)
        #expect(try #require(await halfWired.runNextBatch(company: try company(m))).held == "PR landing unavailable: no remote main fetch")
        // Wired: the hold lifts itself, and the hand-off moves nothing locally even when the remote moved.
        let landing = FakeLanding()
        let fetch = FakeRemoteMain { try Self.remoteCommit(m, parent: base, file: "remote.txt") }
        let q = await queue(m, landing: landing, fetch: fetch)
        let outcome = try #require(await q.runNextBatch(company: try company(m)))
        #expect(outcome.handedToPR.count == 1 && outcome.held == nil)
        let c = try company(m)
        #expect(c.mergeHold == nil, "the PR hold lifted itself")
        #expect(try main(m) == base && c.mainCommit == recorded && c.pendingMainCommit == nil, "local main never moved")
        #expect(try m.ws.head(of: "refs/brahma/pre-merge/\(try request(m, items[0]).number)") == nil, "no pre-merge backup: nothing landed")
        let item = try m.fresh(items[0])
        #expect(item.status == .inReview && item.mergedCommit == nil, "the item completes only when the remote main carries it")
        #expect(m.ws.hasCheckout(key: item.key), "the worktree stays: a red check upstream goes back to the holder")
        #expect(try request(m, items[0]).mergedCommit == nil)
        // Recovery after the hand-off has nothing to finish and moves nothing.
        #expect(await q.recover(company: try company(m)) == 0)
        #expect(await (await queue(m, landing: landing, fetch: fetch)).recover(company: try company(m)) == 0)
        #expect(try main(m) == base && landing.begins.count == 1)
        let lines = try m.activity(.merge).map(\.text)
        #expect(lines.contains { $0.hasPrefix("\(items[0].key) checked and handed to a pull request") }, "\(lines)")
        #expect(!lines.contains { $0.contains("merged into main") })
    }

    /// `handedToPR` is terminal for the queue: a crash right after it is finished by the next queue's recovery (the hand-off
    /// again, once), never by a fast-forward; without a landing machine the batch waits, `main` untouched.
    @Test func handedToPRIsTerminalAndResumable() async throws {
        let m = try MergeFixture()
        let items = try await twoApproved(m)
        let base = try main(m)
        let landing = FakeLanding()
        let q = await queue(m, landing: landing, fetch: FakeRemoteMain(tip: base))
        m.store.journalProbe.set { $0 == MergeStep.handedToPR.rawValue }
        _ = await q.runNextBatch(company: try company(m))
        m.store.journalProbe.set(nil)
        let open = try #require(try m.store.openMergeBatches(companyId: m.company.id).first)
        #expect(open.step == .handedToPR && open.landCommit != nil)
        #expect(try landing.begins.isEmpty && request(m, items[0]).status == .running)
        // No machine: the batch stays open; nothing moves; the request is not put back.
        let unwired = await queue(m, landing: nil, fetch: nil)
        #expect(await unwired.recover(company: try company(m)) == 0)
        #expect(try m.store.openMergeBatches(companyId: m.company.id).count == 1 && main(m) == base)
        #expect(try request(m, items[0]).status == .running)
        // A restarted, wired queue finishes the hand-off.
        let later = FakeLanding()
        let q2 = await queue(m, landing: later, fetch: FakeRemoteMain(tip: base))
        #expect(await q2.recover(company: try company(m)) == 1)
        let done = try #require(try m.store.mergeBatch(id: open.id))
        #expect(done.step == .done && done.error == nil)
        #expect(later.begins.map(\.itemId) == [items[0].id] && later.begins.first?.sha == open.landCommit)
        #expect(try request(m, items[0]).status == .handedToPR && request(m, items[1]).status == .queued)
        #expect(try main(m) == base && company(m).mainCommit == base && company(m).pendingMainCommit == nil)
        #expect(await q2.recover(company: try company(m)) == 0, "finished once")
        #expect(later.begins.count == 1)
        #expect(try m.store.orphanedMergeRequestIds(companyId: m.company.id).isEmpty)
        // And the queue goes on with the next item.
        let next = try #require(await q2.runNextBatch(company: try company(m)))
        #expect(next.handedToPR == [try request(m, items[1]).id])
        // The journal step order keeps PR batches out of every local-landing recovery branch.
        #expect(MergeStep.handedToPR.order > MergeStep.cleaned.order && MergeStep.handedToPR.order < MergeStep.done.order)
    }
}
