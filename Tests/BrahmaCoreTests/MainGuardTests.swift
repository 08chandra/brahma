import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// The main guard (Plan 4a Task 3): only the merge queue moves `main`. Every tick compares `refs/heads/main` with the engine's
/// record (`company.mainCommit`); a head that differs is saved under `refs/brahma/foreign/<stamp>-<n>` and `main` goes back to
/// the record. The guard never reads authors or subjects: a commit is accepted only when it is the recorded one.
@Suite(.scratch, .serialized) struct MainGuardTests {
    // MARK: Helpers

    static let foreignSubject = "Brahma: unattributed changes on main"

    func check(_ m: MergeFixture, now: Date? = nil) throws -> MainGuardResult {
        let company = try #require(try m.store.company(id: m.company.id))
        return try MainGuard.check(company: company, store: m.store, git: m.store.gitWorkspace(root: m.root, companyId: company.id),
                                   paths: m.world.paths, now: now ?? m.now)
    }

    func main(_ m: MergeFixture) throws -> String { try #require(try m.ws.head(of: GitWorkspace.mainRef)) }
    func recorded(_ m: MergeFixture) throws -> String? { try m.store.company(id: m.company.id)?.mainCommit }
    func fixture(_ m: MergeFixture) -> GitFixture { GitFixture(existing: m.root) }

    /// A plain commit at the workspace root, as an agent (or the owner) working there would make it; the new head of `main`.
    @discardableResult
    func foreignCommit(_ m: MergeFixture, file: String = "foreign.txt", text: String = "nobody reviewed this",
                       message: String = "a change outside the queue", config: [String] = []) throws -> String {
        let f = fixture(m)
        try f.write(file, text)
        try f.git(["add", "-A", "--", file])
        try f.git(config + ["commit", "--quiet", "-m", message])
        return try f.git(["rev-parse", "refs/heads/main"])
    }

    func stamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        return f.string(from: date)
    }

    func mergeActivity(_ m: MergeFixture) throws -> [String] { try m.activity(.merge).map(\.text) }

    func openAlerts(_ m: MergeFixture, reason: String) throws -> [Ask] {
        try m.store.writer.read { db in
            try Ask.filter(Column("kind") == AskKind.engineAlert && Column("status") == AskStatus.pendingOwner.rawValue
                           && Column("subjectId") == Store.engineAlertKey(reason) && Column("companyId") == m.company.id).fetchAll(db)
        }
    }

    func restoredText(_ to: String, ref: String) -> String {
        "main was changed outside the merge queue; restored to \(to.prefix(7)), the other tip is saved as \(ref)"
    }

    // MARK: Adoption

    @Test func firstTickAdoptsMain() throws {
        let m = try MergeFixture()
        let head = try main(m)
        try m.exec("UPDATE company SET mainCommit = NULL WHERE id = ?", [m.company.id])
        #expect(try recorded(m) == nil)
        #expect(try check(m) == .adopted(head))
        #expect(try recorded(m) == head)
        #expect(try main(m) == head)
        #expect(try mergeActivity(m).contains("main adopted at \(head.prefix(7)) by the engine"))
        // From then on the head is the record: nothing to do.
        #expect(try check(m) == .ok)
    }

    @Test func adoptMainAcceptsOwnerCommit() throws {
        let m = try MergeFixture()
        let before = try main(m)
        let owners = try foreignCommit(m, file: "owner.txt", message: "the owner's hand-made commit")
        #expect(owners != before)
        // An agent never adopts.
        #expect(throws: WorkError.forbidden("only the owner can adopt main")) {
            try m.store.adoptMain(companyId: m.company.id, by: .agent(m.eng.id))
        }
        #expect(try recorded(m) == before)
        // The owner does: the head is the record now, and the guard has nothing to restore.
        #expect(try m.store.adoptMain(companyId: m.company.id, by: .owner, now: m.now) == owners)
        #expect(try recorded(m) == owners)
        #expect(try mergeActivity(m).contains("main adopted at \(owners.prefix(7)) by the owner"))
        #expect(try check(m) == .ok)
        #expect(try main(m) == owners)
        // While a batch is open the record belongs to the queue: adoption is refused.
        try m.store.writer.write { db in
            try MergeBatch(companyId: m.company.id, number: 1, step: .claimed, requestIds: ["r"], startedAt: m.now).insert(db)
        }
        #expect(throws: WorkError.self) { try m.store.adoptMain(companyId: m.company.id, by: .owner) }
        try m.exec("UPDATE mergeBatch SET step = 'done' WHERE companyId = ?", [m.company.id])
        // A saved foreign tip can be adopted by name: main is moved to it, the checkout follows, the record is written.
        let later = try foreignCommit(m, file: "later.txt", message: "another hand-made commit")
        guard case .restored(let ref, let to) = try check(m) else { Issue.record("expected a restore"); return }
        #expect(to == owners); #expect(try main(m) == owners)
        #expect(!FileManager.default.fileExists(atPath: m.root.appending(path: "later.txt").path))
        #expect(try m.store.adoptMain(companyId: m.company.id, by: .owner, commit: try #require(try m.ws.head(of: ref)), now: m.now) == later)
        #expect(try main(m) == later); #expect(try recorded(m) == later)
        #expect(FileManager.default.fileExists(atPath: m.root.appending(path: "later.txt").path))
        #expect(try check(m) == .ok)
    }

    // MARK: Restores

    @Test func rewriteRestoredAndReported() throws {
        let m = try MergeFixture()
        let before = try main(m)
        let foreign = try foreignCommit(m)
        #expect(try recorded(m) == before)
        let ref = "refs/brahma/foreign/\(stamp(m.now))-1"
        #expect(try check(m) == .restored(foreignRef: ref, to: before))
        #expect(try main(m) == before)
        #expect(try recorded(m) == before)
        #expect(try m.ws.head(of: ref) == foreign, "the other tip is saved")
        #expect(!FileManager.default.fileExists(atPath: m.root.appending(path: "foreign.txt").path), "the checkout follows main")
        #expect(try fixture(m).git(["status", "--porcelain"]).isEmpty)
        let text = restoredText(before, ref: ref)
        #expect(try mergeActivity(m).contains(text))
        let notice = try #require(try m.store.allNotices().last { $0.title == "main restored" })
        #expect(notice.body.contains(text))
        #expect(notice.body.contains("Run brahma merge adopt-main Acme if that change was yours."))
        // 3a's "main changed outside Brahma" alert, if any, is gone with the restore; nothing else is open.
        #expect(try openAlerts(m, reason: Store.mainAlertReason(m.company.id)).isEmpty)
        #expect(try openAlerts(m, reason: Store.mainHeadAlertReason(m.company.id)).isEmpty)
        #expect(try check(m) == .ok)
        // A rewrite (the head amended in place) is a move too.
        try fixture(m).write("amended.txt", "slipped in")
        try fixture(m).git(["add", "-A", "--", "amended.txt"])
        try fixture(m).git(["commit", "--quiet", "--amend", "--no-edit"])
        let amended = try main(m)
        #expect(amended != before)
        guard case .restored(_, let to) = try check(m, now: m.now.addingTimeInterval(1)) else { Issue.record("expected a restore"); return }
        #expect(to == before); #expect(try main(m) == before)
    }

    @Test func uncommittedForeignEditsPreserved() throws {
        let m = try MergeFixture()
        let before = try main(m)
        let foreign = try foreignCommit(m, file: "src/f.txt", text: "committed outside")
        let f = fixture(m)
        try f.write("src/f.txt", "edited after the commit")
        try f.write("src/new.txt", "an uncommitted file")
        guard case .restored(let ref, let to) = try check(m) else { Issue.record("expected a restore"); return }
        #expect(to == before); #expect(try main(m) == before)
        let saved = try #require(try m.ws.head(of: ref))
        #expect(saved != foreign, "the edits are committed on top of the foreign tip")
        #expect(try f.git(["rev-parse", "\(saved)^"]) == foreign)
        #expect(try f.git(["show", "\(saved):src/f.txt"]) == "edited after the commit")
        #expect(try f.git(["show", "\(saved):src/new.txt"]) == "an uncommitted file")
        // The checkout is exactly the record again; nothing of the edits is left behind.
        #expect(!FileManager.default.fileExists(atPath: m.root.appending(path: "src/new.txt").path))
        #expect(!FileManager.default.fileExists(atPath: m.root.appending(path: "src/f.txt").path))
        #expect(try f.git(["status", "--porcelain"]).isEmpty)
        #expect(try check(m) == .ok)
    }

    /// Uncommitted edits at the root with `main` where the record says: not a move.
    @Test func dirtyRootOnRecordedMainIsOk() throws {
        let m = try MergeFixture()
        let before = try main(m)
        try fixture(m).write("wip.txt", "work in progress")
        #expect(try check(m) == .ok)
        #expect(try main(m) == before)
        #expect(try String(contentsOf: m.root.appending(path: "wip.txt"), encoding: .utf8) == "work in progress")
    }

    /// The queue's own journaled landing moves `main` and records it: never foreign. A landing whose compare-and-swap moved
    /// `main` before the record was written leaves its batch open: the guard skips, and recovery records it.
    @Test func queueLandedCommitIsNotForeign() async throws {
        let m = try MergeFixture()
        let i = try await m.approved()
        let q = MergeQueue(store: m.store, paths: m.world.paths, checks: m.world.checks, knownValues: { _ in [] }, clock: { m.now })
        _ = await q.runNextBatch(company: try #require(try m.store.company(id: m.company.id)))
        let landed = try main(m)
        #expect(try m.fresh(i).mergedCommit == landed)
        #expect(try recorded(m) == landed)
        #expect(try check(m) == .ok)
        #expect(try main(m) == landed)
        // A second landing crashes right after main moved: the batch is still at `landing`.
        _ = try await m.approved("Second", by: m.eng2, file: "src/second.txt")
        m.store.journalProbe.set { $0 == "moved" }
        _ = await q.runNextBatch(company: try #require(try m.store.company(id: m.company.id)))
        m.store.journalProbe.set(nil)
        let open = try #require(try m.store.openMergeBatches(companyId: m.company.id).first)
        let landCommit = try #require(open.landCommit)
        #expect(try main(m) == landCommit); #expect(try recorded(m) != landCommit)
        #expect(try check(m) == .skipped, "an open batch owns main")
        #expect(try main(m) == landCommit, "nothing was restored")
        #expect(try m.ws.head(of: "refs/brahma/foreign/\(stamp(m.now))-1") == nil)
        _ = await q.recover(company: try #require(try m.store.company(id: m.company.id)))
        #expect(try recorded(m) == landCommit)
        #expect(try check(m) == .ok)
    }

    /// The engine's author and the old "unattributed changes" subject on a commit nobody journaled: foreign all the same.
    @Test func forgedUnattributedCommitIsForeign() throws {
        let m = try MergeFixture()
        let before = try main(m)
        let forged = try foreignCommit(m, file: "forged.txt", message: Self.foreignSubject,
                                       config: ["-c", "user.name=Brahma", "-c", "user.email=engine@brahma.local"])
        #expect(try fixture(m).git(["log", "-1", "--format=%an <%ae> %s", forged]) == "Brahma <engine@brahma.local> \(Self.foreignSubject)")
        let ref = "refs/brahma/foreign/\(stamp(m.now))-1"
        #expect(try check(m) == .restored(foreignRef: ref, to: before))
        #expect(try main(m) == before); #expect(try m.ws.head(of: ref) == forged)
    }

    @Test func rootOffMainRestoredByRefOnly() throws {
        let m = try MergeFixture()
        let before = try main(m)
        let f = fixture(m)
        try f.git(["checkout", "--quiet", "-b", "x"])
        try f.write("on-x.txt", "committed on x")
        try f.git(["add", "-A", "--", "on-x.txt"])
        try f.git(["commit", "--quiet", "-m", "work on x"])
        let x = try f.git(["rev-parse", "refs/heads/x"])
        try f.write("wip.txt", "uncommitted on x")
        // Something moves `main` to x's commit while the checkout sits on x.
        try f.git(["update-ref", "refs/heads/main", x])
        #expect(try main(m) == x)
        let ref = "refs/brahma/foreign/\(stamp(m.now))-1"
        #expect(try check(m) == .restored(foreignRef: ref, to: before))
        #expect(try main(m) == before)
        #expect(try m.ws.head(of: ref) == x)
        // The root was never touched: HEAD, x, its files and the uncommitted edit are as they were.
        #expect(try f.git(["symbolic-ref", "HEAD"]) == "refs/heads/x")
        #expect(try f.git(["rev-parse", "refs/heads/x"]) == x)
        #expect(try String(contentsOf: m.root.appending(path: "on-x.txt"), encoding: .utf8) == "committed on x")
        #expect(try String(contentsOf: m.root.appending(path: "wip.txt"), encoding: .utf8) == "uncommitted on x")
        let alerts = try openAlerts(m, reason: Store.mainHeadAlertReason(m.company.id))
        #expect(alerts.count == 1)
        #expect(alerts.first?.summary.contains("main checkout is on refs/heads/x; switch it back to main") == true, "\(alerts)")
        #expect(try m.activity(.error).contains { $0.text.contains("main checkout is on refs/heads/x; switch it back to main") })
        #expect(try mergeActivity(m).contains(restoredText(before, ref: ref)))
    }

    @Test func foreignRefNamesAreUnique() throws {
        let m = try MergeFixture()
        let before = try main(m)
        let first = try foreignCommit(m, file: "one.txt", message: "one")
        let at = stamp(m.now)
        #expect(try check(m) == .restored(foreignRef: "refs/brahma/foreign/\(at)-1", to: before))
        let second = try foreignCommit(m, file: "two.txt", message: "two")
        #expect(try check(m) == .restored(foreignRef: "refs/brahma/foreign/\(at)-2", to: before))
        #expect(try m.ws.head(of: "refs/brahma/foreign/\(at)-1") == first)
        #expect(try m.ws.head(of: "refs/brahma/foreign/\(at)-2") == second)
        #expect(try main(m) == before)
    }

    // MARK: Gates

    @Test func guardSkipsDuringBatchAndStop() throws {
        let m = try MergeFixture()
        let before = try main(m)
        let foreign = try foreignCommit(m)
        let batch = MergeBatch(companyId: m.company.id, number: 1, step: .rebased, requestIds: ["r"], startedAt: m.now)
        try m.store.writer.write { db in try batch.insert(db) }
        #expect(try check(m) == .skipped)
        #expect(try main(m) == foreign, "nothing moves while a batch is open")
        try m.exec("UPDATE mergeBatch SET step = 'done' WHERE id = ?", [batch.id])
        try m.store.emergencyStop(note: nil, by: "owner", now: m.now)
        #expect(try check(m) == .skipped)
        #expect(try main(m) == foreign, "nothing moves under the owner's stop")
        try m.store.resumeAfterStop(now: m.now)
        guard case .restored(_, let to) = try check(m) else { Issue.record("expected a restore"); return }
        #expect(to == before); #expect(try main(m) == before)
    }

    /// The orchestrator's tick runs the guard for every company (paused ones too), before the merge step.
    @Test func tickRunsTheGuard() async throws {
        let m = try MergeFixture()
        let before = try main(m)
        try m.exec("UPDATE company SET status = 'paused' WHERE id = ?", [m.company.id])
        let foreign = try foreignCommit(m)
        #expect(foreign != before)
        try await m.cycle()
        #expect(try main(m) == before)
        #expect(try m.ws.head(of: "refs/brahma/foreign/\(stamp(m.now))-1") == foreign)
    }

    // MARK: The restore hook

    @Test func restoreHookReadopts() async throws {
        let m = try MergeFixture()
        let head = try main(m)
        let hooks = RestoreHooks()
        _ = Orchestrator(store: m.store, runner: FakeTurnRunner(), paths: m.world.paths, mcpExecutable: "/usr/local/bin/brahma",
                         clock: TestClock().function, vault: MemoryVault(), restoreHooks: hooks)
        // The restored database recorded an older head; git's main is what the engine runs on now.
        let stale = String(repeating: "a", count: 40)
        try m.exec("UPDATE company SET mainCommit = ?, pendingMainCommit = ? WHERE id = ?", [stale, stale, m.company.id])
        let event = RestoreEvent(companyId: m.company.id, companyName: m.company.name, workspace: m.root, mainHead: head, snapshotName: "snap")
        for hook in hooks.afterRestore { try await hook(event) }
        #expect(try recorded(m) == head)
        #expect(try m.store.company(id: m.company.id)?.pendingMainCommit == nil)
        #expect(try mergeActivity(m).contains("main adopted at \(head.prefix(7)) by the engine"))
        #expect(try check(m) == .ok)
    }

    // MARK: Who may write the record

    /// `company.mainCommit` is written only by the engine's own steps (the import, the queue's journaled landing, 3a's accept,
    /// the restore, `adoptMain`); no MCP tool reaches any of them.
    @Test func noToolPathWritesMain() throws {
        let allowed: Set<String> = [
            "Sources/BrahmaCore/Store/Store.swift", "Sources/BrahmaCore/Store/Store+MainGuard.swift",
            "Sources/BrahmaCore/Store/Store+Merge.swift", "Sources/BrahmaCore/Orchestrator+Restore.swift",
        ]
        var writers: [String] = []
        var toolReaches: [String] = []
        for (path, text) in try EngineGitGuardTests.sources(under: "Sources") {
            let code = EngineGitGuardTests.code(text)
            if code.range(of: #"SET\s+mainCommit\s*="#, options: .regularExpression) != nil, !allowed.contains(path) { writers.append(path) }
            if path.hasPrefix("Sources/BrahmaCore/MCP/"),
               code.range(of: #"\b(adoptMain|acceptMainCommit|finalizeMainCommit|recordMainCommit|setPendingMainCommit)\b|mainCommit\s*="#,
                          options: .regularExpression) != nil {
                toolReaches.append(path)
            }
        }
        #expect(writers.isEmpty, "mainCommit written outside the engine's own steps: \(writers)")
        #expect(toolReaches.isEmpty, "a tool path reaches the main record: \(toolReaches)")
        #expect(!CompanyToolNames.all.contains { $0.contains("adopt_main") || $0.contains("adopt-main") })
    }
}
