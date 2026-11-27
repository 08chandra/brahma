import Foundation
import GRDB

/// Plan X8 Task 4: what a PR's checks and reviews send back to the item, the owner's alert for a landing held for good, and how
/// a waiting landing reads in `brahma why`.
extension Store {
    /// GitHub turned the item's open PR down (`to`: `checksFailed` or `changesRequested`). In one write, compare-and-set on the
    /// (`from` state, `sha`, PR `number`) the step read AND on the item's merge request handed to this PR for `sha` (fix round 1:
    /// without one, nothing is written — no state move, no event): the landing moves to `to` with `status` (why it waits) and
    /// stays open; the request is bounced and the item goes back to In progress the way a failed merge does (`returnUnmerged`:
    /// nothing approved, `mergeFailed` with `detail`, a system DM to its holder — engine text only, which also leaves no merge
    /// lockout); and GitHub's `feedback` goes to the item's owner agent (else its holder) as a waking `prFeedback` event, tainted
    /// when any part is EXTERNAL (its reader is tainted at launch, `relayedTaint`). False — nothing written — otherwise.
    @discardableResult
    func returnPRFeedback(itemId: String, number: Int, from state: PRLandingState, sha: String, to newState: PRLandingState, status: String,
                          detail: String, feedback: PRFeedback.Message, now: Date) throws -> Bool {
        guard newState == .checksFailed || newState == .changesRequested else { throw WorkError.invalid("not a feedback state") }
        let shownStatus = try redact(Self.flat(status, max: 300))
        let shownDetail = try redact(Self.flat(detail, max: 500))
        return try writer.write { db in
            guard var landing = try PRLanding.fetchOne(db, key: itemId), landing.state == state, landing.pushedSHA == sha,
                  landing.prNumber == number, let item = try WorkItem.fetchOne(db, key: itemId),
                  try handedToPRRequest(db, itemId: itemId, sha: sha) != nil else { return false }
            landing.state = newState
            landing.lastError = shownStatus
            landing.lastPolled = now
            landing.updatedAt = now
            try landing.save(db)
            _ = try releaseHandedToPR(db, item: item, sha: sha, failure: newState == .checksFailed ? .itemCheckFailed : nil,
                                      detail: shownDetail, now: now)
            let current = try WorkItem.fetchOne(db, key: itemId) ?? item
            let recipient = try item.ownerId ?? Self.leaseHolderId(db: db, itemId: itemId)
            try recordItemEvent(db: db, item: current, actor: "system", kind: .prFeedback,
                                text: PRFeedback.eventText(number: number, message: feedback),
                                alsoNotify: [recipient].compactMap { $0 }, alsoNotifyRole: .owner, onlyAlsoNotify: true,
                                taintedOverride: feedback.isExternal, now: now)
            return true
        }
    }

    /// The item's merge request handed to its PR (for `sha`, or the latest one when nil).
    func handedToPRRequest(_ db: Database, itemId: String, sha: String?) throws -> MergeRequest? {
        var filter = Column("itemId") == itemId && Column("status") == MergeRequestStatus.handedToPR.rawValue
        if let sha { filter = filter && Column("candidateCommit") == sha }
        return try MergeRequest.filter(filter).order(Column("number").desc).fetchOne(db)
    }

    /// Bounces the item's merge request handed to its PR (see `handedToPRRequest`) and returns the item to its holder through the
    /// merge queue's own path (`returnUnmerged`). False when there is none.
    func releaseHandedToPR(_ db: Database, item: WorkItem, sha: String?, failure: MergeFailure?, detail: String, now: Date) throws -> Bool {
        guard var request = try handedToPRRequest(db, itemId: item.id, sha: sha) else { return false }
        request.status = .bounced
        request.failure = failure
        request.detail = detail
        request.finishedAt = now
        try request.update(db)
        try returnUnmerged(db, item: item, request: request, now: now)
        return true
    }

    // MARK: Hold alerts (fix round 1, I3)

    /// The engine alert of one landing held for good at one commit.
    static func prHoldAlertReason(itemId: String, sha: String) -> String { "prhold:\(itemId)@\(sha)" }

    /// The owner hears once that the item's landing is held for good at its commit (a push GitHub refused, a PR Brahma did not
    /// open on the branch, the branch moved outside Brahma): the engine alert (a DM, an activity line and an Inbox card) names
    /// the hold and what to do. Once per (item, commit): never again for that commit, however often the hold is retried, even
    /// after the owner dismissed the card. False when it was raised before.
    @discardableResult
    func raisePRHoldAlert(itemId: String, sha: String, why: String, now: Date) throws -> Bool {
        let reason = Self.prHoldAlertReason(itemId: itemId, sha: sha)
        return try writer.write { db in
            guard let landing = try PRLanding.fetchOne(db, key: itemId), landing.pushedSHA == sha,
                  let item = try WorkItem.fetchOne(db, key: itemId), let company = try Company.fetchOne(db, key: item.companyId) else { return false }
            // An alert for an older commit of the item is over.
            try resolveEngineAlerts(db, reasons: try Self.openPRHoldAlertReasons(db, itemId: itemId).filter { $0 != reason }, now: now)
            let filed = try Ask.filter(Column("companyId") == company.id && Column("kind") == AskKind.engineAlert
                                       && Column("subjectId") == Store.engineAlertKey(reason)).fetchCount(db)
            guard filed == 0 else { return false }
            let pr = landing.prNumber.map { "PR #\($0)" } ?? "pull request"
            try EngineAlerts.raise(store: self, db: db, text: Self.prHoldAlertText(company: company, item: item, pr: pr, why: why),
                                   now: now, reason: reason, companyId: company.id)
            return true
        }
    }

    /// What the alert says: the hold, and the owner's two ways out.
    static func prHoldAlertText(company: Company, item: WorkItem, pr: String, why: String) -> String {
        "\(company.name): \(item.key)'s \(pr) is held: \(Self.flat(why, max: 300)). Brahma never force-pushes; it retries at most every "
            + "\(Int(PRStep.maxBackoff / 60)) minutes. Fix the branch on GitHub, or abandon the landing so the item goes back to its owner "
            + "agent: brahma merge abandon-pr \(company.slug) \(item.key)"
    }

    /// The item's landing is no longer held (or moved to another commit): every open hold alert of the item resolves (a read
    /// first: no write when there is none).
    func resolvePRHoldAlerts(itemId: String, now: Date) throws {
        guard try writer.read({ db in try !Self.openPRHoldAlertReasons(db, itemId: itemId).isEmpty }) else { return }
        try writer.write { db in try resolveEngineAlerts(db, reasons: try Self.openPRHoldAlertReasons(db, itemId: itemId), now: now) }
    }

    /// The reasons of the item's unresolved hold alerts.
    static func openPRHoldAlertReasons(_ db: Database, itemId: String) throws -> [String] {
        let prefix = Store.engineAlertKey(prHoldAlertReason(itemId: itemId, sha: ""))
        return try String.fetchAll(db, sql: """
            SELECT subjectId FROM ask WHERE kind = ? AND status = ? AND substr(subjectId, 1, ?) = ?
            """, arguments: [AskKind.engineAlert.rawValue, AskStatus.pendingOwner.rawValue, prefix.count, prefix])
            .map { String($0.dropFirst(Store.engineAlertKey("").count)) }
    }

    // MARK: Why

    /// One line per open PR landing of the company that waits on something, for `stallReport` (`brahma why`):
    /// - `@eng-1 waits: PR #12 blocked — required check "ci" failing (brought back as feedback)` (and changes requested);
    /// - `@eng-1 waits: PR #12 waiting for a required review` and the open PR's other statuses (`PRStep.isStatus`: waiting for
    ///   re-review, behind its base, conflicts) — GitHub reports no review count without a protection read;
    /// - `@eng-1 waits: PR #12 held — <why>` for any other recorded hold or error (a refused push, an owner card, ...).
    /// `@<handle>` is the item's owner agent, else the item's key.
    func prWaitLines(companyId: String) throws -> [String] {
        try writer.read { db in
            var lines: [String] = []
            let open = try PRLanding.filter(Column("companyId") == companyId && !PRLandingState.closed.map(\.rawValue).contains(Column("state"))
                                            && Column("lastError") != nil).order(Column("updatedAt"), Column("itemId")).fetchAll(db)
            for landing in open {
                guard let why = landing.lastError, let item = try WorkItem.fetchOne(db, key: landing.itemId) else { continue }
                let who = try item.ownerId.flatMap { try Agent.fetchOne(db, key: $0) }.map { "@\($0.name)" } ?? item.key
                let pr = landing.prNumber.map { "PR #\($0)" } ?? "\(item.key)'s pull request"
                switch landing.state {
                case .checksFailed, .changesRequested:
                    lines.append("\(who) waits: \(pr) blocked — \(Self.flat(why, max: 300))")
                case .open where PRStep.isStatus(why):
                    lines.append("\(who) waits: \(pr) \(Self.flat(why, max: 300))")
                default:
                    lines.append("\(who) waits: \(pr) held — \(Self.flat(why, max: 300))")
                }
            }
            return lines
        }
    }
}
