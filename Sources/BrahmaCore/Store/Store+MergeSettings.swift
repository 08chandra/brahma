import Foundation
import GRDB

/// The owner's merge settings and holds (Plan 4a Task 2), and the CTO's main check. The queue itself only reads these; the
/// settings that decide what reaches `main` are the owner's (the CLI behind `requireOwnerShell`, the app), except the main
/// check, which the company's CTO may set through `set_main_check` (the owner is told).
extension Store {
    /// The hold the queue puts on itself when the root checkout did not follow `main` after a landing (`mainMovedRootBehind`).
    static let rootBehindHoldPrefix = "the root checkout did not follow main"

    /// What `resumeMergeQueue` says when the root still holds the old tree.
    static let rootBehindRefusal = "the workspace root does not match main yet: save your own edits, reset the root to main "
        + "(git reset --hard main), then resume again. Releasing the hold now would quarantine the old files, and accepting that would undo what landed"

    /// What a hold says when a landing could not be recorded (the queue lifts it itself once the record succeeds).
    static let unrecordedLandingMarker = "landed but could not be recorded"
    /// The journal's `error` of a batch whose record or hold is still to be done; the rest is the hold's reason.
    static let heldJournalPrefix = "hold: "
    /// What `resumeMergeQueue` says when a landing still cannot be recorded.
    static let landingNotRecordedRefusal = "a merge that already landed on main could not be recorded yet: the database refused the write. "
        + "Fix that (disk space, a locked database), then resume again; releasing the hold now would leave the landing unrecorded"

    /// Whether the batch still holds these requests (`running` or `landing`, `batchId` the batch's): ones put back in the queue or
    /// withdrawn while the engine was down no longer do.
    func batchStillOwns(requestIds: [String], batchId: String) throws -> Bool {
        try writer.read { db in
            for id in requestIds {
                guard let r = try MergeRequest.fetchOne(db, key: id), r.batchId == batchId,
                      r.status == .running || r.status == .landing else { return false }
            }
            return true
        }
    }

    /// Records the landings a batch journaled as `landed` but could not record (the engine's own retry does this too). Throws
    /// `landingNotRecordedRefusal` when the record still fails.
    func repairUnrecordedLandings(companyId: String, now: Date = Store.now()) throws -> Int {
        var repaired = 0
        let open = try openMergeBatches(companyId: companyId)
        // `landing` as well as `landed`: if journaling `landed` failed after `main` moved, the batch still stands at `landing`.
        for b in open where b.step == .landing || b.step == .landed {
            guard let land = b.landCommit else { continue }
            if b.step == .landing {
                // Only a landing `main` already holds is recorded; one it does not hold is the engine's recovery (it redoes or abandons).
                guard let company = try company(id: companyId) else { continue }
                let git = gitWorkspace(root: URL(fileURLWithPath: company.workspacePath, isDirectory: true), companyId: companyId)
                do {
                    guard let head = try git.head(of: GitWorkspace.mainRef), try git.isAncestor(land, of: head) else { continue }
                } catch { throw WorkError.conflict(Self.landingNotRecordedRefusal) }
            }
            let pairs = b.landedIds.compactMap { id in b.candidates[id].map { (requestId: id, mergedCommit: $0) } }
            do {
                _ = try recordLanded(pairs, mainCommit: land, now: now)
                try advanceBatch(id: b.id, to: .recorded, now: now)
                repaired += 1
            } catch { throw WorkError.conflict(Self.landingNotRecordedRefusal) }
        }
        return repaired
    }

    /// The holds the engine lifts itself when their cause is gone.
    static func liftsItself(_ hold: String?) -> Bool {
        guard let hold else { return false }
        return hold == redMainHold || (hold.contains(unrecordedLandingMarker) && !hold.hasPrefix(rootBehindHoldPrefix))
            || isPRUnavailableHold(hold)
    }

    private static func requireOwnerOrSystem(_ sender: Sender) throws {
        switch sender {
        case .owner, .system: return
        case .agent: throw WorkError.forbidden("only the owner can change the merge settings")
        }
    }

    /// Batch size (1 to 8), strategy and main check, in one write. Owner or system only. A main check set here has no setter
    /// agent, so its runs are sandboxed (an unknown principal never runs unsandboxed).
    public func setMergeSettings(companyId: String, _ settings: MergeSettings, by sender: Sender, now: Date = Store.now()) throws {
        try Self.requireOwnerOrSystem(sender)
        guard MergeSettings.batchRange.contains(settings.batchSize) else {
            throw WorkError.invalid("the batch size must be between \(MergeSettings.batchRange.lowerBound) and \(MergeSettings.batchRange.upperBound)")
        }
        var check = settings.mainCheck
        if var spec = check {
            spec.command = try redact(spec.command)
            try spec.validate()
            check = spec
        }
        try writer.write { db in
            guard var company = try Company.fetchOne(db, key: companyId) else { throw WorkError.notFound("no such company") }
            if company.mainCheck != check { company.mainCheckSetById = nil }
            company.mainCheck = check
            company.mergeBatchSize = settings.batchSize
            company.mergeStrategy = settings.strategy
            try company.update(db)
        }
    }

    /// The CTO's tool: sets (or, with nil, clears) the company's main check. Only a role that covers `cto` may; the owner is
    /// told, and the agent becomes the principal whose code the check is (its runs are unsandboxed only if that agent and every
    /// candidate's author narrow to Full).
    @discardableResult
    func setMainCheck(companyId: String, by agentId: String, check: CheckSpec?, now: Date = Store.now()) throws -> CheckSpec? {
        var spec = check
        if var s = spec {
            s.command = try redact(s.command)
            try s.validate()
            spec = s
        }
        try writer.write { db in
            guard let agent = try Agent.fetchOne(db, key: agentId), agent.companyId == companyId else {
                throw WorkError.forbidden("not in your company")
            }
            guard let company = try Company.fetchOne(db, key: companyId) else { throw WorkError.notFound("no such company") }
            let ctoRoles = catalog.pack(company.packId)?.rolesCovering("cto") ?? ["cto"]
            guard ctoRoles.contains(agent.role) else { throw WorkError.forbidden("only the CTO can set the main check") }
            var updated = company
            updated.mainCheck = spec
            updated.mainCheckSetById = spec == nil ? nil : agentId
            try updated.update(db)
            // Told in the same write: a change the owner is not told of does not happen.
            let shown = spec.map { Self.flat($0.command, max: 200) }
            try notifyOwner(db: db, companyId: companyId, kind: .system, urgency: .normal,
                            title: spec == nil ? "Main check cleared" : "Main check changed",
                            body: spec == nil ? "\(agent.name) cleared the main check; merges are no longer gated by it."
                                              : "\(agent.name) set the main check to: \(shown ?? ""). Every merge is checked with it from now on.",
                            now: now)
        }
        return spec
    }

    /// The merge request an owner names by `M-<n>` or by the item's key (the newest one).
    public func mergeRequest(companyId: String, ref: String) throws -> MergeRequest? {
        let ref = ref.trimmingCharacters(in: .whitespaces)
        if ref.hasPrefix("M-"), let number = Int(ref.dropFirst(2)) {
            return try writer.read { db in
                try MergeRequest.filter(Column("companyId") == companyId && Column("number") == number).fetchOne(db)
            }
        }
        guard let item = try workItems(companyId: companyId).first(where: { $0.key.caseInsensitiveCompare(ref) == .orderedSame }) else { return nil }
        return try latestMergeRequest(itemId: item.id)
    }

    /// Owner only: a request the engine gave up on (`failed`) is put back in the queue, its counters cleared, provided its item is
    /// still approved and waiting. A bounced request went back to its holder with the reasons; it comes back by being fixed and
    /// approved again, not by a retry.
    public func requestMergeRetry(requestId: String, by sender: Sender, now: Date = Store.now()) throws {
        guard case .owner = sender else { throw WorkError.forbidden("only the owner can retry a merge") }
        try writer.write { db in
            guard var request = try MergeRequest.fetchOne(db, key: requestId) else { throw WorkError.notFound("no such merge request") }
            guard request.status == .failed else {
                throw WorkError.conflict("\(request.ref) is \(request.status.title.lowercased()), not failed: only a failed merge is retried")
            }
            guard var item = try WorkItem.fetchOne(db, key: request.itemId), item.companyId == request.companyId,
                  item.status == .inReview, item.verifiedCommit != nil else {
                throw WorkError.conflict("\(request.ref)'s item is no longer approved and waiting, so there is nothing to retry")
            }
            // A newer open request of the item is the retry already.
            if try MergeRequest.filter(Column("itemId") == item.id && Self.openStatuses.contains(Column("status"))).fetchCount(db) > 0 {
                throw WorkError.conflict("\(item.key) already has a merge in the queue")
            }
            let number = try Store.nextMergeRequestNumber(db: db, companyId: request.companyId)
            // The same approval: a fresh request pinned to the verified commit and check revision.
            var fresh = MergeRequest(companyId: request.companyId, itemId: item.id, number: number, headCommit: item.verifiedCommit ?? request.headCommit,
                                     checkRevision: item.verifiedRevision ?? request.checkRevision, enqueuedAt: now)
            fresh.retryRequestedAt = now
            try fresh.insert(db)
            request.retryRequestedAt = now
            try request.update(db)
            item.mergeState = .pending
            item.updatedAt = now
            try item.update(db)
            try recordItemEvent(db: db, item: item, actor: "owner", kind: .mergeQueued, text: "queued to merge again as \(fresh.ref) (the owner retried \(request.ref))", now: now)
        }
    }

    /// Owner only: releases the merge hold. A hold set because the root checkout did not follow `main` is released only once the
    /// root matches `main` again (clean checkout on `main`); otherwise the next batch would quarantine the old files as the owner's
    /// edits, and accepting that would revert what landed.
    @discardableResult
    public func resumeMergeQueue(companyId: String, by sender: Sender, now: Date = Store.now()) throws -> Bool {
        guard case .owner = sender else { throw WorkError.forbidden("only the owner can resume the merge queue") }
        guard let company = try company(id: companyId) else { throw WorkError.notFound("no such company") }
        // A landing the engine could not record is recorded first (the engine's next tick finishes that batch): never a silent
        // half-clear of the hold with the engine still stuck.
        let repaired = try repairUnrecordedLandings(companyId: companyId, now: now)
        guard let hold = company.mergeHold else { return repaired > 0 }
        if hold.hasPrefix(Self.rootBehindHoldPrefix) {
            let git = gitWorkspace(root: URL(fileURLWithPath: company.workspacePath, isDirectory: true), companyId: companyId)
            let matches: Bool
            do { matches = try git.rootBranch() == GitWorkspace.mainRef && !git.isDirty(in: URL(fileURLWithPath: company.workspacePath, isDirectory: true)) }
            catch { throw WorkError.conflict("\(Self.rootBehindRefusal) (the root could not be read: \(Self.flat("\(error)", max: 120)))") }
            guard matches else { throw WorkError.conflict(Self.rootBehindRefusal) }
        }
        try setMergeHold(companyId: companyId, reason: nil, now: now)
        return true
    }
}
