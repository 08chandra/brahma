import Foundation
import GRDB

/// Messages the engine must put in front of the owner. Each also files one `engineAlert` ask per hold reason in every company
/// (a repeat for the same reason changes nothing); the ask answers itself with "resolved" when the hold ends
/// (`Store.clearHold`, or a hold of a higher precedence replacing it).
public enum EngineAlerts {
    /// The reason that keys the alert ask when the caller names none and there is no hold.
    static let generalReason = "doctor"

    /// A system DM to `owner` in every company, an `ActivityEvent(.error)` and the `engineAlert` ask, inside the caller's
    /// transaction. `reason` defaults to the current engine hold's reason. `companyId` limits it to that company.
    public static func raise(store: Store, db: Database, text: String, now: Date, reason: String? = nil,
                             companyId: String? = nil) throws {
        let router = MessageRouter(store: store)
        let key = try reason ?? EngineHold.fetchOne(db, key: 1)?.reason.rawValue ?? generalReason
        for company in try Company.fetchAll(db) where companyId == nil || company.id == companyId {
            try router.sendDM(db: db, companyId: company.id, from: .system, to: "owner", text: text, now: now)
            try ActivityEvent(companyId: company.id, agentId: nil, turnId: nil, kind: .error, text: text, createdAt: now).insert(db)
            try store.fileEngineAlert(db, company: company, reason: key, text: text, now: now)
        }
    }

    public static func raise(store: Store, text: String, now: Date, reason: String? = nil, companyId: String? = nil) throws {
        try store.writer.write { db in try raise(store: store, db: db, text: text, now: now, reason: reason, companyId: companyId) }
    }

    /// The reason that keys the alert about an engine file under `.brahma/` that was a link or not a regular file.
    public static let engineFileReason = "engine-file"

    static func engineFileText(_ problem: UnsafeEngineFile) -> String {
        "The engine refused to write through \(Store.flat(problem.path, max: 400)): it \(problem.problem). Something in the "
            + "workspace (an agent, or another program) put it there; nothing outside the workspace was written. Check the file."
    }
}

extension Store {
    /// Raises the engine alert for a link or odd file found where the engine keeps its own files, in the caller's transaction.
    func alertEngineFile(db: Database, _ problem: UnsafeEngineFile, companyId: String, now: Date) throws {
        try EngineAlerts.raise(store: self, db: db, text: EngineAlerts.engineFileText(problem), now: now,
                               reason: EngineAlerts.engineFileReason, companyId: companyId)
    }

    /// The same in its own transaction; never throws (the alert is best effort, the caller reports its own error).
    func alertEngineFile(_ problem: UnsafeEngineFile, companyId: String, now: Date = Store.now()) {
        try? writer.write { db in try alertEngineFile(db: db, problem, companyId: companyId, now: now) }
    }
}

extension Store {
    /// The reason that keys a company's alert about git checkouts the engine could not set up.
    static func worktreeSetupAlertReason(_ companyId: String) -> String { "worktree-setup:\(companyId)" }

    /// A git checkout the engine needed could not be made (an item's worktree for a claim, a dispatch, a lease turn or a review;
    /// a submission's check checkout). That is the engine's fault, never the work's: the caller defers or retries the work
    /// (a check is recorded inconclusive), and here it is made loud: a log line and one owner alert per company while that alert
    /// stays open. Failures that file their own alert add none: git refused to run in the repository (its config), or `main`
    /// changed outside Brahma. Returns whether an alert was raised; never throws.
    @discardableResult
    func noteWorktreeSetupFailure(companyId: String, what: String, error: any Error, now: Date = Store.now()) -> Bool {
        FileHandle.standardError.write(Data("brahma: could not set up \(what): \(error)\n".utf8))
        if let git = error as? GitError, git.isRepositoryRefusal { return false }
        if GitError.isRepositoryRefusal(text: "\(error)") { return false }
        if let work = error as? WorkError, work.message == Store.mainChangedMessage { return false }
        let reason = Store.worktreeSetupAlertReason(companyId)
        let raised = try? writer.write { db -> Bool in
            guard let company = try Company.fetchOne(db, key: companyId) else { return false }
            let open = try Ask.filter(Column("companyId") == companyId && Column("kind") == AskKind.engineAlert
                                      && Column("status") == AskStatus.pendingOwner.rawValue
                                      && Column("subjectId") == Store.engineAlertKey(reason)).fetchCount(db)
            guard open == 0 else { return false }
            let text = "Brahma could not set up a git checkout in \(company.name) (\(what)): \(Store.flat("\(error)", max: 400)). "
                + "This is Brahma's own fault, not the work's: nothing was counted against it and Brahma tries again. If it keeps "
                + "happening, run `git worktree list` in \(Store.flat(company.workspacePath, max: 200)) and look at .git/worktrees."
            try EngineAlerts.raise(store: self, db: db, text: text, now: now, reason: reason, companyId: companyId)
            return true
        }
        return raised ?? false
    }
}
