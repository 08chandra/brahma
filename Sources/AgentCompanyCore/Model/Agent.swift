import Foundation
import GRDB

public enum AgentState: String, Codable, Sendable { case ready, running, blocked, sleeping, killed }

public enum Blocker: Codable, Equatable, Sendable {
    case agent(String)
    case owner(reason: String)
    case usageLimit(until: Date)
    case turnBudget(until: Date)
    case retry(until: Date, failures: Int)
}

public struct Agent: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "agent"

    public var id: String
    public var companyId: String
    /// Handle: unique per company, lowercase.
    public var name: String
    public var role: String
    public var model: String
    /// UUID string.
    public var sessionId: String
    public var sessionStarted: Bool
    public var state: AgentState
    public var blocker: Blocker?
    public var requestedBlocker: Blocker?
    public var paused: Bool
    public var readySince: Date?
    public var createdAt: Date
}
