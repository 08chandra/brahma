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
private func exec(version: String = "2.1.312 (Claude Code)", help: String = helpText) -> Doctor.Exec {
    { _, args in args == ["--version"] ? version : args == ["--help"] ? help : nil }
}
private let t0 = Date(timeIntervalSince1970: 1_000_000)

private func item(_ r: DoctorReport, _ name: String) -> DoctorItem? { r.items.first { $0.name == name } }

@Suite(.scratch) struct DoctorTests {
    /// Plan S Task S5 (B9): `brahma doctor`'s `tools` line names the engine's tools by absolute path; git missing or older
    /// than 2.43 fails it, a missing `claude` warns.
    @Test func toolsItemNamesTheEnginesTools() {
        let tools = ToolPaths(git: "/opt/x/bin/git", claude: "/opt/x/bin/claude", gitVersion: "2.52.0")
        let item = Doctor.toolPathsItem(.success(tools))
        #expect(item.name == "tools" && item.status == .pass)
        #expect(item.detail == "git /opt/x/bin/git 2.52.0 · claude /opt/x/bin/claude · unzip /usr/bin/unzip · tar /usr/bin/tar")
        let noClaude = Doctor.toolPathsItem(.success(ToolPaths(git: "/opt/x/bin/git", claude: nil, gitVersion: "2.52.0")))
        #expect(noClaude.status == .warn && noClaude.detail.contains("claude not found"))
        #expect(Doctor.toolPathsItem(.failure(.gitMissing)).status == .fail)
        let old = Doctor.toolPathsItem(.failure(.gitTooOld("2.39.5")))
        #expect(old.status == .fail && old.detail.contains("2.39.5") && old.detail.contains("2.43"))
        // The engine's own resolution on this machine: git found, by absolute path, at least 2.43. The test process's one
        // install comes first (Ruling F2-7): this test asks for no temp dir, so run alone nothing else would have installed it.
        _ = toolPathsInstalled
        let live = Doctor.toolPathsItem()
        #expect(live.status != .fail && live.detail.hasPrefix("git /"), "\(live.detail)")
    }

    @Test func allPass() async {
        let runner = ProbeRunner(good())
        let r = await Doctor.run(claudePath: "claude", runner: runner, exec: exec(), now: t0)
        #expect(r.ok, "\(r.items)")
        #expect(r.cliVersion == "2.1.312")
        // Plan C Task C4c adds `collab-tools` (the tool-schema budget).
        #expect(r.items.map(\.name) == ["version", "flags", "probe", "resume-keeps-role", "overage", "tools-present", "sideload-allowed",
                                        "collab-tools"])
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

    /// `plugin-details-inert` (Task 5a): `claude plugin details` on a fixture plugin with hooks and an MCP server, run under the
    /// sandboxed runner with hooks off, creates no marker file. A CLI that ran either part fails the item.
    @Test func pluginDetailsIsInert() async throws {
        // What the real CLI prints for the fixture (probed on 2.1.312): the inline source and both parts counted, none run.
        let inert = try FakeTools.script("claude", """
        echo 'doctor-fixture 1.0.0'; echo '  Source: doctor-fixture@inline'; echo 'Component inventory'
        echo '  Skills (1)  doctor-fixture'; echo '  Agents (1)  helper'; echo '  Hooks (1)  SessionStart'; echo '  MCP servers (1)  fixture'
        echo 'Projected token cost'; echo '  Always-on:   ~14 tok   added to every session'; exit 0
        """)
        let runner = RecordingRunner()
        let r = await Doctor.run(claudePath: inert.path, runner: ProbeRunner(good()), exec: exec(), now: t0, sandbox: runner)
        let found = try #require(item(r, "plugin-details-inert"))
        #expect(found.status == .pass, "\(found.detail)")
        let call = try #require(runner.calls.first)
        #expect(call.policy.network == .none)
        // C2: global options first, then `--plugin-dir <dir> plugin details <name>`.
        let hardening = "--setting-sources '' --strict-mcp-config --settings '{\"disableAllHooks\":true}'"
        #expect(call.command.contains("' \(hardening) --plugin-dir '"), "\(call.command)")
        #expect(call.command.hasSuffix("plugin details 'doctor-fixture'"), "\(call.command)")
        #expect(call.environment["CLAUDE_CONFIG_DIR"]?.hasSuffix("/cc") == true)
        // Exit 0 alone proves nothing: without the inventory the item warns.
        let silent = try FakeTools.script("claude", "exit 0")
        let r0 = await Doctor.run(claudePath: silent.path, runner: ProbeRunner(good()), exec: exec(), now: t0, sandbox: RecordingRunner())
        #expect(item(r0, "plugin-details-inert")?.status == .warn)
        let usage = try FakeTools.script("claude", "echo \"error: unknown option '--setting-sources'\" >&2; exit 1")
        #expect(item(await Doctor.run(claudePath: usage.path, runner: ProbeRunner(good()), exec: exec(), now: t0, sandbox: RecordingRunner()), "plugin-details-inert")?.status == .warn)
        // The fixture really has every part (hooks/, .mcp.json, a skill-frontmatter hook, an agent-frontmatter MCP server), so a
        // CLI that honoured any of them would leave a marker.
        let hostile = try FakeTools.script("claude", """
        for a in "$@"; do
          if [ -f "$a/skills/doctor-fixture/SKILL.md" ]; then sh -c "$(sed -n 's/.*command: *"\\([^"]*\\)".*/\\1/p' "$a/skills/doctor-fixture/SKILL.md" | head -1)"; fi
        done
        echo '  Source: doctor-fixture@inline'; echo '  Hooks (1)'; echo '  MCP servers (1)'
        exit 0
        """)
        let r2 = await Doctor.run(claudePath: hostile.path, runner: ProbeRunner(good()), exec: exec(), now: t0, sandbox: RecordingRunner())
        #expect(item(r2, "plugin-details-inert")?.status == .fail, "\(String(describing: item(r2, "plugin-details-inert")))")
        #expect(!r2.ok)
        // Without a sandbox runner the item is not run (the doctor command always passes one).
        #expect(item(await Doctor.run(claudePath: inert.path, runner: ProbeRunner(good()), exec: exec(), now: t0), "plugin-details-inert") == nil)
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
        // No tools list in the init event: nothing proves the tools are there (fix round 1, M2: fail).
        let none = await Doctor.run(claudePath: "claude", runner: ProbeRunner([[initEvent, limit(), result("OK")],
                                                                               [initEvent, result("BRAHMA-PROBE-7")]]),
                                    exec: exec(), now: t0)
        #expect(item(none, "tools-present")?.status == .fail); #expect(!none.ok)
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
        #expect(item(r, "sideload-allowed")?.detail.contains("--mcp-config") == true, "the company server is ignored too")
        try Data("not json".utf8).write(to: managed)
        #expect(item(await run(), "sideload-allowed")?.status == .fail, "unreadable managed settings: cannot tell")
        #expect(Doctor.managedSettingsPath == "/Library/Application Support/ClaudeCode/managed-settings.json")
        // M3: the drop-in folder next to it counts too.
        try Data(#"{"other": 1}"#.utf8).write(to: managed)
        let dropIns = dir.appending(path: "managed-settings.d")
        try FileManager.default.createDirectory(at: dropIns, withIntermediateDirectories: true)
        try Data(#"{"x": 1}"#.utf8).write(to: dropIns.appending(path: "10-ok.json"))
        #expect(item(await run(), "sideload-allowed")?.status == .pass)
        try Data(#"{"disableSideloadFlags": true}"#.utf8).write(to: dropIns.appending(path: "20-lock.json"))
        #expect(item(await run(), "sideload-allowed")?.status == .fail)
        try FileManager.default.removeItem(at: dropIns.appending(path: "20-lock.json"))
        // And the MDM profile, when readable.
        let mdm = dir.appending(path: "com.anthropic.claudecode.plist")
        let plist = try PropertyListSerialization.data(fromPropertyList: ["disableSideloadFlags": true], format: .xml, options: 0)
        try plist.write(to: mdm)
        let viaMDM = await Doctor.run(claudePath: "claude", runner: ProbeRunner(good()), exec: exec(), now: t0,
                                      managedSettingsPath: managed.path, managedPreferencesPath: mdm.path)
        #expect(item(viaMDM, "sideload-allowed")?.status == .fail)
        try FileManager.default.removeItem(at: mdm)
        // Fix round 2: a drop-in folder that cannot be listed fails (it may hold the setting).
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: dropIns.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dropIns.path) }   // exec-bit fixture: a directory mode
        #expect(item(await run(), "sideload-allowed")?.status == .fail)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: dropIns.path)   // exec-bit fixture: a directory mode
        // And the per-user MDM profile.
        #expect(Doctor.managedPreferencePaths(user: "owner") == ["/Library/Managed Preferences/com.anthropic.claudecode.plist",
                                                                  "/Library/Managed Preferences/owner/com.anthropic.claudecode.plist"])
    }

    /// C1: exec-form hooks (and `onFailure`) are verified live on 2.1.312; an older CLI may run a hook without its arguments,
    /// which would let it fail open, so the minimum is 2.1.312.
    @Test func minimumVersionHasExecFormHooks() async {
        #expect(Doctor.minimumVersion == "2.1.312")
        let r = await Doctor.run(claudePath: "claude", runner: ProbeRunner(good()), exec: exec(version: "2.1.308 (Claude Code)"), now: t0)
        #expect(!r.ok); #expect(item(r, "version")?.status == .fail)
    }

    @Test func oldVersionFails() async {
        let r = await Doctor.run(claudePath: "claude", runner: ProbeRunner(good()), exec: exec(version: "2.1.299 (Claude Code)"), now: t0)
        #expect(!r.ok); #expect(item(r, "version")?.status == .fail)
    }

    @Test func newerVersionWarns() async {
        let r = await Doctor.run(claudePath: "claude", runner: ProbeRunner(good()), exec: exec(version: "2.1.313 (Claude Code)"), now: t0)
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
                                            runner: ProbeRunner([[initEvent, initTools, result("OK")], [initEvent, result("BRAHMA-PROBE-7")]]),
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
                                    exec: exec(version: "2.1.314 (Claude Code)"), now: t0.addingTimeInterval(60))
        #expect(second.requests.count == 2); #expect(r.cliVersion == "2.1.314")
        #expect(try store.latestProbe()?.cliVersion == "2.1.314")
    }
}

@Suite(.scratch, .serialized) struct DoctorExecTests {
    /// Asserts the kill and the throw, not how long they took (a wall-clock bound failed under parallel load at 60.2 s): the
    /// hung process writes its pid, then becomes a 600 s sleep; once the exec has thrown its timeout, that process is gone.
    /// Only a kill can explain that, since nothing else ends a 600 s sleep before the test does. A run whose timeout fired
    /// before the shell wrote its pid proves nothing, so it is repeated with a doubled timeout (bounded: 0.3 s … 38.4 s).
    @Test func aHangingProcessIsKilledAtTheTimeoutAndThrows() async throws {
        let dir = try tempDir()
        var timeout: TimeInterval = 0.3
        for attempt in 0..<8 {
            let file = dir.appending(path: "hung-\(attempt).pid")
            do {
                _ = try await Doctor.execProcess(executable: "/bin/sh", arguments: ["-c", "echo $$ > '\(file.path)'; exec /bin/sleep 600"],
                                                 timeout: timeout, blocking: Blocking())
                Issue.record("expected a timeout")
                return
            } catch let e as Doctor.ExecTimedOut {
                #expect(e.description.contains("did not finish within"), "\(e)")
            }
            if let pid = Self.pidLine(file) {
                // Gone, or a zombie (dead, not yet reaped): either way it no longer runs.
                let gone: Bool
                switch ProcessTable.lookup(pid) {
                case .found(let e): gone = e.isZombie
                case .absent: gone = true
                case .unreadable: gone = false                                // fail closed
                }
                #expect(gone, "the hung process outlived its timeout")
                return
            }
            timeout *= 2
        }
        Issue.record("the shell never wrote its pid, even with a 38 s timeout")
    }

    /// The engine's bounded tool runs (doctor, rclone, zstd/gzip, lsof) all go through `GroupExec`: a hung tool's children
    /// die with it, since its whole process group is signalled.
    @Test func aHungToolsChildrenAreKilledWithItsGroup() async throws {
        // Two pid files: the doctor's run and the external tool's run are each asserted (INT-M3).
        let dir = try tempDir()
        func script(_ f: URL) -> String { "/bin/sleep 600 & echo $! > '\(f.path)'; wait" }
        // The timeout is what is under test, so it starts short. Under load the shell may not have started its child (and
        // written its pid line) before the timeout fires: such a run proves nothing, so it is repeated with a doubled
        // timeout until one did (bounded: 0.5 s … 64 s). Every run must still end as a timeout.
        var doctorChild: Int32?, toolChild: Int32?
        var timeout: TimeInterval = 0.5
        for attempt in 0..<8 where doctorChild == nil || toolChild == nil {
            if doctorChild == nil {
                let file = dir.appending(path: "doctor-\(attempt).pid")
                do {
                    _ = try await Doctor.execProcess(executable: "/bin/sh", arguments: ["-c", script(file)], timeout: timeout, blocking: Blocking())
                    Issue.record("a hung doctor exec must time out")
                } catch is Doctor.ExecTimedOut {}
                doctorChild = Self.pidLine(file)
            }
            if toolChild == nil {
                let file = dir.appending(path: "tool-\(attempt).pid")
                let r = ExternalTool.run(executable: "/bin/sh", arguments: ["-c", script(file) + "; echo never"], environment: [:], timeout: timeout)
                #expect(r.timedOut && r.launched)
                toolChild = Self.pidLine(file)
            }
            timeout *= 2
        }
        for (name, child) in [("doctor", doctorChild), ("tool", toolChild)] {
            let pid = try #require(child, "\(name): the shell never started its child, even with a 64 s timeout")
            let until = AwakeTime.uptime() + 120
            while kill(pid, 0) == 0, AwakeTime.uptime() < until { try await AwakeTime.sleep(for: .milliseconds(20)) }
            #expect(kill(pid, 0) != 0, "\(name): the tool's background child outlived the timeout")
        }
        // A normal run still captures stdout and stderr and returns the exit code.
        let ok = ExternalTool.run(executable: "/bin/sh", arguments: ["-c", "echo out; echo err >&2; exit 3"], environment: [:], timeout: 120)
        #expect(ok.status == 3 && ok.output == "out\nerr\n" && !ok.timedOut, "\(ok)")
    }

    /// INT-I2/M4/M5: `GroupExec` never reports a lost or abandoned leader as success; its default working directory is `/`;
    /// the wait after SIGKILL is bounded by default.
    @Test func groupExecNeverReportsALostChildAsSuccess() throws {
        #expect(GroupExec.defaultAbandonAfter > 0)
        let cwd = GroupExec.run(executable: "/bin/pwd", arguments: [], environment: [:], output: .capture(cap: 1024, stderr: false), timeout: 120)
        #expect(cwd.status == 0); #expect(String(decoding: cwd.output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) == "/")
        // A leader given up on right after SIGKILL (abandonAfter 0) is reported as a failure with a reason, never status 0.
        // Its clock is injected: it stands still until the shell says its TERM trap is set (a file event), then moves one
        // second per reading, so the timeout, TERM (ignored) and KILL come in that order however slow the shell starts.
        let ready = try tempDir().appending(path: "trapped")
        let began = AwakeTime.uptime()
        var t: TimeInterval = 0
        let abandoned = GroupExec.run(executable: "/bin/sh", arguments: ["-c", "trap '' TERM; : > '\(ready.path)'; sleep 600"], environment: [:],
                                      output: .capture(cap: 1024, stderr: false), timeout: 0.2, killGrace: 0.1, abandonAfter: 0,
                                      clock: {
                                          // Backstop: a shell that never gets there still ends the run (and fails below).
                                          if FileManager.default.fileExists(atPath: ready.path) || AwakeTime.uptime() - began > 120 { t += 1 }
                                          return t
                                      })
        #expect(FileManager.default.fileExists(atPath: ready.path), "the shell never set its trap")
        #expect(abandoned.status == -1 && abandoned.error != nil, "an abandoned leader must not read as success: \(abandoned)")
        // A child reaped out from under GroupExec (its exit status lost) is a failure with a reason, never status 0, even
        // though it really exited 0 (N4).
        let lost = GroupExec.run(executable: "/bin/sh", arguments: ["-c", "exit 0"], environment: [:],
                                 output: .capture(cap: 1024, stderr: false), timeout: 120,
                                 spawned: { pid in var st: Int32 = 0; while waitpid(pid, &st, 0) < 0 && errno == EINTR {} })
        #expect(lost.status == -1, "\(lost)")
        #expect(lost.error?.contains("lost track") == true, "\(lost)")
    }

    @Test func aFastProcessReturnsItsOutputAndAFailingOneNil() async throws {
        let ok = try await Doctor.execProcess(executable: "/bin/echo", arguments: ["2.1.304 (Claude Code)"], timeout: 120)
        #expect(ok == "2.1.304 (Claude Code)\n")
        let bad = try await Doctor.execProcess(executable: "/usr/bin/false", arguments: [], timeout: 120)
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

    /// Many doctor execs at once must not take the cooperative workers: an unrelated async task still runs while they hang.
    /// Event-ordered, no timing: every exec blocks until a gate file appears; a watcher thread (outside the cooperative pool)
    /// opens the gate only once the pool's slots are all held by hung execs AND the unrelated task has finished, or after a
    /// generous backstop. Execs that took cooperative workers would keep the unrelated task from ever running.
    @Test func manyConcurrentExecsDoNotStarveTheCooperativePool() async throws {
        let n = max(ProcessInfo.processInfo.activeProcessorCount * 3, 24)
        let pool = Blocking()
        let dir = try tempDir(), gate = dir.appending(path: "gate"), started = try Self.mkdir(dir.appending(path: "started"))
        let hung = "/usr/bin/touch \"$1/started/$$\"; while [ ! -e \"$1/gate\" ]; do /bin/sleep 0.05; done"
        let watch = StarvationWatch()
        let probe = Task {
            try? await AwakeTime.sleep(for: .milliseconds(50))
            watch.probeDone()
        }
        let watcher = Thread {
            let until = AwakeTime.uptime() + 300
            let slots = min(n, Blocking.maxConcurrent)
            func hungCount() -> Int { ((try? FileManager.default.contentsOfDirectory(atPath: started.path)) ?? []).count }
            while !(watch.isProbeDone && hungCount() >= slots), AwakeTime.uptime() < until { Thread.sleep(forTimeInterval: 0.02) }
            watch.gateOpening(hung: hungCount())
            FileManager.default.createFile(atPath: gate.path, contents: nil)
        }
        watcher.start()
        await withTaskGroup(of: Void.self) { g in
            for _ in 0..<n {
                g.addTask { _ = try? await Doctor.execProcess(executable: "/bin/sh", arguments: ["-c", hung, "sh", dir.path], timeout: 600, blocking: pool) }
            }
            await g.waitForAll()
        }
        await probe.value
        let (probeFirst, hungAtGate) = watch.verdict
        #expect(probeFirst, "the unrelated task did not run while the execs hung (\(hungAtGate) of them held the pool)")
        #expect(hungAtGate >= min(n, Blocking.maxConcurrent), "the execs did not all hang at once: \(hungAtGate)")
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: started.path)) ?? []).count == n, "every exec ran")
    }

    private static func mkdir(_ url: URL) throws -> URL {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    /// The pid a script wrote as one whole line (`echo $! > file`), or nil while the line is not complete yet.
    private static func pidLine(_ file: URL) -> Int32? {
        guard let text = try? String(contentsOf: file, encoding: .utf8), text.hasSuffix("\n") else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }
}

/// What the starvation test's watcher saw when it opened the gate.
private final class StarvationWatch: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false, doneBeforeGate = false, hung = 0
    func probeDone() { lock.withLock { done = true } }
    var isProbeDone: Bool { lock.withLock { done } }
    func gateOpening(hung count: Int) { lock.withLock { doneBeforeGate = done; hung = count } }
    var verdict: (Bool, Int) { lock.withLock { (doneBeforeGate, hung) } }
}
