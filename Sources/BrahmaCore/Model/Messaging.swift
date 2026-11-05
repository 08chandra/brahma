import Foundation
import GRDB

public enum ChannelKind: String, Codable, Sendable { case channel, dm }

public struct Channel: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "channel"

    public var id: String
    public var companyId: String
    /// "general", or "dm:<a>:<b>" with sorted handles.
    public var name: String
    public var kind: ChannelKind
    public var createdAt: Date
}

/// Member is an agent id or the literal "owner".
struct ChannelMember: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "channelMember"
    var channelId: String
    var member: String
}

public enum Sender: Equatable, Sendable {
    case owner
    case agent(String)
    /// The engine itself (notices). Channel posts from it never wake anyone; it needs no membership.
    case system

    var id: String {
        switch self {
        case .owner: "owner"
        case .system: "system"
        case .agent(let id): id
        }
    }
}

public struct Message: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "message"

    public var id: String
    public var companyId: String
    public var channelId: String
    /// Agent id or "owner".
    public var senderId: String
    public var text: String
    public var createdAt: Date
    /// Set by the router (Task 10): `impersonation` when an agent's text claims to be the owner (`OwnerImpersonation`).
    public var flag: String? = nil
    /// Written by a session that had read outside content (Task 10 fix round 1, I2): shown as untrusted, and it taints its reader.
    public var taintedOrigin: Bool = false
}

public struct InboxItem: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "inboxItem"

    public var id: Int64?
    public var agentId: String
    public var messageId: String
    public var deliveredTurnId: String?
    /// False for channel traffic not addressed to the recipient: it is counted, not delivered, and never wakes.
    public var wakes: Bool = true
}
