import Foundation
import BrahmaCore

/// One node of the Handbook tree: a page, or a placeholder for a path part that has pages under it but none of its own.
/// Titles and paths may be agent-written and are rendered verbatim.
public struct HandbookNode: Equatable, Identifiable, Sendable {
    public var path: String
    public var title: String
    /// `AUTO`, `DRAFT`, `DEPRECATED`, `TAINTED`, in that order (a placeholder has none).
    public var chips: [String]
    /// False for a placeholder (no page at this path).
    public var isPage: Bool
    public var children: [HandbookNode]

    public var id: String { path.lowercased() }

    public init(path: String, title: String, chips: [String] = [], isPage: Bool = true, children: [HandbookNode] = []) {
        self.path = path; self.title = title; self.chips = chips; self.isPage = isPage; self.children = children
    }
}

/// A tree node with its depth, in display order.
public struct HandbookTreeRow: Equatable, Identifiable, Sendable {
    public var node: HandbookNode
    public var depth: Int
    public var id: String { node.id }
}

/// The Handbook's left-hand tree.
public enum HandbookTree {
    /// The pages as a tree: the pack's sections first, in the pack's order, then any other top-level section alphabetically;
    /// children sorted by title. A page under a path with no page of its own hangs under a placeholder node.
    public static func make(pages: [KBPageSummary], pack: IndustryPack) -> [HandbookNode] {
        make(pages: pages, sections: pack.handbook)
    }

    public static func make(pages: [KBPageSummary], sections: [HandbookSection]) -> [HandbookNode] {
        // Every page and every ancestor path, keyed case-insensitively (paths are unique without case).
        var nodes: [String: HandbookNode] = [:]
        var childKeys: [String: Set<String>] = [:]
        var roots = Set<String>()
        for page in pages {
            let key = page.path.lowercased()
            nodes[key] = HandbookNode(path: page.path, title: page.title, chips: chips(page))
            let parts = page.path.split(separator: "/").map(String.init)
            for depth in 0..<parts.count {
                let path = parts[0...depth].joined(separator: "/")
                let k = path.lowercased()
                if nodes[k] == nil { nodes[k] = HandbookNode(path: path, title: parts[depth], isPage: false) }
                if depth == 0 {
                    roots.insert(k)
                } else {
                    childKeys[parts[0..<depth].joined(separator: "/").lowercased(), default: []].insert(k)
                }
            }
        }
        func byTitle(_ a: HandbookNode, _ b: HandbookNode) -> Bool {
            let (x, y) = (a.title.lowercased(), b.title.lowercased())
            return x != y ? x < y : a.path < b.path
        }
        func build(_ key: String) -> HandbookNode {
            var node = nodes[key]!
            node.children = (childKeys[key] ?? []).map(build).sorted(by: byTitle)
            return node
        }
        var order: [String: Int] = [:]
        for (i, s) in sections.enumerated() where order[s.path.lowercased()] == nil { order[s.path.lowercased()] = i }
        return roots.map(build).sorted { a, b in
            let (x, y) = (order[a.id] ?? Int.max, order[b.id] ?? Int.max)
            return x != y ? x < y : byTitle(a, b)
        }
    }

    /// The tree flattened in display order, every node expanded.
    public static func rows(_ nodes: [HandbookNode], depth: Int = 0) -> [HandbookTreeRow] {
        nodes.flatMap { [HandbookTreeRow(node: $0, depth: depth)] + rows($0.children, depth: depth + 1) }
    }

    static func chips(_ page: KBPageSummary) -> [String] {
        var out: [String] = []
        if page.isAuto { out.append("AUTO") }
        switch page.status {
        case .draft: out.append("DRAFT")
        case .deprecated: out.append("DEPRECATED")
        case .active: break
        }
        if page.tainted { out.append("TAINTED") }
        return out
    }
}

/// One section of a page as the owner reads it: its heading (without the restriction marker), the `RESTRICTED · <roles>`
/// chip when any heading above it (or its own) restricts it, and its own Markdown text (rendered through `SafeMarkdown`).
public struct KBBlock: Equatable, Identifiable, Sendable {
    public var id: String
    /// Nil for the text before the first heading.
    public var heading: String?
    public var level: Int
    public var restrictedChip: String?
    public var markdown: String
}

public enum HandbookPresentation {
    /// `RESTRICTED · <roles>`: each restriction's roles (any one satisfies it) sorted and comma-joined, `@executive` shown as
    /// `executive`; nested restrictions (all must hold) joined with ` + `. Nil when there is none.
    public static func restrictedChip(_ restrictions: [Restriction]) -> String? {
        let parts = restrictions.filter { !$0.isEmpty }.map { set in
            set.map { $0 == "@executive" ? "executive" : $0 }.sorted().joined(separator: ", ")
        }
        return parts.isEmpty ? nil : "RESTRICTED · " + parts.joined(separator: " + ")
    }

    /// The page's sections as the owner sees them. The page-level restriction is the header's chip, not every section's.
    public static func blocks(_ text: String) -> [KBBlock] {
        KBMarkdown.sections(text, page: nil).compactMap { s in
            if s.heading == nil, s.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return nil }
            return KBBlock(id: s.slug, heading: s.heading, level: s.level, restrictedChip: restrictedChip(s.restrictions),
                           markdown: s.text.trimmingCharacters(in: .newlines))
        }
    }

    /// `kb:<path> · REV <n> · @<owner> · UPDATED <yyyy-MM-dd HH:mm>` (the revision read, in the owner's zone).
    public static func header(_ view: KBView, handles: [String: String], timeZone: TimeZone) -> String {
        "kb:\(view.page.path) · REV \(view.revision) · @\(who(view.page.ownerId, handles)) · UPDATED \(timestamp(view.revisionDate, timeZone))"
    }

    /// A revision menu line: `REV <n> · +a −r lines · @<author> · <yyyy-MM-dd HH:mm>` (+ ` · ROLLBACK OF <m>`, ` · TAINTED`).
    public static func revisionLabel(_ r: KBRevision, handles: [String: String], timeZone: TimeZone) -> String {
        var line = "REV \(r.number) · \(r.diffSummary) · @\(who(r.authorId, handles)) · \(timestamp(r.createdAt, timeZone))"
        if let of = r.rollbackOf { line += " · ROLLBACK OF \(of)" }
        if r.tainted { line += " · TAINTED" }
        return line
    }

    /// A page as listed in RECENTLY CHANGED: `<yyyy-MM-dd HH:mm> · REV <n>`.
    public static func recentLine(_ p: KBPageSummary, timeZone: TimeZone) -> String {
        "\(timestamp(p.updatedAt, timeZone)) · REV \(p.revision)"
    }

    /// An agent's handle, `owner` or `system`.
    static func who(_ id: String, _ handles: [String: String]) -> String {
        if let h = handles[id] { return h }
        return id == "owner" || id == "system" ? id : "unknown"
    }

    public static func timestamp(_ date: Date, _ timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }

    /// `kb:<path>#<section>` → `<path>`.
    public static func path(ofRef ref: String) -> String {
        var s = ref
        if s.lowercased().hasPrefix("kb:") { s = String(s.dropFirst(3)) }
        if let hash = s.firstIndex(of: "#") { s = String(s[..<hash]) }
        return s
    }
}
