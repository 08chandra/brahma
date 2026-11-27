import Foundation

/// How GitHub merges a pull request (`merge_method`). The engine takes the repository's own choice, read fresh
/// (`allow_merge_commit`, `allow_squash_merge`, `allow_rebase_merge`), preferring a merge commit, then squash, then rebase.
public enum MergeMethod: String, Codable, CaseIterable, Sendable {
    case merge, squash, rebase

    /// The method the repository allows, in that order of preference; nil when it allows none (the engine never changes the
    /// repository's settings to make one allowed).
    public static func preferred(_ info: RepoInfo) -> MergeMethod? {
        if info.allowMergeCommit { return .merge }
        if info.allowSquashMerge { return .squash }
        if info.allowRebaseMerge { return .rebase }
        return nil
    }
}

/// The body of `PUT /repos/{o}/{r}/pulls/{n}/merge` (the `merge-pr` action), and all of it: the head commit the owner approved
/// (`sha`: GitHub refuses with 409 if the branch moved since) and the method. There is no other field — no bypass, no admin
/// override, no commit message — and none can be added by a caller.
public struct MergePullRequest: Equatable, Sendable, Encodable {
    public let sha: String
    public let mergeMethod: MergeMethod

    public init(sha: String, mergeMethod: MergeMethod) { self.sha = sha; self.mergeMethod = mergeMethod }

    private enum CodingKeys: String, CodingKey {
        case sha, mergeMethod = "merge_method"
    }
}

/// GitHub's answer to a merge (`200 { sha, merged, message }`): `sha` is the commit `main` now points at for this PR (the merge
/// commit, the squashed commit, or the last rebased one).
public struct GitHubMergeResult: Equatable, Sendable {
    public var sha: String
    public var merged: Bool
    public var message: String

    public init(sha: String, merged: Bool, message: String) { self.sha = sha; self.merged = merged; self.message = message }
}
