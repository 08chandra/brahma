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

    @Test func timeoutKillsAndRecords() async throws {
        // The shell forks a child and waits for it: both must be gone, not just the shell.
        let pidFile = try tempDir().appending(path: "pid")
        let started = Date()
        let (outcome, _) = try await run("sleep 30 & echo $! > '\(pidFile.path)'; wait", timeout: 1)
        #expect(outcome.timedOut); #expect(outcome.exitCode == nil)
        #expect(Date().timeIntervalSince(started) < 10)
        let pid = try #require(Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await gone(pid), "the forked child survived the timeout")
    }

    @Test func timeoutEscalatesToKillWhenTermIsIgnored() async throws {
        let pidFile = try tempDir().appending(path: "pid")
        let quick = ProcessCheckRunner(termGrace: 0.5)
        let started = Date()
        let (outcome, _) = try await run("trap '' TERM; (trap '' TERM; sleep 30) & echo $! > '\(pidFile.path)'; while true; do sleep 1; done",
                                         timeout: 1, runner: quick)
        #expect(outcome.timedOut)
        #expect(Date().timeIntervalSince(started) < 10)
        let pid = try #require(Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await gone(pid), "a TERM-ignoring child survived SIGKILL")
    }

    @Test func leftoverBackgroundProcessesAreKilledWhenTheCheckEnds() async throws {
        let pidFile = try tempDir().appending(path: "pid")
        let started = Date()
        let (outcome, _) = try await run("sleep 30 & echo $! > '\(pidFile.path)'; echo done")
        #expect(outcome.exitCode == 0)
        #expect(Date().timeIntervalSince(started) < 10, "the runner waited for the background process's pipe")
        let pid = try #require(Int32(try String(contentsOf: pidFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
        #expect(await gone(pid))
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
        let src = try tempDir(), dst = try tempDir().appending(path: "snap")
        try FileManager.default.createDirectory(at: src.appending(path: "s"), withIntermediateDirectories: true)
        try "one".write(to: src.appending(path: "s/a.sh"), atomically: true, encoding: .utf8)
        try "two".write(to: src.appending(path: "b.sh"), atomically: true, encoding: .utf8)
        let manifest = try CheckScripts.snapshot(files: ["s/a.sh", "b.sh"], from: src, to: dst)
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
        #expect(p.runWorktree(runId: "r-1").path == "/w/acme/.brahma/wt-check/r-1")
    }

    /// True when the process is gone (the check polls briefly: a killed process may take a moment to be reaped).
    private func gone(_ pid: Int32) async -> Bool {
        for _ in 0..<100 {
            if kill(pid, 0) != 0 { return true }
            try? await Task.sleep(for: .milliseconds(30))
        }
        return false
    }
}
