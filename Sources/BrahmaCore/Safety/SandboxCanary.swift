import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The installed `claude` as the sandbox canary keys it: its real path, size and modification time (a `stat`, no process).
/// A new CLI build (an update, a reinstall, a `touch`) is a new fingerprint and needs a new canary pass.
public struct CLIFingerprint: Equatable, Sendable {
    public var realPath: String
    public var size: Int64
    /// Nanoseconds since 1970.
    public var mtime: Int64

    public init(realPath: String, size: Int64, mtime: Int64) { self.realPath = realPath; self.size = size; self.mtime = mtime }

    public struct Unavailable: Error, Equatable, CustomStringConvertible {
        public var claudePath: String
        public var description: String { "can't find the claude CLI '\(Store.flat(claudePath, max: 300))' to fingerprint it" }
    }

    /// `claudePath` as given when it holds a `/`, else the first executable of that name on `PATH`; resolved, then `stat`ed.
    public static func of(claudePath: String, environment: [String: String] = ProcessInfo.processInfo.environment) throws -> CLIFingerprint {
        var candidate: String?
        if claudePath.contains("/") {
            candidate = claudePath
        } else {
            for dir in (environment["PATH"] ?? "/usr/bin:/bin").split(separator: ":") where !dir.isEmpty {
                let path = "\(dir)/\(claudePath)"
                if FileManager.default.isExecutableFile(atPath: path) { candidate = path; break }
            }
        }
        guard let candidate, let real = realpath(candidate, nil) else { throw Unavailable(claudePath: claudePath) }
        let resolved = String(cString: real)
        free(real)
        var st = stat()
        guard stat(resolved, &st) == 0 else { throw Unavailable(claudePath: claudePath) }
        #if canImport(Darwin)
        let m = st.st_mtimespec
        #else
        let m = st.st_mtim
        #endif
        return CLIFingerprint(realPath: resolved, size: Int64(st.st_size), mtime: Int64(m.tv_sec) * 1_000_000_000 + Int64(m.tv_nsec))
    }

    /// The `StableHash` of the fields: the `sandboxCanary.cliFingerprint` column.
    public var key: String { StableHash.fnv1a64("\(realPath)\u{0}\(size)\u{0}\(mtime)") }
}

/// Runs the sandbox canary for one settings shape: the doctor items `sandbox-backend`, `sandbox-canary` and `sandbox-helpers`.
/// The per-launch gate (`Orchestrator`) records a pass (`Store.recordCanary`) only when every item passes.
public protocol SandboxCanaryRunning: Sendable {
    func run(paths: BrahmaPaths, claudePath: String, runner: any TurnRunning, shape: String) async -> [DoctorItem]
}

/// The production canary. It builds a throwaway company under `paths.workspaces/.brahma-canary-<id>/`, plants tokens where no
/// turn may read (the owner's home, the data home, another company's workspace), and compiles the itemless turn the real
/// `SandboxScope.forTurn` and `ClaudeSettingsCompiler` produce (the pre-tool hook on), checking its settings deny all three.
/// `sandbox-backend` is model-free: the Seatbelt runner's `cat` of a token in the data home must fail.
///
/// TODO(Task 3, pending owner decision — see the progress ledger's ruling on the canary probe design): the agent-turn part
/// (a model turn under these settings, judged from its stream) is not built. Until the owner rules, `sandbox-canary` and
/// `sandbox-helpers` report a warning, nothing is recorded, and the per-launch gate keeps sandboxed agents from starting.
public struct SandboxCanary: SandboxCanaryRunning {
    public var environment: SandboxEnvironment
    /// Runs `sandbox-backend`; without one that item is a warning (skipped).
    public var sandbox: (any SandboxedRunner)?
    /// The `brahma` the canary turn's pre-tool hook names, as real turns do.
    public var hookExecutable: String

    public init(environment: SandboxEnvironment = .owner, sandbox: (any SandboxedRunner)? = nil, hookExecutable: String = "brahma") {
        self.environment = environment; self.sandbox = sandbox; self.hookExecutable = hookExecutable
    }

    /// The marker the `sandbox-canary` item carries while the agent-turn part waits for the owner.
    public static let pendingOwnerDecision = "pending owner decision"

    /// The canary's prepared turn: the request (scope, settings file, prefix), its compiled settings and what was planted.
    public struct Prepared: Sendable {
        public var request: TurnRequest
        public var settings: ClaudeSettings
        public var token: String
        /// The planted token files: the owner's home, the data home, another company's workspace.
        public var userHomeToken: URL
        public var dataHomeToken: URL
        public var otherCompanyToken: URL
        public var otherCompany: URL
        var removals: [URL]

        /// Removes everything the canary made (links are removed, never followed).
        public func cleanup() {
            for url in removals.reversed() { try? FileManager.default.removeItem(at: url) }
        }
    }

    /// Builds the throwaway company, plants the tokens and compiles the canary turn. Blocking (git, files). On a throw nothing
    /// is left behind.
    public static func prepare(paths: BrahmaPaths, environment: SandboxEnvironment, hookExecutable: String) throws -> Prepared {
        let fm = FileManager.default
        let id = String(UUID().uuidString.lowercased().prefix(8))
        let token = "BRAHMA-CANARY-\(UUID().uuidString)"
        let ws = paths.workspaces.appending(path: ".brahma-canary-\(id)", directoryHint: .isDirectory)
        let other = paths.workspaces.appending(path: ".brahma-canary-other-\(id)", directoryHint: .isDirectory)
        let homeDir = environment.userHome.appending(path: ".brahma-canary-\(id)", directoryHint: .isDirectory)
        let runDir = paths.runDir.appending(path: "canary-\(id)", directoryHint: .isDirectory)
        let agentId = "canary-\(id)"
        let settingsFile = SettingsFile.path(paths: paths, agentId: agentId)
        var removals = [ws, other, homeDir, runDir, settingsFile]
        do {
            for dir in [ws, other, homeDir] {
                guard !fm.fileExists(atPath: dir.path) else { throw DataHomeError(reason: "\(dir.path) already exists") }
                try fm.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            }
            try BrahmaPaths.ensurePrivateDirectory(runDir)
            func plant(_ dir: URL) throws -> URL {
                let url = dir.appending(path: "token")
                try SettingsFile.writePrivate(Data(token.utf8), to: url)
                return url
            }
            let userHomeToken = try plant(homeDir), dataHomeToken = try plant(runDir), otherToken = try plant(other)
            try GitWorkspace.initStandaloneRepository(at: ws)
            let company = Company(id: agentId, name: "Sandbox canary", slug: "brahma-canary-\(id)", goal: "sandbox canary",
                                  workspacePath: ws.path, status: .running, usageMode: .low, priorityWeight: 1, createdAt: Date())
            let agent = Agent(id: agentId, companyId: company.id, name: "canary", role: "engineer", model: "haiku",
                              sessionId: UUID().uuidString.lowercased(), sessionStarted: false, state: .running, blocker: nil,
                              requestedBlocker: nil, paused: false, readySince: nil, createdAt: Date())
            let layout = SandboxLayout(paths: paths, company: company, agentHandle: agent.name)
            try Sentinel.write(paths: paths)
            try layout.ensure()
            let prefix = try ShellPrefix.write(layout: layout, paths: paths, shell: environment.shell, keepNames: [])
            let scope = try SandboxScope.forTurn(layout: layout, paths: paths, otherWorkspaces: [other], backupTargets: [],
                                                 kind: .work, item: nil, company: company, grants: GrantInputs(),
                                                 darwinUserTemp: environment.darwinUserTemp, userHome: environment.userHome,
                                                 claudeTmpRoot: environment.claudeTmpRoot)
            if let tmp = scope.claudeTmp {
                try ClaudeTmp.ensure(tmp)
                removals.append(tmp)
            }
            let mcpConfig = runDir.appending(path: "empty.mcp.json")
            try SettingsFile.writePrivate(Data("{\"mcpServers\":{}}".utf8), to: mcpConfig)
            var request = TurnRequest(agent: agent, company: company, prompt: "", appendSystemPrompt: nil,
                                      mcpConfigPath: mcpConfig.path, workingDirectory: scope.cwd.path, profile: .sandboxed,
                                      environment: ["BRAHMA_AGENT_ID": agent.id, "BRAHMA_HOME": paths.home.path,
                                                    "BRAHMA_WORKSPACES": paths.workspaces.path])
            request.sandbox = scope
            request.addDirs = scope.readOnlyDirs.map(\.path)
            request.shellPrefix = prefix.path
            request.containmentMarker = TurnProfileCompiler.containmentMarkerPrefix + UUID().uuidString.lowercased()
            request.settingsFilePath = settingsFile.path
            request.turnRecordDirectory = runDir.appending(path: "turns", directoryHint: .isDirectory)
            request.mode = ModeCanary.shapes().first?.1
            request.hookExecutable = hookExecutable
            request.emitRawLines = true
            let profile = TurnProfileCompiler.profile(for: request)
            try TurnProfileCompiler.validate(profile)
            try SettingsFile.write(try TurnProfileCompiler.settingsJSON(profile), to: settingsFile)
            return Prepared(request: request, settings: profile.settings, token: token, userHomeToken: userHomeToken,
                            dataHomeToken: dataHomeToken, otherCompanyToken: otherToken, otherCompany: other, removals: removals)
        } catch {
            for url in removals.reversed() { try? fm.removeItem(at: url) }
            throw error
        }
    }

    /// Whether the compiled settings deny reading the owner's home, the data home and the other company's workspace.
    static func missingDenies(_ prepared: Prepared, paths: BrahmaPaths, environment: SandboxEnvironment) -> [String] {
        let denied = Set((prepared.settings.sandbox?.filesystem?.denyRead ?? []).map(SandboxPath.key))
        return [("the owner's home", environment.userHome), ("the data home", paths.home), ("another company's workspace", prepared.otherCompany)]
            .filter { !denied.contains(SandboxPath.key($0.1.path)) && !denied.contains(SandboxPath.key($0.1.resolvedForSandbox.path)) }
            .map(\.0)
    }

    public func run(paths: BrahmaPaths, claudePath: String, runner: any TurnRunning, shape: String) async -> [DoctorItem] {
        let env = environment, hook = hookExecutable
        let prepared: Result<Prepared, any Error> = await Doctor.execBlocking.run {
            Result { try Self.prepare(paths: paths, environment: env, hookExecutable: hook) }
        }
        var items: [DoctorItem] = []
        switch prepared {
        case .failure(let error):
            items.append(DoctorItem(name: "sandbox-backend", status: .fail, detail: "the canary could not be set up: \(Store.flat("\(error)", max: 300))"))
            items.append(DoctorItem(name: "sandbox-canary", status: .fail, detail: "the canary turn could not be built: \(Store.flat("\(error)", max: 300))"))
        case .success(let p):
            items.append(await Self.backendItem(token: p.dataHomeToken, secret: p.token, sandbox: sandbox))
            let missing = Self.missingDenies(p, paths: paths, environment: env)
            if !missing.isEmpty {
                items.append(DoctorItem(name: "sandbox-canary", status: .fail,
                                        detail: "the compiled settings do not deny reading \(missing.joined(separator: ", "))"))
            } else {
                // TODO(Task 3, pending owner decision): the agent-turn part goes here once the owner has ruled (ledger).
                items.append(DoctorItem(name: "sandbox-canary", status: .warn,
                                        detail: "\(Self.pendingOwnerDecision): the canary scope and settings check out; the turn under them "
                                            + "is not run yet, so sandboxed agents do not start"))
            }
            await Doctor.execBlocking.run { p.cleanup() }
        }
        items.append(DoctorItem(name: "sandbox-helpers", status: .warn, detail: "not checked: \(Self.pendingOwnerDecision)"))
        return items
    }

    /// `sandbox-backend`: the sandboxed runner's `cat` of the planted data-home token fails and prints nothing of it. No model.
    static func backendItem(token: URL, secret: String, sandbox: (any SandboxedRunner)?) async -> DoctorItem {
        let name = "sandbox-backend"
        guard let sandbox else { return DoctorItem(name: name, status: .warn, detail: "skipped: no sandboxed runner") }
        guard !SandboxPath.isUnsafe(token.path) else { return DoctorItem(name: name, status: .fail, detail: "the token path can't be quoted") }
        let scratch = FileManager.default.temporaryDirectory.appending(path: "brahma-doctor-backend-\(UUID().uuidString)", directoryHint: .isDirectory)
        defer { try? FileManager.default.removeItem(at: scratch) }
        do { try BrahmaPaths.ensurePrivateDirectory(scratch) } catch {
            return DoctorItem(name: name, status: .fail, detail: "can't prepare a scratch directory: \(error)")
        }
        let cwd = scratch.resolvedForSandbox
        let out = await sandbox.run(command: "/bin/cat '\(token.path)'", cwd: cwd,
                                    environment: ChildEnvironment.make(base: ProcessInfo.processInfo.environment, purpose: .general),
                                    timeout: .seconds(30), outputURL: cwd.appending(path: "out.log"),
                                    policy: SandboxPolicy(writable: [cwd], readable: [], network: .none, toolchain: false))
        if out.tail.contains(secret) || out.exitCode == 0 {
            return DoctorItem(name: name, status: .fail, detail: "a sandboxed command read a file in the data home: the sandbox does not hold")
        }
        guard out.exitCode != nil else {
            return DoctorItem(name: name, status: .fail, detail: "the sandboxed command could not run: \(Store.flat(out.tail, max: 200))")
        }
        return DoctorItem(name: name, status: .pass, detail: "a sandboxed cat of a file in the data home was refused")
    }
}
