import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// The Claude Code settings every turn runs with (`--settings <file>`, `--setting-sources ""`): a typed mirror of the keys
// verified on 2.1.306 (plan §"What was verified"), compiled from the turn's `SandboxScope`, profile and mode. The sandbox block
// is what makes the Sandboxed profile real for the agent's own Bash; the permission rules are defense in depth for the
// built-in file tools. In `-p` mode an invalid settings file is silently ignored, so Task 3's canary gates scheduling by this
// file's `shape()`, and the shell prefix's sentinel is the per-command backstop.

/// One hook command, always in exec form (`{"type": "command", "command": <executable>, "args": [...]}`). Claude Code wraps a
/// shell-form hook in `CLAUDE_CODE_SHELL_PREFIX` and runs it outside the sandbox, so the prefix would refuse it and a
/// PreToolUse hook would fail open (1b fix round 1, C1); an exec-form hook is run directly. `onFailure: "block"` keeps a hook
/// that cannot run from letting the call through. Both verified live on 2.1.312 (`Doctor.minimumVersion`).
public struct HookCommand: Codable, Equatable, Sendable {
    public var type: String
    /// The executable (one path, no shell words).
    public var command: String
    public var args: [String]
    public var onFailure: String?

    public init(command: String, args: [String], onFailure: String? = "block") {
        type = "command"; self.command = command; self.args = args; self.onFailure = onFailure
    }
}

/// One `hooks.<Event>` entry: a tool-name matcher and the commands it runs.
public struct HookMatcher: Codable, Equatable, Sendable {
    public var matcher: String
    public var hooks: [HookCommand]

    public init(matcher: String, hooks: [HookCommand]) { self.matcher = matcher; self.hooks = hooks }
}

/// The settings file of one turn. Encoded with sorted keys; nil fields are omitted.
public struct ClaudeSettings: Codable, Equatable, Sendable {
    public struct Permissions: Codable, Equatable, Sendable {
        public var allow: [String]?
        public var deny: [String]?
        public init(allow: [String]? = nil, deny: [String]? = nil) { self.allow = allow; self.deny = deny }
    }

    public struct Filesystem: Codable, Equatable, Sendable {
        public var allowWrite: [String]?
        public var denyWrite: [String]?
        public var denyRead: [String]?
        public var allowRead: [String]?
        public init(allowWrite: [String]? = nil, denyWrite: [String]? = nil, denyRead: [String]? = nil, allowRead: [String]? = nil) {
            self.allowWrite = allowWrite; self.denyWrite = denyWrite; self.denyRead = denyRead; self.allowRead = allowRead
        }
    }

    public struct Network: Codable, Equatable, Sendable {
        public var allowedDomains: [String]?
        public var allowLocalBinding: Bool?
        public var allowAllUnixSockets: Bool?
        /// The turn's own mach global name (Task 2's unremovable marker, adopted for turns): allowed by the turn's sandbox and
        /// answered by no service, so the engine recognizes the turn's processes by their sandbox alone (`SandboxProbe`).
        public var allowMachLookup: [String]?
        public init(allowedDomains: [String]? = nil, allowLocalBinding: Bool? = nil, allowAllUnixSockets: Bool? = nil,
                    allowMachLookup: [String]? = nil) {
            self.allowedDomains = allowedDomains; self.allowLocalBinding = allowLocalBinding; self.allowAllUnixSockets = allowAllUnixSockets
            self.allowMachLookup = allowMachLookup
        }
    }

    public struct Sandbox: Codable, Equatable, Sendable {
        public var enabled: Bool?
        public var failIfUnavailable: Bool?
        public var autoAllowBashIfSandboxed: Bool?
        public var allowUnsandboxedCommands: Bool?
        public var filesystem: Filesystem?
        public var network: Network?
        public init(enabled: Bool? = nil, failIfUnavailable: Bool? = nil, autoAllowBashIfSandboxed: Bool? = nil,
                    allowUnsandboxedCommands: Bool? = nil, filesystem: Filesystem? = nil, network: Network? = nil) {
            self.enabled = enabled; self.failIfUnavailable = failIfUnavailable; self.autoAllowBashIfSandboxed = autoAllowBashIfSandboxed
            self.allowUnsandboxedCommands = allowUnsandboxedCommands; self.filesystem = filesystem; self.network = network
        }
    }

    public var disableBundledSkills: Bool?
    public var enabledPlugins: [String: Bool]?
    public var disableSkillShellExecution: Bool?
    // Work-mode keys (F1).
    public var enableWorkflows: Bool?
    public var disableWorkflows: Bool?
    public var workflowSizeGuideline: String?
    public var workflowKeywordTriggerEnabled: Bool?
    public var maxEffortLevel: String?
    public var fastMode: Bool?
    public var plansDirectory: String?
    public var availableModels: [String]?
    /// Standing Ultra. Declared only so a test can assert it is never emitted; nothing sets it.
    public var ultracode: Bool?
    public var permissions: Permissions?
    public var sandbox: Sandbox?
    public var hooks: [String: [HookMatcher]]?

    public init() {}

    /// Compact JSON, keys sorted, slashes unescaped: the bytes of the settings file. Throws rather than ever producing a
    /// smaller file (an empty one would be an unsandboxed turn).
    public func json() throws -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return String(decoding: try encoder.encode(self), as: UTF8.self)
    }

    /// The `StableHash` of the JSON with every string replaced by `"s"` and every array cut to its first element: equal for
    /// two turns whose settings differ only in paths, domains or counts, different when a key appears or disappears.
    public func shape() -> String {
        func reduce(_ v: JSONValue) -> JSONValue {
            switch v {
            case .string: .string("s")
            case .array(let a): .array(a.prefix(1).map(reduce))
            case .object(let o): .object(o.mapValues(reduce))
            default: v
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(self), let value = try? JSONDecoder().decode(JSONValue.self, from: data),
              let reduced = try? encoder.encode(reduce(value)) else { return StableHash.fnv1a64("") }
        return StableHash.fnv1a64(reduced)
    }
}

/// The built-in tools a turn may have (`--tools`, F1): the init names on 2.1.306. 3a's `--allowed-tools` still lists `Glob`
/// and `Grep`; they are harmless there and never added here (2.1.306 has neither).
public enum BuiltinTools {
    /// Quick, Standard and Deep work turns: no `Task`.
    public static let sandboxed: [String] = ["Bash", "Read", "Edit", "Write", "NotebookEdit", "Skill", "ToolSearch", "WebFetch", "WebSearch"]
    /// Only once the sub-agent gate has passed (Task 14u). Until custom Brahma agent types are verified (F7), a Task turn
    /// drops `WebFetch` and `WebSearch` (`taskTurn`).
    public static let withTask: [String] = sandboxed + ["Task"]
    public static let plan: [String] = sandboxed.filter { $0 != "Edit" && $0 != "NotebookEdit" }
    /// Task 14u, once F7-agents passed (only Brahma's worker agent types load).
    public static let ultra: [String] = sandboxed + ["Task", "Workflow"]
    /// An Ultra turn before F7-agents passed (fix round 1, I1): no web tools and no Task; its fan-out is the Workflow tool's.
    public static let ultraBeforeF7: [String] = sandboxed.filter { $0 != "WebFetch" && $0 != "WebSearch" } + ["Workflow"]
    public static let review: [String] = ["Bash", "Read", "Skill", "ToolSearch"]

    /// `withTask` without the web tools: the Task turn until F7 passes.
    static let taskTurn: [String] = withTask.filter { $0 != "WebFetch" && $0 != "WebSearch" }
}

public enum ClaudeSettingsCompiler {
    /// The bundled plugins `disableBundledSkills` leaves on; both are turned off by name.
    public static let disabledBuiltinPlugins: [String: Bool] = ["cc-plugin-agents-md@builtin": false,
                                                                "cc-plugin-plugin-authoring@builtin": false]
    /// Nested `claude` (F1), on every profile: a turn never starts another session of its own.
    public static let nestedClaudeDenies = ["Bash(claude *)", "Bash(*/claude *)"]
    /// The bundled skills left after `disableBundledSkills`, denied when `--disable-slash-commands` must go (F10).
    public static let skillDenies = ["Skill(deep-research)", "Skill(ultrareview)", "Skill(design)", "Skill(doctor)"]
    /// Prefix rules (defense in depth; the canary probes the real effect).
    public static let sandboxedBashDenies = ["Bash(launchctl *)", "Bash(security *)", "Bash(osascript *)", "Bash(open *)",
                                             "Bash(crontab *)", "Bash(at *)", "Bash(sudo *)", "Bash(screencapture *)"]
    /// Ultra (Task 14u, design §2.2): the high-authority company tools a workflow could otherwise call many times as the parent,
    /// denied outright rather than counted, and the bundled skills that would start their own fan-out.
    /// Derived from `CompanyTools.highRiskTools` (S26), so a high-risk tool added later is denied too, plus the Ultra-specific
    /// extras.
    public static var ultraMCPDenies: [String] {
        CompanyTools.highRiskTools.union(ultraExtraMCPDenies).sorted().map { "mcp__company__\($0)" }
    }
    static let ultraExtraMCPDenies: Set<String> = ["propose_extension"]
    public static let ultraSkillDenies = ["Skill(deep-research)", "Skill(ultrareview)"]
    /// The Task 10 PostToolUse hook's matcher.
    public static let postToolMatcher = "WebFetch|WebSearch|Bash|mcp__.*|Skill|Task|Agent"

    /// `<abs>` as the absolute form of a permission rule (`//<abs>`), for the path itself and everything under it.
    static func rules(_ tool: String, _ path: String) -> [String] { ["\(tool)(/\(path))", "\(tool)(/\(path)/**)"] }

    /// The settings of one turn.
    /// - `scope`: the sandboxed turn's scope (nil for the other profiles; a sandboxed profile without one compiles no sandbox
    ///   block and `TurnProfileCompiler.validate` refuses it).
    /// - `mode`: the work mode (nil for Plan 1 inputs: no `maxEffortLevel`; the workflow and fast-mode kill switches still apply).
    /// - `mounts`: the turn's extension parts (Task 5a; empty until then).
    /// - `postToolHook`: the PostToolUse hook (Task 10; nil until then), exec form. `preToolHook`: 3a's PreToolUse block (exec
    ///   form since fix round 1), merged unchanged.
    /// - `machMarker`: the sandboxed turn's mach marker (`sandbox.network.allowMachLookup`).
    /// - `kind`, `plansDirectory`: a plan turn's `plansDirectory` (the scope's cwd when the sandboxed caller names none).
    /// - `deniedPaths`: the Workspace profile's read and edit denies (the data home, the protected list, other workspaces).
    /// - `workflow`: Ultra's policy (Task 14u); Ultra compiles only on the Sandboxed profile with one.
    public static func compile(scope: SandboxScope?, profile: PermissionProfile, mode: ModeDecision?, mounts: [URL],
                               postToolHook: HookCommand?, preToolHook: HookMatcher?, kind: TurnKind = .work,
                               plansDirectory: String? = nil, deniedPaths: [URL] = [],
                               workflow: WorkflowPolicy? = nil, machMarker: String? = nil) -> ClaudeSettings {
        var s = ClaudeSettings()
        var allow: [String] = []
        var deny: [String] = []
        s.disableBundledSkills = true
        s.enabledPlugins = disabledBuiltinPlugins

        switch profile {
        case .sandboxed:
            if let scope {
                let fs = ClaudeSettings.Filesystem(
                    // The cwd is granted literally: never rely on the CLI's own write grant for its physical cwd.
                    allowWrite: dedupe([scope.cwd] + scope.writable + (scope.toolchainTempWrite.map { [$0] } ?? [])
                                       + (scope.claudeTmp.map { [$0] } ?? [])),
                    // A read-only place may also be an `--add-dir`, which can carry a write grant of the CLI's own.
                    denyWrite: dedupe(scope.denyWrite + scope.readOnlyDirs),
                    denyRead: dedupe(scope.denyRead),
                    allowRead: dedupe(scope.readable + scope.readOnlyDirs + [scope.cwd] + (scope.claudeTmp.map { [$0] } ?? [])))
                s.sandbox = ClaudeSettings.Sandbox(
                    enabled: true, failIfUnavailable: true, autoAllowBashIfSandboxed: true, allowUnsandboxedCommands: false,
                    filesystem: fs,
                    network: ClaudeSettings.Network(allowedDomains: scope.network.allowedDomains,
                                                    allowLocalBinding: scope.network.allowLocalBinding, allowAllUnixSockets: false,
                                                    allowMachLookup: machMarker.map { [$0] }))
                allow = ["Bash", "mcp__company"] + scope.network.webDomains.map { "WebFetch(domain:\($0))" }
                for p in unique(scope.protected.map(\.path)) { deny += rules("Read", p) + rules("Edit", p) }
                for d in unique((scope.readOnlyDirs + scope.denyWrite).map(\.path)) { deny += rules("Edit", d) + rules("Write", d) }
                deny += sandboxedBashDenies
            }
        case .workspace:
            s.disableSkillShellExecution = true
            for p in unique(deniedPaths.map(\.path)) { deny += rules("Read", p) + rules("Edit", p) }
        case .full:
            s.disableSkillShellExecution = true
        }
        deny += nestedClaudeDenies
        if !mounts.isEmpty { deny += skillDenies }

        // Mode keys (F1). The kill switches ride on every turn; only an approved Ultra turn (14u) enables workflows.
        s.availableModels = TurnProfileCompiler.availableModels
        s.fastMode = false
        s.workflowKeywordTriggerEnabled = false
        if let mode { s.maxEffortLevel = mode.maxEffortLevel.rawValue }
        if profile == .sandboxed, mode?.mode == .ultra, kind == .work, let workflow {
            s.enableWorkflows = true
            s.workflowSizeGuideline = workflow.sizeGuideline
            s.maxEffortLevel = Effort.high.rawValue
            allow.append("Workflow")
            deny += ultraMCPDenies + ultraSkillDenies
        } else {
            s.disableWorkflows = true
        }
        if kind == .plan {
            s.plansDirectory = plansDirectory ?? (profile == .sandboxed ? scope?.cwd.path : nil)
        }

        var hooks: [String: [HookMatcher]] = [:]
        if let preToolHook { hooks["PreToolUse"] = [preToolHook] }
        if let postToolHook { hooks["PostToolUse"] = [HookMatcher(matcher: postToolMatcher, hooks: [postToolHook])] }
        if !hooks.isEmpty { s.hooks = hooks }

        if !allow.isEmpty || !deny.isEmpty {
            s.permissions = ClaudeSettings.Permissions(allow: allow.isEmpty ? nil : allow, deny: deny.isEmpty ? nil : unique(deny))
        }
        return s
    }

    static func unique(_ items: [String]) -> [String] {
        var seen: Set<String> = []
        return items.filter { seen.insert($0).inserted }
    }

    /// Paths, in order, without repeats (compared as the sandbox compares them: case-insensitively on Darwin).
    static func dedupe(_ urls: [URL]) -> [String] {
        var seen: Set<String> = []
        return urls.map(\.path).filter { seen.insert(SandboxPath.key($0)).inserted }
    }
}

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
        let home = ws.appending(path: ".brahma/home/\(layout.handle)").path
        let cache = ws.appending(path: ".brahma/home/\(layout.handle)/cache").path
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
            keep=' \(keep.joined(separator: " ")) '
            for n in $(\(tools.env) | LC_ALL=C \(tools.sed) -n 's/^\\([A-Za-z_][A-Za-z0-9_]*\\)=.*/\\1/p'); do
              case "$keep" in *" $n "*) continue;; esac
              case "${n#GIT_CONFIG_KEY_}" in "$n"|'') ;; *[!0123456789]*) ;; *) continue;; esac
              case "$n" in CLAUDE_CODE_OAUTH_TOKEN|ANTHROPIC_API_KEY|SSH_AUTH_SOCK|AWS_*|*TOKEN*|*SECRET*|*KEY*|*token*|*secret*|*key*) unset "$n";; esac
            done
            export HOME='\(home)' XDG_CONFIG_HOME='\(home)/.config' XDG_CACHE_HOME='\(cache)/xdg'
            export GIT_CONFIG_GLOBAL='\(home)/.gitconfig' GIT_CONFIG_NOSYSTEM=1
            export npm_config_cache='\(cache)/npm' PIP_CACHE_DIR='\(cache)/pip' CARGO_HOME='\(cache)/cargo' GOMODCACHE='\(cache)/go/mod' GOPATH='\(home)/go'
            exec '\(shell)' -c "$1"

            """
    }

    /// Writes `.brahma/bin/shell-<h>.sh` (0755) through `EngineFiles` (no link on the way is followed; a link at the file is
    /// replaced), only when its content differs. Blocking. Returns its path (as the layout names it).
    @discardableResult
    public static func write(layout: SandboxLayout, paths: BrahmaPaths, shell: String, keepNames: [String],
                             mcpServer: MCPServer? = nil) throws -> URL {
        try SandboxLayout.validate(handle: layout.handle)
        // Claude Code splits `CLAUDE_CODE_SHELL_PREFIX` at whitespace (M7): the prefix's own path holds none.
        let prefixPath = layout.workspace.resolvedForSandbox.appending(path: ".brahma/bin/\(layout.shellPrefix.lastPathComponent)").path
        for path in [prefixPath, layout.shellPrefix.path] where path.contains(where: \.isWhitespace) {
            throw SandboxError.unsafePathCharacter(path)
        }
        let text = try script(layout: layout, paths: paths, shell: shell, keepNames: keepNames, mcpServer: mcpServer)
        let data = Data(text.utf8)
        let name = layout.shellPrefix.lastPathComponent
        let existing = try? EngineFiles.read(workspace: layout.workspace, dir: ".brahma/bin", name: name, limit: 64 * 1024)
        if existing != data || !isExecutable(layout.shellPrefix) {
            // Created 0755 (less whatever the owner's umask removes; the owner's own execute bit always stays).
            try EngineFiles.replace(data, workspace: layout.workspace, dir: ".brahma/bin", name: name, mode: 0o755)
        }
        return layout.shellPrefix
    }

    /// A regular file (not a link) its owner may run.
    private static func isExecutable(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && st.st_mode & S_IFMT == S_IFREG && st.st_mode & 0o100 != 0
    }
}
