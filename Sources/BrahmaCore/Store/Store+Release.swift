import Foundation
import GRDB

/// The smoke check on main (Plan L Task 5): who sets it, the queue of runs, the one path that executes a run (`runSmoke`) and
/// the red-main bug.
extension Store {
    static let smokeCheckRole = "set_smoke_check is not available to your role"
    static let manualSmokeOwnerOnly = "only the owner can request a smoke run"
    static let noMainYet = "main has no engine-recorded commit yet"
    static let redBugDescription = "The engine's smoke check failed on main. Fix main; deploys are blocked until it passes."

    // MARK: Setting it

    /// An ops agent (a role whose pack template lists `set_smoke_check`, `CompanyToolNames.ops`) sets the command the engine
    /// runs on every new `main` and before every deploy, or clears it (`check` nil). The command is agent text: redacted, then
    /// validated as a `CheckSpec` (600 s default, 3600 s ceiling). An activity line records it.
    @discardableResult
    public func setSmokeCheck(companyId: String, by agentId: String, check: CheckSpec?, now: Date = Store.now()) throws -> Company {
        let check = try redact(check)
        try check?.validate()
        return try writer.write { db in
            guard let agent = try Agent.fetchOne(db, key: agentId), agent.companyId == companyId, agent.state != .killed else {
                throw WorkError.forbidden("not in your company")
            }
            guard var company = try Company.fetchOne(db, key: companyId) else { throw WorkError.notFound("no such company") }
            guard catalog.template(role: agent.role, pack: company.packId).companyTools.contains("set_smoke_check") else {
                throw WorkError.forbidden(Self.smokeCheckRole)
            }
            company.smokeCheck = check
            company.smokeCheckSetById = check == nil ? nil : agent.id
            try company.update(db)
            let text = check.map { "@\(agent.name) set the smoke check on main: \(Self.flat($0.command, max: 200))" }
                ?? "@\(agent.name) cleared the smoke check on main; deploys are blocked until one is set"
            try ActivityEvent(companyId: companyId, agentId: agent.id, turnId: nil, kind: .release, text: text, createdAt: now).insert(db)
            return company
        }
    }

    // MARK: Reading

    public func mainSmokeRuns(companyId: String) throws -> [MainSmokeRun] {
        try writer.read { db in
            try MainSmokeRun.filter(Column("companyId") == companyId).order(Column("createdAt"), Column.rowID).fetchAll(db)
        }
    }

    public func mainSmokeRun(id: String) throws -> MainSmokeRun? {
        try writer.read { db in try MainSmokeRun.fetchOne(db, key: id) }
    }

    /// The company's newest smoke run, of any reason or status.
    public func latestMainSmoke(companyId: String) throws -> MainSmokeRun? {
        try writer.read { db in
            try MainSmokeRun.filter(Column("companyId") == companyId)
                .order(Column("createdAt").desc, Column.rowID.desc).fetchOne(db)
        }
    }

    /// The latest result (`passed` or `failed`; `error` is none) at `commit` (`ReleasePolicy.mainIsGreen`).
    func latestResult(companyId: String, commit: String) throws -> MainSmokeRun? {
        try writer.read { db in
            try MainSmokeRun.filter(Column("companyId") == companyId && Column("commit") == commit
                                    && [MainSmokeStatus.passed.rawValue, MainSmokeStatus.failed.rawValue].contains(Column("status")))
                .order(Column("finishedAt").desc, Column.rowID.desc).fetchOne(db)
        }
    }

    /// The queued run the company's smoke slot runs next (after superseding there is at most one).
    func nextQueuedSmoke(companyId: String) throws -> MainSmokeRun? {
        try writer.read { db in
            try MainSmokeRun.filter(Column("companyId") == companyId && Column("status") == MainSmokeStatus.queued.rawValue)
                .order(Column("createdAt").desc, Column.rowID.desc).fetchOne(db)
        }
    }

    // MARK: Queueing

    /// The owner asks for a smoke run of `main` now: a new `manual` row at the engine-accepted head (PR-12: never a reused
    /// result), queued for the tick. Any other sender: `"only the owner can request a smoke run"`.
    @discardableResult
    public func requestManualSmoke(companyId: String, by sender: Sender, now: Date = Store.now()) throws -> MainSmokeRun {
        guard sender == .owner else { throw WorkError.forbidden(Self.manualSmokeOwnerOnly) }
        return try writer.write { db in
            guard let company = try Company.fetchOne(db, key: companyId) else { throw WorkError.notFound("no such company") }
            guard company.smokeCheck != nil else { throw WorkError.invalid(ReleasePolicy.noSmokeCheck) }
            guard let main = company.mainCommit else { throw WorkError.invalid(Self.noMainYet) }
            let run = try Self.queueSmoke(db, companyId: companyId, commit: main, reason: .manual, now: now)
            try ActivityEvent(companyId: companyId, agentId: nil, turnId: nil, kind: .release,
                              text: "owner requested a smoke run of main \(run.sha7)", createdAt: now).insert(db)
            return run
        }
    }

    /// The tick's "main smoke" step: when the company has a smoke check and its engine-accepted `main` (PR-22) has no `merge`
    /// run yet, one is queued. Returns the queued run, or nil when nothing was needed.
    @discardableResult
    func queueMergeSmokeIfNeeded(companyId: String, now: Date) throws -> MainSmokeRun? {
        try writer.write { db in
            guard let company = try Company.fetchOne(db, key: companyId), company.smokeCheck != nil,
                  let main = company.mainCommit else { return nil }
            let exists = try MainSmokeRun.filter(Column("companyId") == companyId && Column("commit") == main
                                                 && Column("reason") == MainSmokeReason.merge.rawValue).fetchCount(db) > 0
            guard !exists else { return nil }
            return try Self.queueSmoke(db, companyId: companyId, commit: main, reason: .merge, now: now)
        }
    }

    /// Inserts a queued run; every older queued run of the company is superseded (`error`, `"superseded"`).
    static func queueSmoke(_ db: Database, companyId: String, commit: String, reason: MainSmokeReason, now: Date) throws -> MainSmokeRun {
        try db.execute(sql: """
            UPDATE mainSmokeRun SET status = ?, outputTail = ?, finishedAt = ? WHERE companyId = ? AND status = ?
            """, arguments: [MainSmokeStatus.error.rawValue, ReleasePolicy.superseded, now, companyId, MainSmokeStatus.queued.rawValue])
        let run = MainSmokeRun(companyId: companyId, commit: commit, reason: reason, createdAt: now)
        try run.insert(db)
        return run
    }

    // MARK: Running

    /// Start-up recovery (fix I1): every run an earlier engine left `running` is handled here, and its stale export and raw
    /// log are cleaned up by the caller (`Orchestrator.recoverSmokes`):
    /// - a `merge` run at the engine-accepted main goes back to `queued` in place (the partial unique index keeps one merge
    ///   row per commit, so it must be the same row), and runs again;
    /// - any other is `error` ("engine restarted"), with no red-main effect.
    /// Returns the runs that were running (their old state), for the clean-up.
    func recoverSmokes(now: Date) throws -> [MainSmokeRun] {
        try writer.write { db in
            let running = try MainSmokeRun.filter(Column("status") == MainSmokeStatus.running.rawValue).fetchAll(db)
            for var run in running {
                let main = try Company.fetchOne(db, key: run.companyId)?.mainCommit
                if run.reason == .merge, run.commit == main {
                    Self.resetToQueued(&run)
                } else {
                    run.status = .error; run.outputTail = ReleasePolicy.engineRestarted; run.finishedAt = now
                }
                try run.update(db)
            }
            return running
        }
    }

    static func resetToQueued(_ run: inout MainSmokeRun) {
        run.status = .queued; run.startedAt = nil; run.finishedAt = nil; run.exitCode = nil; run.outputTail = nil; run.outputPath = nil
    }

    /// Puts a `merge` run that could not finish for the engine's own reasons (cancelled at shutdown, an export failure) back
    /// to `queued` in place while its commit is still the engine-accepted main; otherwise records it `error` with `tail`.
    func requeueOrError(_ run: MainSmokeRun, tail: String, now: Date) throws -> MainSmokeRun {
        try writer.write { db in
            var run = run
            let main = try Company.fetchOne(db, key: run.companyId)?.mainCommit
            if run.reason == .merge, run.commit == main {
                Self.resetToQueued(&run)
            } else {
                run.status = .error; run.outputTail = try redact(tail); run.finishedAt = now
            }
            try run.update(db)
            return run
        }
    }

    static func notMain(_ commit: String) -> String { "\(commit.prefix(7)) is not the engine-accepted main" }

    /// The one path that executes a smoke run outside the tick (Task 7 calls it with reason `release`, through
    /// `Orchestrator.runSmoke`, which holds the company's smoke slot and passes the engine's `Blocking` and clock):
    /// 1. in one write: `commit` must be the engine-accepted main (`company.mainCommit`, else `"<sha7> is not the
    ///    engine-accepted main"`); then the row is inserted or reused, and claimed `running` in that same write, so a queued
    ///    run's superseding can never touch it (fix I3a). A `merge` run at `commit` is reused (PR-12) and claimed if queued;
    ///    a `release` run is reused by `releaseId`; a `manual` run is always a new row. A reused run that is not queued is
    ///    returned as it is;
    /// 2. `EngineExport` the commit into a fresh `.git`-free tree under the data home (`smoke-<id>`);
    /// 3. run the company's smoke check there through `checks` (PR-5);
    /// 4. record the outcome (and the red-main rule).
    func runSmoke(companyId: String, commit: String, reason: MainSmokeReason, releaseId: String?, checks: SmokeChecks,
                  blocking: Blocking, clock: @escaping @Sendable () -> Date) async throws -> MainSmokeRun {
        let now = clock()
        let claimed: (MainSmokeRun, Company, Bool) = try await writer.write { db in
            guard let company = try Company.fetchOne(db, key: companyId) else { throw WorkError.notFound("no such company") }
            guard company.mainCommit == commit else { throw WorkError.invalid(Self.notMain(commit)) }
            var existing: MainSmokeRun?
            switch reason {
            case .merge:
                existing = try MainSmokeRun.filter(Column("companyId") == companyId && Column("commit") == commit
                                                   && Column("reason") == MainSmokeReason.merge.rawValue).fetchOne(db)
            case .release:
                if let releaseId {
                    existing = try MainSmokeRun.filter(Column("companyId") == companyId && Column("releaseId") == releaseId
                                                       && Column("commit") == commit).fetchOne(db)
                }
            case .manual:
                existing = nil
            }
            var run = existing ?? MainSmokeRun(companyId: companyId, commit: commit, reason: reason, releaseId: releaseId, createdAt: now)
            if existing != nil, run.status != .queued { return (run, company, false) }
            run.status = .running; run.startedAt = now; run.outputPath = checks.outputURL(run).path
            if existing == nil { try run.insert(db) } else { try run.update(db) }
            return (run, company, true)
        }
        guard claimed.2 else { return claimed.0 }
        checks.afterClaim?(claimed.0)
        return try await performSmoke(claimed.0, company: claimed.1, checks: checks, blocking: blocking, clock: clock)
    }

    /// Executes the queued run `runId` once (the tick's path): claimed `queued` → `running` in one write, so a second caller
    /// gets the row as it is. Never throws for the run's own failures; they are its recorded outcome.
    func executeSmoke(runId: String, checks: SmokeChecks, blocking: Blocking, clock: @escaping @Sendable () -> Date) async throws -> MainSmokeRun {
        let claimed: (MainSmokeRun, Company)? = try await writer.write { db in
            guard var run = try MainSmokeRun.fetchOne(db, key: runId), run.status == .queued,
                  let company = try Company.fetchOne(db, key: run.companyId) else { return nil }
            run.status = .running
            run.startedAt = clock()
            run.outputPath = checks.outputURL(run).path
            try run.update(db)
            return (run, company)
        }
        guard let (run, company) = claimed else {
            guard let row = try mainSmokeRun(id: runId) else { throw WorkError.notFound("no such smoke run") }
            return row
        }
        return try await performSmoke(run, company: company, checks: checks, blocking: blocking, clock: clock)
    }

    /// Steps 2–4 of a claimed (`running`) run.
    private func performSmoke(_ run: MainSmokeRun, company: Company, checks: SmokeChecks, blocking: Blocking,
                              clock: @escaping @Sendable () -> Date) async throws -> MainSmokeRun {
        guard let spec = company.smokeCheck else {
            return try finishSmoke(run, outcome: CheckOutcome(exitCode: nil, timedOut: false, tail: ReleasePolicy.noSmokeCheck),
                                   spec: nil, now: clock())
        }
        let store = self
        let output = checks.outputURL(run)
        // The export and the log directory: git and file work, off the cooperative pool (PR-1, PR-6).
        let exported: URL? = await blocking.run {
            do {
                try FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
                return try EngineExport.export(store: store, company: company, runId: run.runId, commit: run.commit)
            } catch {
                EngineExport.remove(store: store, company: company, runId: run.runId)
                return nil
            }
        }
        guard let export = exported else {
            // The engine's own failure, not main's: a merge run goes back to the queue (the tick backs off, fix I1).
            return try requeueOrError(run, tail: "could not export \(run.sha7)", now: clock())
        }
        let unsandboxed = PreviewRunner.unsandboxed(store: self, company: company, setById: company.smokeCheckSetById)
        let runner = unsandboxed ? checks.unsandboxed : checks.sandbox
        let policy = Self.smokePolicy(company: company, export: export)
        let environment = ChildEnvironment.make(base: checks.environment,
                                                extra: company.smokeCheckSetById.map { ["BRAHMA_AGENT_ID": $0] } ?? [:],
                                                purpose: .check)
        var outcome = await runner.run(command: spec.command, cwd: export, environment: environment,
                                       timeout: .seconds(spec.timeoutSeconds), outputURL: output, policy: policy)
        if !unsandboxed { outcome = SandboxedCheckRunner.reclassifyNestedSandbox(outcome) }
        let cancelled = Task.isCancelled
        // The export is deleted; the log (agent output) is scrubbed in place, or removed and its tail withheld.
        let scrubbed: Bool = await blocking.run {
            EngineExport.remove(store: store, company: company, runId: run.runId)
            return store.scrubOrRemoveSmokeLog(output)
        }
        // Cancelled (the engine is stopping): no result and never a red bug; a merge run is queued again for the next engine.
        if cancelled { return try requeueOrError(run, tail: ReleasePolicy.engineStopped, now: clock()) }
        if !scrubbed { outcome = CheckOutcome(exitCode: outcome.exitCode, timedOut: outcome.timedOut, tail: Orchestrator.withheldCheckTail) }
        return try finishSmoke(run, outcome: outcome, spec: spec, now: clock())
    }

    /// Scrubs a smoke log in place (`scrubCheckLog`, which removes a log it cannot scrub). True when it is clean or absent.
    func scrubOrRemoveSmokeLog(_ url: URL) -> Bool {
        do { try scrubCheckLog(url); return true } catch let e as CocoaError where e.code == .fileNoSuchFile { return true }
        catch { return false }
    }

    /// The check-shaped policy of a sandboxed smoke (PR-5): writes and reads only its export, the company's outbound
    /// registries (`CompanyNetwork.scope`), the toolchain.
    static func smokePolicy(company: Company, export: URL) -> SandboxPolicy {
        let dir = URL(fileURLWithPath: SandboxPath.resolve(export.path), isDirectory: true)
        let network = CompanyNetwork.scope(company: company, grantDomains: [], grantWebDomains: []).allowedDomains
        return SandboxPolicy(writable: [dir], readable: [dir], network: .outbound(allow: network), toolchain: true)
    }

    /// Records the outcome: `passed` (exit 0), `failed` (another exit, or timed out), `error` (it did not run). Then the
    /// red-main rule, in the same write, for `merge` and `manual` runs:
    /// - a failed run with no open red bug files one (a system bug, P1, ready, the smoke check as its check); with one open,
    ///   it comments there;
    /// - a passed run with a red bug comments `"main is green again at <sha7>"` and clears `redBugItemId`.
    func finishSmoke(_ run: MainSmokeRun, outcome: CheckOutcome, spec: CheckSpec?, now: Date) throws -> MainSmokeRun {
        let tail = try redact(String(outcome.tail.suffix(4000)))
        return try writer.write { db in
            var run = run
            let passed = outcome.exitCode == 0 && !outcome.timedOut
            let failed = !passed && (outcome.timedOut || outcome.exitCode != nil)
            run.status = passed ? .passed : failed ? .failed : .error
            run.exitCode = outcome.timedOut ? nil : outcome.exitCode.map(Int.init)
            run.outputTail = tail
            run.finishedAt = now
            try run.update(db)
            guard run.reason != .release, var company = try Company.fetchOne(db, key: run.companyId) else { return run }
            let open = try company.redBugItemId.flatMap { try WorkItem.fetchOne(db, key: $0) }.flatMap { $0.status == .done ? nil : $0 }
            if run.status == .failed {
                if let bug = open {
                    try recordItemEvent(db: db, item: bug, actor: "system", kind: .commented,
                                        text: "main is still red at \(run.sha7): the smoke check failed (\(run.failure))", now: now)
                } else {
                    let draft = WorkItemDraft(type: WorkItemType("bug"), title: "Main is red at \(run.sha7): smoke check failed",
                                              description: Self.redBugDescription, checkSpec: spec ?? company.smokeCheck,
                                              priority: 1, status: .ready)
                    let bug = try createWorkItem(db: db, companyId: company.id, by: .system, draft: draft, now: now)
                    company.redBugItemId = bug.id
                    try db.execute(sql: "UPDATE company SET redBugItemId = ? WHERE id = ?", arguments: [bug.id, company.id])
                }
                try ActivityEvent(companyId: company.id, agentId: nil, turnId: nil, kind: .release,
                                  text: "main is red at \(run.sha7): the smoke check failed (\(run.failure))", createdAt: now).insert(db)
            } else if run.status == .passed, company.redBugItemId != nil {
                if let bug = open {
                    try recordItemEvent(db: db, item: bug, actor: "system", kind: .commented,
                                        text: "main is green again at \(run.sha7)", now: now)
                }
                try db.execute(sql: "UPDATE company SET redBugItemId = NULL WHERE id = ?", arguments: [company.id])
                try ActivityEvent(companyId: company.id, agentId: nil, turnId: nil, kind: .release,
                                  text: "main is green again at \(run.sha7)", createdAt: now).insert(db)
            }
            return run
        }
    }
}

// MARK: - Releases (Task 6)

/// Files the hosting-account human task when a deploy is proposed without the provider token or the account ID (refusal 7
/// of `Store.proposeDeploy`). Returns the open ask, filing it only when none is open (deduped). Task 9 replaces the stub.
public protocol HumanTaskFiling: Sendable {
    func fileHostingAccount(store: Store, companyId: String, provider: HostingProviderID, now: Date) throws -> Ask
}

/// Until Task 9: an `info` ask with the hosting-account task's title, filed by the engine (`.system`, PR-28: no agent quota
/// is charged), at most one open per company.
public struct StubHumanTaskFiling: HumanTaskFiling {
    public init() {}

    public static func hostingAccountTitle(_ provider: HostingProviderID) -> String {
        switch provider {
        case .cloudflarePages: "Create a Cloudflare account and an API token"
        case .vercel: "Create a Vercel account and a token"
        }
    }

    public func fileHostingAccount(store: Store, companyId: String, provider: HostingProviderID, now: Date) throws -> Ask {
        let title = Self.hostingAccountTitle(provider)
        if let open = try store.asks(companyId: companyId, statuses: [.pendingOwner, .pendingInternal])
            .first(where: { $0.kind == .info && $0.requesterId == "system" && $0.title == title }) {
            return open
        }
        let token = HostingAdapters.adapter(provider).tokenSecret
        return try store.requestFromOwner(companyId: companyId, by: .system, title: title, question: """
            Deploys to \(provider.title) need an account and an API token. Create them, store the token as the company \
            secret \(token) and set the account ID in hosting settings, then answer here.
            """, now: now)
    }
}

extension Store {
    // MARK: Reading

    /// The company's releases, newest first.
    public func releases(companyId: String, limit: Int = 200) throws -> [Release] {
        try writer.read { db in
            try Release.filter(Column("companyId") == companyId).order(Column("number").desc).limit(limit).fetchAll(db)
        }
    }

    /// `R-<n>` of the company (any case), or nil: another company's release is never found.
    public func release(companyId: String, ref: String) throws -> Release? {
        let t = ref.trimmingCharacters(in: .whitespaces)
        guard t.uppercased().hasPrefix("R-"), let n = Int(t.dropFirst(2)), n > 0 else { return nil }
        return try writer.read { db in
            try Release.filter(Column("companyId") == companyId && Column("number") == n).fetchOne(db)
        }
    }

    /// Where the company's deploys run: `<data home>/run/releases/<companyId>` (the same place the executor uses). An
    /// in-memory store has no data home; it uses a stand-in under the temporary directory (nothing is written there).
    func releaseLayout(companyId: String) throws -> ReleaseLayout {
        let home = dataHome ?? FileManager.default.temporaryDirectory.appending(path: "brahma-memory-home", directoryHint: .isDirectory)
        return try ReleaseLayout(paths: BrahmaPaths(home: home, workspaces: home), companyId: companyId)
    }

    // MARK: Proposing

    /// What `propose_deploy` answers on success.
    public static func proposedDeployText(_ r: Release) -> String {
        "Proposed \(r.ref) (release \(r.version) at \(r.sha7)); waiting on the owner."
    }

    /// An ops agent (a role whose pack template lists `propose_deploy`) proposes deploying the engine-accepted `main` as
    /// release `version`. The refusals, in order: the version; a duplicate version; another open release; no output folder;
    /// no smoke check; no `npm` (the owner is told); no token or account (the hosting-account human task is filed, deduped);
    /// `main` not green at its head. On success the release (`proposed`) and its owner-only `deploy` ask are written in one
    /// transaction, with the exact deploy and rollback plans composed by the provider's adapter (injected, PR-25).
    /// Token presence is decided from secret metadata only; `vault` is kept for the brief's signature and unused.
    @discardableResult
    public func proposeDeploy(companyId: String, by agentId: String, version rawVersion: String, notes: String?,
                              now: Date = Store.now(), vault: (any SecretVault)? = nil,
                              adapters: HostingAdapters.Lookup = HostingAdapters.production, layout: ReleaseLayout? = nil,
                              npmPresent: Bool? = nil, humanTasks: any HumanTaskFiling = StubHumanTaskFiling()) throws -> (Release, Ask) {
        let version = rawVersion.trimmingCharacters(in: .whitespaces)
        let notes = try Store.limitedText(try redact(notes), Store.maxAskText, "the notes")
        // Who and the cheap refusals (1–5), read in one snapshot.
        let (company, settings) = try writer.read { db -> (Company, HostingSettings?) in
            guard let agent = try Agent.fetchOne(db, key: agentId), agent.companyId == companyId, agent.state != .killed else {
                throw WorkError.forbidden("not in your company")
            }
            guard let company = try Company.fetchOne(db, key: companyId) else { throw WorkError.notFound("no such company") }
            guard catalog.template(role: agent.role, pack: company.packId).companyTools.contains("propose_deploy") else {
                throw WorkError.forbidden(ReleasePolicy.proposeRole)
            }
            try Self.checkReleaseSlot(db, companyId: companyId, version: version)
            let settings = try HostingSettings.fetchOne(db, key: companyId)
            return (company, settings)
        }
        guard let settings, settings.outputDir != nil else { throw WorkError.invalid(ReleasePolicy.noOutputDir) }
        guard let smokeCheck = company.smokeCheck else { throw WorkError.invalid(ReleasePolicy.noSmokeCheck) }
        // 6. npm, which installs the provider CLI.
        guard npmPresent ?? HostingReadiness.npmOnPath() else {
            try notifyOwner(companyId: companyId, title: "Deploying needs Node.js",
                            body: "Install Node.js (npm) on this Mac so \(company.name) can deploy, then ask again.", now: now)
            throw WorkError.invalid(ReleasePolicy.noNpm)
        }
        // 7. The token and the account (metadata only; the executor reads the token at deploy time).
        let adapter = adapters(settings.provider)
        let tokenPresent = try secrets(companyId: companyId).contains { $0.name == adapter.tokenSecret }
        guard tokenPresent, settings.accountId != nil else {
            let task = try humanTasks.fileHostingAccount(store: self, companyId: companyId, provider: settings.provider, now: now)
            throw WorkError.invalid("The hosting token is missing; I asked the owner (\(task.ref)). Propose again when it is done.")
        }
        // 8. Main must be green at its engine-accepted head (PR-22).
        guard let commit = company.mainCommit else { throw WorkError.invalid(Self.noMainYet) }
        let green = try ReleasePolicy.mainIsGreen(store: self, company: company, at: commit)
        guard green.green else { throw WorkError.invalid(green.reason ?? ReleasePolicy.noSmokeCheck) }

        // The plans, composed outside the write: the commit's tree decides `functions` (PR-24).
        let layout = try layout ?? releaseLayout(companyId: companyId)
        let functions = try gitWorkspace(root: URL(fileURLWithPath: company.workspacePath, isDirectory: true), companyId: companyId)
            .treeHasDirectory(at: commit, path: "functions")
        let (number, previous) = try writer.read { db -> (Int, Release?) in
            let n = (try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(number), 0) + 1 FROM release WHERE companyId = ?",
                                      arguments: [companyId])) ?? 1
            let prev = try Release.filter(Column("companyId") == companyId && Column("status") == ReleaseStatus.deployed.rawValue)
                .order(Column("number").desc).fetchOne(db)
            return (n, prev)
        }
        let input = DeployInput(settings: settings, commit: commit, version: version, layout: layout, release: number, cli: adapter.cli,
                                previousUpload: previous.map { layout.releaseDir($0.number).appending(path: "upload", directoryHint: .isDirectory) },
                                previousDeployURL: previous?.deployURL, functionsInCommit: functions)
        let plan = try adapter.deployPlan(input)
        let rollback = try adapter.rollbackPlan(input)
        let sha7 = String(commit.prefix(7))
        let proposal = Self.deployProposal(settings: settings, adapter: adapter, smokeCheck: smokeCheck, sha7: sha7, plan: plan,
                                           rollback: rollback)

        return try writer.write { db in
            // The slot again, in the write that takes it (a concurrent proposal, or a version taken meanwhile).
            try Self.checkReleaseSlot(db, companyId: companyId, version: version)
            let latestNumber = (try Int.fetchOne(db, sql: "SELECT COALESCE(MAX(number), 0) + 1 FROM release WHERE companyId = ?",
                                                 arguments: [companyId])) ?? 1
            let latestMain = try Company.fetchOne(db, key: companyId)?.mainCommit
            guard latestNumber == number, latestMain == commit else {
                throw WorkError.conflict("main or the releases changed while proposing; propose again")
            }
            var release = Release(companyId: companyId, number: number, version: version, provider: settings.provider,
                                  project: settings.project, commit: commit, previousReleaseId: previous?.id, build: settings.build,
                                  outputDir: settings.outputDir, plan: plan, rollbackPlan: rollback, notes: notes, proposedById: agentId,
                                  createdAt: now)
            let summary = notes ?? "Release \(version) of main at \(sha7)."
            let ask = try propose(db: db, companyId: companyId, by: .agent(agentId), kind: .deploy, risk: .high, category: nil,
                                  title: "Deploy \(version) to \(settings.provider.title) at \(sha7)", summary: summary,
                                  payload: AskPayload(proposal: proposal), document: nil, itemId: nil, subjectId: release.id,
                                  supersedes: nil, requestId: nil, decisionClass: .taste, viaOwner: true, now: now)
            release.askId = ask.id
            try release.insert(db)
            let agentName = try Agent.fetchOne(db, key: agentId)?.name ?? "agent"
            try ActivityEvent(companyId: companyId, agentId: agentId, turnId: nil, kind: .release,
                              text: "@\(agentName) proposed \(release.ref): release \(version) at \(sha7) (\(ask.ref) waits on the owner)",
                              createdAt: now).insert(db)
            return (release, ask)
        }
    }

    /// Refusals 1–3: the version's form, a version already used, another open release.
    static func checkReleaseSlot(_ db: Database, companyId: String, version: String) throws {
        guard ReleasePolicy.validVersion(version) else { throw WorkError.invalid(ReleasePolicy.badVersion) }
        if try Release.filter(Column("companyId") == companyId && Column("version") == version).fetchCount(db) > 0 {
            throw WorkError.conflict("release \(version) already exists")
        }
        if let open = try Release.filter(Column("companyId") == companyId && ReleaseStatus.openRawValues.contains(Column("status")))
            .order(Column("number")).fetchOne(db) {
            throw WorkError.conflict("\(open.ref) is still \(open.status.rawValue)")
        }
    }

    /// The deploy ask's `proposal`: exactly what the engine will do. Agent-written fields (the build, the smoke command, smoke
    /// paths and the expected text) are flattened to one line each; `propose` redacts the whole text before it is stored.
    static func deployProposal(settings: HostingSettings, adapter: any HostingAdapter, smokeCheck: CheckSpec, sha7: String,
                               plan: DeployPlan, rollback: DeployPlan) -> String {
        let build = settings.build.map { flat($0, max: HostingSettings.maxBuild) } ?? "none"
        let base = adapter.smokeBase(settings, deployURL: nil)?.absoluteString ?? "the deploy URL"
        let requests = settings.smoke.isEmpty ? [SmokeRequest(method: "GET", path: "/")] : settings.smoke
        let lines = requests.map { r in
            flat([r.method, r.path, r.body, r.expectStatus.map(String.init)].compactMap { $0 }.joined(separator: " "), max: 300)
        }.joined(separator: ", ")
        let expecting = settings.expectText.map { ", expecting \"\(flat($0, max: HostingSettings.maxExpectText))\"" } ?? ""
        return """
            Build (sandboxed, no token): \(build) → \(settings.outputDir ?? "")
            Smoke on main at \(sha7) just before deploying: \(flat(smokeCheck.command, max: 2000))
            Deploy (engine, token $\(plan.tokenSecret) from Keychain), in order:
            \(plan.display)
            Rollback recorded now:
            \(rollback.display)
            Smoke after deploy: \(base) \(lines)\(expecting)
            """
    }

    // MARK: The owner's decision

    /// The `deploy` ask's final status moves its release (`applyAskEffects`): rejected (or expired) → `rejected`; approved →
    /// `approved` with `approvedAt` and `approvedBy "owner"`. Both only while the release is still `proposed`, so applying an
    /// effect again changes nothing.
    func applyDeployEffects(_ db: Database, ask: Ask, now: Date) throws {
        guard var release = try deployRelease(db, ask: ask), release.status == .proposed else { return }
        switch ask.status {
        case .approved:
            release.status = .approved
            release.approvedAt = now
            release.approvedBy = "owner"
        case .rejected, .expired:
            release.status = .rejected
            release.finishedAt = now
        default:
            return
        }
        try release.update(db)
        try ActivityEvent(companyId: release.companyId, agentId: nil, turnId: nil, kind: .release,
                          text: "\(release.ref) (release \(release.version)) was \(release.status == .approved ? "approved" : "rejected") by the owner",
                          createdAt: now).insert(db)
    }

    /// The owner rescinds an approved `deploy` ask (`reverseAskEffects`): before the executor started, the release is
    /// `cancelled`; once it started nothing changes, and the owner is told to roll back instead.
    func reverseDeployEffects(_ db: Database, ask: Ask, now: Date) throws {
        guard var release = try deployRelease(db, ask: ask) else { return }
        switch release.status {
        case .approved, .proposed:
            release.status = .cancelled
            release.finishedAt = now
            try release.update(db)
            try ActivityEvent(companyId: release.companyId, agentId: nil, turnId: nil, kind: .release,
                              text: "\(release.ref) (release \(release.version)) was cancelled: the owner rescinded \(ask.ref)",
                              createdAt: now).insert(db)
        case .rejected, .cancelled:
            return
        default:
            try notifyOwner(db: db, companyId: release.companyId, kind: .system, urgency: .normal,
                            title: "\(release.ref) already started", body: "Use Roll back in Releases if you want it undone.", now: now)
        }
    }

    /// The release a `deploy` ask decides (by its `askId`, in the ask's company).
    private func deployRelease(_ db: Database, ask: Ask) throws -> Release? {
        guard ask.kind == .deploy else { return nil }
        return try Release.filter(Column("companyId") == ask.companyId && Column("askId") == ask.id).fetchOne(db)
    }
}
