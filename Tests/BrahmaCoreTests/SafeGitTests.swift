import Testing
import Foundation
@testable import BrahmaCore

/// `SafeGit`: every call hardened through `GitCommand`, revs verified by shape and reachability, sizes checked before reads,
/// worktree diffs built from bytes `SafeFS` checked.
@Suite(.scratch) struct SafeGitTests {
    /// Records every call; answers from `respond`, or with a plausible default per subcommand.
    final class RecordingRunner: GitProcessRunning, @unchecked Sendable {
        struct Call { let args: [String]; let env: [String: String]; let stdin: Data?; let timeout: Duration; let outputCap: Int }
        private let lock = NSLock()
        private var recorded: [Call] = []
        var calls: [Call] { lock.withLock { recorded } }
        var respond: (@Sendable ([String]) throws -> (status: Int32, stdout: Data, stderr: Data))?
        /// How long each call takes; past the timeout the runner reports a kill, as the live one does.
        var delay: TimeInterval = 0
        static let sha = String(repeating: "a", count: 40)

        func run(args: [String], env: [String: String], stdin: Data?, timeout: Duration, outputCap: Int) throws -> (status: Int32, stdout: Data, stderr: Data) {
            lock.withLock { recorded.append(Call(args: args, env: env, stdin: stdin, timeout: timeout, outputCap: outputCap)) }
            let limit = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
            if delay > limit {
                Thread.sleep(forTimeInterval: limit)
                throw SafeGitError.timedOut
            }
            if let respond { return try respond(args) }
            let sub = args.first(where: { !$0.hasPrefix("-") && $0 != "git" && !$0.hasPrefix("/") && !$0.contains("=") }) ?? ""
            let text: String
            switch sub {
            case "rev-parse": text = Self.sha + "\n"
            case "cat-file": text = args.contains("-s") ? "5\n" : "hello"
            case "log", "rev-list", "merge-base": text = Self.sha + "\n"
            case "hash-object": text = Self.sha + "\n"
            default: text = ""
            }
            return (0, Data(text.utf8), Data())
        }
    }

    /// A real workspace repository with one commit on `main` and the item worktree `ENG-1`.
    struct Repo {
        let f: GitFixture
        let wt: URL
        let fs: SafeFS
        var root: URL { f.root }
        init() throws {
            f = try GitFixture(files: ["README.md": "hello\n", "src/a.txt": "one\n"])
            wt = try f.ws.addWorktree(key: "ENG-1")
            fs = try SafeFS(workspace: f.root, ownHandle: "eng-1")
        }
        func head(_ ref: String) throws -> String { try f.git(["rev-parse", "--verify", ref + "^{commit}"]) }
    }

    @Test func everyCallIsHardened() throws {
        let r = try Repo()
        let runner = RecordingRunner()
        let git = SafeGit(workspace: r.root, runner: runner)
        let sha = RecordingRunner.sha
        let verified = try git.verifyRev(sha, reachableFrom: ["main"])
        #expect(verified == sha)
        _ = try git.head("main")
        _ = try git.mergeBase("main", "item/ENG-1")
        _ = try git.isAncestor(sha, of: sha)
        _ = try git.blobSize(rev: sha, path: "src/a.txt")
        _ = try git.catFile(rev: sha, path: "src/a.txt", binary: false)
        _ = try git.lsTree(rev: sha, cap: 10)
        _ = try git.diff(base: sha, head: sha, path: "src/a.txt")
        _ = try git.show(commit: sha)
        _ = try git.revList(sha, sha)
        _ = try git.logShas(range: "\(sha)..\(sha)", path: "src/a.txt")
        _ = try git.recentPaths(rev: sha, commits: 5)
        try git.updateShareRef("m1", to: sha)
        try git.deleteShareRef("m1")
        try git.expireAndPrune()
        let calls = runner.calls
        #expect(calls.count >= 14)
        let gitDir = r.root.appending(path: ".git").path
        for call in calls {
            let a = call.args, env = call.env
            #expect(env["GIT_DIR"] == gitDir, "\(a)")
            #expect(env["GIT_CONFIG_NOSYSTEM"] == "1" && env["GIT_CONFIG_GLOBAL"] == "/dev/null", "\(a)")
            #expect(env["GIT_LITERAL_PATHSPECS"] == "1" && env["GIT_TERMINAL_PROMPT"] == "0", "\(a)")
            #expect(env["GIT_COMMON_DIR"] == gitDir, "\(a)")
            for flag in ["core.attributesFile=/dev/null", "core.fsmonitor=false", "core.hooksPath=/dev/null", "diff.external=",
                         "core.untrackedCache=false"] {
                if let i = a.firstIndex(of: flag) { #expect(i > 0 && a[i - 1] == "-c", "\(a)") } else { Issue.record("\(flag) missing from \(a)") }
            }
            let sub = a.first(where: { !$0.hasPrefix("-") && $0 != "git" && !$0.hasPrefix("/") && !$0.contains("=") }) ?? ""
            if ["diff", "show", "log"].contains(sub) {
                #expect(a.contains("--no-textconv") && a.contains("--no-ext-diff"), "\(a)")
            }
            // Every rev follows `--end-of-options`; every path follows `--`.
            if let revIndex = a.firstIndex(where: { $0.contains(sha) }), !a.contains("update-ref") {
                let end = a.firstIndex(of: "--end-of-options")
                #expect(end != nil && end! < revIndex, "\(a)")
            }
            if let pathIndex = a.firstIndex(of: "src/a.txt") {
                let dashes = a.firstIndex(of: "--")
                #expect(dashes != nil && dashes! < pathIndex, "\(a)")
            }
            #expect(call.outputCap == SafeGit.outputCap && call.timeout == SafeGit.timeout)
        }
        #expect(calls.contains { $0.args.contains("update-ref") && $0.args.contains("refs/brahma/shares/m1") })
    }

    @Test func craftedAttributesFilterAndTextconvNotRun() throws {
        let r = try Repo()
        let marker = try tempDir().appending(path: "ran")
        try r.f.git(["config", "filter.evil.clean", "touch \(marker.path)"])
        try r.f.git(["config", "filter.evil.smudge", "touch \(marker.path)"])
        try r.f.git(["config", "diff.evil.textconv", "touch \(marker.path)"])
        try r.f.write(".gitattributes", "* filter=evil diff=evil\n", in: r.wt)
        try r.f.write("src/a.txt", "two\n", in: r.wt)
        let git = SafeGit(workspace: r.root)
        let main = try r.head("main")
        var threw = 0
        func attempt(_ body: () throws -> Void) { do { try body() } catch { threw += 1 } }
        attempt { _ = try git.diff(base: main, head: main, path: nil) }
        attempt { _ = try git.show(commit: main) }
        attempt { _ = try git.catFile(rev: main, path: "src/a.txt", binary: false) }
        attempt { _ = try git.hashObject(from: try r.fs.open("src/a.txt", inWorktree: "ENG-1", maxBytes: 1 << 20)) }
        attempt { _ = try git.worktreeDiff(key: "ENG-1", worktree: r.wt, tempDir: try tempDir(), fs: r.fs) }
        #expect(!FileManager.default.fileExists(atPath: marker.path), "a repository-named program ran")
        // The repository's config names programs: `GitCommand` refuses every call (3a), none runs with them.
        #expect(threw == 5)
    }

    @Test func perWorktreeConfigIgnored() throws {
        let r = try Repo()
        let marker = try tempDir().appending(path: "ran")
        try r.f.git(["config", "extensions.worktreeConfig", "true"])
        let admin = r.root.appending(path: ".git/worktrees/ENG-1")
        try "[core]\n\tfsmonitor = touch \(marker.path)\n".write(to: admin.appending(path: "config.worktree"), atomically: true, encoding: .utf8)
        // The agent's own index, crafted: bytes the engine must neither read as truth nor rewrite.
        let indexFile = admin.appending(path: "index")
        try Data("DIRC crafted by the agent".utf8).write(to: indexFile)
        let before = try Data(contentsOf: indexFile)
        try r.f.write("src/a.txt", "two\n", in: r.wt)
        let git = SafeGit(workspace: r.root)
        let diff = try git.worktreeDiff(key: "ENG-1", worktree: r.wt, tempDir: try tempDir(), fs: r.fs)
        #expect(diff.files.map(\.path) == ["src/a.txt"])
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the per-worktree fsmonitor ran")
        #expect(try Data(contentsOf: indexFile) == before, "the agent's index was rewritten")
    }

    @Test(arguments: ["HEAD", "main", "--output=/tmp/x", "a1b2c3", "a1b2c3d^", "A1B2C3D", "a1b2c3d~1", "", "a1b2c3d e", "refs/heads/main"])
    func nonHexRevRefused(_ rev: String) throws {
        let ws = try tempDir()
        let runner = RecordingRunner()
        let git = SafeGit(workspace: ws, runner: runner)
        #expect(throws: SafeGitError.badRev) { try git.verifyRev(rev, reachableFrom: ["main"]) }
        #expect(throws: SafeGitError.badRev) { try git.catFile(rev: rev, path: "x", binary: false) }
        #expect(throws: SafeGitError.badRev) { try git.lsTree(rev: rev, cap: 10) }
        #expect(runner.calls.isEmpty, "git ran for a rev that is not a sha")
    }

    @Test func unreachableShaRefused() throws {
        let r = try Repo()
        let git = SafeGit(workspace: r.root)
        let main = try r.head("main")
        let tree = try r.f.git(["rev-parse", "\(main)^{tree}"])
        let dangling = try r.f.git(["commit-tree", tree, "-m", "dangling"])
        #expect(throws: SafeGitError.unreachable) { try git.verifyRev(dangling, reachableFrom: ["main", "item/ENG-1"]) }
        #expect(try git.verifyRev(main, reachableFrom: ["main"]) == main)
        #expect(try git.verifyRev(String(main.prefix(12)), reachableFrom: ["item/ENG-1"]) == main)
        try r.f.git(["update-ref", "refs/heads/item/ENG-1", dangling])
        #expect(try git.verifyRev(dangling, reachableFrom: ["main", "item/ENG-1"]) == dangling)
        let other = try r.f.git(["commit-tree", tree, "-m", "pinned"])
        try r.f.git(["update-ref", "refs/brahma/shares/x", other])
        #expect(throws: SafeGitError.unreachable) { try git.verifyRev(other, reachableFrom: ["main"]) }
        #expect(try git.verifyRev(other, reachableFrom: ["refs/brahma/shares/x"]) == other)
        // A sha that is no commit, and a ref name that is not an engine record's shape.
        #expect(throws: SafeGitError.badRev) { try git.verifyRev(tree, reachableFrom: ["main"]) }
        #expect(throws: SafeGitError.badRef) { try git.verifyRev(main, reachableFrom: ["--all"]) }
        #expect(try git.head("item/ENG-1") == dangling)
        #expect(try git.isAncestor(main, of: main) == true)
        #expect(try git.isAncestor(dangling, of: main) == false)
        let tree2 = try git.lsTree(rev: main, cap: 10)
        #expect(tree2.entries.map(\.path) == ["README.md", "src/a.txt"] && tree2.truncated == false)
        #expect(tree2.entries.first?.size == 6 && tree2.entries.first?.mode == "100644")
        #expect(try git.lsTree(rev: main, cap: 1).truncated == true)
        #expect(try git.blobSize(rev: main, path: "src/a.txt") == 4)
        #expect(try git.catFile(rev: main, path: "src/a.txt", binary: false) == Data("one\n".utf8))
        let shown = try git.show(commit: main)
        #expect(shown.subject == "Import existing files" && shown.author == "Brahma")
        #expect(shown.diff.stat.map(\.path) == ["README.md", "src/a.txt"] && shown.diff.patch.contains("+hello"))
    }

    @Test func sizeCheckedBeforeRead() throws {
        let ws = try tempDir()
        let runner = RecordingRunner()
        runner.respond = { args in
            if args.contains("cat-file"), args.contains("-s") { return (0, Data("3145728\n".utf8), Data()) }
            Issue.record("unexpected call \(args)")
            return (1, Data(), Data())
        }
        let git = SafeGit(workspace: ws, runner: runner)
        let sha = RecordingRunner.sha
        #expect(throws: SafeGitError.tooLarge(3_145_728)) { try git.catFile(rev: sha, path: "big.txt", binary: false) }
        #expect(runner.calls.count == 1 && runner.calls[0].args.contains("-s") && !runner.calls[0].args.contains("-p"))
        // The binary cap is larger: the same blob is read as binary.
        runner.respond = { args in
            if args.contains("-s") { return (0, Data("3145728\n".utf8), Data()) }
            return (0, Data(repeating: 0, count: 3_145_728), Data())
        }
        #expect(try git.catFile(rev: sha, path: "big.bin", binary: true).count == 3_145_728)
    }

    @Test func timeoutKillsAndCapsOutput() throws {
        let ws = try tempDir()
        let runner = RecordingRunner()
        runner.delay = 1
        let git = SafeGit(workspace: ws, runner: runner, timeout: .milliseconds(200))
        let started = Date()
        #expect(throws: SafeGitError.timedOut) { try git.head("main") }
        #expect(Date().timeIntervalSince(started) < 0.9)
        #expect(runner.calls.first?.timeout == .milliseconds(200))
        runner.delay = 0
        runner.respond = { _ in (0, Data(repeating: UInt8(ascii: "a"), count: 9 << 20), Data()) }
        #expect(throws: SafeGitError.outputTooLarge) { try git.head("main") }
        // The live runner, through `GitCommand`: a git that outlives the injected timeout is killed and reported the same way
        // (the alias sleeps far longer than any load-delayed timer, so the kill always comes first).
        let r = try Repo()
        let live = SafeGit(workspace: r.root, timeout: .milliseconds(200))
        #expect(throws: SafeGitError.timedOut) { try live.testOnlyRun(["-c", "alias.zz=!sleep 30", "zz"]) }
    }

    @Test func worktreeDiffAgainstBase() throws {
        let r = try Repo()
        let git = SafeGit(workspace: r.root)
        try r.f.write("src/b.txt", "committed\n", in: r.wt)
        try r.f.git(["add", "src/b.txt"], in: r.wt)
        try r.f.git(["commit", "-q", "-m", "add b"], in: r.wt)
        try r.f.write("src/a.txt", "one\nuncommitted\n", in: r.wt)
        let base = try git.mergeBase("main", "item/ENG-1")
        #expect(base == (try r.head("main")))
        let since = try git.worktreeDiff(key: "ENG-1", worktree: r.wt, against: base, tempDir: try tempDir(), fs: r.fs)
        #expect(since.files.map { "\($0.status) \($0.path)" } == ["M src/a.txt", "A src/b.txt"])
        #expect(since.files.map(\.added) == [1, 1] && since.files.map(\.removed) == [0, 0])
        #expect(since.patch.contains("+uncommitted") && since.patch.contains("+committed"))
        #expect(since.truncated == false)
        let onlyUncommitted = try git.worktreeDiff(key: "ENG-1", worktree: r.wt, tempDir: try tempDir(), fs: r.fs)
        #expect(onlyUncommitted.files.map(\.path) == ["src/a.txt"])
        #expect(onlyUncommitted.blobShas["src/a.txt"] == (try r.f.git(["hash-object", "src/a.txt"], in: r.wt)))
        #expect(onlyUncommitted.files.first?.bytes == 16)
    }

    @Test func worktreeDiffMatchesGitStatus() throws {
        let r = try Repo()
        let git = SafeGit(workspace: r.root)
        try r.f.write("src/a.txt", "changed\n", in: r.wt)
        try r.f.write("new/untracked.bin", "\u{0}\u{1}binary\u{2}", in: r.wt)
        try FileManager.default.removeItem(at: r.wt.appending(path: "README.md"))
        let status = try r.f.git(["status", "--porcelain", "--untracked-files=all"], in: r.wt)
            .split(separator: "\n").map { String($0.split(separator: " ").last!) }.sorted()
        let diff = try git.worktreeDiff(key: "ENG-1", worktree: r.wt, tempDir: try tempDir(), fs: r.fs)
        #expect(diff.files.map(\.path).sorted() == status)
        let byPath = Dictionary(uniqueKeysWithValues: diff.files.map { ($0.path, $0) })
        #expect(byPath["README.md"]?.status == "D" && byPath["README.md"]?.bytes == 0)
        #expect(byPath["src/a.txt"]?.status == "M" && byPath["src/a.txt"]?.added == 1 && byPath["src/a.txt"]?.removed == 1)
        #expect(byPath["new/untracked.bin"]?.status == "A" && byPath["new/untracked.bin"]?.added == nil, "binary: no line counts")
        for path in ["src/a.txt", "new/untracked.bin"] {
            #expect(diff.blobShas[path] == (try r.f.git(["hash-object", path], in: r.wt)), "\(path)")
        }
        #expect(diff.blobShas["README.md"] == nil)
        // A planted link in the worktree refuses the diff: nothing is read through it.
        try FileManager.default.createSymbolicLink(at: r.wt.appending(path: "leak"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        #expect(throws: SafeGitError.self) { try git.worktreeDiff(key: "ENG-1", worktree: r.wt, tempDir: try tempDir(), fs: r.fs) }
    }

    @Test func onlyShareRefsWritable() throws {
        let r = try Repo()
        let git = SafeGit(workspace: r.root)
        let main = try r.head("main")
        #expect(throws: SafeGitError.badRef) { try git.updateShareRef("x/../../heads/main", to: main) }
        #expect(throws: SafeGitError.badRef) { try git.updateShareRef("../heads/main", to: main) }
        #expect(throws: SafeGitError.badRef) { try git.updateShareRef("-x", to: main) }
        #expect(throws: SafeGitError.badRef) { try git.deleteShareRef("a/b") }
        #expect(throws: SafeGitError.badRev) { try git.updateShareRef("ok", to: "main") }
        try git.updateShareRef("ok", to: main)
        #expect(try r.f.git(["rev-parse", "refs/brahma/shares/ok"]) == main)
        #expect(try r.head("main") == main)
        try git.deleteShareRef("ok")
        #expect(try r.f.git(["rev-parse", "--verify", "-q", "refs/brahma/shares/ok"], allowFailure: true) == "")
        try git.expireAndPrune()
    }
}
