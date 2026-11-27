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
    public var unsandboxed: any UnsandboxedRunning
    public var http: any HTTPProbing
    public var adapters: HostingAdapters.Lookup
    public var sleep: @Sendable (Duration) async -> Void
    /// Nil: the engine's check environment (`Orchestrator.checkBaseEnvironment`).
    public var environment: [String: String]?

    public init(sandbox: any SandboxedRunner, unsandboxed: any UnsandboxedRunning = UnsandboxedPreviewRunner(),
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
/// 8. **Smoke** (`smoking`): `DeploySmoke` against the adapter's smoke base, with the smoke requests and expected text
///    pinned on the release (final-review m2).
/// 9. **Finish**: `deployed` or `failed` (the owner told; a P1 bug only for what agents can fix, m4), through
///    `Store.finishRelease`.
///
/// Every build, tools and deploy step is killable (`runStep`: spawned, recorded, polled, its group terminated on a timeout
/// or the owner's stop). Raw output stays under the data home (`ReleaseLayout`); only the redacted copy of `deploy.log` (and
/// `build.log`) goes to `<ws>/.brahma/releases/R-<n>/` (PR-7). The owner's stop (`stopAll`) ends the running step, and the
/// release's smoke in flight (its smoke on main, or the deployed site's `DeploySmoke`, cancelled: Task 7 M5): a release
/// that was `deploying` is `interrupted` and never runs again; one `building` or `smoking` is `failed` (`"stopped by the
/// owner during <step>"`).
///
/// Task 8: the owner's rollback (`Store.requestRollback`) is claimed in `advance` right after the deploy claim, before any
/// await (`Store.claimRollback`, one write), and runs the release's recorded `rollbackPlan` exactly as stored (rendered again
/// and compared first), with the deploy steps' token rules, then `DeploySmoke` without expected text (`rollBack`). It never
/// touches `main` and is never retried by the engine. A stop during it records `rollbackStatus interrupted`. `recover`
/// (engine start) ends whatever an earlier engine left in progress without running anything again.
public actor ReleaseExecutor: EmergencyStopObserver {
    /// The release smoke: `(companyId, commit, reason, releaseId, acceptedMain)` → the recorded run.
    public typealias Smoke = @Sendable (String, String, MainSmokeReason, String?, String?) async throws -> MainSmokeRun

    let store: Store
    let paths: BrahmaPaths
    let sandbox: any SandboxedRunner
    let unsandboxed: any UnsandboxedRunning
    let vault: any SecretVault
    let http: any HTTPProbing
    let smoke: Smoke
    let adapters: HostingAdapters.Lookup
    let sleep: @Sendable (Duration) async -> Void
    let clock: @Sendable () -> Date
    let blocking: Blocking
    let environment: [String: String]
    /// The engine's ceiling on every profile (`brahma run --profile`, `Orchestrator.profileCeiling`): narrows the Full-mode
    /// route of a release's build (B2); nil is no ceiling.
    let ceiling: PermissionProfile?
    /// How often a running step's exit, timeout and stop are looked at.
    let stepPoll: Duration
    /// Every step process running now, by pid (the L process registry, PR-4).
    public nonisolated let processes = SpawnedProcesses()

    /// Companies whose release this actor is carrying out (a second `advance` for one of them returns at once).
    private var inFlight = Set<String>()
    /// Release id → its company, while it is carried out.
    private var active: [String: String] = [:]
    /// Releases the owner's stop (`stopAll`) reached.
    private var stops = Set<String>()
    /// Release id → the step it is at (`"smoke on main"`, `"build"`, `"stage"`, `"tools"`, `"deploy"`, `"smoke"`, `"rollback"`):
    /// what a stop's reason names.
    private var stages: [String: String] = [:]
    /// Release id → the redacted end of its rollback log so far (what an interrupted or failed rollback records).
    private var tails: [String: String] = [:]
    /// Release id → the process of its running step.
    private var running: [String: any SandboxedProcess] = [:]
    /// Release id → how to cancel its smoke in flight (the smoke on main, the deployed site's `DeploySmoke`): what the
    /// owner's stop ends at once (Task 7 M5, L-5lite-A).
    private var smokes: [String: @Sendable () -> Void] = [:]

    public init(store: Store, paths: BrahmaPaths, sandbox: any SandboxedRunner, unsandboxed: any UnsandboxedRunning = UnsandboxedPreviewRunner(),
                vault: any SecretVault, http: any HTTPProbing, smoke: @escaping Smoke,
                adapters: @escaping HostingAdapters.Lookup = HostingAdapters.adapter,
                sleep: @escaping @Sendable (Duration) async -> Void = { try? await Task.sleep(for: $0) },
                clock: @escaping @Sendable () -> Date = Store.now,
                environment: [String: String] = ProcessInfo.processInfo.environment, ceiling: PermissionProfile? = nil) {
        self.init(store: store, paths: paths, sandbox: sandbox, unsandboxed: unsandboxed, vault: vault, http: http, smoke: smoke,
                  adapters: adapters, sleep: sleep, clock: clock, blocking: Blocking(), environment: environment, ceiling: ceiling)
    }

    init(store: Store, paths: BrahmaPaths, sandbox: any SandboxedRunner, unsandboxed: any UnsandboxedRunning, vault: any SecretVault,
         http: any HTTPProbing, smoke: @escaping Smoke, adapters: @escaping HostingAdapters.Lookup,
         sleep: @escaping @Sendable (Duration) async -> Void, clock: @escaping @Sendable () -> Date, blocking: Blocking,
         environment: [String: String], ceiling: PermissionProfile?, stepPoll: Duration = .milliseconds(200)) {
        self.store = store; self.paths = paths; self.sandbox = sandbox; self.unsandboxed = unsandboxed
        self.vault = vault.nonInteractive(); self.http = http; self.smoke = smoke; self.adapters = adapters; self.sleep = sleep
        self.clock = clock; self.blocking = blocking; self.environment = environment; self.ceiling = ceiling; self.stepPoll = stepPoll
    }

    /// The export run id of a release's build: `rel-<release id>` (a valid 3a run id, unique across companies).
    public static func exportRunId(_ release: Release) -> String { "rel-\(release.id)" }

    // MARK: Claiming

    /// Every company with an approved release or a requested rollback, one after the other (the tick runs
    /// `advance(companyId:now:)` per company).
    /// A paused company only rolls back (fix I1), as in the tick.
    public func advance(now: Date) async {
        for companyId in ((try? store.companiesWithReleaseWork()) ?? []).sorted() {
            let paused = (try? store.company(id: companyId))??.status != .running
            await advance(companyId: companyId, now: now, rollbackOnly: paused)
        }
    }

    /// Claims and carries out the company's oldest approved release, else its oldest requested rollback. The in-flight check
    /// and insert, then the deploy claim (the first database transaction, conditional on `approved`), then — when there was
    /// none — the rollback claim (one transaction, conditional on `requested`); nothing while the owner's stop holds, and no
    /// await before either (builder-checks 3 and 5, PR-9). One company runs one release or rollback at a time.
    /// `rollbackOnly` (a paused company, fix I1): the deploy claim is skipped, so only a requested rollback can start.
    public func advance(companyId: String, now: Date, rollbackOnly: Bool = false) async {
        guard inFlight.insert(companyId).inserted else { return }
        defer { inFlight.remove(companyId) }
        let claimed: Release?, rollback: Release?
        do {
            claimed = rollbackOnly ? nil : try store.claimRelease(companyId: companyId, now: now)
            rollback = claimed == nil ? try store.claimRollback(companyId: companyId, now: now) : nil
        } catch {
            log("could not claim a release or rollback of \(companyId): \(error)")
            return
        }
        if let release = claimed { await carryOut(release) } else if let rollback { await carryOutRollback(rollback) }
    }

    // MARK: The owner's stop

    /// Every release and rollback in progress stops: its running step's group is terminated (SIGTERM, then SIGKILL after
    /// `EmergencyStop.grace`), and the release records `interrupted` (it was deploying) or `failed`, a rollback `rollbackStatus
    /// interrupted`, each `"stopped by the owner during <step>"` with the owner's notice. Nothing of it runs again. Claims stop
    /// too while the stop holds (`Store.claimRelease`, `Store.claimRollback`).
    public func stopAll(reason: String) async {
        for id in active.keys { stops.insert(id) }
        for cancel in smokes.values { cancel() }
        for process in running.values { await process.terminate(grace: .seconds(EmergencyStop.grace)) }
    }

    /// Runs one of the release's smokes as a task the owner's stop cancels (`stopAll`), and the engine's shutdown too (the
    /// caller's cancellation is passed on). A stop that came first cancels it at once. The caller's `checkStop` then names
    /// the stop.
    private func stoppable<T: Sendable>(_ r: Release, _ body: @escaping @Sendable () async throws -> T) async throws -> T {
        let task = Task { try await body() }
        smokes[r.id] = { task.cancel() }
        defer { smokes[r.id] = nil }
        if stops.contains(r.id) { task.cancel() }
        return try await withTaskCancellationHandler { try await task.value } onCancel: { task.cancel() }
    }

    /// Who stops a release: the owner (`stopAll`, or the stop row, which the observers may not have seen yet) or the engine
    /// itself (its task cancelled at shutdown).
    enum StopCause: Equatable, Sendable { case owner, engine }

    private func stopCause(_ releaseId: String) -> StopCause? {
        if stops.contains(releaseId) { return .owner }
        if Task.isCancelled { return .engine }
        if (try? store.engineStopped()) != nil { return .owner }
        return nil
    }

    /// The recorded reason of a stop at the release's current step: `"stopped by the owner during <step>"`; the engine
    /// stopping says what the owner checks (`Store.recoverReleases` words it the same way after a crash).
    private func stopText(_ cause: StopCause, _ r: Release) -> String {
        let stage = stages[r.id] ?? "release"
        switch cause {
        case .owner: return "stopped by the owner during \(stage)"
        case .engine:
            switch stage {
            case "deploy": return "the engine stopped during the deploy; check \(r.provider.title), then propose again"
            case "rollback": return "the engine stopped during the rollback"
            default: return "the engine stopped during \(stage); propose again"
            }
        }
    }

    private func at(_ r: Release, _ stage: String) { stages[r.id] = stage }

    private struct Stopped: Error { let cause: StopCause }

    private struct Failure: Error {
        let stage: String, detail: String, reason: String
        var results: [SmokeResult]? = nil
        /// The agents can fix it (final-review m4): a failing build, a refused upload, the smoke check failing on main, the
        /// deployed site failing its smoke. Everything else is the owner's (only the owner is told; no bug is filed).
        var bug = false
    }

    private func checkStop(_ release: Release) throws {
        if let cause = stopCause(release.id) { throw Stopped(cause: cause) }
    }

    // MARK: Carrying it out

    private func carryOut(_ release: Release) async {
        active[release.id] = release.companyId
        let end: ReleaseEnd
        do { end = try await deploy(release) } catch let s as Stopped {
            end = .stopped(reason: stopText(s.cause, release))
        } catch let f as Failure {
            end = .failed(stage: f.stage, detail: f.detail, reason: f.reason, results: f.results, bug: f.bug)
        } catch {
            end = .failed(stage: "release", detail: "engine error", reason: "the engine could not carry out the release: \(error)", results: nil)
        }
        await cleanUp(release)
        do { try store.finishRelease(id: release.id, end: end, now: clock()) } catch {
            log("could not record the end of \(release.ref) of \(release.companyId): \(error)")
        }
        forget(release.id)
    }

    private func forget(_ id: String) {
        active[id] = nil
        stops.remove(id)
        running[id] = nil
        smokes[id] = nil
        stages[id] = nil
        tails[id] = nil
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
        at(r, "smoke on main")
        guard let main = company.mainCommit else {
            throw Failure(stage: "smoke on main", detail: "not on main", reason: "\(r.ref)'s commit is no longer on main")
        }
        let commit = r.commit
        let onMain = await blocking.run {
            (try? store.gitWorkspace(root: ws, companyId: company.id).isAncestor(commit, of: main)) ?? false
        }
        guard onMain else { throw Failure(stage: "smoke on main", detail: "not on main", reason: "\(r.ref)'s commit is no longer on main") }
        // Final-review m2: the smoke checks the owner approved (pinned on the release), before anything runs; the smoke on
        // main checks its own pin again in the write that claims its run.
        let site = try store.hosting(companyId: r.companyId)
        try Self.checkSmokePins(r, smokeCheck: company.smokeCheck, site: site)
        try Self.checkProductionURL(adapter, site)
        try checkStop(r)
        let run: MainSmokeRun
        let (smoke, companyId, releaseId) = (self.smoke, r.companyId, r.id)
        do { run = try await stoppable(r) { try await smoke(companyId, commit, .release, releaseId, main) } } catch {
            // A smoke the owner's stop (or the engine's shutdown) ended is the stop, never a "smoke on main" failure.
            try checkStop(r)
            switch (error as? WorkError)?.message {
            case ReleasePolicy.smokeChanged?:
                throw Failure(stage: "integrity", detail: "smoke check changed", reason: ReleasePolicy.smokeChanged)
            case Store.noLongerOnMain(commit)?:
                throw Failure(stage: "smoke on main", detail: "not on main", reason: "\(r.ref)'s commit is no longer on main")
            default:
                throw Failure(stage: "smoke on main", detail: "did not run",
                              reason: "the smoke check could not run at \(r.sha7) just before deploying (\(Self.text(error)))")
            }
        }
        try checkStop(r)
        switch run.status {
        case .passed: break
        case .failed: throw Failure(stage: "smoke on main", detail: run.failure, reason: "the smoke check failed at \(r.sha7) just before deploying",
                                    bug: true)
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
        try Self.checkSmokePins(r, smokeCheck: nil, site: settings)
        try Self.checkProductionURL(adapter, settings)
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
        at(r, "build")
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
            // The build's subject principals, resolved once for this build (S6), from the release record whose build this runs
            // (S6-c1): its proposer, and only while the stored release still has that proposer and those commands (else the
            // integrity refusal, nothing built). Unsandboxed only when the proposer and the company narrow to Full under the
            // ceiling; in a Full company an unconfirmed proposer builds sandboxed with the B1 line. S6-c2: the release supplies
            // only the build and its proposer; the profiles and the policy's domains are the live company's (`live`), read at
            // the resolution, never the company read when the release started (minutes ago, before its smoke).
            let principals: PrincipalSet
            let live: Company
            switch PrincipalResolver(store: store, ceiling: ceiling).resolve(holding: .release(r)) {
            case .allow(let resolved, _): (principals, live) = (resolved.principals, resolved.company)
            case .deny: throw Self.mismatch
            }
            PrincipalResolver.noteSandboxed(principals, store: store, subject: "\(r.ref) build", kind: .release, now: clock())
            let log = releaseDir.appending(path: "build.log", directoryHint: .notDirectory)
            // Plan S Task S7: the build's route is the factory's `.releaseSmoke` decision over the export (the smoke's shape),
            // with the proposer's principals: the owner's Full opt-out, or the sandbox under the validated policy.
            let decision = Store.smokeDecision(company: live, export: export, principals: principals, baseline: sandbox.policyBaseline())
            let outcome = await runStep(r, decision: decision, command: build, cwd: export, environment: toolEnvironment,
                                        timeout: ReleasePolicy.buildTimeout, log: log)
            let tail = await logs.publish(raw: [log], as: "build.log", header: nil).tail
            switch outcome {
            case .stopped(let cause): throw Stopped(cause: cause)
            case .unavailable: throw Failure(stage: "build", detail: "sandbox unavailable", reason: "sandbox unavailable")
            case .couldNotStart(let why): throw Failure(stage: "build", detail: "could not start", reason: "the build could not start (\(why))")
            case .finished(let exit, let timedOut):
                if timedOut || exit != 0 {
                    _ = try? store.advanceRelease(id: r.id, from: .building, to: .building, now: clock()) { $0.outputTail = tail }
                    let detail = timedOut ? "timed out" : "exit \(exit)"
                    throw Failure(stage: "build", detail: detail, reason: "build failed (\(detail))", bug: true)
                }
            }
        }

        // 5. Stage the upload.
        at(r, "stage")
        do {
            let dirs = plan.stageFrom
            try await blocking.tryRun {
                defer { EngineExport.remove(store: store, company: company, runId: runId) }
                try UploadStager.stage(from: export, dirs: dirs, into: upload)
            }
        } catch let e as ReleaseError {
            throw Failure(stage: "stage", detail: e.message, reason: e.message, bug: true)
        } catch {
            throw Failure(stage: "stage", detail: "could not stage", reason: "could not stage the upload (\(Self.text(error)))")
        }
        try checkStop(r)

        // 6. The provider CLI, token-free, into the engine-only tools folder (PR-8).
        at(r, "tools")
        let tools = try await ensureTools(r, adapter: adapter, layout: layout, home: home, logs: logs, environment: toolEnvironment)
        try checkStop(r)

        // 7. Deploy. The token is read, and shown to be redactable, before `deploying` is committed (fix I1): nothing a
        // token step prints reaches a log or the database unless the redactor demonstrably replaces this exact value (no
        // secrets reload pending, none failed, the value long enough to be redacted). Otherwise nothing is deployed.
        let token = try await readToken(r, plan: plan, stage: "deploy", again: "propose again")
        // `deploying` is committed before any step runs, with when it started (final-review m1: from now on the release
        // changed, or may have changed, what is live).
        let deployStarted = clock()
        try store.advanceRelease(id: r.id, from: .building, to: .deploying, now: deployStarted) { $0.deployStartedAt = deployStarted }
        at(r, "deploy")
        let deployStep = plan.steps.lastIndex { $0.label == "deploy" } ?? (plan.steps.count - 1)
        var deployStdout = ""
        var tail = ""
        for (i, step) in plan.steps.enumerated() {
            let result = try await tokenStep(r, argv: step.argv, index: i, plan: plan, adapter: adapter, token: token, layout: layout,
                                             home: home, tools: tools, logs: logs, log: "deploy.log", prefix: "step", stage: "deploy")
            tail = result.tail
            switch result.outcome {
            case .stopped(let cause): throw Stopped(cause: cause)
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
                                             layout: layout, home: home, tools: tools, logs: logs, log: "deploy.log", prefix: "step",
                                             stage: "deploy")
            tail = result.tail
            switch result.outcome {
            case .stopped(let cause): throw Stopped(cause: cause)
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
        at(r, "smoke")
        guard let base = adapter.smokeBase(settings, deployURL: deployURL) else {
            throw Failure(stage: "smoke", detail: "no deploy URL", reason: Self.noSmokeBase("deploy"))
        }
        try checkStop(r)
        let (http, sleep, requests, expectText) = (self.http, self.sleep, r.siteSmoke, r.siteExpectText)
        let smoked = try await stoppable(r) {
            await DeploySmoke.run(base: base, requests: requests, expectText: expectText, http: http, sleep: sleep)
        }
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
                          reason: "the deployed site failed its smoke check (\(Store.flat(detail, max: 120)))", results: results, bug: true)
        }
        return .deployed(productionURL: settings.productionURL ?? base.absoluteString, results: results)
    }

    private static let mismatch = Failure(stage: "integrity", detail: "the hosting settings or the stored plan changed since approval",
                                  reason: "the approved commands no longer match; propose again")

    /// Final-review m2: the smoke check on main (`smokeCheck`, when given) and the deployed site's smoke requests and expected
    /// text (`site`, when given) must still be the ones pinned on the release when it was approved; else nothing runs.
    private static func checkSmokePins(_ r: Release, smokeCheck: CheckSpec??, site: HostingSettings?) throws {
        if let smokeCheck, smokeCheck != r.smokeCheck {
            throw Failure(stage: "integrity", detail: "smoke check changed", reason: ReleasePolicy.smokeChanged)
        }
        if let site, site.smoke != r.siteSmoke || site.expectText != r.siteExpectText {
            throw Failure(stage: "integrity", detail: "site smoke changed", reason: ReleasePolicy.siteSmokeChanged)
        }
    }

    /// Final-fix2 R2: a provider that needs the owner's production URL (Vercel: its per-deploy URLs sit behind deployment
    /// protection) refuses a release whose production URL was cleared after approval, before any build or token step. The
    /// owner's to fix (no bug).
    private static func checkProductionURL(_ adapter: any HostingAdapter, _ settings: HostingSettings?) throws {
        if let why = adapter.productionURLRequired, settings?.productionURL == nil {
            throw Failure(stage: "integrity", detail: "no production URL", reason: why)
        }
    }

    /// No address to smoke (final-review I5, I6b): the site's address is never guessed from the project name.
    static func noSmokeBase(_ step: String) -> String {
        "no verified deploy URL was found in the \(step) output and no production URL is set; set the production URL in HOSTING"
    }

    // MARK: Shared steps

    /// The pinned provider CLI in the engine-only tools folder, installed token-free when it is missing (PR-8: per-run
    /// caches, no npx, no shared cache). Returns the tools folder.
    private func ensureTools(_ r: Release, adapter: any HostingAdapter, layout: ReleaseLayout, home: URL, logs: EngineLogs,
                             environment toolEnvironment: [String: String]) async throws -> URL {
        let tools = layout.deployTools(cli: adapter.cli)
        let bin = tools.appending(path: "node_modules/.bin/\(adapter.cliBin)", directoryHint: .notDirectory)
        guard !Self.exists(bin) else { return tools }
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
        let log = layout.releaseDir(r.number).appending(path: "tools.log", directoryHint: .notDirectory)
        // Plan S Task S7: the factory's `.releaseTool` rule, engine principals (an engine-composed install: never Full).
        let decision = Self.toolDecision(writable: [resolved], readable: [resolved], network: adapter.toolNetwork, baseline: sandbox.policyBaseline())
        let outcome = await runStep(r, decision: decision,
                                    command: ShellQuote.joinArgv(["npm", "install", "--prefix", tools.path, "--no-audit", "--no-fund", cli], rawRefs: []),
                                    cwd: tools, environment: env,
                                    timeout: ReleasePolicy.stepTimeout, log: log)
        await blocking.run { _ = try? EngineFiles.removeNoFollow(tools.appending(path: ".brahma-tmp"), under: layout.root) }
        _ = await logs.publish(raw: [log], as: "tools.log", header: nil)
        switch outcome {
        case .stopped(let cause): throw Stopped(cause: cause)
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
        return tools
    }

    /// The provider token for a token step, read and shown to be redactable before anything holds it (fix I1): nothing a token
    /// step prints reaches a log or the database unless the redactor demonstrably replaces this exact value (no secrets
    /// reload pending, none failed, the value long enough to be redacted). Otherwise nothing runs (`again` says what next).
    private func readToken(_ r: Release, plan: DeployPlan, stage: String, again: String) async throws -> String {
        let (companyId, secret, store, vault) = (r.companyId, plan.tokenSecret, self.store, self.vault)
        let token: String? = await blocking.run { try? vault.value(companyId: companyId, name: secret) }
        guard let token, !token.isEmpty else {
            throw Failure(stage: stage, detail: "no token", reason: "the provider token \(secret) could not be read")
        }
        guard ChildEnvironment.droppedSecretNames([secret: token]).isEmpty else {
            throw Failure(stage: stage, detail: "token name", reason: "the provider token \(secret) cannot be passed to a \(stage) step")
        }
        guard Self.redacts(store: store, token: token) else {
            throw Failure(stage: stage, detail: "token not loaded for redaction",
                          reason: "the hosting token \(secret) isn't loaded for redaction yet; \(again)")
        }
        return token
    }

    // MARK: Rolling back (Task 8)

    private func carryOutRollback(_ release: Release) async {
        active[release.id] = release.companyId
        at(release, "rollback")
        let end: RollbackEnd
        do { end = .succeeded(tail: try await rollBack(release)) } catch let s as Stopped {
            end = .stopped(reason: stopText(s.cause, release), tail: tails[release.id])
        } catch let f as Failure {
            end = .failed(reason: f.reason, tail: tails[release.id])
        } catch {
            end = .failed(reason: "the engine could not carry out the rollback: \(Self.text(error))", tail: tails[release.id])
        }
        await cleanUpRollback(release)
        do { try store.finishRollback(id: release.id, end: end, now: clock()) } catch {
            log("could not record the end of the rollback of \(release.ref) of \(release.companyId): \(error)")
        }
        forget(release.id)
    }

    /// The rollback's HOME and its empty working folder go; the placeholder and every upload stay. Never throws.
    private func cleanUpRollback(_ release: Release) async {
        guard let layout = try? store.releaseLayout(companyId: release.companyId) else { return }
        let dir = layout.releaseDir(release.number)
        await blocking.run {
            _ = try? EngineFiles.removeNoFollow(dir.appending(path: "home", directoryHint: .isDirectory), under: layout.root)
            _ = try? EngineFiles.removeNoFollow(dir.appending(path: "rollback", directoryHint: .isDirectory), under: layout.root)
        }
    }

    private enum RollbackPlace: Sendable { case placeholder, emptyFolder, upload(of: String) }

    /// Runs `r.rollbackPlan` exactly as recorded (spec §6.26): rendered again from the release and the one it restores and
    /// compared (any difference refuses: roll back from the dashboard); its folder prepared (the placeholder written, an empty
    /// folder made, or the restored release's upload required); the provider CLI ensured; the token read under the I1 rule;
    /// every step under the sandbox only, after the provider config check, a verify step confirming its target first; then
    /// `DeploySmoke` without expected text. Returns the redacted end of `rollback.log`. Never touches `main`.
    private func rollBack(_ r: Release) async throws -> String {
        let store = self.store
        guard let company = try store.company(id: r.companyId) else {
            throw Failure(stage: "rollback", detail: "no company", reason: "the company is gone")
        }
        let ws = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        let adapter = adapters(r.provider)
        let layout = try store.releaseLayout(companyId: r.companyId)
        let releaseDir = layout.releaseDir(r.number)
        let home = releaseDir.appending(path: "home", directoryHint: .isDirectory)
        let logs = EngineLogs(store: store, workspace: ws, releaseDir: releaseDir, number: r.number, blocking: blocking)
        try checkStop(r)

        // Integrity: exactly the recorded commands.
        let plan = r.rollbackPlan
        let rendered: DeployPlan
        do { rendered = try await blocking.tryRun { try Self.renderRollbackPlan(store: store, release: r, adapter: adapter, layout: layout) } } catch {
            throw Self.rollbackMismatch
        }
        guard plan.hashIsCurrent, rendered == plan, rendered.hash == plan.hash else { throw Self.rollbackMismatch }
        // No recorded commands (fix M1): nothing is composed in their place.
        guard !plan.steps.isEmpty else {
            throw Failure(stage: "rollback", detail: "no commands", reason: "\(r.ref) has no recorded rollback; \(Store.dashboardRollback)")
        }
        guard let settings = try store.hosting(companyId: r.companyId) else { throw Self.rollbackMismatch }
        let previous = try r.previousReleaseId.flatMap { id in try store.writer.read { try Release.fetchOne($0, key: id) } }

        // Where it runs: the placeholder (rewritten now), an empty folder of this release, or the restored release's upload.
        let cwd = URL(fileURLWithPath: plan.cwdPath, isDirectory: true)
        func same(_ url: URL) -> Bool { url.standardizedFileURL.path == cwd.standardizedFileURL.path }
        let place: RollbackPlace
        if same(layout.placeholderDir) {
            place = .placeholder
        } else if same(releaseDir.appending(path: "rollback", directoryHint: .isDirectory)) {
            place = .emptyFolder
        } else if let previous, same(layout.releaseDir(previous.number).appending(path: "upload", directoryHint: .isDirectory)) {
            place = .upload(of: previous.ref)
        } else {
            throw Self.rollbackMismatch
        }
        let (number, name) = (r.number, company.name)
        let refusal: String? = await blocking.run {
            do {
                try BrahmaPaths.ensurePrivateDirectory(layout.root)
                try EngineFiles.directory(workspace: layout.root, "R-\(number)", mode: 0o700)
                _ = try EngineFiles.removeNoFollow(home, under: layout.root)
                try EngineFiles.directory(workspace: layout.root, "R-\(number)/home", mode: 0o700)
                switch place {
                case .placeholder:
                    try Placeholder.write(to: layout, companyName: name)
                case .emptyFolder:
                    _ = try EngineFiles.removeNoFollow(cwd, under: layout.root)
                    try EngineFiles.directory(workspace: layout.root, "R-\(number)/rollback", mode: 0o700)
                case .upload(let ref):
                    guard Self.isDirectory(cwd) else { return "\(ref)'s files are gone; roll back from the provider dashboard" }
                }
                return nil
            } catch {
                return "the rollback folder is not safe to use (\(Self.text(error)))"
            }
        }
        if let refusal { throw Failure(stage: "rollback", detail: "folder", reason: refusal) }
        try checkStop(r)

        let toolEnvironment = ChildEnvironment.make(base: environment, extra: ["BRAHMA_AGENT_ID": "release"], purpose: .check)
        let tools = try await ensureTools(r, adapter: adapter, layout: layout, home: home, logs: logs, environment: toolEnvironment)
        try checkStop(r)
        let token = try await readToken(r, plan: plan, stage: "rollback", again: "request the rollback again")

        var tail = ""
        var stdout = ""
        var verified: URL?
        for (i, step) in plan.steps.enumerated() {
            let result = try await tokenStep(r, argv: step.argv, index: i, plan: plan, adapter: adapter, token: token, layout: layout,
                                             home: home, tools: tools, logs: logs, log: "rollback.log", prefix: "rollback-step",
                                             stage: "rollback")
            tail = result.tail
            tails[r.id] = tail
            switch result.outcome {
            case .stopped(let cause): throw Stopped(cause: cause)
            case .unavailable: throw Failure(stage: "rollback", detail: "sandbox unavailable", reason: "sandbox unavailable")
            case .couldNotStart(let why):
                throw Failure(stage: "rollback", detail: "could not start", reason: "the \(step.label) step could not start (\(why))")
            case .finished(let exit, let timedOut):
                if step.label == DeployStep.verifyLabel {
                    // The target must be this project's deployment, confirmed with the token, before anything is rolled back.
                    guard exit == 0, !timedOut, adapter.verifiesDeployment(output: result.stdout + "\n" + result.stderr, settings: settings) else {
                        throw Failure(stage: "rollback", detail: "unverified target",
                                      reason: "the rollback target \(step.argv.last ?? "") is not a deployment of \(settings.project)")
                    }
                    verified = step.argv.last.flatMap { URL(string: $0) }
                    continue
                }
                let tolerated = step.okIfOutputContains.map { result.stdout.contains($0) || result.stderr.contains($0) } ?? false
                if timedOut || (exit != 0 && !tolerated) {
                    let detail = timedOut ? "timed out" : "exit \(exit)"
                    throw Failure(stage: "rollback", detail: detail, reason: "the \(step.label) step failed (\(detail))")
                }
                stdout = result.stdout
            }
        }

        // The restored site, smoked without the expected text (it need not carry the current release's). Final-review I6b:
        // for a provider whose deploy URLs are verified with the token (the release's plan has a verify step: Vercel), only
        // the target this rollback verified counts, never a URL its output merely printed.
        let printed = adapter.deployURL(fromOutput: stdout, settings: settings)
        let deployURL = verified ?? (r.plan.verify == nil ? printed : nil)
        guard let base = adapter.smokeBase(settings, deployURL: deployURL) else {
            throw Failure(stage: "rollback", detail: "no URL", reason: Self.noSmokeBase("rollback"))
        }
        try checkStop(r)
        let (http, sleep, requests) = (self.http, self.sleep, settings.smoke)
        let smoked = try await stoppable(r) { await DeploySmoke.run(base: base, requests: requests, expectText: nil, http: http, sleep: sleep) }
        try checkStop(r)
        guard smoked.ok else {
            let first = smoked.results.first { !$0.ok }
            let path = first.flatMap { URL(string: $0.url)?.path }.map { $0.isEmpty ? "/" : $0 } ?? "/"
            let detail = first.map { "\($0.method) \(path): \($0.error ?? $0.status.map { "status \($0)" } ?? "no response")" } ?? "no result"
            throw Failure(stage: "rollback", detail: "smoke", reason: "the site failed its smoke check after the rollback (\(Store.flat(detail, max: 120)))")
        }
        return tail
    }

    private static let rollbackMismatch = Failure(stage: "rollback", detail: "integrity",
                                                  reason: "the recorded rollback commands no longer match the hosting settings; roll back from the provider dashboard")

    // MARK: Crash recovery (Task 8)

    /// Engine start (builder-check 5), before the first tick: whatever an earlier engine left in progress ends, never runs
    /// again (`Store.recoverReleases`: `building`/`smoking` → `failed`, `deploying` → `interrupted`, a running rollback →
    /// `interrupted`, the owner told), and its leftovers go: the export, the release's HOME, the rollback folder and every raw
    /// step file (unscrubbed output an interrupted step may have left under the data home).
    public func recover(now: Date) async throws {
        let left = try store.recoverReleases(now: now)
        for r in left {
            await cleanUp(r)
            await cleanUpRollback(r)
            guard let layout = try? store.releaseLayout(companyId: r.companyId) else { continue }
            let dir = layout.releaseDir(r.number)
            let names = (0...r.plan.steps.count).map { "step-\($0).out" } + (0..<r.rollbackPlan.steps.count).map { "rollback-step-\($0).out" }
            await blocking.run {
                for name in names { _ = try? EngineFiles.removeNoFollow(dir.appending(path: name, directoryHint: .notDirectory), under: layout.root) }
            }
        }
    }

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

    /// The rollback plan of `release` rendered again (Task 8): from the same data-home `ReleaseLayout`, the release's stored
    /// build and output folder, the release it restores (`previousReleaseId`) and the current hosting settings
    /// (`Store.rollbackInput`, as `proposeDeploy` composed it). Anything changed since approval makes it differ: fail closed.
    static func renderRollbackPlan(store: Store, release r: Release, adapter: any HostingAdapter, layout: ReleaseLayout? = nil) throws -> DeployPlan {
        guard var settings = try store.hosting(companyId: r.companyId), settings.provider == r.provider, adapter.id == r.provider else {
            throw WorkError.invalid("the hosting settings changed")
        }
        settings.build = r.build
        settings.outputDir = r.outputDir
        let layout = try layout ?? store.releaseLayout(companyId: r.companyId)
        let previous = try r.previousReleaseId.flatMap { id in try store.writer.read { try Release.fetchOne($0, key: id) } }
        return try adapter.rollbackPlan(Store.rollbackInput(settings: settings, release: r.number, commit: r.commit, version: r.version,
                                                            previous: previous, layout: layout, cli: adapter.cli))
    }

    // MARK: Steps

    enum StepOutcome: Equatable, Sendable {
        case finished(exit: Int32, timedOut: Bool)
        case stopped(StopCause)
        /// `SandboxError.unavailable`: no sandbox on this machine (fail closed, PR-5).
        case unavailable
        case couldNotStart(String)
    }

    /// One killable step (chief review L5): spawned through `runner`, recorded (`processes`, and `ChildGroups` kind
    /// `release` so `brahma stop` reaches it without the engine), its exit polled every `stepPoll`, its whole group
    /// terminated on `timeout` (awake time) or the owner's stop, and waited for until it is reaped.
    /// Plan S Task S7: `decision` is the factory's for this step: the sandbox under its validated policy, a Full company's
    /// unsandboxed runner with its opt-out (the build only), or a refusal, which is a step that could not start.
    private func runStep(_ r: Release, decision: PolicyDecision, command: String, cwd: URL, environment: [String: String],
                         timeout: Duration, log: URL) async -> StepOutcome {
        if let cause = stopCause(r.id) { return .stopped(cause) }
        let process: any SandboxedProcess
        do {
            switch decision {
            case .sandboxed(let policy):
                process = try sandbox.spawn(command: command, cwd: cwd, environment: environment, logURL: log, policy: policy)
            case .fullOptOut(let optOut):
                process = try unsandboxed.spawn(command: command, cwd: cwd, environment: environment, logURL: log, optOut: optOut)
            case .refused(let why):
                // The text a policy the sandbox refused at its spawn gave (`Self.text(error)`).
                return .couldNotStart(why)
            }
        } catch {
            if case SandboxError.unavailable = error { return .unavailable }
            return .couldNotStart(Self.text(error))
        }
        processes.insert(process)
        running[r.id] = process
        let groups = ChildGroups(dir: ChildGroups.directory(runDir: paths.runDir), kind: "release")
        let record = groups.record(process.pid)
        let deadline = AwakeTime.deadline(after: timeout)
        var timedOut = false
        var stopped: StopCause?
        while process.exitStatus() == nil {
            if let cause = stopCause(r.id) { stopped = cause; break }
            if AwakeTime.now >= deadline { timedOut = true; break }
            try? await AwakeTime.sleep(for: stepPoll)
        }
        await process.terminate(grace: .seconds(EmergencyStop.grace))
        groups.forget(record, pid: process.pid)
        processes.remove(process.pid)
        running[r.id] = nil
        // A stop that ended the process itself (`stopAll`, or `brahma stop` signalling the recorded group) is still a stop,
        // not the step's own exit.
        if let cause = stopped ?? stopCause(r.id) { return .stopped(cause) }
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

    /// A token-holding step (deploy, verify, rollback): the provider config check first (I3), then `argv` (engine-composed,
    /// the token never in it, PR-11) under the sandbox only, with the token only in its environment. Its stdout goes to an
    /// engine-only file under the data home (`<prefix>-<index>.out`) and its stderr to a file of its own, so a URL is read
    /// from stdout alone. Both are published to `log` redacted by the store's redactor AND with `token` pinned (the value
    /// this step was given is replaced even when the owner rotated or deleted the secret and the redactor reloaded while the
    /// step ran).
    private func tokenStep(_ r: Release, argv: [String], index: Int, plan: DeployPlan, adapter: any HostingAdapter, token: String,
                           layout: ReleaseLayout, home: URL, tools: URL, logs: EngineLogs, log: String, prefix: String,
                           stage: String) async throws -> TokenStepResult {
        try checkStop(r)
        do { try adapter.refuseProviderConfig(plan, releaseRoot: layout.root) } catch {
            let why = (error as? WorkError)?.message ?? Self.text(error)
            throw Failure(stage: stage, detail: "provider config", reason: why)
        }
        let releaseDir = layout.releaseDir(r.number)
        let stdout = releaseDir.appending(path: "\(prefix)-\(index).out", directoryHint: .notDirectory)
        let stderr = home.appending(path: "\(prefix)-\(index).err", directoryHint: .notDirectory)
        let cwd = URL(fileURLWithPath: plan.cwdPath, isDirectory: true)
        func real(_ url: URL) -> URL { URL(fileURLWithPath: SandboxPath.resolve(url.path), isDirectory: true) }
        var env = ChildEnvironment.make(base: environment, extra: ["BRAHMA_AGENT_ID": "release"], purpose: .check,
                                        secrets: [plan.tokenSecret: token])
        env["HOME"] = home.path
        for (name, value) in plan.env where name != plan.tokenSecret { env[name] = value }
        let command = ShellQuote.joinArgv(argv, rawRefs: []) + " 2>>" + ShellQuote.quote(stderr.path)
        // Plan S Task S7: the factory's `.releaseTool` rule (engine principals: never Full).
        let decision = Self.toolDecision(writable: [real(home), real(cwd)], readable: [real(cwd), real(tools)], network: plan.network,
                                         baseline: sandbox.policyBaseline())
        let outcome = await runStep(r, decision: decision, command: command, cwd: cwd, environment: env,
                                    timeout: ReleasePolicy.stepTimeout, log: stdout)
        let header = "$ " + ShellQuote.joinArgv(argv, rawRefs: [plan.tokenSecret])
        let published = await logs.publish(raw: [stdout, stderr], as: log, header: header, pinned: [plan.tokenSecret: token])
        return TokenStepResult(outcome: outcome, stdout: published.parts[0], stderr: published.parts[1], tail: published.tail)
    }

    // MARK: Helpers

    /// The principals of an engine-composed step (the pinned CLI's install, a token step): the engine itself, so never Full,
    /// never a grant (as before Plan S, when these steps always ran in the sandbox).
    static let enginePrincipals = PrincipalSet(companyId: "", members: [.engine], ownerProfile: .sandboxed)

    /// A provider-tool step's decision (`.releaseTool`): each directory a verified place (its resolved path, reached from its
    /// parent without a link), the provider's pinned hosts, validated against `baseline`. Shared with `ProviderProbe` (its
    /// `.providerProbe` steps are these steps, as the probe runs them).
    static func toolDecision(_ purpose: Purpose = .releaseTool, writable: [URL], readable: [URL], network: [String],
                             baseline: SandboxBaseline) -> PolicyDecision {
        func place(_ url: URL) throws -> Place {
            let resolved = URL(fileURLWithPath: SandboxPath.resolve(url.path), isDirectory: false)
            return try Place.verify(resolved, kind: .directory, under: resolved.deletingLastPathComponent())
        }
        let places: PurposePlaces
        do {
            let (w, rd) = (try writable.map(place), try readable.map(place))
            places = purpose == .providerProbe ? .providerProbe(writable: w, readable: rd) : .releaseTool(writable: w, readable: rd)
        } catch {
            return .refused("a release step's place is not safe to use (\(error))")
        }
        return SandboxPolicyFactory.decide(purpose, principals: enginePrincipals, places: places, network: .fixed(network), baseline: baseline)
    }

    /// Whether every place a token step's output can land would have `token` replaced (fix I1): the redactor is loaded with
    /// no secret failed (`secretsHeld`), no reload is pending (it knows the stored secrets' current version; a read error
    /// counts as pending), and it demonstrably redacts this exact value (a rotated value it has not loaded, or one too short
    /// to redact, comes back unchanged).
    static func redacts(store: Store, token: String) -> Bool {
        guard !store.secretsHeld, (try? store.secretsReloadNeeded()) == false else { return false }
        let redacted = store.redactor.apply(token)
        return redacted != token && !redacted.contains(token)
    }

    /// A real directory (never a link) at `url`.
    static func isDirectory(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && (st.st_mode & S_IFMT) == S_IFDIR
    }

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
    /// `pinned` (secret name → value): values replaced as well as the store's redactor's, whatever the redactor holds by now
    /// (a token step's own token, read before it ran: Task 8, the Task 7 re-review carry-over).
    func publish(raw: [URL], as name: String, header: String?, pinned: [String: String] = [:]) async -> (parts: [String], tail: String) {
        let pin = Redactor()
        pin.update(pinned.map { (name: $0.key, value: $0.value) }, version: "pinned")
        return await blocking.run { [self] in
            let parts = raw.map { url -> String in
                defer { _ = try? EngineFiles.removeNoFollow(url, under: releaseDir) }
                return pin.apply(Self.scrubbedText(url, under: releaseDir, store: store))
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
            return (parts, pin.apply(store.redactor.apply(String(whole.suffix(Self.tailChars)))))
        }
    }

    /// A raw output file scrubbed in place, then read (at most `readLimit`); "" when it is absent, unsafe or not scrubbable.
    static func scrubbedText(_ url: URL, under root: URL, store: Store) -> String {
        guard store.scrubOrRemoveSmokeLog(url), let data = EngineFiles.readNoFollow(url, under: root, limit: readLimit) else { return "" }
        return store.redactor.apply(String(decoding: data, as: UTF8.self))
    }
}
