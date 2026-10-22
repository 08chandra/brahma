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
        let current = try? git.head(of: GitWorkspace.mainRef)
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

    /// Owner-only (`brahma main accept`, the app).
    /// - Without `ref`: the owner has reviewed `main` and accepts its current head.
    /// - With a quarantine ref (`refs/brahma/quarantine/<stamp>`, or just `<stamp>`): its changes are merged into `main` as an
    ///   engine-recorded merge (`mainCommit` advances) and the quarantine ask is settled, which releases the merge step.
    public func acceptMainCommit(companyId: String, ref: String? = nil) throws {
        guard let company = try company(id: companyId) else { throw WorkError.notFound("no such company") }
        let git = gitWorkspace(root: URL(fileURLWithPath: company.workspacePath, isDirectory: true), companyId: company.id)
        guard let ref else {
            guard let head = try git.head(of: GitWorkspace.mainRef) else { throw WorkError.conflict("\(company.name) has no main branch") }
            try writer.write { db in
                try finalizeMainCommit(db, companyId: companyId, commit: head)
                try resolveEngineAlerts(db, reasons: [Store.mainAlertReason(companyId)], now: Store.now())
            }
            return
        }
        let raw = ref.trimmingCharacters(in: .whitespacesAndNewlines)
        let full = raw.hasPrefix(GitWorkspace.quarantinePrefix) ? raw : GitWorkspace.quarantinePrefix + raw
        guard GitWorkspace.isQuarantineRef(full) else {
            throw WorkError.invalid("\(Self.flat(raw, max: 80)) is not a quarantine ref (refs/brahma/quarantine/<yyyyMMdd-HHmmss>)")
        }
        try checkMain(company: company, git: git)
        guard let expected = try self.company(id: companyId)?.mainCommit else { throw WorkError.conflict(Self.mainChangedMessage) }
        var pending: String?
        let head: String
        do {
            head = try git.mergeQuarantine(ref: full, expectedMain: expected, recordPending: { next in
                try self.setPendingMainCommit(companyId: companyId, next)
                pending = next
            })
        } catch let error as GitError {
            if let pending { try? clearPendingMainCommit(companyId: companyId, ifEqual: pending) }
            if case .failed(_, _, let stderr) = error { throw WorkError.conflict("could not accept \(full): \(Self.flat(stderr, max: 300))") }
            throw error
        }
        let now = Store.now()
        try writer.write { db in
            try finalizeMainCommit(db, companyId: companyId, commit: head)
            try ActivityEvent(companyId: companyId, agentId: nil, turnId: nil, kind: .work,
                              text: "the owner accepted \(full) into main at \(head.prefix(7))", createdAt: now).insert(db)
            let asks = try Ask.filter(Column("companyId") == companyId && Column("kind") == AskKind.other
                                      && Column("subjectId") == Self.quarantineSubject(full)
                                      && [AskStatus.pendingOwner.rawValue, AskStatus.pendingInternal.rawValue].contains(Column("status"))).fetchAll(db)
            for var ask in asks {
                ask.ownerNote = "accepted with brahma main accept; merged into main at \(head.prefix(7))"
                ask.ownerDecidedAt = now
                try settle(db, ask: &ask, status: .approved, decidedBy: "owner", tellRequesterToo: false, now: now)
            }
        }
    }
}
