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
    public var packId: String = "software"
    public var packVersion: Int = 1
    /// Share of the weekly allowance kept for the owner; nil means the owner-wide setting (`1 - weeklyShare`).
    public var ownerReserve: Double? = nil
}
