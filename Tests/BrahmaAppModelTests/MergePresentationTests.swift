import Foundation
import Testing
import BrahmaCore
@testable import BrahmaAppModel

/// Plan 4a Task 8b: Work › Merge queue rows, the hold banner and the owner's settings form.
@MainActor @Suite(.scratch) struct MergePresentationTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)
    static let tz = TimeZone(identifier: "UTC")!

    static func request(_ n: Int, _ status: MergeRequestStatus, item: String = "i1", _ change: (inout MergeRequest) -> Void = { _ in })
        -> MergeRequest {
        var r = MergeRequest(id: "m\(n)", companyId: "c", itemId: item, number: n, status: status, headCommit: "feedface1234567",
                             enqueuedAt: t0.addingTimeInterval(Double(n) * 60))
        change(&r)
        return r
    }

    static func snapshot(open: [MergeRequest] = [], recent: [MergeRequest] = [], hold: String? = nil) -> MergeSnapshot {
        MergeSnapshot(open: open, recent: recent, settings: MergeSettings(), mainCommit: "0123456789abcdef", hold: hold, unfinishedBatch: nil)
    }

    static let items = ["i1": "ACME-1", "i2": "ACME-2"]
    static let handles = ["a1": "eng-1", "owner": "owner"]
    static let holders = ["i1": "a1", "i2": "a1"]

    @Test func rowsOrderAndText() {
        let open = [Self.request(3, .queued), Self.request(4, .running, item: "i2") { $0.startedAt = Self.t0 }]
        let recent = [Self.request(2, .failed) { $0.failure = .engineError; $0.detail = "git failed"; $0.finishedAt = Self.t0 },
                      Self.request(1, .merged) { $0.mergedCommit = "abcdef9876543"; $0.finishedAt = Self.t0 }]
        let rows = MergeRows.make(Self.snapshot(open: open, recent: recent), itemKeys: Self.items, itemTitles: ["i1": "Do it\nnow"],
                                  holders: Self.holders, handles: Self.handles, timeZone: Self.tz)
        // Running and landing first, then the queue in order, then history newest first.
        #expect(rows.map(\.ref) == ["M-4", "M-3", "M-2", "M-1"])
        #expect(rows.map(\.statusTitle) == ["MERGING", "QUEUED", "FAILED", "MERGED"])
        #expect(rows.map(\.tone) == [.running, .ready, .warning, .success])
        #expect(rows.map(\.itemKey) == ["ACME-2", "ACME-1", "ACME-1", "ACME-1"])
        // Titles are agent-controlled: one line; an item without one reads "".
        #expect(rows.map(\.title) == ["", "Do it now", "Do it now", "Do it now"])
        #expect(rows.map(\.holder) == ["@eng-1", "@eng-1", "@eng-1", "@eng-1"])
        #expect(rows[1].position == 1 && rows[0].position == nil)
        #expect(rows.map(\.detail) == ["merging feedfac", "1st in queue", "git failed", "main at abcdef9"])
        // COMMIT: what landed, else the pinned head.
        #expect(rows.map(\.commit) == ["feedfac", "feedfac", "feedfac", "abcdef9"])
        #expect(rows.map(\.canRetry) == [false, false, true, false])
        // QUEUED: when it was enqueued (M-4 at t0 + 4 min), not when it started or finished.
        #expect(rows[0].when == "2027-01-15 08:04")
        #expect(rows.map(\.id) == ["m4", "m3", "m2", "m1"])

        // A bounce names its conflicts (agent-controlled file names, one line, at most 20); a bounce never retries from here.
        let bounced = Self.request(5, .bounced) { $0.failure = .conflict; $0.conflictFiles = ["a.swift", "b.swift"] }
        let b = MergeRows.make(Self.snapshot(recent: [bounced]), itemKeys: Self.items, holders: Self.holders, handles: Self.handles,
                               timeZone: Self.tz)[0]
        #expect(b.tone == .danger && b.detail == "conflicts in a.swift, b.swift" && !b.canRetry)
        let cancelled = Self.request(6, .cancelled)
        let c = MergeRows.make(Self.snapshot(recent: [cancelled]), itemKeys: [:], holders: [:], handles: [:], timeZone: Self.tz)[0]
        #expect(c.tone == .muted && c.itemKey == "i1" && c.holder == "—" && c.detail == "cancelled")
        // Two queued: positions 1 and 2.
        let q = MergeRows.make(Self.snapshot(open: [Self.request(7, .queued), Self.request(8, .queued)]), itemKeys: [:], holders: [:],
                               handles: [:], timeZone: Self.tz)
        #expect(q.map(\.position) == [1, 2] && q.map(\.detail) == ["1st in queue", "2nd in queue"])
    }

    @Test func settingsFormValidation() {
        var form = MergeSettingsForm(MergeSettings())
        #expect(form.batchSize == "1" && form.strategy == .ff && form.mainCheckCommand == "" && form.timeoutSeconds == "600")
        #expect(form.validate() == nil)
        #expect(form.settings == MergeSettings())
        for bad in ["0", "9", "x", ""] {
            form.batchSize = bad
            #expect(form.validate() == "Batch size must be 1–8", "\(bad)")
        }
        form.batchSize = "3"
        form.strategy = .merge
        form.mainCheckCommand = "swift test"
        for bad in ["0", "3601", "abc", "-5"] {
            form.timeoutSeconds = bad
            #expect(form.validate() == "Timeout must be 1–3600 seconds", "\(bad)")
        }
        form.timeoutSeconds = "120"
        #expect(form.validate() == nil)
        #expect(form.settings == MergeSettings(mainCheck: CheckSpec(command: "swift test", timeoutSeconds: 120), batchSize: 3, strategy: .merge))
        // A blank command clears the check, whatever the timeout field says.
        form.mainCheckCommand = "   "
        form.timeoutSeconds = "nope"
        #expect(form.validate() == nil)
        #expect(form.settings.mainCheck == nil)
        // The form round-trips a stored check.
        let stored = MergeSettings(mainCheck: CheckSpec(command: "make check", timeoutSeconds: 90), batchSize: 4, strategy: .merge)
        let f2 = MergeSettingsForm(stored)
        #expect(f2.batchSize == "4" && f2.strategy == .merge && f2.mainCheckCommand == "make check" && f2.timeoutSeconds == "90")
        #expect(f2.settings == stored)
    }

    @Test func holdShown() {
        // Held: the reason, and still `main` (8b review, Minor 10: it matters most while held).
        let held = MergeHeader.make(Self.snapshot(open: [Self.request(1, .queued)], hold: "main is red: ACME-9 is the bug"))
        #expect(held.title == "QUEUE HELD" && held.tone == .warning && held.detail == "main is red: ACME-9 is the bug · main at 0123456")
        #expect(held.canResume && held.held == "HELD: main is red: ACME-9 is the bug" && held.main == "MAIN 0123456")
        let busy = MergeHeader.make(Self.snapshot(open: [Self.request(1, .queued), Self.request(2, .running)]))
        #expect(busy.title == "2 IN QUEUE" && busy.tone == .ready && busy.detail == "main at 0123456" && !busy.canResume && busy.held == nil)
        let idle = MergeHeader.make(Self.snapshot())
        #expect(idle.title == "QUEUE IDLE" && idle.tone == .muted && idle.detail == "main at 0123456")
        // The settings chips: defaults, then the owner's.
        #expect(idle.main == "MAIN 0123456" && idle.batch == "BATCH 1" && idle.strategy == "Rebase + fast-forward"
                && idle.mainCheck == "MAIN CHECK NONE" && idle.unfinishedBatch == nil)
        var configured = Self.snapshot()
        configured.settings = MergeSettings(mainCheck: CheckSpec(command: "test -f index.html\n"), batchSize: 4, strategy: .merge)
        let c = MergeHeader.make(configured)
        #expect(c.batch == "BATCH 4" && c.strategy == "Rebase + merge commit" && c.mainCheck == "MAIN CHECK test -f index.html ")
        var noMain = Self.snapshot()
        noMain.mainCommit = nil
        #expect(MergeHeader.make(noMain).detail == "no main yet" && MergeHeader.make(noMain).main == "MAIN —")
        // An unfinished batch is named: the engine resumes it from the journal; held or not.
        var resuming = Self.snapshot(open: [Self.request(1, .landing)])
        resuming.unfinishedBatch = MergeBatch(companyId: "c", number: 7, step: .landing, requestIds: ["m1"], startedAt: Self.t0)
        let r = MergeHeader.make(resuming)
        #expect(r.title == "1 IN QUEUE" && r.detail == "batch #7 at landing · main at 0123456" && r.unfinishedBatch == "BATCH AT LANDING")
        resuming.hold = "stopped by the owner"
        let heldResuming = MergeHeader.make(resuming)
        #expect(heldResuming.detail == "stopped by the owner · batch #7 at landing · main at 0123456" && heldResuming.unfinishedBatch == "BATCH AT LANDING")
    }

    @Test func itemMergeDetailLines() {
        // Nothing yet: every line is a dash and there is no chip.
        let none = ItemMergeDetail()
        #expect(none.branchLine == "—" && none.aheadBehind == "—" && none.diffLine == "—" && none.verifiedLine == "—")
        #expect(none.statusTitle == nil && none.tone == nil && none.mergeLine == nil && none.failureTail == nil)
        // A branch ahead of main with a verified head, queued second.
        var d = ItemMergeDetail(branch: BranchInfo(branch: "item/ACME-1", ahead: 2, behind: 1, diff: DiffStat(files: 1, insertions: 10, deletions: 2),
                                                   head: "feedface1234567"),
                                verifiedCommit: "feedface1234567", request: Self.request(3, .queued), position: 2)
        #expect(d.branchLine == "item/ACME-1 @feedfac" && d.aheadBehind == "2 / 1" && d.diffLine == "1 file +10 −2" && d.verifiedLine == "feedfac")
        #expect(d.statusTitle == "QUEUED" && d.tone == .ready && d.mergeLine == "2nd in queue" && d.failureTail == nil)
        // Landed: the branch is gone and the request reads MERGED (Done means merged).
        d.branch = BranchInfo(branch: "item/ACME-1")
        d.request = Self.request(3, .merged) { $0.mergedCommit = "abcdef9876543" }
        d.position = nil
        #expect(d.branchLine == "item/ACME-1 (gone)" && d.aheadBehind == "—" && d.diffLine == "—")
        #expect(d.statusTitle == "MERGED" && d.tone == .success && d.mergeLine == "main at abcdef9")
        // A failed check shows its redacted tail; a conflict shows its files on the line and no tail.
        d.request = Self.request(4, .bounced) { $0.failure = .itemCheckFailed; $0.detail = "item check failed"; $0.outputTail = "FAIL: 1 test" }
        #expect(d.tone == .danger && d.mergeLine == "item check failed" && d.failureTail == "FAIL: 1 test")
        d.request = Self.request(5, .bounced) { $0.failure = .conflict; $0.conflictFiles = ["a.swift"]; $0.outputTail = "noise" }
        #expect(d.mergeLine == "conflicts in a.swift" && d.failureTail == nil)
    }
}
