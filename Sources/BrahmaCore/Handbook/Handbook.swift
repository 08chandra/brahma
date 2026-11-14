import Foundation
import GRDB

/// The company handbook's pinned numbers and engine-owned names.
public enum Handbook {
    /// A page body, in UTF-8 bytes.
    public static let maxBodyBytes = 200_000
    /// A page title, in characters.
    public static let maxTitle = 120
    /// `kb_write` sources: at most this many, each at most `maxSourceChars` once flattened to one line.
    public static let maxSources = 20
    public static let maxSourceChars = 300
    /// Pages the engine generates from live data (Task 5's `AutoPageKind` raw values). Nobody else writes these paths, whether
    /// or not the engine has made the page yet, and the skeleton leaves them to the engine.
    public static let autoPagePaths: [String] = [
        "Company/Org chart", "Company/Roster", "Decisions log", "Company/Release history", "Company/Sprint summaries",
    ]

    static func isAutoPath(_ path: String) -> Bool {
        autoPagePaths.contains { $0.lowercased() == path.lowercased() }
    }
}

public enum KBStatus: String, Codable, CaseIterable, Sendable, DatabaseValueConvertible {
    case draft, active, deprecated
}

/// Who writes a page: an agent (every rule applies), the owner (exempt from the item and lease rules) or the engine.
public enum KBAuthor: Equatable, Sendable {
    case agent(String)
    case owner
    case system

    /// As stored in `kbRevision.authorId` and `kbPage.ownerId`.
    public var id: String {
        switch self {
        case .agent(let id): id
        case .owner: "owner"
        case .system: "system"
        }
    }

    var reader: Reader {
        if case .agent(let id) = self { return .agent(id) }
        return .owner
    }
}

/// A handbook page: its current revision's title, body and status, its owner and its taint.
public struct KBPage: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "kbPage"

    public var id: String
    public var companyId: String
    /// `HandbookPath.normalize`d.
    public var path: String
    public var title: String
    /// The path's first part.
    public var section: String
    public var body: String
    /// The agent that created it, `"owner"` or `"system"`.
    public var ownerId: String
    public var status: KBStatus
    /// Set on the pages the engine generates (Task 5).
    public var autoKind: String?
    public var revision: Int
    public var lastReviewed: Date?
    public var sources: [String]
    /// A page-level restriction (role ids or `"@executive"`, any one of which satisfies it); nil: none.
    public var restriction: [String]?
    public var tainted: Bool
    public var taintReason: String?
    public var vouchedAt: Date?
    public var createdAt: Date
    public var updatedAt: Date

    public var pageRestriction: Restriction? { restriction.map(Set.init) }
}

/// One revision of a page. Revisions are only ever appended.
public struct KBRevision: Codable, Equatable, Sendable, FetchableRecord, MutablePersistableRecord {
    public static let databaseTableName = "kbRevision"

    public var id: Int64?
    public var companyId: String
    public var pageId: String
    public var number: Int
    public var title: String
    public var body: String
    public var status: KBStatus
    /// An agent id, `"owner"` or `"system"`.
    public var authorId: String
    public var itemId: String?
    public var turnId: String?
    public var summary: String?
    public var diffSummary: String
    public var tainted: Bool
    public var taintReason: String?
    /// The revision a rollback restored.
    public var rollbackOf: Int?
    public var createdAt: Date

    public mutating func didInsert(_ inserted: InsertionSuccess) { id = inserted.rowID }
}

/// A link from one section of a page to another page, with the section's restrictions: a reader sees it as a backlink only
/// when it can read both the source page and that section.
public struct KBLink: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "kbLink"

    public var companyId: String
    public var fromPageId: String
    public var sectionSlug: String
    public var toPath: String
    /// JSON `[[role]]`.
    public var restrictions: [[String]]
}

/// One page, one writer: the agent editing a page for an item, until `expiresActive` (company-active seconds).
public struct KBLease: Codable, Equatable, Sendable, FetchableRecord, PersistableRecord {
    public static let databaseTableName = "kbLease"
    /// Taken or renewed by each write to `activeNow + ttl`.
    public static let ttl: TimeInterval = 7200

    public var pageId: String
    public var companyId: String
    public var agentId: String
    public var itemId: String
    public var expiresActive: Double
}

/// A page as listed (`kbPages`, `kbRecent`).
public struct KBPageSummary: Equatable, Sendable {
    public var path: String
    public var title: String
    public var section: String
    public var status: KBStatus
    public var isAuto: Bool
    public var tainted: Bool
    public var revision: Int
    public var ownerId: String
    public var updatedAt: Date

    init(_ page: KBPage) {
        path = page.path; title = page.title; section = page.section; status = page.status; isAuto = page.autoKind != nil
        tainted = page.tainted; revision = page.revision; ownerId = page.ownerId; updatedAt = page.updatedAt
    }
}

/// A page as one reader may see it (`Store.kbRead`).
public struct KBView: Sendable {
    /// The page's metadata; its `body` is the filtered `text`, never the stored body (no field carries a hidden section).
    public var page: KBPage
    /// The revision read.
    public var revision: Int
    /// The readable sections (or the one asked for), redacted, with `_<k> restricted section(s) not shown._` when any is hidden.
    public var text: String
    public var hiddenSections: Int
    /// The paths of pages linking here that the reader may see the link in, sorted.
    public var backlinks: [String]
    /// The read revision's taint, whatever the page's is now.
    public var tainted: Bool
    public var taintReason: String?
    /// The slugs of the sections in `text`; for an old revision (whole-page readers only), every current section's.
    public var slugs: [String]
    /// When the read revision was written.
    public var revisionDate: Date
}

/// A top-level handbook section a pack starts every company with (`Store.ensureHandbookSkeleton`).
public struct HandbookSection: Codable, Equatable, Sendable {
    public var path: String
    public var title: String
    /// One line.
    public var summary: String
    /// The section page is for executives only (`restriction = ["@executive"]`).
    public var restricted: Bool = false

    public init(path: String, title: String, summary: String, restricted: Bool = false) {
        self.path = path; self.title = title; self.summary = summary; self.restricted = restricted
    }

    private enum CodingKeys: String, CodingKey { case path, title, summary, restricted }

    public init(from d: Decoder) throws {
        let c = try d.container(keyedBy: CodingKeys.self)
        path = try c.decode(String.self, forKey: .path)
        title = try c.decode(String.self, forKey: .title)
        summary = try c.decode(String.self, forKey: .summary)
        restricted = try c.decodeIfPresent(Bool.self, forKey: .restricted) ?? false
    }

    public static let softwareDefault: [HandbookSection] = [
        HandbookSection(path: "Company", title: "Company", summary: "Mission, goals, the org and how we work together."),
        HandbookSection(path: "Product", title: "Product", summary: "What we build, for whom and why: briefs, roadmaps and user insight."),
        HandbookSection(path: "Engineering", title: "Engineering", summary: "Architecture, conventions, runbooks and how we ship."),
        HandbookSection(path: "Design", title: "Design", summary: "Design principles, the design system and interface decisions."),
        HandbookSection(path: "Go-to-market", title: "Go-to-market", summary: "Positioning, pricing, launches and customer messaging."),
        HandbookSection(path: "Operations", title: "Operations", summary: "Environments, deploys, on-call and incident notes."),
        HandbookSection(path: "Research", title: "Research", summary: "Cited research reports on markets, competitors, users and technology."),
        HandbookSection(path: "Decisions log", title: "Decisions log", summary: "Every decided ask, newest first, kept current by the engine."),
        HandbookSection(path: "Meeting notes", title: "Meeting notes", summary: "Standups, retros and meeting summaries."),
    ]
}
