import Testing
import Foundation
@testable import BrahmaCore

@Suite(.scratch) struct GitWorkspaceTests {
    @Test func ensureRepoInitializesMainAndExcludesBrahma() throws {
        let f = try GitFixture(ensure: false)
        try f.ws.ensureRepo()
        #expect(FileManager.default.fileExists(atPath: f.root.appending(path: ".git/HEAD").path))
        #expect(try f.git(["rev-parse", "--abbrev-ref", "HEAD"]) == "main")
        #expect(try f.ws.head(of: "main") != nil)
        let exclude = try String(contentsOf: f.root.appending(path: ".git/info/exclude"), encoding: .utf8)
        #expect(exclude.split(separator: "\n").filter { $0 == ".brahma/" }.count == 1)
        // Idempotent, and the engine's own directory never shows up as a change.
        try f.ws.ensureRepo()
        let again = try String(contentsOf: f.root.appending(path: ".git/info/exclude"), encoding: .utf8)
        #expect(again.split(separator: "\n").filter { $0 == ".brahma/" }.count == 1)
        try f.write(".brahma/progress/X.md", "notes")
        #expect(try f.git(["status", "--porcelain"]) == "")
        #expect(try f.ws.isDirty(in: f.root) == false)
        #expect(f.ws.branch(key: "ACME-1") == "item/ACME-1")
        #expect(f.ws.worktreePath(key: "ACME-1").path.hasSuffix("/.brahma/wt/ACME-1"))
    }

    /// A-I1b: the engine's git commands keep their captured output and private index under a 0700 directory in the data
    /// home (`<exportHome>/tmp`), never the shared per-user temp dir a sandboxed check can read.
    @Test func engineGitTempStaysUnderTheDataHome() throws {
        let home = try tempDir().appending(path: "home", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: home, withIntermediateDirectories: true)
        let f = try GitFixture(ensure: false)
        var ws = GitWorkspace(root: f.root, exportHome: home)
        #expect(ws.gitTemp.path == home.appending(path: "tmp").path)
        let nsTemp = FileManager.default.temporaryDirectory
        func strays() -> [String] {
            ((try? FileManager.default.contentsOfDirectory(atPath: nsTemp.path)) ?? [])
                .filter { $0.hasPrefix("brahma-git-") || $0.hasPrefix("brahma-index-") || $0.hasPrefix("brahma-quarantine-") }
        }
        // Every git run of this workspace reports its temp root. The observer is process-global and tests run in parallel,
        // so it is filtered to this workspace's own home (a unique path), which only this ws's git runs touch.
        let mine = home.path
        final class Seen: @unchecked Sendable { let lock = NSLock(); var roots: Set<String> = [] }
        let seen = Seen()
        ws.gitTempObserver = { url in if url.path.hasPrefix(mine + "/") { seen.lock.withLock { _ = seen.roots.insert(url.path) } } }
        _ = strays()                                          // keep the helper referenced; the real check is below
        try ws.ensureRepo()                                   // init, symbolic-ref, add, commit: many git runs
        _ = try f.write("a.txt", "one")
        _ = try ws.commitAll(in: f.root, message: "x")        // the commit path
        let roots = seen.lock.withLock { seen.roots }
        #expect(!roots.isEmpty, "no git ran for this workspace")
        #expect(roots == [ws.gitTemp.path], "engine git used a temp root outside the data home: \(roots.subtracting([ws.gitTemp.path]))")
        #expect(!roots.contains(nsTemp.path), "engine git used the shared per-user temp dir")
        // The directory it uses is 0700, under the data home.
        var st = stat()
        #expect(stat(ws.gitTemp.path, &st) == 0 && st.st_mode & 0o777 == 0o700)
    }

    /// B-M3: a hard-linked `.git/info/exclude` is refused, never written (a write would change whatever else it links to).
    @Test func hardLinkedExcludeIsRefused() throws {
        let f = try GitFixture()
        let exclude = f.root.appending(path: ".git/info/exclude")
        let other = try tempDir().appending(path: "linked-elsewhere")
        try "owner pattern\n".write(to: other, atomically: true, encoding: .utf8)
        try FileManager.default.removeItem(at: exclude)
        try FileManager.default.linkItem(at: other, to: exclude)
        #expect(throws: (any Error).self) { try f.ws.ensureRepo() }
        #expect(try String(contentsOf: other, encoding: .utf8) == "owner pattern\n", "the hard-linked file was modified")
    }

    @Test func ensureRepoImportsExistingFiles() throws {
        let f = try GitFixture(files: ["a.txt": "one", "src/b.swift": "two"])
        let files = try f.git(["ls-tree", "-r", "--name-only", "main"]).split(separator: "\n").map(String.init)
        #expect(Set(files) == ["a.txt", "src/b.swift"])
        #expect(try f.ws.isDirty(in: f.root) == false)
    }

    @Test func worktreeCreateReuseAndRemoveKeepsBranch() throws {
        let f = try GitFixture(files: ["a.txt": "one"])
        let wt = try f.ws.addWorktree(key: "ACME-1")
        #expect(wt.path == f.ws.worktreePath(key: "ACME-1").path)
        #expect(try String(contentsOf: wt.appending(path: "a.txt"), encoding: .utf8) == "one")
        #expect(try f.git(["rev-parse", "--verify", "item/ACME-1"]) == f.ws.head(of: "main"))
        try f.write("new.txt", "fresh", in: wt)
        #expect(try f.ws.isDirty(in: wt))
        // Adding again reuses the checkout and keeps its files.
        let again = try f.ws.addWorktree(key: "ACME-1")
        #expect(again.path == wt.path)
        #expect(FileManager.default.fileExists(atPath: wt.appending(path: "new.txt").path))
        // Removing auto-commits the work, deletes the directory and keeps the branch.
        try f.ws.removeWorktree(key: "ACME-1", keepIf: { false })
        #expect(!FileManager.default.fileExists(atPath: wt.path))
        #expect(try f.git(["log", "-1", "--format=%s", "item/ACME-1"]) == "ACME-1: auto-commit before release")
        #expect(try f.git(["show", "item/ACME-1:new.txt"]) == "fresh")
        #expect(try f.git(["rev-parse", "--verify", "main"]) == f.ws.head(of: "main"))
        // The branch comes back with its work.
        let back = try f.ws.addWorktree(key: "ACME-1")
        #expect(FileManager.default.fileExists(atPath: back.appending(path: "new.txt").path))
        try f.ws.removeWorktree(key: "ACME-1", keepIf: { false })
        try f.ws.removeWorktree(key: "ACME-1", keepIf: { false })   // already gone: not an error
        try f.ws.deleteBranch(key: "ACME-1")
        #expect(try f.ws.head(of: "item/ACME-1") == nil)
    }

    @Test func commitAllReturnsHeadOnlyWhenSomethingChanged() throws {
        let f = try GitFixture(files: ["a.txt": "one"])
        let wt = try f.ws.addWorktree(key: "K-1")
        #expect(try f.ws.commitAll(in: wt, message: "nothing") == nil)
        try f.write("b.txt", "two", in: wt)
        let sha = try #require(try f.ws.commitAll(in: wt, message: "add b"))
        #expect(try sha == f.ws.head(of: "item/K-1"))
        #expect(try f.ws.isDirty(in: wt) == false)
        #expect(throws: GitError.self) { try f.ws.commitAll(in: f.root.appending(path: "elsewhere"), message: "x") }
    }

    @Test func nameStatusAndDiffBounded() throws {
        let f = try GitFixture(files: ["a.txt": "one"])
        let wt = try f.ws.addWorktree(key: "K-1")
        for i in 0..<2100 { try f.write("many/f\(i).txt", "x", in: wt) }
        let big = (0..<1000).map { "line \($0)" }.joined(separator: "\n")
        try f.write("big.txt", big, in: wt)
        try f.write("a.txt", "changed", in: wt)
        try f.ws.commitAll(in: wt, message: "lots")
        let base = try #require(try f.ws.head(of: "main")), head = try #require(try f.ws.head(of: "item/K-1"))
        let ns = try f.ws.nameStatus(base: base, head: head)
        #expect(ns.entries.count == 2000); #expect(ns.truncated)
        let small = try f.ws.nameStatus(base: base, head: head, limit: 5000)
        #expect(small.entries.count == 2102); #expect(!small.truncated)
        #expect(small.entries.contains(GitChange(status: "M", path: "a.txt")))
        let d = try f.ws.diff(base: base, head: head)
        #expect(d.truncated)
        #expect(d.text.split(separator: "\n", omittingEmptySubsequences: false).count <= 400)
        #expect(d.text.count <= 40_000)
        let chars = try f.ws.diff(base: base, head: head, maxLines: 100_000, maxChars: 500)
        #expect(chars.truncated); #expect(chars.text.count <= 500)
        let tiny = try f.ws.diff(base: base, head: base)
        #expect(tiny.text.isEmpty); #expect(!tiny.truncated)
    }

    @Test func logBetweenRefs() throws {
        let f = try GitFixture(files: ["a.txt": "one"])
        let wt = try f.ws.addWorktree(key: "K-1")
        for i in 1...7 {
            try f.write("f\(i).txt", "x", in: wt)
            try f.ws.commitAll(in: wt, message: "commit \(i)")
        }
        let lines = try f.ws.log(base: "main", head: "item/K-1")
        #expect(lines.count == 5)
        #expect(lines[0].hasSuffix(" commit 7")); #expect(lines[4].hasSuffix(" commit 3"))
        #expect(try f.ws.log(base: "main", head: "item/K-1", limit: 50).count == 7)
        #expect(try f.ws.mergeBase("main", "item/K-1") == f.ws.head(of: "main"))
        #expect(try f.ws.head(of: "no-such-branch") == nil)
        #expect(throws: GitError.self) { try f.ws.log(base: "--output=/tmp/x", head: "main") }
    }

    @Test func indexLockRetried() throws {
        let f = try GitFixture(files: ["a.txt": "one"])
        try f.write("b.txt", "two")
        let lock = f.root.appending(path: ".git/index.lock")
        try Data().write(to: lock)
        // The lock goes between the first try and its retry (the retry hook), not on a timer that races git.
        let retries = TamperLog()
        var ws = f.ws
        ws.gitRetryProbe = { attempt in
            retries.add("\(attempt)")
            try? FileManager.default.removeItem(at: lock)
        }
        let sha = try ws.commitAll(in: f.root, message: "after the lock")
        #expect(sha != nil)
        #expect(retries.all == ["1"], "one retry, after the lock was cleared: \(retries.all)")
        // A lock that never goes away fails with the git error after the retries.
        try f.write("c.txt", "three")
        try Data().write(to: lock)
        do {
            try f.ws.commitAll(in: f.root, message: "stuck")
            Issue.record("expected a failure")
        } catch GitError.failed(let command, _, let stderr) {
            #expect(command.contains("add")); #expect(stderr.contains("index.lock"))
        }
        try? FileManager.default.removeItem(at: lock)
    }

    @Test func craftedRepoConfigIgnored() throws {
        let f = try GitFixture(files: ["a.txt": "one"])
        let wt = try f.ws.addWorktree(key: "K-1")
        // A crafted repository whose config runs a program on index access and whose hooks touch a marker.
        let evil = try tempDir().appending(path: "evil", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: evil, withIntermediateDirectories: true)
        try GitFixture.plainGit(["init", "-q"], in: evil)
        // Each sentinel (a shared script hard-linked at its own path) touches `<its path>-ran` when it runs.
        let script = evil.deletingLastPathComponent().appending(path: "fsm.sh")
        let fsmarker = URL(fileURLWithPath: script.path + "-ran")
        try FakeTools.install(at: script, "touch \"$0-ran\"\nexit 1")
        try GitFixture.plainGit(["config", "core.fsmonitor", script.path], in: evil)
        try GitFixture.plainGit(["config", "diff.external", script.path], in: evil)
        var hookmarkers: [URL] = []
        for hook in ["pre-commit", "post-commit", "commit-msg"] {
            let h = evil.appending(path: ".git/hooks/\(hook)")
            try FakeTools.install(at: h, "touch \"$0-ran\"\nexit 0")
            hookmarkers.append(URL(fileURLWithPath: h.path + "-ran"))
        }
        // The agent rewrites the worktree's `.git` file and the commondir pointer toward the crafted repo.
        try "gitdir: \(evil.path)/.git\n".write(to: wt.appending(path: ".git"), atomically: true, encoding: .utf8)
        let admin = f.root.appending(path: ".git/worktrees/K-1")
        try "\(evil.path)/.git\n".write(to: admin.appending(path: "commondir"), atomically: true, encoding: .utf8)
        try f.write("work.txt", "agent work", in: wt)

        let base = try #require(try f.ws.head(of: "main"))
        // The repointed worktree is refused and restored first; nothing ran.
        #expect(throws: GitError.self) { try f.ws.isDirty(in: wt) }
        #expect(!FileManager.default.fileExists(atPath: fsmarker.path))
        #expect(try f.ws.isDirty(in: wt))
        let sha = try #require(try f.ws.commitAll(in: wt, message: "agent commit"))
        #expect(try f.ws.head(of: "item/K-1") == sha)
        let ns = try f.ws.nameStatus(base: base, head: sha)
        #expect(ns.entries.contains(GitChange(status: "A", path: "work.txt")))
        #expect(try f.ws.diff(base: base, head: sha).text.contains("agent work"))
        #expect(try f.ws.log(base: base, head: sha) .count == 1)
        try f.ws.removeWorktree(key: "K-1", keepIf: { false })
        #expect(!FileManager.default.fileExists(atPath: fsmarker.path), "fsmonitor from the crafted config ran")
        for hookmarker in hookmarkers {
            #expect(!FileManager.default.fileExists(atPath: hookmarker.path), "a hook from the crafted repo ran")
        }
    }

    @Test func addAndRemoveOfOneItemDoNotInterleave() throws {
        let f = try GitFixture(files: ["a.txt": "one"])
        let wt = try f.ws.addWorktree(key: "K-1")
        let inside = DispatchSemaphore(value: 0), done = DispatchSemaphore(value: 0)
        let decided = ResultBox()
        let ws = f.ws
        // A removal that has decided "nobody holds it" and is about to delete the checkout...
        Thread.detachNewThread {
            try? ws.removeWorktree(key: "K-1", keepIf: {
                inside.signal(); Thread.sleep(forTimeInterval: 0.3); decided.add(true); return false
            })
            done.signal()
        }
        inside.wait()
        // ...while a claim asks for the same checkout: it waits for the removal, then makes a fresh one.
        let again = try f.ws.addWorktree(key: "K-1")
        #expect(decided.all == [true])
        done.wait()
        #expect(again.path == wt.path)
        #expect(FileManager.default.fileExists(atPath: wt.appending(path: ".git").path))
        #expect(try f.ws.isDirty(in: wt) == false)
    }

    @Test func removalIsSkippedWhenALeaseAppearsOrCannotBeRead() throws {
        let f = try GitFixture(files: ["a.txt": "one"])
        let wt = try f.ws.addWorktree(key: "K-1")
        try f.write("keep.txt", "unsaved", in: wt)
        try f.ws.removeWorktree(key: "K-1", keepIf: { true })
        #expect(FileManager.default.fileExists(atPath: wt.appending(path: "keep.txt").path))
        struct Unreadable: Error {}
        #expect(throws: Unreadable.self) { try f.ws.removeWorktree(key: "K-1", keepIf: { throw Unreadable() }) }
        #expect(FileManager.default.fileExists(atPath: wt.appending(path: "keep.txt").path))
        try f.ws.removeWorktree(key: "K-1", keepIf: { false })
        #expect(!FileManager.default.fileExists(atPath: wt.path))
    }

    @Test func lockFilesLiveOutsideTheWorkspaceAndWaitIsBounded() throws {
        let f = try GitFixture(files: ["a.txt": "one"])
        var ws = f.ws
        #expect(!ws.lockDirectory.path.hasPrefix(f.root.path))
        let wt = try ws.addWorktree(key: "K-1")
        // Someone (an agent, another process) holds the item's lock for good: the engine gives up on that item.
        let fd = open(ws.lockDirectory.appending(path: "K-1.lock").path, O_CREAT | O_RDWR, 0o600)
        #expect(fd >= 0); #expect(flock(fd, LOCK_EX) == 0)
        defer { close(fd) }
        ws.lockTimeout = 0
        let started = AwakeTime.now
        #expect(throws: GitError.self) { try ws.removeWorktree(key: "K-1", keepIf: { false }) }
        #expect(throws: GitError.self) { try ws.addWorktree(key: "K-1") }
        #expect(AwakeTime.now - started < .seconds(60), "hang guard")
        #expect(FileManager.default.fileExists(atPath: wt.path))
        // Other items are not affected.
        try ws.addWorktree(key: "K-2")
        try ws.removeWorktree(key: "K-2", keepIf: { false })
    }

    /// `git worktree add` writes the new worktree's `commondir` after creating it, and every command that reads all of a
    /// repository's worktrees (another `worktree add`, `worktree list`, `branch -D`) dies on the empty file ("failed to read
    /// .git/worktrees/<id>/commondir: Undefined error: 0"). Item checkouts, run checkouts, sweeps and prunes of one repository,
    /// from the engine and the MCP tools at once, must all succeed.
    @Test func concurrentWorktreeAdministrationOfOneRepositoryAllSucceeds() throws {
        let f = try GitFixture(files: ["a.txt": "one"])
        let main = try #require(try f.ws.head(of: GitWorkspace.mainRef))
        // Two separately made values for the same repository, as the engine and the MCP tool path each make their own.
        let engine = f.ws, tools = f.ws
        let failures = ErrorBox()
        let threads = (0..<24).map { t in
            Thread {
                let ws = t.isMultiple(of: 2) ? engine : tools
                for round in 0..<4 {
                    let n = t * 10 + round
                    do {
                        switch (t + round) % 3 {
                        case 0:
                            try ws.addWorktree(key: "K-\(n)")
                            try ws.removeWorktree(key: "K-\(n)", keepIf: { false })
                            try ws.deleteBranch(key: "K-\(n)")
                        case 1:
                            _ = try ws.addRunWorktree(runId: "run-\(n)", commit: main)
                            ws.removeRunWorktree(runId: "run-\(n)")
                        default:
                            _ = try ws.itemWorktrees()
                            try ws.addWorktree(key: "K-\(n)")
                            _ = try ws.itemWorktrees()
                            try ws.removeWorktree(key: "K-\(n)", keepIf: { false })
                        }
                    } catch { failures.add("\(error)") }
                }
            }
        }
        let done = DispatchGroup()
        for thread in threads {
            done.enter()
            let run = thread
            Thread.detachNewThread { run.start(); while !run.isFinished { usleep(1000) }; done.leave() }
        }
        #expect(done.wait(timeout: .now() + 300) == .success, "hang guard")
        #expect(failures.all.isEmpty, "\(failures.all.count) failed: \(failures.all.prefix(3))")
        #expect(try f.ws.itemWorktrees().isEmpty)
        #expect(try f.git(["worktree", "list", "--porcelain"]).components(separatedBy: "\nworktree ").count == 1)
    }

    /// Another process (the engine, or `brahma mcp`) holds the repository's worktree records: worktree administration here
    /// waits for it (bounded), and goes ahead once it lets go.
    @Test func worktreeAdministrationWaitsForAnotherProcessHoldingTheRecords() throws {
        let f = try GitFixture(files: ["a.txt": "one"])
        var ws = f.ws
        let main = try #require(try ws.head(of: GitWorkspace.mainRef))
        try FileManager.default.createDirectory(at: ws.lockDirectory, withIntermediateDirectories: true)
        let fd = open(ws.lockDirectory.appending(path: "+worktrees.lock").path, O_CREAT | O_RDWR, 0o600)
        #expect(fd >= 0); #expect(flock(fd, LOCK_EX) == 0)
        ws.lockTimeout = 0.2
        #expect(throws: GitError.self) { try ws.addWorktree(key: "K-1") }
        #expect(throws: GitError.self) { try ws.addRunWorktree(runId: "run-1", commit: main) }
        #expect(throws: GitError.self) { try ws.itemWorktrees() }
        #expect(!FileManager.default.fileExists(atPath: ws.worktreePath(key: "K-1").path), "nothing was made while it was held")
        flock(fd, LOCK_UN); close(fd)
        let wt = try ws.addWorktree(key: "K-1")
        #expect(try ws.itemWorktrees().map(\.key) == ["K-1"])
        try ws.removeWorktree(key: "K-1", keepIf: { false })
        #expect(!FileManager.default.fileExists(atPath: wt.path))
    }

    // MARK: Plan-turn write barrier

    /// A workspace with one worktree and `*.log` ignored.
    private func barrierFixture() throws -> (GitFixture, URL) {
        let f = try GitFixture(files: ["a.txt": "one"])
        let wt = try f.ws.addWorktree(key: "ACME-1")
        let exclude = f.root.appending(path: ".git/info/exclude")
        try (try String(contentsOf: exclude, encoding: .utf8) + "*.log\n").write(to: exclude, atomically: true, encoding: .utf8)
        return (f, wt)
    }

    @Test func planBarrierReadsOddPathNames() throws {
        let (f, wt) = try barrierFixture()
        let old = ["old one.log", "pre\nline.log", "q\"pre.log", "dir/sub dir/x.log"]
        for n in old { try f.write(n, "kept", in: wt) }
        let before = try f.ws.planBarrier(key: "ACME-1", in: wt)
        #expect(before.ignored.count == old.count)
        #expect(try f.ws.enforcePlanBarrier(before, key: "ACME-1", in: wt).isEmpty, "nothing changed, nothing flagged")
        let new = ["a b.log", "new\nline.log", "q\"uote.log", "tab\there.log"]
        for n in new { try f.write(n, "x", in: wt) }
        let found = try f.ws.enforcePlanBarrier(before, key: "ACME-1", in: wt)
        #expect(Set(found) == ["new ignored file a b.log", #"new ignored file "new\nline.log""#,
                               #"new ignored file "q\"uote.log""#, #"new ignored file "tab\there.log""#])
        for n in new { #expect(!FileManager.default.fileExists(atPath: wt.appending(path: n).path), "\(n)") }
        for n in old { #expect(FileManager.default.fileExists(atPath: wt.appending(path: n).path), "\(n)") }
    }

    @Test func planBarrierFailsClosedWhenOutputIsCut() throws {
        let (f, wt) = try barrierFixture()
        var ws = f.ws
        for i in 0..<50 { try f.write("ignored-\(i).log", "x", in: wt) }
        ws.planBarrierOutputLimit = 256
        #expect(throws: GitError.self, "no snapshot from a cut listing") { try ws.planBarrier(key: "ACME-1", in: wt) }
        ws.planBarrierOutputLimit = 1 << 20
        let before = try ws.planBarrier(key: "ACME-1", in: wt)
        ws.planBarrierOutputLimit = 256
        let error = try #require(throws: GitWorkspace.PlanBarrierError.self) { try ws.enforcePlanBarrier(before, key: "ACME-1", in: wt) }
        #expect(error.reason.contains("longer than 256 bytes"))
    }

    @Test func planBarrierFlagsChangedAndRemovedIgnoredFiles() throws {
        let (f, wt) = try barrierFixture()
        try f.write("same.log", "same", in: wt); try f.write("edit.log", "1234", in: wt); try f.write("gone.log", "x", in: wt)
        let before = try f.ws.planBarrier(key: "ACME-1", in: wt)
        // Rewritten in place with the same size: the modification time gives it away (no content is hashed).
        let h = try FileHandle(forWritingTo: wt.appending(path: "edit.log"))
        try h.write(contentsOf: Data("abcd".utf8)); try h.close()
        try FileManager.default.removeItem(at: wt.appending(path: "gone.log"))
        let found = try f.ws.enforcePlanBarrier(before, key: "ACME-1", in: wt)
        #expect(found.sorted() == ["changed ignored file edit.log", "removed ignored file gone.log"])
    }

    @Test func planBarrierRestoresMovedAndNewRefs() throws {
        let (f, wt) = try barrierFixture()
        let start = try #require(try f.ws.head(of: "refs/heads/item/ACME-1"))
        let other = try f.git(["commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "evil"])
        try f.git(["tag", "v1", start])
        var before = try f.ws.planBarrier(key: "ACME-1", in: wt)
        try f.git(["update-ref", "refs/heads/item/ACME-1", other])
        try f.git(["update-ref", "refs/tags/v1", other])
        try f.git(["tag", "evil", other])
        try f.git(["update-ref", "refs/notes/x", other])
        var found = try f.ws.enforcePlanBarrier(before, key: "ACME-1", in: wt)
        #expect(found.sorted() == ["moved ref refs/heads/item/ACME-1", "moved ref refs/tags/v1", "new ref refs/notes/x", "new ref refs/tags/evil"])
        #expect(try f.ws.head(of: "refs/heads/item/ACME-1") == start)
        #expect(try f.ws.head(of: "refs/tags/v1") == start)
        #expect(try f.ws.head(of: "refs/tags/evil") == nil)
        #expect(try f.ws.head(of: "refs/notes/x") == nil)
        // Packed refs: a loose ref that shadows the packed one, then the packed-refs file itself.
        try f.git(["pack-refs", "--all"])
        before = try f.ws.planBarrier(key: "ACME-1", in: wt)
        try f.git(["update-ref", "refs/tags/v1", other])
        #expect(try f.ws.enforcePlanBarrier(before, key: "ACME-1", in: wt) == ["moved ref refs/tags/v1"])
        #expect(try f.ws.head(of: "refs/tags/v1") == start)
        try f.git(["pack-refs", "--all"])
        before = try f.ws.planBarrier(key: "ACME-1", in: wt)
        let packed = f.root.appending(path: ".git/packed-refs")
        let text = try String(contentsOf: packed, encoding: .utf8)
        #expect(text.contains("\(start) refs/tags/v1"))
        try text.replacingOccurrences(of: "\(start) refs/tags/v1", with: "\(other) refs/tags/v1")
            .write(to: packed, atomically: true, encoding: .utf8)
        found = try f.ws.enforcePlanBarrier(before, key: "ACME-1", in: wt)
        #expect(found == ["moved ref refs/tags/v1"])
        #expect(try f.ws.head(of: "refs/tags/v1") == start)
    }

    @Test func planBarrierLeavesEngineManagedRefsAlone() throws {
        let (f, wt) = try barrierFixture()
        let other = try f.git(["commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "merged"])
        try f.ws.addWorktree(key: "ACME-2")
        try f.git(["update-ref", "refs/brahma/quarantine/old", other])
        let before = try f.ws.planBarrier(key: "ACME-1", in: wt)
        // The engine merges into main, quarantines a ref and another leaseholder commits (a branch that already existed), all while the plan turn runs.
        try f.git(["update-ref", "refs/heads/main", other])
        try f.git(["update-ref", "refs/brahma/quarantine/new", other])
        try f.git(["update-ref", "-d", "refs/brahma/quarantine/old"])
        try f.git(["update-ref", "refs/heads/item/ACME-2", other])
        #expect(try f.ws.enforcePlanBarrier(before, key: "ACME-1", in: wt).isEmpty)
        #expect(try f.ws.head(of: "refs/heads/main") == other, "main is the main guard's, never put back")
        #expect(try f.ws.head(of: "refs/brahma/quarantine/new") == other)
        #expect(try f.ws.head(of: "refs/brahma/quarantine/old") == nil)
        #expect(try f.ws.head(of: "refs/heads/item/ACME-2") == other)
        #expect(GitWorkspace.engineManaged("refs/heads/item/ACME-1", ownBranch: "refs/heads/item/ACME-1") == false)
    }

    @Test func planBarrierRestoresRepositoryFilesWithTheirModes() throws {
        let (f, wt) = try barrierFixture()
        let fm = FileManager.default
        let admin = f.root.appending(path: ".git/worktrees/ACME-1")
        let script = "#!/bin/sh\nexit 0\n"
        let hook = try f.write(".git/hooks/post-checkout", script)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)      // exec-bit fixture: a mode under test, never run
        let before = try f.ws.planBarrier(key: "ACME-1", in: wt)
        // Rewritten (and so no longer executable), attributes and an alternate added and a tracked file hidden from status
        // with the skip-worktree bit. (A repointed worktree HEAD is the engine's own check, not the barrier's.)
        try "#!/bin/sh\ntouch /tmp/pwned\n".write(to: hook, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: hook.path)
        try f.write(".git/info/attributes", "* filter=evil\n")
        try f.write(".git/objects/info/alternates", "/tmp/elsewhere\n")
        try f.git(["update-index", "--skip-worktree", "a.txt"], in: wt)
        let found = try f.ws.enforcePlanBarrier(before, key: "ACME-1", in: wt)
        #expect(Set(found) == ["changed hooks/post-checkout", "changed info/attributes", "new objects/info/alternates",
                               "changed index"])
        #expect(try String(contentsOf: hook, encoding: .utf8) == script)
        #expect((try fm.attributesOfItem(atPath: hook.path)[.posixPermissions] as? Int) == 0o755, "the hook stays executable")
        #expect(try String(contentsOf: f.root.appending(path: ".git/info/attributes"), encoding: .utf8) == GitCommand.attributesOverride,
                "the engine's own attributes override is put back")
        #expect(!fm.fileExists(atPath: f.root.appending(path: ".git/objects/info/alternates").path))
        #expect(try f.git(["ls-files", "-v", "a.txt"], in: wt) == "H a.txt")
        // A mode change alone is a change too.
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)      // exec-bit fixture: a mode under test, never run
        #expect(try f.ws.enforcePlanBarrier(before, key: "ACME-1", in: wt) == ["changed hooks/post-checkout"])
        #expect((try fm.attributesOfItem(atPath: hook.path)[.posixPermissions] as? Int) == 0o755)
    }

    @Test func planBarrierIgnoresAnIndexRefresh() throws {
        let (f, wt) = try barrierFixture()
        let index = f.root.appending(path: ".git/worktrees/ACME-1/index")
        let before = try f.ws.planBarrier(key: "ACME-1", in: wt)
        let bytes = try Data(contentsOf: index)
        // The CLI's own `git status` may rewrite the index's stat cache; the index still says the same.
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(30)], ofItemAtPath: wt.appending(path: "a.txt").path)
        try f.git(["update-index", "--refresh"], in: wt)
        #expect(try Data(contentsOf: index) != bytes, "the refresh really rewrote the index")
        #expect(try f.ws.enforcePlanBarrier(before, key: "ACME-1", in: wt).isEmpty)
    }

    // MARK: H1: a worktree's HEAD stays on its item branch

    final class TamperLog: @unchecked Sendable {
        private let lock = NSLock(); private var items: [String] = []
        func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private func watched(_ f: GitFixture) -> (GitWorkspace, TamperLog) {
        let log = TamperLog()
        var ws = f.ws
        ws.onWorktreeTamper = { key, detail in log.add("\(key): \(detail)") }
        return (ws, log)
    }

    @Test func headRewrittenToMainRefusesAndHeals() throws {
        let f = try GitFixture(files: ["a.txt": "one"])
        let (ws, log) = watched(f)
        let wt = try ws.addWorktree(key: "K-1")
        let main = try #require(try ws.head(of: "refs/heads/main"))
        let admin = f.root.appending(path: ".git/worktrees/K-1")
        try f.write("b.txt", "two", in: wt)
        #expect(try ws.commitAll(in: wt, message: "first") != nil)
        #expect(log.all.isEmpty, "a normal checkout raises nothing")
        // Another turn rewrites this worktree's HEAD to main.
        try f.write("c.txt", "three", in: wt)
        try "ref: refs/heads/main\n".write(to: admin.appending(path: "HEAD"), atomically: true, encoding: .utf8)
        let branch = try #require(try ws.head(of: "refs/heads/item/K-1"))
        #expect(throws: GitError.self) { try ws.commitAll(in: wt, message: "evil") }
        #expect(try ws.head(of: "refs/heads/main") == main, "main did not move")
        #expect(try ws.head(of: "refs/heads/item/K-1") == branch)
        #expect(log.all.count == 1)
        #expect(log.all.first?.contains("HEAD") == true)
        #expect(try String(contentsOf: admin.appending(path: "HEAD"), encoding: .utf8) == "ref: refs/heads/item/K-1\n", "healed from the record")
        // After the heal the commit lands on the item branch.
        let sha = try #require(try ws.commitAll(in: wt, message: "after heal"))
        #expect(try ws.head(of: "refs/heads/item/K-1") == sha)
        #expect(try ws.head(of: "refs/heads/main") == main)
        #expect(log.all.count == 1, "one alert for one tamper")
    }

    @Test func everyEngineEntryPointChecksHead() throws {
        let f = try GitFixture(files: ["a.txt": "one"])
        let (ws, log) = watched(f)
        let wt = try ws.addWorktree(key: "K-1")
        let start = try #require(try ws.head(of: "refs/heads/item/K-1"))
        let admin = f.root.appending(path: ".git/worktrees/K-1")
        func tamper(_ text: String = "ref: refs/heads/main\n") throws {
            try text.write(to: admin.appending(path: "HEAD"), atomically: true, encoding: .utf8)
        }
        try tamper(); #expect(throws: GitError.self) { try ws.isDirty(in: wt) }
        try tamper(); #expect(throws: GitError.self) { try ws.headCommit(in: wt) }
        try tamper(); #expect(throws: GitError.self) { try ws.resetHard(in: wt, to: start) }
        try tamper(); #expect(throws: GitError.self) { try ws.planBarrier(key: "K-1", in: wt) }
        let before = try ws.planBarrier(key: "K-1", in: wt)
        try tamper(); #expect(throws: GitWorkspace.PlanBarrierError.self) { try ws.enforcePlanBarrier(before, key: "K-1", in: wt) }
        // A detached HEAD is no better.
        try tamper(start + "\n"); #expect(throws: GitError.self) { try ws.commitAll(in: wt, message: "x") }
        // Removal commits first: refused (the checkout stays), and works after the heal.
        try f.write("keep.txt", "work", in: wt)
        try tamper()
        #expect(throws: GitError.self) { try ws.removeWorktree(key: "K-1", keepIf: { false }) }
        #expect(FileManager.default.fileExists(atPath: wt.path))
        try ws.removeWorktree(key: "K-1", keepIf: { false })
        #expect(!FileManager.default.fileExists(atPath: wt.path))
        #expect(try f.git(["show", "item/K-1:keep.txt"]) == "work")
        #expect(try ws.head(of: "refs/heads/main") == start)
        #expect(log.all.count == 7)
    }

    @Test func repointedGitdirAndCommondirAreAlertsToo() throws {
        let f = try GitFixture(files: ["a.txt": "one"])
        let (ws, log) = watched(f)
        let wt = try ws.addWorktree(key: "K-1")
        let admin = f.root.appending(path: ".git/worktrees/K-1")
        #expect(try ws.isDirty(in: wt) == false)
        #expect(log.all.isEmpty, "the paths git wrote itself (resolved or not) are the engine's")
        try "/tmp/elsewhere/.git\n".write(to: admin.appending(path: "commondir"), atomically: true, encoding: .utf8)
        #expect(throws: GitError.self) { try ws.commitAll(in: wt, message: "x") }
        #expect(log.all.count == 1 && log.all[0].contains("commondir"))
        #expect(try String(contentsOf: admin.appending(path: "commondir"), encoding: .utf8) == "../..\n")
        try "gitdir: /tmp/elsewhere/.git\n".write(to: wt.appending(path: ".git"), atomically: true, encoding: .utf8)
        #expect(throws: GitError.self) { try ws.commitAll(in: wt, message: "x") }
        #expect(log.all.count == 2 && log.all[1].contains(".git"))
        try f.write("b.txt", "two", in: wt)
        #expect(try ws.commitAll(in: wt, message: "ok") != nil)
        // A symlink in place of HEAD is replaced by a regular file.
        try FileManager.default.removeItem(at: admin.appending(path: "HEAD"))
        try FileManager.default.createSymbolicLink(atPath: admin.appending(path: "HEAD").path, withDestinationPath: f.root.appending(path: ".git/HEAD").path)
        #expect(throws: GitError.self) { try ws.isDirty(in: wt) }
        #expect(try ws.isDirty(in: wt) == false)
        #expect(log.all.count == 3)
    }

    // MARK: Engine commits never go through HEAD

    @Test func commitLandsOnTheItemBranchEvenIfHeadIsFlippedMidOperation() throws {
        let f = try GitFixture(files: ["a.txt": "one"])
        var (ws, log) = watched(f)
        let wt = try ws.addWorktree(key: "K-1")
        let main = try #require(try ws.head(of: "refs/heads/main"))
        let admin = f.root.appending(path: ".git/worktrees/K-1")
        ws.testHook = { stage in
            // After the engine's check and before its commit: the turn points HEAD at main.
            if stage == "checked" { try? "ref: refs/heads/main\n".write(to: admin.appending(path: "HEAD"), atomically: true, encoding: .utf8) }
        }
        try f.write("b.txt", "two", in: wt)
        let sha = try #require(try ws.commitAll(in: wt, message: "work"))
        #expect(try ws.head(of: "refs/heads/main") == main, "main did not move")
        #expect(try ws.head(of: "refs/heads/item/K-1") == sha)
        #expect(try f.git(["show", "\(sha):b.txt"]) == "two")
        #expect(try f.git(["log", "-1", "--format=%s", sha]) == "work" && (try f.git(["rev-parse", "\(sha)^"])) == main)
        #expect(log.all.count == 1, "the flip is noticed afterwards and reported once")
        #expect(try String(contentsOf: admin.appending(path: "HEAD"), encoding: .utf8) == "ref: refs/heads/item/K-1\n")
        ws.testHook = nil
        #expect(try ws.isDirty(in: wt) == false, "the worktree's own index follows the branch")
        #expect(try f.git(["status", "--porcelain"], in: wt) == "")
        #expect(try ws.commitAll(in: wt, message: "nothing") == nil)
    }

    @Test func commitFailsWhenTheItemBranchMovedMeanwhile() throws {
        let f = try GitFixture(files: ["a.txt": "one"])
        var (ws, _) = watched(f)
        let wt = try ws.addWorktree(key: "K-1")
        let other = try f.git(["commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "raced"])
        ws.testHook = { stage in if stage == "checked" { _ = try? f.git(["update-ref", "refs/heads/item/K-1", other]) } }
        try f.write("b.txt", "two", in: wt)
        #expect(throws: GitError.self) { try ws.commitAll(in: wt, message: "work") }
        #expect(try ws.head(of: "refs/heads/item/K-1") == other, "the compare-and-swap kept the other writer's value")
    }

    @Test func resetNeverMovesAnotherBranchWhenHeadIsFlipped() throws {
        let f = try GitFixture(files: ["a.txt": "one"])
        var (ws, _) = watched(f)
        let wt = try ws.addWorktree(key: "K-1")
        let main = try #require(try ws.head(of: "refs/heads/main"))
        try f.write("b.txt", "two", in: wt)
        _ = try ws.commitAll(in: wt, message: "work")
        try f.write("junk.txt", "untracked", in: wt)
        try f.write("a.txt", "changed", in: wt)
        let admin = f.root.appending(path: ".git/worktrees/K-1")
        ws.testHook = { stage in
            if stage == "checked" { try? "ref: refs/heads/main\n".write(to: admin.appending(path: "HEAD"), atomically: true, encoding: .utf8) }
        }
        try ws.resetHard(in: wt, to: main)
        #expect(try ws.head(of: "refs/heads/main") == main)
        #expect(try ws.head(of: "refs/heads/item/K-1") == main, "the item branch went back")
        #expect(try String(contentsOf: wt.appending(path: "a.txt"), encoding: .utf8) == "one")
        #expect(!FileManager.default.fileExists(atPath: wt.appending(path: "b.txt").path))
        #expect(!FileManager.default.fileExists(atPath: wt.appending(path: "junk.txt").path))
        ws.testHook = nil
        #expect(try ws.isDirty(in: wt) == false)
    }

    @Test func linkedRepositoryDirectoriesAreRefusedAndReported() throws {
        let f = try GitFixture(files: ["a.txt": "one"])
        let (ws, log) = watched(f)
        let wt = try ws.addWorktree(key: "K-1")
        let fm = FileManager.default
        let admin = f.root.appending(path: ".git/worktrees/K-1")
        let copy = try tempDir().appending(path: "admin-copy", directoryHint: .isDirectory)
        try fm.copyItem(at: admin, to: copy)
        try "ref: refs/heads/main\n".write(to: copy.appending(path: "HEAD"), atomically: true, encoding: .utf8)
        try fm.removeItem(at: admin)
        try fm.createSymbolicLink(atPath: admin.path, withDestinationPath: copy.path)
        #expect(throws: GitError.self) { try ws.commitAll(in: wt, message: "x") }
        #expect(log.all.count == 1 && log.all[0].contains(".git/worktrees/K-1"))
        #expect(try String(contentsOf: copy.appending(path: "HEAD"), encoding: .utf8) == "ref: refs/heads/main\n", "nothing was healed through the link")
        // The whole `worktrees` directory as a link.
        try fm.removeItem(at: admin)
        try fm.copyItem(at: copy, to: admin)
        try "ref: refs/heads/item/K-1\n".write(to: admin.appending(path: "HEAD"), atomically: true, encoding: .utf8)
        let dir = f.root.appending(path: ".git/worktrees")
        let moved = try tempDir().appending(path: "worktrees", directoryHint: .isDirectory)
        try fm.moveItem(at: dir, to: moved)
        try fm.createSymbolicLink(atPath: dir.path, withDestinationPath: moved.path)
        #expect(throws: GitError.self) { try ws.isDirty(in: wt) }
        #expect(log.all.count == 2 && log.all[1].contains(".git/worktrees is not"))
    }

    // MARK: H2 and H3

    @Test func planBarrierDeletesANewItemBranch() throws {
        let (f, wt) = try barrierFixture()
        let other = try f.git(["commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "planted"])
        try f.ws.addWorktree(key: "ACME-2")
        let before = try f.ws.planBarrier(key: "ACME-1", in: wt)
        try f.git(["branch", "item/ACME-9", other])
        try f.git(["update-ref", "refs/heads/item/ACME-2", other])          // existed before: the engine's, left alone
        let found = try f.ws.enforcePlanBarrier(before, key: "ACME-1", in: wt)
        #expect(found == ["new ref refs/heads/item/ACME-9"])
        #expect(try f.ws.head(of: "refs/heads/item/ACME-9") == nil)
        #expect(try f.ws.head(of: "refs/heads/item/ACME-2") == other)
        // Packed refs too.
        let again = try f.ws.planBarrier(key: "ACME-1", in: wt)
        try f.git(["branch", "item/ACME-8", other])
        try f.git(["pack-refs", "--all"])
        #expect(try f.ws.enforcePlanBarrier(again, key: "ACME-1", in: wt) == ["new ref refs/heads/item/ACME-8"])
        #expect(try f.ws.head(of: "refs/heads/item/ACME-8") == nil)
    }

    @Test func planBarrierKeepsAnItemBranchTheEngineCreated() throws {
        let (f, wt) = try barrierFixture()
        let other = try f.git(["commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "planted"])
        final class Leases: @unchecked Sendable { var keys: Set<String> = [] }
        let leases = Leases()
        var ws = f.ws
        ws.hasLease = { leases.keys.contains($0) }
        let before = try ws.planBarrier(key: "ACME-1", in: wt)
        // Another agent claims new items while the plan turn runs: one with a worktree, one with only a lease.
        let claimed = try ws.addWorktree(key: "ACME-5")
        try f.git(["branch", "item/ACME-6", other]); leases.keys.insert("ACME-6")
        // A planted branch has no record; a planted branch with a bare admin dir is not a worktree either.
        try f.git(["branch", "item/ACME-9", other])
        #expect(try ws.enforcePlanBarrier(before, key: "ACME-1", in: wt) == ["new ref refs/heads/item/ACME-9"])
        #expect(try ws.head(of: "refs/heads/item/ACME-5") != nil && FileManager.default.fileExists(atPath: claimed.path))
        #expect(try ws.head(of: "refs/heads/item/ACME-6") == other)
        #expect(try ws.head(of: "refs/heads/item/ACME-9") == nil)
        try f.write("w.txt", "work", in: claimed)
        #expect(try ws.commitAll(in: claimed, message: "work") != nil, "the claimed worktree works")
    }

    @Test func planBarrierFailsClosedOnIgnoredDirectories() throws {
        let (f, wt) = try barrierFixture()
        let exclude = f.root.appending(path: ".git/info/exclude")
        try (try String(contentsOf: exclude, encoding: .utf8) + "emptydir/\nvendor/\n").write(to: exclude, atomically: true, encoding: .utf8)
        // A nested repository is listed by git as one entry, `vendor/`, whose contents the barrier cannot see.
        try FileManager.default.createDirectory(at: wt.appending(path: "vendor"), withIntermediateDirectories: true)
        try GitFixture.plainGit(["init", "--quiet"], in: wt.appending(path: "vendor"))
        try f.write("vendor/x.txt", "hidden", in: wt)
        let error = try #require(throws: GitError.self) { try f.ws.planBarrier(key: "ACME-1", in: wt) }
        #expect("\(error)".contains("cannot verify ignored directory"))
        try FileManager.default.removeItem(at: wt.appending(path: "vendor"))
        // Created during the turn: the check fails closed (nothing is deleted blindly).
        let before = try f.ws.planBarrier(key: "ACME-1", in: wt)
        try FileManager.default.createDirectory(at: wt.appending(path: "vendor"), withIntermediateDirectories: true)
        try GitFixture.plainGit(["init", "--quiet"], in: wt.appending(path: "vendor"))
        try f.write("vendor/x.txt", "hidden", in: wt)
        let failed = try #require(throws: GitWorkspace.PlanBarrierError.self) { try f.ws.enforcePlanBarrier(before, key: "ACME-1", in: wt) }
        #expect(failed.reason.contains("cannot verify ignored directory"))
    }

    // MARK: Bounded repository-file capture

    private func sparse(_ url: URL, size: UInt64) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let h = try FileHandle(forWritingTo: url)
        try h.truncate(atOffset: size); try h.close()
    }

    @Test func planBarrierBoundsWhatItReadsOfTheRepository() throws {
        let (f, wt) = try barrierFixture()
        let fm = FileManager.default
        let git = f.root.appending(path: ".git")
        // Snapshot: a huge file, then too many files, and no plan turn starts.
        try sparse(git.appending(path: "hooks/big"), size: 64 << 20)
        let big = try #require(throws: GitError.self) { try f.ws.planBarrier(key: "ACME-1", in: wt) }
        #expect("\(big)".contains("hooks/big"))
        try fm.removeItem(at: git.appending(path: "hooks/big"))
        for i in 0..<600 { try f.write(".git/info/many/f\(i)", "x") }
        #expect(throws: GitError.self) { try f.ws.planBarrier(key: "ACME-1", in: wt) }
        try fm.removeItem(at: git.appending(path: "info/many"))
        // Check: the same plants during the turn are deleted and fail the check; a known file that grew is put back.
        try f.write(".git/hooks/small", "#!/bin/sh\n")
        let before = try f.ws.planBarrier(key: "ACME-1", in: wt)
        try sparse(git.appending(path: "hooks/big"), size: 64 << 20)
        try sparse(git.appending(path: "hooks/small"), size: 4 << 20)
        for i in 0..<600 { try f.write(".git/info/many/f\(i)", "x") }
        let error = try #require(throws: GitWorkspace.PlanBarrierError.self) { try f.ws.enforcePlanBarrier(before, key: "ACME-1", in: wt) }
        #expect(error.reason.contains("hooks/big") && error.reason.contains("hooks/small") && error.reason.contains("more than 500"))
        #expect(error.found.contains("new hooks/big") && error.found.contains("changed hooks/small"))
        #expect(!fm.fileExists(atPath: git.appending(path: "hooks/big").path))
        #expect(!fm.fileExists(atPath: git.appending(path: "info/many").path), "the planted directory is gone")
        #expect(try String(contentsOf: git.appending(path: "hooks/small"), encoding: .utf8) == "#!/bin/sh\n")
        #expect(try f.ws.enforcePlanBarrier(before, key: "ACME-1", in: wt).isEmpty, "clean again")
    }

    @Test func planBarrierReportsARestoreThatFailed() throws {
        let (f, wt) = try barrierFixture()
        let fm = FileManager.default
        let hooks = f.root.appending(path: ".git/hooks")
        try f.write(".git/hooks/post-commit", "#!/bin/sh\n")
        let before = try f.ws.planBarrier(key: "ACME-1", in: wt)
        try "#!/bin/sh\ntouch /tmp/pwned\n".write(to: hooks.appending(path: "post-commit"), atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: hooks.path)      // the put-back cannot write here (exec-bit fixture: a directory)
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hooks.path) }  // exec-bit fixture: a directory
        let error = try #require(throws: GitWorkspace.PlanBarrierError.self) { try f.ws.enforcePlanBarrier(before, key: "ACME-1", in: wt) }
        #expect(error.found == ["changed hooks/post-commit"])
        #expect(error.reason.contains("restore hooks/post-commit"))
    }

    // MARK: The item branch is never a symbolic ref

    @Test func itemBranchSymrefToMainNeverMovesMain() throws {
        let f = try GitFixture(files: ["a.txt": "one"])
        let (ws, log) = watched(f)
        let wt = try ws.addWorktree(key: "K-1")
        let main = try #require(try ws.head(of: GitWorkspace.mainRef))
        try f.write("b.txt", "two", in: wt)
        let first = try #require(try ws.commitAll(in: wt, message: "first"))
        // Another agent makes this item's branch a symbolic ref to main.
        try f.git(["symbolic-ref", "refs/heads/item/K-1", GitWorkspace.mainRef])
        try f.write("c.txt", "three", in: wt)
        #expect(throws: GitError.self) { try ws.commitAll(in: wt, message: "evil") }
        #expect(try ws.head(of: GitWorkspace.mainRef) == main, "the commit did not land on main")
        #expect(throws: GitError.self) { try ws.resetHard(in: wt, to: first) }
        #expect(try ws.head(of: GitWorkspace.mainRef) == main, "the reset did not move main")
        #expect(log.all.count == 2)
        #expect(log.all.allSatisfy { $0.contains("refs/heads/item/K-1 is a symbolic ref") })
        // Put back by the owner: work goes on, on the item branch.
        try f.git(["update-ref", "--no-deref", "refs/heads/item/K-1", first])
        #expect(try ws.commitAll(in: wt, message: "after") != nil)
        #expect(try ws.head(of: GitWorkspace.mainRef) == main)
    }

    @Test func itemBranchTurnedSymbolicMidOperationLeavesMainAlone() throws {
        for reset in [false, true] {
            let f = try GitFixture(files: ["a.txt": "one"])
            var (ws, _) = watched(f)
            let wt = try ws.addWorktree(key: "K-1")
            let main = try #require(try ws.head(of: GitWorkspace.mainRef))
            // After the engine's check: the item branch (still at main's commit) becomes a symbolic ref to main.
            ws.testHook = { stage in if stage == "checked" { _ = try? f.git(["symbolic-ref", "refs/heads/item/K-1", GitWorkspace.mainRef]) } }
            if reset {
                // The reset reads the ref after the flip: refused, nothing moved.
                let other = try f.git(["commit-tree", "HEAD^{tree}", "-p", "HEAD", "-m", "elsewhere"])
                #expect(throws: GitError.self) { try ws.resetHard(in: wt, to: other) }
            } else {
                // The commit read the tip before the flip: the CAS overwrites the symbolic ref instead of following it.
                try f.write("b.txt", "two", in: wt)
                let sha = try ws.commitAll(in: wt, message: "work")
                #expect(try f.git(["symbolic-ref", "-q", "refs/heads/item/K-1"], allowFailure: true) == "", "the item ref is direct again")
                #expect(try f.git(["rev-parse", "refs/heads/item/K-1"]) == sha)
            }
            #expect(try ws.head(of: GitWorkspace.mainRef) == main, "reset: \(reset)")
        }
    }

    @Test func repositoryDirectoryLinkedMidOperationIsReportedAfterwards() throws {
        let f = try GitFixture(files: ["a.txt": "one"])
        var (ws, log) = watched(f)
        let wt = try ws.addWorktree(key: "K-1")
        // After the check: `.git/worktrees` becomes a link to a copy (git still finds everything through it).
        let worktrees = f.root.appending(path: ".git/worktrees")
        let moved = f.root.appending(path: ".git/moved-worktrees")
        ws.testHook = { stage in
            guard stage == "checked" else { return }
            try? FileManager.default.moveItem(at: worktrees, to: moved)
            try? FileManager.default.createSymbolicLink(at: worktrees, withDestinationURL: moved)
        }
        try f.write("b.txt", "two", in: wt)
        let error = try #require(throws: GitError.self) { try ws.commitAll(in: wt, message: "work") }
        #expect("\(error)".contains("is not a real directory"))
        #expect(log.all.count == 1 && log.all[0].contains(".git/worktrees is not a real directory"))
    }

    @Test func planBarrierTakesALargeIndex() throws {
        let (f, wt) = try barrierFixture()
        // Long paths make an index past the 1 MB cap of other repository files with few files.
        let dir = (0..<3).map { "d\($0)" + String(repeating: "x", count: 230) }.joined(separator: "/")
        for i in 0..<1600 { try f.write("\(dir)/f\(i)", "x", in: wt) }
        _ = try f.ws.commitAll(in: wt, message: "many")
        let index = f.root.appending(path: ".git/worktrees/ACME-1/index")
        #expect((try FileManager.default.attributesOfItem(atPath: index.path)[.size] as? Int ?? 0) > GitWorkspace.repoFileLimit)
        let before = try f.ws.planBarrier(key: "ACME-1", in: wt)
        #expect(try f.ws.enforcePlanBarrier(before, key: "ACME-1", in: wt).isEmpty)
    }

    // MARK: Engine checkouts never leave the workspace

    private func fileWatched(_ f: GitFixture) -> (GitWorkspace, TamperLog) {
        let log = TamperLog()
        var ws = f.ws
        ws.onUnsafeEngineFile = { problem in log.add("\(problem)") }
        return (ws, log)
    }

    @Test func linkedBrahmaGetsNoCheckoutAndLosesNothing() throws {
        let fm = FileManager.default
        let f = try GitFixture(files: ["a.txt": "one"])
        let (ws, log) = fileWatched(f)
        let main = try f.git(["rev-parse", "refs/heads/main"])
        let outside = try tempDir()
        // Things outside the workspace at the places `.brahma/wt` and `.brahma/wt-check` would name through the link.
        let kept = ["wt/K-2/keep.txt", "wt/.merge/keep.txt", "wt-check/r2/keep.txt", "wt-check/stray/keep.txt", "wt-check/r3/.git"]
        for rel in kept { try f.write(rel, "keep", in: outside) }
        let brahma = f.root.appending(path: ".brahma")
        if (try? fm.attributesOfItem(atPath: brahma.path)) != nil { try fm.removeItem(at: brahma) }
        try fm.createSymbolicLink(at: brahma, withDestinationURL: outside)
        let before = Set(try fm.subpathsOfDirectory(atPath: outside.path))
        #expect(throws: GitError.self) { try ws.addWorktree(key: "K-1") }
        // A submission's checkout and a merge-check export live under the data home: the link in the workspace has no say.
        let check = try ws.addRunWorktree(runId: "r1", commit: main)
        #expect(check.path == ws.checkoutPath(runId: "r1").path && exists(check.appending(path: "a.txt")))
        ws.removeRunWorktree(runId: "r1")
        #expect(!exists(check))
        let export = try ws.addEngineExport(runId: "r4", commit: main)
        #expect(export.path == ws.exportPath(runId: "r4").path && exists(export.appending(path: "a.txt")))
        #expect(throws: GitError.self) { try ws.removeWorktree(key: "K-2", keepIf: { false }) }
        ws.removeRunWorktree(runId: "r2")
        ws.removeRunWorktree(runId: "r3")
        ws.removeRunWorktrees()
        #expect(Set(try fm.subpathsOfDirectory(atPath: outside.path)) == before, "something was created or deleted outside the workspace")
        for rel in kept { #expect(exists(outside.appending(path: rel)), "\(rel) was deleted") }
        #expect(!(try f.git(["worktree", "list"])).contains("wt/K-1"))
        // Refused and reported: the worktree, its removal, and the start-up sweep of what older engines left in `.brahma/wt-check`.
        #expect(log.all.count == 3 && log.all.allSatisfy { $0.contains(".brahma is a symbolic link") }, "\(log.all)")
    }

    @Test func checkoutPlaceSwappedBeforeGitRunsIsRefused() throws {
        let fm = FileManager.default
        let f = try GitFixture(files: ["a.txt": "one"])
        let main = try f.git(["rev-parse", "refs/heads/main"])
        let outside = try tempDir()
        let home = try tempDir()
        // An item worktree's `.brahma`, and a submission checkout's `<home>/run/checkouts` under the data home (A7). (A
        // merge-check export: `exportSwappedForALinkAfterItsLastCheckWritesNothingOutside`.)
        let calls: [(URL, (GitWorkspace) throws -> Void)] = [
            (f.root.appending(path: ".brahma"), { _ = try $0.addWorktree(key: "K-1") }),
            (home.appending(path: "run/checkouts"), { _ = try $0.addRunWorktree(runId: "r1", commit: main) }),
        ]
        for (n, (brahma, run)) in calls.enumerated() {
            let moved = brahma.deletingLastPathComponent().appending(path: brahma.lastPathComponent + "-moved")
            let made = fileWatched(f)
            var ws = GitWorkspace(root: f.root, lockDirectory: made.0.lockDirectory, mergeDirectory: made.0.mergeDirectory, exportHome: home)
            ws.onUnsafeEngineFile = made.0.onUnsafeEngineFile
            let log = made.1
            // Once the place is made, and before git runs, its directory is moved away and replaced by a link outside.
            ws.checkoutProbe = { _ in
                try? FileManager.default.moveItem(at: brahma, to: moved)
                try? FileManager.default.createSymbolicLink(at: brahma, withDestinationURL: outside)
            }
            #expect(throws: GitError.self) { try run(ws) }
            #expect(try fm.contentsOfDirectory(atPath: outside.path).isEmpty, "case \(n): git or tar wrote outside the workspace")
            #expect(log.all.count == 1 && log.all[0].contains("moved while"), "case \(n): \(log.all)")
            // The place it made is gone (removed through the moved directory), and git keeps no record of it.
            let left = try fm.subpathsOfDirectory(atPath: moved.path).filter { ["K-1", "r1"].contains(URL(fileURLWithPath: $0).lastPathComponent) }
            #expect(left.isEmpty, "case \(n): \(left)")
            let listed = try f.git(["worktree", "list"])
            #expect(!listed.contains("checkouts/r1") && !listed.contains("wt/K-1"), "case \(n): \(listed)")
            try fm.removeItem(at: brahma)
            try fm.moveItem(at: moved, to: brahma)
        }
        // With nothing swapped, the same calls work.
        let wt = try f.ws.addWorktree(key: "K-1")
        #expect(exists(wt.appending(path: "a.txt")))
        let check = try f.ws.addRunWorktree(runId: "r1", commit: main)
        #expect(exists(check.appending(path: "a.txt")))
        f.ws.removeRunWorktree(runId: "r1")
        #expect(!exists(check))
    }

    /// A7: a submission's check runs in a detached checkout under the data home (`<home>/run/checkouts/<runId>`, made 0700
    /// through the walk from the data home), never in the workspace; it is removed through the walked directory's
    /// descriptor, and git forgets it.
    @Test func submissionCheckoutRunsFromTheDataHome() throws {
        let fm = FileManager.default
        let home = try tempDir()
        let f = try GitFixture(files: ["a.txt": "one", "dir/b.txt": "two"])
        let main = try f.git(["rev-parse", "refs/heads/main"])
        let ws = GitWorkspace(root: f.root, mergeDirectory: home.appending(path: "run/merge/c1"), exportHome: home)
        let dir = try ws.addRunWorktree(runId: "run-1", commit: main)
        #expect(dir.path == home.appending(path: "run/checkouts/run-1").path)
        #expect(dir.path == BrahmaPaths(home: home, workspaces: f.root).checkoutDir(runId: "run-1").path)
        #expect((try fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int) == 0o700, "the checkout is engine-private")
        #expect(try String(contentsOf: dir.appending(path: "dir/b.txt"), encoding: .utf8) == "two")
        #expect(try GitFixture.plainGit(["rev-parse", "HEAD"], in: dir) == main)
        #expect(!exists(f.root.appending(path: ".brahma/wt-check")), "nothing of the checkout is in the workspace")
        #expect(try f.git(["worktree", "list"]).contains(dir.lastPathComponent))
        ws.removeRunWorktree(runId: "run-1")
        #expect(!exists(dir))
        #expect(!(try f.git(["worktree", "list"])).contains("run-1"))
        // A crashed run's leftovers go at start-up; a new checkout at a taken run id starts clean.
        let left = try ws.addRunWorktree(runId: "run-2", commit: main)
        try "stale".write(to: left.appending(path: "stale.txt"), atomically: true, encoding: .utf8)
        let again = try ws.addRunWorktree(runId: "run-2", commit: main)
        #expect(!exists(again.appending(path: "stale.txt")))
        ws.removeRunWorktrees()
        #expect(!exists(again))
        #expect(!(try f.git(["worktree", "list"])).contains("run-2"))
    }

    // MARK: Merge-check exports live under the data home

    /// Every file under `dir` (links not followed) with its bytes, or "link" for a link.
    private func tree(_ dir: URL) throws -> [String: String] {
        let fm = FileManager.default
        var out: [String: String] = [:]
        for rel in try fm.subpathsOfDirectory(atPath: dir.path) {
            let url = dir.appending(path: rel)
            let type = try fm.attributesOfItem(atPath: url.path)[.type] as? FileAttributeType
            if type == .typeSymbolicLink { out[rel] = "link" }
            else if type == .typeRegular { out[rel] = String(decoding: try Data(contentsOf: url), as: UTF8.self) }
            else { out[rel] = "dir" }
        }
        return out
    }

    @Test func exportRunsFromTheDataHome() throws {
        let fm = FileManager.default
        let home = try tempDir()
        let f = try GitFixture(files: ["a.txt": "one", "dir/b.txt": "two"])
        let main = try f.git(["rev-parse", "refs/heads/main"])
        let ws = GitWorkspace(root: f.root, mergeDirectory: home.appending(path: "run/merge/c1"), exportHome: home)
        let dir = try ws.addEngineExport(runId: "run-1", commit: main)
        #expect(dir.path == home.appending(path: "run/exports/run-1").path)
        #expect(dir.path == ws.exportPath(runId: "run-1").path)
        #expect(dir.path == BrahmaPaths(home: home, workspaces: f.root).exportDir(runId: "run-1").path)
        #expect((try fm.attributesOfItem(atPath: dir.path)[.posixPermissions] as? Int) == 0o700, "the export is engine-private")
        #expect(try String(contentsOf: dir.appending(path: "dir/b.txt"), encoding: .utf8) == "two")
        #expect(!exists(dir.appending(path: ".git")))
        #expect(!exists(f.root.appending(path: ".brahma/wt-check/run-1")), "nothing of the export is in the workspace")
        ws.removeRunWorktree(runId: "run-1")
        #expect(!exists(dir))
        // What a crashed run left is removed at start-up, and a new export at a taken run id starts clean.
        let left = try ws.addEngineExport(runId: "run-2", commit: main)
        try "stale".write(to: left.appending(path: "stale.txt"), atomically: true, encoding: .utf8)
        let again = try ws.addEngineExport(runId: "run-2", commit: main)
        #expect(!exists(again.appending(path: "stale.txt")))
        ws.removeRunWorktrees()
        #expect(!exists(again))
    }

    /// A4: the workspace repository's config is scanned (the allowlist guard) right before the engine repository fetches
    /// from it, for a merge-check export and for a landing alike; a refused config fetches nothing and nothing is exported.
    @Test func exportAndLandingScanTheWorkspaceConfigBeforeFetching() throws {
        let home = try tempDir()
        let f = try GitFixture(files: ["a.txt": "one"])
        let main = try f.git(["rev-parse", "refs/heads/main"])
        let log = TamperLog()
        var ws = GitWorkspace(root: f.root, mergeDirectory: home.appending(path: "run/merge/c1"), exportHome: home)
        ws.onUnsafeRepository = { log.add($0) }
        try f.git(["config", "uploadpack.packObjectsHook", "touch /tmp/never"])
        let error = try #require(throws: GitError.self) { try ws.addEngineExport(runId: "run-1", commit: main) }
        #expect(error.isRepositoryRefusal, "\(error)")
        #expect(log.all.contains { $0.contains("uploadpack.packobjectshook") || $0.contains("uploadpack.packObjectsHook") }, "\(log.all)")
        #expect(!exists(ws.exportPath(runId: "run-1")))
        let objects = try GitFixture.plainGit(["count-objects", "-v"], in: ws.mergeRepositoryPath)
        #expect(objects.contains("count: 0") && objects.contains("in-pack: 0"), "nothing was fetched: \(objects)")
        try f.git(["config", "--unset", "uploadpack.packObjectsHook"])
        #expect(try String(contentsOf: try ws.addEngineExport(runId: "run-1", commit: main).appending(path: "a.txt"), encoding: .utf8) == "one")
    }

    @Test func exportSwappedForALinkAfterItsLastCheckWritesNothingOutside() throws {
        let fm = FileManager.default
        let home = try tempDir()
        let f = try GitFixture(files: ["a.txt": "one", "dir/b.txt": "two"])
        let main = try f.git(["rev-parse", "refs/heads/main"])
        // The place itself, then its parent (`run/exports`), is moved away and replaced by a link outside once the engine
        // has checked it and before tar runs.
        for target in ["place", "parent"] {
            let outside = try tempDir()
            try f.write("a.txt", "keep", in: outside)
            try f.write("run-1/a.txt", "keep", in: outside)
            let before = try tree(outside)
            let log = TamperLog()
            var ws = GitWorkspace(root: f.root, mergeDirectory: home.appending(path: "run/merge/c1"), exportHome: home)
            ws.onUnsafeEngineFile = { problem in log.add("\(problem)") }
            let swapped = Swapped()
            ws.spawnProbe = { place in
                let victim = target == "place" ? place : place.deletingLastPathComponent()
                let moved = victim.deletingLastPathComponent().appending(path: victim.lastPathComponent + "-moved")
                try? FileManager.default.moveItem(at: victim, to: moved)
                try? FileManager.default.createSymbolicLink(at: victim, withDestinationURL: outside)
                swapped.set(victim, moved)
            }
            // The engine's own export place moved under it: the company's fault (reported), never the item's.
            #expect(throws: MergeInfrastructureError.self) { try ws.addEngineExport(runId: "run-1", commit: main) }
            #expect(try tree(outside) == before, "\(target): tar wrote or overwrote a file outside")
            #expect(log.all.count == 1 && log.all[0].contains("moved while"), "\(target): \(log.all)")
            // The engine removed what it made through its descriptor (for the place, the link that took its name).
            let (victim, moved) = try #require(swapped.get)
            if (try? fm.attributesOfItem(atPath: victim.path)) != nil { try fm.removeItem(at: victim) }
            try fm.moveItem(at: moved, to: victim)
        }
        // With nothing swapped, the export works.
        let dir = try GitWorkspace(root: f.root, mergeDirectory: home.appending(path: "run/merge/c1"), exportHome: home)
            .addEngineExport(runId: "run-1", commit: main)
        #expect(try String(contentsOf: dir.appending(path: "a.txt"), encoding: .utf8) == "one")
    }

    final class Swapped: @unchecked Sendable {
        private let lock = NSLock(); private var pair: (URL, URL)?
        func set(_ a: URL, _ b: URL) { lock.lock(); pair = (a, b); lock.unlock() }
        var get: (URL, URL)? { lock.lock(); defer { lock.unlock() }; return pair }
    }

    // MARK: Repository filters, drivers and replace objects

    final class Refusals: @unchecked Sendable {
        private let lock = NSLock(); private var items: [String] = []
        func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
        var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
    }

    private func guarded(_ f: GitFixture) -> (GitWorkspace, Refusals) {
        let log = Refusals()
        var ws = f.ws
        ws.onUnsafeRepository = { detail in log.add(detail) }
        return (ws, log)
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    /// Commits a `.gitattributes` that names the `evil` filter, diff and merge drivers for every path.
    private func attributed(_ f: GitFixture) throws {
        try f.write(".gitattributes", "* filter=evil diff=evil merge=evil\n")
        try f.git(["add", "-A"])
        try f.git(["commit", "-q", "-m", "attributes"])
    }

    @Test func everyCallCarriesTheHardening() throws {
        let f = try GitFixture(files: ["a.txt": "one"])
        let git = GitCommand(gitDir: f.root.appending(path: ".git"), workTree: f.root, commonDir: nil)
        let env = git.environment()
        let forcedEnv = ["GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_ATTR_NOSYSTEM": "1",
                         "GIT_NO_REPLACE_OBJECTS": "1", "GIT_GRAFT_FILE": "/dev/null", "GIT_TERMINAL_PROMPT": "0",
                         "GIT_ASKPASS": "/usr/bin/false", "SSH_ASKPASS": "/usr/bin/false", "GIT_OPTIONAL_LOCKS": "0",
                         "GIT_DIR": f.root.appending(path: ".git").path, "GIT_WORK_TREE": f.root.path,
                         "GIT_COMMON_DIR": f.root.appending(path: ".git").path]
        for (name, value) in forcedEnv { #expect(env[name] == value, "\(name)") }
        for name in ["GIT_EXTERNAL_DIFF", "GIT_SSH", "GIT_SSH_COMMAND", "GIT_PROXY_COMMAND", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT",
                     "GIT_EXEC_PATH", "GIT_PAGER", "GIT_EDITOR", "GIT_SEQUENCE_EDITOR"] { #expect(env[name] == nil, "\(name)") }
        // Every forced setting, exactly: dropping one fails here.
        let forced = [
            "user.name=Brahma", "user.email=engine@brahma.local", "commit.gpgsign=false", "tag.gpgSign=false",
            "core.fsmonitor=false", "core.hooksPath=/dev/null", "core.pager=cat", "diff.external=",
            "core.sshCommand=/usr/bin/false", "core.gitProxy=", "core.askPass=/usr/bin/false", "credential.helper=",
            "gpg.program=/usr/bin/false", "gpg.ssh.program=/usr/bin/false", "gpg.x509.program=/usr/bin/false",
            "log.showSignature=false", "merge.verifySignatures=false", "submodule.recurse=false", "diff.ignoreSubmodules=dirty",
            "protocol.allow=never", "protocol.ext.allow=never", "core.alternateRefsCommand=", "uploadpack.packObjectsHook=",
            "core.editor=/usr/bin/false", "sequence.editor=/usr/bin/false",
            "core.quotepath=false", "gc.auto=0", "core.attributesFile=/dev/null", "advice.graftFileDeprecated=false",
        ]
        #expect(GitCommand.configFlags == forced.flatMap { ["-c", $0] })
        // A linked worktree pins its own common dir the same way.
        let linked = GitCommand(gitDir: f.root.appending(path: ".git/worktrees/K"), workTree: f.root, commonDir: f.root.appending(path: ".git"))
        #expect(linked.environment()["GIT_COMMON_DIR"] == f.root.appending(path: ".git").path)
        let args = git.arguments(["status"], attrSource: GitCommand.emptyTreeSHA1)
        #expect(Array(args.suffix(args.count - 4)) == forced.flatMap { ["-c", $0] } + ["status"])
        #expect(args.contains("--attr-source=4b825dc642cb6eb9a060e54bf8d69288fbee4904"))
        #expect(args.contains("core.attributesFile=/dev/null"))
        #expect(args.firstIndex(of: "--attr-source=\(GitCommand.emptyTreeSHA1)")! < args.firstIndex(of: "status")!)
        // The engine's attributes override is in place after any engine call.
        _ = try f.ws.isDirty(in: f.root)
        #expect(try String(contentsOf: f.root.appending(path: ".git/info/attributes"), encoding: .utf8) == "* -filter !diff merge=text -export-ignore -export-subst\n")
        try f.write(".git/info/attributes", "* filter=evil\n")
        _ = try f.ws.isDirty(in: f.root)
        #expect(try String(contentsOf: f.root.appending(path: ".git/info/attributes"), encoding: .utf8) == GitCommand.attributesOverride)
    }

    @Test func attrSourceNeedsGit243() throws {
        // 2.43 is where `--attr-source` reaches child git processes (a checkout's) as GIT_ATTR_SOURCE.
        #expect(GitCommand.supportsAttrSource(versionLine: "git version 2.52.0"))
        #expect(GitCommand.supportsAttrSource(versionLine: "git version 2.43.0.windows.1"))
        #expect(!GitCommand.supportsAttrSource(versionLine: "git version 2.42.2"))
        #expect(GitCommand.supportsAttrSource(versionLine: "git version 3.0.1"))
        #expect(!GitCommand.supportsAttrSource(versionLine: "git version 2.41.9"))
        #expect(!GitCommand.supportsAttrSource(versionLine: "git version 2.39.5 (Apple Git-154)"))
        #expect(!GitCommand.supportsAttrSource(versionLine: "not git"))
        #expect(GitCommand.installedSupportsAttrSource, "git 2.52 is installed here")
        // On an older git, anything that reads, writes or compares trees is refused; ref plumbing still works.
        let f = try GitFixture(files: ["a.txt": "one"])
        var git = GitCommand(gitDir: f.root.appending(path: ".git"), workTree: f.root, commonDir: nil)
        git.attrSourceSupported = false
        #expect(throws: GitError.self) { try git.run(["status", "--porcelain"]) }
        #expect(throws: GitError.self) { try git.run(["diff", "HEAD", "HEAD"]) }
        #expect(throws: GitError.self) { try git.run(["worktree", "add", "--detach", "/tmp/never", "HEAD"]) }
        #expect(try git.run(["rev-parse", "HEAD"]).status == 0)
        #expect(try git.run(["worktree", "list", "--porcelain"]).status == 0)
    }

    @Test func repoFilterIsRefusedAndNeverRuns() throws {
        let f = try GitFixture(files: ["a.txt": "one\n"])
        try attributed(f)
        let (ws, log) = guarded(f)
        let wt = try ws.addWorktree(key: "K-1")
        let dir = try tempDir()
        let smudge = dir.appending(path: "smudged"), clean = dir.appending(path: "cleaned")
        try f.git(["config", "filter.evil.smudge", "touch '\(smudge.path)'; cat"])
        try f.git(["config", "filter.evil.clean", "touch '\(clean.path)'; cat"])
        try f.write("a.txt", "changed\n", in: wt)
        let main = try f.git(["rev-parse", "refs/heads/main"])
        #expect(throws: GitError.self) { try ws.isDirty(in: wt) }
        #expect(throws: GitError.self) { try ws.commitAll(in: wt, message: "x") }
        #expect(throws: GitError.self) { try ws.addWorktree(key: "K-2") }
        #expect(throws: GitError.self) { try ws.addRunWorktree(runId: "r1", commit: main) }
        #expect(throws: GitError.self) { try ws.resetHard(in: wt, to: main) }
        #expect(throws: GitError.self) { try ws.planBarrier(key: "K-1", in: wt) }
        #expect(throws: GitError.self) { try ws.diff(base: main, head: main) }
        #expect(throws: GitError.self) { try ws.head(of: GitWorkspace.mainRef) }
        #expect(!exists(smudge), "a smudge filter from the repository config ran"); #expect(!exists(clean), "a clean filter ran")
        #expect(!exists(f.ws.worktreePath(key: "K-2")))
        let refusals = log.all.count
        #expect(refusals >= 8, "every operation was refused and reported")
        #expect(log.all.allSatisfy { $0.contains("filter.evil.smudge") && $0.contains("filter.evil.clean") })
        #expect(try f.git(["rev-parse", "refs/heads/item/K-1"]) == main, "nothing was committed")
        // Once the definition is gone the engine works again, and the committed attributes still name no filter for it.
        try f.git(["config", "--remove-section", "filter.evil"])
        #expect(try ws.isDirty(in: wt))
        #expect(try ws.commitAll(in: wt, message: "work") != nil)
        #expect(log.all.count == refusals)
    }

    @Test func onlyAllowlistedRepoConfigIsAccepted() throws {
        let keys: [(String, String)] = [
            ("filter.x.smudge", "cat"), ("filter.x.process", "x"), ("filter.x.required", "true"), ("diff.x.textconv", "cat"),
            ("diff.x.command", "x"), ("merge.x.driver", "x"), ("core.hooksPath", "/tmp/hooks"), ("core.sshCommand", "ssh -v"),
            ("core.fsmonitor", "/tmp/fsm"), ("include.path", "/tmp/included"), ("includeIf.gitdir:/tmp/.path", "/tmp/included"),
            ("gpg.program", "/tmp/gpg"), ("core.askPass", "/tmp/askpass"), ("submodule.recurse", "true"),
            ("credential.helper", "/tmp/helper"), ("remote.origin.url", "https://example.com/x.git"), ("diff.renames", "true"),
            ("merge.conflictStyle", "diff3"), ("core.autocrlf", "false"), ("alias.st", "!touch /tmp/x"), ("http.proxy", "x"),
            ("core.editor", "x"), ("uploadpack.packObjectsHook", "x"), ("submodule.sub.update", "!touch /tmp/x"),
            ("extensions.refStorage", "reftable"), ("extensions.partialClone", "origin"), ("gc.recentObjectsHook", "/tmp/x"),
            ("sequence.editor", "x"),
        ]
        for (key, value) in keys {
            let f = try GitFixture(files: ["a.txt": "one"])
            let (ws, log) = guarded(f)
            try f.git(["config", key, value])
            #expect(throws: GitError.self, "\(key)") { try ws.isDirty(in: f.root) }
            #expect(log.all.count == 1, "\(key)")
            #expect(log.all.first?.lowercased().contains(key.lowercased()) == true, "\(key): \(log.all)")
        }
        // What git and the engine write, and inert settings, are accepted.
        let f = try GitFixture(files: ["a.txt": "one"])
        let (ws, log) = guarded(f)
        for (key, value) in [("core.symlinks", "true"), ("core.worktree", f.root.path), ("extensions.worktreeConfig", "true"),
                             ("user.name", "Owner"), ("user.email", "o@example.com"), ("branch.main.remote", "."),
                             ("branch.main.merge", "refs/heads/main"), ("gc.auto", "0"), ("gc.refs/heads/*.reflogExpire", "never"),
                             ("pack.threads", "1"), ("index.version", "4"), ("init.defaultBranch", "main"), ("worktree.guessRemote", "false")] {
            try f.git(["config", key, value])
        }
        #expect(try ws.isDirty(in: f.root) == false)
        #expect(log.all.isEmpty, "\(log.all)")
    }

    /// Runs git as given (argv from `/usr/bin/env`), with this environment and stdin; returns stdout.
    @discardableResult
    private func rawGit(_ argv: [String], env: [String: String], stdin: String = "", in dir: URL) throws -> String {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = argv
        p.environment = env
        p.currentDirectoryURL = dir
        let input = Pipe(), out = Pipe()
        p.standardInput = input; p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try p.run()
        input.fileHandleForWriting.write(Data(stdin.utf8)); try input.fileHandleForWriting.close()
        let data = out.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return String(decoding: data, as: UTF8.self)
    }

    /// A shared sentinel script hard-linked at `<dir>/<name>.sh`; it touches `<dir>/<name>.sh-ran` when it runs.
    private func sentinelScript(_ dir: URL, _ name: String) throws -> (script: URL, marker: URL) {
        let script = dir.appending(path: "\(name).sh")
        try FakeTools.install(at: script, "touch \"$0-ran\"\nexit 1")
        return (script, URL(fileURLWithPath: script.path + "-ran"))
    }

    @Test func execOverridesHoldWithoutTheScan() throws {
        let f = try GitFixture(files: ["a.txt": "one\n"])
        let dir = try tempDir()
        let gpg = try sentinelScript(dir, "gpg"), askpass = try sentinelScript(dir, "askpass"), helper = try sentinelScript(dir, "helper")
        try f.git(["config", "gpg.program", gpg.script.path])
        try f.git(["config", "log.showSignature", "true"])
        try f.git(["config", "core.askPass", askpass.script.path])
        try f.git(["config", "credential.helper", helper.script.path])
        // A commit carrying a signature, so showing it asks gpg.
        let tree = try f.git(["rev-parse", "HEAD^{tree}"]), parent = try f.git(["rev-parse", "HEAD"])
        let raw = dir.appending(path: "signed")
        try "tree \(tree)\nparent \(parent)\nauthor A <a@b> 0 +0000\ncommitter A <a@b> 0 +0000\ngpgsig -----BEGIN PGP SIGNATURE-----\n \n iQEz\n -----END PGP SIGNATURE-----\n\nsigned\n"
            .write(to: raw, atomically: true, encoding: .utf8)
        let signed = try f.git(["hash-object", "-t", "commit", "-w", raw.path])
        var git = GitCommand(gitDir: f.root.appending(path: ".git"), workTree: f.root, commonDir: nil)
        git.skipsRepositoryCheck = true
        try git.run(["log", "-1", signed])
        try git.run(["show", "--no-patch", signed])
        #expect(throws: GitError.self, "the scan, the first layer, refuses this repository") { try f.ws.log(base: parent, head: signed) }
        let env = git.environment()
        let fill = "protocol=https\nhost=example.com\n\n"
        try rawGit(git.arguments(["credential", "fill"], attrSource: nil), env: env, stdin: fill, in: f.root)
        #expect(!exists(gpg.marker), "gpg.program ran"); #expect(!exists(askpass.marker), "core.askPass ran")
        #expect(!exists(helper.marker), "credential.helper ran")
        // The same repository with plain git runs every one of them: the fixture is real.
        let plain = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin", "HOME": dir.path,
                     "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
        try rawGit(["git", "log", "-1", signed], env: plain, in: f.root)
        try rawGit(["git", "credential", "fill"], env: plain, stdin: fill, in: f.root)
        #expect(exists(gpg.marker)); #expect(exists(helper.marker)); #expect(exists(askpass.marker))
    }

    @Test func sshAndOtherProtocolsNeverRun() throws {
        let f = try GitFixture(files: ["a.txt": "one\n"])
        let dir = try tempDir()
        let ssh = try sentinelScript(dir, "ssh")
        try f.git(["config", "core.sshCommand", ssh.script.path])
        var git = GitCommand(gitDir: f.root.appending(path: ".git"), workTree: f.root, commonDir: nil)
        git.skipsRepositoryCheck = true
        _ = try git.run(["fetch", "ssh://example.invalid/x.git"], allowFailure: true)
        _ = try git.run(["ls-remote", "ext::\(ssh.script.path)"], allowFailure: true)
        #expect(!exists(ssh.marker))
        let plain = ["PATH": ProcessInfo.processInfo.environment["PATH"] ?? "/usr/bin:/bin", "HOME": dir.path,
                     "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"]
        try rawGit(["git", "fetch", "ssh://example.invalid/x.git"], env: plain, in: f.root)
        #expect(exists(ssh.marker), "the fixture is real")
    }

    @Test func submoduleRecursionNeverRunsTheSubmodulesFilters() throws {
        let f = try GitFixture(files: ["a.txt": "one\n"])
        let wt = try f.ws.addWorktree(key: "K-1")
        let dir = try tempDir()
        let clean = dir.appending(path: "clean-ran")
        // An agent puts a repository of its own inside the worktree, with a filter that its own attributes name.
        let sub = wt.appending(path: "sub")
        try FileManager.default.createDirectory(at: sub, withIntermediateDirectories: true)
        try GitFixture.plainGit(["init", "-q"], in: sub)
        try f.write("f", "one\n", in: sub)
        try GitFixture.plainGit(["add", "f"], in: sub)
        try GitFixture.plainGit(["commit", "-q", "-m", "s"], in: sub)
        try GitFixture.plainGit(["config", "filter.evil.clean", "touch '\(clean.path)'; cat"], in: sub)
        try f.write(".git/info/attributes", "* filter=evil\n", in: sub)
        #expect(try f.ws.commitAll(in: wt, message: "with a nested repository") != nil)
        // Same-size contents: git has to hash the file (through its filter) to see the change.
        for word in ["two", "six"] {
            try f.write("f", "\(word)\n", in: sub)
            _ = try f.ws.isDirty(in: wt)
            _ = try f.ws.commitAll(in: wt, message: "again \(word)")
            let before = try f.ws.planBarrier(key: "K-1", in: wt)
            _ = try f.ws.enforcePlanBarrier(before, key: "K-1", in: wt)
        }
        #expect(!exists(clean), "a filter of the nested repository ran inside an engine call")
        try f.write("f", "ten\n", in: sub)
        try f.git(["status", "--porcelain"], in: wt)
        #expect(exists(clean), "plain git status runs it: the fixture is real")
    }

    @Test func submoduleRecurseFromRepoConfigIsRefusedAndOverridden() throws {
        let f = try GitFixture(files: ["a.txt": "one\n"])
        let (ws, log) = guarded(f)
        let dir = try tempDir()
        let smudge = dir.appending(path: "smudge-ran")
        let source = dir.appending(path: "subsrc", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: source, withIntermediateDirectories: true)
        try GitFixture.plainGit(["init", "-q"], in: source)
        try f.write("f", "one\n", in: source); try GitFixture.plainGit(["add", "f"], in: source)
        try GitFixture.plainGit(["commit", "-q", "-m", "s1"], in: source)
        let s1 = try GitFixture.plainGit(["rev-parse", "HEAD"], in: source)
        try f.write("f", "two\n", in: source); try GitFixture.plainGit(["commit", "-q", "-am", "s2"], in: source)
        try f.git(["-c", "protocol.file.allow=always", "submodule", "add", "-q", source.path, "sub"])
        try f.git(["commit", "-q", "-m", "with a submodule"])
        let recorded = try f.git(["rev-parse", "HEAD"])
        // The submodule's own repository gets a smudge filter its own attributes name, and is moved off the recorded commit.
        let modules = f.root.appending(path: ".git/modules/sub")
        try GitFixture.plainGit(["checkout", "-q", s1], in: f.root.appending(path: "sub"))
        try GitFixture.plainGit(["config", "filter.evil.smudge", "touch '\(smudge.path)'; cat"], in: f.root.appending(path: "sub"))
        try f.write("info/attributes", "* filter=evil\n", in: modules)
        try f.git(["config", "submodule.recurse", "true"])
        #expect(throws: GitError.self) { try ws.resetHard(in: f.root, to: recorded) }
        #expect(log.all.first?.contains("submodule.recurse") == true, "\(log.all)")
        // Without the scan the forced settings keep git out of the submodule.
        var git = GitCommand(gitDir: f.root.appending(path: ".git"), workTree: f.root, commonDir: nil)
        git.skipsRepositoryCheck = true
        try git.run(["reset", "--hard", "--quiet", recorded])
        try git.run(["read-tree", "--reset", "-u", recorded])
        #expect(!exists(smudge), "git recursed into the submodule and ran its filter")
        try f.git(["reset", "--hard", "--quiet", recorded])
        #expect(exists(smudge), "plain git recurses and runs it: the fixture is real")
    }

    @Test func configIsScannedAgainBeforeARetry() throws {
        let f = try GitFixture(files: ["a.txt": "one"])
        let (ws, log) = guarded(f)
        try f.write("b.txt", "two")
        let lock = f.root.appending(path: ".git/index.lock")
        try Data().write(to: lock)
        let config = f.root.appending(path: ".git/config")
        let current = try String(contentsOf: config, encoding: .utf8)
        // One git call whose first attempt meets the lock: between the attempts (the hook) the config gains a filter and the
        // lock goes; the retry is scanned again and refused.
        var git = GitCommand(gitDir: f.root.appending(path: ".git"), workTree: f.root, commonDir: nil, onRefused: { log.add($0) })
        git.beforeRetry = { _ in
            try? (current + "[filter \"evil\"]\n\tclean = cat\n").write(to: config, atomically: true, encoding: .utf8)
            try? FileManager.default.removeItem(at: lock)
        }
        let error = try #require(throws: GitError.self) { try git.run(["add", "-A"]) }
        #expect(error.isRepositoryRefusal, "\(error)")
        #expect(log.all.count == 1)
        _ = ws
    }

    @Test func redirectedCommonDirIsRefusedAndNeverRead() throws {
        let f = try GitFixture(files: ["a.txt": "one\n"])
        try attributed(f)
        let (ws, log) = guarded(f)
        let main = try f.git(["rev-parse", "refs/heads/main"])
        // Another repository with filters, named as the workspace's common dir.
        let dir = try tempDir()
        let evil = dir.appending(path: "evil", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: evil, withIntermediateDirectories: true)
        try GitFixture.plainGit(["clone", "-q", "--bare", f.root.path, evil.appending(path: ".git").path], in: dir)
        let clean = dir.appending(path: "clean-ran"), smudge = dir.appending(path: "smudge-ran"), textconv = dir.appending(path: "textconv-ran")
        let evilConfig = "[filter \"evil\"]\n\tclean = touch '\(clean.path)'; cat\n\tsmudge = touch '\(smudge.path)'; cat\n"
            + "[diff \"evil\"]\n\ttextconv = touch '\(textconv.path)'; cat\n"
        let config = evil.appending(path: ".git/config")
        try (try String(contentsOf: config, encoding: .utf8) + evilConfig).write(to: config, atomically: true, encoding: .utf8)
        try f.write("info/attributes", "* filter=evil diff=evil\n", in: evil.appending(path: ".git"))
        try "\(evil.appending(path: ".git").path)\n".write(to: f.root.appending(path: ".git/commondir"), atomically: true, encoding: .utf8)
        try f.write("a.txt", "six\n")
        #expect(throws: GitError.self) { try ws.isDirty(in: f.root) }
        #expect(throws: GitError.self) { try ws.addWorktree(key: "K-1") }
        #expect(throws: GitError.self) { try ws.addRunWorktree(runId: "r1", commit: main) }
        #expect(!log.all.isEmpty && log.all.allSatisfy { $0.contains("commondir") }, "\(log.all)")
        // Without the scan the pinned common dir keeps git in the workspace's own repository.
        var git = GitCommand(gitDir: f.root.appending(path: ".git"), workTree: f.root, commonDir: nil)
        git.skipsRepositoryCheck = true
        try git.run(["status", "--porcelain"])
        try git.run(["add", "-A"])
        try git.run(["diff", "--no-ext-diff", "HEAD~1", "HEAD"])
        try git.run(["worktree", "add", "--quiet", "--detach", dir.appending(path: "check").path, main])
        #expect(!exists(clean)); #expect(!exists(smudge)); #expect(!exists(textconv))
        // Plain git follows the file and runs the other repository's filters: the fixture is real.
        try f.write("a.txt", "ten\n")
        try f.git(["add", "-A"])
        try f.git(["diff", "--cached"])
        #expect(exists(clean)); #expect(exists(textconv))
    }

    @Test func linkedGitDirectoryIsRefused() throws {
        let f = try GitFixture(files: ["a.txt": "one"])
        let (ws, log) = guarded(f)
        let elsewhere = try tempDir().appending(path: "real.git")
        try FileManager.default.moveItem(at: f.root.appending(path: ".git"), to: elsewhere)
        try FileManager.default.createSymbolicLink(at: f.root.appending(path: ".git"), withDestinationURL: elsewhere)
        #expect(throws: GitError.self) { try ws.isDirty(in: f.root) }
        #expect(log.all.count == 1 && log.all[0].contains("is not a real directory"), "\(log.all)")
    }

    @Test func worktreeConfigIsCheckedToo() throws {
        let f = try GitFixture(files: ["a.txt": "one"])
        let (ws, log) = guarded(f)
        let wt = try ws.addWorktree(key: "K-1")
        try f.write(".git/worktrees/K-1/config.worktree", "[filter \"evil\"]\n\tclean = touch /tmp/never\n")
        #expect(throws: GitError.self) { try ws.isDirty(in: wt) }
        try FileManager.default.removeItem(at: f.root.appending(path: ".git/worktrees/K-1/config.worktree"))
        try f.write(".git/config.worktree", "[diff \"evil\"]\n\ttextconv = touch /tmp/never\n")
        #expect(throws: GitError.self) { try ws.isDirty(in: f.root) }
        #expect(log.all.count == 2)
        #expect(log.all[0].contains("config.worktree") && log.all[0].contains("filter.evil.clean"))
        #expect(log.all[1].contains("diff.evil.textconv"))
        // A config that git cannot parse is refused, not skipped.
        try FileManager.default.removeItem(at: f.root.appending(path: ".git/config.worktree"))
        try f.write(".git/config.worktree", "[filter \"evil\"\n\tclean = x\n")
        #expect(throws: GitError.self) { try ws.isDirty(in: f.root) }
        #expect(log.all.count == 3)
    }

    @Test func includedConfigIsRefusedAndRaisesTheAlert() throws {
        let f = try GitFixture(files: ["a.txt": "one\n"])
        try attributed(f)
        let (ws, log) = guarded(f)
        let dir = try tempDir()
        let marker = dir.appending(path: "included-ran")
        let included = dir.appending(path: "evil.config")
        try "[filter \"evil\"]\n\tclean = touch '\(marker.path)'; cat\n\tsmudge = touch '\(marker.path)'; cat\n"
            .write(to: included, atomically: true, encoding: .utf8)
        try f.git(["config", "include.path", included.path])
        try f.write("a.txt", "changed\n")
        #expect(throws: GitError.self) { try ws.isDirty(in: f.root) }
        #expect(throws: GitError.self) { try ws.addWorktree(key: "K-1") }
        #expect(!exists(marker), "the included filter ran")
        #expect(log.all.count == 2 && log.all.allSatisfy { $0.contains("include.path") })
    }

    @Test func driversDoNotRunEvenWithoutTheConfigCheck() throws {
        // The second layer: the empty-tree attribute source alone keeps a committed `.gitattributes` from naming a driver.
        let f = try GitFixture(files: ["a.txt": "one\n"])
        try attributed(f)
        let base = try f.git(["rev-parse", "HEAD"])
        try f.git(["checkout", "-q", "-b", "side"])
        try f.write("a.txt", "side\n"); try f.git(["commit", "-q", "-am", "side"])
        try f.git(["checkout", "-q", "main"])
        try f.write("a.txt", "main\n"); try f.git(["commit", "-q", "-am", "main"])
        let dir = try tempDir()
        let smudge = dir.appending(path: "smudged"), clean = dir.appending(path: "cleaned")
        let textconv = dir.appending(path: "textconv"), driver = dir.appending(path: "driver")
        try f.git(["config", "filter.evil.smudge", "touch '\(smudge.path)'; cat"])
        try f.git(["config", "filter.evil.clean", "touch '\(clean.path)'; cat"])
        try f.git(["config", "diff.evil.textconv", "touch '\(textconv.path)'; cat"])
        try f.git(["config", "merge.evil.driver", "touch '\(driver.path)'; exit 1"])
        // Without the engine's info/attributes: the attribute source is all that stands in the way.
        try? FileManager.default.removeItem(at: f.root.appending(path: ".git/info/attributes"))
        var git = GitCommand(gitDir: f.root.appending(path: ".git"), workTree: f.root, commonDir: nil)
        git.skipsRepositoryCheck = true
        // `--no-ext-diff` as the engine always passes; textconv is left on.
        try git.run(["diff", "--no-ext-diff", base, "main"])
        try git.run(["log", "-p", "--no-ext-diff", "-2", "main"])
        _ = try git.run(["merge-tree", "--write-tree", "main", "side"], allowFailure: true)
        try f.write("a.txt", "dirty\n")
        try git.run(["add", "-A"])
        try git.run(["worktree", "add", "--quiet", "--detach", dir.appending(path: "check").path, "side"])
        #expect(!exists(smudge)); #expect(!exists(clean)); #expect(!exists(textconv)); #expect(!exists(driver))
        #expect(try String(contentsOf: dir.appending(path: "check/a.txt"), encoding: .utf8) == "side\n")
        // The info/attributes override alone does the same for plain git (the agent's own commands included).
        try GitCommand.attributesOverride.write(to: f.root.appending(path: ".git/info/attributes"), atomically: true, encoding: .utf8)
        try f.git(["diff", base, "main"])
        _ = try f.git(["merge-tree", "--write-tree", "main", "side"], allowFailure: true)
        try f.write("a.txt", "dirty again\n"); try f.git(["add", "-A"])
        #expect(!exists(smudge)); #expect(!exists(clean)); #expect(!exists(textconv)); #expect(!exists(driver))
        // Without either, the same repository runs every one of them: the fixture is real.
        try FileManager.default.removeItem(at: f.root.appending(path: ".git/info/attributes"))
        try f.git(["diff", base, "main"])
        _ = try f.git(["merge-tree", "--write-tree", "main", "side"], allowFailure: true)
        try f.write("a.txt", "dirty once more\n"); try f.git(["add", "-A"])
        try f.git(["worktree", "add", "--quiet", "--detach", dir.appending(path: "plain").path, "side"])
        #expect(exists(textconv)); #expect(exists(driver)); #expect(exists(clean)); #expect(exists(smudge))
    }

    @Test func replaceObjectsNeverStandInForTheVerifiedCommit() throws {
        let f = try GitFixture(files: ["a.txt": "one\n"])
        let base = try #require(try f.ws.head(of: GitWorkspace.mainRef))
        let wt = try f.ws.addWorktree(key: "K-1")
        try f.write("a.txt", "reviewed\n", in: wt)
        let verified = try #require(try f.ws.commitAll(in: wt, message: "reviewed work"))
        // The agent builds another commit and tells git to hand it out wherever the verified one is asked for.
        let evil = try f.plantCommit(parent: base, path: "a.txt", text: "evil payload\n", message: "evil work")
        try f.git(["replace", verified, evil])
        #expect(try f.git(["show", "\(verified):a.txt"]) == "evil payload", "plain git follows the replacement")
        let ws = f.ws
        #expect(try ws.diff(base: base, head: verified).text.contains("+reviewed"))
        #expect(!(try ws.diff(base: base, head: verified).text.contains("evil")))
        #expect(try ws.nameStatus(base: base, head: verified).entries == [GitChange(status: "M", path: "a.txt")])
        #expect(try ws.log(base: base, head: verified).map { $0.split(separator: " ", maxSplits: 1).last.map(String.init) } == ["reviewed work"])
        #expect(try ws.blobs(at: verified, paths: ["a.txt"], limit: 5) == ["a.txt": Data("reviewed\n".utf8)])
        let check = try ws.addRunWorktree(runId: "r1", commit: verified)
        #expect(try String(contentsOf: check.appending(path: "a.txt"), encoding: .utf8) == "reviewed\n", "the check runs the real commit")
        ws.removeRunWorktree(runId: "r1")
        #expect(try ws.headCommit(in: wt) == verified)
        #expect(try ws.isDirty(in: wt) == false, "the worktree is compared with the real tree")
        // Grafts are ignored as well.
        try f.write(".git/info/grafts", "\(verified) \(evil)\n")
        #expect(try ws.log(base: base, head: verified).count == 1)
    }

    @Test func sha256WorkspaceUsesItsOwnEmptyTree() throws {
        let f = try GitFixture(ensure: false)
        try f.git(["init", "-q", "--object-format=sha256", "-b", "main"])
        try f.write("a.txt", "one\n")
        try f.ws.ensureRepo()
        let wt = try f.ws.addWorktree(key: "K-1")
        try f.write("b.txt", "two\n", in: wt)
        let sha = try #require(try f.ws.commitAll(in: wt, message: "work"))
        #expect(sha.count == 64)
        #expect(try f.ws.diff(base: GitWorkspace.mainRef, head: sha).text.contains("+two"))
    }

    // MARK: Merge helpers (9b fix round 1)

    @Test func diffsSplitCRLFLinesAndUseLiteralPathspecs() throws {
        let f = try GitFixture(files: ["a.txt": "one\n"])
        let base = try #require(try f.ws.head(of: GitWorkspace.mainRef))
        try f.write("crlf.txt", (0..<300).map { "line \($0)" }.joined(separator: "\r\n") + "\r\n")
        try f.git(["add", "-A"]); try f.git(["commit", "-qm", "crlf"])
        let head = try #require(try f.ws.head(of: GitWorkspace.mainRef))
        let one = try f.ws.fileDiff(base: base, head: head, path: "crlf.txt", maxLines: 200)
        #expect(one.truncated)
        #expect(one.text.components(separatedBy: "\n").count == 200, "a CRLF line is one line of the cap")
        // The path is literal: a glob names no file.
        #expect(try f.ws.fileDiff(base: base, head: head, path: "*.txt").text.isEmpty)
        let all = try f.ws.diff(base: base, head: head, maxLines: 50)
        #expect(all.truncated); #expect(all.text.components(separatedBy: "\n").count == 50)
    }

    @Test func mergeConflictsThrowsWhenGitCannotTell() throws {
        let f = try GitFixture(files: ["a.txt": "one\n"])
        try f.ws.addWorktree(key: "K-1")
        #expect(try f.ws.mergeConflicts(key: "K-1") == [])
        try f.ws.removeWorktree(key: "K-1", keepIf: { false })
        try f.ws.deleteBranch(key: "K-1")
        // No branch: git fails (status 128), which is "unknown", never "clean".
        #expect(throws: GitError.self) { try f.ws.mergeConflicts(key: "K-1") }
    }

    // MARK: Landing on the locked main (9b fix round 2: R1, R2)

    /// Two items branched from the first commit, each with one commit of its own, and `main` moved on after both.
    private struct Behind {
        let f: GitFixture
        let ws: GitWorkspace
        let mainHead: String
        let k1: String, k2: String

        init(ws make: (URL) -> GitWorkspace = { GitWorkspace(root: $0) }) throws {
            f = try GitFixture(files: ["a.txt": "one\n"])
            ws = make(f.root)
            for key in ["K-1", "K-2"] {
                let wt = try ws.addWorktree(key: key)
                try f.write("\(key).txt", "\(key)\n", in: wt)
                try f.git(["add", "-A"], in: wt); try f.git(["commit", "-qm", key], in: wt)
            }
            k1 = try #require(try ws.head(of: ws.branchRef(key: "K-1")))
            k2 = try #require(try ws.head(of: ws.branchRef(key: "K-2")))
            try f.write("m.txt", "main\n"); try f.git(["add", "-A"]); try f.git(["commit", "-qm", "main moves"])
            mainHead = try #require(try ws.head(of: GitWorkspace.mainRef))
        }

        /// A commit on top of `main` that nobody reviewed.
        func evil(on parent: String? = nil) throws -> String {
            let tree = try f.git(["rev-parse", "\(parent ?? mainHead)^{tree}"])
            let scratch = try tempDir()
            let file = scratch.appending(path: "evil.txt")
            try "unreviewed\n".write(to: file, atomically: true, encoding: .utf8)
            let blob = try f.git(["hash-object", "-w", file.path])
            let idx = scratch.appending(path: "evil.index").path
            try f.git(["read-tree", tree], env: ["GIT_INDEX_FILE": idx])
            try f.git(["update-index", "--add", "--cacheinfo", "100644,\(blob),evil.txt"], env: ["GIT_INDEX_FILE": idx])
            let evilTree = try f.git(["write-tree"], env: ["GIT_INDEX_FILE": idx])
            return try f.git(["commit-tree", evilTree, "-p", parent ?? mainHead, "-m", "evil"])
        }

        /// The engine's merge repository (its git dir holds the rebase state).
        func mergeAdmin() throws -> URL { ws.mergeRepositoryPath }
    }

    @Test func plantedRebaseStateNeverMovesMain() throws {
        let b = try Behind()
        guard case .rebased = try b.ws.landVerified(key: "K-1", verified: b.k1, expectedMain: b.mainHead, recordPending: { _ in }) else {
            Issue.record("K-1 should have been rebased"); return
        }
        // Rebase state planted in the engine's merge repository: a `rebase --abort` would move main to evil.
        let evil = try b.evil()
        let state = try b.mergeAdmin().appending(path: "rebase-merge", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        for (name, text) in ["head-name": "refs/heads/main", "onto": b.mainHead, "orig-head": evil, "interactive": "", "git-rebase-todo": ""] {
            try (text + "\n").write(to: state.appending(path: name), atomically: true, encoding: .utf8)
        }
        let outcome = try b.ws.landVerified(key: "K-2", verified: b.k2, expectedMain: b.mainHead, recordPending: { _ in })
        #expect(try b.ws.head(of: GitWorkspace.mainRef) == b.mainHead, "main never moves to the planted orig-head")
        guard case .rebased(let r) = outcome else { Issue.record("\(outcome)"); return }
        #expect(try !b.ws.isAncestor(evil, of: r))
        #expect(try b.f.git(["rev-parse", "\(r)^"]) == b.mainHead)
        #expect(!FileManager.default.fileExists(atPath: state.path), "the engine cleared the planted state itself")
    }

    @Test func mainFlippedDuringTheRebaseLandsNothingUnreviewed() throws {
        // main flips to an unreviewed commit while the rebase runs, and back after: the result sits on the locked head.
        let b = try Behind()
        let evil = try b.evil()
        var ws = b.ws
        let (root, head) = (b.f.root, b.mainHead)
        ws.rebaseProbe = { phase in
            _ = try? GitFixture.plainGit(["update-ref", "refs/heads/main", phase == .before ? evil : head], in: root)
        }
        guard case .rebased(let r) = try ws.landVerified(key: "K-1", verified: b.k1, expectedMain: b.mainHead, recordPending: { _ in }) else {
            Issue.record("K-1 should have been rebased"); return
        }
        #expect(try b.f.git(["rev-parse", "\(r)^"]) == b.mainHead)
        #expect(try !b.ws.isAncestor(evil, of: r), "the unreviewed commit is not part of what will be checked and landed")
        #expect(try b.f.git(["ls-tree", "--name-only", r]).split(separator: "\n").contains("evil.txt") == false)
        // main flips and stays flipped: nothing moves, the branch is still the verified commit.
        ws.rebaseProbe = { phase in
            if phase == .before { _ = try? GitFixture.plainGit(["update-ref", "refs/heads/main", evil], in: root) }
        }
        let outcome = try ws.landVerified(key: "K-2", verified: b.k2, expectedMain: b.mainHead, recordPending: { _ in })
        #expect(outcome == .mainMoved(head: evil))
        #expect(try b.ws.head(of: b.ws.branchRef(key: "K-2")) == b.k2)
    }

    @Test func rebaseResultMustMatchTheMergeOfTheVerifiedTree() throws {
        // The merge repository's HEAD is swapped after the rebase for a commit with the same shape but other content.
        let b = try Behind()
        var ws = b.ws
        let repo = b.ws.mergeRepositoryPath
        let head = b.mainHead
        ws.rebaseProbe = { phase in
            guard phase == .after,
                  let evil = try? GitFixture.plainGit(["commit-tree", "\(head)^{tree}", "-p", head, "-m", "evil"], in: repo, env: ["GIT_DIR": repo.path])
            else { return }
            try? (evil + "\n").write(to: repo.appending(path: "HEAD"), atomically: true, encoding: .utf8)
        }
        let error = #expect(throws: GitError.self) {
            try ws.landVerified(key: "K-1", verified: b.k1, expectedMain: b.mainHead, recordPending: { _ in })
        }
        #expect("\(String(describing: error))".contains("does not hold the merge of the verified work"))
        #expect(try b.ws.head(of: GitWorkspace.mainRef) == b.mainHead)
        #expect(try b.ws.head(of: b.ws.branchRef(key: "K-1")) == b.k1, "the branch never moves to a result that is not the merge")
    }

    @Test func mergeRepositoryLivesOutsideTheWorkspace() throws {
        let engine = try tempDir().appending(path: "run/merge/c1", directoryHint: .isDirectory)
        let b = try Behind(ws: { GitWorkspace(root: $0, mergeDirectory: engine) })
        // Checkouts left where agents can write by older engines are retired.
        let legacy = b.f.root.appending(path: ".brahma/wt/.merge", directoryHint: .isDirectory)
        try b.f.git(["worktree", "add", "-q", "--detach", legacy.path, "refs/heads/main"])
        let previous = engine.appending(path: ".merge", directoryHint: .isDirectory)
        try b.f.git(["worktree", "add", "-q", "--detach", previous.path, "refs/heads/main"])
        guard case .rebased(let r) = try b.ws.landVerified(key: "K-1", verified: b.k1, expectedMain: b.mainHead, recordPending: { _ in }) else {
            Issue.record("K-1 should have been rebased"); return
        }
        #expect(b.ws.mergeRepositoryPath.path == engine.path + ".git")
        #expect(b.ws.mergeWorktreePath.path == engine.path + "-wt")
        #expect(!b.ws.mergeRepositoryPath.path.hasPrefix(b.f.root.path))
        #expect(!b.ws.mergeWorktreePath.path.hasPrefix(b.f.root.path))
        #expect(try b.f.git(["rev-parse", "HEAD"], in: b.ws.mergeWorktreePath, env: ["GIT_DIR": b.ws.mergeRepositoryPath.path]) == r)
        #expect(!FileManager.default.fileExists(atPath: legacy.path))
        #expect(!FileManager.default.fileExists(atPath: previous.path))
        #expect(!FileManager.default.fileExists(atPath: b.f.root.appending(path: ".git/worktrees/-merge").path))
        #expect(try b.ws.itemWorktrees().map(\.key).sorted() == ["K-1", "K-2"])
        // A link put in place of the repository or its working tree is not followed.
        try FileManager.default.removeItem(at: b.ws.mergeWorktreePath)
        try FileManager.default.removeItem(at: b.ws.mergeRepositoryPath)
        let elsewhere = try tempDir()
        try FileManager.default.createSymbolicLink(at: b.ws.mergeWorktreePath, withDestinationURL: elsewhere)
        try FileManager.default.createSymbolicLink(at: b.ws.mergeRepositoryPath, withDestinationURL: elsewhere)
        guard case .rebased = try b.ws.landVerified(key: "K-2", verified: b.k2, expectedMain: b.mainHead, recordPending: { _ in }) else {
            Issue.record("K-2 should have been rebased"); return
        }
        #expect(try FileManager.default.contentsOfDirectory(atPath: elsewhere.path).isEmpty)
    }

    // MARK: Merges in an engine-owned repository (9b fix round 3: E1, E2)

    /// `main` and `K-1` each change a different end of `big.txt` (a clean content merge, so any merge driver is asked), with a
    /// `.gitattributes` that routes every file to an `evil` driver. `plantDriver()` defines it in the workspace's config (which
    /// the shared allowlist refuses outright: no git runs there while it stays).
    private struct Driven {
        let f: GitFixture
        let ws: GitWorkspace
        let mainHead: String, k1: String
        let sentinel: URL

        init(ws make: (URL) -> GitWorkspace = { GitWorkspace(root: $0) }) throws {
            let lines = (1...20).map { "line \($0)\n" }.joined()
            f = try GitFixture(files: ["big.txt": lines, ".gitattributes": "* merge=evil\n"])
            ws = make(f.root)
            sentinel = try tempDir().appending(path: "driver-ran")
            let wt = try ws.addWorktree(key: "K-1")
            try f.write("big.txt", lines.replacingOccurrences(of: "line 1\n", with: "line one\n"), in: wt)
            try f.git(["add", "-A"], in: wt); try f.git(["commit", "-qm", "K-1"], in: wt)
            k1 = try #require(try ws.head(of: ws.branchRef(key: "K-1")))
            try f.write("big.txt", lines.replacingOccurrences(of: "line 20\n", with: "line twenty\n"))
            try f.git(["add", "-A"]); try f.git(["commit", "-qm", "main moves"])
            mainHead = try #require(try ws.head(of: GitWorkspace.mainRef))
        }

        func plantDriver() throws { try f.git(["config", "merge.evil.driver", "touch '\(sentinel.path)'; true"]) }
    }

    @Test func evilMergeDriverNeverRuns() throws {
        let d = try Driven()
        // Defined in the workspace's config: the landing is refused before any git runs, as the company's fault.
        try d.plantDriver()
        do {
            let outcome = try d.ws.landVerified(key: "K-1", verified: d.k1, expectedMain: d.mainHead, recordPending: { _ in })
            Issue.record("a workspace with a merge driver in its config was merged: \(outcome)")
        } catch let error {
            #expect(error is MergeInfrastructureError, "\(error)")
            #expect("\(error)".contains("merge.evil.driver"), "\(error)")
        }
        #expect(!FileManager.default.fileExists(atPath: d.sentinel.path), "the workspace's merge driver ran")
        #expect(try d.f.git(["rev-parse", "refs/heads/main"]) == d.mainHead)
        // Without it, the tree's `merge=evil` names a driver nothing defines: the built-in text merge runs.
        try d.f.git(["config", "--unset", "merge.evil.driver"])
        guard case .rebased(let r) = try d.ws.landVerified(key: "K-1", verified: d.k1, expectedMain: d.mainHead, recordPending: { _ in }) else {
            Issue.record("K-1 should have been rebased"); return
        }
        #expect(!FileManager.default.fileExists(atPath: d.sentinel.path), "the workspace's merge driver ran")
        let merged = try d.f.git(["show", "\(r):big.txt"])
        #expect(merged.contains("line one")); #expect(merged.contains("line twenty"))
        #expect(try d.ws.head(of: GitWorkspace.mainRef) == d.mainHead)
    }

    @Test func mergeWorkRunsInTheEngineRepositoryNotTheWorkspace() throws {
        let engine = try tempDir().appending(path: "run/merge/c1", directoryHint: .isDirectory)
        let d = try Driven(ws: { GitWorkspace(root: $0, mergeDirectory: engine) })
        guard case .rebased(let r) = try d.ws.landVerified(key: "K-1", verified: d.k1, expectedMain: d.mainHead, recordPending: { _ in }) else {
            Issue.record("K-1 should have been rebased"); return
        }
        let repo = URL(fileURLWithPath: engine.path + ".git", isDirectory: true)
        let config = try String(contentsOf: repo.appending(path: "config"), encoding: .utf8)
        #expect(config == GitWorkspace.engineConfig, "only keys the shared allowlist takes; hooks, fsmonitor and attributes are forced per call")
        for banned in ["include", "merge \"", "filter \"", "diff \"", "[merge", "[filter", "[diff"] { #expect(!config.contains(banned), "\(banned)") }
        let attributes = try String(contentsOf: repo.appending(path: "info/attributes"), encoding: .utf8)
        #expect(attributes == GitWorkspace.engineAttributes)
        #expect(attributes == "* merge=text -filter -diff -text -eol -ident -export-ignore -export-subst -working-tree-encoding\n")
        #expect(try d.f.git(["rev-parse", "HEAD"], env: ["GIT_DIR": repo.path, "GIT_WORK_TREE": engine.path + "-wt"]) == r)
        // Nothing was written in the workspace but the objects and the result's ref.
        #expect(!FileManager.default.fileExists(atPath: d.f.root.appending(path: ".git/worktrees/-merge").path))
        #expect(!FileManager.default.fileExists(atPath: d.f.root.appending(path: ".git/worktrees/.merge").path))
        #expect(try d.f.git(["rev-parse", "--verify", "\(r)^{commit}"]) == r, "the result object reached the workspace")
    }

    @Test func plantedWorkspaceAdminStateHasNoEffect() throws {
        let b = try Behind()
        // The merge checkout older engines kept in the workspace is swapped for a link to a directory an agent controls, holding
        // a planted rebase with an `exec` step and a HEAD naming an unreviewed commit.
        let outside = try tempDir()
        let sentinel = try tempDir().appending(path: "exec-ran")
        let evil = try b.evil()
        let state = outside.appending(path: "rebase-merge", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: state, withIntermediateDirectories: true)
        for (name, text) in ["head-name": "refs/heads/main", "onto": b.mainHead, "orig-head": evil, "interactive": "",
                             "git-rebase-todo": "exec touch '\(sentinel.path)'"] {
            try (text + "\n").write(to: state.appending(path: name), atomically: true, encoding: .utf8)
        }
        try (evil + "\n").write(to: outside.appending(path: "HEAD"), atomically: true, encoding: .utf8)
        let before = try FileManager.default.contentsOfDirectory(atPath: outside.path).sorted()
        let worktrees = b.f.root.appending(path: ".git/worktrees", directoryHint: .isDirectory)
        try FileManager.default.createSymbolicLink(at: worktrees.appending(path: "-merge"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: worktrees.appending(path: ".merge"), withDestinationURL: outside)
        // A planted rebase state in the workspace repository itself.
        let own = b.f.root.appending(path: ".git/rebase-merge", directoryHint: .isDirectory)
        try FileManager.default.copyItem(at: state, to: own)
        guard case .rebased(let r) = try b.ws.landVerified(key: "K-1", verified: b.k1, expectedMain: b.mainHead, recordPending: { _ in }) else {
            Issue.record("K-1 should have been rebased"); return
        }
        #expect(!FileManager.default.fileExists(atPath: sentinel.path), "the planted exec step ran")
        #expect(try b.ws.head(of: GitWorkspace.mainRef) == b.mainHead)
        #expect(try b.f.git(["rev-parse", "\(r)^"]) == b.mainHead)
        #expect(try !b.ws.isAncestor(evil, of: r))
        #expect(try FileManager.default.contentsOfDirectory(atPath: outside.path).sorted() == before, "a link was followed")
    }

    @Test func replaceRefAfterApprovalLandsNothingUnreviewed() throws {
        let b = try Behind()
        let evilFast = try b.evil(on: b.mainHead)
        // K-1 is rebased (its verified commit is replaced by an unreviewed one that has the same parent).
        try b.f.git(["replace", b.k1, try b.evil(on: try b.f.git(["rev-parse", "\(b.k1)^"]))])
        guard case .rebased(let r) = try b.ws.landVerified(key: "K-1", verified: b.k1, expectedMain: b.mainHead, recordPending: { _ in }) else {
            Issue.record("K-1 should have been rebased"); return
        }
        #expect(try b.f.git(["--no-replace-objects", "ls-tree", "-r", "--name-only", r]).split(separator: "\n").contains("evil.txt") == false)
        #expect(try b.f.git(["--no-replace-objects", "ls-tree", "-r", "--name-only", r]).split(separator: "\n").contains("K-1.txt"))
        // A fast-forward: the replaced commit's tree is not what lands in the checkout.
        let g = try Behind()
        let verified = try g.f.git(["rev-parse", "refs/heads/item/K-1"])
        try g.f.git(["reset", "-q", "--hard"]); try g.f.git(["update-ref", "refs/heads/main", try g.f.git(["rev-parse", "\(verified)^"])])
        try g.f.git(["reset", "-q", "--hard"])
        let base = try g.f.git(["rev-parse", "refs/heads/main"])
        try g.f.git(["replace", verified, try g.evil(on: base)])
        guard case .fastForwarded(let head) = try g.ws.landVerified(key: "K-1", verified: verified, expectedMain: base, recordPending: { _ in }) else {
            Issue.record("K-1 should have fast-forwarded"); return
        }
        #expect(head == verified)
        #expect(!FileManager.default.fileExists(atPath: g.f.root.appending(path: "evil.txt").path), "the replacement's tree was checked out")
        #expect(FileManager.default.fileExists(atPath: g.f.root.appending(path: "K-1.txt").path))
        _ = evilFast
    }

    @Test func engineRepositoryFailureIsTheCompanysFaultAndTheItemsIsNot() throws {
        // The place the engine keeps its merge repository cannot be made: the company's fault.
        let blocked = try tempDir()
        let file = blocked.appending(path: "merge")
        try "not a directory".write(to: file, atomically: true, encoding: .utf8)
        let b = try Behind(ws: { GitWorkspace(root: $0, mergeDirectory: file.appending(path: "c1", directoryHint: .isDirectory)) })
        #expect(throws: MergeInfrastructureError.self) {
            try b.ws.landVerified(key: "K-1", verified: b.k1, expectedMain: b.mainHead, recordPending: { _ in })
        }
        // A verified commit git cannot hand over (one of its blobs is gone): the item's fault, never the company's.
        let c = try Behind()
        let blob = try c.f.git(["rev-parse", "\(c.k1):K-1.txt"])
        let loose = c.f.root.appending(path: ".git/objects/\(blob.prefix(2))/\(blob.dropFirst(2))")
        try #require(FileManager.default.fileExists(atPath: loose.path))
        try FileManager.default.removeItem(at: loose)
        do {
            _ = try c.ws.landVerified(key: "K-1", verified: c.k1, expectedMain: c.mainHead, recordPending: { _ in })
            Issue.record("a commit with a missing blob should not land")
        } catch let error {
            #expect(!(error is MergeInfrastructureError), "\(error)")
            #expect(error is GitError, "\(error)")
        }
        // A branch with no history in common with main is the item's too.
        let d = try Behind()
        let orphan = try d.f.git(["commit-tree", "\(d.mainHead)^{tree}", "-m", "orphan"])
        try d.f.git(["update-ref", "refs/heads/item/K-9", orphan])
        do {
            _ = try d.ws.landVerified(key: "K-9", verified: orphan, expectedMain: d.mainHead, recordPending: { _ in })
            Issue.record("an unrelated branch should not land")
        } catch let error {
            #expect(!(error is MergeInfrastructureError), "\(error)")
        }
    }

    // MARK: 9b fix round 4 (X2, X3 and the round-3 re-review)

    /// A loose object at `oid`'s path in `repo` whose content is `text` (so its name lies about it).
    private func forge(_ oid: String, as text: String, in repo: URL) throws {
        let scratch = try GitFixture(files: [:], ensure: false)
        try GitFixture.plainGit(["init", "-q"], in: scratch.root)
        let file = try scratch.write("forged.txt", text)
        let real = try scratch.git(["hash-object", "-w", file.path])
        let dir = repo.appending(path: "objects/\(oid.prefix(2))", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let target = dir.appending(path: String(oid.dropFirst(2)))
        if FileManager.default.fileExists(atPath: target.path) { try FileManager.default.removeItem(at: target) }
        try FileManager.default.copyItem(at: scratch.root.appending(path: ".git/objects/\(real.prefix(2))/\(real.dropFirst(2))"), to: target)
    }

    /// Every regular file and link under `dir`, with its contents (a link: its target).
    private func snapshot(_ dir: URL) -> [String: Data] {
        var out: [String: Data] = [:]
        let fm = FileManager.default
        guard let walk = fm.enumerator(atPath: dir.path) else { return out }
        for case let rel as String in walk {
            let path = dir.appending(path: rel).path
            if let target = try? fm.destinationOfSymbolicLink(atPath: path) { out[rel] = Data(("-> " + target).utf8); continue }
            var isDir: ObjCBool = false
            if fm.fileExists(atPath: path, isDirectory: &isDir), !isDir.boolValue { out[rel] = fm.contents(atPath: path) ?? Data() }
        }
        return out
    }

    @Test func mergeCheckRunsOnAGitFreeExport() throws {
        let home = try tempDir()
        let engine = home.appending(path: "run/merge/c1", directoryHint: .isDirectory)
        let d = try Driven(ws: { GitWorkspace(root: $0, mergeDirectory: engine, exportHome: home) })
        // The tree routes every file through a smudge filter the workspace defines, hides a file from exports and asks for a
        // substitution: none of it may change what the check sees.
        // (A filter the workspace's config defines refuses the workspace outright: `repoFilterIsRefusedAndNeverRuns`.)
        let smudged = try tempDir().appending(path: "smudge-ran")
        try d.f.write(".gitattributes", "* merge=evil filter=evil\nhidden.txt export-ignore\nsubst.txt export-subst\n")
        try d.f.write("hidden.txt", "the test the export must not hide\n")
        try d.f.write("subst.txt", "$Format:%H$\n")
        try d.f.git(["add", "-A"]); try d.f.git(["commit", "-qm", "attrs"])
        let commit = try #require(try d.ws.head(of: GitWorkspace.mainRef))
        let dir = try d.ws.addEngineExport(runId: "run-1", commit: commit)
        #expect(dir.path == home.appending(path: "run/exports/run-1").path, "the check runs under the data home, not in the workspace")
        #expect(!FileManager.default.fileExists(atPath: dir.appending(path: ".git").path), "the export has no .git")
        #expect(try String(contentsOf: dir.appending(path: "big.txt"), encoding: .utf8).contains("line twenty"))
        #expect(try String(contentsOf: dir.appending(path: "hidden.txt"), encoding: .utf8) == "the test the export must not hide\n")
        #expect(try String(contentsOf: dir.appending(path: "subst.txt"), encoding: .utf8) == "$Format:%H$\n")
        #expect(!FileManager.default.fileExists(atPath: smudged.path), "the workspace's filter ran")
        let repo = d.ws.mergeRepositoryPath
        #expect(!FileManager.default.fileExists(atPath: repo.appending(path: "worktrees").path), "no worktree is linked to the engine repository")
        // The check writes next to its directory and into whatever repository git finds from there.
        let before = snapshot(repo)
        #expect(!before.isEmpty)
        let script = """
            echo escaped > ../escaped.txt
            git rev-parse --absolute-git-dir > ../found.txt 2>&1
            cat .git >> ../found.txt 2>&1
            git config merge.evil.driver 'touch planted' 2>/dev/null
            echo planted > planted.txt; git hash-object -w planted.txt 2>/dev/null
            git update-ref refs/heads/planted HEAD 2>/dev/null
            true
            """
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", script]
        p.currentDirectoryURL = dir
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        for k in ["GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_INDEX_FILE"] { env[k] = nil }
        p.environment = env
        p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
        try p.run(); p.waitUntilExit()
        #expect(FileManager.default.fileExists(atPath: dir.deletingLastPathComponent().appending(path: "escaped.txt").path), "the script ran")
        let found = (try? String(contentsOf: dir.deletingLastPathComponent().appending(path: "found.txt"), encoding: .utf8)) ?? ""
        #expect(!found.contains(repo.path), "the check found the engine repository: \(found)")
        #expect(snapshot(repo) == before, "the check changed the engine repository's config or objects")
        d.ws.removeRunWorktree(runId: "run-1")
        #expect(!FileManager.default.fileExists(atPath: dir.path))
    }

    @Test func staleWorkspaceLocksAreRemovedAndReported() throws {
        let b = try Behind()
        // main goes back to K-1's parent, so K-1 fast-forwards it.
        let verified = try b.f.git(["rev-parse", "refs/heads/item/K-1"])
        try b.f.git(["update-ref", "refs/heads/main", try b.f.git(["rev-parse", "\(verified)^"])])
        try b.f.git(["reset", "-q", "--hard"])
        let base = try b.f.git(["rev-parse", "refs/heads/main"])
        // A lock somebody may be using right now is left alone: the move fails as the company's fault.
        let lock = b.f.root.appending(path: ".git/refs/heads/main.lock")
        try "".write(to: lock, atomically: true, encoding: .utf8)
        var reported: [[String]] = []
        #expect(throws: MergeInfrastructureError.self) {
            try b.ws.landVerified(key: "K-1", verified: verified, expectedMain: base, recordPending: { _ in }, tamper: { reported.append($0) })
        }
        #expect(reported.isEmpty); #expect(FileManager.default.fileExists(atPath: lock.path))
        // Left behind (untouched for an hour): removed, reported, and the merge goes through.
        let old = Date().addingTimeInterval(-3600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: lock.path)
        let branchLock = b.f.root.appending(path: ".git/refs/heads/item/K-1.lock")
        try "".write(to: branchLock, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: branchLock.path)
        let outcome = try b.ws.landVerified(key: "K-1", verified: verified, expectedMain: base, recordPending: { _ in }, tamper: { reported.append($0) })
        #expect(outcome == .fastForwarded(mainHead: verified))
        #expect(reported.count == 1 && Set(reported.first ?? []) == ["refs/heads/main.lock", "refs/heads/item/K-1.lock"], "\(reported)")
        #expect(!FileManager.default.fileExists(atPath: lock.path)); #expect(!FileManager.default.fileExists(atPath: branchLock.path))
    }

    /// H1: the merge queue's self-heal works on descriptors only. A directory its lock walk is about to enter, or `info` right
    /// before `info/grafts` goes, is swapped for a link to an outside directory: nothing there is removed.
    @Test func selfHealNeverFollowsADirectorySwappedForALink() throws {
        let fm = FileManager.default
        let old = Date().addingTimeInterval(-3600)
        for (trigger, swapped) in [("scratch/sub", "scratch/sub"), ("info/grafts", "info")] {
            let outside = try tempDir()
            for name in ["victim.lock", "grafts", "keep.txt"] {
                let url = outside.appending(path: name)
                try "outside\n".write(to: url, atomically: true, encoding: .utf8)
                try fm.setAttributes([.modificationDate: old], ofItemAtPath: url.path)
            }
            let before = try tree(outside)
            let swaps = TamperLog()
            let b = try Behind(ws: { root in
                var ws = GitWorkspace(root: root)
                ws.healProbe = { stage in
                    guard stage == trigger, swaps.all.isEmpty else { return }
                    let dir = root.appending(path: ".git/\(swapped)")
                    try? FileManager.default.moveItem(at: dir, to: URL(fileURLWithPath: dir.path + "-moved"))
                    try? FileManager.default.createSymbolicLink(at: dir, withDestinationURL: outside)
                    swaps.add(stage)
                }
                return ws
            })
            // A real stale lock where the walk goes, and a planted `info/grafts`, so the heal has something to remove there.
            let inner = b.f.root.appending(path: ".git/scratch/sub/inner.lock")
            try fm.createDirectory(at: inner.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "".write(to: inner, atomically: true, encoding: .utf8)
            try fm.setAttributes([.modificationDate: old], ofItemAtPath: inner.path)
            try "\(b.k1)\n".write(to: b.f.root.appending(path: ".git/info/grafts"), atomically: true, encoding: .utf8)
            _ = try? b.ws.landVerified(key: "K-1", verified: b.k1, expectedMain: b.mainHead, recordPending: { _ in })
            #expect(swaps.all == [trigger], "\(trigger): the probe ran")
            #expect(try tree(outside) == before, "\(trigger): the self-heal removed a file outside the git dir through a link")
        }
    }

    /// N4: a workspace config refused at a landing's fetch is the company's fault at once: main's history is not bundled from
    /// the previous engine repository (nothing there is touched) and nothing is reported as restored.
    @Test func aRefusedConfigAtTheLandingFetchRestoresNothing() throws {
        let home = try tempDir()
        let planted = TamperLog()
        let b = try Behind(ws: { root in
            var ws = GitWorkspace(root: root, mergeDirectory: home.appending(path: "run/merge/c1"), exportHome: home)
            ws.testHook = { stage in
                guard stage == "fetch", planted.all.isEmpty else { return }
                planted.add(stage)
                _ = try? GitFixture.plainGit(["config", "uploadpack.packObjectsHook", "touch /tmp/never"], in: root)
            }
            return ws
        })
        // An export fetches main into the engine repository; the next landing keeps that one aside as the previous one.
        _ = try b.ws.addEngineExport(runId: "run-1", commit: b.mainHead)
        #expect(planted.all.isEmpty, "an export's fetch is not the landing's")
        var reported: [[String]] = []
        let error = try #require(throws: MergeInfrastructureError.self) {
            try b.ws.landVerified(key: "K-1", verified: b.k1, expectedMain: b.mainHead, recordPending: { _ in }, tamper: { reported.append($0) })
        }
        #expect(planted.all == ["fetch"], "the config was planted before the fetch")
        #expect((error.underlying as? GitError)?.isRepositoryRefusal == true, "\(error)")
        #expect(reported.isEmpty, "\(reported)")
        let previous = b.ws.previousRepositoryPath
        #expect(exists(previous.appending(path: "objects")), "the previous engine repository is kept")
        #expect(try GitFixture.plainGit(["for-each-ref", "refs/brahma/"], in: previous).isEmpty, "main's history was bundled for a refused config")
        #expect(!exists(URL(fileURLWithPath: home.appending(path: "run/merge/c1").path + "-heal.bundle")))
    }

    /// N1: two paths of a tree that differ in bytes but name one file on this volume (the NFC and NFD forms of one name) are
    /// refused for an export, the item's fault: tar would silently keep only one of them.
    @Test func normalizationVariantsCollideInAnExport() throws {
        let home = try tempDir()
        let f = try GitFixture(files: ["a.txt": "one"])
        let scratch = try tempDir()
        let env = ["GIT_INDEX_FILE": scratch.appending(path: "index").path]
        try f.git(["read-tree", "refs/heads/main"], env: env)
        // The names go in on stdin: `Process` hands its arguments over in the file system's form, which would make them one.
        var info = ""
        for (name, text) in [("caf\u{E9}.txt", "composed\n"), ("cafe\u{301}.txt", "decomposed\n")] {
            let blob = try f.git(["hash-object", "-w", try f.write("blob-\(text.count)", text, in: scratch).path])
            info += "100644 \(blob)\t\(name)\n"
        }
        let infoFile = scratch.appending(path: "index-info")
        try Data(info.utf8).write(to: infoFile)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", f.root.path, "-c", "core.precomposeunicode=false", "update-index", "--index-info"]
        p.environment = ProcessInfo.processInfo.environment.merging(env.merging(["GIT_CONFIG_GLOBAL": "/dev/null"]) { $1 }) { $1 }
        p.standardInput = try FileHandle(forReadingFrom: infoFile)
        try p.run(); p.waitUntilExit()
        #expect(p.terminationStatus == 0)
        let tree = try f.git(["write-tree"], env: env)
        let names = try f.git(["-c", "core.precomposeunicode=false", "ls-tree", "-z", "--name-only", tree])
        #expect(names.split(separator: "\0").count == 3, "both forms are in the tree")
        let commit = try f.git(["commit-tree", tree, "-p", "refs/heads/main", "-m", "two forms of one name"])
        try f.git(["update-ref", "refs/heads/item/V-1", commit])
        let ws = GitWorkspace(root: f.root, mergeDirectory: home.appending(path: "run/merge/c1"), exportHome: home)
        let error = try #require(throws: UnexportableTree.self) { try ws.addEngineExport(runId: "run-1", commit: commit) }
        #expect(error.reason.contains("collide"), "\(error)")
        #expect(!exists(ws.exportPath(runId: "run-1")))
    }

    /// N2: a tree whose listing is too long to inspect for colliding paths is refused, never exported unchecked.
    @Test func aTreeTooLargeToInspectIsRefused() throws {
        let home = try tempDir()
        let f = try GitFixture(files: ["a.txt": "one", "dir/b.txt": "two", "dir/c.txt": "three"])
        let main = try f.git(["rev-parse", "refs/heads/main"])
        var ws = GitWorkspace(root: f.root, mergeDirectory: home.appending(path: "run/merge/c1"), exportHome: home)
        ws.collisionListingLimit = 40
        let error = try #require(throws: UnexportableTree.self) { try ws.addEngineExport(runId: "run-1", commit: main) }
        #expect(error.reason.contains("too large to inspect"), "\(error)")
        #expect(!exists(ws.exportPath(runId: "run-1")))
        ws.collisionListingLimit = 64 << 20
        #expect(try String(contentsOf: try ws.addEngineExport(runId: "run-1", commit: main).appending(path: "a.txt"), encoding: .utf8) == "one")
    }

    @Test func objectsWrittenStraightIntoTheEngineRepositoryNeverReachAMerge() throws {
        let engine = try tempDir().appending(path: "run/merge/c1", directoryHint: .isDirectory)
        let d = try Driven(ws: { GitWorkspace(root: $0, mergeDirectory: engine) })
        // Something with the engine repository's path writes into it before the merge: a lying object for the verified
        // commit's `big.txt`, a merge driver in its config and attributes that route every file to it.
        let repo = d.ws.mergeRepositoryPath
        try GitFixture.plainGit(["init", "-q", "--bare", repo.path], in: try tempDir())
        let blob = try d.f.git(["rev-parse", "\(d.k1):big.txt"])
        try forge(blob, as: "evil\n", in: repo)
        let sentinel = try tempDir().appending(path: "planted-driver-ran")
        try "[merge \"evil\"]\n\tdriver = touch '\(sentinel.path)'; true\n".write(to: repo.appending(path: "config"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: repo.appending(path: "info"), withIntermediateDirectories: true)
        try "* merge=evil\n".write(to: repo.appending(path: "info/attributes"), atomically: true, encoding: .utf8)
        let outcome = try d.ws.landVerified(key: "K-1", verified: d.k1, expectedMain: d.mainHead, recordPending: { _ in })
        guard case .rebased(let r) = outcome else { Issue.record("K-1 should have been rebased: \(outcome)"); return }
        let merged = try d.f.git(["show", "\(r):big.txt"])
        #expect(!merged.contains("evil"), "a planted object reached the merge")
        #expect(merged.contains("line one")); #expect(merged.contains("line twenty"))
        #expect(!FileManager.default.fileExists(atPath: sentinel.path), "a planted merge driver ran")
        #expect(try String(contentsOf: repo.appending(path: "config"), encoding: .utf8) == GitWorkspace.engineConfig)
    }

    @Test func aCorruptObjectIsRefusedByTheEngineFetch() throws {
        // A verified commit fsck rejects (no e-mail in its author line), on top of main: it must not fast-forward main.
        let b = try Behind()
        let body = try b.f.write("bad-commit", "tree \(try b.f.git(["rev-parse", "\(b.mainHead)^{tree}"]))\nparent \(b.mainHead)\n"
                                 + "author nobody\ncommitter nobody\n\nbad\n", in: try tempDir())
        let bad = try b.f.git(["hash-object", "-t", "commit", "-w", "--literally", body.path])
        try b.f.git(["update-ref", "refs/heads/item/K-9", bad])
        do {
            let outcome = try b.ws.landVerified(key: "K-9", verified: bad, expectedMain: b.mainHead, recordPending: { _ in })
            Issue.record("a commit fsck refuses landed: \(outcome)")
        } catch let error {
            #expect(!(error is MergeInfrastructureError), "the item's own commit is the item's fault: \(error)")
            #expect("\(error)".contains("fsck") || "\(error)".contains("missingEmail"), "\(error)")
        }
        #expect(try b.ws.head(of: GitWorkspace.mainRef) == b.mainHead)
    }

    /// The author's checkout follows a rebase the engine made (`syncItemCheckout`, through `resetHard`): untracked leftovers
    /// (a file, a directory) do not survive the sync (`clean -fd`).
    @Test func aRebasedItemCheckoutIsSyncedAndCleaned() throws {
        let b = try Behind()
        let wt = b.ws.worktreePath(key: "K-1")
        try b.f.write("leftover.txt", "stray\n", in: wt)
        try b.f.write("stray-dir/x.txt", "stray\n", in: wt)
        let outcome = try b.ws.landVerified(key: "K-1", verified: b.k1, expectedMain: b.mainHead, recordPending: { _ in })
        guard case .rebased(let head) = outcome else { Issue.record("K-1 should have been rebased: \(outcome)"); return }
        #expect(try b.ws.headCommit(in: wt) == head)
        #expect(!exists(wt.appending(path: "leftover.txt")), "an untracked file survived the sync")
        #expect(!exists(wt.appending(path: "stray-dir")), "an untracked directory survived the sync")
        #expect(exists(wt.appending(path: "m.txt")), "the checkout holds the rebased tree")
        #expect(try !b.ws.isDirty(in: wt))
    }

    @Test func mainsHistoryIsTheCompanysFaultAndAPlantedShallowIsHealed() throws {
        // A blob only main's history has is gone, and no earlier engine repository holds it: main cannot be fetched, which is
        // not K-1's doing.
        let b = try Behind()
        let blob = try b.f.git(["rev-parse", "\(b.mainHead):m.txt"])
        try FileManager.default.removeItem(at: b.f.root.appending(path: ".git/objects/\(blob.prefix(2))/\(blob.dropFirst(2))"))
        #expect(throws: MergeInfrastructureError.self) {
            try b.ws.landVerified(key: "K-1", verified: b.k1, expectedMain: b.mainHead, recordPending: { _ in })
        }
        // A planted `shallow` (A3): the engine never makes a shallow workspace, so it is removed, reported, and the landing
        // goes on.
        let s = try Behind()
        let first = try s.f.git(["rev-parse", "\(s.k1)^"])
        let shallow = s.f.root.appending(path: ".git/shallow")
        try (first + "\n").write(to: shallow, atomically: true, encoding: .utf8)
        var reported: [[String]] = []
        let outcome = try s.ws.landVerified(key: "K-1", verified: s.k1, expectedMain: s.mainHead, recordPending: { _ in },
                                            tamper: { reported.append($0) })
        guard case .rebased = outcome else { Issue.record("K-1 should have been rebased: \(outcome)"); return }
        #expect(reported == [["shallow"]]); #expect(!FileManager.default.fileExists(atPath: shallow.path))
        #expect(try s.ws.head(of: GitWorkspace.mainRef) == s.mainHead, "a rebase does not move main")
    }

    @Test func engineFetchesIgnoreTheWorkspacesURLRewritesAndSSHCommand() throws {
        // The workspace config (agent-writable) rewrites both repositories' paths to ssh, whose command would run code: the
        // shared allowlist refuses the workspace before any git runs (the company's fault, not the item's).
        let b = try Behind()
        let sentinel = try tempDir().appending(path: "ssh-ran")
        try b.f.git(["config", "url.ssh://evil.invalid/engine.insteadOf", b.ws.mergeRepositoryPath.path])
        try b.f.git(["config", "url.ssh://evil.invalid/workspace.insteadOf", b.f.root.path])
        try b.f.git(["config", "core.sshCommand", "touch '\(sentinel.path)'; false"])
        #expect(throws: MergeInfrastructureError.self) {
            try b.ws.landVerified(key: "K-1", verified: b.k1, expectedMain: b.mainHead, recordPending: { _ in })
        }
        #expect(!FileManager.default.fileExists(atPath: sentinel.path), "core.sshCommand ran")
        // With them gone the landing goes through (the engine repository is made afresh, with config of its own).
        try b.f.git(["config", "--remove-section", "url.ssh://evil.invalid/engine"])
        try b.f.git(["config", "--remove-section", "url.ssh://evil.invalid/workspace"])
        try b.f.git(["config", "--unset", "core.sshCommand"])
        let outcome = try b.ws.landVerified(key: "K-1", verified: b.k1, expectedMain: b.mainHead, recordPending: { _ in })
        guard case .rebased(let r) = outcome else { Issue.record("\(outcome)"); return }
        #expect(!FileManager.default.fileExists(atPath: sentinel.path), "core.sshCommand ran")
        #expect(try b.f.git(["rev-parse", "\(r)^"]) == b.mainHead)
        #expect(try b.ws.head(of: b.ws.branchRef(key: "K-1")) == r)
    }

    // MARK: Integration with the shared git hardening (9b fix round 5)

    @Test func engineConfigPassesTheSharedAllowlistAndAMergeGoesThrough() throws {
        let dir = try tempDir()
        let file = dir.appending(path: "config")
        try GitWorkspace.engineConfig.write(to: file, atomically: true, encoding: .utf8)
        #expect(RepoConfigGuard.scan(file, with: GitCommand(gitDir: dir, workTree: dir, commonDir: nil)).refused == nil)
        // A landing and the export of its result go through end to end, the engine repository's config as the engine wrote it.
        let b = try Behind()
        guard case .rebased(let r) = try b.ws.landVerified(key: "K-1", verified: b.k1, expectedMain: b.mainHead, recordPending: { _ in }) else {
            Issue.record("K-1 should have been rebased"); return
        }
        let export = try b.ws.addEngineExport(runId: "run-1", commit: r)
        #expect(try String(contentsOf: export.appending(path: "K-1.txt"), encoding: .utf8) == "K-1\n")
        #expect(try String(contentsOf: export.appending(path: "m.txt"), encoding: .utf8) == "main\n")
        #expect(try String(contentsOf: b.ws.mergeRepositoryPath.appending(path: "config"), encoding: .utf8) == GitWorkspace.engineConfig)
        b.ws.removeRunWorktree(runId: "run-1")
    }

    @Test func exportIgnoreCannotHideFilesFromTheMergeCheck() throws {
        let b = try Behind()
        try b.f.write(".gitattributes", "hidden.txt export-ignore\n*.md export-ignore\nsubst.txt export-subst\n")
        try b.f.write("hidden.txt", "the test the export must not hide\n")
        try b.f.write("notes.md", "notes\n")
        try b.f.write("subst.txt", "$Format:%H$\n")
        try b.f.git(["add", "-A"]); try b.f.git(["commit", "-qm", "attrs"])
        let commit = try #require(try b.ws.head(of: GitWorkspace.mainRef))
        let dir = try b.ws.addEngineExport(runId: "run-1", commit: commit)
        #expect(try String(contentsOf: dir.appending(path: "hidden.txt"), encoding: .utf8) == "the test the export must not hide\n")
        #expect(FileManager.default.fileExists(atPath: dir.appending(path: "notes.md").path))
        #expect(try String(contentsOf: dir.appending(path: "subst.txt"), encoding: .utf8) == "$Format:%H$\n")
        // The shared attributes rewrite never weakens the engine repository's own line.
        let engine = try String(contentsOf: b.ws.mergeRepositoryPath.appending(path: "info/attributes"), encoding: .utf8)
        #expect(engine == GitWorkspace.engineAttributes)
        // Every other repository's override says the same about exports.
        #expect(GitCommand.attributesOverride == "* -filter !diff merge=text -export-ignore -export-subst\n")
        #expect(try String(contentsOf: b.f.root.appending(path: ".git/info/attributes"), encoding: .utf8) == GitCommand.attributesOverride)
        b.ws.removeRunWorktree(runId: "run-1")
    }
}

final class ErrorBox: @unchecked Sendable {
    private let lock = NSLock(); private var items: [String] = []
    func add(_ s: String) { lock.lock(); items.append(s); lock.unlock() }
    var all: [String] { lock.lock(); defer { lock.unlock() }; return items }
}
