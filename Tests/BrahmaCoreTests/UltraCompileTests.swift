import Foundation
import Testing
@testable import BrahmaCore

/// A sandboxed world with a real scope, so Ultra compiles the way an orchestrator turn does.
private struct UltraCompileWorld {
    let root: URL, userHome: URL, paths: BrahmaPaths
    let store: Store, company: Company, eng: Agent, item: WorkItem, layout: SandboxLayout

    init() throws {
        root = URL(fileURLWithPath: SandboxPath.resolve(try tempDir().path), isDirectory: false)
        userHome = root.appending(path: "user")
        paths = BrahmaPaths(home: root.appending(path: "data"), workspaces: root.appending(path: "wss"))
        for dir in [userHome, paths.home, paths.workspaces] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        store = try Store(path: paths.database.path)
        company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: paths.workspaces)
        eng = try store.hire(companyId: company.id, name: "eng-1", role: "engineer", model: "sonnet")
        item = try store.createWorkItem(companyId: company.id, by: .owner, draft: WorkItemDraft(type: .task, title: "Thing", ownerId: eng.id,
                                                                                                status: .ready), now: Date())
        layout = SandboxLayout(paths: paths, company: company, agentHandle: "eng-1")
        try layout.ensure()
        let ws = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        try FileManager.default.createDirectory(at: ws.appending(path: ".brahma/wt/\(item.key)"), withIntermediateDirectories: true)
    }

    func request(_ d: ModeDecision?, kind: TurnKind = .work, profile: PermissionProfile = .sandboxed) throws -> TurnRequest {
        var r = TurnRequest(agent: eng, company: company, prompt: "P", appendSystemPrompt: "ROLE",
                            mcpConfigPath: paths.runDir.appending(path: "\(eng.id).mcp.json").path,
                            workingDirectory: company.workspacePath, profile: profile, environment: ["BRAHMA_AGENT_ID": eng.id])
        r.kind = kind
        r.mode = d
        r.hookExecutable = "/usr/local/bin/brahma"
        r.settingsFilePath = paths.runDir.appending(path: "\(eng.id).settings.json").path
        if profile == .sandboxed {
            r.sandbox = try SandboxScope.forTurn(layout: layout, paths: paths, otherWorkspaces: [], backupTargets: [], kind: kind == .review ? .review : .work,
                                                 item: item, company: company, grants: GrantInputs(), darwinUserTemp: nil, userHome: userHome,
                                                 claudeTmpRoot: URL(fileURLWithPath: "/private/tmp/b-test"))
            r.shellPrefix = layout.shellPrefix.path
            r.containmentMarker = "dev.brahma.turn.0123456789abcdef"
        }
        return r
    }
}

/// An admitted Ultra decision as `ModePolicy.select` makes it.
func ultraDecision(_ variant: UltraVariant = .full, approver: UltraApprover = .owner, agents: Int = 2, sessionModel: String? = "sonnet") -> ModeDecision {
    var i = eligibleUltraInputs()
    i.sessionModel = sessionModel
    i.ultra = UltraAdmission(variant: variant, approver: approver, workflowAgents: agents, basis: "confirmed tier L")
    return ModePolicy.select(i)
}

private func value(_ a: [String], _ flag: String) -> String? { a.firstIndex(of: flag).map { a[$0 + 1] } }
private func compiled(_ r: TurnRequest) -> TurnProfile { TurnProfileCompiler.profile(for: r) }

@Suite(.scratch) struct UltraCompileTests {
    @Test func selectCompilesR5FromAnAdmission() {
        let d = ultraDecision(.small, approver: .policy, sessionModel: "opus")
        #expect(d.mode == .ultra); #expect(d.rung == .r5); #expect(d.rung.level == 5)
        #expect(d.model == "opus", "Ultra keeps the session model"); #expect(d.effort == .high); #expect(d.maxEffortLevel == .high)
        #expect(d.maxTurns == 100); #expect(d.maxBudgetUSD == 4); #expect(d.wallClock == .seconds(45 * 60))
        #expect(d.subagents == .forced(model: "sonnet", depth: 1, concurrent: 3))
        #expect(d.workflow == UltraWorkflow(variant: .small, approver: .policy, maxConcurrentAgents: 2))
        #expect(d.reason.contains("Ultra-small (R5) approved by Brahma policy: confirmed tier L"))
        // A refusal runs the computed rung and records why.
        var refused = eligibleUltraInputs(); refused.ultraRefusal = "allowance used"
        let r = ModePolicy.select(refused)
        #expect(r.mode != .ultra); #expect(r.workflow == nil); #expect(r.reason.contains("Ultra not admitted: allowance used"))
        // Never on a review turn, whatever the inputs say.
        var review = eligibleUltraInputs(); review.turnKind = .review
        review.ultra = UltraAdmission(variant: .full, approver: .owner, workflowAgents: 2, basis: "x")
        #expect(ModePolicy.select(review).mode != .ultra)
    }

    @Test func ultraHasThreeWorkflowLocks() throws {
        let w = try UltraCompileWorld()
        let p = compiled(try w.request(ultraDecision()))
        try TurnProfileCompiler.validate(p)
        let a = TurnProfileCompiler.arguments(p)
        // (a) settings, (b) --tools, (c) permissions.allow.
        #expect(p.settings.enableWorkflows == true); #expect(p.settings.disableWorkflows == nil)
        #expect(p.settings.workflowSizeGuideline == "medium")
        #expect(value(a, "--tools")?.split(separator: ",").map(String.init) == BuiltinTools.ultraBeforeF7)
        #expect(p.settings.permissions?.allow?.contains("Workflow") == true)
        #expect(!(value(a, "--disallowed-tools") ?? "").split(separator: ",").contains("Workflow"))
        #expect(value(a, "--model") == "sonnet"); #expect(value(a, "--effort") == "high")
        #expect(value(a, "--max-turns") == "100"); #expect(value(a, "--max-budget-usd") == "15.00")
        #expect(p.settings.maxEffortLevel == "high")
        #expect(p.environment["CLAUDE_CODE_DISABLE_WORKFLOWS"] == nil)
        // The pre-tool hook runs as an Ultra turn with sub-agents.
        #expect(p.settings.hooks?["PreToolUse"]?.first?.hooks.first?.args.prefix(5) == ["hook", "pre-tool", "--mode", "ultra", "--subagents"])
        // Its init must offer Workflow; the forced worker may bill.
        let e = TurnProfileCompiler.expectations(for: ultraDecision(), agents: nil)
        #expect(e.requiredTools == ["Workflow"]); #expect(e.forbiddenTools.isEmpty); #expect(e.extraModels.contains("sonnet"))
        // Small is `small`.
        #expect(compiled(try w.request(ultraDecision(.small))).settings.workflowSizeGuideline == "small")
    }

    @Test func ultraHasSubagentCaps() throws {
        let w = try UltraCompileWorld()
        for (agents, expected) in [(2, "2"), (4, "4")] {
            let env = compiled(try w.request(ultraDecision(agents: agents))).environment
            #expect(env["CLAUDE_CODE_SUBAGENT_MODEL"] == "sonnet"); #expect(env["CLAUDE_CODE_SUBAGENT_MODEL_FORCE"] == "1")
            #expect(env["CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH"] == "1"); #expect(env["CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS"] == "3")
            #expect(env["CLAUDE_CODE_DISABLE_BACKGROUND_TASKS"] == "1"); #expect(env["CLAUDE_CODE_DISABLE_FAST_MODE"] == "1")
            #expect(env["CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS"] == expected)
            for name in env.keys where name.hasPrefix("CLAUDE_CODE_") {
                #expect(ChildEnvironment.engineClaudeVars.contains(name), "\(name) reaches the child only through the allowlist")
            }
        }
        #expect(UltraCaps.max5x.workflowAgents == 2); #expect(UltraCaps.max20x.workflowAgents == 4)
    }

    @Test func ultraDeniesHighRiskMcpAndSkills() throws {
        let w = try UltraCompileWorld()
        let deny = Set(compiled(try w.request(ultraDecision())).settings.permissions?.deny ?? [])
        for tool in ["decide", "propose_decision", "escalate_decision", "request_from_owner", "request_access", "request_secret",
                     "plan_sprint", "close_sprint", "propose_extension", "request_mode"] {
            #expect(deny.contains("mcp__company__\(tool)"), "\(tool)")
        }
        #expect(deny.contains("Skill(deep-research)")); #expect(deny.contains("Skill(ultrareview)"))
        #expect(deny.contains("Bash(claude *)"))
        // A Standard turn denies none of them.
        let standard = ModePolicy.select({ var i = eligibleUltraInputs(); i.tier = .s; return i }())
        #expect(!(compiled(try w.request(standard)).settings.permissions?.deny ?? []).contains("mcp__company__decide"))
    }

    @Test func nonUltraNeverEnablesWorkflows() throws {
        let w = try UltraCompileWorld()
        var inputs = eligibleUltraInputs(); inputs.tier = .m
        for d in [ModePolicy.select(inputs), ModePolicy.select({ var i = inputs; i.turnKind = .notice; return i }())] {
            for profile in PermissionProfile.allCases {
                let p = compiled(try w.request(d, profile: profile))
                #expect(p.settings.enableWorkflows == nil); #expect(p.settings.disableWorkflows == true)
                #expect(p.environment["CLAUDE_CODE_DISABLE_WORKFLOWS"] == "1")
                #expect(!(p.tools ?? []).contains("Workflow")); #expect(p.disallowedTools.contains("Workflow"))
            }
        }
        // Ultra on a review turn compiles no workflow either.
        let review = compiled(try w.request(ultraDecision(), kind: .review))
        #expect(review.settings.enableWorkflows == nil); #expect(!(review.tools ?? []).contains("Workflow"))
    }

    @Test func ultracodeNeverEmitted() throws {
        let w = try UltraCompileWorld()
        for profile in PermissionProfile.allCases {
            let p = compiled(try w.request(ultraDecision(), profile: profile))
            #expect(p.settings.ultracode == nil)
            #expect(!(try TurnProfileCompiler.settingsJSON(p)).contains("ultracode"))
            #expect(!TurnProfileCompiler.arguments(p).joined(separator: " ").contains("ultracode"))
        }
    }

    @Test func ultraDigestNamesActualApprover() {
        let owner = UltraDigest.line(UltraWorkflow(variant: .full, approver: .owner, maxConcurrentAgents: 2))
        #expect(owner == "This turn is opted into multi-agent orchestration (approved by: owner): you may use the Workflow tool with an "
                + "inline script. Hard cap $15.00 LE; at most 10 agents, or the turn is stopped.")
        let policy = UltraDigest.line(UltraWorkflow(variant: .small, approver: .policy, maxConcurrentAgents: 2))
        #expect(policy.contains("(approved by: Brahma policy)")); #expect(!policy.contains("owner"))
        #expect(policy.contains("Hard cap $4.00 LE; at most 5 agents"))
    }

    @Test func bgCeilingBelowWallClock() throws {
        #expect(UltraVariant.bgCeiling == UltraVariant.wallClock - .seconds(300))
        #expect(UltraVariant.bgCeilingMilliseconds == 2_400_000)
        let w = try UltraCompileWorld()
        let p = compiled(try w.request(ultraDecision()))
        #expect(p.environment["CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS"] == "2400000")
        #expect(p.wallClock == .seconds(45 * 60))
    }

    /// S26: every high-risk company tool is denied on Ultra (the set, so a later addition is covered), and the high-risk quota is
    /// 0, which refuses a spec or assignee change through `update_work_item` (no deny rule can target its arguments).
    @Test func ultraDeniesEveryHighRiskToolAndRefusesSpecEdits() throws {
        let w = try UltraCompileWorld()
        let d = ultraDecision()
        let deny = Set(compiled(try w.request(d)).settings.permissions?.deny ?? [])
        for tool in CompanyTools.highRiskTools { #expect(deny.contains("mcp__company__\(tool)"), "\(tool)") }
        #expect(deny.contains("mcp__company__confirm_spec")); #expect(deny.contains("mcp__company__readopt_branch"))
        // Fix round 2, N5: no test key reaches an Ultra turn.
        #expect(deny.contains("mcp__company__use_secret"))
        let standard = ModePolicy.select({ var i = eligibleUltraInputs(); i.tier = .s; return i }())
        #expect(!(compiled(try w.request(standard)).settings.permissions?.deny ?? []).contains("mcp__company__use_secret"))
        #expect(d.quotas.highRisk == 0)
        let tools = CompanyTools(store: w.store, companyId: w.company.id, agentId: w.eng.id, quotas: d.quotas)
        #expect {
            try tools.call(name: "update_work_item", arguments: ["key": .string(w.item.key), "title": .string("A bigger thing")])
        } throws: { "\($0)".contains("high-risk") }
        #expect(try w.store.workItem(id: w.item.id)?.title == "Thing")
    }

    /// I1: before F7-agents passed an Ultra turn has neither web tools nor Task; after, the full Ultra tool set.
    @Test func ultraHasNoWebOrTaskBeforeF7() throws {
        let w = try UltraCompileWorld()
        let before = compiled(try w.request(ultraDecision()))
        let tools = before.tools ?? []
        #expect(tools.contains("Workflow"))
        for t in ["WebFetch", "WebSearch", "Task"] { #expect(!tools.contains(t), "\(t)") }
        #expect(before.disallowedTools.contains("Task")); #expect(before.disallowedTools.contains("Agent"))
        #expect(!before.allowedTools.contains("Task"))
        var r = try w.request(ultraDecision())
        r.taskWebTools = true
        let after = compiled(r)
        #expect(after.tools == BuiltinTools.ultra); #expect(!after.disallowedTools.contains("Task"))
    }

    /// The built-in agents switch (F7): never emitted, and dropped by the child environment, until F7-agents passed.
    @Test func builtinAgentsSwitchOnlyAfterF7() throws {
        let w = try UltraCompileWorld()
        let name = ChildEnvironment.builtinAgentsSwitch
        #expect(name == "CLAUDE_AGENT_SDK_DISABLE_BUILTIN_AGENTS")
        var task = ModePolicy.select({ var i = ModeInputs(); i.hasItem = true; i.tier = .s; i.subagentGate = true; return i }())
        task.maxBudgetUSD = 1
        for d in [ultraDecision(), task] {
            let off = compiled(try w.request(d))
            #expect(off.environment[name] == nil); #expect(!off.builtinAgentsDisabled)
            // Even handed the variable, the child environment drops it.
            let env = ChildEnvironment.make(base: ["PATH": "/usr/bin"], extra: [:], engineClaudeVars: [name: "1"], purpose: .claude,
                                            allowBuiltinAgentsSwitch: off.builtinAgentsDisabled)
            #expect(env[name] == nil)
            var r = try w.request(d)
            r.taskWebTools = true
            let on = compiled(r)
            #expect(on.environment[name] == "1"); #expect(on.builtinAgentsDisabled)
            let child = ChildEnvironment.make(base: ["PATH": "/usr/bin"], extra: on.environment, engineClaudeVars: on.environment,
                                              purpose: .claude, allowBuiltinAgentsSwitch: on.builtinAgentsDisabled)
            #expect(child[name] == "1")
        }
        // Never on a turn that does not fan out, nor on a review turn.
        var plain = try w.request(ModePolicy.select({ var i = ModeInputs(); i.hasItem = true; i.tier = .s; return i }()))
        plain.taskWebTools = true
        #expect(compiled(plain).environment[name] == nil)
        var review = try w.request(ultraDecision(), kind: .review)
        review.taskWebTools = true
        #expect(compiled(review).environment[name] == nil)
        // A general-purpose child never gets it.
        #expect(ChildEnvironment.make(base: [:], engineClaudeVars: [name: "1"], purpose: .general, allowBuiltinAgentsSwitch: true)[name] == nil)
    }

    @Test func ultraOnlySandboxed() throws {
        let w = try UltraCompileWorld()
        for profile in [PermissionProfile.workspace, .full] {
            let p = compiled(try w.request(ultraDecision(), profile: profile))
            #expect(p.workflow == nil); #expect(p.subagents == .off, "\(profile)")
            #expect(p.settings.enableWorkflows == nil); #expect(p.settings.disableWorkflows == true)
            #expect(p.environment["CLAUDE_CODE_DISABLE_WORKFLOWS"] == "1")
            #expect(p.environment["CLAUDE_CODE_WORKFLOW_MAX_CONCURRENT_AGENTS"] == nil)
            #expect(p.environment["CLAUDE_CODE_SUBAGENT_MODEL"] == nil)
            #expect(p.disallowedTools.contains("Workflow")); #expect(p.disallowedTools.contains("Task")); #expect(p.disallowedTools.contains("Agent"))
            #expect(!p.allowedTools.contains("Task"))
            #expect(p.settings.permissions?.allow?.contains("Workflow") != true)
            #expect(p.settings.hooks?["PreToolUse"]?.first?.hooks.first?.args.contains("--subagents") == false)
        }
    }
}
