import Foundation
import GRDB

/// What the engine measured, off the database transaction, about an item it is about to approve for merge (Plan 4a A3):
/// how far the verified commit is ahead of `main` and what the leak scan found in it. `Store.enqueueApproved` is given the two
/// numbers; `commit` lets the transaction check they are of the commit that is being queued.
struct MergeEnqueueFacts: Equatable, Sendable {
    /// Whether a check run's outcome is an auto-approval that goes in the merge queue, so the engine measures it: only a
    /// clean submit pass whose assessment qualifies (a nil assessment never does).
    static func wanted(for autoMerge: AutoMergeAssessment?) -> Bool { autoMerge.map { $0.reason == nil } ?? false }

    var commit: String
    /// `revListCount("main..<commit>")`: 0 means the commit is already part of `main`.
    var ahead: Int
    /// `SecretScan.check(base: main, head: commit)`: finding texts, never values.
    var secretFindings: [String]
    /// The head of `main` when it was measured.
    var mainHead: String?
}

extension Store {
    // MARK: Reads

    /// The company's merge requests with one of `statuses` (nil: all), oldest first by number.
    public func mergeRequests(companyId: String, statuses: [MergeRequestStatus]? = nil, limit: Int = 200) throws -> [MergeRequest] {
        try writer.read { db in
            var request = MergeRequest.filter(Column("companyId") == companyId)
            if let statuses { request = request.filter(statuses.map(\.rawValue).contains(Column("status"))) }
            return try request.order(Column("number")).limit(limit).fetchAll(db)
        }
    }

    /// The item's newest merge request.
    public func latestMergeRequest(itemId: String) throws -> MergeRequest? {
        try writer.read { db in
            try MergeRequest.filter(Column("itemId") == itemId).order(Column("number").desc).fetchOne(db)
        }
    }

    public func mergeSettings(companyId: String) throws -> MergeSettings {
        guard let company = try company(id: companyId) else { throw WorkError.notFound("no such company") }
        return MergeSettings(mainCheck: company.mainCheck, batchSize: company.mergeBatchSize, strategy: company.mergeStrategy)
    }

    /// The runs of one request, oldest first.
    public func mergeRuns(requestId: String) throws -> [MergeRun] {
        try writer.read { db in try MergeRun.filter(Column("requestId") == requestId).order(Column.rowID).fetchAll(db) }
    }

    /// 1 = next to be claimed, counted among the company's queued requests; nil when the request is not queued.
    public func mergePosition(of request: MergeRequest) throws -> Int? {
        try writer.read { db in try Self.queuePosition(db, request: request) }
    }

    static func queuePosition(_ db: Database, request: MergeRequest) throws -> Int? {
        guard request.status == .queued else { return nil }
        let ahead = try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM mergeRequest WHERE companyId = ? AND status = 'queued' AND number < ?",
                                     arguments: [request.companyId, request.number]) ?? 0
        return ahead + 1
    }

    // MARK: Enqueue (at approval)

    /// Measures an item's verified commit for `enqueueApproved` (runs git: call it off the database transaction). nil when it
    /// could not be measured (no repository, unknown commit): the item is then approved without a request and 3a's merge step
    /// handles it, as before.
    func mergeEnqueueFacts(item: WorkItem) -> MergeEnqueueFacts? {
        guard let verified = item.verifiedCommit, let company = try? company(id: item.companyId) else { return nil }
        let git = gitWorkspace(root: URL(fileURLWithPath: company.workspacePath, isDirectory: true), companyId: company.id)
        do {
            guard let main = try git.head(of: GitWorkspace.mainRef), let ahead = try git.commitCount(from: main, to: verified) else { return nil }
            guard ahead > 0 else { return MergeEnqueueFacts(commit: verified, ahead: 0, secretFindings: [], mainHead: main) }
            let base = try git.mergeBase(main, verified) ?? item.baseCommit ?? git.emptyTree()
            let findings = try SecretScan.check(git: git, base: base, head: verified, knownValues: knownSecretValues(companyId: company.id))
            return MergeEnqueueFacts(commit: verified, ahead: ahead, secretFindings: findings, mainHead: main)
        } catch {
            return nil
        }
    }

    /// `mergeEnqueueFacts` for the commit a passing submit run verified.
    func mergeEnqueueFacts(forRun run: VerificationRun) -> MergeEnqueueFacts? {
        guard var item = try? workItem(id: run.itemId) else { return nil }
        item.verifiedCommit = run.commit
        return mergeEnqueueFacts(item: item)
    }

    /// The distinct rules or secret names the findings name (never a place or a value), on one line.
    static func secretLabel(_ findings: [String]) -> String {
        var seen = Set<String>()
        let labels = findings.compactMap { finding -> String? in
            let label = flat(finding.components(separatedBy: " in ").first ?? finding, max: 80)
            return label.isEmpty || !seen.insert(label).inserted ? nil : label
        }
        return labels.isEmpty ? "secret" : flat(labels.joined(separator: ", "), max: 200)
    }

    static func secretDetail(_ findings: [String]) -> String {
        "a possible secret (\(secretLabel(findings))) is in the change; remove it, rotate it if it was real, and resubmit"
    }

    /// Puts an approved item in the company's merge queue. Called from inside `approveForMerge` after its bookkeeping, in the
    /// same transaction; `ahead` and `secretFindings` were measured before it (`mergeEnqueueFacts`).
    ///
    /// - `ahead == 0`: nothing to merge, nil; the caller completes the item (`finishMerge(.merged(head of main))`).
    /// - Findings: a request is recorded as `bounced` (`.secretFound`) and the item goes back to its holder.
    /// - Otherwise: a `queued` request pinned to the item's verified commit and check revision, and a `mergeQueued` event.
    @discardableResult
    func enqueueApproved(db: Database, item: WorkItem, ahead: Int, secretFindings: [String], now: Date) throws -> MergeRequest? {
        guard ahead > 0, let commit = item.verifiedCommit else { return nil }
        // A request is only as good as the commit and check revision it was pinned to: a queued one that is not the item's
        // current approval (the item came back and was approved again) is withdrawn and a fresh one made. One the engine is
        // already checking or landing is left alone.
        let open = try MergeRequest.filter(Column("itemId") == item.id && Self.openStatuses.contains(Column("status")))
            .order(Column("number").desc).fetchAll(db)
        if let busy = open.first(where: { $0.status != .queued }) { return busy }
        if let current = open.first(where: { $0.headCommit == commit && $0.checkRevision == item.verifiedRevision }), secretFindings.isEmpty {
            return current
        }
        try Self.cancelQueuedMerges(db: db, itemId: item.id, now: now)
        let number = (try Int.fetchOne(db, sql: "SELECT MAX(number) FROM mergeRequest WHERE companyId = ?", arguments: [item.companyId]) ?? 0) + 1
        var request = MergeRequest(companyId: item.companyId, itemId: item.id, number: number, headCommit: commit,
                                   checkRevision: item.verifiedRevision, enqueuedAt: now)
        if !secretFindings.isEmpty {
            request.status = .bounced
            request.failure = .secretFound
            request.detail = Self.secretDetail(secretFindings)
            request.finishedAt = now
            try request.insert(db)
            try returnUnmerged(db, item: item, request: request, now: now)
            return nil
        }
        try request.insert(db)
        let position = try Self.queuePosition(db, request: request) ?? 1
        try recordItemEvent(db: db, item: item, actor: "system", kind: .mergeQueued,
                            text: "queued to merge as \(request.ref) (position \(position))", now: now)
        return request
    }

    static let openStatuses = MergeRequestStatus.openRaw

    // MARK: Engine writes

    /// Claims up to `size` queued requests, oldest first, as one batch: they become `running` (`attempts += 1`) and their items
    /// `verifying`. Nothing is claimed while the queue is held (`mergeHold`).
    func claimMergeBatch(companyId: String, size: Int, now: Date = Store.now()) throws -> [MergeRequest] {
        try writer.write { db in
            guard let company = try Company.fetchOne(db, key: companyId), company.mergeHold == nil else { return [] }
            let size = min(max(size, 1), MergeSettings.batchRange.upperBound)
            // A queued request whose item is no longer approved and waiting (it was sent back, moved or is another company's)
            // is stale: it is withdrawn here so it cannot sit at the head of the queue.
            try db.execute(sql: """
                UPDATE mergeRequest SET status = 'cancelled', finishedAt = ?
                WHERE companyId = ? AND status = 'queued' AND NOT EXISTS (
                    SELECT 1 FROM workItem WHERE workItem.id = mergeRequest.itemId AND workItem.companyId = mergeRequest.companyId
                        AND workItem.status = 'inReview' AND workItem.mergeState = 'pending')
                """, arguments: [now, companyId])
            let queued = try MergeRequest.filter(Column("companyId") == companyId && Column("status") == MergeRequestStatus.queued.rawValue)
                .order(Column("number")).limit(size).fetchAll(db)
            let batchId = UUID().uuidString
            var claimed: [MergeRequest] = []
            for var request in queued {
                guard var item = try WorkItem.fetchOne(db, key: request.itemId) else { continue }
                request.status = .running
                request.attempts += 1
                request.batchId = batchId
                request.startedAt = now
                try request.update(db)
                item.mergeState = .verifying
                item.updatedAt = now
                try item.update(db)
                claimed.append(request)
            }
            return claimed
        }
    }

    /// Records one check execution (candidate item check, main check or main at the base). The tail is redacted before it is
    /// stored; a run of another company's request is refused.
    func recordMergeRun(_ run: MergeRun) throws {
        var run = run
        run.outputTail = try redactedTail(run.outputTail)
        try writer.write { db in
            if let requestId = run.requestId {
                guard let request = try MergeRequest.fetchOne(db, key: requestId), request.companyId == run.companyId,
                      try WorkItem.fetchOne(db, key: request.itemId)?.companyId == run.companyId else {
                    throw WorkError.forbidden("not in your company")
                }
            }
            try run.save(db)
        }
    }

    /// The batch's candidate passed: the requests are `landing` (`candidates`: request id → the candidate commit that carries
    /// it) on top of `base`.
    func markLanding(requestIds: [String], candidates: [String: String], base: String, now: Date = Store.now()) throws {
        try writer.write { db in
            for var (request, _) in try Self.ownedBatch(db, ids: requestIds) {
                guard request.status == .running else { continue }
                request.status = .landing
                request.baseCommit = base
                request.candidateCommit = candidates[request.id] ?? request.candidateCommit
                try request.update(db)
            }
        }
    }

    /// The batch landed. In one write the requests become `merged`, `company.mainCommit` is set and each item gets an activity
    /// line; then every item that is not already done completes through `finishMerge` (without its own merge-safety pass), and
    /// `MergeSafety.afterLanding` runs once for the last key.
    @discardableResult
    func recordLanded(_ landed: [(requestId: String, mergedCommit: String)], mainCommit: String, now: Date = Store.now()) throws -> [WorkItem] {
        var items: [(WorkItem, String)] = []
        try writer.write { db in
            // One company per batch: `main` is moved for that company only.
            let batch = try Self.ownedBatch(db, ids: landed.map(\.requestId))
            for ((request, item), mergedCommit) in zip(batch, landed.map(\.mergedCommit)) {
                var (request, item) = (request, item)
                guard request.status == .landing || request.status == .running else { continue }
                request.status = .merged
                request.mergedCommit = mergedCommit
                request.finishedAt = now
                try request.update(db)
                try finalizeMainCommit(db, companyId: request.companyId, commit: mainCommit)
                try appendActivity(db, ActivityEvent(companyId: request.companyId, agentId: nil, turnId: nil, kind: .merge,
                                                     text: "\(item.key) merged into main (\(mergedCommit.prefix(7)))", createdAt: now))
                // `finishMerge` measures "changed while it merged" against `pending`.
                if item.mergeState == .verifying {
                    item.mergeState = .pending
                    try item.update(db)
                }
                items.append((item, mergedCommit))
            }
        }
        var finished: [WorkItem] = []
        for (item, mergedCommit) in items where item.status != .done {
            try finishMerge(itemId: item.id, result: .merged(mainHead: mergedCommit), triggerAfterLanding: false, now: now)
        }
        for (item, _) in items { if let fresh = try workItem(id: item.id) { finished.append(fresh) } }
        if let last = items.last, let company = try company(id: last.0.companyId) {
            try MergeSafety(store: self).afterLanding(companyId: company.id, mergedKey: last.0.key)
        }
        return finished
    }

    /// The request did not land. `.conflict`: the request is `bounced` and 3a's conflict brief goes to the holder
    /// (`finishMerge(.conflict)`). `.snapshotTampered`: the item is flagged and the holder told, as 3a does for a tampered
    /// snapshot. Anything else: the item goes back to `inProgress` with `mergeState = .none`, a `mergeFailed` event carrying
    /// `detail` and a system DM that never carries output.
    func bounceMerge(requestId: String, failure: MergeFailure, detail: String, conflictFiles: [String] = [], mergeBase: String? = nil,
                     mainSide: String? = nil, outputTail: String? = nil, outputPath: String? = nil, now: Date = Store.now()) throws {
        let tail = try redactedTail(outputTail)
        let shownDetail = try redact(Self.flat(detail, max: 500))
        let files = try conflictFiles.map { try redact($0) }
        let outcome: (MergeRequest, WorkItem)? = try writer.write { db in
            var (request, item) = try Self.ownedRequest(db, id: requestId)
            guard request.status.isOpen else { return nil }
            request.status = .bounced
            request.failure = failure
            request.detail = shownDetail
            request.conflictFiles = files
            request.outputTail = tail
            request.outputPath = outputPath
            request.finishedAt = now
            try request.update(db)
            switch failure {
            case .conflict:
                // 3a's conflict step takes the item from `pending`.
                if item.mergeState == .verifying { item.mergeState = .pending; try item.update(db) }
            case .snapshotTampered:
                let flag = "check snapshot tampered: \(Self.flat(shownDetail, max: 200))"
                if !item.reviewFlags.contains(flag) { item.reviewFlags.append(flag); try item.update(db) }
                try returnUnmerged(db, item: item, request: request, now: now,
                                   dm: "\(item.key) was returned: its check snapshot was modified outside the engine (\(Self.flat(shownDetail, max: 200))), so the check was not run.")
            default:
                try returnUnmerged(db, item: item, request: request, now: now)
            }
            return (request, item)
        }
        guard let (request, item) = outcome, failure == .conflict else { return }
        let main = try mainSide ?? company(id: item.companyId)?.mainCommit ?? request.baseCommit ?? ""
        try finishMerge(itemId: item.id, result: .conflict(files: files, mergeBase: mergeBase ?? request.baseCommit ?? main,
                                                           mainCommit: main, itemCommit: request.headCommit), now: now)
    }

    /// The batch could not be decided (main moved, an outage, a stop): the requests go back to `queued` and their items to
    /// `pending`. `countsAsRequeue`: main moved (counts toward `MergeQueue.maxRequeues`); `inconclusive`: the check was
    /// inconclusive (counts toward `maxInconclusive`). An engine error counts neither (its `attempts` already did).
    func requeueMerge(requestIds: [String], countsAsRequeue: Bool, inconclusive: Bool = false, now: Date = Store.now()) throws {
        try writer.write { db in
            for var (request, item) in try Self.ownedBatch(db, ids: requestIds) {
                guard request.status == .running || request.status == .landing else { continue }
                request.status = .queued
                request.batchId = nil
                request.candidateCommit = nil
                request.baseCommit = nil
                if countsAsRequeue { request.requeues += 1 }
                if inconclusive { request.inconclusive += 1 }
                try request.update(db)
                if item.mergeState == .verifying {
                    item.mergeState = .pending
                    item.updatedAt = now
                    try item.update(db)
                }
            }
        }
    }

    /// The request will not be retried by the engine: `failed`, an activity line and an owner notice. The item stays approved
    /// but is not merging (`mergeState = .none`) until the owner retries.
    func failMerge(requestId: String, detail: String, now: Date = Store.now()) throws {
        let reason = try redact(Self.flat(detail, max: 500))
        try writer.write { db in
            var (request, item) = try Self.ownedRequest(db, id: requestId)
            guard request.status.isOpen else { return }
            request.status = .failed
            request.failure = request.failure ?? .engineError
            request.detail = reason
            request.finishedAt = now
            try request.update(db)
            if item.mergeState != .none { item.mergeState = .none; item.updatedAt = now; try item.update(db) }
            try appendActivity(db, ActivityEvent(companyId: request.companyId, agentId: nil, turnId: nil, kind: .merge,
                                                 text: "Merge \(request.ref) (\(item.key)) stopped: \(reason)", createdAt: now))
            try notifyOwner(db: db, companyId: request.companyId, kind: .system, urgency: .normal,
                            title: "Merge \(request.ref) (\(item.key)) stopped",
                            body: "\(reason). Retry it from the merge queue or with brahma merge retry.", now: now)
        }
    }

    /// Holds the merge queue with an engine-written reason, or releases it (nil).
    func setMergeHold(companyId: String, reason: String?, now: Date = Store.now()) throws {
        let value = try reason.map { try redact(Self.flat($0, max: 300)) }
        try writer.write { db in
            try db.execute(sql: "UPDATE company SET mergeHold = ? WHERE id = ?", arguments: [value, companyId])
        }
    }

    /// The item is leaving review (released, moved or reassigned): its `queued` request is withdrawn. A request that is
    /// `running` or `landing` is left alone (`refuseWhileMerging` stops the move before it gets here).
    func cancelMerge(db: Database, itemId: String, now: Date = Store.now()) throws {
        try Self.cancelQueuedMerges(db: db, itemId: itemId, now: now)
    }

    /// Withdraws the item's `queued` requests (never one being checked or landed). Static so a restore's raw database can use it.
    static func cancelQueuedMerges(db: Database, itemId: String, now: Date) throws {
        try db.execute(sql: """
            UPDATE mergeRequest SET status = 'cancelled', finishedAt = ? WHERE itemId = ? AND status = 'queued'
            """, arguments: [now, itemId])
    }

    /// Refuses a release or a move out of review while the engine is checking or landing the item's request.
    static func refuseWhileMerging(db: Database, item: WorkItem) throws {
        if let request = try MergeRequest.filter(Column("itemId") == item.id
            && [MergeRequestStatus.running.rawValue, MergeRequestStatus.landing.rawValue].contains(Column("status")))
            .order(Column("number").desc).fetchOne(db) {
            throw WorkError.conflict("\(item.key) is being merged (\(request.ref)); wait for the merge to finish")
        }
    }

    // MARK: Helpers

    /// The request and its item, refused when the item is another company's (or the request's own company differs).
    private static func ownedRequest(_ db: Database, id: String) throws -> (MergeRequest, WorkItem) {
        guard let request = try MergeRequest.fetchOne(db, key: id), let item = try WorkItem.fetchOne(db, key: request.itemId) else {
            throw WorkError.notFound("no such merge request")
        }
        guard item.companyId == request.companyId else { throw WorkError.forbidden("not in your company") }
        return (request, item)
    }

    /// The requests of one batch and their items. An unknown id is refused, and so is a batch that spans companies (a request
    /// or its item of another company): nothing is written then.
    private static func ownedBatch(_ db: Database, ids: [String]) throws -> [(MergeRequest, WorkItem)] {
        let pairs = try ids.map { try ownedRequest(db, id: $0) }
        let companies = Set(pairs.flatMap { [$0.0.companyId, $0.1.companyId] })
        guard companies.count <= 1 else { throw WorkError.forbidden("not in your company") }
        return pairs
    }

    private func redactedTail(_ tail: String?) throws -> String? {
        guard let tail else { return nil }
        return String(try redact(tail).suffix(Self.tailLimit))   // redacted raw, before the cut
    }

    private func appendActivity(_ db: Database, _ event: ActivityEvent) throws {
        try event.insert(db)
    }

    /// The item goes back to its holder: `inProgress`, nothing approved, `mergeFailed` with the reason and a system DM.
    private func returnUnmerged(_ db: Database, item current: WorkItem, request: MergeRequest, now: Date, dm: String? = nil) throws {
        var item = current
        let detail = request.detail ?? "the merge did not complete"
        item.mergeState = .none
        item.reviewAttempts = 0
        item.autoApproved = false
        // The next merge must be of work that passed its check (and its scans) again.
        item.verifiedRevision = nil
        item.verifiedCommit = nil
        item.updatedAt = now
        try item.update(db)
        let returned = try engineSetStatus(db: db, itemId: item.id, to: .inProgress, now: now)
        try Store.refreshLease(db, itemId: item.id, companyId: item.companyId)
        let holder = try Self.leaseHolderId(db: db, itemId: item.id) ?? item.ownerId
        try recordItemEvent(db: db, item: returned, actor: "system", kind: .mergeFailed, text: detail,
                            alsoNotify: [holder].compactMap { $0 }, alsoNotifyRole: .holder, now: now)
        guard let holder, let agent = try Agent.fetchOne(db, key: holder), agent.state != .killed else { return }
        try MessageRouter(store: self).sendDM(
            db: db, companyId: item.companyId, from: .system, to: agent.name,
            text: dm ?? "\(item.key) was not merged: \(detail). See Merge under Current work in your orientation.", now: now)
    }
}
