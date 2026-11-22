import Foundation

/// `git diff --shortstat` as numbers.
public struct DiffStat: Codable, Equatable, Sendable {
    public var files: Int
    public var insertions: Int
    public var deletions: Int

    public init(files: Int = 0, insertions: Int = 0, deletions: Int = 0) {
        self.files = files; self.insertions = insertions; self.deletions = deletions
    }

    public static let zero = DiffStat()

    /// ` 3 files changed, 10 insertions(+), 2 deletions(-)`; each part may be missing; anything else reads as zero.
    public static func parse(shortstat: String) -> DiffStat {
        var stat = DiffStat()
        for part in shortstat.split(separator: ",") {
            let words = part.split(separator: " ")
            guard words.count >= 2, let n = Int(words[0]) else { continue }
            if words[1].hasPrefix("file") { stat.files = n }
            else if words[1].hasPrefix("insertion") { stat.insertions = n }
            else if words[1].hasPrefix("deletion") { stat.deletions = n }
        }
        return stat
    }
}

/// What the app and the reviewer's header show about an item's branch.
public struct BranchInfo: Codable, Equatable, Sendable {
    public var branch: String
    /// The item's worktree, when it has one.
    public var worktreePath: String?
    /// Commits on the branch that `main` lacks.
    public var ahead: Int
    /// Commits on `main` that the branch lacks.
    public var behind: Int
    /// What the branch changes against its merge base with `main`.
    public var diff: DiffStat
    /// The branch's tip; nil when the branch is gone (landed or deleted).
    public var head: String?

    public init(branch: String, worktreePath: String? = nil, ahead: Int = 0, behind: Int = 0, diff: DiffStat = .zero, head: String? = nil) {
        self.branch = branch; self.worktreePath = worktreePath; self.ahead = ahead; self.behind = behind; self.diff = diff; self.head = head
    }
}

/// Reads an item's branch from the repository (git: call it in a blocking body).
public enum BranchInspector {
    public static func info(git: GitWorkspace, key: String) throws -> BranchInfo {
        let branch = git.branch(key: key)
        let worktree = git.hasCheckout(key: key) ? git.worktreePath(key: key).path : nil
        guard let tip = try git.head(of: git.branchRef(key: key)), let main = try git.head(of: GitWorkspace.mainRef) else {
            return BranchInfo(branch: branch, worktreePath: worktree)
        }
        let base = try git.mergeBase(main, tip)
        let stat = try base.map { DiffStat.parse(shortstat: try git.shortstat(base: $0, head: tip)) } ?? .zero
        return BranchInfo(branch: branch, worktreePath: worktree, ahead: try git.revListCount("\(main)..\(tip)"),
                          behind: try git.revListCount("\(tip)..\(main)"), diff: stat, head: tip)
    }
}
