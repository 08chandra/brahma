import Foundation

/// One check run on a commit, as the engine reads it (`GET /repos/{o}/{r}/commits/{sha}/check-runs`, every page). Its name and
/// output are written by whatever runs the check (often a workflow the agent changed): EXTERNAL text (`PRFeedback`).
public struct GitHubCheckRun: Equatable, Sendable {
    public var name: String
    /// `head_sha`.
    public var headSHA: String
    /// `queued`, `in_progress`, `completed` (newer: `waiting`, `requested`, `pending`).
    public var status: String
    /// `success`, `failure`, `neutral`, `cancelled`, `skipped`, `timed_out`, `action_required`, `stale`, `startup_failure`, or
    /// nil while it runs.
    public var conclusion: String?
    /// `output.title`, `output.summary`, `output.text` (null reads as empty).
    public var title: String
    public var summary: String
    public var text: String

    public init(name: String, headSHA: String, status: String, conclusion: String?, title: String, summary: String, text: String) {
        self.name = name; self.headSHA = headSHA; self.status = status; self.conclusion = conclusion
        self.title = title; self.summary = summary; self.text = text
    }

    /// Concluded in a way that brings the item back (Plan X8 Task 4): `failure`, `timed_out`, `cancelled`, `action_required`.
    public var isFailing: Bool {
        guard let conclusion else { return false }
        return PRFeedback.failingConclusions.contains(conclusion)
    }

    /// Done and not in the way: `success`, `neutral`, `skipped`.
    public var isGreen: Bool { status == "completed" && ["success", "neutral", "skipped"].contains(conclusion ?? "") }
}

/// A GitHub account as a review names it (`user`).
public struct GitHubUser: Equatable, Sendable {
    public var login: String
    public init(login: String) { self.login = login }
}

/// One review of a pull request (`GET /repos/{o}/{r}/pulls/{n}/reviews`, every page, oldest first).
public struct GitHubReview: Equatable, Sendable {
    public var id: Int
    public var user: GitHubUser
    /// `APPROVED`, `CHANGES_REQUESTED`, `COMMENTED`, `DISMISSED`, `PENDING`.
    public var state: String
    /// Null reads as empty.
    public var body: String
    /// `commit_id`: the head the review was made on.
    public var commitId: String

    public init(id: Int, user: GitHubUser, state: String, body: String, commitId: String) {
        self.id = id; self.user = user; self.state = state; self.body = body; self.commitId = commitId
    }
}
