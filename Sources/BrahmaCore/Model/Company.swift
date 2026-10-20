import Foundation
import GRDB

public enum UsageMode: String, Codable, CaseIterable, Sendable { case low, balanced, max }

public enum CompanyStatus: String, Codable, Sendable { case running, paused }

public struct Company: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "company"

    public var id: String
    public var name: String
    public var slug: String
    public var goal: String
    public var workspacePath: String
    public var status: CompanyStatus
    public var usageMode: UsageMode
    public var priorityWeight: Int
    public var createdAt: Date
}
