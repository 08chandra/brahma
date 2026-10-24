import Foundation
import Testing
@testable import BrahmaCore

private func agent(started: Bool = false, model: String = "auto") -> Agent {
    Agent(id: "a1", companyId: "c1", name: "eng", role: "engineer", model: model,
          sessionId: "7081f66a-b7b1-4f6f-96e7-c690d4b0cec0", sessionStarted: started,
          state: .ready, blocker: nil, requestedBlocker: nil, paused: false,
          readySince: nil, createdAt: Date(timeIntervalSince1970: 0))
}

private let company = Company(id: "c1", name: "Acme", slug: "acme", goal: "g", workspacePath: "/tmp/ws/acme",
                              status: .running, usageMode: .balanced, priorityWeight: 1,
                              createdAt: Date(timeIntervalSince1970: 0))

private let hook = "'/usr/local/bin/brahma' hook pre-tool"
private let disallowed = ClaudeCommand.disallowedTools.joined(separator: ",")

private func decision(_ edit: (inout ModeInputs) -> Void) -> ModeDecision {
    var i = ModeInputs()
    i.hasItem = true
    i.tier = .s
    i.budgetLeftLE = 100
    edit(&i)
    return ModePolicy.select(i)
}

private func request(_ d: ModeDecision?, kind: TurnKind = .work, prompt: String = "P", started: Bool = false) -> TurnRequest {
    var r = TurnRequest(agent: agent(started: started), company: company, prompt: prompt, appendSystemPrompt: "ROLE PROMPT",
                        mcpConfigPath: "/tmp/run/a1.mcp.json", workingDirectory: "/tmp/ws/acme", profile: .workspace,
                        environment: ["BRAHMA_AGENT_ID": "a1"])
    r.mode = d
    r.kind = kind
    r.hookCommand = d == nil ? nil : hook
    return r
}

private func args(_ r: TurnRequest) -> [String] { TurnProfileCompiler.arguments(TurnProfileCompiler.profile(for: r)) }
private func value(_ a: [String], _ flag: String) -> String? { a.firstIndex(of: flag).map { a[$0 + 1] } }
private func settings(_ a: [String]) throws -> [String: Any] {
    let json = try #require(value(a, "--settings"))
    return try #require(try JSONSerialization.jsonObject(with: Data(json.utf8)) as? [String: Any])
}

private let quick = decision { $0.turnKind = .notice }
private let standard = decision { _ in }
private let deep = decision { $0.tier = .m; $0.riskTags = ["hotPath"] }
private let deepOpus = decision { $0.tier = .l }
private let allModes = [quick, standard, deep, deepOpus]

@Suite struct ModeProfileTests {
    /// Fix 1 minor: the L-4 gate really gates the per-mode caps.
    @Test func perModeCapsGateEmitsTheCaps() {
        #expect(ModeGates.perModeCaps)
        var on = TurnProfileCompiler.profile(for: request(standard))
        #expect(on.maxTurns == 40); #expect(on.maxBudgetUSD == 2.00)
        on.maxTurns = nil; on.maxBudgetUSD = nil
        TurnProfileCompiler.apply(standard, to: &on, hookCommand: hook, kind: .work, perModeCaps: false)
        #expect(on.maxTurns == nil); #expect(on.maxBudgetUSD == nil)
        let a = TurnProfileCompiler.arguments(on)
        #expect(!a.contains("--max-turns")); #expect(!a.contains("--max-budget-usd")); #expect(a.contains("--effort"))
    }

    @Test func quickHasNoTaskAndWorkflowKillSwitches() throws {
        let a = args(request(quick))
        // 3a's keys plus 5-lite's (Task 1b): disableBundledSkills, disableSkillShellExecution, the two builtin plugins off, and
        // the nested-claude denies.
        let settingsJSON = "{\"availableModels\":[\"haiku\",\"sonnet\",\"opus\"],\"disableBundledSkills\":true,"
            + "\"disableSkillShellExecution\":true,\"disableWorkflows\":true,\"enabledPlugins\":{\"cc-plugin-agents-md@builtin\":false,"
            + "\"cc-plugin-plugin-authoring@builtin\":false},"
            + "\"fastMode\":false,\"hooks\":{\"PreToolUse\":[{\"hooks\":[{\"command\":\"\(hook) --mode quick\","
            + "\"type\":\"command\"}],\"matcher\":\"Agent|Task|Workflow\"}]},\"maxEffortLevel\":\"low\","
            + "\"permissions\":{\"deny\":[\"Bash(claude *)\",\"Bash(*/claude *)\"]},\"workflowKeywordTriggerEnabled\":false}"
        #expect(a == [
            "-p", "--output-format", "stream-json", "--verbose",
            "--model", "haiku", "--fallback-model", "sonnet",
            "--setting-sources", "", "--settings", settingsJSON, "--disable-slash-commands",
            "--strict-mcp-config", "--mcp-config", "/tmp/run/a1.mcp.json",
            "--disallowed-tools", disallowed,
            "--session-id", "7081f66a-b7b1-4f6f-96e7-c690d4b0cec0", "--append-system-prompt", "ROLE PROMPT",
            "--permission-mode", "acceptEdits",
            "--allowed-tools", "Bash,Read,Edit,Write,Glob,Grep,mcp__company",
            "--add-dir", "/tmp/ws/acme",
            "--effort", "low", "--max-turns", "10", "--max-budget-usd", "0.30",
        ])
        let p = TurnProfileCompiler.profile(for: request(quick))
        #expect(p.environment["CLAUDE_CODE_DISABLE_FAST_MODE"] == "1")
        #expect(p.environment["CLAUDE_CODE_DISABLE_WORKFLOWS"] == "1")
        #expect(p.environment["CLAUDE_CODE_SUBAGENT_MODEL"] == nil)
        #expect(p.wallClock == .seconds(300))
    }

    @Test func workspaceDisallowsTask() {
        for d in allModes {
            let denied = value(args(request(d)), "--disallowed-tools")!.split(separator: ",").map(String.init)
            #expect(denied.contains("Task")); #expect(denied.contains("Agent")); #expect(denied.contains("Workflow"))
            let e = TurnProfileCompiler.expectations(for: d, agents: nil)
            #expect(e.forbiddenTools.isSuperset(of: ["Task", "Agent", "Workflow"]))
        }
    }

    @Test func standardForcesHaikuWorkersDepth1() throws {
        // Only once the sub-agent gate passes (never on the 3a workspace profile).
        var d = standard
        d.subagents = .forced(model: "haiku", depth: 1, concurrent: 2)
        let p = TurnProfileCompiler.profile(for: request(d))
        let a = TurnProfileCompiler.arguments(p)
        let denied = value(a, "--disallowed-tools")!.split(separator: ",").map(String.init)
        #expect(!denied.contains("Task")); #expect(!denied.contains("Agent")); #expect(denied.contains("Workflow"))
        #expect(value(a, "--allowed-tools")!.split(separator: ",").contains("Task"))
        #expect(p.environment["CLAUDE_CODE_SUBAGENT_MODEL"] == "haiku")
        #expect(p.environment["CLAUDE_CODE_SUBAGENT_MODEL_FORCE"] == "1")
        #expect(p.environment["CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH"] == "1")
        #expect(p.environment["CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS"] == "2")
        #expect(p.environment["CLAUDE_CODE_DISABLE_BACKGROUND_TASKS"] == "1")
        #expect(TurnProfileCompiler.expectations(for: d, agents: nil).extraModels == ["haiku"])
        // Before the gate: identical except Task is denied and the sub-agent variables are absent.
        let off = TurnProfileCompiler.profile(for: request(standard))
        #expect(off.environment["CLAUDE_CODE_SUBAGENT_MODEL"] == nil)
    }

    @Test func deepForcesSonnetWorkers() {
        var d = deep
        d.subagents = .forced(model: "sonnet", depth: 1, concurrent: 3)
        let p = TurnProfileCompiler.profile(for: request(d))
        #expect(p.environment["CLAUDE_CODE_SUBAGENT_MODEL"] == "sonnet")
        #expect(p.environment["CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS"] == "3")
        #expect(value(TurnProfileCompiler.arguments(p), "--effort") == "high")
    }

    @Test func nonUltraNeverEnablesWorkflows() throws {
        for d in allModes {
            let a = args(request(d))
            let s = try settings(a)
            #expect(s["disableWorkflows"] as? Bool == true); #expect(s["enableWorkflows"] == nil)
            #expect(!value(a, "--allowed-tools")!.contains("Workflow"))
            #expect(TurnProfileCompiler.profile(for: request(d)).environment["CLAUDE_CODE_DISABLE_WORKFLOWS"] == "1")
        }
    }

    @Test func everyModeHasExplicitModelEffortTurnsBudgetWallClock() {
        for (d, effort, turns, budget, wall) in [(quick, "low", "10", "0.30", 300), (standard, "medium", "40", "2.00", 1200),
                                                 (deep, "high", "60", "5.00", 1800), (deepOpus, "medium", "60", "8.00", 1800)] {
            let p = TurnProfileCompiler.profile(for: request(d))
            let a = TurnProfileCompiler.arguments(p)
            #expect(value(a, "--model") == d.model); #expect(value(a, "--effort") == effort)
            #expect(value(a, "--max-turns") == turns); #expect(value(a, "--max-budget-usd") == budget)
            #expect(p.wallClock == .seconds(wall))
        }
        #expect(value(args(request(deepOpus)), "--model") == "opus")
        // A small remaining budget lowers the cap and keeps its digits.
        let tight = decision { $0.budgetLeftLE = 0.0425 }
        #expect(value(args(request(tight)), "--max-budget-usd") == "0.0425")
    }

    @Test func fastModeOffEverywhere() throws {
        for d in allModes {
            #expect(try settings(args(request(d)))["fastMode"] as? Bool == false)
            #expect(TurnProfileCompiler.profile(for: request(d)).environment["CLAUDE_CODE_DISABLE_FAST_MODE"] == "1")
        }
    }

    @Test func availableModelsEverywhere() throws {
        for d in allModes { #expect(try settings(args(request(d)))["availableModels"] as? [String] == ["haiku", "sonnet", "opus"]) }
    }

    @Test func preToolHookEverywhere() throws {
        for d in allModes {
            let s = try settings(args(request(d)))
            let pre = try #require((s["hooks"] as? [String: Any])?["PreToolUse"] as? [[String: Any]])
            #expect(pre.count == 1)
            #expect(pre[0]["matcher"] as? String == "Agent|Task|Workflow")
            let command = (pre[0]["hooks"] as? [[String: Any]])?.first?["command"] as? String
            #expect(command == "\(hook) --mode \(d.mode.rawValue)")
        }
        #expect(TurnProfileCompiler.hookCommand(executable: "/Applications/Bra hma.app/brahma") == "'/Applications/Bra hma.app/brahma' hook pre-tool")
        #expect(TurnProfileCompiler.hookCommand(executable: "/x/it's") == "'/x/it'\\''s' hook pre-tool")
    }

    @Test func modelAllowlistRejectsFableBestDefaultOpusplan1m() throws {
        for bad in ["fable", "best", "default", "opusplan", "sonnet[1m]", "claude-sonnet-4-6", "claude-fable-1", "opus[1m]"] {
            #expect(!ModelAllowlist.allows(bad), "\(bad)")
            var r = request(standard)
            r.agent.model = bad
            var d = standard; d.model = bad
            r.mode = d
            #expect(throws: TurnProfileError.self) { try TurnProfileCompiler.validate(TurnProfileCompiler.profile(for: r)) }
        }
        for good in ["haiku", "sonnet", "opus", "claude-haiku-5-5", "claude-sonnet-5-5", "claude-opus-5-5"] {
            #expect(ModelAllowlist.allows(good))
        }
        try TurnProfileCompiler.validate(TurnProfileCompiler.profile(for: request(standard)))
    }

    @Test func ownerPinStillAllowlisted() {
        var i = ModeInputs(); i.hasItem = true; i.tier = .s; i.agentModel = "opus"
        let pinned = ModePolicy.select(i)
        #expect(pinned.model == "opus"); #expect(pinned.launch)
        i.agentModel = "best"
        let refused = ModePolicy.select(i)
        #expect(!refused.launch); #expect(refused.refusal?.contains("not allowed") == true)
    }

    @Test func planTurnHasPlanModePlansDirectoryNoEditNoTask() throws {
        var p = ModeInputs(); p.hasItem = true; p.tier = .l; p.turnKind = .plan; p.budgetLeftLE = 100
        var r = request(ModePolicy.select(p), kind: .plan)
        r.planDirectory = "/tmp/ws/acme/.brahma/plans/ACME-1"
        let a = args(r)
        #expect(value(a, "--permission-mode") == "plan")
        let denied = value(a, "--disallowed-tools")!.split(separator: ",").map(String.init)
        for name in ["Task", "Agent", "Edit", "NotebookEdit", "Workflow"] { #expect(denied.contains(name), "\(name)") }
        #expect(try settings(a)["plansDirectory"] as? String == "/tmp/ws/acme/.brahma/plans/ACME-1")
        #expect(value(a, "--effort") == "medium"); #expect(value(a, "--max-turns") == "25"); #expect(value(a, "--max-budget-usd") == "4.00")
    }

    @Test func keywordTriggerOff() throws {
        for d in allModes { #expect(try settings(args(request(d)))["workflowKeywordTriggerEnabled"] as? Bool == false) }
    }

    @Test func ultracodeNeverEmitted() throws {
        for d in allModes {
            let a = args(request(d))
            #expect(try settings(a)["ultracode"] == nil)
            #expect(!a.joined(separator: " ").contains("ultracode")); #expect(!a.contains("--advisor"))
            #expect(!a.contains("--thinking")); #expect(!a.contains("--max-thinking-tokens"))
        }
    }

    @Test func engineClaudeVarsOnlyFromCompiler() {
        // Only the listed CLAUDE_CODE_* controls pass, and only from what the engine put on the request; the owner's own
        // environment never supplies them, and the never-passed list is dropped even when the engine names it.
        let base = ["PATH": "/bin", "CLAUDE_CODE_DISABLE_FAST_MODE": "0", "CLAUDE_CODE_SUBAGENT_MODEL": "opus"]
        let engine = ["CLAUDE_CODE_DISABLE_FAST_MODE": "1", "CLAUDE_CODE_EFFORT_LEVEL": "max", "CLAUDE_CODE_WORKFLOWS": "1",
                      "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1", "CLAUDE_CODE_SOMETHING_NEW": "x", "MAX_THINKING_TOKENS": "1",
                      "CLAUDE_AGENT_SDK_DISABLE_BUILTIN_AGENTS": "1"]
        let env = ChildEnvironment.make(base: base, extra: [:], engineClaudeVars: engine, purpose: .claude)
        #expect(env["CLAUDE_CODE_DISABLE_FAST_MODE"] == "1")
        for name in ["CLAUDE_CODE_EFFORT_LEVEL", "CLAUDE_CODE_WORKFLOWS", "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS",
                     "CLAUDE_CODE_SOMETHING_NEW", "MAX_THINKING_TOKENS", "CLAUDE_AGENT_SDK_DISABLE_BUILTIN_AGENTS",
                     "CLAUDE_CODE_SUBAGENT_MODEL"] {
            #expect(env[name] == nil, "\(name)")
        }
        #expect(ChildEnvironment.engineClaudeVars.contains("CLAUDE_CODE_SHELL_PREFIX"))
        #expect(ChildEnvironment.engineClaudeVars.count == 10)
        // Everything the compiler emits is on the list.
        var d = standard; d.subagents = .forced(model: "haiku", depth: 1, concurrent: 2)
        for name in TurnProfileCompiler.profile(for: request(d)).environment.keys where name.hasPrefix("CLAUDE_CODE_") {
            #expect(ChildEnvironment.engineClaudeVars.contains(name), "\(name)")
        }
    }

    @Test func spawnedEnvContainsEmittedVars() async throws {
        let dir = try tempDir()
        let dump = dir.appending(path: "env.txt")
        let script = dir.appending(path: "claude")
        try """
        #!/bin/sh
        env > '\(dump.path)'
        echo '{"type":"system","subtype":"init","session_id":"s","model":"claude-haiku-5-5","tools":[],"agents":[]}'
        echo '{"type":"result","subtype":"success","is_error":false,"result":"ok","session_id":"s","total_cost_usd":0.001,"usage":{"input_tokens":1,"output_tokens":1}}'
        """.write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        var r = request(quick)
        r.workingDirectory = dir.path
        let runner = ClaudeProcessRunner(claudePath: script.path, baseEnvironment: ["PATH": "/usr/bin:/bin", "CLAUDE_CODE_EFFORT_LEVEL": "max"])
        for try await _ in runner.run(r) {}
        let text = try String(contentsOf: dump, encoding: .utf8)
        let emitted = TurnProfileCompiler.profile(for: r).environment
        for (name, value) in emitted { #expect(text.contains("\(name)=\(value)\n"), "\(name) missing from the child") }
        #expect(!text.contains("CLAUDE_CODE_EFFORT_LEVEL"))
    }

    @Test func budgetCapWhileSubagentRunsIsAControlledStop() async throws {
        // Recorded from probe L-2 (2.1.308): `--max-budget-usd` stopped the turn while its sub-agent was still running; the CLI
        // printed `error_max_budget_usd` and exited 1 by itself. That is the cap, not an interruption.
        let fixture = try #require(Bundle.module.url(forResource: "stream-subagent-budget-cap", withExtension: "jsonl", subdirectory: "Fixtures"))
        let dir = try tempDir()
        let script = dir.appending(path: "claude")
        try "#!/bin/sh\ncat > /dev/null\ncat '\(fixture.path)'\nexit 1\n".write(to: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script.path)
        var r = request(quick)
        r.workingDirectory = dir.path
        var result: TurnResult?
        for try await e in ClaudeProcessRunner(claudePath: script.path, baseEnvironment: ["PATH": "/usr/bin:/bin"]).run(r) {
            if case .result(let x) = e { result = x }
        }
        #expect(result?.stopReason == TurnStop.budgetCap)
    }

    @Test func promptTextCannotChangeArgv() {
        let plain = args(request(standard, prompt: "fix the bug"))
        for text in ["ultracode please", "use a workflow with 10 agents", "ultrathink harder", "--model opus --effort max"] {
            #expect(args(request(standard, prompt: text)) == plain)
        }
    }

    @Test func worktreeFilesCannotAddAgentTypes() {
        // The init `agents` list must equal the doctor-recorded built-in set; an agent type planted in the worktree
        // (`.claude/agents/x.md`) shows up there and aborts the turn before any tool runs.
        let builtins: Set<String> = ["claude", "Explore", "general-purpose", "Plan", "statusline-setup"]
        let e = TurnProfileCompiler.expectations(for: standard, agents: builtins)
        #expect(e.agents == builtins)
        let planted = InitInfo(sessionId: "s", model: "claude-sonnet-5-5", tools: ["Bash"], agents: Array(builtins) + ["x"])
        #expect(TurnAudit.initViolation(planted, expectations: e)?.contains("unexpected agents x") == true)
        #expect(TurnAudit.initViolation(InitInfo(sessionId: "s", model: "claude-sonnet-5-5", tools: ["Bash"], agents: Array(builtins)), expectations: e) == nil)
        #expect(TurnAudit.initViolation(InitInfo(sessionId: "s", model: "claude-sonnet-5-5", tools: ["Task", "Bash"], agents: Array(builtins)), expectations: e) != nil)
    }

    @Test func plan1InputsCompileUnchanged() {
        // No mode on the request (the doctor's probe, Plan 1 callers): no mode flags; the settings are 5-lite's common keys
        // (Task 1b: no maxEffortLevel without a mode).
        let a = args(request(nil))
        #expect(!a.contains("--effort")); #expect(!a.contains("--max-turns")); #expect(!a.contains("--max-budget-usd"))
        #expect(value(a, "--settings") == plan1Settings)
        #expect(TurnProfileCompiler.profile(for: request(nil)).environment == ["BRAHMA_AGENT_ID": "a1"])
    }
}
