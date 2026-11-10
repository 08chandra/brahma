import Testing
import Foundation
@testable import BrahmaCore

/// A company on a file-backed store whose data home, workspaces root, "owner's home" and Darwin temp dir all sit in one
/// resolved temp dir, so every compiled path is known and can be written as a placeholder.
private struct CompileWorld {
    let root: URL
    let userHome: URL
    let paths: BrahmaPaths
    let store: Store
    let company: Company
    let eng: Agent
    let item: WorkItem
    let layout: SandboxLayout
    let userTemp: URL

    init(name: String = "Acme") throws {
        root = URL(fileURLWithPath: SandboxPath.resolve(try tempDir().path), isDirectory: false)
        userHome = root.appending(path: "user")
        paths = BrahmaPaths(home: root.appending(path: "data"), workspaces: root.appending(path: "wss"))
        // `<per-user Darwin folder>/T`: the folder (`$DARWIN`) is unreadable to turns except the toolchain's entries.
        userTemp = root.appending(path: "folders/T")
        for dir in [userHome, paths.home, paths.workspaces, userTemp] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        store = try Store(path: paths.database.path)
        company = try store.createCompany(name: name, goal: "g", workspacesRoot: paths.workspaces)
        eng = try store.hire(companyId: company.id, name: "eng-1", role: "engineer", model: "sonnet")
        item = try store.createWorkItem(companyId: company.id, by: .owner, draft: WorkItemDraft(
            type: .task, title: "Thing", ownerId: eng.id, status: .ready), now: Date())
        layout = SandboxLayout(paths: paths, company: company, agentHandle: "eng-1")
        try layout.ensure()
        // The item's worktree and plan directory as the engine makes them (3a), so the scopes name real places.
        try FileManager.default.createDirectory(at: ws.appending(path: ".brahma/wt/\(item.key)"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ws.appending(path: ".brahma/plans/\(item.key)"), withIntermediateDirectories: true)
    }

    var ws: URL { URL(fileURLWithPath: company.workspacePath, isDirectory: false) }

    func scope(_ kind: TurnKind, withItem: Bool = true) throws -> SandboxScope {
        try SandboxScope.forTurn(layout: layout, paths: paths, otherWorkspaces: [], backupTargets: [], kind: kind,
                                 item: withItem ? item : nil, company: company, grants: GrantInputs(),
                                 darwinUserTemp: userTemp, userHome: userHome, claudeTmpRoot: URL(fileURLWithPath: "/private/tmp/b-test"))
    }

    /// The compiled JSON with this world's paths replaced by `$WS`, `$DATA`, `$USERHOME` and `$TMP`.
    func placeholders(_ json: String) -> String {
        json.replacingOccurrences(of: ws.path, with: "$WS")
            .replacingOccurrences(of: paths.home.path, with: "$DATA")
            .replacingOccurrences(of: userHome.path, with: "$USERHOME")
            .replacingOccurrences(of: userTemp.path, with: "$TMP")
            .replacingOccurrences(of: userTemp.deletingLastPathComponent().path, with: "$DARWIN")
            .replacingOccurrences(of: "claude-\(getuid())", with: "claude-$UID")
            .replacingOccurrences(of: "/private/tmp/b-\(getuid())", with: "/private/tmp/b-$UID")
            .replacingOccurrences(of: "/private/tmp/b-test/[0-9a-f]{6}", with: "$AGENTTMP", options: .regularExpression)
            .replacingOccurrences(of: item.key, with: "$KEY")
    }

    func request(_ scope: SandboxScope?, kind: TurnKind = .work, mode: ModeDecision? = standard, mounts: [URL] = [],
                 profile: PermissionProfile = .sandboxed) -> TurnRequest {
        var r = TurnRequest(agent: eng, company: company, prompt: "P", appendSystemPrompt: "ROLE",
                            mcpConfigPath: paths.runDir.appending(path: "\(eng.id).mcp.json").path,
                            workingDirectory: company.workspacePath, profile: profile,
                            environment: ["BRAHMA_AGENT_ID": eng.id])
        r.kind = kind
        r.mode = mode
        r.hookExecutable = mode == nil ? nil : hookExe
        r.containmentMarker = scope == nil ? nil : marker
        r.sandbox = scope
        r.shellPrefix = scope == nil ? nil : layout.shellPrefix.path
        r.settingsFilePath = paths.runDir.appending(path: "\(eng.id).settings.json").path
        r.mounts = mounts
        if kind == .plan { r.planDirectory = ws.appending(path: ".brahma/plans/\(item.key)").path }
        return r
    }
}

private let hookExe = "/usr/local/bin/brahma"
private let marker = "dev.brahma.turn.0123456789abcdef"

private func decision(_ edit: (inout ModeInputs) -> Void) -> ModeDecision {
    var i = ModeInputs()
    i.hasItem = true
    i.tier = .s
    i.budgetLeftLE = 100
    edit(&i)
    return ModePolicy.select(i)
}

private let quick = decision { $0.turnKind = .notice }
private let standard = decision { _ in }
private let deep = decision { $0.tier = .m; $0.riskTags = ["hotPath"] }
private let allModes = [quick, standard, deep]

private func args(_ r: TurnRequest) -> [String] { TurnProfileCompiler.arguments(TurnProfileCompiler.profile(for: r)) }
private func value(_ a: [String], _ flag: String) -> String? { a.firstIndex(of: flag).map { a[$0 + 1] } }
private func settings(_ r: TurnRequest) -> ClaudeSettings { TurnProfileCompiler.profile(for: r).settings }
private func json(_ r: TurnRequest) -> String { (try? TurnProfileCompiler.settingsJSON(TurnProfileCompiler.profile(for: r))) ?? "" }

private func fixture(_ name: String) throws -> String {
    let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures"))
    return try String(contentsOf: url, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
}

/// Pretty-printed, keys sorted: the fixtures are kept readable.
private func pretty(_ settings: ClaudeSettings) throws -> String {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes, .prettyPrinted]
    return String(decoding: try encoder.encode(settings), as: UTF8.self)
}

@Suite(.scratch) struct SettingsCompilerTests {
    // MARK: Snapshots

    @Test func sandboxedSettingsSnapshot() throws {
        let w = try CompileWorld()
        let s = settings(w.request(try w.scope(.work)))
        let text = w.placeholders(try pretty(s))
        #expect(text == (try fixture("settings-sandboxed-item")), "\(text)")
        let compact = w.placeholders(json(w.request(try w.scope(.work))))
        for needle in ["\"allowUnsandboxedCommands\":false", "\"Read(/$USERHOME/.ssh/**)\"", "\"Bash(launchctl *)\"",
                       "\"WebFetch(domain:docs.swift.org)\"", "\"disableBundledSkills\":true", "\"failIfUnavailable\":true"] {
            #expect(compact.contains(needle), "missing \(needle)")
        }
        // `//<abs>` is the absolute form of a permission rule.
        #expect(s.permissions?.deny?.contains("Read(/\(w.userHome.path)/.ssh/**)") == true)
    }

    @Test func itemlessSettingsSnapshot() throws {
        let w = try CompileWorld()
        let s = settings(w.request(try w.scope(.work, withItem: false)))
        let text = w.placeholders(try pretty(s))
        #expect(text == (try fixture("settings-sandboxed-itemless")), "\(text)")
        let fs = try #require(s.sandbox?.filesystem)
        // The lab is the cwd; nothing of the common git dir is writable.
        #expect(fs.allowWrite?.contains(w.layout.lab.path) == true)
        #expect(fs.allowWrite?.contains { $0.hasPrefix(w.ws.appending(path: ".git").path) } == false)
        #expect(fs.denyWrite?.contains(w.ws.appending(path: ".git").path) == true)
    }

    @Test func workspaceProfileHasNoSandboxButDeniesDataHome() throws {
        let w = try CompileWorld()
        var r = w.request(nil, profile: .workspace)
        r.deniedPaths = [w.paths.home] + ProtectedPaths.defaults(userHome: w.userHome)
        let s = settings(r)
        #expect(s.sandbox == nil)
        let deny = try #require(s.permissions?.deny)
        for rule in ["Read(/\(w.paths.home.path)/**)", "Edit(/\(w.paths.home.path)/**)", "Read(/\(w.userHome.path)/.ssh/**)",
                     "Edit(/\(w.userHome.path)/.ssh/**)", "Bash(claude *)", "Bash(*/claude *)"] {
            #expect(deny.contains(rule), "missing \(rule)")
        }
        #expect(!deny.contains("Bash(launchctl *)"), "the Bash prefix rules are the sandboxed profile's")
        #expect(s.permissions?.allow == nil)
        #expect(s.disableSkillShellExecution == true)
        // 3a's argv plus the settings file.
        let a = args(r)
        #expect(value(a, "--settings") == r.settingsFilePath)
        #expect(!a.contains("--restricted")); #expect(!a.contains("--tools")); #expect(!a.contains("--permission-prompts"))
        #expect(value(a, "--permission-mode") == "acceptEdits")
        #expect(value(a, "--add-dir") == w.company.workspacePath)
    }

    // MARK: argv

    @Test func sandboxedArgv() throws {
        let w = try CompileWorld()
        let scope = try w.scope(.work)
        let r = w.request(scope)
        let a = args(r)
        #expect(a.contains("--restricted"))
        #expect(value(a, "--tools") == "Bash,Read,Edit,Write,NotebookEdit,Skill,ToolSearch,WebFetch,WebSearch")
        #expect(value(a, "--permission-prompts") == "none")
        #expect(value(a, "--settings") == r.settingsFilePath)
        let i = try #require(a.firstIndex(of: "--setting-sources")); #expect(a[i + 1] == "")
        #expect(a.contains("--strict-mcp-config"))
        #expect(value(a, "--permission-mode") == "acceptEdits")
        #expect(value(a, "--allowed-tools") == "Bash,Read,Edit,Write,Glob,Grep,mcp__company", "3a's list, unchanged")
        #expect(value(a, "--disallowed-tools")?.split(separator: ",").contains("Task") == true)
        #expect(a.contains("--disable-slash-commands"), "no extension parts mount")
        #expect(!a.contains("--plugin-dir"))
        #expect(!(value(a, "--tools") ?? "").contains("Glob")); #expect(!(value(a, "--tools") ?? "").contains("Grep"))
        // The item turn reads no extra directory: the worktree is its cwd.
        #expect(!a.contains("--add-dir"))
        let p = TurnProfileCompiler.profile(for: r)
        #expect(p.workingDirectory == scope.cwd.path)
        #expect(p.environment["CLAUDE_CODE_SHELL_PREFIX"] == w.layout.shellPrefix.path)
        #expect(ChildEnvironment.make(base: [:], extra: p.environment, engineClaudeVars: p.environment,
                                      purpose: .claude)["CLAUDE_CODE_SHELL_PREFIX"] == w.layout.shellPrefix.path)
        #expect(!a.contains("P"), "the prompt is on stdin")

        // With extension parts mounted: no --disable-slash-commands, one --plugin-dir per mount.
        let mount = w.ws.appending(path: ".brahma/ext/acme/abc123/plugin")
        let m = args(w.request(scope, mounts: [mount]))
        #expect(!m.contains("--disable-slash-commands"))
        #expect(value(m, "--plugin-dir") == mount.path)
        #expect(!(value(m, "--tools") ?? "").contains("Glob"))
    }

    @Test func reviewTurnReadsTheWorktreeThroughAddDirOnly() throws {
        let w = try CompileWorld()
        let scope = try w.scope(.review)
        let r = w.request(scope, kind: .review)
        let a = args(r)
        #expect(value(a, "--tools") == "Bash,Read,Skill,ToolSearch")
        let worktree = w.ws.appending(path: ".brahma/wt/\(w.item.key)").path
        #expect(a.indices.filter { a[$0] == "--add-dir" }.map { a[$0 + 1] }.contains(worktree))
        let fs = try #require(settings(r).sandbox?.filesystem)
        #expect(fs.allowRead?.contains(worktree) == true)
        #expect(fs.allowWrite?.contains(worktree) == false)
        // An --add-dir may carry a write grant of the CLI's own: the read-only places are write-denied explicitly.
        #expect(fs.denyWrite?.contains(worktree) == true)
        let deny = try #require(settings(r).permissions?.deny)
        #expect(deny.contains("Edit(/\(worktree)/**)")); #expect(deny.contains("Write(/\(worktree)/**)"))
    }

    @Test func cwdIsALiteralWriteGrant() throws {
        let w = try CompileWorld()
        for kind in [TurnKind.work, .review, .plan] {
            let scope = try w.scope(kind)
            let fs = try #require(settings(w.request(scope, kind: kind)).sandbox?.filesystem)
            #expect(fs.allowWrite?.first == scope.cwd.path, "\(kind): never rely on the CLI's own grant for its cwd")
            #expect(fs.allowRead?.contains(scope.cwd.path) == true)
            #expect(fs.allowWrite?.contains(w.userTemp.path) == true, "the xcrun temp dir (documented residual)")
        }
    }

    @Test func sandboxedProfileWithoutScopeIsRefused() throws {
        let w = try CompileWorld()
        var r = w.request(nil)
        #expect(throws: TurnProfileError.self) { try TurnProfileCompiler.validate(TurnProfileCompiler.profile(for: r)) }
        r = w.request(try w.scope(.work))
        r.settingsFilePath = nil
        #expect(throws: TurnProfileError.self) { try TurnProfileCompiler.validate(TurnProfileCompiler.profile(for: r)) }
        r = w.request(try w.scope(.work))
        r.shellPrefix = nil
        #expect(throws: TurnProfileError.self) { try TurnProfileCompiler.validate(TurnProfileCompiler.profile(for: r)) }
        try TurnProfileCompiler.validate(TurnProfileCompiler.profile(for: w.request(try w.scope(.work))))
    }

    // MARK: Shape and file

    @Test func shapeIgnoresPathsButNotKeys() throws {
        let a = try CompileWorld(name: "Acme"), b = try CompileWorld(name: "Bolt")
        let sa = settings(a.request(try a.scope(.work))), sb = settings(b.request(try b.scope(.work)))
        #expect(sa != sb)
        #expect(sa.shape() == sb.shape())
        var hooked = sa
        hooked.hooks?["PostToolUse"] = [HookMatcher(matcher: "Bash", hooks: [HookCommand(command: "x", args: [])])]
        #expect(hooked.shape() != sa.shape())
        var withPost = settings(a.request(try a.scope(.work)))
        withPost = ClaudeSettingsCompiler.compile(scope: try a.scope(.work), profile: .sandboxed, mode: standard, mounts: [],
                                                  postToolHook: HookCommand(command: "/x/brahma", args: ["hook", "post-tool"]),
                                                  preToolHook: nil)
        #expect(withPost.shape() != sa.shape())
        #expect(withPost.hooks?["PostToolUse"]?.first?.matcher == "WebFetch|WebSearch|Bash|mcp__.*|Skill|Task|Agent")
        #expect(StableHash.fnv1a64("x").count == sa.shape().count)
    }

    @Test func settingsFileIs0600() throws {
        let w = try CompileWorld()
        let r = w.request(try w.scope(.work))
        let path = try #require(r.settingsFilePath)
        let text = json(r)
        try SettingsFile.write(text, to: URL(fileURLWithPath: path))
        #expect(try String(contentsOfFile: path, encoding: .utf8) == text)
        #expect((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) == 0o600)
        // A link at the path is replaced, never followed.
        let target = w.root.appending(path: "elsewhere.json")
        try Data("keep".utf8).write(to: target)
        try FileManager.default.removeItem(atPath: path)
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: target.path)
        try SettingsFile.write(text, to: URL(fileURLWithPath: path))
        #expect(try String(contentsOf: target, encoding: .utf8) == "keep")
        #expect(SandboxPath.kind(path) == .file)
        #expect((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) == 0o600)
        // The run directory is created 0700 when missing.
        let fresh = w.root.appending(path: "fresh-run/a.settings.json")
        try SettingsFile.write(text, to: fresh)
        #expect((try FileManager.default.attributesOfItem(atPath: fresh.deletingLastPathComponent().path)[.posixPermissions] as? Int) == 0o700)
    }

    // MARK: Modes

    @Test func ultracodeNeverEmitted() throws {
        let w = try CompileWorld()
        var ultra = standard
        ultra.mode = .ultra
        ultra.workflow = UltraWorkflow(variant: .small, approver: .policy, maxConcurrentAgents: 2)
        for mode in allModes + [ultra, nil] as [ModeDecision?] {
            for profile in PermissionProfile.allCases {
                for kind in [TurnKind.work, .review, .plan] {
                    let scope = profile == .sandboxed ? try w.scope(kind) : nil
                    let r = w.request(scope, kind: kind, mode: mode, profile: profile)
                    let text = json(r)
                    #expect(!text.contains("ultracode"), "\(profile) \(kind)")
                    #expect(settings(r).ultracode == nil)
                }
            }
        }
    }

    @Test func nonUltraDisablesWorkflowsAndHasNoWorkflowTool() throws {
        let w = try CompileWorld()
        for mode in allModes + [nil] as [ModeDecision?] {
            for profile in PermissionProfile.allCases {
                let r = w.request(profile == .sandboxed ? try w.scope(.work) : nil, mode: mode, profile: profile)
                let s = settings(r)
                #expect(s.disableWorkflows == true); #expect(s.enableWorkflows == nil); #expect(s.workflowSizeGuideline == nil)
                #expect(s.fastMode == false); #expect(s.workflowKeywordTriggerEnabled == false)
                #expect(s.availableModels == ["haiku", "sonnet", "opus"])
                #expect(s.permissions?.allow?.contains("Workflow") != true)
                let a = args(r)
                #expect(!(value(a, "--tools") ?? "").contains("Workflow"))
                #expect(value(a, "--disallowed-tools")?.split(separator: ",").contains("Workflow") == true)
                if let mode { #expect(s.maxEffortLevel == mode.maxEffortLevel.rawValue) } else { #expect(s.maxEffortLevel == nil) }
            }
        }
        // Ultra (Task 14u) only with a workflow policy (an admitted run), only sandboxed.
        var ultra = standard
        ultra.mode = .ultra
        ultra.workflow = UltraWorkflow(variant: .small, approver: .policy, maxConcurrentAgents: 2)
        let s = settings(w.request(try w.scope(.work), mode: ultra))
        #expect(s.enableWorkflows == true); #expect(s.disableWorkflows == nil); #expect(s.workflowSizeGuideline == "small")
        #expect(s.permissions?.allow?.contains("Workflow") == true)
        var noPolicy = ultra
        noPolicy.workflow = nil
        #expect(settings(w.request(try w.scope(.work), mode: noPolicy)).disableWorkflows == true, "no policy: no workflows")
        #expect(settings(w.request(nil, mode: ultra, profile: .workspace)).disableWorkflows == true, "never on the workspace profile")
    }

    @Test func nestedClaudeDeniedAllProfiles() throws {
        let w = try CompileWorld()
        for profile in PermissionProfile.allCases {
            let deny = settings(w.request(profile == .sandboxed ? try w.scope(.work) : nil, profile: profile)).permissions?.deny ?? []
            #expect(deny.contains("Bash(claude *)"), "\(profile)"); #expect(deny.contains("Bash(*/claude *)"), "\(profile)")
        }
    }

    @Test func disableSlashCommandsOnlyWithoutMounts() throws {
        let w = try CompileWorld()
        let skills = ["Skill(deep-research)", "Skill(ultrareview)", "Skill(design)", "Skill(doctor)"]
        let mount = w.ws.appending(path: ".brahma/ext/acme/abc123/plugin")
        for profile in PermissionProfile.allCases {
            let scope = profile == .sandboxed ? try w.scope(.work) : nil
            let plain = w.request(scope, profile: profile)
            #expect(args(plain).contains("--disable-slash-commands"), "\(profile)")
            let plainDeny = Set(settings(plain).permissions?.deny ?? [])
            #expect(plainDeny.isDisjoint(with: skills), "\(profile)")
            let mounted = w.request(scope, mounts: [mount], profile: profile)
            #expect(!args(mounted).contains("--disable-slash-commands"), "\(profile)")
            let deny = settings(mounted).permissions?.deny ?? []
            for rule in skills { #expect(deny.contains(rule), "\(profile) \(rule)") }
        }
    }

    @Test func taskOffUntilGate() throws {
        let w = try CompileWorld()
        #expect(!SubagentGate.passed(profile: .sandboxed))
        for mode in allModes {
            let a = args(w.request(try w.scope(.work), mode: mode))
            #expect(!(value(a, "--tools") ?? "").split(separator: ",").contains("Task"))
            #expect(value(a, "--disallowed-tools")?.split(separator: ",").contains("Task") == true)
            #expect(value(a, "--disallowed-tools")?.split(separator: ",").contains("Agent") == true)
        }
        // Once the gate passes (14u), a Task turn gets Task and, until F7, no web tools.
        var forced = standard
        forced.subagents = .forced(model: "haiku", depth: 1, concurrent: 2)
        let tools = value(args(w.request(try w.scope(.work), mode: forced)), "--tools")?.split(separator: ",").map(String.init) ?? []
        #expect(tools.contains("Task")); #expect(!tools.contains("WebFetch")); #expect(!tools.contains("WebSearch"))
        #expect(BuiltinTools.withTask == BuiltinTools.sandboxed + ["Task"])
        #expect(BuiltinTools.ultra == BuiltinTools.sandboxed + ["Task", "Workflow"])
    }

    @Test func planTurnToolsAndPlansDirectory() throws {
        let w = try CompileWorld()
        let scope = try w.scope(.plan)
        let r = w.request(scope, kind: .plan)
        let a = args(r)
        #expect(value(a, "--tools") == BuiltinTools.plan.joined(separator: ","))
        #expect(BuiltinTools.plan == ["Bash", "Read", "Write", "Skill", "ToolSearch", "WebFetch", "WebSearch"])
        let plans = w.ws.appending(path: ".brahma/plans/\(w.item.key)").path
        #expect(settings(r).plansDirectory == plans)
        #expect(scope.cwd.path == plans)
        #expect(value(a, "--permission-mode") == "plan", "3a's plan mode, unchanged")
        // 3a's plan-turn denials stay (the more restrictive reading): Bash and Write are in --tools but disallowed.
        let denied = value(a, "--disallowed-tools")?.split(separator: ",").map(String.init) ?? []
        for name in ["Edit", "NotebookEdit", "Write", "Bash"] { #expect(denied.contains(name)) }
        // The workspace plan turn keeps 3a's plansDirectory too.
        var ws = w.request(nil, kind: .plan, profile: .workspace)
        ws.planDirectory = plans
        #expect(settings(ws).plansDirectory == plans)
    }

    @Test func workspaceDisablesSkillShellExecution() throws {
        let w = try CompileWorld()
        #expect(settings(w.request(nil, profile: .workspace)).disableSkillShellExecution == true)
        #expect(settings(w.request(nil, profile: .full)).disableSkillShellExecution == true)
        #expect(settings(w.request(try w.scope(.work))).disableSkillShellExecution == nil)
        for profile in PermissionProfile.allCases {
            let s = settings(w.request(profile == .sandboxed ? try w.scope(.work) : nil, profile: profile))
            #expect(s.disableBundledSkills == true)
            #expect(s.enabledPlugins == ["cc-plugin-agents-md@builtin": false, "cc-plugin-plugin-authoring@builtin": false])
        }
        // Full: no sandbox and no path denies.
        let full = settings(w.request(nil, profile: .full))
        #expect(full.sandbox == nil)
        #expect(full.permissions?.deny == ["Bash(claude *)", "Bash(*/claude *)"])
    }

    /// C1: Claude Code wraps every shell-form hook in `CLAUDE_CODE_SHELL_PREFIX` (unsandboxed, so the prefix refuses it and a
    /// PreToolUse hook fails OPEN). Every hook the engine emits is exec form (`command` = the executable, `args`), on every
    /// profile, and blocks when it cannot run (`onFailure: block`).
    @Test func everyHookIsExecForm() throws {
        let w = try CompileWorld()
        for profile in PermissionProfile.allCases {
            var r = w.request(profile == .sandboxed ? try w.scope(.work) : nil, profile: profile)
            r.postToolHook = HookCommand(command: hookExe, args: ["hook", "post-tool"])
            let s = settings(r)
            let pre = try #require(s.hooks?["PreToolUse"])
            #expect(pre == [HookMatcher(matcher: "Agent|Task|Workflow",
                                        hooks: [HookCommand(command: hookExe, args: ["hook", "pre-tool", "--mode", "standard"])])])
            for (_, matchers) in s.hooks ?? [:] {
                for hook in matchers.flatMap(\.hooks) {
                    #expect(hook.onFailure == "block"); #expect(!hook.command.contains(" "), "exec form: one executable")
                }
            }
            let json = try s.json()
            #expect(json.contains("\"args\":[\"hook\",\"pre-tool\",\"--mode\",\"standard\"]"))
            #expect(json.contains("\"onFailure\":\"block\""))
        }
        var forced = standard
        forced.subagents = .forced(model: "haiku", depth: 1, concurrent: 2)
        let s = settings(w.request(try w.scope(.work), mode: forced))
        #expect(s.hooks?["PreToolUse"]?.first?.hooks.first?.args == ["hook", "pre-tool", "--mode", "standard", "--subagents"])
    }

    /// Fix round 2 (A-N2): what validation checks of a hook is what matters: an absolute executable and an encoded `args`. A path
    /// with a space is a fine exec-form executable; a relative one is refused.
    @Test func hookValidationChecksTheExecutableNotItsSpaces() throws {
        let w = try CompileWorld()
        var r = w.request(try w.scope(.work))
        r.hookExecutable = "/Applications/Bra hma.app/Contents/MacOS/brahma"
        try TurnProfileCompiler.validate(TurnProfileCompiler.profile(for: r))
        r.hookExecutable = "brahma"
        #expect(throws: TurnProfileError.self) { try TurnProfileCompiler.validate(TurnProfileCompiler.profile(for: r)) }
    }

    /// Fix round 2 (B-N3): the owner's shared Claude temp places are write-denied too (Claude's default write grant includes
    /// them), in both spellings.
    @Test func sharedClaudeTempIsWriteDenied() throws {
        let w = try CompileWorld()
        let deny = Set(try w.scope(.work).denyWrite.map(\.path))
        for path in ["/private/tmp/claude-\(getuid())", "/tmp/claude-\(getuid())", "/private/tmp/claude", "/tmp/claude",
                     "/private/tmp/claude-tool-results", "/tmp/claude-tool-results"] {
            #expect(deny.contains(path), "\(path)")
        }
    }

    /// Task 2's unremovable marker, adopted for turns: the sandbox allows the turn's own mach name (and no service answers it),
    /// so the engine can recognize the turn's processes by their sandbox alone.
    @Test func sandboxedTurnCarriesItsMachMarker() throws {
        let w = try CompileWorld()
        let r = w.request(try w.scope(.work))
        #expect(settings(r).sandbox?.network?.allowMachLookup == [marker])
        var bad = r
        bad.containmentMarker = nil
        #expect(throws: TurnProfileError.self) { try TurnProfileCompiler.validate(TurnProfileCompiler.profile(for: bad)) }
        bad.containmentMarker = "dev.brahma.run.x"
        #expect(throws: TurnProfileError.self) { try TurnProfileCompiler.validate(TurnProfileCompiler.profile(for: bad)) }
        #expect(settings(w.request(nil, profile: .workspace)).sandbox == nil)
    }

    /// Carry-over: each sandboxed turn's claude keeps its temp files in its own private directory (`CLAUDE_CODE_TMPDIR`, short
    /// enough for Claude Code to use it: probed live), and the shared `/tmp/claude-<uid>` (the owner's own sessions),
    /// `/tmp/claude-tool-results` and every other agent's directory are unreadable.
    @Test func claudeTempIsTheAgentsOwn() throws {
        let w = try CompileWorld()
        let scope = try w.scope(.work)
        let tmp = try #require(scope.claudeTmp)
        #expect(tmp.path.hasPrefix("/private/tmp/b-test/")); #expect(tmp.path.utf8.count <= SandboxScope.claudeTmpMaxLength)
        let p = TurnProfileCompiler.profile(for: w.request(scope))
        #expect(p.environment["CLAUDE_CODE_TMPDIR"] == tmp.path)
        #expect(ChildEnvironment.engineClaudeVars.contains("CLAUDE_CODE_TMPDIR"))
        let deny = Set(scope.denyRead.map(\.path))
        for path in ["/private/tmp/claude-\(getuid())", "/tmp/claude-\(getuid())", "/private/tmp/claude-tool-results",
                     "/tmp/claude-tool-results", "/private/tmp/b-test"] {
            #expect(deny.contains(path), "\(path)")
        }
        let fs = try #require(p.settings.sandbox?.filesystem)
        #expect(fs.allowWrite?.contains(tmp.path) == true); #expect(fs.allowRead?.contains(tmp.path) == true)
        #expect(TurnProfileCompiler.profile(for: w.request(nil, profile: .workspace)).environment["CLAUDE_CODE_TMPDIR"] == nil)
    }

    /// Added (Task 2 twin): the per-user Darwin folder is unreadable to turns, except the toolchain's own entries.
    @Test func darwinUserFolderIsUnreadable() throws {
        let w = try CompileWorld()
        // The world's "T" stands for `<darwin user dir>/T`: its parent is the folder.
        let scope = try w.scope(.work)
        let dir = w.userTemp.deletingLastPathComponent().path
        let fs = try #require(settings(w.request(scope)).sandbox?.filesystem)
        #expect(fs.denyRead?.contains(dir) == true)
        for allowed in ["T/xcrun_db", "T/TemporaryItems", "C/com.apple.DeveloperTools"] {
            #expect(fs.allowRead?.contains("\(dir)/\(allowed)") == true, "\(allowed)")
        }
        #expect(fs.allowRead?.contains(w.userTemp.path) == false, "T itself is not readable")
    }
}
