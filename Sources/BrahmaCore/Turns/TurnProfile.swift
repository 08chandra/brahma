import Foundation

/// Everything that decides how one `claude -p` turn is launched. `TurnProfileCompiler` is the only place that
/// turns it into argv, settings and the engine-set child environment.
public struct TurnProfile: Equatable, Sendable {
    public enum Session: Equatable, Sendable {
        case start(id: String, systemPrompt: String?)
        /// The system prompt is passed on resume too (byte-identical), so the cacheable prefix never changes.
        case resume(id: String, systemPrompt: String?)
    }

    public var model: String
    public var fallbackModel = "sonnet"
    public var session: Session
    public var mcpConfigPath: String
    public var permission: PermissionProfile
    public var workingDirectory: String
    public var addDirs: [String]
    public var allowedTools = ["Bash", "Read", "Edit", "Write", "Glob", "Grep", "mcp__company"]
    public var disallowedTools = ClaudeCommand.disallowedTools
    /// The turn's settings (the typed mirror `ClaudeSettingsCompiler` compiles; 3a's `extraSettings` dictionary before 5-lite).
    public var settings = ClaudeSettings()
    public var disableSlashCommands = true
    /// `BRAHMA_*` variables plus the engine's `CLAUDE_CODE_*` controls (`ChildEnvironment.engineClaudeVars`).
    public var environment: [String: String] = [:]
    /// Replaces the permission mode of the profile (a plan turn runs in `plan` mode).
    public var permissionModeOverride: String? = nil
    /// How long the turn may run before the engine kills it. Nil: the runner's `maxTurnDuration` (900 s, the Plan 1
    /// fallback); the work modes set it per mode. It is not an argument of the command.
    public var wallClock: Duration? = nil
    public var expectations: TurnExpectations? = nil

    // Work modes (Task 14c). All nil for Plan 1 inputs, which compile byte-identically.
    public var mode: WorkMode? = nil
    /// `--effort`.
    public var effort: Effort? = nil
    /// Settings `maxEffortLevel`: the cap on the main loop's effort.
    public var maxEffortLevel: Effort? = nil
    /// `--max-turns` (a hidden flag: the doctor's mode-canary checks this CLI still knows it).
    public var maxTurns: Int? = nil
    /// `--max-budget-usd`, in `total_cost_usd` list-equivalent dollars.
    public var maxBudgetUSD: Double? = nil
    public var subagents: SubagentPolicy = .off
    /// Ultra's Workflow policy (5-lite). Always nil in 3a: every 3a turn sets the workflow kill switches.
    public var workflow: WorkflowPolicy? = nil
    /// The per-turn MCP quotas (recorded on the turn's credential row, never in argv or an environment).
    public var quotas: ModeQuotas? = nil
    /// `<quoted brahma> hook pre-tool`: the engine's PreToolUse hook on `Agent|Task|Workflow`, on every mode turn.
    public var hookExecutable: String? = nil
    /// That hook as the settings carry it (`hooks.PreToolUse`), built by `apply`.
    public var preToolHook: HookMatcher? = nil

    // Sandboxed profile (5-lite Task 1b).
    /// When set, `--settings <path>` names this file (which holds `settingsJSON(_:)`) instead of carrying the JSON inline.
    public var settingsFilePath: String? = nil
    /// `--restricted`: only the built-in tools `tools` names, file tools confined to the cwd and `--add-dir`.
    public var restricted = false
    /// `--tools`.
    public var tools: [String]? = nil
    /// `--permission-prompts` (`none`: anything that would prompt is denied).
    public var permissionPrompts: String? = nil
    /// `--plugin-dir`, one per mounted extension part (Task 5a).
    public var pluginDirs: [String] = []

    public init(model: String, session: Session, mcpConfigPath: String, permission: PermissionProfile,
                workingDirectory: String, addDirs: [String] = []) {
        self.model = model
        self.session = session
        self.mcpConfigPath = mcpConfigPath
        self.permission = permission
        self.workingDirectory = workingDirectory
        self.addDirs = addDirs
    }
}

/// Ultra's workflow settings (Plan 5-lite, design §2.3). Declared so the profile has the slot; nothing in 3a sets it.
public struct WorkflowPolicy: Equatable, Sendable {
    public var sizeGuideline: String
    public var maxConcurrentAgents: Int
}

public enum TurnProfileError: Error, Equatable, CustomStringConvertible {
    case modelNotAllowed(String)
    /// A Sandboxed turn missing part of its sandbox: it never starts.
    case sandboxIncomplete(String)

    public var description: String {
        switch self {
        case .modelNotAllowed(let m): ModelAllowlist.refusal(m)
        case .sandboxIncomplete(let why): "sandbox scope: the sandboxed turn is incomplete (\(why)); it was not started"
        }
    }
}

public enum TurnProfileCompiler {
    /// The settings keys every mode turn carries (design §2.3).
    public static let availableModels = ["haiku", "sonnet", "opus"]
    public static let hookMatcher = "Agent|Task|Workflow"
    static let subagentTools = ["Task", "Agent"]

    public static func profile(for r: TurnRequest) -> TurnProfile {
        let session: TurnProfile.Session = r.agent.sessionStarted
            ? .resume(id: r.agent.sessionId, systemPrompt: r.appendSystemPrompt)
            : .start(id: r.agent.sessionId, systemPrompt: r.appendSystemPrompt)
        var p = TurnProfile(model: r.mode?.model ?? r.agent.model, session: session, mcpConfigPath: r.mcpConfigPath,
                            permission: r.profile, workingDirectory: r.workingDirectory,
                            addDirs: r.addDirs.isEmpty ? [r.company.workspacePath] : r.addDirs)
        p.environment = r.environment
        p.wallClock = r.wallClock
        p.expectations = r.expectations
        if r.kind == .plan {
            // Plan mode alone is not trusted (the engine checks the checkout afterwards). The turn may only read: no editing
            // tool, no shell, no file writes. Its plan is its result text (or a file the CLI's plan mode puts into the plans
            // directory, the only extra directory it may touch).
            p.permissionModeOverride = "plan"
            p.allowedTools = ["Read", "Glob", "Grep", "mcp__company"]
            for name in ["Edit", "MultiEdit", "NotebookEdit", "Write", "Bash"] where !p.disallowedTools.contains(name) {
                p.disallowedTools.append(name)
            }
            if let dir = r.planDirectory { p.addDirs = [dir] }
        }
        if let d = r.mode { apply(d, to: &p, hookExecutable: r.hookExecutable, kind: r.kind) }
        p = restricted(p, for: r.kind)
        // F10: `--disable-slash-commands` stays unless extension parts mount (then the Skill denies replace it).
        p.disableSlashCommands = r.mounts.isEmpty
        p.pluginDirs = r.mounts.map(\.path)
        p.settingsFilePath = r.settingsFilePath
        if r.profile == .sandboxed { sandboxed(r, &p) }
        p.settings = ClaudeSettingsCompiler.compile(
            scope: r.profile == .sandboxed ? r.sandbox : nil, profile: r.profile, mode: r.mode, mounts: r.mounts,
            postToolHook: r.postToolHook, preToolHook: p.preToolHook, kind: r.kind, plansDirectory: r.planDirectory,
            deniedPaths: r.profile == .workspace ? r.deniedPaths : [], workflow: r.workflow,
            machMarker: r.profile == .sandboxed ? r.containmentMarker : nil)
        return p
    }

    /// The Sandboxed profile's part of a profile: `--restricted`, the mode's built-in tools, no prompts, the scope's cwd and
    /// read-only directories, and the shell prefix. Without a scope the cwd and directories are left as they are and
    /// `validate` refuses the profile.
    static func sandboxed(_ r: TurnRequest, _ p: inout TurnProfile) {
        p.restricted = true
        p.permissionPrompts = "none"
        if r.kind.isReview {
            p.tools = BuiltinTools.review
        } else if r.kind == .plan {
            p.tools = BuiltinTools.plan
        } else if p.subagents != .off {
            // Only once the sub-agent gate passed (14u); no web tools until F7.
            p.tools = BuiltinTools.taskTurn
        } else {
            p.tools = BuiltinTools.sandboxed
        }
        if let scope = r.sandbox {
            p.workingDirectory = scope.cwd.path
            p.addDirs = scope.readOnlyDirs.map(\.path)
            // Claude's own temp files (its TMPDIR) in the agent's home, not the shared `/tmp/claude-<uid>`.
            if let tmp = scope.claudeTmp { p.environment["CLAUDE_CODE_TMPDIR"] = tmp.path }
        }
        if let prefix = r.shellPrefix { p.environment["CLAUDE_CODE_SHELL_PREFIX"] = prefix }
    }

    /// The work-mode part of a profile (design §2.3): `--effort`, `--max-turns`, `--max-budget-usd`, the common settings keys
    /// (`availableModels`, `fastMode:false`, `workflowKeywordTriggerEnabled:false`, `disableWorkflows:true`, `maxEffortLevel`, the
    /// pre-tool hook), the kill-switch environment and, only once the sub-agent gate passes, the forced sub-agent controls.
    static func apply(_ d: ModeDecision, to p: inout TurnProfile, hookExecutable: String?, kind: TurnKind,
                      perModeCaps: Bool = ModeGates.perModeCaps) {
        p.mode = d.mode
        p.effort = d.effort
        p.maxEffortLevel = d.maxEffortLevel
        // `--max-turns` and `--max-budget-usd` only while probe L-4 holds (the cap is per process, the total cumulative).
        if perModeCaps {
            p.maxTurns = d.maxTurns
            p.maxBudgetUSD = d.maxBudgetUSD
        }
        p.wallClock = p.wallClock ?? d.wallClock
        p.quotas = d.quotas
        p.hookExecutable = hookExecutable
        p.subagents = kind.isReview || kind == .plan ? .off : d.subagents
        // The settings keys (`availableModels`, `fastMode`, the workflow kill switches, `maxEffortLevel`) are compiled from the
        // decision by `ClaudeSettingsCompiler`; the pre-tool hook block is built here and merged in unchanged.
        if let hookExecutable {
            p.preToolHook = preToolHook(executable: hookExecutable, mode: d.mode, subagents: p.subagents != .off)
        }
        p.environment["CLAUDE_CODE_DISABLE_FAST_MODE"] = "1"
        p.environment["CLAUDE_CODE_DISABLE_WORKFLOWS"] = "1"
        if case .forced(let model, let depth, let concurrent) = p.subagents {
            p.disallowedTools.removeAll { subagentTools.contains($0) }
            if !p.allowedTools.contains("Task") { p.allowedTools.append("Task") }
            p.environment["CLAUDE_CODE_SUBAGENT_MODEL"] = model
            p.environment["CLAUDE_CODE_SUBAGENT_MODEL_FORCE"] = "1"
            p.environment["CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH"] = "\(depth)"
            p.environment["CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS"] = "\(concurrent)"
            p.environment["CLAUDE_CODE_DISABLE_BACKGROUND_TASKS"] = "1"
        } else {
            for name in subagentTools where !p.disallowedTools.contains(name) { p.disallowedTools.append(name) }
        }
    }

    /// What the engine asserts about the session of a mode turn: no `Task`/`Agent` when sub-agents are off, never `Workflow`
    /// (Ultra is 5-lite's), the init `agents` list equal to the doctor-recorded built-ins, and the forced worker allowed to bill.
    public static func expectations(for d: ModeDecision, agents: Set<String>?) -> TurnExpectations {
        var forbidden: Set<String> = ["Workflow"]
        var extra: Set<String> = []
        if case .forced(let model, _, _) = d.subagents { extra.insert(model) } else { forbidden.formUnion(subagentTools) }
        return TurnExpectations(agents: agents, forbiddenTools: forbidden, extraModels: extra)
    }

    /// 3a's PreToolUse block in exec form: `<executable> hook pre-tool --mode <mode> [--subagents]`, blocking when it cannot
    /// run (fix round 1, C1).
    public static func preToolHook(executable: String, mode: WorkMode, subagents: Bool) -> HookMatcher {
        HookMatcher(matcher: hookMatcher, hooks: [HookCommand(
            command: executable, args: ["hook", "pre-tool", "--mode", mode.rawValue] + (subagents ? ["--subagents"] : []))])
    }

    /// The prefix every sandboxed turn's mach marker has (`dev.brahma.turn.<id>`).
    public static let containmentMarkerPrefix = "dev.brahma.turn."

    /// Refuses a profile whose model or fallback is not on the allowlist (owner pins included), and a Sandboxed profile that
    /// lacks any part of its sandbox (the sandbox block, the settings file, `--restricted` and `--tools`, the shell prefix):
    /// such a turn never starts. The runner calls it before it starts a process.
    public static func validate(_ p: TurnProfile) throws {
        for m in [p.model, p.fallbackModel] where !ModelAllowlist.allows(m) { throw TurnProfileError.modelNotAllowed(m) }
        guard p.permission == .sandboxed else { return }
        guard let sandbox = p.settings.sandbox, sandbox.enabled == true, sandbox.failIfUnavailable == true,
              sandbox.allowUnsandboxedCommands == false, sandbox.filesystem != nil else {
            throw TurnProfileError.sandboxIncomplete("no sandbox scope was compiled")
        }
        guard p.settingsFilePath != nil else { throw TurnProfileError.sandboxIncomplete("no settings file") }
        guard p.restricted, p.tools != nil, p.permissionPrompts == "none" else {
            throw TurnProfileError.sandboxIncomplete("not restricted to its tools")
        }
        guard let prefix = p.environment["CLAUDE_CODE_SHELL_PREFIX"], !prefix.isEmpty else {
            throw TurnProfileError.sandboxIncomplete("no shell prefix")
        }
        // The turn's processes must be recognizable by their sandbox (Task 2's marker, adopted for turns).
        guard let markers = sandbox.network?.allowMachLookup, markers.count == 1,
              markers[0].hasPrefix(containmentMarkerPrefix), markers[0].count > containmentMarkerPrefix.count + 8 else {
            throw TurnProfileError.sandboxIncomplete("no containment marker")
        }
        // Every hook is exec form (C1; the type always encodes `args`) with an absolute executable (fix round 2, A-N2): a
        // relative one would be looked up through the turn's PATH. A space in the path is fine: exec form does not split it.
        for hook in (p.settings.hooks ?? [:]).values.flatMap({ $0 }).flatMap(\.hooks) where !hook.command.hasPrefix("/") {
            throw TurnProfileError.sandboxIncomplete("a hook's executable is not an absolute path")
        }
    }

    /// Review and audit turns never get sub-agent or workflow tools, whatever the profile was widened to.
    public static func restricted(_ profile: TurnProfile, for kind: TurnKind) -> TurnProfile {
        guard kind.isReview else { return profile }
        let banned = ["Task", "Agent", "Workflow"]
        var p = profile
        p.allowedTools.removeAll { banned.contains($0) }
        for name in banned where !p.disallowedTools.contains(name) { p.disallowedTools.append(name) }
        p.subagents = .off
        return p
    }

    /// The compiled settings (`p.settings`), compact, keys sorted: the settings file's bytes (or the inline `--settings`).
    /// Throws rather than produce anything but the compiled settings (M6).
    public static func settingsJSON(_ p: TurnProfile) throws -> String { try p.settings.json() }

    /// `2.00`, `0.30`, `0.0425`: two decimals, more when a small cap needs them.
    static func money(_ v: Double) -> String {
        let two = String(format: "%.2f", v)
        if abs((Double(two) ?? 0) - v) < 1e-9 { return two }
        var s = String(format: "%.6f", v)
        while s.hasSuffix("0") { s.removeLast() }
        return s
    }

    /// Arguments only; the prompt is sent on stdin, never argv.
    public static func arguments(_ p: TurnProfile) -> [String] {
        var a = [
            "-p", "--output-format", "stream-json", "--verbose",
            "--model", p.model, "--fallback-model", p.fallbackModel,
        ]
        if p.restricted { a.append("--restricted") }
        if let tools = p.tools { a += ["--tools", tools.joined(separator: ",")] }
        if let prompts = p.permissionPrompts { a += ["--permission-prompts", prompts] }
        let inline: () -> String = {
            // Only profiles without a settings file (never a sandboxed one: `validate`) carry the JSON inline; encoding plain
            // values cannot fail, and if it ever did the turn must not start with anything else.
            do { return try settingsJSON(p) } catch { preconditionFailure("the turn's settings could not be encoded: \(error)") }
        }
        a += ["--setting-sources", "", "--settings", p.settingsFilePath ?? inline()]
        if p.disableSlashCommands { a.append("--disable-slash-commands") }
        for dir in p.pluginDirs { a += ["--plugin-dir", dir] }
        a += ["--strict-mcp-config", "--mcp-config", p.mcpConfigPath,
              "--disallowed-tools", p.disallowedTools.joined(separator: ",")]
        switch p.session {
        case .start(let id, let system):
            a += ["--session-id", id]
            if let system { a += ["--append-system-prompt", system] }
        case .resume(let id, let system):
            a += ["--resume", id]
            if let system { a += ["--append-system-prompt", system] }
        }
        switch p.permission {
        case .workspace, .sandboxed:
            a += ["--permission-mode", p.permissionModeOverride ?? "acceptEdits", "--allowed-tools", p.allowedTools.joined(separator: ",")]
            for dir in p.addDirs { a += ["--add-dir", dir] }
        case .full:
            a += ["--permission-mode", p.permissionModeOverride ?? "bypassPermissions"]
        }
        if let effort = p.effort { a += ["--effort", effort.rawValue] }
        if let maxTurns = p.maxTurns { a += ["--max-turns", "\(maxTurns)"] }
        if let budget = p.maxBudgetUSD { a += ["--max-budget-usd", money(budget)] }
        return a
    }
}

/// The environment a child process (an agent turn or a check) gets: an allowlist, never the owner's full environment.
public enum ChildEnvironment {
    /// `check` is the engine-run verification command: the `general` allowlist and no auth variables (secrets never reach it).
    public enum Purpose: Sendable { case claude, general, check }

    static let allowed: Set<String> = ["PATH", "HOME", "LANG", "TERM", "USER", "LOGNAME", "SHELL", "DEVELOPER_DIR", "TMPDIR",
        "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy",
        "SSL_CERT_FILE", "NODE_EXTRA_CA_CERTS", "CLAUDE_CONFIG_DIR",
    ]
    static let claudeAuth: Set<String> = ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY"]

    /// The `CLAUDE_CODE_*` controls the engine sets per turn (design §4.1), admitted only from what the compiler put on the turn,
    /// never inherited from the owner's environment. One list for 3a (W1/W8) and 5-lite (F1). Never passed, inherited or not:
    /// `CLAUDE_CODE_EFFORT_LEVEL`, `CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS`, `CLAUDE_CODE_WORKFLOWS`, `MAX_THINKING_TOKENS`,
    /// `CLAUDE_AGENT_SDK_DISABLE_BUILTIN_AGENTS`.
    public static let engineClaudeVars: Set<String> = [
        "CLAUDE_CODE_SUBAGENT_MODEL", "CLAUDE_CODE_SUBAGENT_MODEL_FORCE",
        "CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH", "CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS",
        "CLAUDE_CODE_DISABLE_BACKGROUND_TASKS", "CLAUDE_CODE_DISABLE_FAST_MODE", "CLAUDE_CODE_DISABLE_WORKFLOWS",
        "CLAUDE_CODE_TMPDIR",
        "CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS", "CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS",
        "CLAUDE_CODE_SHELL_PREFIX",
    ]

    static func isSecretName(_ name: String) -> Bool {
        let u = name.uppercased()
        return u.contains("TOKEN") || u.contains("SECRET") || u.contains("KEY") || u.hasPrefix("AWS_") || u == "SSH_AUTH_SOCK"
    }

    /// Names a secret may never take: the engine's own variables, the basics every child needs, the Claude auth
    /// variables and the loader/interpreter hooks that run code in a child.
    static func isReserved(_ name: String) -> Bool {
        allowed.contains(name) || claudeAuth.contains(name) || name.hasPrefix("LC_") || name.hasPrefix("BRAHMA_")
            || name.hasPrefix("CLAUDE_") || name.hasPrefix("ANTHROPIC_") || name.hasPrefix("DYLD_") || name.hasPrefix("LD_")
            || ["NODE_OPTIONS", "BASH_ENV", "ENV", "SHELLOPTS", "PS4", "IFS", "PYTHONSTARTUP", "PYTHONPATH", "RUBYOPT", "PERL5OPT"].contains(name)
    }

    /// `secrets` (name → value) are test keys the engine hands to this child, and are applied after the drop step, which
    /// would otherwise remove them (their names contain KEY, TOKEN or SECRET). A name `SecretName.isInjectable` refuses is
    /// silently dropped, so a row written by other means can never set `GIT_SSH_COMMAND`, `LD_PRELOAD`, `PATH` and the
    /// like; the caller logs `droppedSecretNames(_:)`.
    public static func make(base: [String: String], extra: [String: String] = [:],
                            engineClaudeVars: [String: String] = [:], purpose: Purpose = .general,
                            secrets: [String: String] = [:]) -> [String: String] {
        var env: [String: String] = [:]
        for (name, value) in base where (allowed.contains(name) || name.hasPrefix("LC_")) && !isSecretName(name) {
            env[name] = value
        }
        if purpose == .claude {
            for name in claudeAuth { if let v = base[name] { env[name] = v } }
        }
        // Never the MCP server's per-turn token: it lives only in that server's env block (fix round 1, I2(d)).
        for (name, value) in extra where name.hasPrefix("BRAHMA_") && name != "BRAHMA_DEV" && name != MCPConfig.tokenVariable {
            env[name] = value
        }
        if purpose == .claude {
            for (name, value) in engineClaudeVars where Self.engineClaudeVars.contains(name) { env[name] = value }
        }
        for (name, value) in secrets where SecretName.isInjectable(name) { env[name] = value }
        return env
    }

    /// The names `make` would drop from `secrets` (sorted), for the caller to log.
    public static func droppedSecretNames(_ secrets: [String: String]) -> [String] {
        secrets.keys.filter { !SecretName.isInjectable($0) }.sorted()
    }
}
