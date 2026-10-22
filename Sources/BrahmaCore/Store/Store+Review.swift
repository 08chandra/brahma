import Foundation
import GRDB

public enum ReviewDecision: String, Sendable, Equatable {
    case approve
    case requestChanges = "request_changes"
}

extension Store {
    /// Review turns that end without a decision before the reviewer's manager (else the owner) is told.
    public static let maxReviewAttempts = 3
    static let maxReviewNotes = 8192
    static let reviewTurnOnlyMessage = "reviews happen in their own review turn; you will get one for each item waiting on you"
    public static let mainChangedMessage = "main changed outside Brahma; the owner must review it"

    // MARK: Turn context

    /// Marks an in-progress turn as a review (or other kind) of one item. The MCP credential of the turn is issued with the
    /// same kind and item, so the review tool is reachable from that turn only.
    public func setTurnContext(turnId: String, kind: TurnKind, itemId: String?) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE turn SET kind = ?, itemId = ? WHERE id = ?", arguments: [kind, itemId, turnId])
        }
    }

    // MARK: Pending reviews

    /// The condition for a review turn, in SQL (the item is `inReview`, nobody has decided this round, the engine's check
    /// passed for the current check revision, and the reviewer has not used up its attempts).
    static let pendingReviewWhere = """
        status = 'inReview' AND mergeState = 'none' AND reviewedRound < reviewRound AND verifiedRevision = checkRevision
        AND verifiedCommit IS NOT NULL AND reviewAttempts < \(Store.maxReviewAttempts)
        """

    /// Items waiting for this agent's review, oldest first.
    public func pendingReviews(agentId: String) throws -> [WorkItem] {
        try writer.read { db in try Store.pendingReviews(db: db, agentId: agentId) }
    }

    static func pendingReviews(db: Database, agentId: String) throws -> [WorkItem] {
        guard let agent = try Agent.fetchOne(db, key: agentId), agent.state != .killed else { return [] }
        return try WorkItem.fetchAll(db, sql: """
            SELECT * FROM workItem WHERE companyId = ? AND reviewerId = ? AND \(pendingReviewWhere) ORDER BY updatedAt, number
            """, arguments: [agent.companyId, agentId])
    }

    static func hasPendingReview(db: Database, agentId: String) throws -> Bool {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workItem WHERE reviewerId = ? AND \(pendingReviewWhere)", arguments: [agentId]) ?? 0 > 0
    }

    /// A reviewer asleep when its review becomes due (a pass without a notice, a new reviewer) is made ready.
    static func wakeReviewer(db: Database, item: WorkItem, now: Date) throws {
        guard let reviewerId = item.reviewerId, try hasPendingReviewOf(db: db, itemId: item.id, agentId: reviewerId),
              let agent = try Agent.fetchOne(db, key: reviewerId), agent.state == .sleeping, !agent.paused else { return }
        try transition(db: db, agentId: reviewerId, to: .ready, now: now)
    }

    private static func hasPendingReviewOf(db: Database, itemId: String, agentId: String) throws -> Bool {
        try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM workItem WHERE id = ? AND reviewerId = ? AND \(pendingReviewWhere)",
                         arguments: [itemId, agentId]) ?? 0 > 0
    }

    // MARK: Reviewer resolution

    /// The owner's (assignee's) non-killed manager; else a cto-covering non-killed agent other than the owner; else any
    /// non-killed executive other than the owner. Nobody: `.conflict`.
    func resolveReviewer(db: Database, item: WorkItem) throws -> Agent {
        let ownerId = try item.ownerId ?? Self.leaseHolderId(db: db, itemId: item.id)
        if let ownerId, let owner = try Agent.fetchOne(db, key: ownerId), let managerId = owner.managerId,
           let manager = try Agent.fetchOne(db, key: managerId), manager.companyId == item.companyId, manager.state != .killed,
           manager.id != ownerId {
            return manager
        }
        let packId = try Company.fetchOne(db, key: item.companyId)?.packId ?? "software"
        let ctoRoles = catalog.pack(packId)?.rolesCovering("cto") ?? []
        let live = try Agent.filter(Column("companyId") == item.companyId && Column("state") != AgentState.killed.rawValue)
            .order(Column("createdAt"), Column.rowID).fetchAll(db).filter { $0.id != ownerId }
        if let cto = live.first(where: { ctoRoles.contains($0.role) }) { return cto }
        if let executive = live.first(where: { catalog.template(role: $0.role, pack: packId).kind == .executive }) { return executive }
        throw WorkError.conflict("no reviewer available; set a reviewer on \(item.key)")
    }

    /// Whether the item's current reviewer can still review it: an active teammate who is not the assignee.
    func reviewerIsUsable(db: Database, item: WorkItem) throws -> Bool {
        guard let id = item.reviewerId, let agent = try Agent.fetchOne(db, key: id) else { return false }
        return agent.companyId == item.companyId && agent.state != .killed && id != item.ownerId
    }

    /// A submit would be refused for want of a reviewer: said before anything is committed.
    func checkReviewerAvailable(itemId: String) throws {
        try writer.read { db in
            guard let item = try WorkItem.fetchOne(db, key: itemId) else { throw WorkError.notFound("no such work item") }
            if try !reviewerIsUsable(db: db, item: item) { _ = try resolveReviewer(db: db, item: item) }
        }
    }

    // MARK: Approval

    /// The one way an item becomes approved for merge: its flags are cleared (the event lists them), the round is closed
    /// and `mergeState` is `pending`. `Store.review` and 9c's auto-approval both come here. `by` is an agent id or "system".
    /// `auto`: the engine's risk-tiered auto-approval (9c), counted and queued for audit when the item lands.
    @discardableResult
    func approveForMerge(db: Database, item current: WorkItem, by: String, note: String, auto: Bool = false, now: Date) throws -> WorkItem {
        var item = current
        var text = note
        if !item.reviewFlags.isEmpty { text += " (approved flags: \(item.reviewFlags.joined(separator: "; ")))" }
        item.reviewFlags = []
        item.autoApproved = auto
        item.mergeState = .pending
        item.reviewedRound = item.reviewRound
        item.reviewAttempts = 0
        item.updatedAt = now
        try item.update(db)
        try recordItemEvent(db: db, item: item, actor: by, kind: .reviewApproved, text: text, now: now)
        return item
    }

    // MARK: Review

    /// The reviewer's decision, from inside its own review turn. Authority (all required): the caller is an agent of the item's
    /// company, is its reviewer and not its assignee or lease holder; the item is `inReview` with nothing decided this round
    /// and no merge pending; and the caller has an in-progress review turn for exactly this item.
    ///
    /// Approve additionally needs the engine's pass for the current check revision on the head the reviewer saw
    /// (`currentHead`), and explicit approval of any review flags.
    @discardableResult
    public func review(itemId: String, by agentId: String, decision: ReviewDecision, notes: String, approveFlags: Bool,
                       currentHead: String?, now: Date = Store.now()) throws -> WorkItem {
        try writer.write { db in
            guard let item = try WorkItem.fetchOne(db, key: itemId) else { throw WorkError.notFound("no such work item") }
            let actor = try resolveActor(db, .agent(agentId), companyId: item.companyId)
            let holder = try Self.leaseHolderId(db: db, itemId: item.id)
            if agentId == item.ownerId || agentId == holder {
                throw WorkError.forbidden("the assignee cannot review their own item")
            }
            guard let reviewerId = item.reviewerId else { throw WorkError.forbidden("\(item.key) has no reviewer") }
            guard reviewerId == agentId else {
                let handle = try Agent.fetchOne(db, key: reviewerId)?.name ?? "?"
                throw WorkError.forbidden("\(item.key) is reviewed by @\(handle), not by you")
            }
            guard item.status == .inReview else {
                throw WorkError.conflict("\(item.key) is \(item.status.title.lowercased()), not in review")
            }
            guard item.mergeState != .verifying else {
                throw WorkError.conflict("\(item.key) is being checked again after a rebase onto main; review it when that check passes")
            }
            guard item.mergeState == .none else { throw WorkError.conflict("\(item.key) is already approved and waiting to merge") }
            guard item.reviewedRound < item.reviewRound else { throw WorkError.conflict("\(item.key) was already reviewed this round") }
            let inTurn = try Int.fetchOne(db, sql: """
                SELECT COUNT(*) FROM turn WHERE agentId = ? AND kind = 'review' AND itemId = ? AND outcome = 'inProgress'
                """, arguments: [agentId, item.id]) ?? 0
            guard inTurn > 0 else { throw WorkError.forbidden(Self.reviewTurnOnlyMessage) }
            let body = notes.trimmingCharacters(in: .whitespacesAndNewlines)
            guard body.count <= Self.maxReviewNotes else {
                throw WorkError.invalid("the notes are longer than \(Self.maxReviewNotes) characters")
            }

            switch decision {
            case .approve:
                guard item.verifiedRevision == item.checkRevision, item.verifiedCommit != nil else {
                    throw WorkError.conflict("\(item.key) has no passing check for revision \(item.checkRevision)")
                }
                guard let currentHead, currentHead == item.verifiedCommit else {
                    throw WorkError.conflict("\(item.key) changed since its check passed; the author must resubmit")
                }
                if !item.reviewFlags.isEmpty, !approveFlags {
                    throw WorkError.conflict("\(item.key) has review flags (\(item.reviewFlags.joined(separator: "; "))); "
                        + "approve them explicitly with approve_flags: true or request changes")
                }
                let flatNotes = body.components(separatedBy: .newlines).joined(separator: " ")
                let note = flatNotes.isEmpty ? "approved by @\(actor.handle)" : "approved by @\(actor.handle): \(String(flatNotes.prefix(500)))"
                return try approveForMerge(db: db, item: item, by: agentId, note: note, now: now)

            case .requestChanges:
                guard !body.isEmpty else { throw WorkError.invalid("request_changes needs notes: say what to change") }
                var updated = item
                updated.reviewedRound = item.reviewRound
                updated.reviewAttempts = 0
                updated.updatedAt = now
                try updated.update(db)
                let returned = try engineSetStatus(db: db, itemId: item.id, to: .inProgress, now: now)
                try Store.refreshLease(db, itemId: item.id, companyId: item.companyId)
                try recordItemEvent(db: db, item: returned, actor: agentId, kind: .changesRequested, text: body,
                                    alsoNotify: [holder].compactMap { $0 }, alsoNotifyRole: .holder, now: now)
                return returned
            }
        }
    }

    /// An item's check was edited while it was in review: it is unverified, so it goes back to its holder to resubmit.
    func returnForChangedCheck(db: Database, item current: WorkItem, now: Date) throws {
        var item = current
        item.mergeState = .none
        item.reviewAttempts = 0
        item.verifiedRevision = nil
        item.verifiedCommit = nil
        item.updatedAt = now
        try item.update(db)
        let returned = try engineSetStatus(db: db, itemId: item.id, to: .inProgress, now: now)
        try Store.refreshLease(db, itemId: item.id, companyId: item.companyId)
        let holder = try Self.leaseHolderId(db: db, itemId: item.id)
        try recordItemEvent(db: db, item: returned, actor: "system", kind: .verificationFailed,
                            text: "check changed during review; resubmit", alsoNotify: [holder].compactMap { $0 },
                            alsoNotifyRole: .holder, now: now)
    }

    // MARK: Review turns ending

    /// Called when a turn is recorded as ended, inside the same transaction. A review turn that succeeded or failed (not for
    /// infrastructure reasons) without a decision counts as an attempt; at `maxReviewAttempts` the reviewer's nearest active
    /// manager (else the owner) is told. Interrupted, usage-limited and infrastructure-failed turns count for nothing.
    func noteReviewTurnEnd(db: Database, turnId: String, agent: Agent, end: TurnEnd, infra: Bool, now: Date) throws {
        guard let turn = try Turn.fetchOne(db, key: turnId) else { return }
        if turn.kind == .audit { try noteAuditTurnEnd(db: db, turn: turn, end: end, infra: infra); return }
        guard turn.kind == .review, let itemId = turn.itemId else { return }
        var succeeded = false
        switch end {
        case .succeeded: succeeded = true
        case .failed: if infra { return }
        case .capped: break
        default: return
        }
        if succeeded {
            // The digest was the notice: the reviewer's own pass notice for this item needs no second turn. Done whether or not
            // the reviewer decided (a decision makes the item non-pending, so this comes before the attempt below).
            try db.execute(sql: """
                UPDATE workNotice SET deliveredTurnId = ? WHERE agentId = ? AND deliveredTurnId IS NULL AND eventId IN
                (SELECT id FROM workItemEvent WHERE itemId = ? AND kind IN ('verificationPassed', 'submitted'))
                """, arguments: [turnId, agent.id, itemId])
        }
        try countReviewAttempt(db: db, itemId: itemId, agent: agent, now: now)
    }

    /// One more review turn that ended without a decision, if the item is still waiting for this agent's review. At
    /// `maxReviewAttempts` the reviewer's nearest active manager (else the owner) is told.
    func countReviewAttempt(db: Database, itemId: String, agent: Agent, now: Date) throws {
        guard var item = try WorkItem.fetchOne(db, key: itemId), try Self.hasPendingReviewOf(db: db, itemId: itemId, agentId: agent.id)
        else { return }
        item.reviewAttempts += 1
        item.updatedAt = now
        try item.update(db)
        guard item.reviewAttempts >= Self.maxReviewAttempts else { return }
        let text = "@\(agent.name) has not reviewed \(item.key) after \(Self.maxReviewAttempts) review turns; set another reviewer or talk to them."
        var target = "owner"
        var cursor = agent.managerId
        var hops = 0
        while let id = cursor, hops < 50, let ancestor = try Agent.fetchOne(db, key: id) {
            if ancestor.state != .killed { target = ancestor.name; break }
            cursor = ancestor.managerId
            hops += 1
        }
        try MessageRouter(store: self).sendDM(db: db, companyId: item.companyId, from: .system, to: target, text: text, now: now)
    }
}

extension Store {
    /// A review turn that could not start because the item's worktree could not be created: an attempt like any other
    /// undecided review turn (the lease-holder rules do not apply to a reviewer), so the escalation applies.
    func noteReviewWorktreeFailure(itemId: String, agentId: String, reason: String, now: Date) throws {
        try writer.write { db in
            guard let agent = try Agent.fetchOne(db, key: agentId), let item = try WorkItem.fetchOne(db, key: itemId) else { return }
            try ActivityEvent(companyId: agent.companyId, agentId: agentId, turnId: nil, kind: .error,
                              text: "@\(agent.name) review of \(item.key) not started: the worktree could not be created (\(Store.flat(reason, max: 200)))",
                              createdAt: now).insert(db)
            try countReviewAttempt(db: db, itemId: itemId, agent: agent, now: now)
        }
    }
}
