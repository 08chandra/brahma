import Foundation
import GRDB

/// Told, inside the transaction that completes a work item, that it is done (`Store.completeItem`). Plan 5-lite revokes grants
/// and Plan 7 reassigns threads through this.
public protocol WorkItemObserver: Sendable {
    func itemCompleted(_ item: WorkItem, db: Database) throws
}

/// What the engine's git work for one approved item came to.
public enum MergeResult: Equatable, Sendable {
    /// The branch is now part of `main`, whose head is this.
    case merged(mainHead: String)
    /// `main` had moved on: the branch was rebased onto it and must pass its check again.
    case rebased(head: String)
    /// The rebase conflicted (and was aborted). `mainCommit` is `main`'s head and `itemCommit` the item's verified commit.
    case conflict(files: [String], mergeBase: String, mainCommit: String, itemCommit: String)
}

extension Store {
    static let unattributedCommitMessage = "Brahma: unattributed changes on main"
    static let maxBriefFiles = 50
    static let maxBriefDiffLines = 200

    static func mainHeadAlertReason(_ companyId: String) -> String { "mainhead:\(companyId)" }

    /// The oldest approved item of the company still waiting to land.
    func nextPendingMerge(companyId: String) throws -> WorkItem? {
        try writer.read { db in
            try WorkItem.fetchOne(db, sql: """
                SELECT * FROM workItem WHERE companyId = ? AND status = 'inReview' AND mergeState = 'pending' AND verifiedCommit IS NOT NULL
                ORDER BY updatedAt, number LIMIT 1
                """, arguments: [companyId])
        }
    }

    // MARK: Git side

    /// The engine's merge step for one approved item (off the actor: it runs git).
    ///
    /// 1. The root checkout must be on `refs/heads/main`; otherwise nothing is merged, one engine alert is raised and nil is returned.
    /// 2. A branch already contained in `main` (the engine stopped between merging and recording it) is `merged`.
    /// 3. Uncommitted changes on `main` are committed visibly first.
    /// 4. The item's worktree is put on exactly the verified commit (`reset --hard`, `clean -fd`).
    /// 5. `main` is the branch's merge base: fast-forward. Otherwise rebase onto `main`; a conflict is aborted and reported.
    func performMerge(item: WorkItem, company: Company, now: Date) throws -> MergeResult? {
        let root = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        let git = gitWorkspace(root: root, companyId: company.id)
        guard let verified = item.verifiedCommit else { throw WorkError.conflict("\(item.key) has no verified commit") }
        // `main` must still be what the engine expects; if it was changed outside Brahma the merge is held (the guard has
        // raised its alert) until the owner accepts it.
        do { try prepareRepo(company: company) } catch let error as WorkError where error.message == Store.mainChangedMessage { return nil }
        let checkedOut = try git.checkedOutRef()
        guard checkedOut == GitWorkspace.mainRef else {
            try raiseMainHeadAlert(company: company, ref: checkedOut)
            return nil
        }
        try writer.write { db in try resolveEngineAlerts(db, reasons: [Self.mainHeadAlertReason(company.id)], now: now) }
        guard let mainBefore = try git.head(of: GitWorkspace.mainRef) else { throw WorkError.conflict("\(company.name) has no main branch") }
        if try git.isAncestor(verified, of: mainBefore) { return .merged(mainHead: mainBefore) }

        if try git.isDirty(in: root), let sha = try git.commitAll(in: root, message: Self.unattributedCommitMessage) {
            try writer.write { db in
                try db.execute(sql: "UPDATE company SET mainCommit = ? WHERE id = ?", arguments: [sha, company.id])
                try ActivityEvent(companyId: company.id, agentId: nil, turnId: nil, kind: .work,
                                  text: "main had uncommitted changes; committed as \(sha.prefix(7))", createdAt: now).insert(db)
            }
        }
        try git.resetWorktree(key: item.key, to: verified)
        guard let mainHead = try git.head(of: GitWorkspace.mainRef), let base = try git.mergeBase(GitWorkspace.mainRef, verified) else {
            throw WorkError.conflict("\(item.key) shares no history with main")
        }
        if base == mainHead { return .merged(mainHead: try git.fastForwardMain(key: item.key)) }
        switch try git.rebaseOntoMain(key: item.key) {
        case .rebased(let head): return .rebased(head: head)
        case .conflict(let files): return .conflict(files: files, mergeBase: base, mainCommit: mainHead, itemCommit: verified)
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
    public func finishMerge(itemId: String, result: MergeResult, now: Date = Store.now()) throws {
        guard let item = try workItem(id: itemId), let company = try company(id: item.companyId) else { throw WorkError.notFound("no such work item") }
        let git = gitWorkspace(root: URL(fileURLWithPath: company.workspacePath, isDirectory: true), companyId: company.id)
        switch result {
        case .merged(let head):
            let landed = try writer.write { db -> Bool in
                guard var current = try WorkItem.fetchOne(db, key: itemId), current.status != .done else { return false }
                current.mergeState = .none
                current.mergedCommit = head
                current.updatedAt = now
                try current.update(db)
                _ = try engineSetStatus(db: db, itemId: itemId, to: .done, text: "merged into main at \(head.prefix(7))", event: .merged, now: now)
                try db.execute(sql: "UPDATE company SET mainCommit = ? WHERE id = ?", arguments: [head, company.id])
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
        }
    }

    /// `<ws>/.brahma/conflicts/<KEY>-<yyyyMMdd-HHmmss>.md`: for each conflicting file, what `main` changed since the merge base and
    /// what the item changed, each at most `maxBriefDiffLines` lines and every line quoted with `    | `.
    private func writeConflictBrief(git: GitWorkspace, company: Company, item: WorkItem, files: [String], mergeBase: String,
                                    mainCommit: String, itemCommit: String, now: Date) throws -> URL {
        func quoted(_ text: String) -> String {
            text.isEmpty ? "    | (no changes)" : text.split(separator: "\n", omittingEmptySubsequences: false).map { "    | \($0)" }.joined(separator: "\n")
        }
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
