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
    /// `PRActionDigest.of` the request the card showed (`"vX5-pr-3"`, Rulings X8-21 and 29): the approval answers only a request
    /// with exactly this digest.
    public var digest: String = ""

    public init(askId: String, companyId: String, itemId: String, action: String, sha: String, reason: String, approvedAt: Date? = nil,
                consumedAt: Date? = nil, createdAt: Date, digest: String) {
        self.askId = askId; self.companyId = companyId; self.itemId = itemId; self.action = action; self.sha = sha
        self.reason = reason; self.approvedAt = approvedAt; self.consumedAt = consumedAt; self.createdAt = createdAt; self.digest = digest
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
    /// The owner approved the card whose request had `digest`: an attempt whose request has exactly that digest runs even
    /// though the gate asks (never when it refuses); any other is asked again on a fresh card.
    case approved(askId: String, digest: String)
    /// The owner declined: nothing runs for this sha.
    case declined(reason: String)
}

/// The digest an owner card binds its approval to (Rulings X8-21 and 29): the canonical request the owner saw — the action,
/// the item, the commit, the ref (the head for `open-pr`), the base, the PR title and body (digested), every fact the gate
/// decides on (visibility, taint, external input, first use, `.github/workflows/`) and the reason it asked. Any change to any
/// of it is a different request: a fresh card.
public enum PRActionDigest {
    struct Canonical: Encodable {
        var action: String
        var itemId: String
        var companyId: String
        var sha: String
        var ref: String
        var base: String
        var content: String
        var repoVisibility: String
        var taintedSession: Bool
        var itemTainted: Bool
        var externalInput: Bool
        var firstUse: Bool
        var touchesWorkflows: String
        var reason: String
    }

    /// For `push-branch` the commit and ref come from the request's payload; for `open-pr`, from `open` and `sha`.
    public static func of(_ r: PRActionRequest, reason: String, sha: String, open: OpenPullRequest?) -> String {
        let ref = open.map { PRBranch.ref($0.head) } ?? r.payload.map(\.ref) ?? "-"
        let canonical = Canonical(action: r.type.name, itemId: r.itemId, companyId: r.companyId, sha: r.payload.map(\.sha) ?? sha, ref: ref,
                                  base: open.map(\.base) ?? "-", content: open.map { PRBody.contentDigest(title: $0.title, body: $0.body) } ?? "-",
                                  repoVisibility: r.repoVisibility, taintedSession: r.taintedSession, itemTainted: r.itemTainted,
                                  externalInput: r.externalInput, firstUse: r.firstUse,
                                  touchesWorkflows: r.payload.map { $0.touchesWorkflows ? "yes" : "no" } ?? "-", reason: reason)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        do { return PRBody.hex(SHA256.hash(try encoder.encode(canonical))) } catch {
            // A plain struct of strings and booleans always encodes; if it ever did not, no approval could match it.
            return "unencodable:\(UUID().uuidString)"
        }
    }
}
