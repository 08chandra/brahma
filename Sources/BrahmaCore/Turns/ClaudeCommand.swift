import Foundation

/// How much of the Mac an agent's turn may touch. `sandboxed` (5-lite, the default for new companies) confines every turn to
/// the `SandboxScope` the engine computes for it; `workspace` is 3a's permission-prompt profile; `full` is the whole Mac.
public enum PermissionProfile: String, Codable, Sendable, CaseIterable {
    case workspace, full, sandboxed

    /// How much of the Mac it opens: sandboxed < workspace (the agent's Bash is unconfined) < full.
    var breadth: Int {
        switch self {
        case .sandboxed: 0
        case .workspace: 1
        case .full: 2
        }
    }

    /// The narrower of two profiles (an engine ceiling narrows a company's profile, never widens it).
    public static func narrower(_ a: PermissionProfile, _ b: PermissionProfile) -> PermissionProfile { a.breadth <= b.breadth ? a : b }
}

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
    /// The test keys this turn gets (`use_secret`, Task 4-wire): applied by `ChildEnvironment.make(secrets:)` after its drop
    /// step, the only way a secret value reaches a child. Never part of argv, the settings or any record.
    public var secrets: [String: String] = [:]
    /// Review and audit turns are compiled clean-context: no `Task`, `Agent` or `Workflow` tools.
    public var kind: TurnKind = .work
    /// A plan turn writes its plan here (`<ws>/.brahma/plans/<KEY>/`), the only place it may write.
    public var planDirectory: String? = nil
    /// The turn's wall clock; nil means the runner's own limit (900 s unless configured). 14c sets per-mode values.
    public var wallClock: Duration? = nil
    /// What the engine asserts about the session the CLI reports; nil asserts nothing.
    public var expectations: TurnExpectations? = nil
    /// The work mode the engine chose (`ModePolicy.select`); nil for Plan 1 inputs, which compile byte-identically.
    public var mode: ModeDecision? = nil
    /// The `brahma` executable whose `hook pre-tool` is the engine's PreToolUse hook (exec form); set with the mode.
    public var hookExecutable: String? = nil

    // Sandboxed profile (5-lite Task 1b).
    /// The turn's scope (`SandboxScope.forTurn`): required on the Sandboxed profile, nil otherwise.
    public var sandbox: SandboxScope? = nil
    /// The agent's Bash prefix (`ShellPrefix.write`), passed as `CLAUDE_CODE_SHELL_PREFIX`.
    public var shellPrefix: String? = nil
    /// The turn's extension plugin parts (Task 5a; empty until then): `--plugin-dir` each, and no `--disable-slash-commands`.
    public var mounts: [URL] = []
    /// `<runDir>/<agentId>.settings.json`: the settings travel in this file (`--settings <path>`); nil keeps them inline.
    public var settingsFilePath: String? = nil
    /// The Workspace profile's read and edit denies: the data home, the protected list, the other workspaces.
    public var deniedPaths: [URL] = []
    /// The PostToolUse hook (Task 10, `TaintPolicy.postToolHook`), exec form.
    public var postToolHook: HookCommand? = nil
    /// The session's taint flag file (`TaintFlag.url`) and the database whose agent row carries `sessionTainted`: the pre-tool
    /// hook denies `Agent`, `Task` and `Workflow` when either says tainted (Task 10). Nil: not named.
    public var taintFlagFile: String? = nil
    public var taintDatabase: String? = nil
    /// The sandboxed turn's mach marker (`dev.brahma.turn.<id>`): allowed by its sandbox, so the engine can recognize the
    /// turn's processes by their sandbox alone (Task 2's mechanism). Required on the Sandboxed profile.
    public var containmentMarker: String? = nil
    /// Where the runner records the turn's leader (`<runDir>/turns`), so a restarted engine can still kill what is left.
    public var turnRecordDirectory: URL? = nil
    /// A sub-agent (Task) turn keeps `WebFetch`/`WebSearch` (Task 14u): only once probe F7-agents passed for this CLI build
    /// (only Brahma's worker agent types load, Task 10b). Until then a turn is Task without web tools or web tools without Task.
    public var taskWebTools = false
    /// The runner yields every stdout line as `.raw` too (the sandbox canary reads tool results the parser only digests).
    public var emitRawLines = false
    /// Plan C Task C4c: a concierge run. `TurnProfileCompiler.profile(for:)` then compiles `conciergeProfile` (no built-in
    /// tools, no role card, no session to resume, `--max-turns 4`, Haiku) instead of an agent's turn.
    public var concierge: ConciergeTurn? = nil

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
    /// `disallowedTools` (the harness tools every turn denies) moved with the compiler: `Runtime/Claude/TurnProfile.swift`.

    /// Arguments only; the prompt is sent on stdin, never argv.
    public static func arguments(for r: TurnRequest) -> [String] {
        TurnProfileCompiler.arguments(TurnProfileCompiler.profile(for: r))
    }
}

public enum MCPConfig {
    public static let tokenVariable = "BRAHMA_TURN_TOKEN"

    /// Writes `<runDir>/<agentId>.mcp.json` (mode 0600, atomic) and returns its path. The per-turn token travels
    /// in the server's `env` entry, so it is neither in argv nor in the agent's own process environment.
    /// A review turn passes `reviewItem` (the item key): its server runs `--review-item <KEY>` and writes `<agentId>.review.mcp.json`.
    /// An audit turn passes `audit`: its server runs `--audit` and writes `<agentId>.audit.mcp.json`.
    /// The turn's mode quotas are not here: they ride on the credential row the token names.
    public static func write(paths: BrahmaPaths, executable: String, agent: Agent, turnToken: String,
                             reviewItem: String? = nil, audit: Bool = false,
                             environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        try FileManager.default.createDirectory(at: paths.runDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        var args = ["mcp", "--db", paths.database.path, "--company", agent.companyId, "--agent", agent.id]
        if let reviewItem { args += ["--review-item", reviewItem] } else if audit { args.append("--audit") }
        var env = [tokenVariable: turnToken]
        // A sandboxed turn's shell prefix starts the server by a fixed argv with the database, company and agent baked in (1b
        // fix rounds 1-2); only what the turn's credential checks rides here.
        if let reviewItem { env[MCPLaunch.reviewItemVariable] = reviewItem } else if audit { env[MCPLaunch.auditVariable] = "1" }
        // A dev/demo home's file secret store reaches the turn's `brahma mcp` (which resolves it again against its database's
        // own home, refusing the default home), so its redactor loads the same values as the engine's. Never the agent's env.
        if environment[SecretStore.environmentVariable] == "file" { env[SecretStore.environmentVariable] = "file" }
        let config: [String: Any] = ["mcpServers": ["company": [
            "command": executable,
            "args": args,
            "env": env,
        ] as [String: Any]]]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        let name = reviewItem != nil ? "\(agent.id).review.mcp.json" : audit ? "\(agent.id).audit.mcp.json" : "\(agent.id).mcp.json"
        let url = paths.runDir.appending(path: name)
        // The file holds the turn token, so it is created 0600 (never briefly world-readable) and renamed into place.
        let temp = paths.runDir.appending(path: ".\(name).\(UUID().uuidString)")
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

    /// Plan C Task C4c: the concierge's `<runDir>/concierge-<requestId>.mcp.json` (0600, atomic): `brahma mcp --agent concierge
    /// --company <id> --show-request <id>`, the run's token in the server's env block.
    public static func writeConcierge(paths: BrahmaPaths, executable: String, companyId: String, requestId: String, token: String,
                                      environment: [String: String] = ProcessInfo.processInfo.environment) throws -> String {
        try FileManager.default.createDirectory(at: paths.runDir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let args = ["mcp", "--db", paths.database.path, "--company", companyId, "--agent", ConciergeCaps.agentId,
                    "--show-request", requestId]
        var env = [tokenVariable: token, MCPLaunch.showRequestVariable: requestId]
        if environment[SecretStore.environmentVariable] == "file" { env[SecretStore.environmentVariable] = "file" }
        let config: [String: Any] = ["mcpServers": ["company": ["command": executable, "args": args, "env": env] as [String: Any]]]
        let data = try JSONSerialization.data(withJSONObject: config, options: [.sortedKeys])
        let name = "concierge-\(requestId).mcp.json"
        let url = paths.runDir.appending(path: name)
        let temp = paths.runDir.appending(path: ".\(name).\(UUID().uuidString)")
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


/// Plan C Task C4c: what identifies one concierge run (its company, its show request and its fresh 0700 working directory).
public struct ConciergeTurn: Equatable, Sendable {
    public var companyId: String
    public var requestId: String
    public var workdir: URL

    public init(companyId: String, requestId: String, workdir: URL) {
        self.companyId = companyId; self.requestId = requestId; self.workdir = workdir
    }
}

/// `brahma mcp`'s parameters: its flags, or its env block (`BRAHMA_MCP_*`, written next to the turn token in the 0600 MCP
/// config). A sandboxed turn's shell prefix starts the server by the fixed argv `<exe> mcp`, so there the env block is all
/// there is. Given both ways, they must agree.
public struct MCPLaunch: Equatable, Sendable {
    public static let dbVariable = "BRAHMA_MCP_DB"
    public static let companyVariable = "BRAHMA_MCP_COMPANY"
    public static let agentVariable = "BRAHMA_MCP_AGENT"
    public static let reviewItemVariable = "BRAHMA_MCP_REVIEW_ITEM"
    public static let auditVariable = "BRAHMA_MCP_AUDIT"
    /// Plan C Task C4c: the concierge's server serves exactly one show request.
    public static let showRequestVariable = "BRAHMA_MCP_SHOW_REQUEST"

    public var db: String
    public var company: String
    public var agent: String
    public var reviewItem: String?
    public var audit: Bool
    /// Plan C Task C4c: set exactly for the concierge (`--agent concierge`).
    public var showRequest: String? = nil

    public init(db: String, company: String, agent: String, reviewItem: String?, audit: Bool, showRequest: String? = nil) {
        self.db = db; self.company = company; self.agent = agent; self.reviewItem = reviewItem; self.audit = audit
        self.showRequest = showRequest
    }

    public struct Failure: Error, CustomStringConvertible {
        public let description: String
    }

    public static func resolve(db: String?, company: String?, agent: String?, reviewItem: String?, audit: Bool,
                               showRequest: String? = nil, environment: [String: String]) throws -> MCPLaunch {
        func one(_ flag: String?, _ variable: String, _ name: String) throws -> String? {
            let env = environment[variable].flatMap { $0.isEmpty ? nil : $0 }
            if let flag, let env, flag != env { throw Failure(description: "--\(name) does not match this server's \(variable)") }
            return flag ?? env
        }
        guard let db = try one(db, dbVariable, "db"), let company = try one(company, companyVariable, "company"),
              let agent = try one(agent, agentVariable, "agent") else {
            throw Failure(description: "missing --db, --company or --agent")
        }
        let item = try one(reviewItem, reviewItemVariable, "review-item")
        let envAudit = environment[auditVariable] == "1"
        let isAudit = audit || envAudit
        if item != nil && isAudit { throw Failure(description: "a server is either a review or an audit server, never both") }
        // Plan C Task C4c: the concierge's server serves one show request, and only the concierge's does.
        let request = try one(showRequest, showRequestVariable, "show-request")
        if agent == ConciergeCaps.agentId {
            guard let request, !request.isEmpty else { throw Failure(description: "the concierge's server needs --show-request") }
            guard item == nil, !isAudit else { throw Failure(description: "the concierge's server is neither a review nor an audit server") }
        } else if request != nil {
            throw Failure(description: "--show-request is only for the concierge")
        }
        return MCPLaunch(db: db, company: company, agent: agent, reviewItem: item, audit: isAudit, showRequest: request)
    }
}
