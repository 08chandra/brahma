import Testing
import Foundation
@testable import BrahmaCore

/// The engine's fresh, `.git`-free export of a commit (builder-check 1), a thin wrapper over 3a's `addEngineExport` (PR-2):
/// the commit is fetched by SHA into the engine repository and archived from there, never read through a tree's `.git`.
@Suite(.scratch) struct EngineExportTests {
    /// A company on a file-backed store (data home and workspaces under one test dir), with `files` committed on `main`.
    struct Home {
        let paths: BrahmaPaths
        let store: Store
        let company: Company
        let f: GitFixture

        init(files: [String: String]) throws {
            let root = try tempDir()
            paths = BrahmaPaths(home: root.appending(path: "data"), workspaces: root.appending(path: "wss"))
            try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
            store = try Store(path: paths.database.path)
            company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: paths.workspaces)
            f = GitFixture(existing: URL(fileURLWithPath: company.workspacePath, isDirectory: true))
            try commit(files, message: "files")
        }

        @discardableResult
        func commit(_ files: [String: String], removing: [String] = [], message: String) throws -> String {
            for (path, text) in files { try f.write(path, text) }
            for path in removing { try FileManager.default.removeItem(at: f.root.appending(path: path)) }
            try f.git(["add", "-A"])
            try f.git(["commit", "-q", "-m", message])
            return try f.git(["rev-parse", "refs/heads/main"])
        }

        /// Every path in `commit`'s tree with its content.
        func tree(_ commit: String) throws -> [String: String] {
            var out: [String: String] = [:]
            for path in try f.git(["ls-tree", "-r", "--name-only", commit]).split(separator: "\n").map(String.init) {
                out[path] = try f.git(["show", "\(commit):\(path)"])
            }
            return out
        }
    }

    /// Every file under `dir` (relative path → content, trimmed like `git show`), and every name met on the way.
    static func files(_ dir: URL) throws -> (files: [String: String], names: Set<String>) {
        var files: [String: String] = [:], names: Set<String> = []
        let fm = FileManager.default
        guard let walker = fm.enumerator(atPath: dir.path) else { return ([:], []) }
        while let relative = walker.nextObject() as? String {
            names.insert((relative as NSString).lastPathComponent)
            var isDir: ObjCBool = false
            let url = dir.appending(path: relative)
            if fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue {
                files[relative] = try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return (files, names)
    }

    static func exists(_ url: URL) -> Bool { var st = stat(); return lstat(url.path, &st) == 0 }

    @Test func exportHasCommitContentAndNoGit() throws {
        let h = try Home(files: ["a.txt": "one", "dir/b.txt": "two", "dir/deep/c.txt": "three"])
        let main = try h.f.git(["rev-parse", "refs/heads/main"])
        let runId = try EngineLayout.previewRunId(surfaceId: "S1", commit: main, start: 1)
        let dir = try EngineExport.export(store: h.store, company: h.company, runId: runId, commit: main)
        // Under the data home (PR-2), never in the workspace.
        #expect(dir.path == h.paths.exportDir(runId: runId).path)
        #expect(dir.path == EngineExport.directory(store: h.store, company: h.company, runId: runId).path)
        #expect(!dir.path.hasPrefix(h.company.workspacePath))
        let (files, names) = try Self.files(dir)
        #expect(files == (try h.tree(main)))
        #expect(files["dir/deep/c.txt"] == "three")
        #expect(!names.contains(".git"), "no .git entry anywhere: \(names)")
        EngineExport.remove(store: h.store, company: h.company, runId: runId)
        #expect(!Self.exists(dir))
    }

    /// A build that rewrites `.git` in its run dir (a crafted HEAD, an fsmonitor command, a hook, a `.git` file) changes
    /// nothing the engine exports next: the next export into the same place is exactly the next commit, nothing crafted ran,
    /// and nothing crafted is left.
    @Test func buildRewritingGitDoesNotChangeExport() throws {
        let h = try Home(files: ["a.txt": "one", "dir/b.txt": "two"])
        let first = try h.f.git(["rev-parse", "refs/heads/main"])
        let runId = "prev-s1-reused"
        let dir = try EngineExport.export(store: h.store, company: h.company, runId: runId, commit: first)
        let crafted = try h.f.plantCommit(parent: first, path: "a.txt", text: "crafted", message: "crafted")
        let marker = try tempDir().appending(path: "fsmonitor-ran")
        let hookMarker = dir.deletingLastPathComponent().appending(path: "hook-ran")
        try h.f.write(".git/HEAD", "ref: refs/heads/evil\n", in: dir)
        try h.f.write(".git/refs/heads/evil", crafted + "\n", in: dir)
        try h.f.write(".git/config", "[core]\n\tfsmonitor = touch \(marker.path)\n\thooksPath = hooks\n", in: dir)
        try FakeTools.install(at: dir.appending(path: ".git/hooks/post-checkout"), "touch \"$(dirname \"$0\")/../../../hook-ran\"")
        try h.f.write("dir/.git", "gitdir: ../.git\n", in: dir)
        try h.f.write("a.txt", "rewritten by the build", in: dir)

        let next = try h.commit(["a.txt": "one v2", "c.txt": "new"], removing: ["dir/b.txt"], message: "next")
        let again = try EngineExport.export(store: h.store, company: h.company, runId: runId, commit: next)
        #expect(again.path == dir.path, "the same place")
        let (files, names) = try Self.files(again)
        #expect(files == (try h.tree(next)), "exactly the next commit")
        #expect(files["a.txt"] == "one v2" && files["dir/b.txt"] == nil)
        #expect(!names.contains(".git"), "the crafted .git dir and .git file are gone: \(names)")
        #expect(!Self.exists(again.appending(path: "dir")))
        #expect(!Self.exists(marker), "the crafted fsmonitor never ran")
        #expect(!Self.exists(hookMarker), "the crafted hook never ran")
        EngineExport.remove(store: h.store, company: h.company, runId: runId)
    }

    /// Replaces the plan's `exportIndexIsEngineOnly` (PR-2): the export is made from the engine repository (the commit is
    /// fetched there by SHA), not from the workspace's index, HEAD or working files, and the workspace's `.git` is left as it was.
    @Test func exportComesFromTheEngineRepository() throws {
        let h = try Home(files: ["a.txt": "one", "dir/b.txt": "two"])
        let main = try h.f.git(["rev-parse", "refs/heads/main"])
        // The workspace says otherwise everywhere: another branch checked out with other content, a staged file, a dirty file.
        try h.f.git(["checkout", "-q", "-b", "other"])
        try h.f.write("a.txt", "other branch")
        try h.f.git(["commit", "-q", "-am", "other"])
        try h.f.write("staged.txt", "staged")
        try h.f.git(["add", "staged.txt"])
        try h.f.write("dir/b.txt", "dirty")
        let index = try Data(contentsOf: h.f.root.appending(path: ".git/index"))
        let head = try String(contentsOf: h.f.root.appending(path: ".git/HEAD"), encoding: .utf8)

        let dir = try EngineExport.export(store: h.store, company: h.company, runId: "prev-s2-engine", commit: main)
        let (files, names) = try Self.files(dir)
        #expect(files == (try h.tree(main)))
        #expect(files["a.txt"] == "one" && files["dir/b.txt"] == "two" && files["staged.txt"] == nil)
        #expect(!names.contains(".git"))
        // The engine repository holds the commit (fetched by SHA); the workspace's index and HEAD are untouched.
        let engine = h.store.gitWorkspace(root: h.f.root, companyId: h.company.id).mergeRepositoryPath
        #expect(!engine.path.hasPrefix(h.company.workspacePath))
        #expect((try? GitFixture.plainGit(["cat-file", "-e", "\(main)^{commit}"], in: engine)) != nil, "the commit is in the engine repository")
        #expect(try Data(contentsOf: h.f.root.appending(path: ".git/index")) == index)
        #expect(try String(contentsOf: h.f.root.appending(path: ".git/HEAD"), encoding: .utf8) == head)
        #expect(try String(contentsOf: h.f.root.appending(path: "dir/b.txt"), encoding: .utf8) == "dirty")
        // An unknown commit or a bad run id is refused, and nothing is left at that place.
        #expect(throws: (any Error).self) {
            try EngineExport.export(store: h.store, company: h.company, runId: "prev-s2-missing", commit: String(repeating: "a", count: 40))
        }
        #expect(!Self.exists(h.paths.exportDir(runId: "prev-s2-missing")))
        #expect(throws: (any Error).self) { try EngineExport.export(store: h.store, company: h.company, runId: "../escape", commit: main) }
        EngineExport.remove(store: h.store, company: h.company, runId: "prev-s2-engine")
    }
}
