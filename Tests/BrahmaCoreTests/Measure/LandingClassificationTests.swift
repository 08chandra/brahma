import Foundation
import Testing
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

    /// An owner's adopt of `main` (`main adopted at <sha7> by the owner`) covers its head and the unbroken run of otherwise
    /// unclassified commits below it, stopping at the first verified one. A quarantine accept covers only the head it names. An
    /// activity row an agent wrote, or the engine's own re-affirmation, covers nothing.
    @Test func ownerAcceptRules() throws {
        let (store, company, items) = try rig(items: 1)
        let root = sha(1)
        let (b1, _) = try MeasureFixtures.land(store, company: company, items: items, number: 1, enqueuedAt: t0, landedAt: t0,
                                               commits: [sha(71)], base: root)
        try MeasureFixtures.mergeRun(store, company: company, batch: b1, kind: .item, finishedAt: t0)
        func activity(_ kind: ActivityKind, _ text: String, agent: String? = nil) throws {
            try store.writer.write { db in
                try ActivityEvent(companyId: company.id, agentId: agent, turnId: nil, kind: kind, text: text, createdAt: t0).insert(db)
            }
        }
        let q = sha(75)
        try activity(.merge, "main adopted at \(sha(74).prefix(7)) by the owner")
        try activity(.work, "the owner accepted refs/brahma/quarantine/20261101-101010 (\(q.prefix(12))) into main at \(q.prefix(7))")
        try activity(.merge, "main adopted at \(sha(76).prefix(7)) by the engine")
        try activity(.merge, "main adopted at \(sha(77).prefix(7)) by the owner", agent: "agent-1")
        try activity(.merge, "main adopted at \(sha(78).prefix(7)) by the owner, really")
        let recs = try records(store, company)
        #expect(recs.accepts.count == 2, "the engine's, the agent's and the malformed rows are not owner accepts: \(recs.accepts)")
        let walk = [sha(78), sha(77), q, sha(76), sha(74), sha(73), sha(72), sha(71), root]
        let r = LandingAudit.classify(walk: walk, records: recs)
        #expect(r.ownerAccepted == [q, sha(74), sha(73), sha(72)], "\(r)")
        #expect(r.unverified == [sha(78), sha(77), sha(76)], "\(r)")
        #expect(r.verified == 1 && r.imported == [root])
        #expect(r.summary == "landings verified: 25% (1/4); owner-accepted 4; imported 1")
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
        let r = LandingAudit.classify(walk: [sha(91), sha(1)], records: try records(store, acme))
        #expect(r.unverified == [sha(91)] && r.ownerAccepted.isEmpty, "\(r)")
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
