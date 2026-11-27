import Foundation

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
    /// The plugins Claude Code bundles (`cc-plugin-*@builtin`; 2.1.322 registers fourteen), each turned off by name on every
    /// turn: `disableBundledSkills` leaves them on, and the init line of a 2.1.322 `-p` turn listed `cc-plugin-privacy` and
    /// `cc-plugin-telemetry` (sandbox canary, live run). The sandbox canary judges the init `plugins` by the subset rule, so a
    /// bundled plugin a later CLI adds keeps the canary failing until it is reviewed and added here. `cc-plugin-sec-default`
    /// is left alone: it is the managed-settings security layer for Team and Enterprise organizations, adds no policy of its
    /// own, and is not ours to switch off.
    public static let bundledPluginNames = [
        "cc-plugin-agents-md", "cc-plugin-claude-platform", "cc-plugin-claude-test", "cc-plugin-diff", "cc-plugin-easel",
        "cc-plugin-mermaid", "cc-plugin-mods-guide", "cc-plugin-plugin-authoring", "cc-plugin-privacy", "cc-plugin-responsive-mode",
        "cc-plugin-telemetry", "cc-plugin-tips", "cc-plugin-you-should-know",
    ]
    public static let disabledBuiltinPlugins: [String: Bool] =
        Dictionary(uniqueKeysWithValues: bundledPluginNames.map { ("\($0)@builtin", false) })
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
    /// `use_secret` too (fix round 2, N5): no test key reaches an Ultra turn, whose workflow agents all share its MCP server.
    static let ultraExtraMCPDenies: Set<String> = ["propose_extension", "use_secret"]
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
