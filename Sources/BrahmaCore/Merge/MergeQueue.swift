import Foundation

extension EngineLayout {
    /// `<ws>/.brahma/wt/.merge`: where 4a's plan put a merge checkout. 3a retired that place (it is agent-writable), so the queue
    /// never creates or uses it: its rebases and merges happen in the engine's own repository under the data home
    /// (`GitWorkspace.buildCandidate`). Kept as the name of the retired path.
    public var mergeCheckout: URL { dotBrahma.appending(path: "wt/.merge", directoryHint: .isDirectory) }
    /// `<ws>/.brahma/merge`: engine-written merge records an agent may read.
    public var mergeLogs: URL { dotBrahma.appending(path: "merge", directoryHint: .isDirectory) }
    /// `<ws>/.brahma/artifacts`: published artifacts (Task 6).
    public var artifacts: URL { dotBrahma.appending(path: "artifacts", directoryHint: .isDirectory) }
}

/// What one `runNextBatch` did. The ids are merge request ids.
public struct MergeBatchOutcome: Equatable, Sendable {
    public var merged: [String]
    public var bounced: [String]
    public var requeued: [String]
    public var failed: [String]
    /// The reason the queue is now held (`company.mergeHold`), when this batch held it.
    public var held: String?
    /// `main`'s head after this batch landed something.
    public var mainCommit: String?

    public init(merged: [String] = [], bounced: [String] = [], requeued: [String] = [], failed: [String] = [],
                held: String? = nil, mainCommit: String? = nil) {
        self.merged = merged; self.bounced = bounced; self.requeued = requeued; self.failed = failed
        self.held = held; self.mainCommit = mainCommit
    }
}

/// The merge queue (Plan 4a Task 1b), which replaced 3a's one-item merge step. One request at a time per company
/// (`runNextBatch`): the request's verified commit (never a re-resolved branch) is rebased onto `main` in the engine's own
/// repository, checked hermetically in a fresh `.git`-free export under the sandboxed check runner, scanned for secrets and
/// landed by fast-forward, all under the company's `GitLock`. Every engine git call goes through `GitWorkspace`; every
/// agent-written command runs through `checks`; stored output tails are redacted.
///
/// It fails closed: an approved item with no request is measured first (never landed blind), a root checkout off `main` or with
/// local edits in the way lands nothing, and a stop leaves `main` where it was.
public actor MergeQueue: EmergencyStopObserver {
    public static let maxRequeues = 3
    public static let maxAttempts = 3
    public static let blameReruns = 1
    public static let maxInconclusive = 3

    /// The message of the commit the queue makes of what is uncommitted at the workspace root.
    static let unattributedMessage = "Brahma: unattributed changes on main"
    static let rootSecretHold = "possible secret in uncommitted changes at the workspace root"

    let store: Store
    let paths: BrahmaPaths
    let checks: any CheckRunning
    let knownValues: @Sendable () -> [(String, String)]
    let clock: @Sendable () -> Date
    let blocking: Blocking
    let baseEnvironment: [String: String]

    /// Company id → the batch in flight.
    private var running: [String: Task<MergeBatchOutcome?, Never>] = [:]
    /// Company id → batches in a row that failed for the engine's own reasons.
    private var faults: [String: Int] = [:]

    public init(store: Store, paths: BrahmaPaths, checks: any CheckRunning, knownValues: @escaping @Sendable () -> [(String, String)],
                clock: @escaping @Sendable () -> Date = Store.now) {
        self.init(store: store, paths: paths, checks: checks, knownValues: knownValues, clock: clock, blocking: Blocking(),
                  baseEnvironment: ProcessInfo.processInfo.environment)
    }

    /// The orchestrator's: its `Blocking` (so the queue's git shares the engine's slots) and its check environment.
    init(store: Store, paths: BrahmaPaths, checks: any CheckRunning, knownValues: @escaping @Sendable () -> [(String, String)],
         clock: @escaping @Sendable () -> Date, blocking: Blocking, baseEnvironment: [String: String]) {
        self.store = store; self.paths = paths; self.checks = checks; self.knownValues = knownValues; self.clock = clock
        self.blocking = blocking; self.baseEnvironment = baseEnvironment
    }

    // MARK: Entry points

    /// Takes the company's next queued request through the whole merge. Nil when there was nothing to do: the engine is
    /// stopped, the queue is held, a batch of the company is already running, or nothing is queued.
    public func runNextBatch(company: Company) async -> MergeBatchOutcome? {
        guard running[company.id] == nil else { return nil }
        let id = company.id
        let task = Task<MergeBatchOutcome?, Never> { await self.batch(companyId: id) }
        running[id] = task
        let outcome = await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        running[id] = nil
        return outcome
    }

    /// The owner's emergency stop (A4): the batches in flight are cancelled (the check in flight is terminated by its runner's
    /// cancellation, its process group included) and awaited. Their requests go back to `queued`, not counted. Nothing is
    /// claimed while `engineStopped()` is non-nil.
    public func stopAll(reason: String) async {
        let tasks = Array(running.values)
        for task in tasks { task.cancel() }
        for task in tasks { _ = await task.value }
    }

    // MARK: One batch

    private func batch(companyId: String) async -> MergeBatchOutcome? {
        let (store, blocking, clock) = (self.store, self.blocking, self.clock)
        if (try? store.engineStopped()) != nil || Task.isCancelled { return nil }
        guard let company = try? store.company(id: companyId), company.mergeHold == nil else { return nil }
        let git = workspace(of: company)
        let claimed: MergeRequest?
        do {
            claimed = try await blocking.tryRun {
                // The root checkout must be on `main`: nothing is built or checked for a landing that cannot happen. One alert
                // per hold; it resolves itself once the checkout is back.
                let branch = try git.rootBranch()
                guard branch == GitWorkspace.mainRef else {
                    try? store.raiseMainHeadAlert(company: company, ref: branch)
                    return nil
                }
                let now = clock()
                try store.writer.write { db in try store.resolveEngineAlerts(db, reasons: [Store.mainHeadAlertReason(company.id)], now: now) }
                // Uncommitted changes an older engine quarantined are waiting for the owner's decision: merges wait too. And an
                // item another engine is merging right now (its lockout) is not merged a second time.
                if try store.quarantineHeld(companyId: company.id) || store.anyMerging(companyId: company.id) { return nil }
                // An approval with no request is measured now and queued (or completed, or bounced for a leak), never landed unseen.
                try store.adoptUnqueuedApprovals(companyId: company.id, now: now)
                return try store.claimMergeBatch(companyId: company.id, size: 1, now: now).first
            }
        } catch {
            note("could not claim a merge for \(company.name): \(error)")
            return nil
        }
        guard let request = claimed else { return nil }
        guard let item = try? store.workItem(id: request.itemId) else {
            try? store.failMerge(requestId: request.id, detail: "the item of this merge request is gone", now: clock())
            return MergeBatchOutcome(failed: [request.id])
        }
        // The holder gets no work turn, and the MCP tools refuse the item, while its merge runs.
        try? store.beginMerging(itemId: item.id)
        let outcome = await process(request, item: item, company: company, git: git)
        try? store.endMerging(itemId: item.id)
        if outcome.merged.isEmpty == false { faults[company.id] = nil }
        return outcome
    }

    /// The company's workspace through the store's factory, its git children recorded for the owner's stop.
    private nonisolated func workspace(of company: Company) -> GitWorkspace {
        var git = store.gitWorkspace(root: URL(fileURLWithPath: company.workspacePath, isDirectory: true), companyId: company.id)
        git.childGroups = ChildGroups(dir: ChildGroups.directory(runDir: paths.runDir), kind: "merge")
        return git
    }

    private nonisolated func note(_ text: String) {
        FileHandle.standardError.write(Data("brahma merge queue: \(text)\n".utf8))
    }

    private enum Prepared: Sendable {
        case base(String)
        /// `main` is not what the engine recorded (the main guard's alert is up): nothing is merged.
        case mainChanged
        /// `main` moved while the root was being committed.
        case moved
        case held(String)
    }

    private func process(_ r: MergeRequest, item: WorkItem, company: Company, git: GitWorkspace) async -> MergeBatchOutcome {
        var out = MergeBatchOutcome()
        var settled = false
        let (store, blocking, clock, paths, known) = (self.store, self.blocking, self.clock, self.paths, self.knownValues)
        func stopped() -> Bool { Task.isCancelled || (try? store.engineStopped()) != nil }
        func requeue(counts: Bool, inconclusive: Bool = false) {
            settled = true
            if counts, r.requeues >= Self.maxRequeues {
                try? store.failMerge(requestId: r.id, detail: "main moved \(Self.maxRequeues + 1) times while this was being merged",
                                     failure: .mainMoved, now: clock())
                out.failed.append(r.id)
                return
            }
            do { try store.requeueMerge(requestIds: [r.id], countsAsRequeue: counts, inconclusive: inconclusive, now: clock()) }
            catch { note("could not requeue \(r.ref): \(error)") }
            out.requeued.append(r.id)
        }
        // The conflict bounce runs git (3a's conflict brief), so the write is made on a blocking thread.
        /// The owner's stop cut the merge short before `main` moved: the request goes back as it was (never counted) and the
        /// feed says so.
        func requeueStopped() {
            note("the merge of \(item.key) was stopped by the owner before main moved")
            try? store.appendEvent(ActivityEvent(
                companyId: company.id, agentId: nil, turnId: nil, kind: .error,
                text: "the merge of \(item.key) was stopped by the owner before main moved; it keeps its approval and merges after the resume",
                createdAt: clock()))
            requeue(counts: false)
        }
        func bounce(_ failure: MergeFailure, _ detail: String, files: [String] = [], mergeBase: String? = nil, mainSide: String? = nil,
                    findings: [String] = [], tail: String? = nil, path: String? = nil) async {
            settled = true
            do {
                try await blocking.tryRun {
                    try store.bounceMerge(requestId: r.id, failure: failure, detail: detail, conflictFiles: files, mergeBase: mergeBase,
                                          mainSide: mainSide, findings: findings, outputTail: tail, outputPath: path, now: clock())
                }
                out.bounced.append(r.id)
            } catch {
                note("could not bounce \(r.ref): \(error)")
                requeue(counts: false)
            }
        }
        func fail(_ detail: String) {
            settled = true
            try? store.failMerge(requestId: r.id, detail: detail, now: clock())
            out.failed.append(r.id)
        }

        do {
            // 1. The base: `main` as the engine recorded it, with what is uncommitted at the root committed on top (scanned
            //    first; no ref moves until the commit is built and clean).
            let prepared = try await blocking.tryRun { () throws -> Prepared in
                try GitLock.withLock(paths: paths, companyId: company.id) {
                    // Agent-writable state that would hold every merge (stale lock files, a planted `shallow`) is repaired and reported.
                    let repaired = try git.healWorkspace()
                    if !repaired.isEmpty { store.reportMergeTamper(company: company, removed: repaired, now: clock()) }
                    do { try store.checkMain(company: company, git: git) }
                    catch let error as WorkError where error.message == Store.mainChangedMessage { return .mainChanged }
                    guard var base = try git.revParse("main") else {
                        throw GitError.failed(command: "rev-parse main", status: -1, stderr: "the workspace has no main branch")
                    }
                    let root = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
                    if try git.isDirty(in: root), let unattributed = try git.prepareRootCommit(message: Self.unattributedMessage, parent: base) {
                        guard try SecretScan.check(git: git, base: base, head: unattributed, knownValues: known()).isEmpty else {
                            return .held(Self.rootSecretHold)
                        }
                        try store.setPendingMainCommit(companyId: company.id, unattributed)
                        guard try git.advanceMain(from: base, to: unattributed) else {
                            try store.clearPendingMainCommit(companyId: company.id, ifEqual: unattributed)
                            return .moved
                        }
                        try store.writer.write { db in try store.finalizeMainCommit(db, companyId: company.id, commit: unattributed) }
                        base = unattributed
                    }
                    return .base(base)
                }
            }
            let base: String
            switch prepared {
            case .base(let value): base = value
            case .mainChanged:
                requeue(counts: false)
                return out
            case .moved:
                requeue(counts: true)
                return out
            case .held(let reason):
                try store.setMergeHold(companyId: company.id, reason: reason, now: clock())
                try store.notifyOwner(companyId: company.id, title: "Merges are held in \(company.name)",
                                      body: "\(reason). Brahma did not commit it. Remove the secret or move it out of the workspace, then release the hold.",
                                      now: clock())
                out.held = reason
                requeue(counts: false)
                return out
            }
            if stopped() { requeueStopped(); return out }

            // 2. The candidate: the verified commit rebased onto the base (and merged `--no-ff` for that strategy), built in the
            //    engine's own repository and handed to the workspace as objects only.
            let message = company.mergeStrategy == .merge ? "Merge \(item.key): \(Store.flat(item.title, max: 72))" : nil
            let built = try await blocking.tryRun { () throws -> CandidateResult in
                try GitLock.withLock(paths: paths, companyId: company.id) {
                    try git.buildCandidate(key: item.key, head: r.headCommit, onto: base, mergeMessage: message,
                                           tamper: { store.reportMergeTamper(company: company, removed: $0, now: clock()) })
                }
            }
            let candidate: String
            switch built {
            case .conflict(let files, let mergeBase, let mainSide):
                await bounce(.conflict, "it conflicts with main in \(files.count) file\(files.count == 1 ? "" : "s")", files: files,
                       mergeBase: mergeBase, mainSide: mainSide)
                return out
            case .built(_, let value): candidate = value
            }
            if stopped() { requeueStopped(); return out }

            // 3. The checks, hermetic: the snapshot's integrity first (3a's guard), then the company's main check, then the item's.
            if let file = try store.snapshotTamper(itemId: item.id, revision: r.checkRevision ?? item.checkRevision) {
                await bounce(.snapshotTampered, file)
                return out
            }
            var specs: [(MergeRun.Kind, CheckSpec, String)] = []
            if let main = company.mainCheck { specs.append((.main, main, company.mainCheckSetById ?? "merge")) }
            if let spec = item.checkSpec { specs.append((.item, spec, "merge")) }
            for (kind, spec, agent) in specs {
                switch await runCheck(kind: kind, spec: spec, agent: agent, request: r, item: item, company: company, git: git,
                                      candidate: candidate) {
                case .passed: break
                case .stopped:
                    requeueStopped()
                    return out
                case .failed(let detail, let tail, let path):
                    await bounce(kind == .main ? .mainCheckFailed : .itemCheckFailed, detail, tail: tail, path: path)
                    return out
                case .inconclusive(let tail):
                    if r.inconclusive >= Self.maxInconclusive {
                        fail("its check could not run \(Self.maxInconclusive + 1) times (\(Store.flat(tail, max: 200)))")
                    } else {
                        requeue(counts: false, inconclusive: true)
                    }
                    return out
                case .unexportable(let reason):
                    await bounce(.itemCheckFailed, "its tree cannot be written out for the check: \(reason)")
                    return out
                case .fault(let error):
                    throw error
                }
            }

            // 4. The leak scan of what will land.
            let findings = try await blocking.tryRun { try SecretScan.check(git: git, base: base, head: candidate, knownValues: known()) }
            if !findings.isEmpty {
                await bounce(.secretFound, Store.secretDetail(findings), findings: findings)
                return out
            }
            if stopped() { requeueStopped(); return out }

            // 5. The landing, under the lock: `main` must still be the base.
            enum Landing: Sendable { case landed, moved, blocked, notFastForward, offMain(String), stopped }
            let landing = try await blocking.tryRun { () throws -> Landing in
                try GitLock.withLock(paths: paths, companyId: company.id) {
                    guard try git.revParse("main") == base else { return .moved }
                    try git.updateRef("refs/brahma/pre-merge/\(r.number)", to: base)
                    try store.markLanding(requestIds: [r.id], candidates: [r.id: candidate], base: base, now: clock())
                    // The expected next head is recorded before `main` moves (3a's crash record), and cleared if it does not.
                    try store.setPendingMainCommit(companyId: company.id, candidate)
                    // The last moment before `main` moves: the owner's stop is read here (S15), and nothing has moved if it is up.
                    store.mergeRefProbe.call(GitWorkspace.mainRef)
                    if (try? store.engineStopped()) != nil {
                        try store.clearPendingMainCommit(companyId: company.id, ifEqual: candidate)
                        return .stopped
                    }
                    let result: FastForwardResult
                    do { result = try git.fastForwardMain(to: candidate) } catch {
                        try? store.clearPendingMainCommit(companyId: company.id, ifEqual: candidate)
                        throw error
                    }
                    switch result {
                    case .ok: return .landed
                    case .blockedByLocalChanges:
                        try store.clearPendingMainCommit(companyId: company.id, ifEqual: candidate)
                        return .blocked
                    case .notFastForward:
                        try store.clearPendingMainCommit(companyId: company.id, ifEqual: candidate)
                        return .notFastForward
                    case .rootNotOnMain(let ref):
                        try store.clearPendingMainCommit(companyId: company.id, ifEqual: candidate)
                        return .offMain(ref)
                    }
                }
            }
            switch landing {
            case .landed:
                settled = true
                _ = try await blocking.tryRun { try store.recordLanded([(requestId: r.id, mergedCommit: candidate)], mainCommit: candidate, now: clock()) }
                out.merged.append(r.id)
                out.mainCommit = candidate
            case .stopped: requeueStopped()
            case .moved, .notFastForward: requeue(counts: true)
            case .blocked: requeue(counts: false)
            case .offMain(let ref):
                try? store.raiseMainHeadAlert(company: company, ref: ref.hasPrefix("refs/") ? ref : nil)
                requeue(counts: false)
            }
        } catch {
            if settled { note("\(r.ref) was recorded, then: \(error)"); return out }
            if stopped() || error is StoppedByOwner || error is CancellationError {
                requeueStopped()
            } else if error is MergeInfrastructureError || error is GitLockError || (error as? GitError)?.isRepositoryRefusal == true {
                // The engine's own machinery, never charged to the item; a run of such faults is one alert.
                note("the merge of \(r.ref) hit the engine's own fault: \(error)")
                requeue(counts: false)
                faults[company.id, default: 0] += 1
                if faults[company.id] == Self.maxAttempts {
                    try? EngineAlerts.raise(
                        store: store, text: "\(company.name): merges into main are held (\(Store.flat("\(error)", max: 300))); "
                            + "\(Self.maxAttempts) attempts in a row failed for Brahma's own reasons. \(item.key) keeps its approval and its "
                            + "place in the queue; Brahma tries again and the queue moves as soon as the fault clears.",
                        now: clock(), reason: Store.mergeHoldAlertReason(company.id))
                }
            } else if r.attempts < Self.maxAttempts {
                note("the merge of \(r.ref) failed (attempt \(r.attempts)): \(error)")
                requeue(counts: false)
            } else {
                note("the merge of \(r.ref) failed for good: \(error)")
                fail("git failed \(r.attempts) times: \(Store.flat("\(error)", max: 300))")
            }
        }
        if !settled { requeue(counts: false) }
        return out
    }

    // MARK: One check

    private enum CheckVerdict: Sendable {
        case passed
        case stopped
        case failed(detail: String, tail: String, path: String?)
        case inconclusive(tail: String)
        case unexportable(String)
        case fault(any Error)
    }

    /// One check on a fresh `.git`-free export of the candidate, run by the sandboxed `checks`, then the export is deleted.
    /// The run is recorded (`MergeRun`, `running` first: the sandbox route reads that record) and its tail redacted.
    private func runCheck(kind: MergeRun.Kind, spec: CheckSpec, agent: String, request r: MergeRequest, item: WorkItem,
                          company: Company, git: GitWorkspace, candidate: String) async -> CheckVerdict {
        let (store, blocking, clock, paths, checks) = (self.store, self.blocking, self.clock, self.paths, self.checks)
        let runId = UUID().uuidString
        var run = MergeRun(id: runId, companyId: company.id, requestId: r.id, candidateCommit: candidate, kind: kind, itemId: item.id,
                           command: spec.command, status: .running, startedAt: clock())
        let output = paths.companyDir(company.id).appending(path: "check-output/merge-\(runId).log")
        func finish(_ status: VerificationStatus, exit: Int?, tail: String?) {
            run.status = status; run.exitCode = exit; run.outputTail = tail; run.outputPath = output.path; run.finishedAt = clock()
            do { try store.recordMergeRun(run) } catch { note("could not record the merge run of \(r.ref): \(error)") }
        }
        do {
            try store.recordMergeRun(run)
            let dir: URL
            do {
                dir = try await blocking.tryRun {
                    try GitLock.withLock(paths: paths, companyId: company.id) {
                        let export = try EngineExport.export(store: store, company: company, runId: runId, commit: candidate, now: clock())
                        if kind == .item { try Self.overlaySnapshot(store: store, item: item, revision: r.checkRevision, into: export) }
                        return export
                    }
                }
            } catch let refused as UnexportableTree {
                await blocking.run { EngineExport.remove(store: store, company: company, runId: runId) }
                finish(.error, exit: nil, tail: refused.reason)
                return .unexportable(refused.reason)
            } catch {
                await blocking.run { EngineExport.remove(store: store, company: company, runId: runId) }
                finish(.error, exit: nil, tail: "the export for the check failed: \(error)")
                return .fault(error)
            }
            try? FileManager.default.createDirectory(at: output.deletingLastPathComponent(), withIntermediateDirectories: true)
            let environment = ChildEnvironment.make(base: baseEnvironment, extra: ["BRAHMA_AGENT_ID": agent], purpose: .check)
            let groups = ChildGroups(dir: ChildGroups.directory(runDir: paths.runDir), kind: "check")
            var outcome = await ChildGroups.$current.withValue(groups) {
                await checks.run(command: spec.command, workingDirectory: dir, timeout: TimeInterval(spec.timeoutSeconds),
                                 outputURL: output, environment: environment)
            }
            // The log is agent output: scrubbed in place; a log that cannot be scrubbed is removed and its tail withheld.
            let scrubbed: Bool = await blocking.run {
                EngineExport.remove(store: store, company: company, runId: runId)
                do { try store.scrubCheckLog(output); return true } catch let e as CocoaError where e.code == .fileNoSuchFile { return true }
                catch { return false }
            }
            if !scrubbed { outcome = CheckOutcome(exitCode: outcome.exitCode, timedOut: outcome.timedOut, tail: Orchestrator.withheldCheckTail) }
            if Task.isCancelled || (try? store.engineStopped()) != nil {
                finish(.error, exit: nil, tail: "stopped by the owner before the check finished")
                return .stopped
            }
            if outcome.timedOut {
                finish(.timedOut, exit: nil, tail: outcome.tail)
                return .failed(detail: "\(kind == .main ? "the main" : "its") check timed out after \(spec.timeoutSeconds) s", tail: outcome.tail,
                               path: output.path)
            }
            guard let code = outcome.exitCode else {
                finish(.inconclusive, exit: nil, tail: outcome.tail)
                return .inconclusive(tail: outcome.tail)
            }
            guard code == 0 else {
                finish(.failed, exit: Int(code), tail: outcome.tail)
                return .failed(detail: "\(kind == .main ? "the main" : "its") check failed (exit \(code))", tail: outcome.tail, path: output.path)
            }
            finish(.passed, exit: 0, tail: outcome.tail)
            return .passed
        } catch {
            await blocking.run { EngineExport.remove(store: store, company: company, runId: runId) }
            finish(.error, exit: nil, tail: "the check could not be started: \(error)")
            return .fault(error)
        }
    }

    /// The item's saved check scripts (the baseline `ensureCheckSnapshot` took from the base commit, already verified unchanged)
    /// are written over the same paths in the export, so a script the branch weakened cannot weaken the merge check. Read and
    /// written through descriptors, never following a link; a file that cannot be read is a failure (nothing runs).
    nonisolated static func overlaySnapshot(store: Store, item: WorkItem, revision: Int?, into export: URL) throws {
        guard let snapshot = try store.latestCheckSnapshot(itemId: item.id, upTo: revision ?? item.checkRevision),
              let root = snapshot.dir.range(of: "/.brahma/checks/", options: .backwards)
                .map({ URL(fileURLWithPath: String(snapshot.dir[..<$0.lowerBound]), isDirectory: true) }) else { return }
        for name in snapshot.manifest.keys.sorted() {
            let source = URL(fileURLWithPath: snapshot.dir, isDirectory: true).appending(path: name)
            guard let data = EngineFiles.readNoFollow(source, under: root, limit: CheckScripts.maxHashedBytes + 1),
                  data.count <= CheckScripts.maxHashedBytes else {
                throw GitError.failed(command: "overlay", status: -1, stderr: "the saved check script \(Store.flat(name, max: 120)) cannot be read")
            }
            let parts = name.split(separator: "/").map(String.init)
            guard let last = parts.last, !parts.contains(".."), !parts.contains(".") else { continue }
            let parent = parts.dropLast().joined(separator: "/")
            try EngineFiles.directory(workspace: export, parent)
            try EngineFiles.replace(data, workspace: export, dir: parent, name: last)
        }
    }
}
