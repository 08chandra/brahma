import Foundation

/// One GitHub action the engine wants to take for an item (the stand-in for X4's `ActionRequest`, Ruling 1). Filed only after
/// the engine's own checks passed (for a push: `PrePushScan`).
public struct PRActionRequest: Equatable, Sendable {
    public var type: GitHubActionType
    public var companyId: String
    public var itemId: String
    /// For `push-branch`: what is pushed (the owner's card shows `diffstat` and `paths`).
    public var payload: PushPayload?
    /// The session that produced the change is tainted.
    public var taintedSession: Bool
    /// The item came from outside (an untrusted issue) or a tainted writer (`workItem.taintedOrigin`).
    public var itemTainted: Bool
    /// The action carries text from outside (an issue body, review text).
    public var externalInput: Bool
    /// No action of this type of the company is known to have reached GitHub yet (`GitHubRules.firstPushAsks`).
    public var firstUse: Bool
    /// The repository's visibility, read fresh from `GitHubAPI.repo` for this action (never the value seen at connect time).
    public var repoVisibility: String

    public init(type: GitHubActionType, companyId: String, itemId: String, payload: PushPayload? = nil, taintedSession: Bool,
                itemTainted: Bool, externalInput: Bool, firstUse: Bool, repoVisibility: String) {
        self.type = type; self.companyId = companyId; self.itemId = itemId; self.payload = payload
        self.taintedSession = taintedSession; self.itemTainted = itemTainted; self.externalInput = externalInput
        self.firstUse = firstUse; self.repoVisibility = repoVisibility
    }
}

/// What the gate decided: run it now, ask the owner first, or never.
public enum PRActionDecision: Equatable, Sendable {
    case auto
    case ask(reason: String)
    case refuse(rule: String)
}

/// The one decision path for GitHub actions. Its only production conformer is `NoChannelGate`; a channel core (Plan X4) replaces
/// it with its policy, applying `GitHubRules` in its §8.4.5 order.
public protocol PRActionGate: Sendable {
    func decide(_ r: PRActionRequest) async -> PRActionDecision
}

/// This tree has no channel core: every GitHub action is refused, so nothing reaches GitHub.
public struct NoChannelGate: PRActionGate {
    public init() {}
    public func decide(_ r: PRActionRequest) async -> PRActionDecision { .refuse(rule: LandingMode.needsChannelText) }
}

/// The github channel's own rules (spec §9.3.4; grants can only narrow them), as pure functions so X4's policy lifts them
/// unchanged. Each returns why the action must be an owner ask, or nil.
public enum GitHubRules {
    /// The company's first push asks (X4 rule 2).
    public static func firstPushAsks(_ r: PRActionRequest) -> String? {
        r.type == .pushBranch && r.firstUse ? "the company's first push to GitHub asks you first" : nil
    }

    /// Anything tainted asks (X4 rule 3): the session, the item or the input came from outside.
    public static func taintedAsks(_ r: PRActionRequest) -> String? {
        guard r.taintedSession || r.itemTainted || r.externalInput else { return nil }
        return "this change comes from tainted input (\([r.taintedSession ? "the session" : nil, r.itemTainted ? "the item" : nil, r.externalInput ? "external text" : nil].compactMap { $0 }.joined(separator: ", ")))"
    }

    /// A push to a repository that is not private asks (rule 5); `visibility` is read fresh for each push.
    public static func publicRepoPushAsks(visibility: String) -> String? {
        visibility == "private" ? nil : "the repository is \(visibility.isEmpty ? "of unknown visibility" : visibility), not private"
    }

    /// A change under `.github/workflows/` always asks (rule 5): workflows run with the repository's secrets.
    public static func workflowsPathAsks(payload: PushPayload) -> String? {
        payload.touchesWorkflows ? "the change touches .github/workflows/, which runs with the repository's secrets" : nil
    }

    /// Merging is irreversible (spec §8.4.5 rule 4): it always asks the owner — with `--engine-merge` and a `merge-pr` grant
    /// too; the grant only lets the engine file the request at all. The landing machine enforces it itself as well: it never
    /// presses merge without the owner's approval of exactly that request, whatever a gate answers.
    public static func mergePRAlwaysAsks(_ type: GitHubActionType) -> String? {
        type.reversible ? nil : irreversibleMergeText
    }

    /// Why a merge asks.
    public static let irreversibleMergeText = "merging a pull request cannot be undone"
}
