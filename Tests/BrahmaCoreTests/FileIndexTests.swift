import Testing
import Foundation
@testable import BrahmaCore

/// Plan C Task C4a: the fuzzy file index (fzf-style scoring over lowercase ASCII-folded paths), its caps and its cache.
@Suite(.scratch) struct FileIndexTests {
    @Test func fuzzyFileRanking() throws {
        let idx = FileIndex(testPaths: ["tests/check_out.py", "src/checkout/old/notes.md", "src/routes/checkout.tsx"])
        #expect(idx.search("checkout", limit: 3).map(\.path) == ["src/routes/checkout.tsx", "src/checkout/old/notes.md", "tests/check_out.py"])
        // Fuzzy never beats a direct ref, and a path that is not a subsequence scores nothing.
        #expect(idx.search("checkout", limit: 3).allSatisfy { $0.score > 0 && $0.score <= 0.95 })
        #expect(idx.search("zzz", limit: 3).isEmpty)
        #expect(idx.search("CHECKOUT", limit: 1).map(\.path) == ["src/routes/checkout.tsx"])
        #expect(idx.search("checkout", limit: 1).count == 1)
    }

    @Test func recencyBreaksTies() throws {
        let paths = ["a/foo.ts", "b/foo.ts"]
        let idx = FileIndex(testPaths: paths, recency: ["a/foo.ts": 100, "b/foo.ts": 200])
        let hits = idx.search("foo", limit: 2)
        #expect(hits.map(\.path) == ["b/foo.ts", "a/foo.ts"])
        #expect(hits[0].score == hits[1].score)
        // Without recency: the shorter path, then lexicographic.
        #expect(FileIndex(testPaths: ["b/foo.ts", "a/foo.ts", "cc/foo.ts"]).search("foo", limit: 3).map(\.path) == ["a/foo.ts", "b/foo.ts", "cc/foo.ts"])
    }

    @Test func capsAt200k() throws {
        let idx = FileIndex(testPaths: (0...200_000).map { "f/\($0).txt" })
        #expect(idx.count == FileIndex.maxEntries && idx.count == 200_000)
        #expect(idx.truncated)
        #expect(!FileIndex(testPaths: ["a.txt"]).truncated)
        #expect(FileIndex.recencyCommits == 500)
    }

    @Test func cacheKeyedByTreeSha() async throws {
        let cf = try CollabFixture()
        let git = SafeGit(workspace: cf.workspace)
        let cache = FileIndexCache()
        let first = try await cache.index(companyId: cf.c.id, branch: "main", git: git)
        let again = try await cache.index(companyId: cf.c.id, branch: "main", git: git)
        #expect(first.id == again.id && first.treeSha == again.treeSha)
        #expect(first.search("checkout", limit: 1).map(\.path) == ["src/checkout.tsx"])
        #expect(first.search("checkout", limit: 1).first?.branch == "main")
        // A new commit (a new tree): rebuilt.
        try cf.fx.git.write("src/zebra.ts", "z\n")
        try cf.fx.git.git(["add", "-A"])
        try cf.fx.git.git(["commit", "-q", "-m", "zebra"])
        let rebuilt = try await cache.index(companyId: cf.c.id, branch: "main", git: git)
        #expect(rebuilt.id != first.id && rebuilt.treeSha != first.treeSha)
        #expect(rebuilt.search("zebra", limit: 1).map(\.path) == ["src/zebra.ts"])
        // An empty commit keeps the tree: the same index.
        try cf.fx.git.git(["commit", "-q", "--allow-empty", "-m", "nothing"])
        #expect(try await cache.index(companyId: cf.c.id, branch: "main", git: git).id == rebuilt.id)
        // Company D, even over the very same tree, gets an index of its own; and D's workspace shows only D's files.
        let sameTreeForD = try await cache.index(companyId: cf.fx.d.id, branch: "main", git: git)
        #expect(sameTreeForD.id != rebuilt.id)
        let dGit = GitFixture(existing: URL(fileURLWithPath: cf.fx.d.workspacePath))
        try dGit.write("d-only.txt", "d\n")
        try dGit.git(["add", "-A"])
        try dGit.git(["commit", "-q", "-m", "d"])
        let dIndex = try await cache.index(companyId: cf.fx.d.id, branch: "main", git: SafeGit(workspace: URL(fileURLWithPath: cf.fx.d.workspacePath)))
        #expect(dIndex.search("checkout", limit: 5).isEmpty)
        #expect(dIndex.search("donly", limit: 5).map(\.path) == ["d-only.txt"])
    }
}
