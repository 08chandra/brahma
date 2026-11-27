import Foundation
import GRDB

/// Plan X8 Task 5: the merge's records. Pressing merge (`--engine-merge`, behind the owner's card) starts with one write that
/// moves the landing `mergeable` → `merging` and spends the card's approval together, so an approval presses merge at most
/// once whatever happens next; a merged PR completes its item through the merge queue's own landing record (`recordLanded`).
extension Store {
    /// The engine is about to send `merge-pr` for the item's landing at `sha`: in one write, compare-and-set `mergeable` →
    /// `merging` (`lastError` cleared) and, when the gate's `auto` came from the owner's card (`approvalAskId`), that approval is
    /// used up. False — nothing written, nothing to send — when the landing moved on or the approval is not usable any more.
    func startPRMerge(itemId: String, sha: String, approvalAskId: String?, now: Date) throws -> Bool {
        try writer.write { db in
            guard var landing = try PRLanding.fetchOne(db, key: itemId), landing.state == .mergeable, landing.pushedSHA == sha else { return false }
            if let approvalAskId {
                try db.execute(sql: """
                    UPDATE prActionApproval SET consumedAt = ?
                    WHERE askId = ? AND itemId = ? AND action = ? AND sha = ? AND approvedAt IS NOT NULL AND consumedAt IS NULL
                    """, arguments: [now, approvalAskId, itemId, GitHubActionType.mergePR.name, sha])
                guard db.changesCount == 1 else { return false }
            }
            landing.state = .merging
            landing.lastError = nil
            landing.updatedAt = now
            try landing.save(db)
            return true
        }
    }

    /// The item's PR is merged: an owner card still pending for it (a `merge-pr` the owner had not decided when a human merged
    /// on GitHub) can decide nothing any more and is superseded. Decided cards stay as they are (their history).
    func supersedePendingPRActionCards(itemId: String, now: Date) throws {
        try writer.write { db in
            for row in try PRActionApproval.filter(Column("itemId") == itemId).fetchAll(db) {
                guard var ask = try Ask.fetchOne(db, key: row.askId), ask.status.isPending else { continue }
                try settle(db, ask: &ask, status: .superseded, decidedBy: "system", tellRequesterToo: false, now: now)
                _ = try row.delete(db)
            }
        }
    }

    /// The company's merged landings whose item has not completed yet: the merge request handed to the PR for the pushed commit
    /// is still open (`handedToPR`). The PR step finishes them (the remote `main` fetch, then `recordLanded`).
    func prLandingsAwaitingCompletion(companyId: String) throws -> [PRLanding] {
        try writer.read { db in
            try PRLanding.fetchAll(db, sql: "SELECT l.* FROM prLanding l WHERE l.companyId = ? AND \(Self.awaitsCompletion) ORDER BY l.updatedAt, l.itemId",
                                   arguments: [companyId, PRLandingState.merged.rawValue, MergeRequestStatus.handedToPR.rawValue])
        }
    }

    /// The item's landing when it awaits completion (`prLandingsAwaitingCompletion`), else nil.
    func prLandingAwaitingCompletion(itemId: String) throws -> PRLanding? {
        try writer.read { db in
            try PRLanding.fetchOne(db, sql: "SELECT l.* FROM prLanding l WHERE l.itemId = ? AND \(Self.awaitsCompletion)",
                                   arguments: [itemId, PRLandingState.merged.rawValue, MergeRequestStatus.handedToPR.rawValue])
        }
    }

    /// `merged`, and the item's merge request for the pushed commit still `handedToPR` (arguments: the two states, in order).
    private static let awaitsCompletion = """
        l.state = ? AND EXISTS (SELECT 1 FROM mergeRequest r WHERE r.itemId = l.itemId AND r.status = ? AND r.candidateCommit = l.pushedSHA)
        """

    /// The item's PR is merged on GitHub and the remote `main` was fetched: the item completes through the merge queue's own
    /// landing record — its handed-to-PR request for `sha` becomes `merged` at `mergedCommit`, one "merged into main" line, the
    /// item Done (`finishMerge`) — so one landing record exists whichever way the item landed. `company.mainCommit` and the
    /// local `main` are the remote-main fetch's to move (Task 6), not this record's. False when no request is handed to the PR
    /// for `sha` (completed before, or the item was brought back). Runs git (`finishMerge`'s housekeeping): call it on `Blocking`.
    @discardableResult
    func completePRLanding(itemId: String, sha: String, mergedCommit: String, now: Date) throws -> Bool {
        guard let request = try writer.read({ db in try handedToPRRequest(db, itemId: itemId, sha: sha) }) else { return false }
        try recordLanded([(requestId: request.id, mergedCommit: mergedCommit)], mainCommit: nil, now: now)
        return true
    }
}
