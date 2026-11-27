import Testing
import Foundation
@testable import BrahmaCore

/// A workspace with an agent layout and a data home, both in one resolved temp dir. The prefix is run with `/bin/sh <file>`
/// (a system binary), the way Claude Code runs `CLAUDE_CODE_SHELL_PREFIX` with the command as its one argument.
private struct PrefixWorld {
    let root: URL
    let paths: BrahmaPaths
    let company: Company
    let layout: SandboxLayout

    init() throws {
        root = URL(fileURLWithPath: SandboxPath.resolve(try tempDir().path), isDirectory: false)
        paths = BrahmaPaths(home: root.appending(path: "data"), workspaces: root.appending(path: "wss"))
        let ws = paths.workspaces.appending(path: "acme")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        company = Company(id: "c1", name: "Acme", slug: "acme", goal: "g", workspacePath: ws.path, status: .running,
                          usageMode: .low, priorityWeight: 1, createdAt: Date(timeIntervalSince1970: 0))
        layout = SandboxLayout(paths: paths, company: company, agentHandle: "eng-1")
    }

    var home: String { layout.agentHome.path }

    func server(_ exe: String, git: String? = "/opt/git/bin/git") -> ShellPrefix.MCPServer {
        ShellPrefix.MCPServer(executable: exe, database: paths.database.path, companyId: company.id, agentId: "a1",
                              ownerHome: "/Users/owner", git: git)
    }
    var cache: String { layout.agentCache.path }

    /// The sentinel as an unsandboxed test needs it: present but unreadable (mode 000), the way the sandbox makes it look.
    func unreadableSentinel() throws {
        try FileManager.default.createDirectory(at: paths.runDir, withIntermediateDirectories: true)
        try Data("sentinel".utf8).write(to: paths.sentinel)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: paths.sentinel.path)
    }

    func run(_ prefix: URL, _ command: String, environment: [String: String], in cwd: URL? = nil) throws -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [prefix.path, command]
        p.environment = environment
        if let cwd { p.currentDirectoryURL = cwd }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile()
        let e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: e, as: UTF8.self))
    }
}

@Suite(.scratch) struct ShellPrefixTests {
    @Test func exportsHomeAndExecsShell() throws {
        let w = try PrefixWorld()
        try w.unreadableSentinel()
        let prefix = try ShellPrefix.write(layout: w.layout, paths: w.paths, shell: "/bin/zsh", keepNames: [])
        #expect(prefix.path == w.layout.shellPrefix.path)
        let r = try w.run(prefix, "echo $HOME:$GIT_CONFIG_GLOBAL:$GIT_CONFIG_NOSYSTEM:$XDG_CACHE_HOME:$npm_config_cache:$GOPATH:$ZSH_NAME",
                          environment: ["PATH": "/usr/bin:/bin", "HOME": "/Users/owner"])
        #expect(r.status == 0, "\(r.err)")
        #expect(r.out == "\(w.home):\(w.home)/.gitconfig:1:\(w.cache)/xdg:\(w.cache)/npm:\(w.home)/go:zsh\n")
        #expect(SandboxPath.kind(prefix.path) == .file)
        #expect((try FileManager.default.attributesOfItem(atPath: prefix.path)[.posixPermissions] as? Int) == 0o755)
    }

    @Test func sentinelReadableRefuses() throws {
        let w = try PrefixWorld()
        try FileManager.default.createDirectory(at: w.paths.runDir, withIntermediateDirectories: true)
        try Data("sentinel".utf8).write(to: w.paths.sentinel)
        let prefix = try ShellPrefix.write(layout: w.layout, paths: w.paths, shell: "/bin/zsh", keepNames: [])
        let marker = w.root.appending(path: "ran")
        let r = try w.run(prefix, "touch '\(marker.path)'", environment: ["PATH": "/usr/bin:/bin"])
        #expect(r.status == 126)
        #expect(r.err.contains("sandbox is not active"))
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the command never ran")
        // No sentinel at all: the command runs (the engine writes it at start; the canary is Task 3's).
        try FileManager.default.removeItem(at: w.paths.sentinel)
        #expect(try w.run(prefix, "touch '\(marker.path)'", environment: ["PATH": "/usr/bin:/bin"]).status == 0)
        #expect(FileManager.default.fileExists(atPath: marker.path))
    }

    @Test func scrubsSecretsKeepsTestKeys() throws {
        let w = try PrefixWorld()
        try w.unreadableSentinel()
        let prefix = try ShellPrefix.write(layout: w.layout, paths: w.paths, shell: "/bin/zsh", keepNames: ["TEST_KEY"])
        let env = ["PATH": "/usr/bin:/bin", "FAKE_SECRET_TOKEN": "x", "AWS_X": "y", "SSH_AUTH_SOCK": "z", "ANTHROPIC_API_KEY": "k",
                   "CLAUDE_CODE_OAUTH_TOKEN": "t", "my_api_key": "lower", "OTHER_KEY": "o", "TEST_KEY": "v", "PLAIN": "p",
                   "GITHUB_TOKEN_X": "g"]
        let r = try w.run(prefix, "env", environment: env)
        #expect(r.status == 0, "\(r.err)")
        let names = Set(r.out.split(separator: "\n").compactMap { $0.split(separator: "=", maxSplits: 1).first.map(String.init) })
        for gone in ["FAKE_SECRET_TOKEN", "AWS_X", "SSH_AUTH_SOCK", "ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "my_api_key",
                     "OTHER_KEY", "GITHUB_TOKEN_X"] {
            #expect(!names.contains(gone), "\(gone) reached the command")
        }
        #expect(r.out.contains("TEST_KEY=v\n")); #expect(r.out.contains("PLAIN=p\n"))
    }

    @Test func scriptIsTheBriefsBodyAndRewrittenOnlyWhenChanged() throws {
        let w = try PrefixWorld()
        let text = try ShellPrefix.script(layout: w.layout, paths: w.paths, shell: "/bin/bash", keepNames: ["A_KEY", "B"],
                                          mcpServer: w.server("/opt/brahma/bin/brahma"))
        // Fix round 1: absolute tools (I1); the engine's MCP server by a fixed argv, never `$1` (I2); git keys by digits (M1).
        #expect(text == """
            #!/bin/sh
            if [ -n "${BRAHMA_TURN_TOKEN:-}" ]; then
              case "$1" in "/opt/brahma/bin/brahma mcp"|"/opt/brahma/bin/brahma mcp "*|"'/opt/brahma/bin/brahma' mcp"|"'/opt/brahma/bin/brahma' mcp "*|"'/opt/brahma/bin/brahma' 'mcp'"|"'/opt/brahma/bin/brahma' 'mcp' "*)
                set -- /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME='/Users/owner' BRAHMA_AGENT_ID='a1' BRAHMA_HOME='\(w.paths.home.path)' BRAHMA_WORKSPACES='\(w.paths.workspaces.path)' "BRAHMA_TURN_TOKEN=$BRAHMA_TURN_TOKEN"
                if [ "${BRAHMA_SECRET_STORE:-}" = file ]; then set -- "$@" BRAHMA_SECRET_STORE=file; fi
                if [ -n "${BRAHMA_MCP_REVIEW_ITEM:-}" ]; then set -- "$@" "BRAHMA_MCP_REVIEW_ITEM=$BRAHMA_MCP_REVIEW_ITEM"; fi
                if [ "${BRAHMA_MCP_AUDIT:-}" = 1 ]; then set -- "$@" BRAHMA_MCP_AUDIT=1; fi
                exec "$@" '/opt/brahma/bin/brahma' mcp --db '\(w.paths.database.path)' --company 'c1' --agent 'a1' --git '/opt/git/bin/git';;
              esac
              echo "brahma: refused" >&2; exit 126
            fi
            if \(ShellPrefix.tools.cat) '\(w.paths.sentinel.path)' >/dev/null 2>&1; then echo "brahma: sandbox is not active; command refused" >&2; exit 126; fi
            keep=' A_KEY B '
            for n in $(\(ShellPrefix.tools.env) | LC_ALL=C \(ShellPrefix.tools.sed) -n 's/^\\([A-Za-z_][A-Za-z0-9_]*\\)=.*/\\1/p'); do
              case "$keep" in *" $n "*) continue;; esac
              case "${n#GIT_CONFIG_KEY_}" in "$n"|'') ;; *[!0123456789]*) ;; *) continue;; esac
              case "$n" in CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_API_KEY|SSH_AUTH_SOCK|AWS_*|*TOKEN*|*SECRET*|*KEY*|*token*|*secret*|*key*) unset "$n";; esac
            done
            export HOME='\(w.home)' XDG_CONFIG_HOME='\(w.home)/.config' XDG_CACHE_HOME='\(w.cache)/xdg'
            export GIT_CONFIG_GLOBAL='\(w.home)/.gitconfig' GIT_CONFIG_NOSYSTEM=1
            export npm_config_cache='\(w.cache)/npm' PIP_CACHE_DIR='\(w.cache)/pip' CARGO_HOME='\(w.cache)/cargo' GOMODCACHE='\(w.cache)/go/mod' GOPATH='\(w.home)/go'
            exec '/bin/bash' -c "$1"

            """)
        let url = try ShellPrefix.write(layout: w.layout, paths: w.paths, shell: "/bin/zsh", keepNames: [])
        let before = try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int
        _ = try ShellPrefix.write(layout: w.layout, paths: w.paths, shell: "/bin/zsh", keepNames: [])
        #expect(try FileManager.default.attributesOfItem(atPath: url.path)[.systemFileNumber] as? Int == before, "unchanged: not rewritten")
        _ = try ShellPrefix.write(layout: w.layout, paths: w.paths, shell: "/bin/bash", keepNames: [])
        #expect(try String(contentsOf: url, encoding: .utf8).contains("exec '/bin/bash' -c"))
        // A link planted at the prefix is replaced, never followed.
        let target = w.root.appending(path: "target.sh")
        try Data("echo planted".utf8).write(to: target)
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createSymbolicLink(atPath: url.path, withDestinationPath: target.path)
        _ = try ShellPrefix.write(layout: w.layout, paths: w.paths, shell: "/bin/bash", keepNames: [])
        #expect(SandboxPath.kind(url.path) == .file)
        #expect(try String(contentsOf: target, encoding: .utf8) == "echo planted")
    }

    /// Live probe (a), reworked (fix round 1, I2): Claude Code starts its stdio MCP servers through the prefix, unsandboxed. With
    /// the server's per-turn token present, a line that is the engine's MCP command runs the FIXED argv `<exe> mcp` (the server
    /// reads its parameters from its env block); `$1` is never evaluated, so nothing on it runs. Any other line: refused.
    @Test func engineMCPServerRunsAFixedArgv() throws {
        let w = try PrefixWorld()
        try FileManager.default.createDirectory(at: w.paths.runDir, withIntermediateDirectories: true)
        try Data("sentinel".utf8).write(to: w.paths.sentinel)   // readable: no sandbox, as for an MCP server
        let exe = try FakeTools.script("brahma", """
            echo "args:$*"
            /usr/bin/env | /usr/bin/sort | /usr/bin/grep -v -e '^PWD=' -e '^SHLVL=' -e '^_=' -e '^OLDPWD='
            """)
        let server = w.server(exe.path)
        let prefix = try ShellPrefix.write(layout: w.layout, paths: w.paths, shell: "/bin/zsh", keepNames: [], mcpServer: server)
        // Fix round 2 (A-N1): the server's identity is baked into the argv, and only a fixed allowlist of variables reaches it
        // (`env -i`): a forged env block cannot choose the database, company, agent, data home or a preload library.
        let env = ["PATH": "/usr/bin:/bin", "BRAHMA_TURN_TOKEN": "tok", "HOME": "/Users/forged", "CLAUDE_CODE_OAUTH_TOKEN": "o",
                   "ANTHROPIC_API_KEY": "k", "BRAHMA_MCP_DB": "/agent/fake.sqlite", "BRAHMA_MCP_COMPANY": "other",
                   "BRAHMA_MCP_AGENT": "other", "BRAHMA_HOME": "/agent/home", "BRAHMA_AGENT_ID": "other", "LD_PRELOAD": "/agent/x.so",
                   "BRAHMA_SECRET_STORE": "file", "BRAHMA_MCP_REVIEW_ITEM": "K-1"]
        let expected = """
            args:mcp --db \(w.paths.database.path) --company c1 --agent a1 --git /opt/git/bin/git
            BRAHMA_AGENT_ID=a1
            BRAHMA_HOME=\(w.paths.home.path)
            BRAHMA_MCP_REVIEW_ITEM=K-1
            BRAHMA_SECRET_STORE=file
            BRAHMA_TURN_TOKEN=tok
            BRAHMA_WORKSPACES=\(w.paths.workspaces.path)
            HOME=/Users/owner
            PATH=/usr/bin:/bin:/usr/sbin:/sbin

            """
        let marker = w.root.appending(path: "rode-along")
        for form in ["\(exe.path) mcp --db x", "'\(exe.path)' mcp --db x", "'\(exe.path)' 'mcp' '--db' 'x'", "\(exe.path) mcp",
                     "\(exe.path) mcp --db x; touch '\(marker.path)'", "\(exe.path) mcp $(touch \(marker.path))"] {
            let r = try w.run(prefix, form, environment: env)
            #expect(r.status == 0, "\(form): \(r.err)")
            #expect(r.out == expected, "\(form): \(r.out)")
        }
        // Only `file` passes as the secret store, and the audit flag only as `1`.
        let quiet = try w.run(prefix, "\(exe.path) mcp", environment: ["BRAHMA_TURN_TOKEN": "tok", "BRAHMA_SECRET_STORE": "memory",
                                                                          "BRAHMA_MCP_AUDIT": "yes"])
        #expect(!quiet.out.contains("BRAHMA_SECRET_STORE")); #expect(!quiet.out.contains("BRAHMA_MCP_AUDIT"))
        let audit = try w.run(prefix, "\(exe.path) mcp", environment: ["BRAHMA_TURN_TOKEN": "tok", "BRAHMA_MCP_AUDIT": "1"])
        #expect(audit.out.contains("BRAHMA_MCP_AUDIT=1\n"))
        #expect(!FileManager.default.fileExists(atPath: marker.path), "nothing on the line ever runs")
        // Token set, any other line (Claude's own Bash wrapper shape included): refused, whatever the sentinel says.
        try w.unreadableSentinel()
        for line in ["/bin/echo hi", "\(exe.path)x mcp", "true; \(exe.path) mcp", "\(exe.path) mcp\ntouch \(marker.path)",
                     "source /tmp/snap.sh 2>/dev/null || true && eval '\(exe.path) mcp' < /dev/null && pwd -P >| /tmp/cwd"] {
            #expect(try w.run(prefix, line, environment: env).status == 126, "\(line)")
        }
        // Without the token the line is an ordinary command (sandbox, scrub, agent HOME).
        let plain = try w.run(prefix, "/bin/echo $HOME", environment: ["PATH": "/usr/bin:/bin", "HOME": "/Users/owner"])
        #expect(plain.out == "\(w.home)\n")
        // No MCP server named: a token-carrying line is refused.
        let none = try ShellPrefix.write(layout: w.layout, paths: w.paths, shell: "/bin/zsh", keepNames: [])
        #expect(try w.run(none, "\(exe.path) mcp", environment: env).status == 126)
        #expect(throws: SandboxError.self) {
            _ = try ShellPrefix.script(layout: w.layout, paths: w.paths, shell: "/bin/zsh", keepNames: [], mcpServer: w.server("/x/$(id)/brahma"))
        }
        var odd = w.server(exe.path); odd.companyId = "c'1"
        #expect(throws: SandboxError.self) {
            _ = try ShellPrefix.script(layout: w.layout, paths: w.paths, shell: "/bin/zsh", keepNames: [], mcpServer: odd)
        }
        // Ruling S5-4 (B9): the engine's git rides in the fixed argv, single-quoted; one that could break out of the quotes (or
        // is not absolute) refuses the prefix, and an engine with no git passes no `--git` (the server's git then refuses).
        for bad in ["/opt/gi't/git", "/opt/$(id)/git", "/opt/`id`/git", "git", "/opt/g\u{0}it"] {
            #expect(throws: SandboxError.self, "\(bad)") {
                _ = try ShellPrefix.script(layout: w.layout, paths: w.paths, shell: "/bin/zsh", keepNames: [], mcpServer: w.server(exe.path, git: bad))
            }
        }
        let noGit = try ShellPrefix.script(layout: w.layout, paths: w.paths, shell: "/bin/zsh", keepNames: [], mcpServer: w.server(exe.path, git: nil))
        #expect(!noGit.contains("--git"))
        #expect(noGit.contains("--agent 'a1';;"))
    }

    /// I1: the sentinel check's tools come by absolute path, never through the inherited PATH (a `cat` the agent planted in
    /// a relative PATH entry cannot fake an unreadable sentinel).
    @Test func plantedCatOnPathCannotDefeatTheSentinel() throws {
        let w = try PrefixWorld()
        try FileManager.default.createDirectory(at: w.paths.runDir, withIntermediateDirectories: true)
        try Data("sentinel".utf8).write(to: w.paths.sentinel)   // readable: the sandbox is not active
        let cwd = try tempDir()
        for tool in ["cat", "env", "sed"] { try FakeTools.install(at: cwd.appending(path: "bin/\(tool)"), "exit 1") }
        let prefix = try ShellPrefix.write(layout: w.layout, paths: w.paths, shell: "/bin/zsh", keepNames: [])
        let marker = w.root.appending(path: "ran")
        let r = try w.run(prefix, "/usr/bin/touch '\(marker.path)'", environment: ["PATH": "bin:/usr/bin:/bin"], in: cwd)
        #expect(r.status == 126, "\(r.err)")
        #expect(!FileManager.default.fileExists(atPath: marker.path))
    }

    /// Live probe (d): git needs the `GIT_CONFIG_KEY_<n>` Claude Code injects next to `GIT_CONFIG_COUNT`.
    @Test func gitConfigKeysSurviveTheScrub() throws {
        let w = try PrefixWorld()
        try w.unreadableSentinel()
        let prefix = try ShellPrefix.write(layout: w.layout, paths: w.paths, shell: "/bin/zsh", keepNames: [])
        let r = try w.run(prefix, "env", environment: ["PATH": "/usr/bin:/bin", "GIT_CONFIG_COUNT": "1",
                                                        "GIT_CONFIG_KEY_0": "safe.directory", "GIT_CONFIG_VALUE_0": "/x",
                                                        "GIT_CONFIG_KEY_X": "secretish", "GIT_CONFIG_KEY_0X": "s",
                                                        "GIT_CONFIG_KEY_0_SECRET_TOKEN": "s", "GIT_CONFIG_KEY_": "s"])
        #expect(r.out.contains("GIT_CONFIG_KEY_0=safe.directory\n")); #expect(r.out.contains("GIT_CONFIG_COUNT=1\n"))
        #expect(!r.out.contains("GIT_CONFIG_KEY_X")); #expect(!r.out.contains("GIT_CONFIG_KEY_0X"))
        #expect(!r.out.contains("GIT_CONFIG_KEY_0_SECRET_TOKEN")); #expect(!r.out.contains("GIT_CONFIG_KEY_="))
    }

    @Test func keepNamesMustBeVariableNames() throws {
        let w = try PrefixWorld()
        let text = try ShellPrefix.script(layout: w.layout, paths: w.paths, shell: "/bin/zsh", keepNames: ["GOOD_KEY", "bad name", "x'y", "1X", "*"])
        #expect(text.contains("keep=' GOOD_KEY '\n"))
    }

    @Test func unsafePathsRefused() throws {
        let root = try tempDir()
        let paths = BrahmaPaths(home: root.appending(path: "da'ta"), workspaces: root)
        let company = Company(id: "c1", name: "Acme", slug: "acme", goal: "g", workspacePath: root.appending(path: "acme").path,
                              status: .running, usageMode: .low, priorityWeight: 1, createdAt: Date(timeIntervalSince1970: 0))
        let layout = SandboxLayout(paths: paths, company: company, agentHandle: "eng-1")
        #expect(throws: SandboxError.self) { _ = try ShellPrefix.script(layout: layout, paths: paths, shell: "/bin/zsh", keepNames: []) }
        let ok = BrahmaPaths(home: root.appending(path: "data"), workspaces: root)
        #expect(throws: SandboxError.self) { _ = try ShellPrefix.script(layout: layout, paths: ok, shell: "/bin/z'sh", keepNames: []) }
    }

    /// M7: Claude splits `CLAUDE_CODE_SHELL_PREFIX` at whitespace (` -`): a prefix path holding any is refused.
    @Test func prefixPathWithWhitespaceRefused() throws {
        let root = URL(fileURLWithPath: SandboxPath.resolve(try tempDir().path), isDirectory: false)
        let paths = BrahmaPaths(home: root.appending(path: "data"), workspaces: root.appending(path: "Work -Projects"))
        let ws = paths.workspaces.appending(path: "acme")
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let company = Company(id: "c1", name: "Acme", slug: "acme", goal: "g", workspacePath: ws.path, status: .running,
                              usageMode: .low, priorityWeight: 1, createdAt: Date(timeIntervalSince1970: 0))
        let layout = SandboxLayout(paths: paths, company: company, agentHandle: "eng-1")
        #expect(throws: SandboxError.self) { _ = try ShellPrefix.write(layout: layout, paths: paths, shell: "/bin/zsh", keepNames: []) }
    }

    @Test func shellIsTheOwnersZshOrBash() {
        #expect(ShellPrefix.shell(environment: ["SHELL": "/bin/bash"]) == "/bin/bash")
        #expect(ShellPrefix.shell(environment: ["SHELL": "/bin/zsh"]) == "/bin/zsh")
        #if os(macOS)
        #expect(ShellPrefix.shell(environment: ["SHELL": "/opt/homebrew/bin/fish"]) == "/bin/zsh")
        #expect(ShellPrefix.shell(environment: [:]) == "/bin/zsh")
        #else
        #expect(ShellPrefix.shell(environment: ["SHELL": "/usr/bin/fish"]) == "/bin/bash")
        #endif
    }

    @Test func engineStartWritesTheSentinel() async throws {
        let root = try tempDir()
        let paths = BrahmaPaths(home: root.appending(path: "home"), workspaces: root.appending(path: "ws"))
        try Sentinel.write(paths: paths)
        #expect(try String(contentsOf: paths.sentinel, encoding: .utf8) == "sentinel")
        #expect((try FileManager.default.attributesOfItem(atPath: paths.sentinel.path)[.posixPermissions] as? Int) == 0o600)
        try Sentinel.write(paths: paths)
        // And the orchestrator writes it when it starts.
        let w = try World()
        try? FileManager.default.removeItem(at: w.paths.sentinel)
        try await w.orchestrator.start()
        #expect(try String(contentsOf: w.paths.sentinel, encoding: .utf8) == "sentinel")
        #expect((try FileManager.default.attributesOfItem(atPath: w.paths.sentinel.path)[.posixPermissions] as? Int) == 0o600)
    }
}
