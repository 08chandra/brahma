import Foundation
import GRDB

/// How a company's approved items reach `main` (Plan X8). `local`: the merge queue fast-forwards the workspace's `main` itself.
/// `pr`: the queue pushes the verified commit to a `brahma/<KEY>` branch on GitHub and opens a pull request; `main` moves only
/// when that PR is merged there. Stored on `company.landing`; changed only through `Store.setLanding`.
public enum LandingMode: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case local, pr

    /// The channel actions a github channel must be granted before PR mode can be switched on.
    public static let requiredActionTypes: Set<String> = ["push-branch", "open-pr", "comment"]
    /// The further action `--engine-merge` needs: the engine merges a mergeable PR itself.
    public static let engineMergeActionType = "merge-pr"

    /// What `brahma company landing <co> pr` says while no connected github channel grants the required actions.
    public static let needsChannelText = "PR mode needs a github channel with a grant for push-branch (brahma/), open-pr and comment; "
        + "see brahma accounts grant"
    /// What `--engine-merge` says without a `merge-pr` grant.
    public static let needsMergeGrantText = "--engine-merge needs a grant for \(engineMergeActionType); see brahma accounts grant"
}

/// What the owner's github channel allows the engine to do for one company, as the landing switch reads it.
public struct LandingGrantStatus: Sendable, Equatable {
    /// A github channel is connected for the company.
    public var channelConnected: Bool
    /// The channel action types the owner has granted (`push-branch`, `open-pr`, `comment`, `merge-pr`, ...).
    public var grantedActions: Set<String>
    /// The engine-held push token (`LandingSwitch.tokenSecretName`) is recorded; decided from the secret's metadata, never its value.
    public var tokenPresent: Bool

    public init(channelConnected: Bool, grantedActions: Set<String>, tokenPresent: Bool) {
        self.channelConnected = channelConnected
        self.grantedActions = grantedActions
        self.tokenPresent = tokenPresent
    }
}

/// The seam a channel core (Plan X4) fills in: the landing switch asks it, never a channel table of its own.
public protocol LandingGrantChecking: Sendable {
    func status(companyId: String) throws -> LandingGrantStatus
}

/// This tree has no github channel and no grants for channel actions: nothing is connected, nothing is granted, and only the
/// token's presence is reported. PR mode therefore fails closed until a channel core replaces this checker.
public struct NoChannelGrantChecker: LandingGrantChecking {
    let store: Store

    public init(store: Store) { self.store = store }

    public func status(companyId: String) throws -> LandingGrantStatus {
        let token = try store.secrets(companyId: companyId).contains { $0.name == LandingSwitch.tokenSecretName }
        return LandingGrantStatus(channelConnected: false, grantedActions: [], tokenPresent: token)
    }
}

/// The owner's switch between landing modes (`brahma company landing`). `local` always succeeds and abandons nothing: open PR
/// landings keep polling until merged or closed by the owner. `pr` needs a connected github channel granting
/// `LandingMode.requiredActionTypes` and the push token; `engineMerge` also needs `LandingMode.engineMergeActionType`.
public enum LandingSwitch {
    /// The engine-held, company-scoped secret the push reads (`brahma secret set <co> GITHUB_PUSH_TOKEN`).
    public static let tokenSecretName = "GITHUB_PUSH_TOKEN"

    /// Why the switch to `mode` is refused under `status`, or nil when it is allowed.
    public static func refusal(mode: LandingMode, engineMerge: Bool, status: LandingGrantStatus) -> String? {
        guard mode == .pr else { return nil }
        guard status.channelConnected, LandingMode.requiredActionTypes.isSubset(of: status.grantedActions), status.tokenPresent else {
            return LandingMode.needsChannelText
        }
        if engineMerge, !status.grantedActions.contains(LandingMode.engineMergeActionType) { return LandingMode.needsMergeGrantText }
        return nil
    }

    /// Checks the grants, then records the mode. Returns the status it decided on. Throws `WorkError.forbidden` with the
    /// refusal text; the mode is unchanged then.
    @discardableResult
    public static func apply(_ mode: LandingMode, engineMerge: Bool, companyId: String, store: Store,
                             checker: any LandingGrantChecking, now: Date = Store.now()) throws -> LandingGrantStatus {
        let status = try checker.status(companyId: companyId)
        if let why = refusal(mode: mode, engineMerge: engineMerge, status: status) { throw WorkError.forbidden(why) }
        try store.setLanding(mode, engineMerge: mode == .pr && engineMerge, companyId: companyId, now: now)
        return status
    }
}
