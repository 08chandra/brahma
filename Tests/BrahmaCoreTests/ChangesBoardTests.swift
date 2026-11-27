import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Plan C Task C5b: `Store.changesBoard` — every active lease with a worktree, scoped per reader, sorted by last edit.
@Suite(.scratch) struct ChangesBoardTests {
    struct Board {
        let f: ChangesFixture
        let eng2: Agent
        let eng2Item: WorkItem, eng3Item: WorkItem
        let wt2: URL, wt3: URL

        init(titles: (String, String) = ("Cart", "Search")) throws {
            f = try ChangesFixture()
            eng2 = try f.store.hire(companyId: f.c.id, name: "eng-2", role: "engineer", model: "sonnet", managerId: f.fx.cto.id)
            eng2Item = try f.store.createWorkItem(companyId: f.c.id, by: .owner, draft: WorkItemDraft(type: .task, title: titles.0))
            eng3Item = try f.store.createWorkItem(companyId: f.c.id, by: .owner, draft: WorkItemDraft(type: .task, title: titles.1))
            #expect(eng2Item.key == "ENG-2" && eng3Item.key == "ENG-3")
            // Leases as the engine records them (a claim needs a check script; the board only needs the rows).
            let (cId, now) = (f.c.id, f.cf.now)
            let holders = [(eng2Item.id, eng2.id), (eng3Item.id, f.fx.eng3.id)]
            try f.store.writer.write { db in
                for (itemId, agentId) in holders {
                    try db.execute(sql: "UPDATE workItem SET status = 'inProgress', ownerId = ? WHERE id = ?", arguments: [agentId, itemId])
                    try WorkLease(itemId: itemId, companyId: cId, agentId: agentId, acquiredAt: now, expiresActive: 1e12).insert(db)
                }
            }
            wt2 = try f.fx.git.ws.addWorktree(key: "ENG-2")
            wt3 = try f.fx.git.ws.addWorktree(key: "ENG-3")
            try f.fx.git.write("src/cart.ts", "cart\n", in: wt2)
            try f.fx.git.write("src/a.ts", "one\nsearch\n", in: wt3)
        }

        func rows(_ reader: Reader) throws -> [BoardRow] {
            try f.store.changesBoard(companyId: f.c.id, reader: reader, knownValues: [], now: f.cf.now)
        }

        func touch(_ url: URL, _ date: Date) throws {
            try FileManager.default.setAttributes([.modificationDate: date], ofItemAtPath: url.path)
        }
    }

    @Test func boardScopeFiltering() throws {
        let b = try Board()
        #expect(try b.rows(.owner).map(\.key).sorted() == ["ENG-1", "ENG-2", "ENG-3"])
        #expect(try b.rows(.concierge).map(\.key).sorted() == ["ENG-1", "ENG-2", "ENG-3"])
        #expect(try b.rows(.agent(b.f.fx.eng1.id)).map(\.key) == ["ENG-1"])
        #expect(try b.rows(.agent(b.f.fx.qa2.id)).map(\.key) == ["ENG-1"])
        #expect(try b.rows(.agent(b.eng2.id)).map(\.key) == ["ENG-2"])
        #expect(try b.rows(.agent(b.f.eng7.id)).isEmpty)
        // An agent of another company sees nothing of this one.
        let outsider = try b.f.store.hire(companyId: b.f.fx.d.id, name: "d-eng", role: "engineer", model: "sonnet")
        #expect(try b.rows(.agent(outsider.id)).isEmpty)
        // A lease without a worktree in place is not a row.
        try b.f.fx.git.git(["worktree", "remove", "--force", b.wt3.path])
        #expect(try b.rows(.owner).map(\.key).sorted() == ["ENG-1", "ENG-2"])
    }

    @Test func boardRowFields() throws {
        let b = try Board()
        let now = b.f.cf.now
        try b.touch(b.f.wt.appending(path: "src/a.ts"), now.addingTimeInterval(-300))
        try b.touch(b.f.wt.appending(path: "src/b.ts"), now.addingTimeInterval(-250))
        try b.touch(b.f.wt.appending(path: "Sources/App.swift"), now.addingTimeInterval(-200))
        try b.touch(b.wt2.appending(path: "src/cart.ts"), now.addingTimeInterval(-100))
        try b.touch(b.wt3.appending(path: "src/a.ts"), now.addingTimeInterval(-400))
        try b.f.addRun(commit: try b.f.fx.head("item/ENG-2"), status: .running, at: now, item: b.eng2Item)
        let rows = try b.rows(.owner)
        #expect(rows.map(\.key) == ["ENG-2", "ENG-1", "ENG-3"], "sorted by last edit, newest first")
        let eng1 = try #require(rows.first { $0.key == "ENG-1" })
        #expect(eng1.title == "Checkout" && eng1.agent == "eng-1" && eng1.reviewer == "qa-2")
        #expect(eng1.files == 3 && eng1.added == 5 && eng1.removed == 3, "\(eng1)")   // vs main: a.ts +4/-1, b.ts +1, App.swift -2
        #expect(eng1.lastEdit.map { abs($0.timeIntervalSince(now.addingTimeInterval(-200))) < 1 } == true)
        #expect(eng1.checkStatus == "failed" && !eng1.tainted)
        let eng2 = try #require(rows.first { $0.key == "ENG-2" })
        #expect(eng2.files == 1 && eng2.added == 1 && eng2.removed == 0 && eng2.checkStatus == "running" && eng2.reviewer == nil)
        #expect(eng2.agentState == (try b.f.store.agent(id: b.eng2.id))?.state.rawValue)
        let eng3 = try #require(rows.first { $0.key == "ENG-3" })
        #expect(eng3.checkStatus == "none" && eng3.agent == "eng-3")
        // Tainted holder session: the row says so.
        try b.f.store.markTainted(agentId: b.eng2.id, source: "docs.swift.org")
        #expect(try b.rows(.owner).first { $0.key == "ENG-2" }?.tainted == true)
    }

    @Test func boardTitlesSanitized() throws {
        let b = try Board(titles: ("Cart \u{202E}evil\u{202C}\nline two", "Search [1](http://x)"))
        let rows = try b.rows(.owner)
        let cart = try #require(rows.first { $0.key == "ENG-2" })
        #expect(cart.title == "Cart evil line two")
        #expect(!cart.title.unicodeScalars.contains { RefText.isHidden($0.value) })
        // A title holding a stored value is withheld whole.
        let secret = TestSecrets.stripe
        let (cId, key) = (b.f.c.id, "ENG-3")
        try b.f.store.writer.write { db in try db.execute(sql: "UPDATE workItem SET title = ? WHERE companyId = ? AND key = ?", arguments: ["Search \(secret)", cId, key]) }
        let gated = try b.f.store.changesBoard(companyId: cId, reader: .owner, knownValues: [(name: "K", value: secret)], now: b.f.cf.now)
        let row = try #require(gated.first { $0.key == "ENG-3" })
        #expect(row.title == "ENG-3" && !row.title.contains(secret))
    }
}
