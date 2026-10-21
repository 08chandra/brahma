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

@Suite struct TurnProfileTests {
    @Test func plan1ArgvUnchanged() throws {
        let first = TurnProfileCompiler.arguments(TurnProfileCompiler.profile(for: request(started: false)))
        #expect(first == [
            "-p", "--output-format", "stream-json", "--verbose",
            "--model", "opus", "--fallback-model", "sonnet",
            "--setting-sources", "", "--settings", "{\"enabledPlugins\":{}}", "--disable-slash-commands",
            "--strict-mcp-config", "--mcp-config", "/tmp/run/a1.mcp.json",
            "--disallowed-tools", disallowed,
            "--session-id", "7081f66a-b7b1-4f6f-96e7-c690d4b0cec0", "--append-system-prompt", "ROLE PROMPT",
            "--permission-mode", "acceptEdits",
            "--allowed-tools", "Bash,Read,Edit,Write,Glob,Grep,mcp__company",
            "--add-dir", "/tmp/ws/acme",
        ])
        #expect(ClaudeCommand.arguments(for: request(started: false)) == first)
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

    @Test func multipleAddDirs() {
        var r = request(started: false)
        r.addDirs = ["/a", "/b"]
        let args = TurnProfileCompiler.arguments(TurnProfileCompiler.profile(for: r))
        let pairs = args.indices.filter { args[$0] == "--add-dir" }.map { args[$0 + 1] }
        #expect(pairs == ["/a", "/b"])
    }

    @Test func extraSettingsMerged() {
        var p = TurnProfileCompiler.profile(for: request(started: false))
        p.extraSettings = ["sandbox": .object(["enabled": .bool(true)])]
        #expect(TurnProfileCompiler.settingsJSON(p) == "{\"enabledPlugins\":{},\"sandbox\":{\"enabled\":true}}")
        p.extraSettings = [:]
        #expect(TurnProfileCompiler.settingsJSON(p) == "{\"enabledPlugins\":{}}")
    }

    @Test func slashCommandsFlagKeptByDefault() {
        var p = TurnProfileCompiler.profile(for: request(started: false))
        #expect(p.disableSlashCommands)
        #expect(TurnProfileCompiler.arguments(p).contains("--disable-slash-commands"))
        p.disableSlashCommands = false
        #expect(!TurnProfileCompiler.arguments(p).contains("--disable-slash-commands"))
    }

    @Test func childEnvironmentStripsDev() {
        let env = ChildEnvironment.make(base: ["PATH": "/bin", "BRAHMA_DEV": "1"], extra: ["BRAHMA_DEV": "1"], purpose: .claude)
        #expect(env["BRAHMA_DEV"] == nil)
    }

    @Test func childEnvironmentIsAllowlisted() {
        let base = ["FAKE_SECRET_TOKEN": "x", "AWS_X": "x", "SSH_AUTH_SOCK": "/s", "RANDOM_VAR": "x", "MY_API_KEY": "x",
                    "PATH": "/bin", "HOME": "/h", "LANG": "en_US.UTF-8", "LC_ALL": "C", "BRAHMA_DEV": "1",
                    "ANTHROPIC_API_KEY": "k", "CLAUDE_CODE_OAUTH_TOKEN": "t"]
        let env = ChildEnvironment.make(base: base, extra: ["BRAHMA_AGENT_ID": "a1", "BRAHMA_DEV": "1", "OTHER": "no"],
                                        purpose: .claude)
        for name in ["FAKE_SECRET_TOKEN", "AWS_X", "SSH_AUTH_SOCK", "RANDOM_VAR", "MY_API_KEY", "BRAHMA_DEV", "OTHER"] {
            #expect(env[name] == nil, "\(name) leaked")
        }
        #expect(env["PATH"] == "/bin"); #expect(env["HOME"] == "/h"); #expect(env["LANG"] == "en_US.UTF-8")
        #expect(env["LC_ALL"] == "C"); #expect(env["BRAHMA_AGENT_ID"] == "a1")
        #expect(env["ANTHROPIC_API_KEY"] == "k"); #expect(env["CLAUDE_CODE_OAUTH_TOKEN"] == "t")
        let other = ChildEnvironment.make(base: base, extra: [:], purpose: .general)
        #expect(other["ANTHROPIC_API_KEY"] == nil); #expect(other["CLAUDE_CODE_OAUTH_TOKEN"] == nil)
    }

    @Test func stableHashIsFnv1a64() {
        #expect(StableHash.fnv1a64("") == "cbf29ce484222325")
        #expect(StableHash.fnv1a64("a") == "af63dc4c8601ec8c")
        #expect(StableHash.fnv1a64(Data("a".utf8)) == "af63dc4c8601ec8c")
    }
}
