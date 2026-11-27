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

    /// A tab model over a fast live engine (both cadences `interval`), with a private defaults suite and this process's owner
    /// principal; `known` are the stored values the model gates with.
    func model(interval: Duration = .milliseconds(100), defaults: UserDefaults? = nil, known: [(name: String, value: String)] = [],
               noOwner: Bool = false) throws -> (ChangesTabModel, LiveChanges) {
        let live = LiveChanges(store: w.store, interval: interval, idle: interval)
        let suite = defaults ?? UserDefaults(suiteName: "brahma.tests.changes.\(UUID().uuidString)")!
        let now = w.now
        let principal: OwnerPrincipal? = noOwner ? nil : try w.owner()
        let m = ChangesTabModel(store: w.store, live: live, companyId: w.company.id, owner: principal, knownValues: { known }, defaults: suite, clock: { now })
        return (m, live)
    }

    /// The anchor of `lineText` on `side` of the snapshot file `path` (the engine's display path), through the model's builder.
    func anchor(_ m: ChangesTabModel, path: String, lineText: String, side: String = "new") throws -> DiffAnchor {
        let diff = try #require(m.diff), snapshot = try #require(m.snapshot)
        let section = try #require(snapshot.files.first { $0.path == path }?.patchIndex)
        for (h, hunk) in diff.files[section].hunks.enumerated() {
            if let i = hunk.lines.firstIndex(where: { $0.text == lineText && (side == "old" ? $0.oldNo : $0.newNo) != nil }) {
                return try #require(m.anchor(fileIndex: section, hunk: h, index: i, side: side))
            }
        }
        throw TestFailure("no line \(lineText) in \(path)")
    }

    func write(_ path: String, _ text: String) throws { try RefWorld.write(path, text, in: wt) }
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
        let (m, live) = try cw.model(defaults: suite)
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
        let owner = try cw.w.owner()
        let again = ChangesTabModel(store: cw.w.store, live: live, companyId: cw.w.company.id, owner: owner, knownValues: { [] }, defaults: suite, clock: { cw.w.now })
        #expect(again.mode == .split)
        #expect(ChangesTabModel(store: cw.w.store, live: live, companyId: "other", owner: owner, knownValues: { [] }, defaults: suite, clock: { cw.w.now }).mode == .unified)
        // The file rows point at their hunks through the engine's identity.
        #expect(m.files.map(\.path) == ["Sources/App.swift", "src/a.ts"] && m.files.map(\.fileIndex) == [0, 1])
        #expect(m.isLive && m.chips.map(\.text) == ["UNCOMMITTED", "LIVE"])
        // Deselecting clears the diff and ends the watch.
        m.select(nil)
        #expect(m.snapshot == nil && m.diff == nil && m.selectedKey == nil)
        try await eventuallyAsync { await !live.isWatching(companyId: cw.w.company.id, key: cw.key, compare: .main) }
        m.stop()
    }

    @Test func compareModePickerListsRevisions() async throws {
        let cw = try ChangesWorld()
        let (m, live) = try cw.model()
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
        let (m, _) = try cw.model()
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
        let (m, live) = try cw.model()
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
        let (refused, refusedLive) = try cw.model()
        let blind = ChangesTabModel(store: cw.w.store, live: refusedLive, companyId: cw.w.company.id, owner: try cw.w.owner(),
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
        let (m, _) = try cw.model()
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
        let oldAnchor = try cw.anchor(m, path: "Sources/App.swift", lineText: "let b = 2", side: "old")
        let revert = try cw.w.store.requestHunkRevert(companyId: cw.w.company.id, key: cw.key, compare: .main, anchor: oldAnchor, note: nil,
                                                       knownValues: [], now: cw.w.now, owner: owner)
        await m.refresh()
        #expect(m.comments.count == 3)
        #expect(m.markers.count == 2, "\(m.markers.keys)")
        let placed = try #require(m.markers.first { $0.key.path == "src/a.ts" })
        #expect(placed.key.side == "new" && placed.key.line == 3 && placed.key.lineText == "three")
        #expect(placed.key.hunkHeader == anchor.hunkHeader && anchor.hunkHeader.hasPrefix("@@ -") && anchor.hunkHeader.hasSuffix(" @@"),
                "the header is the numbers only, never a line of the file")
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
        try await eventually { changes.comments.count == 1 }
        #expect(changes.comments.first?.kind == DiffComment.comment && changes.markers.count == 1)
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
        #expect(changes.isRunning && changes.selectedKey == cw.key && changes.compare == .main)
        try await eventually { changes.snapshot != nil }
        // I-4: the pane's header carries the model's chips, rebuilt per yield (the static render has none of them).
        guard case .ref(let shown) = app.previewBody(forTab: PreviewTabID.ref) else { Issue.record("no ref body"); return }
        #expect(shown.header.chips.contains { $0.text == "LIVE" } && shown.header.chips.contains { $0.text == "UNCOMMITTED" })
        #expect(shown.header.chips.contains { $0.text.hasPrefix("LEASED BY @eng-1") })
        #expect(shown.header.chips.filter { $0.text == "UNCOMMITTED" }.count == 1, "no duplicate chips: \(shown.header.chips)")
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

    // MARK: Fix round 1

    /// I-1 / M-8: files are matched on the engine's identity (`patchIndex`), so a path with a space, two spaces, a quote (git
    /// C-quotes it) or a non-ASCII letter keeps its hunks, its anchors are the engine's display path, and its comments place. A
    /// ZWSP or bidi name is refused by the engine's walk (`SafeFS.checkComponent`): the whole live diff reads as unavailable, never
    /// as a live diff with a mislabelled file.
    @Test func hostilePathsKeepHunksAndComments() async throws {
        let cw = try ChangesWorld()
        let hostile = ["src/we ird.ts", "src/caf\u{E9}.ts", "src/two  spaces.ts", "src/qu\"ote.ts"]
        for (i, p) in hostile.enumerated() { try cw.write(p, "line \(i)\n") }
        let (m, _) = try cw.model()
        m.start()
        m.select(cw.key)
        try await eventually { m.diff?.files.count == 2 + hostile.count }
        let snapshot = try #require(m.snapshot), diff = try #require(m.diff)
        #expect(snapshot.files.count == 2 + hostile.count)
        #expect(m.files.allSatisfy { $0.fileIndex != nil }, "every file keeps its hunks: \(m.files)")
        #expect(Set(m.files.compactMap(\.fileIndex)).count == m.files.count)
        // The parser's own paths: no trailing tab, no fake rename for a space.
        let spaced = try #require(snapshot.files.first { $0.path == "src/we ird.ts" })
        let parsed = diff.files[try #require(spaced.patchIndex)]
        #expect(parsed.path == "src/we ird.ts" && parsed.oldPath == nil && parsed.hunks.count == 1 && parsed.hunks[0].lines.first?.text == "line 0")
        let quoted = diff.files[try #require(snapshot.files.first { $0.patchIndex == diff.files.firstIndex { $0.path.contains("ote.ts") } }?.patchIndex)]
        #expect(quoted.path == "src/qu\"ote.ts" && quoted.hunks[0].lines.first?.text == "line 3", "git's C-quoting is decoded as the engine does")
        // A comment on every hostile file, anchored through the model (the engine accepts each path), places as a marker.
        let owner = try cw.w.owner()
        for p in snapshot.files where p.path != "Sources/App.swift" && p.path != "src/a.ts" {
            let i = try #require(p.patchIndex)
            let a = try #require(m.anchor(fileIndex: i, hunk: 0, index: 0, side: "new"))
            #expect(a.path == p.path && a.line == 1)
            _ = try cw.w.store.addDiffComment(companyId: cw.w.company.id, key: cw.key, compare: .main, anchor: a, text: "on \(i)", knownValues: [],
                                               now: cw.w.now, owner: owner)
        }
        await m.refreshItem()
        #expect(m.comments.count == hostile.count && m.markers.count == hostile.count && m.outdated.isEmpty, "\(m.outdated)")
        #expect(m.anchor(fileIndex: 99, hunk: 0, index: 0, side: "new") == nil && m.anchor(fileIndex: 0, hunk: 0, index: 0, side: "sideways") == nil)
        // A hidden-character name: the engine refuses the walk, the stream ends, and after the retries the model shows the refusal.
        try cw.write("src/zw\u{200B}sp.ts", "x\n")
        try await eventually { !m.isRunning }
        #expect(m.error == Store.refUnavailable && !m.isLive && m.chips.contains { $0.text == "STALE" })
        #expect(m.diff?.files.count == 2 + hostile.count, "what was shown stays, marked stale")
    }

    /// I-2: a stream that ends is shown STALE and resubscribed with backoff; after `maxRetries` ends in a row the model shows the
    /// generic refusal and stops, and a new `start()` tries again. A key the owner can't watch refuses the same way.
    @Test func endedStreamIsNotLive() async throws {
        #expect(ChangesTabModel.backoff(1) == .milliseconds(500) && ChangesTabModel.backoff(2) == .seconds(1) && ChangesTabModel.backoff(3) == .seconds(2))
        #expect(ChangesTabModel.backoff(0) == .milliseconds(500) && ChangesTabModel.backoff(40) <= .seconds(30))
        #expect(ChangesTabModel.backoff(4) == .seconds(4) && ChangesTabModel.backoff(5) == .seconds(8))
        #expect(ChangesTabModel.maxRetries == 5)
        let cw = try ChangesWorld()
        let (m, live) = try cw.model()
        m.start()
        m.select(cw.key)
        try await eventually { m.isLive }
        #expect(m.chips.contains { $0.text == "LIVE" } && m.retryAttempt == 0 && m.error == nil)
        // The worktree goes away: the engine ends the stream.
        try RefWorld.git(["worktree", "remove", "--force", cw.wt.path], in: cw.w.workspace)
        try await eventually { !m.isLive }
        #expect(m.snapshot != nil && m.diff != nil, "what was shown stays, marked stale")
        #expect(m.chips.contains { $0.text == "STALE" } && !m.chips.contains { $0.text == "LIVE" })
        try await eventually { m.error != nil }
        #expect(m.error == Store.refUnavailable && !m.isRunning && m.retryAttempt == ChangesTabModel.maxRetries + 1, "the first end plus the retries")
        try await eventuallyAsync { await !live.isWatching(companyId: cw.w.company.id, key: cw.key, compare: .main) }
        // A new start tries again (and gives up the same way while the worktree is gone).
        m.start()
        #expect(m.isRunning && m.retryAttempt == 0)
        try await eventually { !m.isRunning }
        #expect(m.error == Store.refUnavailable)
        // `changes:<KEY>` for a key with nothing to watch: the refusal, never a blank live pane.
        let (other, _) = try cw.model()
        other.start()
        other.select("ENG-9")
        try await eventually { !other.isRunning }
        #expect(other.error == Store.refUnavailable && other.snapshot == nil)
        // M-1: without an owner principal nothing is read.
        let (blind, blindLive) = try cw.model(noOwner: true)
        _ = blindLive
        blind.select(cw.key)
        blind.start()
        #expect(!blind.isRunning && blind.error == OwnerPrincipal.refusal)
        await blind.refresh()
        #expect(blind.board.isEmpty && blind.revisions.isEmpty && blind.error == OwnerPrincipal.refusal)
    }

    /// I-3: the board reloads on the model's own cadence (the engine's idle interval), never on the app tick.
    @Test func boardReloadsOffTheTick() async throws {
        #expect(ChangesTabModel.boardInterval == ChangesLimits.idleInterval)
        let cw = try ChangesWorld()
        let app = await cw.w.app()
        let changes = try #require(app.changes)
        #expect(changes.boardLoads == 0)
        app.apply(.changes(key: cw.key))
        try await eventually { changes.boardLoads == 1 && !changes.rows.isEmpty }
        for _ in 0..<10 { await app.tick() }
        try await Task.sleep(for: .milliseconds(300))
        #expect(changes.boardLoads == 1, "ten ticks reload nothing")
        #expect(changes.rows.first?.key == cw.key)
        // An explicit refresh (an owner action) reloads once; stopping ends the loop.
        await changes.refresh()
        #expect(changes.boardLoads == 2)
        app.selectPreviewTab(nil)
        await app.tick()
        try await Task.sleep(for: .milliseconds(200))
        #expect(changes.boardLoads == 2 && !changes.isRunning)
    }

    /// I-4 / M-3 / M-4 / M-8: a tainted live diff shows a TAINTED chip whose reason is gated as a final string (a stored value or a
    /// secret-shaped token in it withholds the reason), a stored value in the diff is never shown, CR characters keep their marker
    /// (the one trailing CR of a CRLF line is the parser's line ending; a doubled or mid-line CR is shown) and raise the HIDDEN
    /// CHARACTERS chip, and the chips follow the stream.
    @Test func taintedLiveDiffShowsGatedChips() async throws {
        let cw = try ChangesWorld()
        // M-8 (core case): a stored value that matches no secret pattern — built at runtime (C5b-4) — is withheld only because the
        // subscription's known values reached the gate.
        let secret = ["plum", "orchard", String(UInt64.random(in: 1_000_000...9_999_999))].joined(separator: "-")
        try cw.write("src/a.ts", "one\nTWO\nthree\nkey = \(secret)\n")
        try cw.write("win.txt", "a\r\r\nb\rc\r\n")
        let git = SafeGit(workspace: cw.w.workspace)
        try cw.w.store.recordTaintedCommits(companyId: cw.w.company.id, itemId: cw.w.item.id, agentId: cw.w.eng1.id, turnId: nil, headBefore: cw.r1,
                                            headAfter: cw.r2, source: "docs.example.com token \(secret)", git: git, now: cw.w.now)
        // The control: with no known values the value is plain text and shows (no pattern catches it).
        let (control, _) = try cw.model(known: [])
        control.start()
        control.select(cw.key)
        try await eventually { control.isLive }
        #expect(control.snapshot?.patch.contains(secret) == true)
        #expect(control.diff?.files.flatMap(\.hunks).flatMap(\.lines).contains { $0.text.contains(secret) } == true)
        #expect(control.chips.contains { $0.text == "TAINTED · from a session that read docs.example.com token \(secret)" })
        control.stop()
        let (m, _) = try cw.model(known: [(name: "PLUM", value: secret)])
        m.start()
        m.select(cw.key)
        try await eventually { m.isLive }
        let snapshot = try #require(m.snapshot), diff = try #require(m.diff)
        #expect(snapshot.tainted && !snapshot.patch.contains(secret), "the known value is redacted from the patch")
        #expect(!diff.files.flatMap(\.hunks).flatMap(\.lines).contains { $0.text.contains(secret) }, "a stored value never reaches a shown line")
        #expect(diff.files.flatMap(\.hunks).flatMap(\.lines).contains { $0.text.hasPrefix("key = ") && !$0.text.contains(secret) })
        let texts = m.chips.map(\.text)
        #expect(texts == ["UNCOMMITTED", "LIVE", "TAINTED", "HIDDEN CHARACTERS"], "\(texts)")
        #expect(m.chips.first { $0.text == "TAINTED" }?.tone == .warn)
        // A line's trailing CR (after the line ending's) survives as a marker in the highlighted rows (M-4); a mid-line CR too.
        let win = try #require(snapshot.files.first { $0.path == "win.txt" }?.patchIndex)
        let lines = diff.files[win].hunks[0].lines
        #expect(lines.map(\.text) == ["a\r", "b\rc"], "\(lines)")
        let rows = diff.highlighted(file: win)
        #expect(rows.count == 2 && rows[0].last?.text == "⟦U+000D⟧" && rows[0].last?.hidden == true, "\(rows)")
        #expect(rows[1].contains { $0.text == "⟦U+000D⟧" && $0.hidden } && rows[1].first?.text == "b" && rows[1].last?.text == "c")
        // The pure builder: a reason with no stored value in it shows, gated as one string; the known value withholds it.
        let gate = GlobalSearch.TextGate(knownValues: [])
        var taintedSnapshot = snapshot
        taintedSnapshot.taintReason = "from a session that read docs.example.com"
        #expect(ChangesTabModel.chips(for: taintedSnapshot, diff: nil, live: true, gate: gate).map(\.text)
                == ["UNCOMMITTED", "LIVE", "TAINTED · from a session that read docs.example.com"])
        #expect(ChangesTabModel.chips(for: snapshot, diff: nil, live: true, gate: gate).map(\.text).contains { $0.hasSuffix(secret) })
        #expect(ChangesTabModel.chips(for: snapshot, diff: nil, live: true, gate: GlobalSearch.TextGate(knownValues: [(name: "PLUM", value: secret)])).map(\.text)
                == ["UNCOMMITTED", "LIVE", "TAINTED"])
        // The pure builder: no taint, no hidden, not live.
        let plain = ChangesSnapshot(key: "ENG-1", compare: .head, base: "b", target: "worktree", files: [], added: 0, removed: 0, patch: "", truncated: true,
                                    tainted: false, taintReason: nil, lastEdit: nil, patchHash: "h", computedAt: cw.w.now)
        #expect(ChangesTabModel.chips(for: plain, diff: nil, live: false, gate: GlobalSearch.TextGate(knownValues: [])).map(\.text)
                == ["UNCOMMITTED", "STALE", "TRUNCATED"])
        var committed = plain
        committed.target = "abc"
        committed.truncated = false
        #expect(ChangesTabModel.chips(for: committed, diff: nil, live: true, gate: GlobalSearch.TextGate(knownValues: [])).map(\.text) == ["LIVE"])
        m.stop()
    }

    // MARK: Fix round 2 (Rulings C6b-1, C6b-2)

    /// Ruling C6b-1: the OPENED header of a tainted live diff never shows less than the static TAINTED warning — before the first
    /// snapshot, while live (exactly one chip, the model's), and after the stream ends.
    @Test func taintedChipNeverDrops() async throws {
        let cw = try ChangesWorld()
        try cw.w.store.recordTaintedCommits(companyId: cw.w.company.id, itemId: cw.w.item.id, agentId: cw.w.eng1.id, turnId: nil, headBefore: cw.r1,
                                            headAfter: cw.r2, source: "docs.example.com", git: SafeGit(workspace: cw.w.workspace), now: cw.w.now)
        let app = await cw.w.app()
        let changes = try #require(app.changes)
        // The static render carries the resolver's TAINTED chip; with no snapshot yet the pane keeps it as it is.
        let body = try await RefBodies.body(for: try cw.w.resolve("\(cw.key):diff@worktree"), store: cw.w.store, companyId: cw.w.company.id,
                                            context: try cw.w.renderContext())
        #expect(body.content == .changes(key: cw.key, compare: .main))
        #expect(body.header.chips.filter { $0.text.hasPrefix("TAINTED") }.count == 1 && body.header.chips.contains { $0.text == "UNCOMMITTED" })
        #expect(changes.snapshot == nil && app.liveOpenedBody(body).header.chips == body.header.chips)
        changes.show(key: cw.key, compare: .main)
        #expect(changes.snapshot == nil && app.liveOpenedBody(body).header.chips == body.header.chips, "selected, no snapshot yet: the static chips")
        func tainted() -> [String] {
            guard case .ref(let b) = app.previewBody(forTab: PreviewTabID.ref) else { return [] }
            return b.header.chips.filter { $0.text.hasPrefix("TAINTED") }.map(\.text)
        }
        await app.openRef(WorkRef(kind: .diff, id: cw.key, branch: "worktree:\(cw.key)"), origin: .owner)
        try await eventually { app.openedBody != nil }
        #expect(tainted().count == 1, "\(tainted())")
        try await eventually { changes.snapshot != nil }
        #expect(tainted() == ["TAINTED · from a session that read docs.example.com"], "exactly one, the model's, with the gated reason")
        guard case .ref(let live) = app.previewBody(forTab: PreviewTabID.ref) else { Issue.record("no ref body"); return }
        #expect(live.header.chips.filter { $0.text == "UNCOMMITTED" }.count == 1 && live.header.chips.contains { $0.text == "LIVE" })
        // The stream ends: STALE, and still TAINTED — while retrying and once the model gave up.
        try RefWorld.git(["worktree", "remove", "--force", cw.wt.path], in: cw.w.workspace)
        try await eventually { !changes.isLive }
        #expect(tainted().count == 1)
        guard case .ref(let stale) = app.previewBody(forTab: PreviewTabID.ref) else { Issue.record("no ref body"); return }
        #expect(stale.header.chips.contains { $0.text == "STALE" } && !stale.header.chips.contains { $0.text == "LIVE" })
        try await eventually { !changes.isRunning }
        #expect(tainted().count == 1 && changes.error == Store.refUnavailable)
        // A model whose snapshot carries no taint never removes a static TAINTED chip either (the static warning is a floor).
        var untainted = body
        untainted.header.chips = [RefChip(text: "TAINTED · outside content", tone: .warn)]
        #expect(app.liveOpenedBody(untainted).header.chips.contains { $0.text.hasPrefix("TAINTED") })
        app.closeOpened()
    }

    /// Ruling C6b-2: the engine and the app split the patch the same way (by scalar, one trailing CR a line ending), the snapshot
    /// names the sections the engine emitted, and the app refuses to render a parse that disagrees with them.
    @Test func sectionsAreVerified() async throws {
        #expect(ChangesTabModel.unverifiedText == "diff couldn't be verified")
        // The engine splits on scalars: CRLF lines are lines of their own, their CR kept as content (the app's parser shows one
        // trailing CR as the line ending).
        let crlf = "diff --git a/w.txt b/w.txt\nindex 1..2 100644\n--- a/w.txt\n+++ b/w.txt\n@@ -1,2 +1,2 @@\n-a\r\n+b\r\r\n c\r\n"
        let sections = ChangesPatch.parse(crlf)
        #expect(sections.count == 1 && sections[0].hunks == ["@@ -1,2 +1,2 @@", "-a\r", "+b\r\r", " c\r"], "\(sections.map(\.hunks))")
        #expect(ChangesPatch.lines("x\r\ny\r\r\n") == ["x\r", "y\r\r", ""])
        #expect(DiffModel.parse(patch: crlf).files[0].hunks[0].lines.map(\.text) == ["a", "b\r", "c"])
        // N-1: a CR-terminated line right before the next file's `diff --git` never swallows it — the engine and the app see the same
        // three sections, in the same order, with the same paths.
        let glued3 = "diff --git a/A.txt b/A.txt\nnew file mode 100644\nindex 0..1\n--- /dev/null\n+++ b/A.txt\n@@ -0,0 +1 @@\n+x\r\n"
            + DiffPresentationTests.file("B.txt", ["+b"]) + DiffPresentationTests.file("C.txt", ["+c"])
        let engineSections = ChangesPatch.parse(glued3), appSections = DiffModel.parse(patch: glued3)
        #expect(engineSections.map(\.path) == ["A.txt", "B.txt", "C.txt"] && appSections.files.map(\.path) == ["A.txt", "B.txt", "C.txt"])
        #expect(engineSections[0].hunks == ["@@ -0,0 +1 @@", "+x\r"] && engineSections[1].hunks.count == 2 && appSections.files[0].hunks[0].lines.count == 1)
        // A real snapshot names its sections, in the patch's order; the parse agrees and every file finds its section.
        let cw = try ChangesWorld()
        try cw.write("A.txt", "x\r\n")   // sorts first: its CR-terminated last line precedes Sources/App.swift's `diff --git` (N-1)
        try cw.write("win.txt", "a\r\nb\r\n")
        try cw.write("src/caf\u{E9}.ts", "x\n")
        let (m, _) = try cw.model()
        m.start()
        m.select(cw.key)
        try await eventually { m.diff != nil }
        let snapshot = try #require(m.snapshot), diff = try #require(m.diff)
        #expect(snapshot.sectionPaths == ["A.txt", "Sources/App.swift", "src/a.ts", "src/caf\u{E9}.ts", "win.txt"], "\(snapshot.sectionPaths)")
        #expect(snapshot.sectionPaths == diff.files.map(\.path))
        #expect(snapshot.sectionHunks == ChangesTabModel.spans(diff) && snapshot.sectionHunks.count == 5 && snapshot.sectionHunks.allSatisfy { !$0.isEmpty })
        #expect(snapshot.files.compactMap(\.patchIndex).sorted() == [0, 1, 2, 3, 4] && m.files.allSatisfy { $0.fileIndex != nil })
        // Every file's section is its own: the engine's gated path is the gate of the parser's decoded one.
        let gate = GlobalSearch.TextGate(knownValues: [])
        for f in snapshot.files { #expect(gate.final(diff.files[try #require(f.patchIndex)].path, max: 512) == f.path, "\(f.path)") }
        let appSwift = try #require(snapshot.files.first { $0.path == "Sources/App.swift" }?.patchIndex)
        #expect(diff.files[appSwift].hunks[0].lines.contains { $0.kind == .del && $0.text == "let b = 2" }, "App.swift's hunks are App.swift's")
        #expect(ChangesTabModel.verify(diff, against: snapshot) == nil && m.error == nil)
        // A parse that disagrees with the engine's sections (count or path) is refused with the plain message.
        var forged = snapshot
        forged.sectionPaths = Array(snapshot.sectionPaths.dropLast())
        #expect(ChangesTabModel.verify(diff, against: forged) == ChangesTabModel.unverifiedText)
        forged.sectionPaths = snapshot.sectionPaths.map { $0 + "x" }
        #expect(ChangesTabModel.verify(diff, against: forged) == ChangesTabModel.unverifiedText)
        forged.sectionPaths = [snapshot.sectionPaths[1], snapshot.sectionPaths[0]] + snapshot.sectionPaths.dropFirst(2)
        #expect(ChangesTabModel.verify(diff, against: forged) == ChangesTabModel.unverifiedText)
        // A withheld patch has no sections on either side.
        var withheld = snapshot
        withheld.patch = "[patch withheld]\n"
        withheld.sectionPaths = []
        withheld.sectionHunks = []
        #expect(ChangesTabModel.verify(DiffModel.parse(patch: withheld.patch), against: withheld) == nil)
        // Hand-made patches with a combining-character path and a ZWSP path: each section lands on its own file, through the
        // engine's section identity, or the diff is refused.
        let combining = "src/cafe\u{301}.ts", zwsp = "src/zw\u{200B}sp.ts"
        let patch = DiffPresentationTests.file(combining, ["+one"]) + DiffPresentationTests.file(zwsp, ["+two"])
        let parsed = DiffModel.parse(patch: patch)
        #expect(parsed.files.map(\.path) == [combining, zwsp] && ChangesPatch.parse(patch).map(\.path) == [combining, zwsp])
        let ok = ChangesSnapshot(key: "ENG-1", compare: .main, base: "b", target: "worktree",
                                 files: [ChangedFile(path: "src/caf\u{E9}.ts", status: "A", added: 1, removed: 0, patchIndex: 0),
                                         ChangedFile(path: "src/zwsp.ts", status: "A", added: 1, removed: 0, patchIndex: 1)],
                                 added: 2, removed: 0, patch: patch, truncated: false, tainted: false, taintReason: nil, lastEdit: nil, patchHash: "h",
                                 computedAt: cw.w.now, sectionPaths: [combining, zwsp], sectionHunks: DiffAnchoring.spans(in: patch))
        #expect(ChangesTabModel.verify(parsed, against: ok) == nil)
        let rows = ChangesFiles.rows(ok, diff: parsed)
        #expect(rows.map(\.fileIndex) == [0, 1] && parsed.files[1].hunks[0].lines.first?.text == "two")
        var bad = ok
        bad.sectionPaths = [zwsp, combining]
        #expect(ChangesTabModel.verify(parsed, against: bad) == ChangesTabModel.unverifiedText)
        // A CRLF patch glued the old way (one Character "\r\n") still parses to the same sections on both sides.
        let glued = DiffPresentationTests.file("w.txt", ["-a\r", "+b\r"]) + DiffPresentationTests.file("z.txt", ["+z"])
        #expect(DiffModel.parse(patch: glued).files.map(\.path) == ChangesPatch.parse(glued).map(\.path))
        #expect(DiffModel.parse(patch: glued).files[0].hunks[0].lines.map(\.text) == ["a", "b"])
        m.stop()
    }

    // MARK: Fix round 3 (R2-1, R2-2)

    /// R2-1: every diff line is classified by its FIRST UNICODE SCALAR on both sides (`ChangesPatch.marker`): a line that starts
    /// with a combining mark, a ZWJ or a variation selector is still an add/del, so the engine's numbers, its relocation, the
    /// holder's quote row and the app's markers all name the same line; the snapshot's per-hunk spans make any remaining
    /// divergence refuse to render.
    @Test func scalarClassificationAgrees() throws {
        #expect(ChangesPatch.marker("+\u{301}x") == .add && ChangesPatch.marker("-\u{200D}y") == .del && ChangesPatch.marker(" \u{FE0F}z") == .context)
        #expect(ChangesPatch.marker("\\\u{301} No newline at end of file") == .note && ChangesPatch.marker("@@ -1 +1 @@") == .hunkHeader)
        #expect(ChangesPatch.marker("") == .other && ChangesPatch.marker("x") == .other && ChangesPatch.marker("@x") == .other)
        let header = "@@ -10,7 +10,8 @@"
        let body = [" a", "+\u{301}x", "-\u{200D}y", "+\u{FE0F}z", " \u{20E3}k", "-\u{308}w", "+\u{E0100}v", " b", "-old target", "+new target", " tail"]
        let patch = DiffPresentationTests.file("src/m.ts", body, header: header)
        let engine = DiffAnchoring.hunks(in: patch, sectionIndex: 0)
        let app = DiffModel.parse(patch: patch)
        try #require(engine.count == 1 && app.files.count == 1 && app.files[0].hunks.count == 1)
        let shown = engine[0].numbered.filter { $0.old != nil || $0.new != nil }
        let lines = app.files[0].hunks[0].lines
        #expect(shown.map { [$0.old, $0.new] } == lines.map { [$0.oldNo, $0.newNo] }, "\(shown.map { ($0.old, $0.new) })")
        #expect(shown.map(\.text) == lines.map(\.text))
        #expect(lines.first { $0.text == "new target" }?.newNo == 16 && lines.first { $0.text == "old target" }?.oldNo == 15)
        // The holder's quote is centred on the engine's row for the anchored number: the commented line itself.
        let at = try #require(engine[0].numbered.firstIndex { $0.new == 16 })
        #expect(engine[0].lines[at] == "+new target")
        let atOld = try #require(engine[0].numbered.firstIndex { $0.old == 15 })
        #expect(engine[0].lines[atOld] == "-old target")
        // Markers: the engine relocates the comment to the number the app shows the same text at.
        func comment(_ side: String, _ line: Int, _ text: String) -> DiffComment {
            DiffComment(id: UUID().uuidString, companyId: "c", itemId: "i", kind: DiffComment.comment, path: "src/m.ts", side: side, line: line,
                        lineHash: StableHash.fnv1a64(text), hunkHeader: header, compare: "ENG-1:diff@worktree", baseSha: nil, text: "look",
                        eventId: nil, createdAt: .now, resolvedAt: nil)
        }
        for (side, line, text) in [("new", 16, "new target"), ("old", 15, "old target"), ("new", 11, "\u{301}x"), ("old", 11, "\u{200D}y")] {
            let relocated = DiffAnchoring.relocate(comment(side, line, text), in: patch, sectionIndex: 0)
            #expect(relocated == line, "\(side) \(text)")
            #expect(ChangesTabModel.anchor(in: app.files[0], path: "src/m.ts", side: side, line: try #require(relocated))?.lineText == text)
        }
        // The engine's per-hunk spans agree with the app's parse; a forced divergence (count or classification) is refused.
        let spans = DiffAnchoring.spans(in: patch)
        #expect(spans == [[HunkSpan(old: 7, new: 8, shown: 11)]] && ChangesTabModel.spans(app) == spans)
        let snapshot = ChangesSnapshot(key: "ENG-1", compare: .main, base: "b", target: "worktree",
                                       files: [ChangedFile(path: "src/m.ts", status: "M", added: 4, removed: 3, patchIndex: 0)],
                                       added: 4, removed: 3, patch: patch, truncated: false, tainted: false, taintReason: nil, lastEdit: nil,
                                       patchHash: "h", computedAt: .now, sectionPaths: ["src/m.ts"], sectionHunks: spans)
        #expect(ChangesTabModel.verify(app, against: snapshot) == nil)
        var diverged = app
        diverged.files[0].hunks[0].lines[1] = DiffLine(kind: .ctx, text: "\u{301}x", oldNo: 11, newNo: 11)   // the old Character reading
        #expect(ChangesTabModel.verify(diverged, against: snapshot) == ChangesTabModel.unverifiedText)
        for forged in [[[HunkSpan(old: 7, new: 8, shown: 12)]], [[HunkSpan(old: 8, new: 9, shown: 11)]], [spans[0] + spans[0]], []] {
            var s = snapshot
            s.sectionHunks = forged
            #expect(ChangesTabModel.verify(app, against: s) == ChangesTabModel.unverifiedText, "\(forged)")
        }
        // {add, del} and {ctx, unnumbered} have the same old/new counts; the shown count tells them apart.
        #expect(HunkSpan(old: 1, new: 1, shown: 2) != HunkSpan(old: 1, new: 1, shown: 1))
    }

    /// R2-2: the board loop holds the model only around its reload, never across its sleep: a running model dropped without
    /// `stop()` is freed long before the next `boardInterval`.
    @Test func droppedModelIsFreedDuringBoardSleep() async throws {
        let cw = try ChangesWorld()
        weak var dropped: ChangesTabModel?
        do {
            let (m, _) = try cw.model()
            dropped = m
            m.start()
            try await eventually { m.boardLoads >= 1 }
        }
        #expect(ChangesTabModel.boardInterval >= .seconds(10))
        try await eventually(timeout: .seconds(4)) { dropped == nil }
    }
}
