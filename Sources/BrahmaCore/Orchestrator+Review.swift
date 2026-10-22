import Foundation
import GRDB

/// What a review turn is built from: the item, its worktree and the digest the reviewer sees instead of any conversation.
struct ReviewTurnContext {
    var item: WorkItem
    var worktree: URL
    var digest: String
    /// Tier L or flagged: the strongest model.
    var deep: Bool
}

extension Orchestrator {
    /// The oldest pending review of `agent`, ready to run, or nil. Throws `WorktreeUnavailable` when its worktree is missing
    /// and cannot be recreated (the turn does not start). Runs git, so it is called off the actor.
    nonisolated static func prepareReview(store: Store, agent: Agent, company: Company) throws -> ReviewTurnContext? {
        guard let item = try store.pendingReviews(agentId: agent.id).first, let commit = item.verifiedCommit else { return nil }
        let workspace = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        let git = store.gitWorkspace(root: workspace, companyId: company.id)
        if !git.hasCheckout(key: item.key) {
            do { try git.addWorktree(key: item.key) } catch {
                throw WorktreeUnavailable(itemId: item.id, key: item.key, reason: "\(error)")
            }
        }
        // The real change: from where the branch left `main` to the commit the engine verified.
        var names: (entries: [GitChange], truncated: Bool) = ([], false)
        var diff: (text: String, truncated: Bool)
        do {
            guard let base = try git.mergeBase(GitWorkspace.mainRef, commit) else {
                throw GitError.failed(command: "merge-base", status: 1, stderr: "the branch shares no history with main")
            }
            names = try git.nameStatus(base: base, head: commit)
            diff = try git.diff(base: base, head: commit)
        } catch {
            diff = ("(the diff could not be produced: \(String(describing: error).prefix(200)))", false)
        }
        let run = try store.passingVerification(itemId: item.id, commit: commit)
        let digest = ReviewDigest.render(item: item, run: run, nameStatus: names, diff: diff,
                                         dependencies: try store.dependencies(itemId: item.id),
                                         worktree: git.worktreePath(key: item.key).path, timeZone: store.ownerTimeZone())
        return ReviewTurnContext(item: item, worktree: git.worktreePath(key: item.key), digest: digest,
                                 deep: item.tier == .l || !item.reviewFlags.isEmpty)
    }
}

extension Store {
    /// The newest passing run of the item on exactly this commit.
    func passingVerification(itemId: String, commit: String) throws -> VerificationRun? {
        try writer.read { db in
            try VerificationRun.filter(Column("itemId") == itemId && Column("commit") == commit
                                       && Column("status") == VerificationStatus.passed.rawValue)
                .order(Column.rowID.desc).fetchOne(db)
        }
    }
}
