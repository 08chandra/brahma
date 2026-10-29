import Foundation
import Testing
@testable import BrahmaCore

/// Live work-mode probes (design §7; haiku, tiny prompts, `--max-budget-usd` ≤ 0.05). They use subscription quota.
/// Run with: BRAHMA_LIVE=1 swift test --filter LiveModeTests
@Suite(.scratch, .enabled(if: ProcessInfo.processInfo.environment["BRAHMA_LIVE"] == "1"))
struct LiveModeTests {
    private func request(_ d: ModeDecision, dir: URL, session: String = UUID().uuidString.lowercased(), resume: Bool = false,
                         prompt: String = "Reply with OK.") throws -> TurnRequest {
        let config = dir.appending(path: "empty.mcp.json")
        if !FileManager.default.fileExists(atPath: config.path) { try Data("{\"mcpServers\":{}}".utf8).write(to: config) }
        let agent = Agent(id: "live", companyId: "live", name: "live", role: "engineer", model: d.model, sessionId: session,
                          sessionStarted: resume, state: .running, blocker: nil, requestedBlocker: nil, paused: false, readySince: nil,
                          createdAt: Date())
        let company = Company(id: "live", name: "Live", slug: "live", goal: "probe", workspacePath: dir.path, status: .running,
                              usageMode: .low, priorityWeight: 1, createdAt: Date())
        var r = TurnRequest(agent: agent, company: company, prompt: prompt, appendSystemPrompt: nil, mcpConfigPath: config.path,
                            workingDirectory: dir.path, profile: .workspace, environment: ["BRAHMA_AGENT_ID": "live"])
        r.mode = d
        return r
    }

    private func quick(budget: Double = 0.05) -> ModeDecision {
        var i = ModeInputs(); i.turnKind = .notice; i.budgetLeftLE = budget
        var d = ModePolicy.select(i)
        d.maxBudgetUSD = budget
        return d
    }

    private func run(_ r: TurnRequest) async throws -> (InitInfo?, TurnResult?) {
        var info: InitInfo?, result: TurnResult?
        for try await e in ClaudeProcessRunner().run(r) {
            if case .initInfo(let i) = e { info = i }
            if case .result(let x) = e { result = x }
        }
        return (info, result)
    }

    /// The built `brahma` binary sits next to the test resource bundle; the pre-tool hook runs from it.
    private func brahmaExecutable() throws -> String {
        let url = Bundle.module.bundleURL.deletingLastPathComponent().appending(path: "brahma")
        try #require(FileManager.default.isExecutableFile(atPath: url.path), "build the brahma product first")
        return url.path
    }

    /// L-1: the compiled Quick profile (with the engine's pre-tool hook) runs, its session has no `Task`, `Agent` or `Workflow`
    /// tool, and fast mode is off.
    @Test(.timeLimit(.minutes(3))) func liveQuickInitLacksTask() async throws {
        let dir = try tempDir()
        var r = try request(quick(), dir: dir)
        r.hookCommand = TurnProfileCompiler.hookCommand(executable: try brahmaExecutable())
        let (info, result) = try await run(r)
        let tools = Set(try #require(info).tools)
        #expect(tools.isDisjoint(with: ["Task", "Agent", "Workflow"]), "\(tools)")
        #expect(try #require(result).isError == false)
        #expect(result?.fastModeState == "off" || result?.fastModeState == nil)
    }

    /// The doctor's mode-canary against the installed CLI: no model call, every shape answers as compiled.
    @Test(.timeLimit(.minutes(2))) func liveModeCanaryPasses() async throws {
        let r = try #require(await ModeCanary.run(runner: ClaudeProcessRunner()))
        #expect(r.item.status == .pass, "\(r.item.detail)")
        #expect(r.builtinAgents?.contains("Explore") == true)
        #expect(r.reportedSubscription != nil)
    }

    /// L-2: with sub-agents forced on (gate shape only; 3a never compiles it), the worker's cost is part of `total_cost_usd`
    /// and a tiny cap stops the turn while it waits on the sub-agent.
    @Test(.timeLimit(.minutes(5))) func liveSubagentCostIncludedAndCapStops() async throws {
        let dir = try tempDir()
        var d = quick()
        d.subagents = .forced(model: "sonnet", depth: 1, concurrent: 2)
        let prompt = "Make exactly one Agent tool call with description='probe', subagent_type='general-purpose', prompt='Reply PONG.'. Then reply with its answer."
        let (_, full) = try await run(try request(d, dir: dir, prompt: prompt))
        let r = try #require(full)
        #expect(r.modelsUsed.contains { $0.contains("sonnet") }, "the forced worker billed: \(r.modelsUsed)")
        d.maxBudgetUSD = 0.0007
        let (_, capped) = try await run(try request(d, dir: dir, prompt: prompt.replacingOccurrences(of: "Reply PONG.", with: "Run ls three times, then reply PONG.")))
        #expect(capped?.stopReason == TurnStop.budgetCap)
    }

    /// L-4: `--max-budget-usd` is per process and `total_cost_usd` is cumulative over `--resume`.
    @Test(.timeLimit(.minutes(3))) func liveMaxBudgetOnResume() async throws {
        let dir = try tempDir()
        let session = UUID().uuidString.lowercased()
        let (_, first) = try await run(try request(quick(budget: 0.03), dir: dir, session: session))
        let (_, second) = try await run(try request(quick(budget: 0.03), dir: dir, session: session, resume: true))
        let a = try #require(first?.costUSD), b = try #require(second?.costUSD)
        #expect(b >= a, "the resumed total includes the first turn")
        #expect(second?.isError == false, "a fresh per-process cap: the resume is not stopped by the first turn's spend")
    }
}
