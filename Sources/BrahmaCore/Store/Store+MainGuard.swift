import Foundation
import GRDB

/// The engine's record of where `refs/heads/main` stands. `company.mainCommit` advances only from the engine: the repository
/// import at creation, its own merges, its dirty-main commit, and the owner accepting the current head. An agent that moves
/// `main` by any other route (a reset, a rewrite, or a fast-forward of unreviewed commits) makes the head differ from the
/// record; claims and merges are then refused and the owner is alerted until the owner accepts it. Nothing resolves that alert
/// by itself.
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

    /// Passes only when `refs/heads/main` is exactly the recorded head. A different head (descendant or not), an unreadable
    /// one, or no record at all raises one owner alert and throws `mainChangedMessage`. The alert is never resolved here.
    /// Merges (9b) call this too and hold while it throws.
    func checkMain(company: Company, git: GitWorkspace? = nil) throws {
        let git = git ?? gitWorkspace(root: URL(fileURLWithPath: company.workspacePath, isDirectory: true), companyId: company.id)
        let current = try? git.head(of: GitWorkspace.mainRef)
        let recorded = try writer.read { try Company.fetchOne($0, key: company.id)?.mainCommit }
        if let recorded, let current, recorded == current { return }
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

    /// The owner has reviewed `main` and accepts its current head. Owner-only (`brahma main accept`, the app).
    public func acceptMainCommit(companyId: String) throws {
        guard let company = try company(id: companyId) else { throw WorkError.notFound("no such company") }
        let git = gitWorkspace(root: URL(fileURLWithPath: company.workspacePath, isDirectory: true), companyId: company.id)
        guard let head = try git.head(of: GitWorkspace.mainRef) else { throw WorkError.conflict("\(company.name) has no main branch") }
        try writer.write { db in
            try db.execute(sql: "UPDATE company SET mainCommit = ? WHERE id = ?", arguments: [head, companyId])
            try resolveEngineAlerts(db, reasons: [Store.mainAlertReason(companyId)], now: Store.now())
        }
    }
}
