import Foundation

/// Everything that decides how one `claude -p` turn is launched. `TurnProfileCompiler` is the only place that
/// turns it into argv.
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
    public var extraSettings: [String: JSONValue] = [:]
    public var disableSlashCommands = true
    public var environment: [String: String] = [:]

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

public enum TurnProfileCompiler {
    public static func profile(for r: TurnRequest) -> TurnProfile {
        let session: TurnProfile.Session = r.agent.sessionStarted
            ? .resume(id: r.agent.sessionId, systemPrompt: r.appendSystemPrompt)
            : .start(id: r.agent.sessionId, systemPrompt: r.appendSystemPrompt)
        var p = TurnProfile(model: r.agent.model, session: session, mcpConfigPath: r.mcpConfigPath,
                            permission: r.profile, workingDirectory: r.workingDirectory,
                            addDirs: r.addDirs.isEmpty ? [r.company.workspacePath] : r.addDirs)
        p.environment = r.environment
        return p
    }

    /// `{"enabledPlugins":{}}` merged with `extraSettings`, compact, keys sorted.
    public static func settingsJSON(_ p: TurnProfile) -> String {
        var settings = p.extraSettings
        if settings["enabledPlugins"] == nil { settings["enabledPlugins"] = .object([:]) }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        let data = (try? encoder.encode(settings)) ?? Data("{\"enabledPlugins\":{}}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Arguments only; the prompt is sent on stdin, never argv.
    public static func arguments(_ p: TurnProfile) -> [String] {
        var a = [
            "-p", "--output-format", "stream-json", "--verbose",
            "--model", p.model, "--fallback-model", p.fallbackModel,
            "--setting-sources", "", "--settings", settingsJSON(p),
        ]
        if p.disableSlashCommands { a.append("--disable-slash-commands") }
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
        case .workspace:
            a += ["--permission-mode", "acceptEdits", "--allowed-tools", p.allowedTools.joined(separator: ",")]
            for dir in p.addDirs { a += ["--add-dir", dir] }
        case .full:
            a += ["--permission-mode", "bypassPermissions"]
        }
        return a
    }
}

/// The environment a child process (an agent turn or a check) gets: an allowlist, never the owner's full environment.
public enum ChildEnvironment {
    public enum Purpose: Sendable { case claude, general }

    static let allowed: Set<String> = ["PATH", "HOME", "LANG", "TERM", "USER", "LOGNAME", "SHELL", "DEVELOPER_DIR", "TMPDIR",
        "HTTP_PROXY", "HTTPS_PROXY", "NO_PROXY", "http_proxy", "https_proxy", "no_proxy",
        "SSL_CERT_FILE", "NODE_EXTRA_CA_CERTS", "CLAUDE_CONFIG_DIR",
    ]
    static let claudeAuth: Set<String> = ["CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_API_KEY"]

    static func isSecretName(_ name: String) -> Bool {
        let u = name.uppercased()
        return u.contains("TOKEN") || u.contains("SECRET") || u.contains("KEY") || u.hasPrefix("AWS_") || u == "SSH_AUTH_SOCK"
    }

    /// `CLAUDE_CODE_*` settings the engine itself decides per turn (effort, agent teams, ...). They are admitted only
    /// from what the engine puts in `TurnRequest.environment`, never inherited from the owner's environment.
    static func isEngineClaudeVar(_ name: String) -> Bool { name.hasPrefix("CLAUDE_CODE_") && !isSecretName(name) }

    public static func make(base: [String: String], extra: [String: String] = [:],
                            engineClaudeVars: [String: String] = [:], purpose: Purpose = .general) -> [String: String] {
        var env: [String: String] = [:]
        for (name, value) in base where (allowed.contains(name) || name.hasPrefix("LC_")) && !isSecretName(name) {
            env[name] = value
        }
        if purpose == .claude {
            for name in claudeAuth { if let v = base[name] { env[name] = v } }
        }
        for (name, value) in extra where name.hasPrefix("BRAHMA_") && name != "BRAHMA_DEV" { env[name] = value }
        if purpose == .claude {
            for (name, value) in engineClaudeVars where isEngineClaudeVar(name) { env[name] = value }
        }
        return env
    }
}
