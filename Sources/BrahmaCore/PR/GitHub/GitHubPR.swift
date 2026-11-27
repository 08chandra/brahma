import Foundation

/// A pull request as the engine reads it (`GET /repos/{o}/{r}/pulls/{n}`, the list `GET /repos/{o}/{r}/pulls`, and the answer
/// to `POST /repos/{o}/{r}/pulls`).
public struct GitHubPR: Equatable, Sendable {
    public var number: Int
    /// `html_url`.
    public var htmlURL: String
    /// `open` or `closed`.
    public var state: String
    public var merged: Bool
    /// `head.ref`: the branch, without the owner.
    public var headRef: String
    /// `head.sha`.
    public var headSHA: String
    /// `base.ref`.
    public var baseRef: String
    /// `title` and `body` (null on GitHub reads as empty): what proves the PR's content is the engine's (Ruling 28).
    public var title: String
    public var body: String

    public init(number: Int, htmlURL: String, state: String, merged: Bool, headRef: String, headSHA: String, baseRef: String,
                title: String, body: String) {
        self.number = number; self.htmlURL = htmlURL; self.state = state; self.merged = merged
        self.headRef = headRef; self.headSHA = headSHA; self.baseRef = baseRef; self.title = title; self.body = body
    }

    public var isOpen: Bool { state == "open" }
}

/// The body of `POST /repos/{o}/{r}/pulls` (the `open-pr` action). `maintainer_can_modify` is always false and cannot be set:
/// no maintainer of the base repository gets push rights to the engine's `brahma/` branch.
public struct OpenPullRequest: Equatable, Sendable, Encodable {
    public var title: String
    /// The engine's branch, `brahma/<KEY>-<slug>` (same repository, so no `owner:` prefix).
    public var head: String
    /// The repository's default branch, read fresh (`RepoInfo.defaultBranch`).
    public var base: String
    /// `PRBody.render`'s text.
    public var body: String
    public let maintainerCanModify = false

    public init(title: String, head: String, base: String, body: String) {
        self.title = title; self.head = head; self.base = base; self.body = body
    }

    private enum CodingKeys: String, CodingKey {
        case title, head, base, body, maintainerCanModify = "maintainer_can_modify"
    }
}

/// How a GitHub call failed when GitHub itself answered. Any other error a `GitHubAPI` throws (a lost connection, a timeout, a
/// crash mid-call) leaves the outcome unknown: the engine reconciles by reading back, never by sending again blind.
public enum GitHubAPIError: Error, Equatable, Sendable {
    /// GitHub answered with a client error (4xx: validation, not found, forbidden): the call had no effect. A 5xx is not this:
    /// the server may have acted before failing, so a conformer throws something else and the outcome is unknown.
    case rejected(status: Int, message: String)
}
