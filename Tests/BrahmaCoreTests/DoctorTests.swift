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

@Suite(.scratch) struct DoctorTests {
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

@Suite(.scratch, .serialized) struct DoctorExecTests {
    @Test func aHangingProcessIsKilledAtTheTimeoutAndThrows() async throws {
        let started = AwakeTime.uptime()
        do {
            _ = try await Doctor.execProcess(executable: "/bin/sleep", arguments: ["120"], timeout: 0.3, blocking: Blocking())
            Issue.record("expected a timeout")
        } catch let e as Doctor.ExecTimedOut {
            #expect(e.description.contains("did not finish within"), "\(e)")
        }
        #expect(AwakeTime.uptime() - started < 60, "killed long before the 120 s sleep ends")
    }

    /// The engine's bounded tool runs (doctor, rclone, zstd/gzip, lsof) all go through `GroupExec`: a hung tool's children
    /// die with it, since its whole process group is signalled.
    @Test func aHungToolsChildrenAreKilledWithItsGroup() async throws {
        // Two pid files: the doctor's run and the external tool's run are each asserted (INT-M3).
        let dir = try tempDir()
        let doctorPid = dir.appending(path: "doctor.pid"), toolPid = dir.appending(path: "tool.pid")
        func script(_ f: URL) -> String { "/bin/sleep 300 & echo $! > '\(f.path)'; wait" }
        _ = try? await Doctor.execProcess(executable: "/bin/sh", arguments: ["-c", script(doctorPid)], timeout: 0.5, blocking: Blocking())
        let r = ExternalTool.run(executable: "/bin/sh", arguments: ["-c", script(toolPid) + "; echo never"], environment: [:], timeout: 0.5)
        #expect(r.timedOut && r.launched)
        for file in [doctorPid, toolPid] {
            let pid = try #require(Int32(try String(contentsOf: file, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)))
            let until = AwakeTime.uptime() + 5
            while kill(pid, 0) == 0, AwakeTime.uptime() < until { try await Task.sleep(nanoseconds: 20_000_000) }
            #expect(kill(pid, 0) != 0, "\(file.lastPathComponent): the tool's background child outlived the timeout")
        }
        // A normal run still captures stdout and stderr and returns the exit code.
        let ok = ExternalTool.run(executable: "/bin/sh", arguments: ["-c", "echo out; echo err >&2; exit 3"], environment: [:], timeout: 10)
        #expect(ok.status == 3 && ok.output == "out\nerr\n" && !ok.timedOut, "\(ok)")
    }

    /// INT-I2/M4/M5: `GroupExec` never reports a lost or abandoned leader as success; its default working directory is `/`;
    /// the wait after SIGKILL is bounded by default.
    @Test func groupExecNeverReportsALostChildAsSuccess() throws {
        #expect(GroupExec.defaultAbandonAfter > 0)
        let cwd = GroupExec.run(executable: "/bin/pwd", arguments: [], environment: [:], output: .capture(cap: 1024, stderr: false), timeout: 10)
        #expect(cwd.status == 0); #expect(String(decoding: cwd.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "/")
        // A leader given up on right after SIGKILL (abandonAfter 0) is reported as a failure with a reason, never status 0.
        let abandoned = GroupExec.run(executable: "/bin/sh", arguments: ["-c", "trap '' TERM; sleep 30"], environment: [:],
                                      output: .capture(cap: 1024, stderr: false), timeout: 0.2, killGrace: 0.1, abandonAfter: 0)
        #expect(abandoned.status == -1 && abandoned.error != nil, "an abandoned leader must not read as success: \(abandoned)")
        // A child reaped out from under GroupExec (its exit status lost) is a failure with a reason, never status 0, even
        // though it really exited 0 (N4).
        let lost = GroupExec.run(executable: "/bin/sh", arguments: ["-c", "exit 0"], environment: [:],
                                 output: .capture(cap: 1024, stderr: false), timeout: 10,
                                 spawned: { pid in var st: Int32 = 0; while waitpid(pid, &st, 0) < 0 && errno == EINTR {} })
        #expect(lost.status == -1, "\(lost)")
        #expect(lost.error?.contains("lost track") == true, "\(lost)")
    }

    @Test func aFastProcessReturnsItsOutputAndAFailingOneNil() async throws {
        let ok = try await Doctor.execProcess(executable: "/bin/echo", arguments: ["2.1.304 (Claude Code)"], timeout: 10)
        #expect(ok == "2.1.304 (Claude Code)\n")
        let bad = try await Doctor.execProcess(executable: "/usr/bin/false", arguments: [], timeout: 10)
        #expect(bad == nil)
    }

    @Test func aTimedOutExecIsAFailingItemWithAClearDetail() async {
        let hang: Doctor.Exec = { _, _ in throw Doctor.ExecTimedOut(command: "claude --version", seconds: 30) }
        let r = await Doctor.run(claudePath: "claude", runner: ProbeRunner([]), exec: hang, now: t0)
        #expect(!r.ok)
        #expect(item(r, "version")?.status == .fail)
        #expect(item(r, "version")?.detail.contains("did not finish within 30 s") == true, "\(r.items)")
        let help: Doctor.Exec = { _, a in if a == ["--help"] { throw Doctor.ExecTimedOut(command: "claude --help", seconds: 30) }; return "2.1.304 (Claude Code)" }
        let r2 = await Doctor.run(claudePath: "claude", runner: ProbeRunner(good()), exec: help, now: t0)
        #expect(item(r2, "flags")?.status == .fail)
        #expect(item(r2, "flags")?.detail.contains("did not finish") == true, "\(r2.items)")
    }

    /// Many doctor execs at once must not take the cooperative workers: an unrelated async task still runs promptly.
    @Test func manyConcurrentExecsDoNotStarveTheCooperativePool() async throws {
        let n = max(ProcessInfo.processInfo.activeProcessorCount * 3, 24)
        let pool = Blocking()
        let probe = Task { () -> TimeInterval in
            let t = AwakeTime.uptime()
            try? await AwakeTime.sleep(for: .milliseconds(50))
            return AwakeTime.uptime() - t
        }
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<n { g.addTask { _ = try? await Doctor.execProcess(executable: "/bin/sleep", arguments: ["0.2"], timeout: 10, blocking: pool) } }
            let elapsed = await probe.value
            #expect(elapsed < 0.6, "the unrelated task took \(elapsed) s")
            await g.waitForAll()
        }
    }
}
