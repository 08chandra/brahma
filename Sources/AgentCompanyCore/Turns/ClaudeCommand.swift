import Foundation

public enum PermissionProfile: String, Codable, Sendable { case workspace, full }

public struct TurnRequest: Sendable {
    public var agent: Agent
    public var company: Company
    public var prompt: String
    public var appendSystemPrompt: String?
    public var mcpConfigPath: String
    public var workingDirectory: String
    public var profile: PermissionProfile

    public init(agent: Agent, company: Company, prompt: String, appendSystemPrompt: String?,
                mcpConfigPath: String, workingDirectory: String, profile: PermissionProfile) {
        self.agent = agent
        self.company = company
        self.prompt = prompt
        self.appendSystemPrompt = appendSystemPrompt
        self.mcpConfigPath = mcpConfigPath
        self.workingDirectory = workingDirectory
        self.profile = profile
    }
}

public enum ClaudeCommand {
    /// Harness tools that would bypass the company's own messaging and scheduling.
    public static let disallowedTools: [String] = [
        "CronCreate", "CronDelete", "CronList", "ScheduleWakeup", "Monitor", "RemoteTrigger",
        "PushNotification", "SendMessage", "ListAgents", "EnterWorktree", "ExitWorktree",
        "DesignSync", "ReportFindings", "TaskStop",
    ]

    /// Arguments only; the prompt is sent on stdin, never argv.
    public static func arguments(for r: TurnRequest) -> [String] {
        var a = [
            "-p", "--output-format", "stream-json", "--verbose",
            "--model", r.agent.model, "--fallback-model", "sonnet",
            "--setting-sources", "project", "--settings", "{\"enabledPlugins\":{}}", "--disable-slash-commands",
            "--strict-mcp-config", "--mcp-config", r.mcpConfigPath,
            "--disallowed-tools", disallowedTools.joined(separator: ","),
        ]
        if r.agent.sessionStarted {
            a += ["--resume", r.agent.sessionId]
        } else {
            a += ["--session-id", r.agent.sessionId]
            if let system = r.appendSystemPrompt { a += ["--append-system-prompt", system] }
        }
        switch r.profile {
        case .workspace:
            a += ["--permission-mode", "acceptEdits",
                  "--allowed-tools", "Bash,Read,Edit,Write,Glob,Grep,mcp__company",
                  "--add-dir", r.company.workspacePath]
        case .full:
            a += ["--permission-mode", "bypassPermissions"]
        }
        return a
    }
}

public enum MCPConfig {
    /// Writes `<runDir>/<agentId>.mcp.json` (mode 0600, atomic) and returns its path.
    public static func write(paths: AgentCoPaths, executable: String, agent: Agent) throws -> String {
        try FileManager.default.createDirectory(at: paths.runDir, withIntermediateDirectories: true)
        let config: [String: Any] = ["mcpServers": ["company": [
            "command": executable,
            "args": ["mcp", "--db", paths.database.path, "--company", agent.companyId, "--agent", agent.id],
        ] as [String: Any]]]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        let url = paths.runDir.appending(path: "\(agent.id).mcp.json")
        try data.write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
        return url.path
    }
}
