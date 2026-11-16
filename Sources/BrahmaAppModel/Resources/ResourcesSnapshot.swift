import Foundation
import BrahmaCore

/// Work › Resources for the selected company, read off-main with the snapshot: every resource by number, purged tombstones
/// included (a folder's files follow it).
public enum ResourcesSnapshot {
    public static func load(store: Store, companyId: String) throws -> [ResourceRow] {
        let rows = try store.resources(companyId: companyId, reader: .owner, includePurged: true)
        guard !rows.isEmpty else { return [] }
        let handles = Dictionary(try store.agents(companyId: companyId).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        let refs = Dictionary(rows.map { ($0.id, $0.ref) }, uniquingKeysWith: { a, _ in a })
        // A folder counts its live files only (one purged on its own is a tombstone).
        var live: [String: Int] = [:]
        for r in rows where r.purgedAt == nil { if let parent = r.parentId { live[parent, default: 0] += 1 } }
        var labels: [AccessClass: String] = [:]
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = store.ownerTimeZone()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return try rows.map { r in
            let scope = r.scope
            if labels[scope] == nil { labels[scope] = try store.resourceScopeLabel(scope, companyId: companyId) }
            return ResourcesPresentation.row(r, scopeLabel: labels[scope] ?? scope.label, handles: handles, liveFiles: live[r.id] ?? 0,
                                             parentRef: r.parentId.flatMap { refs[$0] }, formatter: f)
        }
    }
}
