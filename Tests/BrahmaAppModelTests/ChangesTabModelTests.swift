import Testing
import Foundation
import GRDB
@testable import BrahmaCore
@testable import BrahmaAppModel

/// Plan C Task C6b's world: `RefWorld` with ENG-1 leased by @eng-1, its worktree in place (`item/ENG-1`), two check runs
/// (r1 = the branch's first commit, r2 = a commit made in the worktree) and uncommitted edits in the worktree.
@MainActor
struct ChangesWorld {
    let w: RefWorld
    let wt: URL
    let r1: String, r2: String
    var key: String { w.item.key }

    init() throws {
        w = try RefWorld()
        let (cId, itemId, eng1Id, now) = (w.company.id, w.item.id, w.eng1.id, w.now)
        try w.write { db in
            try db.execute(sql: "UPDATE workItem SET status = 'inProgress', ownerId = ? WHERE id = ?", arguments: [eng1Id, itemId])
            try WorkLease(itemId: itemId, companyId: cId, agentId: eng1Id, acquiredAt: now, expiresActive: 1e12).insert(db)
        }
        wt = try GitWorkspace(root: w.workspace).addWorktree(key: w.item.key)
        r1 = try RefWorld.git(["rev-parse", "HEAD"], in: wt)
        try RefWorld.write("src/a.ts", "one\nTWO\n", in: wt)
        try RefWorld.git(["add", "-A"], in: wt)
        try RefWorld.git(["commit", "-q", "-m", "r2"], in: wt)
        r2 = try RefWorld.git(["rev-parse", "HEAD"], in: wt)
        try addRun(commit: r1, status: .passed, at: now.addingTimeInterval(-20))
        try addRun(commit: r2, status: .failed, at: now.addingTimeInterval(-10))
        try RefWorld.write("src/a.ts", "one\nTWO\nthree\n", in: wt)
        try RefWorld.write("Sources/App.swift", "let a = 1\n", in: wt)
    }

    func addRun(commit: String, status: VerificationStatus, at: Date) throws {
        let (cId, itemId) = (w.company.id, w.item.id)
        try w.write { db in
            try VerificationRun(id: UUID().uuidString, companyId: cId, itemId: itemId, checkRevision: 0, scriptHash: "h", commit: commit, command: "true",
                                workingDirectory: ".", timeoutSeconds: 60, purpose: .submit, status: status, exitCode: status == .passed ? 0 : 1,
                                createdAt: at).insert(db)
        }
    }

    /// A tab model over a fast live engine (both cadences `interval`), with a private defaults suite.
    func model(interval: Duration = .milliseconds(100), defaults: UserDefaults? = nil) -> (ChangesTabModel, LiveChanges) {
        let live = LiveChanges(store: w.store, interval: interval, idle: interval)
        let suite = defaults ?? UserDefaults(suiteName: "brahma.tests.changes.\(UUID().uuidString)")!
        let now = w.now
        let m = ChangesTabModel(store: w.store, live: live, companyId: w.company.id, knownValues: { [] }, defaults: suite, clock: { now })
        return (m, live)
    }

    /// The anchor of `lineText` on the new side of `path`, from the diff the model shows.
    func anchor(_ m: ChangesTabModel, path: String, lineText: String) throws -> DiffAnchor {
        let diff = try #require(m.diff)
        let file = try #require(diff.files.first { $0.path == path })
        for hunk in file.hunks {
            if let line = hunk.lines.first(where: { $0.text == lineText && $0.newNo != nil }) {
                return DiffAnchor(path: path, side: "new", line: line.newNo!, hunkHeader: hunk.header, lineText: lineText)
            }
        }
        throw TestFailure("no line \(lineText) in \(path)")
    }
}


/// `eventually` for an async condition (an actor's state).
@MainActor
func eventuallyAsync(timeout: Duration = .seconds(60), _ cond: () async throws -> Bool) async throws {
    let deadline = AwakeTime.now + timeout
    while AwakeTime.now < deadline {
        if try await cond() { return }
        try await Task.sleep(for: .milliseconds(20))
    }
    struct Timeout: Error {}
    if try await !cond() { throw Timeout() }
}

/// Plan C Task C6b: the CHANGES tab model — the tab itself, the board rows, live diffs per compare mode, the scroll stop across
/// yields, subscribing only while visible, review markers and drafts, and the "changed since shown" flag.
@MainActor @Suite(.scratch) struct ChangesTabModelTests {
    static func surface(_ id: String, _ name: String) -> PreviewSurface {
        PreviewSurface(id: id, companyId: "c", name: name, position: 0, build: nil, run: "npm start", url: "http://127.0.0.1:{port}/", smoke: [],
                       setById: "a1", createdAt: .now, updatedAt: .now)
    }

    @Test func changesTabAppearsWithWorktrees() throws {
        #expect(PreviewTabID.changes == "changes")
        var p = PreviewSnapshot.empty
        p.surfaces = [Self.surface("s1", "web")]
        #expect(PreviewTabs.make(p, opened: nil).map(\.id) == ["surface:s1"], "no CHANGES tab without a lease with a worktree")
        p.worktreeKeys = ["ENG-1", "ENG-2"]
        let opened = OpenedRef(ref: WorkRef(kind: .item, id: "ENG-1"), title: "ENG-1", kindChip: "ITEM", origin: .owner)
        let tabs = PreviewTabs.make(p, opened: opened)
        #expect(tabs.map(\.id) == ["surface:s1", PreviewTabID.changes, PreviewTabID.ref], "after the surfaces, before OPENED")
        let changes = tabs[1]
        #expect(changes.title == "CHANGES" && changes.statusTitle == "2 LIVE" && changes.tone == .busy && changes.surfaceId == nil && !changes.closable)
        // Fixed: ARTIFACTS and LIVE come after it, and it is never the default selection.
        p.live = URL(string: "https://example.com")
        p.liveRef = "R-1"
        let withLive = PreviewTabs.make(p)
        #expect(withLive.map(\.id) == ["surface:s1", PreviewTabID.changes, PreviewTabID.live])
        #expect(PreviewTabs.defaultSelection(withLive) == PreviewTabID.live)
        #expect(PreviewTabs.resolve(PreviewTabID.changes, withLive) == PreviewTabID.changes)
        p.worktreeKeys = ["ENG-1"]
        #expect(PreviewTabs.make(p)[1].statusTitle == "1 LIVE")
        // The body of the tab is the CHANGES case.
        #expect(PreviewBody.changes == PreviewBody.changes)

        // From a real company: the snapshot lists the leased worktrees that are in place, and none once the lease is gone.
        let cw = try ChangesWorld()
        let loaded = try PreviewSnapshot.load(store: cw.w.store, company: cw.w.company)
        #expect(loaded.worktreeKeys == [cw.key])
        #expect(try PreviewSnapshot.load(store: cw.w.store, company: try RefWorld().company).worktreeKeys.isEmpty)
        try cw.w.write { db in try db.execute(sql: "DELETE FROM workLease") }
        #expect(try PreviewSnapshot.load(store: cw.w.store, company: cw.w.company).worktreeKeys.isEmpty)
        // The target strings.
        #expect(SelectTarget("changes") == .changes(key: nil))
        #expect(SelectTarget("changes:eng-1") == .changes(key: "ENG-1"))
        #expect(SelectTarget("changes:") == nil)
        #expect(LaunchOptions.parse(["/x", "--select", "changes:ENG-1"]).select == .changes(key: "ENG-1"))
    }

    @Test func boardRowsPresentation() {
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        let rows = [
            BoardRow(key: "ENG-1", title: "Checkout totals", agent: "eng-1", agentState: "running", files: 6, added: 120, removed: 34,
                     lastEdit: now.addingTimeInterval(-12), checkStatus: "failed", reviewer: "qa-2", tainted: true),
            BoardRow(key: "ENG-2", title: "Cart", agent: "eng-2", agentState: "ready", files: 1, added: 1, removed: 0,
                     lastEdit: now.addingTimeInterval(-90), checkStatus: "running", reviewer: nil, tainted: false),
            BoardRow(key: "ENG-3", title: "Search", agent: "eng-3", agentState: "blocked", files: 0, added: 0, removed: 0,
                     lastEdit: nil, checkStatus: "none", reviewer: nil, tainted: false),
            BoardRow(key: "ENG-4", title: "Docs", agent: "eng-4", agentState: "killed", files: 2, added: 0, removed: 9,
                     lastEdit: now.addingTimeInterval(-7_300), checkStatus: "passed", reviewer: nil, tainted: false),
            BoardRow(key: "ENG-5", title: "Infra", agent: "ops-1", agentState: "sleeping", files: 3, added: 2, removed: 2,
                     lastEdit: now.addingTimeInterval(-200_000), checkStatus: nil, reviewer: nil, tainted: false),
        ]
        let views = BoardRows.make(rows, now: now)
        #expect(views.map(\.key) == ["ENG-1", "ENG-2", "ENG-3", "ENG-4", "ENG-5"], "the engine's order is kept")
        let first = views[0]
        #expect(first.title == "Checkout totals" && first.agent == "@eng-1" && first.stats == "+120 −34 · 6 files")
        #expect(first.edited == "edited 12 s ago" && first.check == "CHECK FAILED" && first.checkTone == .bad && first.agentTone == .good && first.tainted)
        #expect(first.reviewer == "@qa-2")
        #expect(views[1].stats == "+1 −0 · 1 file" && views[1].edited == "edited 1 min ago" && views[1].check == "CHECK RUNNING" && views[1].checkTone == .busy)
        #expect(views[1].agentTone == .idle && views[1].reviewer == nil && !views[1].tainted)
        #expect(views[2].stats == "+0 −0 · 0 files" && views[2].edited == "no edits yet" && views[2].check == "NO CHECK" && views[2].checkTone == .idle)
        #expect(views[2].agentTone == .warn)
        #expect(views[3].edited == "edited 2 h ago" && views[3].check == "CHECK PASSED" && views[3].checkTone == .good && views[3].agentTone == .bad)
        #expect(views[4].edited == "edited 2 d ago" && views[4].check == "NO CHECK" && views[4].agentTone == .idle)
        #expect(BoardRows.make([], now: now).isEmpty)
    }

    @Test func selectingRowOpensLiveDiff() async throws {
        let cw = try ChangesWorld()
        let suite = UserDefaults(suiteName: "brahma.tests.changes.\(UUID().uuidString)")!
        let (m, live) = cw.model(defaults: suite)
        #expect(m.selectedKey == nil && m.snapshot == nil && m.diff == nil && m.compare == .main && m.mode == .unified)
        m.start()
        await m.refresh()
        #expect(m.board.map(\.key) == [cw.key] && m.rows.first?.agent == "@eng-1" && m.rows.first?.stats == "+2 −3 · 2 files")
        m.select(cw.key)
        #expect(m.compare == .main)
        try await eventually { m.snapshot != nil && m.diff != nil }
        let snapshot = try #require(m.snapshot)
        #expect(snapshot.key == cw.key && snapshot.compare == .main && snapshot.target == "worktree")
        #expect(snapshot.files.map(\.path) == ["Sources/App.swift", "src/a.ts"])
        let diff = try #require(m.diff)
        #expect(diff.files.map(\.path) == ["Sources/App.swift", "src/a.ts"] && diff.added == 2 && diff.removed == 3)
        #expect(m.changeStops.count == 2 && m.stopIndex == nil)
        #expect(await live.isWatching(companyId: cw.w.company.id, key: cw.key, compare: .main))
        // The mode is per company and survives a new model over the same defaults.
        m.mode = .split
        let again = ChangesTabModel(store: cw.w.store, live: live, companyId: cw.w.company.id, knownValues: { [] }, defaults: suite, clock: { cw.w.now })
        #expect(again.mode == .split)
        #expect(ChangesTabModel(store: cw.w.store, live: live, companyId: "other", knownValues: { [] }, defaults: suite, clock: { cw.w.now }).mode == .unified)
        // Deselecting clears the diff and ends the watch.
        m.select(nil)
        #expect(m.snapshot == nil && m.diff == nil && m.selectedKey == nil)
        try await eventuallyAsync { await !live.isWatching(companyId: cw.w.company.id, key: cw.key, compare: .main) }
        m.stop()
    }

    @Test func compareModePickerListsRevisions() async throws {
        let cw = try ChangesWorld()
        let (m, live) = cw.model()
        m.start()
        m.select(cw.key)
        await m.refresh()
        #expect(m.revisions.map(\.label) == ["base", "r1", "r2", "head", "worktree"])
        #expect(m.revisions[1].sha == cw.r1 && m.revisions[1].checkStatus == "passed" && m.revisions[2].sha == cw.r2 && m.revisions[2].checkStatus == "failed")
        #expect(m.revisions[4].sha == nil)
        try await eventually { m.snapshot?.compare == .main }
        m.setCompare(.revisions(from: "r1", to: "r2"))
        #expect(m.compare == .revisions(from: "r1", to: "r2") && m.snapshot == nil && m.diff == nil, "a new compare starts clean")
        try await eventually { m.snapshot?.compare == .revisions(from: "r1", to: "r2") }
        let snapshot = try #require(m.snapshot)
        #expect(snapshot.base == cw.r1 && snapshot.target == cw.r2 && snapshot.files.map(\.path) == ["src/a.ts"])
        #expect(await live.isWatching(companyId: cw.w.company.id, key: cw.key, compare: .revisions(from: "r1", to: "r2")))
        try await eventuallyAsync { await !live.isWatching(companyId: cw.w.company.id, key: cw.key, compare: .main) }
        // Head and last check are live compares against engine commits.
        m.setCompare(.head)
        try await eventually { m.snapshot?.compare == .head }
        #expect(m.snapshot?.base == cw.r2 && m.snapshot?.target == "worktree")
        m.setCompare(.lastCheck)
        try await eventually { m.snapshot?.compare == .lastCheck }
        #expect(m.snapshot?.base == cw.r2)
        m.stop()
    }

    @Test func liveYieldKeepsScrollStop() async throws {
        let cw = try ChangesWorld()
        let (m, _) = cw.model()
        m.start()
        m.select(cw.key)
        try await eventually { m.diff != nil }
        let first = try #require(m.snapshot)
        #expect(m.stopIndex == nil)
        m.nextChange()
        m.nextChange()
        #expect(m.stopIndex == 1)
        let stop = try #require(m.currentStop)
        let path = try #require(m.diff?.files[stop.file].path)
        #expect(path == "src/a.ts" && stop.file == 1)
        // A new file that sorts first shifts every file index; the yield keeps the stop on the same file.
        try RefWorld.write("AAA.ts", "aaa\n", in: cw.wt)
        try await eventually { m.snapshot?.patchHash != first.patchHash }
        try await eventually { m.diff?.files.count == 3 }
        let kept = try #require(m.currentStop)
        #expect(m.diff?.files[kept.file].path == "src/a.ts" && kept.file == 2 && kept.line == stop.line, "\(kept)")
        #expect(m.changeStops.count == 3)
        // Stepping clamps at both ends.
        m.nextChange(); m.nextChange(); m.nextChange()
        #expect(m.stopIndex == 2)
        m.previousChange(); m.previousChange(); m.previousChange(); m.previousChange()
        #expect(m.stopIndex == 0)
        // The stopped file disappearing drops the stop.
        m.nextChange(); m.nextChange()
        #expect(m.currentStop.map { m.diff?.files[$0.file].path } == "src/a.ts")
        try RefWorld.write("src/a.ts", "one\ntwo\n", in: cw.wt)  // back to main's content: no change in that file
        try await eventually { m.diff?.files.contains { $0.path == "src/a.ts" } == false }
        #expect(m.stopIndex == nil)
        m.stop()
    }

    @Test func subscribesOnlyWhileVisible() async throws {
        let cw = try ChangesWorld()
        let (m, live) = cw.model()
        m.select(cw.key)
        try await Task.sleep(for: .milliseconds(150))
        #expect(await !live.isWatching(companyId: cw.w.company.id, key: cw.key, compare: .main), "nothing streams before start()")
        #expect(!m.isRunning && m.snapshot == nil)
        m.start()
        #expect(m.isRunning)
        try await eventually { m.snapshot != nil }
        #expect(await live.isWatching(companyId: cw.w.company.id, key: cw.key, compare: .main))
        m.stop()
        #expect(!m.isRunning)
        try await eventuallyAsync { await !live.isWatching(companyId: cw.w.company.id, key: cw.key, compare: .main) }
        #expect(m.snapshot != nil, "what was shown stays until the next start")
        // Through the app: the model runs while the CHANGES tab is selected, and stops when the owner leaves it.
        let app = await cw.w.app()
        let changes = try #require(app.changes)
        #expect(!changes.isRunning && changes.companyId == cw.w.company.id)
        #expect(app.previewTabs.map(\.id).contains(PreviewTabID.changes))
        app.apply(.changes(key: cw.key))
        #expect(app.selectedPreviewTab == PreviewTabID.changes && app.sidebarSelection == .missionControl)
        #expect(changes.isRunning && changes.selectedKey == cw.key)
        #expect(app.previewBody == .changes)
        try await eventually { changes.snapshot != nil }
        app.selectPreviewTab(nil)
        #expect(!changes.isRunning)
        try await eventuallyAsync { await !app.liveChanges.isWatching(companyId: cw.w.company.id, key: cw.key, compare: .main) }
        app.apply(.changes(key: nil))
        #expect(changes.isRunning && changes.selectedKey == cw.key, "the board keeps the selection")
        // A stored value that can't be read refuses the stream (fail closed): nothing is shown.
        let (refused, refusedLive) = cw.model()
        let blind = ChangesTabModel(store: cw.w.store, live: refusedLive, companyId: cw.w.company.id,
                                    knownValues: { throw WorkError.invalid("vault locked") }, defaults: UserDefaults(suiteName: "brahma.tests.changes.x")!,
                                    clock: { cw.w.now })
        _ = refused
        blind.start()
        blind.select(cw.key)
        try await eventually { blind.error != nil }
        #expect(blind.snapshot == nil && blind.diff == nil)
        #expect(await !refusedLive.isWatching(companyId: cw.w.company.id, key: cw.key, compare: .main))
        blind.stop()
    }

    @Test func commentMarkersPlaced() async throws {
        let cw = try ChangesWorld()
        let (m, _) = cw.model()
        m.start()
        m.select(cw.key)
        try await eventually { m.diff != nil }
        let owner = try cw.w.owner()
        let anchor = try cw.anchor(m, path: "src/a.ts", lineText: "three")
        let c = try cw.w.store.addDiffComment(companyId: cw.w.company.id, key: cw.key, compare: .main, anchor: anchor, text: "Why three?",
                                               knownValues: [], now: cw.w.now, owner: owner)
        // A second comment whose line text is not in the diff any more (its hash matches nothing within ±50 lines): outdated.
        var stale = anchor
        stale.lineText = "nothing like this"
        stale.line = 2
        _ = try cw.w.store.addDiffComment(companyId: cw.w.company.id, key: cw.key, compare: .main, anchor: stale, text: "Stale", knownValues: [],
                                           now: cw.w.now, owner: owner)
        // A revert request on App.swift's deletion anchors on the old side.
        let app = try #require(m.diff?.files.first { $0.path == "Sources/App.swift" })
        let gone = try #require(app.hunks.first?.lines.first { $0.kind == .del })
        let oldAnchor = DiffAnchor(path: "Sources/App.swift", side: "old", line: gone.oldNo!, hunkHeader: app.hunks[0].header, lineText: gone.text)
        let revert = try cw.w.store.requestHunkRevert(companyId: cw.w.company.id, key: cw.key, compare: .main, anchor: oldAnchor, note: nil,
                                                       knownValues: [], now: cw.w.now, owner: owner)
        await m.refresh()
        #expect(m.comments.count == 3)
        #expect(m.markers.count == 2, "\(m.markers.keys)")
        let placed = try #require(m.markers.first { $0.key.path == "src/a.ts" })
        #expect(placed.key.side == "new" && placed.key.line == 3 && placed.key.lineText == "three")
        #expect(placed.key.hunkHeader == DiffAnchoring.headerRange(anchor.hunkHeader), "the header is the numbers only, never a line of the file")
        #expect(placed.value.map(\.id) == [c.id] && placed.value.first?.text == "Why three?")
        let revertMarker = try #require(m.markers.first { $0.key.path == "Sources/App.swift" })
        #expect(revertMarker.key.side == "old" && revertMarker.value.first?.id == revert.id && revertMarker.value.first?.kind == DiffComment.revertRequest)
        #expect(m.outdated == ["src/a.ts": 1])
        // A resolved comment leaves the markers.
        try cw.w.store.resolveDiffComment(companyId: cw.w.company.id, id: c.id, now: cw.w.now, owner: owner)
        await m.refresh()
        #expect(m.markers[placed.key] == nil && m.outdated == ["src/a.ts": 1])
        #expect(m.comments.count == 3, "resolved comments are still listed")
        m.stop()
    }

    @Test func reviewDraftValidation() async throws {
        let anchor = DiffAnchor(path: "src/a.ts", side: "new", line: 3, hunkHeader: "@@ -1,2 +1,3 @@", lineText: "three")
        #expect(ReviewDraft(anchor: anchor, text: "", isRevert: false).validate() == "Write a comment first")
        #expect(ReviewDraft(anchor: anchor, text: "  \n ", isRevert: false).validate() == "Write a comment first")
        #expect(ReviewDraft(anchor: anchor, text: "", isRevert: true).validate() == nil, "a revert request needs no note")
        #expect(ReviewDraft(anchor: anchor, text: "Why?", isRevert: false).validate() == nil)
        #expect(ReviewDraft(anchor: anchor, text: String(repeating: "x", count: DiffReviewLimits.maxText), isRevert: false).validate() == nil)
        let long = ReviewDraft(anchor: anchor, text: String(repeating: "x", count: DiffReviewLimits.maxText + 1), isRevert: true)
        #expect(long.validate() == "Keep the comment under 2,000 characters")
        #expect(ReviewDraft.maxText == 2000)

        // Through the app: an invalid draft posts nothing; without an owner principal the review is refused before any write;
        // a valid one writes exactly one comment row and the model lists it.
        let cw = try ChangesWorld()
        let app = await cw.w.app()
        let changes = try #require(app.changes)
        app.apply(.changes(key: cw.key))
        try await eventually { changes.diff != nil }
        let live = try cw.anchor(changes, path: "src/a.ts", lineText: "three")
        #expect(await app.submitReview(ReviewDraft(anchor: live, text: "", isRevert: false), key: cw.key, compare: .main) == false)
        #expect(app.errorMessage == "Write a comment first")
        #expect(try cw.w.count("diffComment") == 0)
        app.errorMessage = nil
        let minted = app.owner
        app.owner = nil
        #expect(await app.submitReview(ReviewDraft(anchor: live, text: "Why?", isRevert: false), key: cw.key, compare: .main) == false)
        #expect(app.errorMessage == Store.refUnavailable)
        #expect(try cw.w.count("diffComment") == 0)
        app.owner = minted
        app.errorMessage = nil
        #expect(await app.submitReview(ReviewDraft(anchor: live, text: "Why three?", isRevert: false), key: cw.key, compare: .main))
        #expect(try cw.w.count("diffComment") == 1)
        #expect(app.errorMessage == nil)
        #expect(changes.comments.count == 1 && changes.comments.first?.kind == DiffComment.comment && changes.markers.count == 1)
        #expect(await app.submitReview(ReviewDraft(anchor: live, text: "", isRevert: true), key: cw.key, compare: .main))
        #expect(try cw.w.count("diffComment") == 2)
        #expect(changes.comments.last?.kind == DiffComment.revertRequest)
        // Both sit on the same anchor.
        #expect(changes.markers.count == 1 && changes.markers.values.first?.count == 2)
        app.selectPreviewTab(nil)
    }

    @Test func changedSinceShownFlag() async throws {
        let cw = try ChangesWorld()
        let app = await cw.w.app()
        let changes = try #require(app.changes)
        // A live diff ref opened in the OPENED tab renders through the changes model (the engine's gated snapshot, live).
        let ref = WorkRef(kind: .diff, id: cw.key, branch: "worktree:\(cw.key)", params: ["at": "stale-hash"])
        await app.openRef(ref, origin: .showAnswer(requestId: "r1", by: "@eng-1"))
        try await eventually { app.openedBody != nil }
        #expect(app.openedBody?.content == .changes(key: cw.key, compare: .main))
        #expect(app.openedBody?.header.chips.contains { $0.text == "LIVE" } == true)
        #expect(app.openedBody?.header.chips.contains { $0.text == "UNCOMMITTED" } == true)
        #expect(changes.isRunning && changes.selectedKey == cw.key && changes.compare == .main)
        try await eventually { changes.snapshot != nil }
        #expect(changes.changedSinceShown, "shown at a patch hash that is not the current one")
        let current = try #require(changes.snapshot?.patchHash)
        // Opened at the current hash of the same compare: unchanged.
        await app.openRef(WorkRef(kind: .diff, id: cw.key, branch: "worktree:\(cw.key)", params: ["at": current]), origin: .owner)
        try await eventually { app.openedBody?.content == .changes(key: cw.key, compare: .main) }
        #expect(!changes.changedSinceShown && changes.snapshot?.patchHash == current)
        // A ref without `at` never flags; its compare follows the ref (`?vs=head`).
        await app.openRef(WorkRef(kind: .diff, id: cw.key, branch: "worktree:\(cw.key)", params: ["vs": "head"]), origin: .owner)
        try await eventually { changes.snapshot?.compare == .head }
        #expect(!changes.changedSinceShown && changes.compare == .head)
        await app.openRef(WorkRef(kind: .diff, id: cw.key, branch: "worktree:\(cw.key)"), origin: .owner)
        try await eventually { changes.snapshot?.compare == .main }
        #expect(!changes.changedSinceShown)
        // Leaving the OPENED tab for a surface stops the stream; closing the opened ref too.
        app.selectPreviewTab(nil)
        #expect(!changes.isRunning)
        app.selectPreviewTab(PreviewTabID.ref)
        #expect(changes.isRunning)
        app.closeOpened()
        #expect(!changes.isRunning)
        // The deep link `changes:<KEY>` lands on the CHANGES tab with that item's live diff vs main.
        app.apply(.changes(key: cw.key))
        #expect(changes.isRunning && changes.compare == .main && app.selectedPreviewTab == PreviewTabID.changes)
        app.selectPreviewTab(nil)
    }
}
