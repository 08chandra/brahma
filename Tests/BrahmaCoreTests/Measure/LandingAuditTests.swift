import Foundation
import Testing
@testable import BrahmaCore

/// `LandingAudit.run` over a real repository (Plan X6a Task 6; ruling R3: an ordinary test over a `GitFixture`). The fixture's
/// `main` is built with plain git, one commit per landed candidate (what 4a's fast-forward leaves), and the store records the
/// landings with those commits, so the audit's first-parent walk meets them.
@Suite(.scratch) struct LandingAuditTests {
    let t0 = MeasureFixtures.t0

    struct Rig {
        let store: Store
        let repo: GitFixture
        let company: Company
        let root: String
    }

    /// A store and a company whose workspace is a fresh repository: `main` holds only the engine's root commit.
    func rig() throws -> Rig {
        let store = try Store.inMemory()
        let repo = try GitFixture(files: ["README.md": "acme\n"])
        let company = try MeasureFixtures.company(store, name: "Acme", workspacePath: repo.root.path)
        return Rig(store: store, repo: repo, company: company, root: try repo.git(["rev-parse", "refs/heads/main"]))
    }

    /// A commit on `main` (the root checkout) with `message`; returns it.
    @discardableResult
    func commit(_ rig: Rig, _ path: String, _ message: String) throws -> String {
        try rig.repo.write(path, "\(path) \(UUID().uuidString)\n")
        try rig.repo.git(["add", "--", path])
        try rig.repo.git(["commit", "-q", "--no-verify", "-m", message])
        return try rig.repo.git(["rev-parse", "HEAD"])
    }

    /// One batch landing `commits` (one item each) on `base`, with a passed item check at its land commit.
    @discardableResult
    func land(_ rig: Rig, number: Int, commits: [String], base: String, passed: Bool = true) throws -> MergeBatch {
        let items = try MeasureFixtures.items(rig.store, company: rig.company, count: commits.count)
        let (batch, _) = try MeasureFixtures.land(rig.store, company: rig.company, items: items, number: number, enqueuedAt: t0,
                                                  landedAt: t0.addingTimeInterval(Double(number) * 3600), commits: commits, base: base)
        if passed { try MeasureFixtures.mergeRun(rig.store, company: rig.company, batch: batch, kind: .item, finishedAt: t0) }
        return batch
    }

    func audit(_ rig: Rig, since: Date? = nil, maxCommits: Int = LandingAudit.maxCommits) throws -> LandingAuditResult {
        try LandingAudit.run(store: rig.store, git: rig.repo.ws, companyId: rig.company.id, since: since, maxCommits: maxCommits)
    }

    /// Every queue landing on `main` is verified: a batch of three (each candidate a commit of its own) and a single item whose
    /// branch held two commits (the rebased chain). The engine's root commit is the company's first: imported.
    @Test func allQueueLandingsVerified() throws {
        let rig = try rig()
        let c1 = try commit(rig, "a.txt", "ACME-1"), c2 = try commit(rig, "b.txt", "ACME-2"), c3 = try commit(rig, "c.txt", "ACME-3")
        try land(rig, number: 1, commits: [c1, c2, c3], base: rig.root)
        let x = try commit(rig, "d.txt", "ACME-4 part one")
        let c4 = try commit(rig, "d2.txt", "ACME-4 part two")
        try land(rig, number: 2, commits: [c4], base: c3)
        let r = try audit(rig)
        #expect(r.commits == 6 && r.verified == 5, "\(r)")
        #expect(r.imported == [rig.root] && r.unverified.isEmpty && r.ownerAccepted.isEmpty && r.truncatedAt == nil, "\(r)")
        #expect(r.historyChanged.isEmpty, "\(r)")
        #expect(r.allClassified)
        #expect(r.lines() == ["landings verified: 100% (5/5); owner-accepted 0; imported 1"], "\(r.lines())")
        _ = x
    }

    /// A commit made on `main` outside the queue and then accepted by the owner (`brahma main accept`, which adopts `main`'s
    /// head) is owner-accepted, not unverified.
    @Test func ownerAcceptClassified() throws {
        let rig = try rig()
        let c1 = try commit(rig, "a.txt", "ACME-1")
        try land(rig, number: 1, commits: [c1], base: rig.root)
        try rig.store.writer.write { db in
            try db.execute(sql: "UPDATE company SET mainCommit = ? WHERE id = ?", arguments: [c1, rig.company.id])
        }
        let o1 = try commit(rig, "o1.txt", "owner hotfix part 1")
        let o2 = try commit(rig, "o2.txt", "owner hotfix part 2")
        let before = try audit(rig)
        #expect(before.unverified == [o2, o1], "\(before)")
        #expect(before.historyChanged.contains { $0.contains("main is at \(o2.prefix(7))") && $0.contains(String(c1.prefix(7))) },
                "the record still says c1: \(before.historyChanged)")
        let accepted = try rig.store.acceptMainCommit(companyId: rig.company.id)
        #expect(accepted.head == o2)
        let r = try audit(rig)
        #expect(r.ownerAccepted == [o2, o1] && r.unverified.isEmpty && r.verified == 1, "\(r)")
        #expect(r.historyChanged.isEmpty, "\(r)")
        #expect(r.lines() == ["landings verified: 100% (1/1); owner-accepted 2; imported 1"], "\(r.lines())")
    }

    /// An imported company starts at `importedCommit`: that commit is imported, the history it came with is not audited.
    @Test func importCommitClassified() throws {
        let rig = try rig()
        let p1 = try commit(rig, "old1.txt", "pre-import 1")
        let imported = try commit(rig, "old2.txt", "pre-import 2")
        try rig.store.writer.write { db in
            try db.execute(sql: "UPDATE company SET importedCommit = ? WHERE id = ?", arguments: [imported, rig.company.id])
        }
        let c1 = try commit(rig, "a.txt", "ACME-1")
        try land(rig, number: 1, commits: [c1], base: imported)
        let r = try audit(rig)
        #expect(r.commits == 2 && r.verified == 1 && r.imported == [imported] && r.unverified.isEmpty, "\(r)")
        #expect(!r.unverified.contains(p1) && !r.unverified.contains(rig.root))
        #expect(r.allClassified)
    }

    /// A commit made directly on `main` (no landing, no accept) is unverified, and so is a landing whose batch has no passed
    /// check. The subject is read for the report as git stores it (terminal escapes and all); the CLI sanitizes it.
    @Test func outsideCommitIsUnverified() throws {
        let rig = try rig()
        let c1 = try commit(rig, "a.txt", "ACME-1")
        try land(rig, number: 1, commits: [c1], base: rig.root)
        let c2 = try commit(rig, "b.txt", "ACME-2")
        try land(rig, number: 2, commits: [c2], base: c1, passed: false)
        let outside = try commit(rig, "x.txt", "sneak \u{1b}[2J\u{1b}]0;owned\u{07} in")
        let r = try audit(rig)
        #expect(r.unverified == [outside, c2] && r.verified == 1, "\(r)")
        #expect(!r.allClassified)
        #expect(r.subjects[outside] == "sneak \u{1b}[2J\u{1b}]0;owned\u{07} in", "\(r.subjects)")
        #expect(r.lines().first == "landings verified: 33% (1/3); owner-accepted 0; imported 1", "\(r.lines())")
        #expect(r.lines().contains("unverified: \(outside.prefix(7)) sneak \u{1b}[2J\u{1b}]0;owned\u{07} in"), "\(r.lines())")
        #expect(r.lines().contains("unverified: \(c2.prefix(7)) ACME-2"), "\(r.lines())")
    }

    /// A restore that put `main` back (`restoreMain` with its `restoreEvent`, and a `restoreEpoch`) is reported as a history
    /// change; another company's restore is not.
    @Test func restoreReported() throws {
        let rig = try rig()
        let c1 = try commit(rig, "a.txt", "ACME-1")
        try land(rig, number: 1, commits: [c1], base: rig.root)
        let zeta = try MeasureFixtures.company(rig.store, name: "Zeta")
        let restoredAt = t0.addingTimeInterval(86_400)
        try rig.store.writer.write { db in
            try db.execute(sql: "INSERT INTO restoreEvent (nonce, snapshot, restoredAt) VALUES (?, ?, ?)", arguments: ["n1", "snap-1", restoredAt])
            try db.execute(sql: "INSERT INTO restoreMain (nonce, companyId, mainCommit) VALUES (?, ?, ?)", arguments: ["n1", rig.company.id, c1])
            try db.execute(sql: "INSERT INTO restoreMain (nonce, companyId, mainCommit) VALUES (?, ?, ?)", arguments: ["n1", zeta.id, rig.root])
            try RestoreEpoch(id: "e1", companyId: rig.company.id, mainCommit: rig.root, listed: false, source: "snap-2",
                             createdAt: restoredAt.addingTimeInterval(60)).insert(db)
        }
        let r = try audit(rig)
        #expect(r.historyChanged.count == 2, "\(r.historyChanged)")
        #expect(r.historyChanged.first == "restore at 2023-11-15T22:13:20Z: main restored to \(c1.prefix(7))", "\(r.historyChanged)")
        #expect(r.historyChanged.last == "restore at 2023-11-15T22:14:20Z (database unreadable): main restored to \(rig.root.prefix(7))",
                "\(r.historyChanged)")
        #expect(r.allClassified, "a restore is reported, not a failure: \(r)")
        #expect(r.lines().contains("history changed: \(r.historyChanged.first ?? "-")"))
    }

    /// The walk is bounded at `maxCommits`; past it the result says where it stopped and the audit does not pass.
    @Test func boundStated() throws {
        let rig = try rig()
        var commits: [String] = []
        for n in 1...4 { commits.append(try commit(rig, "f\(n).txt", "ACME-\(n)")) }
        var base = rig.root
        for (n, c) in commits.enumerated() { try land(rig, number: n + 1, commits: [c], base: base); base = c }
        let cut = try audit(rig, maxCommits: 3)
        #expect(cut.commits == 3 && cut.truncatedAt == 3 && cut.verified == 3 && cut.imported.isEmpty, "\(cut)")
        #expect(!cut.allClassified)
        #expect(cut.lines().contains("stopped at 3 commits: older history of main was not audited"), "\(cut.lines())")
        let whole = try audit(rig, maxCommits: 5)
        #expect(whole.commits == 5 && whole.truncatedAt == nil && whole.imported == [rig.root] && whole.allClassified, "\(whole)")
        #expect(LandingAudit.maxCommits == 10_000)
    }

    /// No `main` in the workspace (or no workspace): the audit cannot run, and says so rather than reporting zero commits.
    @Test func missingMainThrows() throws {
        let store = try Store.inMemory()
        let company = try MeasureFixtures.company(store, name: "Acme")
        #expect(throws: (any Error).self) {
            try LandingAudit.run(store: store, git: GitWorkspace(root: URL(fileURLWithPath: company.workspacePath)), companyId: company.id,
                                 since: nil)
        }
    }
}
