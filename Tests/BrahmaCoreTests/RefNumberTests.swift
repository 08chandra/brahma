import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// C3b fix round 3. Ruling 50: every ref number (F-, AR-, A-, mem:, items, releases, sprints, grants, merges) comes from a
/// per-company monotonic counter, never reused after a discard, sweep or purge; a removed number reads "that file was removed"
/// to the owner, never as another file. Ruling 51: a share in progress holds a lease on what it made, so no sweep takes its
/// copies however long it runs; a dead share's lease expires and the sweep takes them then.
@Suite(.scratch) struct RefNumberTests {
    struct W {
        let cf: CollabFixture
        var store: Store { cf.store }
        var fx: RefFixture { cf.fx }
        var c: Company { cf.c }

        init() throws { cf = try CollabFixture() }

        /// A share copy as `snapshotPrivateFile` makes one, at `now`.
        func copy(_ text: String, now: Date? = nil) throws -> Int {
            try store.vaultShareCopy(companyId: c.id, data: Data(text.utf8), fileName: "x.txt", sourceDetail: "x.txt",
                                     scope: .agent(fx.eng1.id), readerSet: [fx.eng1.id], futureHolders: false,
                                     provenance: .agent(fx.eng1.id), taint: nil, secretScan: .none, paths: cf.paths, now: now ?? cf.now)
        }

        func ownerOpen(_ ref: String) throws -> String {
            try store.openRef(companyId: c.id, reader: .owner, ref: ref, lines: nil, copy: false, turnId: nil, context: fx.ctx,
                              knownValues: [], paths: cf.paths, now: cf.now).text
        }

        func shareCopies() throws -> [Resource] {
            try store.writer.read { db in
                try Resource.fetchAll(db, sql: "SELECT * FROM resource WHERE companyId = ? AND addedVia = 'share'", arguments: [c.id])
            }
        }
    }

    // MARK: Ruling 50

    @Test func discardedNumberNeverReused() throws {
        let w = try W()
        let first = try w.copy("first")
        w.store.discardShareArtifacts(companyId: w.c.id, [.resource(first)], paths: w.cf.paths, now: w.cf.now)
        #expect(try w.store.resource(companyId: w.c.id, number: first) == nil)
        let second = try w.copy("second")
        #expect(second == first + 1, "F-\(first) was handed out again")
        #expect(try w.ownerOpen("F-\(first)") == Store.removedText)
        #expect(w.cf.failure { try w.cf.open(.eng1, "F-\(first)") } == "that ref isn't available to you")
        #expect(try w.ownerOpen("F-\(second)").contains("second"))
    }

    @Test func sweptNumberNeverReused() throws {
        let w = try W()
        let old = w.cf.now.addingTimeInterval(-2 * ShareLimits.orphanGrace)
        let orphan = try w.copy("orphan", now: old)
        #expect(try w.store.sweepShareOrphans(companyId: w.c.id, paths: w.cf.paths, now: w.cf.now) == 1)
        #expect(try w.copy("next") == orphan + 1)
        #expect(try w.ownerOpen("F-\(orphan)") == Store.removedText)
    }

    @Test func purgedNumberNeverReused() throws {
        let w = try W()
        let n = try w.copy("purge me")
        _ = try w.store.purgeResource(companyId: w.c.id, number: n, backups: [], contentVault: ContentVault(paths: w.cf.paths), paths: w.cf.paths)
        #expect(try w.copy("after") == n + 1)
        #expect(try w.ownerOpen("F-\(n)") != Store.removedText, "a purge keeps its tombstone")
    }

    @Test func otherRefNumbersNeverReused() throws {
        let w = try W()
        let cId = w.c.id
        // Items: the highest goes (as any row could), the next is still one past it.
        let item = try w.store.createWorkItem(companyId: cId, by: .owner, draft: WorkItemDraft(type: .task, title: "Gone"))
        try w.store.writer.write { db in try db.execute(sql: "DELETE FROM workItem WHERE id = ?", arguments: [item.id]) }
        let next = try w.store.createWorkItem(companyId: cId, by: .owner, draft: WorkItemDraft(type: .task, title: "Next"))
        #expect(next.number == item.number + 1)
        // Asks too (A-5 is the fixture's highest): A-6 is taken, then every ask row goes; the next is still A-7.
        let six = try w.store.writer.write { db in try Store.nextAskNumber(db: db, companyId: cId) }
        #expect(six == 6)
        try w.store.writer.write { db in try db.execute(sql: "DELETE FROM ask WHERE companyId = ?", arguments: [cId]) }
        let seven = try w.store.writer.write { db in try Store.nextAskNumber(db: db, companyId: cId) }
        #expect(seven == 7)
        // The counter only moves forward, whatever floor a caller passes.
        let again = try w.store.writer.write { db in try Store.nextRefNumber(db: db, companyId: cId, kind: .ask, floor: 2) }
        #expect(again == 8)
    }

    // MARK: Ruling 51

    @Test func slowShareKeepsItsCopy() throws {
        let w = try W()
        let store = w.store, cId = w.c.id, paths = w.cf.paths
        // While the share runs, a sweep comes from far past the grace (but within the share's lease).
        store.refHooks.setAfterSharePrepared {
            _ = try store.sweepShareOrphans(companyId: cId, paths: paths, now: Store.now().addingTimeInterval(2 * ShareLimits.orphanGrace))
        }
        defer { store.refHooks.setAfterSharePrepared(nil) }
        let reply = try store.share(companyId: cId, by: w.fx.eng1.id, refs: [".brahma/labs/eng-1/mine.txt"], to: "@qa-2", note: nil,
                                    replyTo: nil, context: w.fx.ctx, knownValues: [], paths: paths, now: w.cf.now)
        let copy = try #require(try w.shareCopies().first)
        #expect(reply == "Shared F-\(copy.number) with @qa-2.")
        #expect(try w.cf.open(.qa2, "F-\(copy.number)").text.contains("eng lab"))
        // The lease is gone once the share is done.
        #expect(try store.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM shareLease") } == 0)
    }

    @Test func deadShareCopySweptAfterLeaseExpires() throws {
        let w = try W()
        let now = Store.now()
        let lease = try w.store.beginShareLease(companyId: w.c.id, now: now)
        let n = try w.copy("in flight", now: now)
        try w.store.leaseShareArtifact(lease, companyId: w.c.id, .resource(n))
        // Past the grace but within the lease: kept.
        _ = try w.store.sweepShareOrphans(companyId: w.c.id, paths: w.cf.paths, now: now.addingTimeInterval(2 * ShareLimits.orphanGrace))
        #expect(try w.store.resource(companyId: w.c.id, number: n) != nil)
        // The share's process died: its lease expires, and the next sweep takes the copy (and the lease).
        _ = try w.store.sweepShareOrphans(companyId: w.c.id, paths: w.cf.paths, now: now.addingTimeInterval(ShareLimits.leaseExpiry + 1))
        #expect(try w.store.resource(companyId: w.c.id, number: n) == nil)
        #expect(try w.store.writer.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM shareLease") } == 0)
    }

    // MARK: Fix round 4

    /// N3-2: an upgrade seeds every counter from the numbers the company already used: its rows, and the refs, reads and
    /// purges that name a number whose row is gone. A number deleted before its kind's first allocation after the upgrade is
    /// never handed out again.
    @Test func upgradeSeedsCountersFromExistingNumbers() throws {
        let root = try tempDir()
        let path = root.appending(path: "old.sqlite").path
        let pool = try DatabasePool(path: path)
        try Migrations.migrator().migrate(pool, upTo: "vC-gate-requests")   // the schema before Ruling 50
        let at = "2026-01-01 00:00:00.000"
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            for c in ["c1", "c2"] {
                try db.execute(sql: """
                    INSERT INTO company (id, name, slug, goal, workspacePath, status, usageMode, priorityWeight, createdAt)
                    VALUES (?, ?, ?, 'g', '/tmp/x', 'running', 'balanced', 1, ?)
                    """, arguments: [c, c, c, at])
            }
            func resource(_ c: String, _ n: Int) throws {
                try db.execute(sql: """
                    INSERT INTO resource (id, companyId, number, kind, displayName, scopeKind, provenance, tainted, addedVia, createdAt, updatedAt)
                    VALUES (?, ?, ?, 'file', 'x.txt', 'company', 'owner', 0, 'library', ?, ?)
                    """, arguments: ["\(c)-r\(n)", c, n, at, at])
            }
            func ask(_ c: String, _ n: Int) throws {
                try db.execute(sql: """
                    INSERT INTO ask (id, companyId, number, kind, risk, requesterId, title, status, createdAt, updatedAt)
                    VALUES (?, ?, ?, 'approval', 'low', 'a1', 't', 'open', ?, ?)
                    """, arguments: ["\(c)-a\(n)", c, n, at, at])
            }
            // c1: F-1…F-7 and A-1…A-5, all still there at the upgrade.
            for n in 1...7 { try resource("c1", n) }
            for n in 1...5 { try ask("c1", n) }
            // c2: F-1…F-3; F-9 and A-4 were deleted before the upgrade, and only a read and a message's ref still name them.
            for n in 1...3 { try resource("c2", n) }
            try db.execute(sql: """
                INSERT INTO refRead (id, companyId, readerKind, readerId, canonical, tainted, via, createdAt)
                VALUES ('rr1', 'c2', 'owner', NULL, 'F-9', 0, 'open_ref', ?), ('rr2', 'c2', 'owner', NULL, 'A-4', 0, 'open_ref', ?)
                """, arguments: [at, at])
            try db.execute(sql: "INSERT INTO channel (id, companyId, name, kind, createdAt) VALUES ('ch1', 'c2', 'general', 'channel', ?)",
                           arguments: [at])
            try db.execute(sql: "INSERT INTO message (id, companyId, channelId, senderId, text, createdAt) VALUES ('m1', 'c2', 'ch1', 'owner', 'F-9', ?)",
                           arguments: [at])
            try db.execute(sql: """
                INSERT INTO messageRef (id, companyId, messageId, position, canonical, kind, refId, accessKind, createdAt)
                VALUES ('mr1', 'c2', 'm1', 0, 'F-9', 'resource', '9', 'company', ?)
                """, arguments: [at])
        }
        try pool.close()

        let store = try Store(path: path)
        let paths = BrahmaPaths(home: root.appending(path: "home"), workspaces: root.appending(path: "ws"))
        func copy(_ c: String) throws -> Int {
            try store.vaultShareCopy(companyId: c, data: Data("x\n".utf8), fileName: "x.txt", sourceDetail: "x.txt", scope: .company,
                                     readerSet: nil, futureHolders: false, provenance: .owner, taint: nil, secretScan: .none, paths: paths,
                                     now: Store.now())
        }
        func nextAsk(_ c: String) throws -> Int { try store.writer.write { db in try Store.nextAskNumber(db: db, companyId: c) } }
        // After the upgrade, F-7 and A-5 go (as a sweep or a discard takes a row) before either kind's first allocation.
        try store.writer.write { db in
            try db.execute(sql: "DELETE FROM resource WHERE companyId = 'c1' AND number = 7")
            try db.execute(sql: "DELETE FROM ask WHERE companyId = 'c1' AND number = 5")
        }
        #expect(try copy("c1") == 8, "F-7 was handed out again")
        #expect(try nextAsk("c1") == 6, "A-5 was handed out again")
        #expect(try copy("c2") == 10, "F-9 was handed out again")
        #expect(try nextAsk("c2") == 5, "A-4 was handed out again")
        // The counters moved on from their seeds.
        let counters = try store.writer.read { db in
            try Row.fetchAll(db, sql: "SELECT companyId, kind, last FROM refCounter WHERE kind IN ('resource', 'ask') ORDER BY companyId, kind")
                .map { "\($0["companyId"] as String) \($0["kind"] as String) \($0["last"] as Int)" }
        }
        #expect(counters == ["c1 ask 6", "c1 resource 8", "c2 ask 5", "c2 resource 10"])
        try store.close()
    }

    /// N3-2 (belt and braces): the allocator itself never hands out a number at or below one a row of its kind holds, whatever
    /// the counter says and whatever floor the caller passes.
    @Test func allocatorStaysAboveEveryRow() throws {
        let w = try W()
        let cId = w.c.id
        try w.cf.addResource(40, name: "forty.md", ext: "md", bytes: nil)
        let item = try w.store.createWorkItem(companyId: cId, by: .owner, draft: WorkItemDraft(type: .task, title: "Kept"))
        // A counter that lags its rows (or has no row at all).
        try w.store.writer.write { db in try db.execute(sql: "DELETE FROM refCounter WHERE companyId = ?", arguments: [cId]) }
        let numbers = try w.store.writer.write { db in
            (try Store.nextRefNumber(db: db, companyId: cId, kind: .resource, floor: 0),
             try Store.nextRefNumber(db: db, companyId: cId, kind: .item, floor: 0),
             try Store.nextRefNumber(db: db, companyId: cId, kind: .ask, floor: 0))
        }
        #expect(numbers.0 == 41)
        #expect(numbers.1 == item.number + 1)
        #expect(numbers.2 == 6, "A-5 is the fixture's highest ask")
        #expect(try w.store.writer.read { db in try Store.peekRefNumber(db: db, companyId: cId, kind: .resource, floor: 0) } == 42)
    }

    /// N3-1: a copy or snapshot is recorded for removal before it is leased, so a lease write that fails still leaves nothing
    /// (no copy, snapshot, share ref, lease or message), and the share is refused.
    @Test func leaseFailureLeavesNothing() throws {
        let w = try W()
        try w.cf.hold(); try w.cf.review()
        let store = w.store, cId = w.c.id
        _ = try store.createChannel(companyId: cId, name: "team", members: [w.fx.cto.id, w.fx.eng1.id, w.fx.qa2.id])
        func share(_ refs: [String], to: String = "@qa-2") -> String? {
            do {
                _ = try store.share(companyId: cId, by: w.fx.eng1.id, refs: refs, to: to, note: nil, replyTo: nil, context: w.fx.ctx,
                                    knownValues: [], paths: w.cf.paths, now: w.cf.now)
                return nil
            } catch let e as WorkError { return e.message } catch { return "\(error)" }
        }
        func nothingLeft(_ label: String) throws {
            #expect(try w.shareCopies().isEmpty, "\(label): a share copy stayed")
            let counts = try store.writer.read { db in
                (try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM refSnapshot WHERE companyId = ?", arguments: [cId]) ?? -1,
                 try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM shareLease") ?? -1,
                 try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM shareLeaseItem") ?? -1,
                 try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM message WHERE companyId = ? AND kind = 'share'", arguments: [cId]) ?? -1)
            }
            #expect(counts.0 == 0, "\(label): a diff snapshot stayed")
            #expect(counts.1 == 0 && counts.2 == 0, "\(label): a lease stayed")
            #expect(counts.3 == 0, "\(label): the share was posted")
            #expect(try w.fx.git.git(["for-each-ref", "refs/brahma/shares/"]).isEmpty, "\(label): a share ref stayed")
        }
        let wt = try w.fx.git.ws.addWorktree(key: "ENG-1")
        // A secret pattern: the worktree file is shared as a redacted company copy.
        try w.fx.git.write("src/a.ts", "one\nkey = \(SecretGateTests.aws)\n", in: wt)
        defer { store.refHooks.setFailLeaseKinds([]) }

        // A private snapshot, and a worktree file's redacted copy: the copy exists when its lease write fails.
        store.refHooks.setFailLeaseKinds(["resource"])
        #expect(share([".brahma/labs/eng-1/mine.txt"]) == Store.refUnavailable)
        try nothingLeft("private snapshot")
        #expect(share(["ENG-1:src/a.ts@worktree"]) == Store.refUnavailable)
        try nothingLeft("worktree copy")
        #expect(share(["src/a.ts", ".brahma/labs/eng-1/mine.txt"], to: "#team") == "ref 2 isn't available to you")
        try nothingLeft("second ref's snapshot")
        // A worktree diff's vault snapshot.
        store.refHooks.setFailLeaseKinds(["snapshot"])
        #expect(share(["ENG-1:diff@worktree"]) == Store.refUnavailable)
        try nothingLeft("diff snapshot")

        // With the lease working, the same shares go.
        store.refHooks.setFailLeaseKinds([])
        #expect(share([".brahma/labs/eng-1/mine.txt"]) == nil)
        #expect(share(["ENG-1:diff@worktree"]) == nil)
        #expect(try w.shareCopies().count == 1)
    }
}
