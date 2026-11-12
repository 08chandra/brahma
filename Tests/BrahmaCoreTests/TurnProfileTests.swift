import Foundation
import Testing
@testable import BrahmaCore

private func agent(started: Bool) -> Agent {
    Agent(id: "a1", companyId: "c1", name: "ceo", role: "ceo", model: "opus",
          sessionId: "7081f66a-b7b1-4f6f-96e7-c690d4b0cec0", sessionStarted: started,
          state: .ready, blocker: nil, requestedBlocker: nil, paused: false,
          readySince: nil, createdAt: Date(timeIntervalSince1970: 0))
}

private let company = Company(id: "c1", name: "Acme", slug: "acme", goal: "g", workspacePath: "/tmp/ws/acme",
                              status: .running, usageMode: .balanced, priorityWeight: 1,
                              createdAt: Date(timeIntervalSince1970: 0))

private func request(started: Bool, profile: PermissionProfile = .workspace) -> TurnRequest {
    TurnRequest(agent: agent(started: started), company: company, prompt: "P", appendSystemPrompt: "ROLE PROMPT",
                mcpConfigPath: "/tmp/run/a1.mcp.json", workingDirectory: "/tmp/ws/acme", profile: profile)
}

private let disallowed = ClaudeCommand.disallowedTools.joined(separator: ",")
/// The settings every Workspace turn carries since 5-lite Task 1b (3a's was `{"enabledPlugins":{}}`): bundled skills and the two
/// builtin plugins off, skill shell execution off, nested `claude` denied, the workflow and fast-mode kill switches.
let plan1Settings = "{\"availableModels\":[\"haiku\",\"sonnet\",\"opus\"],\"disableBundledSkills\":true,"
    + "\"disableSkillShellExecution\":true,\"disableWorkflows\":true,\"enabledPlugins\":{"
    + "\"cc-plugin-agents-md@builtin\":false,\"cc-plugin-claude-platform@builtin\":false,\"cc-plugin-claude-test@builtin\":false,\"cc-plugin-diff@builtin\":false,\"cc-plugin-easel@builtin\":false,\"cc-plugin-mermaid@builtin\":false,\"cc-plugin-mods-guide@builtin\":false,\"cc-plugin-plugin-authoring@builtin\":false,\"cc-plugin-privacy@builtin\":false,\"cc-plugin-responsive-mode@builtin\":false,\"cc-plugin-telemetry@builtin\":false,\"cc-plugin-tips@builtin\":false,\"cc-plugin-you-should-know@builtin\":false},\"fastMode\":false,\"permissions\":{\"deny\":[\"Bash(claude *)\","
    + "\"Bash(*/claude *)\"]},\"workflowKeywordTriggerEnabled\":false}"

@Suite(.scratch) struct TurnProfileTests {
    @Test func plan1ArgvUnchanged() throws {
        let first = TurnProfileCompiler.arguments(TurnProfileCompiler.profile(for: request(started: false)))
        #expect(first == [
            "-p", "--output-format", "stream-json", "--verbose",
            "--model", "opus", "--fallback-model", "sonnet",
            "--setting-sources", "", "--settings", plan1Settings, "--disable-slash-commands",
            "--strict-mcp-config", "--mcp-config", "/tmp/run/a1.mcp.json",
            "--disallowed-tools", disallowed,
            "--session-id", "7081f66a-b7b1-4f6f-96e7-c690d4b0cec0", "--append-system-prompt", "ROLE PROMPT",
            "--permission-mode", "acceptEdits",
            "--allowed-tools", "Bash,Read,Edit,Write,Glob,Grep,mcp__company",
            "--add-dir", "/tmp/ws/acme",
        ])
        #expect(ClaudeCommand.arguments(for: request(started: false)) == first)
        // With a settings file (as every engine turn has), `--settings` names the file instead.
        var filed = request(started: false)
        filed.settingsFilePath = "/tmp/run/a1.settings.json"
        let fileArgs = TurnProfileCompiler.arguments(TurnProfileCompiler.profile(for: filed))
        #expect(fileArgs == first.map { $0 == plan1Settings ? "/tmp/run/a1.settings.json" : $0 })
        let resumed = TurnProfileCompiler.arguments(TurnProfileCompiler.profile(for: request(started: true)))
        let i = try #require(resumed.firstIndex(of: "--resume"))
        #expect(resumed[i + 1] == "7081f66a-b7b1-4f6f-96e7-c690d4b0cec0")
        #expect(!resumed.contains("--session-id"))
        // Efficiency amendment: the role prompt rides every turn, resumes included, byte-identical.
        let j = try #require(resumed.firstIndex(of: "--append-system-prompt"))
        #expect(resumed[j + 1] == "ROLE PROMPT")
        #expect(resumed[j + 1] == first[first.firstIndex(of: "--append-system-prompt")! + 1])
        let full = TurnProfileCompiler.arguments(TurnProfileCompiler.profile(for: request(started: false, profile: .full)))
        #expect(full.contains("bypassPermissions")); #expect(!full.contains("--allowed-tools")); #expect(!full.contains("--add-dir"))
        #expect(!first.contains("P"))
    }

    @Test func planTurnArgv() {
        var r = request(started: false)
        r.kind = .plan
        r.planDirectory = "/tmp/ws/acme/.brahma/plans/ACME-1"
        r.addDirs = ["/tmp/ws/acme/.brahma/plans/ACME-1"]
        let args = TurnProfileCompiler.arguments(TurnProfileCompiler.profile(for: r))
        #expect(args == [
            "-p", "--output-format", "stream-json", "--verbose",
            "--model", "opus", "--fallback-model", "sonnet",
            "--setting-sources", "", "--settings",
            // 3a's plansDirectory, now among the 5-lite keys.
            plan1Settings.replacingOccurrences(of: "},\"workflowKeywordTriggerEnabled\"",
                                               with: "},\"plansDirectory\":\"/tmp/ws/acme/.brahma/plans/ACME-1\",\"workflowKeywordTriggerEnabled\""),
            "--disable-slash-commands",
            "--strict-mcp-config", "--mcp-config", "/tmp/run/a1.mcp.json",
            "--disallowed-tools", disallowed + ",Edit,MultiEdit,NotebookEdit,Write,Bash",
            "--session-id", "7081f66a-b7b1-4f6f-96e7-c690d4b0cec0", "--append-system-prompt", "ROLE PROMPT",
            "--permission-mode", "plan",
            "--allowed-tools", "Read,Glob,Grep,mcp__company",
            "--add-dir", "/tmp/ws/acme/.brahma/plans/ACME-1",
        ])
    }

    @Test func multipleAddDirs() {
        var r = request(started: false)
        r.addDirs = ["/a", "/b"]
        let args = TurnProfileCompiler.arguments(TurnProfileCompiler.profile(for: r))
        let pairs = args.indices.filter { args[$0] == "--add-dir" }.map { args[$0 + 1] }
        #expect(pairs == ["/a", "/b"])
    }

    /// 5-lite: the settings are the typed mirror (`ClaudeSettings`, 3a's `extraSettings` dictionary renamed); `settingsJSON` is
    /// exactly its encoding.
    @Test func settingsAreTheTypedMirror() throws {
        var p = TurnProfileCompiler.profile(for: request(started: false))
        #expect(try TurnProfileCompiler.settingsJSON(p) == plan1Settings)
        p.settings.sandbox = ClaudeSettings.Sandbox(enabled: true)
        #expect(try TurnProfileCompiler.settingsJSON(p).contains("\"sandbox\":{\"enabled\":true}"))
        p.settings = ClaudeSettings()
        #expect(try TurnProfileCompiler.settingsJSON(p) == "{}")
    }

    @Test func slashCommandsFlagKeptByDefault() {
        var p = TurnProfileCompiler.profile(for: request(started: false))
        #expect(p.disableSlashCommands)
        #expect(TurnProfileCompiler.arguments(p).contains("--disable-slash-commands"))
        p.disableSlashCommands = false
        #expect(!TurnProfileCompiler.arguments(p).contains("--disable-slash-commands"))
    }

    /// I2(d): the MCP server's per-turn token lives only in that server's env block (the 0600 MCP config); it never reaches
    /// claude's own environment, whatever puts it on the request.
    @Test func turnTokenNeverReachesClaudesEnvironment() {
        let env = ChildEnvironment.make(base: ["PATH": "/bin", MCPConfig.tokenVariable: "t1"],
                                        extra: [MCPConfig.tokenVariable: "t2", "BRAHMA_AGENT_ID": "a1"],
                                        engineClaudeVars: [MCPConfig.tokenVariable: "t3"], purpose: .claude)
        #expect(env[MCPConfig.tokenVariable] == nil); #expect(env["BRAHMA_AGENT_ID"] == "a1")
        var r = request(started: false, profile: .workspace)
        r.environment[MCPConfig.tokenVariable] = "leak"
        let p = TurnProfileCompiler.profile(for: r)
        #expect(ChildEnvironment.make(base: [:], extra: p.environment, engineClaudeVars: p.environment, purpose: .claude)[MCPConfig.tokenVariable] == nil)
    }

    @Test func childEnvironmentStripsDev() {
        let env = ChildEnvironment.make(base: ["PATH": "/bin", "BRAHMA_DEV": "1"], extra: ["BRAHMA_DEV": "1"], purpose: .claude)
        #expect(env["BRAHMA_DEV"] == nil)
    }

    @Test func effortEnvNeverInherited() {
        let base = ["PATH": "/bin", "CLAUDE_CODE_EFFORT_LEVEL": "max", "CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS": "1",
                    "MAX_THINKING_TOKENS": "63999", "CLAUDE_CODE_SOMETHING_ELSE": "x"]
        for purpose in [ChildEnvironment.Purpose.claude, .general] {
            let env = ChildEnvironment.make(base: base, extra: [:], purpose: purpose)
            #expect(env["CLAUDE_CODE_EFFORT_LEVEL"] == nil); #expect(env["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"] == nil)
            #expect(env["MAX_THINKING_TOKENS"] == nil); #expect(env["CLAUDE_CODE_SOMETHING_ELSE"] == nil)
        }
        // Only what the engine passes for this turn gets through, and only to claude; secrets never do.
        let engine = ["CLAUDE_CODE_EFFORT_LEVEL": "low", "CLAUDE_CODE_DISABLE_FAST_MODE": "1", "CLAUDE_CODE_OAUTH_TOKEN": "t", "MAX_THINKING_TOKENS": "1", "OTHER": "x"]
        let env = ChildEnvironment.make(base: base, extra: [:], engineClaudeVars: engine, purpose: .claude)
        #expect(env["CLAUDE_CODE_DISABLE_FAST_MODE"] == "1"); #expect(env["CLAUDE_CODE_EFFORT_LEVEL"] == nil, "never passed, even engine-set (W1)")
        #expect(env["CLAUDE_CODE_OAUTH_TOKEN"] == nil, "auth comes only from the base environment")
        #expect(env["MAX_THINKING_TOKENS"] == nil); #expect(env["OTHER"] == nil)
        #expect(env["CLAUDE_CODE_EXPERIMENTAL_AGENT_TEAMS"] == nil)
        #expect(ChildEnvironment.make(base: base, extra: [:], engineClaudeVars: engine, purpose: .general)["CLAUDE_CODE_DISABLE_FAST_MODE"] == nil)
    }

    @Test func taskToolIsDisallowed() {
        #expect(ClaudeCommand.disallowedTools.contains("Task"))
        #expect(ClaudeCommand.disallowedTools.contains("Agent"))
        #expect(ClaudeCommand.disallowedTools.contains("Workflow"))
        let args = ClaudeCommand.arguments(for: request(started: false))
        let i = args.firstIndex(of: "--disallowed-tools")!
        #expect(args[i + 1].split(separator: ",").contains("Task"))
        #expect(args[i + 1].split(separator: ",").contains("Agent"))
    }

    @Test func childEnvironmentIsAllowlisted() {
        let base = ["FAKE_SECRET_TOKEN": "x", "AWS_X": "x", "SSH_AUTH_SOCK": "/s", "RANDOM_VAR": "x", "MY_API_KEY": "x",
                    "PATH": "/bin", "HOME": "/h", "LANG": "en_US.UTF-8", "LC_ALL": "C", "BRAHMA_DEV": "1",
                    "ANTHROPIC_API_KEY": "k", "CLAUDE_CODE_OAUTH_TOKEN": "t",
                    "HTTPS_PROXY": "http://p:3128", "no_proxy": "localhost", "SSL_CERT_FILE": "/c.pem",
                    "NODE_EXTRA_CA_CERTS": "/ca.pem", "CLAUDE_CONFIG_DIR": "/cfg", "PROXY_API_KEY": "x"]
        let env = ChildEnvironment.make(base: base, extra: ["BRAHMA_AGENT_ID": "a1", "BRAHMA_DEV": "1", "OTHER": "no"],
                                        purpose: .claude)
        for name in ["FAKE_SECRET_TOKEN", "AWS_X", "SSH_AUTH_SOCK", "RANDOM_VAR", "MY_API_KEY", "BRAHMA_DEV", "OTHER"] {
            #expect(env[name] == nil, "\(name) leaked")
        }
        #expect(env["PATH"] == "/bin"); #expect(env["HOME"] == "/h"); #expect(env["LANG"] == "en_US.UTF-8")
        #expect(env["LC_ALL"] == "C"); #expect(env["BRAHMA_AGENT_ID"] == "a1")
        #expect(env["ANTHROPIC_API_KEY"] == "k"); #expect(env["CLAUDE_CODE_OAUTH_TOKEN"] == "t")
        for (name, value) in ["HTTPS_PROXY": "http://p:3128", "no_proxy": "localhost", "SSL_CERT_FILE": "/c.pem",
                              "NODE_EXTRA_CA_CERTS": "/ca.pem", "CLAUDE_CONFIG_DIR": "/cfg"] {
            #expect(env[name] == value, "\(name) missing")
        }
        let other = ChildEnvironment.make(base: base, extra: [:], purpose: .general)
        #expect(other["ANTHROPIC_API_KEY"] == nil); #expect(other["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
    }

    @Test func stableHashIsFnv1a64() {
        #expect(StableHash.fnv1a64("") == "cbf29ce484222325")
        #expect(StableHash.fnv1a64("a") == "af63dc4c8601ec8c")
        #expect(StableHash.fnv1a64(Data("a".utf8)) == "af63dc4c8601ec8c")
    }
}
