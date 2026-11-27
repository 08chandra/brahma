import Foundation
import GRDB

/// Plan X8 Task 4: what a PR's checks and reviews send back to the item, and how a waiting landing reads in `brahma why`.
extension Store {
    /// GitHub turned the item's open PR down (`to`: `checksFailed` or `changesRequested`). In one write, compare-and-set on the
    /// (`from` state, `sha`, PR `number`) the step read: the landing moves to `to` with `status` (why it waits) and stays open;
    /// the item's merge request handed to this PR is bounced and the item goes back to In progress the way a failed merge does
    /// (`returnUnmerged`: nothing approved, `mergeFailed` with `detail`, a system DM to its holder — engine text only, which
    /// also leaves no merge lockout); and GitHub's `feedback` goes to the item's owner agent (else its holder) as a waking
    /// `prFeedback` event, tainted when any part is EXTERNAL (its reader is tainted at launch, `relayedTaint`). False — nothing
    /// written — when the landing moved on meanwhile.
    @discardableResult
    func returnPRFeedback(itemId: String, number: Int, from state: PRLandingState, sha: String, to newState: PRLandingState, status: String,
                          detail: String, feedback: PRFeedback.Message, now: Date) throws -> Bool {
        guard newState == .checksFailed || newState == .changesRequested else { throw WorkError.invalid("not a feedback state") }
        let shownStatus = try redact(Self.flat(status, max: 300))
        let shownDetail = try redact(Self.flat(detail, max: 500))
        return try writer.write { db in
            guard var landing = try PRLanding.fetchOne(db, key: itemId), landing.state == state, landing.pushedSHA == sha,
                  landing.prNumber == number, let item = try WorkItem.fetchOne(db, key: itemId) else { return false }
            landing.state = newState
            landing.lastError = shownStatus
            landing.lastPolled = now
            landing.updatedAt = now
            try landing.save(db)
            if var request = try MergeRequest.filter(Column("itemId") == itemId && Column("status") == MergeRequestStatus.handedToPR.rawValue
                                                     && Column("candidateCommit") == sha).order(Column("number").desc).fetchOne(db) {
                request.status = .bounced
                request.failure = newState == .checksFailed ? .itemCheckFailed : nil
                request.detail = shownDetail
                request.finishedAt = now
                try request.update(db)
                try returnUnmerged(db, item: item, request: request, now: now)
            }
            let current = try WorkItem.fetchOne(db, key: itemId) ?? item
            let recipient = try item.ownerId ?? Self.leaseHolderId(db: db, itemId: itemId)
            try recordItemEvent(db: db, item: current, actor: "system", kind: .prFeedback,
                                text: PRFeedback.eventText(number: number, message: feedback),
                                alsoNotify: [recipient].compactMap { $0 }, alsoNotifyRole: .owner, onlyAlsoNotify: true,
                                taintedOverride: feedback.isExternal, now: now)
            return true
        }
    }

    /// One line per open PR landing of the company that waits on something, for `stallReport` (`brahma why`):
    /// - `@eng-1 waits: PR #12 blocked — required check "ci" failing (brought back as feedback)` (and changes requested);
    /// - `@eng-1 waits: PR #12 waiting for a required review` (GitHub reports no count without a protection read);
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
                case .open where why == PRStep.waitingForReviewText:
                    lines.append("\(who) waits: \(pr) \(PRStep.waitingForReviewText)")
                default:
                    lines.append("\(who) waits: \(pr) held — \(Self.flat(why, max: 300))")
                }
            }
            return lines
        }
    }
}
