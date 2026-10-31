import Foundation

/// How long a preview may take.
public struct PreviewTimeouts: Equatable, Sendable {
    public var build: Duration = .seconds(1800)
    /// From spawn until the URL answers.
    public var ready: Duration = .seconds(120)
    /// Between readiness probes.
    public var poll: Duration = .milliseconds(500)

    public init(build: Duration = .seconds(1800), ready: Duration = .seconds(120), poll: Duration = .milliseconds(500)) {
        self.build = build; self.ready = ready; self.poll = poll
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

    public init(surface: PreviewSurface, company: Company, layout: EngineLayout, run: URL, commit: String, port: Int,
                policy: SandboxPolicy, environment: [String: String], logURL: URL, timeouts: PreviewTimeouts = PreviewTimeouts()) {
        self.surface = surface; self.company = company; self.layout = layout; self.run = run; self.commit = commit
        self.port = port; self.policy = policy; self.environment = environment; self.logURL = logURL; self.timeouts = timeouts
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

    public init(status: PreviewStatus, message: String?, process: Int32? = nil, resolvedURL: String? = nil) {
        self.status = status; self.message = message; self.process = process; self.resolvedURL = resolvedURL
    }
}

/// Starts and stops one kind of preview.
public protocol PreviewAdapter: Sendable {
    var kind: PreviewKind { get }
    /// Why this kind cannot run on this machine, or nil.
    func availability() -> String?
    func start(_ c: PreviewContext) async -> PreviewUpdate
    func stop(_ c: PreviewContext, state: PreviewState) async
}

/// What previews run on: the sandbox, the probes and the table of spawned processes.
public struct PreviewDependencies: Sendable {
    public var sandbox: any SandboxedRunner
    public var http: any HTTPProbing
    public var listen: any ListenProbing
    public var processes: SpawnedProcesses

    public init(sandbox: any SandboxedRunner, http: any HTTPProbing, listen: any ListenProbing, processes: SpawnedProcesses) {
        self.sandbox = sandbox; self.http = http; self.listen = listen; self.processes = processes
    }

    /// The real probes (`URLSessionHTTPProbe`, `LsofListenProbe`) and a fresh process table around `sandbox`.
    public static func live(sandbox: any SandboxedRunner) -> PreviewDependencies {
        PreviewDependencies(sandbox: sandbox, http: URLSessionHTTPProbe(), listen: LsofListenProbe(), processes: SpawnedProcesses())
    }
}
