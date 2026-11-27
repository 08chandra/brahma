import Testing
import Foundation
@testable import BrahmaCore

// Plan X1 Task 3: the Claude adapter behind the runtime seam. Its compile is proven byte-identical by `ClaudeParityGoldenTests`
// (which now compiles through `ClaudeRuntime.compile`); these tests pin the rest of the adapter: its parser is today's parser,
// the runner launches only through the catalog (an unknown runtime fails closed and spawns nothing), and the canary's turn is
// built through `canaryShape(for:)` with today's shape key.

/// Counts the runner's spawns (the fake `Spawn` seam of Ruling 28); each one fails, so no process ever starts.
private final class SpawnCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var n = 0
    var count: Int { lock.withLock { n } }
    func spawn() throws -> TurnChild {
        lock.withLock { n += 1 }
        throw CocoaError(.featureUnsupported)
    }
}

private func workspaceRequest(in dir: URL) -> TurnRequest {
    let agent = Agent(id: "rt-\(UUID().uuidString)", companyId: "c1", name: "ceo", role: "ceo", model: "sonnet", sessionId: "s1",
                      sessionStarted: false, state: .running, blocker: nil, requestedBlocker: nil, paused: false,
                      readySince: nil, createdAt: Date(timeIntervalSince1970: 0))
    let company = Company(id: "c1", name: "Acme", slug: "acme", goal: "g", workspacePath: dir.path, status: .running,
                          usageMode: .low, priorityWeight: 1, createdAt: Date(timeIntervalSince1970: 0))
    return TurnRequest(agent: agent, company: company, prompt: "P", appendSystemPrompt: "ROLE",
                       mcpConfigPath: "/tmp/x.mcp.json", workingDirectory: dir.path, profile: .workspace)
}

/// Every `stream-*.jsonl` fixture in the test bundle, by name.
private func streamFixtures() throws -> [(name: String, lines: [String])] {
    let dir = try #require(Bundle.module.url(forResource: "Fixtures", withExtension: nil))
    let names = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        .filter { $0.hasPrefix("stream-") && $0.hasSuffix(".jsonl") }.sorted()
    return try names.map { name in
        let text = try String(contentsOf: dir.appending(path: name), encoding: .utf8)
        return (name, text.split(separator: "\n", omittingEmptySubsequences: true).map(String.init))
    }
}

@Suite(.scratch) struct ClaudeRuntimeTests {
    @Test func identityAndSignals() throws {
        let runtime = ClaudeRuntime()
        #expect(runtime.id == RuntimeCatalog.claude)
        #expect(runtime.taintSignal == .syncHook)
        #expect(runtime.usageSignal(for: .subscription) == .rateLimitEvents)
        #expect(runtime.usageSignal(for: .gateway) == .proxyMetered)
        // The catalog registers it, and only it.
        let registered = try #require(RuntimeCatalog.runtime(RuntimeCatalog.claude))
        #expect(registered.id == RuntimeCatalog.claude)
        #expect(RuntimeCatalog.all.map(\.id) == [RuntimeCatalog.claude])
    }

    /// Every fixture line parses to the same events through the adapter's parser as through `StreamParser.parseAll` (a line
    /// that is not JSON: no events).
    @Test func parserMatchesStreamParser() throws {
        let fixtures = try streamFixtures()
        #expect(fixtures.count >= 9, "\(fixtures.map(\.name))")
        let now = Date(timeIntervalSince1970: 1_800_000_000)
        var parser = try #require(RuntimeCatalog.runtime(RuntimeCatalog.claude)).parser()
        var lines = 0
        for (name, fixture) in fixtures {
            for line in fixture + ["not json", ""] {
                lines += 1
                let expected = StreamParser.parseAll(line: line, now: now) ?? []
                #expect(parser.parse(line: line, now: now) == expected, "\(name): \(line.prefix(120))")
            }
        }
        #expect(lines > 40)
        var direct = ClaudeStreamParser()
        #expect(direct.parse(line: "not json", now: now).isEmpty)
    }

    /// The gates a shape needs are today's `probeGate` rows for its probe shape (`ProbeGates.catalog`): the Task fan-out, Ultra
    /// and the sandboxed plan turn; a plain turn needs none.
    @Test func gatesAreTodaysProbeGates() {
        let runtime = ClaudeRuntime()
        func shape(_ profile: PermissionProfile, _ kind: TurnKind, launch: String?, auth: AuthRoute = .subscription) -> TurnShape {
            TurnShape(profile: profile, kind: kind, mode: nil, launch: launch, settingsShape: "s", auth: auth)
        }
        func ids(_ s: ProbeShape) -> [ProbeGateId] { ProbeGates.catalog(s).map { ProbeGateId(rawValue: $0) } }
        #expect(runtime.gates(for: shape(.sandboxed, .work, launch: "task")) == ids(.sandboxedTask))
        #expect(runtime.gates(for: shape(.sandboxed, .work, launch: "ultra")) == ids(.ultra))
        #expect(runtime.gates(for: shape(.sandboxed, .work, launch: "ultra-small")) == ids(.ultra))
        #expect(runtime.gates(for: shape(.sandboxed, .plan, launch: nil)) == ids(.sandboxedPlan))
        #expect(runtime.gates(for: shape(.sandboxed, .work, launch: "task", auth: .gateway)) == ids(.sandboxedTask))
        #expect(runtime.gates(for: shape(.sandboxed, .work, launch: nil)).isEmpty)
        #expect(runtime.gates(for: shape(.workspace, .plan, launch: nil)).isEmpty)
        #expect(runtime.gates(for: shape(.full, .work, launch: nil)).isEmpty)
        #expect(ProbeGates.catalog(.sandboxedTask).contains("F7-agents") && ProbeGates.catalog(.sandboxedTask).contains("V-1"))
    }

    /// A request the compiler refuses (a model off the allowlist; a sandboxed turn without its sandbox) does not compile: the
    /// refusal's text is today's `TurnProfileError` text.
    @Test func compileFailsClosed() throws {
        var bad = workspaceRequest(in: try tempDir())
        bad.agent.model = "gpt-4"
        #expect(throws: RuntimeCompileError.invalid(TurnProfileError.modelNotAllowed("gpt-4").description)) {
            _ = try ClaudeRuntime().compile(bad, RuntimeProbe(runtime: RuntimeCatalog.claude))
        }
        var unscoped = workspaceRequest(in: try tempDir())
        unscoped.profile = .sandboxed
        do {
            _ = try ClaudeRuntime().compile(unscoped, RuntimeProbe(runtime: RuntimeCatalog.claude))
            Issue.record("a sandboxed turn without its scope compiled")
        } catch {
            #expect("\(error)".hasPrefix("sandbox scope: the sandboxed turn is incomplete"), "\(error)")
        }
    }

    /// The launch a workspace request compiles to: today's argv, the runtime's executable, the request's cwd and prompt, no
    /// sandbox, today's child environment and the inline settings (no settings file).
    @Test func compileIsTodaysLaunch() throws {
        let r = workspaceRequest(in: try tempDir())
        let base = ["PATH": "/usr/bin:/bin", "HOME": "/Users/o", "EDITOR": "vi"]
        let spec = try ClaudeRuntime(executable: "/opt/claude", baseEnvironment: base).compile(r, RuntimeProbe(runtime: RuntimeCatalog.claude))
        let profile = TurnProfileCompiler.profile(for: r)
        #expect(spec.executable == "/opt/claude")
        #expect(spec.arguments == TurnProfileCompiler.arguments(profile))
        #expect(spec.environment == ChildEnvironment.make(base: base, extra: profile.environment, engineClaudeVars: profile.environment,
                                                          purpose: .claude, allowBuiltinAgentsSwitch: profile.builtinAgentsDisabled))
        #expect(spec.workingDirectory == r.workingDirectory)
        #expect(spec.stdin == "P")
        #expect(spec.sandbox == .unsandboxed(.workspace))
        #expect(spec.files.isEmpty)
        #expect(spec.wallClock == nil)
        // The control session (the mode canary's) is the same launch with the input format after `-p`.
        let control = try ClaudeRuntime(executable: "/opt/claude", baseEnvironment: base).compileControl(r, RuntimeProbe(runtime: RuntimeCatalog.claude))
        var expected = spec.arguments
        expected.insert(contentsOf: ["--input-format", "stream-json"], at: 1)
        #expect(control.arguments == expected)
    }

    /// Fail closed at the catalog: a request for a runtime the catalog does not have ends its stream with `TurnError` naming
    /// it, and the runner spawns nothing (the fake spawn counts). The same request on Claude reaches the spawn.
    @Test func runnerUsesCatalog() async throws {
        let dir = try tempDir()
        let counter = SpawnCounter()
        var runner = RuntimeProcessRunner(claudePath: "/usr/bin/false", baseEnvironment: ["PATH": "/usr/bin:/bin"])
        runner.spawn = { _, _, _, _, _, _, _, _, _ in try counter.spawn() }
        var r = workspaceRequest(in: dir)
        let unknown = try JSONDecoder().decode(RuntimeId.self, from: Data(#""no-such-runtime""#.utf8))
        r.runtime = unknown
        var events: [StreamEvent] = []
        do {
            for try await e in runner.run(r) { events.append(e) }
            Issue.record("the stream of an unknown runtime finished")
        } catch let e as TurnError {
            #expect(e == .runtimeUnavailable(unknown))
            #expect(e.description == "runtime no-such-runtime is not available")
        }
        #expect(events.isEmpty)
        #expect(counter.count == 0, "nothing is spawned for an unknown runtime")

        // Positive control: the default runtime (Claude) compiles and reaches the spawn seam.
        var known = workspaceRequest(in: dir)
        #expect(known.runtime == RuntimeCatalog.claude)
        known.runtime = RuntimeCatalog.claude
        await #expect(throws: CocoaError.self) {
            for try await _ in runner.run(known) {}
        }
        #expect(counter.count == 1)
        // `ClaudeProcessRunner` is the same type, kept by its old name.
        #expect(ClaudeProcessRunner.self == RuntimeProcessRunner.self)
    }

    /// The canary's turn comes from `canaryShape(for:)`: the shape key is the asking shape's key, and the prepared turn is
    /// today's (`SandboxCanary.prepare`): the same compiled settings shape, so no recorded canary pass changes.
    @Test func canaryShapeBuildsTodaysCanaryTurn() throws {
        let root = try tempDir()
        let paths = BrahmaPaths(home: root.appending(path: "home"), workspaces: root.appending(path: "ws"))
        let userHome = root.appending(path: "user")
        for dir in [paths.home, paths.workspaces, userHome] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let env = SandboxEnvironment(userHome: userHome, darwinUserTemp: nil, shell: "/bin/zsh")
        let hook = "/usr/local/bin/brahma"
        for spec in [SandboxCanary.TurnSpec.standard, SandboxCanary.TurnSpec(plan: true),
                     SandboxCanary.TurnSpec(allowedDomains: [], webDomains: [], allowLocalBinding: true)] {
            let today = try SandboxCanary.prepare(paths: paths, environment: env, hookExecutable: hook, spec: spec)
            let todayShape = today.settings.shape()
            today.cleanup()
            let asked = SandboxCanary.canaryTurnShape(spec: spec, askedShape: todayShape)
            #expect(asked.key == todayShape)
            let shape = ClaudeRuntime().canaryShape(for: asked)
            #expect(shape.shapeKey == todayShape)
            let prepared = try shape.request(CanaryInputs(paths: paths, environment: env, hookExecutable: hook, spec: spec))
            defer { prepared.cleanup() }
            #expect(prepared.settings.shape() == todayShape)
            #expect(prepared.request.runtime == RuntimeCatalog.claude)
        }
    }
}
