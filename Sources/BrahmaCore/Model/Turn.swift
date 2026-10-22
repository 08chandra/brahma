import Foundation
import GRDB

public enum TurnOutcome: String, Codable, Sendable { case inProgress, succeeded, failed, usageLimited, interrupted }

public struct Turn: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "turn"

    public var id: String
    public var agentId: String
    public var companyId: String
    public var startedAt: Date
    public var endedAt: Date?
    public var outcome: TurnOutcome
    public var summary: String?
    public var costUSD: Double?
    /// True when the turn failed for infrastructure reasons (network, account); never counted against the agent.
    public var infra: Bool = false
}

public enum ActivityKind: String, Codable, Sendable { case stateChanged, message, toolUse, turnStarted, turnFinished, usage, error, work }

public struct ActivityEvent: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "activityEvent"

    public var id: Int64?
    public var companyId: String
    public var agentId: String?
    public var turnId: String?
    public var kind: ActivityKind
    public var text: String
    public var createdAt: Date

    public init(id: Int64? = nil, companyId: String, agentId: String?, turnId: String?, kind: ActivityKind, text: String, createdAt: Date) {
        self.id = id; self.companyId = companyId; self.agentId = agentId; self.turnId = turnId
        self.kind = kind; self.text = text; self.createdAt = createdAt
    }
}
