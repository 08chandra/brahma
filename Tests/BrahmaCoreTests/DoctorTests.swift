import Foundation
import Testing
@testable import BrahmaCore

/// Scripted runner: one event list per call, in order.
private final class ProbeRunner: TurnRunning, @unchecked Sendable {
    private let lock = NSLock()
    private var scripts: [[StreamEvent]]
    private var _requests: [TurnRequest] = []
    var requests: [TurnRequest] { lock.withLock { _requests } }
    init(_ scripts: [[StreamEvent]]) { self.scripts = scripts }

    func run(_ request: TurnRequest) -> AsyncThrowingStream<StreamEvent, Error> {
        let events: [StreamEvent] = lock.withLock {
            _requests.append(request)
            return scripts.isEmpty ? [] : scripts.removeFirst()
        }
        return AsyncThrowingStream { c in events.forEach { c.yield($0) }; c.finish() }
    }
}

private func limit(overage: Bool = false, overageStatus: String? = nil) -> StreamEvent {
    .rateLimit(RateLimitInfo(status: "allowed", resetsAt: nil, rateLimitType: "five_hour", isUsingOverage: overage,
                             fiveHourUtilization: 0.1, sevenDayUtilization: 0.1, observedAt: Date(),
                             overageStatus: overageStatus))
}
private func result(_ text: String, error: Bool = false, usage: Bool = true) -> StreamEvent {
    .result(TurnResult(isError: error, subtype: error ? "error" : "success", text: text, costUSD: 0.001,
                       apiErrorStatus: nil, sessionId: "s", hasUsage: usage))
}
private let initEvent = StreamEvent.initialized(sessionId: "s", model: "haiku")
/// The init `tools` of 2.1.306 (plus harness tools): every `BuiltinTools.sandboxed` name is there.
private let initTools = StreamEvent.initInfo(InitInfo(sessionId: "s", model: "haiku", tools: [
    "Task", "Bash", "Edit", "NotebookEdit", "Read", "Skill", "ToolSearch", "WebFetch", "WebSearch", "Write", "TodoWrite",
    "mcp__company__post_message"], agents: []))
private func good(_ extra: StreamEvent? = nil) -> [[StreamEvent]] {
    [[initEvent, initTools, extra ?? limit(), result("OK")], [initEvent, result("BRAHMA-PROBE-7")]]
}

private let helpText = Doctor.requiredFlags.map { "  \($0) <value>  something" }.joined(separator: "\n")
private func exec(version: String = "2.1.304 (Claude Code)", help: String = helpText) -> Doctor.Exec {
    { _, args in args == ["--version"] ? version : args == ["--help"] ? help : nil }
}
private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func item(_ r: DoctorReport, _ name: String) -> DoctorItem? { r.items.first { $0.name == name } }

@Suite struct DoctorTests {
    @Test func allPass() async {
        let runner = ProbeRunner(good())
        let r = await Doctor.run(claudePath: "claude", runner: runner, exec: exec(), now: t0)
        #expect(r.ok, "\(r.items)")
        #expect(r.cliVersion == "2.1.304")
        #expect(r.items.map(\.name) == ["version", "flags", "probe", "resume-keeps-role", "overage", "tools-present", "sideload-allowed"])
        #expect(r.items.allSatisfy { $0.status == .pass }, "\(r.items)")
        let reqs = runner.requests
        #expect(reqs.count == 2)
        #expect(reqs[0].agent.model == "haiku"); #expect(reqs[0].prompt == "Reply with the single word OK.")
        #expect(reqs[0].appendSystemPrompt == "Brahma probe: the codeword is BRAHMA-PROBE-7.")
        #expect(reqs[1].agent.sessionStarted); #expect(reqs[1].agent.sessionId == reqs[0].agent.sessionId)
        #expect(reqs[1].appendSystemPrompt == reqs[0].appendSystemPrompt)
        #expect(reqs[1].prompt == "Reply with the codeword only.")
        #expect(reqs[0].environment["BRAHMA_AGENT_ID"] != nil)
    }

    @Test func sandboxFlagsAreRequired() async {
        for flag in ["--restricted", "--tools", "--plugin-dir", "--permission-prompts"] {
            #expect(Doctor.requiredFlags.contains(flag), "\(flag)")
            let help = helpText.components(separatedBy: "\n").filter { !$0.contains(" \(flag) ") }.joined(separator: "\n")
            let r = await Doctor.run(claudePath: "claude", runner: ProbeRunner(good()), exec: exec(help: help), now: t0)
            #expect(!r.ok); #expect(item(r, "flags")?.detail.contains(flag) == true)
        }
    }

    @Test func toolsPresentFailsNamingTheMissingTools() async {
        let tools = StreamEvent.initInfo(InitInfo(sessionId: "s", model: "haiku", tools: ["Bash", "Read", "Edit", "Write", "Skill",
                                                                                         "WebFetch", "WebSearch"], agents: []))
        let r = await Doctor.run(claudePath: "claude", runner: ProbeRunner([[initEvent, tools, limit(), result("OK")],
                                                                            [initEvent, result("BRAHMA-PROBE-7")]]),
                                 exec: exec(), now: t0)
        #expect(!r.ok)
        let tp = item(r, "tools-present")
        #expect(tp?.status == .fail); #expect(tp?.detail.contains("NotebookEdit") == true); #expect(tp?.detail.contains("ToolSearch") == true)
        #expect(tp?.detail.contains("Bash") == false)
        // No tools list in the init event: nothing to compare (a warning; the canary checks the real sandboxed shape).
        let none = await Doctor.run(claudePath: "claude", runner: ProbeRunner([[initEvent, limit(), result("OK")],
                                                                               [initEvent, result("BRAHMA-PROBE-7")]]),
                                    exec: exec(), now: t0)
        #expect(item(none, "tools-present")?.status == .warn)
    }

    @Test func sideloadFlagsDisabledByManagedSettingsFails() async throws {
        let dir = try tempDir()
        let managed = dir.appending(path: "managed-settings.json")
        func run() async -> DoctorReport {
            await Doctor.run(claudePath: "claude", runner: ProbeRunner(good()), exec: exec(), now: t0, managedSettingsPath: managed.path)
        }
        #expect(item(await run(), "sideload-allowed")?.status == .pass, "no managed settings")
        try Data(#"{"disableSideloadFlags": false, "other": 1}"#.utf8).write(to: managed)
        #expect(item(await run(), "sideload-allowed")?.status == .pass)
        try Data(#"{"disableSideloadFlags": true}"#.utf8).write(to: managed)
        let r = await run()
        #expect(!r.ok); #expect(item(r, "sideload-allowed")?.status == .fail)
        #expect(item(r, "sideload-allowed")?.detail.contains("--plugin-dir") == true)
        try Data("not json".utf8).write(to: managed)
        #expect(item(await run(), "sideload-allowed")?.status == .fail, "unreadable managed settings: cannot tell")
        #expect(Doctor.managedSettingsPath == "/Library/Application Support/ClaudeCode/managed-settings.json")
    }

    @Test func oldVersionFails() async {
        let r = await Doctor.run(claudePath: "claude", runner: ProbeRunner(good()), exec: exec(version: "2.1.299 (Claude Code)"), now: t0)
        #expect(!r.ok); #expect(item(r, "version")?.status == .fail)
    }

    @Test func newerVersionWarns() async {
        let r = await Doctor.run(claudePath: "claude", runner: ProbeRunner(good()), exec: exec(version: "2.1.306 (Claude Code)"), now: t0)
        #expect(r.ok); #expect(item(r, "version")?.status == .warn)
    }

    @Test func missingFlagFails() async {
        let help = helpText.replacingOccurrences(of: "--fallback-model", with: "")
        let r = await Doctor.run(claudePath: "claude", runner: ProbeRunner(good()), exec: exec(help: help), now: t0)
        #expect(!r.ok); #expect(item(r, "flags")?.status == .fail)
        #expect(item(r, "flags")?.detail.contains("--fallback-model") == true)
    }

    @Test func probeWithoutResultFails() async {
        let r = await Doctor.run(claudePath: "claude", runner: ProbeRunner([[initEvent]]), exec: exec(), now: t0)
        #expect(!r.ok); #expect(item(r, "probe")?.status == .fail)
        let noUsage = await Doctor.run(claudePath: "claude", runner: ProbeRunner([[initEvent, result("OK", usage: false)]]),
                                       exec: exec(), now: t0)
        #expect(item(noUsage, "probe")?.status == .fail)
        let missingLimit = await Doctor.run(claudePath: "claude",
                                            runner: ProbeRunner([[initEvent, result("OK")], [initEvent, result("BRAHMA-PROBE-7")]]),
                                            exec: exec(), now: t0)
        #expect(missingLimit.ok); #expect(item(missingLimit, "probe")?.status == .warn)
    }

    @Test func resumeLosingRolePromptFails() async {
        let r = await Doctor.run(claudePath: "claude",
                                 runner: ProbeRunner([[initEvent, limit(), result("OK")], [initEvent, result("I do not know")]]),
                                 exec: exec(), now: t0)
        #expect(!r.ok); #expect(item(r, "resume-keeps-role")?.status == .fail)
    }

    @Test func overageInUseFails() async {
        let r = await Doctor.run(claudePath: "claude", runner: ProbeRunner(good(limit(overage: true))), exec: exec(), now: t0)
        #expect(!r.ok); #expect(item(r, "overage")?.status == .fail)
    }

    @Test func overageAllowedWarns() async {
        let r = await Doctor.run(claudePath: "claude", runner: ProbeRunner(good(limit(overageStatus: "allowed"))), exec: exec(), now: t0)
        #expect(r.ok); #expect(item(r, "overage")?.status == .warn)
    }

    @Test func ensureReusesFreshReport() async throws {
        let store = try Store.inMemory()
        let first = ProbeRunner(good())
        let a = await Doctor.ensure(store: store, claudePath: "claude", runner: first, exec: exec(), now: t0)
        #expect(a.ok)
        let second = ProbeRunner(good())
        let b = await Doctor.ensure(store: store, claudePath: "claude", runner: second, exec: exec(),
                                    now: t0.addingTimeInterval(Doctor.maxAge - 1))
        #expect(b == a); #expect(second.requests.isEmpty)
        let c = await Doctor.ensure(store: store, claudePath: "claude", runner: second, exec: exec(),
                                    now: t0.addingTimeInterval(Doctor.maxAge + 1))
        #expect(second.requests.count == 2); #expect(c.checkedAt > a.checkedAt)
    }

    @Test func ensureRerunsOnVersionChange() async throws {
        let store = try Store.inMemory()
        _ = await Doctor.ensure(store: store, claudePath: "claude", runner: ProbeRunner(good()), exec: exec(), now: t0)
        let second = ProbeRunner(good())
        let r = await Doctor.ensure(store: store, claudePath: "claude", runner: second,
                                    exec: exec(version: "2.1.310 (Claude Code)"), now: t0.addingTimeInterval(60))
        #expect(second.requests.count == 2); #expect(r.cliVersion == "2.1.310")
        #expect(try store.latestProbe()?.cliVersion == "2.1.310")
    }
}
