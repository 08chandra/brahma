import Foundation
import GRDB

/// Where one item's PR landing is (Plan X8). Written by the engine's PR step; the item's merge request stays open until the PR
/// is merged upstream and the fetched `main` carries the pushed commit.
public enum PRLandingState: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case pushing, pushed, opening, open, checksFailed, changesRequested, mergeable, merging, merged, closedUpstream, abandoned

    /// Still being watched: not yet merged, closed upstream or abandoned.
    public var isOpen: Bool { !Self.closed.contains(self) }

    static let closed: Set<PRLandingState> = [.merged, .closedUpstream, .abandoned]
}

/// One item's pull request on GitHub, table `prLanding` (`"vX5-pr"`). One row per item: a resubmit updates it.
public struct PRLanding: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "prLanding"

    public var itemId: String
    public var companyId: String
    /// `brahma/<KEY>`.
    public var branch: String
    /// The verified commit the engine pushed (rebased onto the recorded `main`, secret-scanned).
    public var pushedSHA: String
    public var prNumber: Int? = nil
    public var prURL: String? = nil
    public var state: PRLandingState
    public var lastPolled: Date? = nil
    public var lastError: String? = nil
    /// The merge commit (or `pushedSHA` for a rebase merge) once GitHub reports the PR merged.
    public var mergedSHA: String? = nil
    public var updatedAt: Date
    /// `PRBody.contentDigest` of the title and body the engine sent with its `open-pr` (`"vX5-pr-3"`): a PR on the branch is the
    /// engine's only when its content matches (Ruling 28). Nil until the engine has sent one.
    public var openDigest: String? = nil

    public init(itemId: String, companyId: String, branch: String, pushedSHA: String, prNumber: Int? = nil, prURL: String? = nil,
                state: PRLandingState, lastPolled: Date? = nil, lastError: String? = nil, mergedSHA: String? = nil, updatedAt: Date,
                openDigest: String? = nil) {
        self.itemId = itemId
        self.companyId = companyId
        self.branch = branch
        self.pushedSHA = pushedSHA
        self.prNumber = prNumber
        self.prURL = prURL
        self.state = state
        self.lastPolled = lastPolled
        self.lastError = lastError
        self.mergedSHA = mergedSHA
        self.updatedAt = updatedAt
        self.openDigest = openDigest
    }
}
