import Foundation
import GRDB

/// One owner card for a GitHub action the gate asked about, and the one-shot approval it may become (Plan X8 Ruling 26), table
/// `prActionApproval` (`"vX5-pr-2"`). A row is written when the engine files the `prAction` card; the owner's approval
/// (`Store.ownerDecide`, decided by the owner) sets `approvedAt`; the landing machine consumes it once, when the approved action
/// reached GitHub (`consumedAt`). It is bound to exactly one (company, item, action, sha): a resubmitted item (a new sha) needs a
/// new card. An approval never overrides the gate's `refuse`. No agent tool reads or writes this table.
public struct PRActionApproval: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "prActionApproval"

    /// The `prAction` card.
    public var askId: String
    public var companyId: String
    public var itemId: String
    /// `GitHubActionType.name`: `push-branch`, `open-pr`, `merge-pr`.
    public var action: String
    /// The verified commit the action is for.
    public var sha: String
    /// Why the gate asked (shown on the card and in the landing's `lastError`).
    public var reason: String
    public var approvedAt: Date? = nil
    public var consumedAt: Date? = nil
    public var createdAt: Date

    public init(askId: String, companyId: String, itemId: String, action: String, sha: String, reason: String, approvedAt: Date? = nil,
                consumedAt: Date? = nil, createdAt: Date) {
        self.askId = askId; self.companyId = companyId; self.itemId = itemId; self.action = action; self.sha = sha
        self.reason = reason; self.approvedAt = approvedAt; self.consumedAt = consumedAt; self.createdAt = createdAt
    }

    /// Approved by the owner and not yet used.
    public var isUsable: Bool { approvedAt != nil && consumedAt == nil }
}

/// Where the card for one (item, action, sha) stands, as the landing machine reads it.
public enum PRActionCardState: Equatable, Sendable {
    /// No card: ask the gate (and file one if it asks).
    case none
    /// The owner has not decided yet.
    case waiting(reason: String)
    /// The owner approved: the next attempt runs even though the gate would ask (never when it refuses).
    case approved(askId: String)
    /// The owner declined: nothing runs for this sha.
    case declined(reason: String)
}
