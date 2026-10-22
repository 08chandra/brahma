import Foundation
import GRDB

private struct UsageStateRow: Codable, FetchableRecord, PersistableRecord {
    static let databaseTableName = "usageState"
    var id: Int = 1
    var status: String
    var resetsAt: Date?
    var rateLimitType: String?
    var isUsingOverage: Bool
    var fiveHourUtilization: Double?
    var sevenDayUtilization: Double?
    var observedAt: Date
    var fiveHourResetsAt: Date?
    var sevenDayResetsAt: Date?
}

extension Store {
    /// Single-row table: the latest observed rate-limit state replaces the previous one.
    public func saveRateLimit(_ info: RateLimitInfo) throws {
        let row = UsageStateRow(
            status: info.status, resetsAt: info.resetsAt, rateLimitType: info.rateLimitType,
            isUsingOverage: info.isUsingOverage, fiveHourUtilization: info.fiveHourUtilization,
            sevenDayUtilization: info.sevenDayUtilization, observedAt: info.observedAt,
            fiveHourResetsAt: info.fiveHourResetsAt, sevenDayResetsAt: info.sevenDayResetsAt)
        try writer.write { db in
            try row.save(db)
            try Store.calibrate(db, observing: info)
        }
    }

    public func latestRateLimit() throws -> RateLimitInfo? {
        try writer.read { db in try Store.latestRateLimit(db: db) }
    }

    /// In-transaction `latestRateLimit`.
    static func latestRateLimit(db: Database) throws -> RateLimitInfo? {
        try UsageStateRow.fetchOne(db, key: 1).map {
            RateLimitInfo(status: $0.status, resetsAt: $0.resetsAt, rateLimitType: $0.rateLimitType,
                          isUsingOverage: $0.isUsingOverage, fiveHourUtilization: $0.fiveHourUtilization,
                          sevenDayUtilization: $0.sevenDayUtilization, observedAt: $0.observedAt,
                          fiveHourResetsAt: $0.fiveHourResetsAt, sevenDayResetsAt: $0.sevenDayResetsAt)
        }
    }
}
