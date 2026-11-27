import Foundation
import GRDB

/// The landing machine's writes (Plan X8 Task 3): every transition of an item's `prLanding` row goes through here or through
/// `PushBranchStage`'s record of its own push.
extension Store {
    /// What a non-owner is told when it tries to abandon a landing (Ruling 21).
    static let prAbandonOwnerOnly = "only the owner can abandon a PR landing"

    /// Starts (or restarts) the item's landing for `sha` at `pushing`. The same commit again is idempotent: an open landing is
    /// left as it is (true: carry on), a closed one stays closed (false). A new commit — the item was resubmitted — restarts at
    /// `pushing` on the landing's branch, keeping its PR while that is open (the PR follows the branch), and voids every owner
    /// card for an older commit.
    func beginPRLanding(item: WorkItem, sha: String, branch: String, now: Date) throws -> Bool {
        try writer.write { db in
            let existing = try PRLanding.fetchOne(db, key: item.id)
            if let existing, existing.pushedSHA == sha { return existing.state.isOpen }
            var landing = existing ?? PRLanding(itemId: item.id, companyId: item.companyId, branch: branch, pushedSHA: sha, state: .pushing,
                                                updatedAt: now)
            if let existing, !existing.state.isOpen {
                landing.branch = branch
                landing.prNumber = nil
                landing.prURL = nil
                landing.mergedSHA = nil
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

    /// Changes the item's landing in one write (`updatedAt` set); nil when there is none.
    @discardableResult
    func updatePRLanding(itemId: String, now: Date, _ change: (inout PRLanding) -> Void) throws -> PRLanding? {
        try writer.write { db in
            guard var landing = try PRLanding.fetchOne(db, key: itemId) else { return nil }
            change(&landing)
            landing.updatedAt = now
            try landing.save(db)
            return landing
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

    /// The PR was closed on GitHub without being merged: the landing ends `closedUpstream`, its owner cards are void, and the
    /// item's owner agent gets a work notice (a `mergeFailed` event: the item did not land, back to its holder).
    func closePRLandingUpstream(itemId: String, number: Int, now: Date) throws {
        try writer.write { db in
            guard var landing = try PRLanding.fetchOne(db, key: itemId), landing.state.isOpen,
                  let item = try WorkItem.fetchOne(db, key: itemId) else { return }
            landing.state = .closedUpstream
            landing.lastPolled = now
            landing.lastError = "PR #\(number) was closed on GitHub without merging"
            landing.updatedAt = now
            try landing.save(db)
            try voidPRActionCards(db, itemId: itemId, keepingSHA: nil, now: now)
            try recordItemEvent(db: db, item: item, actor: "system", kind: .mergeFailed,
                                text: "PR #\(number) was closed on GitHub without merging: \(item.key) did not land; resubmit it to open a new one",
                                alsoNotify: item.ownerId.map { [$0] } ?? [], alsoNotifyRole: .owner, onlyAlsoNotify: true, now: now)
        }
    }

    /// Owner only (Ruling 21). Ends the item's open landing (`abandoned`, with the owner's reason) and voids its owner cards;
    /// nothing is closed or deleted on GitHub.
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
        }
    }
}
