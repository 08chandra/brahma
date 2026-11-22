import Foundation
import GRDB

/// What a review turn is built from: the item, its worktree and the digest the reviewer sees instead of any conversation.
struct ReviewTurnContext {
    var item: WorkItem
    var worktree: URL
    var digest: String
    /// Tier L or flagged: the strongest model.
    var deep: Bool
    /// The item is marked, or its submission came from a tainted session (S19: the review turn is tainted at launch).
    var untrusted = false
}

extension Orchestrator {
    /// The oldest pending review of `agent`, ready to run, or nil. Throws `WorktreeUnavailable` when its worktree is missing
    /// and cannot be recreated (the turn does not start). Runs git, so it is called off the actor.
    nonisolated static func prepareReview(store: Store, agent: Agent, company: Company) throws -> ReviewTurnContext? {
        guard let item = try store.pendingReviews(agentId: agent.id).first, let commit = item.verifiedCommit else { return nil }
        let workspace = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        let git = store.gitWorkspace(root: workspace, companyId: company.id)
        if !git.hasCheckout(key: item.key) {
            do {
                try git.addWorktree(key: item.key)
                store.noteWorktreeSetupSuccess(companyId: company.id)
            } catch {
                throw WorktreeUnavailable(itemId: item.id, key: item.key, reason: "\(error)", review: true)
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
        // A marked item, or a submission a tainted session wrote, is framed as untrusted; the review turn is not tainted by it.
        let submitted = try store.itemEvents(itemId: item.id, limit: 200).last(where: { $0.kind == .submitted })
        let digest = ReviewDigest.render(item: item, run: run, nameStatus: names, diff: diff,
                                         dependencies: try store.dependencies(itemId: item.id),
                                         worktree: git.worktreePath(key: item.key).path, timeZone: store.ownerTimeZone(),
                                         untrusted: item.taintedOrigin || submitted?.taintedOrigin == true,
                                         // C3b: the diff holds commits a tainted session made (fail closed: unreadable is tainted).
                                         taintedCommits: store.reviewDiffTaint(companyId: company.id, itemKey: item.key, commit: commit))
        var context = ReviewTurnContext(item: item, worktree: git.worktreePath(key: item.key), digest: digest,
                                        deep: item.tier == .l || !item.reviewFlags.isEmpty)
        context.untrusted = item.taintedOrigin || submitted?.taintedOrigin == true
        return context
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

/// What a batched audit turn is built from: the samples batched to the agent and the digest of their merged diffs.
struct AuditTurnContext {
    var itemIds: [String]
    var digest: String
    /// One of the audited items is marked (S19).
    var untrusted = false
}

extension Orchestrator {
    /// The agent's batched audit (9c), ready to run, or nil. Each sample's merged diff is read from the engine-recorded base
    /// and merged commit. A sample whose diff cannot be produced is deferred (`Store.deferAudits`), never put to the auditor.
    /// Runs git, so it is called off the actor.
    nonisolated static func prepareAudit(store: Store, agent: Agent, company: Company) throws -> AuditTurnContext? {
        let samples = try store.pendingAudits(agentId: agent.id)
        guard !samples.isEmpty else { return nil }
        let git = store.gitWorkspace(root: URL(fileURLWithPath: company.workspacePath, isDirectory: true), companyId: company.id)
        var entries: [AuditDigest.Entry] = []
        var deferred: [String] = []
        for sample in samples {
            guard let item = try store.workItem(id: sample.itemId), item.companyId == company.id else { continue }
            guard let base = sample.baseCommit, let merged = sample.mergedCommit,
                  let names = try? git.nameStatus(base: base, head: merged), let diff = try? git.diff(base: base, head: merged) else {
                deferred.append(sample.itemId)
                continue
            }
            let author = try sample.authorId.flatMap { try store.agent(id: $0) }?.name
            entries.append(AuditDigest.Entry(item: item, author: author, mergedCommit: sample.mergedCommit, nameStatus: names, diff: diff))
        }
        try store.deferAudits(itemIds: deferred, agentId: agent.id)
        guard !entries.isEmpty else { return nil }
        return AuditTurnContext(itemIds: entries.map(\.item.id), digest: AuditDigest.render(entries: entries),
                                untrusted: entries.contains { $0.item.taintedOrigin })
    }
}
