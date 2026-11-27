import Testing
import Foundation
@testable import BrahmaCore

// Plan X1 Task 1: the Claude turn-shape parity goldens, recorded on the code BEFORE the runtime seam (Tasks 2-4) moves anything.
// One golden per shape the compiler can produce today, each `{ argv, settings, envNames, env, mcpConfig, shape }`, compiled through
// today's path (`TurnProfileCompiler.profile(for:)` → `validate` → `arguments`, `settingsJSON`, `ChildEnvironment.make(purpose:
// .claude)`, `MCPConfig.write`) and compared byte for byte after normalization. `BRAHMA_RECORD_GOLDENS=1` records; without it the
// suite compares. The later tasks prove the seam by this suite staying green without a single golden changing.

// MARK: - The shape set (Task 0 (e), as ruled for this task)

/// One cell of profile × kind × mode × launch × network × item. The pruning rules are `ParityShapes.enumerate()`.
struct ParityCell: Hashable, Sendable {
    enum Mode: String, CaseIterable { case quick, standard, deep, plan, ultra }
    /// `-f7` marks the fan-out turn once probe F7-agents passed for the CLI (`TurnRequest.taskWebTools`): the same settings and
    /// shape key, a different `--tools` and the built-in agents switch in the environment.
    enum Launch: String, CaseIterable {
        case none, task, taskF7 = "task-f7", ultraSmall = "ultra-small", ultraSmallF7 = "ultra-small-f7", ultra, ultraF7 = "ultra-f7"

        var fansOut: Bool { self != .none }
        var f7Passed: Bool { [.taskF7, .ultraSmallF7, .ultraF7].contains(self) }
        var ultraVariant: UltraVariant? {
            switch self {
            case .ultraSmall, .ultraSmallF7: .small
            case .ultra, .ultraF7: .full
            default: nil
            }
        }
        /// What `CanaryShape.launch` must say of the decision this launch compiles.
        var canaryLaunch: String? {
            switch self {
            case .none: nil
            case .task, .taskF7: "task"
            case .ultraSmall, .ultraSmallF7: "ultra-small"
            case .ultra, .ultraF7: "ultra"
            }
        }
    }
    /// `default`: the company's network as created (the default registries and docs, local binding on). `custom`: owner-added
    /// Bash and web domains and local binding off (the one network input that is a boolean, so the only one that moves the shape).
    enum Network: String { case none, `default`, custom }
    enum Item: String { case none, item, itemless }

    var profile: PermissionProfile
    var kind: TurnKind
    var mode: Mode
    var launch: Launch
    var network: Network
    var item: Item

    var name: String { "\(profile.rawValue)-\(kind.rawValue)-\(mode.rawValue)-\(launch.rawValue)-\(network.rawValue)-\(item.rawValue)" }
}

enum ParityShapes {
    /// The shapes that compile through `TurnProfileCompiler.profile(for:)` but are not turn cells: the concierge's run
    /// (`conciergeProfile`) and the doctor's mode canary (`ModeCanary.shapes()`, through the runner's `control` argv).
    static let conciergeName = "concierge"
    static func modeCanaryName(_ shape: String) -> String { "mode-canary-\(shape)" }
    /// Plan X1 Task 4 (`workSandboxedAmbientAuth`): a sandboxed work turn compiled while the owner's environment carries Claude
    /// auth and gateway variables (`GoldenWorld.ambientAuthEnvironment`); its golden shows none of them.
    static let workSandboxedAmbientAuth = "work-sandboxed-ambient-auth"
    /// The cell the ambient-auth shape compiles: only its base environment differs.
    static let ambientAuthCell = ParityCell(profile: .sandboxed, kind: .work, mode: .standard, launch: .none, network: .default, item: .item)
    static var specialNames: [String] {
        [conciergeName, workSandboxedAmbientAuth] + ModeCanary.shapes().map { modeCanaryName($0.0) }
    }

    /// Every golden's name: the cells plus the special shapes.
    static var allNames: Set<String> { Set(enumerate().map(\.name)).union(specialNames) }

    /// The generating set of Task 0 (e) — profile {sandboxed, workspace, full} × kind {work, review, audit, notice, plan, show} ×
    /// mode {quick, standard, deep, plan, ultra} × launch × network × item — pruned to what the compiler and `ModePolicy`
    /// produce. The rules, as code:
    static func enumerate() -> [ParityCell] {
        var out: [ParityCell] = []
        for profile in [PermissionProfile.sandboxed, .workspace, .full] {
            for kind in TurnKind.allCases {
                for mode in modes(for: kind) {
                    for launch in launches(profile: profile, kind: kind, mode: mode) {
                        for network in networks(profile: profile) {
                            for item in items(profile: profile, kind: kind, mode: mode, launch: launch) {
                                out.append(ParityCell(profile: profile, kind: kind, mode: mode, launch: launch, network: network, item: item))
                            }
                        }
                    }
                }
            }
        }
        return out
    }

    /// Plan kind only with plan mode (and plan mode only on the plan kind); notice and show are always Quick; review and audit
    /// are Standard or Deep (`ModePolicy.review`); work is Quick, Standard, Deep or Ultra.
    static func modes(for kind: TurnKind) -> [ParityCell.Mode] {
        switch kind {
        case .work: [.quick, .standard, .deep, .ultra]
        case .review, .audit: [.standard, .deep]
        case .notice, .show: [.quick]
        case .plan: [.plan]
        }
    }

    /// Fan-out only for sandboxed work (`SubagentGate.passed` is false off the sandbox; Ultra is admitted only there): `task`
    /// with Standard or Deep (the gate's forced sub-agents), Ultra always with its workflow (`ultra-small` or `ultra`, never
    /// without a launch). Review, audit, plan, notice and show never fan out; Ultra off the sandbox is pruned entirely.
    static func launches(profile: PermissionProfile, kind: TurnKind, mode: ParityCell.Mode) -> [ParityCell.Launch] {
        guard profile == .sandboxed, kind == .work else { return mode == .ultra ? [] : [.none] }
        switch mode {
        case .quick, .plan: return [.none]
        case .standard, .deep: return [.none, .task, .taskF7]
        case .ultra: return [.ultraSmall, .ultraSmallF7, .ultra, .ultraF7]
        }
    }

    /// Network only matters on the sandboxed profile (the `sandbox.network` block).
    static func networks(profile: PermissionProfile) -> [ParityCell.Network] {
        profile == .sandboxed ? [.default, .custom] : [.none]
    }

    /// Item/itemless only matters on the sandboxed profile (the scope's cwd and write paths) and only for work; an itemless work
    /// turn is always Quick without fan-out (`ModePolicy.select`'s kind gate), so that is the one itemless cell per network.
    static func items(profile: PermissionProfile, kind: TurnKind, mode: ParityCell.Mode, launch: ParityCell.Launch) -> [ParityCell.Item] {
        guard profile == .sandboxed else { return [.none] }
        guard kind == .work else { return [.item] }
        return mode == .quick && launch == .none ? [.item, .itemless] : [.item]
    }
}

// MARK: - Fixtures (the ones `SettingsCompilerTests` and `TurnProfileTests` use)

private let hookExe = "/usr/local/bin/brahma"
private let marker = "dev.brahma.turn.0123456789abcdef"
private let turnToken = "fixture-turn-token"
private let conciergeRequestId = "3f6a2c1e-0000-4000-8000-00000000c0de"

/// The decisions as `SettingsCompilerTests` and `ModeCanary.shapes()` make them: hasItem, tier S, $100 left, then the edit.
private func decision(_ edit: (inout ModeInputs) -> Void) -> ModeDecision {
    var i = ModeInputs()
    i.hasItem = true
    i.tier = .s
    i.budgetLeftLE = 100
    edit(&i)
    return ModePolicy.select(i)
}

private func decision(kind: TurnKind, mode: ParityCell.Mode, launch: ParityCell.Launch) throws -> ModeDecision {
    switch (kind, mode) {
    case (.show, _): return decision { $0.turnKind = .show }
    case (.review, .deep), (.audit, .deep): return decision { $0.turnKind = kind; $0.tier = .l }
    case (.review, _), (.audit, _): return decision { $0.turnKind = kind }
    case (.plan, _): return decision { $0.turnKind = .plan }
    // Quick as the mode canary and `SettingsCompilerTests` make it (haiku low).
    case (_, .quick): return decision { $0.turnKind = .notice }
    case (_, .standard): return decision { $0.subagentGate = launch.fansOut }
    case (_, .deep): return decision { $0.tier = .m; $0.riskTags = ["hotPath"]; $0.subagentGate = launch.fansOut }
    case (_, .ultra):
        // Ultra is only ever compiled with its launch (`ParityShapes.launches`); a cell without one is an enumeration bug.
        let variant = try #require(launch.ultraVariant, "an Ultra cell without an Ultra launch")
        return decision { $0.ultra = UltraAdmission(variant: variant, approver: .policy, workflowAgents: 2, basis: "fixture") }
    case (_, .plan): return decision { $0.turnKind = .plan }
    }
}

/// A company on a file-backed store whose data home, workspaces root, owner's home and Darwin temp dir all sit in one resolved
/// temp dir (`SettingsCompilerTests.CompileWorld`), so every compiled path is known and can be written as a placeholder.
/// Internal (not private): Task 2's `RuntimeTypesTests.subscriptionShapeKeyUnchanged` iterates the same shapes.
struct GoldenWorld {
    let root: URL
    let userHome: URL
    let paths: BrahmaPaths
    let store: Store
    let company: Company
    let eng: Agent
    let item: WorkItem
    let layout: SandboxLayout
    let userTemp: URL
    let canaryDir: URL

    init() throws {
        root = URL(fileURLWithPath: SandboxPath.resolve(try tempDir().path), isDirectory: false)
        userHome = root.appending(path: "user")
        paths = BrahmaPaths(home: root.appending(path: "data"), workspaces: root.appending(path: "wss"))
        userTemp = root.appending(path: "folders/T")
        canaryDir = root.appending(path: "canary")
        for dir in [userHome, paths.home, paths.workspaces, userTemp, canaryDir] {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        store = try Store(path: paths.database.path)
        company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: paths.workspaces)
        eng = try store.hire(companyId: company.id, name: "eng-1", role: "engineer", model: "sonnet")
        item = try store.createWorkItem(companyId: company.id, by: .owner, draft: WorkItemDraft(
            type: .task, title: "Thing", ownerId: eng.id, status: .ready), now: Date())
        layout = SandboxLayout(paths: paths, company: company, agentHandle: "eng-1")
        try layout.ensure()
        try FileManager.default.createDirectory(at: ws.appending(path: ".brahma/wt/\(item.key)"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: ws.appending(path: ".brahma/plans/\(item.key)"), withIntermediateDirectories: true)
        try Data("{\"mcpServers\":{}}".utf8).write(to: canaryDir.appending(path: "empty.mcp.json"))
    }

    var ws: URL { URL(fileURLWithPath: company.workspacePath, isDirectory: false) }
    var plansDir: String { ws.appending(path: ".brahma/plans/\(item.key)").path }

    /// The company with the cell's network: as created, or with owner-added domains and local binding off.
    func company(_ network: ParityCell.Network) -> Company {
        var c = company
        if network == .custom {
            c.allowedDomains = ["internal.example.com"]
            c.webDomains = ["docs.example.com"]
            c.allowLocalBinding = false
        }
        return c
    }

    func scope(_ cell: ParityCell) throws -> SandboxScope {
        try SandboxScope.forTurn(layout: layout, paths: paths, otherWorkspaces: [], backupTargets: [], kind: cell.kind,
                                 item: cell.item == .itemless ? nil : item, company: company(cell.network), grants: GrantInputs(),
                                 darwinUserTemp: userTemp, userHome: userHome, claudeTmpRoot: URL(fileURLWithPath: "/private/tmp/b-test"))
    }

    /// The owner's environment as the engine would see it: the basics, two proxies of no consequence, and names `ChildEnvironment`
    /// must drop (a secret-looking one, an unlisted one). No auth variable, so `envNames` is stable.
    var baseEnvironment: [String: String] {
        ["PATH": "/usr/bin:/bin:/usr/sbin:/sbin", "HOME": userHome.path, "LANG": "en_US.UTF-8", "LC_ALL": "en_US.UTF-8",
         "TERM": "xterm-256color", "USER": "owner", "LOGNAME": "owner", "SHELL": "/bin/zsh", "TMPDIR": userTemp.path + "/",
         "DEVELOPER_DIR": "/Applications/Xcode.app/Contents/Developer", "EDITOR": "vi", "SSH_AUTH_SOCK": "/private/tmp/agent.sock",
         "AWS_PROFILE": "owner", "NPM_CONFIG_USERCONFIG": userHome.appending(path: ".npmrc").path]
    }

    /// Plan X1 Task 4: the owner's environment with a Claude login and the gateway's names set in the shell. The key value is
    /// assembled at runtime (Ruling 8); none of these may reach a turn.
    var ambientAuthEnvironment: [String: String] {
        baseEnvironment.merging(["ANTHROPIC_API_KEY": ["sk", "ant", "real"].joined(separator: "-"),
                                 "CLAUDE_CODE_OAUTH_TOKEN": "owner-oauth", "ANTHROPIC_BASE_URL": "https://x",
                                 "ANTHROPIC_DEFAULT_OPUS_MODEL": "owner-model", "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC": "1"]) { $1 }
    }

    /// The cell's request as `Orchestrator.performTurn`'s `turnRequest` builds it.
    func request(_ cell: ParityCell) throws -> TurnRequest {
        let company = company(cell.network)
        let mcpPath = try MCPConfig.write(paths: paths, executable: hookExe, agent: eng, turnToken: turnToken,
                                          reviewItem: cell.kind == .review ? item.key : nil, audit: cell.kind == .audit, environment: [:])
        var r = TurnRequest(agent: eng, company: company, prompt: "P", appendSystemPrompt: "ROLE", mcpConfigPath: mcpPath,
                            workingDirectory: company.workspacePath, profile: cell.profile,
                            environment: ["BRAHMA_AGENT_ID": eng.id, "BRAHMA_HOME": paths.home.path, "BRAHMA_WORKSPACES": paths.workspaces.path])
        r.kind = cell.kind
        r.mode = try decision(kind: cell.kind, mode: cell.mode, launch: cell.launch)
        r.hookExecutable = hookExe
        r.settingsFilePath = SettingsFile.path(paths: paths, agentId: eng.id).path
        r.postToolHook = TaintPolicy.postToolHook(executable: hookExe, database: paths.database.path, agentId: eng.id)
        r.taintFlagFile = try #require(TaintFlag.url(home: paths.home, agentId: eng.id)).path
        r.taintDatabase = paths.database.path
        r.taskWebTools = cell.launch.f7Passed
        if cell.kind == .plan { r.planDirectory = plansDir }
        switch cell.profile {
        case .sandboxed:
            let scope = try scope(cell)
            r.sandbox = scope
            r.addDirs = scope.readOnlyDirs.map(\.path)
            r.shellPrefix = layout.shellPrefix.path
            r.containmentMarker = marker
        case .workspace:
            r.deniedPaths = [paths.home] + ProtectedPaths.defaults(userHome: userHome)
        case .full:
            break
        }
        return r
    }

    /// The concierge's request as `Concierge.run` builds it (Plan C Task C4c).
    func conciergeRequest() throws -> TurnRequest {
        let workdir = paths.home.appending(path: "tmp/concierge-\(conciergeRequestId)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: workdir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])  // exec-bit fixture: the concierge workdir's mode, as Concierge.run makes it
        let mcpPath = try MCPConfig.writeConcierge(paths: paths, executable: hookExe, companyId: company.id, requestId: conciergeRequestId,
                                                   token: turnToken, environment: [:])
        let agent = Agent(id: ConciergeCaps.agentId, companyId: company.id, name: ConciergeCaps.agentId, role: "concierge",
                          model: ConciergeCaps.model, sessionId: "00000000-0000-4000-8000-000000000001", sessionStarted: false,
                          state: .running, blocker: nil, requestedBlocker: nil, paused: false, readySince: nil, createdAt: Date(timeIntervalSince1970: 0))
        var turn = TurnRequest(agent: agent, company: company, prompt: "Q", appendSystemPrompt: nil, mcpConfigPath: mcpPath,
                               workingDirectory: workdir.path, profile: .workspace, addDirs: [workdir.path],
                               environment: ["BRAHMA_AGENT_ID": ConciergeCaps.agentId, "BRAHMA_HOME": paths.home.path])
        turn.kind = .show
        turn.concierge = ConciergeTurn(companyId: company.id, requestId: conciergeRequestId, workdir: workdir)
        turn.wallClock = ConciergeCaps.wallClock
        return turn
    }

    /// The mode canary's request as `ModeCanary.run` builds it (the doctor's control session on the workspace profile).
    func modeCanaryRequest(_ d: ModeDecision) -> TurnRequest {
        let agent = Agent(id: "doctor-canary", companyId: "doctor", name: "canary", role: "probe", model: d.model,
                          sessionId: "00000000-0000-4000-8000-000000000002", sessionStarted: false, state: .running, blocker: nil,
                          requestedBlocker: nil, paused: false, readySince: nil, createdAt: Date(timeIntervalSince1970: 0))
        let company = Company(id: "doctor", name: "Doctor", slug: "doctor", goal: "canary", workspacePath: canaryDir.path,
                              status: .running, usageMode: .low, priorityWeight: 1, createdAt: Date(timeIntervalSince1970: 0))
        var request = TurnRequest(agent: agent, company: company, prompt: "", appendSystemPrompt: nil,
                                  mcpConfigPath: canaryDir.appending(path: "empty.mcp.json").path, workingDirectory: canaryDir.path,
                                  profile: .workspace, environment: ["BRAHMA_AGENT_ID": "doctor-canary"])
        request.mode = d
        request.hookExecutable = hookExe
        return request
    }

    /// Every per-run path and id of this world as a stable placeholder. Longer paths first (the run dir sits in the data home).
    func normalize(_ text: String) -> String {
        text.replacingOccurrences(of: "/private/tmp/b-test/[0-9a-f]{6}", with: "<AGENTTMP>", options: .regularExpression)
            .replacingOccurrences(of: paths.runDir.path, with: "<RUN>")
            .replacingOccurrences(of: ws.path, with: "<WS>")
            .replacingOccurrences(of: paths.workspaces.path, with: "<WORKSPACES>")
            .replacingOccurrences(of: paths.home.path, with: "<HOME>")
            .replacingOccurrences(of: userHome.path, with: "<USERHOME>")
            .replacingOccurrences(of: userTemp.path, with: "<TMP>")
            .replacingOccurrences(of: userTemp.deletingLastPathComponent().path, with: "<DARWIN>")
            .replacingOccurrences(of: canaryDir.path, with: "<CANARY>")
            .replacingOccurrences(of: root.path, with: "<ROOT>")
            .replacingOccurrences(of: "claude-\(getuid())", with: "claude-<UID>")
            .replacingOccurrences(of: "/private/tmp/b-\(getuid())", with: "/private/tmp/b-<UID>")
            .replacingOccurrences(of: item.key, with: "<KEY>")
            .replacingOccurrences(of: eng.id, with: "<AGENT>")
            .replacingOccurrences(of: company.id, with: "<COMPANY>")
            .replacingOccurrences(of: turnToken, with: "<TOKEN>")
            .replacingOccurrences(of: "[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}",
                                  with: "<ID>", options: .regularExpression)
    }
}

// MARK: - Capture

/// What one golden records of a compiled request.
private struct Capture {
    var argv: [String]
    var settings: Any
    var env: [String: String]
    var mcpConfig: Any
    var shape: String

    /// The golden's text: keys sorted, pretty-printed, every per-run path and id a placeholder.
    func text(_ world: GoldenWorld) throws -> String {
        let secretFree = env.filter { !ChildEnvironment.isSecretName($0.key) }
        let object: [String: Any] = ["argv": argv, "settings": settings, "envNames": env.keys.sorted(), "env": secretFree,
                                     "mcpConfig": mcpConfig, "shape": shape]
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys, .prettyPrinted, .withoutEscapingSlashes])
        return world.normalize(String(decoding: data, as: UTF8.self)) + "\n"
    }
}

private func json(_ text: String) throws -> Any { try JSONSerialization.jsonObject(with: Data(text.utf8)) }

/// Since Task 3 the path runs through the runtime seam: `ClaudeRuntime.compile` (the mode canary's control session through
/// `compileControl`, the runner's own builder) → the launch's argv, its settings (the settings file the launch carries, or the
/// inline `--settings`), its child environment and the MCP config its argv names; the shape is `TurnShape.of(_:auth:)`'s key.
/// Task 1 recorded the goldens on today's direct path (`TurnProfileCompiler.profile(for:)` → `validate` → `arguments`,
/// `settingsJSON`, `ChildEnvironment.make(purpose: .claude)`); they match unchanged.
private func capture(_ r: TurnRequest, world: GoldenWorld, controlSession: Bool = false,
                     baseEnvironment: [String: String]? = nil) throws -> Capture {
    let runtime = ClaudeRuntime(baseEnvironment: baseEnvironment ?? world.baseEnvironment)
    let caps = RuntimeProbe(runtime: RuntimeCatalog.claude)
    let spec = controlSession ? try runtime.compileControl(r, caps) : try runtime.compile(r, caps)
    func value(after flag: String) throws -> String {
        let i = try #require(spec.arguments.firstIndex(of: flag), "no \(flag) in the argv")
        return try #require(spec.arguments.indices.contains(i + 1) ? spec.arguments[i + 1] : nil, "no value after \(flag)")
    }
    let settingsArgument = try value(after: "--settings")
    let settingsText = spec.files.first { $0.path == settingsArgument }.map { String(decoding: $0.contents, as: UTF8.self) } ?? settingsArgument
    let mcp = try String(contentsOfFile: try value(after: "--mcp-config"), encoding: .utf8)
    return Capture(argv: spec.arguments, settings: try json(settingsText), env: spec.environment, mcpConfig: try json(mcp),
                   shape: try TurnShape.of(r, auth: .subscription).key)
}

private func capture(cell: ParityCell, world: GoldenWorld) throws -> Capture {
    let r = try world.request(cell)
    // The enumeration must describe the decision truthfully: the mode and the launch are the policy's own.
    let d = try #require(r.mode)
    #expect(d.mode.rawValue == cell.mode.rawValue, "\(cell.name)")
    #expect(CanaryShape.launch(d) == cell.launch.canaryLaunch, "\(cell.name)")
    return try capture(r, world: world)
}

private func capture(name: String, world: GoldenWorld) throws -> Capture {
    if name == ParityShapes.conciergeName { return try capture(try world.conciergeRequest(), world: world) }
    if name == ParityShapes.workSandboxedAmbientAuth {
        return try capture(try world.request(ParityShapes.ambientAuthCell), world: world, baseEnvironment: world.ambientAuthEnvironment)
    }
    if let canary = ModeCanary.shapes().first(where: { ParityShapes.modeCanaryName($0.0) == name }) {
        return try capture(world.modeCanaryRequest(canary.1), world: world, controlSession: true)
    }
    let cell = try #require(ParityShapes.enumerate().first { $0.name == name }, "no such shape: \(name)")
    return try capture(cell: cell, world: world)
}

/// The request behind the golden `name`, as `capture(name:)` builds it (shared with Task 2's `RuntimeTypesTests`).
func goldenRequest(name: String, world: GoldenWorld) throws -> TurnRequest {
    if name == ParityShapes.conciergeName { return try world.conciergeRequest() }
    if name == ParityShapes.workSandboxedAmbientAuth { return try world.request(ParityShapes.ambientAuthCell) }
    if let canary = ModeCanary.shapes().first(where: { ParityShapes.modeCanaryName($0.0) == name }) {
        return world.modeCanaryRequest(canary.1)
    }
    let cell = try #require(ParityShapes.enumerate().first { $0.name == name }, "no such shape: \(name)")
    return try world.request(cell)
}

// MARK: - Golden files

enum Goldens {
    static let recording = ProcessInfo.processInfo.environment["BRAHMA_RECORD_GOLDENS"] == "1"
    /// The source tree's `Fixtures/turn-shapes` (where recording writes; `everyShapeCovered` lists it).
    static let sourceDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent().appending(path: "Fixtures/turn-shapes")

    /// The committed golden, from the test bundle (as every fixture here is read).
    static func read(_ name: String) throws -> String {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "json", subdirectory: "Fixtures/turn-shapes"),
                               "no golden recorded for \(name) (run with BRAHMA_RECORD_GOLDENS=1)")
        return try String(contentsOf: url, encoding: .utf8)
    }

    static func write(_ name: String, _ text: String) throws {
        try FileManager.default.createDirectory(at: sourceDirectory, withIntermediateDirectories: true)
        try Data(text.utf8).write(to: sourceDirectory.appending(path: "\(name).json"))
    }

    static func recordedNames() throws -> Set<String> {
        let names = try FileManager.default.contentsOfDirectory(atPath: sourceDirectory.path)
        return Set(names.filter { $0.hasSuffix(".json") }.map { String($0.dropLast(5)) })
    }
}

@Suite(.scratch) struct ClaudeParityGoldenTests {
    /// Every shape compiled through today's path, recorded (`BRAHMA_RECORD_GOLDENS=1`) or compared byte for byte.
    @Test func captureOrCompare() throws {
        let world = try GoldenWorld()
        let names = ParityShapes.allNames.sorted()
        #expect(names.count >= 40 && names.count <= 120, "\(names.count) shapes")
        var mismatches: [String] = []
        for name in names {
            let text = try capture(name: name, world: world).text(world)
            if Goldens.recording {
                try Goldens.write(name, text)
                continue
            }
            let expected = try Goldens.read(name)
            if text != expected {
                mismatches.append(name)
                Issue.record("golden \(name) differs:\n--- recorded\n\(expected)\n--- compiled now\n\(text)")
            }
        }
        if Goldens.recording {
            // A re-recording leaves no stale file behind.
            for stale in try Goldens.recordedNames().subtracting(names) {
                try FileManager.default.removeItem(at: Goldens.sourceDirectory.appending(path: "\(stale).json"))
            }
        }
        #expect(mismatches.isEmpty, "\(mismatches.count) golden(s) differ: \(mismatches.joined(separator: ", "))")
    }

    /// The golden set on disk equals the enumerated set: no stale file, no missing shape.
    @Test func everyShapeCovered() throws {
        let enumerated = ParityShapes.allNames
        let recorded = try Goldens.recordedNames()
        #expect(recorded == enumerated,
                "missing: \(enumerated.subtracting(recorded).sorted()); stale: \(recorded.subtracting(enumerated).sorted())")
        // The cells are distinct, and every golden is a distinct compile (no two cells are the same request).
        let cells = ParityShapes.enumerate()
        #expect(Set(cells.map(\.name)).count == cells.count)
        // No golden may carry a literal in a real key format, and every company server's token is the placeholder (the mode
        // canary's MCP config has no server at all).
        for name in recorded.sorted() {
            let text = try String(contentsOf: Goldens.sourceDirectory.appending(path: "\(name).json"), encoding: .utf8)
            for pattern in ["(^|[^A-Za-z0-9])sk-", "AKIA[0-9A-Z]{12}", "ghp_", "xox[abprs]-", turnToken] {
                #expect(text.range(of: pattern, options: .regularExpression) == nil, "\(name) matches \(pattern)")
            }
            let golden = try #require(try json(text) as? [String: Any], "\(name) is not a JSON object")
            let servers = try #require((golden["mcpConfig"] as? [String: Any])?["mcpServers"] as? [String: Any], "\(name) has no mcpServers")
            if let company = servers["company"] as? [String: Any] {
                #expect((company["env"] as? [String: String])?[MCPConfig.tokenVariable] == "<TOKEN>", "\(name): the token is not the placeholder")
            } else {
                #expect(name.hasPrefix("mode-canary-"), "\(name) has no company server")
            }
        }
    }

    /// Plan X1 Task 4: with Claude auth and the gateway's names in the owner's environment, the turn compiles exactly as without
    /// them — no auth or gateway variable in its environment.
    @Test func ambientAuthShapeHasNoAuthVariable() throws {
        let world = try GoldenWorld()
        let ambient = try capture(name: ParityShapes.workSandboxedAmbientAuth, world: world)
        for name in ["ANTHROPIC_API_KEY", "CLAUDE_CODE_OAUTH_TOKEN", "ANTHROPIC_BASE_URL", "ANTHROPIC_DEFAULT_OPUS_MODEL",
                     "CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC"] {
            #expect(ambient.env[name] == nil, "\(name) reached the turn")
        }
        #expect(!ambient.env.keys.contains { $0.hasPrefix("ANTHROPIC_") })
        let plain = try capture(cell: ParityShapes.ambientAuthCell, world: world)
        #expect(try ambient.text(world) == (try plain.text(world)))
    }

    /// The pair (e) asks about: an item and an itemless sandboxed work turn hash to the same shape (no array goes empty), the two
    /// networks do not (local binding is a boolean), and a fan-out's F7 variant keeps its key (only strings differ).
    @Test func shapeIdentities() throws {
        let world = try GoldenWorld()
        func shape(_ name: String) throws -> String { try capture(name: name, world: world).shape }
        let quickItem = try shape("sandboxed-work-quick-none-default-item")
        #expect(quickItem == (try shape("sandboxed-work-quick-none-default-itemless")))
        #expect(quickItem != (try shape("sandboxed-work-quick-none-custom-item")))
        let task = try shape("sandboxed-work-standard-task-default-item")
        #expect(task == (try shape("sandboxed-work-standard-task-f7-default-item")))
        #expect(task != (try shape("sandboxed-work-standard-none-default-item")))
        #expect(try shape("sandboxed-work-ultra-ultra-default-item") != (try shape("sandboxed-work-ultra-ultra-small-default-item")))
    }
}
