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
