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
}
