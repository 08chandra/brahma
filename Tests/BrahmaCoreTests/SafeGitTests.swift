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
        // C2b R1-1: only the share refs' reflogs are expired, never `--all`.
        #expect(has(["for-each-ref", "refs/brahma/shares/"]))
        #expect(!calls.contains { $0.args.contains("reflog") && $0.args.contains("--all") })
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
    /// with `core.logAllRefUpdates=always`) is gone after the purge, or the purge says it is incomplete. C2b R1-1: only the
    /// share refs' reflogs are expired, so what a branch's or a worktree's reflog keeps is reported (incomplete), never
    /// silently kept, and that reflog is left as it was.
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
        let branchLog = try r.f.git(["reflog", "show", "item/ENG-1"])
        #expect(throws: SafeGitError.purgeIncomplete(remaining: 2), "the branch's and the worktree's reflogs still reach them") {
            try git.expireAndPrune(purged: [blob, commit])
        }
        #expect(try r.f.git(["reflog", "show", "item/ENG-1"]) == branchLog, "a branch's reflog was expired")
        #expect(try r.f.git(["reflog", "show", "refs/brahma/shares/p"]).isEmpty, "the share ref's reflog was kept")
        // Once the owner clears those reflogs, the purge completes.
        try r.f.git(["reflog", "expire", "--expire=now", "--expire-unreachable=now", "--all"])
        try git.expireAndPrune(purged: [blob, commit])
        #expect(throws: (any Error).self, "the purged blob is still in the repository") { try r.f.git(["cat-file", "-e", blob]) }
        #expect(throws: (any Error).self, "the purged commit is still in the repository") { try r.f.git(["cat-file", "-e", commit]) }
        #expect(try r.head("item/ENG-1") == before && (try r.f.git(["rev-parse", "refs/brahma/shares/p"])) == before)
        // An object a branch still reaches is reported, never silently kept.
        #expect(throws: SafeGitError.purgeIncomplete(remaining: 1)) { try git.expireAndPrune(purged: [before]) }
    }

    /// C2b R1-1: a share purge leaves every other reflog alone (an unrelated branch's, a worktree's `HEAD`).
    @Test func sharePurgeKeepsOtherReflogs() throws {
        let r = try Repo()
        let git = SafeGit(workspace: r.root)
        try r.f.git(["config", "core.logAllRefUpdates", "always"])
        try r.f.git(["branch", "side"])
        try r.f.write("side.txt", "side\n")
        try r.f.git(["checkout", "-q", "side"])
        try r.f.git(["add", "side.txt"]); try r.f.git(["commit", "-q", "-m", "side"])
        try r.f.git(["checkout", "-q", "main"])
        try r.f.write("wt.txt", "wt\n", in: r.wt)
        try r.f.git(["add", "wt.txt"], in: r.wt); try r.f.git(["commit", "-q", "-m", "wt"], in: r.wt)
        let side = try r.f.git(["reflog", "show", "side"]), head = try r.f.git(["reflog", "show", "HEAD"], in: r.wt)
        #expect(!side.isEmpty && !head.isEmpty)
        let main = try r.head("main")
        let tree = try r.f.git(["rev-parse", "\(main)^{tree}"])
        let pinned = try r.f.git(["commit-tree", tree, "-m", "pinned"])
        try git.updateShareRef("gone", to: pinned)
        try git.updateShareRef("kept", to: main)
        try git.updateShareRef("kept", to: pinned)
        try git.updateShareRef("kept", to: main)
        try git.deleteShareRef("gone")
        try git.expireAndPrune(purged: [pinned])
        #expect(try r.f.git(["reflog", "show", "side"]) == side)
        #expect(try r.f.git(["reflog", "show", "HEAD"], in: r.wt) == head)
        #expect(try r.f.git(["reflog", "show", "refs/brahma/shares/kept"]).isEmpty, "a share ref's reflog is expired")
        #expect(throws: (any Error).self) { try r.f.git(["cat-file", "-e", pinned]) }
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
    @Test(arguments: [":/usr/bin:/bin", ".:/usr/bin:/bin", "bin:/usr/bin:/bin:"]) func plantedGitInWorktreeNeverRuns(_ path: String) throws {
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
        // The `git --version` probes: resolved the same way (absolute executable, stripped child PATH).
        let probe = try #require(GitCommand.versionProbe(base: ["PATH": path, "HOME": scratch.path]))
        #expect(probe.executable.hasPrefix("/") && !probe.executable.hasPrefix(r.wt.path) && probe.0.executableURL?.path == probe.executable)
        #expect(probe.0.environment?["PATH"] == "/usr/bin:/bin" && probe.0.arguments == ["--version"])
        // The worktree diff itself, with the planted git sitting in the worktree (ignored by name: `FakeTools.install` hard-links
        // the shared script, which SafeFS would refuse as a file with another link): every git it starts is an absolute
        // executable outside the worktree, exec'd as argv[0].
        try r.f.write(".gitignore", "git\n", in: r.wt)
        final class Spawns: @unchecked Sendable { let lock = NSLock(); var all: [(String, [String])] = [] }
        let spawns = Spawns()
        var live = LiveGitRunner()
        live.spawnObserver = { exe, argv in spawns.lock.withLock { spawns.all.append((exe, argv)) } }
        let diff = try SafeGit(workspace: r.root, runner: live).worktreeDiff(key: "ENG-1", worktree: r.wt, tempDir: try tempDir(), fs: r.fs)
        #expect(diff.files.map(\.path) == [".gitignore"])
        let realWt = realpath(r.wt.path, nil).map { p in defer { free(p) }; return String(cString: p) } ?? r.wt.path
        let started = spawns.lock.withLock { spawns.all }
        #expect(started.count >= 4, "\(started.count)")
        for (exe, argv) in started {
            #expect(exe.hasPrefix("/") && exe.hasSuffix("/git") && argv.first == exe && !exe.hasPrefix(r.wt.path) && !exe.hasPrefix(realWt), "\(exe)")
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the planted git ran (worktreeDiff)")
    }

    /// The reviewer's window: the root entry is a link to an outside directory for exactly the time one git process starts and
    /// runs, and is put back after. No process has the worktree as its work tree, so nothing resolves the name: the result is
    /// the real worktree's, the outside file is never listed or read, and no outside name appears anywhere.
    @Test func worktreeDiffImmuneToStartupWindowSwap() throws {
        let r = try Repo()
        try r.f.write("src/a.txt", "changed\n", in: r.wt)
        try FileManager.default.removeItem(at: r.wt.appending(path: "README.md"))      // a deletion: `update-index --force-remove` runs
        let outside = try tempDir().appending(path: "outside", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: outside.appending(path: "src"), withIntermediateDirectories: true)
        try "outside readme\n".write(to: outside.appending(path: "README.md"), atomically: true, encoding: .utf8)
        let secret = outside.appending(path: "OUTSIDE-SECRET.txt")
        try "outside bytes\n".write(to: secret, atomically: true, encoding: .utf8)
        try "outside a\n".write(to: outside.appending(path: "src/a.txt"), atomically: true, encoding: .utf8)
        let secretAtime = Self.atime(secret)
        let moved = r.wt.appendingPathExtension("moved")
        let wt = r.wt
        for trigger in ["read-tree", "ls-tree", "check-ignore", "--stdin-paths", "--force-remove", "--index-info", "--name-status", "--numstat", "-p"] {
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
            #expect(diff.files.map { "\($0.status) \($0.path)" } == ["D README.md", "A new/n.txt", "M src/a.txt"] && diff.patch.contains("+changed")
                    && diff.patch.contains("-hello"), "\(trigger): \(diff.files)")
            let shown = "\(diff.files) \(diff.patch) \(diff.blobShas) " + runner.captured.map { String(decoding: $0.stdout, as: UTF8.self) }.joined()
            #expect(!shown.contains("OUTSIDE-SECRET") && !shown.contains("outside"), "\(trigger): outside content surfaced")
        }
        #expect(Self.atime(secret) == secretAtime, "the outside file was read")
    }

    /// Ignore rules are git's own verdict for every walked path (negations, escapes, trailing spaces, `**` included), the
    /// engine prunes nothing, a tracked file under an ignored directory is still diffed, a real nested repository is one entry
    /// `nested/` (as git lists it), an invalid `.git` leaves its directory walked as git walks it, and `.git` entries are never
    /// listed. The expectation is git's own `ls-files --others --exclude-standard` on the same tree.
    @Test func worktreeDiffHonoursIgnoreRules() throws {
        let r = try Repo()
        try r.f.write("build/keep.txt", "tracked\n", in: r.wt)
        try r.f.write(".gitignore", "build/\n", in: r.wt)
        try r.f.git(["add", "-f", "build/keep.txt", ".gitignore"], in: r.wt)
        try r.f.git(["commit", "-q", "-m", "tracked under an ignored dir"], in: r.wt)
        try r.f.write(".gitignore", "build/\n*.log\n!keep.log\n\\#lit\nsp\\ \ntrail   \nx/**/y*z/\n", in: r.wt)
        try r.f.write("build/keep.txt", "changed\n", in: r.wt)
        for path in ["build/out.bin", "build/deep/more.bin", "a.log", "keep.log", "src/sub.log", "keep.txt", "#lit", "sp ", "trail",
                     "x/q/yAz/f", "x/y/z/f", "invalid/.git/HEAD", "invalid/inner.txt", "plainfile/.git", "plainfile/inner.txt"] {
            try r.f.write(path, "x", in: r.wt)
        }
        try r.f.git(["init", "-q", "nested"], in: r.wt)
        try r.f.write("nested/inner.txt", "x", in: r.wt)
        let diff = try SafeGit(workspace: r.root).worktreeDiff(key: "ENG-1", worktree: r.wt, tempDir: try tempDir(), fs: r.fs)
        let added = diff.files.filter { $0.status == "A" }.map(\.path).sorted()
        let git = try Self.untracked(r)
        #expect(added == git, "engine \(added) vs git \(git)")
        #expect(added == ["invalid/inner.txt", "keep.log", "keep.txt", "nested/", "plainfile/inner.txt", "x/y/z/f"], "\(added)")
        #expect(diff.files.filter { $0.status == "M" }.map(\.path) == [".gitignore", "build/keep.txt"], "\(diff.files)")
        #expect(diff.patch.contains("+changed"))
        #expect(!diff.files.contains { $0.path.contains(".git/") || $0.path.hasSuffix("/.git") })
        let nested = try #require(diff.files.first { $0.path == "nested/" })
        #expect(nested.added == nil && nested.removed == nil && nested.bytes == 0 && diff.blobShas["nested/"] == nil)
        // Ignored, the nested repository is not listed either (git judges the directory).
        try r.f.write(".gitignore", "nested/\n", in: r.wt)
        let hidden = try SafeGit(workspace: r.root).worktreeDiff(key: "ENG-1", worktree: r.wt, tempDir: try tempDir(), fs: r.fs)
        let gitAfter = try Self.untracked(r)
        #expect(!hidden.files.contains { $0.path == "nested/" } && !gitAfter.contains("nested/"))
    }

    /// Git's untracked, not ignored paths in the item worktree (no global excludes).
    static func untracked(_ r: Repo) throws -> [String] {
        try r.f.git(["-c", "core.excludesFile=/dev/null", "ls-files", "-z", "--others", "--exclude-standard"], in: r.wt)
            .split(separator: "\u{0}").map(String.init).sorted()
    }

    /// NB1/NB2: a tracked file under an ignored-looking directory is listed as modified (never as deleted); and the differential
    /// against git: for a table of patterns (anchored, `**`, negation, directory-only, escaped `#` and `*`, trailing spaces) the
    /// untracked paths the engine lists are exactly git's. With no pruning, any path hidden that git shows (or shown that git
    /// ignores) fails.
    @Test func ignoredLookingDirHoldsTrackedFile() throws {
        let r = try Repo()
        try r.f.write("build/keep.txt", "tracked\n", in: r.wt)
        try r.f.write(".gitignore", "build/\n", in: r.wt)
        try r.f.git(["add", "-f", "build/keep.txt", ".gitignore"], in: r.wt)
        try r.f.git(["commit", "-q", "-m", "tracked under an ignored dir"], in: r.wt)
        try r.f.write("build/keep.txt", "changed\n", in: r.wt)
        try r.f.write("build/junk.o", "x", in: r.wt)
        let diff = try SafeGit(workspace: r.root).worktreeDiff(key: "ENG-1", worktree: r.wt, tempDir: try tempDir(), fs: r.fs)
        #expect(diff.files.map { "\($0.status) \($0.path)" } == ["M build/keep.txt"], "\(diff.files)")
        // The differential, pattern by pattern.
        let patterns = ["*.log", "/root-only", "a/**/x*y/", "!keep", "dir/", "\\#notcomment", "\\*/", "trail   ", "sp\\ ", "doc/*.txt",
                        "**/gen", "keep", "!/root-only/not"]
        try r.f.write(".gitignore", patterns.joined(separator: "\n") + "\n", in: r.wt)
        let paths = ["x.log", "d/x.log", "keep", "d/keep", "root-only/a", "root-only/not/b", "sub/root-only/c", "a/x/y/f", "a/q/xzy/f",
                     "a/q/x/z/y/f", "a/xy/f", "dir/f", "d/dir/f", "dirfile", "#notcomment", "notcomment", "*/f", "xfoo/n.txt", "trail",
                     "trail   x", "sp ", "sp", "doc/a.txt", "doc/sub/a.txt", "gen/f", "d/gen/f", "keep.log", "plain"]
        for path in paths { try r.f.write(path, "x", in: r.wt) }
        let listed = try SafeGit(workspace: r.root).worktreeDiff(key: "ENG-1", worktree: r.wt, tempDir: try tempDir(), fs: r.fs)
            .files.filter { $0.status == "A" }.map(\.path).sorted()
        let git = try Self.untracked(r)
        #expect(listed == git, "engine \(listed) vs git \(git)")
        // Path by path against `git check-ignore` itself: listed exactly when git does not ignore it.
        for path in paths {
            let ignoredByGit = (try? r.f.git(["-c", "core.excludesFile=/dev/null", "check-ignore", "-q", "--no-index", "--", path], in: r.wt)) != nil
            #expect(listed.contains(path) == !ignoredByGit, "\(path): engine listed \(listed.contains(path)), git ignored \(ignoredByGit)")
        }
        #expect(listed.contains("xfoo/n.txt") && listed.contains("a/q/x/z/y/f") && !listed.contains("*/f"), "\(listed)")
    }

    /// NB1: whatever the walk cannot account for refuses the whole diff, never a skip: a `.git` entry (a plain file, a case
    /// variant) in a directory the base tracks paths under, a directory that cannot be opened, a tree deeper than the cap.
    @Test func walkRefusesWhatItCannotAccountFor() throws {
        let r = try Repo()
        let git = SafeGit(workspace: r.root)
        func refusal() -> String {
            do { _ = try git.worktreeDiff(key: "ENG-1", worktree: r.wt, tempDir: try tempDir(), fs: r.fs); return "" } catch { return "\(error)" }
        }
        try r.f.write("src/a.txt", "changed\n", in: r.wt)
        try r.f.write("src/new.txt", "n\n", in: r.wt)
        // (a) `src/.git` a plain file: git still lists `src/a.txt` modified; the engine refuses rather than hide it.
        try r.f.write("src/.git", "hi\n", in: r.wt)
        #expect(refusal() == "the worktree of ENG-1 holds a .git entry in a tracked directory")
        try FileManager.default.removeItem(at: r.wt.appending(path: "src/.git"))
        // ... a nested `git init` there too.
        try r.f.git(["init", "-q", "src"], in: r.wt)
        #expect(refusal() == "the worktree of ENG-1 holds a .git entry in a tracked directory")
        try FileManager.default.removeItem(at: r.wt.appending(path: "src/.git"))
        #expect(try git.worktreeDiff(key: "ENG-1", worktree: r.wt, tempDir: try tempDir(), fs: r.fs).files.map(\.path) == ["src/a.txt", "src/new.txt"])
        // (b) A directory that cannot be opened (EACCES): refused, not skipped.
        let locked = r.wt.appending(path: "locked")
        try r.f.write("locked/f.txt", "x", in: r.wt)
        chmod(locked.path, 0)
        let text = refusal()
        chmod(locked.path, 0o755)                     // exec-bit fixture: a directory's mode restored after the chmod 000 under test
        #expect(text == "the worktree of ENG-1 cannot be listed", "\(text)")
        try FileManager.default.removeItem(at: locked)
        // A tracked directory that cannot be opened: its files are not reported deleted.
        chmod(r.wt.appending(path: "src").path, 0)
        let tracked = refusal()
        chmod(r.wt.appending(path: "src").path, 0o755)    // exec-bit fixture: a directory's mode restored
        #expect(tracked == "the worktree of ENG-1 cannot be listed", "\(tracked)")
        // (c) Deeper than `maxDepth`: refused as too large, never truncated.
        var deep = "d"
        for _ in 0..<WorktreeListing.maxDepth { deep += "/d" }
        try r.f.write(deep + "/f.txt", "x", in: r.wt)
        #expect(refusal().hasPrefix("too many/too large changes to diff"), "a tree past maxDepth was not refused as too large")
    }

    /// NB3: the walk's path text is byte-bounded (`listingByteCap`), refusing as `.tooManyChanges`; `check-ignore`'s output past
    /// the cap is the same refusal, never a raw `.outputTooLarge`.
    @Test func listingIsByteBounded() throws {
        let r = try Repo()
        let long = String(repeating: "n", count: 200)
        for i in 0..<20 { try r.f.write("\(long)\(i)/\(long).txt", "x", in: r.wt) }
        var git = SafeGit(workspace: r.root)
        #expect(try git.worktreeDiff(key: "ENG-1", worktree: r.wt, tempDir: try tempDir(), fs: r.fs).files.count == 20)
        git.listingByteCap = 4096
        do {
            _ = try git.worktreeDiff(key: "ENG-1", worktree: r.wt, tempDir: try tempDir(), fs: r.fs)
            Issue.record("a listing past the byte cap was accepted")
        } catch let e as SafeGitError {
            guard case .tooManyChanges(_, let bytes) = e else { Issue.record("\(e)"); return }
            #expect(bytes > 4096 && bytes < 4096 + 1024, "\(bytes)")
        }
        // check-ignore's output overflowing: `.tooManyChanges`.
        final class Overflow: GitProcessRunning, @unchecked Sendable {
            let live = LiveGitRunner()
            func run(args: [String], env: [String: String], stdin: Data?, timeout: Duration, outputCap: Int) throws -> (status: Int32, stdout: Data, stderr: Data) {
                if args.contains("check-ignore") { throw SafeGitError.outputTooLarge }
                return try live.run(args: args, env: env, stdin: stdin, timeout: timeout, outputCap: outputCap)
            }
        }
        do {
            _ = try SafeGit(workspace: r.root, runner: Overflow()).worktreeDiff(key: "ENG-1", worktree: r.wt, tempDir: try tempDir(), fs: r.fs)
            Issue.record("check-ignore overflow was accepted")
        } catch let e as SafeGitError {
            guard case .tooManyChanges = e else { Issue.record("check-ignore overflow surfaced as \(e)"); return }
        }
    }

    /// R5: a `.gitignore` the engine cannot read safely (over 1 MiB, or a link) yields no rules: nothing is ignored on its account,
    /// nothing throws, the files are listed.
    @Test func unreadableGitignoreIgnoresNothing() throws {
        let r = try Repo()
        try r.f.write("sub/.gitignore", "*.log\n", in: r.wt)
        try r.f.write("sub/a.log", "x", in: r.wt)
        try r.f.write("sub/keep.txt", "x", in: r.wt)
        let git = SafeGit(workspace: r.root)
        #expect(try git.worktreeDiff(key: "ENG-1", worktree: r.wt, tempDir: try tempDir(), fs: r.fs).files.map(\.path) == ["sub/.gitignore", "sub/keep.txt"])
        // Over 1 MiB: not copied for git; `sub/a.log` is listed again.
        var big = Data("*.log\n".utf8)
        big.append(Data(repeating: UInt8(ascii: "#"), count: 2 << 20))
        try big.write(to: r.wt.appending(path: "sub/.gitignore"))
        let large = try git.worktreeDiff(key: "ENG-1", worktree: r.wt, tempDir: try tempDir(), fs: r.fs)
        #expect(large.files.map(\.path) == ["sub/.gitignore", "sub/a.log", "sub/keep.txt"], "\(large.files.map(\.path))")
        // A second hard link: never read for rules; the file itself is a change SafeFS refuses to read, so the whole diff is
        // refused (fail closed, the generic text).
        try "*.log\n".write(to: r.wt.appending(path: "sub/.gitignore"), atomically: true, encoding: .utf8)
        let other = try tempDir().appending(path: "rules-link")
        try FileManager.default.linkItem(at: r.wt.appending(path: "sub/.gitignore"), to: other)
        #expect(throws: SafeGitError.io("a changed path cannot be read (linked)")) {
            try git.worktreeDiff(key: "ENG-1", worktree: r.wt, tempDir: try tempDir(), fs: r.fs)
        }
        try FileManager.default.removeItem(at: other)
        // A link in place of the ignore file: a link entry, no rules from it.
        try FileManager.default.removeItem(at: r.wt.appending(path: "sub/.gitignore"))
        let outside = try tempDir().appending(path: "rules")
        try "*.log\n".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: r.wt.appending(path: "sub/.gitignore"), withDestinationURL: outside)
        let linked = try git.worktreeDiff(key: "ENG-1", worktree: r.wt, tempDir: try tempDir(), fs: r.fs)
        #expect(linked.files.map(\.path) == ["sub/.gitignore", "sub/a.log", "sub/keep.txt"], "\(linked.files.map(\.path))")
        #expect(linked.blobShas["sub/.gitignore"] == SafeGit.blobId(of: Data(outside.path.utf8), sha256: false), "the link was followed")
    }

    /// Round 5: the `.gitignore` copies made for git are summed by each opened descriptor's size against `ignoreCopyByteCap`
    /// before a byte is copied; past it the whole diff is `.tooManyChanges` (never a partial rule set). The budget is checked
    /// per file and per copied chunk. Sparse 1 MiB files (no blocks on disk) would each cost a real MiB of zeros per copy.
    @Test func gitignoreCopiesAreCapped() throws {
        let r = try Repo()
        var rels: [String] = []
        for i in 0..<6 {
            let rel = "d\(i)/.gitignore"
            try r.f.write(rel, "", in: r.wt)
            let h = try FileHandle(forWritingTo: r.wt.appending(path: rel))
            try h.truncate(atOffset: 1 << 20)
            try h.close()
            rels.append(rel)
        }
        #expect(SafeGit(workspace: r.root).ignoreCopyByteCap == SafeGit.outputCap)
        var git = SafeGit(workspace: r.root)
        git.ignoreCopyByteCap = 4 << 20
        do {
            _ = try git.worktreeDiff(key: "ENG-1", worktree: r.wt, tempDir: try tempDir(), fs: r.fs)
            Issue.record("ignore-file copies past the cap were accepted")
        } catch let e as SafeGitError {
            guard case .tooManyChanges(_, let bytes) = e else { Issue.record("\(e)"); return }
            #expect(bytes > 4 << 20 && bytes <= 5 << 20, "\(bytes)")
        }
        // The copy step worktreeDiff runs, into a shadow the test can measure.
        func written(_ dir: URL) throws -> Int {
            var total = 0
            for case let url as URL in FileManager.default.enumerator(at: dir, includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey])! {
                let values = try url.resourceValues(forKeys: [.fileSizeKey, .isRegularFileKey])
                if values.isRegularFile == true { total += values.fileSize ?? 0 }
            }
            return total
        }
        let tree = try r.fs.worktreeDirectory(key: "ENG-1")
        let over = try tempDir()
        #expect(throws: SafeGitError.tooManyChanges(files: 6, bytes: 5 << 20)) {
            try SafeGit.copyIgnoreFiles(rels, from: tree, key: "ENG-1", fs: r.fs, to: over, cap: 4 << 20, budget: SafeGit.Budget(limit: .seconds(60)))
        }
        #expect(try written(over) <= 4 << 20, "more than the cap was written")
        // Within the cap: every copy made, byte for byte.
        let within = try tempDir()
        try SafeGit.copyIgnoreFiles(rels, from: tree, key: "ENG-1", fs: r.fs, to: within, cap: 6 << 20, budget: SafeGit.Budget(limit: .seconds(60)))
        #expect(try written(within) == 6 << 20)
        // An exhausted budget in the copy loop: `.timedOut`, nothing copied.
        let late = try tempDir()
        #expect(throws: SafeGitError.timedOut) {
            try SafeGit.copyIgnoreFiles(rels, from: tree, key: "ENG-1", fs: r.fs, to: late, cap: 6 << 20, budget: SafeGit.Budget(limit: .zero))
        }
        #expect(try written(late) == 0)
        // Per chunk: one file's copy stops at the first chunk once the budget is spent.
        let file = try r.fs.open("d0/.gitignore", inWorktree: "ENG-1", maxBytes: 1 << 20)
        let one = try tempDir().appending(path: "one")
        #expect(throws: SafeGitError.timedOut) { try SafeGit.write(file: file, to: one.path, budget: SafeGit.Budget(limit: .zero)) }
        #expect((try? FileManager.default.attributesOfItem(atPath: one.path)[.size] as? Int) == 0)
    }

    /// R7: an unchanged file's id is computed in bounded chunks, the budget checked per chunk; a same-size tracked file that
    /// grows between the walk and its open counts as modified without one byte of it hashed for an id.
    @Test func idComparisonIsSizePinnedAndChunked() throws {
        let r = try Repo()
        final class Chunks: @unchecked Sendable { let lock = NSLock(); var sizes: [Int] = [] }
        let chunks = Chunks()
        try Data(repeating: UInt8(ascii: "b"), count: 4 << 20).write(to: r.wt.appending(path: "big.bin"))
        try Data(repeating: UInt8(ascii: "m"), count: 1 << 20).write(to: r.wt.appending(path: "mid.bin"))
        try r.f.git(["add", "big.bin", "mid.bin"], in: r.wt)
        try r.f.git(["commit", "-q", "-m", "big"], in: r.wt)
        var git = SafeGit(workspace: r.root, timeout: .seconds(60))
        git.hashChunkProbe = { n in chunks.lock.withLock { chunks.sizes.append(n) } }
        let quiet = try git.worktreeDiff(key: "ENG-1", worktree: r.wt, tempDir: try tempDir(), fs: r.fs)
        #expect(quiet.files.isEmpty, "\(quiet.files)")
        let sizes = chunks.lock.withLock { chunks.sizes }
        #expect(sizes.reduce(0, +) == (5 << 20) + 10 && sizes.allSatisfy { $0 <= 64 << 10 } && sizes.count >= 80, "chunks: \(sizes.count)")
        // (README.md and src/a.txt, 10 bytes, are the fixture's other unchanged files.)
        // The budget is checked inside one file's hashing: an exhausted budget stops it at the first chunk.
        let file = try r.fs.open("big.bin", inWorktree: "ENG-1", maxBytes: 8 << 20)
        #expect(throws: SafeGitError.timedOut) { try SafeGit.blobId(of: file, sha256: false, budget: SafeGit.Budget(limit: .zero)) }
        // mid.bin grows right after the walk: modified, copied, and not one of its bytes hashed for an id (only big.bin's were).
        try r.f.write("new/n.txt", "n\n", in: r.wt)                      // a candidate, so check-ignore runs (the seam after the walk)
        chunks.lock.withLock { chunks.sizes = [] }
        let runner = SwapRunner(trigger: "check-ignore")
        let mid = r.wt.appending(path: "mid.bin")
        runner.after = { let h = try FileHandle(forWritingTo: mid); try h.seekToEnd(); try h.write(contentsOf: Data("grown".utf8)); try h.close() }
        var grownGit = SafeGit(workspace: r.root, runner: runner, timeout: .seconds(60))
        grownGit.hashChunkProbe = git.hashChunkProbe
        let grown = try grownGit.worktreeDiff(key: "ENG-1", worktree: r.wt, tempDir: try tempDir(), fs: r.fs)
        #expect(grown.files.map { "\($0.status) \($0.path)" } == ["M mid.bin", "A new/n.txt"], "\(grown.files)")
        #expect(grown.files.first?.bytes == (1 << 20) + 5)
        #expect(chunks.lock.withLock { chunks.sizes.reduce(0, +) } == (4 << 20) + 10, "the grown file was read for an id comparison")
    }

    /// The engine's blob ids are git's: SHA-1 vectors and git's own ids, a multi-chunk (> 64 KiB) file through `SafeFS` and a
    /// link's target against `git hash-object` in a SHA-1 repository and in a real `--object-format=sha256` one.
    @Test func blobIdsMatchGit() throws {
        var sha1 = SHA1()
        sha1.update(Data("abc".utf8))
        #expect(SHA1.hex(digest: sha1.finalize()) == "a9993e364706816aba3e25717850c26c9cd0d89d")
        var long = SHA1()
        for _ in 0..<1000 { long.update(Data(String(repeating: "a", count: 1000).utf8)) }
        #expect(SHA1.hex(digest: long.finalize()) == "34aa973cd4c4daa4f61eeb2bdbad27316534016f")
        var split = SHA1()                                                   // unaligned pieces across block boundaries
        for piece in ["a", String(repeating: "b", count: 63), String(repeating: "c", count: 65), "", "d"] { split.update(Data(piece.utf8)) }
        var whole = SHA1()
        whole.update(Data(("a" + String(repeating: "b", count: 63) + String(repeating: "c", count: 65) + "d").utf8))
        #expect(SHA1.hex(digest: split.finalize()) == SHA1.hex(digest: whole.finalize()))
        #expect(SafeGit.blobId(of: Data("hello\n".utf8), sha256: false) == "ce013625030ba8dba906f756967f9e9ca394464a")
        #expect(SafeGit.blobId(of: Data(), sha256: false) == "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391")
        var bytes = Data(count: 200_003)
        for i in bytes.indices { bytes[i] = UInt8(truncatingIfNeeded: i &* 31 &+ i >> 7) }
        // SHA-1: the item worktree's repository.
        let r = try Repo()
        try bytes.write(to: r.wt.appending(path: "multi.bin"))
        let file = try r.fs.open("multi.bin", inWorktree: "ENG-1", maxBytes: 1 << 20)
        #expect(try SafeGit.blobId(of: file, sha256: false) == (try r.f.git(["hash-object", "multi.bin"], in: r.wt)))
        // SHA-256: a real repository in that object format.
        let repo = try tempDir().appending(path: "s256", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try GitFixture.plainGit(["init", "-q", "--object-format=sha256"], in: repo)
        try bytes.write(to: repo.appending(path: "multi.bin"))
        let gitId = try GitFixture.plainGit(["hash-object", "multi.bin"], in: repo)
        #expect(gitId.count == 64)
        #expect(try SafeGit.blobId(of: file, sha256: true) == gitId)
        try "hello\n".write(to: repo.appending(path: "h.txt"), atomically: true, encoding: .utf8)
        #expect(SafeGit.blobId(of: Data("hello\n".utf8), sha256: true) == (try GitFixture.plainGit(["hash-object", "h.txt"], in: repo)))
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
