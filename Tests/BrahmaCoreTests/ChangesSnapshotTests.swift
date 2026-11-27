import Testing
import Foundation
import GRDB
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import BrahmaCore

/// Plan C Task C5b's world on top of `CollabFixture`: ENG-1 leased by eng-1 with reviewer qa-2, two check runs (r1 = the
/// branch's first commit, r2 = a commit made in the worktree) and, unless `edits` is false, uncommitted edits in the worktree.
struct ChangesFixture {
    let cf: CollabFixture
    let wt: URL
    let r1: String, r2: String, base: String
    let eng7: Agent
    /// The owner principal of this (owner) test process, for the owner-only review APIs (Ruling C6-3).
    let owner: OwnerPrincipal

    var store: Store { cf.store }
    var c: Company { cf.c }
    var fx: RefFixture { cf.fx }
    var item: WorkItem { cf.fx.item }

    init(edits: Bool = true) throws {
        cf = try CollabFixture()
        let (itemId, cId, eng1Id, qa2Id, now) = (cf.fx.item.id, cf.c.id, cf.fx.eng1.id, cf.fx.qa2.id, cf.now)
        try cf.store.writer.write { db in
            try db.execute(sql: "UPDATE workItem SET status = 'inProgress', ownerId = ?, reviewerId = ? WHERE id = ?", arguments: [eng1Id, qa2Id, itemId])
            try WorkLease(itemId: itemId, companyId: cId, agentId: eng1Id, acquiredAt: now, expiresActive: 1e12).insert(db)
        }
        eng7 = try cf.store.hire(companyId: cId, name: "eng-7", role: "engineer", model: "sonnet", managerId: cf.fx.cto.id)
        owner = try OwnerPrincipal.mint()
        wt = try cf.fx.git.ws.addWorktree(key: "ENG-1")
        r1 = try cf.fx.head("item/ENG-1")
        try cf.fx.git.write("src/a.ts", "one\nTWO\nthree\nfour\n", in: wt)
        try cf.fx.git.git(["add", "-A"], in: wt)
        try cf.fx.git.git(["commit", "-q", "-m", "r2"], in: wt)
        r2 = try cf.fx.git.git(["rev-parse", "HEAD"], in: wt)
        base = try cf.fx.git.git(["merge-base", "main", "item/ENG-1"])
        try addRun(commit: r1, status: .passed, at: now.addingTimeInterval(-20))
        try addRun(commit: r2, status: .failed, at: now.addingTimeInterval(-10))
        if edits {
            try cf.fx.git.write("src/a.ts", "one\nTWO\nthree\nfour\nfive\n", in: wt)
            try cf.fx.git.write("Sources/App.swift", "let a = 1\n", in: wt)
        }
    }

    func addRun(commit: String, status: VerificationStatus, at: Date, item: WorkItem? = nil) throws {
        let target = item ?? self.item
        try store.writer.write { db in
            try VerificationRun(id: UUID().uuidString, companyId: target.companyId, itemId: target.id, checkRevision: 0, scriptHash: "h",
                                commit: commit, command: "true", workingDirectory: ".", timeoutSeconds: 60, purpose: .submit, status: status,
                                exitCode: status == .passed ? 0 : 1, createdAt: at).insert(db)
        }
    }

    func snapshot(_ compare: CompareMode, as who: RefFixture.Who = .owner, known: [(name: String, value: String)] = []) throws -> ChangesSnapshot {
        try store.changesSnapshot(companyId: c.id, key: "ENG-1", compare: compare, reader: fx.reader(who), knownValues: known, now: cf.now)
    }

    /// `git diff --numstat` as plain git computes it: between two commits, or (target nil) the worktree against a commit.
    func numstat(_ base: String, _ target: String?) throws -> Set<String> {
        let out = target.map { try? fx.git.git(["diff", "--numstat", base, $0]) } ?? (try? fx.git.git(["diff", "--numstat", base], in: wt))
        return Set((out ?? "").split(separator: "\n").map { line in
            let f = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            return "\(f[2]) +\(f[0]) -\(f[1])"
        })
    }

    static func describe(_ s: ChangesSnapshot) -> Set<String> {
        Set(s.files.map { "\($0.path) +\($0.added) -\($0.removed)" })
    }
}

/// Ruling C5b-4: no test fixture carries a literal in a real provider's key format; values are built at run time from parts.
enum TestSecrets {
    /// A Stripe-shaped test value (never a real key format as one literal).
    static let stripe = "sk_" + "test_" + "51Hx9Q" + String(repeating: "x", count: 20)
}

/// A git runner that records every call and runs it for real.
final class PassthroughRecordingRunner: GitProcessRunning, @unchecked Sendable {
    private let live = LiveGitRunner()
    private let lock = NSLock()
    private var recorded: [[String]] = []
    var calls: [[String]] { lock.withLock { recorded } }
    func run(args: [String], env: [String: String], stdin: Data?, timeout: Duration, outputCap: Int) throws -> (status: Int32, stdout: Data, stderr: Data) {
        try run(args: args, env: env, stdin: stdin, timeout: timeout, outputCap: outputCap, workTreeDescriptor: nil)
    }
    func run(args: [String], env: [String: String], stdin: Data?, timeout: Duration, outputCap: Int, workTreeDescriptor: Int32?) throws -> (status: Int32, stdout: Data, stderr: Data) {
        lock.withLock { recorded.append(args) }
        return try live.run(args: args, env: env, stdin: stdin, timeout: timeout, outputCap: outputCap, workTreeDescriptor: workTreeDescriptor)
    }
}

/// Plan C Task C5b: `Store.changesSnapshot` — compare modes from engine records, summaries for binary and large files,
/// redaction before anything is returned or stored, the agent's own index never touched, and the diff grammar forms.
@Suite(.scratch) struct ChangesSnapshotTests {
    @Test(arguments: [CompareMode.main, .head, .lastCheck, .revisions(from: "r1", to: "r2"), .revisions(from: "r1", to: "worktree")])
    func compareModes(_ m: CompareMode) throws {
        let f = try ChangesFixture()
        let s = try f.snapshot(m)
        let expectedBase: String, expectedTarget: String?
        switch m {
        case .main: (expectedBase, expectedTarget) = (f.base, nil)
        case .head, .lastCheck: (expectedBase, expectedTarget) = (f.r2, nil)
        case .revisions(_, "r2"): (expectedBase, expectedTarget) = (f.r1, f.r2)
        default: (expectedBase, expectedTarget) = (f.r1, nil)
        }
        #expect(s.base == expectedBase)
        #expect(s.target == (expectedTarget ?? "worktree"))
        #expect(s.compare == m && s.key == "ENG-1")
        let expected = try f.numstat(expectedBase, expectedTarget)
        #expect(ChangesFixture.describe(s) == expected)
        #expect(s.added == s.files.reduce(0) { $0 + $1.added } && s.removed == s.files.reduce(0) { $0 + $1.removed })
        #expect(!s.patch.isEmpty && !s.truncated && !s.tainted)
        #expect(!s.patchHash.isEmpty && s.computedAt == f.cf.now)
        if expectedTarget == nil { #expect(s.lastEdit != nil) } else { #expect(s.lastEdit == nil) }
    }

    @Test func itemRevisionsListed() throws {
        let f = try ChangesFixture()
        let revs = try f.store.itemRevisions(companyId: f.c.id, key: "ENG-1")
        #expect(revs.map(\.label) == ["base", "r1", "r2", "head", "worktree"])
        #expect(revs.map(\.sha) == [f.base, f.r1, f.r2, f.r2, nil])
        #expect(revs.map(\.checkStatus) == [nil, "passed", "failed", nil, nil])
        #expect(throws: WorkError.self) { try f.snapshot(.revisions(from: "r3", to: "worktree")) }
    }

    @Test func binarySummarized() throws {
        let f = try ChangesFixture(edits: false)
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52]) + Data(repeating: 0, count: 1200)
        try png.write(to: f.wt.appending(path: "img.png"))
        try f.fx.git.git(["add", "img.png"], in: f.wt)
        try f.fx.git.git(["commit", "-q", "-m", "png"], in: f.wt)
        try (png + Data(repeating: 7, count: 400)).write(to: f.wt.appending(path: "img.png"))
        let s = try f.snapshot(.head)
        let file = try #require(s.files.first { $0.path == "img.png" })
        #expect(file.status == "M" && file.added == 0 && file.removed == 0)
        #expect(file.summary == "binary · 1.2 KB → 1.6 KB")
        #expect(!s.patch.contains("img.png") && !s.patch.contains("@@"))
    }

    @Test func largeFileSummarized() throws {
        let f = try ChangesFixture(edits: false)
        let line = String(repeating: "x", count: 99) + "\n"
        let big = String(repeating: line, count: 30_000)        // 3 MB of text
        try f.fx.git.write("big.txt", big, in: f.wt)
        try f.fx.git.write("src/a.ts", "one\nTWO\nthree\nfour\nfive\n", in: f.wt)
        let s = try f.snapshot(.head)
        let file = try #require(s.files.first { $0.path == "big.txt" })
        #expect(file.status == "A")
        #expect(file.summary?.hasPrefix("large file · 3.0 MB, diff not shown") == true)
        #expect(!s.patch.contains("big.txt") && s.patch.contains("+five"))
        #expect(!s.truncated)
        // Hunks of one file are capped too.
        let tall = (1...2000).map { "l\($0)" }.joined(separator: "\n") + "\n"
        try f.fx.git.write("tall.txt", tall, in: f.wt)
        let t = try f.snapshot(.head)
        let tallFile = try #require(t.files.first { $0.path == "tall.txt" })
        #expect(tallFile.added == 2000 && tallFile.summary == "500 more lines not shown")
        #expect(t.patch.contains("+l1500\n") && !t.patch.contains("+l1501\n"))
    }

    @Test func diffRedactsSecrets() throws {
        let f = try ChangesFixture(edits: false)
        let stripe = TestSecrets.stripe
        let known = [(name: "STRIPE_KEY", value: stripe)]
        try f.fx.git.write("src/conf.ts", "const key = '\(stripe)'\nconst aws = '\(SecretGateTests.aws)'\n", in: f.wt)
        let s = try f.snapshot(.main, known: known)
        #expect(s.patch.contains("[redacted stored secret STRIPE_KEY]") && s.patch.contains("[redacted aws-key]"))
        #expect(!s.patch.contains(stripe) && !s.patch.contains(SecretGateTests.aws))
        // A worktree diff holding a stored value is never pinned (C2b): no snapshot row, nothing in the vault.
        let live = try f.fx.ref("ENG-1:diff@worktree")
        #expect(throws: WorkError.self) {
            try f.store.pinRef(live, for: .agent(f.fx.eng1.id), companyId: f.c.id, messageRefId: "mr-s", knownValues: known, paths: f.cf.paths)
        }
        // The pattern alone, committed: the diff cache keeps only the redacted text.
        try f.fx.git.write("src/conf.ts", "const aws = '\(SecretGateTests.aws)'\n", in: f.wt)
        try f.fx.git.git(["add", "-A"], in: f.wt)
        try f.fx.git.git(["commit", "-q", "-m", "conf"], in: f.wt)
        _ = try f.store.pinRef(try f.fx.ref("ENG-1:diff"), for: .agent(f.fx.eng1.id), companyId: f.c.id, messageRefId: "mr-c", knownValues: known, paths: f.cf.paths)
        let cId = f.c.id
        let rows = try f.store.writer.read { db in try RefSnapshot.fetchAll(db, sql: "SELECT * FROM refSnapshot WHERE companyId = ?", arguments: [cId]) }
        #expect(rows.map(\.kind) == [RefSnapshot.diffCache])
        var stored: [String] = []
        if let files = FileManager.default.enumerator(at: f.cf.vault.root, includingPropertiesForKeys: nil) {
            for case let url as URL in files where (try? url.resourceValues(forKeys: [.isRegularFileKey]).isRegularFile) == true {
                stored.append(String(decoding: try Data(contentsOf: url), as: UTF8.self))
            }
        }
        #expect(stored.count == 1 && stored.first?.contains("[redacted aws-key]") == true)
        #expect(!stored.contains { $0.contains(stripe) || $0.contains(SecretGateTests.aws) })
    }

    @Test func agentsOwnIndexNeverUsed() throws {
        let f = try ChangesFixture()
        let index = f.cf.workspace.appending(path: ".git/worktrees/ENG-1/index")
        let before = try Data(contentsOf: index)
        let mtimeBefore = try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date
        for i in 0..<10 {
            _ = try f.snapshot(i % 2 == 0 ? .main : .revisions(from: "r1", to: "worktree"))
        }
        #expect(try Data(contentsOf: index) == before)
        #expect(try FileManager.default.attributesOfItem(atPath: index.path)[.modificationDate] as? Date == mtimeBefore)
    }

    @Test func grammarForms() throws {
        let fx = try RefFixture()
        let ctx = fx.ctx
        func parse(_ s: String) -> WorkRef? { WorkRef.parse(s, context: ctx) }
        // A trailing "?" without "vs=" is punctuation.
        let scanned = RefScanner.scan("see ENG-1:changes?", context: ctx)
        #expect(scanned.map { $0.ref.canonical } == ["ENG-1:diff@worktree"])
        #expect(parse("ENG-1:changes?") == nil)
        #expect(parse("ENG-1:changes") == parse("ENG-1:diff@worktree"))
        #expect(parse("ENG-1:changes")?.canonical == "ENG-1:diff@worktree")
        for form in ["ENG-1:diff@worktree?vs=head", "ENG-1:diff@worktree?vs=check", "ENG-1:diff@r1..r2", "ENG-1:diff@r1..worktree",
                     "ENG-1:diff@base..head", "diff:a1b2c3d..b2c3d4e", "wt:@eng-1"] {
            let ref = try #require(parse(form), "\(form)")
            #expect(ref.kind == .diff && ref.canonical == form, "\(form)")
        }
        #expect(parse("ENG-1:diff@worktree?vs=head")?.params["vs"] == "head")
        #expect(parse("ENG-1:diff@worktree?vs=head")?.isWorktree == true)
        #expect(parse("ENG-1:diff@r1..worktree")?.isWorktree == true)
        #expect(parse("ENG-1:diff@r1..r2")?.isWorktree == false)
        #expect(CompareMode(ref: try #require(parse("ENG-1:diff@worktree?vs=check"))) == .lastCheck)
        #expect(CompareMode(ref: try #require(parse("ENG-1:diff@r1..r2"))) == .revisions(from: "r1", to: "r2"))
        #expect(CompareMode(ref: try #require(parse("ENG-1:changes"))) == .main)
        #expect(CompareMode.head.ref(key: "ENG-1").canonical == "ENG-1:diff@worktree?vs=head")
        for bad in ["diff:main..HEAD", "ENG-1:diff@r0..r2", "ENG-1:diff@worktree?vs=main", "ENG-1:diff@r2..base", "wt:eng-1", "wt:@Eng 1",
                    "diff:a1b2c3d..", "ENG-1:diff@worktree?"] {
            #expect(parse(bad) == nil, "\(bad)")
        }
    }

    @Test func wtHandleResolvesToCurrentLease() throws {
        let f = try ChangesFixture()
        let r = try f.store.resolveRef(try f.fx.ref("wt:@eng-1"), for: .owner, companyId: f.c.id)
        #expect(r.visibility == .full && r.ref.canonical == "ENG-1:diff@worktree")
        #expect(try f.store.resolveRef(try f.fx.ref("wt:@qa-2"), for: .owner, companyId: f.c.id).visibility == .missing)
        #expect(try f.store.resolveRef(try f.fx.ref("wt:@nobody"), for: .owner, companyId: f.c.id).visibility == .missing)
    }

    @Test func liveWorktreeRefScoped() throws {
        let f = try ChangesFixture()
        let live = try f.fx.ref("ENG-1:diff@worktree")
        #expect(try f.fx.resolve(.qa2, live).visibility == .full)
        #expect(try f.fx.resolve(.eng1, live).visibility == .full)
        #expect(try f.fx.resolve(.owner, live).visibility == .full)
        #expect(try f.fx.resolve(.concierge, live).visibility == .full)
        #expect(try f.store.resolveRef(live, for: .agent(f.eng7.id), companyId: f.c.id).visibility == .refused)
        #expect(try f.store.resolveRef(try f.fx.ref("ENG-1:changes"), for: .agent(f.eng7.id), companyId: f.c.id).visibility == .refused)
        #expect(try f.store.resolveRef(try f.fx.ref("wt:@eng-1"), for: .agent(f.eng7.id), companyId: f.c.id).visibility == .refused)
        #expect(try f.store.resolveRef(try f.fx.ref("ENG-1:diff@r1..worktree"), for: .agent(f.eng7.id), companyId: f.c.id).visibility == .refused)
        #expect(throws: WorkError.self) {
            try f.store.changesSnapshot(companyId: f.c.id, key: "ENG-1", compare: .main, reader: .agent(f.eng7.id), knownValues: [], now: f.cf.now)
        }
        // A pinned share of the same diff keeps the company class.
        let pinned = try f.store.pinRef(live, for: .agent(f.fx.eng1.id), companyId: f.c.id, messageRefId: "mr-p", knownValues: [], paths: f.cf.paths)
        #expect(try f.store.resolveRef(pinned, for: .agent(f.eng7.id), companyId: f.c.id).visibility == .full)
        // A committed diff is company-readable as before.
        #expect(try f.store.resolveRef(try f.fx.ref("ENG-1:diff"), for: .agent(f.eng7.id), companyId: f.c.id).visibility == .full)
    }

    // MARK: Fix round 1

    /// C5b-2: a live `@worktree` file follows the live worktree rule like the diff does.
    @Test func liveWorktreeFileRefScoped() throws {
        let f = try ChangesFixture()
        let file = try f.fx.ref("ENG-1:src/a.ts@worktree")
        #expect(try f.fx.resolve(.eng1, file).visibility == .full)
        #expect(try f.fx.resolve(.qa2, file).visibility == .full)
        #expect(try f.fx.resolve(.owner, file).visibility == .full)
        #expect(try f.fx.resolve(.concierge, file).visibility == .full)
        #expect(try f.store.resolveRef(file, for: .agent(f.eng7.id), companyId: f.c.id).visibility == .refused)
        #expect(f.cf.failure {
            try f.store.openRef(companyId: f.c.id, reader: .agent(f.eng7.id), ref: "ENG-1:src/a.ts@worktree", lines: nil, copy: false, turnId: nil,
                                context: f.fx.ctx, knownValues: [], paths: f.cf.paths, now: f.cf.now)
        } == Store.refUnavailable)
        // A pinned blob keeps the company class, and so does the committed file.
        let pinned = try f.store.pinRef(file, for: .agent(f.fx.eng1.id), companyId: f.c.id, messageRefId: "mr-lf", knownValues: [], paths: f.cf.paths)
        #expect(try f.store.resolveRef(pinned, for: .agent(f.eng7.id), companyId: f.c.id).visibility == .full)
        #expect(try f.store.resolveRef(try f.fx.ref("ENG-1:src/a.ts"), for: .agent(f.eng7.id), companyId: f.c.id).visibility == .full)
    }

    static func taintR2(_ f: ChangesFixture) throws {
        try f.store.recordTaintedCommits(companyId: f.c.id, itemId: f.item.id, agentId: f.fx.eng1.id, turnId: nil, headBefore: f.r1, headAfter: f.r2,
                                         source: "docs.swift.org", git: SafeGit(workspace: f.cf.workspace), now: f.cf.now)
    }
    static let taintReason = "from a session that read docs.swift.org"

    /// C5b-3: a diff between two revs shows both sides, so a tainted commit on either side taints it.
    @Test func diffRangeTaintSymmetric() throws {
        let f = try ChangesFixture()
        try Self.taintR2(f)
        let main = try f.fx.head("main")
        for s in ["diff:\(f.r2)..\(main)", "diff:\(main)..\(f.r2)", "diff:\(f.r2)..\(f.r1)", "diff:\(f.r1)..\(f.r2)", "ENG-1:diff@r2..r1", "ENG-1:diff@r1..r2",
                  "ENG-1:diff@base..head", "ENG-1:diff"] {
            #expect(try f.store.refTaint(try f.fx.ref(s), companyId: f.c.id) == (true, Self.taintReason), "\(s)")
        }
        for s in ["diff:\(f.r1)..\(main)", "diff:\(main)..\(f.r1)", "diff:\(f.base)..\(f.r1)", "ENG-1:diff@base..r1"] {
            #expect(try f.store.refTaint(try f.fx.ref(s), companyId: f.c.id) == (false, nil), "\(s)")
        }
        // A rev pair whose merge base can't be found reads as tainted (fail closed).
        let orphan = try f.fx.git.git(["commit-tree", try f.fx.git.git(["rev-parse", "main^{tree}"]), "-m", "orphan"])
        try f.fx.git.git(["update-ref", "refs/heads/item/ENG-1", orphan])
        defer { _ = try? f.fx.git.git(["update-ref", "refs/heads/item/ENG-1", f.r2]) }
        #expect(try f.store.refTaint(try f.fx.ref("diff:\(orphan)..\(main)"), companyId: f.c.id).tainted)
    }

    /// N-1: the live compare vs main shows the branch's commits, so their taint rides on it (not only the holder's session).
    @Test func liveDiffVsMainTaintedByCommittedTaint() throws {
        let f = try ChangesFixture()
        #expect(!(try f.snapshot(.main)).tainted)
        try Self.taintR2(f)
        let live = try f.snapshot(.main)
        #expect(live.tainted && live.taintReason == Self.taintReason)
        #expect(try f.snapshot(.revisions(from: "r1", to: "worktree")).tainted)
        #expect(try f.snapshot(.revisions(from: "r1", to: "r2")).tainted)
        // Fix round 2 (R1-2): a compare whose base is (or descends from) r2 shows r2's lines as context, so it is marked too.
        #expect(try f.snapshot(.head).tainted)
        #expect(try f.snapshot(.lastCheck).tainted)
        // A pair that displays nothing of r2 is clean, and so is the holder's session.
        #expect(!(try f.snapshot(.revisions(from: "base", to: "r1"))).tainted)
        // The resolver, the open path and the board agree with the snapshot.
        let resolved = try f.fx.resolve(.owner, try f.fx.ref("ENG-1:changes"))
        #expect(resolved.tainted && resolved.taintReason == Self.taintReason)
        #expect(try f.fx.resolve(.owner, try f.fx.ref("ENG-1:diff@worktree?vs=head")).tainted)
        #expect(try f.cf.open(.qa2, "ENG-1:changes").tainted)
        #expect(try f.store.changesBoard(companyId: f.c.id, reader: .owner, knownValues: [], now: f.cf.now).first { $0.key == "ENG-1" }?.tainted == true)
    }

    // MARK: Fix round 2

    /// R1-2: whatever a compare displays on either side carries its taint — a tainted base commit (r2) marks every mode that
    /// shows its lines, as context, as `-` lines or as `+` lines.
    @Test(arguments: [CompareMode.main, .head, .lastCheck, .revisions(from: "r1", to: "r2"), .revisions(from: "r1", to: "worktree"),
                      .revisions(from: "r2", to: "worktree"), .revisions(from: "r2", to: "head"), .revisions(from: "base", to: "r2")])
    func baseSideTaintMarksEveryCompare(_ m: CompareMode) throws {
        let f = try ChangesFixture()
        #expect(!(try f.snapshot(m)).tainted)
        try Self.taintR2(f)
        let s = try f.snapshot(m)
        #expect(s.tainted && s.taintReason == Self.taintReason, "\(m)")
        let resolved = try f.fx.resolve(.owner, m.ref(key: "ENG-1"))
        #expect(resolved.tainted, "\(m)")
        // A pair that never shows r2 stays clean.
        #expect(try f.store.refTaint(try f.fx.ref("ENG-1:diff@base..r1"), companyId: f.c.id) == (false, nil))
    }

    /// R1-3 (Ruling C5b-5): the live readers are the lease holder if there is one, else the assignee, plus the reviewer and
    /// the owner.
    @Test func assigneeNotReaderWhileAnotherHolds() throws {
        let f = try ChangesFixture()
        let live = try f.fx.ref("ENG-1:diff@worktree"), file = try f.fx.ref("ENG-1:src/a.ts@worktree")
        let (itemId, cId, eng3Id, now) = (f.item.id, f.c.id, f.fx.eng3.id, f.cf.now)
        // eng-3 takes the lease; eng-1 stays the assignee.
        try f.store.writer.write { db in
            try db.execute(sql: "DELETE FROM workLease WHERE itemId = ?", arguments: [itemId])
            try WorkLease(itemId: itemId, companyId: cId, agentId: eng3Id, acquiredAt: now, expiresActive: 1e12).insert(db)
        }
        for ref in [live, file] {
            #expect(try f.fx.resolve(.eng1, ref).visibility == .refused, "the assignee is not a reader while another agent holds the lease")
            #expect(try f.store.resolveRef(ref, for: .agent(eng3Id), companyId: cId).visibility == .full)
            #expect(try f.fx.resolve(.qa2, ref).visibility == .full)
            #expect(try f.fx.resolve(.owner, ref).visibility == .full)
            #expect(try f.fx.resolve(.concierge, ref).visibility == .full)
        }
        #expect(try f.store.changesBoard(companyId: cId, reader: .agent(f.fx.eng1.id), knownValues: [], now: now).isEmpty)
        #expect(try f.store.changesBoard(companyId: cId, reader: .agent(eng3Id), knownValues: [], now: now).map(\.key) == ["ENG-1"])
        // No lease: the assignee reads again.
        try f.store.writer.write { db in try db.execute(sql: "DELETE FROM workLease WHERE itemId = ?", arguments: [itemId]) }
        #expect(try f.fx.resolve(.eng1, live).visibility == .full)
        #expect(try f.store.resolveRef(live, for: .agent(eng3Id), companyId: cId).visibility == .refused)
    }

    /// R1-4 (Ruling C5b-6): `.brahma/progress/<KEY>.md` is live content of the item: the live reader set only; anything else
    /// under `progress/` is refused for everyone (fail closed).
    @Test func progressFileFollowsLiveRule() throws {
        let f = try ChangesFixture()
        try f.fx.git.write(".brahma/progress/ENG-1.md", "# ENG-1\n\n## Plan\nship five\n")
        try f.fx.git.write(".brahma/progress/ENG-9.md", "stray\n")
        try f.fx.git.write(".brahma/progress/notes.txt", "stray\n")
        let progress = try f.fx.ref(".brahma/progress/ENG-1.md")
        #expect(try f.fx.resolve(.eng1, progress).visibility == .full)
        #expect(try f.fx.resolve(.qa2, progress).visibility == .full)
        #expect(try f.fx.resolve(.owner, progress).visibility == .full)
        #expect(try f.fx.resolve(.concierge, progress).visibility == .full)
        #expect(try f.store.resolveRef(progress, for: .agent(f.eng7.id), companyId: f.c.id).visibility == .refused)
        #expect(try f.fx.resolve(.cto, progress).visibility == .refused)
        #expect(f.cf.failure {
            try f.store.openRef(companyId: f.c.id, reader: .agent(f.eng7.id), ref: ".brahma/progress/ENG-1.md", lines: nil, copy: false, turnId: nil,
                                context: f.fx.ctx, knownValues: [], paths: f.cf.paths, now: f.cf.now)
        } == Store.refUnavailable)
        #expect(try f.cf.open(.eng1, ".brahma/progress/ENG-1.md").text.contains("    | ship five"))
        for stray in [".brahma/progress/ENG-9.md", ".brahma/progress/notes.txt"] {
            #expect(try f.fx.resolve(.owner, try f.fx.ref(stray)).visibility == .refused, "\(stray)")
            #expect(try f.fx.resolve(.eng1, try f.fx.ref(stray)).visibility == .refused, "\(stray)")
        }
    }

    // MARK: Fix round 3

    /// Ruling C5b-7: a compare is never clean on a narrower check than `commitSource`. A commit of another item whose taint
    /// record was orphaned by a rewrite (so no row names the rewritten sha) lands on this item's branch: every compare that
    /// shows it is marked.
    @Test func orphanedOtherItemCommitTaintsCompare() throws {
        let f = try ChangesFixture(edits: false)
        let other = try f.store.createWorkItem(companyId: f.c.id, by: .owner, draft: WorkItemDraft(type: .task, title: "Other"))
        let wt2 = try f.fx.git.ws.addWorktree(key: other.key)
        try f.fx.git.write("other.txt", "from the other item\n", in: wt2)
        try f.fx.git.git(["add", "-A"], in: wt2)
        try f.fx.git.git(["commit", "-q", "-m", "other work"], in: wt2)
        let x = try f.fx.git.git(["rev-parse", "HEAD"], in: wt2)
        try f.store.recordTaintedCommits(companyId: f.c.id, itemId: other.id, agentId: f.fx.eng3.id, turnId: nil, headBefore: try f.fx.head("main"),
                                         headAfter: x, source: "docs.swift.org", git: SafeGit(workspace: f.cf.workspace), now: f.cf.now)
        // The other item's history is rewritten: the tainted row names a sha no longer on any branch.
        try f.fx.git.git(["commit", "-q", "--amend", "-m", "rewritten"], in: wt2)
        let rewritten = try f.fx.git.git(["rev-parse", "HEAD"], in: wt2)
        #expect(rewritten != x)
        // The rewritten commit lands on this item's branch.
        try f.fx.git.git(["merge", "-q", "--no-edit", rewritten], in: f.wt)
        try f.fx.git.write("src/a.ts", "one\nTWO\nthree\nfour\nfive\n", in: f.wt)
        for m in [CompareMode.head, .main, .lastCheck, .revisions(from: "r2", to: "worktree")] {
            let s = try f.snapshot(m)
            #expect(s.tainted && s.taintReason == Self.taintReason, "\(m)")
        }
        #expect(try f.fx.resolve(.owner, try f.fx.ref("ENG-1:diff@worktree?vs=head")).tainted)
        #expect(try f.cf.open(.eng1, "ENG-1:changes").tainted)
    }

    /// Ruling C5b-7 (2): a taint lookup that fails reads as tainted, never as an error — here another item's branch sits on an
    /// unrelated root, so `orphanedItems` can't judge it.
    @Test func orphanLookupFailureReadsTainted() throws {
        let f = try ChangesFixture()
        let other = try f.store.createWorkItem(companyId: f.c.id, by: .owner, draft: WorkItemDraft(type: .task, title: "Other"))
        let wt2 = try f.fx.git.ws.addWorktree(key: other.key)
        try f.fx.git.write("other.txt", "from the other item\n", in: wt2)
        try f.fx.git.git(["add", "-A"], in: wt2)
        try f.fx.git.git(["commit", "-q", "-m", "other work"], in: wt2)
        let x = try f.fx.git.git(["rev-parse", "HEAD"], in: wt2)
        try f.store.recordTaintedCommits(companyId: f.c.id, itemId: other.id, agentId: f.fx.eng3.id, turnId: nil, headBefore: try f.fx.head("main"),
                                         headAfter: x, source: "docs.swift.org", git: SafeGit(workspace: f.cf.workspace), now: f.cf.now)
        // The other item's branch is reset onto a root unrelated to main: its merge base can't be computed.
        let root = try f.fx.git.git(["commit-tree", try f.fx.git.git(["rev-parse", "main^{tree}"]), "-m", "unrelated root"])
        try f.fx.git.git(["update-ref", "refs/heads/item/\(other.key)", root])
        for m in [CompareMode.main, .head, .lastCheck, .revisions(from: "base", to: "head"), .revisions(from: "r1", to: "r2"), .revisions(from: "r1", to: "worktree")] {
            let s = try f.snapshot(m)
            #expect(s.tainted, "\(m) must read tainted, not throw or read clean")
        }
        #expect(try f.fx.resolve(.owner, try f.fx.ref("ENG-1:changes")).tainted)
        #expect(try f.store.refTaint(try f.fx.ref("diff:\(f.r1)..\(f.r2)"), companyId: f.c.id).tainted)
    }

    // MARK: Fix round 4

    /// Opens a restore epoch whose own `main` is `main` (the restored database can place nothing after it).
    static func openEpoch(_ f: ChangesFixture, id: String, main: String?) throws {
        let cId = f.c.id
        try f.store.writer.write { db in
            try RestoreEpoch(id: id, companyId: cId, mainCommit: main, listed: true, source: "a restored backup", createdAt: Date(),
                             clearedBy: nil, clearedAt: nil).insert(db)
        }
    }
    static let epochReason = "from a session that read a restored backup"

    /// R3-1: the key-less `diff:a..b` applies the restore-epoch rule `commit:<sha>` and `ENG-n:diff` apply: an open epoch
    /// whose `main` doesn't hold a displayed commit marks the range, even with no tainted-commit rows at all.
    @Test func restoreEpochTaintsKeylessRange() throws {
        let f = try ChangesFixture(edits: false)
        let main = try f.fx.head("main")
        #expect(try f.store.refTaint(try f.fx.ref("diff:\(main)..\(f.r2)"), companyId: f.c.id) == (false, nil))
        try Self.openEpoch(f, id: "epoch-r4", main: main)
        // r2 is a post-restore commit: every ref that shows it reads tainted, and alike.
        #expect(try f.store.refTaint(try f.fx.ref("commit:\(f.r2)"), companyId: f.c.id) == (true, Self.epochReason))
        #expect(try f.store.refTaint(try f.fx.ref("ENG-1:diff"), companyId: f.c.id) == (true, Self.epochReason))
        for s in ["diff:\(main)..\(f.r2)", "diff:\(f.r2)..\(main)", "diff:\(f.r1)..\(f.r2)", "diff:\(f.r2)..\(f.r1)"] {
            #expect(try f.store.refTaint(try f.fx.ref(s), companyId: f.c.id) == (true, Self.epochReason), "\(s)")
        }
        #expect(try f.fx.resolve(.owner, try f.fx.ref("diff:\(main)..\(f.r2)")).tainted)
        // A pair the epoch's own main holds both sides of stays clean.
        let parent = try f.fx.git.git(["rev-parse", "\(main)~1"])
        #expect(try f.store.refTaint(try f.fx.ref("commit:\(parent)"), companyId: f.c.id) == (false, nil))
        #expect(try f.store.refTaint(try f.fx.ref("diff:\(parent)..\(main)"), companyId: f.c.id) == (false, nil))
    }

    /// R3-1: an epoch whose range can't be judged (no `main` recorded, or one git can't read) reads as tainted for
    /// `diff:a..b`, as it does for `commit:<sha>`.
    @Test(arguments: [nil, String(repeating: "e", count: 40)])
    func restoreEpochLookupFailureTaintsKeylessRange(_ epochMain: String?) throws {
        let f = try ChangesFixture(edits: false)
        let main = try f.fx.head("main")
        let parent = try f.fx.git.git(["rev-parse", "\(main)~1"])
        try Self.openEpoch(f, id: "epoch-r4", main: epochMain)
        #expect(try f.store.refTaint(try f.fx.ref("commit:\(parent)"), companyId: f.c.id) == (true, Self.epochReason))
        for s in ["diff:\(parent)..\(main)", "diff:\(main)..\(f.r2)"] {
            #expect(try f.store.refTaint(try f.fx.ref(s), companyId: f.c.id) == (true, Self.epochReason), "\(s)")
        }
    }
}
