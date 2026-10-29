import Testing
import Foundation
@testable import BrahmaCore

/// The turn's process lifetime (Task 1a re-review, binding on 1b): no process of a turn outlives it. The fake `claude` is
/// `/bin/sh -c <script>` (a system binary, so it runs while new executables stall), started the way every turn is: its own
/// session, swept when the turn ends.
/// Each request its own agent id: the runner's per-agent registry is process-wide, and another suite's turn of "a1" must not
/// make this one wait.
private func request(in dir: URL, agentId: String = "c-" + UUID().uuidString.prefix(8).lowercased()) -> TurnRequest {
    let agent = Agent(id: agentId, companyId: "c1", name: "ceo", role: "ceo", model: "sonnet", sessionId: "s1",
                      sessionStarted: false, state: .running, blocker: nil, requestedBlocker: nil, paused: false,
                      readySince: nil, createdAt: Date(timeIntervalSince1970: 0))
    let company = Company(id: "c1", name: "Acme", slug: "acme", goal: "g", workspacePath: dir.path, status: .running,
                          usageMode: .low, priorityWeight: 1, createdAt: Date(timeIntervalSince1970: 0))
    return TurnRequest(agent: agent, company: company, prompt: "PROMPT", appendSystemPrompt: "ROLE",
                       mcpConfigPath: "/tmp/x.mcp.json", workingDirectory: dir.path, profile: .workspace,
                       environment: ["BRAHMA_AGENT_ID": agentId])
}

private func shRunner(_ script: String) -> ClaudeProcessRunner {
    var runner = ClaudeProcessRunner(claudePath: "/bin/sh", baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory()])  // raw-temp-api: a HOME value for /bin/sh, nothing written there
    runner.leadingArguments = ["-c", script, "fake-claude"]
    return runner
}

private let initLine = #"{"type":"system","subtype":"init","session_id":"s1","model":"m"}"#
private let resultLine = #"{"type":"result","subtype":"success","is_error":false,"result":"ok","session_id":"s1"}"#

private func collect(_ stream: AsyncThrowingStream<StreamEvent, Error>) async throws -> [StreamEvent] {
    var out: [StreamEvent] = []
    for try await e in stream { out.append(e) }
    return out
}

private func pid(in file: URL) async throws -> pid_t {
    for _ in 0..<400 {
        if let text = try? String(contentsOf: file, encoding: .utf8), text.hasSuffix("\n"), let pid = pid_t(text.trimmingCharacters(in: .whitespacesAndNewlines)) {
            return pid
        }
        try await Task.sleep(for: .milliseconds(10))
    }
    throw FakeError(description: "no pid in \(file.path)")
}

/// A process that is gone (or only a zombie its parent has not reaped yet).
private func gone(_ pid: pid_t) async -> Bool {
    for _ in 0..<200 {
        if kill(pid, 0) != 0 { return true }
        if ProcessTable.entry(pid)?.isZombie == true { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return false
}

/// A sandboxed turn's request on a hand-made scope (the runner only needs its shape): workspace, the agent's home and lab.
private struct SandboxedRequestWorld {
    let dir: URL
    let ws: URL
    let home: URL
    let request: TurnRequest
    /// The turn's mach marker (Task 2's mechanism, adopted for turns) and where its leader is recorded.
    let marker = "dev.brahma.turn.\(UUID().uuidString.lowercased())"
    var records: URL { dir.appending(path: "turns") }

    /// A Seatbelt profile shaped like the turn's: writes in the agent's home, its marker allowed and every other turn marker
    /// denied (as Claude Code's own profile denies unlisted mach names).
    var profile: String {
        "(version 1)(allow default)(deny file-write*)(allow file-write* (subpath \"\(home.path)\"))"
            + "(deny mach-lookup (global-name-prefix \"dev.brahma.turn.\"))(allow mach-lookup (global-name \"\(marker)\"))"
    }

    init() throws {
        dir = URL(fileURLWithPath: SandboxPath.resolve(try tempDir().path), isDirectory: false)
        ws = dir.appending(path: "ws")
        home = ws.appending(path: ".brahma/home/eng-1")
        let lab = ws.appending(path: ".brahma/labs/eng-1")
        for d in [home, lab] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        let scope = SandboxScope(workspace: ws, cwd: lab, writable: [home, lab], readable: [home, lab], readOnlyDirs: [],
                                 denyRead: [], denyWrite: [], protected: [],
                                 network: NetworkScope(allowedDomains: [], webDomains: [], allowLocalBinding: false),
                                 toolchainTempWrite: nil)
        var r = Self.base(dir, agentId: "s-" + UUID().uuidString.prefix(8).lowercased(), name: "eng-1")
        r.profile = .sandboxed
        r.sandbox = scope
        r.shellPrefix = ws.appending(path: ".brahma/bin/shell-eng-1.sh").path
        r.settingsFilePath = dir.appending(path: "a1.settings.json").path
        r.containmentMarker = marker
        r.turnRecordDirectory = dir.appending(path: "turns")
        request = r
    }

    static func base(_ dir: URL, agentId: String, name: String) -> TurnRequest {
        let agent = Agent(id: agentId, companyId: "c1", name: name, role: "engineer", model: "sonnet", sessionId: "s1",
                          sessionStarted: false, state: .running, blocker: nil, requestedBlocker: nil, paused: false,
                          readySince: nil, createdAt: Date(timeIntervalSince1970: 0))
        let company = Company(id: "c1", name: "Acme", slug: "acme", goal: "g", workspacePath: dir.appending(path: "ws").path,
                              status: .running, usageMode: .low, priorityWeight: 1, createdAt: Date(timeIntervalSince1970: 0))
        return TurnRequest(agent: agent, company: company, prompt: "PROMPT", appendSystemPrompt: "ROLE",
                           mcpConfigPath: "/tmp/x.mcp.json", workingDirectory: dir.path, profile: .workspace,
                           environment: ["BRAHMA_AGENT_ID": agentId])
    }
}

/// `perl -e 'use POSIX; ...'` (a system binary) stands in for `setsid`, which macOS does not ship.
private let perl = "/usr/bin/perl"

@Suite(.scratch, .serialized) struct TurnContainmentTests {
    /// `setsid sleep 300 &`: a new session and process group, reparented to launchd once the shell exits.
    @Test func backgroundedSessionLeaderDoesNotSurviveTheTurn() async throws {
        let dir = try tempDir()
        let pidFile = dir.appending(path: "escapee.pid")
        let runner = shRunner("""
            cat > /dev/null
            \(perl) -e 'use POSIX; POSIX::setsid(); open(F, ">", $ARGV[0]); print F "$$\\n"; close F; exec "/bin/sleep", "300"' '\(pidFile.path)' &
            while [ ! -s '\(pidFile.path)' ]; do sleep 0.05; done
            echo '\(initLine)'
            echo '\(resultLine)'
            """)
        let events = try await collect(runner.run(request(in: dir)))
        #expect(events.contains { if case .result = $0 { true } else { false } })
        let escapee = try await pid(in: pidFile)
        #expect(await gone(escapee), "the setsid'd background process outlived its turn")
    }

    /// The same escapee with the turn's marker removed from its environment: it is still a descendant the engine watched.
    @Test func escapeeWithoutTheMarkerIsStillTracked() async throws {
        let dir = try tempDir()
        let pidFile = dir.appending(path: "escapee.pid")
        let runner = shRunner("""
            cat > /dev/null
            /usr/bin/env -u BRAHMA_TURN_MARK \(perl) -e 'use POSIX; POSIX::setsid(); open(F, ">", $ARGV[0]); print F "$$\\n"; close F; exec "/bin/sleep", "300"' '\(pidFile.path)' &
            while [ ! -s '\(pidFile.path)' ]; do sleep 0.05; done
            sleep 0.5
            echo '\(initLine)'
            echo '\(resultLine)'
            """)
        _ = try await collect(runner.run(request(in: dir)))
        let escapee = try await pid(in: pidFile)
        #expect(await gone(escapee), "a descendant without the marker outlived its turn")
    }

    /// The escape every other channel misses: a double fork into a new session, faster than any poll, with the turn's marker
    /// variable removed. On a sandboxed turn its sandbox still gives it away: it allows the turn's unique mach name (Task 2's
    /// unremovable marker). It also deletes the agent's home first (the old write-shape probe's blind spot, B-I2).
    @Test func doubleForkedSandboxedEscapeeIsFoundByItsMarker() async throws {
        let w = try SandboxedRequestWorld()
        let pidFile = w.dir.appending(path: "out/escapee.pid")
        try FileManager.default.createDirectory(at: pidFile.deletingLastPathComponent(), withIntermediateDirectories: true)
        let profile = w.profile.replacingOccurrences(of: "\"", with: "\\\"")
            .replacingOccurrences(of: "(allow file-write* (subpath", with: "(allow file-write* (subpath \\\"\(pidFile.deletingLastPathComponent().path)\\\") (subpath")
        var runner = shRunner("""
            cat > /dev/null
            /usr/bin/sandbox-exec -p "\(profile)" /usr/bin/env -u BRAHMA_TURN_MARK \(perl) -e 'use POSIX; exit 0 if fork; POSIX::setsid(); exit 0 if fork; system("/bin/rm", "-rf", $ARGV[1]); open(F, ">", $ARGV[0]); print F "$$\\n"; close F; close STDOUT; close STDERR; exec "/bin/sleep", "300"' '\(pidFile.path)' '\(w.home.path)'
            while [ ! -s '\(pidFile.path)' ]; do sleep 0.05; done
            echo '\(initLine)'
            echo '\(resultLine)'
            """)
        runner.baseEnvironment["PATH"] = "/usr/bin:/bin"
        _ = try await collect(runner.run(w.request))
        let escapee = try await pid(in: pidFile)
        #expect(await gone(escapee), "a double-forked, sandboxed process outlived its turn")
    }

    @Test func markerProbeMatchesOnlyThisTurnsSandbox() async throws {
        let w = try SandboxedRequestWorld()
        func start(_ args: [String]) throws -> Process {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: args[0]); p.arguments = Array(args.dropFirst())
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run()
            return p
        }
        let mine = try start(["/usr/bin/sandbox-exec", "-p", w.profile, "/bin/sleep", "30"])
        let other = try start(["/usr/bin/sandbox-exec", "-p", w.profile.replacingOccurrences(of: w.marker, with: w.marker + "x"), "/bin/sleep", "30"])
        let allowAll = try start(["/usr/bin/sandbox-exec", "-p", "(version 1)(allow default)", "/bin/sleep", "30"])
        let plain = try start(["/bin/sleep", "30"])
        defer { for p in [mine, other, allowAll, plain] { p.terminate() } }
        try await Task.sleep(for: .milliseconds(300))
        let probe = SandboxProbe(machMarker: w.marker)
        #expect(probe.classify(mine.processIdentifier) == .mine)
        #expect(probe.classify(other.processIdentifier) == .notMine, "another turn")
        #expect(probe.classify(allowAll.processIdentifier) == .notMine, "a sandbox that allows every lookup")
        #expect(probe.classify(plain.processIdentifier) == .notMine, "not sandboxed")
        #expect(probe.classify(getpid()) == .notMine)
    }

    /// B-I2: a sandboxed process whose policy the kernel cannot read counts as a survivor (fail closed), never as "not ours".
    @Test func unreadableSandboxCountsAsASurvivor() async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep"); p.arguments = ["30"]
        let since = ProcessTable.startStamp(slack: 1)
        try p.run()
        defer { p.terminate() }
        let result = SandboxSweep.run(probe: SandboxProbe(machMarker: "dev.brahma.turn.none"), since: since,
                                      classify: { $0 == p.processIdentifier ? .unknown : .notMine })
        #expect(result.survivors.contains(p.processIdentifier)); #expect(!result.clean)
    }

    /// B-I2: once per engine, the engine checks it can see what a sandbox allows; on this Mac it can.
    @Test func containmentSelfTestPasses() {
        #if os(macOS)
        #expect(ContainmentSelfTest.run())
        #else
        #expect(!ContainmentSelfTest.run())
        #endif
    }

    /// B-I1: a turn's leader is recorded where a restarted engine finds it. An engine that crashed mid-turn left the leader
    /// (in its own session) and its children running; the next engine kills them all, and only then forgets the record.
    @Test func restartedEngineKillsAnEarlierEnginesTurn() async throws {
        let dir = try tempDir()
        let records = dir.appending(path: "turns")
        let childFile = dir.appending(path: "child.pid")
        let since = ProcessTable.startStamp(slack: 1)
        let leader = try ProcessGroupChild.spawn(executable: "/bin/sh", arguments: ["sh", "-c", "/bin/sleep 300 & echo $! > '\(childFile.path)'; exec /bin/sleep 300"],
                                                 environment: ["PATH": "/usr/bin:/bin"], workingDirectory: dir, output: -1, newSession: true)
        let child = try await pid(in: childFile)
        let start = try #require(ProcessTable.entry(leader.pid)?.start)
        try TurnRecords.add(TurnRecord(leader: leader.pid, leaderStart: start, since: since, machMarker: nil), agentId: "a1", in: records)
        // A fresh registry: nothing in memory knows this turn.
        let left = try await TurnRegistry().waitUntilGone("a1", records: records, deadline: .seconds(10))
        #expect(left.survivors.isEmpty)
        #expect(Set(left.killed).isSuperset(of: [leader.pid, child]))
        _ = leader.finish()
        #expect(await gone(child))
        #expect(try TurnRecords.load(agentId: "a1", in: records).isEmpty, "the record goes once nothing is left")
    }

    /// B-I1 with the marker: a sandboxed escapee of a crashed engine's turn (out of the session and group) is found by the
    /// marker in the record.
    @Test func restartedEngineKillsAMarkedEscapee() async throws {
        let w = try SandboxedRequestWorld()
        let pidFile = w.home.appending(path: "escapee.pid")
        let since = ProcessTable.startStamp(slack: 1)
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        p.arguments = ["-p", w.profile, perl, "-e", "use POSIX; exit 0 if fork; POSIX::setsid(); exit 0 if fork; open(F, \">\", $ARGV[0]); print F \"$$\\n\"; close F; exec \"/bin/sleep\", \"300\"", pidFile.path]
        try p.run(); p.waitUntilExit()
        let escapee = try await pid(in: pidFile)
        try TurnRecords.add(TurnRecord(leader: 999_999, leaderStart: since, since: since, machMarker: w.marker), agentId: "a1", in: w.records)
        let left = try await TurnRegistry().waitUntilGone("a1", records: w.records, deadline: .seconds(10))
        #expect(left.killed.contains(escapee)); #expect(left.survivors.isEmpty)
        #expect(await gone(escapee))
    }

    /// M2: a wait that cannot finish fails closed: on its deadline, or when the waiting task is cancelled.
    @Test func waitFailsClosedOnDeadlineAndCancellation() async throws {
        let registry = TurnRegistry()
        try await registry.claim("a1", deadline: .seconds(5))   // an in-flight turn that never ends
        await #expect(throws: (any Error).self) { _ = try await registry.waitUntilGone("a1", records: nil, deadline: .milliseconds(200)) }
        let waiter = Task { try await registry.waitUntilGone("a1", records: nil, deadline: .seconds(30)) }
        waiter.cancel()
        await #expect(throws: (any Error).self) { _ = try await waiter.value }
        // M3: claiming is "nothing running, then begin" in one step: a second claim waits for the first to end.
        await #expect(throws: (any Error).self) { try await registry.claim("a1", deadline: .milliseconds(200)) }
        registry.end("a1", survivors: [])
        try await registry.claim("a1", deadline: .seconds(1))
        registry.end("a1", survivors: [])
    }

    /// M13: the wait overlaps a turn whose stream was dropped while its processes are still being swept.
    @Test func waitCoversATurnStillBeingSwept() async throws {
        let dir = try tempDir()
        let overlap = "o-" + UUID().uuidString.prefix(8).lowercased()
        let pidFile = dir.appending(path: "child.pid")
        let runner = shRunner("""
            cat > /dev/null
            \(perl) -e 'use POSIX; POSIX::setsid(); open(F, ">", $ARGV[0]); print F "$$\\n"; close F; exec "/bin/sleep", "300"' '\(pidFile.path)' &
            while [ ! -s '\(pidFile.path)' ]; do sleep 0.05; done
            echo '\(initLine)'
            exec /bin/sleep 30
            """)
        let turn = Task { () -> Void in
            for try await e in runner.run(request(in: dir, agentId: overlap)) { if case .initialized = e { return } }
        }
        try await turn.value   // the stream is dropped after init: the runner terminates and sweeps on its own
        let child = try await pid(in: pidFile)
        let left = try await runner.waitForTurnProcesses(agentId: overlap, records: dir.appending(path: "turns"))
        #expect(left.survivors.isEmpty)
        #expect(ProcessTable.entry(child) == nil || ProcessTable.entry(child)?.isZombie == true, "swept before the wait returned")
    }

    /// M13: the runner itself refuses a sandboxed turn whose cwd became a link after the scope was computed.
    @Test func runnerRefusesALinkedCwdBeforeSpawn() async throws {
        let w = try SandboxedRequestWorld()
        let lab = try #require(w.request.sandbox?.cwd)
        try FileManager.default.removeItem(at: lab)
        try FileManager.default.createSymbolicLink(atPath: lab.path, withDestinationPath: w.dir.path)
        let runner = shRunner("cat > /dev/null; echo '\(initLine)'; echo '\(resultLine)'")
        await #expect(throws: SandboxError.self) { _ = try await collect(runner.run(w.request)) }
    }

    /// Carry-over: a grant read path dropped at spawn (a link put where the approved directory was) is reported to the engine,
    /// which logs it.
    @Test func grantDroppedAtSpawnIsReported() async throws {
        let w = try SandboxedRequestWorld()
        let grant = w.dir.appending(path: "granted")
        try FileManager.default.createDirectory(at: grant, withIntermediateDirectories: true)
        var r = w.request
        r.sandbox?.readOnlyDirs.append(grant); r.sandbox?.readable.append(grant); r.sandbox?.grantReadDirs.append(grant)
        r.addDirs.append(grant.path)
        try FileManager.default.removeItem(at: grant)
        try FileManager.default.createSymbolicLink(atPath: grant.path, withDestinationPath: w.home.path)
        let runner = shRunner("cat > /dev/null; echo '\(initLine)'; echo '\(resultLine)'")
        let events = try await collect(runner.run(r))
        #expect(events.contains { if case .sandboxNote(let text) = $0 { text.contains(grant.path) } else { false } })
    }

    /// A child left in the turn's own process group after `claude` exits (the plain `cmd &` case).
    @Test func plainBackgroundChildIsKilled() async throws {
        let dir = try tempDir()
        let pidFile = dir.appending(path: "child.pid")
        let runner = shRunner("""
            cat > /dev/null
            /bin/sleep 300 > /dev/null 2>&1 &
            echo $! > '\(pidFile.path)'
            echo '\(initLine)'
            echo '\(resultLine)'
            """)
        _ = try await collect(runner.run(request(in: dir)))
        let child = try await pid(in: pidFile)
        #expect(await gone(child))
    }

    /// The turn's process is its own session leader (and group leader), and every child sees the turn's marker.
    @Test func turnRunsInItsOwnSessionWithAMarker() async throws {
        let dir = try tempDir()
        let out = dir.appending(path: "ids.txt")
        let runner = shRunner("""
            cat > /dev/null
            echo "$$ $(/bin/ps -o pgid= -p $$) ${BRAHMA_TURN_MARK:-none}" > '\(out.path)'
            /bin/sleep 1
            echo '\(initLine)'
            echo '\(resultLine)'
            """)
        let turn = Task { try await collect(runner.run(request(in: dir))) }
        for _ in 0..<200 where !FileManager.default.fileExists(atPath: out.path) { try await Task.sleep(for: .milliseconds(10)) }
        try await Task.sleep(for: .milliseconds(50))
        let parts = try String(contentsOf: out, encoding: .utf8).split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        let leader = try #require(pid_t(parts[0]))
        #expect(getsid(leader) == leader, "its own session")
        _ = try await turn.value
        #expect(parts.count == 3)
        #expect(parts[0] == parts[1], "its own process group")
        #expect(parts[2] != "none" && parts[2].count >= 32, "a per-turn marker")
        #expect(getpgid(getpid()) != pid_t(parts[1]), "not the engine's group")
    }

    /// The next turn of the same agent waits for the previous one's processes to be gone.
    @Test func nextTurnWaitsForTheSweep() async throws {
        let dir = try tempDir()
        let runner = shRunner("""
            cat > /dev/null
            echo '\(initLine)'
            echo '\(resultLine)'
            """)
        let id = "n-" + UUID().uuidString.prefix(8).lowercased()
        _ = try await collect(runner.run(request(in: dir, agentId: id)))
        #expect(try await runner.waitForTurnProcesses(agentId: id, records: dir.appending(path: "turns")).survivors.isEmpty)
        #expect(try await runner.waitForTurnProcesses(agentId: "nobody", records: dir.appending(path: "turns")).survivors.isEmpty)
    }

    @Test func processTableReadsAChildsEnvironment() async throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/bin/sleep")
        p.arguments = ["5"]
        p.environment = ["PATH": "/usr/bin:/bin", "BRAHMA_TURN_MARK": "abc123"]
        try p.run()
        defer { p.terminate() }
        try await Task.sleep(for: .milliseconds(100))
        // Linux shows another process's environment; macOS no longer does (the marker is then only a Linux channel).
        #if os(Linux)
        let env = try #require(ProcessTable.environment(p.processIdentifier))
        #expect(env.contains("BRAHMA_TURN_MARK=abc123"), "\(env)")
        #else
        #expect(!(ProcessTable.environment(p.processIdentifier) ?? []).contains("BRAHMA_TURN_MARK=abc123"))
        #endif
        let e = try #require(ProcessTable.entry(p.processIdentifier))
        #expect(e.ppid == getpid()); #expect(e.start >= ProcessTable.startStamp(slack: 30))
    }

    @Test func processTableSeesThisProcess() throws {
        let me = try #require(ProcessTable.entry(getpid()))
        #expect(me.pid == getpid()); #expect(me.ppid == getppid()); #expect(me.uid == getuid())
        #expect(ProcessTable.snapshot().contains { $0.pid == getpid() })
        #expect(ProcessTable.entry(-5) == nil)
    }
}
