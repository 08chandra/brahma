import Testing
import Foundation
@testable import BrahmaCore

@Suite struct GitWorkspaceTests {
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
        Thread.detachNewThread { Thread.sleep(forTimeInterval: 0.15); try? FileManager.default.removeItem(at: lock) }
        let sha = try f.ws.commitAll(in: f.root, message: "after the lock")
        #expect(sha != nil)
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
        let fsmarker = evil.deletingLastPathComponent().appending(path: "fsmonitor-ran")
        let hookmarker = evil.deletingLastPathComponent().appending(path: "hook-ran")
        let script = evil.deletingLastPathComponent().appending(path: "fsm.sh")
        try "#!/bin/sh\ntouch '\(fsmarker.path)'\nexit 1\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        try GitFixture.plainGit(["config", "core.fsmonitor", script.path], in: evil)
        try GitFixture.plainGit(["config", "diff.external", script.path], in: evil)
        for hook in ["pre-commit", "post-commit", "commit-msg"] {
            let h = evil.appending(path: ".git/hooks/\(hook)")
            try FileManager.default.createDirectory(at: h.deletingLastPathComponent(), withIntermediateDirectories: true)
            try "#!/bin/sh\ntouch '\(hookmarker.path)'\nexit 0\n".write(to: h, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: h.path)
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
        #expect(!FileManager.default.fileExists(atPath: hookmarker.path), "a hook from the crafted repo ran")
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
        ws.lockTimeout = 0.3
        let started = Date()
        #expect(throws: GitError.self) { try ws.removeWorktree(key: "K-1", keepIf: { false }) }
        #expect(throws: GitError.self) { try ws.addWorktree(key: "K-1") }
        #expect(Date().timeIntervalSince(started) < 5)
        #expect(FileManager.default.fileExists(atPath: wt.path))
        // Other items are not affected.
        try ws.addWorktree(key: "K-2")
        try ws.removeWorktree(key: "K-2", keepIf: { false })
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
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
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
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hook.path)
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
        try fm.setAttributes([.posixPermissions: 0o500], ofItemAtPath: hooks.path)      // the put-back cannot write here
        defer { try? fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: hooks.path) }
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
        #expect(env["GIT_CONFIG_NOSYSTEM"] == "1"); #expect(env["GIT_CONFIG_GLOBAL"] == "/dev/null")
        #expect(env["GIT_NO_REPLACE_OBJECTS"] == "1"); #expect(env["GIT_GRAFT_FILE"] == "/dev/null")
        let args = git.arguments(["status"], attrSource: GitCommand.emptyTreeSHA1)
        #expect(args.contains("--attr-source=4b825dc642cb6eb9a060e54bf8d69288fbee4904"))
        #expect(args.contains("core.attributesFile=/dev/null"))
        #expect(args.firstIndex(of: "--attr-source=\(GitCommand.emptyTreeSHA1)")! < args.firstIndex(of: "status")!)
        // The engine's attributes override is in place after any engine call.
        _ = try f.ws.isDirty(in: f.root)
        #expect(try String(contentsOf: f.root.appending(path: ".git/info/attributes"), encoding: .utf8) == "* -filter !diff merge=text\n")
        try f.write(".git/info/attributes", "* filter=evil\n")
        _ = try f.ws.isDirty(in: f.root)
        #expect(try String(contentsOf: f.root.appending(path: ".git/info/attributes"), encoding: .utf8) == GitCommand.attributesOverride)
    }

    @Test func attrSourceNeedsGit242() throws {
        #expect(GitCommand.supportsAttrSource(versionLine: "git version 2.52.0"))
        #expect(GitCommand.supportsAttrSource(versionLine: "git version 2.42.0.windows.1"))
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

    private func sentinelScript(_ dir: URL, _ name: String) throws -> (script: URL, marker: URL) {
        let marker = dir.appending(path: "\(name)-ran"), script = dir.appending(path: "\(name).sh")
        try "#!/bin/sh\ntouch '\(marker.path)'\nexit 1\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        return (script, marker)
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
        // While the engine waits for the lock, the config gains a filter; then the lock goes.
        Thread.detachNewThread {
            Thread.sleep(forTimeInterval: 0.08)
            try? (current + "[filter \"evil\"]\n\tclean = cat\n").write(to: config, atomically: true, encoding: .utf8)
            Thread.sleep(forTimeInterval: 0.05)
            try? FileManager.default.removeItem(at: lock)
        }
        // One git call whose first attempt meets the lock: the retry is scanned again and refused.
        let git = GitCommand(gitDir: f.root.appending(path: ".git"), workTree: f.root, commonDir: nil, onRefused: { log.add($0) })
        let error = try #require(throws: GitError.self) { try git.run(["add", "-A"]) }
        #expect(error.isRepositoryRefusal, "\(error)")
        #expect(log.all.count == 1)
        _ = ws
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
}

