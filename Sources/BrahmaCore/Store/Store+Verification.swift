import Foundation
import GRDB

public enum VerificationStatus: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case queued, running, passed, failed, timedOut, inconclusive, error
}

public enum VerificationPurpose: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case submit, merge
}

/// One execution of an item's check by the engine, on one committed snapshot. Written only by the engine.
public struct VerificationRun: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "verificationRun"

    public var id: String
    public var companyId: String
    public var itemId: String
    public var checkRevision: Int
    /// Hash of the check scripts as submitted.
    public var scriptHash: String
    public var commit: String
    public var command: String
    /// The item's worktree when queued; the detached checkout the check ran in once it started.
    public var workingDirectory: String
    public var timeoutSeconds: Int
    public var purpose: VerificationPurpose
    /// 1 for a first run; each re-run (flake or infrastructure) adds one.
    public var attempt: Int = 1
    public var status: VerificationStatus
    public var flaky: Bool = false
    public var exitCode: Int?
    public var outputPath: String?
    /// The last 4000 characters of the output. Never copied into messages.
    public var outputTail: String?
    public var requestedBy: String?
    /// A retry is not started before this company-active time.
    public var notBeforeActive: Double?
    public var createdAt: Date
    public var startedAt: Date?
    public var finishedAt: Date?
}

/// The baseline copy of an item's check scripts, taken once per check revision when the item is claimed.
public struct CheckSnapshot: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "checkSnapshot"

    public var itemId: String
    public var checkRevision: Int
    public var dir: String
    /// Script path (relative to the repository) → content hash.
    public var manifest: [String: String]
}

public struct SubmitResult: Sendable {
    public var item: WorkItem
    /// The queued check run; nil for an item with no check.
    public var run: VerificationRun?
}

extension Store {
    /// A failed first run is re-run this many times before it counts (a pass after a failure is a flake).
    public static let flakeReruns = 1
    /// Inconclusive (infrastructure) runs before the item is returned as unable to be checked.
    public static let maxInconclusive = 3
    /// Company-active seconds between inconclusive attempts.
    public static let inconclusiveDelay: TimeInterval = 300
    static let maxSummary = 4000
    static let tailLimit = 4000
    static let tamperTail = "check snapshot was modified outside the engine"
    static let flakeFlag = "flaky check: failed, then passed on re-run"
    static let infraReason = "check could not run reliably (infrastructure)"

    // MARK: Snapshots

    public func checkSnapshot(itemId: String, revision: Int) throws -> CheckSnapshot? {
        try writer.read { db in try CheckSnapshot.fetchOne(db, key: ["itemId": itemId, "checkRevision": revision]) }
    }

    /// The newest snapshot at or below `revision` (any when nil).
    public func latestCheckSnapshot(itemId: String, upTo revision: Int? = nil) throws -> CheckSnapshot? {
        try writer.read { db in try Store.latestCheckSnapshot(db, itemId: itemId, upTo: revision) }
    }

    static func latestCheckSnapshot(_ db: Database, itemId: String, upTo revision: Int?) throws -> CheckSnapshot? {
        var request = CheckSnapshot.filter(Column("itemId") == itemId)
        if let revision { request = request.filter(Column("checkRevision") <= revision) }
        return try request.order(Column("checkRevision").desc).fetchOne(db)
    }

    /// Keeps the first snapshot of an (item, revision): later calls change nothing. Returns whether this one was saved.
    @discardableResult
    func saveCheckSnapshot(itemId: String, revision: Int, dir: String, manifest: [String: String]) throws -> Bool {
        try writer.write { db in
            guard try CheckSnapshot.fetchOne(db, key: ["itemId": itemId, "checkRevision": revision]) == nil else { return false }
            try CheckSnapshot(itemId: itemId, checkRevision: revision, dir: dir, manifest: manifest).insert(db)
            return true
        }
    }

    /// At claim, after the worktree exists: records where the item's branch started (once) and saves the scripts the check
    /// command names, once per check revision, into `<workspace>/.brahma/checks/<KEY>/rev<n>/`. The baseline comes from the
    /// engine-recorded base commit in the object database, never from the agent's worktree, so scripts an agent already
    /// weakened on its branch cannot become the baseline (submit then flags them as modified). Without a base (no common
    /// history with `main`) the head of `main` is used. A later claim of the same revision keeps the first baseline.
    func ensureCheckSnapshot(item: WorkItem, workspace: URL) throws {
        let git = gitWorkspace(root: workspace, companyId: item.companyId)
        // The branch head at claim is the recorded head (scan (a), Task 4-wire): a submit accepts only fast-forwards of it. A
        // branch flagged as moved stays flagged through a release and a new claim; only `readoptBranch` clears it.
        if let head = try git.head(of: git.branchRef(key: item.key)) { try recordLeaseHead(itemId: item.id, commit: head) }
        var base = item.baseCommit
        if base == nil {
            base = try git.mergeBase(GitWorkspace.mainRef, git.branchRef(key: item.key))
            if let base { try recordBaseCommit(itemId: item.id, commit: base) }
        }
        guard let spec = item.checkSpec else { return }
        if try checkSnapshot(itemId: item.id, revision: item.checkRevision) != nil { return }
        let source = try base ?? git.head(of: GitWorkspace.mainRef)
        let candidates = CheckScripts.candidatePaths(command: spec.command).filter { $0 != "manifest.json" }
        let contents = try source.map { try git.blobs(at: $0, paths: Array(candidates.prefix(200)), limit: CheckScripts.maxFiles) } ?? [:]
        let paths = CheckPaths(workspace: workspace)
        let dir = paths.snapshotDir(key: item.key, revision: item.checkRevision)
        let relative = CheckPaths.snapshotRelative(key: item.key, revision: item.checkRevision)
        let manifest: [String: String]
        do {
            manifest = try CheckScripts.write(contents: contents, workspace: workspace, dir: relative)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
            try EngineFiles.replace(try encoder.encode(manifest), workspace: workspace, dir: relative, name: "manifest.json")
        } catch let refused as UnsafeEngineFile {
            alertEngineFile(refused, companyId: item.companyId)
            throw refused
        }
        try saveCheckSnapshot(itemId: item.id, revision: item.checkRevision, dir: dir.path, manifest: manifest)
    }

    func recordBaseCommit(itemId: String, commit: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE workItem SET baseCommit = ? WHERE id = ? AND baseCommit IS NULL", arguments: [commit, itemId])
        }
    }

    /// For the merge flow: when an item's branch is deleted (merged) and the item is reopened, the next claim records a new base.
    func clearBaseCommit(itemId: String) throws {
        try writer.write { db in try db.execute(sql: "UPDATE workItem SET baseCommit = NULL WHERE id = ?", arguments: [itemId]) }
    }

    /// The first saved script that no longer matches its baseline hash (missing counts), or nil. No snapshot, no tampering.
    func snapshotTamper(itemId: String, revision: Int) throws -> String? {
        guard let snap = try latestCheckSnapshot(itemId: itemId, upTo: revision) else { return nil }
        let names = snap.manifest.keys.sorted()
        // The snapshot lives at `<workspace>/.brahma/checks/…`: from the workspace down, no part of the way is a link.
        let root = snap.dir.range(of: "/.brahma/checks/", options: .backwards).map { URL(fileURLWithPath: String(snap.dir[..<$0.lowerBound]), isDirectory: true) }
        let now = CheckScripts.hashes(files: names, in: URL(fileURLWithPath: snap.dir, isDirectory: true), root: root)
        return names.first { (now[$0] ?? nil) != snap.manifest[$0] }
    }

    // MARK: Submit

    static let maxFlagLength = 200
    static let maxFlagsPerSubmit = 20

    /// The summary as stored: trimmed, not empty, at most `maxSummary` characters.
    static func validSummary(_ raw: String) throws -> String {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw WorkError.invalid("the summary is empty") }
        guard text.count <= maxSummary else { throw WorkError.invalid("the summary is longer than \(maxSummary) characters") }
        return text
    }

    /// Review flags built from agent-controlled text (git paths): one line each, control characters removed, at most
    /// `maxFlagLength` characters, at most `maxFlagsPerSubmit` of them with the rest counted ("and <k> more").
    static func sanitizedFlags(_ flags: [String]) -> [String] {
        func clean(_ f: String) -> String {
            var line = f.components(separatedBy: .newlines).joined(separator: " ")
            line = String(String.UnicodeScalarView(line.unicodeScalars.filter { $0.value >= 32 && $0.value != 127 }))
                .trimmingCharacters(in: .whitespaces)
            return line.count > maxFlagLength ? String(line.prefix(maxFlagLength - 1)) + "…" : line
        }
        let cleaned = flags.map(clean).filter { !$0.isEmpty }
        guard cleaned.count > maxFlagsPerSubmit else { return cleaned }
        return Array(cleaned.prefix(maxFlagsPerSubmit)) + ["and \(cleaned.count - maxFlagsPerSubmit) more"]
    }

    /// The holder hands the item over: it becomes `inReview` with no verified revision, and the engine queues its check
    /// (an item with no check is verified at once). `flags` are weakening signs found by the caller.
    @discardableResult
    /// `mainConflicts` is a dry run of the submitted branch against `main` (nil when it could not be made): it replaces the
    /// item's `conflicts with main` flag (an empty list clears it; nil keeps what is there).
    func submitForReview(itemId: String, agentId: String, summary: String, flags: [String], commit: String, scriptHash: String,
                         workingDirectory: String, mainConflicts: [String]? = nil, now: Date = Store.now()) throws -> SubmitResult {
        try writer.write { db in
            guard var item = try WorkItem.fetchOne(db, key: itemId) else { throw WorkError.notFound("no such work item") }
            let actor = try resolveActor(db, .agent(agentId), companyId: item.companyId)
            guard let lease = try WorkLease.fetchOne(db, key: itemId), lease.agentId == agentId else {
                throw WorkError.forbidden("you do not hold \(item.key)")
            }
            guard item.status == .inProgress else {
                throw WorkError.conflict("\(item.key) is \(item.status.title.lowercased()), not in progress")
            }
            let text = try Self.validSummary(try redact(summary))   // redacted raw, before validation and storage
            if commit == item.baseCommit { throw WorkError.conflict("\(item.key) has no changes to submit") }
            // Someone must be able to review it: the named reviewer, else the owner's manager, a CTO or an executive.
            var chosenReviewer: Agent?
            if try !reviewerIsUsable(db: db, item: item) {
                let reviewer = try resolveReviewer(db: db, item: item)
                item.reviewerId = reviewer.id
                chosenReviewer = reviewer
            }
            item.reviewAttempts = 0
            item.mergeState = .none
            item.autoApproved = false
            // The engine accepted this head: it is the recorded head the holder's next turn starts from (scan (a)).
            item.leaseHeadCommit = commit
            item.submitSummary = text
            item.reviewRound += 1
            item.status = .inReview
            item.verifiedRevision = nil
            item.verifiedCommit = nil
            for f in Self.sanitizedFlags(flags) where !item.reviewFlags.contains(f) { item.reviewFlags.append(f) }
            if let mainConflicts {
                item.reviewFlags.removeAll { $0.hasPrefix(MergeSafety.conflictFlagPrefix) }
                if let flag = MergeSafety.flag(files: mainConflicts) { item.reviewFlags.append(flag) }
            }
            // Older queued runs of this item are for work that has been replaced.
            try db.execute(sql: """
                UPDATE verificationRun SET status = 'error', outputTail = 'superseded by a newer submission', finishedAt = ?
                WHERE itemId = ? AND status = 'queued'
                """, arguments: [now, itemId])
            var run: VerificationRun?
            if let spec = item.checkSpec {
                run = VerificationRun(
                    id: UUID().uuidString, companyId: item.companyId, itemId: item.id, checkRevision: item.checkRevision,
                    scriptHash: scriptHash, commit: commit, command: spec.command, workingDirectory: workingDirectory,
                    timeoutSeconds: spec.timeoutSeconds, purpose: .submit, attempt: 1, status: .queued, requestedBy: agentId,
                    createdAt: now)
            } else {
                item.verifiedRevision = item.checkRevision
                item.verifiedCommit = commit
            }
            item.updatedAt = now
            try item.update(db)
            try run?.insert(db)
            try recordItemEvent(db: db, item: item, actor: actor.id, kind: .submitted,
                                text: "submitted for review (round \(item.reviewRound)) at \(commit.prefix(7))", now: now)
            if let chosenReviewer {
                try recordItemEvent(db: db, item: item, actor: "system", kind: .assigned, text: "reviewer is @\(chosenReviewer.name)",
                                    alsoNotify: [chosenReviewer.id], alsoNotifyRole: .reviewer, now: now)
            }
            // An item with no check is reviewable at once; nothing else will tell its reviewer.
            if run == nil { try Store.wakeReviewer(db: db, item: item, now: now) }
            return SubmitResult(item: item, run: run)
        }
    }

    // MARK: Queue

    /// Runs ready to start: queued, their retry time reached in company-active seconds, their company running.
    func queuedVerifications(limit: Int) throws -> [VerificationRun] {
        guard limit > 0 else { return [] }
        return try writer.read { db in
            try VerificationRun.fetchAll(db, sql: """
                SELECT r.* FROM verificationRun r
                JOIN company c ON c.id = r.companyId
                LEFT JOIN companyActivity ca ON ca.companyId = r.companyId
                WHERE r.status = 'queued' AND c.status = 'running'
                AND (r.notBeforeActive IS NULL OR r.notBeforeActive <= COALESCE(ca.activeSeconds, 0))
                ORDER BY r.createdAt, r.rowid LIMIT ?
                """, arguments: [limit])
        }
    }

    /// The newest run of the item.
    public func latestVerification(itemId: String) throws -> VerificationRun? {
        try writer.read { db in
            try VerificationRun.filter(Column("itemId") == itemId).order(Column.rowID.desc).fetchOne(db)
        }
    }

    /// queued → running. A run whose check or item has moved on is not started: it is recorded as superseded and nil is returned.
    func beginVerification(runId: String, outputPath: String, now: Date = Store.now()) throws -> VerificationRun? {
        try writer.write { db in
            guard var run = try VerificationRun.fetchOne(db, key: runId), run.status == .queued else { return nil }
            guard let item = try WorkItem.fetchOne(db, key: run.itemId), try !Self.isStale(db, run: run, item: item) else {
                run.status = .error; run.outputTail = "superseded before it started"; run.finishedAt = now
                try run.update(db)
                return nil
            }
            run.status = .running; run.startedAt = now; run.outputPath = outputPath
            try run.update(db)
            return run
        }
    }

    func setVerificationDirectory(runId: String, path: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE verificationRun SET workingDirectory = ? WHERE id = ?", arguments: [path, runId])
        }
    }

    /// Start-up: runs the previous process left `running` go back to the queue.
    @discardableResult
    func recoverVerifications(now: Date) throws -> Int {
        try writer.write { db in
            try db.execute(sql: """
                UPDATE verificationRun SET status = 'queued', startedAt = NULL, outputPath = NULL WHERE status = 'running'
                """)
            return db.changesCount
        }
    }

    /// A merge check that could not start for the company's own reasons (the engine's merge repository or its lock, a
    /// shallow workspace: `MergeInfrastructureError`): the same run goes back to the queue, not before `delay` more active
    /// seconds. It is not an attempt: nothing is recorded as inconclusive and the item keeps its approval and its place.
    func deferVerification(runId: String, delay: TimeInterval) throws {
        try writer.write { db in
            guard let run = try VerificationRun.fetchOne(db, key: runId), run.status == .running else { return }
            let active = try Self.activeNow(db: db, companyId: run.companyId)
            try db.execute(sql: """
                UPDATE verificationRun SET status = 'queued', startedAt = NULL, outputPath = NULL, notBeforeActive = ? WHERE id = ?
                """, arguments: [active + delay, runId])
        }
    }

    // MARK: Outcomes

    /// A run is stale when the item's check changed, the item left review, or (for a submit run) the item was submitted again.
    private static func isStale(_ db: Database, run: VerificationRun, item: WorkItem) throws -> Bool {
        if item.checkRevision != run.checkRevision || item.status != .inReview { return true }
        // A merge run belongs to the rebase that queued it: the item must still be waiting for it.
        if run.purpose == .merge, item.mergeState != .verifying { return true }
        if run.purpose == .submit,
           let latest = try String.fetchOne(db, sql: """
               SELECT "commit" FROM verificationRun WHERE itemId = ? AND purpose = 'submit' ORDER BY rowid DESC LIMIT 1
               """, arguments: [run.itemId]), latest != run.commit { return true }
        return false
    }

    /// What the earlier runs of this run's chain (consecutive attempts of one submission) came to.
    private static func history(_ db: Database, before run: VerificationRun) throws -> (realFailures: Int, inconclusive: Int) {
        var real = 0, inconclusive = 0
        var attempt = run.attempt
        var rowid = try Int64.fetchOne(db, sql: "SELECT rowid FROM verificationRun WHERE id = ?", arguments: [run.id]) ?? Int64.max
        while attempt > 1 {
            guard let row = try Row.fetchOne(db, sql: """
                SELECT rowid AS rid, * FROM verificationRun WHERE itemId = ? AND purpose = ? AND attempt = ? AND rowid < ?
                ORDER BY rowid DESC LIMIT 1
                """, arguments: [run.itemId, run.purpose.rawValue, attempt - 1, rowid]) else { break }
            let previous = try VerificationRun(row: row)
            switch previous.status {
            case .failed, .timedOut: real += 1
            case .inconclusive: inconclusive += 1
            default: break
            }
            attempt = previous.attempt
            rowid = row["rid"]
        }
        return (real, inconclusive)
    }

    private func queueAgain(_ db: Database, after run: VerificationRun, notBeforeActive: Double?, now: Date) throws {
        let next = VerificationRun(
            id: UUID().uuidString, companyId: run.companyId, itemId: run.itemId, checkRevision: run.checkRevision,
            scriptHash: run.scriptHash, commit: run.commit, command: run.command, workingDirectory: run.workingDirectory,
            timeoutSeconds: run.timeoutSeconds, purpose: run.purpose, attempt: run.attempt + 1, status: .queued,
            requestedBy: run.requestedBy, notBeforeActive: notBeforeActive, createdAt: now)
        try next.insert(db)
    }

    /// Records a finished run and acts on it, in one transaction:
    /// 1. inconclusive (a failure while an engine hold is active, a network-looking tail, or a check that could not run):
    ///    retried identically after `inconclusiveDelay` active seconds, `maxInconclusive` times, then the item is returned
    ///    as unable to be checked; never counted against the agent;
    /// 2. stale (the check changed or the item left review): recorded only;
    /// 3. pass: the item is verified (a pass after a failed first run is a flake and flagged);
    /// 4. first real failure: one immediate re-run;
    /// 5. failure after the re-run: the item goes back to `inProgress` with a system DM to the holder (no output in it).
    ///
    /// `autoMerge`: the engine's measurement of the change (`assessAutoMerge`). A clean submit pass of a qualifying item is
    /// approved here, in the same transaction, through `approveForMerge` (risk-tiered review, 9c): no review turn, no reviewer
    /// woken. Every database condition is checked again here, and the measurement must be of this run's commit and the item's
    /// recorded base.
    @discardableResult
    func finishVerification(runId: String, outcome: CheckOutcome, autoMerge: AutoMergeAssessment? = nil,
                            now: Date = Store.now()) throws -> VerificationRun? {
        try writer.write { db in
            guard var run = try VerificationRun.fetchOne(db, key: runId), run.status == .running else { return nil }
            let active = try Self.activeNow(db: db, companyId: run.companyId)
            let exitedClean = outcome.exitCode == 0 && !outcome.timedOut
            let couldNotRun = outcome.exitCode == nil && !outcome.timedOut
            let held = try EngineHold.fetchOne(db, key: 1) != nil
            let infra = !exitedClean && (couldNotRun || held || EngineHealth.classify(text: outcome.tail, apiErrorStatus: nil) == .network)
            run.exitCode = outcome.exitCode.map(Int.init)
            run.outputTail = String(try redact(outcome.tail).suffix(Self.tailLimit))   // redacted raw, before the cut
            run.finishedAt = now
            run.status = exitedClean ? .passed : infra ? .inconclusive : outcome.timedOut ? .timedOut : .failed
            guard var item = try WorkItem.fetchOne(db, key: run.itemId), try !Self.isStale(db, run: run, item: item) else {
                try run.update(db)
                return run
            }
            let before = try Self.history(db, before: run)
            let holder = try WorkLease.fetchOne(db, key: item.id)?.agentId ?? run.requestedBy
            switch run.status {
            case .passed where run.purpose == .merge:
                run.flaky = before.realFailures > 0
                try run.update(db)
                item.verifiedCommit = run.commit
                item.updatedAt = now
                if run.flaky {
                    // A flaky pass is a review flag (Review Focus 4): the approval was for a clean pass, so the item goes back to
                    // its reviewer, who must approve the flag explicitly before it lands.
                    if !item.reviewFlags.contains(Self.flakeFlag) { item.reviewFlags.append(Self.flakeFlag) }
                    item.verifiedRevision = run.checkRevision
                    item.mergeState = .none
                    item.autoApproved = false
                    item.reviewAttempts = 0
                    item.reviewRound += 1
                    try item.update(db)
                    try recordItemEvent(db: db, item: item, actor: "system", kind: .verificationPassed,
                                        text: "check passed on re-run after rebase onto main (flaky); it needs another review",
                                        alsoNotify: [holder].compactMap { $0 }, alsoNotifyRole: .holder, now: now)
                    try Store.wakeReviewer(db: db, item: item, now: now)
                } else if item.reviewedRound < item.reviewRound {
                    // Its auto-approval was taken back while this check ran (auto-merge switched off): it goes to its reviewer.
                    item.verifiedRevision = run.checkRevision
                    item.mergeState = .none
                    item.reviewAttempts = 0
                    try item.update(db)
                    try recordItemEvent(db: db, item: item, actor: "system", kind: .verificationPassed,
                                        text: "check passed after rebase onto main; it needs a review",
                                        alsoNotify: [holder].compactMap { $0 }, alsoNotifyRole: .holder, now: now)
                    try Store.wakeReviewer(db: db, item: item, now: now)
                } else {
                    // The rebased branch passed again: it is approved and waits to land. (Not a new review, so no reviewer is woken.)
                    item.mergeState = .pending
                    try item.update(db)
                    try recordItemEvent(db: db, item: item, actor: "system", kind: .edited,
                                        text: "check passed after rebase onto main; ready to merge", now: now)
                }
            case .passed:
                run.flaky = before.realFailures > 0
                try run.update(db)
                item.verifiedRevision = run.checkRevision
                item.verifiedCommit = run.commit
                if run.flaky, !item.reviewFlags.contains(Self.flakeFlag) { item.reviewFlags.append(Self.flakeFlag) }
                item.updatedAt = now
                try item.update(db)
                if let autoMerge, autoMerge.reason == nil, autoMerge.commit == run.commit, autoMerge.base == item.baseCommit,
                   autoMerge.withinCaps, try autoMergeCandidate(db: db, item: item, run: run) {
                    // Risk-tiered review: the pass is the approval. The reviewer is not woken for a review that will not happen.
                    try recordItemEvent(db: db, item: item, actor: "system", kind: .verificationPassed, text: "check passed",
                                        alsoNotify: [holder].compactMap { $0 }, alsoNotifyRole: .holder, onlyAlsoNotify: true, now: now)
                    try approveForMerge(db: db, item: item, by: "system", note: ReviewPolicy.autoApprovedNote, auto: true, now: now)
                    return run
                }
                try recordItemEvent(db: db, item: item, actor: "system", kind: .verificationPassed,
                                    text: run.flaky ? "check passed on re-run (flaky)" : "check passed",
                                    alsoNotify: [holder].compactMap { $0 }, alsoNotifyRole: .holder, now: now)
                try Store.wakeReviewer(db: db, item: item, now: now)
            case .inconclusive:
                try run.update(db)
                if before.inconclusive + 1 >= Self.maxInconclusive {
                    try returnToHolder(db, item: item, run: run, holder: holder, reason: Self.infraReason, counted: false, now: now)
                } else {
                    try queueAgain(db, after: run, notBeforeActive: active + Self.inconclusiveDelay, now: now)
                }
            default:
                try run.update(db)
                if before.realFailures < Self.flakeReruns {
                    try queueAgain(db, after: run, notBeforeActive: nil, now: now)
                } else {
                    let reason = run.status == .timedOut ? "timed out after \(run.timeoutSeconds) s" : "exit \(run.exitCode ?? -1)"
                    try returnToHolder(db, item: item, run: run, holder: holder, reason: reason, now: now)
                }
            }
            return run
        }
    }

    /// The item goes back to `inProgress` with its lease refreshed, a `verificationFailed` event and a DM to the holder.
    /// The DM never carries output; the holder reads the check tail in its orientation.
    /// `counted`: a real failure (not inconclusive), which counts toward the failed-check loop guard (`noteFailedCheck`).
    private func returnToHolder(_ db: Database, item: WorkItem, run: VerificationRun, holder: String?, reason: String,
                                counted: Bool = true, now: Date, dm: String? = nil, event: String? = nil) throws {
        // A failed re-check after the engine's rebase also ends the pending merge.
        try db.execute(sql: "UPDATE workItem SET mergeState = 'none', reviewAttempts = 0 WHERE id = ?", arguments: [item.id])
        let after = run.purpose == .merge ? " after rebase onto main" : ""
        let returned = try engineSetStatus(db: db, itemId: item.id, to: .inProgress, now: now)
        try Store.refreshLease(db, itemId: item.id, companyId: item.companyId)
        try recordItemEvent(db: db, item: returned, actor: "system", kind: .verificationFailed,
                            text: event ?? "check failed\(after) (\(reason))", alsoNotify: [holder].compactMap { $0 },
                            alsoNotifyRole: .holder, now: now)
        if let holder, let agent = try Agent.fetchOne(db, key: holder), agent.state != .killed {
            try MessageRouter(store: self).sendDM(
                db: db, companyId: item.companyId, from: .system, to: agent.name,
                text: dm ?? "\(item.key) check failed\(after) (\(reason)). See the check tail under Current work in your orientation.", now: now)
        }
        if counted { try noteFailedCheck(db: db, itemId: item.id, holderId: holder, now: now) }
    }

    /// A lease that did not run during review starts a full time-to-live again when the item comes back.
    static func refreshLease(_ db: Database, itemId: String, companyId: String) throws {
        let active = try activeNow(db: db, companyId: companyId)
        try db.execute(sql: "UPDATE workLease SET expiresActive = ? WHERE itemId = ? AND expiresActive >= 0",
                       arguments: [active + WorkLease.ttl, itemId])
    }

    /// The merge check of an item's rebased commit could not run because its own tree cannot be exported (A1:
    /// `UnexportableTree`): the run is recorded `error` with the reason, and the item goes back to its holder with it. The
    /// company's merge queue is not held for it.
    func returnUnexportable(runId: String, reason: String, now: Date = Store.now()) throws {
        try writer.write { db in
            guard var run = try VerificationRun.fetchOne(db, key: runId), run.status == .running || run.status == .queued else { return }
            let shown = Self.flat(try redact(reason), max: 400)
            run.status = .error; run.outputTail = shown; run.finishedAt = now
            try run.update(db)
            guard let item = try WorkItem.fetchOne(db, key: run.itemId), try !Self.isStale(db, run: run, item: item) else { return }
            let holder = try WorkLease.fetchOne(db, key: item.id)?.agentId ?? run.requestedBy
            try returnToHolder(db, item: item, run: run, holder: holder, reason: shown, now: now,
                               dm: "\(item.key) was returned: after its rebase onto main its commit could not be written out for the merge check (\(shown)). Fix that on your branch and submit again.",
                               event: "the merge check could not run: \(shown)")
        }
    }

    /// The saved baseline of the item's check no longer matches: the run is refused (`error`), the item gets a review flag
    /// and returns to `inProgress`, and the holder is told. Output of nothing is recorded.
    func refuseVerification(runId: String, file: String, now: Date = Store.now()) throws {
        try writer.write { db in
            guard var run = try VerificationRun.fetchOne(db, key: runId), run.status == .running || run.status == .queued else { return }
            run.status = .error; run.outputTail = Self.tamperTail; run.finishedAt = now
            try run.update(db)
            guard var item = try WorkItem.fetchOne(db, key: run.itemId), try !Self.isStale(db, run: run, item: item) else { return }
            let flag = "check snapshot tampered: \(file)"
            if !item.reviewFlags.contains(flag) { item.reviewFlags.append(flag) }
            item.updatedAt = now
            try item.update(db)
            let holder = try WorkLease.fetchOne(db, key: item.id)?.agentId ?? run.requestedBy
            try returnToHolder(db, item: item, run: run, holder: holder, reason: Self.tamperTail, now: now,
                               dm: "\(item.key) was returned: its check snapshot was modified outside the engine (\(file)), so the check was not run.",
                               event: "\(Self.tamperTail) (\(file)); the check was not run")
        }
    }
}
