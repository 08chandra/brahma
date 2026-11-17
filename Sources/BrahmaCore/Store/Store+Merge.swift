import Foundation
import GRDB

/// Told, inside the transaction that completes a work item, that it is done (`Store.completeItem`). Plan 5-lite revokes grants
/// and Plan 7 reassigns threads through this.
public protocol WorkItemObserver: Sendable {
    func itemCompleted(_ item: WorkItem, db: Database) throws
}

/// What the engine's git work for one approved item came to.
enum MergeResult: Equatable, Sendable {
    /// The verified commit is now part of `main`, whose head is this.
    case merged(mainHead: String)
    /// `main` had moved on: the verified commit was rebased onto it (in the engine's merge checkout) and the result must pass
    /// its check before it lands.
    case rebased(head: String)
    /// The rebase conflicted (and was aborted). `mainCommit` is `main`'s head and `itemCommit` the item's verified commit.
    case conflict(files: [String], mergeBase: String, mainCommit: String, itemCommit: String)
    /// The item's branch is no longer the verified commit (it is `head`): nothing was merged.
    case branchMoved(head: String?)
    /// The merge step's leak scan (`SecretScan.check` of `main...verified`, Task 4-wire) found these: nothing was merged.
    case secretsFound(findings: [String])
}

extension Store {
    /// What the holder is told to do about a leaked commit: the branch is rewritten in the holder's own turn (continuity
    /// between turns permits that) and submitted again in the same turn.
    static let secretRecovery = "Rewrite your branch in this turn so no commit carries it (reset to main and recommit without it, "
        + "or squash; a commit message, author or header carrying it is rewritten too), take the value from your environment instead, "
        + "then submit again in the same turn. If that turn ends without an accepted submit, the rewrite flags the branch and "
        + "only your manager (or the owner) can re-adopt it."
    static let maxBriefFiles = 50
    static let maxBriefDiffLines = 200
    /// Merge attempts of one item that may fail in a row before it goes back to its holder and the queue moves on.
    static let maxMergeFailures = 3
    static let quarantineTitle = "Uncommitted changes found in the main checkout"
    static let quarantineCategory = "engine-code"

    static func mainHeadAlertReason(_ companyId: String) -> String { "mainhead:\(companyId)" }
    static func mergeFailureAlertReason(_ itemId: String) -> String { "mergefail:\(itemId)" }
    static func mergeHoldAlertReason(_ companyId: String) -> String { "mergehold:\(companyId)" }
    static func mergeTamperAlertReason(_ companyId: String) -> String { "mergetamper:\(companyId)" }
    static func quarantineMovedAlertReason(_ companyId: String) -> String { "quarantinemoved:\(companyId)" }
    /// `quarantine:<ref>@<full sha>`: the ask names the exact commit the engine quarantined, which is all an accept merges.
    static func quarantineSubject(_ ref: String, commit: String) -> String { "quarantine:\(ref)@\(commit)" }

    /// The oldest approved item of the company still waiting to land (one whose merge is not already running).
    func nextPendingMerge(companyId: String) throws -> WorkItem? {
        try writer.read { db in
            try WorkItem.fetchOne(db, sql: """
                SELECT * FROM workItem w WHERE companyId = ? AND status = 'inReview' AND mergeState = 'pending' AND verifiedCommit IS NOT NULL
                AND NOT EXISTS (SELECT 1 FROM itemMerge m WHERE m.itemId = w.id AND m.running)
                ORDER BY updatedAt, number LIMIT 1
                """, arguments: [companyId])
        }
    }

    // MARK: Lockout while merging

    /// The merge of this item has started: its holder gets no work turn and the MCP tools refuse the item until `endMerging`.
    func beginMerging(itemId: String) throws {
        try writer.write { db in
            try db.execute(sql: """
                INSERT INTO itemMerge (itemId, running) VALUES (?, 1) ON CONFLICT(itemId) DO UPDATE SET running = 1
                """, arguments: [itemId])
        }
    }

    func endMerging(itemId: String) throws {
        try writer.write { db in try db.execute(sql: "UPDATE itemMerge SET running = 0 WHERE itemId = ?", arguments: [itemId]) }
    }

    func isMerging(itemId: String) throws -> Bool {
        try writer.read { db in try Bool.fetchOne(db, sql: "SELECT running FROM itemMerge WHERE itemId = ?", arguments: [itemId]) ?? false }
    }

    /// Agents holding the lease of an item whose merge is running.
    func agentsLockedOutByMerges() throws -> Set<String> {
        try writer.read { db in
            Set(try String.fetchAll(db, sql: """
                SELECT l.agentId FROM workLease l JOIN itemMerge m ON m.itemId = l.itemId WHERE m.running
                """))
        }
    }

    /// Start-up: no merge is running. A pending head that `main` never reached (a crash before the move) is forgotten. Each
    /// company's activity records the git the engine found (merges need 2.43 or newer).
    func recoverMerges() throws {
        let gitLine: (ActivityKind, String) = GitWorkspace.installedGitMerges
            ? (.work, "git \(GitWorkspace.installedGitVersion ?? "?") found; merges into main need git 2.43 or newer")
            : (.error, "git \(GitWorkspace.installedGitVersion ?? "was not found"): merges into main need git 2.43 or newer and are refused")
        try writer.write { db in
            try db.execute(sql: "UPDATE itemMerge SET running = 0")
            for company in try Company.fetchAll(db) {
                try ActivityEvent(companyId: company.id, agentId: nil, turnId: nil, kind: gitLine.0, text: gitLine.1, createdAt: Store.now()).insert(db)
            }
        }
        for company in try companies() where company.pendingMainCommit != nil {
            let ws = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
            guard FileManager.default.fileExists(atPath: ws.appending(path: ".git").path) else { continue }
            let head = try? gitWorkspace(root: ws, companyId: company.id).head(of: GitWorkspace.mainRef)
            if let head, head == company.mainCommit { try clearPendingMainCommit(companyId: company.id, ifEqual: nil) }
        }
    }

    // MARK: The expected next head of main (crash recovery)

    func setPendingMainCommit(companyId: String, _ commit: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE company SET pendingMainCommit = ? WHERE id = ?", arguments: [commit, companyId])
        }
    }

    /// Clears the pending head (only when it is still `ifEqual`, if given).
    func clearPendingMainCommit(companyId: String, ifEqual: String?) throws {
        try writer.write { db in
            if let ifEqual {
                try db.execute(sql: "UPDATE company SET pendingMainCommit = NULL WHERE id = ? AND pendingMainCommit = ?", arguments: [companyId, ifEqual])
            } else {
                try db.execute(sql: "UPDATE company SET pendingMainCommit = NULL WHERE id = ?", arguments: [companyId])
            }
        }
    }

    /// The engine (or the owner's accept) moved `main` to `commit`: it is the recorded head now.
    func finalizeMainCommit(_ db: Database, companyId: String, commit: String) throws {
        try db.execute(sql: "UPDATE company SET mainCommit = ?, pendingMainCommit = NULL WHERE id = ?", arguments: [commit, companyId])
    }

    // MARK: Failures

    /// One merge attempt of the item failed (git failed, not a hold). After `maxMergeFailures` in a row the item goes back to
    /// its holder with a `mergeFailed` event, the owner gets an engine alert, and the company's queue moves on. True then.
    @discardableResult
    func noteMergeFailure(itemId: String, error: String, now: Date = Store.now()) throws -> Bool {
        let reason = Self.flat(error, max: 300)
        return try writer.write { db -> Bool in
            try db.execute(sql: """
                INSERT INTO itemMerge (itemId, failures, lastError) VALUES (?, 1, ?)
                ON CONFLICT(itemId) DO UPDATE SET failures = failures + 1, lastError = excluded.lastError
                """, arguments: [itemId, reason])
            let failures = try Int.fetchOne(db, sql: "SELECT failures FROM itemMerge WHERE itemId = ?", arguments: [itemId]) ?? 0
            guard failures >= Self.maxMergeFailures, var item = try WorkItem.fetchOne(db, key: itemId), item.status == .inReview,
                  item.mergeState == .pending, let company = try Company.fetchOne(db, key: item.companyId) else { return false }
            try db.execute(sql: "UPDATE itemMerge SET failures = 0 WHERE itemId = ?", arguments: [itemId])
            item.mergeState = .none
            item.reviewAttempts = 0
            item.verifiedRevision = nil
            item.verifiedCommit = nil
            item.updatedAt = now
            try item.update(db)
            let returned = try engineSetStatus(db: db, itemId: itemId, to: .inProgress, now: now)
            try Store.refreshLease(db, itemId: itemId, companyId: item.companyId)
            let holder = try Self.leaseHolderId(db: db, itemId: itemId) ?? item.ownerId
            try recordItemEvent(db: db, item: returned, actor: "system", kind: .mergeFailed,
                                text: "could not be merged into main after \(Self.maxMergeFailures) attempts (\(reason)); it is back with its holder",
                                alsoNotify: [holder].compactMap { $0 }, alsoNotifyRole: .holder, now: now)
            if let holder, let agent = try Agent.fetchOne(db, key: holder), agent.state != .killed {
                try MessageRouter(store: self).sendDM(
                    db: db, companyId: item.companyId, from: .system, to: agent.name,
                    text: "\(item.key) could not be merged into main after \(Self.maxMergeFailures) attempts; the owner was alerted. "
                        + "Check item/\(item.key) (rebase it on main if it is behind), run your check and resubmit.", now: now)
            }
            try EngineAlerts.raise(
                store: self, db: db,
                text: "\(company.name): \(item.key) could not be merged into main after \(Self.maxMergeFailures) attempts (\(reason)). "
                    + "It went back to its holder and the merge queue moved on.",
                now: now, reason: Self.mergeFailureAlertReason(itemId))
            return true
        }
    }

    // MARK: Quarantine

    static let openAskStatuses = [AskStatus.pendingOwner.rawValue, AskStatus.pendingInternal.rawValue]

    /// The quarantine asks the engine itself filed for this company (requester `system`), newest first.
    func engineQuarantineAsks(_ db: Database, companyId: String, ref: String? = nil) throws -> [Ask] {
        let subject = ref.map { "quarantine:\($0)@%" } ?? "quarantine:%"
        return try Ask.filter(Column("companyId") == companyId && Column("kind") == AskKind.other && Column("category") == Self.quarantineCategory
                              && Column("requesterId") == "system" && Column("subjectId").like(subject))
            .order(Column("number").desc).fetchAll(db)
    }

    /// A quarantine of this company's root checkout is waiting for the owner: the merge step holds. Only asks the engine
    /// filed count; an agent's ask in the same category holds nothing.
    func quarantineHeld(companyId: String) throws -> Bool {
        try writer.read { db in
            try engineQuarantineAsks(db, companyId: companyId).contains { Self.openAskStatuses.contains($0.status.rawValue) }
        }
    }

    /// Never commits a dirty root checkout: its changes go to a quarantine ref, the checkout is restored to `main`, and the
    /// owner gets one ask (reserved category `engine-code`) naming the ref, pinning the quarantine commit's full SHA (subject
    /// and payload) and quoting what changed.
    func quarantineRoot(company: Company, git: GitWorkspace, expectedMain: String, now: Date) throws {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(identifier: "UTC")
        f.dateFormat = "yyyyMMdd-HHmmss"
        guard let q = try git.quarantineRoot(expectedMain: expectedMain, stamp: f.string(from: now)) else { return }
        // `<status>\t<path>`, each part one cleaned line (paths are whatever was in the checkout).
        var files = q.nameStatus.prefix(200).map { line -> String in
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            let status = parts.count == 2 ? ReviewDigest.flat(parts[0], max: 8) : "?"
            return ReviewDigest.quotePrefix + status + "\t" + ReviewDigest.flat(parts.last ?? line, max: 300)
        }
        if q.nameStatus.count > 200 { files.append(ReviewDigest.quotePrefix + "… and \(q.nameStatus.count - 200) more") }
        let summary = """
            Brahma found uncommitted changes in the main checkout of \(Self.flat(company.name, max: 100)). They were not committed to main: \
            they are saved as \(q.ref) (\(q.commit.prefix(7))) and the checkout was restored to main (\(expectedMain.prefix(7))). \
            Merges into main wait until you decide.

            Review exactly what would be merged with: git --no-replace-objects diff \(expectedMain) \(q.commit)
            Merge them into main by approving this ask, or with: brahma main accept \(Self.flat(company.name, max: 100)) \(q.ref)
            Only commit \(q.commit) is merged; if \(q.ref) points anywhere else by then, the accept is refused.
            Rejecting this ask leaves main as it is; the changes stay on \(q.ref).

            Changed files:
            \(files.joined(separator: "\n"))

            Summary:
            \(ReviewDigest.quote(q.stat, maxChars: 4000))
            """
        try writer.write { db in
            _ = try propose(db: db, companyId: company.id, by: .system, kind: .other, risk: .high, category: Self.quarantineCategory,
                            title: Self.quarantineTitle, summary: summary,
                            payload: AskPayload(proposal: "Merge \(q.commit) (\(q.ref)) into main at \(expectedMain)"), document: nil,
                            itemId: nil, subjectId: Self.quarantineSubject(q.ref, commit: q.commit), supersedes: nil, requestId: nil,
                            decisionClass: .goalChanging,
                            viaOwner: true, now: now)
            try ActivityEvent(companyId: company.id, agentId: nil, turnId: nil, kind: .error,
                              text: "the main checkout had uncommitted changes; they were moved to \(q.ref) and merges wait for the owner",
                              createdAt: now).insert(db)
        }
    }

    // MARK: Git side

    /// The engine's merge step for one approved item (off the actor: it runs git).
    ///
    /// 1. `main` must be exactly the recorded head (`checkMain`) and the root checkout on `refs/heads/main`; otherwise nothing
    ///    is merged (one engine alert) and nil is returned.
    /// 2. A quarantine waiting for the owner holds the merge step (nil). A dirty root checkout is quarantined, never
    ///    committed, and the merge step holds (nil).
    /// 3. `GitWorkspace.landVerified` lands exactly the verified commit: refused when the branch moved, a fast-forward
    ///    (`pendingMainCommit` written before `main` moves, the record finalized after), or a rebase of the verified commit in
    ///    the engine's merge checkout.
    ///
    /// Everything up to the landing (the guard, the checkout, a quarantine) and the locks, moving `main`, the merge repository
    /// and `main`'s history fail as `MergeInfrastructureError`: the company's fault, never counted against the item. Stale
    /// lock files left in the workspace repository are removed and reported to the owner (`reportMergeTamper`).
    ///
    /// The owner's stop (Task 7c fix round 1, S15) is read before anything is done, before a quarantine, and again right
    /// before each ref the landing moves (`landVerified`'s `beforeRefMove`): once it is raised the merge throws
    /// `StoppedByOwner` with nothing moved (a pending `main` record is cleared). `childGroups` records each git it runs.
    func performMerge(item: WorkItem, company: Company, now: Date, childGroups: ChildGroups? = nil) throws -> MergeResult? {
        let root = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        var git = gitWorkspace(root: root, companyId: company.id)
        git.childGroups = childGroups
        let stopGate: (String) throws -> Void = { [self] ref in
            mergeRefProbe.call(ref)
            if try engineStopped() != nil { throw StoppedByOwner() }
        }
        try stopGate("")
        guard let verified = item.verifiedCommit else { throw WorkError.conflict("\(item.key) has no verified commit") }
        let expected: String? = try MergeInfrastructureError.wrapping {
            // `main` must still be what the engine expects; if it was changed outside Brahma the merge is held (the guard
            // has raised its alert) until the owner accepts it.
            do { try checkMain(company: company, git: git) } catch let error as WorkError where error.message == Store.mainChangedMessage { return nil }
            let checkedOut = try git.checkedOutRef()
            guard checkedOut == GitWorkspace.mainRef else {
                try raiseMainHeadAlert(company: company, ref: checkedOut)
                return nil
            }
            try writer.write { db in try resolveEngineAlerts(db, reasons: [Self.mainHeadAlertReason(company.id)], now: now) }
            if try quarantineHeld(companyId: company.id) { return nil }
            guard let expected = try self.company(id: company.id)?.mainCommit else { return nil }
            if try git.isDirty(in: root) {
                try stopGate("refs/quarantine")
                try quarantineRoot(company: company, git: git, expectedMain: expected, now: now)
                return nil
            }
            return expected
        }
        guard let expected else { return nil }
        // Scan (b), Task 4-wire: what the verified commit adds against `main` is scanned again right before it lands (a value
        // may have become a known secret since the submit). A finding bounces the item to its holder (`finishMerge`).
        let scanBase = try git.mergeBase(expected, verified) ?? item.baseCommit ?? git.emptyTree()   // the recorded main, never the live ref
        let findings = try SecretScan.check(git: git, base: scanBase, head: verified, knownValues: knownSecretValues(companyId: company.id))
        if !findings.isEmpty { return .secretsFound(findings: findings) }
        var pending: String?
        let outcome: GitWorkspace.LandOutcome
        do {
            outcome = try git.landVerified(key: item.key, verified: verified, expectedMain: expected, recordPending: { next in
                try MergeInfrastructureError.wrapping { try self.setPendingMainCommit(companyId: company.id, next) }
                pending = next
            }, tamper: { removed in self.reportMergeTamper(company: company, removed: removed, now: now) }, beforeRefMove: stopGate)
        } catch {
            if let pending { try? clearPendingMainCommit(companyId: company.id, ifEqual: pending) }
            throw error
        }
        switch outcome {
        case .fastForwarded(let head):
            try MergeInfrastructureError.wrapping { try writer.write { db in try finalizeMainCommit(db, companyId: company.id, commit: head) } }
            return .merged(mainHead: head)
        case .alreadyLanded(let head): return .merged(mainHead: head)
        case .rebased(let head): return .rebased(head: head)
        case .conflict(let files, let base, let mainHead):
            return .conflict(files: files, mergeBase: base, mainCommit: mainHead, itemCommit: verified)
        case .branchMoved(let head): return .branchMoved(head: head)
        case .mainMoved: return nil    // the guard sees it on the next attempt
        }
    }

    /// Agent-writable state that held the merge queue was repaired (A3: stale git lock files, a planted `shallow` or
    /// `info/grafts`, objects of `main`'s history restored): the owner hears about it (one open alert at a time), since Brahma
    /// did not leave it there.
    func reportMergeTamper(company: Company, removed: [String], now: Date) {
        let names = removed.map { Self.flat($0, max: 120) }.joined(separator: ", ")
        try? EngineAlerts.raise(
            store: self, text: "\(company.name): Brahma repaired the workspace repository so merges into main could go on (\(names)). "
                + "These held merges into main and Brahma did not leave them; something with access to the workspace did.",
            now: now, reason: Self.mergeTamperAlertReason(company.id))
    }

    /// A merge check's export worked (A1): the company's merge hold alert, if one is open, is resolved.
    func resolveMergeHoldAlert(companyId: String, now: Date) throws {
        try writer.write { db in try resolveEngineAlerts(db, reasons: [Self.mergeHoldAlertReason(companyId)], now: now) }
    }

    /// One alert per company however often the merge is retried; it resolves itself when the checkout is back on `main`.
    private func raiseMainHeadAlert(company: Company, ref: String?) throws {
        let reason = Self.mainHeadAlertReason(company.id)
        let open = try writer.read { db in
            try Ask.filter(Column("kind") == AskKind.engineAlert && Column("status") == AskStatus.pendingOwner.rawValue
                           && Column("subjectId") == Store.engineAlertKey(reason)).fetchCount(db)
        }
        guard open == 0 else { return }
        try EngineAlerts.raise(
            store: self, text: "\(company.name): main checkout is on \(ref ?? "a detached HEAD"); switch it back to main. "
                + "Brahma merges nothing there until you do.", now: Store.now(), reason: reason)
    }

    // MARK: Recording

    /// Applies the merge step's result. Runs git (the conflict brief, removing the landed branch, the dry runs of everybody
    /// else's branch), so it is called off the actor, by the same detached task as `performMerge`.
    ///
    /// - `.merged`: `done`, `doneAt`, `mergedCommit`, lease deleted, event `merged`, the completion hook; then the worktree and
    ///   branch go and `MergeSafety.afterLanding` looks at everybody else's branch.
    /// - `.rebased`: `verifying` plus a queued `merge` check on the new head (an item with no check is `pending` at once). An
    ///   item whose auto-approval was revoked while the merge ran (`revokeAutoApprovals`) gets the same re-check, then goes to
    ///   review (`finishVerification`); without a check its review is of the rebased head.
    /// - `.conflict`: the item goes back to its holder with a conflict brief; its verification is cleared.
    /// - `.branchMoved`: the branch is not what was checked and reviewed: the item goes back to its holder, nothing merged.
    /// - `.secretsFound`: the merge-step leak scan found something: the item goes back to its holder with the findings
    ///   (never a value), its verification cleared, nothing merged.
    ///
    /// `triggerAfterLanding: false` (the merge queue's `recordLanded`, which records `main`'s head itself and runs
    /// `MergeSafety.afterLanding` once for a whole batch) leaves both out of `.merged`.
    func finishMerge(itemId: String, result: MergeResult, triggerAfterLanding: Bool = true, now: Date = Store.now()) throws {
        guard let item = try workItem(id: itemId), let company = try company(id: item.companyId) else { throw WorkError.notFound("no such work item") }
        let git = gitWorkspace(root: URL(fileURLWithPath: company.workspacePath, isDirectory: true), companyId: company.id)
        // The attempt did not fail: the failure count starts again.
        try writer.write { db in try db.execute(sql: "UPDATE itemMerge SET failures = 0, lastError = NULL WHERE itemId = ?", arguments: [itemId]) }
        switch result {
        case .merged(let head):
            let landed = try writer.write { db -> Bool in
                guard var current = try WorkItem.fetchOne(db, key: itemId), current.status != .done else { return false }
                // The merge lockout lives in the tool layer: an owner edit or an engine step can still have changed the item while
                // its merge ran. The commit is in main either way; say so, and tell the holder.
                let diverged = current.status != .inReview || current.mergeState != .pending
                let wasStatus = current.status
                current.mergeState = .none
                current.mergedCommit = head
                // The branch goes with the landing: a reopened item starts a new record at its next claim (R2).
                current.leaseHeadCommit = nil
                current.updatedAt = now
                try current.update(db)
                // Risk-tiered review: an auto-approved item that lands is an auto-merge, and every one is queued for an audit.
                try queueAudit(db: db, item: current, mergedCommit: head)
                _ = try engineSetStatus(db: db, itemId: itemId, to: .done, text: "merged into main at \(head.prefix(7))", event: .merged, now: now)
                if diverged {
                    let holder = try Self.leaseHolderId(db: db, itemId: itemId)
                    try recordItemEvent(db: db, item: current, actor: "system", kind: .edited,
                                        text: "landed in main at \(head.prefix(7)) although the item had been changed while its merge ran "
                                            + "(it was \(wasStatus.title.lowercased())); check that main holds what you intend",
                                        alsoNotify: [holder].compactMap { $0 }, alsoNotifyRole: .holder, now: now)
                }
                // A merge request this landing completes (3a's step landing an item the queue has not claimed) is closed with it.
                try db.execute(sql: """
                    UPDATE mergeRequest SET status = 'merged', mergedCommit = ?, finishedAt = ?
                    WHERE itemId = ? AND status IN ('queued', 'running', 'landing')
                    """, arguments: [head, now, itemId])
                if triggerAfterLanding { try finalizeMainCommit(db, companyId: company.id, commit: head) }
                try resolveEngineAlerts(db, reasons: [Self.mergeFailureAlertReason(itemId), Self.mergeHoldAlertReason(company.id)], now: now)
                return true
            }
            guard landed else { return }
            // Housekeeping: a leftover worktree is swept later, so none of this is fatal.
            let (store, companyId, key) = (self, company.id, item.key)
            try? store.removeItemWorktree(git: git, companyId: companyId, key: key)
            try? git.deleteBranch(key: key)
            try? clearBaseCommit(itemId: itemId)
            if triggerAfterLanding { try MergeSafety(store: self).afterLanding(companyId: company.id, mergedKey: item.key) }

        case .rebased(let head):
            let base = try? git.mergeBase(GitWorkspace.mainRef, head)
            try writer.write { db in
                // The engine moved the branch: the rebased head is the recorded head the next submit (and the next holder
                // turn's continuity check) is measured against, recorded in the same write as the merge-state change.
                try Self.recordLeaseHead(db: db, itemId: itemId, commit: head)
                guard var current = try WorkItem.fetchOne(db, key: itemId), current.status == .inReview else { return }
                // Auto-merge was switched off while this merge ran (`revokeAutoApprovals`): the branch already carries the
                // rebased commit, so the rebase is applied all the same and the item goes to its reviewer from there.
                let revoked = current.mergeState == .none && current.reviewedRound < current.reviewRound && current.verifiedCommit != nil
                guard current.mergeState == .pending || revoked else { return }
                // The branch now carries a rebased head: a request pinned to the old one is withdrawn (3a's check re-runs on this head).
                try Self.cancelQueuedMerges(db: db, itemId: itemId, now: now)
                // Weakening is measured from where the branch now starts.
                if let base, current.baseCommit != nil { current.baseCommit = base }
                current.updatedAt = now
                if revoked, current.checkSpec == nil {
                    current.verifiedCommit = head
                    try current.update(db)
                    try recordItemEvent(db: db, item: current, actor: "system", kind: .edited,
                                        text: "rebased onto main at \(head.prefix(7)) as auto-merge was switched off; it needs a review", now: now)
                    try Store.wakeReviewer(db: db, item: current, now: now)
                } else if let spec = current.checkSpec {
                    // A revoked item's passing re-check goes to review (`finishVerification`), not back to `pending`.
                    current.mergeState = .verifying
                    let holder = try Self.leaseHolderId(db: db, itemId: itemId)
                    let scriptHash = try String.fetchOne(db, sql: """
                        SELECT scriptHash FROM verificationRun WHERE itemId = ? ORDER BY rowid DESC LIMIT 1
                        """, arguments: [itemId]) ?? ""
                    try db.execute(sql: """
                        UPDATE verificationRun SET status = 'error', outputTail = 'superseded by a newer submission', finishedAt = ?
                        WHERE itemId = ? AND status = 'queued'
                        """, arguments: [now, itemId])
                    try VerificationRun(
                        id: UUID().uuidString, companyId: current.companyId, itemId: itemId, checkRevision: current.checkRevision,
                        scriptHash: scriptHash, commit: head, command: spec.command, workingDirectory: git.worktreePath(key: current.key).path,
                        timeoutSeconds: spec.timeoutSeconds, purpose: .merge, attempt: 1, status: .queued, requestedBy: holder,
                        createdAt: now).insert(db)
                    try current.update(db)
                    try recordItemEvent(db: db, item: current, actor: "system", kind: .edited,
                                        text: revoked ? "rebased onto main at \(head.prefix(7)) as auto-merge was switched off; the check runs again, then it needs a review"
                                            : "rebased onto main at \(head.prefix(7)); the check runs again before it lands", now: now)
                } else {
                    current.mergeState = .pending
                    current.verifiedCommit = head
                    try current.update(db)
                    try recordItemEvent(db: db, item: current, actor: "system", kind: .edited, text: "rebased onto main at \(head.prefix(7))", now: now)
                }
            }

        case .secretsFound(let findings):
            let shown = Self.sanitizedFlags(findings).joined(separator: "; ")
            try writer.write { db in
                guard var current = try WorkItem.fetchOne(db, key: itemId), current.status == .inReview, current.mergeState == .pending
                else { return }
                current.mergeState = .none
                current.reviewAttempts = 0
                current.autoApproved = false
                // The next merge must be of work that passed its check (and its scans) again.
                current.verifiedRevision = nil
                current.verifiedCommit = nil
                current.updatedAt = now
                try current.update(db)
                let returned = try engineSetStatus(db: db, itemId: itemId, to: .inProgress, now: now)
                try Store.refreshLease(db, itemId: itemId, companyId: current.companyId)
                let holder = try Self.leaseHolderId(db: db, itemId: itemId) ?? current.ownerId
                try recordItemEvent(db: db, item: returned, actor: "system", kind: .verificationFailed,
                                    text: "not merged: the change contains what looks like a secret (\(shown)). \(Store.secretRecovery)",
                                    alsoNotify: [holder].compactMap { $0 }, alsoNotifyRole: .holder, now: now)
                guard let holder, let agent = try Agent.fetchOne(db, key: holder), agent.state != .killed else { return }
                try MessageRouter(store: self).sendDM(
                    db: db, companyId: current.companyId, from: .system, to: agent.name,
                    text: "\(current.key) was not merged: the change contains what looks like a secret (\(shown)). \(Store.secretRecovery)", now: now)
            }

        case .conflict(let files, let mergeBase, let mainCommit, let itemCommit):
            let brief = try writeConflictBrief(git: git, company: company, item: item, files: files, mergeBase: mergeBase,
                                               mainCommit: mainCommit, itemCommit: itemCommit, now: now)
            let shown = Self.sanitizedFlags(files)
            try writer.write { db in
                guard var current = try WorkItem.fetchOne(db, key: itemId), current.status == .inReview, current.mergeState == .pending
                else { return }
                current.mergeState = .none
                current.reviewAttempts = 0
                // The next merge must be of work that passed its check again.
                current.verifiedRevision = nil
                current.verifiedCommit = nil
                current.reviewFlags.removeAll { $0.hasPrefix(MergeSafety.conflictFlagPrefix) }
                current.updatedAt = now
                try current.update(db)
                let returned = try engineSetStatus(db: db, itemId: itemId, to: .inProgress, now: now)
                try Store.refreshLease(db, itemId: itemId, companyId: current.companyId)
                let holder = try Self.leaseHolderId(db: db, itemId: itemId) ?? current.ownerId
                try recordItemEvent(db: db, item: returned, actor: "system", kind: .mergeConflict,
                                    text: "could not be merged into main (conflicts: \(shown.joined(separator: ", "))); conflict brief: \(brief.path)",
                                    alsoNotify: [holder].compactMap { $0 }, alsoNotifyRole: .holder, now: now)
                guard let holder, let agent = try Agent.fetchOne(db, key: holder), agent.state != .killed else { return }
                let block = shown.map { "    | \($0)" }.joined(separator: "\n")
                try MessageRouter(store: self).sendDM(
                    db: db, companyId: current.companyId, from: .system, to: agent.name,
                    text: "\(current.key) could not be merged into main. In this turn, rebase item/\(current.key) on main, resolve these files, then resubmit:\n"
                        + block + "\nConflict brief: \(brief.path)", now: now)
            }

        case .branchMoved(let head):
            try writer.write { db in
                guard var current = try WorkItem.fetchOne(db, key: itemId), current.status == .inReview, current.mergeState == .pending
                else { return }
                current.mergeState = .none
                current.reviewAttempts = 0
                // What was checked and approved is not what the branch holds now: both happen again.
                current.verifiedRevision = nil
                current.verifiedCommit = nil
                current.updatedAt = now
                try current.update(db)
                let returned = try engineSetStatus(db: db, itemId: itemId, to: .inProgress, now: now)
                try Store.refreshLease(db, itemId: itemId, companyId: current.companyId)
                let holder = try Self.leaseHolderId(db: db, itemId: itemId) ?? current.ownerId
                let now7 = head.map { " (now \($0.prefix(7)))" } ?? ""
                try recordItemEvent(db: db, item: returned, actor: "system", kind: .verificationFailed,
                                    text: "item/\(current.key) moved after its check passed\(now7); nothing was merged. Resubmit so the check and the review see that work.",
                                    alsoNotify: [holder].compactMap { $0 }, alsoNotifyRole: .holder, now: now)
                guard let holder, let agent = try Agent.fetchOne(db, key: holder), agent.state != .killed else { return }
                try MessageRouter(store: self).sendDM(
                    db: db, companyId: current.companyId, from: .system, to: agent.name,
                    text: "\(current.key) changed after its check passed and was approved, so nothing was merged. "
                        + "Resubmit it; the check and the review run again on what item/\(current.key) holds.", now: now)
            }
        }
    }

    /// `<ws>/.brahma/conflicts/<KEY>-<yyyyMMdd-HHmmss>.md`: for each conflicting file, what `main` changed since the merge base and
    /// what the item changed, each at most `maxBriefDiffLines` lines and every line quoted with `    | `.
    private func writeConflictBrief(git: GitWorkspace, company: Company, item: WorkItem, files: [String], mergeBase: String,
                                    mainCommit: String, itemCommit: String, now: Date) throws -> URL {
        // Every line quoted, control characters (a CRLF's `\r` among them) removed: `ReviewDigest.quote` splits at each `\n`.
        func quoted(_ text: String) -> String { ReviewDigest.quote(text, maxChars: 1 << 20, empty: "(no changes)") }
        var out = ["# Merge conflict: \(item.key)", "",
                   "item/\(item.key) could not be rebased onto main. Rebase it in your worktree, resolve the files below, run your check and resubmit.",
                   "", "Merge base: \(mergeBase)", "main: \(mainCommit)", "item/\(item.key): \(itemCommit)", ""]
        for file in files.prefix(Self.maxBriefFiles) {
            out.append("## \(Self.flat(file, max: 300))")
            for (label, head) in [("main since the merge base", mainCommit), ("item/\(item.key) since the merge base", itemCommit)] {
                out.append(""); out.append("### \(label)")
                do {
                    let diff = try git.fileDiff(base: mergeBase, head: head, path: file, maxLines: Self.maxBriefDiffLines)
                    out.append(quoted(diff.text))
                    if diff.truncated { out.append("[diff truncated]") }
                } catch {
                    out.append("    | (the diff could not be produced)")
                }
            }
            out.append("")
        }
        if files.count > Self.maxBriefFiles { out.append("… and \(files.count - Self.maxBriefFiles) more files") }
        let workspace = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = ownerTimeZone()
        f.dateFormat = "yyyyMMdd-HHmmss"
        // A new file under a real directory, never through a link (one planted on its name is skipped and alerted on).
        do {
            let written = try EngineFiles.createUnique(Data((out.joined(separator: "\n") + "\n").utf8), workspace: workspace,
                                                       dir: ".brahma/conflicts", base: "\(item.key)-\(f.string(from: now))", ext: "md")
            for problem in written.skipped { alertEngineFile(problem, companyId: company.id, now: now) }
            return written.url
        } catch let refused as UnsafeEngineFile {
            alertEngineFile(refused, companyId: company.id, now: now)
            throw refused
        }
    }
}
