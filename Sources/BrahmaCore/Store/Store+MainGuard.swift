import Foundation
import GRDB

/// The engine's record of where `refs/heads/main` stands. `company.mainCommit` advances only from the engine: the repository
/// import at creation, its merges of verified and reviewed items, and content the owner accepted (`acceptMainCommit`: the
/// current head, or a quarantine of the root checkout). A dirty root checkout is never committed (`Store.performMerge`
/// quarantines it). An agent that moves `main` by any other route (a reset, a rewrite, or a fast-forward of unreviewed
/// commits) makes the head differ from the record; claims and merges are then refused and the owner is alerted until the
/// owner accepts it. Nothing resolves that alert by itself.
///
/// Before the engine moves `main` it writes the head it is moving to as `company.pendingMainCommit`, and records it as
/// `mainCommit` after. A crash in between leaves `main` at the pending head, which the guard accepts and records.
extension Store {
    static func mainAlertReason(_ companyId: String) -> String { "main:\(companyId)" }

    /// Engine use only: records the head the engine itself produced.
    func recordMainCommit(companyId: String, commit: String) throws {
        try writer.write { db in
            try db.execute(sql: "UPDATE company SET mainCommit = ? WHERE id = ?", arguments: [commit, companyId])
        }
    }

    /// Makes the workspace a repository and checks `main` against the record (`checkMain`).
    func prepareRepo(company: Company) throws {
        let git = gitWorkspace(root: URL(fileURLWithPath: company.workspacePath, isDirectory: true), companyId: company.id)
        try git.ensureRepo()
        try checkMain(company: company, git: git)
    }

    /// Passes only when `refs/heads/main` is exactly the recorded head, or exactly the pending head the engine was moving it
    /// to (that one is then recorded). A different head (descendant or not), an unreadable one, or no record at all raises
    /// one owner alert and throws `mainChangedMessage`. The alert is never resolved here. Merges call this too and hold while
    /// it throws.
    func checkMain(company: Company, git: GitWorkspace? = nil) throws {
        let git = git ?? gitWorkspace(root: URL(fileURLWithPath: company.workspacePath, isDirectory: true), companyId: company.id)
        var current: String?
        do { current = try git.head(of: GitWorkspace.mainRef) } catch let e as GitError where e.isRepositoryRefusal {
            throw e      // its own alert; main is not known to have moved
        } catch { current = nil }
        // A `main` that is a symbolic ref is not the branch the engine recorded, whatever it points at: fail closed.
        if current != nil, (try? git.mainIsSymbolic()) != false { current = nil }
        let row = try writer.read { try Row.fetchOne($0, sql: "SELECT mainCommit, pendingMainCommit FROM company WHERE id = ?", arguments: [company.id]) }
        let recorded: String? = row?["mainCommit"]
        let pending: String? = row?["pendingMainCommit"]
        if let recorded, let current, recorded == current { return }
        if let pending, let current, pending == current {
            try writer.write { db in
                try db.execute(sql: "UPDATE company SET mainCommit = ?, pendingMainCommit = NULL WHERE id = ? AND pendingMainCommit = ?",
                               arguments: [pending, company.id, pending])
            }
            return
        }
        let reason = Self.mainAlertReason(company.id)
        let open = try writer.read { db in
            try Ask.filter(Column("kind") == AskKind.engineAlert && Column("status") == AskStatus.pendingOwner.rawValue
                           && Column("subjectId") == Store.engineAlertKey(reason)
                           && Column("companyId") == company.id).fetchCount(db)
        }
        if open == 0 {
            try EngineAlerts.raise(store: self, text: "The main branch of \(company.name) changed outside Brahma (it was moved, rewritten or reset). "
                + "Brahma starts no new work and merges nothing there until you have reviewed main and accepted it.", now: Store.now(), reason: reason)
        }
        throw WorkError.conflict(Self.mainChangedMessage)
    }

    // MARK: Adoption (Plan 4a Task 3)

    /// The record takes `main`'s head (`brahma merge adopt-main`, the first-tick adoption of the main guard, the restore hook).
    /// Owner and engine only (`.agent` is refused); never while a merge batch is open (its journal owns `main`). With `commit`
    /// (a commit id or any revision the owner names, a `refs/brahma/foreign/...` tip the guard saved, say) that is not `main`'s
    /// head, `main` is first moved there by compare-and-swap with the root checkout following (refused while the root has
    /// uncommitted edits). Writes activity `main adopted at <sha7> by the owner|the engine`, closes 3a's "main changed
    /// outside Brahma" alert, and returns the recorded commit. Runs git: call it off the actor.
    @discardableResult
    public func adoptMain(companyId: String, by sender: Sender, commit: String? = nil, now: Date = Store.now()) throws -> String {
        if case .agent = sender { throw WorkError.forbidden("only the owner can adopt main") }
        guard let company = try company(id: companyId) else { throw WorkError.notFound("no such company") }
        let git = gitWorkspace(root: URL(fileURLWithPath: company.workspacePath, isDirectory: true), companyId: company.id)
        let name = Self.flat(company.name, max: 100)
        do {
            return try git.withMainLock { () throws -> String in
                guard try openMergeBatches(companyId: companyId).isEmpty else {
                    throw WorkError.conflict("a merge batch of \(name) is open; wait for it to finish (brahma merge \(name)), then adopt main")
                }
                guard let head = try git.head(of: GitWorkspace.mainRef) else { throw WorkError.conflict("\(name) has no main branch") }
                var target = head
                if let commit {
                    guard let wanted = try git.revParse(commit) else { throw WorkError.invalid("\(Self.flat(commit, max: 80)) names no commit in the workspace of \(name)") }
                    if wanted != head {
                        // `setMain` takes main's lock itself: a nested take would wait on this one, so the swap runs here.
                        guard try git.swapMainLocked(to: wanted, expecting: head) else {
                            throw WorkError.conflict("main of \(name) moved while it was being adopted; look at it and try again")
                        }
                        target = wanted
                    }
                }
                let who = sender == .owner ? "the owner" : "the engine"
                try writer.write { db in
                    try finalizeMainCommit(db, companyId: companyId, commit: target)
                    try resolveEngineAlerts(db, reasons: [Self.mainAlertReason(companyId)], now: now)
                    try ActivityEvent(companyId: companyId, agentId: nil, turnId: nil, kind: .merge,
                                      text: "main adopted at \(target.prefix(7)) by \(who)", createdAt: now).insert(db)
                }
                return target
            }
        } catch let error as GitError {
            if case .failed(_, _, let stderr) = error { throw WorkError.conflict("could not adopt main of \(name): \(Self.flat(stderr, max: 300))") }
            throw error
        }
    }

    /// The main guard put `main` back (`MainGuard.check`): the company's feed, one owner notice, and, with the root checkout off
    /// `main`, 3a's one self-resolving alert that it is on another ref. 3a's "main changed outside Brahma" alert, if open, is
    /// closed: `main` is the record again. Nothing here throws (the restore is done; a failed report is logged by the caller's
    /// activity being absent, not by undoing anything).
    func reportMainRestored(company: Company, restore: GitWorkspace.ForeignRestore, recorded: String, now: Date) {
        let name = Self.flat(company.name, max: 100)
        let text = "main was changed outside the merge queue; restored to \(recorded.prefix(7)), the other tip is saved as \(restore.ref)"
        try? writer.write { db in
            try ActivityEvent(companyId: company.id, agentId: nil, turnId: nil, kind: .merge, text: text, createdAt: now).insert(db)
            try resolveEngineAlerts(db, reasons: [Self.mainAlertReason(company.id)], now: now)
            try notifyOwner(db: db, companyId: company.id, kind: .system, urgency: .normal, title: "main restored",
                            body: "\(name): \(text). Run brahma merge adopt-main \(name) if that change was yours.", now: now)
        }
        if !restore.rootReset {
            try? raiseMainHeadAlert(company: company, ref: restore.rootRef.map { Self.flat($0, max: 200) })
        }
    }

    /// Owner-only (`brahma main accept`, the app, and the owner's approval of the engine's quarantine ask: `ownerDecide`).
    /// - Without `ref`: the owner has reviewed `main` and accepts its current head.
    /// - With a quarantine ref (`refs/brahma/quarantine/<stamp>`, or just `<stamp>`): the commit the engine recorded on its
    ///   own quarantine ask for that ref (never what the ref holds now) is merged into `main` as an engine-recorded merge
    ///   (`mainCommit` advances), and a pending ask is settled `approved` (with `note`, when given), which releases the merge
    ///   step. An ask already decided (rejected, expired, or approved by an older engine that merged nothing) is not left
    ///   stranded: its recorded commit is merged all the same, and the result says how the ask stands. A ref with no such
    ///   ask (one an agent made, or an ask an agent filed) is refused. A ref that no longer points at the recorded commit is
    ///   refused and flagged to the owner (an engine alert): what the owner was shown is not what the ref holds. Accepting a
    ///   quarantine that is already merged changes nothing (`alreadyMerged`).
    @discardableResult
    public func acceptMainCommit(companyId: String, ref: String? = nil, note: String? = nil) throws -> MainAcceptance {
        guard let company = try company(id: companyId) else { throw WorkError.notFound("no such company") }
        let git = gitWorkspace(root: URL(fileURLWithPath: company.workspacePath, isDirectory: true), companyId: company.id)
        guard let ref else {
            guard let head = try git.head(of: GitWorkspace.mainRef) else { throw WorkError.conflict("\(company.name) has no main branch") }
            try writer.write { db in
                try finalizeMainCommit(db, companyId: companyId, commit: head)
                try resolveEngineAlerts(db, reasons: [Store.mainAlertReason(companyId)], now: Store.now())
            }
            return MainAcceptance(head: head, ask: nil, alreadyMerged: false)
        }
        let raw = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = raw.hasPrefix(GitWorkspace.quarantinePrefix) ? raw : GitWorkspace.quarantinePrefix + raw
        guard GitWorkspace.isQuarantineRef(full) else {
            throw WorkError.invalid("\(Self.flat(raw, max: 80)) is not a quarantine ref (refs/brahma/quarantine/<yyyyMMdd-HHmmss>)")
        }
        // The engine's own ask for this ref, and the commit it recorded there (subject and payload must agree).
        let asks = try writer.read { db in try engineQuarantineAsks(db, companyId: companyId, ref: full) }
        func recorded(_ ask: Ask) -> String? {
            guard let subject = ask.subjectId, subject.hasPrefix("quarantine:\(full)@") else { return nil }
            let sha = String(subject.dropFirst("quarantine:\(full)@".count))
            guard sha.range(of: "^[0-9a-f]{40}([0-9a-f]{24})?$", options: .regularExpression) != nil,
                  ask.payload?.proposal?.contains(sha) == true else { return nil }
            return sha
        }
        let pinned = asks.filter { recorded($0) != nil }
        guard let ask = pinned.first(where: { Self.openAskStatuses.contains($0.status.rawValue) }) ?? pinned.first,
              let commit = recorded(ask) else {
            throw WorkError.conflict("no quarantine ask from Brahma is waiting for \(full); only a quarantine the engine made and asked you about can be accepted")
        }
        let open = Self.openAskStatuses.contains(ask.status.rawValue)
        if !open, let head = try git.head(of: GitWorkspace.mainRef), try git.isAncestor(commit, of: head) {
            return MainAcceptance(head: head, ask: ask, alreadyMerged: true)    // already accepted and merged
        }
        try checkMain(company: company, git: git)
        guard let expected = try self.company(id: companyId)?.mainCommit else { throw WorkError.conflict(Self.mainChangedMessage) }
        var pending: String?
        let outcome: GitWorkspace.QuarantineOutcome
        do {
            outcome = try git.mergeQuarantine(ref: full, commit: commit, expectedMain: expected, recordPending: { next in
                try self.setPendingMainCommit(companyId: companyId, next)
                pending = next
            })
        } catch let error as GitError {
            if let pending { try? clearPendingMainCommit(companyId: companyId, ifEqual: pending) }
            if case .failed(_, _, let stderr) = error { throw WorkError.conflict("could not accept \(full): \(Self.flat(stderr, max: 300))") }
            throw error
        }
        let now = Store.now()
        switch outcome {
        case .refMoved(let current):
            let now7 = current.map { "it now points at \($0)" } ?? "it was deleted"
            let text = "\(company.name): \(full) moved after Brahma asked you about it (\(now7); Brahma recorded \(commit)). "
                + "Nothing was merged. Review the recorded commit with: git --no-replace-objects diff \(expected) \(commit)"
            try writer.write { db in
                try EngineAlerts.raise(store: self, db: db, text: text, now: now, reason: Self.quarantineMovedAlertReason(companyId))
            }
            throw WorkError.conflict("\(full) moved since Brahma recorded it (\(now7); recorded \(commit.prefix(12))); nothing was merged")
        case .merged(let head):
            try writer.write { db in
                try finalizeMainCommit(db, companyId: companyId, commit: head)
                let earlier = open ? "" : " (\(ask.ref) was \(ask.status.rawValue) earlier)"
                try ActivityEvent(companyId: companyId, agentId: nil, turnId: nil, kind: .work,
                                  text: "the owner accepted \(full) (\(commit.prefix(12))) into main at \(head.prefix(7))\(earlier)",
                                  createdAt: now).insert(db)
                guard var current = try Ask.fetchOne(db, key: ask.id), Self.openAskStatuses.contains(current.status.rawValue) else { return }
                current.ownerNote = note.map { Self.flat($0, max: Self.maxAskField) }
                    ?? "accepted with brahma main accept; \(commit.prefix(12)) merged into main at \(head.prefix(7))"
                current.ownerDecidedAt = now
                try settle(db, ask: &current, status: .approved, decidedBy: "owner", tellRequesterToo: false, now: now)
            }
            return MainAcceptance(head: head, ask: try self.ask(id: ask.id) ?? ask, alreadyMerged: false)
        }
    }

    /// The quarantine ref an ask is the engine's own quarantine ask for (requester `system`, kind `other`, category
    /// `engine-code`, subject `quarantine:<ref>@<sha>`); nil for any other ask, an agent's look-alike included.
    public static func quarantineRef(of ask: Ask) -> String? {
        guard ask.requesterId == "system", ask.kind == .other, ask.category == quarantineCategory,
              let subject = ask.subjectId, subject.hasPrefix("quarantine:"), let at = subject.lastIndex(of: "@") else { return nil }
        let ref = String(subject[subject.index(subject.startIndex, offsetBy: "quarantine:".count)..<at])
        return GitWorkspace.isQuarantineRef(ref) ? ref : nil
    }
}

/// What the owner's accept of `main` came to (`Store.acceptMainCommit`).
public struct MainAcceptance: Sendable {
    /// `main`'s head afterwards.
    public var head: String
    /// The engine's quarantine ask the accept was for, as it stands now; nil when the current head was accepted.
    public var ask: Ask?
    /// The quarantined commit was already in `main`: nothing was merged.
    public var alreadyMerged: Bool
}
