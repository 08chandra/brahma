import Foundation

/// How long a preview may take.
public struct PreviewTimeouts: Equatable, Sendable {
    public var build: Duration = .seconds(1800)
    /// From spawn until the URL answers.
    public var ready: Duration = .seconds(120)
    /// Between readiness probes.
    public var poll: Duration = .milliseconds(500)
    /// A one-shot preview's demo command (Plan 4a).
    public var demo: Duration = .seconds(120)

    public init(build: Duration = .seconds(1800), ready: Duration = .seconds(120), poll: Duration = .milliseconds(500),
                demo: Duration = .seconds(120)) {
        self.build = build; self.ready = ready; self.poll = poll; self.demo = demo
    }
}

/// Everything one start of one surface needs.
public struct PreviewContext: Sendable {
    public var surface: PreviewSurface
    public var company: Company
    public var layout: EngineLayout
    /// The fresh export it builds and runs in (`EngineExport`, at `EngineLayout.previewRunId`).
    public var run: URL
    public var commit: String
    public var port: Int
    public var policy: SandboxPolicy
    public var environment: [String: String]
    public var logURL: URL
    public var timeouts: PreviewTimeouts
    /// Where a one-shot preview's output goes (Plan 4a; the runner uses `EngineLayout.previewOutput(name:)`).
    public var outputURL: URL
    /// The policy of the long-running app when it is not `policy` (a macOS app: `PreviewPolicy.guiApp`); nil otherwise.
    public var appPolicy: SandboxPolicy? = nil
    /// The start runs through `PreviewDependencies.unsandboxed` (a Full company, PR-5): use `deps.runner(for:)`.
    public var unsandboxed: Bool = false
    /// Hears the pid of a long-running process as soon as it is spawned (the runner records it, so a stop reaches it).
    public var onSpawn: (@Sendable (Int32, Double) async -> Void)? = nil
    /// What scrubs the captured output, the build log and the smoke results before anything keeps them (the runner passes
    /// `Store.redactor`; Plan 4a Task 5). Nil, or not loaded: nothing that would need it is kept (fail closed).
    public var redactor: Redactor? = nil
    /// The sprint a `demo` is for (its number), set by the sprint-review demo (Plan 4a Task 7): names a Simulator screenshot
    /// `<name>-demo-<sprint>.png`. Nil outside a sprint demo.
    public var demoSprint: Int? = nil

    public init(surface: PreviewSurface, company: Company, layout: EngineLayout, run: URL, commit: String, port: Int,
                policy: SandboxPolicy, environment: [String: String], logURL: URL, timeouts: PreviewTimeouts = PreviewTimeouts(),
                outputURL: URL? = nil, appPolicy: SandboxPolicy? = nil, unsandboxed: Bool = false,
                onSpawn: (@Sendable (Int32, Double) async -> Void)? = nil, redactor: Redactor? = nil) {
        self.surface = surface; self.company = company; self.layout = layout; self.run = run; self.commit = commit
        self.port = port; self.policy = policy; self.environment = environment; self.logURL = logURL; self.timeouts = timeouts
        self.outputURL = outputURL ?? layout.previewOutput(name: surface.name)
        self.appPolicy = appPolicy; self.unsandboxed = unsandboxed; self.onSpawn = onSpawn; self.redactor = redactor
    }

    /// A preview's environment: `ChildEnvironment.make` of `base` as for a check (`BRAHMA_AGENT_ID=preview`, nothing
    /// secret, no `BRAHMA_DEV`), then `PORT` and `HOST=127.0.0.1` (PR-3: `make`'s `extra` keeps only `BRAHMA_*`).
    public static func environment(base: [String: String] = ProcessInfo.processInfo.environment, port: Int) -> [String: String] {
        var env = ChildEnvironment.make(base: base, extra: ["BRAHMA_AGENT_ID": "preview"], purpose: .check)
        env["PORT"] = String(port)
        env["HOST"] = "127.0.0.1"
        return env
    }
}

/// What an adapter reports about a start.
public struct PreviewUpdate: Equatable, Sendable {
    public var status: PreviewStatus
    /// Engine-composed (never log output).
    public var message: String?
    public var process: Int32? = nil
    public var resolvedURL: String? = nil
    /// The Simulator device an iOS preview runs on (Plan 4a).
    public var simulatorId: String? = nil
    /// A backend's smoke results.
    public var smokeResults: [SmokeResult] = []
    /// A one-shot preview's captured output.
    public var outputPath: String? = nil

    public init(status: PreviewStatus, message: String?, process: Int32? = nil, resolvedURL: String? = nil, simulatorId: String? = nil,
                smokeResults: [SmokeResult] = [], outputPath: String? = nil) {
        self.status = status; self.message = message; self.process = process; self.resolvedURL = resolvedURL
        self.simulatorId = simulatorId; self.smokeResults = smokeResults; self.outputPath = outputPath
    }
}

/// Starts and stops one kind of preview, and shows it for a demo.
public protocol PreviewAdapter: Sendable {
    var kind: PreviewKind { get }
    /// Why this kind cannot run on this machine, or nil.
    func availability() -> String?
    func start(_ c: PreviewContext) async -> PreviewUpdate
    /// Stops what `start` left running (a process group, a Simulator app, a macOS app). Called on every stop of a run.
    func stop(_ c: PreviewContext, state: PreviewState) async
    /// What the preview shows now, for a demo (Plan 4a). The web adapter's: one GET (`WebAdapter.demo`).
    func demo(_ c: PreviewContext, state: PreviewState) async -> DemoCapture
}

extension PreviewAdapter {
    /// An adapter with nothing of its own to show: not ok, `"<name>: no demo for <Kind> previews"`.
    public func demo(_ c: PreviewContext, state: PreviewState) async -> DemoCapture {
        DemoCapture(ok: false, line: "\(c.surface.name): no demo for \(kind.title) previews")
    }
}

/// What previews run on: the sandbox, the probes and the table of spawned processes.
public struct PreviewDependencies: Sendable {
    public var sandbox: any SandboxedRunner
    public var http: any HTTPProbing
    public var listen: any ListenProbing
    public var processes: SpawnedProcesses
    /// What a Full company's previews run through when its checks would run unsandboxed too (PR-5).
    public var unsandboxed: any SandboxedRunner
    /// The iOS Simulator (Plan 4a; Task 7 provides the real one).
    public var simulator: any SimulatorControlling = UnavailableSimulator()
    /// macOS app launching (Plan 4a; Task 7 provides the real one).
    public var macApps: any MacAppLaunching = UnavailableMacApps()
    /// The adapter of each kind the engine's preview runner uses; nil: `PreviewAdapters.defaults` over these dependencies
    /// (Task 9c: tests inject an adapter here to drive the engine's own runner).
    public var adapters: [PreviewKind: any PreviewAdapter]? = nil

    public init(sandbox: any SandboxedRunner, http: any HTTPProbing, listen: any ListenProbing, processes: SpawnedProcesses,
                unsandboxed: any SandboxedRunner = UnsandboxedPreviewRunner(), simulator: any SimulatorControlling = UnavailableSimulator(),
                macApps: any MacAppLaunching = UnavailableMacApps()) {
        self.sandbox = sandbox; self.http = http; self.listen = listen; self.processes = processes; self.unsandboxed = unsandboxed
        self.simulator = simulator; self.macApps = macApps
    }

    /// The runner one start's agent-written commands go through: `unsandboxed` exactly when the runner routed the start
    /// there (`PreviewContext.unsandboxed`, PR-5), else the sandbox.
    public func runner(for c: PreviewContext) -> any SandboxedRunner { c.unsandboxed ? unsandboxed : sandbox }

    /// The real probes (`URLSessionHTTPProbe`, `LsofListenProbe`), a fresh process table around `sandbox`, the real Simulator
    /// controller (`xcrun simctl`) and macOS app launcher (Plan 4a Task 7; each says when it cannot work here).
    public static func live(sandbox: any SandboxedRunner) -> PreviewDependencies {
        PreviewDependencies(sandbox: sandbox, http: URLSessionHTTPProbe(), listen: LsofListenProbe(), processes: SpawnedProcesses(),
                            simulator: SimctlController(), macApps: ProcessMacAppLauncher())
    }
}
