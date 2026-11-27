import Foundation
import GRDB

/// Where a company imports issues from.
public enum IssueProvider: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case github, linear
}

/// One company's link to an issue source, table `issueLink` (`"vX5-pr"`): at most one per provider.
public struct IssueLink: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "issueLink"

    public var companyId: String
    public var provider: IssueProvider
    /// `owner/repo` for GitHub, the team key for Linear.
    public var target: String
    /// Only issues carrying this label are imported; nil: every open issue.
    public var label: String? = nil
    /// Where the last poll stopped (an `updated_at` timestamp), nil before the first.
    public var cursor: String? = nil
    public var lastPolled: Date? = nil

    public init(companyId: String, provider: IssueProvider, target: String, label: String? = nil, cursor: String? = nil,
                lastPolled: Date? = nil) {
        self.companyId = companyId
        self.provider = provider
        self.target = target
        self.label = label
        self.cursor = cursor
        self.lastPolled = lastPolled
    }
}
