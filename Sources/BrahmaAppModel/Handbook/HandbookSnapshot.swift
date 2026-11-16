import Foundation
import BrahmaCore

/// The Handbook's lists for one company, read off-main as the owner: every page (for the tree), the 20 most recently
/// changed, the agents' handles and the owner's zone. Nothing here is persisted (Plan ML ruling 5).
public struct HandbookSnapshot: Equatable, Sendable {
    public static let recentLimit = 20

    public var pages: [KBPageSummary]
    public var tree: [HandbookNode]
    public var recent: [KBPageSummary]
    /// Agent id → handle, plus `owner` and `system`.
    public var handles: [String: String]
    public var timeZone: TimeZone

    public static let empty = HandbookSnapshot(pages: [], tree: [], recent: [], handles: [:], timeZone: .current)

    public static func load(store: Store, companyId: String) throws -> HandbookSnapshot {
        guard let company = try store.company(id: companyId) else { throw WorkError.notFound("no such company") }
        let pages = try store.kbPages(companyId: companyId, reader: .owner)
        let sections = store.catalog.pack(company.packId)?.handbook ?? HandbookSection.softwareDefault
        var handles = Dictionary(try store.agents(companyId: companyId).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        handles["owner"] = "owner"
        handles["system"] = "system"
        return HandbookSnapshot(pages: pages, tree: HandbookTree.make(pages: pages, sections: sections),
                                recent: try store.kbRecent(companyId: companyId, reader: .owner, limit: recentLimit),
                                handles: handles, timeZone: store.ownerTimeZone())
    }
}
