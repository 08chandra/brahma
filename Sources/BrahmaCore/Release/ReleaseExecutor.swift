import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// What the release executor runs through (`Orchestrator.init(releaseDeps:)`): the platform sandbox (every tools and deploy
/// step, always: PR-5), the runner a Full company's build uses (as its checks run), the HTTP probe of the deployed site, the
/// adapter lookup (PR-25), the wait between smoke rounds, and the environment every step's is built from.
public struct ReleaseDependencies: Sendable {
    public var sandbox: any SandboxedRunner
    public var unsandboxed: any SandboxedRunner
    public var http: any HTTPProbing
    public var adapters: HostingAdapters.Lookup
    public var sleep: @Sendable (Duration) async -> Void
    /// Nil: the engine's check environment (`Orchestrator.checkBaseEnvironment`).
    public var environment: [String: String]?

    public init(sandbox: any SandboxedRunner, unsandboxed: any SandboxedRunner = UnsandboxedPreviewRunner(),
                http: any HTTPProbing = URLSessionHTTPProbe(), adapters: @escaping HostingAdapters.Lookup = HostingAdapters.production,
                sleep: @escaping @Sendable (Duration) async -> Void = { try? await AwakeTime.sleep(for: $0) },
                environment: [String: String]? = nil) {
        self.sandbox = sandbox; self.unsandboxed = unsandboxed; self.http = http; self.adapters = adapters; self.sleep = sleep
        self.environment = environment
    }
}

/// Carries out an owner-approved deploy exactly once (Plan L Task 7; spec §6.26 "the engine performs exactly the approved
/// payload, once"). Only this actor moves a release past `approved`.
///
/// `advance` claims the company's oldest approved release in one write (`Store.claimRelease`, the first statement, no await
/// before it; an in-flight set keeps a second caller out), then, each status change committed before the next side effect:
/// 1. **Smoke on main**: the commit must still be on the engine-accepted main (`merge-base --is-ancestor`), then the company's
///    smoke check runs at the commit (`Orchestrator.runSmoke`'s path, reason `release`, the company's smoke slot).
/// 2. **Integrity**: the deploy plan is rendered again from the release's stored build, output folder, commit and version and
///    the current hosting settings; anything but the stored plan and `commandsHash` refuses ("propose again").
/// 3. **Backup**: `refs/brahma/main-backup` and `refs/brahma/releases/<version>` (PR-29) name the commit.
/// 4. **Build**: a fresh `.git`-free export of the commit (`EngineExport`, under the data home); the stored build runs there
///    with no secret, writing only the export (a check-shaped policy, PR-5, no shared cache, PR-19).
/// 5. **Stage**: `UploadStager` copies the plan's folders into the release's engine-only `upload/`.
/// 6. **Tools**: the pinned provider CLI is installed token-free into `ReleaseLayout.deployTools(cli:)` when missing (PR-8).
/// 7. **Deploy** (`deploying`): every plan step, engine-composed argv, under the sandbox only (fail closed), the token only in
///    its environment, after `ProviderConfigCheck` (I3); the deploy URL from the deploy step's stdout only, confirmed by the
///    plan's verify step when it has one (Vercel).
/// 8. **Smoke** (`smoking`): `DeploySmoke` against the adapter's smoke base.
/// 9. **Finish**: `deployed` or `failed` (a P1 bug, the owner told), through `Store.finishRelease`.
///
/// Every build, tools and deploy step is killable (`runStep`: spawned, recorded, polled, its group terminated on a timeout
/// or the owner's stop). Raw output stays under the data home (`ReleaseLayout`); only the redacted copy of `deploy.log` (and
/// `build.log`) goes to `<ws>/.brahma/releases/R-<n>/` (PR-7). The owner's stop (`stopAll`) ends the running step: a release
/// that was `deploying` is `interrupted` and never runs again; one `building` or `smoking` is `failed`.
public actor ReleaseExecutor: EmergencyStopObserver {
    /// The release smoke: `(companyId, commit, reason, releaseId, acceptedMain)` → the recorded run.
    public typealias Smoke = @Sendable (String, String, MainSmokeReason, String?, String?) async throws -> MainSmokeRun

    let store: Store
    let paths: BrahmaPaths
    let sandbox: any SandboxedRunner
    let unsandboxed: any SandboxedRunner
    let vault: any SecretVault
    let http: any HTTPProbing
    let smoke: Smoke
    let adapters: HostingAdapters.Lookup
    let sleep: @Sendable (Duration) async -> Void
    let clock: @Sendable () -> Date
    let blocking: Blocking
    let environment: [String: String]
    /// How often a running step's exit, timeout and stop are looked at.
    let stepPoll: Duration
    /// Every step process running now, by pid (the L process registry, PR-4).
    public nonisolated let processes = SpawnedProcesses()

    /// Companies whose release this actor is carrying out (a second `advance` for one of them returns at once).
    private var inFlight = Set<String>()
    /// Release id → its company, while it is carried out.
    private var active: [String: String] = [:]
    /// Release id → why it must stop (`stopAll`).
    private var stops: [String: String] = [:]
    /// Release id → the process of its running step.
    private var running: [String: any SandboxedProcess] = [:]

    public init(store: Store, paths: BrahmaPaths, sandbox: any SandboxedRunner, unsandboxed: any SandboxedRunner = UnsandboxedPreviewRunner(),
                vault: any SecretVault, http: any HTTPProbing, smoke: @escaping Smoke,
                adapters: @escaping HostingAdapters.Lookup = HostingAdapters.adapter,
                sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                clock: @escaping @Sendable () -> Date = Store.now,
                environment: [String: String] = ProcessInfo.processInfo.environment) {
        self.init(store: store, paths: paths, sandbox: sandbox, unsandboxed: unsandboxed, vault: vault, http: http, smoke: smoke,
                  adapters: adapters, sleep: sleep, clock: clock, blocking: Blocking(), environment: environment)
    }

    init(store: Store, paths: BrahmaPaths, sandbox: any SandboxedRunner, unsandboxed: any SandboxedRunner, vault: any SecretVault,
         http: any HTTPProbing, smoke: @escaping Smoke, adapters: @escaping HostingAdapters.Lookup,
         sleep: @escaping @Sendable (Duration) async -> Void, clock: @escaping @Sendable () -> Date, blocking: Blocking,
         environment: [String: String], stepPoll: Duration = .milliseconds(200)) {
        self.store = store; self.paths = paths; self.sandbox = sandbox; self.unsandboxed = unsandboxed
        self.vault = vault.nonInteractive(); self.http = http; self.smoke = smoke; self.adapters = adapters; self.sleep = sleep
        self.clock = clock; self.blocking = blocking; self.environment = environment; self.stepPoll = stepPoll
    }

    /// The export run id of a release's build: `rel-<release id>` (a valid 3a run id, unique across companies).
    public static func exportRunId(_ release: Release) -> String { "rel-\(release.id)" }

    // MARK: Claiming

    /// Every company with an approved release, one after the other (the tick runs `advance(companyId:now:)` per company).
    public func advance(now: Date) async {
        for companyId in ((try? store.companiesWithApprovedRelease()) ?? []).sorted() {
            await advance(companyId: companyId, now: now)
        }
    }

    /// Claims and carries out the company's oldest approved release, if any. The in-flight check and insert, then the claim
    /// (the first database transaction, conditional on `approved`; nothing while the owner's stop holds), with no await
    /// between them (builder-check 3, PR-9).
    public func advance(companyId: String, now: Date) async {
        guard inFlight.insert(companyId).inserted else { return }
        defer { inFlight.remove(companyId) }
        let claimed: Release?
        do { claimed = try store.claimRelease(companyId: companyId, now: now) } catch {
            log("could not claim a release of \(companyId): \(error)")
            return
        }
        guard let release = claimed else { return }
        await carryOut(release)
    }

    // MARK: The owner's stop

    /// Every release in progress stops: its running step's group is terminated (SIGTERM, then SIGKILL after
    /// `EmergencyStop.grace`), and the release records `interrupted` (it was deploying) or `failed`. Claims stop too while
    /// the stop holds (`Store.claimRelease`).
    public func stopAll(reason: String) async {
        for id in active.keys { stops[id] = reason }
        for process in running.values { await process.terminate(grace: .seconds(EmergencyStop.grace)) }
    }

    private func stopReason(_ releaseId: String) -> String? {
        if let reason = stops[releaseId] { return reason }
        if Task.isCancelled { return ReleasePolicy.engineStopped }
        if let row = try? store.engineStopped() { return "stopped by the owner" + (row.note.map { ": \($0)" } ?? "") }
        return nil
    }

    private struct Stopped: Error { let reason: String }

    private struct Failure: Error {
        let stage: String, detail: String, reason: String
        var results: [SmokeResult]? = nil
    }

    private func checkStop(_ release: Release) throws {
        if let reason = stopReason(release.id) { throw Stopped(reason: reason) }
    }

    // MARK: Carrying it out

    private func carryOut(_ release: Release) async {
        active[release.id] = release.companyId
        let end: ReleaseEnd
        do { end = try await deploy(release) } catch let s as Stopped {
            end = .stopped(reason: s.reason)
        } catch let f as Failure {
            end = .failed(stage: f.stage, detail: f.detail, reason: f.reason, results: f.results)
        } catch {
            end = .failed(stage: "release", detail: "engine error", reason: "the engine could not carry out the release: \(error)", results: nil)
        }
        await cleanUp(release)
        do { try store.finishRelease(id: release.id, end: end, now: clock()) } catch {
            log("could not record the end of \(release.ref) of \(release.companyId): \(error)")
        }
        active[release.id] = nil
        stops[release.id] = nil
        running[release.id] = nil
    }

    /// The export goes, and the release's HOME (anything a provider CLI kept there); `upload/` stays (what a rollback to this
    /// release deploys again). Never throws.
    private func cleanUp(_ release: Release) async {
        let store = self.store
        guard let company = try? store.company(id: release.companyId), let layout = try? store.releaseLayout(companyId: release.companyId) else { return }
        let runId = Self.exportRunId(release)
        let home = layout.releaseDir(release.number).appending(path: "home", directoryHint: .isDirectory)
        await blocking.run {
            EngineExport.remove(store: store, company: company, runId: runId)
            _ = try? EngineFiles.removeNoFollow(home, under: layout.root)
        }
    }

    private func deploy(_ r: Release) async throws -> ReleaseEnd {
        let store = self.store
        guard let company = try store.company(id: r.companyId) else {
            throw Failure(stage: "release", detail: "no company", reason: "the company is gone")
        }
        let ws = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        let adapter = adapters(r.provider)
        let layout = try store.releaseLayout(companyId: r.companyId)
        let releaseDir = layout.releaseDir(r.number)
        let home = releaseDir.appending(path: "home", directoryHint: .isDirectory)
        let upload = releaseDir.appending(path: "upload", directoryHint: .isDirectory)
        let logs = EngineLogs(store: store, workspace: ws, releaseDir: releaseDir, number: r.number, blocking: blocking)

        // 1. On main, then the smoke check at the commit (builder-check 7).
        guard let main = company.mainCommit else {
            throw Failure(stage: "smoke on main", detail: "not on main", reason: "\(r.ref)'s commit is no longer on main")
        }
        let commit = r.commit
        let onMain = await blocking.run {
            (try? store.gitWorkspace(root: ws, companyId: company.id).isAncestor(commit, of: main)) ?? false
        }
        guard onMain else { throw Failure(stage: "smoke on main", detail: "not on main", reason: "\(r.ref)'s commit is no longer on main") }
        try checkStop(r)
        let run: MainSmokeRun
        do { run = try await smoke(r.companyId, r.commit, .release, r.id, main) } catch {
            throw Failure(stage: "smoke on main", detail: "did not run",
                          reason: "the smoke check could not run at \(r.sha7) just before deploying (\(Self.text(error)))")
        }
        try checkStop(r)
        switch run.status {
        case .passed: break
        case .failed: throw Failure(stage: "smoke on main", detail: run.failure, reason: "the smoke check failed at \(r.sha7) just before deploying")
        default: throw Failure(stage: "smoke on main", detail: "no result",
                               reason: "the smoke check could not run at \(r.sha7) just before deploying (\(Store.flat(run.outputTail ?? "no result", max: 200)))")
        }

        // 2. Integrity: exactly the approved commands, rendered again from the stored release.
        guard var settings = try store.hosting(companyId: r.companyId) else { throw Self.mismatch }
        let rendered: DeployPlan
        do { rendered = try await blocking.tryRun { try Self.renderPlan(store: store, release: r, adapter: adapter, layout: layout) } } catch {
            throw Self.mismatch
        }
        guard rendered == r.plan, rendered.hash == r.commandsHash, r.plan.hashIsCurrent, r.plan.build == r.build,
              r.plan.outputDir == r.outputDir else { throw Self.mismatch }
        let plan = r.plan
        settings.build = r.build
        settings.outputDir = r.outputDir

        // 3. Backup refs (PR-1, PR-29), from engine records only.
        do {
            let version = r.version
            _ = try await blocking.tryRun { try store.gitWorkspace(root: ws, companyId: company.id).writeReleaseRefs(version: version, commit: commit) }
        } catch {
            throw Failure(stage: "backup", detail: "git", reason: "could not write the backup refs (\(Self.text(error)))")
        }
        try store.advanceRelease(id: r.id, from: .building, to: .building, now: clock()) { $0.backupRef = GitWorkspace.mainBackupRef }
        try checkStop(r)

        // 4. Build, in a fresh export, with no secret.
        let runId = Self.exportRunId(r)
        let number = r.number
        let export: URL
        do {
            export = try await blocking.tryRun {
                try BrahmaPaths.ensurePrivateDirectory(layout.root)
                try EngineFiles.remove(workspace: layout.root, dir: "", name: "R-\(number)")   // an earlier engine's leftovers
                try EngineFiles.directory(workspace: layout.root, "R-\(number)", mode: 0o700)
                try EngineFiles.directory(workspace: layout.root, "R-\(number)/home", mode: 0o700)
                return try EngineExport.export(store: store, company: company, runId: runId, commit: commit)
            }
        } catch {
            throw Failure(stage: "build", detail: "export", reason: "could not export \(r.sha7) (\(Self.text(error)))")
        }
        let toolEnvironment = ChildEnvironment.make(base: environment, extra: ["BRAHMA_AGENT_ID": "release"], purpose: .check)
        if let build = r.build {
            let full = PreviewRunner.unsandboxed(store: store, company: company, setById: r.proposedById)
            let log = releaseDir.appending(path: "build.log", directoryHint: .notDirectory)
            let outcome = await runStep(r, runner: full ? unsandboxed : sandbox, command: build, cwd: export, environment: toolEnvironment,
                                        policy: Store.smokePolicy(company: company, export: export), timeout: ReleasePolicy.buildTimeout,
                                        log: log)
            let tail = await logs.publish(raw: [log], as: "build.log", header: nil).tail
            switch outcome {
            case .stopped(let reason): throw Stopped(reason: reason)
            case .unavailable: throw Failure(stage: "build", detail: "sandbox unavailable", reason: "sandbox unavailable")
            case .couldNotStart(let why): throw Failure(stage: "build", detail: "could not start", reason: "the build could not start (\(why))")
            case .finished(let exit, let timedOut):
                if timedOut || exit != 0 {
                    _ = try? store.advanceRelease(id: r.id, from: .building, to: .building, now: clock()) { $0.outputTail = tail }
                    let detail = timedOut ? "timed out" : "exit \(exit)"
                    throw Failure(stage: "build", detail: detail, reason: "build failed (\(detail))")
                }
            }
        }

        // 5. Stage the upload.
        do {
            let dirs = plan.stageFrom
            try await blocking.tryRun {
                defer { EngineExport.remove(store: store, company: company, runId: runId) }
                try UploadStager.stage(from: export, dirs: dirs, into: upload)
            }
        } catch let e as ReleaseError {
            throw Failure(stage: "stage", detail: e.message, reason: e.message)
        } catch {
            throw Failure(stage: "stage", detail: "could not stage", reason: "could not stage the upload (\(Self.text(error)))")
        }
        try checkStop(r)

        // 6. The provider CLI, token-free, into the engine-only tools folder (PR-8: per-run caches, no npx, no shared cache).
        let tools = layout.deployTools(cli: adapter.cli)
        let bin = tools.appending(path: "node_modules/.bin/\(adapter.cliBin)", directoryHint: .notDirectory)
        if !Self.exists(bin) {
            let cli = adapter.cli
            do {
                try await blocking.tryRun {
                    try BrahmaPaths.ensurePrivateDirectory(layout.root.appending(path: "tools", directoryHint: .isDirectory))
                    try EngineFiles.directory(workspace: layout.root, "tools/\(cli)", mode: 0o700)
                }
            } catch { throw Failure(stage: "tools", detail: "folder", reason: "the tools folder is not safe to use (\(Self.text(error)))") }
            let resolved = URL(fileURLWithPath: SandboxPath.resolve(tools.path), isDirectory: true)
            var env = toolEnvironment
            env["HOME"] = home.path
            let log = releaseDir.appending(path: "tools.log", directoryHint: .notDirectory)
            let outcome = await runStep(r, runner: sandbox,
                                        command: ShellQuote.joinArgv(["npm", "install", "--prefix", tools.path, "--no-audit", "--no-fund", cli], rawRefs: []),
                                        cwd: tools, environment: env,
                                        policy: SandboxPolicy(writable: [resolved], readable: [resolved], network: .outbound(allow: adapter.toolNetwork),
                                                              toolchain: true),
                                        timeout: ReleasePolicy.stepTimeout, log: log)
            await blocking.run { _ = try? EngineFiles.removeNoFollow(tools.appending(path: ".brahma-tmp"), under: layout.root) }
            _ = await logs.publish(raw: [log], as: "tools.log", header: nil)
            switch outcome {
            case .stopped(let reason): throw Stopped(reason: reason)
            case .unavailable: throw Failure(stage: "tools", detail: "sandbox unavailable", reason: "sandbox unavailable")
            case .couldNotStart(let why): throw Failure(stage: "tools", detail: "could not start", reason: "installing \(cli) could not start (\(why))")
            case .finished(let exit, let timedOut):
                if timedOut || exit != 0 {
                    let detail = timedOut ? "timed out" : "exit \(exit)"
                    throw Failure(stage: "tools", detail: detail, reason: "installing \(cli) failed (\(detail))")
                }
            }
            guard Self.exists(bin) else {
                throw Failure(stage: "tools", detail: "not installed", reason: "installing \(cli) did not provide \(adapter.cliBin)")
            }
        }
        try checkStop(r)

        // 7. Deploy: `deploying` is committed before any step runs.
        try store.advanceRelease(id: r.id, from: .building, to: .deploying, now: clock())
        let (companyId, secret) = (r.companyId, plan.tokenSecret)
        let vault = self.vault
        let token: String? = await blocking.run { try? vault.value(companyId: companyId, name: secret) }
        guard let token, !token.isEmpty else {
            throw Failure(stage: "deploy", detail: "no token", reason: "the provider token \(secret) could not be read")
        }
        guard ChildEnvironment.droppedSecretNames([secret: token]).isEmpty else {
            throw Failure(stage: "deploy", detail: "token name", reason: "the provider token \(secret) cannot be passed to a deploy step")
        }
        let deployStep = plan.steps.lastIndex { $0.label == "deploy" } ?? (plan.steps.count - 1)
        var deployStdout = ""
        var tail = ""
        for (i, step) in plan.steps.enumerated() {
            let result = try await tokenStep(r, argv: step.argv, index: i, plan: plan, adapter: adapter, token: token, layout: layout,
                                             home: home, tools: tools, logs: logs)
            tail = result.tail
            switch result.outcome {
            case .stopped(let reason): throw Stopped(reason: reason)
            case .unavailable: throw Failure(stage: "deploy", detail: "sandbox unavailable", reason: "sandbox unavailable")
            case .couldNotStart(let why): throw Failure(stage: "deploy", detail: "could not start", reason: "the \(step.label) step could not start (\(why))")
            case .finished(let exit, let timedOut):
                let tolerated = step.okIfOutputContains.map { result.stdout.contains($0) || result.stderr.contains($0) } ?? false
                if timedOut || (exit != 0 && !tolerated) {
                    let failedTail = result.tail
                    _ = try? store.advanceRelease(id: r.id, from: .deploying, to: .deploying, now: clock()) { $0.outputTail = failedTail }
                    let detail = timedOut ? "timed out" : "exit \(exit)"
                    throw Failure(stage: "deploy", detail: detail, reason: "the \(step.label) step failed (\(detail))")
                }
            }
            if i == deployStep { deployStdout = result.stdout }
        }
        // The deploy URL from the deploy step's stdout only (never stderr or a build's streamed log), confirmed with the
        // deploy's own token when the plan says how (Vercel).
        let deployURL = adapter.deployURL(fromOutput: deployStdout, settings: settings)
        if let url = deployURL, let argv = plan.verifyArgv(url: url) {
            let result = try await tokenStep(r, argv: argv, index: plan.steps.count, plan: plan, adapter: adapter, token: token,
                                             layout: layout, home: home, tools: tools, logs: logs)
            tail = result.tail
            switch result.outcome {
            case .stopped(let reason): throw Stopped(reason: reason)
            case .unavailable: throw Failure(stage: "deploy", detail: "sandbox unavailable", reason: "sandbox unavailable")
            case .couldNotStart, .finished:
                guard case .finished(exit: 0, timedOut: false) = result.outcome,
                      adapter.verifiesDeployment(output: result.stdout + "\n" + result.stderr, settings: settings) else {
                    throw Failure(stage: "deploy", detail: "unverified deploy URL",
                                  reason: "the deploy URL \(url.absoluteString) is not a deployment of \(settings.project)")
                }
            }
        }

        // 8. Smoke the site.
        let finalTail = tail
        try store.advanceRelease(id: r.id, from: .deploying, to: .smoking, now: clock()) {
            $0.deployURL = deployURL?.absoluteString
            $0.outputTail = finalTail
        }
        guard let base = adapter.smokeBase(settings, deployURL: deployURL) else {
            throw Failure(stage: "smoke", detail: "no deploy URL",
                          reason: "no deploy URL was found in the deploy output and no production URL is set")
        }
        try checkStop(r)
        let smoked = await DeploySmoke.run(base: base, requests: settings.smoke, expectText: settings.expectText, http: http, sleep: sleep)
        try checkStop(r)
        var results = smoked.results
        // The custom domain is recorded, never gating: DNS may still be on its way.
        if let domain = settings.customDomain, let custom = URL(string: "https://\(domain)") {
            results.append(await DeploySmoke.probe(base: custom, request: SmokeRequest(method: "GET", path: "/"), expectText: nil, http: http))
        }
        guard smoked.ok else {
            let first = smoked.results.first { !$0.ok }
            let path = first.flatMap { URL(string: $0.url)?.path }.map { $0.isEmpty ? "/" : $0 } ?? "/"
            let detail = first.map { "\($0.method) \(path): \($0.error ?? $0.status.map { "status \($0)" } ?? "no response")" } ?? "no result"
            throw Failure(stage: "smoke", detail: Store.flat(detail, max: 120),
                          reason: "the deployed site failed its smoke check (\(Store.flat(detail, max: 120)))", results: results)
        }
        return .deployed(productionURL: settings.productionURL ?? base.absoluteString, results: results)
    }

    private static let mismatch = Failure(stage: "integrity", detail: "the hosting settings or the stored plan changed since approval",
                                  reason: "the approved commands no longer match; propose again")

    // MARK: Plans

    /// The deploy plan of `release` rendered again (carried-forward ruling 2): from the same data-home `ReleaseLayout` the
    /// proposal used, the release's stored build, output folder, commit, version and number, its previous release's upload
    /// and deploy URL, whether the commit has `functions/` (PR-24), and the current hosting settings (an owner change of the
    /// account or project after approval makes it differ: fail closed). Runs git (blocking).
    static func renderPlan(store: Store, release r: Release, adapter: any HostingAdapter, layout: ReleaseLayout? = nil) throws -> DeployPlan {
        guard var settings = try store.hosting(companyId: r.companyId), settings.provider == r.provider, adapter.id == r.provider,
              let company = try store.company(id: r.companyId) else {
            throw WorkError.invalid("the hosting settings changed")
        }
        settings.build = r.build
        settings.outputDir = r.outputDir
        let layout = try layout ?? store.releaseLayout(companyId: r.companyId)
        let previous = try r.previousReleaseId.flatMap { id in try store.writer.read { try Release.fetchOne($0, key: id) } }
        let functions = try store.gitWorkspace(root: URL(fileURLWithPath: company.workspacePath, isDirectory: true), companyId: company.id)
            .treeHasDirectory(at: r.commit, path: "functions")
        let input = DeployInput(settings: settings, commit: r.commit, version: r.version, layout: layout, release: r.number, cli: adapter.cli,
                                previousUpload: previous.map { layout.releaseDir($0.number).appending(path: "upload", directoryHint: .isDirectory) },
                                previousDeployURL: previous?.deployURL, functionsInCommit: functions)
        return try adapter.deployPlan(input)
    }

    // MARK: Steps

    enum StepOutcome: Equatable, Sendable {
        case finished(exit: Int32, timedOut: Bool)
        case stopped(String)
        /// `SandboxError.unavailable`: no sandbox on this machine (fail closed, PR-5).
        case unavailable
        case couldNotStart(String)
    }

    /// One killable step (chief review L5): spawned through `runner`, recorded (`processes`, and `ChildGroups` kind
    /// `release` so `brahma stop` reaches it without the engine), its exit polled every `stepPoll`, its whole group
    /// terminated on `timeout` (awake time) or the owner's stop, and waited for until it is reaped.
    private func runStep(_ r: Release, runner: any SandboxedRunner, command: String, cwd: URL, environment: [String: String],
                         policy: SandboxPolicy, timeout: Duration, log: URL) async -> StepOutcome {
        if let reason = stopReason(r.id) { return .stopped(reason) }
        let process: any SandboxedProcess
        do { process = try runner.spawn(command: command, cwd: cwd, environment: environment, logURL: log, policy: policy) } catch {
            if case SandboxError.unavailable = error { return .unavailable }
            return .couldNotStart(Self.text(error))
        }
        processes.insert(process)
        running[r.id] = process
        let groups = ChildGroups(dir: ChildGroups.directory(runDir: paths.runDir), kind: "release")
        let record = groups.record(process.pid)
        let deadline = AwakeTime.deadline(after: timeout)
        var timedOut = false
        var stopped: String?
        while process.exitStatus() == nil {
            if let reason = stopReason(r.id) { stopped = reason; break }
            if AwakeTime.now >= deadline { timedOut = true; break }
            try? await AwakeTime.sleep(for: stepPoll)
        }
        await process.terminate(grace: .seconds(EmergencyStop.grace))
        groups.forget(record, pid: process.pid)
        processes.remove(process.pid)
        running[r.id] = nil
        // A stop that ended the process itself (`stopAll`, or `brahma stop` signalling the recorded group) is still a stop,
        // not the step's own exit.
        if let reason = stopped ?? stopReason(r.id) { return .stopped(reason) }
        return .finished(exit: process.exitStatus() ?? -1, timedOut: timedOut)
    }

    struct TokenStepResult {
        var outcome: StepOutcome
        /// Redacted.
        var stdout: String
        var stderr: String
        /// The end of the release's redacted deploy log.
        var tail: String
    }

    /// A token-holding step (deploy, verify): the provider config check first (I3), then `argv` (engine-composed, the token
    /// never in it, PR-11) under the sandbox only, with the token only in its environment. Its stdout goes to an engine-only
    /// file under the data home and its stderr to a file of its own, so the deploy URL is read from stdout alone.
    private func tokenStep(_ r: Release, argv: [String], index: Int, plan: DeployPlan, adapter: any HostingAdapter, token: String,
                           layout: ReleaseLayout, home: URL, tools: URL, logs: EngineLogs) async throws -> TokenStepResult {
        try checkStop(r)
        do { try adapter.refuseProviderConfig(plan, releaseRoot: layout.root) } catch {
            let why = (error as? WorkError)?.message ?? Self.text(error)
            throw Failure(stage: "deploy", detail: "provider config", reason: why)
        }
        let releaseDir = layout.releaseDir(r.number)
        let stdout = releaseDir.appending(path: "step-\(index).out", directoryHint: .notDirectory)
        let stderr = home.appending(path: "step-\(index).err", directoryHint: .notDirectory)
        let cwd = URL(fileURLWithPath: plan.cwdPath, isDirectory: true)
        func real(_ url: URL) -> URL { URL(fileURLWithPath: SandboxPath.resolve(url.path), isDirectory: true) }
        var env = ChildEnvironment.make(base: environment, extra: ["BRAHMA_AGENT_ID": "release"], purpose: .check,
                                        secrets: [plan.tokenSecret: token])
        env["HOME"] = home.path
        for (name, value) in plan.env where name != plan.tokenSecret { env[name] = value }
        let command = ShellQuote.joinArgv(argv, rawRefs: []) + " 2>>" + ShellQuote.quote(stderr.path)
        let outcome = await runStep(r, runner: sandbox, command: command, cwd: cwd, environment: env,
                                    policy: SandboxPolicy(writable: [real(home), real(cwd)], readable: [real(cwd), real(tools)],
                                                          network: .outbound(allow: plan.network), toolchain: true),
                                    timeout: ReleasePolicy.stepTimeout, log: stdout)
        let header = "$ " + ShellQuote.joinArgv(argv, rawRefs: [plan.tokenSecret])
        let published = await logs.publish(raw: [stdout, stderr], as: "deploy.log", header: header)
        return TokenStepResult(outcome: outcome, stdout: published.parts[0], stderr: published.parts[1], tail: published.tail)
    }

    // MARK: Helpers

    static func exists(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0
    }

    static func text(_ error: any Error) -> String {
        Store.flat((error as? WorkError)?.message ?? "\(error)", max: 300)
    }

    private func log(_ line: String) {
        FileHandle.standardError.write(Data("brahma release: \(line)\n".utf8))
    }
}

/// A release's logs (PR-7): each step's raw output lands in engine-only files under the data home, is scrubbed of every
/// secret in place right after the step, then appended to the release's `deploy.log` (or `build.log`, `tools.log`) under the
/// data home, and that redacted log is copied to `<ws>/.brahma/releases/R-<n>/` for the owner and agents to read. A file
/// that cannot be scrubbed is removed and its text withheld. All file work runs in the engine's `Blocking`.
final class EngineLogs: @unchecked Sendable {
    let store: Store
    let workspace: URL
    let releaseDir: URL
    let number: Int
    let blocking: Blocking
    private let lock = NSLock()
    private var texts: [String: String] = [:]
    static let readLimit = 2 << 20
    static let tailChars = 4000

    init(store: Store, workspace: URL, releaseDir: URL, number: Int, blocking: Blocking) {
        self.store = store; self.workspace = workspace; self.releaseDir = releaseDir; self.number = number; self.blocking = blocking
    }

    /// Scrubs, reads and removes each of `raw`; appends `header` and their text to the log `name`, writes that log under the
    /// data home and its copy to the workspace. Returns each file's redacted text and the redacted end of the whole log.
    func publish(raw: [URL], as name: String, header: String?) async -> (parts: [String], tail: String) {
        await blocking.run { [self] in
            let parts = raw.map { url -> String in
                defer { _ = try? EngineFiles.removeNoFollow(url, under: releaseDir) }
                return Self.scrubbedText(url, under: releaseDir, store: store)
            }
            var added = header.map { $0 + "\n" } ?? ""
            for part in parts where !part.isEmpty { added += part.hasSuffix("\n") ? part : part + "\n" }
            let whole = lock.withLock { () -> String in
                texts[name, default: ""] += added
                return texts[name] ?? ""
            }
            let local = releaseDir.appending(path: name, directoryHint: .notDirectory)
            // Assembled from scrubbed parts, and scrubbed once more as a whole (`Redactor.scrubFile`) before it is copied.
            do {
                try EngineFiles.replace(Data(whole.utf8), workspace: releaseDir, dir: "", name: name)
                if store.scrubOrRemoveSmokeLog(local), let clean = EngineFiles.readNoFollow(local, under: releaseDir, limit: Self.readLimit * 4) {
                    let dir = ".brahma/releases/R-\(number)"
                    try EngineFiles.directory(workspace: workspace, dir)
                    try EngineFiles.replace(clean, workspace: workspace, dir: dir, name: name)
                }
            } catch {
                FileHandle.standardError.write(Data("brahma release: could not write \(name) of R-\(number): \(error)\n".utf8))
            }
            return (parts, store.redactor.apply(String(whole.suffix(Self.tailChars))))
        }
    }

    /// A raw output file scrubbed in place, then read (at most `readLimit`); "" when it is absent, unsafe or not scrubbable.
    static func scrubbedText(_ url: URL, under root: URL, store: Store) -> String {
        guard store.scrubOrRemoveSmokeLog(url), let data = EngineFiles.readNoFollow(url, under: root, limit: readLimit) else { return "" }
        return store.redactor.apply(String(decoding: data, as: UTF8.self))
    }
}
