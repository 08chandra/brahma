import Testing
import Foundation
@testable import BrahmaCore

@Suite(.serialized) struct CheckRunnerTests {
    private let runner = ProcessCheckRunner()

    private func run(_ command: String, in dir: URL? = nil, timeout: TimeInterval = 20, env: [String: String]? = nil,
                     runner: ProcessCheckRunner? = nil) async throws -> (CheckOutcome, String) {
        let work = try dir ?? tempDir()
        let out = try tempDir().appending(path: "out.log")
        let environment = env ?? ChildEnvironment.make(base: ProcessInfo.processInfo.environment, extra: ["BRAHMA_AGENT_ID": "agent-1"],
                                                       purpose: .check)
        let outcome = await (runner ?? self.runner).run(command: command, workingDirectory: work, timeout: timeout,
                                                        outputURL: out, environment: environment)
        return (outcome, (try? String(contentsOf: out, encoding: .utf8)) ?? "")
    }

    @Test func passAndFailExitCodes() async throws {
        let (ok, okOut) = try await run("echo hello; exit 0")
        #expect(ok.exitCode == 0); #expect(!ok.timedOut); #expect(ok.tail.contains("hello")); #expect(okOut.contains("hello"))
        let (bad, _) = try await run("echo nope >&2; exit 3")
        #expect(bad.exitCode == 3); #expect(!bad.timedOut); #expect(bad.tail.contains("nope"))
        // stdin is /dev/null: reading it ends at once.
        let (stdin, _) = try await run("cat; echo after")
        #expect(stdin.exitCode == 0); #expect(stdin.tail.contains("after"))
        // A command killed by a signal reports the shell convention 128 + signal.
        let (killed, _) = try await run("kill -9 $$")
        #expect(killed.exitCode == 137)
        // A directory that is not there is "could not run", never a thrown error or a failure.
        let (missing, _) = try await run("true", in: URL(fileURLWithPath: "/nonexistent-brahma-dir"))
        #expect(missing.exitCode == nil); #expect(!missing.timedOut); #expect(!missing.tail.isEmpty)
    }

    @Test func checkEnvironmentIsScoped() async throws {
        let base = ["PATH": "/usr/bin:/bin", "HOME": "/tmp/h", "FAKE_SECRET_TOKEN": "s3cret", "ANTHROPIC_API_KEY": "sk-x",
                    "CLAUDE_CODE_OAUTH_TOKEN": "t", "BRAHMA_DEV": "1", "AWS_PROFILE": "prod", "NODE_AUTH_TOKEN": "n"]
        let env = ChildEnvironment.make(base: base, extra: ["BRAHMA_AGENT_ID": "holder-7", "BRAHMA_DEV": "1"], purpose: .check)
        let (_, text) = try await run("env", env: env)
        #expect(text.contains("BRAHMA_AGENT_ID=holder-7"))
        #expect(text.contains("PATH=/usr/bin:/bin"))
        for secret in ["FAKE_SECRET_TOKEN", "s3cret", "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "BRAHMA_DEV", "AWS_PROFILE", "NODE_AUTH_TOKEN"] {
            #expect(!text.contains(secret), "\(secret) leaked into the check environment")
        }
        // The runner uses exactly the environment it is given.
        let (_, exact) = try await run("echo \"[$ONLY_THIS]\"; echo \"[$HOME]\"", env: ["ONLY_THIS": "yes", "PATH": "/usr/bin:/bin"])
        #expect(exact.contains("[yes]")); #expect(exact.contains("[]"))
    }

    @Test func runsInGivenDirectory() async throws {
        let dir = try tempDir()
        try "x".write(to: dir.appending(path: "marker.txt"), atomically: true, encoding: .utf8)
        let (outcome, text) = try await run("pwd -P; ls marker.txt", in: dir)
        #expect(outcome.exitCode == 0)
        #expect(text.contains(dir.resolvingSymlinksInPath().path)); #expect(text.contains("marker.txt"))
    }

    /// A runner clock that stands still until `file` exists (the command has started and written what the test needs), then
    /// moves `step` seconds per reading: the timeout fires only after the command is under way, with no real timer to race.
    private func clock(after file: URL, step: TimeInterval = 10) -> @Sendable () -> TimeInterval {
        final class Ticks: @unchecked Sendable { let lock = NSLock(); var t = 0.0 }
        let ticks = Ticks()
        return {
            ticks.lock.withLock {
                if ((try? String(contentsOf: file, encoding: .utf8)) ?? "").contains("\n") { ticks.t += step }
                return ticks.t
            }
        }
    }

    @Test func timeoutKillsAndRecords() async throws {
        // The shell forks a child and waits for it: both must be gone, not just the shell.
        let pidFile = try tempDir().appending(path: "pid")
        let (outcome, _) = try await run("sleep 30 & echo $! > '\(pidFile.path)'; wait", timeout: 1,
                                         runner: ProcessCheckRunner(termGrace: 0.5, clock: clock(after: pidFile)))
        #expect(outcome.timedOut); #expect(outcome.exitCode == nil)
        let pid = try #require(Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await gone(pid), "the forked child survived the timeout")
    }

    /// B-I1: a check that moves its leader out of its own process group (into the engine's) cannot dodge the timeout. The
    /// `killpg` misses the now-empty group, but the leader is killed by `kill(pid)` directly, so the run still ends.
    @Test func timeoutKillsALeaderThatLeftItsGroup() async throws {
        // `setpgrp(0, getppid())` puts this process into its parent's (the runner's) group; it then ignores TERM and sleeps.
        final class Ticks: @unchecked Sendable { let lock = NSLock(); var t = 0.0; func next() -> TimeInterval { lock.withLock { t += 0.5; return t } } }
        let ticks = Ticks()
        let (outcome, _) = try await run("exec perl -e 'setpgrp(0, getppid()); $SIG{TERM}=\"IGNORE\"; sleep 600'",
                                         timeout: 1, runner: ProcessCheckRunner(termGrace: 0.5, clock: { ticks.next() }))
        #expect(outcome.timedOut); #expect(outcome.exitCode == nil)
    }

    @Test func timeoutEscalatesToKillWhenTermIsIgnored() async throws {
        let pidFile = try tempDir().appending(path: "pid")
        let quick = ProcessCheckRunner(termGrace: 0.5, clock: clock(after: pidFile, step: 0.5))
        let (outcome, _) = try await run("trap '' TERM; (trap '' TERM; sleep 30) & echo $! > '\(pidFile.path)'; while true; do sleep 1; done",
                                         timeout: 1, runner: quick)
        #expect(outcome.timedOut)
        let pid = try #require(Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await gone(pid), "a TERM-ignoring child survived SIGKILL")
    }

    @Test func leftoverBackgroundProcessesAreKilledWhenTheCheckEnds() async throws {
        let pidFile = try tempDir().appending(path: "pid")
        let started = AwakeTime.now
        let (outcome, _) = try await run("sleep 300 & echo $! > '\(pidFile.path)'; echo done")
        #expect(outcome.exitCode == 0)
        #expect(AwakeTime.now - started < .seconds(60), "hang guard: the runner waited for the background process's pipe (it sleeps 300 s)")
        let pid = try #require(Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await gone(pid))
    }

    /// A sleeping Mac must not expire a check: the timeout runs on a clock that stands still in sleep.
    @Test func timeoutFollowsTheMonotonicClockNotTheWallClock() async throws {
        // The injected clock does not move: the command outlives its 1 s timeout on the wall clock without timing out.
        let frozen = ProcessCheckRunner(clock: { 100 })
        let (steady, _) = try await run("sleep 1.5; echo done", timeout: 1, runner: frozen)
        #expect(!steady.timedOut); #expect(steady.exitCode == 0)
        // One that jumps ahead (as the wall clock does after a sleep) times it out.
        final class Jumpy: @unchecked Sendable {
            let lock = NSLock(); var t = 0.0
            func next() -> TimeInterval { lock.withLock { t += 0.5; return t } }
        }
        let jumpy = Jumpy()
        let (cut, _) = try await run("sleep 20", timeout: 1, runner: ProcessCheckRunner(termGrace: 0.5, clock: { jumpy.next() }))
        #expect(cut.timedOut)
        // The default is the system uptime clock.
        let a = ProcessCheckRunner.uptime(); try await Task.sleep(for: .milliseconds(20)); #expect(ProcessCheckRunner.uptime() > a)
    }

    @Test func outputIsCapped() async throws {
        // 3 MB of 'a', then a distinctive last line.
        let (outcome, text) = try await run("head -c 3000000 /dev/zero | tr '\\0' 'a'; echo; echo THE-LAST-LINE")
        #expect(outcome.exitCode == 0)
        let marker = "[output truncated]"
        #expect(text.components(separatedBy: marker).count - 1 == 1, "the marker is appended exactly once")
        #expect(text.utf8.count <= 1_048_576 + marker.utf8.count + 4)
        #expect(text.utf8.count > 1_000_000)
        #expect(!text.contains("THE-LAST-LINE"))
        // The tail is the real end of the output, at most 4000 characters.
        #expect(outcome.tail.count <= 4000); #expect(outcome.tail.contains("THE-LAST-LINE"))
        // Small output is not marked.
        let (_, small) = try await run("echo tiny")
        #expect(!small.contains(marker))
    }

    @Test func isTestFileRules() {
        for p in ["test/a.js", "tests/a.js", "src/__tests__/x.ts", "spec/foo.rb", "a/specs/b.rb", "TESTS/x.py", "Test/y.go",
                  "test_foo.py", "pkg/test_bar.py", "foo.test.js", "foo.spec.ts", "foo_test.go", "foo-test.js", "foo.tests.js",
                  "FooTests.swift", "Sources/FooTest.swift", "a/b/LeaseTests.swift", "UPPER.TEST.JS"] {
            #expect(PathRules.isTestFile(p), "\(p) should be a test file")
        }
        for p in ["src/main.swift", "latest/a.js", "contest/x.py", "attest.js", "src/testing/a.js", "protest.go", "README.md",
                  "Sources/Tests.txt", "src/spectrum/a.c", "mytest.go", "test.js", "specs.md", "a/testdata/x.json"] {
            #expect(!PathRules.isTestFile(p), "\(p) should not be a test file")
        }
    }

    @Test func referencedFilesFromCommand() throws {
        let root = try tempDir()
        func make(_ path: String, _ text: String = "x") throws {
            let url = root.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        try make("scripts/check.sh"); try make("tests/a.js"); try make("input.txt")
        let outside = root.deletingLastPathComponent().appending(path: "secret-\(UUID().uuidString).txt")
        try "s".write(to: outside, atomically: true, encoding: .utf8)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "link.txt"), withDestinationURL: outside)
        try FileManager.default.createSymbolicLink(at: root.appending(path: "dirlink"), withDestinationURL: root.deletingLastPathComponent())

        let command = "./scripts/check.sh --fast && node \"tests/a.js\" < input.txt; (cat 'input.txt') | cat ../\(outside.lastPathComponent) "
            + "missing.sh /etc/passwd scripts tests/../tests/a.js link.txt dirlink/\(outside.lastPathComponent) | grep -q x>data/other.txt"
        let files = CheckScripts.referencedFiles(command: command, root: root)
        #expect(files == ["scripts/check.sh", "tests/a.js", "input.txt"], "\(files)")

        // Quotes are stripped from a token; directories, missing files, absolute paths, '..' and symlinks are not files.
        #expect(CheckScripts.referencedFiles(command: "cat 'input.txt'", root: root) == ["input.txt"])
        // At most 20 files.
        for n in 0..<30 { try make("many/f\(n).txt") }
        let many = (0..<30).map { "many/f\($0).txt" }.joined(separator: " ")
        let capped = CheckScripts.referencedFiles(command: "cat " + many, root: root)
        #expect(capped.count == CheckScripts.maxFiles); #expect(CheckScripts.maxFiles == 20)
        #expect(capped.first == "many/f0.txt")
    }

    @Test func snapshotAndHashes() throws {
        let ws = try tempDir()
        let dst = ws.appending(path: "snap")
        let manifest = try CheckScripts.write(contents: ["s/a.sh": Data("one".utf8), "b.sh": Data("two".utf8)], workspace: ws, dir: "snap")
        #expect(manifest == ["s/a.sh": StableHash.fnv1a64("one"), "b.sh": StableHash.fnv1a64("two")])
        #expect(try String(contentsOf: dst.appending(path: "s/a.sh"), encoding: .utf8) == "one")
        #expect(CheckScripts.hashes(files: ["s/a.sh", "b.sh", "gone.sh"], in: dst) == ["s/a.sh": manifest["s/a.sh"]!, "b.sh": manifest["b.sh"]!, "gone.sh": nil])
        try "changed".write(to: dst.appending(path: "b.sh"), atomically: true, encoding: .utf8)
        #expect(CheckScripts.hashes(files: ["b.sh"], in: dst)["b.sh"]! != manifest["b.sh"]!)
        // The script hash depends on names and contents, not on order.
        #expect(CheckScripts.scriptHash(manifest) == CheckScripts.scriptHash(["b.sh": manifest["b.sh"]!, "s/a.sh": manifest["s/a.sh"]!]))
        #expect(CheckScripts.scriptHash(manifest) != CheckScripts.scriptHash(["b.sh": manifest["b.sh"]!]))
        #expect(CheckScripts.scriptHash([:]).count == 16)
    }

    @Test func checkPathsLayout() {
        let p = CheckPaths(workspace: URL(fileURLWithPath: "/w/acme"))
        #expect(p.snapshotDir(key: "ACME-3", revision: 2).path == "/w/acme/.brahma/checks/ACME-3/rev2")
        #expect(p.manifest(key: "ACME-3", revision: 2).path == "/w/acme/.brahma/checks/ACME-3/rev2/manifest.json")
        // Neither a submission's checkout nor a merge check's export is in the workspace: both live under the data home.
        let home = BrahmaPaths(home: URL(fileURLWithPath: "/h"), workspaces: URL(fileURLWithPath: "/w"))
        #expect(home.exportDir(runId: "r-1").path == "/h/run/exports/r-1")
        #expect(home.checkoutDir(runId: "r-1").path == "/h/run/checkouts/r-1")
        let ws = GitWorkspace(root: URL(fileURLWithPath: "/w/acme"), exportHome: home.home)
        #expect(ws.exportPath(runId: "r-1") == home.exportDir(runId: "r-1"))
        #expect(ws.checkoutPath(runId: "r-1") == home.checkoutDir(runId: "r-1"))
    }

    /// True when the process is gone (the check polls briefly: a killed process may take a moment to be reaped).
    /// B-M1: if the leader is reaped out from under the engine (waitid gives ECHILD), its exit is lost, so the outcome is
    /// inconclusive (exitCode nil), never exit 0. Signalling a lost child never happens.
    @Test func lostChildIsInconclusiveNotPass() async throws {
        let child = try ProcessGroupChild.spawn(executable: "/bin/sh", arguments: ["/bin/sh", "-c", "exit 0"],
                                                environment: ["PATH": "/usr/bin:/bin"], workingDirectory: URL(fileURLWithPath: "/"),
                                                output: -1)
        // Reap it ourselves before the engine notices (what a stray wait(-1) elsewhere would do).
        var status: Int32 = 0
        while waitpid(child.pid, &status, 0) < 0 && errno == EINTR {}
        #expect(child.hasExited())
        #expect(child.lostTrack)
        #expect(child.signalGroup(SIGKILL) == false, "a lost child must never be signalled")
    }

    private func gone(_ pid: Int32) async -> Bool {
        for _ in 0..<100 {
            if kill(pid, 0) != 0 { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return false
    }
}
