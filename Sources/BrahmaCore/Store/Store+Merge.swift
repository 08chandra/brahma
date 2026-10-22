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
}

extension Store {
    static let maxBriefFiles = 50
    static let maxBriefDiffLines = 200
    /// Merge attempts of one item that may fail in a row before it goes back to its holder and the queue moves on.
    static let maxMergeFailures = 3
    static let quarantineTitle = "Uncommitted changes found in the main checkout"
    static let quarantineCategory = "engine-code"

    static func mainHeadAlertReason(_ companyId: String) -> String { "mainhead:\(companyId)" }
    static func mergeFailureAlertReason(_ itemId: String) -> String { "mergefail:\(itemId)" }
    static func mergeHoldAlertReason(_ companyId: String) -> String { "mergehold:\(companyId)" }
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

    /// Start-up: no merge is running. A pending head that `main` never reached (a crash before the move) is forgotten.
    func recoverMerges() throws {
        try writer.write { db in try db.execute(sql: "UPDATE itemMerge SET running = 0") }
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
            Merge them into main with: brahma main accept \(Self.flat(company.name, max: 100)) \(q.ref)
            Only commit \(q.commit) is merged; if \(q.ref) points anywhere else by then, the accept is refused.

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
    /// Everything up to the landing (the guard, the checkout, a quarantine) and the locks, moving `main` and the merge checkout
    /// fail as `MergeInfrastructureError`: the company's fault, never counted against the item.
    func performMerge(item: WorkItem, company: Company, now: Date) throws -> MergeResult? {
        let root = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        let git = gitWorkspace(root: root, companyId: company.id)
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
                try quarantineRoot(company: company, git: git, expectedMain: expected, now: now)
                return nil
            }
            return expected
        }
        guard let expected else { return nil }
        var pending: String?
        let outcome: GitWorkspace.LandOutcome
        do {
            outcome = try git.landVerified(key: item.key, verified: verified, expectedMain: expected, recordPending: { next in
                try MergeInfrastructureError.wrapping { try self.setPendingMainCommit(companyId: company.id, next) }
                pending = next
            })
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
    /// - `.rebased`: `verifying` plus a queued `merge` check on the new head (an item with no check is `pending` at once).
    /// - `.conflict`: the item goes back to its holder with a conflict brief; its verification is cleared.
    /// - `.branchMoved`: the branch is not what was checked and reviewed: the item goes back to its holder, nothing merged.
    func finishMerge(itemId: String, result: MergeResult, now: Date = Store.now()) throws {
        guard let item = try workItem(id: itemId), let company = try company(id: item.companyId) else { throw WorkError.notFound("no such work item") }
        let git = gitWorkspace(root: URL(fileURLWithPath: company.workspacePath, isDirectory: true), companyId: company.id)
        // The attempt did not fail: the failure count starts again.
        try writer.write { db in try db.execute(sql: "UPDATE itemMerge SET failures = 0, lastError = NULL WHERE itemId = ?", arguments: [itemId]) }
        switch result {
        case .merged(let head):
            let landed = try writer.write { db -> Bool in
                guard var current = try WorkItem.fetchOne(db, key: itemId), current.status != .done else { return false }
                current.mergeState = .none
                current.mergedCommit = head
                current.updatedAt = now
                try current.update(db)
                _ = try engineSetStatus(db: db, itemId: itemId, to: .done, text: "merged into main at \(head.prefix(7))", event: .merged, now: now)
                try finalizeMainCommit(db, companyId: company.id, commit: head)
                try resolveEngineAlerts(db, reasons: [Self.mergeFailureAlertReason(itemId), Self.mergeHoldAlertReason(company.id)], now: now)
                return true
            }
            guard landed else { return }
            // Housekeeping: a leftover worktree is swept later, so none of this is fatal.
            let (store, companyId, key) = (self, company.id, item.key)
            try? git.removeWorktree(key: key, keepIf: { try store.lease(companyId: companyId, key: key) != nil })
            try? git.deleteBranch(key: key)
            try? clearBaseCommit(itemId: itemId)
            try MergeSafety(store: self).afterLanding(companyId: company.id, mergedKey: item.key)

        case .rebased(let head):
            let base = try? git.mergeBase(GitWorkspace.mainRef, head)
            try writer.write { db in
                guard var current = try WorkItem.fetchOne(db, key: itemId), current.status == .inReview, current.mergeState == .pending
                else { return }
                // Weakening is measured from where the branch now starts.
                if let base, current.baseCommit != nil { current.baseCommit = base }
                current.updatedAt = now
                if let spec = current.checkSpec {
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
                                        text: "rebased onto main at \(head.prefix(7)); the check runs again before it lands", now: now)
                } else {
                    current.mergeState = .pending
                    current.verifiedCommit = head
                    try current.update(db)
                    try recordItemEvent(db: db, item: current, actor: "system", kind: .edited, text: "rebased onto main at \(head.prefix(7))", now: now)
                }
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
                    text: "\(current.key) could not be merged into main. Rebase item/\(current.key) on main, resolve these files, then resubmit:\n"
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
        let dir = URL(fileURLWithPath: company.workspacePath, isDirectory: true).appending(path: ".brahma/conflicts", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = ownerTimeZone()
        f.dateFormat = "yyyyMMdd-HHmmss"
        let url = dir.appending(path: "\(item.key)-\(f.string(from: now)).md")
        try (out.joined(separator: "\n") + "\n").write(to: url, atomically: true, encoding: .utf8)
        return url
    }
}
