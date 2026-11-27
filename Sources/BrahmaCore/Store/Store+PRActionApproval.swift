import Foundation
import GRDB

/// The owner card for a GitHub action the gate asked about, and its one-shot approval (Plan X8 Ruling 26). The engine files it
/// (`filePRActionCard`); the owner decides it through the ordinary `ownerDecide` (an `AskKind.prAction` card is reserved:
/// no preset decides it); `applyPRActionEffects` turns the owner's approval into the one-shot approval; the landing machine reads
/// `prActionCardState` and consumes the approval once the action reached GitHub. No agent tool reaches any of it.
extension Store {
    /// Where the card for (item, action, sha) stands. A card that can no longer decide anything — rescinded, superseded,
    /// approved by anyone but the owner, approved but narrowed by a restore, or already used — is forgotten (`.none`), so the
    /// next ask files a fresh one.
    public func prActionCardState(companyId: String, itemId: String, action: GitHubActionType, sha: String) throws -> PRActionCardState {
        try writer.write { db in
            guard let row = try Self.prActionRow(db, companyId: companyId, itemId: itemId, action: action, sha: sha) else { return .none }
            let ask = try Ask.fetchOne(db, key: row.askId)
            switch ask?.status {
            case .pendingOwner?, .pendingInternal?: return .waiting(reason: row.reason)
            case .rejected?: return .declined(reason: row.reason)
            case .approved? where row.isUsable: return .approved(askId: row.askId, digest: row.digest)
            default:
                _ = try row.delete(db)
                return .none
            }
        }
    }

    /// Files the owner's `prAction` card for (item, action, sha), once: while a card for the tuple stands, it is returned
    /// unchanged. `digest` (`PRActionDigest.of` the request the card shows) is what its approval will answer. Engine-filed (`requesterId` "system"), straight to the owner. Its request id is
    /// `pr-<action>-<itemId>-<sha>` (a later card for the same tuple, after the first was rescinded or narrowed away, adds `-<n>`).
    @discardableResult
    public func filePRActionCard(companyId: String, itemId: String, action: GitHubActionType, sha: String, reason: String, digest: String,
                                 card: PRActionCard, now: Date = Store.now()) throws -> Ask {
        try writer.write { db in
            if let row = try Self.prActionRow(db, companyId: companyId, itemId: itemId, action: action, sha: sha),
               let ask = try Ask.fetchOne(db, key: row.askId) {
                return ask
            }
            let base = "pr-\(action.name)-\(itemId)-\(sha)"
            let earlier = try Ask.filter(Column("companyId") == companyId && Column("requesterId") == "system" && Column("kind") == AskKind.prAction
                                         && Column("itemId") == itemId).order(Column("number")).fetchAll(db)
                .filter { $0.requestId?.hasPrefix(base) == true }
            // A card for the tuple still pending without its record (a restore dropped it: an unreadable live database, or a
            // record only the snapshot had): nothing says which request it showed, so it can answer none. It is superseded —
            // the owner can no longer approve it — and a fresh card shows the request asked about now (fix round 2, N1).
            for var stale in earlier where stale.status.isPending {
                try settle(db, ask: &stale, status: .superseded, decidedBy: "system", tellRequesterToo: false, now: now)
            }
            let requestId = earlier.isEmpty ? base : "\(base)-\(earlier.count + 1)"
            let ask = try propose(db: db, companyId: companyId, by: .system, kind: .prAction, risk: nil, category: nil, title: card.title,
                                  summary: card.summary, payload: card.payload, document: nil, itemId: itemId,
                                  subjectId: "pr:\(action.name)@\(sha)", supersedes: nil, requestId: requestId, decisionClass: .taste,
                                  viaOwner: true, now: now)
            guard ask.status.isPending else {
                throw WorkError.conflict("\(ask.ref) already stands for this \(action.name) and is \(ask.status.rawValue)")
            }
            try PRActionApproval(askId: ask.id, companyId: companyId, itemId: itemId, action: action.name, sha: sha,
                                 reason: Store.flat(reason, max: 500), createdAt: now, digest: digest).insert(db)
            return ask
        }
    }

    /// The approved action reached GitHub: its approval is used up (never used a second time).
    public func consumePRActionApproval(askId: String, now: Date = Store.now()) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE prActionApproval SET consumedAt = ? WHERE askId = ? AND approvedAt IS NOT NULL AND consumedAt IS NULL",
                           arguments: [now, askId])
        }
    }

    /// The card no longer matches what would run (Rulings X8-21, 29: the request changed since the owner saw it): a pending one
    /// is superseded, an approved one stays in the history but answers nothing; either way it is forgotten, so the next ask files
    /// a fresh card.
    public func voidPRActionCard(askId: String, now: Date = Store.now()) throws {
        try writer.write { db in
            if var ask = try Ask.fetchOne(db, key: askId), ask.status.isPending {
                try settle(db, ask: &ask, status: .superseded, decidedBy: "system", tellRequesterToo: false, now: now)
            }
            _ = try PRActionApproval.deleteOne(db, key: askId)
        }
    }

    /// The item's cards for any other commit (`keepingSHA`; nil: every one) can no longer be acted on: a pending one is
    /// superseded (the owner no longer sees it as open) and every one is forgotten, approved or not.
    func voidPRActionCards(_ db: Database, itemId: String, keepingSHA: String?, now: Date) throws {
        let rows = try PRActionApproval.filter(Column("itemId") == itemId).fetchAll(db).filter { $0.sha != keepingSHA }
        for row in rows {
            if var ask = try Ask.fetchOne(db, key: row.askId), ask.status.isPending {
                try settle(db, ask: &ask, status: .superseded, decidedBy: "system", tellRequesterToo: false, now: now)
            }
            _ = try row.delete(db)
        }
    }

    /// `applyAskEffects` for a `prAction` card: only the owner's own approval becomes the one-shot approval.
    func applyPRActionEffects(_ db: Database, ask: Ask, now: Date) throws {
        guard ask.status == .approved, ask.decidedBy == "owner" else { return }
        try db.execute(sql: "UPDATE prActionApproval SET approvedAt = ? WHERE askId = ? AND approvedAt IS NULL AND consumedAt IS NULL",
                       arguments: [now, ask.id])
    }

    /// `reverseAskEffects` for a rescinded `prAction` card: an approval not yet used is withdrawn.
    func reversePRActionEffects(_ db: Database, ask: Ask) throws {
        try db.execute(sql: "UPDATE prActionApproval SET approvedAt = NULL WHERE askId = ? AND consumedAt IS NULL", arguments: [ask.id])
    }

    static func prActionRow(_ db: Database, companyId: String, itemId: String, action: GitHubActionType, sha: String) throws -> PRActionApproval? {
        try PRActionApproval.filter(Column("companyId") == companyId && Column("itemId") == itemId && Column("action") == action.name
                                    && Column("sha") == sha).fetchOne(db)
    }
}
