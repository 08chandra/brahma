import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import BrahmaCore

/// One start of a web preview (`WebAdapter.startServer`): build, spawn, readiness, the loopback check. FakeSandbox (real
/// processes in their own group, unsandboxed) and fake probes; one test runs a real server under the real Seatbelt runner.
@Suite(.scratch) struct WebAdapterTests {
    static let policy = SandboxPolicy(writable: [URL(fileURLWithPath: "/nowhere")], readable: [], network: .none, toolchain: false)

    struct Setup {
        let dir: URL
        let context: PreviewContext
        let sandbox: FakeSandbox
        let http: FakeHTTPProbe
        let listen: FakeListenProbe
        let deps: PreviewDependencies
    }

    static func setup(build: String? = nil, run: String = "sleep 300", http: FakeHTTPProbe = FakeHTTPProbe([FakeHTTPProbe.ok()]),
                      listen: [String] = ["127.0.0.1"], timeouts: PreviewTimeouts = PreviewTimeouts(ready: .seconds(20), poll: .milliseconds(50)),
                      port: Int = 47100) throws -> Setup {
        let dir = try tempDir()
        let runDir = dir.appending(path: "run", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        let layout = EngineLayout(workspace: dir.appending(path: "ws", directoryHint: .isDirectory))
        let now = Date()
        let surface = PreviewSurface(id: "s1", companyId: "c1", name: "web", position: 0, build: build, run: run,
                                     url: "http://127.0.0.1:{port}/", setById: "owner", createdAt: now, updatedAt: now)
        let company = Company(id: "c1", name: "Acme", slug: "acme", goal: "g", workspacePath: layout.workspace.path, status: .running,
                              usageMode: .low, priorityWeight: 1, createdAt: now)
        let context = PreviewContext(surface: surface, company: company, layout: layout, run: runDir, commit: String(repeating: "a", count: 40),
                                     port: port, policy: policy, environment: ["PATH": "/bin:/usr/bin"],
                                     logURL: layout.previewLog(name: "web"), timeouts: timeouts)
        let sandbox = FakeSandbox()
        let probe = FakeListenProbe(listen)
        return Setup(dir: dir, context: context, sandbox: sandbox, http: http, listen: probe,
                     deps: .fake(sandbox: sandbox, http: http, listen: probe))
    }

    /// Whether any process is left in group `pgid` (`kill(-pgid, 0)`).
    static func groupAlive(_ pgid: Int32) -> Bool { kill(-pgid, 0) == 0 }

    static func waitGone(_ pgid: Int32) async -> Bool {
        let deadline = AwakeTime.deadline(after: .seconds(15))
        while AwakeTime.now < deadline {
            if !groupAlive(pgid) { return true }
            try? await AwakeTime.sleep(for: .milliseconds(50))
        }
        return !groupAlive(pgid)
    }

    @Test func becomesRunningWhenReachable() async throws {
        let s = try Self.setup(http: FakeHTTPProbe([FakeHTTPProbe.refused, FakeHTTPProbe.refused, FakeHTTPProbe.ok()]))
        let update = await WebAdapter.startServer(s.context, deps: s.deps)
        #expect(update.status == .running, "\(update)")
        #expect(update.resolvedURL == "http://127.0.0.1:47100/")
        #expect(s.http.requests.count == 3 && s.http.requests.allSatisfy { $0.method == "GET" && $0.url.absoluteString == "http://127.0.0.1:47100/" })
        #expect(s.listen.ports.contains(47100))
        let calls = s.sandbox.calls
        #expect(calls.map(\.kind) == [.spawn])
        #expect(calls[0].policy == s.context.policy && calls[0].cwd == s.context.run && calls[0].output == s.context.logURL)
        let pid = try #require(update.process)
        #expect(s.deps.processes.process(pid) != nil)
        await s.deps.processes.process(pid)?.terminate(grace: .seconds(2))
        s.deps.processes.remove(pid)
    }

    @Test func portIsSubstitutedInRun() async throws {
        let s = try Self.setup(run: "exec sleep 300 # {port}")
        let update = await WebAdapter.startServer(s.context, deps: s.deps)
        #expect(update.status == .running)
        #expect(s.sandbox.calls.first?.command == "exec sleep 300 # 47100")
        if let pid = update.process { await s.deps.processes.process(pid)?.terminate(grace: .seconds(2)); s.deps.processes.remove(pid) }
    }

    @Test func nonLoopbackBindRefused() async throws {
        let s = try Self.setup(listen: ["*"])
        let update = await WebAdapter.startServer(s.context, deps: s.deps)
        #expect(update == PreviewUpdate(status: .failed, message: "listens on *; bind to 127.0.0.1 (the engine sets HOST and PORT)"))
        #expect(s.sandbox.calls.map(\.kind) == [.spawn])
        #expect(s.deps.processes.count == 0, "the failed start left no process in the table")
        #expect(await Self.waitGone(s.lastSpawnPid()), "the group is gone")
    }

    /// Deferred minor 3: an answering URL with no listen address known is "could not tell", which fails closed.
    @Test func unknownListenAddressFailsClosed() async throws {
        let s = try Self.setup(listen: [])
        let update = await WebAdapter.startServer(s.context, deps: s.deps)
        #expect(update == PreviewUpdate(status: .failed, message: "could not tell where it listens on port 47100; bind to 127.0.0.1 (the engine sets HOST and PORT)"))
        #expect(s.listen.ports.count == WebAdapter.listenProbes)
        #expect(await Self.waitGone(s.lastSpawnPid()))
    }

    @Test func startTimesOut() async throws {
        let s = try Self.setup(http: FakeHTTPProbe(), timeouts: PreviewTimeouts(ready: .seconds(1), poll: .milliseconds(100)))
        let update = await WebAdapter.startServer(s.context, deps: s.deps)
        #expect(update == PreviewUpdate(status: .failed, message: "not reachable at http://127.0.0.1:47100/ after 1 s"))
        #expect(s.deps.processes.count == 0)
        #expect(await Self.waitGone(s.lastSpawnPid()))
    }

    @Test func exitDuringStart() async throws {
        let s = try Self.setup(run: "exit 7", http: FakeHTTPProbe())
        let update = await WebAdapter.startServer(s.context, deps: s.deps)
        #expect(update == PreviewUpdate(status: .failed, message: "exited during start (exit 7)"))
        #expect(s.deps.processes.count == 0)
    }

    @Test func buildFailureStops() async throws {
        let s = try Self.setup(build: "echo building; exit 2")
        let update = await WebAdapter.startServer(s.context, deps: s.deps)
        #expect(update == PreviewUpdate(status: .failed, message: "build failed (exit 2)"))
        #expect(s.sandbox.calls.map(\.kind) == [.run], "run never spawned")
        let build = s.sandbox.calls[0]
        #expect(build.command == "echo building; exit 2" && build.cwd == s.context.run && build.policy == s.context.policy)
        #expect(build.output == s.context.logURL)
    }

    @Test func buildTimesOut() async throws {
        var timeouts = PreviewTimeouts(ready: .seconds(5), poll: .milliseconds(50))
        timeouts.build = .seconds(1)
        let s = try Self.setup(build: "sleep 300", timeouts: timeouts)
        let update = await WebAdapter.startServer(s.context, deps: s.deps)
        #expect(update == PreviewUpdate(status: .failed, message: "build timed out"))
        #expect(s.sandbox.calls.map(\.kind) == [.run])
    }

    @Test func sandboxUnavailable() async throws {
        let s = try Self.setup()
        s.sandbox.spawnError = SandboxError.unavailable
        let update = await WebAdapter.startServer(s.context, deps: s.deps)
        #expect(update == PreviewUpdate(status: .unavailable, message: "sandbox unavailable on this platform"))
    }

    /// Deferred minor 2: a port something listens on over IPv6 only (`[::1]:P`) is not free.
    @Test func ipv6ListenerMakesPortBusy() throws {
        let fd = socket(AF_INET6, Int32(SOCK_STREAM), 0)
        try #require(fd >= 0)
        defer { close(fd) }
        var one: Int32 = 1
        setsockopt(fd, IPPROTO_IPV6, IPV6_V6ONLY, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in6()
        addr.sin6_family = sa_family_t(AF_INET6)
        addr.sin6_addr = in6addr_loopback
        addr.sin6_port = 0
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size)) } }
        try #require(bound == 0)
        #expect(listen(fd, 1) == 0)
        var got = sockaddr_in6()
        var len = socklen_t(MemoryLayout<sockaddr_in6>.size)
        _ = withUnsafeMutablePointer(to: &got) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        let port = Int(UInt16(bigEndian: got.sin6_port))
        #expect(!PortAllocator.isFree(port), "a [::1] listener on \(port) is seen")
    }

    /// A real server under 5-lite's real Seatbelt runner, the real preview policy and the real probes (PR-13).
    @Test(.enabled(if: Toolchain.seatbeltAvailable && FileManager.default.isExecutableFile(atPath: "/usr/bin/python3"), "no sandbox-exec or python3"))
    func realServerIfPythonAvailable() async throws {
        let home = try Scratch.homeDir().resolvedForSandbox
        defer { try? FileManager.default.removeItem(at: home) }
        let run = home.appending(path: "run", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        try "hello from the preview".write(to: run.appending(path: "index.html"), atomically: true, encoding: .utf8)
        let ws = home.appending(path: "ws", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: ws, withIntermediateDirectories: true)
        let layout = EngineLayout(workspace: ws)
        try EngineFiles.directory(workspace: ws, ".brahma/preview/logs")
        let port = try PortAllocator.allocate(excluding: [])
        let now = Date()
        let company = Company(id: "c1", name: "Acme", slug: "acme", goal: "g", workspacePath: ws.path, status: .running,
                              usageMode: .low, priorityWeight: 1, createdAt: now)
        let surface = PreviewSurface(id: "s1", companyId: "c1", name: "web", position: 0, build: nil,
                                     run: "python3 -m http.server {port} --bind 127.0.0.1", url: "http://127.0.0.1:{port}/",
                                     setById: "owner", createdAt: now, updatedAt: now)
        let policy = PreviewPolicy.server(layout, run: run, company: company, port: port)
        let realHome = FileManager.default.homeDirectoryForCurrentUser.resolvedForSandbox  // raw-temp-api: read-only, the home the policy denies
        let baseline = SandboxBaseline.current(paths: BrahmaPaths(home: realHome.appending(path: "Library/Application Support/Brahma"),
                                                                  workspaces: realHome.appending(path: "Brahma")),
                                               otherWorkspaces: [], backupTargets: [])
        let sandbox = SandboxRunners.platformDefault(baseline: { baseline }, proxies: EgressProxyPool())
        let deps = PreviewDependencies.live(sandbox: sandbox)
        let env = PreviewContext.environment(base: ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "LANG": "en_US.UTF-8"], port: port)
        let context = PreviewContext(surface: surface, company: company, layout: layout, run: run, commit: String(repeating: "a", count: 40),
                                     port: port, policy: policy, environment: env, logURL: layout.previewLog(name: "web"),
                                     timeouts: PreviewTimeouts(ready: .seconds(60), poll: .milliseconds(250)))
        let update = await WebAdapter.startServer(context, deps: deps)
        #expect(update.status == .running, "\(update) log: \(PreviewLog.tail(layout, name: "web", lines: 20))")
        #expect(update.resolvedURL == "http://127.0.0.1:\(port)/")
        // A second bind, on another port, inside the same policy fails.
        let out = home.appending(path: "second.log")
        let second = await sandbox.run(command: "python3 -c 'import socket; s=socket.socket(); s.bind((\"127.0.0.1\", \(port + 1))); s.listen(1); print(\"bound\")'",
                                       cwd: run, environment: env, timeout: .seconds(60), outputURL: out, policy: policy)
        #expect(second.exitCode != 0, "\(second)")
        if let pid = update.process, let p = deps.processes.process(pid) {
            await p.terminate(grace: .seconds(5))
            deps.processes.remove(pid)
            #expect(await Self.waitGone(pid))
        }
    }
}

extension WebAdapterTests.Setup {
    /// The pid of the last spawn (the group FakeSandbox started), from the fake's own record of processes it ran.
    func lastSpawnPid() -> Int32 { sandbox.lastSpawnedPid ?? -1 }
}
