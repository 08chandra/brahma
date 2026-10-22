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
        // The engine merges into main, quarantines a ref and another leaseholder commits, all while the plan turn runs.
        try f.git(["update-ref", "refs/heads/main", other])
        try f.git(["update-ref", "refs/brahma/quarantine/new", other])
        try f.git(["update-ref", "-d", "refs/brahma/quarantine/old"])
        try f.git(["update-ref", "refs/heads/item/ACME-2", other])
        try f.git(["branch", "item/ACME-3", other])
        #expect(try f.ws.enforcePlanBarrier(before, key: "ACME-1", in: wt).isEmpty)
        #expect(try f.ws.head(of: "refs/heads/main") == other, "main is the main guard's, never put back")
        #expect(try f.ws.head(of: "refs/brahma/quarantine/new") == other)
        #expect(try f.ws.head(of: "refs/brahma/quarantine/old") == nil)
        #expect(try f.ws.head(of: "refs/heads/item/ACME-2") == other)
        #expect(try f.ws.head(of: "refs/heads/item/ACME-3") == other)
        #expect(GitWorkspace.engineManaged("refs/heads/item/ACME-1", ownBranch: "refs/heads/item/ACME-1") == false)
    }

    @Test func planBarrierRestoresRepositoryFilesWithTheirModes() throws {
        let (f, wt) = try barrierFixture()
        let fm = FileManager.default
        let admin = f.root.appending(path: ".git/worktrees/ACME-1")
        let script = "#!/bin/sh\nexit 0\n"
        let hook = try f.write(".git/hooks/post-checkout", script)
        try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hook.path)
        let head = try String(contentsOf: admin.appending(path: "HEAD"), encoding: .utf8)
        let before = try f.ws.planBarrier(key: "ACME-1", in: wt)
        // Rewritten (and so no longer executable), attributes and an alternate added, the worktree's HEAD repointed and a
        // tracked file hidden from status with the skip-worktree bit.
        try "#!/bin/sh\ntouch /tmp/pwned\n".write(to: hook, atomically: true, encoding: .utf8)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: hook.path)
        try f.write(".git/info/attributes", "* filter=evil\n")
        try f.write(".git/objects/info/alternates", "/tmp/elsewhere\n")
        try "ref: refs/heads/main\n".write(to: admin.appending(path: "HEAD"), atomically: true, encoding: .utf8)
        try f.git(["update-index", "--skip-worktree", "a.txt"], in: wt)
        let found = try f.ws.enforcePlanBarrier(before, key: "ACME-1", in: wt)
        #expect(Set(found) == ["changed hooks/post-checkout", "new info/attributes", "new objects/info/alternates",
                               "changed worktrees/ACME-1/HEAD", "changed index"])
        #expect(try String(contentsOf: hook, encoding: .utf8) == script)
        #expect((try fm.attributesOfItem(atPath: hook.path)[.posixPermissions] as? Int) == 0o755, "the hook stays executable")
        #expect(!fm.fileExists(atPath: f.root.appending(path: ".git/info/attributes").path))
        #expect(!fm.fileExists(atPath: f.root.appending(path: ".git/objects/info/alternates").path))
        #expect(try String(contentsOf: admin.appending(path: "HEAD"), encoding: .utf8) == head)
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
}
