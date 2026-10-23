import Foundation
import GRDB

extension Store {
    /// How many items the company has, whatever a limited read returned (the app shows "showing N of M" when it is more).
    public func workItemCount(companyId: String) throws -> Int {
        try writer.read { db in try WorkItem.filter(Column("companyId") == companyId).fetchCount(db) }
    }

    /// The newest check run of every item of the company, by item id.
    public func latestVerifications(companyId: String) throws -> [String: VerificationRun] {
        try writer.read { db in
            let runs = try VerificationRun.fetchAll(db, sql: """
                SELECT * FROM verificationRun
                WHERE rowid IN (SELECT MAX(rowid) FROM verificationRun WHERE companyId = ? GROUP BY itemId)
                """, arguments: [companyId])
            return Dictionary(runs.map { ($0.itemId, $0) }, uniquingKeysWith: { a, _ in a })
        }
    }
}
