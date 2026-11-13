import Foundation
import BrahmaCore

/// Where a node sits on the chart. `<` is by `rawValue`: Board above the CEO, the CEO above the rest of the C-suite,
/// then directors, managers and individual contributors.
public enum OrgTier: Int, Comparable, Sendable {
    case board, ceo, csuite, director, manager, ic

    public static func < (l: OrgTier, r: OrgTier) -> Bool { l.rawValue < r.rawValue }

    /// CEO = a role covering "ceo"; other executives → C-suite; the pack's director role → director; other managers →
    /// manager; everything else (unknown roles included) → ic.
    public static func of(role: String, pack: IndustryPack) -> OrgTier {
        if pack.rolesCovering("ceo").contains(role) { return .ceo }
        let kind = pack.role(role)?.kind
        if kind == .executive { return .csuite }
        if role == pack.org.director { return .director }
        if kind == .manager { return .manager }
        return .ic
    }
}

extension Vacancy {
    /// A row of 3a's `orgVacancy` as the map draws it. `agentIdsByHandle` holds the non-killed agents only, so a missing
    /// or killed manager leaves `managerId` nil and the seat hangs under Board. The role title falls back to the role id
    /// when the pack does not know the role.
    public init(row: OrgVacancy, pack: IndustryPack, agentIdsByHandle: [String: String]) {
        self = Vacancy(id: row.handle, role: row.role, roleTitle: pack.role(row.role)?.title ?? row.role,
                       managerId: row.managerHandle.flatMap { agentIdsByHandle[$0] }, team: row.team, note: row.note,
                       source: .org).cleaned()
    }
}

public enum DottedLinks {
    /// Reviewer → owner for every `inProgress` or `inReview` item with an owner and a reviewer, both in `agents` and
    /// distinct. One link per (from, to, kind), keeping the numerically lowest key; sorted by (from, to) for determinism.
    public static func reviewers(items: [WorkItem], agents: Set<String>) -> [DottedLink] {
        var best: [String: DottedLink] = [:]
        for item in items where item.status == .inProgress || item.status == .inReview {
            guard let owner = item.ownerId, let reviewer = item.reviewerId, owner != reviewer,
                  agents.contains(owner), agents.contains(reviewer) else { continue }
            let link = DottedLink(from: reviewer, to: owner, kind: .reviewer, itemKey: item.key)
            let key = "\(link.from)\u{0}\(link.to)\u{0}\(link.kind.rawValue)"
            if let existing = best[key], !numericallyBefore(item.key, existing.itemKey) { continue }
            best[key] = link
        }
        return best.values.sorted { ($0.from, $0.to, $0.kind.rawValue) < ($1.from, $1.to, $1.kind.rawValue) }
    }

    static func numericallyBefore(_ a: String, _ b: String) -> Bool {
        switch a.compare(b, options: .numeric) {
        case .orderedAscending: true
        case .orderedDescending: false
        case .orderedSame: a < b
        }
    }
}

/// One node of the chart: an agent, the owner ("owner") or an open seat ("vacancy:<id>").
public struct OrgNode: Identifiable, Equatable, Sendable {
    public var id: String
    public var tier: OrgTier
    public var parentId: String?
    public var childIds: [String]
    public var depth: Int

    public init(id: String, tier: OrgTier, parentId: String?, childIds: [String], depth: Int) {
        self.id = id; self.tier = tier; self.parentId = parentId; self.childIds = childIds; self.depth = depth
    }
}

/// The reporting tree rooted at Board. Built from the agents' `managerId`s; every agent whose manager is missing,
/// killed or part of a cycle hangs under Board, so the result is always one tree reaching every node.
public struct OrgTree: Equatable, Sendable {
    static let boardId = "owner"
    /// Above this many active agents the managers start collapsed.
    public static let collapseThreshold = 60
    public static let searchLimit = 20

    public var nodes: [String: OrgNode]
    public let rootId = OrgTree.boardId
    /// DFS pre-order from Board.
    public var order: [String]

    public init(nodes: [String: OrgNode], order: [String]) { self.nodes = nodes; self.order = order }

    public static func vacancyNodeId(_ vacancyId: String) -> String { "vacancy:\(vacancyId)" }

    // MARK: Build

    public static func build(agents: [Agent], pack: IndustryPack, vacancies: [Vacancy], showFormer: Bool = false) -> OrgTree {
        var included: [String: Agent] = [:]
        for a in agents where showFormer || a.state != .killed { included[a.id] = a }
        let ids = included.keys.sorted()

        // 1. Resolve each agent's parent: its manager when that manager is included and not killed, else Board.
        var parent: [String: String] = [:]
        for id in ids {
            if let m = included[id]!.managerId, let manager = included[m], manager.state != .killed { parent[id] = m }
        }

        // 2. Break cycles. The parent map is a functional graph, so each cycle is a fixed set of agents whatever order
        //    they are visited in; its member with the smallest id loses its manager. Each agent is visited once.
        var color: [String: Int] = [:]   // nil = unvisited, 1 = on the current chain, 2 = done
        for id in ids where color[id] == nil {
            var chain: [String] = []
            var cursor: String? = id
            while let c = cursor, color[c] == nil {
                color[c] = 1
                chain.append(c)
                cursor = parent[c]
            }
            if let c = cursor, color[c] == 1, let start = chain.firstIndex(of: c) {
                let loser = chain[start...].min()!
                parent[loser] = nil
            }
            for c in chain { color[c] = 2 }
        }

        // 3. Children, in chart order.
        let rootId = boardId
        var tier: [String: OrgTier] = [rootId: .board]
        for id in ids { tier[id] = OrgTier.of(role: included[id]!.role, pack: pack) }
        var reports: [String: [String]] = [:]
        for id in ids { reports[parent[id] ?? rootId, default: []].append(id) }
        var seats: [String: [Vacancy]] = [:]
        for v in vacancies {
            let under: String
            if let m = v.managerId, let manager = included[m], manager.state != .killed { under = m } else { under = rootId }
            seats[under, default: []].append(v)
        }
        func handle(_ id: String) -> String { included[id]?.name ?? id }
        func children(of id: String) -> [String] {
            let agentKids = (reports[id] ?? []).sorted { l, r in
                let lk = (tier[l]!.rawValue, (reports[l]?.isEmpty ?? true) ? 1 : 0, handle(l), l)
                let rk = (tier[r]!.rawValue, (reports[r]?.isEmpty ?? true) ? 1 : 0, handle(r), r)
                return lk < rk
            }
            let seatKids = (seats[id] ?? []).map(\.id).sorted().map(vacancyNodeId)
            return agentKids + seatKids
        }

        // 4. DFS from Board for order and depth.
        var nodes: [String: OrgNode] = [:]
        var order: [String] = []
        var stack: [(id: String, parent: String?, depth: Int)] = [(rootId, nil, 0)]
        while let top = stack.popLast() {
            let (id, parentId, depth) = top
            let kids = children(of: id)
            nodes[id] = OrgNode(id: id, tier: tier[id] ?? .ic, parentId: parentId, childIds: kids, depth: depth)
            order.append(id)
            for k in kids.reversed() { stack.append((k, id, depth + 1)) }
        }
        return OrgTree(nodes: nodes, order: order)
    }

    // MARK: Collapse

    /// Above the threshold every manager-tier node with children starts collapsed; otherwise nothing does.
    public func defaultCollapsed(activeCount: Int) -> Set<String> {
        guard activeCount > OrgTree.collapseThreshold else { return [] }
        return Set(nodes.values.filter { $0.tier == .manager && !$0.childIds.isEmpty }.map(\.id))
    }

    /// `overrides` (true = expanded) win over `defaults`; then every ancestor of `focus` is expanded so the focused node
    /// is always reachable.
    public func collapsed(defaults: Set<String>, overrides: [String: Bool], focus: String?) -> Set<String> {
        var result = defaults
        for (id, expanded) in overrides {
            if expanded { result.remove(id) } else if nodes[id] != nil { result.insert(id) }
        }
        if let focus { for a in ancestors(focus) { result.remove(a) } }
        return result
    }

    /// The node that stands in for `id` on the chart: its topmost collapsed ancestor, or `id` itself.
    public func visibleAncestor(_ id: String, collapsed: Set<String>) -> String {
        var result = id
        for a in ancestors(id) where collapsed.contains(a) { result = a }
        return result
    }

    /// Parent, grandparent, …, Board. Empty for Board and for an unknown id.
    public func ancestors(_ id: String) -> [String] {
        var result: [String] = []
        var cursor = nodes[id]?.parentId
        while let c = cursor, result.count <= nodes.count {
            result.append(c)
            cursor = nodes[c]?.parentId
        }
        return result
    }

    /// `a`, its ancestors up to and including the lowest common ancestor, then down to `b`. Empty when either is unknown.
    public func path(_ a: String, _ b: String) -> [String] {
        guard nodes[a] != nil, nodes[b] != nil else { return [] }
        let up = [a] + ancestors(a)
        let down = [b] + ancestors(b)
        let onUp = Set(up)
        guard let lcaIndex = down.firstIndex(where: onUp.contains) else { return [] }
        let lca = down[lcaIndex]
        let toLCA = up.prefix(through: up.firstIndex(of: lca)!)
        return Array(toLCA) + down[..<lcaIndex].reversed()
    }

    // MARK: Labels and search

    /// A manager-tier node's team, uppercased then `MapText.clean`ed to 32 clusters: the one source of every team title,
    /// band label and team-card title. Nil for other nodes and for a manager without a team.
    public func teamLabel(_ id: String, agents: [String: Agent]) -> String? {
        guard nodes[id]?.tier == .manager, let team = agents[id]?.team, !team.isEmpty else { return nil }
        return MapGrouping.teamTitle(team)
    }

    /// Case-insensitive: handle-prefix matches first, then handles or roles containing the query; agent ids only, at most
    /// `searchLimit`. An empty (or blank) query gives nothing.
    public func search(_ query: String, handles: [String: String], roles: [String: String]) -> [String] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        func isAgent(_ id: String) -> Bool { id != OrgTree.boardId && !id.hasPrefix("vacancy:") }
        let candidates = handles.keys.filter(isAgent).sorted { l, r in
            let lh = handles[l]!, rh = handles[r]!
            return lh == rh ? l < r : DottedLinks.numericallyBefore(lh, rh)
        }
        var result: [String] = []
        for id in candidates where handles[id]!.lowercased().hasPrefix(q) { result.append(id) }
        let matched = Set(result)
        for id in candidates where !matched.contains(id) {
            if handles[id]!.lowercased().contains(q) || (roles[id]?.lowercased().contains(q) ?? false) { result.append(id) }
        }
        return Array(result.prefix(OrgTree.searchLimit))
    }
}
