import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Plan C Task C4a's resolver world (on `RefFixture`): ENG-142 leased by @eng-3 with a dirty worktree, the `web` preview with
/// smoke path `/checkout`, artifact AR-4 published by a designer (and AR-5 by an engineer), ask A-7 pending, run 551 failed on
/// ENG-142, and two releases.
struct ShowFixture {
    let fx: RefFixture
    let files = FileIndexCache()
    let commits = CommitIndexCache()
    let item142: WorkItem
    let designer: Agent
    var store: Store { fx.store }
    var c: Company { fx.c }
    var worktree: URL { GitWorkspace(root: URL(fileURLWithPath: c.workspacePath, isDirectory: true)).worktreePath(key: "ENG-142") }

    init() throws {
        fx = try RefFixture()
        let s = fx.store, c = fx.c, now = fx.now
        let created = try s.createWorkItem(companyId: c.id, by: .owner, draft: WorkItemDraft(type: .task, title: "Checkout totals"))
        let (cId, createdId, eng3Id, eng1Id) = (c.id, created.id, fx.eng3.id, fx.eng1.id)
        try s.writer.write { db in
            try db.execute(sql: "UPDATE workItem SET key = 'ENG-142', number = 142, status = 'inProgress', ownerId = ? WHERE id = ?",
                           arguments: [eng3Id, createdId])
            try WorkLease(itemId: createdId, companyId: cId, agentId: eng3Id, acquiredAt: now, expiresActive: 1_000_000_000).insert(db)
        }
        item142 = try #require(try s.workItem(id: created.id))
        let ws = GitWorkspace(root: URL(fileURLWithPath: c.workspacePath, isDirectory: true))
        let wt = try ws.addWorktree(key: "ENG-142")
        try "draft\n".write(to: wt.appending(path: "scratch.txt"), atomically: true, encoding: .utf8)

        designer = try s.hire(companyId: c.id, name: "designer-1", role: "designer", model: "sonnet")
        try fx.seedArtifact(4, title: "Checkout mockup", publishedById: designer.id)
        try fx.seedArtifact(5, title: "Checkout notes", publishedById: fx.eng1.id)
        try s.writer.write { db in
            try PreviewSurface(id: UUID().uuidString, companyId: cId, name: "web", position: 0, build: nil, run: "npm start",
                               url: "http://127.0.0.1:{port}/", smoke: [SmokeRequest(method: "GET", path: "/checkout")],
                               setById: "owner", createdAt: now, updatedAt: now).insert(db)
            try Ask(id: UUID().uuidString, companyId: cId, number: 7, kind: .info, risk: .low, requesterId: eng1Id,
                    title: "Pick a payment provider", summary: "s", status: .pendingOwner, createdActive: 0, statusSinceActive: 0,
                    createdAt: now, updatedAt: now).insert(db)
            try VerificationRun(id: "550", companyId: cId, itemId: createdId, checkRevision: 0, scriptHash: "h", commit: "abc",
                                command: "true", workingDirectory: ".", timeoutSeconds: 60, purpose: .submit, status: .passed,
                                exitCode: 0, createdAt: now.addingTimeInterval(-60)).insert(db)
            try VerificationRun(id: "551", companyId: cId, itemId: createdId, checkRevision: 0, scriptHash: "h", commit: "abc",
                                command: "true", workingDirectory: ".", timeoutSeconds: 60, purpose: .submit, status: .failed,
                                exitCode: 1, createdAt: now).insert(db)
            for n in 1...2 {
                try db.execute(sql: """
                    INSERT INTO release (id, companyId, number, version, status, provider, project, "commit", plan, commandsHash,
                      rollbackPlan, proposedById, createdAt) VALUES (?, ?, ?, ?, 'deployed', 'p', 'p', 'abc', '{}', 'h', '{}', 'owner', ?)
                    """, arguments: [UUID().uuidString, cId, n, "1.\(n)", now.addingTimeInterval(Double(n))])
            }
        }
    }

    func resolve(_ q: String, as reader: Reader = .owner) async throws -> ShowResult {
        try await ShowResolver(store: store, files: files, commits: commits).resolve(q, companyId: c.id, reader: reader)
    }

    func top(_ q: String) async throws -> ShowHit? { try await resolve(q).hits.first }

    func count(_ table: String) throws -> Int {
        try store.writer.read { db in
            guard try db.tableExists(table) else { return 0 }
            return try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0
        }
    }
}

@Suite(.scratch) struct ShowResolverTests {
    @Test func directRefResolvesWithoutTurn() async throws {
        let w = try ShowFixture()
        let before = try ["turn", "showRequest", "refRead"].map(w.count)
        let r = try await w.resolve("ENG-142")
        let top = try #require(r.hits.first)
        #expect(top.ref.canonical == "ENG-142" && top.score == 1.0 && top.group == .top)
        #expect(r.intent == .lookup && r.topScore == 1.0 && r.answer == nil)
        #expect(try ["turn", "showRequest", "refRead"].map(w.count) == before)
        // The same ref typed in prose; and lowercase.
        #expect(try await w.top("show me ENG-142 please")?.ref.canonical == "ENG-142")
        #expect(try await w.top("eng-142")?.ref.canonical == "ENG-142")
    }

    @Test func showMePhraseResolvesWithoutTurn() async throws {
        let w = try ShowFixture()
        let before = try ["turn", "showRequest", "refRead"].map(w.count)
        let r = try await w.resolve("show me the landing page on mobile")
        #expect(r.stripped == "landing page mobile")
        #expect(r.hits.first?.ref.canonical == "preview:web@iphone" && r.hits.first?.score == 0.95)
        #expect(r.intent == .lookup)
        #expect(try await w.top("the checkout page on ipad")?.ref.canonical == "preview:web/checkout@ipad")
        #expect(try await w.top("checkout page")?.ref.canonical == "preview:web/checkout")
        #expect(try await w.top("the web")?.ref.canonical == "preview:web")
        #expect(try ["turn", "showRequest", "refRead"].map(w.count) == before)
    }

    @Test func bareAskKeyOpensAsk() async throws {
        let w = try ShowFixture()
        let ask = try #require(try await w.top("A-7"))
        #expect(ask.ref.canonical == "A-7" && ask.ref.kind == .ask && ask.score == 1.0)
        let artifact = try #require(try await w.top("AR-4"))
        #expect(artifact.ref.canonical == "AR-4" && artifact.ref.kind == .artifact)
        // Unknown numbers are no hit at all.
        #expect(try await w.resolve("A-99").hits.allSatisfy { $0.ref.canonical != "A-99" })
    }

    @Test func whatIsAgentDoingResolvesToNowView() async throws {
        let w = try ShowFixture()
        #expect(try await w.top("what's @eng-3 doing")?.ref.canonical == "@eng-3")
        #expect(try await w.top("@eng-3 now")?.ref.canonical == "@eng-3")
        #expect(try await w.top("@eng-3")?.ref.canonical == "@eng-3")
        // A bare handle is the now view, not an actor filter.
        #expect(try await w.resolve("@eng-3").filters.actor == nil)
    }

    @Test func changesForKeyPrefersLiveWorktreeDiff() async throws {
        let w = try ShowFixture()
        #expect(try await w.top("changes for ENG-142")?.ref.canonical == "ENG-142:diff@worktree")
        #expect(try await w.top("what changed in ENG-142")?.ref.canonical == "ENG-142:diff@worktree")
        try FileManager.default.removeItem(at: w.worktree.appending(path: "scratch.txt"))
        #expect(try await w.top("changes for ENG-142")?.ref.canonical == "ENG-142:diff")
        // No lease: the committed diff.
        #expect(try await w.top("diff for ENG-1")?.ref.canonical == "ENG-1:diff")
    }

    @Test func latestFailingRun() async throws {
        let w = try ShowFixture()
        #expect(try await w.top("latest failing run")?.ref.canonical == "run:551")
        #expect(try await w.top("failing tests")?.ref.canonical == "run:551")
        #expect(try await w.top("last run for ENG-142")?.ref.canonical == "ENG-142:run")
        #expect(try await w.top("latest release")?.ref.canonical == "rel:2")
        #expect(try await w.top("what shipped")?.ref.canonical == "rel:2")
    }

    @Test func mockupPhraseFindsDesignerArtifact() async throws {
        let w = try ShowFixture()
        let r = try await w.resolve("mockup for checkout")
        #expect(r.hits.first?.ref.canonical == "AR-4")
        // An engineer's artifact is not a mockup.
        #expect(!r.hits.contains { $0.ref.canonical == "AR-5" && $0.group == .top })
    }

    @Test(arguments: [("why is checkout slow", ShowIntent.request), ("xyzzy", .request), ("ENG-142", .lookup), ("checkout", .lookup)])
    func askPreselectedOnlyBelowThreshold(_ q: String, _ i: ShowIntent) async throws {
        let w = try ShowFixture()
        let r = try await w.resolve(q)
        #expect(r.intent == i, "\(q): top \(r.topScore) \(r.hits.first?.ref.canonical ?? "-")")
        #expect(ShowIntent.classify(stripped: r.stripped, topScore: r.topScore, hasFact: true) == .fact)
        #expect(ShowIntent.threshold == 0.6)
    }

    @Test func degenerateQueriesAreSafe() async throws {
        let w = try ShowFixture()
        for q in ["", "show me", "???", "kind:", "by @", String(repeating: "a", count: 5000), "\u{202E}x"] {
            let r = try await w.resolve(q)
            #expect(r.intent == .request, "\(q.prefix(20))")
            #expect(r.normalized.count <= ShowQuery.maxQuery && ShowResolver.maxQuery == 300)
            #expect(r.hits.count <= ShowResolver.groupLimit * ShowGroup.allCases.count)
            #expect(r.hits.allSatisfy { $0.score < ShowIntent.threshold }, "\(q.prefix(20)): \(r.hits.map(\.ref.canonical))")
            _ = try await w.resolve(q, as: .agent(w.fx.eng1.id))
        }
    }

    /// 20k files, 50k messages, 20k activity rows and 2000 commits; 100 queries by the owner after one warm-up.
    @Test(.enabled(if: ProcessInfo.processInfo.environment["BRAHMA_PERF"] == "1")) func p95Under50ms() async throws {
        let fx = try RefFixture()
        let s = fx.store, c = fx.c, now = fx.now
        try PerfSeed.files(fx.git.root, files: 20_000, commits: 2000)
        let general = try #require(try await s.writer.read { db in
            try Channel.fetchOne(db, sql: "SELECT * FROM channel WHERE companyId = ? AND name = 'general'", arguments: [c.id])
        })
        let words = ["checkout", "payment", "flaky", "deploy", "retry", "invoice", "cache", "login", "search", "billing"]
        let (cId, ownerId) = (c.id, "owner")
        try await s.writer.write { db in
            for i in 0..<50_000 {
                let text = "\(words[i % words.count]) \(words[(i / 7) % words.count]) note \(i)"
                let m = Message(id: "m\(i)", companyId: cId, channelId: general.id, senderId: ownerId, text: text,
                                createdAt: now.addingTimeInterval(Double(-i)))
                try m.insert(db)
                _ = try s.ingest(db: db, MemoryIngestDoc(companyId: cId, source: .message, sourceId: m.id, ref: "msg:\(m.id)",
                                                         title: "#general @owner", body: text, access: .channel(general.id),
                                                         provenance: .owner, authorId: ownerId, createdAt: m.createdAt), now: now)
            }
            for i in 0..<20_000 {
                try ActivityEvent(companyId: cId, agentId: nil, turnId: nil, kind: .work, text: "ENG-1 \(words[i % words.count]) step \(i)",
                                  createdAt: now.addingTimeInterval(Double(-i))).insert(db)
            }
        }
        let resolver = ShowResolver(store: s, files: FileIndexCache(), commits: CommitIndexCache())
        _ = try await resolver.resolve("checkout", companyId: c.id, reader: .owner)     // builds the indexes
        let queries = (0..<100).map { i in ["checkout", "src/mod\(i)", "payment flaky", "ENG-1", "deploy this week", "by @eng-1 retry",
                                            "file\(i * 37)", "invoice", "kind:commit change", "what's @eng-3 doing"][i % 10] }
        var times: [Double] = []
        for q in queries {
            let start = DispatchTime.now().uptimeNanoseconds
            _ = try await resolver.resolve(q, companyId: c.id, reader: .owner)
            times.append(Double(DispatchTime.now().uptimeNanoseconds - start) / 1e6)
        }
        times.sort()
        let p95 = times[Int(Double(times.count) * 0.95) - 1]
        print("ShowResolver p95 \(p95) ms, median \(times[times.count / 2]) ms")
        #expect(p95 < 50, "p95 \(p95) ms")
    }
}

/// Builds a big repository fast (one `git fast-import`): `files` files on main in the first commit, then `commits - 1` commits
/// each changing one of them.
enum PerfSeed {
    static func files(_ root: URL, files: Int, commits: Int) throws {
        var stream = "commit refs/heads/main\nmark :1\ncommitter Perf <perf@example.com> 1700000000 +0000\ndata 4\nbig\nfrom refs/heads/main^0\n"
        for i in 0..<files {
            let body = "file \(i)\n"
            stream += "M 100644 inline src/mod\(i % 200)/file\(i).swift\ndata \(body.utf8.count)\n\(body)"
        }
        for n in 1..<commits {
            let msg = "change \(n) to file\(n)"
            let body = "changed \(n)\n"
            stream += "commit refs/heads/main\ncommitter Perf <perf@example.com> \(1700000000 + n) +0000\ndata \(msg.utf8.count)\n\(msg)\n"
            stream += "M 100644 inline src/mod\(n % 200)/file\(n).swift\ndata \(body.utf8.count)\n\(body)"
        }
        let input = root.deletingLastPathComponent().appending(path: "fast-import.txt")
        try stream.write(to: input, atomically: true, encoding: .utf8)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "git fast-import --quiet --force < \"$1\"", "sh", input.path]
        p.currentDirectoryURL = root
        try p.run()
        p.waitUntilExit()
        guard p.terminationStatus == 0 else { throw FakeError(description: "fast-import failed") }
    }
}
