import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Plan C Task C1b: `Store.resolveRef` (per reader, blanked unless `.full`, engine-derived titles) and `Store.pinRef`.
@Suite(.scratch) struct RefResolverTests {
    @Test func lockedBlanksMetadata() throws {
        let fx = try RefFixture()
        let r = try fx.resolve(.eng1, try fx.ref("F-1"))
        #expect(r.visibility == .locked(approverRole: "owner"))
        #expect(r.title == "" && r.subtitle == "")
        #expect(r.bytes == nil)
        #expect(r.ref.kind == .resource && r.ref.id == "" && r.ref.params.isEmpty)
        #expect(!r.opaqueId.isEmpty)
        #expect(r.accessClass == .ownerOnly)
        #expect(r.reader == .agent(fx.eng1.id))
        // The handle is fresh each time: it says nothing about the object.
        #expect(try fx.resolve(.eng1, try fx.ref("F-1")).opaqueId != r.opaqueId)
        // The owner sees it all.
        let owner = try fx.resolve(.owner, try fx.ref("F-1"))
        #expect(owner.visibility == .full)
        #expect(owner.title == "plan.pdf")
        #expect(owner.bytes == 1200)
        #expect(owner.ref.id == "1")
        #expect(owner.accessClass == .agent(fx.cto.id))
    }

    @Test func titlesAreEngineDerived() throws {
        let fx = try RefFixture()
        let main = String(try fx.head().prefix(7))
        let file = try fx.resolve(.eng1, try fx.ref("src/checkout.tsx"))
        #expect(file.visibility == .full)
        #expect(file.title == "src/checkout.tsx")
        #expect(file.subtitle == "49 lines · TypeScript · @\(main)")
        #expect(file.ref.rev == nil)                           // resolving never pins
        let swift = try fx.resolve(.eng1, try fx.ref("Sources/App.swift"))
        #expect(swift.subtitle == "3 lines · Swift · @\(main)")
        #expect(swift.bytes == 30)
        let ranged = try fx.resolve(.eng1, try fx.ref("src/checkout.tsx:40-88"))
        #expect(ranged.title == "src/checkout.tsx:40-88")
        let diff = try fx.resolve(.eng1, try fx.ref("ENG-1:diff"))
        #expect(diff.title == "ENG-1 diff")
        #expect(diff.subtitle == "+3 \u{2212}1 in 2 files")
        let oneFile = try fx.resolve(.eng1, try fx.ref("ENG-1:diff/src/b.ts"))
        #expect(oneFile.subtitle == "+1 \u{2212}0 in 1 file")
        let item = try fx.resolve(.eng1, try fx.ref("ENG-1"))
        #expect(item.title == "ENG-1 Checkout")
        #expect(item.subtitle == "inReview · @eng-3")
        let onBranch = try fx.resolve(.eng1, try fx.ref("ENG-1:src/a.ts"))
        #expect(onBranch.subtitle.hasPrefix("3 lines · TypeScript · @"))
        let ask = try fx.resolve(.cto, try fx.ref("A-5"))
        #expect(ask.title == "A-5 Which API?")
        #expect(ask.subtitle == "pendingInternal")
        let commit = try fx.resolve(.qa2, try fx.ref("commit:\(main)"))
        #expect(commit.title == "commit \(main)")
        #expect(commit.subtitle == "+54 \u{2212}0 in 3 files")
        let agent = try fx.resolve(.qa2, try fx.ref("@eng-3"))
        #expect(agent.title == "@eng-3")
        let channel = try fx.resolve(.eng1, try fx.ref("#eng"))
        #expect(channel.title == "#eng" && channel.subtitle == "1 member")
    }

    @Test func agentTitlesSanitized() throws {
        let fx = try RefFixture()
        try fx.store.writer.write { db in
            try db.execute(sql: "UPDATE workItem SET title = ? WHERE id = ?", arguments: ["Pay\u{202E}lacoL", fx.item.id])
        }
        #expect(try fx.resolve(.eng1, try fx.ref("ENG-1")).title == "ENG-1 PaylacoL")
        try fx.store.writer.write { db in
            try db.execute(sql: "UPDATE workItem SET title = ? WHERE id = ?", arguments: [String(repeating: "y", count: 300), fx.item.id])
        }
        let long = try fx.resolve(.eng1, try fx.ref("ENG-1")).title
        #expect(long.count == SafeTitle.max && long.hasPrefix("ENG-1 yyy") && long.hasSuffix("\u{2026}"))
        // The sanitizer itself (artifact titles go through it once 4a lands).
        #expect(SafeTitle.make("Pay\u{202E}lacoL").text == "PaylacoL")
        #expect(SafeTitle.make("\u{0420}ay").confusable)
        #expect(SafeTitle.make(String(repeating: "z", count: 300)).text.count == 120)
    }

    @Test(.disabled("4a Task 6 pending: Artifact")) func artifactTitlesSanitized() throws {
        // 4a-gap: an artifact titled "Pay\u{202E}lacoL" resolves with the bidi control stripped, a Cyrillic "Рay" one as
        // confusable, and a 300-character one capped at 120.
        let fx = try RefFixture()
        let r = try fx.resolve(.owner, try fx.ref("AR-1"))
        #expect(r.visibility == .full)
    }

    @Test func artifactResolvesMissingUntil4a() throws {
        let fx = try RefFixture()
        let r = try fx.resolve(.owner, try fx.ref("AR-1"))
        #expect(r.visibility == .missing && r.title == "" && r.ref.id == "")
    }

    @Test func pinsCommittedRefs() throws {
        let fx = try RefFixture()
        let head = try fx.head()
        let pinned = try fx.store.pinRef(try fx.ref("src/a.ts"), for: .agent(fx.eng1.id), companyId: fx.c.id, messageRefId: "mr-1")
        #expect(pinned.rev == head)
        #expect(pinned.canonical == "src/a.ts@\(head)")
        #expect(WorkRef.parse(pinned.canonical, context: fx.ctx) == pinned)
        #expect(try fx.resolve(.eng1, pinned).newer == nil)
        // main moves, touching the file: the pinned ref still resolves as shared, and knows a newer one exists.
        try fx.git.write("src/a.ts", "one\nchanged\n")
        try fx.git.git(["commit", "-q", "-am", "move main"])
        let after = try fx.resolve(.eng1, pinned)
        #expect(after.visibility == .full)
        #expect(after.ref.rev == head)
        let newer = try #require(after.newer)
        #expect(newer.rev == (try fx.head()))
        // An item and the diff pin too.
        let item = try fx.store.pinRef(try fx.ref("ENG-1"), for: .owner, companyId: fx.c.id, messageRefId: "mr-2")
        #expect(item.params["was"] == "inReview")
        let diff = try fx.store.pinRef(try fx.ref("ENG-1:diff"), for: .owner, companyId: fx.c.id, messageRefId: "mr-3")
        #expect(diff.rev == (try fx.head("item/ENG-1")))
        let ask = try fx.store.pinRef(try fx.ref("A-5"), for: .owner, companyId: fx.c.id, messageRefId: "mr-4")
        #expect(ask.params["was"] == "pendingInternal")
        // A reader that can't read it can't pin (share) it.
        #expect(throws: WorkError.self) {
            try fx.store.pinRef(try fx.ref("F-1"), for: .agent(fx.eng1.id), companyId: fx.c.id, messageRefId: "mr-5")
        }
    }

    /// Live uncommitted forms read the item's worktree: files through SafeFS, the diff through `SafeGit.worktreeDiff`.
    @Test func worktreeFormsResolveLive() throws {
        let fx = try RefFixture()
        let wt = try fx.git.ws.addWorktree(key: "ENG-1")
        try fx.git.write("src/a.ts", "one\nTWO\nthree\nfour\n", in: wt)
        let file = try fx.resolve(.eng1, try fx.ref("ENG-1:src/a.ts@worktree"))
        #expect(file.visibility == .full)
        #expect(file.subtitle == "4 lines · TypeScript · UNCOMMITTED")
        let diff = try fx.resolve(.eng1, try fx.ref("ENG-1:diff@worktree"))
        #expect(diff.title == "ENG-1 diff (uncommitted)")
        #expect(diff.subtitle == "+1 \u{2212}0 in 1 file")
        #expect(try fx.resolve(.eng1, try fx.ref("ENG-1:nope.ts@worktree")).visibility == .missing)
    }

    @Test func otherAgentLabRefusedOnResolve() throws {
        let fx = try RefFixture()
        let r = try fx.resolve(.eng1, try fx.ref(".brahma/labs/qa-2/x"))
        #expect(r.visibility == .refused)
        #expect(r.title == "" && r.ref.id == "")
        let own = try fx.resolve(.eng1, try fx.ref(".brahma/labs/eng-1/mine.txt"))
        #expect(own.visibility == .full)
        #expect(own.title == ".brahma/labs/eng-1/mine.txt")
        #expect(own.bytes == 8)
        let owner = try fx.resolve(.owner, try fx.ref(".brahma/labs/qa-2/x"))
        #expect(owner.visibility == .full)
    }

    @Test func agentRevMustBeReachable() throws {
        let fx = try RefFixture()
        let dangling = try fx.git.plantCommit(parent: try fx.head(), path: "src/a.ts", text: "planted\n", message: "planted")
        let r = try fx.resolve(.eng1, try fx.ref("src/a.ts@\(dangling)"))
        #expect(r.visibility == .missing)
        #expect(r.title == "")
        // A reachable one resolves.
        let ok = try fx.resolve(.eng1, try fx.ref("src/a.ts@\(try fx.head())"))
        #expect(ok.visibility == .full)
    }
}
