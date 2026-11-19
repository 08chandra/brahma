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
            if delay > 0 { Thread.sleep(forTimeInterval: min(delay, limit)) }
            if delay > limit { throw SafeGitError.timedOut }
            if let respond { return try respond(args) }
            let sub = args.first(where: { !$0.hasPrefix("-") && $0 != "git" && $0 != "." && !$0.hasPrefix("/") && !$0.contains("=") }) ?? ""
            let text: String
            switch sub {
            case "rev-parse": text = Self.sha + "\n"
            case "cat-file": text = args.contains("--batch-check") ? Self.sha + " missing\n" : args.contains("-s") ? "5\n" : "hello"
            case "log", "rev-list", "merge-base": text = Self.sha + "\n"
            case "hash-object":
                let paths = stdin.map { $0.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: true).count } ?? 1
                text = String(repeating: Self.sha + "\n", count: max(1, paths))
            case "check-ignore": return (1, Data(), Data())
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
        try git.expireAndPrune(purged: [sha])
        _ = try git.worktreeDiff(key: "ENG-1", worktree: r.wt, against: sha, tempDir: try tempDir(), fs: r.fs)
        let calls = runner.calls
        #expect(calls.count >= 22)
        // No process of the call has the agent's worktree (or `.`) as its work tree or directory: worktreeDiff's run in the
        // engine-owned shadow directory of the call, everything else in the workspace.
        for call in calls {
            #expect(call.env["GIT_WORK_TREE"] != r.wt.path && call.env["GIT_WORK_TREE"] != "." && call.args[1] != r.wt.path, "\(call.args.prefix(3))")
        }
        #expect(calls.contains { $0.args.contains("read-tree") && $0.env["GIT_WORK_TREE"]!.contains("/shadow") })
        #expect(!calls.contains { $0.args.contains("ls-files") }, "git enumerated the worktree")
        #expect(!calls.contains { $0.args.contains("--name-status") && !$0.args.contains("--cached") }, "git compared the worktree")
        let gitDir = r.root.appending(path: ".git").path
        for call in calls {
            let a = call.args, env = call.env
            #expect(env["GIT_DIR"] == gitDir, "\(a)")
            #expect(env["GIT_CONFIG_NOSYSTEM"] == "1" && env["GIT_CONFIG_GLOBAL"] == "/dev/null", "\(a)")
            // `check-ignore` refuses literal pathspecs; every other process gets them.
            #expect((env["GIT_LITERAL_PATHSPECS"] == "1") == !a.contains("check-ignore") && env["GIT_TERMINAL_PROMPT"] == "0", "\(a)")
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
            if let revIndex = a.firstIndex(where: { $0.contains(sha) }) {
                let end = a.firstIndex(of: "--end-of-options")
                #expect(end != nil && end! < revIndex, "\(a)")
            }
            if let pathIndex = a.firstIndex(of: "src/a.txt") {
                let dashes = a.firstIndex(of: "--")
                #expect(dashes != nil && dashes! < pathIndex, "\(a)")
            }
            #expect(call.outputCap == SafeGit.outputCap && call.timeout <= SafeGit.timeout)
        }
        #expect(calls.contains { $0.args.contains("update-ref") && $0.args.contains("refs/brahma/shares/m1") })
        // worktreeDiff's own processes went the same way: read-tree, ls-files, one hash-object over engine copies, update-index,
        // diff --cached.
        func has(_ parts: [String]) -> Bool { calls.contains { c in parts.allSatisfy(c.args.contains) } }
        #expect(has(["read-tree", "--end-of-options", sha]))
        #expect(has(["ls-tree", "-r", "-l", "--end-of-options", sha]))
        #expect(has(["check-ignore", "-z", "--stdin", "--no-index"]))
        #expect(has(["hash-object", "-w", "--no-filters", "--stdin-paths"]))
        #expect(has(["update-index", "--index-info"]))
        #expect(has(["diff", "--cached", "--numstat"]) && has(["diff", "--cached", "-p"]))
        #expect(!calls.contains { $0.args.contains("hash-object") && $0.args.contains(where: { $0.hasSuffix("src/a.txt") }) },
                "hash-object was given an agent path")
        #expect(calls.contains { $0.args.contains("repack") && $0.args.contains("-a") && $0.args.contains("-d") })
        #expect(has(["reflog", "expire", "--expire=now", "--expire-unreachable=now", "--all"]))
        #expect(calls.contains { $0.args.contains("--batch-check") && $0.stdin == Data((sha + "\n").utf8) }, "the purge did not verify its objects")
    }

    /// The live runner maps `GitCommand`'s timeout kill to `.timedOut`: a `git` on PATH that only sleeps, a short injected
    /// timeout, and no bound on how late the kill comes (only that it does).
    @Test func liveRunnerMapsTimeoutKill() throws {
        let r = try Repo()
        let bin = try FakeTools.bin(["git": "#!/bin/sh\nexec sleep 600\n"])
        let env = ["PATH": bin.path + ":/usr/bin:/bin", "GIT_DIR": r.root.appending(path: ".git").path, "GIT_WORK_TREE": r.root.path]
        #expect(throws: SafeGitError.timedOut) {
            try LiveGitRunner().run(args: ["status"], env: env, stdin: nil, timeout: .milliseconds(200), outputCap: 1 << 20)
        }
        // An anchored command line without its descriptor is refused, never run in this process's directory.
        #expect(throws: SafeGitError.self) {
            try LiveGitRunner().run(args: ["-C", ".", "status"], env: ["GIT_DIR": env["GIT_DIR"]!, "GIT_WORK_TREE": "."], stdin: nil, timeout: .seconds(1), outputCap: 1 << 20)
        }
    }

    /// M3: a caller's `extraConfig` is added before `configFlags`, so a hardened flag always wins.
    @Test func extraConfigCannotOverrideHardening() throws {
        var g = GitCommand(gitDir: URL(fileURLWithPath: "/x/.git"), workTree: URL(fileURLWithPath: "/x"), commonDir: nil)
        g.extraConfig = ["-c", "core.hooksPath=/evil", "-c", "core.untrackedCache=false"]
        let a = g.arguments(["status"], attrSource: nil)
        let evil = a.firstIndex(of: "core.hooksPath=/evil"), hard = a.lastIndex(of: "core.hooksPath=/dev/null")
        #expect(evil != nil && hard != nil && evil! < hard!, "\(a)")
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
        // The live runner's kill is `GitCommand`'s timer (3a's tests); under the full suite's load that dispatch timer can be
        // starved for longer than any sleeping alias here, so no live leg: the seam's mapping is what this test owns.
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
        // A planted link in the worktree is a link entry (its target string is the blob, as git stores links): never followed.
        try FileManager.default.createSymbolicLink(at: r.wt.appending(path: "leak"), withDestinationURL: URL(fileURLWithPath: "/etc/hosts"))
        let withLink = try git.worktreeDiff(key: "ENG-1", worktree: r.wt, tempDir: try tempDir(), fs: r.fs)
        let leak = try #require(withLink.files.first { $0.path == "leak" })
        #expect(leak.status == "A" && leak.bytes == "/etc/hosts".utf8.count)
        #expect(withLink.blobShas["leak"] == SafeGit.blobId(of: Data("/etc/hosts".utf8), sha256: false))
        #expect(withLink.patch.contains("+/etc/hosts") && !withLink.patch.contains("localhost"), "the link was followed")
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
        #expect(throws: SafeGitError.badRev, "an abbreviation is not a verified id") { try git.updateShareRef("ok", to: String(main.prefix(12))) }
        try git.updateShareRef("ok", to: main)
        #expect(try r.f.git(["rev-parse", "refs/brahma/shares/ok"]) == main)
        #expect(try r.head("main") == main)
        try git.deleteShareRef("ok")
        #expect(try r.f.git(["rev-parse", "--verify", "-q", "refs/brahma/shares/ok"], allowFailure: true) == "")
        // A purged share's objects are gone at once: a commit only the share ref kept is pruned by `expireAndPrune`.
        let tree = try r.f.git(["rev-parse", "\(main)^{tree}"])
        let secret = try r.f.git(["commit-tree", tree, "-m", "secret"])
        try git.updateShareRef("s", to: secret)
        try r.f.git(["repack", "-a", "-d", "-q"])     // an agent's gc may have packed it: a packed copy must die too
        #expect(throws: SafeGitError.purgeIncomplete(remaining: 1), "still pinned by the share ref: the purge must say so") {
            try git.expireAndPrune(purged: [secret])
        }
        #expect(try r.f.git(["cat-file", "-e", secret]) == "", "still reachable through the share ref")
        let item = try r.head("item/ENG-1")
        try git.deleteShareRef("s")
        try git.expireAndPrune(purged: [secret])
        #expect(try r.head("item/ENG-1") == item && (try r.head("main")) == main, "a branch moved")
        #expect(throws: SafeGitError.badRev) { try git.expireAndPrune(purged: [String(main.prefix(12))]) }
        #expect(try r.f.git(["cat-file", "-e", secret], allowFailure: true) == "")
        #expect(throws: (any Error).self, "the purged object is still in the repository") { try r.f.git(["cat-file", "-e", secret]) }
        #expect(try r.f.git(["cat-file", "-e", main]) == "", "a reachable commit survived")
    }

    /// R1: a purged blob that only reflogs reach (the item branch's, moved back; the worktree's `HEAD`; a moved share ref's
    /// with `core.logAllRefUpdates=always`) is gone after the purge, or the purge says it is incomplete.
    @Test func purgeIsFailClosed() throws {
        let r = try Repo()
        let git = SafeGit(workspace: r.root)
        try r.f.git(["config", "core.logAllRefUpdates", "always"])
        let before = try r.head("item/ENG-1")
        try r.f.write("secret.txt", "the secret\n", in: r.wt)
        try r.f.git(["add", "secret.txt"], in: r.wt)
        try r.f.git(["commit", "-q", "-m", "secret"], in: r.wt)
        let commit = try r.head("item/ENG-1")
        let blob = try r.f.git(["rev-parse", "\(commit):secret.txt"])
        // Only reflogs reach them now: the branch moved back (its reflog and the worktree HEAD's keep the commit), and a share
        // ref moved off it (its own reflog keeps it).
        try r.f.git(["reset", "-q", "--hard", before], in: r.wt)
        try git.updateShareRef("p", to: commit)
        try git.updateShareRef("p", to: before)
        #expect(try r.f.git(["reflog", "show", "refs/brahma/shares/p"]).contains(String(commit.prefix(7))))
        #expect(try r.f.git(["cat-file", "-e", blob]) == "" && (try r.f.git(["cat-file", "-e", commit])) == "")
        try git.expireAndPrune(purged: [blob, commit])
        #expect(throws: (any Error).self, "the purged blob is still in the repository") { try r.f.git(["cat-file", "-e", blob]) }
        #expect(throws: (any Error).self, "the purged commit is still in the repository") { try r.f.git(["cat-file", "-e", commit]) }
        #expect(try r.head("item/ENG-1") == before && (try r.f.git(["rev-parse", "refs/brahma/shares/p"])) == before)
        // An object a branch still reaches is reported, never silently kept.
        #expect(throws: SafeGitError.purgeIncomplete(remaining: 1)) { try git.expireAndPrune(purged: [before]) }
    }

    /// Forwards to the live runner (anchored when asked) and runs `after` once, right after the first process whose arguments
    /// hold `trigger` returns; keeps that process's stdout.
    final class SwapRunner: GitProcessRunning, @unchecked Sendable {
        private let live = LiveGitRunner()
        private let lock = NSLock()
        let trigger: String
        /// Runs once, right before the first process whose arguments hold `trigger` starts (its startup window).
        var before: (@Sendable () throws -> Void)?
        var after: (@Sendable () throws -> Void)?
        private(set) var triggered: Data?
        /// Every process's arguments and stdout, in order.
        private(set) var captured: [(args: [String], stdout: Data)] = []
        init(trigger: String) { self.trigger = trigger }
        func stdout(of sub: String) -> String { String(decoding: captured.first { $0.args.contains(sub) }?.stdout ?? Data(), as: UTF8.self) }
        func run(args: [String], env: [String: String], stdin: Data?, timeout: Duration, outputCap: Int) throws -> (status: Int32, stdout: Data, stderr: Data) {
            try run(args: args, env: env, stdin: stdin, timeout: timeout, outputCap: outputCap, workTreeDescriptor: nil)
        }
        func run(args: [String], env: [String: String], stdin: Data?, timeout: Duration, outputCap: Int, workTreeDescriptor: Int32?) throws -> (status: Int32, stdout: Data, stderr: Data) {
            if args.contains(trigger), let pre = lock.withLock({ let b = before; before = nil; return b }) { try pre() }
            let out = try live.run(args: args, env: env, stdin: stdin, timeout: timeout, outputCap: outputCap, workTreeDescriptor: workTreeDescriptor)
            lock.withLock { captured.append((args, out.stdout)) }
            if args.contains(trigger), let body = lock.withLock({ let b = after; after = nil; return b }) {
                lock.withLock { triggered = out.stdout }
                try body()
            }
            return out
        }
    }

    static func atime(_ url: URL) -> (Int, Int) {
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return (-1, -1) }
        return (st.st_atimespec.tv_sec, st.st_atimespec.tv_nsec)
    }

    /// R2/R3: after git's first step the agent swaps the worktree's root entry for a link to an outside directory. The check
    /// right after that process sees the path no longer is the held directory and refuses the whole diff with the generic text;
    /// no further process runs, nothing outside is listed or read, and no outside name appears anywhere.
    @Test func worktreeDiffRefusesRootSwapBetweenProcesses() throws {
        let r = try Repo()
        try r.f.write("src/a.txt", "changed\n", in: r.wt)
        let outside = try tempDir().appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside.appending(path: "src"), withIntermediateDirectories: true)
        let marker = outside.appending(path: "SECRET-MARKER.txt")
        try "outside bytes\n".write(to: marker, atomically: true, encoding: .utf8)
        let markerAtime = Self.atime(marker)
        let moved = r.wt.appendingPathExtension("moved")
        let runner = SwapRunner(trigger: "read-tree")
        let wt = r.wt
        runner.after = {
            try FileManager.default.moveItem(at: wt, to: moved)
            try FileManager.default.createSymbolicLink(at: wt, withDestinationURL: outside)
        }
        var text = ""
        do {
            _ = try SafeGit(workspace: r.root, runner: runner).worktreeDiff(key: "ENG-1", worktree: r.wt, tempDir: try tempDir(), fs: r.fs)
            Issue.record("a swapped worktree root was accepted")
        } catch { text = "\(error)" }
        #expect(runner.triggered != nil, "the swap never ran")
        #expect(text == "the worktree of ENG-1 is not in place", "\(text)")
        #expect(runner.captured.last?.args.contains("read-tree") == true, "a process ran after the swap: \(runner.captured.map(\.args))")
        #expect(Self.atime(marker) == markerAtime, "the outside marker was read")
    }

    /// R2: an anchored process runs inside the descriptor's directory, whatever path it was given: `rev-parse --show-toplevel`
    /// names the held directory, not the path's target.
    @Test func anchoredGitRunsInTheDescriptor() throws {
        let r = try Repo()
        let fd = open(r.wt.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        try #require(fd >= 0)
        defer { close(fd) }
        let elsewhere = try tempDir()
        var g = GitCommand(gitDir: r.root.appending(path: ".git"), workTree: elsewhere, commonDir: nil)
        g.workTreeDescriptor = fd
        let top = try g.run(["rev-parse", "--show-toplevel"]).text
        let real = realpath(r.wt.path, nil).map { p in defer { free(p) }; return String(cString: p) } ?? r.wt.path
        #expect(top == real, "\(top)")
        #expect(g.arguments(["x"], attrSource: nil).prefix(3) == ["git", "-C", "."] && g.environment()["GIT_WORK_TREE"] == ".")
    }

    /// R4: a `git` planted in the worktree never runs, however PATH is shaped: the executable is resolved in the engine from
    /// absolute PATH entries and exec'd by absolute path; relative and empty entries are stripped from the child's PATH.
    @Test(arguments: [".:/usr/bin:/bin", "/usr/bin::/bin", "bin:/usr/bin:/bin:"]) func plantedGitInWorktreeNeverRuns(_ path: String) throws {
        let r = try Repo()
        let scratch = try tempDir()
        let marker = scratch.appending(path: "planted-marker")
        try FakeTools.install(at: r.wt.appending(path: "git"), "#!/bin/sh\ntouch \"$TMPDIR/planted-marker\"\necho PLANTED\n")
        let gitDir = r.root.appending(path: ".git").path
        // Anchored, through the live runner: the child's working directory IS the worktree holding the planted `git`.
        let fd = open(r.wt.path, O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        try #require(fd >= 0)
        defer { close(fd) }
        let env = ["PATH": path, "TMPDIR": scratch.path, "GIT_DIR": gitDir, "GIT_WORK_TREE": "."]
        let out = try LiveGitRunner().run(args: ["-C", ".", "rev-parse", "--git-dir"], env: env, stdin: nil, timeout: .seconds(10), outputCap: 1 << 20, workTreeDescriptor: fd)
        #expect(out.status == 0 && String(decoding: out.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == gitDir)
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the planted git ran (anchored)")
        // A plain GitCommand call with the same PATH: argv[0] is absolute and not /usr/bin/env, the child's PATH has only
        // absolute entries, the marker never appears.
        final class Seen: @unchecked Sendable { var executable = ""; var argv: [String] = [] }
        let seen = Seen()
        var g = GitCommand(gitDir: r.root.appending(path: ".git"), workTree: r.wt, commonDir: nil)
        g.baseEnvironment = ["PATH": path, "TMPDIR": scratch.path]
        g.spawnObserver = { exe, argv in seen.executable = exe; seen.argv = argv }
        #expect(try g.run(["rev-parse", "--git-dir"]).text == gitDir)
        #expect(seen.executable.hasPrefix("/") && seen.executable.hasSuffix("/git") && seen.executable != "/usr/bin/env" && seen.argv.first == seen.executable, "\(seen.executable)")
        #expect(g.environment()["PATH"] == "/usr/bin:/bin")
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the planted git ran (plain)")
        // The worktree diff itself, with the planted git sitting in the worktree (ignored by name: `FakeTools.install` hard-links
        // the shared script, which SafeFS would refuse as a file with another link; what matters here is that it never runs).
        try r.f.write(".gitignore", "git\n", in: r.wt)
        let diff = try SafeGit(workspace: r.root).worktreeDiff(key: "ENG-1", worktree: r.wt, tempDir: try tempDir(), fs: r.fs)
        #expect(diff.files.map(\.path) == [".gitignore"])
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the planted git ran (worktreeDiff)")
    }

    /// The reviewer's window: the root entry is a link to an outside directory for exactly the time one git process starts and
    /// runs, and is put back after. No process has the worktree as its work tree, so nothing resolves the name: the result is
    /// the real worktree's, the outside file is never listed or read, and no outside name appears anywhere.
    @Test func worktreeDiffImmuneToStartupWindowSwap() throws {
        let r = try Repo()
        try r.f.write("src/a.txt", "changed\n", in: r.wt)
        let outside = try tempDir().appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside.appending(path: "src"), withIntermediateDirectories: true)
        let secret = outside.appending(path: "OUTSIDE-SECRET.txt")
        try "outside bytes\n".write(to: secret, atomically: true, encoding: .utf8)
        try "outside a\n".write(to: outside.appending(path: "src/a.txt"), atomically: true, encoding: .utf8)
        let secretAtime = Self.atime(secret)
        let moved = r.wt.appendingPathExtension("moved")
        let wt = r.wt
        for trigger in ["read-tree", "ls-tree", "check-ignore", "--stdin-paths", "--index-info", "--numstat"] {
            let runner = SwapRunner(trigger: trigger)
            runner.before = {
                try FileManager.default.moveItem(at: wt, to: moved)
                try FileManager.default.createSymbolicLink(at: wt, withDestinationURL: outside)
            }
            runner.after = {
                try FileManager.default.removeItem(at: wt)
                try FileManager.default.moveItem(at: moved, to: wt)
            }
            try r.f.write("new/n.txt", "n\n", in: r.wt)          // a candidate, so check-ignore runs
            let diff = try SafeGit(workspace: r.root, runner: runner).worktreeDiff(key: "ENG-1", worktree: r.wt, tempDir: try tempDir(), fs: r.fs)
            #expect(runner.triggered != nil, "\(trigger): the swap never ran")
            #expect(diff.files.map(\.path) == ["new/n.txt", "src/a.txt"] && diff.patch.contains("+changed"), "\(trigger): \(diff.files)")
            let shown = "\(diff.files) \(diff.patch) \(diff.blobShas) " + runner.captured.map { String(decoding: $0.stdout, as: UTF8.self) }.joined()
            #expect(!shown.contains("OUTSIDE-SECRET") && !shown.contains("outside"), "\(trigger): outside content surfaced")
        }
        #expect(Self.atime(secret) == secretAtime, "the outside file was read")
    }

    /// Ignore rules: directories a `.gitignore` clearly ignores are pruned from the walk, files get git's own verdict (negations
    /// included), nested repositories and `.git` entries are never listed.
    @Test func worktreeDiffHonoursIgnoreRules() throws {
        let r = try Repo()
        try r.f.write(".gitignore", "build/\n*.log\n!keep.log\n", in: r.wt)
        try r.f.write("build/out.bin", "x", in: r.wt)
        try r.f.write("build/deep/more.bin", "x", in: r.wt)
        try r.f.write("a.log", "x", in: r.wt)
        try r.f.write("keep.log", "x", in: r.wt)
        try r.f.write("src/sub.log", "x", in: r.wt)
        try r.f.write("keep.txt", "x", in: r.wt)
        try r.f.write("nested/.git/HEAD", "ref: refs/heads/main\n", in: r.wt)
        try r.f.write("nested/inner.txt", "x", in: r.wt)
        let diff = try SafeGit(workspace: r.root).worktreeDiff(key: "ENG-1", worktree: r.wt, tempDir: try tempDir(), fs: r.fs)
        #expect(diff.files.map(\.path) == [".gitignore", "keep.log", "keep.txt"], "\(diff.files.map(\.path))")
        // With a negation in force nothing is pruned, yet the verdict is still git's: the same set.
        var rules = GitIgnoreRules()
        rules.push("build/\n*.log\n", base: "")
        #expect(rules.prunes(directory: "build") && rules.prunes(directory: "src/build") && !rules.prunes(directory: "src"))
        rules.push("!important/\n", base: "src")
        #expect(!rules.prunes(directory: "build"), "a negation in force must stop pruning")
        rules.truncate(to: 1)
        #expect(rules.prunes(directory: "build"))
    }

    /// The engine's blob ids are git's (a file through `SafeFS`, a link's target), SHA-1 and SHA-256.
    @Test func blobIdsMatchGit() throws {
        let r = try Repo()
        try r.f.write("src/a.txt", "hello\n", in: r.wt)
        let file = try r.fs.open("src/a.txt", inWorktree: "ENG-1", maxBytes: 100)
        #expect(try SafeGit.blobId(of: file, sha256: false) == "ce013625030ba8dba906f756967f9e9ca394464a")
        #expect(try SafeGit.blobId(of: file, sha256: false) == (try r.f.git(["hash-object", "src/a.txt"], in: r.wt)))
        #expect(SafeGit.blobId(of: Data("hello\n".utf8), sha256: false) == "ce013625030ba8dba906f756967f9e9ca394464a")
        #expect(SafeGit.blobId(of: Data(), sha256: false) == "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
        #expect(SafeGit.blobId(of: Data("hello\n".utf8), sha256: true) == SHA256.hex(Data("blob 6\u{0}hello\n".utf8)))
        var sha1 = SHA1()
        sha1.update(Data("abc".utf8))
        #expect(SHA1.hex(digest: sha1.finalize()) == "a9993e364706816aba3e25717850c26c9cd0d89d")
        var long = SHA1()
        for _ in 0..<1000 { long.update(Data(String(repeating: "a", count: 1000).utf8)) }
        #expect(SHA1.hex(digest: long.finalize()) == "34aa973cd4c4daa4f61eeb2bdbad27316534016f")
    }

    /// R2 (ii)/(iii): a subdirectory swapped for a link after git listed its files cannot be read through: the refusal names
    /// nothing agent-controlled or git-reported, and nothing outside is read.
    @Test func worktreeDiffSurvivesMidDiffSymlinkSwap() throws {
        let r = try Repo()
        try r.f.write("new/u.txt", "untracked\n", in: r.wt)
        let outside = try tempDir().appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        let marker = outside.appending(path: "u.txt")
        try "SECRET-BYTES\n".write(to: marker, atomically: true, encoding: .utf8)
        let markerAtime = Self.atime(marker)
        let sub = r.wt.appending(path: "new")
        let runner = SwapRunner(trigger: "check-ignore")
        runner.after = {
            try FileManager.default.moveItem(at: sub, to: sub.appendingPathExtension("moved"))
            try FileManager.default.createSymbolicLink(at: sub, withDestinationURL: outside)
        }
        var text = ""
        do {
            _ = try SafeGit(workspace: r.root, runner: runner).worktreeDiff(key: "ENG-1", worktree: r.wt, tempDir: try tempDir(), fs: r.fs)
            Issue.record("a path behind a planted link was accepted")
        } catch { text = "\(error)" }
        #expect(runner.triggered != nil, "the swap never ran")
        #expect(!text.isEmpty && !text.contains("u.txt") && !text.contains("new") && !text.contains(outside.path) && !text.contains("SECRET"), "\(text)")
        #expect(Self.atime(marker) == markerAtime, "the outside file was read")
    }

    /// A fake for `worktreeDiff`'s processes: an empty base (`ls-tree`), so every file the walk finds in the real worktree is a
    /// change; `hash-object` must never be reached.
    private func fakeForWorktreeDiff(delay: TimeInterval = 0) -> RecordingRunner {
        let runner = RecordingRunner()
        runner.delay = delay
        runner.respond = { args in
            if args.contains("hash-object") { Issue.record("hash-object ran before the caps were checked"); return (1, Data(), Data()) }
            if args.contains("check-ignore") { return (1, Data(), Data()) }
            return (0, Data(), Data())
        }
        return runner
    }

    @Test func worktreeDiffRefusesTooManyFiles() throws {
        let r = try Repo()
        let main = try r.head("main")
        // Three new files plus the two the base holds (the fake's base is empty): five changed paths.
        for name in (1...3).map({ "f\($0).txt" }) { try r.f.write(name, "x", in: r.wt) }
        let runner = fakeForWorktreeDiff()
        let git = SafeGit(workspace: r.root, runner: runner, maxDiffFiles: 4)
        #expect(throws: SafeGitError.tooManyChanges(files: 5, bytes: 0)) {
            try git.worktreeDiff(key: "ENG-1", worktree: r.wt, against: main, tempDir: try tempDir(), fs: r.fs)
        }
        #expect(SafeGitError.tooManyChanges(files: 2001, bytes: 0).description == "too many/too large changes to diff (2001 files, 0 MB)")
        #expect(!runner.calls.contains { $0.args.contains("hash-object") })
        #expect(SafeGit.maxDiffFiles == 2000 && SafeGit.maxDiffBytes == 200 << 20)
        // A base listing past git's output cap is the same refusal, never `.outputTooLarge`.
        let flood = RecordingRunner()
        flood.respond = { args in args.contains("ls-tree") ? (0, Data(repeating: UInt8(ascii: "a"), count: 9 << 20), Data()) : (0, Data(), Data()) }
        #expect(throws: SafeGitError.tooManyChanges(files: 0, bytes: 0)) {
            try SafeGit(workspace: r.root, runner: flood).worktreeDiff(key: "ENG-1", worktree: r.wt, against: main, tempDir: try tempDir(), fs: r.fs)
        }
    }

    /// The descriptors of this process whose kernel path lies under `dir` (other tests' descriptors never do).
    static func descriptors(under dir: URL) -> [String] {
        let prefix = realpath(dir.path, nil).map { p in defer { free(p) }; return String(cString: p) } ?? dir.path
        var found: [String] = []
        for name in (try? FileManager.default.contentsOfDirectory(atPath: "/dev/fd")) ?? [] {
            guard let fd = Int32(name) else { continue }
            var buffer = [CChar](repeating: 0, count: Int(MAXPATHLEN))
            guard fcntl(fd, F_GETPATH, &buffer) == 0 else { continue }
            let path = String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
            if path.hasPrefix(prefix + "/") { found.append(path) }   // files below it; the held directory itself is the anchor
        }
        return found
    }

    /// Looks at the worktree's open descriptors right before the one hashing process runs.
    final class ProbingRunner: GitProcessRunning, @unchecked Sendable {
        private let live = LiveGitRunner()
        let worktree: URL
        private(set) var atHashing: [String]?
        init(worktree: URL) { self.worktree = worktree }
        func run(args: [String], env: [String: String], stdin: Data?, timeout: Duration, outputCap: Int) throws -> (status: Int32, stdout: Data, stderr: Data) {
            try run(args: args, env: env, stdin: stdin, timeout: timeout, outputCap: outputCap, workTreeDescriptor: nil)
        }
        func run(args: [String], env: [String: String], stdin: Data?, timeout: Duration, outputCap: Int, workTreeDescriptor: Int32?) throws -> (status: Int32, stdout: Data, stderr: Data) {
            if args.contains("hash-object") { atHashing = SafeGitTests.descriptors(under: worktree) }
            return try live.run(args: args, env: env, stdin: stdin, timeout: timeout, outputCap: outputCap, workTreeDescriptor: workTreeDescriptor)
        }
    }

    /// I1: descriptors are released per path: a diff of more files than a 256 `maxfiles` limit allows works, no worktree file
    /// is open when the hashing process runs, and none is left open afterwards.
    @Test func worktreeDiffHoldsOneDescriptorAtATime() throws {
        let r = try Repo()
        for n in 1...300 { try r.f.write("many/f\(n).txt", "\(n)\n", in: r.wt) }
        let runner = ProbingRunner(worktree: r.wt)
        let diff = try SafeGit(workspace: r.root, runner: runner).worktreeDiff(key: "ENG-1", worktree: r.wt, tempDir: try tempDir(), fs: r.fs)
        #expect(diff.files.count == 300 && diff.blobShas.count == 300)
        #expect(runner.atHashing == [], "worktree descriptors still open at the hashing step: \(runner.atHashing ?? ["(no hashing ran)"])")
        #expect(Self.descriptors(under: r.wt) == [], "worktree descriptors left open after the call")
    }

    /// Runs `inner` (call B) once, right before the first `hash-object` of the call it serves (call A), then forwards to git.
    final class Interleaver: GitProcessRunning, @unchecked Sendable {
        private let live = LiveGitRunner()
        private let lock = NSLock()
        var inner: (@Sendable () throws -> SafeGit.WorktreeDiff)?
        private(set) var innerResult: SafeGit.WorktreeDiff?
        private(set) var innerError: (any Error)?
        func run(args: [String], env: [String: String], stdin: Data?, timeout: Duration, outputCap: Int) throws -> (status: Int32, stdout: Data, stderr: Data) {
            try run(args: args, env: env, stdin: stdin, timeout: timeout, outputCap: outputCap, workTreeDescriptor: nil)
        }
        func run(args: [String], env: [String: String], stdin: Data?, timeout: Duration, outputCap: Int, workTreeDescriptor: Int32?) throws -> (status: Int32, stdout: Data, stderr: Data) {
            let body: (@Sendable () throws -> SafeGit.WorktreeDiff)? = lock.withLock { let b = inner; inner = nil; return b }
            if args.contains("hash-object"), let body {
                do { let result = try body(); lock.withLock { innerResult = result } } catch { lock.withLock { innerError = error } }
            } else if let body {
                lock.withLock { inner = body }
            }
            return try live.run(args: args, env: env, stdin: stdin, timeout: timeout, outputCap: outputCap, workTreeDescriptor: workTreeDescriptor)
        }
    }

    /// I2: two calls on the same key and `tempDir`, one running inside the other's hashing step, keep their own copies and ids.
    @Test func worktreeDiffCallsAreIndependent() throws {
        let r = try Repo()
        let shared = try tempDir()
        let file = r.wt.appending(path: "shared.txt")
        try "first\n".write(to: file, atomically: true, encoding: .utf8)
        let firstSha = try r.f.git(["hash-object", "shared.txt"], in: r.wt)
        let runner = Interleaver()
        let root = r.root, wt = r.wt, fs = r.fs
        runner.inner = {
            // Call B: the file changes, and B runs to completion (its own call directory) while A waits to hash its copies.
            try "second\n".write(to: file, atomically: true, encoding: .utf8)
            return try SafeGit(workspace: root).worktreeDiff(key: "ENG-1", worktree: wt, tempDir: shared, fs: fs)
        }
        let a = try SafeGit(workspace: r.root, runner: runner).worktreeDiff(key: "ENG-1", worktree: r.wt, tempDir: shared, fs: r.fs)
        if let e = runner.innerError { Issue.record("call B failed: \(e)") }
        let b = try #require(runner.innerResult)
        #expect(a.blobShas["shared.txt"] == firstSha, "A reported B's bytes")
        #expect(b.blobShas["shared.txt"] == (try r.f.git(["hash-object", "shared.txt"], in: r.wt)))
        #expect(a.patch.contains("+first") && b.patch.contains("+second"))
        // Nothing of either call is left in the shared directory.
        #expect(try FileManager.default.contentsOfDirectory(atPath: shared.path).isEmpty)
    }

    /// I3: the worktree root git is pointed at must be the directory SafeFS holds for the key; a swapped entry is refused and
    /// nothing from the link's target reaches the error.
    @Test func worktreeDiffRefusesSwappedWorktree() throws {
        let r = try Repo()
        let git = SafeGit(workspace: r.root)
        let main = try r.head("main")
        let other = try tempDir().appending(path: "elsewhere", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        try "leak".write(to: other.appending(path: "SECRET-NAME.txt"), atomically: true, encoding: .utf8)
        // A worktree URL that is not `.brahma/wt/<key>` is refused before any git runs.
        #expect(throws: SafeGitError.self) { try git.worktreeDiff(key: "ENG-1", worktree: other, against: main, tempDir: try tempDir(), fs: r.fs) }
        // The agent swaps its worktree entry for a link.
        try FileManager.default.moveItem(at: r.wt, to: r.wt.appendingPathExtension("moved"))
        try FileManager.default.createSymbolicLink(at: r.wt, withDestinationURL: other)
        var text = ""
        do { _ = try git.worktreeDiff(key: "ENG-1", worktree: r.wt, against: main, tempDir: try tempDir(), fs: r.fs); Issue.record("not refused") }
        catch { text = "\(error)" }
        #expect(!text.isEmpty && !text.contains("SECRET-NAME") && !text.contains(other.path), "\(text)")
    }

    @Test func worktreeDiffRefusesTooManyBytes() throws {
        let r = try Repo()
        let main = try r.head("main")
        // Four changed paths (the base is empty for the fake), copied in path order: README.md (6) + a.txt (5) passes 10.
        try r.f.write("a.txt", "12345", in: r.wt)
        try r.f.write("b.txt", "123456", in: r.wt)
        let runner = fakeForWorktreeDiff()
        let git = SafeGit(workspace: r.root, runner: runner, maxDiffBytes: 10)
        #expect(throws: SafeGitError.tooManyChanges(files: 4, bytes: 11)) {
            try git.worktreeDiff(key: "ENG-1", worktree: r.wt, against: main, tempDir: try tempDir(), fs: r.fs)
        }
        #expect(!runner.calls.contains { $0.args.contains("hash-object") })
        #expect(SafeGitError.tooManyChanges(files: 2, bytes: 3 << 20).description == "too many/too large changes to diff (2 files, 3 MB)")
    }

    @Test func worktreeDiffOverallTimeout() throws {
        let r = try Repo()
        let main = try r.head("main")
        // Every process is well within its own timeout; the call as a whole is not.
        let runner = fakeForWorktreeDiff(delay: 0.15)
        let git = SafeGit(workspace: r.root, runner: runner, timeout: .milliseconds(400))
        let started = Date()
        #expect(throws: SafeGitError.timedOut) {
            try git.worktreeDiff(key: "ENG-1", worktree: r.wt, against: main, tempDir: try tempDir(), fs: r.fs)
        }
        #expect(Date().timeIntervalSince(started) < 1.5)
        let calls = runner.calls
        #expect(calls.count >= 2 && calls.count <= 4, "\(calls.count) processes ran on a 0.4 s budget at 0.15 s each")
        #expect(calls.allSatisfy { $0.timeout <= .milliseconds(400) })
        #expect(calls.last.map { $0.timeout < .milliseconds(400) } == true, "the last process did not get only what was left")
    }

    /// Counts the processes a live call runs.
    final class CountingRunner: GitProcessRunning, @unchecked Sendable {
        private let live = LiveGitRunner()
        private let lock = NSLock()
        private var n = 0
        var count: Int { lock.withLock { n } }
        func run(args: [String], env: [String: String], stdin: Data?, timeout: Duration, outputCap: Int) throws -> (status: Int32, stdout: Data, stderr: Data) {
            try run(args: args, env: env, stdin: stdin, timeout: timeout, outputCap: outputCap, workTreeDescriptor: nil)
        }
        func run(args: [String], env: [String: String], stdin: Data?, timeout: Duration, outputCap: Int, workTreeDescriptor: Int32?) throws -> (status: Int32, stdout: Data, stderr: Data) {
            lock.withLock { n += 1 }
            return try live.run(args: args, env: env, stdin: stdin, timeout: timeout, outputCap: outputCap, workTreeDescriptor: workTreeDescriptor)
        }
    }

    @Test func worktreeDiffUsesConstantProcesses() throws {
        func processes(files: Int) throws -> Int {
            let r = try Repo()
            for n in 1...files { try r.f.write("new/f\(n).txt", "line \(n)\n", in: r.wt) }
            try r.f.write("src/a.txt", "changed\n", in: r.wt)
            let runner = CountingRunner()
            let diff = try SafeGit(workspace: r.root, runner: runner).worktreeDiff(key: "ENG-1", worktree: r.wt, tempDir: try tempDir(), fs: r.fs)
            #expect(diff.files.count == files + 1 && diff.blobShas.count == files + 1)
            #expect(diff.blobShas["new/f1.txt"] == (try r.f.git(["hash-object", "new/f1.txt"], in: r.wt)))
            return runner.count
        }
        let three = try processes(files: 3), thirty = try processes(files: 30)
        #expect(three == thirty, "\(three) processes for 3 files, \(thirty) for 30")
        #expect(three <= 10)
    }
}
