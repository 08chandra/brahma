import Foundation

/// One push (the engine-side stand-in for S's `HelperOp.gitPush`, Ruling 2): the verified commit of the engine-owned repository
/// to one `brahma/` branch of one GitHub repository.
public struct GitPushRequest: Equatable, Sendable {
    /// The repository's common git dir (the company workspace's `.git`).
    public var gitCommonDir: URL
    /// 40 lowercase hex.
    public var sha: String
    /// `refs/heads/brahma/...`.
    public var ref: String
    /// Exactly `https://github.com/<owner>/<repo>.git`, from the channel record (never from the repository's config).
    public var url: String

    public init(gitCommonDir: URL, sha: String, ref: String, url: String) {
        self.gitCommonDir = gitCommonDir; self.sha = sha; self.ref = ref; self.url = url
    }
}

/// What a push came to.
public enum GitPushOutcome: Equatable, Sendable {
    /// GitHub took it: the branch's head is `remoteHead` (the pushed commit).
    case pushed(remoteHead: String)
    /// Refused before git started (an argument, the repository's config, a commit it does not have).
    case refused(String)
    /// Git said no (a rejection, the credential): nothing changed upstream. Sanitized git output.
    case failed(String)
    /// It may or may not have reached GitHub (a timeout, a connection lost after sending): reconciled by reading the branch,
    /// never retried blind.
    case unknown(String)
}

/// What one git process did.
public struct GitPushProcessResult: Equatable, Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data
    public var timedOut: Bool

    public init(status: Int32, stdout: Data, stderr: Data, timedOut: Bool) {
        self.status = status; self.stdout = stdout; self.stderr = stderr; self.timedOut = timedOut
    }
}

/// The seam between `GitPush` and a git process: `args` (after `git`) and `env` exactly as `GitCommand.commandLine` built them
/// plus `GitPushEnvironment`; `credential`, when given, reaches the child only as the read end of a pipe at descriptor 3
/// (`LivePushRunner`), never in argv or the environment. A test fake records the call.
///
/// `GitProcessRunning` has no way to hand a child a descriptor, hence this sibling protocol; the command line still comes from
/// `GitCommand.commandLine()` and nothing in `GitCommand` changed.
public protocol GitPushRunning: Sendable {
    func run(args: [String], env: [String: String], credential: TokenHandle?, workingDirectory: URL, timeout: Duration,
             outputCap: Int) throws -> GitPushProcessResult
}

/// The push child's environment: `GitCommand`'s pinned one built over a base holding only `PATH` (so nothing of the engine's
/// own environment — a `GIT_CONFIG_*`, a trace switch, a proxy, a token — reaches git), plus config entries that switch off
/// hooks, redirects and submodule pushes. Never the token (Ruling X8-17): a same-uid `ps -E` reads any child's environment.
public enum GitPushEnvironment {
    /// The `GIT_CONFIG_COUNT` entries, in order.
    public static let config: [(key: String, value: String)] = [
        ("core.hooksPath", "/dev/null"), ("http.followRedirects", "false"), ("push.recurseSubmodules", "no"),
    ]

    /// Every name the child's environment holds, exactly.
    public static let names: Set<String> = {
        var n: Set<String> = ["PATH", "HOME", "XDG_CONFIG_HOME", "GIT_DIR", "GIT_WORK_TREE", "GIT_COMMON_DIR", "GIT_CONFIG_GLOBAL",
                              "GIT_CONFIG_NOSYSTEM", "GIT_ATTR_NOSYSTEM", "GIT_NO_REPLACE_OBJECTS", "GIT_GRAFT_FILE",
                              "GIT_TERMINAL_PROMPT", "GIT_ASKPASS", "SSH_ASKPASS", "GIT_OPTIONAL_LOCKS", "GIT_CONFIG_COUNT"]
        for i in config.indices { n.insert("GIT_CONFIG_KEY_\(i)"); n.insert("GIT_CONFIG_VALUE_\(i)") }
        return n
    }()

    /// `commandLine`'s environment with the config entries added; any name outside `names` is dropped.
    static func make(_ base: [String: String]) -> [String: String] {
        var env = base
        env["GIT_CONFIG_COUNT"] = String(config.count)
        for (i, entry) in config.enumerated() {
            env["GIT_CONFIG_KEY_\(i)"] = entry.key
            env["GIT_CONFIG_VALUE_\(i)"] = entry.value
        }
        // Pinned whatever `GitCommand` does: no prompt, no askpass, no global or system config.
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_ASKPASS"] = "/usr/bin/false"
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        return env.filter { names.contains($0.key) }
    }
}

/// The push op (Ruling 2 and X8-17). `run` checks every argument, refuses a repository whose config names a remote, a URL
/// rewrite, a helper or any program (`GitCommand`'s config allowlist), probes that the commit is there, then runs
/// `git push --no-tags --porcelain --no-verify --recurse-submodules=no <url> <sha>:<ref>` with `GitCommand`'s forced `-c`
/// flags (hooks off, every protocol but https off), `GitPushEnvironment`, an empty engine `HOME`, and a one-shot credential
/// helper.
///
/// The credential (X8-17): a credential helper, not `GIT_ASKPASS`, because git hands a helper the request's protocol and host,
/// so it answers only `https` + `github.com` (nothing else, even a redirect `http.followRedirects=false` already stops), and
/// it is asked once for both username and password where askpass is run per prompt with the prompt text in its argv. The
/// helper is a 0700 script in a 0700 call directory made for this push and removed after it; it holds no secret: it reads the
/// token once from descriptor 3, the read end of a pipe the engine filled and closed (`TokenHandle.withPipe`) and handed to
/// git alone, and prints it to git on its stdout. The token is never in argv, in any environment, on disk or in a log.
///
/// Network: the URL is checked to be exactly `https://github.com/<o>/<r>.git` and redirects are off; binding the child to an
/// egress proxy that admits only github.com (spec §9.4: "network to github.com only") is S's or X4's follow-up: the engine's git
/// runs unsandboxed on this tree.
public struct GitPush: Sendable {
    public static let timeout: Duration = .seconds(120)
    public static let outputCap = 1 << 20
    /// The longest git error shown or stored.
    public static let maxShownError = 300
    static let probeTimeout: Duration = .seconds(30)
    /// The credential helper reads the token at this descriptor.
    static let credentialDescriptor: Int32 = 3

    let runner: any GitPushRunning
    /// Where the per-push call directory is made (the engine's 0700 temp dir under its data home).
    let tempRoot: URL
    /// Only `PATH` is taken from it (absolute entries). Test seam; the engine's own environment otherwise.
    var engineEnvironment: [String: String] = ProcessInfo.processInfo.environment
    /// Tests only: `http://127.0.0.1:<port>` standing in for `https://github.com` (a `-c url.<it>/.insteadOf=` override and
    /// `protocol.http.allow`), so the real push runs against a loopback server. Never set by the engine.
    var loopbackRemote: String? = nil

    public init(runner: any GitPushRunning = LivePushRunner(), tempRoot: URL) {
        self.runner = runner; self.tempRoot = tempRoot
    }

    /// The argument checks: the repository the URL names, or why the request is refused. Nothing runs before this passes.
    public static func validate(_ r: GitPushRequest) -> PRDecision<GitHubRepoRef> {
        guard r.sha.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil else {
            return .refused("the pushed commit must be a full 40-character sha (no +, no delete)")
        }
        let branch = r.ref.hasPrefix("refs/heads/") ? String(r.ref.dropFirst("refs/heads/".count)) : ""
        guard branch.hasPrefix(PRBranch.prefix), branch.count > PRBranch.prefix.count, PRBranch.isValidBranchName(branch),
              r.ref.utf8.count <= PRBranch.maxRefBytes else {
            return .refused("the engine pushes only to refs/heads/\(PRBranch.prefix)*, one valid branch")
        }
        guard let repo = GitHubRepoRef.parse(pushURL: r.url) else {
            return .refused("the push URL must be exactly https://github.com/<owner>/<repo>.git")
        }
        return .allowed(repo)
    }

    public func run(_ r: GitPushRequest, token: TokenHandle) throws -> GitPushOutcome {
        if let why = Self.validate(r).refusal { return .refused(why) }
        if let loopbackRemote { precondition(loopbackRemote.hasPrefix("http://127.0.0.1:"), "the loopback seam is for tests on 127.0.0.1") }
        let fm = FileManager.default
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let callDir = tempRoot.appending(path: "brahma-push-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: callDir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        defer { Self.remove(callDir, under: tempRoot) }
        let home = callDir.appending(path: "home", directoryHint: .isDirectory)
        try fm.createDirectory(at: home, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])

        var git = GitCommand(gitDir: r.gitCommonDir, workTree: callDir, commonDir: nil)
        git.baseEnvironment = ["PATH": GitCommand.absoluteEntries(of: engineEnvironment["PATH"])]
        git.homeDirectory = home
        git.allowsHTTPSFetch = true
        git.timeoutSeconds = SafeGit.seconds(Self.timeout)
        git.tempRoot = callDir
        // A company workspace may name its own advisory hooks directory (`CompanyHooks`); the forced `core.hooksPath=/dev/null`
        // overrides it. Any other hooks path refuses the repository.
        let root = r.gitCommonDir.deletingLastPathComponent()
        git.engineHooksPath = root.pathComponents.contains(".brahma") ? nil : root.appending(path: ".brahma/hooks").path

        // The commit must be in the repository (a read-only probe, no credential).
        let probe: (args: [String], environment: [String: String])
        do { probe = try git.commandLine(["cat-file", "-e", "\(r.sha)^{commit}"]) } catch let e as GitError { return .refused(Self.refusalText(e)) }
        let present = try runner.run(args: probe.args, env: GitPushEnvironment.make(probe.environment), credential: nil,
                                     workingDirectory: callDir, timeout: Self.probeTimeout, outputCap: 4096)
        guard present.status == 0, !present.timedOut else { return .refused("commit \(r.sha.prefix(7)) is not in the engine's repository") }

        let helper = callDir.appending(path: "credential-helper")
        try Self.writeHelper(helper, loopback: loopbackRemote)
        var args = ["-c", Self.helperConfig(helper), "-c", "credential.useHttpPath=false"]
        if let loopbackRemote { args += ["-c", "protocol.http.allow=always", "-c", "url.\(loopbackRemote)/.insteadOf=https://github.com/"] }
        args += ["push", "--no-tags", "--porcelain", "--no-verify", "--recurse-submodules=no", r.url, "\(r.sha):\(r.ref)"]
        let line: (args: [String], environment: [String: String])
        do { line = try git.commandLine(args) } catch let e as GitError { return .refused(Self.refusalText(e)) }
        let result = try runner.run(args: line.args, env: GitPushEnvironment.make(line.environment), credential: token,
                                    workingDirectory: callDir, timeout: Self.timeout, outputCap: Self.outputCap)
        return Self.outcome(result, sha: r.sha, ref: r.ref, token: token)
    }

    // MARK: Pieces

    /// The one-shot helper. It answers only `get` for the expected protocol and host, reads the token once from descriptor 3
    /// (shell builtins only: the value is never in any argv), closes the descriptor and prints the credential to git.
    static func writeHelper(_ url: URL, loopback: String?) throws {
        var protocolName = "https", host = "github.com"
        if let loopback, let rest = loopback.split(separator: "/", omittingEmptySubsequences: true).dropFirst().first {
            protocolName = "http"
            host = String(rest)
        }
        let script = """
            #!/bin/sh
            # Brahma's one-shot push credential (Ruling X8-17). It holds no secret: it reads the token once from descriptor \(credentialDescriptor).
            [ "$1" = get ] || exit 0
            p=; h=
            while IFS= read -r l && [ -n "$l" ]; do
              case "$l" in protocol=*) p=${l#protocol=} ;; host=*) h=${l#host=} ;; esac
            done
            [ "$p" = '\(protocolName)' ] && [ "$h" = '\(host)' ] || exit 0
            IFS= read -r t <&\(credentialDescriptor) || [ -n "$t" ] || exit 0
            exec \(credentialDescriptor)<&-
            printf 'username=x-access-token\\npassword=%s\\n' "$t"

            """
        guard FileManager.default.createFile(atPath: url.path, contents: Data(script.utf8), attributes: [.posixPermissions: 0o700]) else {
            throw GitError.failed(command: "push", status: -1, stderr: "cannot write the credential helper")
        }
    }

    /// `credential.helper=!'<path>'`: git runs a `!` helper as a shell snippet (`<snippet> get`), so the path is single-quoted
    /// (each `'` as `'\''`) and survives the spaces of the default data home (`~/Library/Application Support/Brahma`). A bare
    /// absolute path would be split by that shell.
    static func helperConfig(_ helper: URL) -> String {
        "credential.helper=!'" + helper.path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    static func refusalText(_ e: GitError) -> String {
        if case .failed(_, _, let stderr) = e, e.isRepositoryRefusal { return Store.flat(stderr, max: 400) }
        return Store.flat(e.description, max: 400)
    }

    /// Markers of a connection lost after git may have sent the pack: the outcome is unknown.
    static let ambiguous = ["hung up unexpectedly", "rpc failed", "unexpected disconnect", "connection reset", "operation timed out",
                            "early eof", "broken pipe", "transfer closed", "http/2 stream", "ssl_read", "recv failure"]

    static func outcome(_ result: GitPushProcessResult, sha: String, ref: String, token: TokenHandle) -> GitPushOutcome {
        let stderr = shown(result.stderr, token: token)
        if result.timedOut { return .unknown("git push timed out after \(Int(SafeGit.seconds(timeout))) s") }
        let lines = String(decoding: result.stdout.prefix(outputCap), as: UTF8.self).split(separator: "\n")
        // `--porcelain`: `<flag>\t<from>:<to>\t<summary>`; ` ` fast-forward, `*` new, `=` up to date, `!` rejected.
        let mine = lines.first { line in
            let fields = line.split(separator: "\t")
            return fields.count >= 2 && fields[1].hasSuffix(":" + ref)
        }
        if let flag = mine?.first, [" ", "*", "="].contains(flag) {
            // Git reported the ref taken but exited non-zero: what GitHub holds is read back, never assumed either way.
            return result.status == 0 ? .pushed(remoteHead: sha) : .unknown("git push reported \(ref) but exited \(result.status)")
        }
        if let mine, mine.first == "!" {
            let summary = mine.split(separator: "\t").dropFirst(2).first.map(String.init) ?? "rejected"
            return .failed(shown(Data(summary.utf8), token: token))
        }
        if result.status == 0 { return .unknown("git push reported no result for \(ref)") }
        let lower = String(decoding: result.stderr.prefix(64 << 10), as: UTF8.self).lowercased()
        if ambiguous.contains(where: lower.contains) { return .unknown(stderr.isEmpty ? "the connection was lost" : stderr) }
        return .failed(stderr.isEmpty ? "git push failed (\(result.status))" : stderr)
    }

    /// Git's output as shown or stored: at most 64 KiB read, the token redacted, then `SafeGit`'s rule (ASCII-folded, path-like
    /// words dropped) and `maxShownError` characters.
    static func shown(_ data: Data, token: TokenHandle) -> String {
        let text = token.redact(String(decoding: data.prefix(64 << 10), as: UTF8.self))
        let noEscapes = text.replacingOccurrences(of: "\u{1b}\\[[0-9;]*[A-Za-z]", with: "", options: .regularExpression)
        return String(SafeGit.sanitizedStderr(Data(noEscapes.utf8)).prefix(maxShownError))
    }

    static func remove(_ dir: URL, under root: URL) {
        do { _ = try EngineFiles.removeNoFollow(dir, under: root) } catch {
            FileHandle.standardError.write(Data("brahma: could not remove a push call directory: \(error)\n".utf8))
        }
    }
}
