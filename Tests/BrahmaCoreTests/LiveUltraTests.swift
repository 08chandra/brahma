import Foundation
import Testing
@testable import BrahmaCore

/// Live Ultra probes U-1…U-10 (Task 14u; haiku workers forced through FORCE, each run at most $0.05). They use subscription
/// quota and need the owner's approval to run. Run with: BRAHMA_LIVE=1 swift test --filter LiveUltraTests
/// Each drives the production probe runner (`LiveProbeGates`) for one gate of the Ultra shape. Gates that have no automated
/// probe in this build (U-4, U-6…U-9) are expected to fail closed with that reason, not to pass.
@Suite(.scratch, .serialized, .enabled(if: ProcessInfo.processInfo.environment["BRAHMA_LIVE"] == "1"))
struct LiveUltraTests {
    private func brahmaExecutable() throws -> String {
        let url = Bundle.module.bundleURL.deletingLastPathComponent().appending(path: "brahma")
        try #require(FileManager.default.isExecutableFile(atPath: url.path), "build the brahma product first")
        return url.path
    }

    private func gate(_ g: String, _ shape: ProbeShape = .ultra) async throws -> GateResult {
        let root = try tempDir()
        let paths = BrahmaPaths(home: root.appending(path: "home"), workspaces: root.appending(path: "ws"))
        let userHome = root.appending(path: "user")
        try FileManager.default.createDirectory(at: userHome, withIntermediateDirectories: true)
        let runner = LiveProbeGates(paths: paths, environment: SandboxEnvironment(userHome: userHome, darwinUserTemp: nil, shell: "/bin/zsh"),
                                    runner: ClaudeProcessRunner(), hookExecutable: try brahmaExecutable())
        return await runner.run(gate: g, shape: shape)
    }

    private func expectPass(_ g: String) async throws {
        let r = try await gate(g)
        #expect(r.passed, "\(g): \(r.detail)")
    }

    private func expectNotAutomated(_ g: String) async throws {
        let r = try await gate(g)
        #expect(!r.passed); #expect(r.detail.hasPrefix("not automated"), "\(g): \(r.detail)")
    }

    /// U-1: the exact Ultra argv; a two-agent inline workflow runs under the policy-wording opt-in; the last result stands.
    @Test(.timeLimit(.minutes(5))) func liveUltraSmallTwoAgentWorkflowLastResult() async throws { try await expectPass("U-1") }
    /// U-2: workers bill only the forced model; no nested Agent below depth 1.
    @Test(.timeLimit(.minutes(5))) func liveUltraWorkersForcedModelAndNoNestedAgent() async throws { try await expectPass("U-2") }
    /// U-3 (= V-7): the budget cap stops a workflow, and `total_cost_usd` includes its agents.
    @Test(.timeLimit(.minutes(5))) func liveBudgetCapStopsWorkflowAndCostIncludesAgents() async throws { try await expectPass("U-3") }
    /// U-4 (V-1): a sub-agent's WebFetch taints the session. Not automated in this build.
    @Test(.timeLimit(.minutes(5))) func liveSubagentWebFetchTaints() async throws { try await expectNotAutomated("U-4") }
    /// U-5 (V-2): remote isolation is refused under the Ultra argv.
    @Test(.timeLimit(.minutes(5))) func liveRemoteIsolationRefused() async throws { try await expectPass("U-5") }
    /// U-6: the background-wait ceiling stops the turn. Not automated (a 40-minute run).
    @Test(.timeLimit(.minutes(5))) func liveBgCeilingStops() async throws { try await expectNotAutomated("U-6") }
    /// U-7: the emergency stop kills workflow agents. Not automated live.
    @Test(.timeLimit(.minutes(5))) func emergencyStopKillsWorkflowAgents() async throws { try await expectNotAutomated("U-7") }
    /// U-8: the RSS of an Ultra turn is measured. Not automated.
    @Test(.timeLimit(.minutes(5))) func ultraRSSMeasured() async throws { try await expectNotAutomated("U-8") }
    /// U-9: standing ultracode does not lift the caps. Not automated.
    @Test(.timeLimit(.minutes(5))) func ultracodeCapsStillHold() async throws { try await expectNotAutomated("U-9") }
    /// U-10: a named workflow is refused by the pre-tool hook.
    @Test(.timeLimit(.minutes(5))) func liveNamedWorkflowRefused() async throws { try await expectPass("U-10") }
}
