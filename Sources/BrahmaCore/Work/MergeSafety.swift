import Foundation
import GRDB

/// Keeps several engineers' branches from colliding (Task 9b). After every landing in `main`, `afterLanding` dry-runs each open
/// item branch against the new `main` and tells holders whose branch has fallen behind.
struct MergeSafety: Sendable {
    /// A branch more than this many commits behind `main` is told to rebase.
    static let maxBehindCommits = 20
    /// ... or one that has been behind `main` for more than this many company-active days.
    static let maxBehindActiveDays = 2
    static let conflictFlagPrefix = "conflicts with main: "
    static let maxFlagFiles = 5
    static let maxNoticeFiles = 20

    let store: Store
    init(store: Store) { self.store = store }

    /// The review flag for a dry run that conflicts on `files`; nil for a clean one.
    static func flag(files: [String]) -> String? {
        guard !files.isEmpty else { return nil }
        let listed = files.prefix(maxFlagFiles).joined(separator: ", ")
        let more = files.count > maxFlagFiles ? ", and \(files.count - maxFlagFiles) more" : ""
        return Store.sanitizedFlags([conflictFlagPrefix + listed + more]).first
    }

    /// One pass over the company's in-progress and in-review branches (the landed item excluded). A failure on one branch
    /// (a dry run git could not make) is skipped and changes no flag; the rest are still looked at.
    func afterLanding(companyId: String, mergedKey: String) throws {
        guard let company = try store.company(id: companyId) else { return }
        let git = store.gitWorkspace(root: URL(fileURLWithPath: company.workspacePath, isDirectory: true), companyId: companyId)
        let items = try store.writer.read { db in
            try WorkItem.fetchAll(db, sql: """
                SELECT * FROM workItem WHERE companyId = ? AND status IN ('inProgress', 'inReview') AND mergeState = 'none' AND key <> ?
                ORDER BY number
                """, arguments: [companyId, mergedKey])
        }
        for item in items {
            guard (try? git.head(of: git.branchRef(key: item.key))) ?? nil != nil else { continue }
            if let files = try? git.mergeConflicts(key: item.key) { try? recordDryRun(item: item, files: files, mergedKey: mergedKey) }
            if item.status == .inProgress { try? checkFreshness(item: item, git: git) }
        }
    }

    /// Adds, replaces or clears the item's `conflicts with main` flag. A notice goes out only when the flag changes.
    private func recordDryRun(item: WorkItem, files: [String], mergedKey: String) throws {
        let flag = Self.flag(files: files)
        let now = Store.now()
        try store.writer.write { db in
            guard var current = try WorkItem.fetchOne(db, key: item.id), current.status == .inProgress || current.status == .inReview,
                  current.mergeState == .none else { return }
            let old = current.reviewFlags.first { $0.hasPrefix(Self.conflictFlagPrefix) }
            guard old != flag else { return }
            current.reviewFlags.removeAll { $0.hasPrefix(Self.conflictFlagPrefix) }
            if let flag { current.reviewFlags.append(flag) }
            current.updatedAt = now
            try current.update(db)
            guard flag != nil else { return }
            let shown = Store.sanitizedFlags(files)
            var text = "would conflict with main after \(mergedKey)"
            for f in shown.prefix(Self.maxNoticeFiles) { text += "\n    | \(f)" }
            if shown.count > Self.maxNoticeFiles { text += "\n    | … and \(shown.count - Self.maxNoticeFiles) more" }
            let holder = try Store.leaseHolderId(db: db, itemId: current.id) ?? current.ownerId
            try store.recordItemEvent(db: db, item: current, actor: "system", kind: .mergeConflict, text: text,
                                      alsoNotify: [holder].compactMap { $0 }, alsoNotifyRole: .holder, now: now)
        }
    }

    /// One notice per merge base: when the branch is more than `maxBehindCommits` commits or `maxBehindActiveDays` active days
    /// behind `main`. Rebasing moves the merge base and starts a new count.
    private func checkFreshness(item: WorkItem, git: GitWorkspace) throws {
        let base = try git.mergeBase(GitWorkspace.mainRef, git.branchRef(key: item.key))
        let behind = try git.commitsBehind(key: item.key)
        let now = Store.now()
        try store.writer.write { db in
            guard behind > 0, let base else {
                try db.execute(sql: "DELETE FROM branchFreshness WHERE itemId = ?", arguments: [item.id])
                return
            }
            guard let current = try WorkItem.fetchOne(db, key: item.id), current.status == .inProgress else { return }
            let active = try Store.activeNow(db: db, companyId: item.companyId)
            var since = active
            var notified = false
            if let row = try Row.fetchOne(db, sql: "SELECT mergeBase, behindSinceActive, notified FROM branchFreshness WHERE itemId = ?",
                                          arguments: [item.id]), (row["mergeBase"] as String) == base {
                since = row["behindSinceActive"]
                notified = row["notified"]
            }
            let overdue = behind > Self.maxBehindCommits || active - since > Double(Self.maxBehindActiveDays) * 86_400
            let notify = overdue && !notified
            try db.execute(sql: "INSERT OR REPLACE INTO branchFreshness (itemId, mergeBase, behindSinceActive, notified) VALUES (?, ?, ?, ?)",
                           arguments: [item.id, base, since, notified || notify])
            guard notify else { return }
            let holder = try Store.leaseHolderId(db: db, itemId: item.id) ?? current.ownerId
            try store.recordItemEvent(
                db: db, item: current, actor: "system", kind: .branchBehind,
                text: "\(item.key) is \(behind) commits behind main; rebase item/\(item.key) on main in your worktree and re-run your check.",
                alsoNotify: [holder].compactMap { $0 }, alsoNotifyRole: .holder, onlyAlsoNotify: true, now: now)
        }
    }
}
