import Foundation

// Plan X1 Task 2: the runtime seam (spec §8.1.1). The interface a coding-agent runtime presents to the engine, and the value
// types that cross it. Placed in `BrahmaCore` (Ruling 1: the monolith; Plans S/R/P are not merged) with the `public` access of the
// planned `BrahmaRuntime` target, so a later split is a pure move. Task 3 puts the Claude adapter behind it.
//
// Nothing here fails open: no `try?`, no `?? true` / `?? false`, no empty `catch` (`GatewayFailOpenLintTests`).

/// A runtime's name. Constructed only in `RuntimeCatalog` (`RuntimeIdLintTests.runtimeIdsOnlyInCatalog`); decoding through
/// `Codable` is the only other way in. Never compared with a string literal: name a runtime through the catalog.
public struct RuntimeId: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// How a turn is authorized: the owner's subscription on the CLI's own login, or the gateway's proxy-metered key.
public enum AuthRoute: String, Codable, Sendable {
    case subscription, gateway
}

/// One live probe the runtime's doctor runs (for Claude: `F7-agents`, the mode canary's gates, …).
public struct ProbeGateId: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
}

/// The doctor's facts about the installed CLI, passed in as values (the doctor's report lives above this seam).
/// Ruling 27: no `tools` (`ToolPaths` is a Plan S type that is not merged).
public struct ProbeEnvironment: Sendable {
    public var executable: String
    public var cliVersion: String?
    public var cliFlags: Set<String>

    public init(executable: String, cliVersion: String? = nil, cliFlags: Set<String> = []) {
        self.executable = executable; self.cliVersion = cliVersion; self.cliFlags = cliFlags
    }
}

/// What a runtime's probe found: which gates passed, which auth routes are available, and notes for the doctor.
public struct RuntimeProbe: Codable, Equatable, Sendable {
    public var runtime: RuntimeId
    public var cliVersion: String?
    public var passedGates: Set<ProbeGateId>
    public var authRoutes: Set<AuthRoute>
    public var notes: [String]

    public init(runtime: RuntimeId, cliVersion: String? = nil, passedGates: Set<ProbeGateId> = [], authRoutes: Set<AuthRoute> = [],
                notes: [String] = []) {
        self.runtime = runtime; self.cliVersion = cliVersion; self.passedGates = passedGates; self.authRoutes = authRoutes
        self.notes = notes
    }
}

/// How the runtime reports a tainted session: Claude's synchronous PostToolUse hook, or a launch already marked tainted.
public enum TaintSignalMode: String, Codable, Sendable {
    case syncHook, launchTainted
}

/// How the runtime's usage is known: its own rate-limit events (a subscription login), the gateway's metering, or not at all.
public enum UsageSignalMode: String, Codable, Sendable, CaseIterable {
    case rateLimitEvents, proxyMetered, none
}

/// `compile` refuses: the runtime cannot build this turn (a gate it needs has not passed, an auth route it lacks).
public enum RuntimeCompileError: Error, Equatable {
    case unavailable(String)
}

/// What today's canary request builder takes (`SandboxCanary.prepare(paths:environment:hookExecutable:spec:)`): the data home,
/// the owner's environment, the hook executable and the asking turn's spec. The throwaway company and agent, the planted
/// tokens and the settings file are the builder's own work, not inputs (see the Task 2 report for the mapping to the brief).
public struct CanaryInputs: Sendable {
    public var paths: BrahmaPaths
    public var environment: SandboxEnvironment
    public var hookExecutable: String
    public var spec: SandboxCanary.TurnSpec

    public init(paths: BrahmaPaths, environment: SandboxEnvironment, hookExecutable: String, spec: SandboxCanary.TurnSpec = .standard) {
        self.paths = paths; self.environment = environment; self.hookExecutable = hookExecutable; self.spec = spec
    }
}

/// The canary a turn shape needs: its key (what a pass is recorded under) and how to build the canary's request. Equatable on
/// `shapeKey` alone. `request` throws as today's builder does (it plants files and compiles the turn; a failure must surface,
/// never be swallowed).
public struct CanaryTurnShape: Sendable, Equatable {
    public var shapeKey: String
    public var request: @Sendable (CanaryInputs) throws -> TurnRequest

    public init(shapeKey: String, request: @escaping @Sendable (CanaryInputs) throws -> TurnRequest) {
        self.shapeKey = shapeKey; self.request = request
    }

    public static func == (a: CanaryTurnShape, b: CanaryTurnShape) -> Bool { a.shapeKey == b.shapeKey }
}

/// A coding-agent runtime: probed once per CLI build, asked for the gates a shape needs, compiles a turn request into a launch,
/// parses what the launched process prints, and says how taint and usage are signalled.
public protocol AgentRuntime: Sendable {
    var id: RuntimeId { get }
    func probe(_ env: ProbeEnvironment) async -> RuntimeProbe
    func gates(for shape: TurnShape) -> [ProbeGateId]
    func compile(_ r: TurnRequest, _ caps: RuntimeProbe) throws(RuntimeCompileError) -> LaunchSpec
    func parser() -> any RuntimeStreamParser
    func canaryShape(for shape: TurnShape) -> CanaryTurnShape
    var taintSignal: TaintSignalMode { get }
    /// Per auth route (deviating from spec §8.1.1's property): one runtime reports subscription rate limits on its own login and
    /// is proxy-metered through the gateway.
    func usageSignal(for auth: AuthRoute) -> UsageSignalMode
}

/// The shape of a turn as the canary and the probe gates see it (Rulings 10 and 26): the permission profile, the kind, the
/// work mode, the fan-out launch, the compiled settings' shape and the auth route. `key` is today's canary shape string
/// (`CanaryShape.key(settings, launch:)`) for a subscription turn, so no recorded canary pass changes, and that string +
/// `+gateway` for a gateway turn.
public struct TurnShape: Hashable, Codable, Sendable {
    public var profile: PermissionProfile
    public var kind: TurnKind
    public var mode: WorkMode?
    /// `CanaryShape.launch`: nil, `task`, `ultra-small` or `ultra`.
    public var launch: String?
    /// `ClaudeSettings.shape()` of the compiled settings.
    public var settingsShape: String
    public var auth: AuthRoute

    public init(profile: PermissionProfile, kind: TurnKind, mode: WorkMode?, launch: String?, settingsShape: String, auth: AuthRoute) {
        self.profile = profile; self.kind = kind; self.mode = mode; self.launch = launch; self.settingsShape = settingsShape
        self.auth = auth
    }

    /// `settingsShape` without a launch, `StableHash.fnv1a64(settingsShape + "|" + launch)` with one (`CanaryShape.key`); a
    /// gateway shape appends `+gateway`.
    public var key: String {
        let subscription: String
        if let launch {
            subscription = StableHash.fnv1a64(settingsShape + "|" + launch)
        } else {
            subscription = settingsShape
        }
        switch auth {
        case .subscription: return subscription
        case .gateway: return subscription + "+gateway"
        }
    }

    /// The shape of a request, compiled through today's path (`TurnProfileCompiler.profile(for:)`, validated) with
    /// `CanaryShape.launch` of its mode decision. Throws what `validate` throws: an invalid profile has no shape.
    public static func of(_ r: TurnRequest, auth: AuthRoute) throws -> TurnShape {
        let profile = TurnProfileCompiler.profile(for: r)
        try TurnProfileCompiler.validate(profile)
        return TurnShape(profile: r.profile, kind: r.kind, mode: r.mode?.mode, launch: CanaryShape.launch(r.mode),
                         settingsShape: profile.settings.shape(), auth: auth)
    }
}
