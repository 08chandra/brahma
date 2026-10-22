import Foundation
import Testing
@testable import BrahmaCore

/// Doctor `mode-canary` (design §6.4): each mode's compiled argv is started with `--input-format stream-json` and asked
/// `initialize`, `get_settings` and `get_usage` (no model call). Faked control responses here.
private final class CanaryRunner: TurnRunning, @unchecked Sendable {
    var applied: (ModeDecision) -> [String: JSONValue]
    var initialize: [String: JSONValue]
    var effective: [String: JSONValue]
    var usage: [String: JSONValue]
    var exitStatus: Int32 = 0
    var answer = true
    private let lock = NSLock()
    private var _requests: [TurnRequest] = []
    var requests: [TurnRequest] { lock.withLock { _requests } }

    init() {
        applied = { d in
            let id = ["haiku": "claude-haiku-5-5", "sonnet": "claude-sonnet-5-5", "opus": "claude-opus-5-5"][d.model] ?? d.model
            return ["model": .string(id), "effort": .string(d.effort.rawValue), "advisor": .null, "ultracode": .bool(false)]
        }
        initialize = ["fast_mode_state": .string("off"),
                      "agents": .array(["claude", "Explore", "general-purpose", "Plan", "statusline-setup"].map { .object(["name": .string($0)]) })]
        effective = ["disableWorkflows": .bool(true), "fastMode": .bool(false), "availableModels": .array([.string("haiku"), .string("sonnet"), .string("opus")])]
        usage = ["subscription_type": .string("max")]
    }

    func run(_ request: TurnRequest) -> AsyncThrowingStream<StreamEvent, Error> { AsyncThrowingStream { $0.finish() } }

    func control(_ request: TurnRequest, messages: [JSONValue], timeout: Duration) async -> ControlTranscript? {
        lock.withLock { _requests.append(request) }
        guard answer, let d = request.mode else { return ControlTranscript(exitStatus: exitStatus, lines: []) }
        var lines: [String] = []
        for m in messages {
            guard let id = m.objectValue?["request_id"]?.stringValue,
                  let subtype = m.objectValue?["request"]?.objectValue?["subtype"]?.stringValue else { continue }
            let body: [String: JSONValue]
            switch subtype {
            case "initialize": body = initialize
            case "get_settings": body = ["applied": .object(applied(d)), "effective": .object(effective)]
            case "get_usage": body = usage
            default: body = [:]
            }
            let response: JSONValue = .object(["type": .string("control_response"), "response": .object([
                "subtype": .string("success"), "request_id": .string(id), "response": .object(body)])])
            lines.append(String(decoding: try! JSONEncoder().encode(response), as: UTF8.self))
        }
        return ControlTranscript(exitStatus: exitStatus, lines: lines)
    }
}

@Suite struct ModeCanaryTests {
    @Test func modeCanaryAppliedEffortMatchesEachCap() async throws {
        let runner = CanaryRunner()
        let result = try #require(await ModeCanary.run(runner: runner))
        #expect(result.item.status == .pass, "\(result.item)")
        #expect(result.item.name == "mode-canary")
        // One shape per emitted cap value: low, medium and high.
        #expect(Set(runner.requests.compactMap { $0.mode?.effort }) == [.low, .medium, .high])
        for r in runner.requests {
            let args = ClaudeCommand.arguments(for: r)
            #expect(args.contains("--max-turns")); #expect(args.contains("--effort")); #expect(args.contains("--max-budget-usd"))
            // Compiled with the pre-tool hook like a real turn (fix 1 minor).
            #expect(r.hookCommand == "'brahma' hook pre-tool")
            #expect(args[args.firstIndex(of: "--settings")! + 1].contains("hook pre-tool --mode"))
        }
        #expect(result.builtinAgents == ["claude", "Explore", "general-purpose", "Plan", "statusline-setup"])
        // A CLI that applies another effort than the flag (an env override, an org cap) fails the canary.
        runner.applied = { d in ["model": .string("claude-\(d.model)-5-5"), "effort": .string("high"), "advisor": .null, "ultracode": .bool(false)] }
        let bad = try #require(await ModeCanary.run(runner: runner))
        #expect(bad.item.status == .fail); #expect(bad.item.detail.contains("effort"))
    }

    @Test func workflowInInitToolsOnlyForUltraShape() async throws {
        let runner = CanaryRunner()
        runner.effective["disableWorkflows"] = .bool(false)
        runner.effective["enableWorkflows"] = .bool(true)
        let r = try #require(await ModeCanary.run(runner: runner))
        #expect(r.item.status == .fail); #expect(r.item.detail.contains("workflows"))
        // Every 3a shape compiles the kill switches; the per-turn init assertion forbids the tools.
        for (_, d) in ModeCanary.shapes() {
            #expect(TurnProfileCompiler.expectations(for: d, agents: nil).forbiddenTools.contains("Workflow"))
        }
    }

    @Test func ultracodeFalseEverywhere() async throws {
        let runner = CanaryRunner()
        runner.applied = { d in ["model": .string("claude-\(d.model)-5-5"), "effort": .string(d.effort.rawValue), "advisor": .null, "ultracode": .bool(true)] }
        let r = try #require(await ModeCanary.run(runner: runner))
        #expect(r.item.status == .fail); #expect(r.item.detail.contains("ultracode"))
    }

    @Test func fastModeOnFails() async throws {
        let runner = CanaryRunner()
        runner.initialize["fast_mode_state"] = .string("on")
        let r = try #require(await ModeCanary.run(runner: runner))
        #expect(r.item.status == .fail); #expect(r.item.detail.contains("fast mode"))
    }

    @Test func hiddenFlagUnknownFails() async throws {
        // Probe V-11: an unknown flag makes the CLI exit non-zero before it answers anything.
        let runner = CanaryRunner()
        runner.answer = false
        runner.exitStatus = 1
        let r = try #require(await ModeCanary.run(runner: runner))
        #expect(r.item.status == .fail); #expect(r.item.detail.contains("--max-turns"))
        // A runner that cannot run control sessions (the Plan 1 fakes) adds nothing.
        #expect(await ModeCanary.run(runner: NoControlRunner()) == nil)
    }

    @Test func planTierMismatchWarnsOnly() async throws {
        // Owner answer Q-M1: the configured tier always wins; the CLI's report only earns a WARN.
        let runner = CanaryRunner()
        runner.usage = ["subscription_type": .string("pro")]
        let r = try #require(await ModeCanary.run(runner: runner))
        #expect(r.reportedSubscription == "pro"); #expect(r.item.status == .pass)
        #expect(Doctor.planTierItem(configured: .max5x, reported: r.reportedSubscription)?.status == .warn)
        #expect(Doctor.planTierItem(configured: .max5x, reported: "max") == nil)
        // The doctor carries it into the report, with the sub-agent gate record.
        let helpText = Doctor.requiredFlags.map { "  \($0) <v>" }.joined(separator: "\n")
        let exec: Doctor.Exec = { _, args in args == ["--version"] ? "2.1.308 (Claude Code)" : args == ["--help"] ? helpText : nil }
        let report = await Doctor.run(claudePath: "claude", runner: runner, exec: exec, now: Date(timeIntervalSince1970: 1_000_000))
        #expect(report.reportedSubscription == "pro")
        #expect(report.builtinAgents?.contains("Explore") == true)
        #expect(report.subagentGate == false)
        #expect(report.items.contains { $0.name == "mode-canary" })
        #expect(report.items.first { $0.name == "subagent-gate" }?.detail == SubagentGate.workspaceDetail)
        #expect(Doctor.requiredFlags.contains("--effort")); #expect(Doctor.requiredFlags.contains("--max-budget-usd"))
        #expect(!Doctor.requiredFlags.contains("--max-turns"), "hidden flags are checked by the canary, not --help")
    }
}

private struct NoControlRunner: TurnRunning {
    func run(_ request: TurnRequest) -> AsyncThrowingStream<StreamEvent, Error> { AsyncThrowingStream { $0.finish() } }
}
