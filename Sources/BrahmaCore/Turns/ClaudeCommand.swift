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
    /// Directories the agent may touch besides its working directory. Empty means `[company.workspacePath]`.
    public var addDirs: [String] = []
    /// Engine-set `BRAHMA_*` variables for the child; everything else comes from `ChildEnvironment`.
    public var environment: [String: String] = [:]

    public init(agent: Agent, company: Company, prompt: String, appendSystemPrompt: String?,
                mcpConfigPath: String, workingDirectory: String, profile: PermissionProfile,
                addDirs: [String] = [], environment: [String: String] = [:]) {
        self.addDirs = addDirs
        self.environment = environment
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
    /// Harness tools that would bypass the company's own messaging and scheduling. `Task` (sub-agents) stays off on the
    /// Workspace profile: they would run with no model pin and outside the engine's accounting.
    public static let disallowedTools: [String] = [
        "CronCreate", "CronDelete", "CronList", "ScheduleWakeup", "Monitor", "RemoteTrigger",
        "PushNotification", "SendMessage", "ListAgents", "EnterWorktree", "ExitWorktree",
        "DesignSync", "ReportFindings", "Task", "TaskStop",
    ]

    /// Arguments only; the prompt is sent on stdin, never argv.
    public static func arguments(for r: TurnRequest) -> [String] {
        TurnProfileCompiler.arguments(TurnProfileCompiler.profile(for: r))
    }
}

public enum MCPConfig {
    public static let tokenVariable = "BRAHMA_TURN_TOKEN"

    /// Writes `<runDir>/<agentId>.mcp.json` (mode 0600, atomic) and returns its path. The per-turn token travels
    /// in the server's `env` entry, so it is neither in argv nor in the agent's own process environment.
    public static func write(paths: BrahmaPaths, executable: String, agent: Agent, turnToken: String) throws -> String {
        try FileManager.default.createDirectory(at: paths.runDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let config: [String: Any] = ["mcpServers": ["company": [
            "command": executable,
            "args": ["mcp", "--db", paths.database.path, "--company", agent.companyId, "--agent", agent.id],
            "env": [tokenVariable: turnToken],
        ] as [String: Any]]]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        let url = paths.runDir.appending(path: "\(agent.id).mcp.json")
        // The file holds the turn token, so it is created 0600 (never briefly world-readable) and renamed into place.
        let temp = paths.runDir.appending(path: ".\(agent.id).mcp.json.\(UUID().uuidString)")
        let fd = open(temp.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown) }
        let bytes = [UInt8](data)
        let written = Foundation.write(fd, bytes, bytes.count)
        close(fd)
        guard written == bytes.count, rename(temp.path, url.path) == 0 else {
            try? FileManager.default.removeItem(at: temp)
            throw CocoaError(.fileWriteUnknown)
        }
        return url.path
    }
}
