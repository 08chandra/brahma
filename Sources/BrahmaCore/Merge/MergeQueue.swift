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


    let store: Store
    let paths: BrahmaPaths
    let checks: any CheckRunning
    /// The secret values a candidate is scanned for, of the one company being merged (never another's: a finding names the secret).
    let knownValues: @Sendable (String) -> [(String, String)]
    let clock: @Sendable () -> Date
    let blocking: Blocking
    let baseEnvironment: [String: String]

    /// Company id → the batch in flight.
    private var running: [String: Task<MergeBatchOutcome?, Never>] = [:]
    /// Company id → batches in a row that failed for the engine's own reasons.
    private var faults: [String: Int] = [:]
    /// Companies whose journal `recover` has looked at since this process started or since the owner's last stop.
    private var recovered: Set<String> = []
    private var recovering: Set<String> = []
    /// Recoveries in a row that threw, per company, and when the next one is due (a backoff, so a persistent fault is not a tick storm).
    private var recoveryFaults: [String: Int] = [:]
    private var recoveryRetryAt: [String: Date] = [:]

    /// `knownValues` takes the company id; by default it is the company's own loaded secrets (`Store.knownSecretValues`).
    public init(store: Store, paths: BrahmaPaths, checks: any CheckRunning,
                knownValues: (@Sendable (String) -> [(String, String)])? = nil, clock: @escaping @Sendable () -> Date = Store.now) {
        self.init(store: store, paths: paths, checks: checks, knownValues: knownValues ?? { [store] in store.knownSecretValues(companyId: $0) },
                  clock: clock, blocking: Blocking(),
                  baseEnvironment: ProcessInfo.processInfo.environment)
    }

    /// The orchestrator's: its `Blocking` (so the queue's git shares the engine's slots) and its check environment.
    init(store: Store, paths: BrahmaPaths, checks: any CheckRunning, knownValues: @escaping @Sendable (String) -> [(String, String)],
         clock: @escaping @Sendable () -> Date, blocking: Blocking, baseEnvironment: [String: String]) {
        self.store = store; self.paths = paths; self.checks = checks; self.knownValues = knownValues; self.clock = clock
        self.blocking = blocking; self.baseEnvironment = baseEnvironment
    }

    // MARK: Entry points

    /// Takes the company's next queued request through the whole merge. Nil when there was nothing to do: the engine is
    /// stopped, the queue is held, a batch of the company is already running, or nothing is queued.
    public func runNextBatch(company: Company) async -> MergeBatchOutcome? {
        guard running[company.id] == nil, !recovering.contains(company.id) else { return nil }
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
        // The journal keeps the step each batch was at; the first batch after the resume recovers it before anything is claimed.
        recovered.removeAll()
        let tasks = Array(running.values)
        for task in tasks { task.cancel() }
        for task in tasks { _ = await task.value }
    }

    /// Whether the owner's stop holds: an error reading it counts as stopped (final review M1, as `PreviewRunner.ownerStopHolds`),
    /// so a database fault never lets a batch, a recovery or a check go on past a stop it could not see.
    static func stopHolds(_ store: Store) -> Bool {
        do { return try store.engineStopped() != nil } catch { return true }
    }

    // MARK: One batch

    private func batch(companyId: String) async -> MergeBatchOutcome? {
        let (store, blocking, clock) = (self.store, self.blocking, self.clock)
        if Self.stopHolds(store) || Task.isCancelled { return nil }
        guard var loaded = try? store.company(id: companyId) else { return nil }
        // The first batch of a process (and the first after the owner's stop) starts by recovering what the journal left.
        // An unfinished batch (a landing that could not be recorded, a hold that could not be written) is retried at every tick;
        // nothing is claimed while the journal holds one, so a landing is never made twice.
        let unfinished = ((try? store.openMergeBatches(companyId: companyId))?.isEmpty ?? false) == false
        if !recovered.contains(companyId) || unfinished { _ = await recoverCompany(loaded) }
        if Task.isCancelled || Self.stopHolds(store) { return nil }
        guard let open = try? store.openMergeBatches(companyId: companyId), open.isEmpty,
              let reloaded = try? store.company(id: companyId) else { return nil }
        loaded = reloaded
        // A queue held because the main check fails on main itself is released when main has a new head whose check passes.
        if loaded.mergeHold == Store.redMainHold {
            await releaseRedMainIfFixed(loaded)
            guard let fresh = try? store.company(id: companyId) else { return nil }
            loaded = fresh
        }
        let company = loaded
        guard company.mergeHold == nil else { return nil }
        let git = workspace(of: company)
        let size = company.mergeBatchSize
        let claimed: [MergeRequest]
        do {
            claimed = try await blocking.tryRun {
                // The root checkout must be on `main`: nothing is built or checked for a landing that cannot happen. One alert
                // per hold; it resolves itself once the checkout is back.
                let branch = try git.rootBranch()
                guard branch == GitWorkspace.mainRef else {
                    try? store.raiseMainHeadAlert(company: company, ref: branch)
                    return []
                }
                let now = clock()
                try store.writer.write { db in try store.resolveEngineAlerts(db, reasons: [Store.mainHeadAlertReason(company.id)], now: now) }
                // Uncommitted changes an older engine quarantined are waiting for the owner's decision: merges wait too. And an
                // item another engine is merging right now (its lockout) is not merged a second time.
                if try store.quarantineHeld(companyId: company.id) || store.anyMerging(companyId: company.id) { return [] }
                // An approval with no request is measured now and queued (or completed, or bounced for a leak), never landed unseen.
                try store.adoptUnqueuedApprovals(companyId: company.id, now: now)
                return try store.claimMergeBatch(companyId: company.id, size: size, now: now)
            }
        } catch {
            note("could not claim a merge for \(company.name): \(error)")
            return nil
        }
        guard !claimed.isEmpty else { return nil }
        var requests: [MergeRequest] = []
        var items: [String: WorkItem] = [:]
        for request in claimed {
            guard let item = try? store.workItem(id: request.itemId) else {
                try? store.failMerge(requestId: request.id, detail: "the item of this merge request is gone", now: clock())
                continue
            }
            requests.append(request)
            items[request.id] = item
        }
        guard !requests.isEmpty else {
            if let id = claimed.first?.batchId { try? store.advanceBatch(id: id, to: .done, error: "its items are gone", now: clock()) }
            return MergeBatchOutcome(failed: claimed.map(\.id))
        }
        // The holder gets no work turn, and the MCP tools refuse the item, while its merge runs.
        for item in items.values { try? store.beginMerging(itemId: item.id) }
        var outcome = await process(requests, items: items, company: company, git: git)
        for item in items.values { try? store.endMerging(itemId: item.id) }
        if outcome.merged.isEmpty == false { faults[company.id] = nil }
        outcome.failed += claimed.filter { c in !requests.contains { $0.id == c.id } }.map(\.id)
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
        /// The root checkout had uncommitted changes: 3a's quarantine moved them aside (a ref, an owner ask); nothing is committed
        /// to `main`, and the queue waits for the owner's decision (`quarantineHeld`).
        case quarantined
        /// The owner's stop was seen before anything moved.
        case stopped
    }

    /// The bookkeeping of one batch in flight: what became of each request. Touched only by the one `process` call that made it
    /// (never concurrently), so the reference is safe to share with its own helpers.
    private final class BatchLedger: @unchecked Sendable {
        var out = MergeBatchOutcome()
        var settled = Set<String>()
        /// The owner's stop (or a landing that could not be recorded) leaves the journal at the step it was at.
        var leaveOpen = false
        var batchError: String?
    }

    /// One request of the batch with the candidate commit that carries it (the batch's rebased chain, in order).
    struct Member: Sendable {
        var request: MergeRequest
        var item: WorkItem
        var candidate: String
    }

    /// What a check run (with its blame rules) said about a candidate.
    private enum Verdict: Sendable {
        case pass
        case fail(Failure)
        /// 3a's inconclusive rule held (an engine hold, a network-looking tail, a check that could not run): nobody is blamed.
        /// Never charged by default: it is bisected like a failure, and the single member a bisection isolates is charged.
        case inconclusive(String)
        case stopped
    }

    private struct Failure: Sendable {
        enum Kind: Sendable { case main, item(Int), tree }
        var kind: Kind
        var detail: String
        var tail: String?
        var path: String?
    }

    /// What the batch's checks need to know, fixed once the chain is built.
    private struct BatchContext: Sendable {
        var company: Company
        var git: GitWorkspace
        var batchId: String
        var base: String
        var members: [Member]
        var pinnedMain: [String: Data]
        var pinnedItem: [String: [String: Data]]
    }

    /// The landing, under the lock.
    private enum Landing: Sendable {
        /// `main` moved and the request(s) were recorded under the same lock (so nothing else writes the root, `main` or refs
        /// between the move and its record); `held` is a reason the queue is now held (the root did not follow, or the record
        /// failed).
        case landed(held: String?, recorded: Bool, holdFailed: Bool)
        case moved, blocked, notFastForward, offMain(String), stopped
    }

    /// Takes the claimed requests (one batch) through the whole merge, journaling each step (`mergeBatch`).
    private func process(_ requests: [MergeRequest], items: [String: WorkItem], company: Company, git: GitWorkspace) async -> MergeBatchOutcome {
        let ledger = BatchLedger()
        let batchId = requests.first?.batchId ?? ""
        let (store, blocking, clock, paths, known) = (self.store, self.blocking, self.clock, self.paths, self.knownValues)
        func stopped() -> Bool { Task.isCancelled || Self.stopHolds(store) }
        func requeue(_ r: MergeRequest, counts: Bool, inconclusive: Bool = false) {
            ledger.settled.insert(r.id)
            if counts, r.requeues >= Self.maxRequeues {
                try? store.failMerge(requestId: r.id, detail: "main moved \(Self.maxRequeues + 1) times while this was being merged",
                                     failure: .mainMoved, now: clock())
                ledger.out.failed.append(r.id)
                return
            }
            do { try store.requeueMerge(requestIds: [r.id], countsAsRequeue: counts, inconclusive: inconclusive, now: clock()) }
            catch { note("could not requeue \(r.ref): \(error)") }
            ledger.out.requeued.append(r.id)
        }
        func requeueUnsettled(counting counted: Set<String> = []) {
            for r in requests where !ledger.settled.contains(r.id) { requeue(r, counts: counted.contains(r.id)) }
        }
        /// The owner's stop cut the merge short before `main` moved: the requests go back as they were (never counted) and the
        /// feed says so; the journal stays where it was, for `recover` after the resume.
        func requeueStopped() {
            let keys = requests.compactMap { items[$0.id]?.key }.joined(separator: ", ")
            note("the merge of \(keys) was stopped by the owner before main moved")
            try? store.appendEvent(ActivityEvent(
                companyId: company.id, agentId: nil, turnId: nil, kind: .error,
                text: "the merge of \(keys) was stopped by the owner before main moved; it keeps its approval and merges after the resume",
                createdAt: clock()))
            // Before the landing's last steps the journal is left for `recover`; inside them (backed up, landing: `main` has not
            // moved, the requests go back) it ends here, so a recovery never redoes a move for requests that are no longer the
            // batch's; once `main` has moved the landing is finished by `recover`, never abandoned.
            let step = (try? store.mergeBatch(id: batchId))?.step ?? .claimed
            if step.order > MergeStep.checked.order, step.order <= MergeStep.landing.order {
                ledger.batchError = "interrupted: stopped before main moved"
                try? store.clearPendingMainCommit(companyId: company.id, ifEqual: nil)
            } else {
                ledger.leaveOpen = true
            }
            requeueUnsettled()
        }
        func bounce(_ r: MergeRequest, _ failure: MergeFailure, _ detail: String, files: [String] = [], mergeBase: String? = nil,
                    mainSide: String? = nil, findings: [String] = [], tail: String? = nil, path: String? = nil) async {
            ledger.settled.insert(r.id)
            do {
                try await blocking.tryRun {
                    try store.bounceMerge(requestId: r.id, failure: failure, detail: detail, conflictFiles: files, mergeBase: mergeBase,
                                          mainSide: mainSide, findings: findings, outputTail: tail, outputPath: path, now: clock())
                }
                ledger.out.bounced.append(r.id)
            } catch {
                note("could not bounce \(r.ref): \(error)")
                requeue(r, counts: false)
            }
        }
        func fail(_ r: MergeRequest, _ detail: String) {
            ledger.settled.insert(r.id)
            try? store.failMerge(requestId: r.id, detail: detail, now: clock())
            ledger.out.failed.append(r.id)
        }
        /// 3a's inconclusive rule: nobody is blamed; each request is put back (`inconclusive += 1`) until it has been
        /// inconclusive `maxInconclusive` times, then it is failed as infrastructure.
        func inconclusive(owner: String?) {
            ledger.batchError = "its check could not run reliably"
            for r in requests where !ledger.settled.contains(r.id) {
                guard r.id == owner else { requeue(r, counts: false); continue }
                if r.inconclusive + 1 >= Self.maxInconclusive { fail(r, Store.infraReason) } else { requeue(r, counts: false, inconclusive: true) }
            }
        }

        /// The end of every batch that was decided: whatever is left goes back uncounted, and the journal is finished.
        func finish() -> MergeBatchOutcome {
            requeueUnsettled()
            if !ledger.leaveOpen { try? store.advanceBatch(id: batchId, to: .done, error: ledger.batchError, now: clock()) }
            return ledger.out
        }

        do {
            try store.journalCrash(after: .claimed)
            // 1. The base: `main` as the engine recorded it. Nothing is committed to it (3a's B1): what is uncommitted at the root
            //    goes to a quarantine ref with one owner ask and reaches `main` only through the owner's accept.
            let prepared = try await blocking.tryRun { () throws -> Prepared in
                try GitLock.withLock(paths: paths, companyId: company.id) {
                    // Agent-writable state that would hold every merge (stale lock files, a planted `shallow`) is repaired and reported.
                    let repaired = try git.healWorkspace()
                    if !repaired.isEmpty { store.reportMergeTamper(company: company, removed: repaired, now: clock()) }
                    do { try store.checkMain(company: company, git: git) }
                    catch let error as WorkError where error.message == Store.mainChangedMessage { return .mainChanged }
                    guard let base = try git.revParse("main") else {
                        throw GitError.failed(command: "rev-parse main", status: -1, stderr: "the workspace has no main branch")
                    }
                    let root = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
                    if try git.isDirty(in: root) {
                        // The owner's stop is read before the root is reset and cleaned (3a's gate, S15); a read error stops it too.
                        store.mergeRefProbe.call("refs/quarantine")
                        if try Task.isCancelled || store.engineStopped() != nil { return .stopped }
                        try store.quarantineRoot(company: company, git: git, expectedMain: base, now: clock())
                        return .quarantined
                    }
                    return .base(base)
                }
            }
            let base: String
            switch prepared {
            case .base(let value): base = value
            case .mainChanged:
                ledger.batchError = "main is not what Brahma recorded"
                requeueUnsettled()
                return finish()
            case .quarantined:
                ledger.batchError = "the workspace root had uncommitted changes"
                requeueUnsettled()
                return finish()
            case .stopped:
                requeueStopped()
                return finish()
            }
            try store.advanceBatch(id: batchId, to: .claimed, base: base, now: clock())
            if stopped() { requeueStopped(); return finish() }

            // 2. The snapshot of each item's saved check scripts is verified (3a's guard) and held in memory here, once: what is
            //    overlaid later is these bytes, never the agent-writable directory read again. The main check's scripts are
            //    pinned from `base` (git objects), so a candidate cannot edit what gates its own landing.
            var pinnedItem: [String: [String: Data]] = [:]
            var active: [MergeRequest] = []
            for r in requests {
                guard let item = items[r.id] else { continue }
                do {
                    pinnedItem[r.id] = try await blocking.tryRun { try Self.loadSnapshot(store: store, item: item, revision: r.checkRevision) }
                    active.append(r)
                } catch let tampered as SnapshotTampered {
                    await bounce(r, .snapshotTampered, tampered.file)
                }
            }
            let pinnedMain: [String: Data] = try await blocking.tryRun {
                guard let spec = company.mainCheck else { return [:] }
                return try git.blobs(at: base, paths: CheckScripts.candidatePaths(command: spec.command), limit: CheckScripts.maxFiles)
            }

            // 3. The candidates: each request's verified commit rebased onto the tip of the chain so far (and merged `--no-ff` for
            //    that strategy), built in the engine's own repository and handed to the workspace as objects only. A conflict
            //    skips only that request.
            var tip = base
            var members: [Member] = []
            for r in active {
                guard let item = items[r.id] else { continue }
                if stopped() { requeueStopped(); return finish() }
                let from = tip
                let message = company.mergeStrategy == .merge ? "Merge \(item.key): \(Store.flat(item.title, max: 72))" : nil
                let built = try await blocking.tryRun { () throws -> CandidateResult in
                    try GitLock.withLock(paths: paths, companyId: company.id) {
                        try git.buildCandidate(key: item.key, head: r.headCommit, onto: from, mergeMessage: message,
                                               tamper: { store.reportMergeTamper(company: company, removed: $0, now: clock()) })
                    }
                }
                switch built {
                case .conflict(let files, let mergeBase, let mainSide):
                    await bounce(r, .conflict, "it conflicts with main in \(files.count) file\(files.count == 1 ? "" : "s")", files: files,
                                 mergeBase: mergeBase, mainSide: mainSide)
                case .built(_, let value):
                    tip = value
                    members.append(Member(request: r, item: item, candidate: value))
                }
            }
            guard !members.isEmpty else {
                ledger.batchError = "every request conflicted"
                return finish()
            }
            try store.advanceBatch(id: batchId, to: .rebased, candidates: Dictionary(uniqueKeysWithValues: members.map { ($0.request.id, $0.candidate) }),
                                   now: clock())
            try store.journalCrash(after: .rebased)
            if stopped() { requeueStopped(); return finish() }

            // 4. The checks, hermetic, on fresh exports: the whole batch first, the bisect when that fails.
            let ctx = BatchContext(company: company, git: git, batchId: batchId, base: base, members: members, pinnedMain: pinnedMain,
                                   pinnedItem: pinnedItem)
            let k = members.count
            var landCount = 0
            var culprit: (member: Member, failure: MergeFailure, detail: String, tail: String?, path: String?)?
            var inconclusiveMember: Member?
            let top = try await testPrefix(k, ctx)
            switch top {
            case .stopped: requeueStopped(); return finish()
            case .pass: landCount = k
            case .fail, .inconclusive:
                // A failure and an inconclusive result are bisected alike: the first prefix that is not green is the one the
                // last member makes red (or unrunnable).
                var lo = 1, hi = k
                var bad: [Int: Verdict] = [k: top]
                while lo < hi {
                    let mid = (lo + hi) / 2
                    let verdict = try await testPrefix(mid, ctx)
                    switch verdict {
                    case .pass: lo = mid + 1
                    case .stopped: requeueStopped(); return finish()
                    case .fail, .inconclusive: bad[mid] = verdict; hi = mid
                    }
                }
                guard case .fail(let failure)? = bad[lo] else {
                    // The check could not run with this member in: nobody is blamed but the member the bisection isolated.
                    inconclusiveMember = members[lo - 1]
                    landCount = lo - 1
                    break
                }
                let blamed = members[lo - 1]
                var failureKind: MergeFailure = .itemCheckFailed
                var detail = failure.detail
                switch failure.kind {
                case .main:
                    failureKind = .mainCheckFailed
                    if lo == 1 {
                        // The main check fails with only the first request in it: is main itself red? Run it once at `base`, which
                        // must be the head the engine recorded (the guard has just checked; if it moved since, nothing runs).
                        guard (try? store.company(id: company.id))??.mainCommit == base else {
                            ledger.batchError = "main is not what Brahma recorded"
                            requeueUnsettled()
                            return finish()
                        }
                        switch await runCheck(kind: .mainAtBase, spec: company.mainCheck ?? CheckSpec(command: "true"),
                                              agent: company.mainCheckSetById ?? "merge", requestId: nil, itemId: nil, batchId: batchId,
                                              prefix: nil, attempt: 1, company: company, git: git, candidate: base, pinned: [:]) {
                        case .passed: break
                        case .failed:
                            // Main is already red: nobody is blamed, the whole batch goes back uncounted, the queue is held.
                            ledger.batchError = Store.redMainHold
                            try? store.setMergeHold(companyId: company.id, reason: Store.redMainHold, now: clock())
                            try? store.notifyOwner(
                                companyId: company.id, title: "Merge queue held",
                                body: "The main check fails on main \(base.prefix(7)), so no item is blamed. Fix main or change the main check, "
                                    + "then run brahma merge resume \(company.name).", now: clock())
                            ledger.out.held = Store.redMainHold
                            requeueUnsettled()
                            return finish()
                        case .stopped: requeueStopped(); return finish()
                        case .inconclusive, .unexportable: inconclusive(owner: nil); return finish()
                        case .fault(let error): throw error
                        }
                    }
                case .item(let index) where index != lo - 1:
                    // An earlier item's check fails once this request is in the candidate: this request is the culprit.
                    detail = "its change made \(members[index].item.key)'s check fail after rebasing on main (\(failure.detail))"
                case .item, .tree: break
                }
                culprit = (blamed, failureKind, detail, failure.tail, failure.path)
                landCount = lo - 1
            }

            // 5. What passed is scanned for leaks once more, then landed.
            let landSet = Array(members.prefix(landCount))
            var recordFailed = false
            if let last = landSet.last {
                let findings = try await blocking.tryRun { try SecretScan.check(git: git, base: base, head: last.candidate, knownValues: known(company.id)) }
                if !findings.isEmpty {
                    // The request(s) whose own range holds it are bounced; the rest go back, not counted.
                    var from = base
                    var bounced = 0
                    for member in landSet {
                        let (a, b) = (from, member.candidate)
                        let own = try await blocking.tryRun { try SecretScan.check(git: git, base: a, head: b, knownValues: known(company.id)) }
                        from = member.candidate
                        if !own.isEmpty {
                            await bounce(member.request, .secretFound, Store.secretDetail(own), findings: own)
                            bounced += 1
                        }
                    }
                    if bounced == 0 {
                        for member in landSet { await bounce(member.request, .secretFound, Store.secretDetail(findings), findings: findings) }
                    }
                    ledger.batchError = "a possible secret was found"
                    requeueUnsettled()
                    return finish()
                }
                if stopped() { requeueStopped(); return finish() }
                let landCommit = last.candidate
                try store.advanceBatch(id: batchId, to: .checked, landCommit: landCommit, landedIds: landSet.map(\.request.id), now: clock())
                try store.journalCrash(after: .checked)

                // 6. The landing, under the lock: `main` must still be the base.
                let keys = landSet.map(\.item.key).joined(separator: ", ")
                let ids = landSet.map(\.request.id)
                let pairs = landSet.map { (requestId: $0.request.id, mergedCommit: $0.candidate) }
                let number = landSet[0].request.number
                let candidates = Dictionary(uniqueKeysWithValues: landSet.map { ($0.request.id, $0.candidate) })
                let result = try await blocking.tryRun { () throws -> Landing in
                    try GitLock.withLock(paths: paths, companyId: company.id) {
                        guard try git.revParse("main") == base else { return .moved }
                        // The last moment before `main` moves: the owner's stop is read here (S15), and nothing has moved if it is up.
                        store.mergeRefProbe.call(GitWorkspace.mainRef)
                        // A read error is the engine's fault (requeued uncounted), never the item's.
                        let stoppedNow: Bool
                        do { stoppedNow = try Task.isCancelled || store.engineStopped() != nil } catch { throw MergeInfrastructureError(underlying: error) }
                        if stoppedNow { return .stopped }
                        try git.updateRef("refs/brahma/pre-merge/\(number)", to: base)
                        try store.advanceBatch(id: batchId, to: .backedUp, now: clock())
                        try store.journalCrash(after: .backedUp)
                        try store.markLanding(requestIds: ids, candidates: candidates, base: base, now: clock())
                        // The expected next head is recorded before `main` moves (3a's crash record), and cleared if it does not.
                        try store.setPendingMainCommit(companyId: company.id, landCommit)
                        do {
                            try store.advanceBatch(id: batchId, to: .landing, now: clock())
                            try store.journalCrash(after: .landing)
                        } catch is SimulatedCrash {
                            throw SimulatedCrash()
                        } catch {
                            try? store.clearPendingMainCommit(companyId: company.id, ifEqual: landCommit)
                            throw error
                        }
                        let move: FastForwardResult
                        do { move = try git.fastForwardMain(to: landCommit) } catch {
                            try? store.clearPendingMainCommit(companyId: company.id, ifEqual: landCommit)
                            throw error
                        }
                        switch move {
                        case .ok, .mainMovedRootBehind:
                            // `main` has moved: nothing below may throw (a landed request must never go back to `queued`), except the
                            // test seam that simulates a crash.
                            try store.journalCrash(label: "moved")
                            let record = try self.recordLanding(batchId: batchId, from: .landing, landed: pairs, landCommit: landCommit,
                                                                rootBehind: move == .mainMovedRootBehind, label: keys, company: company)
                            return .landed(held: record.held, recorded: record.recorded, holdFailed: record.holdFailed)
                        case .blockedByLocalChanges:
                            try store.clearPendingMainCommit(companyId: company.id, ifEqual: landCommit)
                            return .blocked
                        case .notFastForward:
                            try store.clearPendingMainCommit(companyId: company.id, ifEqual: landCommit)
                            return .notFastForward
                        case .rootNotOnMain(let ref):
                            try store.clearPendingMainCommit(companyId: company.id, ifEqual: landCommit)
                            return .offMain(ref)
                        }
                    }
                }
                let landIds = Set(ids)
                switch result {
                case .landed(let held, let recorded, let holdFailed):
                    for id in ids { ledger.settled.insert(id) }
                    if recorded { ledger.out.merged += ids } else { ledger.out.failed += ids }
                    ledger.out.mainCommit = landCommit
                    ledger.out.held = held
                    // Landed but neither recorded nor held: nothing runs for this company in this process until a recovery has looked
                    // at it (landing it again is never right).
                    // The journal keeps the batch open: the next tick retries the record or the hold (`recover`).
                    if !recorded || holdFailed { ledger.leaveOpen = true }
                    if !recorded { recordFailed = true }
                case .stopped:
                    requeueStopped()
                    return finish()
                case .moved, .notFastForward:
                    ledger.batchError = "main moved while this was being merged"
                    requeueUnsettled(counting: landIds)
                    return finish()
                case .blocked:
                    ledger.batchError = "the workspace root has local changes in the way"
                    requeueUnsettled()
                    return finish()
                case .offMain(let ref):
                    try? store.raiseMainHeadAlert(company: company, ref: ref.hasPrefix("refs/") ? ref : nil)
                    ledger.batchError = "the workspace root is not on main"
                    requeueUnsettled()
                    return finish()
                }
            }

            // 7. The request behind the landed ones that made a check fail is told; the ones after it go back, not counted.
            if recordFailed { return ledger.out }
            if let m = inconclusiveMember { inconclusive(owner: m.request.id) }
            if let c = culprit {
                await bounce(c.member.request, c.failure, c.detail, tail: c.tail, path: c.path)
            }
            requeueUnsettled()
            if !landSet.isEmpty {
                // The landed items' worktrees and branches go (a landing's cleanup tolerates what is already gone).
                await blocking.run { self.cleanLanded(landSet.map { ($0.request.id, $0.item.key) }, company: company, git: git) }
                try store.advanceBatch(id: batchId, to: .cleaned, now: clock())
                try store.journalCrash(after: .cleaned)
            }
            return finish()
        } catch is SimulatedCrash {
            // A test's simulated crash: nothing after it runs and nothing is cleaned up.
            return ledger.out
        } catch {
            if stopped() || error is StoppedByOwner || error is CancellationError {
                requeueStopped()
                return finish()
            }
            ledger.batchError = Store.flat("\(error)", max: 200)
            if error is MergeInfrastructureError || error is GitLockError || (error as? GitError)?.isRepositoryRefusal == true {
                // The engine's own machinery, never charged to the item; a run of such faults is one alert.
                note("the merge of \(requests.compactMap { $0.ref }.joined(separator: ", ")) hit the engine's own fault: \(error)")
                requeueUnsettled()
                faults[company.id, default: 0] += 1
                if faults[company.id] == Self.maxAttempts {
                    try? EngineAlerts.raise(
                        store: store, text: "\(company.name): merges into main are held (\(Store.flat("\(error)", max: 300))); "
                            + "\(Self.maxAttempts) attempts in a row failed for Brahma's own reasons. The approved items keep their approval and "
                            + "their place in the queue; Brahma tries again and the queue moves as soon as the fault clears.",
                        now: clock(), reason: Store.mergeHoldAlertReason(company.id))
                }
            } else {
                for r in requests where !ledger.settled.contains(r.id) {
                    if r.attempts < Self.maxAttempts {
                        note("the merge of \(r.ref) failed (attempt \(r.attempts)): \(error)")
                        requeue(r, counts: false)
                    } else {
                        note("the merge of \(r.ref) failed for good: \(error)")
                        fail(r, "git failed \(r.attempts) times: \(Store.flat("\(error)", max: 300))")
                    }
                }
            }
            return finish()
        }

    }

    // MARK: Checks with blame

    /// The batch's first `j` requests checked on the candidate that carries them: the main check, then each of their own checks,
    /// each on a fresh export. The first failure, after the blame rules, is the verdict.
    private func testPrefix(_ j: Int, _ ctx: BatchContext) async throws -> Verdict {
        let candidate = ctx.members[j - 1].candidate
        var plan: [(kind: MergeRun.Kind, spec: CheckSpec, agent: String, index: Int?)] = []
        if let main = ctx.company.mainCheck { plan.append((.main, main, ctx.company.mainCheckSetById ?? "merge", nil)) }
        for index in 0..<j { if let spec = ctx.members[index].item.checkSpec { plan.append((.item, spec, "merge", index)) } }
        for step in plan {
            let verdict = try await blamedRun(kind: step.kind, spec: step.spec, agent: step.agent, index: step.index, prefix: j,
                                              candidate: candidate, ctx)
            if case .pass = verdict { continue }
            return verdict
        }
        return .pass
    }

    /// One check with the blame rules: a failure that looks like infrastructure is inconclusive (no re-run); any other failure is
    /// run once more at the same candidate, and a pass the second time is a pass, flagged flaky.
    private func blamedRun(kind: MergeRun.Kind, spec: CheckSpec, agent: String, index: Int?, prefix j: Int, candidate: String,
                           _ ctx: BatchContext) async throws -> Verdict {
        let owner = ctx.members[index ?? (j - 1)]
        let pinned = kind == .main ? ctx.pinnedMain : (ctx.pinnedItem[owner.request.id] ?? [:])
        func run(attempt: Int) async -> CheckVerdict {
            await runCheck(kind: kind, spec: spec, agent: agent, requestId: owner.request.id, itemId: owner.item.id, batchId: ctx.batchId,
                           prefix: j, attempt: attempt, company: ctx.company, git: ctx.git, candidate: candidate, pinned: pinned)
        }
        func failure(_ detail: String, _ tail: String, _ path: String?) -> Verdict {
            .fail(Failure(kind: index.map { .item($0) } ?? .main, detail: detail, tail: tail, path: path))
        }
        switch await run(attempt: 1) {
        case .passed: return .pass
        case .stopped: return .stopped
        case .inconclusive(let tail): return .inconclusive(tail)
        case .unexportable(let reason):
            return .fail(Failure(kind: .tree, detail: "its tree cannot be written out for the check: \(reason)", tail: nil, path: nil))
        case .fault(let error): throw error
        case .failed:
            switch await run(attempt: 2) {
            case .passed(let second):
                var flaky = second
                flaky.flaky = true
                do { try store.recordMergeRun(flaky) } catch { note("could not record the flaky run: \(error)") }
                let flagged = kind == .main ? Array(ctx.members.prefix(j)) : [owner]
                try? store.flagFlakyMerge(itemIds: flagged.map(\.item.id))
                return .pass
            case .stopped: return .stopped
            case .inconclusive(let tail): return .inconclusive(tail)
            case .unexportable(let reason):
                return .fail(Failure(kind: .tree, detail: "its tree cannot be written out for the check: \(reason)", tail: nil, path: nil))
            case .fault(let error): throw error
            case .failed(let detail, let tail, let path): return failure(detail, tail, path)
            }
        }
    }

    /// The red-main hold ends when `main` has a new head (not the one the check failed at) and the main check passes there.
    private func releaseRedMainIfFixed(_ company: Company) async {
        let (store, blocking, clock) = (self.store, self.blocking, self.clock)
        let git = workspace(of: company)
        // Only the head the engine recorded is checked: a live `main` that differs was moved outside the queue, which the main
        // guard and the batch path deal with; nothing unverified runs under the setter's profile here.
        guard let spec = company.mainCheck, let head = (try? store.company(id: company.id))??.mainCommit,
              (try? await blocking.tryRun({ try git.revParse("main") })) == head,
              let last = try? store.latestMainAtBaseRun(companyId: company.id), last.candidateCommit != head else { return }
        let verdict = await runCheck(kind: .mainAtBase, spec: spec, agent: company.mainCheckSetById ?? "merge", requestId: nil, itemId: nil,
                                     batchId: nil, prefix: nil, attempt: 1, company: company, git: git, candidate: head, pinned: [:])
        if case .passed = verdict {
            try? store.setMergeHold(companyId: company.id, reason: nil, now: clock())
            try? store.notifyOwner(companyId: company.id, title: "Merge queue resumed",
                                   body: "The main check passes on main \(head.prefix(7)) again, so merges continue.", now: clock())
        }
    }

    // MARK: Landing records

    struct LandingRecord: Sendable { var held: String?; var recorded: Bool; var holdFailed: Bool }

    /// After `main` moved to `landCommit`: journals `landed`, records the requests as merged (idempotent), journals `recorded`,
    /// and holds the queue and tells the owner when the root did not follow or the record failed. Runs under the `GitLock`.
    /// Nothing here throws except the test seam that simulates a crash: `main` has moved, so a failure is reported, never
    /// propagated.
    nonisolated func recordLanding(batchId: String, from step: MergeStep, landed: [(requestId: String, mergedCommit: String)],
                                   landCommit: String, rootBehind: Bool, label: String, company: Company,
                                   alreadyTold: Bool = false) throws -> LandingRecord {
        let (store, clock) = (self.store, self.clock)
        func advance(_ to: MergeStep, error: String? = nil) {
            do { try store.advanceBatch(id: batchId, to: to, error: error, now: clock()) }
            catch { note("could not journal \(to.rawValue) of a landing: \(error)") }
        }
        if step.order < MergeStep.landed.order {
            advance(.landed)
            try store.journalCrash(after: .landed)
        }
        var recorded = true
        var held: String? = rootBehind ? "\(Store.rootBehindHoldPrefix) after \(label) landed; its files still hold the old tree" : nil
        if step.order < MergeStep.recorded.order {
            do {
                _ = try store.recordLanded(landed, mainCommit: landCommit, now: clock())
                advance(.recorded)
                try store.journalCrash(after: .recorded)
            } catch is SimulatedCrash {
                throw SimulatedCrash()
            } catch {
                recorded = false
                let text = "\(label) \(Store.unrecordedLandingMarker) (\(Store.flat("\(error)", max: 200)))"
                held = held.map { "\($0); also \(text)" } ?? text
            }
        }
        var holdFailed = false
        if let held {
            do { try store.setMergeHold(companyId: company.id, reason: held, now: clock()) } catch {
                holdFailed = true
                note("could not hold the queue after \(label) landed: \(error)")
            }
            // What is still to do is in the journal, so the next tick (or the owner's resume) finishes it: a record that failed,
            // a hold that could not be written.
            if !recorded || holdFailed { advance(recorded ? .recorded : .landed, error: "\(Store.heldJournalPrefix)\(held)") }
            // Told once (best effort), even when the hold could not be written; each cause says how it is mended.
            if !alreadyTold {
                var remedy: [String] = []
                if rootBehind {
                    remedy.append("Reconcile the workspace root with main (save your own edits, then reset the root to main), and reject any quarantine of the old files. Then release the hold.")
                }
                if !recorded {
                    remedy.append("The database refused the record of the landing: fix that (disk space, a locked database), then run brahma merge resume \(company.name). Brahma finishes the record itself as soon as it can.")
                }
                do {
                    try store.notifyOwner(companyId: company.id, title: "Merges are held in \(company.name)",
                                          body: "\(held). " + remedy.joined(separator: " "), now: clock())
                } catch {
                    note("could not notify the owner after \(label) landed: \(error)")
                }
            }
        }
        return LandingRecord(held: held, recorded: recorded, holdFailed: holdFailed)
    }

    /// The landed items' worktrees and branches: removal tolerates what is already gone.
    nonisolated func cleanLanded(_ landed: [(requestId: String, key: String)], company: Company, git: GitWorkspace) {
        for (_, key) in landed {
            _ = try? store.removeItemWorktree(git: git, companyId: company.id, key: key)
            try? git.deleteBranch(key: key)
        }
    }

    // MARK: Recovery

    /// Finishes or abandons what the journal says an earlier run left (`start()` and the first batch after the owner's stop call
    /// it). Returns how many batches it dealt with.
    ///
    /// - claimed, rebased, checked (and a `preparing`/`prepared` row, which the queue never writes: S1): nothing moved; the
    ///   requests go back, not counted, and the batch finishes with `"interrupted"`.
    /// - backedUp, landing: the candidate already in `main` continues from `landed`; `main` still the base: the fast-forward is
    ///   redone and continues; anything else: as above.
    /// - landed, recorded, cleaned: the remaining steps run.
    /// - a request still `running`/`landing` that no open batch holds goes back too.
    @discardableResult
    public func recover(company: Company) async -> Int {
        guard running[company.id] == nil, !recovering.contains(company.id) else { return 0 }
        recovering.insert(company.id)
        defer { recovering.remove(company.id) }
        return await recoverCompany(company)
    }

    /// How one unfinished batch fared in a recovery.
    private enum Recovery: Sendable {
        /// Finished or abandoned.
        case dealt
        /// Still open for a reason the batch itself records (a record or a hold the database refused): retried later.
        case pending
        /// The recovery itself threw (git, the lock, a database read): backed off and escalated.
        case faulted(String)
    }

    private func recoverCompany(_ company: Company) async -> Int {
        let (store, blocking, clock, paths) = (self.store, self.blocking, self.clock, self.paths)
        // Nothing is recovered while the owner's stop is up: it runs on the first batch after it clears.
        if Self.stopHolds(store) || Task.isCancelled { return 0 }
        // A recovery that keeps failing waits out its backoff instead of taking the lock at every tick.
        if let due = recoveryRetryAt[company.id], clock() < due { return 0 }
        let git = workspace(of: company)
        var count = 0
        var fault: String?
        var pending = false
        do {
            let open = try store.openMergeBatches(companyId: company.id)
            if !open.isEmpty {
                // As every batch starts: stale lock files and a planted `shallow` are repaired (and reported) first.
                try await blocking.tryRun {
                    try GitLock.withLock(paths: paths, companyId: company.id) {
                        let repaired = try git.healWorkspace()
                        if !repaired.isEmpty { store.reportMergeTamper(company: company, removed: repaired, now: clock()) }
                    }
                }
            }
            for batch in open {
                switch await recoverBatch(batch, company: company, git: git) {
                case .dealt: count += 1
                case .pending: pending = true
                case .faulted(let why): fault = fault ?? why
                }
            }
            for id in try store.orphanedMergeRequestIds(companyId: company.id) {
                try store.requeueMerge(requestIds: [id], countsAsRequeue: false, now: clock())
            }
            if try store.openMergeBatches(companyId: company.id).isEmpty {
                recovered.insert(company.id)
            }
        } catch {
            fault = "\(error)"
        }
        if let fault {
            noteRecoveryFault(company, fault)
        } else {
            recoveryFaults[company.id] = nil
            recoveryRetryAt[company.id] = pending ? clock().addingTimeInterval(Self.recoveryBackoff(1)) : nil
        }
        return count
    }

    /// 30 s, doubling to 15 minutes.
    static func recoveryBackoff(_ failures: Int) -> TimeInterval { min(30 * pow(2, Double(max(failures, 1) - 1)), 900) }

    /// A recovery threw: it is retried after a backoff, the third failure in a row is one engine alert and one owner notice (the
    /// streak counter is cleared by the next recovery that does not throw).
    private func noteRecoveryFault(_ company: Company, _ why: String) {
        let n = (recoveryFaults[company.id] ?? 0) + 1
        recoveryFaults[company.id] = n
        recoveryRetryAt[company.id] = clock().addingTimeInterval(Self.recoveryBackoff(n))
        note("recovery for \(company.name) failed (\(n) in a row): \(why)")
        guard n == Self.maxAttempts else { return }
        let shown = Store.flat(why, max: 300)
        try? EngineAlerts.raise(
            store: store, text: "\(company.name): an interrupted merge batch could not be finished (\(shown)); \(n) attempts in a row failed. "
                + "Merges wait until it can; Brahma keeps trying with a growing pause.", now: clock(), reason: Store.mergeHoldAlertReason(company.id))
        try? store.notifyOwner(companyId: company.id, title: "Merge recovery is failing",
                               body: "Brahma could not finish an interrupted merge batch in \(company.name) after \(n) tries (\(shown)). Merges there wait. "
                                   + "It keeps trying with a growing pause and needs no command: merges go on by themselves once it succeeds. "
                                   + "If it persists, check the workspace and the disk; brahma merge list \(company.name) shows the waiting merges.",
                               now: clock())
    }

    private func recoverBatch(_ b: MergeBatch, company: Company, git: GitWorkspace) async -> Recovery {
        let (store, blocking, clock, paths) = (self.store, self.blocking, self.clock, self.paths)
        func abandon(_ why: String) {
            // A pending head recorded for a move that will not be made goes with the abandoned batch.
            if let land = b.landCommit { try? store.clearPendingMainCommit(companyId: company.id, ifEqual: land) }
            try? store.requeueMerge(requestIds: b.requestIds, countsAsRequeue: false, now: clock())
            try? store.advanceBatch(id: b.id, to: .done, error: why, now: clock())
        }
        let landed = b.landedIds.compactMap { id in b.candidates[id].map { (requestId: id, mergedCommit: $0) } }
        switch b.step {
        case .done:
            return .dealt
        case .claimed, .preparing, .prepared, .rebased, .checked:
            abandon("interrupted")
            return .dealt
        case .backedUp, .landing, .landed, .recorded, .cleaned:
            guard let landCommit = b.landCommit, let base = b.base, !landed.isEmpty, landed.count == b.landedIds.count else {
                abandon("interrupted")
                return .dealt
            }
            let keys = keysOf(b.landedIds)
            enum Resume: Sendable { case abandon, done(complete: Bool) }
            let told = b.error?.hasPrefix(Store.heldJournalPrefix) == true
            do {
                store.mergeRefProbe.call("recover")
                if store.mergeRefProbe.fails("recover") { throw GitError.failed(command: "recover", status: -1, stderr: "injected recovery fault") }
                let resume = try await blocking.tryRun { () throws -> Resume in
                    try GitLock.withLock(paths: paths, companyId: company.id) {
                        var rootBehind = false
                        if b.step.order < MergeStep.landed.order {
                            let head = try git.revParse("main")
                            if let head, try git.isAncestor(landCommit, of: head) {
                                // `main` moved and the move was not journaled: it goes on from `landed`.
                            } else if head == base {
                                // `main` has not moved: the fast-forward of the commit that was checked is redone, but only for requests
                                // that are still the batch's (not put back in the queue, not withdrawn while the engine was down).
                                if try store.engineStopped() != nil { return .abandon }
                                guard try store.batchStillOwns(requestIds: b.landedIds, batchId: b.id) else { return .abandon }
                                try store.setPendingMainCommit(companyId: company.id, landCommit)
                                let move: FastForwardResult
                                do { move = try git.fastForwardMain(to: landCommit) } catch {
                                    try? store.clearPendingMainCommit(companyId: company.id, ifEqual: landCommit)
                                    throw error
                                }
                                switch move {
                                case .ok: break
                                case .mainMovedRootBehind: rootBehind = true
                                default:
                                    try store.clearPendingMainCommit(companyId: company.id, ifEqual: landCommit)
                                    return .abandon
                                }
                            } else {
                                return .abandon
                            }
                        }
                        let record = try self.recordLanding(batchId: b.id, from: b.step, landed: landed, landCommit: landCommit,
                                                            rootBehind: rootBehind, label: keys, company: company, alreadyTold: told)
                        guard record.recorded, !record.holdFailed else { return .done(complete: false) }
                        // A hold the engine could not write earlier is written now; one set because the record had failed is lifted.
                        if let text = b.error?.dropFirst(Store.heldJournalPrefix.count).description, b.error?.hasPrefix(Store.heldJournalPrefix) == true {
                            if text.hasPrefix(Store.rootBehindHoldPrefix) {
                                try store.setMergeHold(companyId: company.id, reason: text, now: clock())
                            } else if let hold = try store.company(id: company.id)?.mergeHold, hold.contains(Store.unrecordedLandingMarker),
                                      !hold.hasPrefix(Store.rootBehindHoldPrefix) {
                                try store.setMergeHold(companyId: company.id, reason: nil, now: clock())
                            }
                        }
                        return .done(complete: true)
                    }
                }
                switch resume {
                case .abandon:
                    abandon("interrupted")
                case .done(let complete):
                    if !complete { return .pending }
                    await blocking.run { self.cleanLanded(b.landedIds.map { ($0, self.keyOf($0) ?? "") }, company: company, git: git) }
                    try? store.advanceBatch(id: b.id, to: .cleaned, now: clock())
                    // What the batch claimed but did not land goes back (the culprit's bounce was not journaled: it is judged again).
                    let rest = b.requestIds.filter { !b.landedIds.contains($0) }
                    try? store.requeueMerge(requestIds: rest, countsAsRequeue: false, now: clock())
                    try? store.advanceBatch(id: b.id, to: .done, now: clock())
                }
            } catch {
                return .faulted("batch \(b.number): \(error)")
            }
            return .dealt
        }
    }

    /// The item keys of some merge requests (for a notice), `M-n` when the item is gone.
    private nonisolated func keysOf(_ requestIds: [String]) -> String {
        requestIds.map { keyOf($0) ?? "a request" }.joined(separator: ", ")
    }

    private nonisolated func keyOf(_ requestId: String) -> String? {
        let request: MergeRequest? = try? store.writer.read { try MergeRequest.fetchOne($0, key: requestId) }
        guard let request else { return nil }
        return (try? store.workItem(id: request.itemId))?.key
    }

    // MARK: One check

    private enum CheckVerdict: Sendable {
        case passed(MergeRun)
        case stopped
        case failed(detail: String, tail: String, path: String?)
        case inconclusive(tail: String)
        case unexportable(String)
        case fault(any Error)
    }

    /// One check on a fresh `.git`-free export of the candidate, run by the sandboxed `checks`, then the export is deleted.
    /// The run is recorded (`MergeRun`, `running` first: the sandbox route reads that record) and its tail redacted. A failure
    /// that looks like infrastructure (3a's rule: an engine hold, a network-looking tail, a check that could not run) is
    /// `inconclusive`, not `failed`.
    private func runCheck(kind: MergeRun.Kind, spec: CheckSpec, agent: String, requestId: String?, itemId: String?, batchId: String?,
                          prefix: Int?, attempt: Int, company: Company, git: GitWorkspace, candidate: String,
                          pinned: [String: Data]) async -> CheckVerdict {
        let (store, blocking, clock, paths, checks) = (self.store, self.blocking, self.clock, self.paths, self.checks)
        let runId = UUID().uuidString
        var run = MergeRun(id: runId, companyId: company.id, batchId: batchId, requestId: requestId, prefix: prefix, candidateCommit: candidate,
                           kind: kind, itemId: itemId, command: spec.command, status: .running, attempt: attempt, startedAt: clock())
        let output = paths.companyDir(company.id).appending(path: "check-output/merge-\(runId).log")
        func finish(_ status: VerificationStatus, exit: Int?, tail: String?) {
            run.status = status; run.exitCode = exit; run.outputTail = tail; run.outputPath = output.path; run.finishedAt = clock()
            do { try store.recordMergeRun(run) } catch { note("could not record a merge run: \(error)") }
        }
        do {
            try store.recordMergeRun(run)
            let dir: URL
            do {
                dir = try await blocking.tryRun {
                    try GitLock.withLock(paths: paths, companyId: company.id) {
                        let export = try EngineExport.export(store: store, company: company, runId: runId, commit: candidate, now: clock())
                        try Self.overlay(pinned, into: export)
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
            if Task.isCancelled || Self.stopHolds(store) {
                finish(.error, exit: nil, tail: "stopped by the owner before the check finished")
                return .stopped
            }
            let subject = kind == .item ? "its" : "the main"
            if outcome.exitCode == 0 && !outcome.timedOut {
                finish(.passed, exit: 0, tail: outcome.tail)
                return .passed(run)
            }
            // 3a's inconclusive rule: a check that could not run, an engine hold, or a tail that looks like the network.
            let held: Bool
            do { held = try store.engineHold() != nil } catch { held = true }
            let infra = (outcome.exitCode == nil && !outcome.timedOut) || held
                || EngineHealth.classify(text: outcome.tail, apiErrorStatus: nil) == .network
            if infra {
                finish(.inconclusive, exit: outcome.exitCode.map(Int.init), tail: outcome.tail)
                return .inconclusive(tail: outcome.tail)
            }
            if outcome.timedOut {
                finish(.timedOut, exit: nil, tail: outcome.tail)
                return .failed(detail: "\(subject) check timed out after \(spec.timeoutSeconds) s", tail: outcome.tail, path: output.path)
            }
            let code = outcome.exitCode ?? -1
            finish(.failed, exit: Int(code), tail: outcome.tail)
            return .failed(detail: "\(subject) check failed (exit \(code))", tail: outcome.tail, path: output.path)
        } catch {
            await blocking.run { EngineExport.remove(store: store, company: company, runId: runId) }
            finish(.error, exit: nil, tail: "the check could not be started: \(error)")
            return .fault(error)
        }
    }

    /// A saved check script no longer matches its manifest hash (missing, unreadable, over the cap, or changed).
    struct SnapshotTampered: Error { let file: String }

    /// The item's saved check scripts (the baseline `ensureCheckSnapshot` took from the base commit), read through descriptors
    /// (no link followed) and checked against the manifest hash of each; one that differs is `SnapshotTampered`. No snapshot: none.
    nonisolated static func loadSnapshot(store: Store, item: WorkItem, revision: Int?) throws -> [String: Data] {
        guard let snapshot = try store.latestCheckSnapshot(itemId: item.id, upTo: revision ?? item.checkRevision) else { return [:] }
        let dir = URL(fileURLWithPath: snapshot.dir, isDirectory: true)
        let root = snapshot.dir.range(of: "/.brahma/checks/", options: .backwards)
            .map { URL(fileURLWithPath: String(snapshot.dir[..<$0.lowerBound]), isDirectory: true) } ?? dir
        var out: [String: Data] = [:]
        for name in snapshot.manifest.keys.sorted() {
            guard let data = EngineFiles.readNoFollow(dir.appending(path: name), under: root, limit: CheckScripts.maxHashedBytes + 1),
                  data.count <= CheckScripts.maxHashedBytes, StableHash.fnv1a64(data) == snapshot.manifest[name] else {
                throw SnapshotTampered(file: Store.flat(name, max: 200))
            }
            out[name] = data
        }
        return out
    }

    /// Writes pinned scripts over the same paths in the export through `EngineFiles` (no link followed).
    nonisolated static func overlay(_ files: [String: Data], into export: URL) throws {
        for name in files.keys.sorted() {
            let parts = name.split(separator: "/").map(String.init)
            guard let last = parts.last, !parts.contains(".."), !parts.contains(".") else { continue }
            let parent = parts.dropLast().joined(separator: "/")
            try EngineFiles.directory(workspace: export, parent)
            try EngineFiles.replace(files[name] ?? Data(), workspace: export, dir: parent, name: last)
        }
    }
}
