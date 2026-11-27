import Foundation

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
    /// The built-in agents switch (F7): dropped like every other unlisted variable, admitted only with `allowBuiltinAgentsSwitch`
    /// (the compiled profile's `builtinAgentsDisabled`, set only once F7-agents passed).
    public static let builtinAgentsSwitch = "CLAUDE_AGENT_SDK_DISABLE_BUILTIN_AGENTS"

    public static func make(base: [String: String], extra: [String: String] = [:],
                            engineClaudeVars: [String: String] = [:], purpose: Purpose = .general,
                            secrets: [String: String] = [:], allowBuiltinAgentsSwitch: Bool = false) -> [String: String] {
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
            // The sandbox canary's four probe variables (paths of the dummy tokens it planted, `CanaryProbes.variables`): only
            // the canary's own request carries them.
            for name in CanaryProbes.variables { if let value = extra[name] { env[name] = value } }
            for (name, value) in engineClaudeVars where Self.engineClaudeVars.contains(name) { env[name] = value }
            if allowBuiltinAgentsSwitch, engineClaudeVars[builtinAgentsSwitch] == "1" { env[builtinAgentsSwitch] = "1" }
        }
        for (name, value) in secrets where SecretName.isInjectable(name) { env[name] = value }
        return env
    }

    /// The names `make` would drop from `secrets` (sorted), for the caller to log.
    public static func droppedSecretNames(_ secrets: [String: String]) -> [String] {
        secrets.keys.filter { !SecretName.isInjectable($0) }.sorted()
    }
}
