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
        var title = ""
        var body = ""
        var maintainerCanModify = false
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

    enum Failure: Error, Equatable { case notFound(String), unavailable, lostResponse }

    /// How the next `POST /pulls` fails, if it does: `lostResponse` opens the PR and then loses the answer (an unknown
    /// outcome); `lostRequest` loses the call before GitHub saw it (also unknown); `rejected` is GitHub's own 4xx.
    enum OpenFailure: Equatable { case lostResponse, lostRequest, rejected(Int, String) }

    private let lock = NSLock()
    private var repos: [GitHubRepoRef: Repo] = [:]
    private var log: [String] = []
    /// When set, every call fails (GitHub unreachable).
    private var down = false
    private var nextOpenFailure: OpenFailure?
    private var opens: [OpenPullRequest] = []
    /// Called after each request is logged, outside the lock (tests read the landing's state at that moment).
    private var hook: (@Sendable (String) -> Void)?

    init(_ repo: GitHubRepoRef, visibility: String = "private", defaultBranch: String = "main", protection: Protection = Protection()) {
        repos[repo] = Repo(visibility: visibility, defaultBranch: defaultBranch, protection: protection)
    }

    var requests: [String] { lock.withLock { log } }
    /// Every `POST /pulls` body, as sent.
    var openRequests: [OpenPullRequest] { lock.withLock { opens } }

    func failNextOpen(_ failure: OpenFailure?) { lock.withLock { nextOpenFailure = failure } }
    func onRequest(_ hook: (@Sendable (String) -> Void)?) { lock.withLock { self.hook = hook } }

    /// Logs a request, then runs the hook outside the lock.
    private func logged<T>(_ line: String, _ body: () throws -> T) throws -> T {
        let (result, hook): (Result<T, Error>, (@Sendable (String) -> Void)?) = lock.withLock {
            log.append(line)
            return (Result { try body() }, self.hook)
        }
        hook?(line)
        return try result.get()
    }

    static func pr(_ repo: GitHubRepoRef, _ p: PullRequest) -> GitHubPR {
        GitHubPR(number: p.number, htmlURL: "https://github.com/\(repo.owner)/\(repo.name)/pull/\(p.number)", state: p.state, merged: p.merged,
                 headRef: p.head, headSHA: p.headSHA, baseRef: p.base)
    }

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
        try logged("GET /repos/\(repo.owner)/\(repo.name)") {
            if down { throw Failure.unavailable }
            guard let r = repos[repo] else { throw Failure.notFound("/repos/\(repo.owner)/\(repo.name)") }
            return RepoInfo(visibility: r.visibility, defaultBranch: r.defaultBranch)
        }
    }

    func branch(_ repo: GitHubRepoRef, name: String) async throws -> GitHubBranch? {
        try logged("GET /repos/\(repo.owner)/\(repo.name)/branches/\(name)") {
            if down { throw Failure.unavailable }
            guard let r = repos[repo] else { throw Failure.notFound("/repos/\(repo.owner)/\(repo.name)") }
            return r.branches[name].map { GitHubBranch(sha: $0) }
        }
    }

    func openPR(_ repo: GitHubRepoRef, _ request: OpenPullRequest) async throws -> GitHubPR {
        try logged("POST /repos/\(repo.owner)/\(repo.name)/pulls") {
            opens.append(request)
            if down { throw Failure.unavailable }
            let failure = nextOpenFailure
            nextOpenFailure = nil
            if failure == .lostRequest { throw Failure.unavailable }
            if case .rejected(let status, let message) = failure { throw GitHubAPIError.rejected(status: status, message: message) }
            guard var r = repos[repo] else { throw Failure.notFound("/repos/\(repo.owner)/\(repo.name)") }
            guard let headSHA = r.branches[request.head] else {
                throw GitHubAPIError.rejected(status: 422, message: "Validation Failed: head \(request.head) does not exist")
            }
            if r.pulls.contains(where: { $0.head == request.head && $0.state == "open" }) {
                throw GitHubAPIError.rejected(status: 422, message: "A pull request already exists for \(repo.owner):\(request.head).")
            }
            let number = (r.pulls.map(\.number) + r.issues.map(\.number)).max().map { $0 + 1 } ?? 1
            let pull = PullRequest(number: number, head: request.head, headSHA: headSHA, base: request.base,
                                   baseSHA: r.branches[request.base] ?? "", title: request.title, body: request.body,
                                   maintainerCanModify: request.maintainerCanModify)
            r.pulls.append(pull)
            repos[repo] = r
            if failure == .lostResponse { throw Failure.lostResponse }
            return Self.pr(repo, pull)
        }
    }

    func pulls(_ repo: GitHubRepoRef, head: String, state: String) async throws -> [GitHubPR] {
        try logged("GET /repos/\(repo.owner)/\(repo.name)/pulls?head=\(head)&state=\(state)") {
            if down { throw Failure.unavailable }
            guard let r = repos[repo] else { throw Failure.notFound("/repos/\(repo.owner)/\(repo.name)") }
            let parts = head.split(separator: ":", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[0] == repo.owner else { return [] }
            return r.pulls.filter { $0.head == parts[1] && (state == "all" || $0.state == state) }.map { Self.pr(repo, $0) }
        }
    }

    func pull(_ repo: GitHubRepoRef, number: Int) async throws -> GitHubPR? {
        try logged("GET /repos/\(repo.owner)/\(repo.name)/pulls/\(number)") {
            if down { throw Failure.unavailable }
            guard let r = repos[repo] else { throw Failure.notFound("/repos/\(repo.owner)/\(repo.name)") }
            return r.pulls.first { $0.number == number }.map { Self.pr(repo, $0) }
        }
    }
}
