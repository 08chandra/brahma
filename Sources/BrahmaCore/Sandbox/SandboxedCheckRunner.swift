import Foundation
import GRDB

/// How one engine-run check is run, decided from its working directory.
public enum CheckRoute: Sendable {
    /// The `.check` purpose's policy (`SandboxPolicyFactory.decide`, Plan S Task S7).
    case sandboxed(ValidatedPolicy)
    /// The company runs Full (the factory's `FullOptOut`, never a `Bool`): the plain `ProcessCheckRunner`.
    case unsandboxed(FullOptOut)
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
    /// - the run's company runs Full, and so does the role of its confirmed holder (the lease's agent, else who requested the
    ///   run; a known agent): `.unsandboxed`. An unconfirmed author (no holder, an unknown agent, a lookup that fails) runs
    ///   sandboxed with an activity line (B1);
    /// - otherwise `.sandboxed`: writable = exactly that checkout (or export) and the company's shared check cache
    ///   (`SandboxLayout.sharedCache`, created without following a link); readable = the company workspace; network =
    ///   `.outbound(allow: CompanyNetwork.scope(...).allowedDomains)`; toolchain on. A merge check writes only its export
    ///   (no shared cache, B-I3). Nothing else of the data home is in the policy, so the rest of it (the database, other
    ///   runs, the merge repository) stays unreadable and unwritable. A `.brahma/cache/shared` a check turned into a link is
    ///   removed (without following it) and recreated; a refusal carries a precise reason (B-I2).
    ///
    /// `ceiling` is the engine's (`brahma run --profile`, final review I4): it narrows the company's and the role's profile
    /// exactly as it does for turns (`turnProfile`), so a check runs unsandboxed only when the narrowed profile is still Full.
    ///
    /// Plan S Task S7: the route is `SandboxPolicyFactory.decide(.check(…))` over the checkout and the workspace as verified
    /// `Place`s and the principals resolved above; the policy is validated against `baseline` (the check runner's, taken now;
    /// the owner's when none is given), and a policy the factory refuses is `.refused` with the runner's own refusal text.
    public static func checkRoute(store: Store, ceiling: PermissionProfile? = nil,
                                  baseline: @escaping @Sendable () -> SandboxBaseline = { SandboxBaseline.owner() })
        -> @Sendable (String) -> CheckRoute {
        { cwd in
            let dir = URL(fileURLWithPath: cwd, isDirectory: true)
            let runId = dir.lastPathComponent
            // The engine's record of the run: a verification run (3a's submit and merge checks), or a merge queue run
            // (`MergeRun`, Plan 4a: recorded `running` before its check starts; its place is always an export).
            struct Record { var id: String; var companyId: String; var itemId: String?; var requestedBy: String?; var purpose: String
                            var recordedDirectory: String?
                            /// A merge queue run: its principals are resolved from the record (`.mergeRun`, never from a lease
                            /// alone) and an unknown one runs sandboxed.
                            var isMergeRun = false
                            /// The record itself: the route is decided from it (S6-c1), never from a later re-read.
                            var held: PrincipalResolver.HeldRecord }
            let record: Record
            let place: (GitWorkspace) -> URL
            if let run = try? store.writer.read({ try VerificationRun.fetchOne($0, key: runId) }) {
                guard run.status == .running else { return .refused("the check run \(runId) is not running (\(run.status.rawValue))") }
                record = Record(id: run.id, companyId: run.companyId, itemId: run.itemId, requestedBy: run.requestedBy,
                                purpose: run.purpose.rawValue, recordedDirectory: run.workingDirectory, held: .verificationRun(run))
                // The exact place 3a's engine made for this run, by the run's recorded purpose (exhaustive; a new purpose must
                // choose a place here rather than fall through to a checkout policy — B-M4).
                switch run.purpose {
                case .merge: place = { $0.exportPath(runId: run.id) }
                case .submit: place = { $0.checkoutPath(runId: run.id) }
                }
            } else if let run = try? store.writer.read({ try MergeRun.fetchOne($0, key: runId) }) {
                guard run.status == .running else { return .refused("the merge run \(runId) is not running (\(run.status?.rawValue ?? "unknown"))") }
                record = Record(id: run.id, companyId: run.companyId, itemId: run.itemId, requestedBy: nil, purpose: "merge", recordedDirectory: nil,
                                isMergeRun: true, held: .mergeRun(run))
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

            // The run's subject principals, resolved once for this check (spec §6.2.3, S6): a merge run's by 4a's rule (the
            // setter, the candidate's items and every landed item, each item's holder and author), a verification run's its
            // holder (the lease's agent, else who requested it). The check runs unsandboxed only when every principal and the
            // company itself narrow to Full under the ceiling (`runsUnsandboxed`). In a Full company, an unconfirmed author of a
            // verification run (no holder, an unknown agent, a failed lookup) runs it sandboxed with the B1 activity line; a
            // merge run's unknown principals ran sandboxed before S6 too, and still do without a line (4a).
            // S6-c1: decided from the run record read above; a stored run that no longer matches it (another requester, item
            // or command) is refused, so nothing runs on the stale record. S6-c2: the run supplies only the command and who
            // asked for it; the profiles and the policy's domains come from the live company the resolver read (`live`), and
            // a live company that cannot be read, or whose workspace is not the one checked above, is refused.
            let principals: PrincipalSet
            let live: Company
            switch PrincipalResolver(store: store, ceiling: ceiling).resolve(holding: record.held) {
            case .allow(let resolved, _): (principals, live) = (resolved.principals, resolved.company)
            case .deny(let why): return .refused(why)
            }
            guard live.workspacePath == company.workspacePath else { return .refused("the company of run \(runId) changed while it was starting") }
            if !principals.runsUnsandboxed, !record.isMergeRun, principals.unconfirmedInFullCompany != nil {
                PrincipalResolver.noteSandboxed(principals, store: store, subject: itemSubject(store: store, companyId: record.companyId,
                                                                                               itemId: record.itemId, runId: runId),
                                                kind: .work, agentId: record.requestedBy)
            }

            // The workspace may sit behind a link the owner chose; everything under it is built logically and must be real:
            // a real directory, named by its resolved path (`Place.verify`).
            let wsReal = ws.resolvedForSandbox
            let workspacePlace: Place
            do { workspacePlace = try Place.verify(wsReal, kind: .directory, under: wsReal) } catch {
                return .refused("the workspace of \(company.id) is not a directory")
            }
            // The engine made the checkout/export; it must be a real directory, named by its resolved path, reached from its
            // parent without following a link.
            let checkout = URL(fileURLWithPath: SandboxPath.resolve(placeURL.path), isDirectory: false)
            let checkoutPlace: Place
            do { checkoutPlace = try Place.verify(checkout, kind: .directory, under: checkout.deletingLastPathComponent()) } catch {
                return .refused("the \(record.purpose) place of \(runId) is missing")
            }

            // A check writes only its own checkout/export — no writable shared cache at all (A re-review ruling). Every
            // toolchain cache is per-run under TMPDIR (SeatbeltRunner), so nothing a check plants can run in a later check
            // or a merge check, and there is no shared `npm` a check could break for its company's later runs. The factory's
            // `.check` rule: writable the checkout, readable the workspace, the live company's domains, the toolchain; Full
            // only when every principal and the company narrow to Full (`runsUnsandboxed`).
            let kind: CheckKind = record.isMergeRun ? .mergeQueue : (record.purpose == "merge" ? .merge : .submit)
            switch SandboxPolicyFactory.decide(.check(kind), principals: principals,
                                               places: .check(checkout: checkoutPlace, workspace: workspacePlace),
                                               network: CompanyNetwork.scope(company: live, grantDomains: [], grantWebDomains: []),
                                               baseline: baseline()) {
            case .sandboxed(let policy): return .sandboxed(policy)
            case .fullOptOut(let optOut): return .unsandboxed(optOut)
            case .refused(let why): return .refused(PolicyRefusal.tail(why))
            }
        }
    }

    /// The subject of a check's B1 line: its item's key (company-scoped), else the run.
    private static func itemSubject(store: Store, companyId: String, itemId: String?, runId: String) -> String {
        guard let itemId else { return "run \(runId)" }
        do {
            return try store.writer.read { db in
                try WorkItem.filter(Column("id") == itemId && Column("companyId") == companyId).fetchOne(db)
            }?.key ?? "run \(runId)"
        } catch {
            return "run \(runId)"
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
                                    route: checkRoute(store: store, ceiling: ceiling, baseline: baseline))
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
