import Foundation

// Plan X1 Task 3: the Claude Code adapter behind the runtime seam (spec §8.1.1). It wraps today's compiler (`TurnProfileCompiler`
// with `ClaudeSettingsCompiler`) and parser (`StreamParser`) unchanged, so every launch it compiles is byte-identical to the one
// the runner built before the seam (`ClaudeParityGoldenTests` compiles through it against Task 1's goldens).
//
// Nothing here fails open (`GatewayFailOpenLintTests`: zero sites, no baseline): no `try?`, no `?? true` / `?? false`, no empty
// `catch`.

/// The Claude Code CLI (`claude -p --output-format stream-json`) as an `AgentRuntime`.
public struct ClaudeRuntime: AgentRuntime {
    /// The CLI's command name, looked up through `/usr/bin/env` by the runner.
    public static let defaultExecutable = "claude"

    public var id: RuntimeId { RuntimeCatalog.claude }
    /// The CLI the launch starts: a command name (looked up through `/usr/bin/env` by the runner) or an absolute path.
    public var executable: String
    /// What `ChildEnvironment` filters into the launch's environment: the launcher's own environment (tests inject one).
    public var baseEnvironment: [String: String]

    public init(executable: String = ClaudeRuntime.defaultExecutable,
                baseEnvironment: [String: String] = ProcessInfo.processInfo.environment) {
        self.executable = executable
        self.baseEnvironment = baseEnvironment
    }

    /// No live call here: the probe gates are run by the doctor and `brahma mode gates` and recorded as `probeGate` rows, which
    /// the engine reads. This reports the CLI as described and the subscription route (the gateway route lands with the
    /// gateway), with no gate passed: a caller that trusts this alone gets nothing it did not verify (fail closed).
    public func probe(_ env: ProbeEnvironment) async -> RuntimeProbe {
        RuntimeProbe(runtime: id, cliVersion: env.cliVersion, passedGates: [], authRoutes: [.subscription], notes: [])
    }

    /// Today's probe gates for the shape (`ProbeGates.catalog`, the `probeGate` rows): the sandboxed Task fan-out, the Ultra
    /// workflow and the sandboxed plan turn each need theirs; any other shape needs none. The auth route does not change them.
    public func gates(for shape: TurnShape) -> [ProbeGateId] {
        guard let probeShape = Self.probeShape(shape) else { return [] }
        return ProbeGates.catalog(probeShape).map { ProbeGateId(rawValue: $0) }
    }

    /// The 5-lite probe shape a turn shape is gated by (`ProbeShape`), from its fan-out launch (`CanaryShape.launch`) and kind.
    static func probeShape(_ shape: TurnShape) -> ProbeShape? {
        guard shape.profile == .sandboxed else { return nil }
        switch shape.launch {
        case "task": return .sandboxedTask
        case "ultra", "ultra-small": return .ultra
        default: return shape.kind == .plan ? .sandboxedPlan : nil
        }
    }

    /// The launch of `r` as the runner built it before the seam: the compiled profile, validated (a refusal is the compiler's
    /// own text), its argv, the settings file it names (with the compiled settings' bytes; inline settings ride in the argv), the
    /// filtered child environment, the profile's working directory and wall clock, and the prompt for stdin. The probe result
    /// does not change a subscription launch today: the gates a turn needs are applied by the engine before it builds the
    /// request (`TurnRequest.taskWebTools`, the mode decision).
    public func compile(_ r: TurnRequest, _ caps: RuntimeProbe) throws(RuntimeCompileError) -> LaunchSpec {
        let profile = try Self.validatedProfile(r)
        var files: [LaunchFile] = []
        if let path = profile.settingsFilePath {
            files.append(LaunchFile(path: path, contents: Data(try Self.settingsText(profile).utf8)))
        }
        let sandbox: LaunchSandbox
        if profile.permission == .sandboxed {
            // `validate` refuses a sandboxed profile without its settings file; this keeps the refusal if it ever did not.
            guard let path = profile.settingsFilePath else {
                throw .invalid(TurnProfileError.sandboxIncomplete("no settings file").description)
            }
            sandbox = .claudeSettings(path: path)
        } else {
            sandbox = .unsandboxed(profile.permission)
        }
        let environment = ChildEnvironment.make(base: baseEnvironment, extra: profile.environment, engineClaudeVars: profile.environment,
                                                purpose: .claude, secrets: r.secrets,
                                                allowBuiltinAgentsSwitch: profile.builtinAgentsDisabled)
        return LaunchSpec(executable: executable, arguments: TurnProfileCompiler.arguments(profile), environment: environment,
                          files: files, sandbox: sandbox, workingDirectory: profile.workingDirectory, stdin: r.prompt,
                          wallClock: profile.wallClock)
    }

    /// The mode canary's control session (`TurnRunning.control`): the compiled launch with `--input-format stream-json` after
    /// `-p`, no prompt (control messages are written instead, so no model is called) and, as before the seam, no secrets.
    public func compileControl(_ r: TurnRequest, _ caps: RuntimeProbe) throws(RuntimeCompileError) -> LaunchSpec {
        var request = r
        request.secrets = [:]
        var spec = try compile(request, caps)
        spec.arguments.insert(contentsOf: ["--input-format", "stream-json"], at: 1)
        spec.stdin = ""
        return spec
    }

    public func parser() -> any RuntimeStreamParser { ClaudeStreamParser() }

    /// The canary's turn for a shape: today's builder (`SandboxCanary.prepare`) with the asking turn's spec, recorded under the
    /// shape's key (today's canary shape string for a subscription turn, so no recorded pass changes).
    public func canaryShape(for shape: TurnShape) -> CanaryTurnShape {
        CanaryTurnShape(shapeKey: shape.key) { inputs in
            try SandboxCanary.prepare(paths: inputs.paths, environment: inputs.environment, hookExecutable: inputs.hookExecutable,
                                      spec: inputs.spec)
        }
    }

    /// The PostToolUse hook marks a session tainted as the tool call returns.
    public var taintSignal: TaintSignalMode { .syncHook }

    /// The CLI's own `rate_limit_event`s on a subscription login; the gateway's metering on a gateway turn (no rate-limit
    /// events then, X1-0).
    public func usageSignal(for auth: AuthRoute) -> UsageSignalMode {
        switch auth {
        case .subscription: .rateLimitEvents
        case .gateway: .proxyMetered
        }
    }

    /// The compiled profile of `r`, validated: the runner's check before it starts a process.
    static func validatedProfile(_ r: TurnRequest) throws(RuntimeCompileError) -> TurnProfile {
        let profile = TurnProfileCompiler.profile(for: r)
        do {
            try TurnProfileCompiler.validate(profile)
        } catch {
            throw .invalid("\(error)")
        }
        return profile
    }

    /// The compiled settings' bytes (`TurnProfileCompiler.settingsJSON`); an encoding failure refuses the launch.
    static func settingsText(_ profile: TurnProfile) throws(RuntimeCompileError) -> String {
        do {
            return try TurnProfileCompiler.settingsJSON(profile)
        } catch {
            throw .invalid("the turn's settings could not be encoded: \(error)")
        }
    }
}

/// The adapter's line parser: `StreamParser.parseAll(line:now:)`, a line that is not JSON giving no events. Stateless.
public struct ClaudeStreamParser: RuntimeStreamParser {
    public init() {}

    public mutating func parse(line: String, now: Date) -> [TurnEvent] {
        StreamParser.parseAll(line: line, now: now) ?? []
    }
}
