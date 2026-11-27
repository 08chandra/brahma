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

    /// The latest result (`passed` or `failed`; `error` is none) at `commit` (`ReleasePolicy.mainIsGreen`, `brahma release`).
    public func latestResult(companyId: String, commit: String) throws -> MainSmokeRun? {
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
    /// The engine-accepted main no longer descends from a release's commit (final-review I1's re-check inside the slot).
    static func noLongerOnMain(_ commit: String) -> String { "\(commit.prefix(7)) is no longer on the engine-accepted main" }

    /// The one path that executes a smoke run outside the tick (Task 7 calls it with reason `release`, through
    /// `Orchestrator.runSmoke`, which holds the company's smoke slot and passes the engine's `Blocking` and clock):
    /// 1. in one write: `commit` must be the engine-accepted main (`company.mainCommit`, else `"<sha7> is not the
    ///    engine-accepted main"`) — or, for a `release` run only, `acceptedMain` must still be the engine-accepted main: the
    ///    executor passes the main it checked `commit` is an ancestor of (`main` moved on after the release was proposed;
    ///    the release still deploys, and smokes, its own commit), and the company's smoke check must still be the one pinned on
    ///    the release (final-review m2). Then the row is inserted or reused, and claimed `running` in that same write, so a queued
    ///    run's superseding can never touch it (fix I3a). A `merge` run at `commit` is reused (PR-12) and claimed if queued;
    ///    a `release` run is reused by `releaseId`; a `manual` run is always a new row. A reused run that is not queued is
    ///    returned as it is;
    /// 2. `EngineExport` the commit into a fresh `.git`-free tree under the data home (`smoke-<id>`);
    /// 3. run the company's smoke check there through `checks` (PR-5);
    /// 4. record the outcome (and the red-main rule).
    func runSmoke(companyId: String, commit: String, reason: MainSmokeReason, releaseId: String?, acceptedMain: String? = nil,
                  checks: SmokeChecks, blocking: Blocking, clock: @escaping @Sendable () -> Date) async throws -> MainSmokeRun {
        let now = clock()
        let claimed: (MainSmokeRun, Company, Bool) = try await writer.write { db in
            guard let company = try Company.fetchOne(db, key: companyId) else { throw WorkError.notFound("no such company") }
            let descends = reason == .release && acceptedMain != nil && company.mainCommit == acceptedMain
            guard company.mainCommit == commit || descends else { throw WorkError.invalid(Self.notMain(commit)) }
            // Final-review m2: a release's smoke runs only the check the owner approved (pinned on the release), checked in
            // the write that claims the run, so a change after approval can never weaken the gate.
            if reason == .release, let releaseId, let release = try Release.fetchOne(db, key: releaseId), release.companyId == companyId,
               release.smokeCheck != company.smokeCheck {
                throw WorkError.conflict(ReleasePolicy.smokeChanged)
            }
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
        // The smoke's subject principals, resolved once for this run (S6): the smoke check's setter. Unsandboxed only when it and
        // the company narrow to Full under the ceiling; in a Full company an unconfirmed setter runs sandboxed with the B1 line.
        let principals = PrincipalResolver(store: self, ceiling: checks.ceiling).resolve(.mainSmoke(companyId: company.id))
        PrincipalResolver.noteSandboxed(principals, store: self, subject: "The main smoke check", kind: .release, now: clock())
        let unsandboxed = principals.runsUnsandboxed
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
/// of `Store.proposeDeploy`). Returns the open ask, filing it only when none is open (deduped). Task 9's
/// `EngineHumanTaskFiling` (Store+HumanTasks) is the real one.
public protocol HumanTaskFiling: Sendable {
    func fileHostingAccount(store: Store, companyId: String, provider: HostingProviderID, now: Date) throws -> Ask
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
                              npmPresent: Bool? = nil, humanTasks: any HumanTaskFiling = EngineHumanTaskFiling()) throws -> (Release, Ask) {
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
        let adapter = adapters(settings.provider)
        // Final-fix2 R2: a provider whose per-deploy URLs are not public (Vercel's deployment protection) is smoked only at
        // the owner's production URL; with none recorded nothing is proposed (the executor checks again before any token step).
        if let why = adapter.productionURLRequired, settings.productionURL == nil { throw WorkError.invalid(why) }
        // 6. npm, which installs the provider CLI.
        guard npmPresent ?? HostingReadiness.npmOnPath() else {
            try notifyOwner(companyId: companyId, title: "Deploying needs Node.js",
                            body: "Install Node.js (npm) on this Mac so \(company.name) can deploy, then ask again.", now: now)
            throw WorkError.invalid(ReleasePolicy.noNpm)
        }
        // 7. The token and the account (metadata only; the executor reads the token at deploy time).
        let tokenPresent = try secrets(companyId: companyId).contains { $0.name == adapter.tokenSecret }
        guard tokenPresent, settings.accountId != nil else {
            let task = try humanTasks.fileHostingAccount(store: self, companyId: companyId, provider: settings.provider, now: now)
            // Final-review m10: say what is actually missing.
            let missing = !tokenPresent && settings.accountId == nil ? "The hosting token and account ID are missing"
                : !tokenPresent ? "The hosting token is missing" : "The hosting account ID is missing"
            throw WorkError.invalid("\(missing); I asked the owner (\(task.ref)). Propose again when it is done.")
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
            let n = try Store.peekRefNumber(db: db, companyId: companyId, kind: .release, floor: try Store.highestRelease(db, companyId))
            let prev = try Release.filter(Column("companyId") == companyId && Column("status") == ReleaseStatus.deployed.rawValue)
                .order(Column("number").desc).fetchOne(db)
            return (n, prev)
        }
        let input = DeployInput(settings: settings, commit: commit, version: version, layout: layout, release: number, cli: adapter.cli,
                                previousUpload: previous.map { layout.releaseDir($0.number).appending(path: "upload", directoryHint: .isDirectory) },
                                previousDeployURL: previous?.deployURL, functionsInCommit: functions)
        let plan = try adapter.deployPlan(input)
        // The rollback restores `previous` with its own build, output folder, commit and version (Task 8, Task 4 M3).
        let rollback = try adapter.rollbackPlan(Self.rollbackInput(settings: settings, release: number, commit: commit, version: version,
                                                                   previous: previous, layout: layout, cli: adapter.cli))
        let sha7 = String(commit.prefix(7))
        let proposal = Self.deployProposal(settings: settings, adapter: adapter, smokeCheck: smokeCheck, sha7: sha7, plan: plan,
                                           rollback: rollback)

        return try writer.write { db in
            // The slot again, in the write that takes it (a concurrent proposal, or a version taken meanwhile).
            try Self.checkReleaseSlot(db, companyId: companyId, version: version)
            let latestNumber = try Store.peekRefNumber(db: db, companyId: companyId, kind: .release, floor: try Store.highestRelease(db, companyId))
            let latest = try Company.fetchOne(db, key: companyId)
            guard latestNumber == number, latest?.mainCommit == commit else {
                throw WorkError.conflict("main or the releases changed while proposing; propose again")
            }
            // Final-review m2: the smoke checks the ask shows are the ones pinned to the release.
            let hosting = try HostingSettings.fetchOne(db, key: companyId)
            guard latest?.smokeCheck == smokeCheck, hosting?.smoke == settings.smoke, hosting?.expectText == settings.expectText else {
                throw WorkError.conflict("the smoke check changed while proposing; propose again")
            }
            var release = Release(companyId: companyId, number: number, version: version, provider: settings.provider,
                                  project: settings.project, commit: commit, previousReleaseId: previous?.id, build: settings.build,
                                  outputDir: settings.outputDir, plan: plan, rollbackPlan: rollback, notes: notes, proposedById: agentId,
                                  createdAt: now, smokeCheck: smokeCheck, siteSmoke: settings.smoke, siteExpectText: settings.expectText)
            let summary = notes ?? "Release \(version) of main at \(sha7)."
            let ask = try propose(db: db, companyId: companyId, by: .agent(agentId), kind: .deploy, risk: .high, category: nil,
                                  title: "Deploy \(version) to \(settings.provider.title) at \(sha7)", summary: summary,
                                  payload: AskPayload(proposal: proposal), document: nil, itemId: nil, subjectId: release.id,
                                  supersedes: nil, requestId: nil, decisionClass: .taste, viaOwner: true, now: now)
            release.askId = ask.id
            // Ruling 50: the number previewed above is taken from the counter now (it is still the next one: checked above).
            _ = try Store.nextRefNumber(db: db, companyId: companyId, kind: .release, floor: try Store.highestRelease(db, companyId))
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
        // Final-review m3: unique ignoring case (APFS folds case in the loose refs `refs/brahma/releases/<version>`).
        if let taken = try Release.filter(Column("companyId") == companyId && Column("version").lowercased == version.lowercased())
            .fetchOne(db) {
            throw WorkError.conflict(taken.version == version ? "release \(version) already exists"
                                                                : "release \(version) already exists (as \(taken.version))")
        }
        if let open = try Release.filter(Column("companyId") == companyId && ReleaseStatus.openRawValues.contains(Column("status")))
            .order(Column("number")).fetchOne(db) {
            throw WorkError.conflict("\(open.ref) is still \(open.status.rawValue)")
        }
        // Task 8 fix I2b: nothing is proposed while a rollback is pending or running.
        if let rolling = try pendingRollback(db, companyId: companyId) {
            throw WorkError.conflict("\(rolling.ref)'s rollback is \(rolling.rollbackStatus?.rawValue ?? "pending")")
        }
    }

    /// The company's release whose rollback is `requested` or `running`, if any (at most one: `requestRollback`).
    static func pendingRollback(_ db: Database, companyId: String) throws -> Release? {
        try Release.filter(Column("companyId") == companyId
                           && [RollbackStatus.requested.rawValue, RollbackStatus.running.rawValue].contains(Column("rollbackStatus")))
            .order(Column("number")).fetchOne(db)
    }

    /// Shown when the recorded rollback has no commands (fix M1: a Vercel previous release with no recorded deploy URL).
    static let noRecordedRollback = "the previous release has no recorded deploy URL; roll back from the provider dashboard"

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
            \(rollback.steps.isEmpty ? "none: \(Self.noRecordedRollback)" : rollback.display)
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

// MARK: - The release executor's records (Task 7)

/// How a release the executor was carrying out ended (`Store.finishRelease`).
enum ReleaseEnd: Equatable, Sendable {
    /// The smoke after the deploy passed.
    case deployed(productionURL: String, results: [SmokeResult])
    /// A step failed. `stage` is the bug's word (`smoke on main`, `integrity`, `backup`, `build`, `stage`, `tools`, `deploy`,
    /// `smoke`), `detail` its parenthesis, `reason` the release's `failedReason`. `bug` (final-review m4): the failure is one
    /// the agents can fix (the build, the staged output, the smoke check failing on main, the deployed site failing its smoke),
    /// so a P1 bug is filed for them; an owner-side one (integrity, the token, provider config, the tools, the backup, the
    /// folder, the sandbox, the engine) only tells the owner.
    case failed(stage: String, detail: String, reason: String, results: [SmokeResult]?, bug: Bool = false)
    /// The owner's stop (or the engine shutting down) cut it short: `interrupted` while deploying (it is never run again),
    /// `failed` while building or smoking.
    case stopped(reason: String)
}

extension Store {
    /// The rollback hint of a release that changed (or may have changed) what is live (final-review I2): its own recorded
    /// rollback, naming what that puts back (the release before it, or the placeholder page); with no recorded commands, the
    /// provider's dashboard.
    static func rollbackHint(_ db: Database, company: String, release: Release) throws -> String {
        guard !release.rollbackPlan.steps.isEmpty else { return "\(release.ref) has no recorded rollback; \(dashboardRollback)." }
        let restores = try release.previousReleaseId.flatMap { try Release.fetchOne(db, key: $0) }?.ref ?? "the placeholder page"
        return "Run brahma release rollback \(flat(company, max: 100)) \(release.ref) (puts \(restores) back) or use Roll back in Releases."
    }

    /// The executor's claim (builder-check 3, PR-9), one write transaction: nothing while the owner's stop holds; otherwise
    /// the company's oldest approved release moves `approved` → `building` (with `startedAt`) by
    /// `UPDATE release SET status = 'building' … WHERE id = ? AND status = 'approved'`, and is returned; nil when there was
    /// none or another caller claimed it first.
    func claimRelease(companyId: String, now: Date) throws -> Release? {
        try writer.write { db in
            if try Self.engineStopped(db) != nil { return nil }
            // Task 8 fix I2b: an approved deploy waits while a rollback is pending or running (it runs after).
            if try Self.pendingRollback(db, companyId: companyId) != nil { return nil }
            guard let oldest = try Release.filter(Column("companyId") == companyId && Column("status") == ReleaseStatus.approved.rawValue)
                .order(Column("approvedAt"), Column("number")).fetchOne(db) else { return nil }
            try db.execute(sql: "UPDATE release SET status = ?, startedAt = ? WHERE id = ? AND status = ?",
                           arguments: [ReleaseStatus.building.rawValue, now, oldest.id, ReleaseStatus.approved.rawValue])
            guard db.changesCount == 1, let claimed = try Release.fetchOne(db, key: oldest.id) else { return nil }
            try ActivityEvent(companyId: companyId, agentId: nil, turnId: nil, kind: .release,
                              text: "started \(claimed.ref): release \(claimed.version) at \(claimed.sha7)", createdAt: now).insert(db)
            return claimed
        }
    }

    /// One step of a release in progress, in its own write (committed before the executor's next side effect): the release
    /// must still be `from`; it becomes `to` with `change` applied. Throws `WorkError.conflict` when it is no longer `from`.
    @discardableResult
    func advanceRelease(id: String, from: ReleaseStatus, to: ReleaseStatus, now: Date,
                        _ change: @escaping @Sendable (inout Release) -> Void = { _ in }) throws -> Release {
        try writer.write { db in
            guard var release = try Release.fetchOne(db, key: id) else { throw WorkError.notFound("no such release") }
            guard release.status == from else { throw WorkError.conflict("\(release.ref) is \(release.status.rawValue), not \(from.rawValue)") }
            change(&release)
            release.status = to
            if let tail = release.outputTail { release.outputTail = try redact(tail) }
            try release.update(db)
            if from != to {
                try ActivityEvent(companyId: release.companyId, agentId: nil, turnId: nil, kind: .release,
                                  text: "\(release.ref) (release \(release.version)): \(to.title.lowercased())", createdAt: now).insert(db)
            }
            return release
        }
    }

    /// Records how a release in progress (`building`, `deploying` or `smoking`) ended, in one write: its row, an activity
    /// line, the owner's notice and, for a failure the agents can fix (`ReleaseEnd.failed`'s `bug`, final-review m4), a P1 bug
    /// filed by the engine (`Release <v> failed: <stage> (<detail>)`, type `bug`, no check). A release no longer in progress is returned as it is. Every agent-controlled part (the failure,
    /// the smoke results) is redacted.
    @discardableResult
    func finishRelease(id: String, end: ReleaseEnd, now: Date) throws -> Release {
        try writer.write { db in
            guard var release = try Release.fetchOne(db, key: id) else { throw WorkError.notFound("no such release") }
            let inProgress: [ReleaseStatus] = [.building, .deploying, .smoking]
            guard inProgress.contains(release.status) else { return release }
            let companyName = try Company.fetchOne(db, key: release.companyId)?.name ?? "the company"
            let deployStarted = release.status != .building
            let v = release.version
            func redacted(_ results: [SmokeResult]) throws -> [SmokeResult] {
                try results.map { r in
                    var r = r
                    r.url = try redact(r.url); r.bodyPrefix = try redact(r.bodyPrefix); r.error = try redact(r.error)
                    return r
                }
            }
            let activity: String
            let notice: (title: String, body: String)
            release.finishedAt = now
            switch end {
            case .deployed(let url, let results):
                release.status = .deployed
                release.deployedAt = now
                release.productionURL = url
                release.smokeStatus = "passed"
                release.smokeResults = try redacted(results)
                activity = "Release \(v) is live at \(url)"
                notice = ("\(companyName) is live", "\(url) (release \(v))")
            case .failed(let stage, let detail, let reason, let results, let bug):
                let reason = try redact(reason)
                release.status = .failed
                release.failedReason = reason
                if let results {
                    release.smokeStatus = "failed"
                    release.smokeResults = try redacted(results)
                }
                if bug {
                    let title = Self.flat("Release \(v) failed: \(stage) (\(try redact(detail)))", max: Self.maxTitle - 1)
                    let draft = WorkItemDraft(type: WorkItemType("bug"), title: title, description: Self.flat(reason, max: 2000),
                                              checkSpec: nil, priority: 1, status: .ready)
                    _ = try createWorkItem(db: db, companyId: release.companyId, by: .system, draft: draft, now: now)
                }
                activity = "\(release.ref) (release \(v)) failed: \(Self.flat(reason, max: 300))"
                notice = ("Release \(v) failed", deployStarted ? try Self.rollbackHint(db, company: companyName, release: release)
                                                               : "Nothing was deployed: \(Self.flat(reason, max: 300))")
            case .stopped(let reason):
                release.failedReason = try redact(reason)
                if release.status == .deploying {
                    release.status = .interrupted
                    activity = "\(release.ref) (release \(v)) was interrupted while deploying: \(Self.flat(reason, max: 300))"
                    notice = ("Release \(v) was interrupted", "It may be partly live. " + (try Self.rollbackHint(db, company: companyName, release: release)))
                } else {
                    release.status = .failed
                    activity = "\(release.ref) (release \(v)) was stopped: \(Self.flat(reason, max: 300))"
                    notice = ("Release \(v) was stopped", deployStarted ? try Self.rollbackHint(db, company: companyName, release: release)
                                                                     : "Nothing was deployed.")
                }
            }
            try release.update(db)
            try ActivityEvent(companyId: release.companyId, agentId: nil, turnId: nil, kind: .release, text: try redact(activity),
                              createdAt: now).insert(db)
            try notifyOwner(db: db, companyId: release.companyId, kind: .system, urgency: .normal, title: notice.title,
                            body: notice.body, now: now)
            return release
        }
    }
}

// MARK: - Rollbacks and crash recovery (Task 8)

/// How a rollback the executor was carrying out ended (`Store.finishRollback`). `tail` is the redacted end of its log.
enum RollbackEnd: Equatable, Sendable {
    /// Every recorded step ran and the site passed its smoke check.
    case succeeded(tail: String)
    /// A step or the smoke failed, or the rollback was refused before any step (never retried by the engine).
    case failed(reason: String, tail: String?)
    /// The owner's stop or the engine stopping cut it short (never run again by itself).
    case stopped(reason: String, tail: String?)
}

extension Store {
    static let rollbackOwnerOnly = "only the owner can roll back a release"
    static let dashboardRollback = "roll back from the provider dashboard"

    /// What a rollback plan is composed from (`HostingAdapter.rollbackPlan`), at propose time and when the executor renders
    /// it again: for release `number` (its folder, e.g. Vercel's empty `rollback/`), the release it restores — `previous`, the
    /// company's last deployed release when it was proposed — with that release's own build, output folder, commit, version,
    /// upload and deploy URL (Task 4 M3: never the current settings' output folder). With no previous release (the placeholder)
    /// the proposed release's own values. `settings` are the hosting settings with the proposed release's build and output.
    public static func rollbackInput(settings: HostingSettings, release number: Int, commit: String, version: String,
                                     previous: Release?, layout: ReleaseLayout, cli: String) -> DeployInput {
        var s = settings
        if let previous {
            s.build = previous.build
            s.outputDir = previous.outputDir
        }
        return DeployInput(settings: s, commit: previous?.commit ?? commit, version: previous?.version ?? version, layout: layout,
                           release: number, cli: cli,
                           previousUpload: previous.map { layout.releaseDir($0.number).appending(path: "upload", directoryHint: .isDirectory) },
                           previousDeployURL: previous?.deployURL, functionsInCommit: false)
    }

    /// The owner asks the engine to roll back release `releaseRef` (`R-<n>`) by running its recorded `rollbackPlan`, the one
    /// shown in the deploy ask. Owner only (`"only the owner can roll back a release"`); only a release that changed, or may
    /// have changed, what is live (`Release.isRollbackCandidate`: `deployed`, `interrupted` (final-review I2: a stop or crash
    /// while deploying), or `failed` once its deploy step started (m1)) whose rollback is not `requested` or `running`. The
    /// refusals include `"R-<n> is <status>; only deployed, interrupted or failed releases roll back"`, `"R-<n> failed before
    /// deploying; nothing to roll back"` and `"R-<n> is already rolling back"`. Sets `rollbackStatus requested` and
    /// `rollbackRequestedAt` in one write; the executor claims it (`claimRollback`).
    @discardableResult
    public func requestRollback(companyId: String, releaseRef: String, by sender: Sender, now: Date = Store.now()) throws -> Release {
        guard sender == .owner else { throw WorkError.forbidden(Self.rollbackOwnerOnly) }
        let notFound = WorkError.notFound("no release \(Self.flat(releaseRef, max: 40))")
        guard let found = try release(companyId: companyId, ref: releaseRef) else { throw notFound }
        return try writer.write { db in
            guard var r = try Release.fetchOne(db, key: found.id), r.companyId == companyId else { throw notFound }
            guard r.isRollbackCandidate else {
                if r.status == .failed { throw WorkError.invalid("\(r.ref) failed before deploying; nothing to roll back") }
                throw WorkError.invalid("\(r.ref) is \(r.status.rawValue); only deployed, interrupted or failed releases roll back")
            }
            if r.rollbackStatus == .requested || r.rollbackStatus == .running { throw WorkError.conflict("\(r.ref) is already rolling back") }
            // Fix I2: one rollback at a time; never while a release is open; only the release that is live now (the newest
            // rollback candidate), so the records always say what is live.
            if let other = try Self.pendingRollback(db, companyId: companyId) {
                throw WorkError.conflict("\(other.ref)'s rollback is \(other.rollbackStatus?.rawValue ?? "pending")")
            }
            if let open = try Release.filter(Column("companyId") == companyId && ReleaseStatus.openRawValues.contains(Column("status")))
                .order(Column("number")).fetchOne(db) {
                // Final-review m1: a proposal waits on the owner; rejecting its ask is what frees the rollback.
                if open.status == .proposed, let ask = try open.askId.flatMap({ try Ask.fetchOne(db, key: $0) }) {
                    throw WorkError.conflict("\(open.ref) is still proposed; reject \(ask.ref) first")
                }
                throw WorkError.conflict("\(open.ref) is still \(open.status.rawValue); roll back after it finishes")
            }
            if let live = try Self.liveRelease(db, companyId: companyId), live.id != r.id {
                throw WorkError.invalid("\(r.ref) is not the live release; roll back \(live.ref)")
            }
            // Fix M1: a release recorded with no rollback commands is rolled back in the provider's dashboard.
            guard !r.rollbackPlan.steps.isEmpty else {
                throw WorkError.invalid("\(r.ref) has no recorded rollback; \(Self.dashboardRollback)")
            }
            r.rollbackStatus = .requested
            r.rollbackRequestedAt = now
            r.rollbackStartedAt = nil
            try r.update(db)
            try ActivityEvent(companyId: companyId, agentId: nil, turnId: nil, kind: .release,
                              text: "owner requested a rollback of \(r.ref) (release \(r.version))", createdAt: now).insert(db)
            return r
        }
    }

    /// The company's live release (final-review I2, m1): its newest `Release.isRollbackCandidate`, or nil.
    static func liveRelease(_ db: Database, companyId: String) throws -> Release? {
        try Release.filter(sql: """
            companyId = ? AND (status IN (?, ?) OR (status = ? AND deployStartedAt IS NOT NULL))
            """, arguments: [companyId, ReleaseStatus.deployed.rawValue, ReleaseStatus.interrupted.rawValue, ReleaseStatus.failed.rawValue])
            .order(Column("number").desc).fetchOne(db)
    }

    /// The companies with a requested rollback (a paused company is admitted for these only, fix I1).
    func companiesWithRequestedRollback() throws -> Set<String> {
        try writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT DISTINCT companyId FROM release WHERE rollbackStatus = ?",
                                    arguments: [RollbackStatus.requested.rawValue]))
        }
    }

    /// The companies with an approved release or a requested rollback (the tick's "release" step).
    func companiesWithReleaseWork() throws -> Set<String> {
        try writer.read { db in
            Set(try String.fetchAll(db, sql: "SELECT DISTINCT companyId FROM release WHERE status = ? OR rollbackStatus = ?",
                                    arguments: [ReleaseStatus.approved.rawValue, RollbackStatus.requested.rawValue]))
        }
    }

    /// The executor's rollback claim (builder-check 5), one write transaction: nothing while the owner's stop holds or while
    /// one of the company's releases is in progress; otherwise its oldest requested rollback moves `requested` → `running`,
    /// with `rollbackStartedAt` set and `rollbackRequestedAt` cleared in the same conditional `UPDATE`, and is returned; nil
    /// when there was none or another caller claimed it first.
    func claimRollback(companyId: String, now: Date) throws -> Release? {
        try writer.write { db in
            if try Self.engineStopped(db) != nil { return nil }
            let inProgress = [ReleaseStatus.building, .deploying, .smoking].map(\.rawValue)
            if try Release.filter(Column("companyId") == companyId && inProgress.contains(Column("status"))).fetchCount(db) > 0 {
                return nil
            }
            guard let oldest = try Release.filter(Column("companyId") == companyId
                                                  && Column("rollbackStatus") == RollbackStatus.requested.rawValue)
                .order(Column("rollbackRequestedAt"), Column("number")).fetchOne(db) else { return nil }
            // Only a rollback candidate (`Release.isRollbackCandidate`: deployed, interrupted, failed once deploying started).
            try db.execute(sql: """
                UPDATE release SET rollbackStatus = ?, rollbackStartedAt = ?, rollbackRequestedAt = NULL
                WHERE id = ? AND rollbackStatus = ? AND (status IN (?, ?) OR (status = ? AND deployStartedAt IS NOT NULL))
                """, arguments: [RollbackStatus.running.rawValue, now, oldest.id, RollbackStatus.requested.rawValue,
                                 ReleaseStatus.deployed.rawValue, ReleaseStatus.interrupted.rawValue, ReleaseStatus.failed.rawValue])
            guard db.changesCount == 1, let claimed = try Release.fetchOne(db, key: oldest.id) else { return nil }
            try ActivityEvent(companyId: companyId, agentId: nil, turnId: nil, kind: .release,
                              text: "started the rollback of \(claimed.ref) (release \(claimed.version))", createdAt: now).insert(db)
            return claimed
        }
    }

    /// Records how a `running` rollback ended, in one write (a rollback no longer running is returned as it is):
    /// - succeeded: `rollbackStatus succeeded`, status `rolledBack`, `rolledBackAt`, the tail;
    /// - failed: `rollbackStatus failed`, the tail, the owner told (the engine never retries; the owner may ask again);
    /// - stopped: `rollbackStatus interrupted`, the tail, the owner told `"Rollback of R-<n> was interrupted"`, `"Check
    ///   <provider title>; you can request the rollback again."`.
    /// Rollback never touches `main`. Agent-controlled text (the tail, the reason) is redacted.
    @discardableResult
    func finishRollback(id: String, end: RollbackEnd, now: Date) throws -> Release {
        try writer.write { db in
            guard var r = try Release.fetchOne(db, key: id) else { throw WorkError.notFound("no such release") }
            guard r.rollbackStatus == .running else { return r }
            let activity: String
            var notice: (title: String, body: String)?
            switch end {
            case .succeeded(let tail):
                r.rollbackStatus = .succeeded
                r.status = .rolledBack
                r.rolledBackAt = now
                r.rollbackOutputTail = try redact(tail)
                activity = "\(r.ref) (release \(r.version)) was rolled back"
            case .failed(let reason, let tail):
                let reason = try redact(reason)
                r.rollbackStatus = .failed
                r.rollbackOutputTail = try redact(tail)
                activity = "the rollback of \(r.ref) (release \(r.version)) failed: \(Self.flat(reason, max: 300))"
                notice = ("Rollback of \(r.ref) failed", Self.flat(reason, max: 300))
            case .stopped(let reason, let tail):
                let reason = try redact(reason)
                r.rollbackStatus = .interrupted
                r.rollbackOutputTail = try redact(tail)
                activity = "the rollback of \(r.ref) (release \(r.version)) was interrupted: \(Self.flat(reason, max: 300))"
                notice = ("Rollback of \(r.ref) was interrupted", "Check \(r.provider.title); you can request the rollback again.")
            }
            try r.update(db)
            try ActivityEvent(companyId: r.companyId, agentId: nil, turnId: nil, kind: .release, text: activity, createdAt: now).insert(db)
            if let notice {
                try notifyOwner(db: db, companyId: r.companyId, kind: .system, urgency: .normal, title: notice.title, body: notice.body, now: now)
            }
            return r
        }
    }

    /// Engine start (builder-check 5): nothing an earlier engine left in progress ever runs again.
    /// - `building` or `smoking` → `failed`, `"the engine stopped during <build|smoke>; propose again"`;
    /// - `deploying` → `interrupted`, `"the engine stopped during the deploy; check <provider title>, then propose again"`;
    /// - a `running` rollback → `interrupted` (`finishRollback`).
    /// Each with the owner's notice (`finishRelease`, `finishRollback`). Returns the rows as they were, for the clean-up.
    func recoverReleases(now: Date) throws -> [Release] {
        let left = try writer.read { db in
            let inProgress = [ReleaseStatus.building, .deploying, .smoking].map(\.rawValue)
            return try Release.filter(inProgress.contains(Column("status")) || Column("rollbackStatus") == RollbackStatus.running.rawValue)
                .order(Column("companyId"), Column("number")).fetchAll(db)
        }
        for r in left {
            switch r.status {
            case .deploying:
                try finishRelease(id: r.id, end: .stopped(reason: "the engine stopped during the deploy; check \(r.provider.title), then propose again"),
                                  now: now)
            case .building, .smoking:
                let step = r.status == .building ? "build" : "smoke"
                try finishRelease(id: r.id, end: .stopped(reason: "the engine stopped during \(step); propose again"), now: now)
            default:
                break
            }
            if r.rollbackStatus == .running {
                try finishRollback(id: r.id, end: .stopped(reason: "the engine stopped during the rollback", tail: nil), now: now)
            }
        }
        return left
    }
}
