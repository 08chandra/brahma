import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The settings file: `<runDir>/<agentId>.settings.json`, written atomically at 0600 (a temporary file created `O_EXCL` 0600
/// and renamed over the target, so a link planted there is replaced, never followed). The run directory is the data home's,
/// which no turn can read or write.
public enum SettingsFile {
    public static func path(paths: BrahmaPaths, agentId: String) -> URL { paths.runDir.appending(path: "\(agentId).settings.json") }

    public static func write(_ text: String, to url: URL) throws {
        try writePrivate(Data(text.utf8), to: url)
    }

    /// `data` to `url` atomically at 0600; its directory is created 0700 when missing.
    static func writePrivate(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temp = dir.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
        let fd = open(temp.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temp.path]) }
        let bytes = [UInt8](data)
        var written = 0
        while written < bytes.count {
            let n = bytes[written...].withUnsafeBytes { Foundation.write(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            written += n
        }
        let synced = fsync(fd) == 0
        close(fd)
        guard written == bytes.count, synced, rename(temp.path, url.path) == 0 else {
            unlink(temp.path)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }
}

/// `<home>/run/.sentinel`: a file only an unsandboxed process can read. The engine writes it when it starts; the shell prefix
/// refuses every command that can read it (the sandbox denies the whole data home), so a turn whose settings were silently
/// ignored runs no command at all.
public enum Sentinel {
    public static let content = "sentinel"

    public static func write(paths: BrahmaPaths) throws {
        try SettingsFile.writePrivate(Data(content.utf8), to: paths.sentinel)
    }
}

/// The agent's Bash prefix (`CLAUDE_CODE_SHELL_PREFIX`): Claude Code runs it with one argument, the full command string. It
/// refuses when the sentinel is readable (no sandbox), scrubs secret-looking variables (except the agent's injected test keys,
/// Task 4), points `HOME`, the XDG and git config and the package caches at the agent's own places, and execs the shell.
public enum ShellPrefix {
    /// The owner's `$SHELL` when it is `/bin/zsh` or `/bin/bash`, else `/bin/zsh` (macOS) or `/bin/bash` (Linux).
    public static func shell(environment: [String: String] = ProcessInfo.processInfo.environment) -> String {
        if let s = environment["SHELL"], s == "/bin/zsh" || s == "/bin/bash" { return s }
        #if os(macOS)
        return "/bin/zsh"
        #else
        return "/bin/bash"
        #endif
    }

    /// The tools the script runs, by absolute path: never found through the PATH it inherits (fix round 1, I1), where a
    /// relative entry could hold a `cat` an agent planted.
    public static let tools: (cat: String, env: String, sed: String) = {
        #if os(macOS)
        return ("/bin/cat", "/usr/bin/env", "/usr/bin/sed")
        #else
        return ("/bin/cat", "/usr/bin/env", "/bin/sed")
        #endif
    }()

    /// The engine's own company MCP server as the prefix starts it: the executable and, baked into the fixed argv, the database,
    /// company and agent it serves (fix round 2, A-N1), so a forged env block cannot choose them; `ownerHome` is its `HOME`.
    public struct MCPServer: Equatable, Sendable {
        public var executable: String
        public var database: String
        public var companyId: String
        public var agentId: String
        public var ownerHome: String

        public init(executable: String, database: String, companyId: String, agentId: String, ownerHome: String) {
            self.executable = executable; self.database = database; self.companyId = companyId; self.agentId = agentId
            self.ownerHome = ownerHome
        }
    }

    /// The script: the brief's body, with these changes (live probes, Step 1; fix round 1):
    /// - Claude Code starts stdio MCP servers through the prefix too, outside the sandbox. A process carrying the per-turn
    ///   `BRAHMA_TURN_TOKEN` (only the company server's env block has it; never claude's own environment) is either the engine's
    ///   own server, started by the FIXED argv `<exe> mcp --db <db> --company <c> --agent <a>` under `env -i` with a fixed
    ///   allowlist (PATH, the owner's HOME, the engine's BRAHMA_AGENT_ID/HOME/WORKSPACES, and from the block only the token, a
    ///   `file` secret store, the review item and the audit flag, which the credential checks), or refused (126). The line Claude
    ///   hands over is only compared, never evaluated. Without `mcpServer` every token-carrying line is refused.
    /// - `cat`, `env` and `sed` by absolute path (`tools`).
    /// - `GIT_CONFIG_KEY_<digits>` (the git settings Claude Code injects next to `GIT_CONFIG_COUNT`) survive the scrub; nothing
    ///   else that holds `KEY` does.
    /// Every substituted value is single- or double-quoted, so one holding `'`, `"`, `\`, `$`, a backquote, a control character
    /// or `%00` is refused (`SandboxError.unsafePathCharacter`); a keep name that is not a variable name is dropped (it is then
    /// scrubbed like any other). No bracket range is used in a `case` (locale-independent); `sed`'s runs with `LC_ALL=C`.
    public static func script(layout: SandboxLayout, paths: BrahmaPaths, shell: String, keepNames: [String],
                              mcpServer: MCPServer? = nil) throws -> String {
        // The agent's places as the turn's scope names them: built under the resolved workspace.
        let ws = layout.workspace.resolvedForSandbox
        let home = ws.appending(path: layout.homeRelative).path
        let cache = ws.appending(path: "\(layout.homeRelative)/cache").path
        let sentinel = paths.sentinel.path
        let serverPaths = mcpServer.map { [$0.executable, $0.database, $0.ownerHome, paths.home.path, paths.workspaces.path] } ?? []
        for value in [home, cache, sentinel, shell] + serverPaths
        where SandboxPath.isUnsafe(value) || !value.hasPrefix("/") || value.contains("$") || value.contains("`") {
            throw SandboxError.unsafePathCharacter(value)
        }
        if let mcpServer {
            for id in [mcpServer.companyId, mcpServer.agentId]
            where id.range(of: "^[A-Za-z0-9_-]{1,64}$", options: .regularExpression) == nil {
                throw SandboxError.unsafePathCharacter(id)
            }
        }
        let keep = keepNames.filter { $0.range(of: "^[A-Za-z_][A-Za-z0-9_]*$", options: .regularExpression) != nil }
        let serverCase = mcpServer.map { m in
            let exe = m.executable
            let forms = ["\"\(exe) mcp\"", "\"\(exe) mcp \"*", "\"'\(exe)' mcp\"", "\"'\(exe)' mcp \"*", "\"'\(exe)' 'mcp'\"",
                         "\"'\(exe)' 'mcp' \"*"].joined(separator: "|")
            return """
                  case "$1" in \(forms))
                    set -- /usr/bin/env -i PATH=/usr/bin:/bin:/usr/sbin:/sbin HOME='\(m.ownerHome)' BRAHMA_AGENT_ID='\(m.agentId)' BRAHMA_HOME='\(paths.home.path)' BRAHMA_WORKSPACES='\(paths.workspaces.path)' "BRAHMA_TURN_TOKEN=$BRAHMA_TURN_TOKEN"
                    if [ "${BRAHMA_SECRET_STORE:-}" = file ]; then set -- "$@" BRAHMA_SECRET_STORE=file; fi
                    if [ -n "${BRAHMA_MCP_REVIEW_ITEM:-}" ]; then set -- "$@" "BRAHMA_MCP_REVIEW_ITEM=$BRAHMA_MCP_REVIEW_ITEM"; fi
                    if [ "${BRAHMA_MCP_AUDIT:-}" = 1 ]; then set -- "$@" BRAHMA_MCP_AUDIT=1; fi
                    exec "$@" '\(exe)' mcp --db '\(m.database)' --company '\(m.companyId)' --agent '\(m.agentId)';;
                  esac

                """
        } ?? ""
        return """
            #!/bin/sh
            if [ -n "${BRAHMA_TURN_TOKEN:-}" ]; then
            \(serverCase)  echo "brahma: refused" >&2; exit 126
            fi
            if \(tools.cat) '\(sentinel)' >/dev/null 2>&1; then echo "brahma: sandbox is not active; command refused" >&2; exit 126; fi
            \(gatewayProxyDrop)keep=' \(keep.joined(separator: " ")) '
            for n in $(\(tools.env) | LC_ALL=C \(tools.sed) -n 's/^\\([A-Za-z_][A-Za-z0-9_]*\\)=.*/\\1/p'); do
              case "$keep" in *" $n "*) continue;; esac
              case "${n#GIT_CONFIG_KEY_}" in "$n"|'') ;; *[!0123456789]*) ;; *) continue;; esac
              case "$n" in CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_*|SSH_AUTH_SOCK|AWS_*|*TOKEN*|*SECRET*|*KEY*|*token*|*secret*|*key*) unset "$n";; esac
            done
            export HOME='\(home)' XDG_CONFIG_HOME='\(home)/.config' XDG_CACHE_HOME='\(cache)/xdg'
            export GIT_CONFIG_GLOBAL='\(home)/.gitconfig' GIT_CONFIG_NOSYSTEM=1
            export npm_config_cache='\(cache)/npm' PIP_CACHE_DIR='\(cache)/pip' CARGO_HOME='\(cache)/cargo' GOMODCACHE='\(cache)/go/mod' GOPATH='\(home)/go'
            exec '\(shell)' -c "$1"

            """
    }

    /// Plan X1 Task 12 (Ruling 64): a gateway turn's `claude` runs with the four proxy variables naming its claude proxy and
    /// `NO_PROXY` the loopback names (`ClaudeGatewayCompile`). Agent Bash keeps its own network path: when the turn's marker
    /// (`BRAHMA_CLAUDE_PROXY`) is set, each proxy variable still holding the claude proxy (and each `NO_PROXY` still holding
    /// the gateway's value) gets the owner's value back from `BRAHMA_BASE_<name>`, or is unset when the owner set none; a
    /// value Claude Code's sandbox put there for the command is left alone. Then the marker and the carriers go. Every
    /// `ANTHROPIC_*` (the turn token, the gateway's base URL and model names) is unset by the scrub after it.
    static var gatewayProxyDrop: String {
        let marker = ClaudeGatewayCompile.claudeProxyMarker
        let base = ClaudeGatewayCompile.baseProxyPrefix
        func restore(_ name: String, when value: String) -> String {
            "  if [ \"${\(name):-}\" = \(value) ]; then if [ -n \"${\(base)\(name)+x}\" ]; then \(name)=\"$\(base)\(name)\"; "
                + "export \(name); else unset \(name); fi; fi\n"
        }
        let names = ClaudeGatewayCompile.proxyNames + ClaudeGatewayCompile.noProxyNames
        let lines = ClaudeGatewayCompile.proxyNames.map { restore($0, when: "\"$\(marker)\"") }
            + ClaudeGatewayCompile.noProxyNames.map { restore($0, when: "'\(ClaudeGatewayCompile.noProxy)'") }
        return "if [ -n \"${\(marker):-}\" ]; then\n" + lines.joined()
            + "  unset \(marker) \(names.map { base + $0 }.joined(separator: " "))\nfi\n"
    }

    /// The minimal prefix a Workspace or Full gateway turn's Bash runs through (Ruling 64(1)): those profiles have no
    /// sandboxed prefix, and their Bash would otherwise inherit the claude proxy and the turn token. It restores the owner's
    /// proxy values (`gatewayProxyDrop`), unsets every `ANTHROPIC_*`, and execs the shell on the command. Nothing else: Bash on
    /// these profiles is the owner's, as on a subscription turn.
    public static let gatewayPrefixName = "gateway-shell-"

    public static func gatewayScript(shell: String) throws -> String {
        guard shell.hasPrefix("/"), !SandboxPath.isUnsafe(shell), !shell.contains("$"), !shell.contains("`") else {
            throw SandboxError.unsafePathCharacter(shell)
        }
        return """
            #!/bin/sh
            \(gatewayProxyDrop)for n in $(\(tools.env) | LC_ALL=C \(tools.sed) -n 's/^\\(ANTHROPIC_[A-Za-z0-9_]*\\)=.*/\\1/p'); do unset "$n"; done
            exec '\(shell)' -c "$1"

            """
    }

    /// Writes `.brahma/bin/gateway-shell-<h>.sh` (0755) through `EngineFiles`, as `write` does the sandboxed prefix, only when
    /// its content differs. For the launcher of a Workspace or Full gateway turn (Task 14), which sets `TurnRequest.shellPrefix`
    /// to it. Blocking. Returns its path.
    @discardableResult
    public static func writeGateway(layout: SandboxLayout, shell: String) throws -> URL {
        try SandboxLayout.validate(handle: layout.handle)
        let url = layout.gatewayShellPrefix
        let prefixPath = layout.workspace.resolvedForSandbox.appending(path: layout.gatewayShellPrefixRelative).path
        for path in [prefixPath, url.path] where path.contains(where: \.isWhitespace) {
            throw SandboxError.unsafePathCharacter(path)
        }
        let data = Data(try gatewayScript(shell: shell).utf8)
        let existing = try? EngineFiles.read(workspace: layout.workspace, dir: layout.binDirRelative, name: url.lastPathComponent,
                                             limit: 64 * 1024)
        if existing != data || !isExecutable(url) {
            try EngineFiles.replace(data, workspace: layout.workspace, dir: layout.binDirRelative, name: url.lastPathComponent, mode: 0o755)
        }
        return url
    }

    /// Writes `.brahma/bin/shell-<h>.sh` (0755) through `EngineFiles` (no link on the way is followed; a link at the file is
    /// replaced), only when its content differs. Blocking. Returns its path (as the layout names it).
    @discardableResult
    public static func write(layout: SandboxLayout, paths: BrahmaPaths, shell: String, keepNames: [String],
                             mcpServer: MCPServer? = nil) throws -> URL {
        try SandboxLayout.validate(handle: layout.handle)
        // Claude Code splits `CLAUDE_CODE_SHELL_PREFIX` at whitespace (M7): the prefix's own path holds none.
        let prefixPath = layout.workspace.resolvedForSandbox.appending(path: layout.shellPrefixRelative).path
        for path in [prefixPath, layout.shellPrefix.path] where path.contains(where: \.isWhitespace) {
            throw SandboxError.unsafePathCharacter(path)
        }
        let text = try script(layout: layout, paths: paths, shell: shell, keepNames: keepNames, mcpServer: mcpServer)
        let data = Data(text.utf8)
        let name = layout.shellPrefix.lastPathComponent
        let existing = try? EngineFiles.read(workspace: layout.workspace, dir: layout.binDirRelative, name: name, limit: 64 * 1024)
        if existing != data || !isExecutable(layout.shellPrefix) {
            // Created 0755 (less whatever the owner's umask removes; the owner's own execute bit always stays).
            try EngineFiles.replace(data, workspace: layout.workspace, dir: layout.binDirRelative, name: name, mode: 0o755)
        }
        return layout.shellPrefix
    }

    /// A regular file (not a link) its owner may run.
    private static func isExecutable(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && st.st_mode & S_IFMT == S_IFREG && st.st_mode & 0o100 != 0
    }
}
