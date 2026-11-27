import Foundation
import GRDB

/// A provider login (a GitHub login, a Linear email) whose issues and PR comments the owner trusts, table `trustedLogin`
/// (`"vX5-pr"`). Owner-only: no agent tool reads or writes this list.
public struct TrustedLogin: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "trustedLogin"

    public var companyId: String
    public var login: String
    /// Who added it: `owner`.
    public var addedBy: String
    public var addedAt: Date

    public init(companyId: String, login: String, addedBy: String, addedAt: Date) {
        self.companyId = companyId
        self.login = login
        self.addedBy = addedBy
        self.addedAt = addedAt
    }
}
