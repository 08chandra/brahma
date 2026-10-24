import Foundation
import GRDB

/// How one engine-run check is run, decided from its working directory.
public enum CheckRoute: Sendable {
    case sandboxed(SandboxPolicy)
    /// The company runs Full: the plain `ProcessCheckRunner`.
    case unsandboxed
    /// Not a place the engine runs a check in: nothing runs.
    case refused
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
        switch route(workingDirectory.path) {
        case .refused:
            return GroupRun.fail(Self.refusedTail, outputURL: outputURL)
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
    ///   `.outbound(allow: CompanyNetwork.scope(...).allowedDomains)`; toolchain on. Nothing else of the data home is in
    ///   the policy, so the rest of it (the database, other runs, the merge repository) stays unreadable and unwritable.
    public static func checkRoute(store: Store) -> @Sendable (String) -> CheckRoute {
        { cwd in
            let dir = URL(fileURLWithPath: cwd, isDirectory: true)
            let runId = dir.lastPathComponent
            guard let run = try? store.writer.read({ try VerificationRun.fetchOne($0, key: runId) }), run.status == .running,
                  let company = try? store.company(id: run.companyId) else { return .refused }
            let ws = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
            let git = store.gitWorkspace(root: ws, companyId: company.id)
            let place = run.purpose == .merge ? git.exportPath(runId: run.id) : git.checkoutPath(runId: run.id)
            func same(_ a: String, _ b: String) -> Bool {
                URL(fileURLWithPath: a).standardizedFileURL.path == URL(fileURLWithPath: b).standardizedFileURL.path
            }
            guard same(place.path, cwd), same(run.workingDirectory, cwd) else { return .refused }

            if company.permissionProfile == .full {
                let holder = (try? store.lease(itemId: run.itemId))?.agentId ?? run.requestedBy
                let role = holder.flatMap { try? store.agent(id: $0) }?.role
                if role.map({ company.profile(forRole: $0) == .full }) ?? true { return .unsandboxed }
            }

            // The workspace may sit behind a link the owner chose; everything under it is built logically and must be real.
            let wsReal = ws.resolvedForSandbox
            guard SandboxPath.kind(wsReal.path) == .directory else { return .refused }
            let layout = SandboxLayout(paths: BrahmaPaths(home: store.dataHome ?? wsReal, workspaces: wsReal.deletingLastPathComponent()),
                                       company: company, agentHandle: "check")
            let relative = String(layout.sharedCache.path.dropFirst(layout.workspace.path.count + 1))
            guard (try? EngineFiles.directory(workspace: wsReal, relative, mode: 0o700)) != nil else { return .refused }
            let cache = wsReal.appending(path: relative)
            guard SandboxPath.linkedComponent(cache.path, under: wsReal.path) == nil else { return .refused }
            // The engine made the checkout; it must be a real directory, named by its resolved path.
            let checkout = URL(fileURLWithPath: SandboxPath.resolve(place.path), isDirectory: false)
            guard SandboxPath.kind(checkout.path) == .directory else { return .refused }

            let network = CompanyNetwork.scope(company: company, grantDomains: [], grantWebDomains: []).allowedDomains
            return .sandboxed(SandboxPolicy(writable: [checkout, cache], readable: [wsReal], network: .outbound(allow: network),
                                            toolchain: true))
        }
    }

    /// The default check runner: `SandboxedCheckRunner` over the platform sandbox (Seatbelt on macOS, else fail closed) with
    /// `checkRoute`. The baseline is the owner's (`SandboxBaseline.current`) with the data home (and the store's, if
    /// different) as engine homes and every company's workspace listed; backup targets are not known here yet (Task 13b).
    static func defaultCheckRunner(store: Store, paths: BrahmaPaths) -> any CheckRunning {
        let baseline: @Sendable () -> SandboxBaseline = {
            var b = SandboxBaseline.current(paths: paths, otherWorkspaces: [], backupTargets: [])
            if let home = store.dataHome?.resolvedForSandbox, !b.engineHomes.contains(home) { b.engineHomes.append(home) }
            do {
                b.companyWorkspaces = try store.companies().map { URL(fileURLWithPath: $0.workspacePath, isDirectory: false).resolvedForSandbox }
            } catch {
                b.problem = "could not list the company workspaces (\(error))"
            }
            return b
        }
        return SandboxedCheckRunner(sandbox: SandboxRunners.platformDefault(baseline: baseline, proxies: EgressProxyPool()),
                                    route: checkRoute(store: store))
    }
}
