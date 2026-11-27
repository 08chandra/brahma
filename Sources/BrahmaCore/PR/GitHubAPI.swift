import Foundation

/// A GitHub repository named exactly by the push URL `https://github.com/<owner>/<name>.git` (the only shape PR mode accepts).
public struct GitHubRepoRef: Hashable, Codable, Sendable {
    public var owner: String
    public var name: String

    public init(owner: String, name: String) { self.owner = owner; self.name = name }

    /// `https://github.com/<owner>/<name>.git`.
    public var pushURL: String { "https://github.com/\(owner)/\(name).git" }

    /// The repository a push URL names, or nil unless it is exactly `https://github.com/<owner>/<name>.git`: no credentials, no
    /// port, no query or fragment, no other host, no path beyond the two parts. Owner: GitHub's login rule (letters, digits and
    /// single inner `-`, at most 39); name: letters, digits, `.`, `_`, `-`, at most 100, never `.` or `..`.
    public static func parse(pushURL url: String) -> GitHubRepoRef? {
        let prefix = "https://github.com/", suffix = ".git"
        guard url.hasPrefix(prefix), url.hasSuffix(suffix), url.utf8.count <= 200 else { return nil }
        let middle = url.dropFirst(prefix.count).dropLast(suffix.count)
        let parts = middle.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2 else { return nil }
        let owner = String(parts[0]), name = String(parts[1])
        guard owner.range(of: "^[A-Za-z0-9](?:[A-Za-z0-9]|-(?=[A-Za-z0-9])){0,38}$", options: .regularExpression) != nil,
              name.range(of: "^[A-Za-z0-9._-]{1,100}$", options: .regularExpression) != nil, name != ".", name != "..",
              !name.lowercased().hasSuffix(".git") else { return nil }
        return GitHubRepoRef(owner: owner, name: name)
    }
}

/// What the engine reads of a repository (`GET /repos/{owner}/{repo}`).
public struct RepoInfo: Equatable, Sendable {
    /// `public`, `private` or `internal`. Anything but `private` makes every push an owner ask (`GitHubRules.publicRepoPushAsks`).
    public var visibility: String
    public var defaultBranch: String
    public var allowMergeCommit: Bool
    public var allowSquashMerge: Bool
    public var allowRebaseMerge: Bool

    public init(visibility: String, defaultBranch: String, allowMergeCommit: Bool = true, allowSquashMerge: Bool = true,
                allowRebaseMerge: Bool = true) {
        self.visibility = visibility; self.defaultBranch = defaultBranch
        self.allowMergeCommit = allowMergeCommit; self.allowSquashMerge = allowSquashMerge; self.allowRebaseMerge = allowRebaseMerge
    }
}

/// A GitHub branch's head (`GET /repos/{owner}/{repo}/branches/{branch}`: `commit.sha`).
public struct GitHubBranch: Equatable, Sendable {
    public var sha: String
    public init(sha: String) { self.sha = sha }
}

/// The GitHub REST surface the engine needs (Ruling 1). Later tasks add the pull request and issue calls. There is no production
/// conformer on this tree (no URLSession anywhere in the engine): PR mode is dormant and fails closed until a channel core
/// (Plan X4) supplies an authenticated one. Tests use `FakeGitHub`.
public protocol GitHubAPI: Sendable {
    func repo(_ repo: GitHubRepoRef) async throws -> RepoInfo
    /// Nil when the branch does not exist (404).
    func branch(_ repo: GitHubRepoRef, name: String) async throws -> GitHubBranch?
    /// The `open-pr` action: `POST /repos/{o}/{r}/pulls` with `request` as the body (`maintainer_can_modify` always false).
    /// Throws `GitHubAPIError.rejected` when GitHub refused it; any other error leaves the outcome unknown.
    func openPR(_ repo: GitHubRepoRef, _ request: OpenPullRequest) async throws -> GitHubPR
    /// `GET /repos/{o}/{r}/pulls?head=<head>&state=<state>`: `head` is `<owner>:<branch>`, `state` `open`, `closed` or `all`.
    /// How an unknown `open-pr` is reconciled.
    func pulls(_ repo: GitHubRepoRef, head: String, state: String) async throws -> [GitHubPR]
    /// `GET /repos/{o}/{r}/pulls/{number}`; nil when there is none (404). Carries `mergeable_state`.
    func pull(_ repo: GitHubRepoRef, number: Int) async throws -> GitHubPR?
    /// `GET /repos/{o}/{r}/commits/{sha}/check-runs` (`filter=latest`), every page: the checks on a PR's head.
    func checkRuns(_ repo: GitHubRepoRef, sha: String) async throws -> [GitHubCheckRun]
    /// `GET /repos/{o}/{r}/pulls/{number}/reviews`, every page, oldest first.
    func reviews(_ repo: GitHubRepoRef, number: Int) async throws -> [GitHubReview]
    /// The `merge-pr` action (`--engine-merge` only, behind an owner card): `PUT /repos/{o}/{r}/pulls/{number}/merge` with exactly
    /// `request` as the body (`{ sha, merge_method }`). Throws `GitHubAPIError.rejected` when GitHub refused it — 409: the head
    /// is not `sha` (the branch moved); 405: not mergeable (protection, rules, checks, method); any other error leaves the
    /// outcome unknown: the engine reads the PR back (`pull`), never merges again blind. Never a protection or settings call.
    func mergePR(_ repo: GitHubRepoRef, number: Int, _ request: MergePullRequest) async throws -> GitHubMergeResult
}
