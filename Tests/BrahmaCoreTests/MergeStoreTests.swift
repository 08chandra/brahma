import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// The merge queue's schema, store writes and the enqueue at approval (Plan 4a Task 1a).
@Suite(.scratch, .serialized) struct MergeStoreTests {
    @Test func approvalQueuesThroughApproveForMerge() async throws {
        let m = try MergeFixture()
        let i = try await m.verified()
        let j = try await m.verified("Second", by: m.eng2, file: "src/second.txt")
        let text = try m.approve(i)
        #expect(text == "Approved \(i.key); it is queued to merge as M-1.")
        let request = try #require(try m.store.latestMergeRequest(itemId: i.id))
        let item = try m.fresh(i)
        #expect(request.status == .queued)
        #expect(request.ref == "M-1")
        #expect(request.headCommit == item.verifiedCommit)
        #expect(request.checkRevision == item.verifiedRevision)
        #expect(item.mergeState == .pending)
        #expect(Array(try m.kinds(i).suffix(2)) == [.reviewApproved, .mergeQueued])
        let queued = try #require(try m.store.itemEvents(itemId: i.id, limit: 500).last)
        #expect(queued.text == "queued to merge as M-1 (position 1)")
        #expect(try m.store.mergePosition(of: request) == 1)
        // A second approved item queues behind it. (Both were verified before the first approval: a tick of the engine would
        // run 3a's own merge step on an approved one.)
        try m.approve(j)
        let second = try #require(try m.store.latestMergeRequest(itemId: j.id))
        #expect(second.ref == "M-2")
        #expect(try m.store.mergePosition(of: second) == 2)
        #expect(try m.store.mergeRequests(companyId: m.company.id, statuses: [.queued]).map(\.ref) == ["M-1", "M-2"])
    }

    @Test func tierSAutoApprovalAlsoQueues() async throws {
        let m = try MergeFixture(autoMergeSmall: true)
        let i = try m.item("small change", tier: .s)
        try m.claimAndSubmit(i, file: "src/small.txt")
        try await m.cycle()
        let item = try m.fresh(i)
        #expect(item.autoApproved)
        #expect(item.mergeState == .pending)
        let request = try #require(try m.store.latestMergeRequest(itemId: i.id))
        #expect(request.status == .queued)
        #expect(request.headCommit == item.verifiedCommit)
        #expect(Array(try m.kinds(i).suffix(2)) == [.reviewApproved, .mergeQueued])
    }

    @Test func noChangesCompletesAtApproval() async throws {
        let m = try MergeFixture()
        let i = try await m.verified("Already there")
        // The branch's commits are already part of main (the owner merged them by hand).
        let head = try #require(try m.head(i))
        try GitFixture.plainGit(["merge", "--ff-only", head], in: m.root)
        try m.store.recordMainCommit(companyId: m.company.id, commit: head)
        let text = try m.approve(i)
        #expect(text.hasPrefix("Approved \(i.key);"))
        #expect(try m.fresh(i).status == .done)
        #expect(try m.store.mergeRequests(companyId: m.company.id).isEmpty)
        #expect(try m.fresh(i).mergedCommit == head)
    }

    @Test func secretFoundAtEnqueueBounces() async throws {
        let m = try MergeFixture()
        let i = try await m.verified("Leaky")
        // A value that got into the verified commit without the submit scan seeing it (a value that became known since).
        let secret = "AKIA" + "ABCDEFGHIJKLMNOP"
        let wt = m.ws.worktreePath(key: i.key)
        try m.write("src/leak.txt", "key = \(secret)\n", in: wt)
        try GitFixture.plainGit(["add", "-A"], in: wt)
        try GitFixture.plainGit(["commit", "-m", "more work"], in: wt)
        let head = try #require(try m.head(i))
        try m.exec("UPDATE workItem SET verifiedCommit = ? WHERE id = ?", [head, i.id])
        let text = try m.approve(i)
        let item = try m.fresh(i)
        #expect(item.status == .inProgress)
        #expect(item.mergeState == .none)
        #expect(item.verifiedCommit == nil)
        #expect(try m.store.mergeRequests(companyId: m.company.id, statuses: [.queued, .running, .landing]).isEmpty)
        let request = try #require(try m.store.latestMergeRequest(itemId: i.id))
        #expect(request.status == .bounced)
        #expect(request.failure == .secretFound)
        let detail = try #require(request.detail)
        #expect(detail == "a possible secret (aws-key) is in the change; remove it, rotate it if it was real, and resubmit")
        let kinds = try m.kinds(i)
        #expect(kinds.last == .mergeFailed); #expect(kinds.contains(.reviewApproved)); #expect(!kinds.contains(.mergeQueued))
        // No value anywhere the engine wrote text.
        let events = try m.store.itemEvents(itemId: i.id, limit: 500).map(\.text)
        let dms = try m.dms(m.eng)
        #expect(dms.contains("\(i.key) was not merged: \(detail). See Merge under Current work in your orientation."))
        for written in events + dms + [text, detail, request.detail ?? ""] { #expect(!written.contains(secret)) }
        #expect(!text.contains(secret))
    }

    @Test func cancelOnlyQueued() async throws {
        let m = try MergeFixture()
        let a = try await m.verified("First", file: "src/a.txt")
        let b = try await m.verified("Second", by: m.eng2, file: "src/b.txt")
        let c = try await m.verified("Third", by: m.eng3, file: "src/c.txt")
        for i in [a, b, c] { try m.approve(i) }
        // The queue claims the first: running.
        let claimed = try m.store.claimMergeBatch(companyId: m.company.id, size: 1, now: m.now)
        #expect(claimed.map(\.ref) == ["M-1"])
        #expect(claimed.first?.attempts == 1)
        #expect(try m.fresh(a).mergeState == .verifying)
        // Release is refused while it is running.
        let refused = try #require(throws: WorkError.self) {
            try m.store.releaseLease(itemId: a.id, agentId: m.eng.id, note: nil, now: m.now)
        }
        #expect(refused.message == "\(a.key) is being merged (M-1); wait for the merge to finish")
        // Withdrawing an item from review cancels a queued request only.
        try m.cancelMerges([a, b])
        #expect(try m.store.latestMergeRequest(itemId: a.id)?.status == .running)
        #expect(try m.store.latestMergeRequest(itemId: b.id)?.status == .cancelled)
        // Blocking an item in review (the one way out of it) cancels its queued request through the update path.
        _ = try m.store.updateWorkItem(id: c.id, by: .owner, patch: WorkItemPatch(status: .blocked, blockedReason: "waiting"), now: m.now)
        #expect(try m.store.latestMergeRequest(itemId: c.id)?.status == .cancelled)
        #expect(try m.fresh(c).mergeState == .none)
        // ... and the running one cannot be moved.
        let held = try #require(throws: WorkError.self) {
            try m.store.updateWorkItem(id: a.id, by: .owner, patch: WorkItemPatch(status: .blocked, blockedReason: "waiting"), now: m.now)
        }
        #expect(held.message == "\(a.key) is being merged (M-1); wait for the merge to finish")
    }

    @Test func tailsAreRedacted() async throws {
        let m = try MergeFixture()
        let value = "zebra-secret-998877"
        try m.store.setSecret(companyId: m.company.id, name: "NEW_KEY", value: value, isTest: false, vault: m.vault)
        _ = try m.store.reloadRedactorIfNeeded(vault: m.vault)
        let a = try await m.approved()
        let request = try #require(try m.store.claimMergeBatch(companyId: m.company.id, size: 1, now: m.now).first)
        try m.store.recordMergeRun(MergeRun(companyId: m.company.id, batchId: request.batchId, requestId: request.id, prefix: 1,
                                            kind: .item, itemId: a.id, command: "make test", status: .failed, exitCode: 2,
                                            outputTail: "boom \(value) boom"))
        let run = try #require(try m.store.mergeRuns(requestId: request.id).first)
        #expect(run.outputTail == "boom [redacted NEW_KEY] boom")
        try m.store.bounceMerge(requestId: request.id, failure: .itemCheckFailed,
                                detail: "its check failed after rebasing on main (exit 2)", outputTail: "tail \(value)", now: m.now)
        let bounced = try #require(try m.store.latestMergeRequest(itemId: a.id))
        #expect(bounced.outputTail == "tail [redacted NEW_KEY]")
        #expect(bounced.status == .bounced)
        let item = try m.fresh(a)
        #expect(item.status == .inProgress); #expect(item.mergeState == .none)
        let dms = try m.dms(m.eng)
        #expect(dms.last == "\(a.key) was not merged: its check failed after rebasing on main (exit 2). See Merge under Current work in your orientation.")
    }

    @Test func mergeFailedWakesHolder() async throws {
        let m = try MergeFixture()
        let a = try await m.approved()
        let request = try #require(try m.store.claimMergeBatch(companyId: m.company.id, size: 1, now: m.now).first)
        try m.store.bounceMerge(requestId: request.id, failure: .mainCheckFailed,
                                detail: "the main check failed after rebasing on main (timed out after 600s)", now: m.now)
        let notice = try #require(try m.store.pendingNotices(agentId: m.eng.id).first { $0.event.kind == .mergeFailed })
        #expect(notice.notice.wakes)
        #expect(notice.event.text == "the main check failed after rebasing on main (timed out after 600s)")
        _ = a
    }

    @Test func landingWritesActivityAndMainCommit() async throws {
        let m = try MergeFixture()
        let a = try await m.approved()
        let request = try #require(try m.store.claimMergeBatch(companyId: m.company.id, size: 1, now: m.now).first)
        let base = try GitFixture.plainGit(["rev-parse", "refs/heads/main"], in: m.root)
        try m.store.markLanding(requestIds: [request.id], candidates: [request.id: request.headCommit], base: base, now: m.now)
        #expect(try m.store.latestMergeRequest(itemId: a.id)?.status == .landing)
        // The engine lands it (fast-forward) and records it.
        try GitFixture.plainGit(["merge", "--ff-only", request.headCommit], in: m.root)
        let landed = try m.store.recordLanded([(request.id, request.headCommit)], mainCommit: request.headCommit, now: m.now)
        #expect(landed.map(\.status) == [.done])
        let merged = try #require(try m.store.latestMergeRequest(itemId: a.id))
        #expect(merged.status == .merged); #expect(merged.mergedCommit == request.headCommit)
        #expect(try m.store.company(id: m.company.id)?.mainCommit == request.headCommit)
        let activity = try m.activity(.merge)
        #expect(activity.map(\.text) == ["\(a.key) merged into main (\(request.headCommit.prefix(7)))"])
        // Nothing lands twice: an item that is already done is not finished again.
        let again = try m.store.recordLanded([(request.id, request.headCommit)], mainCommit: request.headCommit, now: m.now)
        #expect(again.isEmpty)
    }

    @Test func requeueAndFailWriteTheirState() async throws {
        let m = try MergeFixture()
        let a = try await m.approved()
        let request = try #require(try m.store.claimMergeBatch(companyId: m.company.id, size: 1, now: m.now).first)
        try m.store.requeueMerge(requestIds: [request.id], countsAsRequeue: true, now: m.now)
        let queued = try #require(try m.store.latestMergeRequest(itemId: a.id))
        #expect(queued.status == .queued); #expect(queued.requeues == 1); #expect(queued.attempts == 1); #expect(queued.batchId == nil)
        #expect(try m.fresh(a).mergeState == .pending)
        try m.store.setMergeHold(companyId: m.company.id, reason: "main is red", now: m.now)
        #expect(try m.store.claimMergeBatch(companyId: m.company.id, size: 1, now: m.now).isEmpty)
        try m.store.setMergeHold(companyId: m.company.id, reason: nil, now: m.now)
        let again = try #require(try m.store.claimMergeBatch(companyId: m.company.id, size: 1, now: m.now).first)
        #expect(again.attempts == 2)
        try m.store.failMerge(requestId: again.id, detail: "git failed three times", now: m.now)
        let failed = try #require(try m.store.latestMergeRequest(itemId: a.id))
        #expect(failed.status == .failed)
        let notices = try m.store.allNotices()
        #expect(notices.contains { $0.title == "Merge M-1 (\(a.key)) stopped"
            && $0.body == "git failed three times. Retry it from the merge queue or with brahma merge retry." })
    }

    @Test func crossCompanyRequestRefused() async throws {
        let m = try MergeFixture()
        let a = try await m.approved()
        let request = try #require(try m.store.latestMergeRequest(itemId: a.id))
        // A request row whose item is another company's is never written through.
        let other = try m.world.company("Other")
        try m.exec("UPDATE mergeRequest SET companyId = ? WHERE id = ?", [other.id, request.id])
        let err = try #require(throws: WorkError.self) {
            try m.store.failMerge(requestId: request.id, detail: "x", now: m.now)
        }
        #expect(err.message == "not in your company")
    }

    @Test func settingsAndSchemaDefaults() throws {
        let w = try World()
        let c = try w.company("Acme")
        let settings = try w.store.mergeSettings(companyId: c.id)
        #expect(settings == MergeSettings(mainCheck: nil, batchSize: 1, strategy: .ff))
        #expect(MergeSettings.batchRange == 1...8)
        #expect(MergeStrategy.ff.title == "Rebase + fast-forward")
        #expect(MergeStrategy.merge.title == "Rebase + merge commit")
        #expect(try w.store.company(id: c.id)?.mergeHold == nil)
        #expect(MergeRequestStatus.allCases.filter(\.isOpen) == [.queued, .running, .landing])
    }

    @Test func digestMergeLines() {
        func request(_ status: MergeRequestStatus, failure: MergeFailure? = nil, detail: String? = nil, tail: String? = nil) -> MergeRequest {
            var r = MergeRequest(companyId: "c", itemId: "i", number: 4, status: status, headCommit: "abc", enqueuedAt: Date(timeIntervalSince1970: 0))
            r.failure = failure; r.detail = detail; r.outputTail = tail
            return r
        }
        #expect(TurnDigest.mergeLines(MergeOrientation(request: request(.queued), position: 2)) == ["Merge: M-4 queued (position 2)"])
        #expect(TurnDigest.mergeLines(MergeOrientation(request: request(.running), position: nil)) == ["Merge: M-4 merging"])
        #expect(TurnDigest.mergeLines(MergeOrientation(request: request(.landing), position: nil)) == ["Merge: M-4 merging"])
        let conflict = request(.bounced, failure: .conflict, detail: "it conflicts with main")
        #expect(TurnDigest.mergeLines(MergeOrientation(request: conflict, position: nil)) == ["Merge: M-4 not merged — it conflicts with main"])
        let tail = (1...30).map { "line \($0)" }.joined(separator: "\n")
        let check = request(.bounced, failure: .itemCheckFailed, detail: "its check failed after rebasing on main (exit 1)", tail: tail)
        let lines = TurnDigest.mergeLines(MergeOrientation(request: check, position: nil))
        #expect(lines.first == "Merge: M-4 not merged — its check failed after rebasing on main (exit 1)")
        let quoted = lines.dropFirst().joined(separator: "\n").components(separatedBy: "\n")
        #expect(quoted.count == 20)
        #expect(quoted.first == "    | line 11"); #expect(quoted.last == "    | line 30")
        #expect(TurnDigest.mergeLines(nil).isEmpty)
        #expect(TurnDigest.mergeLines(MergeOrientation(request: request(.merged), position: nil)).isEmpty)
    }

    @Test func showWorkItemCarriesMerge() async throws {
        let m = try MergeFixture()
        let a = try await m.approved()
        let out = try m.tools(m.eng).call(name: "show_work_item", arguments: ["key": .string(a.key)])
        let json = try #require(try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any])
        let merge = try #require(json["merge"] as? [String: Any])
        #expect(merge["ref"] as? String == "M-1"); #expect(merge["status"] as? String == "queued")
        #expect(merge["failure"] is NSNull); #expect(merge["detail"] is NSNull)
    }

    // MARK: A request follows its item's approval (fix round 1)

    /// Approves an item, sends it back through `trigger`, resubmits and approves again: the first request is withdrawn and the
    /// second is pinned to the new commit, with its own `mergeQueued` event.
    private func reapprovalIsFresh(_ m: MergeFixture, trigger: (WorkItem) throws -> Void) async throws {
        let i = try await m.verified()
        try m.approve(i)
        let first = try #require(try m.store.latestMergeRequest(itemId: i.id))
        #expect(first.status == .queued)
        try trigger(i)
        #expect(try m.fresh(i).status == .inProgress)
        #expect(try m.store.mergeRequests(companyId: m.company.id, statuses: [.queued]).isEmpty, "the returned item's request is withdrawn")
        try await m.resubmit(i, file: "src/again.txt")
        let again = try m.fresh(i)
        #expect(again.verifiedCommit != nil); #expect(again.verifiedCommit != first.headCommit)
        let text = try m.approve(i, flags: true)   // a check edit leaves a review flag to approve
        #expect(text == "Approved \(i.key); it is queued to merge as M-2.")
        let all = try m.store.mergeRequests(companyId: m.company.id)
        #expect(all.map(\.status) == [.cancelled, .queued])
        let second = try #require(all.last)
        #expect(second.ref == "M-2"); #expect(second.headCommit == again.verifiedCommit); #expect(second.checkRevision == again.verifiedRevision)
        let queuedEvents = try m.store.itemEvents(itemId: i.id, limit: 500).filter { $0.kind == .mergeQueued }.map(\.text)
        #expect(queuedEvents == ["queued to merge as M-1 (position 1)", "queued to merge as M-2 (position 1)"])
    }

    @Test func checkEditReturnWithdrawsQueuedRequest() async throws {
        let m = try MergeFixture()
        try await reapprovalIsFresh(m) { i in
            let active = m.store.activeNow(companyId: m.company.id)
            try m.exec("UPDATE workLease SET expiresActive = ? WHERE itemId = ?", [active + 5, i.id])
            _ = try m.store.updateWorkItem(id: i.id, by: .owner, patch: WorkItemPatch(
                checkSpec: .some(CheckSpec(command: "true && true", paths: ["src/p1"]))), now: m.now)
        }
    }

    @Test func conflictReturnWithdrawsQueuedRequest() async throws {
        let m = try MergeFixture()
        try await reapprovalIsFresh(m) { i in
            let head = try #require(try m.head(i))
            let main = try GitFixture.plainGit(["rev-parse", "refs/heads/main"], in: m.root)
            try m.store.finishMerge(itemId: i.id, result: .conflict(files: ["src/work.txt"], mergeBase: main, mainCommit: main, itemCommit: head))
        }
    }

    @Test func secretsFoundReturnWithdrawsQueuedRequest() async throws {
        let m = try MergeFixture()
        try await reapprovalIsFresh(m) { i in
            try m.store.finishMerge(itemId: i.id, result: .secretsFound(findings: ["aws-key in src/work.txt"]))
        }
    }

    @Test func branchMovedReturnWithdrawsQueuedRequest() async throws {
        let m = try MergeFixture()
        try await reapprovalIsFresh(m) { i in
            try m.store.finishMerge(itemId: i.id, result: .branchMoved(head: nil))
        }
    }

    @Test func revokedAutoApprovalWithdrawsQueuedRequest() async throws {
        let m = try MergeFixture(autoMergeSmall: true)
        let i = try m.item("small change", tier: .s)
        try m.claimAndSubmit(i, file: "src/small.txt")
        try await m.cycle()
        let first = try #require(try m.store.latestMergeRequest(itemId: i.id))
        #expect(first.status == .queued)
        try m.store.setAutoMerge(false)
        #expect(try m.store.latestMergeRequest(itemId: i.id)?.status == .cancelled)
        #expect(try m.fresh(i).mergeState == .none)
        // The reviewer approves the same commit: a fresh request, with its own event.
        try m.approve(i)
        let second = try #require(try m.store.latestMergeRequest(itemId: i.id))
        #expect(second.ref == "M-2"); #expect(second.status == .queued); #expect(second.headCommit == first.headCommit)
        #expect(try m.kinds(i).filter { $0 == .mergeQueued }.count == 2)
    }

    @Test func approvingAgainRefreshesAStaleQueuedRequest() async throws {
        // Defence in depth: a queued request pinned to something else than the item's current approval is replaced.
        let m = try MergeFixture()
        let i = try await m.verified()
        try m.approve(i)
        let first = try #require(try m.store.latestMergeRequest(itemId: i.id))
        try m.exec("UPDATE mergeRequest SET headCommit = 'deadbeef' WHERE id = ?", [first.id])
        let item = try m.fresh(i)
        try m.enqueue(item, ahead: 1)
        let all = try m.store.mergeRequests(companyId: m.company.id)
        #expect(all.map(\.status) == [.cancelled, .queued])
        #expect(all.last?.headCommit == item.verifiedCommit)
    }

    @Test func staleHeadRequestDoesNotWedgeTheQueue() async throws {
        let m = try MergeFixture()
        let a = try await m.verified("First", file: "src/a.txt")
        let b = try await m.verified("Second", by: m.eng2, file: "src/b.txt")
        try m.approve(a); try m.approve(b)
        // The head request's item is no longer approved (something returned it without withdrawing the request).
        try m.exec("UPDATE workItem SET mergeState = 'none' WHERE id = ?", [a.id])
        let claimed = try m.store.claimMergeBatch(companyId: m.company.id, size: 1, now: m.now)
        #expect(claimed.map(\.ref) == ["M-2"])
        #expect(try m.store.latestMergeRequest(itemId: a.id)?.status == .cancelled)
    }

    @Test func onlyQualifyingAutoApprovalsAreMeasured() {
        #expect(!MergeEnqueueFacts.wanted(for: nil), "a failed or non-submit run has no assessment")
        #expect(!MergeEnqueueFacts.wanted(for: AutoMergeAssessment(commit: "c", base: "b", lines: 1, reason: "too big")))
        #expect(MergeEnqueueFacts.wanted(for: AutoMergeAssessment(commit: "c", base: "b", lines: 1, reason: nil)))
    }

    @Test func batchWritesRefuseMixedCompanies() async throws {
        let m = try MergeFixture()
        let a = try await m.verified("First", file: "src/a.txt")
        try m.approve(a)
        // A second company in the same store, with a request of its own being landed.
        let store = m.store
        let other = try m.world.company("Other")
        let hired = try store.hire(companyId: other.id, name: "o-eng", role: "engineer", model: "sonnet")
        let foreignItem = try store.createWorkItem(companyId: other.id, by: .owner, draft: WorkItemDraft(
            type: .task, title: "Foreign", ownerId: hired.id, status: .ready), now: m.now)
        try m.exec("UPDATE workItem SET status = 'inReview', mergeState = 'pending' WHERE id = ?", [foreignItem.id])
        try m.exec("""
            INSERT INTO mergeRequest (id, companyId, itemId, number, status, headCommit, enqueuedAt)
            VALUES ('foreign-1', ?, ?, 1, 'landing', 'abc', ?)
            """, [other.id, foreignItem.id, m.now])
        let claimed = try #require(try store.claimMergeBatch(companyId: m.company.id, size: 1, now: m.now).first)
        let ids = [claimed.id, "foreign-1"]
        let before = try m.store.company(id: m.company.id)?.mainCommit
        let otherBefore = try store.company(id: other.id)?.mainCommit
        func refused(_ body: () throws -> Void) -> String {
            do { try body(); return "no error" } catch let e as WorkError { return e.message } catch { return "\(error)" }
        }
        #expect(refused { try store.markLanding(requestIds: ids, candidates: [:], base: "b", now: m.now) } == "not in your company")
        #expect(refused { _ = try store.recordLanded([(claimed.id, "abc"), ("foreign-1", "abc")], mainCommit: "abc", now: m.now) } == "not in your company")
        #expect(refused { try store.requeueMerge(requestIds: ids, countsAsRequeue: true, now: m.now) } == "not in your company")
        #expect(refused { try store.markLanding(requestIds: [claimed.id, "no-such"], candidates: [:], base: "b", now: m.now) } == "no such merge request")
        // Nothing was written, for either company.
        #expect(try store.latestMergeRequest(itemId: a.id)?.status == .running)
        #expect(try store.mergeRequests(companyId: other.id).map(\.status) == [.landing])
        #expect(try store.company(id: m.company.id)?.mainCommit == before)
        #expect(try store.company(id: other.id)?.mainCommit == otherBefore)
    }

    @Test func secretDetailNamesEveryDistinctLabel() {
        let findings = ["aws-key in src/a.txt (commit abc1234)", "known secret STRIPE_KEY in src/b.txt", "aws-key in src/c.txt"]
        #expect(Store.secretDetail(findings)
                == "a possible secret (aws-key, known secret STRIPE_KEY) is in the change; remove it, rotate it if it was real, and resubmit")
        #expect(Store.secretDetail([]) == "a possible secret (secret) is in the change; remove it, rotate it if it was real, and resubmit")
    }
}
