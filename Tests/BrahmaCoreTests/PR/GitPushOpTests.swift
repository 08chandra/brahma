import Foundation
import Testing
@testable import BrahmaCore

/// A `GitPushRunning` that runs nothing: it records every call (argv, environment, whether a credential was handed over, the
/// helper script's bytes as they were on disk during the call) and answers from a script.
final class RecordingPushRunner: GitPushRunning, @unchecked Sendable {
    struct Call {
        var args: [String]
        var env: [String: String]
        var hadCredential: Bool
        var workingDirectory: URL
        var timeout: Duration
        var outputCap: Int
        /// The credential helper named in argv, read during the call (nil when there was none).
        var helperBytes: Data?
        var helperMode: Int?
        var callDirMode: Int?
    }
    private let lock = NSLock()
    private var recorded: [Call] = []
    /// The answer to `cat-file -e` (is the commit present?).
    var shaPresent = true
    var pushResult = GitPushProcessResult(status: 0, stdout: Data(), stderr: Data(), timedOut: false)

    var calls: [Call] { lock.withLock { recorded } }
    var pushes: [Call] { calls.filter { $0.args.contains("push") } }

    func run(args: [String], env: [String: String], credential: TokenHandle?, workingDirectory: URL, timeout: Duration,
             outputCap: Int) throws -> GitPushProcessResult {
        var call = Call(args: args, env: env, hadCredential: credential != nil, workingDirectory: workingDirectory, timeout: timeout,
                        outputCap: outputCap)
        if let helper = args.first(where: { $0.hasPrefix("credential.helper=") && $0.count > "credential.helper=".count }) {
            let path = String(helper.dropFirst("credential.helper=".count))
            call.helperBytes = FileManager.default.contents(atPath: path)
            call.helperMode = (try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? NSNumber)?.intValue
            call.callDirMode = (try FileManager.default.attributesOfItem(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path)[.posixPermissions] as? NSNumber)?.intValue
        }
        lock.withLock { recorded.append(call) }
        if args.contains("cat-file") { return GitPushProcessResult(status: shaPresent ? 0 : 1, stdout: Data(), stderr: Data(), timedOut: false) }
        return pushResult
    }
}

/// The engine-side push op (Ruling X8-17): its argument checks, the hardened environment that never holds the token, the
/// repository config that cannot redirect it, and its sanitized output.
@Suite(.scratch) struct GitPushOpTests {
    /// A token-shaped value with no provider prefix, assembled at run time.
    static let token = ["brahma", "push", "token", "Zq7Wv3Kx9Lm2Np5R"].joined(separator: "-")

    struct Repo {
        let fx: GitFixture
        let sha: String
        var gitDir: URL { fx.root.appending(path: ".git", directoryHint: .isDirectory) }

        init() throws {
            fx = try GitFixture(files: ["README.md": "hello\n"])
            try fx.git(["add", "-A"])
            try fx.git(["commit", "-q", "--allow-empty", "-m", "base"])
            sha = try fx.git(["rev-parse", "HEAD"])
        }

        func request(sha: String? = nil, ref: String = "refs/heads/brahma/A-7-fix", url: String = "https://github.com/acme/app.git") -> GitPushRequest {
            GitPushRequest(gitCommonDir: gitDir, sha: sha ?? self.sha, ref: ref, url: url)
        }
    }

    static func handle() throws -> TokenHandle { try #require(TokenHandle(value: token)) }

    static func push(_ runner: RecordingPushRunner, engineEnvironment: [String: String] = ["PATH": "/usr/bin:/bin:/opt/homebrew/bin"]) throws -> GitPush {
        var push = GitPush(runner: runner, tempRoot: try tempDir())
        push.engineEnvironment = engineEnvironment
        return push
    }

    @Test func refusesForceDeleteTagsAndForeignURL() throws {
        let repo = try Repo()
        let runner = RecordingPushRunner()
        let push = try Self.push(runner)
        let token = try Self.handle()
        let bad: [GitPushRequest] = [
            // Force (`+`), delete (an empty source), a short or non-hex source, a second refspec smuggled in.
            repo.request(sha: "+" + repo.sha), repo.request(sha: ""), repo.request(sha: String(repo.sha.prefix(12))),
            repo.request(sha: repo.sha.uppercased()), repo.request(sha: repo.sha + " " + repo.sha),
            repo.request(ref: "+refs/heads/brahma/A-7"), repo.request(ref: "refs/heads/brahma/A-7:refs/heads/main"),
            // Tags, main, anything outside brahma/, a climb out of it, an empty branch under it.
            repo.request(ref: "refs/tags/v1"), repo.request(ref: "refs/heads/main"), repo.request(ref: "main"),
            repo.request(ref: "refs/heads/brahma/../main"), repo.request(ref: "refs/heads/brahma/"), repo.request(ref: "refs/heads/brahmax/a"),
            repo.request(ref: "refs/heads/brahma/a b"), repo.request(ref: "refs/heads/brahma/a.lock"),
            // Any URL but exactly https://github.com/<o>/<r>.git.
            repo.request(url: "https://gitlab.com/acme/app.git"), repo.request(url: "http://github.com/acme/app.git"),
            repo.request(url: "https://github.com.evil.example/acme/app.git"), repo.request(url: "https://x:y@github.com/acme/app.git"),
            repo.request(url: "https://github.com/acme/app"), repo.request(url: "https://github.com/acme/app.git?x=1"),
            repo.request(url: "https://github.com:443/acme/app.git"), repo.request(url: "https://github.com/acme/app/x.git"),
            repo.request(url: "file:///tmp/app.git"), repo.request(url: "https://github.com/../app.git"),
            repo.request(url: "ssh://git@github.com/acme/app.git"), repo.request(url: "https://github.com/-acme/app.git"),
            repo.request(url: "https://github.com/acme/app.git.git"), repo.request(url: "https://github.com/acme/app.git#x"),
        ]
        for request in bad {
            let outcome = try push.run(request, token: token)
            guard case .refused = outcome else { Issue.record("accepted \(request)"); continue }
        }
        #expect(runner.calls.isEmpty, "a refused request starts no git at all")
        // A commit the repository does not have is refused after one read-only probe, never pushed.
        runner.shaPresent = false
        let missing = try push.run(repo.request(sha: String(repeating: "a", count: 40)), token: token)
        #expect(missing == .refused("commit aaaaaaa is not in the engine's repository"), "\(missing)")
        #expect(runner.pushes.isEmpty)
        #expect(runner.calls.allSatisfy { !$0.hadCredential }, "the probe never gets the credential")
        // A good request: one refspec, sha:ref, no `+`, no tags, no force or delete flag, the URL from the argument.
        runner.shaPresent = true
        runner.pushResult = GitPushProcessResult(status: 0, stdout: Data("To https://github.com/acme/app.git\n*\t\(repo.sha):refs/heads/brahma/A-7-fix\t[new branch]\nDone\n".utf8),
                                                 stderr: Data(), timedOut: false)
        #expect(try push.run(repo.request(), token: token) == .pushed(remoteHead: repo.sha))
        let call = try #require(runner.pushes.last)
        let tail = Array(call.args.drop { $0 != "push" })
        #expect(tail == ["push", "--no-tags", "--porcelain", "--no-verify", "--recurse-submodules=no",
                         "https://github.com/acme/app.git", "\(repo.sha):refs/heads/brahma/A-7-fix"], "\(tail)")
        for flag in ["--force", "-f", "--delete", "-d", "--mirror", "--tags", "--all", "--prune", "--force-with-lease"] {
            #expect(!call.args.contains(flag), "\(flag)")
        }
        #expect(!call.args.contains { $0.hasPrefix("+") })
        #expect(call.hadCredential)
        #expect(call.timeout == GitPush.timeout && call.outputCap == GitPush.outputCap)
    }

    @Test func envIsHardenedBaseAndCarriesNoToken() throws {
        let repo = try Repo()
        let runner = RecordingPushRunner()
        // The engine's own environment carries everything that could leak or redirect: none of it reaches git.
        let hostile = ["PATH": "/usr/bin:relative/bin:/bin", "GIT_CONFIG_PARAMETERS": "'url.x.insteadof'='https://github.com/'",
                       "GIT_CONFIG_COUNT": "1", "GIT_CONFIG_KEY_0": "credential.helper", "GIT_CONFIG_VALUE_0": "!evil",
                       "GIT_TRACE": "/tmp/trace", "GIT_TRACE_CURL": "1", "GIT_ASKPASS": "/tmp/askpass", "HOME": "/Users/owner",
                       "GITHUB_PUSH_TOKEN": Self.token, "GH_TOKEN": Self.token, "HTTPS_PROXY": "http://proxy.invalid:1",
                       "SSH_AUTH_SOCK": "/tmp/agent", "LANG": "en_US.UTF-8"]
        let push = try Self.push(runner, engineEnvironment: hostile)
        _ = try push.run(repo.request(), token: try Self.handle())
        let call = try #require(runner.pushes.first)
        // Exactly the hardened base, plus PATH and HOME the op sets.
        #expect(Set(call.env.keys) == GitPushEnvironment.names, "\(Set(call.env.keys).symmetricDifference(GitPushEnvironment.names))")
        #expect(call.env["PATH"] == "/usr/bin:/bin", "only absolute PATH entries")
        // The non-descriptor spawn: a real work tree path (the call dir), never an anchored `.`; the live runner refuses one.
        #expect(call.env["GIT_WORK_TREE"] != "." && call.env["GIT_WORK_TREE"] == call.workingDirectory.path)
        #expect(throws: GitError.self) {
            _ = try LivePushRunner().run(args: ["--version"], env: ["GIT_DIR": repo.gitDir.path, "GIT_WORK_TREE": ".", "PATH": "/usr/bin"],
                                         credential: nil, workingDirectory: try tempDir(), timeout: .seconds(5), outputCap: 1024)
        }
        #expect(call.env["GIT_CONFIG_GLOBAL"] == "/dev/null" && call.env["GIT_CONFIG_NOSYSTEM"] == "1")
        #expect(call.env["GIT_TERMINAL_PROMPT"] == "0" && call.env["GIT_ASKPASS"] == "/usr/bin/false")
        let home = try #require(call.env["HOME"])
        #expect(home != "/Users/owner" && call.env["XDG_CONFIG_HOME"] == home, "an empty engine home: no ~/.netrc, no ~/.git-credentials")
        var config: [String: String] = [:]
        for i in 0..<(Int(call.env["GIT_CONFIG_COUNT"] ?? "") ?? 0) {
            config[call.env["GIT_CONFIG_KEY_\(i)"] ?? ""] = call.env["GIT_CONFIG_VALUE_\(i)"]
        }
        #expect(config == ["core.hooksPath": "/dev/null", "http.followRedirects": "false", "push.recurseSubmodules": "no"], "\(config)")
        #expect(call.args.contains("core.hooksPath=/dev/null"), "also on the command line, which outranks every file")
        // The token VALUE is nowhere in argv or the environment; the helper named in argv holds none of it either.
        for arg in call.args { #expect(!arg.contains(Self.token), "argv: \(arg)") }
        for (name, value) in call.env { #expect(!value.contains(Self.token) && !name.contains(Self.token), "env \(name)") }
        let helper = try #require(call.helperBytes, "the push names its one-shot credential helper")
        #expect(!String(decoding: helper, as: UTF8.self).contains(Self.token))
        #expect(String(decoding: helper, as: UTF8.self).contains("<&3"), "the helper reads the inherited descriptor")
        #expect(call.helperMode == 0o700 && call.callDirMode == 0o700)
        #expect(call.hadCredential)
        // Only the one helper: the hardened reset comes first, the engine's helper last.
        let helpers = call.args.filter { $0.hasPrefix("credential.helper=") }
        #expect(helpers.count == 2 && helpers.first == "credential.helper=" && helpers.last != "credential.helper=", "\(helpers)")
        // The call dir (helper included) is gone afterwards.
        let path = String(try #require(helpers.last).dropFirst("credential.helper=".count))
        #expect(!FileManager.default.fileExists(atPath: URL(fileURLWithPath: path).deletingLastPathComponent().path))
        // The handle itself never prints its value.
        let handle = try Self.handle()
        #expect("\(handle)" == "TokenHandle(…)" && String(reflecting: handle) == "TokenHandle(…)")
        var dumped = ""
        dump(handle, to: &dumped)
        #expect(!dumped.contains(Self.token), "\(dumped)")
        // A value the credential protocol would split is refused.
        #expect(TokenHandle(value: "a\nb") == nil && TokenHandle(value: "") == nil && TokenHandle(value: "a\u{0}b") == nil)
    }

    /// The repository's own config cannot send the push elsewhere: a config that names a remote, a URL rewrite or a helper is
    /// refused before git starts, and a planted hook never runs (the real push is `GitPushTests`' loopback server).
    @Test func repoConfigCannotRedirect() throws {
        for (key, value) in [("url.https://evil.example/.insteadOf", "https://github.com/"), ("remote.origin.pushurl", "https://evil.example/x.git"),
                             ("url.https://evil.example/.pushInsteadOf", "https://github.com/"), ("credential.helper", "!cat ~/.ssh/id_rsa"),
                             ("http.proxy", "http://evil.example:8080"), ("core.sshCommand", "touch /tmp/pwned")] {
            let repo = try Repo()
            try repo.fx.git(["config", "--file", repo.gitDir.appending(path: "config").path, key, value])
            let runner = RecordingPushRunner()
            let outcome = try Self.push(runner).run(repo.request(), token: try Self.handle())
            guard case .refused(let why) = outcome else { Issue.record("\(key): pushed anyway"); continue }
            #expect(why.contains(GitCommand.refusalPrefix), "\(key): \(why)")
            #expect(runner.pushes.isEmpty, "\(key)")
        }
        // A planted hook (no config needed): the push still runs with hooks off and pre-push skipped.
        let repo = try Repo()
        let hooks = repo.gitDir.appending(path: "hooks")
        try FileManager.default.createDirectory(at: hooks, withIntermediateDirectories: true)
        try "#!/bin/sh\ntouch \"$0.ran\"\n".write(to: hooks.appending(path: "pre-push"), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: hooks.appending(path: "pre-push").path)
        let runner = RecordingPushRunner()
        _ = try Self.push(runner).run(repo.request(), token: try Self.handle())
        let call = try #require(runner.pushes.first)
        #expect(call.args.contains("--no-verify") && call.args.contains("core.hooksPath=/dev/null"))
        #expect(call.args.contains("https://github.com/acme/app.git"), "the URL is the argument's")
        #expect(!call.args.contains("origin"))
    }

    @Test func stderrSanitizedAndCapped() throws {
        let repo = try Repo()
        let runner = RecordingPushRunner()
        let push = try Self.push(runner)
        let noisy = "remote: \u{1b}[31merror\u{1b}[0m at /Users/owner/secret/path ünïcode " + Self.token + " "
            + String(repeating: "x", count: 2 << 20)
        runner.pushResult = GitPushProcessResult(status: 1, stdout: Data(), stderr: Data(noisy.utf8), timedOut: false)
        guard case .failed(let text) = try push.run(repo.request(), token: try Self.handle()) else { Issue.record("not a failure"); return }
        #expect(text.count <= GitPush.maxShownError, "\(text.count)")
        #expect(!text.contains(Self.token), "the token is never shown")
        #expect(!text.contains("/Users/owner"), "path-like words are dropped")
        #expect(text.unicodeScalars.allSatisfy { (0x20...0x7E).contains($0.value) }, "ASCII only")
        #expect(text.contains("remote:"))
        // A rejection is a known failure; a dropped connection after sending is unknown (reconciled, never retried blind).
        runner.pushResult = GitPushProcessResult(status: 1, stdout: Data("!\t\(repo.sha):refs/heads/brahma/A-7-fix\t[remote rejected] (protected)\nDone\n".utf8),
                                                 stderr: Data("error: failed to push some refs\n".utf8), timedOut: false)
        guard case .failed = try push.run(repo.request(), token: try Self.handle()) else { Issue.record("a rejection must fail"); return }
        runner.pushResult = GitPushProcessResult(status: 128, stdout: Data(), stderr: Data("fatal: the remote end hung up unexpectedly\n".utf8), timedOut: false)
        guard case .unknown = try push.run(repo.request(), token: try Self.handle()) else { Issue.record("a lost connection must be unknown"); return }
        runner.pushResult = GitPushProcessResult(status: -1, stdout: Data(), stderr: Data(), timedOut: true)
        guard case .unknown = try push.run(repo.request(), token: try Self.handle()) else { Issue.record("a timeout must be unknown"); return }
    }
}
