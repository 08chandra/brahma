import Foundation
import Testing
import GRDB
@testable import BrahmaCore

/// The landing audit's classification (Plan X6a Task 6), pure: a first-parent commit list (newest first, as `rev-list
/// --first-parent` gives it) classified against the store's records (`LandingAudit.records`), no git. The records come from
/// `MeasureFixtures`, whose made-up shas stand in for commits.
@Suite(.scratch) struct LandingClassificationTests {
    let t0 = MeasureFixtures.t0

    /// A store, a company and `count` items.
    func rig(items count: Int) throws -> (Store, Company, [WorkItem]) {
        let store = try Store.inMemory()
        let company = try MeasureFixtures.company(store, name: "Acme")
        return (store, company, try MeasureFixtures.items(store, company: company, count: count))
    }

    /// A made-up commit id whose first seven digits are `n` (owner accept records name a commit by its first seven).
    func sha(_ n: Int) -> String { String(format: "%07x", n) + String(repeating: "a", count: 33) }

    func records(_ store: Store, _ company: Company, since: Date? = nil) throws -> LandingRecords {
        try LandingAudit.records(store: store, companyId: company.id, since: since)
    }

    /// Every intermediate candidate of a three-item batch is verified (4a fast-forwards `main` through each of them), and the
    /// root of first-parent history is the company's first commit (no `importedCommit`): imported.
    @Test func batchOfThreeAllVerified() throws {
        let (store, company, items) = try rig(items: 3)
        let root = sha(1)
        let (batch, _) = try MeasureFixtures.land(store, company: company, items: items, number: 1, enqueuedAt: t0, landedAt: t0,
                                                  commits: [sha(11), sha(12), sha(13)], base: root)
        try MeasureFixtures.mergeRun(store, company: company, batch: batch, kind: .item, finishedAt: t0)
        let r = LandingAudit.classify(walk: [sha(13), sha(12), sha(11), root], records: try records(store, company))
        #expect(r.commits == 4 && r.verified == 3, "\(r)")
        #expect(r.imported == [root] && r.unverified.isEmpty && r.ownerAccepted.isEmpty && r.truncatedAt == nil, "\(r)")
        #expect(r.allClassified)
        #expect(r.summary == "landings verified: 100% (3/3); owner-accepted 0; imported 1")
    }

    /// Ruling R24: a batch abandoned after `checked` keeps `landCommit`/`landedIds` and finishes `done`, its requests requeued
    /// (not `merged` by it). It verifies nothing, even with a passed run at its land commit.
    @Test func abandonedBatchDoesNotVerify() throws {
        let (store, company, items) = try rig(items: 2)
        let root = sha(1)
        let (batch, requests) = try MeasureFixtures.land(store, company: company, items: items, number: 1, enqueuedAt: t0, landedAt: t0,
                                                         commits: [sha(21), sha(22)], base: root)
        try MeasureFixtures.mergeRun(store, company: company, batch: batch, kind: .main, finishedAt: t0)
        try store.writer.write { db in
            for r in requests {
                try db.execute(sql: "UPDATE mergeRequest SET status = 'queued', batchId = NULL, mergedCommit = NULL WHERE companyId = ? AND id = ?",
                               arguments: [company.id, r.id])
            }
        }
        let r = LandingAudit.classify(walk: [sha(22), sha(21), root], records: try records(store, company))
        #expect(r.verified == 0 && r.unverified == [sha(22), sha(21)], "\(r)")
        #expect(!r.allClassified)
        #expect(r.summary == "landings verified: 0% (0/2); owner-accepted 0; imported 1")
    }

    /// Ruling R24 inside a landed batch: only the requests that batch merged count. Its other landed id (requeued) verifies
    /// nothing; the merged one does.
    @Test func onlyMergedRequestsOfABatchVerify() throws {
        let (store, company, items) = try rig(items: 2)
        let root = sha(1)
        let (batch, requests) = try MeasureFixtures.land(store, company: company, items: items, number: 1, enqueuedAt: t0, landedAt: t0,
                                                         commits: [sha(31), sha(32)], base: root)
        try MeasureFixtures.mergeRun(store, company: company, batch: batch, kind: .item, finishedAt: t0)
        try store.writer.write { db in
            try db.execute(sql: "UPDATE mergeRequest SET status = 'queued', batchId = NULL WHERE companyId = ? AND id = ?",
                           arguments: [company.id, requests[1].id])
        }
        let r = LandingAudit.classify(walk: [sha(32), sha(31), root], records: try records(store, company))
        #expect(r.unverified == [sha(32)] && r.verified == 1, "\(r)")
    }

    /// A landed batch with no passed check at its land commit (no run at all, or only a failed one, or a pass at another
    /// candidate) verifies nothing.
    @Test func batchWithoutPassedRunDoesNotVerify() throws {
        let (store, company, items) = try rig(items: 2)
        let root = sha(1)
        let (b1, _) = try MeasureFixtures.land(store, company: company, items: [items[0]], number: 1, enqueuedAt: t0, landedAt: t0,
                                               commits: [sha(41)], base: root)
        try MeasureFixtures.mergeRun(store, company: company, batch: b1, kind: .item, status: .failed, finishedAt: t0)
        try MeasureFixtures.mergeRun(store, company: company, batch: b1, kind: .item, candidateCommit: sha(99), finishedAt: t0)
        let (b2, _) = try MeasureFixtures.land(store, company: company, items: [items[1]], number: 2, enqueuedAt: t0, landedAt: t0,
                                               commits: [sha(42)], base: sha(41))
        // A `mainAtBase` run says nothing about the candidate.
        try MeasureFixtures.mergeRun(store, company: company, batch: b2, kind: .mainAtBase, finishedAt: t0)
        let r = LandingAudit.classify(walk: [sha(42), sha(41), root], records: try records(store, company))
        #expect(r.unverified == [sha(42), sha(41)] && r.verified == 0, "\(r)")
    }

    /// An item whose branch holds several commits lands as a rebased chain: every commit between the previous candidate (or
    /// the batch's base) and its candidate is the item's, verified with it. A chain whose lower end is not on the walk keeps
    /// only its candidate.
    @Test func multiCommitItemChainVerified() throws {
        let (store, company, items) = try rig(items: 2)
        let root = sha(1)
        let (b1, _) = try MeasureFixtures.land(store, company: company, items: [items[0]], number: 1, enqueuedAt: t0, landedAt: t0,
                                               commits: [sha(53)], base: root)
        try MeasureFixtures.mergeRun(store, company: company, batch: b1, kind: .item, finishedAt: t0)
        let (b2, _) = try MeasureFixtures.land(store, company: company, items: [items[1]], number: 2, enqueuedAt: t0, landedAt: t0,
                                               commits: [sha(62)], base: sha(77))   // a base not on main
        try MeasureFixtures.mergeRun(store, company: company, batch: b2, kind: .item, finishedAt: t0)
        let r = LandingAudit.classify(walk: [sha(62), sha(61), sha(53), sha(52), sha(51), root], records: try records(store, company))
        #expect(r.verified == 4 && r.unverified == [sha(61)], "\(r)")
    }

    /// A structured owner accept (`mainAccept`, ruling R38) as `Store.recordMainAccept` writes it.
    func accept(_ store: Store, _ company: Company, _ commit: String, previous: String?, kind: MainAcceptKind = .adopt) throws {
        try store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO mainAccept (companyId, "commit", previousHead, kind, createdAt) VALUES (?, ?, ?, ?, ?)
                """, arguments: [company.id, commit, previous, kind, t0])
        }
    }

    /// The reviewer's walk (review #1, ruling R38a) over an inconsistent record: the owner adopted H with `previousHead` V, but
    /// C2 and C1 are a landed batch's candidates (no passed run) and X sits between them and V. The accept covers H; its run
    /// stops at C2, a commit the store records, which its own record decides (unverified); X below stays unverified.
    @Test func acceptRunStopsAtRecordedCommit() throws {
        let (store, company, items) = try rig(items: 3)
        let (root, v, x, c1, c2, h) = (sha(1), sha(2), sha(3), sha(4), sha(5), sha(6))
        let (b1, _) = try MeasureFixtures.land(store, company: company, items: [items[0]], number: 1, enqueuedAt: t0, landedAt: t0,
                                               commits: [v], base: root)
        try MeasureFixtures.mergeRun(store, company: company, batch: b1, kind: .item, finishedAt: t0)
        try MeasureFixtures.land(store, company: company, items: [items[1], items[2]], number: 2, enqueuedAt: t0, landedAt: t0,
                                 commits: [c1, c2], base: v)
        try accept(store, company, h, previous: v)
        let r = LandingAudit.classify(walk: [h, c2, c1, x, v, root], records: try records(store, company))
        #expect(r.ownerAccepted == [h] && r.unverified == [c2, c1, x] && r.verified == 1 && r.imported == [root], "\(r)")
        #expect(!r.allClassified)
        // A store-recorded commit is never owner-accepted, even when an accept names it.
        try accept(store, company, c2, previous: v)
        let again = LandingAudit.classify(walk: [h, c2, c1, x, v, root], records: try records(store, company))
        #expect(again.ownerAccepted == [h] && again.unverified == [c2, c1, x], "\(again)")
    }

    /// An adopt over two commits made outside Brahma above the recorded head V covers the head and both; V stays verified.
    @Test func adoptOverOutsideCommits() throws {
        let (store, company, items) = try rig(items: 1)
        let (root, v, o1, o2, h) = (sha(1), sha(2), sha(3), sha(4), sha(5))
        let (b1, _) = try MeasureFixtures.land(store, company: company, items: items, number: 1, enqueuedAt: t0, landedAt: t0,
                                               commits: [v], base: root)
        try MeasureFixtures.mergeRun(store, company: company, batch: b1, kind: .item, finishedAt: t0)
        try accept(store, company, h, previous: v)
        let r = LandingAudit.classify(walk: [h, o2, o1, v, root], records: try records(store, company))
        #expect(r.ownerAccepted == [h, o2, o1] && r.verified == 1 && r.unverified.isEmpty && r.allClassified, "\(r)")
        #expect(r.summary == "landings verified: 100% (1/1); owner-accepted 3; imported 1")
        // The run ends at the previous head even with nothing recorded there, and at another accept's commit.
        let (store2, company2, _) = try rig(items: 0)
        try accept(store2, company2, h, previous: o1)
        try accept(store2, company2, sha(9), previous: nil, kind: .quarantineAccept)
        let r2 = LandingAudit.classify(walk: [h, o2, o1, sha(9), sha(8), root], records: try records(store2, company2))
        #expect(r2.ownerAccepted == [h, o2, sha(9), sha(8)] && r2.unverified == [o1], "\(r2)")
    }

    /// Only the structured full commit id counts: a walked commit that shares the accepted commit's first seven digits is not
    /// accepted.
    @Test func onlyStructuredFullShaCounts() throws {
        let (store, company, _) = try rig(items: 0)
        let accepted = sha(70), twin = String(sha(70).prefix(7)) + String(repeating: "b", count: 33)
        try accept(store, company, accepted, previous: twin)
        let r = LandingAudit.classify(walk: [twin, sha(1)], records: try records(store, company))
        #expect(r.ownerAccepted.isEmpty && r.unverified == [twin], "\(r)")
        let r2 = LandingAudit.classify(walk: [accepted, twin, sha(1)], records: try records(store, company))
        #expect(r2.ownerAccepted == [accepted] && r2.unverified == [twin], "\(r2)")
    }

    /// Acceptances from before `mainAccept` exist only as activity text (ruling R38). One matches only the single walked commit
    /// with its seven-digit prefix, committed before the acceptance, and covers that commit alone (no run). Two walked commits
    /// sharing the prefix match neither. An agent's row, the engine's re-affirmation, a malformed row and any row written after
    /// `mainAccept` began match nothing.
    @Test func legacyAcceptRules() throws {
        let (store, company, _) = try rig(items: 0)
        func activity(_ kind: ActivityKind, _ text: String, agent: String? = nil, at: Date? = nil) throws {
            try store.writer.write { db in
                try ActivityEvent(companyId: company.id, agentId: agent, turnId: nil, kind: kind, text: text, createdAt: at ?? t0).insert(db)
            }
        }
        let epoch: Date = try #require(try store.writer.read { db in try Row.fetchOne(db, sql: "SELECT at FROM measureEpoch WHERE name = 'mainAccept'")?["at"] })
        let unique = sha(10), below = sha(11), late = sha(12), q = sha(13), agentHead = sha(14), engineHead = sha(15), newer = sha(16)
        let twinA = sha(20), twinB = String(sha(20).prefix(7)) + String(repeating: "c", count: 33)
        try activity(.merge, "main adopted at \(unique.prefix(7)) by the owner")
        try activity(.merge, "main adopted at \(late.prefix(7)) by the owner")
        try activity(.work, "the owner accepted refs/brahma/quarantine/20230101-000000 (\(q.prefix(12))) into main at \(q.prefix(7))")
        try activity(.merge, "main adopted at \(agentHead.prefix(7)) by the owner", agent: "agent-1")
        try activity(.merge, "main adopted at \(engineHead.prefix(7)) by the engine")
        try activity(.merge, "main adopted at \(twinA.prefix(7)) by the owner")
        try activity(.merge, "main adopted at \(newer.prefix(7)) by the owner", at: epoch.addingTimeInterval(60))
        let recs = try records(store, company)
        #expect(recs.legacyAccepts.count == 4, "\(recs.legacyAccepts)")
        let walk = [newer, engineHead, agentHead, twinA, twinB, q, late, unique, below, sha(1)]
        let candidates = LandingAudit.legacyCandidates(walk: walk, records: recs)
        #expect(Set(candidates) == [unique, late, q], "the twins match neither: \(candidates)")
        let times = [unique: t0.addingTimeInterval(-60), late: t0.addingTimeInterval(60), q: t0.addingTimeInterval(-1)]
        let r = LandingAudit.classify(walk: walk, records: recs, commitTimes: times)
        #expect(r.ownerAccepted == [q, unique], "\(r)")
        #expect(r.unverified == [newer, engineHead, agentHead, twinA, twinB, late, below], "no run below a legacy accept: \(r)")
    }

    /// Ruling R24 within a chain: a landed id the batch did not merge (link 0) verifies nothing, but its candidate still bounds
    /// the merged link 1's range, which stops there.
    @Test func nonMergedLinkBoundsTheNextRange() throws {
        let (store, company, items) = try rig(items: 2)
        let (root, c1, x, c2) = (sha(1), sha(2), sha(3), sha(4))
        let (batch, requests) = try MeasureFixtures.land(store, company: company, items: items, number: 1, enqueuedAt: t0, landedAt: t0,
                                                         commits: [c1, c2], base: root)
        try MeasureFixtures.mergeRun(store, company: company, batch: batch, kind: .item, finishedAt: t0)
        try store.writer.write { db in
            try db.execute(sql: "UPDATE mergeRequest SET status = 'queued', batchId = NULL WHERE companyId = ? AND id = ?",
                           arguments: [company.id, requests[0].id])
        }
        let r = LandingAudit.classify(walk: [c2, x, c1, root], records: try records(store, company))
        #expect(r.verified == 2 && r.unverified == [c1] && r.imported == [root], "\(r)")
    }

    /// Review #5: a landed id with no candidate stays in the chain as a gap: the next link, with no commit below it to stop at,
    /// covers only its own candidate.
    @Test func candidateGapCoversOnlyTheTop() throws {
        let (store, company, items) = try rig(items: 2)
        let (root, x, c2) = (sha(1), sha(2), sha(3))
        let (batch, requests) = try MeasureFixtures.land(store, company: company, items: items, number: 1, enqueuedAt: t0, landedAt: t0,
                                                         commits: [sha(9), c2], base: root)
        try MeasureFixtures.mergeRun(store, company: company, batch: batch, kind: .item, finishedAt: t0)
        try store.writer.write { db in
            guard var b = try MergeBatch.fetchOne(db, key: batch.id) else { throw FakeError(description: "no batch") }
            b.candidates.removeValue(forKey: requests[0].id)
            try b.update(db)
        }
        let recs = try records(store, company)
        #expect(recs.batches.first?.chain.map(\.commit) == [nil, c2], "\(recs.batches)")
        let r = LandingAudit.classify(walk: [c2, x, root], records: recs)
        #expect(r.verified == 1 && r.unverified == [x], "\(r)")
    }

    /// A company imported from an existing repository starts at `importedCommit`: that commit is imported and nothing below it
    /// is audited. Without one, the root of first-parent history is the first commit.
    @Test func importedCommitStopsTheWalk() throws {
        let (store, company, _) = try rig(items: 0)
        try store.writer.write { db in
            try db.execute(sql: "UPDATE company SET importedCommit = ? WHERE id = ?", arguments: [sha(3), company.id])
        }
        let r = LandingAudit.classify(walk: [sha(5), sha(4), sha(3), sha(2), sha(1)], records: try records(store, company))
        #expect(r.commits == 3 && r.imported == [sha(3)] && r.unverified == [sha(5), sha(4)], "\(r)")
    }

    /// `since`: the walk stops below the newest landing that finished before it (an engine-recorded time; commit dates are
    /// the author's), and nothing is imported.
    @Test func sinceStopsAtLastLandingBefore() throws {
        let (store, company, items) = try rig(items: 2)
        let (b1, _) = try MeasureFixtures.land(store, company: company, items: [items[0]], number: 1, enqueuedAt: t0, landedAt: t0,
                                               commits: [sha(81)], base: sha(1))
        try MeasureFixtures.mergeRun(store, company: company, batch: b1, kind: .item, finishedAt: t0)
        let later = t0.addingTimeInterval(10 * 86_400)
        let (b2, _) = try MeasureFixtures.land(store, company: company, items: [items[1]], number: 2, enqueuedAt: later, landedAt: later,
                                               commits: [sha(83)], base: sha(82))
        try MeasureFixtures.mergeRun(store, company: company, batch: b2, kind: .item, finishedAt: later)
        let recs = try records(store, company, since: t0.addingTimeInterval(86_400))
        #expect(recs.stopBefore == sha(81))
        let r = LandingAudit.classify(walk: [sha(83), sha(82), sha(81), sha(1)], records: recs)
        #expect(r.commits == 2 && r.verified == 1 && r.unverified == [sha(82)] && r.imported.isEmpty, "\(r)")
    }

    /// The walk is bounded: a list longer than `maxCommits` is cut there and the result says so; such a run never passes.
    @Test func boundCutsTheWalk() throws {
        let (store, company, _) = try rig(items: 0)
        let r = LandingAudit.classify(walk: (1...4).reversed().map(sha), records: try records(store, company), maxCommits: 3)
        #expect(r.commits == 3 && r.truncatedAt == 3 && r.imported.isEmpty && !r.allClassified, "\(r)")
        #expect(r.lines().contains { $0.contains("stopped at 3 commits") }, "\(r.lines())")
        // Exactly at the bound, with the root reached: complete.
        let full = LandingAudit.classify(walk: (1...3).reversed().map(sha), records: try records(store, company), maxCommits: 3)
        #expect(full.truncatedAt == nil && full.imported == [sha(1)], "\(full)")
    }

    /// Records are the company's own: another company's landings, runs, accepts and restores never classify this one's commits.
    @Test func otherCompanyRecordsIgnored() throws {
        let (store, acme, _) = try rig(items: 0)
        let zeta = try MeasureFixtures.company(store, name: "Zeta")
        let zItems = try MeasureFixtures.items(store, company: zeta, count: 1)
        let (zb, _) = try MeasureFixtures.land(store, company: zeta, items: zItems, number: 1, enqueuedAt: t0, landedAt: t0,
                                               commits: [sha(91)], base: sha(1))
        try MeasureFixtures.mergeRun(store, company: zeta, batch: zb, kind: .item, finishedAt: t0)
        try store.writer.write { db in
            try ActivityEvent(companyId: zeta.id, agentId: nil, turnId: nil, kind: .merge,
                              text: "main adopted at \(sha(92).prefix(7)) by the owner", createdAt: t0).insert(db)
        }
        try accept(store, zeta, sha(93), previous: nil)
        let r = LandingAudit.classify(walk: [sha(93), sha(91), sha(1)], records: try records(store, acme))
        #expect(r.unverified == [sha(93), sha(91)] && r.ownerAccepted.isEmpty, "\(r)")
    }

    /// The report: a summary line, the unverified commits (short sha and subject, at most `maxListed`), the history changes.
    /// The lines are plain text; the CLI sanitizes each one (subjects are agent-controlled).
    @Test func linesListUnverifiedWithSubjects() throws {
        var r = LandingAuditResult(commits: 3, verified: 1, ownerAccepted: [], imported: [sha(1)], unverified: [sha(3)],
                                   historyChanged: ["restore at 2023-11-14T22:13:20Z: main restored to 0000000"], truncatedAt: nil)
        r.subjects = [sha(3): "fix \u{1b}[31mred"]
        let lines = r.lines()
        #expect(lines.first == "landings verified: 50% (1/2); owner-accepted 0; imported 1", "\(lines)")
        #expect(lines.contains("unverified: \(sha(3).prefix(7)) fix \u{1b}[31mred"), "\(lines)")
        #expect(lines.contains("history changed: restore at 2023-11-14T22:13:20Z: main restored to 0000000"), "\(lines)")
        let none = LandingAuditResult(commits: 1, verified: 0, ownerAccepted: [], imported: [sha(1)], unverified: [], historyChanged: [],
                                      truncatedAt: nil)
        #expect(none.summary == "landings verified: none to verify (0/0); owner-accepted 0; imported 1")
        #expect(none.allClassified)
    }
}
