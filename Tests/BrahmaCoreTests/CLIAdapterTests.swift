import Testing
import Foundation
@testable import BrahmaCore

/// A CLI preview (Plan 4a Task 5): the optional build, then the demo, each run to completion through the sandbox runner in the
/// fresh export; the engine captures the demo's output (redacted, capped at 1 MB) and the result is `ran`. FakeSandbox runs
/// real commands (unsandboxed, the policy recorded).
@Suite(.scratch) struct CLIAdapterTests {
    static let policy = ValidatedPolicy.fixture(writable: [URL(fileURLWithPath: "/nowhere")])

    struct Setup {
        let dir: URL
        let context: PreviewContext
        let sandbox: FakeSandbox
        let deps: PreviewDependencies
        let redactor: Redactor
        var adapter: CLIAdapter { CLIAdapter(deps: deps) }
    }

    /// A loaded redactor holding `secrets`.
    static func redactor(_ secrets: [(name: String, value: String)] = []) -> Redactor {
        let r = Redactor()
        r.update(secrets, version: "v1")
        return r
    }

    static func setup(build: String? = nil, demo: String = "echo hello", timeouts: PreviewTimeouts = PreviewTimeouts(),
                      redactor: Redactor? = CLIAdapterTests.redactor()) throws -> Setup {
        let dir = try tempDir()
        let runDir = dir.appending(path: "run", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        try "readme".write(to: runDir.appending(path: "README.md"), atomically: true, encoding: .utf8)
        let layout = EngineLayout(workspace: dir.appending(path: "ws", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: layout.workspace, withIntermediateDirectories: true)
        _ = try EngineFiles.directory(workspace: layout.workspace, ".brahma/preview/logs")
        let now = Date()
        let surface = PreviewSurface(id: "s1", companyId: "c1", name: "tool", kind: "cli", position: 0, build: build, run: nil, url: nil,
                                     setById: "owner", createdAt: now, updatedAt: now, demo: demo)
        let company = Company(id: "c1", name: "Acme", slug: "acme", goal: "g", workspacePath: layout.workspace.path, status: .running,
                              usageMode: .low, priorityWeight: 1, createdAt: now)
        let context = PreviewContext(surface: surface, company: company, layout: layout, run: runDir, commit: String(repeating: "a", count: 40),
                                     port: 0, policy: policy, environment: ["PATH": "/bin:/usr/bin"],
                                     logURL: layout.previewLog(name: "tool"), timeouts: timeouts, redactor: redactor)
        let sandbox = FakeSandbox()
        let r = redactor ?? Self.redactor()
        return Setup(dir: dir, context: context, sandbox: sandbox, deps: .fake(sandbox: sandbox), redactor: r)
    }

    static func text(_ url: URL) -> String? { (try? Data(contentsOf: url)).map { String(decoding: $0, as: UTF8.self) } }

    @Test func demoOutputCaptured() async throws {
        let s = try Self.setup(build: "echo built > built.txt; echo building", demo: "pwd; ls -a; cat built.txt")
        let update = await s.adapter.start(s.context)
        #expect(update.status == .ran && update.message == "exit 0" && update.process == nil, "\(update)")
        #expect(update.outputPath == s.context.outputURL.path)
        // Both commands ran through the sandbox runner, in the run, under the context's policy; the build's output went to
        // the log, the demo's to the output file.
        let calls = s.sandbox.calls
        #expect(calls.map(\.kind) == [.run, .run])
        #expect(calls.map(\.command) == ["echo built > built.txt; echo building", "pwd; ls -a; cat built.txt"])
        #expect(calls.allSatisfy { $0.cwd == s.context.run && $0.policy == s.context.policy })
        #expect(calls.map(\.output) == [s.context.logURL, s.context.outputURL])
        let out = try #require(Self.text(s.context.outputURL))
        let lines = out.split(separator: "\n").map(String.init)
        #expect(lines.first == s.context.run.resolvedForSandbox.path || lines.first == s.context.run.path, "\(out)")
        #expect(lines.contains("README.md") && lines.contains("built"))
        #expect(!lines.contains(".git"))
        #expect(!FileManager.default.fileExists(atPath: s.context.run.appending(path: ".git").path))
        #expect(Self.text(s.context.logURL)?.contains("building") == true)
        // The demo re-runs it (not the build): exit and line count.
        let demo = await s.adapter.demo(s.context, state: PreviewState(surfaceId: "s1", companyId: "c1", status: .ran, updatedAt: Date()))
        #expect(demo.ok && demo.line == "tool: demo exit 0, \(lines.count) lines", "\(demo)")
        #expect(demo.outputPath == s.context.outputURL.path)
        #expect(s.sandbox.calls.map(\.command).last == "pwd; ls -a; cat built.txt" && s.sandbox.calls.count == 3)
    }

    @Test func demoFailureIsRanNotCrash() async throws {
        let s = try Self.setup(demo: "echo oops; exit 3")
        let update = await s.adapter.start(s.context)
        #expect(update.status == .ran && update.message == "exit 3" && update.process == nil, "\(update)")
        #expect(Self.text(s.context.outputURL) == "oops\n")
        let demo = await s.adapter.demo(s.context, state: PreviewState(surfaceId: "s1", companyId: "c1", status: .ran, updatedAt: Date()))
        #expect(!demo.ok && demo.line == "tool: demo exit 3, 1 lines", "\(demo)")
        // A failing build is a failed start; the demo never runs.
        let b = try Self.setup(build: "exit 2", demo: "echo never")
        let built = await b.adapter.start(b.context)
        #expect(built.status == .failed && built.message == "build failed (exit 2)", "\(built)")
        #expect(b.sandbox.calls.map(\.command) == ["exit 2"])
        // No sandbox on this platform: unavailable, nothing ran.
        var u = try Self.setup()
        u = Setup(dir: u.dir, context: u.context, sandbox: u.sandbox,
                  deps: PreviewDependencies(sandbox: UnavailableSandboxRunner(), http: FakeHTTPProbe(), listen: FakeListenProbe(),
                                            processes: SpawnedProcesses()), redactor: u.redactor)
        let off = await u.adapter.start(u.context)
        #expect(off.status == .unavailable && off.message == UnavailableSandboxRunner.tail, "\(off)")
    }

    @Test func demoTimeout() async throws {
        let s = try Self.setup(demo: "echo started; sleep 60", timeouts: PreviewTimeouts(demo: .seconds(1)))
        let began = Date()
        let update = await s.adapter.start(s.context)
        #expect(update.status == .ran && update.message == "timed out after 1 s", "\(update)")
        #expect(Date().timeIntervalSince(began) < 30)
        #expect(Self.text(s.context.outputURL)?.hasPrefix("started") == true)
        let demo = await s.adapter.demo(s.context, state: PreviewState(surfaceId: "s1", companyId: "c1", status: .ran, updatedAt: Date()))
        #expect(!demo.ok && demo.line == "tool: demo timed out after 1 s", "\(demo)")
    }

    @Test func outputIsRedacted() async throws {
        let secret = "sk-live-0123456789abcdef"
        let s = try Self.setup(demo: "echo token=\(secret)", redactor: Self.redactor([(name: "API_KEY", value: secret)]))
        let update = await s.adapter.start(s.context)
        #expect(update.status == .ran && update.outputPath == s.context.outputURL.path, "\(update)")
        let out = try #require(Self.text(s.context.outputURL))
        #expect(!out.contains(secret) && out.contains("[redacted API_KEY]"), "\(out)")
        // The build log is scrubbed too.
        let b = try Self.setup(build: "echo \(secret)", demo: "true", redactor: Self.redactor([(name: "API_KEY", value: secret)]))
        _ = await b.adapter.start(b.context)
        #expect(Self.text(b.context.logURL)?.contains(secret) == false)
        // Capped at 1 MB.
        let big = try Self.setup(demo: "head -c 3000000 /dev/zero | tr '\\0' 'x'")
        let capped = await big.adapter.start(big.context)
        #expect(capped.status == .ran && capped.message == "exit 0", "\(capped)")
        let size = try #require(try FileManager.default.attributesOfItem(atPath: big.context.outputURL.path)[.size] as? Int)
        #expect(size <= CLIAdapter.outputCap && size > 1_000_000, "\(size)")
        #expect(CLIAdapter.outputCap == 1_048_576)
        // A redactor that has not loaded cannot scrub: the output is withheld (removed), never left raw.
        let held = try Self.setup(demo: "echo \(secret)", redactor: Redactor())
        let withheld = await held.adapter.start(held.context)
        #expect(withheld.status == .ran && withheld.message == "exit 0" && withheld.outputPath == nil, "\(withheld)")
        #expect(!FileManager.default.fileExists(atPath: held.context.outputURL.path))
        // No redactor at all: the same.
        let none = try Self.setup(demo: "echo \(secret)", redactor: nil)
        let noneUpdate = await none.adapter.start(none.context)
        #expect(noneUpdate.outputPath == nil && !FileManager.default.fileExists(atPath: none.context.outputURL.path))
    }

    /// Through the engine: the default adapter table runs a CLI surface in a fresh export of `main`; the result is terminal
    /// until `main` moves, then the demo runs again on the new head.
    @Test func rerunWhenMainMoves() async throws {
        let root = try tempDir()
        let data = root.appending(path: "data", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
        let store = try Store(path: data.appending(path: "brahma.sqlite").path)
        let sandbox = FakeSandbox()
        let deps = PreviewDependencies.fake(sandbox: sandbox)
        let w = try World(store: store, previewDeps: deps)
        let company = try w.company("Acme")
        let devops = try w.hire(company, "devops")
        let f = GitFixture(existing: URL(fileURLWithPath: company.workspacePath, isDirectory: true))
        func merge(_ text: String) throws {
            try f.write("README.md", text)
            try f.git(["add", "-A"]); try f.git(["commit", "-q", "-m", "change"])
            _ = try store.acceptMainCommit(companyId: company.id)
        }
        try merge("one")
        let paths = w.paths
        let runner = PreviewRunner(store: store, paths: paths, deps: deps,
                                   sandboxLayout: { SandboxLayout(paths: paths, company: $0, agentHandle: "preview") },
                                   timeouts: PreviewTimeouts(ready: .seconds(600), poll: .milliseconds(50)), memory: { false },
                                   clock: w.clock.function)
        let tools = CompanyTools(store: store, companyId: company.id, agentId: devops.id)
        _ = try tools.call(name: "set_preview_command", arguments: ["name": .string("tool"), "kind": .string("cli"),
                                                                   "demo": .string("cat README.md; ls -a")])
        let lag = Date().timeIntervalSince(w.clock.now); if lag > -1 { w.clock.advance(lag + 1) }
        func settle() async { for _ in 0..<6 { await runner.reconcile(now: w.clock.now); await runner.waitForStarts() } }
        func state() throws -> PreviewState { try #require(try store.previewStates(companyId: company.id).values.first) }
        await settle()
        var s = try state()
        #expect(s.status == .ran && s.message == "exit 0" && s.pid == nil, "\(s)")
        let first = try #require(s.outputPath)
        #expect(Self.text(URL(fileURLWithPath: first))?.hasPrefix("one") == true)
        #expect(Self.text(URL(fileURLWithPath: first))?.contains(".git") == false)
        let runs = sandbox.calls.filter { $0.kind == .run }
        #expect(runs.count == 1)
        #expect(runs.first?.policy.writable == [try #require(runs.first?.cwd).resolvedForSandbox])
        // Terminal while nothing changes.
        w.clock.advance(3600)
        await settle()
        #expect(sandbox.calls.filter { $0.kind == .run }.count == 1)
        // A new main: after the debounce, it runs again on the new head, in a new export.
        try merge("two")
        await settle()
        w.clock.advance(PreviewRunner.debounce + 1)
        await settle()
        let again = sandbox.calls.filter { $0.kind == .run }
        #expect(again.count == 2 && again[0].cwd != again[1].cwd)
        s = try state()
        let head = try store.company(id: company.id)?.mainCommit
        #expect(s.status == .ran && s.commit == head, "\(s)")
        #expect(Self.text(URL(fileURLWithPath: try #require(s.outputPath)))?.hasPrefix("two") == true)
        await runner.stopAll()
    }
}
