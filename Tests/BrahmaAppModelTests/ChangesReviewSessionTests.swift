import Testing
import Foundation
@testable import BrahmaCore
@testable import BrahmaAppModel

/// Plan C Task C7c fix round 1: the inline review in progress lives in the CHANGES model (I-1) — it survives live yields, a
/// refused post keeps it, and it is posted against the key and compare it was started on; whether a live yield may scroll the
/// pane back to the current change stop (only after ⌘↓/⌘↑, never once the owner scrolled away or while a review is open); chips
/// only from the model (m-6); an alert another task raised is never replaced (m-5); the worktree nudger's root check (m-2).
@MainActor @Suite(.scratch) struct ChangesReviewSessionTests {
    @Test func reviewDraftSurvivesYields() async throws {
        let cw = try ChangesWorld()
        let (m, _) = try cw.model()
        m.start()
        m.select(cw.key)
        try await eventually { m.diff != nil }
        #expect(m.review == nil && !m.canPostReview)
        let anchor = try cw.anchor(m, path: "src/a.ts", lineText: "three")
        #expect(m.beginReview(anchor))
        m.setReviewText("half typed")
        #expect(m.review?.draft.anchor == anchor && m.review?.key == cw.key && m.review?.compare == .main && m.canPostReview)
        // A live yield (the holder keeps editing) leaves the draft as typed.
        let before = try #require(m.snapshot?.patchHash)
        try cw.write("src/b.ts", "new\n")
        try await eventually { m.snapshot?.patchHash != before }
        #expect(m.review?.draft.text == "half typed" && m.review?.draft.anchor == anchor)
        // A second "+" never replaces a draft with text in it.
        var other = anchor
        other.line = 1
        #expect(!m.beginReview(other) && m.review?.draft.anchor == anchor)
        // Another compare keeps the draft (it posts against the compare it was started on); nothing can be posted until a diff of
        // the selected key is shown again.
        m.setCompare(.head)
        #expect(m.review?.draft.text == "half typed" && m.review?.compare == .main && !m.canPostReview)
        m.setCompare(.main)
        try await eventually { m.diff != nil }
        #expect(m.canPostReview)
        // Selecting the same row keeps it; another item drops it; cancelling drops it.
        m.select(cw.key)
        #expect(m.review != nil)
        m.cancelReview()
        #expect(m.review == nil)
        #expect(m.beginReview(other))
        m.select("ENG-9")
        #expect(m.review == nil, "a draft never follows the owner to another item")
        m.stop()
    }

    @Test func postedReviewKeepsTheDraftOnRefusal() async throws {
        let cw = try ChangesWorld()
        let app = await cw.w.app()
        let changes = try #require(app.changes)
        app.apply(.changes(key: cw.key))
        try await eventually { changes.diff != nil }
        let anchor = try cw.anchor(changes, path: "src/a.ts", lineText: "three")
        #expect(await app.postReview(isRevert: false) == false, "no review in progress posts nothing")
        #expect(changes.beginReview(anchor))
        // An invalid draft: the problem shows on the draft, never in the window's alert.
        #expect(await app.postReview(isRevert: false) == false)
        #expect(changes.review?.error == "Write a comment first" && app.errorMessage == nil)
        // A refusal keeps every typed character and shows the refusal on the draft; the window's alert is left as it was.
        changes.setReviewText("Why three?")
        let minted = app.owner
        app.owner = nil
        #expect(await app.postReview(isRevert: false) == false)
        #expect(changes.review?.draft.text == "Why three?" && changes.review?.error == Store.refUnavailable && changes.review?.posting == false)
        #expect(app.errorMessage == nil)
        #expect(try cw.w.count("diffComment") == 0)
        app.owner = minted
        // Posted: exactly one row, the draft is done.
        #expect(await app.postReview(isRevert: false))
        #expect(try cw.w.count("diffComment") == 1)
        #expect(changes.review == nil && app.errorMessage == nil)
        // A revert request with an empty note is a valid draft.
        #expect(changes.beginReview(anchor))
        #expect(await app.postReview(isRevert: true))
        #expect(try cw.w.count("diffComment") == 2 && changes.review == nil)
        app.selectPreviewTab(nil)
    }

    @Test func alertRestoreNeverClobbersAnotherAlert() {
        // m-5: the refusal we raised is taken back to what was there; an alert another task raised meanwhile stays.
        #expect(AppModel.alertAfterReview(current: "refused", ours: "refused", before: nil) == nil)
        #expect(AppModel.alertAfterReview(current: "refused", ours: "refused", before: "Backup failed") == "Backup failed")
        #expect(AppModel.alertAfterReview(current: "Backup failed", ours: "refused", before: nil) == "Backup failed")
        #expect(AppModel.alertAfterReview(current: nil, ours: "refused", before: "x") == nil)
    }

    @Test func liveYieldsScrollOnlyToAFollowedStop() async throws {
        let cw = try ChangesWorld()
        let (m, _) = try cw.model()
        m.start()
        m.select(cw.key)
        try await eventually { m.diff != nil }
        #expect(!m.followsStop && !m.rescrollsOnYield, "nothing to follow before ⌘↓/⌘↑")
        #expect(m.stopMoves == 0)
        m.nextChange()
        #expect(m.followsStop && m.rescrollsOnYield)
        #expect(m.stopMoves == 1, "every ⌘↓/⌘↑ is an explicit move the pane scrolls to")
        // The owner scrolled away: yields leave the pane where it is until the next ⌘↓/⌘↑.
        m.ownerScrolled()
        #expect(!m.followsStop && !m.rescrollsOnYield)
        m.previousChange()
        #expect(m.followsStop && m.rescrollsOnYield && m.stopMoves == 2)
        // Never while a review is open.
        let anchor = try cw.anchor(m, path: "src/a.ts", lineText: "three")
        #expect(m.beginReview(anchor))
        #expect(m.followsStop && !m.rescrollsOnYield)
        m.cancelReview()
        #expect(m.rescrollsOnYield)
        // Another item starts unfollowed.
        m.select("ENG-9")
        #expect(!m.followsStop)
        m.stop()
    }

    @Test func chipsComeFromTheModel() {
        // m-6: the board's and the comment thread's TAINTED chips are the model's.
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = BoardRows.make([
            BoardRow(key: "ENG-1", title: "T", agent: "eng-1", agentState: "running", files: 1, added: 1, removed: 0, lastEdit: now,
                     checkStatus: nil, reviewer: nil, tainted: true),
            BoardRow(key: "ENG-2", title: "U", agent: "eng-2", agentState: "ready", files: 1, added: 1, removed: 0, lastEdit: now,
                     checkStatus: nil, reviewer: nil, tainted: false),
        ], now: now)
        #expect(rows[0].chips == [RefChip(text: "TAINTED", tone: .warn)])
        #expect(rows[1].chips.isEmpty)
        func comment(tainted: Bool, kind: String = DiffComment.comment) -> DiffComment {
            DiffComment(companyId: "c", itemId: "i", kind: kind, path: "a", side: "new", line: 1, lineHash: "h", hunkHeader: "@@ -1 +1 @@",
                        compare: "ENG-1:diff@worktree", baseSha: nil, text: "t", eventId: nil, createdAt: now, tainted: tainted)
        }
        #expect(DiffThread.chips(for: comment(tainted: true)) == [RefChip(text: "TAINTED", tone: .warn)])
        #expect(DiffThread.chips(for: comment(tainted: false)).isEmpty)
        #expect(DiffThread.kindText(comment(tainted: false)) == "COMMENT")
        #expect(DiffThread.kindText(comment(tainted: false, kind: DiffComment.revertRequest)) == "REVERT REQUEST")
    }

    @Test func nudgerRootMustBeTheWorktreeItself() throws {
        // m-2: the watched root is re-checked right before the stream is made: a real directory named for the key directly in
        // `.brahma/wt`, never a link (to anywhere), a file, a missing path or a key that walks out.
        let fm = FileManager.default
        let root = fm.temporaryDirectory.appending(path: "c7c-root-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? fm.removeItem(at: root) }
        let wt = root.appending(path: ".brahma/wt", directoryHint: .isDirectory)
        try fm.createDirectory(at: wt.appending(path: "ENG-1"), withIntermediateDirectories: true)
        let outside = root.appending(path: "elsewhere", directoryHint: .isDirectory)
        try fm.createDirectory(at: outside, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: wt.appending(path: "ENG-2"), withDestinationURL: outside)
        try fm.createSymbolicLink(at: wt.appending(path: "ENG-3"), withDestinationURL: wt.appending(path: "ENG-1"))
        try Data("x".utf8).write(to: wt.appending(path: "ENG-4"))
        #expect(WorktreeWatchRoot.isSafe(path: wt.appending(path: "ENG-1").path, key: "ENG-1"))
        #expect(!WorktreeWatchRoot.isSafe(path: wt.appending(path: "ENG-2").path, key: "ENG-2"), "a link out")
        #expect(!WorktreeWatchRoot.isSafe(path: wt.appending(path: "ENG-3").path, key: "ENG-3"), "a link, even to another worktree")
        #expect(!WorktreeWatchRoot.isSafe(path: wt.appending(path: "ENG-4").path, key: "ENG-4"), "a file")
        #expect(!WorktreeWatchRoot.isSafe(path: wt.appending(path: "ENG-5").path, key: "ENG-5"), "missing")
        #expect(!WorktreeWatchRoot.isSafe(path: wt.appending(path: "ENG-1").path, key: "ENG-2"), "the path names another key")
        #expect(!WorktreeWatchRoot.isSafe(path: outside.path, key: "elsewhere"), "not directly in .brahma/wt")
        #expect(!WorktreeWatchRoot.isSafe(path: wt.path + "/../wt/ENG-1", key: "ENG-1"), "a path that walks")
        // A linked `.brahma/wt` itself (the parent swapped for a link) is refused too.
        let fake = root.appending(path: "fake/.brahma", directoryHint: .isDirectory)
        try fm.createDirectory(at: fake, withIntermediateDirectories: true)
        try fm.createSymbolicLink(at: fake.appending(path: "wt"), withDestinationURL: wt)
        #expect(!WorktreeWatchRoot.isSafe(path: fake.appending(path: "wt/ENG-1").path, key: "ENG-1"))
    }
}
