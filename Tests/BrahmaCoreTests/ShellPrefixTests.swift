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
    var cache: String { layout.agentCache.path }

    /// The sentinel as an unsandboxed test needs it: present but unreadable (mode 000), the way the sandbox makes it look.
    func unreadableSentinel() throws {
        try FileManager.default.createDirectory(at: paths.runDir, withIntermediateDirectories: true)
        try Data("sentinel".utf8).write(to: paths.sentinel)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: paths.sentinel.path)
    }

    func run(_ prefix: URL, _ command: String, environment: [String: String]) throws -> (status: Int32, out: String, err: String) {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sh")
        p.arguments = [prefix.path, command]
        p.environment = environment
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

@Suite struct ShellPrefixTests {
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
                                          mcpExecutable: "/opt/brahma/bin/brahma")
        #expect(text == """
            #!/bin/sh
            case "${BRAHMA_TURN_TOKEN:+t}:$1" in *[!-A-Za-z0-9_./:\\ \\']*) ;; "t:/opt/brahma/bin/brahma mcp "*|"t:'/opt/brahma/bin/brahma' mcp "*|"t:'/opt/brahma/bin/brahma' 'mcp' "*) exec '/bin/bash' -c "$1";; esac
            if cat '\(w.paths.sentinel.path)' >/dev/null 2>&1; then echo "brahma: sandbox is not active; command refused" >&2; exit 126; fi
            keep=' A_KEY B '
            for n in $(env | sed -n 's/^\\([A-Za-z_][A-Za-z0-9_]*\\)=.*/\\1/p'); do
              case "$keep" in *" $n "*) continue;; esac
              case "$n" in GIT_CONFIG_KEY_[0-9]*) continue;; esac
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

    /// Live probe (a): Claude Code starts its stdio MCP servers through the prefix, unsandboxed. The engine's own server (with
    /// its per-turn token) passes; nothing else does, token or not.
    @Test func engineMCPServerPassesTheSentinel() throws {
        let w = try PrefixWorld()
        try FileManager.default.createDirectory(at: w.paths.runDir, withIntermediateDirectories: true)
        try Data("sentinel".utf8).write(to: w.paths.sentinel)   // readable: no sandbox, as for an MCP server
        let prefix = try ShellPrefix.write(layout: w.layout, paths: w.paths, shell: "/bin/zsh", keepNames: [], mcpExecutable: "/bin/echo")
        let env = ["PATH": "/usr/bin:/bin", "BRAHMA_TURN_TOKEN": "tok", "HOME": "/Users/owner"]
        for form in ["/bin/echo mcp --db x", "'/bin/echo' mcp --db x", "'/bin/echo' 'mcp' '--db' 'x'"] {
            let r = try w.run(prefix, form, environment: env)
            #expect(r.status == 0, "\(form): \(r.err)"); #expect(r.out == "mcp --db x\n", "\(form)")
        }
        // The server line is exec'd before the scrub and the HOME export (the script text test shows the order), so the server
        // keeps its token; a `$` on the line is refused like any other shell syntax.
        #expect(try w.run(prefix, "/bin/echo mcp $BRAHMA_TURN_TOKEN", environment: env).status == 126)
        // Without the token, or any other command with it: refused.
        #expect(try w.run(prefix, "/bin/echo mcp --db x", environment: ["PATH": "/usr/bin:/bin"]).status == 126)
        #expect(try w.run(prefix, "/bin/echo hi", environment: env).status == 126)
        #expect(try w.run(prefix, "/bin/echo mcpx", environment: env).status == 126)
        #expect(try w.run(prefix, "true; /bin/echo mcp ", environment: env).status == 126)
        // Nothing can ride along on the server's line.
        let marker = w.root.appending(path: "rode-along")
        for extra in ["; touch '\(marker.path)'", " && touch \(marker.path)", "\ntouch \(marker.path)", " $(touch \(marker.path))",
                      " `touch \(marker.path)`", " | touch \(marker.path)", " > \(marker.path)"] {
            #expect(try w.run(prefix, "/bin/echo mcp x" + extra, environment: env).status == 126, "\(extra)")
        }
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        // No MCP executable named: nothing passes.
        let plain = try ShellPrefix.write(layout: w.layout, paths: w.paths, shell: "/bin/zsh", keepNames: [])
        #expect(try w.run(plain, "/bin/echo mcp --db x", environment: env).status == 126)
        #expect(throws: SandboxError.self) {
            _ = try ShellPrefix.script(layout: w.layout, paths: w.paths, shell: "/bin/zsh", keepNames: [], mcpExecutable: "/x/$(id)/brahma")
        }
    }

    /// Live probe (d): git needs the `GIT_CONFIG_KEY_<n>` Claude Code injects next to `GIT_CONFIG_COUNT`.
    @Test func gitConfigKeysSurviveTheScrub() throws {
        let w = try PrefixWorld()
        try w.unreadableSentinel()
        let prefix = try ShellPrefix.write(layout: w.layout, paths: w.paths, shell: "/bin/zsh", keepNames: [])
        let r = try w.run(prefix, "env", environment: ["PATH": "/usr/bin:/bin", "GIT_CONFIG_COUNT": "1",
                                                        "GIT_CONFIG_KEY_0": "safe.directory", "GIT_CONFIG_VALUE_0": "/x",
                                                        "GIT_CONFIG_KEY_X": "secretish"])
        #expect(r.out.contains("GIT_CONFIG_KEY_0=safe.directory\n")); #expect(r.out.contains("GIT_CONFIG_COUNT=1\n"))
        #expect(!r.out.contains("GIT_CONFIG_KEY_X"))
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
