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
    /// How much the owner is asked (Task 11a); changing it never touches asks already waiting.
    public var autonomy: AutonomyPreset = .important
    /// The head of `refs/heads/main` the engine expects: recorded at ensureRepo, after each engine merge and when the owner
    /// accepts main. Claims and merges refuse while `main` is anything else (`Store.checkMain`).
    public var mainCommit: String? = nil
    /// The head the engine is about to move `main` to, written before the move. A crash between moving `main` and recording
    /// it leaves `main` here; the guard then accepts it and records it (`Store.checkMain`).
    public var pendingMainCommit: String? = nil
    /// Auto-approved items that landed in `main` (9c); every one is audited.
    public var autoMergeCount: Int = 0
}
