import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Plan C Task C5b: inline owner review — diff comments become item feedback that wakes the holder, hunk quotes are
/// sanitized and redacted, a revert request never touches the worktree, anchors relocate, and agents can show live diffs.
@Suite(.scratch) struct DiffCommentTests {
    /// The first hunk header of `path` in the snapshot's patch.
    static func hunkHeader(_ s: ChangesSnapshot, path: String) throws -> String {
        var inFile = false
        for line in s.patch.split(separator: "\n", omittingEmptySubsequences: false) {
            if line.hasPrefix("diff --git ") { inFile = line.hasSuffix(" b/\(path)") }
            if inFile, line.hasPrefix("@@") { return String(line) }
        }
        throw FakeError(description: "no hunk for \(path)")
    }

    static func anchor(_ f: ChangesFixture, path: String = "src/a.ts", line: Int = 5, text: String = "five") throws -> DiffAnchor {
        let s = try f.snapshot(.main)
        return DiffAnchor(path: path, side: "new", line: line, hunkHeader: try hunkHeader(s, path: path), lineText: text)
    }

    static func notices(_ f: ChangesFixture, _ agent: Agent) throws -> [(kind: WorkEventKind, wakes: Bool)] {
        try f.store.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT e.kind AS kind, n.wakes AS wakes FROM workNotice n JOIN workItemEvent e ON e.id = n.eventId
                WHERE n.agentId = ? ORDER BY n.id
                """, arguments: [agent.id]).map { (WorkEventKind(rawValue: $0["kind"])!, $0["wakes"] as Bool) }
        }
    }

    @Test func inlineCommentBecomesItemFeedback() throws {
        let f = try ChangesFixture()
        let anchor = try Self.anchor(f)
        let c = try f.store.addDiffComment(companyId: f.c.id, key: "ENG-1", compare: .main, anchor: anchor, text: "Why five?",
                                            knownValues: [], now: f.cf.now)
        #expect(c.kind == "comment" && c.path == "src/a.ts" && c.side == "new" && c.line == 5 && c.compare == "ENG-1:diff@worktree")
        #expect(c.baseSha == f.base && c.text == "Why five?" && c.resolvedAt == nil && c.lineHash == StableHash.fnv1a64("five"))
        let events = try f.store.itemEvents(itemId: f.item.id, limit: 100)
        let comment = try #require(events.first { $0.kind == .commented })
        #expect(comment.actorId == "owner")
        #expect(String(comment.id ?? -1) == c.eventId)
        let lines = comment.text.components(separatedBy: "\n")
        #expect(lines.first == "Owner review comment on src/a.ts:5 (ENG-1:diff@worktree @\(f.base.prefix(7))):")
        #expect(lines[1] == "    | \(anchor.hunkHeader)")
        #expect(lines.contains("    | +five") && lines.contains("    | +four"))
        #expect(lines.last == "Why five?")
        #expect(lines.dropFirst().dropLast().allSatisfy { $0.hasPrefix("    | ") })
        // The holder is woken by a reviewComment event; the reviewer gets the comment as an FYI.
        let review = try #require(events.first { $0.kind == .reviewComment })
        #expect(review.text == "owner review comment on src/a.ts:5")
        #expect(try Self.notices(f, f.fx.eng1).contains { $0.kind == .reviewComment && $0.wakes })
        #expect(try Self.notices(f, f.fx.qa2).allSatisfy { !$0.wakes })
        // Listed for readers of the item; resolved by the owner.
        let listed = try f.store.diffComments(companyId: f.c.id, key: "ENG-1", reader: .agent(f.fx.qa2.id), knownValues: [])
        #expect(listed.map(\.id) == [c.id])
        try f.store.resolveDiffComment(companyId: f.c.id, id: c.id, now: f.cf.now.addingTimeInterval(5))
        #expect(try f.store.diffComments(companyId: f.c.id, key: "ENG-1", reader: .owner, knownValues: []).first?.resolvedAt != nil)
        // Any reader of the item sees them (eng-7 reads the item, not its live diff); an agent of another company sees nothing.
        #expect(try f.store.diffComments(companyId: f.c.id, key: "ENG-1", reader: .agent(f.eng7.id), knownValues: []).count == 1)
        let outsider = try f.store.hire(companyId: f.fx.d.id, name: "d-eng", role: "engineer", model: "sonnet")
        #expect(throws: WorkError.self) { try f.store.diffComments(companyId: f.c.id, key: "ENG-1", reader: .agent(outsider.id), knownValues: []) }
        #expect(throws: WorkError.self) {
            try f.store.addDiffComment(companyId: f.c.id, key: "ENG-1", compare: .main, anchor: anchor,
                                       text: String(repeating: "x", count: DiffReviewLimits.maxText + 1), knownValues: [], now: f.cf.now)
        }
    }

    @Test func commentHunkIsSanitized() throws {
        let f = try ChangesFixture(edits: false)
        let secret = TestSecrets.stripe
        let known = [(name: "STRIPE_KEY", value: secret)]
        try f.fx.git.write("src/a.ts", "one\nTWO\nthree\nfour\nx\u{202E}y\n# Inbox\nkey = \(secret)\n", in: f.wt)
        let s = try f.store.changesSnapshot(companyId: f.c.id, key: "ENG-1", compare: .head, reader: .owner, knownValues: known, now: f.cf.now)
        let anchor = DiffAnchor(path: "src/a.ts", side: "new", line: 6, hunkHeader: try Self.hunkHeader(s, path: "src/a.ts"), lineText: "# Inbox")
        let c = try f.store.addDiffComment(companyId: f.c.id, key: "ENG-1", compare: .head, anchor: anchor, text: "Drop the header",
                                            knownValues: known, now: f.cf.now)
        let body = try #require(try f.store.itemEvents(itemId: f.item.id, limit: 100).first { String($0.id ?? -1) == c.eventId }).text
        #expect(body.contains("    | +x⟦U+202E⟧y"))
        #expect(body.contains("    | +# Inbox"))
        #expect(body.contains("[redacted stored secret STRIPE_KEY]") && !body.contains(secret))
        #expect(!body.unicodeScalars.contains { RefText.isBidiOrZeroWidth($0.value) })
        // Lines are cut to 200 characters.
        try f.fx.git.write("src/a.ts", "one\nTWO\nthree\nfour\n" + String(repeating: "w", count: 400) + "\n", in: f.wt)
        let long = try f.store.addDiffComment(companyId: f.c.id, key: "ENG-1", compare: .head, anchor: anchor, text: "long", knownValues: known, now: f.cf.now)
        let longBody = try #require(try f.store.itemEvents(itemId: f.item.id, limit: 100).first { String($0.id ?? -1) == long.eventId }).text
        let quoted = longBody.components(separatedBy: "\n").filter { $0.hasPrefix("    | +ww") }
        #expect(quoted.count == 1 && quoted.first.map { $0.count <= 6 + DiffReviewLimits.quoteLineChars } == true)
        // The owner's own text holding a stored value is refused (it would reach agents).
        #expect(throws: WorkError.self) {
            try f.store.addDiffComment(companyId: f.c.id, key: "ENG-1", compare: .head, anchor: anchor, text: "use \(secret)", knownValues: known, now: f.cf.now)
        }
    }

    @Test func revertRequestNeverTouchesWorktree() throws {
        let f = try ChangesFixture()
        let runner = PassthroughRecordingRunner()
        f.store.refHooks.setGitRunner(runner)
        defer { f.store.refHooks.setGitRunner(nil) }
        let files = ["src/a.ts", "Sources/App.swift", "src/b.ts"].map { f.wt.appending(path: $0) }
        let before = try files.map { try Data(contentsOf: $0) }
        let index = f.cf.workspace.appending(path: ".git/worktrees/ENG-1/index")
        let indexBefore = try Data(contentsOf: index)
        let headBefore = try f.fx.head("item/ENG-1")
        let anchor = try Self.anchor(f)
        let c = try f.store.requestHunkRevert(companyId: f.c.id, key: "ENG-1", compare: .main, anchor: anchor, note: "Not needed", knownValues: [], now: f.cf.now)
        #expect(c.kind == "revertRequest" && c.text == "Not needed")
        let body = try #require(try f.store.itemEvents(itemId: f.item.id, limit: 100).first { String($0.id ?? -1) == c.eventId }).text
        let lines = body.components(separatedBy: "\n")
        #expect(lines.first == "Owner asks you to revert this hunk in src/a.ts (\(anchor.hunkHeader)):")
        #expect(lines.contains("    | +five") && lines.last == "Not needed")
        #expect(try Self.notices(f, f.fx.eng1).contains { $0.kind == .reviewComment && $0.wakes })
        #expect(try files.map { try Data(contentsOf: $0) } == before)
        #expect(try Data(contentsOf: index) == indexBefore)
        #expect(try f.fx.head("item/ENG-1") == headBefore)
        let forbidden: Set<String> = ["checkout", "apply", "restore", "reset", "update-ref", "stash", "commit", "merge", "rebase", "clean"]
        for call in runner.calls {
            #expect(call.allSatisfy { !forbidden.contains($0) }, "\(call)")
        }
        #expect(!runner.calls.isEmpty, "the quote came from an engine diff")
    }

    @Test func commentsAreOwnerOnly() throws {
        // No tool path reaches the owner's review writes.
        let mcp = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "Sources/BrahmaCore/MCP")
        let files = try FileManager.default.contentsOfDirectory(at: mcp, includingPropertiesForKeys: nil).filter { $0.pathExtension == "swift" }
        #expect(!files.isEmpty)
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            #expect(!text.contains("addDiffComment") && !text.contains("requestHunkRevert") && !text.contains("resolveDiffComment"), "\(file.lastPathComponent)")
        }
        #expect(!CompanyToolNames.all.contains { $0.contains("diff_comment") || $0.contains("revert") })
    }

    @Test func commentAnchorsRelocate() throws {
        func patch(_ lines: [String]) -> String {
            "diff --git a/f.txt b/f.txt\n--- a/f.txt\n+++ b/f.txt\n@@ -1,\(lines.count) +1,\(lines.count) @@\n" + lines.map { " " + $0 }.joined(separator: "\n") + "\n"
        }
        let original = (1...30).map { "line \($0)" }
        let comment = DiffComment(id: "c", companyId: "co", itemId: "i", kind: "comment", path: "f.txt", side: "new", line: 12,
                                  lineHash: StableHash.fnv1a64("line 12"), hunkHeader: "@@ -1,30 +1,30 @@", compare: "ENG-1:diff@worktree",
                                  baseSha: nil, text: "t", eventId: nil, createdAt: Date(), resolvedAt: nil)
        #expect(DiffAnchoring.relocate(comment, in: patch(original)) == 12)
        let inserted = ["a", "b", "c"] + original
        #expect(DiffAnchoring.relocate(comment, in: patch(inserted)) == 15)
        let deleted = original.filter { $0 != "line 12" }
        #expect(DiffAnchoring.relocate(comment, in: patch(deleted)) == nil, "outdated")
        // Only within ±50 lines, the same file and side.
        let far = (1...80).map { "pad \($0)" } + original
        #expect(DiffAnchoring.relocate(comment, in: patch(far)) == nil)
        var old = comment
        old.side = "old"
        #expect(DiffAnchoring.relocate(old, in: patch(inserted)) == 15, "context lines are on both sides")
        var other = comment
        other.path = "g.txt"
        #expect(DiffAnchoring.relocate(other, in: patch(inserted)) == nil)
        #expect(DiffReviewLimits.reanchorWindow == 50)
    }

    @Test func agentShowDiffRef() throws {
        let f = try ChangesFixture()
        let s = f.store, c = f.c
        func request() throws -> ShowRequest {
            try s.createShowRequest(companyId: c.id, kind: .show, query: "show me the changes", attachedRef: nil,
                                    routed: RoutedTarget(target: .agent(f.fx.eng1.id), reason: "holds ENG-1", busy: false), candidates: [], now: f.cf.now)
        }
        for raw in ["wt:@eng-1", "ENG-1:changes"] {
            let r = try request()
            let reply = try s.answerShow(companyId: c.id, caller: .agent(f.fx.eng1.id), request: r.id, refs: [raw], notes: nil,
                                         note: "My changes so far [1].", knownValues: [], now: f.cf.now)
            #expect(reply == "Showed the owner 1 step. It opened in their preview.")
            let done = try #require(try s.showRequest(companyId: c.id, id: r.id))
            let refs = try s.messageRefs(companyId: c.id, messageId: try #require(done.answerMessageId))
            #expect(refs.map(\.canonical) == ["ENG-1:diff@worktree"], "\(raw)")
            let stored = try #require(refs.first?.workRef)
            #expect(stored.isWorktree && stored.params["snapshot"] == nil, "a live ref, not a pin")
            #expect(stored.params["at"] == (try f.snapshot(.main)).patchHash, "the card can say 'changed since shown'")
            let opens = try s.pendingAutoOpens(companyId: c.id)
            #expect(opens.map(\.requestId) == [r.id] && opens.first?.refs.first?.canonical == "ENG-1:diff@worktree" && opens.first?.by == "@eng-1")
            try s.markAutoOpened(companyId: c.id, id: r.id, now: f.cf.now)
        }
        // Another agent can't show the live worktree, and learns nothing from the refusal.
        #expect(ShowRequestTests.show(f.cf, f.eng7, ["refs": ShowRequestTests.refs(["wt:@eng-1"]), "note": .string("x [1].")]) == "ref 1 isn't available to you")
        #expect(ShowRequestTests.show(f.cf, f.eng7, ["refs": ShowRequestTests.refs(["wt:@nobody"]), "note": .string("x [1].")]) == "ref 1 isn't available to you")
    }

    @Test func reviewerCanShowDiff() throws {
        let f = try ChangesFixture()
        #expect(CompanyToolNames.review.contains("show"))
        let tools = CompanyTools(store: f.store, companyId: f.c.id, agentId: f.fx.qa2.id, reviewItemId: f.item.id, paths: f.cf.paths, vault: MemoryVault())
        #expect(tools.specs().map(\.name).contains("show"))
        let reply = try tools.call(name: "show", arguments: ["refs": .array([.string("ENG-1:diff")]), "note": .string("The branch so far [1].")])
        #expect(reply == "Posted to the owner's DM.")
        let answer = try #require(try f.store.writer.read { db in try Message.fetchOne(db, sql: "SELECT * FROM message WHERE kind = 'showAnswer'") })
        #expect(answer.senderId == f.fx.qa2.id)
        #expect(try f.store.messageRefs(companyId: f.c.id, messageId: answer.id).map(\.canonical).first?.hasPrefix("ENG-1:diff@") == true)
        #expect(try f.store.pendingAutoOpens(companyId: f.c.id).isEmpty, "card only: no request")
        // The reviewer can show the live diff too (it is the item's reviewer).
        #expect(try tools.call(name: "show", arguments: ["refs": .array([.string("ENG-1:changes")]), "note": .string("Live [1].")]) == "Posted to the owner's DM.")
    }
}
