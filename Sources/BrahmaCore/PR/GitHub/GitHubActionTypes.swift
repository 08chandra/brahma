import Foundation

/// How much an action changes the outside world (X4's risk classes, as far as GitHub needs them).
public enum GitHubRiskClass: String, Codable, Sendable {
    case read, modify
}

/// What the engine may do on GitHub for a company in PR mode (spec §8.5.1, §9.3.4). `name` is the action type a channel grant
/// names (`LandingMode.requiredActionTypes`, `LandingMode.engineMergeActionType`). The engine never deletes a branch, never
/// force-pushes and never touches protection, settings, secrets or workflows: there is no action type for any of that.
public enum GitHubActionType: Hashable, Codable, Sendable {
    /// Push the verified commit to `brahma/<KEY>-<slug>`. Reversible: the owner can delete a branch the engine created (the engine
    /// itself never deletes one).
    case pushBranch
    /// Open the item's pull request. Reversible: it can be closed.
    case openPR
    /// Press merge on a mergeable PR (`--engine-merge` only). Irreversible: `main` moves upstream.
    case mergePR
    /// A status comment on the PR or the linked issue.
    case comment
    /// A read: PR status (checks, reviews, mergeability), issues, the repository's settings.
    case read(ReadSubtype)

    public enum ReadSubtype: String, Codable, Sendable, CaseIterable {
        case prStatus, issues, repo
    }

    public static let all: [GitHubActionType] = [.pushBranch, .openPR, .mergePR, .comment] + ReadSubtype.allCases.map { .read($0) }

    /// The action type a grant names.
    public var name: String {
        switch self {
        case .pushBranch: "push-branch"
        case .openPR: "open-pr"
        case .mergePR: LandingMode.engineMergeActionType
        case .comment: "comment"
        case .read: "read"
        }
    }

    public var riskClass: GitHubRiskClass {
        switch self {
        case .read: .read
        case .pushBranch, .openPR, .mergePR, .comment: .modify
        }
    }

    /// Whether the owner can undo it. Only `mergePR` cannot be: `GitHubRules.mergePRAlwaysAsks`.
    public var reversible: Bool { self != .mergePR }
}
