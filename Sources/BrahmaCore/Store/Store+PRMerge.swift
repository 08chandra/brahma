import Foundation
import GRDB

/// Plan X8 Task 5: the merge's records. Pressing merge (`--engine-merge`, behind the owner's card) starts with one write that
/// moves the landing `mergeable` → `merging` and spends the card's approval together, so an approval presses merge at most
/// once whatever happens next; a merged PR completes its item through the merge queue's own landing record (`recordLanded`).
extension Store {
    /// The engine is about to send `merge-pr` for the item's landing at `sha`: in one write, compare-and-set `mergeable` →
    /// `merging` (`lastError` cleared) and the owner's approval (`approvalAskId`, owner-decided, unused) is used up. There is no
    /// merge without one (rule 4: irreversible, whatever a gate answered). False — nothing written, nothing to send — when the
    /// landing moved on or the approval is not usable.
    func startPRMerge(itemId: String, sha: String, approvalAskId: String, now: Date) throws -> Bool {
        try writer.write { db in
            guard var landing = try PRLanding.fetchOne(db, key: itemId), landing.state == .mergeable, landing.pushedSHA == sha,
                  let ask = try Ask.fetchOne(db, key: approvalAskId), ask.status == .approved, ask.decidedBy == "owner" else { return false }
            try db.execute(sql: """
                UPDATE prActionApproval SET consumedAt = ?
                WHERE askId = ? AND itemId = ? AND action = ? AND sha = ? AND approvedAt IS NOT NULL AND consumedAt IS NULL
                """, arguments: [now, approvalAskId, itemId, GitHubActionType.mergePR.name, sha])
            guard db.changesCount == 1 else { return false }
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
    static let awaitsCompletion = """
        l.state = ? AND EXISTS (SELECT 1 FROM mergeRequest r WHERE r.itemId = l.itemId AND r.status = ? AND r.candidateCommit = l.pushedSHA)
        """

    /// The item's PR is merged on GitHub and the remote `main` was fetched: the item completes through the merge queue's own
    /// landing record — its handed-to-PR request for `sha` becomes `merged` at `mergedCommit`, one "merged into main" line, the
    /// item Done (`finishMerge`) — so one landing record exists whichever way the item landed. `company.mainCommit` and the
    /// local `main` are the remote-main fetch's to move (Task 6), not this record's. False when no request is handed to the PR
    /// for `sha` (completed before, or the item was brought back). Runs git (`finishMerge`'s housekeeping): call it on `Blocking`.
    /// `how`: how GitHub merged it, from the merge commit's parents (`a merge commit`, `squash or rebase`): recorded on the
    /// company's activity line.
    @discardableResult
    func completePRLanding(itemId: String, sha: String, mergedCommit: String, number: Int, how: String, now: Date) throws -> Bool {
        guard let request = try writer.read({ db in try handedToPRRequest(db, itemId: itemId, sha: sha) }) else { return false }
        try recordLanded([(requestId: request.id, mergedCommit: mergedCommit)], mainCommit: nil, now: now)
        try writer.write { db in
            guard let item = try WorkItem.fetchOne(db, key: itemId) else { return }
            try ActivityEvent(companyId: item.companyId, agentId: nil, turnId: nil, kind: .merge,
                              text: "\(item.key): PR #\(number) merged on GitHub as \(how) (\(mergedCommit.prefix(7))), proven on the fetched main",
                              createdAt: now).insert(db)
        }
        return true
    }

    /// Ruling 35 / X8-34 / X8-32c: GitHub reports the item's PR merged, but Brahma cannot prove it landed the commit it verified
    /// (the head was not the pushed commit, the base not the default branch, no merge commit, a rewritten remote `main`, a main
    /// without the merge commit, a merge commit without the pushed commit) — or it was merged after the item was brought back
    /// ("merged outside Brahma"). In one write, compare-and-set on (`from`, `sha`): the landing is `merged` with `why`; the
    /// verified commit is NEVER recorded as landed: the item's request handed to the PR is bounced and the item goes back to
    /// its holder (`returnUnmerged`); its pending cards are superseded; and the owner gets ONE engine alert (an Inbox card, a
    /// DM) per (item, commit). False when the landing moved on.
    @discardableResult
    func holdMergedPRLanding(itemId: String, sha: String, from states: Set<PRLandingState>, mergedSHA: String?, why: String,
                             now: Date) throws -> Bool {
        let shown = try redact(Self.flat(why, max: 400))
        return try writer.write { db in
            guard var landing = try PRLanding.fetchOne(db, key: itemId), states.contains(landing.state), landing.pushedSHA == sha,
                  let item = try WorkItem.fetchOne(db, key: itemId), let company = try Company.fetchOne(db, key: item.companyId) else { return false }
            landing.state = .merged
            landing.mergedSHA = mergedSHA
            landing.lastError = shown
            landing.lastPolled = now
            landing.updatedAt = now
            try landing.save(db)
            for row in try PRActionApproval.filter(Column("itemId") == itemId).fetchAll(db) {
                guard var ask = try Ask.fetchOne(db, key: row.askId), ask.status.isPending else { continue }
                try settle(db, ask: &ask, status: .superseded, decidedBy: "system", tellRequesterToo: false, now: now)
                _ = try row.delete(db)
            }
            let pr = landing.prNumber.map { "PR #\($0)" } ?? "pull request"
            let released = try releaseHandedToPR(db, item: item, sha: sha, failure: nil,
                                                 detail: "\(pr) was merged on GitHub, but Brahma does not record it as landed: \(shown)", now: now)
            try resolveEngineAlerts(db, reasons: try Self.openPRHoldAlertReasons(db, itemId: itemId), now: now)
            let reason = Self.prMergedAlertReason(itemId: itemId, sha: sha)
            let filed = try Ask.filter(Column("companyId") == company.id && Column("kind") == AskKind.engineAlert
                                       && Column("subjectId") == Store.engineAlertKey(reason)).fetchCount(db)
            if filed == 0 {
                let text = "\(company.name): \(item.key)'s \(pr) was merged on GitHub, but Brahma does not record it as landed: \(shown). "
                    + (released ? "The item went back to its holder" : "The item stays with its holder")
                    + "; its verified commit is not recorded on main. Check what reached the default branch on GitHub."
                try EngineAlerts.raise(store: self, db: db, text: text, now: now, reason: reason, companyId: company.id)
            }
            return true
        }
    }

    /// The engine alert of a merged PR Brahma does not record as landed, once per (item, commit).
    static func prMergedAlertReason(itemId: String, sha: String) -> String { "prmerged:\(itemId)@\(sha)" }
}
