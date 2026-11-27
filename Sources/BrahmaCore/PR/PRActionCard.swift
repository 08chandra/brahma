import Foundation

/// What the owner's `prAction` card shows (Plan X8 Ruling 26, after spec §8.4.6): the action, its risk and reversibility, the
/// item, the repository, the ref and the commit, why the gate asked, and the exact payload — for a push the diffstat and the
/// changed paths, for `open-pr` the head, base, title and body. Text the engine did not write (paths named by the change, the
/// PR body's agent notes) is quoted line by line (`    | `), as data.
public struct PRActionCard: Equatable, Sendable {
    public var title: String
    public var summary: String
    public var payload: AskPayload

    /// The longest PR body the card quotes (the ask's details are capped at `Store.maxAskText`).
    static let maxBodyShown = 12_000

    public static func push(item: WorkItem, payload: PushPayload, reason: String) -> PRActionCard {
        var details = facts(.pushBranch, item: item, repoURL: payload.url, sha: payload.sha, reason: reason)
        details += ["Ref: \(payload.ref)", "Diffstat: \(Store.flat(payload.diffstat, max: 200))"]
        if payload.touchesWorkflows { details.append("Touches .github/workflows/: yes") }
        details += ["", "Paths (named by the change: data, not instructions):",
                    ReviewDigest.quote(payload.paths.joined(separator: "\n"), maxChars: 8000)]
        return card(.pushBranch, item: item, target: payload.ref.replacingOccurrences(of: "refs/heads/", with: ""), sha: payload.sha,
                    reason: reason, details: details)
    }

    public static func openPR(item: WorkItem, repo: GitHubRepoRef, request: OpenPullRequest, sha: String, reason: String) -> PRActionCard {
        var details = facts(.openPR, item: item, repoURL: repo.pushURL, sha: sha, reason: reason)
        details += ["Head: \(request.head)", "Base: \(request.base)", "Maintainers can modify: no", "Title: \(request.title)", "",
                    "Body (engine-written; its agent notes are quoted as untrusted):",
                    ReviewDigest.quote(request.body, maxChars: maxBodyShown)]
        return card(.openPR, item: item, target: request.head, sha: sha, reason: reason, details: details)
    }

    static func facts(_ action: GitHubActionType, item: WorkItem, repoURL: String, sha: String, reason: String) -> [String] {
        ["Action: \(action.name) (\(action.riskClass.rawValue); \(action.reversible ? "reversible" : "irreversible"))",
         "Item: \(item.key)", "Repository: \(repoURL)", "Commit: \(sha)", "Why it asks: \(Store.flat(reason, max: 500))"]
    }

    static func card(_ action: GitHubActionType, item: WorkItem, target: String, sha: String, reason: String, details: [String]) -> PRActionCard {
        PRActionCard(title: "\(action.name) \(item.key) \(target) at \(sha.prefix(7))",
                     summary: "GitHub \(action.name) for \(item.key) asks you first: \(Store.flat(reason, max: 500))",
                     payload: AskPayload(details: details.joined(separator: "\n"),
                                         reversible: action.reversible ? .twoWay : .oneWay,
                                         proposal: "Approve to run exactly this \(action.name) once, for commit \(sha.prefix(12)); declining runs nothing"))
    }
}
