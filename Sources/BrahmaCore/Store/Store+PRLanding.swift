import Foundation
import GRDB

/// The landing machine's writes (Plan X8 Task 3): every transition of an item's `prLanding` row goes through here. The
/// machine's and the push stage's writes are compare-and-set on the (state, commit) their pass started from, in one transaction
/// (fix round 1, I1): an owner's abandon, a new `begin` or a close upstream that landed meanwhile is never overwritten, and the
/// pass stops. `beginPRLanding` and `abandonPRLanding` are the authorities that move a landing on regardless.
extension Store {
    /// What a non-owner is told when it tries to abandon a landing (Ruling 21).
    static let prAbandonOwnerOnly = "only the owner can abandon a PR landing"

    /// Starts (or restarts) the item's landing for `sha` at `pushing`. The same commit again is idempotent: an open landing is
    /// left as it is (true: carry on), a closed one stays closed (false) — except one GitHub sent back (`checksFailed`,
    /// `changesRequested`, Task 4 fix round 1): the item was resubmitted unchanged (a check re-run, a review answered), so the
    /// landing is `open` again and its checks and reviews are read anew. A new commit — the item was resubmitted — restarts at
    /// `pushing` on the landing's branch, keeping its PR while that is open (the PR follows the branch), and voids every owner
    /// card for an older commit.
    func beginPRLanding(item: WorkItem, sha: String, branch: String, now: Date) throws -> Bool {
        try writer.write { db in
            let existing = try PRLanding.fetchOne(db, key: item.id)
            if var existing, existing.pushedSHA == sha {
                if existing.state == .checksFailed || existing.state == .changesRequested {
                    existing.state = .open
                    existing.lastError = nil
                    existing.updatedAt = now
                    try existing.save(db)
                }
                return existing.state.isOpen
            }
            var landing = existing ?? PRLanding(itemId: item.id, companyId: item.companyId, branch: branch, pushedSHA: sha, state: .pushing,
                                                updatedAt: now)
            if let existing, !existing.state.isOpen {
                landing.branch = branch
                landing.prNumber = nil
                landing.prURL = nil
                landing.mergedSHA = nil
                landing.openDigest = nil
                landing.leaseSHA = nil
            } else if let existing, existing.state != .pushing {
                // Ruling X8-31′: the branch holds the commit Brahma pushed and recorded; the resubmit may replace that one only.
                // (Still `pushing`: the earlier commit never was confirmed on GitHub, so the lease stays what it was.)
                landing.leaseSHA = existing.pushedSHA
            }
            landing.pushedSHA = sha
            landing.state = .pushing
            landing.lastError = nil
            landing.updatedAt = now
            try landing.save(db)
            try voidPRActionCards(db, itemId: item.id, keepingSHA: sha, now: now)
            return true
        }
    }

    /// Compare-and-set: changes the item's landing (`updatedAt` set) only while it is still in one of `states` at `sha`, in one
    /// write. False — nothing written — when it moved on (or is gone).
    @discardableResult
    func casPRLanding(itemId: String, from states: Set<PRLandingState>, sha: String, now: Date, _ change: (inout PRLanding) -> Void) throws -> Bool {
        try writer.write { db in
            guard var landing = try PRLanding.fetchOne(db, key: itemId), states.contains(landing.state), landing.pushedSHA == sha else { return false }
            change(&landing)
            landing.updatedAt = now
            try landing.save(db)
            return true
        }
    }

    /// `PushBranchStage`'s record of its own push: creates the landing at `pushing`, or changes one still `pushing` at `sha`
    /// (CAS, as `casPRLanding`). False — nothing written — when the landing moved on meanwhile.
    func recordPushStage(item: WorkItem, branch: String, sha: String, state: PRLandingState, error: String?, now: Date) throws -> Bool {
        try writer.write { db in
            var landing: PRLanding
            if let existing = try PRLanding.fetchOne(db, key: item.id) {
                guard existing.state == .pushing, existing.pushedSHA == sha else { return false }
                landing = existing
            } else {
                guard state == .pushing else { return false }
                landing = PRLanding(itemId: item.id, companyId: item.companyId, branch: branch, pushedSHA: sha, state: .pushing, updatedAt: now)
            }
            landing.branch = branch
            landing.state = state
            landing.lastError = error
            landing.updatedAt = now
            try landing.save(db)
            return true
        }
    }

    /// The remote `main` the merge queue verified `sha` on: the base its hand-off recorded (`markHandedToPR`), or nil.
    func prHandOffBase(itemId: String, sha: String) throws -> String? {
        try writer.read { db in
            try String.fetchOne(db, sql: """
                SELECT baseCommit FROM mergeRequest
                WHERE itemId = ? AND status = 'handedToPR' AND candidateCommit = ? AND baseCommit IS NOT NULL
                ORDER BY number DESC LIMIT 1
                """, arguments: [itemId, sha])
        }
    }

    /// Whether some PR of the company is known to have been opened (`open-pr`'s first use).
    func hasOpenedPRLanding(companyId: String) throws -> Bool {
        try writer.read { db in
            try PRLanding.filter(Column("companyId") == companyId && Column("prNumber") != nil).fetchCount(db) > 0
        }
    }

    /// The PR was closed on GitHub without being merged: the landing ends `closedUpstream` and its owner cards are void. In the
    /// same write (Plan X8 Task 5, carried from Task 4) the item's merge request handed to the PR is bounced and the item goes
    /// back to its holder through the merge queue's own path (`returnUnmerged`: In progress, a `mergeFailed` notice, a DM), so
    /// nothing stays locked in review — as an owner's abandon does. Without such a request (already released) the item's owner
    /// agent still gets the `mergeFailed` notice. CAS on (`state`, `sha`, PR number) the watch read. The release is of the
    /// request handed for `sha`: the PR that closed carries that commit (a request for another commit is not this PR's); the
    /// owner's abandon releases the latest handed request whatever its commit (`sha: nil`), since it gives the landing up.
    func closePRLandingUpstream(itemId: String, number: Int, from state: PRLandingState, sha: String, now: Date) throws {
        try writer.write { db in
            guard var landing = try PRLanding.fetchOne(db, key: itemId), landing.state == state, landing.pushedSHA == sha,
                  landing.prNumber == number, let item = try WorkItem.fetchOne(db, key: itemId) else { return }
            landing.state = .closedUpstream
            landing.lastPolled = now
            landing.lastError = "PR #\(number) was closed on GitHub without merging"
            landing.updatedAt = now
            try landing.save(db)
            try voidPRActionCards(db, itemId: itemId, keepingSHA: nil, now: now)
            try resolveEngineAlerts(db, reasons: try Self.openPRHoldAlertReasons(db, itemId: itemId), now: now)
            let text = "PR #\(number) was closed on GitHub without merging: \(item.key) did not land; resubmit it to open a new one"
            guard try !releaseHandedToPR(db, item: item, sha: sha, failure: nil, detail: text, now: now) else { return }
            try recordItemEvent(db: db, item: item, actor: "system", kind: .mergeFailed, text: text,
                                alsoNotify: item.ownerId.map { [$0] } ?? [], alsoNotifyRole: .owner, onlyAlsoNotify: true, now: now)
        }
    }

    /// Owner only (Ruling 21). Ends the item's open landing (`abandoned`, with the owner's reason) and voids its owner cards;
    /// nothing is closed or deleted on GitHub. Task 4 fix round 1: the item's merge request handed to the PR is bounced and the
    /// item goes back to its holder (it did not land; nothing stays locked in review), and the landing's hold alert resolves.
    public func abandonPRLanding(itemId: String, reason: String, by sender: Sender, now: Date = Store.now()) throws {
        guard sender == .owner else { throw WorkError.forbidden(Self.prAbandonOwnerOnly) }
        try writer.write { db in
            guard var landing = try PRLanding.fetchOne(db, key: itemId) else { throw WorkError.notFound("no PR landing for that item") }
            guard landing.state.isOpen else { throw WorkError.conflict("the PR landing is already \(landing.state.rawValue)") }
            let why = Store.flat(reason, max: 300)
            landing.state = .abandoned
            landing.lastError = why.isEmpty ? "abandoned by the owner" : "abandoned by the owner: \(why)"
            landing.updatedAt = now
            try landing.save(db)
            try voidPRActionCards(db, itemId: itemId, keepingSHA: nil, now: now)
            if let item = try WorkItem.fetchOne(db, key: itemId) {
                _ = try releaseHandedToPR(db, item: item, sha: nil, failure: nil,
                                          detail: "the owner abandoned the item's pull request landing; it did not land", now: now)
            }
            try resolveEngineAlerts(db, reasons: try Self.openPRHoldAlertReasons(db, itemId: itemId), now: now)
        }
    }
}
