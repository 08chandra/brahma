import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// The merge queue (Plan 4a Task 1b): the git methods, the lock and `MergeQueue.runNextBatch`, which replaced 3a's one-item step.
/// Requests are queued through the real tools (`MergeFixture`); the queue is driven directly (`runNextBatch`) unless a test is
/// about the orchestrator's own tick.
@Suite(.scratch, .serialized) struct MergeQueueTests {
    // MARK: Helpers

    static let secretValue = "hunter2-value-xyz-1234567890"

    func queue(_ m: MergeFixture, known: @escaping @Sendable (String) -> [(String, String)] = { _ in [] },
               checks: (any CheckRunning)? = nil) -> MergeQueue {
        MergeQueue(store: m.store, paths: m.world.paths, checks: checks ?? m.world.checks, knownValues: known, clock: { m.now })
    }

    @discardableResult
    func batch(_ q: MergeQueue, _ m: MergeFixture) async throws -> MergeBatchOutcome? {
        await q.runNextBatch(company: try #require(try m.store.company(id: m.company.id)))
    }

    func main(_ m: MergeFixture) throws -> String { try #require(try m.ws.head(of: GitWorkspace.mainRef)) }
    func request(_ m: MergeFixture, _ i: WorkItem) throws -> MergeRequest { try #require(try m.store.latestMergeRequest(itemId: i.id)) }
    func git(_ m: MergeFixture, _ args: [String], in dir: URL? = nil) throws -> String {
        try GitFixture.plainGit(args, in: dir ?? m.root)
    }

    /// Claims `i`, writes `files` in its worktree and submits.
    func submit(_ m: MergeFixture, _ i: WorkItem, _ a: Agent? = nil, files: [String: Data]) throws {
        let a = a ?? m.eng
        _ = try m.tools(a).call(name: "claim_lease", arguments: ["key": .string(i.key)])
        let wt = m.ws.worktreePath(key: i.key)
        for (path, data) in files {
            let url = wt.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try data.write(to: url)
        }
        _ = try m.tools(a).call(name: "submit_for_review", arguments: ["key": .string(i.key), "summary": .string("did the work")])
    }

    /// Two items verified (checks passed) and approved, so M-1 and M-2 are queued; the engine has not run a tick since.
    func twoApproved(_ m: MergeFixture, first: [String: Data], second: [String: Data]) async throws -> (WorkItem, WorkItem) {
        let i = try m.item("First"), j = try m.item("Second")
        try submit(m, i, m.eng, files: first)
        try submit(m, j, m.eng2, files: second)
        try await m.cycle()
        try m.approve(try m.fresh(i))
        try m.approve(try m.fresh(j))
        return (try m.fresh(i), try m.fresh(j))
    }

    func text(_ s: String) -> Data { Data(s.utf8) }

    // MARK: Landing

    @Test func landsFastForwardThroughFinishMerge() async throws {
        let m = try MergeFixture()
        // A bystander branch that conflicts with what lands: `MergeSafety.afterLanding` flags it exactly once.
        let other = try m.item("Bystander")
        try submit(m, other, m.eng3, files: ["src/work.txt": text("someone else's version")])
        let i = try await m.approved()
        let oldMain = try main(m)
        let backup = "refs/brahma/main-backup"
        try git(m, ["update-ref", backup, oldMain])
        let head = try #require(try m.head(i))
        let q = queue(m)
        let outcome = try #require(try await batch(q, m))
        let r = try request(m, i)
        #expect(outcome.merged == [r.id] && outcome.bounced.isEmpty && outcome.requeued.isEmpty && outcome.failed.isEmpty)
        #expect(outcome.held == nil)
        #expect(try main(m) == head)
        #expect(outcome.mainCommit == head)
        #expect(try String(contentsOf: m.root.appending(path: "src/work.txt"), encoding: .utf8) == "work for \(i.key)")
        let item = try m.fresh(i)
        #expect(item.status == .done)
        #expect(item.mergedCommit == head)
        #expect(!m.ws.hasCheckout(key: i.key))
        #expect(try m.ws.head(of: m.ws.branchRef(key: i.key)) == nil)
        #expect(try m.store.company(id: m.company.id)?.mainCommit == head)
        #expect(r.status == .merged && r.mergedCommit == head)
        #expect(try m.ws.head(of: "refs/brahma/pre-merge/\(r.number)") == oldMain)
        #expect(try m.ws.head(of: backup) == oldMain)
        let warned = try m.store.itemEvents(itemId: other.id, limit: 50).filter { $0.kind == .mergeConflict }
        #expect(warned.count == 1)
    }

    @Test func mergeCommitStrategy() async throws {
        let m = try MergeFixture()
        try m.exec("UPDATE company SET mergeStrategy = ? WHERE id = ?", [MergeStrategy.merge.rawValue, m.company.id])
        let i = try await m.approved("Add the widget")
        let oldMain = try main(m)
        let head = try #require(try m.head(i))
        try await batch(queue(m), m)
        let tip = try main(m)
        #expect(tip != head)
        #expect(try git(m, ["rev-parse", "\(tip)^1"]) == oldMain)
        #expect(try git(m, ["rev-parse", "\(tip)^2"]) == head)
        #expect(try git(m, ["log", "-1", "--format=%s", tip]) == "Merge \(i.key): Add the widget")
        #expect(try m.fresh(i).mergedCommit == tip)
        #expect(try m.store.company(id: m.company.id)?.mainCommit == tip)
    }

    @Test func rebasesWhenMainMoved() async throws {
        let m = try MergeFixture()
        let (i, j) = try await twoApproved(m, first: ["src/a.txt": text("a")], second: ["src/b.txt": text("b")])
        let headJ = try #require(try m.head(j))
        let q = queue(m)
        try await batch(q, m)
        #expect(try m.fresh(i).status == .done)
        let afterFirst = try main(m)
        let outcome = try #require(try await batch(q, m))
        let r = try request(m, j)
        #expect(outcome.merged == [r.id])
        let tip = try main(m)
        #expect(tip != headJ)                                   // rebased: a new commit
        #expect(r.headCommit == headJ)                          // the request stays pinned to what was verified
        #expect(try git(m, ["rev-parse", "\(tip)^"]) == afterFirst)
        #expect(FileManager.default.fileExists(atPath: m.root.appending(path: "src/a.txt").path))
        #expect(FileManager.default.fileExists(atPath: m.root.appending(path: "src/b.txt").path))
        #expect(try m.fresh(j).mergedCommit == tip)
    }

    @Test func conflictUsesFinishMergeWithBase() async throws {
        let m = try MergeFixture()
        let (i, j) = try await twoApproved(m, first: ["a.txt": text("one\n")], second: ["a.txt": text("two\n")])
        let q = queue(m)
        try await batch(q, m)
        let landed = try main(m)
        let outcome = try #require(try await batch(q, m))
        let r = try request(m, j)
        #expect(outcome.bounced == [r.id])
        #expect(r.status == .bounced && r.failure == .conflict)
        #expect(r.conflictFiles == ["a.txt"])
        #expect(try main(m) == landed)
        let item = try m.fresh(j)
        #expect(item.status == .inProgress)
        #expect(try m.kinds(j).contains(.mergeConflict))
        // 3a's conflict brief got the merge base and main's side.
        let briefs = try FileManager.default.contentsOfDirectory(at: m.root.appending(path: ".brahma/conflicts"), includingPropertiesForKeys: nil)
        let brief = try #require(briefs.first { $0.lastPathComponent.hasPrefix(j.key) })
        let body = try String(contentsOf: brief, encoding: .utf8)
        let base = try git(m, ["merge-base", landed, r.headCommit])
        #expect(body.contains("Merge base: \(base)"))
        #expect(body.contains("main: \(landed)"))
        #expect(body.contains("## a.txt"))
        // The merge work left nothing in the workspace.
        #expect(try git(m, ["status", "--porcelain"]).isEmpty)
        _ = i
    }

    @Test func conflictNamesParsedWithNul() async throws {
        let m = try MergeFixture()
        let name = "a b\tc.txt"
        let (_, j) = try await twoApproved(m, first: [name: text("one\n")], second: [name: text("two\n")])
        let q = queue(m)
        try await batch(q, m)
        try await batch(q, m)
        #expect(try request(m, j).conflictFiles == [name])
    }

    @Test func binaryConflictListed() async throws {
        let m = try MergeFixture()
        let (_, j) = try await twoApproved(m, first: ["img.bin": Data([0, 1, 2, 3, 0, 255])], second: ["img.bin": Data([9, 0, 8, 0, 7])])
        let q = queue(m)
        try await batch(q, m)
        let outcome = try #require(try await batch(q, m))
        #expect(outcome.bounced.count == 1)
        #expect(try request(m, j).conflictFiles == ["img.bin"])
    }

    @Test func branchWithMergeCommitsRebases() async throws {
        let m = try MergeFixture()
        let i = try m.item("Merges inside"), j = try m.item("Other")
        _ = try m.tools(m.eng).call(name: "claim_lease", arguments: ["key": .string(i.key)])
        let wt = m.ws.worktreePath(key: i.key)
        try git(m, ["checkout", "-q", "-b", "side"], in: wt)
        try m.write("side.txt", "side", in: wt)
        try git(m, ["add", "-A"], in: wt); try git(m, ["commit", "-q", "-m", "side"], in: wt)
        try git(m, ["checkout", "-q", "item/\(i.key)"], in: wt)
        try m.write("top.txt", "top", in: wt)
        try git(m, ["add", "-A"], in: wt); try git(m, ["commit", "-q", "-m", "top"], in: wt)
        try git(m, ["merge", "--no-ff", "-q", "-m", "merge side", "side"], in: wt)
        try git(m, ["branch", "-q", "-D", "side"], in: wt)
        _ = try m.tools(m.eng).call(name: "submit_for_review", arguments: ["key": .string(i.key), "summary": .string("merged")])
        try submit(m, j, m.eng2, files: ["other.txt": text("o")])
        try await m.cycle()
        try m.approve(try m.fresh(j)); try m.approve(try m.fresh(i))
        let q = queue(m)
        try await batch(q, m)                       // Other lands first, so the merge-commit branch is behind main
        let outcome = try #require(try await batch(q, m))
        #expect(outcome.merged == [try request(m, i).id])
        for f in ["side.txt", "top.txt", "other.txt"] {
            #expect(FileManager.default.fileExists(atPath: m.root.appending(path: f).path), "\(f)")
        }
    }

    // MARK: Checks

    @Test func checksRunInFreshExport() async throws {
        let m = try MergeFixture()
        let i = try await m.approved()
        let seen = Seen()
        m.world.checks.onRun { call in
            seen.add(Seen.Entry(dir: call.workingDirectory, hadGit: FileManager.default.fileExists(atPath: call.workingDirectory.appending(path: ".git").path),
                                existed: FileManager.default.fileExists(atPath: call.workingDirectory.path),
                                agent: call.environment["BRAHMA_AGENT_ID"], dev: call.environment["BRAHMA_DEV"], command: call.command))
            return nil
        }
        let before = m.world.checks.calls.count
        try await batch(queue(m), m)
        #expect(m.world.checks.calls.count == before + 1)
        let entry = try #require(seen.entries.last)
        #expect(entry.existed && !entry.hadGit)
        #expect(entry.dir.standardizedFileURL != m.root.standardizedFileURL)
        #expect(!entry.dir.path.contains("/.brahma/wt/"))
        #expect(entry.agent == "merge" && entry.dev == nil)
        #expect(entry.command == MergeFixture.check)
        #expect(!FileManager.default.fileExists(atPath: entry.dir.path))           // deleted after
        let runs = try m.store.mergeRuns(requestId: try request(m, i).id)
        #expect(runs.count == 1)
        let run = try #require(runs.first)
        #expect(run.kind == .item && run.status == .passed && run.exitCode == 0)
        #expect(run.candidateCommit == (try request(m, i)).candidateCommit)
        #expect(entry.dir.lastPathComponent == run.id)
    }

    @Test func tamperedSnapshotBounces() async throws {
        let m = try MergeFixture()
        try m.write("scripts/check.sh", "exit 0\n", in: m.root)
        try git(m, ["add", "-A"]); try git(m, ["commit", "-q", "-m", "add the check script"])
        try m.store.recordMainCommit(companyId: m.company.id, commit: try main(m))
        let i = try m.store.createWorkItem(companyId: m.company.id, by: .owner, draft: WorkItemDraft(
            type: .task, title: "Scripted", checkSpec: CheckSpec(command: "sh scripts/check.sh", paths: ["src"]), tier: .m,
            reviewerId: m.rev.id, status: .ready), now: m.now)
        try submit(m, i, m.eng, files: ["src/x.txt": text("x")])
        try await m.cycle()
        try m.approve(try m.fresh(i))
        let snapshot = m.root.appending(path: ".brahma/checks/\(i.key)/rev\(try m.fresh(i).checkRevision)/scripts/check.sh")
        try "exit 1 # weakened\n".write(to: snapshot, atomically: true, encoding: .utf8)
        let before = try main(m)
        let before2 = m.world.checks.calls.count
        let outcome = try #require(try await batch(queue(m), m))
        let r = try request(m, i)
        #expect(outcome.bounced == [r.id] && r.failure == .snapshotTampered)
        #expect(m.world.checks.calls.count == before2)
        #expect(try main(m) == before)
        let item = try m.fresh(i)
        #expect(item.reviewFlags.contains { $0.hasPrefix("check snapshot tampered: ") })
        #expect(item.status == .inProgress)
    }

    @Test func mainCheckRunsFirst() async throws {
        let m = try MergeFixture()
        let i = try await m.approved()
        try await m.store.writer.write { db in
            var c = try #require(try Company.fetchOne(db, key: m.company.id))
            c.mainCheck = CheckSpec(command: "make smoke")
            try c.update(db)
        }
        let before = m.world.checks.calls.count
        try await batch(queue(m), m)
        #expect(m.world.checks.calls.dropFirst(before).map(\.command) == ["make smoke", MergeFixture.check])
        let runs = try m.store.mergeRuns(requestId: try request(m, i).id)
        #expect(runs.map(\.kind) == [.main, .item])
        // A failing main check bounces with its tail, before the item check runs.
        let j = try await m.approved("Second", by: m.eng2, file: "src/second.txt")
        m.world.checks.enqueue(FakeCheckRunner.fail("smoke exploded"))
        let mark = m.world.checks.calls.count
        let outcome = try #require(try await batch(queue(m), m))
        let r = try request(m, j)
        #expect(outcome.bounced == [r.id] && r.failure == .mainCheckFailed)
        #expect(r.outputTail?.contains("smoke exploded") == true)
        #expect(m.world.checks.calls.count == mark + 1)
    }

    @Test func mergesVerifiedCommitNotLaterEdits() async throws {
        let m = try MergeFixture()
        let i = try await m.approved()
        let verified = try #require(try m.fresh(i).verifiedCommit)
        let wt = m.ws.worktreePath(key: i.key)
        try m.write("src/later.txt", "sneaked in after approval", in: wt)
        try git(m, ["add", "-A"], in: wt); try git(m, ["commit", "-q", "-m", "later"], in: wt)
        #expect(try m.head(i) != verified)
        try await batch(queue(m), m)
        #expect(try main(m) == verified)
        #expect(!FileManager.default.fileExists(atPath: m.root.appending(path: "src/later.txt").path))
        #expect(try m.fresh(i).mergedCommit == verified)
    }

    @Test func secretInCandidateBouncesBeforeLanding() async throws {
        let m = try MergeFixture()
        let i = try m.item("Leaky")
        try submit(m, i, files: ["src/config.txt": text("token = \(Self.secretValue)\n")])
        try await m.cycle()
        try m.approve(try m.fresh(i))
        let before = try main(m)
        let value = Self.secretValue
        let outcome = try #require(try await batch(queue(m, known: { _ in [("DEPLOY_TOKEN", value)] }), m))
        let r = try request(m, i)
        #expect(outcome.bounced == [r.id] && r.failure == .secretFound)
        #expect(try main(m) == before)
        #expect(r.detail?.contains(Self.secretValue) != true && r.outputTail?.contains(Self.secretValue) != true)
        #expect(try m.fresh(i).status == .inProgress)
    }

    // MARK: The root checkout

    /// 3a's rule stays (Task 1b fix round, ruling S1): the queue never commits what is uncommitted at the root to `main`. The
    /// tick quarantines it (a ref, one owner ask), restores the checkout, lands nothing and creates no commit.
    @Test func dirtyRootIsQuarantinedNotCommitted() async throws {
        let m = try MergeFixture()
        let i = try await m.approved()
        let oldMain = try main(m)
        try m.write("notes/owner.txt", "the owner's uncommitted note", in: m.root)
        try await m.cycle()
        #expect(try main(m) == oldMain)
        #expect(try m.store.company(id: m.company.id)?.mainCommit == oldMain)
        #expect(try git(m, ["log", "--format=%s", "main"]).contains("unattributed") == false)
        let refs = try git(m, ["for-each-ref", "--format=%(refname)", "refs/brahma/quarantine/"]).split(separator: "\n")
        #expect(refs.count == 1)
        let ref = String(try #require(refs.first))
        #expect(try git(m, ["show", "\(ref):notes/owner.txt"]) == "the owner's uncommitted note")
        #expect(try git(m, ["rev-parse", "\(ref)^"]) == oldMain)
        #expect(try git(m, ["status", "--porcelain"]).isEmpty)           // the checkout is main again
        let asks = try await m.store.writer.read { db in
            try Ask.filter(Column("companyId") == m.company.id && Column("category") == "engine-code").fetchAll(db)
        }
        #expect(asks.count == 1 && asks[0].status == .pendingOwner && asks[0].title == Store.quarantineTitle)
        let r = try request(m, i)
        #expect(r.status == .queued && r.requeues == 0)
        #expect(try m.fresh(i).status == .inReview)
        // Held: more ticks land nothing and file nothing new, until the owner decides.
        m.world.clock.advance(120); try await m.cycle()
        #expect(try main(m) == oldMain)
        #expect(try request(m, i).status == .queued)
    }

    @Test func secretInDirtyRootNeverReachesMain() async throws {
        let m = try MergeFixture()
        let i = try await m.approved()
        let before = try main(m)
        try m.write("leak.env", "KEY=AKIAABCDEFGHIJKLMNOP\n", in: m.root)
        try await m.cycle()
        try await m.cycle()
        #expect(try main(m) == before)
        #expect(try git(m, ["log", "--all", "--format=%H", "--", "leak.env"]).split(separator: "\n").allSatisfy { sha in
            (try? git(m, ["merge-base", "--is-ancestor", String(sha), "main"])) == nil })   // only a quarantine ref has it
        #expect(try git(m, ["for-each-ref", "--format=%(refname)", "refs/brahma/quarantine/"]).split(separator: "\n").count == 1)
        #expect(try m.store.company(id: m.company.id)?.mainCommit == before)
        let r = try request(m, i)
        #expect(r.status == .queued && r.requeues == 0)
        let asks = try await m.store.writer.read { db in
            try Ask.filter(Column("companyId") == m.company.id && Column("category") == "engine-code").fetchAll(db)
        }
        #expect(asks.count == 1)
        #expect(!asks[0].summary.contains("AKIAABCDEFGHIJKLMNOP"))      // names only, never a value
        #expect(try m.store.hasMergeWork(companyId: m.company.id))
    }

    @Test func rootOnOtherBranchDoesNotLand() async throws {
        let m = try MergeFixture()
        let i = try await m.approved()
        let before = try main(m)
        try git(m, ["checkout", "-q", "-b", "x"])
        let q = queue(m)
        try await batch(q, m)
        try await batch(q, m)
        #expect(try main(m) == before)
        let r = try request(m, i)
        #expect(r.status == .queued && r.requeues == 0)
        let alerts = try await m.store.writer.read { db in
            try Ask.filter(Column("kind") == AskKind.engineAlert && Column("companyId") == m.company.id).fetchAll(db)
        }.filter { ($0.title + $0.summary).contains("main checkout is on refs/heads/x; switch it back to main") }
        #expect(alerts.count == 1)
        // Back on main it lands.
        try git(m, ["checkout", "-q", "main"])
        let outcome = try #require(try await batch(q, m))
        #expect(outcome.merged == [r.id])
    }

    @Test func rootEditsDuringBatchRequeue() async throws {
        let m = try MergeFixture()
        let i = try await m.approved()
        let before = try main(m)
        let root = m.root
        m.world.checks.onRun { _ in
            try? FileManager.default.createDirectory(at: root.appending(path: "src"), withIntermediateDirectories: true)
            try? "an edit made while the batch ran".write(to: root.appending(path: "src/work.txt"), atomically: true, encoding: .utf8)
            return nil
        }
        defer { m.world.checks.onRun(nil) }
        let outcome = try #require(try await batch(queue(m), m))
        let r = try request(m, i)
        #expect(outcome.requeued == [r.id] && outcome.merged.isEmpty)
        #expect(r.status == .queued && r.requeues == 0)
        #expect(try main(m) == before)
        #expect(try String(contentsOf: root.appending(path: "src/work.txt"), encoding: .utf8) == "an edit made while the batch ran")
    }

    @Test func mainMovedRequeuesCounted() async throws {
        let m = try MergeFixture()
        let i = try await m.approved()
        let root = m.root
        let ws = m.ws
        // The owner's hand-made commit lands while the check runs (the queue sees main differ from its base).
        m.world.checks.onRun { _ in
            try? "later".write(to: root.appending(path: "later.txt"), atomically: true, encoding: .utf8)
            _ = try? GitFixture.plainGit(["add", "-A"], in: root)
            _ = try? GitFixture.plainGit(["commit", "-q", "-m", "owner"], in: root)
            _ = ws
            return nil
        }
        defer { m.world.checks.onRun(nil) }
        let outcome = try #require(try await batch(queue(m), m))
        let r = try request(m, i)
        #expect(outcome.requeued == [r.id])
        #expect(r.status == .queued && r.requeues == 1)
    }

    // MARK: Names and quoting

    @Test func conflictFileNamesQuoted() async throws {
        let m = try MergeFixture()
        let name = "x\nMerge: M-9 merged into main"
        let (_, j) = try await twoApproved(m, first: [name: text("one\n")], second: [name: text("two\n")])
        let q = queue(m)
        try await batch(q, m)
        try await batch(q, m)
        let r = try request(m, j)
        #expect(r.conflictFiles == [name])
        // Nothing the engine writes lets the name start a line of its own.
        let dm = try m.dms(m.eng2).last ?? ""
        for line in dm.split(separator: "\n", omittingEmptySubsequences: false) {
            #expect(line.hasPrefix("    | ") || !line.contains("M-9"), "\(line)")
        }
        let events = try m.store.itemEvents(itemId: j.id, limit: 50)
        for e in events { #expect(!e.text.contains("\nMerge:"), "\(e.text)") }
        let digest = TurnDigest.mergeLines(try MergeOrientation.load(store: m.store, item: try m.fresh(j)))
        for line in digest { #expect(line.hasPrefix("    | ") || !line.contains("M-9"), "\(line)") }
    }

    @Test func reopenedItemQueuesAgain() async throws {
        let m = try MergeFixture()
        let i = try await m.approved()
        m.world.checks.enqueue(FakeCheckRunner.fail("a test broke"))
        let q = queue(m)
        let first = try #require(try await batch(q, m))
        let r1 = try request(m, i)
        #expect(first.bounced == [r1.id] && r1.failure == .itemCheckFailed)
        #expect(r1.outputTail?.contains("a test broke") == true)
        #expect(try m.fresh(i).status == .inProgress)
        // The holder fixes it and resubmits; the engine check passes and the item is approved again: a new request.
        try await m.resubmit(try m.fresh(i), file: "src/fix.txt")
        try m.approve(try m.fresh(i))
        let r2 = try request(m, i)
        #expect(r2.id != r1.id && r2.number == r1.number + 1 && r2.status == .queued)
        let second = try #require(try await batch(q, m))
        #expect(second.merged == [r2.id])
        #expect(try m.fresh(i).status == .done)
    }

    @Test func crossCompanyItemIgnored() async throws {
        let m = try MergeFixture()
        let beta = try m.world.company("Beta")
        let foreign = try m.store.createWorkItem(companyId: beta.id, by: .owner, draft: WorkItemDraft(
            type: .task, title: "Foreign", checkSpec: CheckSpec(command: "make test"), tier: .m, status: .ready), now: m.now)
        try m.exec("UPDATE workItem SET status = 'inReview', mergeState = 'pending', verifiedCommit = ? WHERE id = ?", [try main(m), foreign.id])
        let forged = MergeRequest(companyId: m.company.id, itemId: foreign.id, number: 1, headCommit: try main(m), enqueuedAt: m.now)
        try await m.store.writer.write { try forged.insert($0) }
        let before = try main(m)
        let outcome = try await batch(queue(m), m)
        #expect(outcome == nil || outcome?.merged.isEmpty == true)
        #expect(try main(m) == before)
        let stored = try #require(try await m.store.writer.read { try MergeRequest.fetchOne($0, key: forged.id) })
        #expect(stored.status == .cancelled)
        let item = try #require(try m.store.workItem(id: foreign.id))
        #expect(item.status == .inReview && item.mergeState == .pending)
    }

    // MARK: The kill switch

    @Test func mergeQueueHonorsEmergencyStop() async throws {
        let m = try MergeFixture()
        let i = try await m.approved()
        let before = try main(m)
        let cancelled = Seen()
        let started = Seen()
        m.world.checks.onRun { call in
            started.add(Seen.Entry(dir: call.workingDirectory, hadGit: false, existed: true, agent: nil, dev: nil, command: call.command))
            try? await Task.sleep(for: .seconds(2))
            if Task.isCancelled { cancelled.add(Seen.Entry(dir: call.workingDirectory, hadGit: false, existed: true, agent: nil, dev: nil, command: "cancelled")) }
            return nil
        }
        defer { m.world.checks.onRun(nil) }
        let q = queue(m)
        let company = try #require(try m.store.company(id: m.company.id))
        let task = Task { await q.runNextBatch(company: company) }
        for _ in 0..<400 where started.entries.isEmpty { try await Task.sleep(for: .milliseconds(10)) }
        #expect(started.entries.count == 1)
        _ = try m.store.emergencyStop(note: "test", by: "cli", now: m.now)
        await q.stopAll(reason: "stopped by the owner")
        let outcome = await task.value
        #expect(cancelled.entries.count == 1, "the check was cancelled")
        #expect(outcome?.merged.isEmpty ?? true)
        let r = try request(m, i)
        #expect(r.status == .queued && r.requeues == 0)
        #expect(try main(m) == before)
        #expect(try m.fresh(i).mergeState == .pending)
        // Nothing is claimed while the stop stands.
        #expect(try await batch(q, m) == nil)
        #expect(try request(m, i).status == .queued)
        // After the resume it lands.
        m.world.checks.onRun(nil)
        _ = try m.store.resumeAfterStop(now: m.now)
        let after = try #require(try await batch(q, m))
        #expect(after.merged == [r.id])
    }

    // MARK: Carry-forwards from Task 1a

    @Test func orphanedApprovalIsRequeuedNotLandedBlind() async throws {
        let m = try MergeFixture()
        let i = try await m.approved()
        // 1a recorded no request (git could not measure the approval) or a withdrawn one returned the item to `pending`.
        try m.exec("DELETE FROM mergeRequest WHERE itemId = ?", [i.id])
        #expect(try m.fresh(i).mergeState == .pending)
        let head = try #require(try m.fresh(i).verifiedCommit)
        let outcome = try #require(try await batch(queue(m), m))
        let r = try request(m, i)
        #expect(outcome.merged == [r.id])
        #expect(r.headCommit == head)                                   // re-measured, pinned to the verified commit
        #expect(try main(m) == head)
        #expect(try m.fresh(i).status == .done)
    }

    @Test func orphanWithSecretIsBouncedNotLanded() async throws {
        let m = try MergeFixture()
        let i = try m.item("Leaky")
        try submit(m, i, files: ["src/config.txt": text("token = \(Self.secretValue)\n")])
        try await m.cycle()
        try m.approve(try m.fresh(i))
        try m.exec("DELETE FROM mergeRequest WHERE itemId = ?", [i.id])
        let before = try main(m)
        let value = Self.secretValue
        _ = try await batch(queue(m, known: { _ in [("DEPLOY_TOKEN", value)] }), m)
        // The re-measure at claim time sees the leak: the item goes back to its holder and nothing lands.
        #expect(try main(m) == before)
        #expect(try m.fresh(i).status == .inProgress)
    }

    @Test func unmeasurableApprovalFailsClosed() async throws {
        let m = try MergeFixture()
        let i = try await m.approved()
        let before = try main(m)
        // Git cannot measure the approval (its verified commit is not in the repository) and 1a recorded no request.
        try m.exec("DELETE FROM mergeRequest WHERE itemId = ?", [i.id])
        try m.exec("UPDATE workItem SET verifiedCommit = ? WHERE id = ?", [String(repeating: "ab", count: 20), i.id])
        let outcome = try await batch(queue(m), m)
        #expect(outcome == nil)                                          // nothing was claimed, so nothing could land
        #expect(try main(m) == before)
        let r = try request(m, i)
        #expect(r.status == .failed && r.failure == .engineError)
        #expect(r.detail?.contains("could not measure") == true)
        #expect(try m.fresh(i).mergeState == MergeState.none)
        #expect(try m.store.allNotices().contains { $0.title == "Merge \(r.ref) (\(i.key)) stopped" })
        // It is not tried again by itself: the queue has nothing to do for it.
        #expect(!(try m.store.hasMergeWork(companyId: m.company.id)))
    }

    @Test func rebasedItemWithoutCheckIsRequeued() async throws {
        let m = try MergeFixture()
        let i = try await m.approved()
        let head = try #require(try m.fresh(i).verifiedCommit)
        // 3a's `.rebased` path: the queued request is withdrawn and, with no check to run again, the item is `pending` with none.
        try m.exec("UPDATE workItem SET checkSpec = NULL WHERE id = ?", [i.id])
        try m.store.finishMerge(itemId: i.id, result: .rebased(head: head))
        #expect(try request(m, i).status == .cancelled)
        #expect(try m.fresh(i).mergeState == .pending)
        #expect(try m.store.hasMergeWork(companyId: m.company.id))
        let outcome = try #require(try await batch(queue(m), m))
        let r = try request(m, i)
        #expect(outcome.merged == [r.id] && r.number == 2)
        #expect(try m.fresh(i).status == .done)
    }

    @Test func sandboxRouteKnowsTheQueuesExports() async throws {
        let m = try MergeFixture()
        let i = try await m.approved()
        let route = Orchestrator.checkRoute(store: m.store)
        let company = try #require(try m.store.company(id: m.company.id))
        let head = try main(m)
        let runId = UUID().uuidString
        let dir = try EngineExport.export(store: m.store, company: company, runId: runId, commit: head)
        defer { EngineExport.remove(store: m.store, company: company, runId: runId) }
        func refused(_ r: CheckRoute) -> Bool { if case .refused = r { return true } else { return false } }
        // No record: refused. A `running` merge run for this place: sandboxed to exactly that export.
        #expect(refused(route(dir.path)))
        let run = MergeRun(id: runId, companyId: company.id, requestId: nil, kind: .item, itemId: i.id, status: .running)
        try await m.store.writer.write { try run.insert($0) }
        guard case .sandboxed(let policy) = route(dir.path) else { Issue.record("not sandboxed: \(route(dir.path))"); return }
        #expect(policy.writable.map { $0.resolvingSymlinksInPath().path } == [dir.resolvingSymlinksInPath().path])
        // Another directory with that run's name, or a finished run: refused.
        #expect(refused(route(dir.deletingLastPathComponent().appending(path: "elsewhere").path)))
        try m.exec("UPDATE mergeRun SET status = 'passed' WHERE id = ?", [runId])
        #expect(refused(route(dir.path)))
    }

    // MARK: Fix round 1

    /// An item's check script, committed on main so its snapshot has something to pin.
    func scripted(_ m: MergeFixture, script: String = "scripts/check.sh", body: String = "exit 0\n") throws {
        try m.write(script, body, in: m.root)
        try git(m, ["add", "-A"]); try git(m, ["commit", "-q", "-m", "add \(script)"])
        try m.store.recordMainCommit(companyId: m.company.id, commit: try main(m))
    }

    func scriptedItem(_ m: MergeFixture, command: String = "sh scripts/check.sh") throws -> WorkItem {
        try m.store.createWorkItem(companyId: m.company.id, by: .owner, draft: WorkItemDraft(
            type: .task, title: "Scripted", checkSpec: CheckSpec(command: command, paths: ["src"]), tier: .m,
            reviewerId: m.rev.id, status: .ready), now: m.now)
    }

    /// S2: the main check's scripts are read from `base`, so a candidate that edits the script that gates its own landing does
    /// not change what runs.
    @Test func mainCheckScriptsArePinnedFromBase() async throws {
        let m = try MergeFixture()
        try scripted(m, script: "scripts/smoke.sh", body: "echo base-smoke\n")
        try await m.store.writer.write { db in
            var c = try #require(try Company.fetchOne(db, key: m.company.id))
            c.mainCheck = CheckSpec(command: "sh scripts/smoke.sh")
            try c.update(db)
        }
        let i = try m.item("Weakens the gate")
        try submit(m, i, files: ["scripts/smoke.sh": text("echo weakened\nexit 0\n"), "src/x.txt": text("x")])
        try await m.cycle()
        try m.approve(try m.fresh(i))
        let ran = Seen()
        m.world.checks.onRun { call in
            if call.command == "sh scripts/smoke.sh" {
                let content = (try? String(contentsOf: call.workingDirectory.appending(path: "scripts/smoke.sh"), encoding: .utf8)) ?? "missing"
                ran.add(Seen.Entry(dir: call.workingDirectory, hadGit: false, existed: true, agent: nil, dev: nil, command: content))
            }
            return nil
        }
        defer { m.world.checks.onRun(nil) }
        try await batch(queue(m), m)
        #expect(ran.entries.map(\.command) == ["echo base-smoke\n"], "\(ran.entries.map(\.command))")
        // What lands is still the candidate's own tree.
        #expect(try String(contentsOf: m.root.appending(path: "scripts/smoke.sh"), encoding: .utf8) == "echo weakened\nexit 0\n")
    }

    /// S2: the item's saved scripts are hashed at the guard and held; swapping one on disk afterwards (while the main check runs)
    /// does not change what the item check runs.
    @Test func snapshotSwappedAfterTheGuardIsNotUsed() async throws {
        let m = try MergeFixture()
        try scripted(m)
        try await m.store.writer.write { db in
            var c = try #require(try Company.fetchOne(db, key: m.company.id))
            c.mainCheck = CheckSpec(command: "make smoke")
            try c.update(db)
        }
        let i = try scriptedItem(m)
        try submit(m, i, files: ["src/x.txt": text("x")])
        try await m.cycle()
        try m.approve(try m.fresh(i))
        let snapshot = m.root.appending(path: ".brahma/checks/\(i.key)/rev\(try m.fresh(i).checkRevision)/scripts/check.sh")
        let seen = Seen()
        m.world.checks.onRun { call in
            if call.command == "make smoke" {
                try? "exit 1 # swapped after the guard\n".write(to: snapshot, atomically: true, encoding: .utf8)
            } else {
                let content = (try? String(contentsOf: call.workingDirectory.appending(path: "scripts/check.sh"), encoding: .utf8)) ?? "missing"
                seen.add(Seen.Entry(dir: call.workingDirectory, hadGit: false, existed: true, agent: nil, dev: nil, command: content))
            }
            return nil
        }
        defer { m.world.checks.onRun(nil) }
        try await batch(queue(m), m)
        #expect(seen.entries.map(\.command) == ["exit 0\n"], "the guard's bytes ran: \(seen.entries.map(\.command))")
        // A swap before the guard is a bounce (tamperedSnapshotBounces); a hash that differs is never overlaid.
        let item = try m.fresh(i)
        #expect(throws: MergeQueue.SnapshotTampered.self) { try MergeQueue.loadSnapshot(store: m.store, item: item, revision: item.checkRevision) }
    }

    /// S3: a merge run with no known principal runs sandboxed; a Full-profile principal behaves as before (unsandboxed).
    @Test func mergeRunPrincipalDecidesTheSandbox() async throws {
        let m = try MergeFixture()
        let i = try await m.approved()
        try m.store.updateSandbox(companyId: m.company.id, SandboxPatch(profile: .full), userHome: try tempDir())
        let route = Orchestrator.checkRoute(store: m.store)
        let company = try #require(try m.store.company(id: m.company.id))
        func place(_ kind: MergeRun.Kind, itemId: String?) async throws -> String {
            let runId = UUID().uuidString
            let dir = try EngineExport.export(store: m.store, company: company, runId: runId, commit: try main(m))
            let run = MergeRun(id: runId, companyId: company.id, kind: kind, itemId: itemId, status: .running)
            try await m.store.writer.write { try run.insert($0) }
            return dir.path
        }
        func sandboxed(_ r: CheckRoute) -> Bool { if case .sandboxed = r { return true } else { return false } }
        func unsandboxed(_ r: CheckRoute) -> Bool { if case .unsandboxed = r { return true } else { return false } }
        // The item's holder (a Full-profile engineer) is the principal of the item check: as before.
        #expect(unsandboxed(route(try await place(.item, itemId: i.id))))
        // ... also after its lease is gone (the assignee is the fallback), and with a sandboxed role it stays sandboxed.
        try m.exec("DELETE FROM workLease WHERE itemId = ?", [i.id])
        #expect(unsandboxed(route(try await place(.item, itemId: i.id))))
        // No item, no principal: sandboxed (never the old `?? true`).
        #expect(sandboxed(route(try await place(.item, itemId: nil))))
        // The main check's principal is who set it: nobody, or an agent that does not exist, is sandboxed.
        #expect(sandboxed(route(try await place(.main, itemId: i.id))))
        try m.exec("UPDATE company SET mainCheckSetById = 'no-such-agent' WHERE id = ?", [company.id])
        #expect(sandboxed(route(try await place(.main, itemId: i.id))))
        try m.exec("UPDATE company SET mainCheckSetById = ? WHERE id = ?", [m.eng.id, company.id])
        #expect(unsandboxed(route(try await place(.main, itemId: i.id))))
        try m.store.updateSandbox(companyId: m.company.id, SandboxPatch(roleProfiles: ["engineer": .sandboxed]), userHome: try tempDir())
        #expect(sandboxed(route(try await place(.main, itemId: i.id))))
        #expect(sandboxed(route(try await place(.item, itemId: i.id))))
    }

    /// S3b: a merge check runs unsandboxed only if EVERY principal whose code it executes narrows to Full: for the main check its
    /// setter and the item author(s) (a batch: every item), for the item check the holder and the assignee.
    @Test func mergeCheckSandboxNeedsEveryPrincipalFull() async throws {
        let m = try MergeFixture()
        let i = try await m.approved()
        let ops = try m.store.hire(companyId: m.company.id, name: "ops-1", role: "ops", model: "sonnet")
        let junior = try m.store.hire(companyId: m.company.id, name: "jr", role: "junior", model: "sonnet")
        try m.store.updateSandbox(companyId: m.company.id, SandboxPatch(profile: .full), userHome: try tempDir())
        func roles(_ r: [String: PermissionProfile]) throws {
            try m.store.updateSandbox(companyId: m.company.id, SandboxPatch(roleProfiles: r), userHome: try tempDir())
        }
        try roles(["ops": .full, "engineer": .full, "junior": .workspace])
        try m.exec("UPDATE company SET mainCheckSetById = ? WHERE id = ?", [ops.id, m.company.id])
        let route = Orchestrator.checkRoute(store: m.store)
        let company = try #require(try m.store.company(id: m.company.id))
        func place(_ kind: MergeRun.Kind, itemId: String?, batch: String? = nil) async throws -> String {
            let runId = UUID().uuidString
            let dir = try EngineExport.export(store: m.store, company: company, runId: runId, commit: try main(m))
            let run = MergeRun(id: runId, companyId: company.id, batchId: batch, kind: kind, itemId: itemId, status: .running)
            try await m.store.writer.write { try run.insert($0) }
            return dir.path
        }
        func sandboxed(_ r: CheckRoute) -> Bool { if case .sandboxed = r { return true } else { return false } }
        func unsandboxed(_ r: CheckRoute) -> Bool { if case .unsandboxed = r { return true } else { return false } }
        // Full setter and Full author (holder and assignee): as before, unsandboxed.
        #expect(unsandboxed(route(try await place(.main, itemId: i.id))))
        #expect(unsandboxed(route(try await place(.item, itemId: i.id))))
        // Full setter, Workspace-profile author: the main check runs that author's code, so it is sandboxed.
        try roles(["ops": .full, "engineer": .workspace, "junior": .workspace])
        #expect(sandboxed(route(try await place(.main, itemId: i.id))))
        #expect(sandboxed(route(try await place(.item, itemId: i.id))))
        // Workspace setter, Full author: sandboxed too.
        try roles(["ops": .workspace, "engineer": .full, "junior": .workspace])
        #expect(sandboxed(route(try await place(.main, itemId: i.id))))
        #expect(unsandboxed(route(try await place(.item, itemId: i.id))))
        try roles(["ops": .full, "engineer": .full, "junior": .workspace])
        // The holder and the assignee differ: both count (the assignee is not Full).
        try m.exec("UPDATE workItem SET ownerId = ? WHERE id = ?", [junior.id, i.id])
        #expect(sandboxed(route(try await place(.item, itemId: i.id))))
        #expect(sandboxed(route(try await place(.main, itemId: i.id))))
        try m.exec("UPDATE workItem SET ownerId = ? WHERE id = ?", [m.eng.id, i.id])
        #expect(unsandboxed(route(try await place(.main, itemId: i.id))))
        // A batch: every item counts, one non-Full item makes the run sandboxed.
        let other = try m.item("Other")
        try m.exec("UPDATE workItem SET ownerId = ? WHERE id = ?", [junior.id, other.id])
        var a = MergeRequest(companyId: m.company.id, itemId: i.id, number: 98, headCommit: try main(m), enqueuedAt: m.now)
        var b = MergeRequest(companyId: m.company.id, itemId: other.id, number: 99, headCommit: try main(m), enqueuedAt: m.now)
        a.batchId = "batch-1"; b.batchId = "batch-1"
        let (ra, rb) = (a, b)
        try await m.store.writer.write { try ra.insert($0); try rb.insert($0) }
        #expect(sandboxed(route(try await place(.main, itemId: i.id, batch: "batch-1"))))
        #expect(unsandboxed(route(try await place(.main, itemId: i.id, batch: "no-such-batch"))))
        // A missing candidate principal: sandboxed (no item, or an item with neither holder nor assignee).
        #expect(sandboxed(route(try await place(.main, itemId: nil))))
        try m.exec("DELETE FROM workLease WHERE itemId = ?", [i.id])
        try m.exec("UPDATE workItem SET ownerId = NULL WHERE id = ?", [i.id])
        #expect(sandboxed(route(try await place(.main, itemId: i.id))))
        #expect(sandboxed(route(try await place(.item, itemId: i.id))))
    }

    /// If the hold cannot be written after `main` moved (and the record worked), the request is not put back in the queue: it
    /// stays merged, so a retry cannot land it a second time.
    @Test func holdWriteFailingAfterTheMoveDoesNotRequeue() async throws {
        let m = try MergeFixture()
        let i = try await m.approved()
        let head = try #require(try m.fresh(i).verifiedCommit)
        let lock = m.root.appending(path: ".git/index.lock")
        m.store.mergeRefProbe.set { ref in if ref == "follow" { try? "".write(to: lock, atomically: true, encoding: .utf8) } }
        defer { m.store.mergeRefProbe.set(nil) }
        // Writing a hold fails.
        try m.exec("CREATE TRIGGER no_hold BEFORE UPDATE OF mergeHold ON company BEGIN SELECT RAISE(ABORT, 'no hold'); END")
        let outcome = try #require(try await batch(queue(m), m))
        let r = try request(m, i)
        #expect(outcome.merged == [r.id] && outcome.requeued.isEmpty)
        #expect(r.status == .merged && r.requeues == 0)
        #expect(try main(m) == head)
        #expect(try m.fresh(i).status == .done)
    }

    /// The owner's stop is read before the root is reset and cleaned for a quarantine (3a's gate): nothing is touched.
    @Test func stopBeforeQuarantineLeavesTheRootAlone() async throws {
        let m = try MergeFixture()
        let i = try await m.approved()
        try m.write("notes/owner.txt", "uncommitted", in: m.root)
        let store = m.store, now = m.now
        store.mergeRefProbe.set { ref in if ref == "refs/quarantine" { _ = try? store.emergencyStop(note: nil, by: "owner", now: now) } }
        defer { store.mergeRefProbe.set(nil) }
        let before = try main(m)
        try await batch(queue(m), m)
        #expect(try store.engineStopped() != nil)
        #expect(try main(m) == before)
        #expect(FileManager.default.fileExists(atPath: m.root.appending(path: "notes/owner.txt").path), "the root was not cleaned")
        #expect(try git(m, ["for-each-ref", "refs/brahma/quarantine/"]).isEmpty)
        let r = try request(m, i)
        #expect(r.status == .queued && r.requeues == 0)
    }

    /// I5: a candidate is scanned for its own company's secrets only: another company's value in this company's change neither
    /// bounces it nor names that other secret.
    @Test func otherCompaniesSecretsAreNotScanned() async throws {
        let m = try MergeFixture()
        let beta = try m.world.company("Beta")
        let value = "beta-only-secret-value-9876543210"
        try m.store.setSecret(companyId: beta.id, name: "BETA_TOKEN", value: value, isTest: false, vault: m.vault, now: m.now)
        _ = try m.store.reloadRedactorIfNeeded(vault: m.vault, force: true)
        #expect(m.store.knownSecretValues(companyId: beta.id).contains { $0.1 == value })
        #expect(!m.store.knownSecretValues(companyId: m.company.id).contains { $0.1 == value })
        let i = try m.item("Has the same string")
        try submit(m, i, files: ["src/config.txt": text("token = \(value)\n")])
        try await m.cycle()
        try m.approve(try m.fresh(i))
        // The default scan (no injected values) is the company's own secrets.
        let q = MergeQueue(store: m.store, paths: m.world.paths, checks: m.world.checks)
        let company = try #require(try m.store.company(id: m.company.id))
        let outcome = try #require(await q.runNextBatch(company: company))
        #expect(outcome.merged == [try request(m, i).id])
        #expect(try m.fresh(i).status == .done)
    }

    /// I6: the landing is recorded under the same `GitLock` as the move of `main`: while `finishMerge` completes the item, a
    /// second taker of the lock times out.
    @Test func landingIsRecordedUnderTheGitLock() async throws {
        let probe = LockProbe()
        let m = try MergeFixture(observers: [probe])
        let paths = m.world.paths, company = m.company.id
        probe.attempt = {
            do { try GitLock.withLock(paths: paths, companyId: company, wait: .milliseconds(100)) { }; return "free" }
            catch GitLockError.timeout { return "held" } catch { return "\(error)" }
        }
        let i = try await m.approved()
        try await batch(queue(m), m)
        #expect(try m.fresh(i).status == .done)
        #expect(probe.results == ["held"], "\(probe.results)")
    }

    /// Only the export fails (the data home's exports directory is a file): Brahma's own fault, so nothing is checked or landed,
    /// and the item is not returned to its holder.
    @Test func exportFaultAloneRequeuesWithoutLanding() async throws {
        let m = try MergeFixture()
        let i = try await m.approved()
        let before = try main(m)
        let export = m.store.gitWorkspace(root: m.root, companyId: m.company.id).exportPath(runId: "probe").deletingLastPathComponent()
        try FileManager.default.createDirectory(at: export.deletingLastPathComponent(), withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: export)
        try "blocked".write(to: export, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: export) }
        let mark = m.world.checks.calls.count
        let outcome = try #require(try await batch(queue(m), m))
        #expect(outcome.merged.isEmpty && outcome.bounced.isEmpty)
        #expect(m.world.checks.calls.count == mark, "no check ran without its export")
        #expect(try main(m) == before)
        let r = try request(m, i)
        #expect(r.status == .queued || r.status == .failed)
        #expect(try m.fresh(i).status == .inReview, "not returned to its holder")
        #expect(try m.kinds(i).contains(.mergeFailed) == false)
        // Once the fault clears it lands.
        try FileManager.default.removeItem(at: export)
        let after = try #require(try await batch(queue(m), m))
        #expect(after.merged == [r.id])
    }

    // MARK: Orchestrator

    @Test func orchestratorRunsQueueNotThe3aStep() async throws {
        let m = try MergeFixture()
        let i = try await m.approved()
        let head = try #require(try m.head(i))
        try await m.cycle()
        let r = try request(m, i)
        #expect(r.status == .merged)
        #expect(try main(m) == head)
        #expect(try m.fresh(i).status == .done)
        // 3a's step would have recorded no merge run and a verification run of purpose merge; the queue records its own.
        #expect(try m.store.mergeRuns(requestId: r.id).count == 1)
        #expect(!(try m.store.isMerging(itemId: i.id)))
        #expect(m.world.orchestrator.stopObservers.contains { $0 is MergeQueue })
    }

    // MARK: Git methods

    @Test func gitLockExcludesAndTimesOut() throws {
        let m = try MergeFixture()
        let paths = m.world.paths
        let key = "co-lock-test"
        let result = try GitLock.withLock(paths: paths, companyId: key) { 42 }
        #expect(result == 42)
        #expect(FileManager.default.fileExists(atPath: paths.home.appending(path: "run/git-\(key).lock").path))
        // Held by a nested caller on another descriptor: the second waits, then times out.
        #expect(throws: GitLockError.timeout) {
            try GitLock.withLock(paths: paths, companyId: key) {
                try GitLock.withLock(paths: paths, companyId: key, wait: Duration.milliseconds(200)) { 1 }
            }
        }
        #expect(throws: (any Error).self) { try GitLock.withLock(paths: paths, companyId: "../escape") { 1 } }
    }

    @Test func gitMethodsOnTheRoot() throws {
        let m = try MergeFixture()
        let ws = m.ws
        let tip = try #require(try ws.revParse("main"))
        #expect(try ws.revParse("no-such-ref") == nil)
        #expect(try ws.rootBranch() == "refs/heads/main")
        #expect(try ws.revListCount("main..main") == 0)
        // A commit on top of main, made with plain git in a scratch clone of the objects (the engine never builds one at the root).
        try m.write("loose.txt", "loose", in: m.root)
        try git(m, ["add", "-A"]); try git(m, ["commit", "-q", "-m", "next"])
        let c = try #require(try ws.revParse("main"))
        try git(m, ["reset", "-q", "--hard", tip])
        #expect(try ws.isAncestor(tip, of: c))
        #expect(try ws.revListCount("\(tip)..\(c)") == 1)
        #expect(try ws.shortstat(base: tip, head: c).contains("1 file changed"))
        // Off main: refused; on main: main moves by compare-and-swap and the checkout follows.
        try git(m, ["checkout", "-q", "-b", "elsewhere"])
        #expect(try ws.fastForwardMain(to: c) == .rootNotOnMain(ref: "refs/heads/elsewhere"))
        try git(m, ["checkout", "-q", "main"])
        #expect(try ws.fastForwardMain(to: c) == .ok)
        #expect(try ws.revParse("main") == c)
        #expect(try git(m, ["status", "--porcelain"]).isEmpty)
        #expect(try ws.fastForwardMain(to: tip) == .notFastForward)
        #expect(throws: (any Error).self) { try ws.updateRef("refs/heads/not-allowed", to: c) }
        try ws.updateRef("refs/brahma/pre-merge/7", to: tip)
        #expect(try ws.revParse("refs/brahma/pre-merge/7") == tip)
    }

    /// I4: if the root cannot follow `main` after it moved, the queue never falls back to updating only the index (which would
    /// make the old files look like the owner's edits): the result says so, and the queue records the landing and holds.
    @Test func rootThatCannotFollowMainHoldsTheQueue() async throws {
        let m = try MergeFixture()
        let i = try await m.approved()
        let head = try #require(try m.fresh(i).verifiedCommit)
        let lock = m.root.appending(path: ".git/index.lock")
        // A lock on the index that appears right after `main` moved: the ref is moved, the two-tree update cannot run.
        m.store.mergeRefProbe.set { ref in if ref == "follow" { try? "".write(to: lock, atomically: true, encoding: .utf8) } }
        defer { m.store.mergeRefProbe.set(nil) }
        let outcome = try #require(try await batch(queue(m), m))
        let r = try request(m, i)
        #expect(outcome.merged == [r.id] && outcome.mainCommit == head)
        let hold = try #require(try m.store.company(id: m.company.id)?.mergeHold)
        #expect(hold.contains("did not follow main") && outcome.held == hold)
        #expect(try m.store.allNotices().contains { $0.title.contains("held") })
        #expect(try main(m) == head)
        // The root still holds the old tree, and the index was not rewritten to hide that.
        try FileManager.default.removeItem(at: lock)
        #expect(!FileManager.default.fileExists(atPath: m.root.appending(path: "src/work.txt").path))
        #expect(try git(m, ["status", "--porcelain"]).contains("src/work.txt"))
        // Held: the next batch does not run, so nothing can commit or revert anything.
        let again = try await batch(queue(m), m)
        #expect(again == nil)
        #expect(try main(m) == head)
    }

    @Test func branchInfoReadsRepo() async throws {
        let m = try MergeFixture()
        let (i, j) = try await twoApproved(m, first: ["src/a.txt": text("a\nb\n")], second: ["src/b.txt": text("c\n")])
        let info = try BranchInspector.info(git: m.ws, key: j.key)
        #expect(info.branch == "item/\(j.key)")
        #expect(info.ahead == 1 && info.behind == 0)
        #expect(info.diff == DiffStat(files: 1, insertions: 1, deletions: 0))
        #expect(info.head == (try m.head(j)))
        #expect(info.worktreePath == m.ws.worktreePath(key: j.key).path)
        try await batch(queue(m), m)                                       // the first lands: j is now behind main
        let behind = try BranchInspector.info(git: m.ws, key: j.key)
        #expect(behind.ahead == 1 && behind.behind == 1)
        let gone = try BranchInspector.info(git: m.ws, key: i.key)          // landed: no branch, no worktree
        #expect(gone.head == nil && gone.worktreePath == nil)
        #expect(DiffStat.parse(shortstat: " 3 files changed, 10 insertions(+), 2 deletions(-)") == DiffStat(files: 3, insertions: 10, deletions: 2))
        #expect(DiffStat.parse(shortstat: " 1 file changed, 1 deletion(-)") == DiffStat(files: 1, insertions: 0, deletions: 1))
        #expect(DiffStat.parse(shortstat: "") == .zero)
    }
    // MARK: Task 2 pre-work (Task 1b review findings)

    /// A `read-tree` that throws after `main` moved is not a failed landing: main moved, so the request is recorded as merged,
    /// the queue is held and the owner told (`.mainMovedRootBehind`), never put back in `queued`.
    @Test func followThrowingAfterMainMovedHoldsAndRecords() async throws {
        let m = try MergeFixture()
        let i = try await m.approved()
        let head = try #require(try m.fresh(i).verifiedCommit)
        m.store.mergeRefProbe.failOn(["follow"])
        defer { m.store.mergeRefProbe.failOn([]) }
        let outcome = try #require(try await batch(queue(m), m))
        let r = try request(m, i)
        #expect(outcome.merged == [r.id] && outcome.requeued.isEmpty && outcome.failed.isEmpty)
        #expect(outcome.held?.contains("did not follow main") == true)
        #expect(r.status == .merged && r.requeues == 0)
        #expect(try main(m) == head)
        #expect(try m.store.company(id: m.company.id)?.mergeHold != nil)
        #expect(try m.store.allNotices().contains { $0.title.contains("Merges are held") })
    }

    /// A database read error while the sandbox route looks up a principal is not a missing row: the run is sandboxed.
    @Test func lookupErrorsForceTheSandbox() async throws {
        let m = try MergeFixture()
        let i = try await m.approved()
        try m.store.updateSandbox(companyId: m.company.id, SandboxPatch(profile: .full), userHome: try tempDir())
        try m.store.updateSandbox(companyId: m.company.id, SandboxPatch(roleProfiles: ["engineer": .full]), userHome: try tempDir())
        let route = Orchestrator.checkRoute(store: m.store)
        let company = try #require(try m.store.company(id: m.company.id))
        func place(batch: String? = nil) async throws -> String {
            let runId = UUID().uuidString
            let dir = try EngineExport.export(store: m.store, company: company, runId: runId, commit: try main(m))
            let run = MergeRun(id: runId, companyId: company.id, batchId: batch, kind: .item, itemId: i.id, status: .running)
            try await m.store.writer.write { try run.insert($0) }
            return dir.path
        }
        func sandboxed(_ r: CheckRoute) -> Bool { if case .sandboxed = r { return true } else { return false } }
        #expect(!sandboxed(route(try await place())), "control: the holder and the author are Full")
        // The item row cannot be read (its status is not a status): the author is unknown, not absent.
        try m.exec("UPDATE workItem SET status = 'garbage' WHERE id = ?", [i.id])
        #expect(sandboxed(route(try await place())))
        try m.exec("UPDATE workItem SET status = 'inReview' WHERE id = ?", [i.id])
        #expect(!sandboxed(route(try await place())), "control again")
        // The lease row cannot be read.
        try m.exec("UPDATE workLease SET acquiredAt = 'garbage' WHERE itemId = ?", [i.id])
        #expect(sandboxed(route(try await place())))
        try m.exec("UPDATE workLease SET acquiredAt = ? WHERE itemId = ?", [m.now, i.id])
        #expect(!sandboxed(route(try await place())), "control again")
        // The batch's requests cannot be read.
        let other = try m.item("Other")
        var b = MergeRequest(companyId: m.company.id, itemId: other.id, number: 77, headCommit: try main(m), enqueuedAt: m.now)
        b.batchId = "batch-x"
        let rb = b
        try await m.store.writer.write { try rb.insert($0) }
        try m.exec("UPDATE workItem SET ownerId = ? WHERE id = ?", [m.eng.id, other.id])
        #expect(!sandboxed(route(try await place(batch: "batch-x"))), "control: the other item's author is Full too")
        try m.exec("ALTER TABLE mergeRequest RENAME COLUMN batchId TO batchIdGone")
        #expect(sandboxed(route(try await place(batch: "batch-x"))))
    }

    /// If the landing could not be recorded and the hold could not be written, the owner is still told, and the queue does not
    /// run that company again (the request stays `landing`; it was landed, so landing it again is never right).
    @Test func doubleFaultAfterTheMoveNotifiesAndStops() async throws {
        let m = try MergeFixture()
        let (i, j) = try await twoApproved(m, first: ["src/a.txt": text("a")], second: ["src/b.txt": text("b")])
        let head = try #require(try m.fresh(i).verifiedCommit)
        try m.exec("CREATE TRIGGER no_record BEFORE UPDATE OF status ON mergeRequest WHEN NEW.status = 'merged' BEGIN SELECT RAISE(ABORT, 'no record'); END")
        try m.exec("CREATE TRIGGER no_hold BEFORE UPDATE OF mergeHold ON company BEGIN SELECT RAISE(ABORT, 'no hold'); END")
        let q = queue(m)
        let outcome = try #require(try await batch(q, m))
        let r = try request(m, i)
        #expect(outcome.failed == [r.id] && outcome.merged.isEmpty && outcome.requeued.isEmpty)
        #expect(r.status == .landing)
        #expect(try main(m) == head)
        #expect(try m.store.allNotices().contains { $0.title.contains("Merges are held") })
        // Nothing else lands behind it in this process.
        #expect(try await batch(q, m) == nil)
        #expect(try main(m) == head)
        #expect(try request(m, j).status == .queued)
    }

    /// The owner-stop read before a quarantine fails closed: a read error is not "not stopped".
    @Test func stopReadErrorDoesNotQuarantine() async throws {
        let m = try MergeFixture()
        let i = try await m.approved()
        try m.write("notes/owner.txt", "uncommitted", in: m.root)
        try m.exec("DROP TABLE engineStop")
        let before = try main(m)
        try await batch(queue(m), m)
        #expect(try main(m) == before)
        #expect(FileManager.default.fileExists(atPath: m.root.appending(path: "notes/owner.txt").path), "the root was not cleaned")
        #expect(try git(m, ["for-each-ref", "refs/brahma/quarantine/"]).isEmpty)
        #expect(try request(m, i).status == .queued)
    }

}

/// Entries a check hook records (the hook runs on the runner's task).
final class Seen: @unchecked Sendable {
    struct Entry: Sendable {
        var dir: URL; var hadGit: Bool; var existed: Bool; var agent: String?; var dev: String?; var command: String
    }
    private let lock = NSLock()
    private var all: [Entry] = []
    var entries: [Entry] { lock.withLock { all } }
    func add(_ e: Entry) { lock.withLock { all.append(e) } }
}

/// Tries to take the company's `GitLock` from inside the completion hook (it runs in `finishMerge`'s transaction).
final class LockProbe: WorkItemObserver, @unchecked Sendable {
    private let lock = NSLock()
    private var _results: [String] = []
    var attempt: (@Sendable () -> String)?
    var results: [String] { lock.withLock { _results } }
    func itemCompleted(_ item: WorkItem, db: Database) throws {
        let r = attempt?() ?? "no probe"
        lock.withLock { _results.append(r) }
    }
}
