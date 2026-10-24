import Testing
import Foundation
@testable import BrahmaCore

/// The turn's process lifetime (Task 1a re-review, binding on 1b): no process of a turn outlives it. The fake `claude` is
/// `/bin/sh -c <script>` (a system binary, so it runs while new executables stall), started the way every turn is: its own
/// session, swept when the turn ends.
private func request(in dir: URL, agentId: String = "a1") -> TurnRequest {
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
    var runner = ClaudeProcessRunner(claudePath: "/bin/sh", baseEnvironment: ["PATH": "/usr/bin:/bin", "HOME": NSTemporaryDirectory()])
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
        var r = Self.base(dir, agentId: "a1", name: "eng-1")
        r.profile = .sandboxed
        r.sandbox = scope
        r.shellPrefix = ws.appending(path: ".brahma/bin/shell-eng-1.sh").path
        r.settingsFilePath = dir.appending(path: "a1.settings.json").path
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

@Suite(.serialized) struct TurnContainmentTests {
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
    /// removed. On a sandboxed turn its sandbox (which it cannot drop) still gives it away. The fake CLI starts it under a
    /// Seatbelt profile shaped like an agent's turn (writes to the agent's home, not the workspace top).
    @Test func doubleForkedSandboxedEscapeeIsFoundByItsSandbox() async throws {
        let w = try SandboxedRequestWorld()
        let pidFile = w.home.appending(path: "escapee.pid")
        let profile = "(version 1)(allow default)(deny file-write*)(allow file-write* (subpath \\\"\(w.home.path)\\\"))"
        var runner = shRunner("""
            cat > /dev/null
            /usr/bin/sandbox-exec -p "\(profile)" /usr/bin/env -u BRAHMA_TURN_MARK \(perl) -e 'use POSIX; exit 0 if fork; POSIX::setsid(); exit 0 if fork; open(F, ">", $ARGV[0]); print F "$$\\n"; close F; close STDOUT; close STDERR; exec "/bin/sleep", "300"' '\(pidFile.path)'
            while [ ! -s '\(pidFile.path)' ]; do sleep 0.05; done
            echo '\(initLine)'
            echo '\(resultLine)'
            """)
        runner.baseEnvironment["PATH"] = "/usr/bin:/bin"
        _ = try await collect(runner.run(w.request))
        let escapee = try await pid(in: pidFile)
        #expect(await gone(escapee), "a double-forked, sandboxed process outlived its turn")
    }

    @Test func sandboxProbeMatchesOnlyAnAgentShapedSandbox() async throws {
        let w = try SandboxedRequestWorld()
        func start(_ args: [String]) throws -> Process {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: args[0]); p.arguments = Array(args.dropFirst())
            p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
            try p.run()
            return p
        }
        let agentShaped = try start(["/usr/bin/sandbox-exec", "-p",
                                     "(version 1)(allow default)(deny file-write*)(allow file-write* (subpath \"\(w.home.path)\"))",
                                     "/bin/sleep", "30"])
        let workspaceWide = try start(["/usr/bin/sandbox-exec", "-p",
                                       "(version 1)(allow default)(deny file-write*)(allow file-write* (subpath \"\(w.ws.path)\"))",
                                       "/bin/sleep", "30"])
        let otherAgent = try start(["/usr/bin/sandbox-exec", "-p",
                                    "(version 1)(allow default)(deny file-write*)(allow file-write* (subpath \"\(w.ws.path)/.brahma/home/eng-2\"))",
                                    "/bin/sleep", "30"])
        let plain = try start(["/bin/sleep", "30"])
        defer { for p in [agentShaped, workspaceWide, otherAgent, plain] { p.terminate() } }
        try await Task.sleep(for: .milliseconds(300))
        let probe = SandboxProbe(workspace: w.ws, handle: "eng-1")
        #expect(probe.matches(agentShaped.processIdentifier))
        #expect(!probe.matches(workspaceWide.processIdentifier), "an owner's tool sandboxed to the whole workspace")
        #expect(!probe.matches(otherAgent.processIdentifier), "another agent's turn")
        #expect(!probe.matches(plain.processIdentifier), "not sandboxed")
        #expect(!probe.matches(getpid()))
        let found = probe.scan(ProcessTable.snapshot()).map(\.pid)
        #expect(found.contains(agentShaped.processIdentifier))
        #expect(!found.contains(plain.processIdentifier))
        // The registry finds such a leftover before the agent's next turn (and kills it).
        let registry = TurnRegistry()
        registry.begin("eng", probe: probe)
        registry.end("eng", survivors: [])
        #expect(await registry.waitUntilGone("eng").isEmpty)
        #expect(await gone(agentShaped.processIdentifier))
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

    /// The turn's process is its own session leader, and every child sees the turn's marker.
    @Test func turnRunsInItsOwnSessionWithAMarker() async throws {
        let dir = try tempDir()
        let out = dir.appending(path: "ids.txt")
        let runner = shRunner("""
            cat > /dev/null
            echo "$$ $(/bin/ps -o pgid= -p $$) ${BRAHMA_TURN_MARK:-none}" > '\(out.path)'
            echo '\(initLine)'
            echo '\(resultLine)'
            """)
        _ = try await collect(runner.run(request(in: dir)))
        let parts = try String(contentsOf: out, encoding: .utf8).split(separator: " ").map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        #expect(parts.count == 3)
        #expect(parts[0] == parts[1], "its own process group (and session: it is the leader of both)")
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
        _ = try await collect(runner.run(request(in: dir)))
        #expect(await runner.waitForTurnProcesses(agentId: "a1").isEmpty)
        #expect(await runner.waitForTurnProcesses(agentId: "nobody").isEmpty)
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
