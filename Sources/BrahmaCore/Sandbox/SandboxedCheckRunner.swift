import Foundation
import GRDB

/// How one engine-run check is run, decided from its working directory.
public enum CheckRoute: Sendable {
    case sandboxed(SandboxPolicy)
    /// The company runs Full: the plain `ProcessCheckRunner`.
    case unsandboxed
    /// Not a place the engine runs a check in (or its own places could not be prepared): nothing runs, with a precise
    /// reason for the log and the outcome tail (B-I2c).
    case refused(String)
}

/// The engine's check runner: every check runs under the sandbox its route gives (`Orchestrator.checkRoute`), a Full
/// company's through `fallback`, anything else not at all. 3a's snapshot integrity guard (`Store.snapshotTamper`) still
/// runs before this is ever called (`Orchestrator.performCheck`).
public struct SandboxedCheckRunner: CheckRunning {
    public static let refusedTail = "check directory is outside every company workspace"

    let sandbox: any SandboxedRunner
    let route: @Sendable (String) -> CheckRoute
    let fallback: any CheckRunning

    public init(sandbox: any SandboxedRunner, route: @escaping @Sendable (String) -> CheckRoute,
                fallback: any CheckRunning = ProcessCheckRunner()) {
        self.sandbox = sandbox; self.route = route; self.fallback = fallback
    }

    public func run(command: String, workingDirectory: URL, timeout: TimeInterval, outputURL: URL,
                    environment: [String: String]) async -> CheckOutcome {
        // The route reads the database, calls realpath and creates the shared cache: blocking work, so it runs on a thread of
        // its own, never the cooperative pool (3a's rule; B-M6). `SeatbeltRunner` likewise does its `prepare` on the check's
        // own thread.
        let route = self.route
        let decided: CheckRoute = await withCheckedContinuation { continuation in
            let thread = Thread { continuation.resume(returning: route(workingDirectory.path)) }
            thread.name = "brahma-check-route"
            thread.start()
        }
        switch decided {
        case .refused(let why):
            return GroupRun.fail(why.isEmpty ? Self.refusedTail : why, outputURL: outputURL)
        case .unsandboxed:
            return await fallback.run(command: command, workingDirectory: workingDirectory, timeout: timeout, outputURL: outputURL,
                                      environment: environment)
        case .sandboxed(let policy):
            return await sandbox.run(command: command, cwd: workingDirectory, environment: environment, timeout: .seconds(timeout),
                                     outputURL: outputURL, policy: policy)
        }
    }
}

extension Orchestrator {
    /// The route of an engine-run check, from the engine's own record of the run, never from what is on disk:
    /// - the working directory must be exactly the place 3a's engine made for that run: `<home>/run/checkouts/<runId>` for
    ///   a submission's check, `<home>/run/exports/<runId>` for a merge check (`GitWorkspace.checkoutPath`/`exportPath`, by
    ///   the run's purpose), the run must be `running`, and its recorded directory must be that place; otherwise `.refused`;
    /// - the run's company runs Full (its own profile, and its item holder's role profile too when there is a holder):
    ///   `.unsandboxed`;
    /// - otherwise `.sandboxed`: writable = exactly that checkout (or export) and the company's shared check cache
    ///   (`SandboxLayout.sharedCache`, created without following a link); readable = the company workspace; network =
    ///   `.outbound(allow: CompanyNetwork.scope(...).allowedDomains)`; toolchain on. A merge check writes only its export
    ///   (no shared cache, B-I3). Nothing else of the data home is in the policy, so the rest of it (the database, other
    ///   runs, the merge repository) stays unreadable and unwritable. A `.brahma/cache/shared` a check turned into a link is
    ///   removed (without following it) and recreated; a refusal carries a precise reason (B-I2).
    public static func checkRoute(store: Store) -> @Sendable (String) -> CheckRoute {
        { cwd in
            let dir = URL(fileURLWithPath: cwd, isDirectory: true)
            let runId = dir.lastPathComponent
            guard let run = try? store.writer.read({ try VerificationRun.fetchOne($0, key: runId) }) else {
                return .refused("no engine record of a check running in \(runId)")
            }
            guard run.status == .running else { return .refused("the check run \(runId) is not running (\(run.status.rawValue))") }
            guard let company = try? store.company(id: run.companyId) else { return .refused("the company of run \(runId) is gone") }
            let ws = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
            let git = store.gitWorkspace(root: ws, companyId: company.id)
            // The exact place 3a's engine made for this run, by the run's recorded purpose (exhaustive; a new purpose must
            // choose a place here rather than fall through to a checkout policy — B-M4).
            let place: URL
            switch run.purpose {
            case .merge: place = git.exportPath(runId: run.id)
            case .submit: place = git.checkoutPath(runId: run.id)
            }
            func same(_ a: String, _ b: String) -> Bool {
                URL(fileURLWithPath: a).standardizedFileURL.path == URL(fileURLWithPath: b).standardizedFileURL.path
            }
            guard same(place.path, cwd) else { return .refused("\(cwd) is not run \(runId)'s \(run.purpose.rawValue) place") }
            guard same(run.workingDirectory, cwd) else { return .refused("run \(runId) did not record \(cwd) as its directory") }

            if company.permissionProfile == .full {
                let holder = (try? store.lease(itemId: run.itemId))?.agentId ?? run.requestedBy
                let role = holder.flatMap { try? store.agent(id: $0) }?.role
                if role.map({ company.profile(forRole: $0) == .full }) ?? true { return .unsandboxed }
            }

            // The workspace may sit behind a link the owner chose; everything under it is built logically and must be real.
            let wsReal = ws.resolvedForSandbox
            guard SandboxPath.kind(wsReal.path) == .directory else { return .refused("the workspace of \(company.id) is not a directory") }
            // The engine made the checkout/export; it must be a real directory, named by its resolved path.
            let checkout = URL(fileURLWithPath: SandboxPath.resolve(place.path), isDirectory: false)
            guard SandboxPath.kind(checkout.path) == .directory else { return .refused("the \(run.purpose.rawValue) place of \(runId) is missing") }

            let network = CompanyNetwork.scope(company: company, grantDomains: [], grantWebDomains: []).allowedDomains
            // A merge check writes only its export: no shared cache, so a submission check of this company can never have
            // left config that runs during the merge gate (B-I3).
            if run.purpose == .merge {
                return .sandboxed(SandboxPolicy(writable: [checkout], readable: [wsReal], network: .outbound(allow: network), toolchain: true))
            }
            let layout = SandboxLayout(paths: BrahmaPaths(home: store.dataHome ?? wsReal, workspaces: wsReal.deletingLastPathComponent()),
                                       company: company, agentHandle: "check")
            let cacheRelative = String(layout.sharedCache.path.dropFirst(layout.workspace.path.count + 1))
            let cache = wsReal.appending(path: cacheRelative)
            // B-I2: `cache/shared` must be a real directory with no link anywhere below the workspace. If a check made it a
            // link or an odd file, the engine removes it (anchored, no link followed) and recreates it, so one check cannot
            // silently stop its company's later checks. A link above it (in `.brahma/cache`) is engine territory: refuse.
            let cacheParent = wsReal.appending(path: ".brahma/cache")
            if SandboxPath.kind(cache.path) != .directory || SandboxPath.linkedComponent(cache.path, under: wsReal.path) != nil {
                if SandboxPath.linkedComponent(cacheParent.path, under: wsReal.path) != nil {
                    return .refused("\(cacheParent.path) is not a real engine directory")
                }
                _ = try? EngineFiles.removeNoFollow(cache, under: cacheParent)
            }
            guard (try? EngineFiles.directory(workspace: wsReal, cacheRelative, mode: 0o700)) != nil,
                  SandboxPath.kind(cache.path) == .directory, SandboxPath.linkedComponent(cache.path, under: wsReal.path) == nil else {
                return .refused("the shared check cache of \(company.id) could not be prepared")
            }
            return .sandboxed(SandboxPolicy(writable: [checkout, cache], readable: [wsReal], network: .outbound(allow: network),
                                            toolchain: true))
        }
    }

    /// The default check runner: `SandboxedCheckRunner` over the platform sandbox (Seatbelt on macOS, else fail closed) with
    /// `checkRoute`. The baseline is the owner's (`SandboxBaseline.current`) with the data home (and the store's, if
    /// different) as engine homes, every company's workspace listed, and the owner's backup folders and WAL replica
    /// protected (`checkBaseline`).
    static func defaultCheckRunner(store: Store, paths: BrahmaPaths) -> any CheckRunning {
        let baseline: @Sendable () -> SandboxBaseline = { checkBaseline(store: store, paths: paths) }
        return SandboxedCheckRunner(sandbox: SandboxRunners.platformDefault(baseline: baseline, proxies: EgressProxyPool()),
                                    route: checkRoute(store: store))
    }

    /// The Seatbelt baseline of one check run, taken when it starts (so a backup folder added since is protected).
    static func checkBaseline(store: Store, paths: BrahmaPaths) -> SandboxBaseline {
        var b = SandboxBaseline.current(paths: paths, otherWorkspaces: [],
                                        backupTargets: BackupTargets.protectedFolders(store: store))
        if let home = store.dataHome?.resolvedForSandbox, !b.engineHomes.contains(home) { b.engineHomes.append(home) }
        do {
            b.companyWorkspaces = try store.companies().map { URL(fileURLWithPath: $0.workspacePath, isDirectory: false).resolvedForSandbox }
        } catch {
            b.problem = "could not list the company workspaces (\(error))"
        }
        return b
    }
}
