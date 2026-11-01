import Testing
import Foundation
@testable import BrahmaCore

/// The engine-owned pre-commit hook (Task 5a): installed through `GitCommand`, advisory for agents' plain git, never run by
/// engine git (which passes `core.hooksPath=/dev/null`).
@Suite(.scratch) struct HookTests {
    private struct Fixture {
        let git: GitFixture
        let layout: SandboxLayout
        var hook: URL { layout.hooksDir.appending(path: "pre-commit") }

        init() throws {
            git = try GitFixture(files: ["README.md": "# hi\n"])
            let paths = ownerPaths(try tempDir())
            let company = Company(id: "c1", name: "Acme", slug: "acme", goal: "g", workspacePath: git.root.path,
                                  status: .running, usageMode: .low, priorityWeight: 1, createdAt: Date())
            layout = SandboxLayout(paths: paths, company: company, agentHandle: "eng-1")
            ScratchScope.current?.allowExecutable(named: "pre-commit")
        }

        func install() throws -> Bool { try CompanyHooks.install(layout: layout, git: git.ws) }
        func hooksPath() throws -> String { try git.git(["config", "--get", "core.hooksPath"]) }
    }

    @Test func installSetsHooksPathAndScript() throws {
        let f = try Fixture()
        #expect(try f.install())
        let fm = FileManager.default
        #expect(fm.fileExists(atPath: f.hook.path))
        #expect((try fm.attributesOfItem(atPath: f.hook.path)[.posixPermissions] as? Int) == 0o755)
        #expect(try String(contentsOf: f.hook, encoding: .utf8) == CompanyHooks.preCommit)
        #expect(CompanyHooks.preCommit.hasPrefix("#!/bin/sh\n"))
        #expect(try f.hooksPath() == f.layout.hooksDir.path)
        // Idempotent: nothing to change the second time.
        #expect(!(try f.install()))
        // Engine git still accepts the repository (the config allowlist admits exactly this value).
        #expect(try f.git.ws.head(of: GitWorkspace.mainRef) != nil)
        // Every secret pattern of the engine's scan is in the script, so the two never drift.
        for p in SecretScan.patterns { #expect(CompanyHooks.preCommit.contains(p.ere), "\(p.label)") }
    }

    @Test func blocksAwsKeyCommit() throws {
        let f = try Fixture()
        _ = try f.install()
        try f.git.write("config.env", "AWS_KEY=AKIAABCDEFGHIJKLMNOP\n")
        try f.git.git(["add", "config.env"])
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", f.git.root.path, "-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-q", "-m", "leak"]
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        p.environment = env
        let err = Pipe()
        p.standardError = err; p.standardOutput = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        try p.run()
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(p.terminationStatus != 0)
        #expect(stderr.contains("Brahma: possible secret (aws-key) in staged changes — commit blocked."), "\(stderr)")
        #expect(!stderr.contains("AKIAABCDEFGHIJKLMNOP"), "the hook never echoes the match")
        #expect(try f.git.git(["log", "--oneline"]).split(separator: "\n").count == 1, "nothing was committed")
        // A clean change commits (the leaking file unstaged first).
        try f.git.git(["rm", "-q", "--cached", "config.env"])
        try f.git.write("notes.md", "fine\n")
        try f.git.git(["add", "notes.md"]); try f.git.git(["commit", "-q", "-m", "ok"])
        #expect(try f.git.git(["log", "--oneline"]).split(separator: "\n").count == 2)
    }

    /// A staged value for every SecretScan pattern; the test fails when a pattern gains no sample here.
    static let samples: [String: String] = [
        "aws-key": "AKIAABCDEFGHIJKLMNOP", "private-key": "-----BEGIN RSA PRIVATE KEY-----", "github-token": "ghp_" + String(repeating: "a", count: 36),
        "github-pat": "github_pat_" + String(repeating: "a", count: 60), "slack-token": "xoxb-1234567890abcdef",
        "openai-style": "sk-" + String(repeating: "a", count: 24), "stripe-live": "sk_live_" + String(repeating: "a", count: 24),
        "google-api": "AIza" + String(repeating: "a", count: 35),
    ]

    private static func commit(_ f: Fixture, _ message: String) throws -> (status: Int32, stderr: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", f.git.root.path, "-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-q", "-m", message]
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        p.environment = env
        let err = Pipe()
        p.standardError = err; p.standardOutput = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        try p.run()
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        return (p.terminationStatus, stderr)
    }

    /// B-I2: every pattern blocks (the `private-key` ERE starts with `-`, which needs `grep -e`), a line whose content starts
    /// with `+` is scanned too (M1), and a clean commit prints nothing.
    @Test(arguments: SecretScan.patterns.map(\.label)) func everySecretPatternBlocks(_ label: String) throws {
        let f = try Fixture()
        _ = try f.install()
        let sample = try #require(Self.samples[label], "add a sample for \(label)")
        try f.git.write("leak.txt", "x = \(sample)\n")
        try f.git.git(["add", "leak.txt"])
        let r = try Self.commit(f, "leak")
        #expect(r.status != 0, "\(label)")
        #expect(r.stderr.contains("Brahma: possible secret (\(label)) in staged changes — commit blocked."), "\(label): \(r.stderr)")
        #expect(!r.stderr.contains(sample)); #expect(!r.stderr.contains("grep:"), "\(r.stderr)")
        // The same value on a line that itself starts with `+`.
        try f.git.write("leak.txt", "+\(sample)\n")
        try f.git.git(["add", "leak.txt"])
        #expect(try Self.commit(f, "leak2").status != 0, "\(label): a line starting with + is scanned")
        try f.git.git(["rm", "-q", "--cached", "leak.txt"])
        try f.git.write("fine.txt", "+nothing to see\n")
        try f.git.git(["add", "fine.txt"])
        let clean = try Self.commit(f, "clean")
        #expect(clean.status == 0); #expect(clean.stderr.isEmpty, "a clean commit prints nothing: \(clean.stderr)")
        #expect(CompanyHooks.preCommit.contains("--no-ext-diff --no-textconv"))
        #expect(SecretScan.patterns.allSatisfy { !$0.ere.contains("'") }, "the EREs are single-quoted in the script")
    }

    /// S14 (fix round 1b): added lines are taken by their `>` marker inside hunks only. Content that starts with `++ ` or
    /// `+++ ` (which rendered like a `+++ b/path` header) is scanned; a real header (a path that looks like a key) is not
    /// content; a binary-attributed file is scanned (`--text`); a CRLF line is scanned.
    @Test func addedLineMarkersAreUnambiguous() throws {
        let key = "AKIAABCDEFGHIJKLMNOP"
        let blocked = "Brahma: possible secret (aws-key) in staged changes — commit blocked."
        func attempt(_ files: [String: Data], attributes: String? = nil) throws -> (status: Int32, stderr: String) {
            let f = try Fixture()
            _ = try f.install()
            if let attributes {
                try f.git.write(".gitattributes", attributes)
                try f.git.git(["add", ".gitattributes"])
                try f.git.git(["-c", "core.hooksPath=/dev/null", "-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-q", "-m", "attrs"])
            }
            for (name, data) in files {
                try data.write(to: f.git.root.appending(path: name))
                try f.git.git(["add", "--", name])
            }
            return try Self.commit(f, "change")
        }
        for content in ["++ \(key)\n", "+++ \(key)\n", "+++ b/\(key)\n", "x\n++ \(key)\n"] {
            let r = try attempt(["notes.txt": Data(content.utf8)])
            #expect(r.status != 0, "\(content.debugDescription)"); #expect(r.stderr.contains(blocked), "\(content.debugDescription): \(r.stderr)")
        }
        // A real `+++ b/<path>` header whose path looks like a key is never scanned as content.
        let header = try attempt(["\(key).txt": Data("nothing here\n".utf8)])
        #expect(header.status == 0, "\(header.stderr)"); #expect(header.stderr.isEmpty, "\(header.stderr)")
        // A binary-attributed file (and one holding NUL bytes) is still scanned.
        let binary = try attempt(["blob.bin": Data([0, 1, 2]) + Data("\n\(key)\n".utf8)], attributes: "*.bin binary\n")
        #expect(binary.status != 0, "\(binary.stderr)"); #expect(binary.stderr.contains(blocked))
        // A CRLF line.
        let crlf = try attempt(["win.txt": Data("first\r\nkey = \(key)\r\n".utf8)])
        #expect(crlf.status != 0, "\(crlf.stderr)"); #expect(crlf.stderr.contains(blocked))
        #expect(CompanyHooks.preCommit.contains("--text --output-indicator-new='>'"))
    }

    /// The hook's extraction keeps exactly the added lines' content, CR stripped, and nothing from the headers.
    @Test func extractionKeepsOnlyAddedContent() throws {
        let f = try Fixture()
        _ = try f.install()
        try f.git.write("README.md", "# hi\r\n++ two\n+++ three\n")
        try f.git.write("new.txt", "added\r\n")
        try f.git.git(["add", "-A"])
        let script = CompanyHooks.preCommit.split(separator: "\n").map(String.init)
        let awk = try #require(script.first { $0.hasPrefix("awk ") })
        // The script's own awk program (`awk '<program>' "$added" > …`).
        let program = try #require(awk.components(separatedBy: " \"$added\" > ").first.map { String($0.dropFirst(4)) })
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = ["-c", "git diff --cached -U0 --no-color --no-ext-diff --no-textconv --text --output-indicator-new='>' | awk \(program)"]
        p.currentDirectoryURL = f.git.root
        var env = ProcessInfo.processInfo.environment; env["GIT_CONFIG_GLOBAL"] = "/dev/null"; p.environment = env
        let out = Pipe(); p.standardOutput = out; p.standardError = FileHandle.nullDevice
        try p.run()
        let text = String(decoding: out.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init).sorted() == ["", "# hi", "++ two", "+++ three", "added"].sorted(), "\(text.debugDescription)")
    }

    @Test func warnsOnDeletedTests() throws {
        let f = try Fixture()
        _ = try f.install()
        try f.git.write("Tests/FooTests.swift", "// t\n"); try f.git.write("src/a.spec.js", "// s\n"); try f.git.write("src/keep.js", "1\n")
        try f.git.git(["add", "-A"]); try f.git.git(["commit", "-q", "-m", "add tests"])
        try f.git.git(["rm", "-q", "Tests/FooTests.swift", "src/a.spec.js", "src/keep.js"])
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        p.arguments = ["git", "-C", f.git.root.path, "-c", "user.name=T", "-c", "user.email=t@example.com", "commit", "-q", "-m", "rm tests"]
        var env = ProcessInfo.processInfo.environment
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        p.environment = env
        let err = Pipe()
        p.standardError = err; p.standardOutput = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        try p.run()
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        p.waitUntilExit()
        #expect(p.terminationStatus == 0, "advisory: the commit goes through")
        #expect(stderr.contains("Brahma: you deleted test files: Tests/FooTests.swift src/a.spec.js. Your reviewer must approve this explicitly."), "\(stderr)")
        #expect(!stderr.contains("keep.js"))
        #expect(try f.git.git(["log", "--oneline"]).split(separator: "\n").count == 3)
    }

    @Test func reinstallRepairsTamper() throws {
        let f = try Fixture()
        _ = try f.install()
        // The script is replaced and made non-executable; the config points elsewhere.
        try Data("#!/bin/sh\nexit 0\n".utf8).write(to: f.hook)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: f.hook.path)
        try f.git.git(["config", "core.hooksPath", "/tmp/evil-hooks"])
        #expect(try f.install())
        #expect(try String(contentsOf: f.hook, encoding: .utf8) == CompanyHooks.preCommit)
        #expect((try FileManager.default.attributesOfItem(atPath: f.hook.path)[.posixPermissions] as? Int) == 0o755)
        #expect(try f.hooksPath() == f.layout.hooksDir.path)
        // A link where the script should be is replaced, never written through.
        let target = try tempDir().appending(path: "target")
        try Data("x".utf8).write(to: target)
        try FileManager.default.removeItem(at: f.hook)
        try FileManager.default.createSymbolicLink(at: f.hook, withDestinationURL: target)
        #expect(try f.install())
        #expect(try String(contentsOf: target, encoding: .utf8) == "x")
        #expect(try String(contentsOf: f.hook, encoding: .utf8) == CompanyHooks.preCommit)
        // Any other hooksPath value keeps refusing engine git (the allowlist admits only the engine's own).
        try f.git.git(["config", "core.hooksPath", "/tmp/evil-hooks"])
        #expect(throws: GitError.self) { try f.git.ws.head(of: GitWorkspace.mainRef) }
        _ = try f.install()
        #expect(try f.git.ws.head(of: GitWorkspace.mainRef) != nil)
    }

    @Test func engineCommitsSkipHook() throws {
        let f = try Fixture()
        _ = try f.install()
        // The engine's own commit of a file the hook would block goes through: engine git never runs hooks.
        try f.git.write("Tests/GoneTests.swift", "// t\n")
        try f.git.git(["add", "-A"]); try f.git.git(["commit", "-q", "-m", "tests"])
        try FileManager.default.removeItem(at: f.git.root.appending(path: "Tests/GoneTests.swift"))
        try f.git.write("secret.env", "AKIAABCDEFGHIJKLMNOP\n")
        let before = try f.git.git(["rev-parse", "HEAD"])
        let commit = try f.git.ws.commitAll(in: f.git.root, message: "engine")
        #expect(commit != nil); #expect(try f.git.git(["rev-parse", "HEAD"]) != before)
        #expect(try f.git.git(["show", "--stat", "--format=", "HEAD"]).contains("secret.env"))
    }
}
