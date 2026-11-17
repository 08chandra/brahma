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
            let outcome = await sandbox.run(command: command, cwd: workingDirectory, environment: environment, timeout: .seconds(timeout),
                                            outputURL: outputURL, policy: policy)
            return Self.reclassifyNestedSandbox(outcome)
        }
    }

    /// A tool that runs its own `sandbox-exec` inside Brahma's sandbox (SwiftPM compiling a manifest, a plugin) cannot nest
    /// and fails with `sandbox_apply: Operation not permitted`. That is not a real check failure, so it is recorded
    /// inconclusive (not counted against the agent) with an actionable tail, rather than bouncing the item (B-I5).
    static func reclassifyNestedSandbox(_ outcome: CheckOutcome) -> CheckOutcome {
        guard outcome.exitCode != nil, outcome.exitCode != 0,
              outcome.tail.contains("sandbox_apply: Operation not permitted") || outcome.tail.contains("sandbox-exec: sandbox_apply")
        else { return outcome }
        let hint = "this check needs --disable-sandbox for SwiftPM inside Brahma's sandbox (e.g. `swift test --disable-sandbox`), "
            + "or build Xcode projects with `xcodebuild -project`, not Swift packages"
        return CheckOutcome(exitCode: nil, timedOut: false, tail: outcome.tail + "\n" + hint)
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
    ///
    /// `ceiling` is the engine's (`brahma run --profile`, final review I4): it narrows the company's and the role's profile
    /// exactly as it does for turns (`turnProfile`), so a check runs unsandboxed only when the narrowed profile is still Full.
    public static func checkRoute(store: Store, ceiling: PermissionProfile? = nil) -> @Sendable (String) -> CheckRoute {
        { cwd in
            let dir = URL(fileURLWithPath: cwd, isDirectory: true)
            let runId = dir.lastPathComponent
            // The engine's record of the run: a verification run (3a's submit and merge checks), or a merge queue run
            // (`MergeRun`, Plan 4a: recorded `running` before its check starts; its place is always an export).
            struct Record { var id: String; var companyId: String; var itemId: String?; var requestedBy: String?; var purpose: String
                            var recordedDirectory: String?
                            /// A merge queue run: its principal is derived from the record (never from a lease alone) and an
                            /// unknown one runs sandboxed.
                            var mergeKind: MergeRun.Kind?; var batchId: String?; var isMergeRun = false }
            let record: Record
            let place: (GitWorkspace) -> URL
            if let run = try? store.writer.read({ try VerificationRun.fetchOne($0, key: runId) }) {
                guard run.status == .running else { return .refused("the check run \(runId) is not running (\(run.status.rawValue))") }
                record = Record(id: run.id, companyId: run.companyId, itemId: run.itemId, requestedBy: run.requestedBy,
                                purpose: run.purpose.rawValue, recordedDirectory: run.workingDirectory)
                // The exact place 3a's engine made for this run, by the run's recorded purpose (exhaustive; a new purpose must
                // choose a place here rather than fall through to a checkout policy — B-M4).
                switch run.purpose {
                case .merge: place = { $0.exportPath(runId: run.id) }
                case .submit: place = { $0.checkoutPath(runId: run.id) }
                }
            } else if let run = try? store.writer.read({ try MergeRun.fetchOne($0, key: runId) }) {
                guard run.status == .running else { return .refused("the merge run \(runId) is not running (\(run.status?.rawValue ?? "unknown"))") }
                record = Record(id: run.id, companyId: run.companyId, itemId: run.itemId, requestedBy: nil, purpose: "merge", recordedDirectory: nil,
                                mergeKind: run.kind, batchId: run.batchId, isMergeRun: true)
                place = { $0.exportPath(runId: run.id) }
            } else {
                return .refused("no engine record of a check running in \(runId)")
            }
            guard let company = try? store.company(id: record.companyId) else { return .refused("the company of run \(runId) is gone") }
            let ws = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
            let git = store.gitWorkspace(root: ws, companyId: company.id)
            let placeURL = place(git)
            func same(_ a: String, _ b: String) -> Bool {
                URL(fileURLWithPath: a).standardizedFileURL.path == URL(fileURLWithPath: b).standardizedFileURL.path
            }
            guard same(placeURL.path, cwd) else { return .refused("\(cwd) is not run \(runId)'s \(record.purpose) place") }
            if let recorded = record.recordedDirectory {
                guard same(recorded, cwd) else { return .refused("run \(runId) did not record \(cwd) as its directory") }
            }

            func narrowed(_ p: PermissionProfile) -> PermissionProfile { ceiling.map { PermissionProfile.narrower(p, $0) } ?? p }
            if narrowed(company.permissionProfile) == .full {
                if record.isMergeRun {
                    // A merge check runs unsandboxed only if EVERY principal whose code it executes narrows to Full: for the main
                    // check its setter and the candidate's item(s) (every item of a batch), for the item check the item's author
                    // (its lease holder and its assignee, both when both exist). A missing principal, an id that is no agent
                    // (or is gone), or none at all runs sandboxed.
                    // A database error on any lookup is not an absent row: the principal could be anyone, so the run is sandboxed.
                    // `mainAtBase` runs main's own scripts at the base, no candidate's code: its principal is the main check's setter
                    // alone (A5, decided here and not left to a default case); an unknown kind is sandboxed.
                    let usesItems = record.mergeKind == .main || record.mergeKind == .item
                    var itemIds = Set(usesItems ? record.itemId.map { [$0] } ?? [] : [])
                    var ids: [String] = []
                    var missing = false
                    if usesItems, let batchId = record.batchId {
                        do { itemIds.formUnion(try store.writer.read { try MergeRequest.filter(Column("batchId") == batchId).fetchAll($0) }.map(\.itemId)) }
                        catch { missing = true }
                    }
                    switch record.mergeKind {
                    case .main: if let setter = company.mainCheckSetById { ids.append(setter) } else { missing = true }
                    case .item: break
                    case .mainAtBase: if let setter = company.mainCheckSetById { ids.append(setter) } else { missing = true }
                    default: missing = true
                    }
                    if usesItems && itemIds.isEmpty { missing = true }
                    for id in itemIds.sorted() {
                        do {
                            let holder = try store.lease(itemId: id)?.agentId, author = try store.workItem(id: id)?.ownerId
                            if holder == nil && author == nil { missing = true }
                            ids.append(contentsOf: [holder, author].compactMap { $0 })
                        } catch { missing = true }
                    }
                    var allFull = !missing && !ids.isEmpty
                    for id in ids where allFull {
                        do {
                            guard let role = try store.agent(id: id)?.role else { allFull = false; break }
                            if narrowed(company.profile(forRole: role)) != .full { allFull = false }
                        } catch { allFull = false }
                    }
                    if allFull { return .unsandboxed }
                } else {
                    let holder = record.itemId.flatMap { try? store.lease(itemId: $0) }?.agentId ?? record.requestedBy
                    let role = holder.flatMap { try? store.agent(id: $0) }?.role
                    if role.map({ narrowed(company.profile(forRole: $0)) == .full }) ?? true { return .unsandboxed }
                }
            }

            // The workspace may sit behind a link the owner chose; everything under it is built logically and must be real.
            let wsReal = ws.resolvedForSandbox
            guard SandboxPath.kind(wsReal.path) == .directory else { return .refused("the workspace of \(company.id) is not a directory") }
            // The engine made the checkout/export; it must be a real directory, named by its resolved path.
            let checkout = URL(fileURLWithPath: SandboxPath.resolve(placeURL.path), isDirectory: false)
            guard SandboxPath.kind(checkout.path) == .directory else { return .refused("the \(record.purpose) place of \(runId) is missing") }

            let network = CompanyNetwork.scope(company: company, grantDomains: [], grantWebDomains: []).allowedDomains
            // A check writes only its own checkout/export — no writable shared cache at all (A re-review ruling). Every
            // toolchain cache is per-run under TMPDIR (SeatbeltRunner), so nothing a check plants can run in a later check
            // or a merge check, and there is no shared `npm` a check could break for its company's later runs.
            return .sandboxed(SandboxPolicy(writable: [checkout], readable: [wsReal], network: .outbound(allow: network),
                                            toolchain: true))
        }
    }

    /// The default check runner: `SandboxedCheckRunner` over the platform sandbox (Seatbelt on macOS, else fail closed) with
    /// `checkRoute`. The baseline is the owner's (`SandboxBaseline.current`) with the data home (and the store's, if
    /// different) as engine homes, every company's workspace listed, and the owner's backup folders and WAL replica
    /// protected (`checkBaseline`).
    static func defaultCheckRunner(store: Store, paths: BrahmaPaths, ceiling: PermissionProfile? = nil) -> any CheckRunning {
        let baseline: @Sendable () -> SandboxBaseline = { checkBaseline(store: store, paths: paths) }
        let onStraggler: @Sendable (StragglerReport) -> Void = { report in reportStragglers(report, store: store) }
        return SandboxedCheckRunner(sandbox: SandboxRunners.platformDefault(baseline: baseline, proxies: EgressProxyPool(),
                                                                            onStraggler: onStraggler),
                                    route: checkRoute(store: store, ceiling: ceiling))
    }

    /// What a sandboxed check left behind, as an owner-visible activity line on its item's company (and the engine log):
    /// killed stragglers are noted (the outcome stands), unkillable or unidentifiable ones say the run was recorded
    /// inconclusive (B-I4, N1/N2).
    static func reportStragglers(_ report: StragglerReport, store: Store) {
        let pids = (report.killed + report.survivors).map(String.init).joined(separator: ", ")
        FileHandle.standardError.write(Data(("brahma orchestrator: a sandboxed check left processes outside its group (pid \(pids)); "
            + (report.inconclusive ? "recorded inconclusive" : "killed") + "\n").utf8))
        guard let runId = report.checkout?.lastPathComponent,
              let run = try? store.writer.read({ try VerificationRun.fetchOne($0, key: runId) }) else { return }
        let key = (try? store.workItem(id: run.itemId))?.key ?? run.itemId
        let text: String
        if report.inconclusive {
            text = "\(key): its check left processes running that could not be "
                + (report.tableUnreadable ? "accounted for (the process table could not be read)" : "killed or identified")
                + "; the run was recorded inconclusive"
        } else {
            text = "\(key): its check left \(report.killed.count) process(es) running outside its group; Brahma killed them"
        }
        try? store.appendEvent(ActivityEvent(companyId: run.companyId, agentId: run.requestedBy, turnId: nil,
                                             kind: report.inconclusive ? .error : .work, text: text, createdAt: Store.now()))
    }

    /// The Seatbelt baseline of one check run, taken when it starts (so a backup folder added since is protected).
    static func checkBaseline(store: Store, paths: BrahmaPaths) -> SandboxBaseline {
        // The backup folders must be known to protect them: a database error fails closed (`problem`), never an empty list
        // (INT-I1).
        var backups: [URL] = []
        var problems: [String] = []
        do { backups = try BackupTargets.requiredProtectedFolders(store: store) } catch {
            problems.append("could not read the backup targets (\(error))")
        }
        var b = SandboxBaseline.current(paths: paths, otherWorkspaces: [], backupTargets: backups)
        if let home = store.dataHome?.resolvedForSandbox, !b.engineHomes.contains(home) { b.engineHomes.append(home) }
        do {
            b.companyWorkspaces = try store.companies().map { URL(fileURLWithPath: $0.workspacePath, isDirectory: false).resolvedForSandbox }
        } catch {
            problems.append("could not list the company workspaces (\(error))")
        }
        if let existing = b.problem { problems.insert(existing, at: 0) }
        if !problems.isEmpty { b.problem = problems.joined(separator: "; ") }
        return b
    }
}
