import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Batches of the merge queue (Plan 4a Task 2): a batch of up to `mergeBatchSize` requests is rebased onto each other, checked
/// as a whole and bisected to the culprit when the check fails; the blame rules decide who is told. Checks are the fake runner's;
/// a hook decides each outcome from the command and from what the export of the candidate holds.
@Suite(.scratch, .serialized) struct MergeBatchTests {
    static let secretValue = "batch-secret-value-xyz-1234567890"

    func queue(_ m: MergeFixture, known: @escaping @Sendable (String) -> [(String, String)] = { _ in [] }) -> MergeQueue {
        MergeQueue(store: m.store, paths: m.world.paths, checks: m.world.checks, knownValues: known, clock: { m.now })
    }
    @discardableResult
    func batch(_ q: MergeQueue, _ m: MergeFixture) async throws -> MergeBatchOutcome? {
        await q.runNextBatch(company: try #require(try m.store.company(id: m.company.id)))
    }
    func main(_ m: MergeFixture) throws -> String { try #require(try m.ws.head(of: GitWorkspace.mainRef)) }
    func request(_ m: MergeFixture, _ i: WorkItem) throws -> MergeRequest { try #require(try m.store.latestMergeRequest(itemId: i.id)) }
    func text(_ s: String) -> Data { Data(s.utf8) }

    /// An item whose own check has its own command (`make test <title>`), so a hook can tell whose check is running.
    func item(_ m: MergeFixture, _ title: String) throws -> WorkItem {
        let n = try m.store.workItems(companyId: m.company.id).count + 1
        return try m.store.createWorkItem(companyId: m.company.id, by: .owner, draft: WorkItemDraft(
            type: .task, title: title, checkSpec: CheckSpec(command: "make test \(title)", paths: ["src/p\(n)"]), tier: .m,
            reviewerId: m.rev.id, status: .ready), now: m.now)
    }

    /// Three items (A, B, C, three authors) verified and approved, so M-1..M-3 are queued; the batch size is 3. The engine has not
    /// run a merge tick since. `files[n]` is what item n changes.
    func threeApproved(_ m: MergeFixture, _ files: [[String: String]]) async throws -> [WorkItem] {
        let authors = [m.eng, m.eng2, m.eng3]
        var items: [WorkItem] = []
        for (n, name) in ["A", "B", "C"].prefix(files.count).enumerated() {
            let i = try item(m, name)
            _ = try m.tools(authors[n]).call(name: "claim_lease", arguments: ["key": .string(i.key)])
            for (path, body) in files[n] { try m.write(path, body, in: m.ws.worktreePath(key: i.key)) }
            _ = try m.tools(authors[n]).call(name: "submit_for_review", arguments: ["key": .string(i.key), "summary": .string("did \(name)")])
            items.append(i)
        }
        // The engine checks at most a few submissions per tick: tick until every item passed its check.
        for _ in 0..<6 where try items.contains(where: { try m.fresh($0).verifiedCommit == nil }) { try await m.cycle() }
        for i in items { try m.approve(try m.fresh(i)) }
        try m.exec("UPDATE company SET mergeBatchSize = 3 WHERE id = ?", [m.company.id])
        return try items.map { try m.fresh($0) }
    }

    func setMainCheck(_ m: MergeFixture, _ command: String, by agent: Agent? = nil) throws {
        let setter = (agent ?? m.eng).id, id = m.company.id
        try m.store.writer.write { db in
            guard var c = try Company.fetchOne(db, key: id) else { throw WorkError.notFound("company") }
            c.mainCheck = CheckSpec(command: command)
            c.mainCheckSetById = setter
            try c.update(db)
        }
    }

    /// Fails a command when the export of the candidate holds a file.
    func failWhenPresent(_ m: MergeFixture, command: String, file: String, tail: String = "1 test failed") {
        m.world.checks.onRun { call in
            guard call.command == command,
                  FileManager.default.fileExists(atPath: call.workingDirectory.appending(path: file).path) else { return nil }
            return FakeCheckRunner.fail(tail)
        }
    }

    // MARK: Landing and bisect

    @Test func batchLandsAllWhenGreen() async throws {
        let m = try MergeFixture()
        let items = try await threeApproved(m, [["src/a.txt": "a"], ["src/b.txt": "b"], ["src/c.txt": "c"]])
        try setMainCheck(m, "make smoke")
        let before = m.world.checks.calls.count
        let q = queue(m)
        let outcome = try #require(try await batch(q, m))
        let rs = try items.map { try request(m, $0) }
        #expect(outcome.merged == rs.map(\.id) && outcome.bounced.isEmpty && outcome.requeued.isEmpty && outcome.failed.isEmpty)
        let tip = try main(m)
        #expect(outcome.mainCommit == tip)
        #expect(rs.map(\.status) == [.merged, .merged, .merged])
        #expect(rs.allSatisfy { $0.batchId == rs[0].batchId } && rs[0].batchId != nil)
        for f in ["a", "b", "c"] { #expect(FileManager.default.fileExists(atPath: m.root.appending(path: "src/\(f).txt").path)) }
        #expect(try items.map { try m.fresh($0).status } == [.done, .done, .done])
        #expect(try items.map { try m.fresh($0).mergedCommit } == rs.map(\.mergedCommit))
        #expect(rs.last?.mergedCommit == tip)
        // One check pass on the whole batch: the main check, then each item's check, on the tip.
        #expect(m.world.checks.calls.dropFirst(before).map(\.command) == ["make smoke", "make test A", "make test B", "make test C"])
        let runs = try m.store.mergeRuns(requestId: rs[2].id)
        #expect(runs.contains { $0.kind == .main && $0.prefix == 3 } && runs.contains { $0.kind == .item && $0.prefix == 3 })
        // The journal ran to its end.
        let journal = try #require(try m.store.mergeBatches(companyId: m.company.id).first)
        #expect(journal.step == .done && journal.error == nil && journal.landedIds == rs.map(\.id) && journal.landCommit == tip)
        #expect(journal.requestIds == rs.map(\.id) && journal.candidates.count == 3)
        #expect(try m.store.company(id: m.company.id)?.mainCommit == tip)
    }

    @Test func bisectFindsCulprit() async throws {
        let m = try MergeFixture()
        let items = try await threeApproved(m, [["src/a.txt": "a"], ["src/b-bad.txt": "bad"], ["src/c.txt": "c"]])
        failWhenPresent(m, command: "make test B", file: "src/b-bad.txt", tail: "B is broken")
        let q = queue(m)
        let outcome = try #require(try await batch(q, m))
        let (ra, rb, rc) = (try request(m, items[0]), try request(m, items[1]), try request(m, items[2]))
        #expect(outcome.merged == [ra.id] && outcome.bounced == [rb.id] && outcome.requeued == [rc.id])
        #expect(ra.status == .merged && rb.status == .bounced && rb.failure == .itemCheckFailed && rc.status == .queued)
        #expect(rb.outputTail?.contains("B is broken") == true)
        #expect(rc.requeues == 0 && rc.inconclusive == 0, "the item behind the culprit is not counted")
        #expect(try m.fresh(items[1]).status == .inProgress)
        #expect(try m.fresh(items[0]).status == .done)
        #expect(!FileManager.default.fileExists(atPath: m.root.appending(path: "src/b-bad.txt").path))
        let journal = try #require(try m.store.mergeBatches(companyId: m.company.id).first)
        #expect(journal.step == .done && journal.landedIds == [ra.id])
        // The next batch lands C (B is out of the way).
        m.world.checks.onRun(nil)
        let next = try #require(try await batch(q, m))
        #expect(next.merged == [rc.id])
        #expect(try m.fresh(items[2]).status == .done)
    }

    @Test func earlierItemsCheckBlamesCulprit() async throws {
        let m = try MergeFixture()
        let items = try await threeApproved(m, [["src/a.txt": "a"], ["src/b.txt": "b"], ["src/c-breaks-a.txt": "c"]])
        // A's own check passes alone, but fails once C's change is in the candidate.
        failWhenPresent(m, command: "make test A", file: "src/c-breaks-a.txt", tail: "A broke")
        let outcome = try #require(try await batch(queue(m), m))
        let (ra, rb, rc) = (try request(m, items[0]), try request(m, items[1]), try request(m, items[2]))
        #expect(outcome.merged == [ra.id, rb.id] && outcome.bounced == [rc.id] && outcome.requeued.isEmpty)
        #expect(rc.status == .bounced && rc.failure == .itemCheckFailed)
        let detail = try #require(rc.detail)
        #expect(detail.contains("its change made \(items[0].key)'s check fail after rebasing on main"), "\(detail)")
        #expect(try m.fresh(items[0]).status == .done && (try m.fresh(items[0]).reviewFlags.isEmpty))
    }

    @Test func conflictInBatchSkipsOnlyThatItem() async throws {
        let m = try MergeFixture()
        let items = try await threeApproved(m, [["a.txt": "one\n"], ["a.txt": "two\n"], ["src/c.txt": "c"]])
        let outcome = try #require(try await batch(queue(m), m))
        let (ra, rb, rc) = (try request(m, items[0]), try request(m, items[1]), try request(m, items[2]))
        #expect(outcome.merged == [ra.id, rc.id] && outcome.bounced == [rb.id])
        #expect(rb.status == .bounced && rb.failure == .conflict && rb.conflictFiles == ["a.txt"])
        #expect(try String(contentsOf: m.root.appending(path: "a.txt"), encoding: .utf8) == "one\n")
        #expect(FileManager.default.fileExists(atPath: m.root.appending(path: "src/c.txt").path))
        #expect(try m.fresh(items[1]).status == .inProgress)
    }

    @Test func secretInBatchBouncesOnlyItsItem() async throws {
        let m = try MergeFixture()
        let items = try await threeApproved(m, [["src/a.txt": "a"], ["src/b.txt": "token = \(Self.secretValue)\n"], ["src/c.txt": "c"]])
        let before = try main(m)
        let value = Self.secretValue
        let q = queue(m, known: { _ in [("DEPLOY_TOKEN", value)] })
        let outcome = try #require(try await batch(q, m))
        let (ra, rb, rc) = (try request(m, items[0]), try request(m, items[1]), try request(m, items[2]))
        #expect(outcome.bounced == [rb.id] && Set(outcome.requeued) == [ra.id, rc.id] && outcome.merged.isEmpty)
        #expect(rb.status == .bounced && rb.failure == .secretFound)
        #expect(ra.status == .queued && rc.status == .queued && ra.requeues == 0 && rc.requeues == 0)
        #expect(try main(m) == before)
        #expect(rb.detail?.contains(Self.secretValue) != true)
        // The rest lands in the next batch.
        let next = try #require(try await batch(q, m))
        #expect(Set(next.merged) == [ra.id, rc.id])
    }

    // MARK: Blame rules

    @Test func redMainHoldsQueue() async throws {
        let m = try MergeFixture()
        let items = try await threeApproved(m, [["src/a.txt": "a"], ["src/b.txt": "b"], ["src/c.txt": "c"]])
        try setMainCheck(m, "make smoke")
        m.world.checks.onRun { call in call.command == "make smoke" ? FakeCheckRunner.fail("smoke is red") : nil }
        let before = try main(m)
        let q = queue(m)
        let outcome = try #require(try await batch(q, m))
        #expect(outcome.merged.isEmpty && outcome.bounced.isEmpty && outcome.requeued.count == 3)
        #expect(try main(m) == before)
        for i in items {
            let r = try request(m, i)
            #expect(r.status == .queued && r.requeues == 0 && r.inconclusive == 0, "nobody is blamed")
            #expect(try m.fresh(i).status == .inReview)
        }
        let company = try #require(try m.store.company(id: m.company.id))
        #expect(company.mergeHold == "the main check fails on main itself")
        let notice = try #require(try m.store.allNotices().last { $0.title == "Merge queue held" })
        #expect(notice.body == "The main check fails on main \(before.prefix(7)), so no item is blamed. Fix main or change the main check, then run brahma merge resume \(company.name).")
        let runs = try await m.store.writer.read { try MergeRun.filter(Column("kind") == "mainAtBase").fetchAll($0) }
        #expect(runs.count == 1 && runs.first?.status == .failed && runs.first?.candidateCommit == before)
        // Held: nothing runs. Resumed by the owner: it does.
        #expect(try await batch(q, m) == nil)
        try m.store.resumeMergeQueue(companyId: m.company.id, by: Sender.owner)
        #expect(try m.store.company(id: m.company.id)?.mergeHold == nil)
        m.world.checks.onRun(nil)
        #expect(try #require(try await batch(q, m)).merged.count == 3)
    }

    @Test func mainCheckFailingOnlyWithTheCandidateBlamesIt() async throws {
        let m = try MergeFixture()
        let items = try await threeApproved(m, [["src/a-breaks-main.txt": "a"], ["src/b.txt": "b"]])
        try setMainCheck(m, "make smoke")
        failWhenPresent(m, command: "make smoke", file: "src/a-breaks-main.txt", tail: "smoke: a broke it")
        let outcome = try #require(try await batch(queue(m), m))
        let (ra, rb) = (try request(m, items[0]), try request(m, items[1]))
        // main is green at the base, so the first item is the culprit; the second is not counted.
        #expect(outcome.bounced == [ra.id] && outcome.requeued == [rb.id])
        #expect(ra.failure == .mainCheckFailed && rb.status == .queued && rb.requeues == 0)
        #expect(try m.store.company(id: m.company.id)?.mergeHold == nil)
        let atBase = try await m.store.writer.read { try MergeRun.filter(Column("kind") == "mainAtBase").fetchAll($0) }
        #expect(atBase.count == 1 && atBase.first?.status == .passed)
    }

    @Test func flakyCheckRerunOnce() async throws {
        let m = try MergeFixture()
        let items = try await threeApproved(m, [["src/a.txt": "a"]])
        let calls = BatchCounter()
        m.world.checks.onRun { call in
            guard call.command == "make test A" else { return nil }
            return calls.next() == 1 ? FakeCheckRunner.fail("flaked") : nil
        }
        let outcome = try #require(try await batch(queue(m), m))
        let r = try request(m, items[0])
        #expect(outcome.merged == [r.id] && r.status == .merged)
        let runs = try m.store.mergeRuns(requestId: r.id).filter { $0.kind == .item }
        #expect(runs.map(\.attempt) == [1, 2] && runs.map(\.status) == [.failed, .passed])
        #expect(runs[1].flaky && !runs[0].flaky)
        #expect(try m.fresh(items[0]).reviewFlags.contains("flaky check during merge: failed, then passed"))
        #expect(try m.fresh(items[0]).status == .done)
    }

    @Test func failingTwiceIsNotFlaky() async throws {
        let m = try MergeFixture()
        let items = try await threeApproved(m, [["src/a.txt": "a"]])
        m.world.checks.onRun { call in call.command == "make test A" ? FakeCheckRunner.fail("really broken") : nil }
        let outcome = try #require(try await batch(queue(m), m))
        let r = try request(m, items[0])
        #expect(outcome.bounced == [r.id] && r.failure == .itemCheckFailed)
        let runs = try m.store.mergeRuns(requestId: r.id).filter { $0.kind == .item }
        #expect(runs.map(\.attempt) == [1, 2] && runs.allSatisfy { $0.status == .failed && !$0.flaky })
    }

    @Test func networkFailureIsInconclusive() async throws {
        let m = try MergeFixture()
        let items = try await threeApproved(m, [["src/a.txt": "a"]])
        m.world.checks.onRun { call in
            call.command == "make test A" ? FakeCheckRunner.fail("npm ERR! getaddrinfo ENOTFOUND registry.npmjs.org") : nil
        }
        let q = queue(m)
        let first = try #require(try await batch(q, m))
        var r = try request(m, items[0])
        #expect(first.requeued == [r.id] && r.status == .queued && r.inconclusive == 1 && r.requeues == 0)
        #expect(try m.store.mergeRuns(requestId: r.id).filter { $0.kind == .item }.map(\.status) == [.inconclusive], "no re-run for infrastructure")
        _ = try #require(try await batch(q, m))
        r = try request(m, items[0])
        #expect(r.status == .queued && r.inconclusive == 2)
        let third = try #require(try await batch(q, m))
        r = try request(m, items[0])
        #expect(third.failed == [r.id] && r.status == .failed)
        #expect(r.detail == "check could not run reliably (infrastructure)")
        #expect(try m.fresh(items[0]).mergeState == .none)
    }

    @Test func mainMovedOutsideQueueRequeues() async throws {
        let m = try MergeFixture()
        let items = try await threeApproved(m, [["src/a.txt": "a"], ["src/b.txt": "b"]])
        let root = m.root
        // While the checks run, someone commits to main from outside the queue.
        m.world.checks.onRun { call in
            guard call.command == "make test A" else { return nil }
            _ = try? GitFixture.plainGit(["commit", "-q", "--allow-empty", "-m", "outside"], in: root)
            return nil
        }
        let outsideBefore = try main(m)
        let q = queue(m)
        let outcome = try #require(try await batch(q, m))
        let outside = try main(m)
        #expect(outside != outsideBefore)
        #expect(outcome.merged.isEmpty && outcome.requeued.count == 2)
        for i in items.prefix(2) {
            let r = try request(m, i)
            #expect(r.status == .queued && r.requeues == 1)
        }
        let journal = try #require(try m.store.mergeBatches(companyId: m.company.id).first)
        #expect(journal.step == .done && journal.error != nil)
    }

    /// Controller ruling 1 / S5: an inconclusive result is never charged by default. It is bisected like a failure; the single
    /// member the bisection isolates is charged, the green prefix before it lands, the others go back uncounted. (An item
    /// check case: B's own check cannot run.)
    @Test func inconclusiveIsChargedOnlyToTheOwnerOfTheRun() async throws {
        let m = try MergeFixture()
        let items = try await threeApproved(m, [["src/a.txt": "a"], ["src/b.txt": "b"], ["src/c.txt": "c"]])
        m.world.checks.onRun { call in
            call.command == "make test B" ? FakeCheckRunner.fail("npm ERR! getaddrinfo ENOTFOUND registry.npmjs.org") : nil
        }
        let q = queue(m)
        for round in 1...3 {
            let outcome = try #require(try await batch(q, m))
            let (ra, rb, rc) = (try request(m, items[0]), try request(m, items[1]), try request(m, items[2]))
            #expect(ra.inconclusive == 0 && rc.inconclusive == 0 && rc.status == .queued && ra.status == .merged, "round \(round)")
            if round < 3 {
                #expect(rb.status == .queued && rb.inconclusive == round)
            } else {
                #expect(outcome.failed == [rb.id] && rb.status == .failed && rb.detail == "check could not run reliably (infrastructure)")
            }
        }
        // C lands once B is out of the way.
        m.world.checks.onRun(nil)
        let last = try #require(try await batch(q, m))
        #expect(last.merged == [try request(m, items[2]).id])
    }

    /// S5, the main-check case: member 2's change makes the main check look like a network failure. Only member 2 is charged;
    /// members 1 and 3 never accumulate a count and never fail (the old default charged the last member, 3).
    @Test func inconclusiveMainCheckChargesOnlyTheCulprit() async throws {
        let m = try MergeFixture()
        let items = try await threeApproved(m, [["src/a.txt": "a"], ["src/b-net.txt": "b"], ["src/c.txt": "c"]])
        try setMainCheck(m, "make smoke")
        m.world.checks.onRun { call in
            guard call.command == "make smoke",
                  FileManager.default.fileExists(atPath: call.workingDirectory.appending(path: "src/b-net.txt").path) else { return nil }
            return FakeCheckRunner.fail("getaddrinfo ENOTFOUND registry.npmjs.org")
        }
        let q = queue(m)
        for round in 1...3 {
            _ = try #require(try await batch(q, m))
            let (ra, rb, rc) = (try request(m, items[0]), try request(m, items[1]), try request(m, items[2]))
            #expect(ra.status == .merged && ra.inconclusive == 0, "round \(round)")
            #expect(rc.status == .queued && rc.inconclusive == 0 && rc.requeues == 0, "C is never charged (round \(round))")
            #expect(round < 3 ? (rb.status == .queued && rb.inconclusive == round) : rb.status == .failed, "round \(round)")
        }
        m.world.checks.onRun(nil)
        #expect(try #require(try await batch(q, m)).merged == [try request(m, items[2]).id])
    }

    /// S4: every principal whose code is in the candidate counts, including every request the queue landed earlier. A
    /// Workspace-profile author's change that landed earlier makes a later `.main`, `.mainAtBase` and `.item` run sandboxed,
    /// whoever sets the check and however many green runs came after.
    @Test func earlierLandedNonFullAuthorForcesTheSandbox() async throws {
        let m = try MergeFixture()
        let landed = try await m.approved()
        try await batch(queue(m), m)
        let head = try main(m)
        let junior = try m.store.hire(companyId: m.company.id, name: "jr", role: "junior", model: "sonnet")
        let ops = try m.store.hire(companyId: m.company.id, name: "ops-1", role: "ops", model: "sonnet")
        try m.store.updateSandbox(companyId: m.company.id, SandboxPatch(profile: .full), userHome: try tempDir())
        try m.store.updateSandbox(companyId: m.company.id, SandboxPatch(roleProfiles: ["ops": .full, "engineer": .full, "junior": .workspace]),
                                  userHome: try tempDir())
        try m.exec("UPDATE company SET mainCheckSetById = ? WHERE id = ?", [ops.id, m.company.id])
        let route = Orchestrator.checkRoute(store: m.store)
        let company = try #require(try m.store.company(id: m.company.id))
        func place(_ kind: MergeRun.Kind, itemId: String? = nil, batch: String? = nil, at commit: String? = nil) async throws -> String {
            let runId = UUID().uuidString
            let at = try commit ?? main(m)
            let dir = try EngineExport.export(store: m.store, company: company, runId: runId, commit: at)
            let run = MergeRun(id: runId, companyId: company.id, batchId: batch, candidateCommit: at, kind: kind, itemId: itemId, status: .running)
            try await m.store.writer.write { try run.insert($0) }
            return dir.path
        }
        func sandboxed(_ r: CheckRoute) -> Bool { if case .sandboxed = r { return true } else { return false } }
        // The earlier landing's author is Full: unsandboxed (the control).
        let current = try m.item("Current")
        try m.exec("UPDATE workItem SET ownerId = ? WHERE id = ?", [m.eng.id, current.id])
        #expect(!sandboxed(route(try await place(.main, itemId: current.id))), "control")
        #expect(!sandboxed(route(try await place(.mainAtBase, at: head))), "control")
        // Now the earlier landing's author is a Workspace-profile agent.
        try m.exec("UPDATE workItem SET ownerId = ? WHERE id = ?", [junior.id, landed.id])
        try m.exec("DELETE FROM workLease WHERE itemId = ?", [landed.id])
        // A green run after that landing does not clear it.
        let green = MergeRun(companyId: company.id, kind: .main, status: .passed, startedAt: m.now.addingTimeInterval(60))
        try await m.store.writer.write { try green.insert($0) }
        #expect(sandboxed(route(try await place(.mainAtBase, at: head))))
        #expect(sandboxed(route(try await place(.main, itemId: current.id))))
        #expect(sandboxed(route(try await place(.item, itemId: current.id))))
    }

    /// Controller ruling 2: the red-main re-check runs only on the engine-recorded head. A live `main` that differs (someone moved
    /// it outside the queue) is not checked here.
    @Test func redMainRecheckOnlyOnTheRecordedHead() async throws {
        let m = try MergeFixture()
        _ = try await threeApproved(m, [["src/a.txt": "a"]])
        try setMainCheck(m, "make smoke")
        m.world.checks.onRun { call in call.command == "make smoke" ? FakeCheckRunner.fail("red") : nil }
        let q = queue(m)
        _ = try await batch(q, m)
        #expect(try m.store.company(id: m.company.id)?.mergeHold == Store.redMainHold)
        // main moves outside the queue; the checks would now pass.
        _ = try GitFixture.plainGit(["commit", "-q", "--allow-empty", "-m", "outside"], in: m.root)
        m.world.checks.onRun(nil)
        let before = m.world.checks.calls.count
        #expect(try await batch(q, m) == nil)
        #expect(m.world.checks.calls.count == before, "no check ran on an unrecorded head")
        #expect(try m.store.company(id: m.company.id)?.mergeHold == Store.redMainHold)
    }

    /// Controller ruling 2: the `mainAtBase` run's principals are the setter and the authors of what landed since; a non-Full
    /// author, or a main whose latest commit the queue did not land, makes it sandboxed.
    @Test func mainAtBasePrincipalsIncludeLandedAuthors() async throws {
        let m = try MergeFixture()
        let i = try await m.approved()
        try await batch(queue(m), m)
        let head = try main(m)
        let junior = try m.store.hire(companyId: m.company.id, name: "jr", role: "junior", model: "sonnet")
        let ops = try m.store.hire(companyId: m.company.id, name: "ops-1", role: "ops", model: "sonnet")
        try m.store.updateSandbox(companyId: m.company.id, SandboxPatch(profile: .full), userHome: try tempDir())
        func roles(_ r: [String: PermissionProfile]) throws {
            try m.store.updateSandbox(companyId: m.company.id, SandboxPatch(roleProfiles: r), userHome: try tempDir())
        }
        try roles(["ops": .full, "engineer": .full, "junior": .workspace])
        try m.exec("UPDATE company SET mainCheckSetById = ? WHERE id = ?", [ops.id, m.company.id])
        let route = Orchestrator.checkRoute(store: m.store)
        let company = try #require(try m.store.company(id: m.company.id))
        func place(at commit: String) async throws -> String {
            let runId = UUID().uuidString
            let dir = try EngineExport.export(store: m.store, company: company, runId: runId, commit: commit)
            let run = MergeRun(id: runId, companyId: company.id, candidateCommit: commit, kind: .mainAtBase, status: .running)
            try await m.store.writer.write { try run.insert($0) }
            return dir.path
        }
        func sandboxed(_ r: CheckRoute) -> Bool { if case .sandboxed = r { return true } else { return false } }
        // Full setter, Full author of what landed (the main head is that request's commit): unsandboxed.
        #expect(!sandboxed(route(try await place(at: head))))
        // A non-Full author among what landed since: sandboxed.
        try m.exec("UPDATE workItem SET ownerId = ? WHERE id = ?", [junior.id, i.id])
        try m.exec("DELETE FROM workLease WHERE itemId = ?", [i.id])
        #expect(sandboxed(route(try await place(at: head))))
        try m.exec("UPDATE workItem SET ownerId = ? WHERE id = ?", [m.eng.id, i.id])
        #expect(!sandboxed(route(try await place(at: head))), "control")
        // A commit the queue did not land (unknown author): sandboxed.
        _ = try GitFixture.plainGit(["commit", "-q", "--allow-empty", "-m", "outside"], in: m.root)
        #expect(sandboxed(route(try await place(at: try main(m)))))
        // No setter: sandboxed.
        try m.exec("UPDATE company SET mainCheckSetById = NULL WHERE id = ?", [m.company.id])
        #expect(sandboxed(route(try await place(at: head))))
    }

    // MARK: Stop during the landing, and a stuck landing

    /// A stop that arrives inside the landing closure, before `main` moves, abandons the batch: the journal ends `done`
    /// "interrupted", the requests go back, and after the resume nothing redoes a fast-forward for them.
    @Test func stopInsideTheLandingNeverRedoesTheMove() async throws {
        let m = try MergeFixture()
        let items = try await threeApproved(m, [["src/a.txt": "a"], ["src/b.txt": "b"]])
        let base = try main(m)
        let (store, now) = (m.store, m.now)
        store.journalProbe.set { label in
            if label == "backedUp" { _ = try? store.emergencyStop(note: nil, by: "owner", now: now) }
            return false
        }
        try m.exec("CREATE TRIGGER no_landing BEFORE UPDATE OF status ON mergeRequest WHEN NEW.status = 'landing' BEGIN SELECT RAISE(ABORT, 'no landing'); END")
        let q = queue(m)
        _ = try await batch(q, m)
        store.journalProbe.set(nil)
        await q.stopAll(reason: "owner")
        #expect(try main(m) == base)
        let journal = try #require(try m.store.mergeBatches(companyId: m.company.id).first)
        #expect(journal.step == .done && journal.error?.contains("interrupted") == true, "\(journal.step) \(journal.error ?? "")")
        #expect(try items.allSatisfy { try request(m, $0).status == .queued && request(m, $0).requeues == 0 })
        #expect(try m.store.company(id: m.company.id)?.pendingMainCommit == nil)
        // Resumed (the fault gone): the recovery finds nothing to redo, and the next batch lands both once.
        try m.exec("DROP TRIGGER no_landing")
        try m.store.resumeAfterStop(now: m.now)
        #expect(await q.recover(company: try #require(try m.store.company(id: m.company.id))) == 0)
        #expect(try main(m) == base)
        let next = try #require(try await batch(q, m))
        #expect(next.merged.count == 2)
        for i in items { #expect(try m.kinds(i).filter { $0 == .merged }.count == 1) }
    }

    /// Recovery at `backedUp`/`landing` never redoes the fast-forward for requests that are no longer the batch's (back in the
    /// queue, withdrawn): it abandons the batch and `main` stays where it was.
    @Test(arguments: [MergeStep.backedUp, MergeStep.landing])
    func recoveryDoesNotLandWithdrawnRequests(step: MergeStep) async throws {
        let m = try MergeFixture()
        let items = try await threeApproved(m, [["src/a.txt": "a"], ["src/b.txt": "b"]])
        let base = try main(m)
        m.store.journalProbe.set { $0 == step.rawValue }
        _ = try await batch(queue(m), m)
        m.store.journalProbe.set(nil)
        let open = try #require(try m.store.openMergeBatches(companyId: m.company.id).first)
        #expect(open.step == step)
        // One request is withdrawn while the engine is down, the other put back in the queue.
        try m.exec("UPDATE mergeRequest SET status = 'cancelled' WHERE itemId = ?", [items[0].id])
        try m.exec("UPDATE mergeRequest SET status = 'queued', batchId = NULL WHERE itemId = ?", [items[1].id])
        #expect(await queue(m).recover(company: try #require(try m.store.company(id: m.company.id))) == 1)
        #expect(try main(m) == base, "the withdrawn change did not land")
        #expect(try m.store.company(id: m.company.id)?.pendingMainCommit == nil)
        let journal = try #require(try m.store.mergeBatches(companyId: m.company.id).first)
        #expect(journal.step == .done && journal.error == "interrupted")
        #expect(try request(m, items[0]).status == .cancelled)
    }

    /// Once `main` has moved the landing always finishes, whatever the owner does next: a stop raised right after the CAS
    /// changes nothing.
    @Test func stopAfterTheMoveStillRecords() async throws {
        let m = try MergeFixture()
        let items = try await threeApproved(m, [["src/a.txt": "a"], ["src/b.txt": "b"]])
        let (store, now) = (m.store, m.now)
        store.journalProbe.set { label in
            if label == "moved" { _ = try? store.emergencyStop(note: nil, by: "owner", now: now) }
            return false
        }
        let q = queue(m)
        let outcome = try #require(try await batch(q, m))
        store.journalProbe.set(nil)
        #expect(outcome.merged.count == 2)
        try expectDone(m, items)
    }

    func expectDone(_ m: MergeFixture, _ items: [WorkItem]) throws {
        let tip = try main(m)
        for i in items {
            #expect(try m.fresh(i).status == .done && request(m, i).status == .merged && m.kinds(i).filter { $0 == .merged }.count == 1)
        }
        #expect(try m.store.company(id: m.company.id)?.mainCommit == tip)
        #expect(try m.store.openMergeBatches(companyId: m.company.id).isEmpty)
    }

    /// Liveness: a landing that could not be recorded keeps the queue from landing again, and is not stuck for good. While the
    /// fault lasts the owner's resume is refused (exactly, nothing half-cleared); once it is gone the resume records the landing,
    /// the engine's next tick finishes the batch and the queue moves on, with no restart.
    @Test func stuckLandingRecoversAndResumeRepairs() async throws {
        let m = try MergeFixture()
        let items = try await threeApproved(m, [["src/a.txt": "a"], ["src/b.txt": "b"]])
        m.exec_noThrow("CREATE TRIGGER no_record BEFORE UPDATE OF status ON mergeRequest WHEN NEW.status = 'merged' BEGIN SELECT RAISE(ABORT, 'no record'); END")
        m.exec_noThrow("CREATE TRIGGER no_hold BEFORE UPDATE OF mergeHold ON company BEGIN SELECT RAISE(ABORT, 'no hold'); END")
        try m.exec("UPDATE company SET mergeBatchSize = 1 WHERE id = ?", [m.company.id])
        let q = queue(m)
        let first = try #require(try await batch(q, m))
        #expect(first.failed.count == 1 && first.merged.isEmpty)
        let landed = try main(m)
        let notices = try m.store.allNotices().filter { $0.title.contains("Merges are held") }.count
        #expect(notices == 1)
        // Ticks while it stays broken: nothing lands, nobody is told again.
        #expect(try await batch(q, m) == nil)
        #expect(try await batch(q, m) == nil)
        #expect(try main(m) == landed)
        #expect(try m.store.allNotices().filter { $0.title.contains("Merges are held") }.count == notices)
        // The owner's resume while the record still fails: refused, exactly.
        #expect(throws: WorkError.conflict(Store.landingNotRecordedRefusal)) { try m.store.resumeMergeQueue(companyId: m.company.id, by: Sender.owner) }
        // The fault clears; the owner resumes: the landing is recorded, and the engine carries on.
        try m.exec("DROP TRIGGER no_record")
        try m.exec("DROP TRIGGER no_hold")
        try m.store.resumeMergeQueue(companyId: m.company.id, by: Sender.owner)
        #expect(try request(m, items[0]).status == .merged)
        let next = try #require(try await batch(q, m))
        #expect(next.merged == [try request(m, items[1]).id], "recovery finished the stuck batch, then the next item landed")
        try expectDone(m, items)
        #expect(try main(m) != landed)
    }

    /// The same without the owner: the fault clears by itself and the engine's own next tick repairs it.
    @Test func stuckLandingRepairsItselfWhenTheFaultClears() async throws {
        let m = try MergeFixture()
        let items = try await threeApproved(m, [["src/a.txt": "a"], ["src/b.txt": "b"]])
        m.exec_noThrow("CREATE TRIGGER no_record BEFORE UPDATE OF status ON mergeRequest WHEN NEW.status = 'merged' BEGIN SELECT RAISE(ABORT, 'no record'); END")
        try m.exec("UPDATE company SET mergeBatchSize = 1 WHERE id = ?", [m.company.id])
        let q = queue(m)
        _ = try await batch(q, m)
        try m.exec("DROP TRIGGER no_record")
        let next = try #require(try await batch(q, m))
        #expect(next.merged == [try request(m, items[1]).id])
        try expectDone(m, items)
    }

    // MARK: Settings and holds

    @Test func settingsValidation() throws {
        let m = try MergeFixture()
        let id = m.company.id
        #expect(try m.store.mergeSettings(companyId: id) == MergeSettings())
        try m.store.setMergeSettings(companyId: id, MergeSettings(mainCheck: CheckSpec(command: "make smoke", timeoutSeconds: 90), batchSize: 3, strategy: .merge), by: .owner)
        let set = try m.store.mergeSettings(companyId: id)
        #expect(set.batchSize == 3 && set.strategy == .merge && set.mainCheck?.command == "make smoke" && set.mainCheck?.timeoutSeconds == 90)
        // An owner-set main check has no setter agent: its runs are sandboxed.
        #expect(try m.store.company(id: id)?.mainCheckSetById == nil)
        for bad in [0, 9, -1] {
            #expect(throws: WorkError.self) { try m.store.setMergeSettings(companyId: id, MergeSettings(batchSize: bad), by: .owner) }
        }
        #expect(throws: WorkError.self) {
            try m.store.setMergeSettings(companyId: id, MergeSettings(mainCheck: CheckSpec(command: "x", timeoutSeconds: 0)), by: .owner)
        }
        #expect(throws: WorkError.self) {
            try m.store.setMergeSettings(companyId: id, MergeSettings(mainCheck: CheckSpec(command: "  ")), by: .owner)
        }
        #expect(try m.store.mergeSettings(companyId: id).batchSize == 3, "a refused write changes nothing")
        // Not an agent's.
        #expect(throws: WorkError.forbidden("only the owner can change the merge settings")) {
            try m.store.setMergeSettings(companyId: id, MergeSettings(batchSize: 2), by: .agent(m.eng.id))
        }
        try m.store.setMergeSettings(companyId: id, MergeSettings(batchSize: 2), by: .system)
        #expect(try m.store.mergeSettings(companyId: id) == MergeSettings(mainCheck: nil, batchSize: 2, strategy: .ff))
    }

    @Test func mainCheckOnlyByCTO() throws {
        let m = try MergeFixture()
        let cto = try m.store.hire(companyId: m.company.id, name: "cto-1", role: "cto", model: "sonnet")
        let ctoArch = try m.store.hire(companyId: m.company.id, name: "cta-1", role: "cto-architect", model: "sonnet")
        for who in [m.eng, m.rev] {
            #expect(throws: WorkError.forbidden("only the CTO can set the main check")) {
                try m.store.setMainCheck(companyId: m.company.id, by: who.id, check: CheckSpec(command: "make smoke"))
            }
        }
        #expect(try m.store.company(id: m.company.id)?.mainCheck == nil)
        let before = try m.store.allNotices().count
        try m.store.setMainCheck(companyId: m.company.id, by: cto.id, check: CheckSpec(command: "make smoke"))
        #expect(try m.store.company(id: m.company.id)?.mainCheckSetById == cto.id)
        #expect(try m.store.allNotices().count == before + 1, "the owner is told")
        try m.store.setMainCheck(companyId: m.company.id, by: ctoArch.id, check: nil)
        #expect(try m.store.company(id: m.company.id)?.mainCheck == nil)
        // Another company's agent is not this company's.
        let beta = try m.world.company("Beta")
        #expect(throws: WorkError.self) { try m.store.setMainCheck(companyId: beta.id, by: cto.id, check: CheckSpec(command: "x")) }
        // The secret a command carries is redacted before it is stored.
        _ = try m.store.setSecret(companyId: m.company.id, name: "SMOKE_TOKEN", value: Self.secretValue, isTest: false, vault: m.vault, now: m.now)
        _ = try m.store.reloadRedactorIfNeeded(vault: m.vault, force: true)
        try m.store.setMainCheck(companyId: m.company.id, by: cto.id, check: CheckSpec(command: "curl -H 'x: \(Self.secretValue)' x"))
        #expect(try m.store.company(id: m.company.id)?.mainCheck?.command.contains(Self.secretValue) == false)
    }

    /// A hold set because the root checkout did not follow main is released only when the root matches main again: releasing it
    /// earlier would quarantine the old tree, and accepting that would revert the landed item.
    @Test func resumeRefusedWhileTheRootIsBehind() async throws {
        let m = try MergeFixture()
        let i = try await m.approved()
        m.store.mergeRefProbe.failOn(["follow"])
        let outcome = try #require(try await batch(queue(m), m))
        m.store.mergeRefProbe.failOn([])
        #expect(outcome.merged.count == 1 && outcome.held != nil)
        let hold = try #require(try m.store.company(id: m.company.id)?.mergeHold)
        #expect(hold.hasPrefix("the root checkout did not follow main"))
        #expect(throws: WorkError.conflict(Store.rootBehindRefusal)) { try m.store.resumeMergeQueue(companyId: m.company.id, by: Sender.owner) }
        #expect(try m.store.company(id: m.company.id)?.mergeHold == hold, "still held")
        // The owner brings the root to main (the files follow); now it resumes.
        _ = try GitFixture.plainGit(["reset", "--hard", "main"], in: m.root)
        try m.store.resumeMergeQueue(companyId: m.company.id, by: Sender.owner)
        #expect(try m.store.company(id: m.company.id)?.mergeHold == nil)
        // Not an agent's, and not by default.
        #expect(throws: WorkError.self) { try m.store.resumeMergeQueue(companyId: m.company.id, by: .agent(m.eng.id)) }
        _ = i
    }

    @Test func retryRequeuesAFailedRequest() async throws {
        let m = try MergeFixture()
        let i = try await m.approved()
        let r = try request(m, i)
        // Not failed: nothing to retry.
        #expect(throws: WorkError.self) { try m.store.requestMergeRetry(requestId: r.id, by: Sender.owner) }
        try m.exec("UPDATE mergeRequest SET status = 'failed', failure = 'engineError', detail = 'git failed' WHERE id = ?", [r.id])
        try m.exec("UPDATE workItem SET mergeState = 'none' WHERE id = ?", [i.id])
        #expect(throws: WorkError.forbidden("only the owner can retry a merge")) { try m.store.requestMergeRetry(requestId: r.id, by: .agent(m.eng.id)) }
        try m.store.requestMergeRetry(requestId: r.id, by: Sender.owner)
        let fresh = try request(m, i)
        #expect(fresh.id != r.id && fresh.status == .queued && fresh.attempts == 0 && fresh.headCommit == r.headCommit)
        #expect(try m.fresh(i).mergeState == .pending)
        #expect(try m.store.mergeRequest(companyId: m.company.id, ref: "M-\(fresh.number)")?.id == fresh.id)
        #expect(try m.store.mergeRequest(companyId: m.company.id, ref: i.key)?.id == fresh.id)
        // A second retry of the old one is refused (the item has a request in the queue).
        #expect(throws: WorkError.self) { try m.store.requestMergeRetry(requestId: r.id, by: Sender.owner) }
        #expect(try await batch(queue(m), m)?.merged == [fresh.id])
    }
}

/// A counter a check hook can bump from the runner's task.
final class BatchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    func next() -> Int { lock.withLock { n += 1; return n } }
}
