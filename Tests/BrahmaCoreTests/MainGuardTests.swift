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

    /// B6: no record is fail-closed. The guard adopts nothing by itself: the owner is alerted once (not once per tick) and
    /// accepts with `brahma merge adopt-main`; the engine's only automatic record is the one it writes when it creates the company.
    @Test func noRecordAlertsOnceAndWaitsForTheOwner() throws {
        let m = try MergeFixture()
        let created = try main(m)
        #expect(try recorded(m) == created, "the company's creation recorded main")
        try m.exec("UPDATE company SET mainCommit = NULL WHERE id = ?", [m.company.id])
        let moved = try foreignCommit(m, file: "unrecorded.txt", message: "nobody recorded this")
        #expect(try check(m) == .skipped)
        #expect(try recorded(m) == nil, "nothing is adopted")
        #expect(try main(m) == moved, "nothing is restored either: there is no record to restore to")
        #expect(try m.ws.head(of: "refs/brahma/foreign/\(stamp(m.now))-1") == nil)
        let alerts = try openAlerts(m, reason: Store.mainAlertReason(m.company.id))
        #expect(alerts.count == 1)
        #expect(alerts.first?.summary.contains("brahma merge adopt-main Acme") == true, "\(alerts)")
        func told() throws -> Int { try m.activity(.error).filter { $0.text.contains("brahma merge adopt-main Acme") }.count }
        #expect(try told() == 1)
        // The next ticks say nothing new.
        #expect(try check(m, now: m.now.addingTimeInterval(60)) == .skipped)
        #expect(try check(m, now: m.now.addingTimeInterval(120)) == .skipped)
        #expect(try openAlerts(m, reason: Store.mainAlertReason(m.company.id)).count == 1)
        #expect(try told() == 1)
        #expect(try recorded(m) == nil)
        // The owner accepts: main as it stands then is the record, the alert is closed, the guard is content.
        #expect(try m.store.adoptMain(companyId: m.company.id, by: .owner, now: m.now) == moved)
        #expect(try recorded(m) == moved)
        #expect(try openAlerts(m, reason: Store.mainAlertReason(m.company.id)).isEmpty)
        #expect(try mergeActivity(m).contains("main adopted at \(moved.prefix(7)) by the owner"))
        #expect(try check(m) == .ok)
    }

    /// B6: a `main` that is a symbolic ref, or that names no commit, is never adopted and never repaired by the guard: 3a's one
    /// "main changed outside Brahma" alert, nothing moves, the record stays.
    @Test func symbolicOrUnresolvableMainRefusesAdoption() throws {
        let m = try MergeFixture()
        let before = try main(m)
        let f = fixture(m)
        try f.git(["branch", "--quiet", "x", before])
        try f.git(["symbolic-ref", "refs/heads/main", "refs/heads/x"])
        #expect(try m.ws.mainIsSymbolic())
        #expect(throws: WorkError.self) { try m.store.adoptMain(companyId: m.company.id, by: .owner, now: m.now) }
        #expect(try recorded(m) == before)
        #expect(try check(m) == .skipped)
        #expect(try check(m, now: m.now.addingTimeInterval(60)) == .skipped)
        #expect(try m.ws.mainIsSymbolic(), "the guard does not rewrite a symbolic main")
        #expect(try f.git(["symbolic-ref", "refs/heads/main"]) == "refs/heads/x")
        #expect(try recorded(m) == before)
        #expect(try openAlerts(m, reason: Store.mainAlertReason(m.company.id)).count == 1, "3a's alert, once")
        #expect(try f.git(["for-each-ref", "refs/brahma/foreign/"]).isEmpty, "nothing saved, nothing moved")
        // A ref that names no commit: nothing to adopt, nothing to restore to; the owner is told.
        try f.git(["symbolic-ref", "--delete", "refs/heads/main"])
        try m.exec("UPDATE company SET mainCommit = NULL WHERE id = ?", [m.company.id])
        #expect(throws: WorkError.self) { try m.store.adoptMain(companyId: m.company.id, by: .owner, now: m.now) }
        #expect(try recorded(m) == nil)
        #expect(try check(m) == .skipped)
        #expect(try recorded(m) == nil)
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

    /// Round 2: `brahma main accept` (3a's `acceptMainCommit`) and `adopt-main` share one guard: a symbolic `main`, a `main` that
    /// names no commit and an open merge batch refuse both; the plain accept records the head as an adoption by the owner.
    @Test func mainAcceptSharesTheAdoptGuard() throws {
        let m = try MergeFixture()
        let before = try main(m)
        let f = fixture(m)
        try f.git(["branch", "--quiet", "x", before])
        try f.git(["symbolic-ref", "refs/heads/main", "refs/heads/x"])
        #expect(throws: WorkError.self) { try m.store.acceptMainCommit(companyId: m.company.id) }
        #expect(try recorded(m) == before)
        try f.git(["symbolic-ref", "--delete", "refs/heads/main"])
        try f.git(["update-ref", "refs/heads/main", before])
        #expect(!(try m.ws.mainIsSymbolic()))
        let batch = MergeBatch(companyId: m.company.id, number: 1, step: .checked, requestIds: ["r"], startedAt: m.now)
        try m.store.writer.write { db in try batch.insert(db) }
        let owners = try foreignCommit(m, file: "owner.txt", message: "the owner's commit")
        #expect(throws: WorkError.self) { try m.store.acceptMainCommit(companyId: m.company.id) }
        let refusal = (try? m.store.acceptMainCommit(companyId: m.company.id, ref: "refs/brahma/quarantine/20260101-000000")).map { _ in "" }
        #expect(refusal == nil, "the quarantine path refuses too")
        do { _ = try m.store.acceptMainCommit(companyId: m.company.id, ref: "refs/brahma/quarantine/20260101-000000") }
        catch let e as WorkError { #expect(e.message.contains("merge batch"), "\(e.message)") } catch { Issue.record("\(error)") }
        #expect(try recorded(m) == before)
        try m.exec("UPDATE mergeBatch SET step = 'done' WHERE id = ?", [batch.id])
        let accepted = try m.store.acceptMainCommit(companyId: m.company.id)
        #expect(accepted.head == owners && accepted.ask == nil && !accepted.alreadyMerged)
        #expect(try recorded(m) == owners)
        #expect(try mergeActivity(m).contains("main adopted at \(owners.prefix(7)) by the owner"))
        #expect(try check(m) == .ok)
    }

    /// The guard's git-lock wait is pinned: another engine's batch may hold the company's GitLock for a whole landing, and the
    /// guard is retried every tick, so it waits 5 s (not GitLock's 30 s) before giving the blocking slot back.
    @Test func lockWaitIsPinned() {
        #expect(MainGuard.lockWait == .seconds(5))
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
        #expect(notice.body.contains("(\(ref) is \(foreign))"), "the notice names the saved commit: \(notice.body)")
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
        let beta = try m.world.company("Beta")
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
        // B4: the other company hears nothing of it (no ask, no activity, no DM).
        let betaAsks = try m.store.writer.read { db in try Ask.filter(Column("companyId") == beta.id && Column("kind") == AskKind.engineAlert).fetchCount(db) }
        #expect(betaAsks == 0)
        #expect(try m.store.events(afterId: 0, limit: 500).filter { $0.companyId == beta.id }.allSatisfy { !$0.text.contains("main checkout is on") })
        let betaDMs = try m.store.writer.read { db in
            try Message.filter(Column("companyId") == beta.id && Column("senderId") == "system").fetchAll(db).filter { $0.text.contains("main checkout is on") }.count
        }
        #expect(betaDMs == 0)
    }

    /// A detached root: still ref-only, and the alert says so.
    @Test func rootDetachedRestoredByRefOnly() throws {
        let m = try MergeFixture()
        let before = try main(m)
        let f = fixture(m)
        try f.git(["checkout", "--quiet", "--detach"])
        try f.write("wip.txt", "uncommitted while detached")
        let foreign = try f.git(["commit-tree", "\(before)^{tree}", "-p", before, "-m", "made elsewhere"])
        try f.git(["update-ref", "refs/heads/main", foreign])
        guard case .restored(let ref, let to) = try check(m) else { Issue.record("expected a restore"); return }
        #expect(to == before); #expect(try main(m) == before)
        #expect(try m.ws.head(of: ref) == foreign)
        #expect(try f.git(["symbolic-ref", "--quiet", "HEAD"], allowFailure: true).isEmpty, "still detached")
        #expect(try f.git(["rev-parse", "HEAD"]) == before)
        #expect(try String(contentsOf: m.root.appending(path: "wip.txt"), encoding: .utf8) == "uncommitted while detached")
        let alerts = try openAlerts(m, reason: Store.mainHeadAlertReason(m.company.id))
        #expect(alerts.first?.summary.contains("main checkout is on a detached HEAD; switch it back to main") == true, "\(alerts)")
    }

    /// M4: `pendingMainCommit` is written only by the engine's own moves (the queue's journaled landing, the owner's accept) and
    /// cleared on every failure path; a `main` standing exactly there is the engine's crash record, and 3a's `checkMain` records it.
    @Test func pendingHeadFromTheEnginesOwnMoveIsRecorded() throws {
        let m = try MergeFixture()
        let before = try main(m)
        let next = try foreignCommit(m, file: "landing.txt", message: "what the engine was landing")
        try m.exec("UPDATE company SET pendingMainCommit = ? WHERE id = ?", [next, m.company.id])
        #expect(try check(m) == .ok)
        #expect(try recorded(m) == next)
        #expect(try m.store.company(id: m.company.id)?.pendingMainCommit == nil)
        #expect(try main(m) == next)
        #expect(try f(m).git(["for-each-ref", "refs/brahma/foreign/"]).isEmpty)
        _ = before
    }

    func f(_ m: MergeFixture) -> GitFixture { fixture(m) }

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

    /// C1: while a restore the engine has not taken up names the company (an unconsumed `restoreEvent` and its marker), the
    /// restore step decides first; the guard looks at `main` on a later tick.
    @Test func guardSkipsWhileARestoreIsPending() async throws {
        let m = try MergeFixture()
        let before = try main(m)
        let foreign = try foreignCommit(m)
        let nonce = try await m.store.writer.write { db in try BackupService.recordRestoreEvent(db, snapshot: "snap.sqlite", now: m.now) }
        let marker = BackupService.restoreMarker(paths: m.world.paths)
        try BrahmaPaths.ensurePrivateDirectory(marker.deletingLastPathComponent())
        try RestoreMarker.write(nonce: nonce, to: marker)
        #expect(try check(m) == .skipped)
        #expect(try main(m) == foreign, "nothing moved")
        #expect(try f(m).git(["for-each-ref", "refs/brahma/foreign/"]).isEmpty)
        // The restore is taken up (the event consumed): the guard acts.
        try m.exec("UPDATE restoreEvent SET consumedAt = ? WHERE nonce = ?", [m.now, nonce])
        guard case .restored(_, let to) = try check(m) else { Issue.record("expected a restore"); return }
        #expect(to == before); #expect(try main(m) == before)
        // An unconsumed event whose marker is gone can never be taken up: it does not hold the guard.
        let again = try foreignCommit(m, file: "again.txt", message: "again")
        _ = try await m.store.writer.write { db in try BackupService.recordRestoreEvent(db, snapshot: "snap2.sqlite", now: m.now) }
        #expect(try check(m, now: m.now.addingTimeInterval(1)) == .skipped)
        #expect(try main(m) == again)
        try FileManager.default.removeItem(at: marker)
        guard case .restored = try check(m, now: m.now.addingTimeInterval(1)) else { Issue.record("expected a restore"); return }
        #expect(try main(m) == before)
    }

    /// I1: an owner's adopt that lands between the guard's read of the record and its restore is not undone: the restore
    /// re-reads the record under main's lock and stands down.
    @Test func guardDoesNotUndoAnAdoptRacingIt() throws {
        let m = try MergeFixture()
        let before = try main(m)
        let owners = try foreignCommit(m, file: "owner.txt", message: "the owner's commit")
        let (store, companyId) = (m.store, m.company.id)
        store.mergeRefProbe.set { ref in
            guard ref == "refs/brahma/foreign" else { return }
            _ = try? store.adoptMain(companyId: companyId, by: .owner)
        }
        defer { store.mergeRefProbe.set(nil) }
        #expect(try check(m) == .skipped)
        #expect(try main(m) == owners, "the owner's adopt stands")
        #expect(try recorded(m) == owners)
        #expect(try f(m).git(["for-each-ref", "refs/brahma/foreign/"]).isEmpty, "nothing was saved as foreign")
        #expect(FileManager.default.fileExists(atPath: m.root.appending(path: "owner.txt").path))
        store.mergeRefProbe.set(nil)
        #expect(try check(m) == .ok)
        _ = before
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

    /// The engine's restore step: for a company whose `main` is exactly what the restored database recorded, the hook re-affirms
    /// the record (activity, a pending head cleared, 3a's alert closed). A head the restored database did not record is left
    /// to the main guard (B6: after a restore the record is what the restored database says).
    @Test func restoreHookReadopts() async throws {
        let m = try MergeFixture()
        let head = try main(m)
        let hooks = RestoreHooks()
        _ = Orchestrator(store: m.store, runner: FakeTurnRunner(), paths: m.world.paths, mcpExecutable: "/usr/local/bin/brahma",
                         clock: TestClock().function, vault: MemoryVault(), restoreHooks: hooks)
        let stale = String(repeating: "a", count: 40)
        try m.exec("UPDATE company SET pendingMainCommit = ? WHERE id = ?", [stale, m.company.id])
        try EngineAlerts.raise(store: m.store, text: "older alert", now: m.now, reason: Store.mainAlertReason(m.company.id), companyId: m.company.id)
        let event = RestoreEvent(companyId: m.company.id, companyName: m.company.name, workspace: m.root, mainHead: head, snapshotName: "snap")
        for hook in hooks.afterRestore { try await hook(event) }
        #expect(try recorded(m) == head)
        #expect(try m.store.company(id: m.company.id)?.pendingMainCommit == nil)
        #expect(try openAlerts(m, reason: Store.mainAlertReason(m.company.id)).isEmpty)
        #expect(try mergeActivity(m).contains("main adopted at \(head.prefix(7)) by the engine"))
        #expect(try check(m) == .ok)
        // The restored database recorded something else: the hook adopts nothing (the guard restores on its tick).
        try m.exec("UPDATE company SET mainCommit = ? WHERE id = ?", [stale, m.company.id])
        for hook in hooks.afterRestore { try await hook(event) }
        #expect(try recorded(m) == stale)
        #expect(try mergeActivity(m).filter { $0 == "main adopted at \(head.prefix(7)) by the engine" }.count == 1)
        // I2: the live main moved after the restore step read it: the hook never moves main back (that is the guard's, with a
        // saved foreign ref); it refuses, and the record stays.
        try m.exec("UPDATE company SET mainCommit = ? WHERE id = ?", [head, m.company.id])
        let moved = try foreignCommit(m, file: "after-restore.txt", message: "moved after the restore read main")
        var refused = false
        for hook in hooks.afterRestore { do { try await hook(event) } catch is WorkError { refused = true } }
        #expect(refused)
        #expect(try main(m) == moved, "the hook moved nothing")
        #expect(try recorded(m) == head)
        #expect(try f(m).git(["for-each-ref", "refs/brahma/foreign/"]).isEmpty)
        #expect(FileManager.default.fileExists(atPath: m.root.appending(path: "after-restore.txt").path))
        // Nor does the engine ever swap by itself, even when asked by commit.
        #expect(throws: WorkError.self) { try m.store.adoptMain(companyId: m.company.id, by: .system, commit: head) }
        #expect(try main(m) == moved)
    }

    /// I4 (B6): the engine's one automatic record, at the company's creation, is refused for a symbolic `main`: the record stays
    /// nil and the guard's first tick asks the owner.
    @Test func companyCreationRefusesASymbolicMain() throws {
        let m = try MergeFixture()
        let dir = m.world.paths.workspaces.appending(path: "beta", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = GitFixture(existing: dir)
        try f.ws.ensureRepo()
        let head = try f.git(["rev-parse", "refs/heads/main"])
        try f.git(["branch", "--quiet", "x", head])
        try f.git(["symbolic-ref", "refs/heads/main", "refs/heads/x"])
        let beta = try m.store.createCompany(name: "Beta", goal: "g", workspacesRoot: m.world.paths.workspaces)
        #expect(beta.workspacePath == dir.path)
        #expect(beta.mainCommit == nil)
        #expect(try m.store.company(id: beta.id)?.mainCommit == nil)
        let result = try MainGuard.check(company: beta, store: m.store, git: m.store.gitWorkspace(root: dir, companyId: beta.id),
                                         paths: m.world.paths, now: m.now)
        #expect(result == .skipped)
        #expect(try m.store.company(id: beta.id)?.mainCommit == nil)
        // A plain main is recorded, as before.
        let gamma = try m.world.company("Gamma")
        #expect(gamma.mainCommit != nil)
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
