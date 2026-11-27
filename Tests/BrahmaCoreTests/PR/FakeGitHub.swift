import Foundation
@testable import BrahmaCore

/// An in-memory GitHub for PR mode's tests (Plan X8): repositories with visibility, a default branch and branch protection;
/// branches; pull requests whose `mergeable_state` follows the protection (`blocked`, `unstable`, `behind`, `clean`); check
/// runs; reviews pinned to a `commit_id`; comments; issues; commits with `verification.verified` and `author.login`. Every
/// call is logged (`requests`: `GET /repos/o/r`, ...). Conforms to `GitHubAPI`; later tasks add the PR and issue calls.
final class FakeGitHub: GitHubAPI, @unchecked Sendable {
    struct Protection: Equatable { var requiredChecks: [String] = []; var requiredReviews = 0 }
    struct CheckRun: Equatable { var name: String; var headSHA: String; var conclusion: String? }
    struct Review: Equatable { var user: String; var state: String; var commitId: String }
    struct Comment: Equatable { var user: String; var body: String }
    struct IssueRecord: Equatable { var number: Int; var title: String; var body: String; var user: String; var labels: [String]; var state = "open" }
    struct Commit: Equatable { var sha: String; var authorLogin: String?; var verified: Bool }
    struct PullRequest: Equatable {
        var number: Int
        var head: String
        var headSHA: String
        var base: String
        var baseSHA: String
        var state = "open"
        var merged = false
        var reviews: [Review] = []
        var comments: [Comment] = []
    }
    struct Repo {
        var visibility: String
        var defaultBranch = "main"
        var protection = Protection()
        var branches: [String: String] = [:]
        var pulls: [PullRequest] = []
        var checkRuns: [CheckRun] = []
        var issues: [IssueRecord] = []
        var commits: [String: Commit] = [:]
    }

    enum Failure: Error, Equatable { case notFound(String), unavailable }

    private let lock = NSLock()
    private var repos: [GitHubRepoRef: Repo] = [:]
    private var log: [String] = []
    /// When set, every call fails (GitHub unreachable).
    private var down = false

    init(_ repo: GitHubRepoRef, visibility: String = "private", defaultBranch: String = "main", protection: Protection = Protection()) {
        repos[repo] = Repo(visibility: visibility, defaultBranch: defaultBranch, protection: protection)
    }

    var requests: [String] { lock.withLock { log } }

    func update(_ repo: GitHubRepoRef, _ change: (inout Repo) -> Void) {
        lock.withLock { if var r = repos[repo] { change(&r); repos[repo] = r } }
    }

    func setDown(_ value: Bool) { lock.withLock { down = value } }

    func snapshot(_ repo: GitHubRepoRef) -> Repo? { lock.withLock { repos[repo] } }

    /// GitHub's `mergeable_state` for a PR under the repository's protection: `behind` when the base moved past the PR's base,
    /// `blocked` when approvals at the head are missing, `unstable` when a required check is not green at the head, else `clean`.
    func mergeableState(_ repo: GitHubRepoRef, pr number: Int) -> String? {
        lock.withLock {
            guard let r = repos[repo], let pr = r.pulls.first(where: { $0.number == number }) else { return nil }
            if let tip = r.branches[pr.base], tip != pr.baseSHA { return "behind" }
            let approvals = Set(pr.reviews.filter { $0.state == "APPROVED" && $0.commitId == pr.headSHA }.map(\.user)).count
            if approvals < r.protection.requiredReviews { return "blocked" }
            let green = Set(r.checkRuns.filter { $0.headSHA == pr.headSHA && $0.conclusion == "success" }.map(\.name))
            if !Set(r.protection.requiredChecks).isSubset(of: green) { return "unstable" }
            return "clean"
        }
    }

    // MARK: GitHubAPI

    func repo(_ repo: GitHubRepoRef) async throws -> RepoInfo {
        try lock.withLock {
            log.append("GET /repos/\(repo.owner)/\(repo.name)")
            if down { throw Failure.unavailable }
            guard let r = repos[repo] else { throw Failure.notFound("/repos/\(repo.owner)/\(repo.name)") }
            return RepoInfo(visibility: r.visibility, defaultBranch: r.defaultBranch)
        }
    }

    func branch(_ repo: GitHubRepoRef, name: String) async throws -> GitHubBranch? {
        try lock.withLock {
            log.append("GET /repos/\(repo.owner)/\(repo.name)/branches/\(name)")
            if down { throw Failure.unavailable }
            guard let r = repos[repo] else { throw Failure.notFound("/repos/\(repo.owner)/\(repo.name)") }
            return r.branches[name].map { GitHubBranch(sha: $0) }
        }
    }
}
