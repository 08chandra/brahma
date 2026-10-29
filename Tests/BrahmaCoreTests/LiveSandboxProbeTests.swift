import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Task 1b Step 1: one real haiku turn (at most $0.05) on the real compiled sandboxed argv and settings file, the real shell
/// prefix and sentinel, and the built `brahma mcp`, in a seeded throwaway company. It records:
/// - (a) an MCP `post_message` works under `--restricted`;
/// - (b) with `--disable-slash-commands` off, the `Skill(design)`/`Skill(doctor)` deny rules refuse both (F10);
/// - (c) with `.claude/skills/x/SKILL.md` and `.claude/agents/x.md` in the cwd, init `skills` and `agents` lack `x`;
/// - (d) a commit on `item/<KEY>` succeeds with only the per-ref `allowWrite` entries.
/// Run with: BRAHMA_LIVE=1 swift test --filter LiveSandboxProbeTests (the findings are printed as `PROBE …` lines).
@Suite(.scratch, .enabled(if: ProcessInfo.processInfo.environment["BRAHMA_LIVE"] == "1"))
struct LiveSandboxProbeTests {
    @Test(.timeLimit(.minutes(4)))
    func sandboxedTurnProbes() async throws {
        let brahma = Bundle.module.bundleURL.deletingLastPathComponent().appending(path: "brahma").path
        try #require(FileManager.default.isExecutableFile(atPath: brahma), "build the brahma product first")
        // Outside the owner's home and the Darwin temp dir (the turn's toolchain write), like a real data home and workspaces.
        let root = URL(fileURLWithPath: SandboxPath.resolve("/tmp"), isDirectory: false).appending(path: "brahma-probe-\(UUID().uuidString)")
        let keep = ProcessInfo.processInfo.environment["BRAHMA_PROBE_KEEP"] == "1"
        defer { if !keep { try? FileManager.default.removeItem(at: root) } }
        let paths = BrahmaPaths(home: root.appending(path: "data"), workspaces: root.appending(path: "wss"))
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        let store = try Store(path: paths.database.path)
        let company = try store.createCompany(name: "Probe", goal: "probe", workspacesRoot: paths.workspaces)
        let agent = try store.hire(companyId: company.id, name: "eng-1", role: "engineer", model: "haiku")
        let item = try store.createWorkItem(companyId: company.id, by: .owner, draft: WorkItemDraft(
            type: .task, title: "Probe", acceptanceCriteria: "it works", checkSpec: CheckSpec(command: "true", paths: ["src/a"]),
            status: .ready), now: Date())
        _ = try CompanyTools(store: store, companyId: company.id, agentId: agent.id).call(name: "claim_lease", arguments: ["key": .string(item.key)])
        try Sentinel.write(paths: paths)

        let layout = SandboxLayout(paths: paths, company: company, agentHandle: agent.name)
        try layout.ensure()
        let env = SandboxEnvironment.current
        let prefix = try ShellPrefix.write(layout: layout, paths: paths, shell: env.shell, keepNames: [], mcpExecutable: brahma)
        let scope = try SandboxScope.forTurn(layout: layout, paths: paths, otherWorkspaces: [], backupTargets: [], kind: .work,
                                             item: item, company: company, grants: GrantInputs(), darwinUserTemp: env.darwinUserTemp)
        // (c): project skills and agents in the cwd (planted after the engine's sweep would have run).
        let cwd = scope.cwd
        try FileManager.default.createDirectory(at: cwd.appending(path: ".claude/skills/x"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: cwd.appending(path: ".claude/agents"), withIntermediateDirectories: true)
        try "---\nname: x\ndescription: probe skill x\n---\nSay X.\n".write(to: cwd.appending(path: ".claude/skills/x/SKILL.md"), atomically: true, encoding: .utf8)
        try "---\nname: x\ndescription: probe agent x\n---\nSay X.\n".write(to: cwd.appending(path: ".claude/agents/x.md"), atomically: true, encoding: .utf8)

        let turn = Turn(id: UUID().uuidString, agentId: agent.id, companyId: company.id, startedAt: Date(), endedAt: nil,
                        outcome: .inProgress, summary: nil, costUSD: nil)
        try await store.writer.write { db in try turn.insert(db) }
        let token = try store.issueTurnCredential(turnId: turn.id)
        var request = TurnRequest(
            agent: agent, company: company,
            prompt: """
                This is an automated probe. Do exactly these steps, each once, then stop:
                1. Call the tool mcp__company__post_message with channel "general" and text "probe-a".
                2. Call the Skill tool with skill "design". Then call the Skill tool with skill "doctor".
                3. Run this Bash command exactly: git commit --allow-empty -m probe-d && git log -1 --format=%s
                Finally reply with one line: RESULTS a=<ok|fail> b-design=<ran|refused> b-doctor=<ran|refused> d=<ok|fail>
                """,
            appendSystemPrompt: "You are a test agent running a scripted probe.",
            mcpConfigPath: try MCPConfig.write(paths: paths, executable: brahma, agent: agent, turnToken: token),
            workingDirectory: cwd.path, profile: .sandboxed,
            environment: ["BRAHMA_AGENT_ID": agent.id, "BRAHMA_HOME": paths.home.path, "BRAHMA_WORKSPACES": paths.workspaces.path])
        // (On failure, claude's own log of the server is under ~/Library/Caches/claude-cli-nodejs/<cwd>/mcp-logs-company/.)
        request.sandbox = scope
        request.shellPrefix = prefix.path
        request.settingsFilePath = SettingsFile.path(paths: paths, agentId: agent.id).path
        // (b) needs `--disable-slash-commands` off: compile as with a mount (the Skill denies), but pass no `--plugin-dir`.
        request.mounts = [root.appending(path: "no-plugin")]
        var profile = TurnProfileCompiler.profile(for: request)
        profile.pluginDirs = []
        try TurnProfileCompiler.validate(profile)
        try SettingsFile.write(TurnProfileCompiler.settingsJSON(profile), to: URL(fileURLWithPath: request.settingsFilePath!))
        let args = TurnProfileCompiler.arguments(profile) + ["--max-budget-usd", "0.05"]

        if keep {
            let cmd = (["claude"] + args).map { "'" + $0.replacingOccurrences(of: "'", with: "'\\''") + "'" }.joined(separator: " ")
            try "cd '\(cwd.path)'\n\(cmd)\n".write(toFile: "/tmp/brahma-probe-1b-cmd.sh", atomically: true, encoding: .utf8)
            let env = ChildEnvironment.make(base: ProcessInfo.processInfo.environment, extra: profile.environment,
                                            engineClaudeVars: profile.environment, purpose: .claude)
            try env.map { "\($0.key)=\($0.value)" }.joined(separator: "\n").write(toFile: "/tmp/brahma-probe-1b-env.txt", atomically: true, encoding: .utf8)
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["claude"] + args
        process.environment = ChildEnvironment.make(base: ProcessInfo.processInfo.environment, extra: profile.environment,
                                                    engineClaudeVars: profile.environment, purpose: .claude)
        process.currentDirectoryURL = cwd
        let stdin = Pipe(), stdout = Pipe()
        process.standardInput = stdin; process.standardOutput = stdout; process.standardError = FileHandle.nullDevice
        try process.run()
        try stdin.fileHandleForWriting.write(contentsOf: Data(request.prompt.utf8))
        try stdin.fileHandleForWriting.close()
        let out = String(decoding: stdout.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        try out.write(to: URL(fileURLWithPath: "/tmp/brahma-probe-1b-stream.jsonl"), atomically: true, encoding: .utf8)

        var skills: [String] = [], agents: [String] = [], tools: [String] = [], result = "", cost = 0.0
        var denials: [String] = []
        for line in out.split(separator: "\n") {
            guard let obj = try? JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any] else { continue }
            if obj["type"] as? String == "system", obj["subtype"] as? String == "init" {
                skills = obj["skills"] as? [String] ?? []
                agents = obj["agents"] as? [String] ?? []
                tools = obj["tools"] as? [String] ?? []
            }
            if obj["type"] as? String == "result" {
                result = obj["result"] as? String ?? ""
                cost = (obj["total_cost_usd"] as? Double) ?? 0
                for d in obj["permission_denials"] as? [[String: Any]] ?? [] {
                    denials.append("\(d["tool_name"] ?? "?") \((d["tool_input"] as? [String: Any]).map { "\($0)" } ?? "")")
                }
            }
        }
        // The company MCP server, started as claude starts it (its config's command, args and env over claude's environment),
        // for its stderr when (a) fails.
        if !out.contains("\"name\":\"company\",\"status\":\"connected\"") {
            let config = try JSONSerialization.jsonObject(with: Data(contentsOf: URL(fileURLWithPath: request.mcpConfigPath))) as? [String: Any]
            let server = ((config?["mcpServers"] as? [String: Any])?["company"] as? [String: Any]) ?? [:]
            let mcp = Process()
            mcp.executableURL = URL(fileURLWithPath: server["command"] as? String ?? brahma)
            mcp.arguments = server["args"] as? [String] ?? []
            var mcpEnv = process.environment ?? [:]
            for (k, v) in server["env"] as? [String: String] ?? [:] { mcpEnv[k] = v }
            mcp.environment = mcpEnv
            mcp.currentDirectoryURL = cwd
            let err = Pipe(), inp = Pipe()
            mcp.standardError = err; mcp.standardInput = inp; mcp.standardOutput = FileHandle.nullDevice
            try mcp.run()
            try? inp.fileHandleForWriting.close()
            mcp.waitUntilExit()
            print("PROBE (a) mcp server exit \(mcp.terminationStatus): \(String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).prefix(600))")
        }
        let posted = try store.messages(channelId: try #require(try store.channel(companyId: company.id, name: "general")).id, limit: 20)
            .contains { $0.text.contains("probe-a") }
        let git = Process()
        git.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        git.arguments = ["git", "-C", company.workspacePath, "log", "-1", "--format=%s", "refs/heads/item/\(item.key)"]
        let gitOut = Pipe()
        git.standardOutput = gitOut; git.standardError = FileHandle.nullDevice
        try git.run(); git.waitUntilExit()
        let subject = String(decoding: gitOut.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        let head: String? = subject == "probe-d" ? "PASS" : "FAIL"
        print("PROBE init tools: \(tools.joined(separator: ", "))")
        print("PROBE (a) post_message under --restricted: \(posted ? "PASS" : "FAIL")")
        print("PROBE (b) denials: \(denials)")
        print("PROBE (c) init skills: \(skills); agents: \(agents); x absent: \(!skills.contains { $0.hasSuffix("x") && $0.count <= 3 } && !agents.contains("x"))")
        print("PROBE (d) commit on item/\(item.key): \(head ?? "FAIL") (last subject: \(subject))")
        print("PROBE result: \(result.prefix(400)); cost $\(cost)")
        #expect(cost <= 0.06)
    }
}
