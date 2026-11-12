import Foundation
import GRDB

/// Who is reading company memory. `.concierge` is reserved for Collab: it reads like the owner, except `.secret` docs.
public enum Reader: Hashable, Codable, Sendable {
    case owner
    case agent(String)
    case concierge
}

/// Who a memory doc belongs to, stored as `accessKind` + `accessId` (`company|team|role|item|agent|channel|dm|owner`).
public enum AccessClass: Hashable, Codable, Sendable {
    case company
    case team(String)
    case role(String)
    case item(String)
    case agent(String)
    case channel(String)
    case dm(String)
    case ownerOnly

    public var kind: String {
        switch self {
        case .company: "company"
        case .team: "team"
        case .role: "role"
        case .item: "item"
        case .agent: "agent"
        case .channel: "channel"
        case .dm: "dm"
        case .ownerOnly: "owner"
        }
    }

    public var id: String? {
        switch self {
        case .company, .ownerOnly: nil
        case .team(let id), .role(let id), .item(let id), .agent(let id), .channel(let id), .dm(let id): id
        }
    }

    /// For display.
    public var label: String {
        switch self {
        case .company: "company"
        case .team(let t): "team \(t)"
        case .role(let r): "role \(r)"
        case .item(let i): "item \(i)"
        case .agent(let a): "agent \(a)"
        case .channel(let c): "channel \(c)"
        case .dm(let c): "dm \(c)"
        case .ownerOnly: "owner only"
        }
    }

    /// The stored form back; nil for an unknown kind, or a kind that needs an id without one.
    public init?(kind: String, id: String?) {
        switch kind {
        case "company": self = .company
        case "owner": self = .ownerOnly
        default:
            guard let id, !id.isEmpty else { return nil }
            switch kind {
            case "team": self = .team(id)
            case "role": self = .role(id)
            case "item": self = .item(id)
            case "agent": self = .agent(id)
            case "channel": self = .channel(id)
            case "dm": self = .dm(id)
            default: return nil
            }
        }
    }
}

public typealias MemoryScope = AccessClass

/// How sensitive a doc is, in declaration order. `secret` exists for Collab refs; ML never stores secret values.
public enum Sensitivity: String, Codable, Comparable, CaseIterable, Sendable {
    case normal
    case `internal`
    case restricted
    case hrPerf = "hr-perf"
    case secret

    private var order: Int { Self.allCases.firstIndex(of: self) ?? 0 }
    public static func < (a: Sensitivity, b: Sensitivity) -> Bool { a.order < b.order }
}

/// Role ids, or the token `"@executive"` (matches `ReaderContext.isExecutive`), any one of which satisfies it. A doc carries
/// `[Restriction]` (its page restriction plus every enclosing heading marker): every element must be satisfied.
public typealias Restriction = Set<String>

public enum AccessLevel: Sendable {
    /// Title, snippet and text.
    case full
    /// Title only (a manager over a report's private memory).
    case summary
    /// Nothing: not even that it exists.
    case none
}

/// What the access engine knows about a reader, loaded once per query (`load`). The owner's and the concierge's are empty.
public struct ReaderContext: Sendable {
    public var reader: Reader
    public var companyId: String
    public var agentId: String?
    public var team: String?
    /// The agent's role, every role its template `covers` (a merged executive holds those seats) and its `actingRole`.
    public var roles: Set<String>
    /// Its template's kind is `.executive`, or it is the acting CEO.
    public var isExecutive: Bool
    /// Channel and DM memberships.
    public var channelIds: Set<String>
    /// Items it authored, owns, leases or reviews, plus items owned by anyone in its subtree.
    public var itemIds: Set<String>
    /// Items it owns or leases now (`futureHolders` docs follow these).
    public var heldItemIds: Set<String>
    /// Its whole subtree.
    public var reportIds: Set<String>
    /// The teams of its subtree.
    public var teamsBelow: Set<String>

    public init(reader: Reader, companyId: String, agentId: String? = nil, team: String? = nil, roles: Set<String> = [],
                isExecutive: Bool = false, channelIds: Set<String> = [], itemIds: Set<String> = [],
                heldItemIds: Set<String> = [], reportIds: Set<String> = [], teamsBelow: Set<String> = []) {
        self.reader = reader; self.companyId = companyId; self.agentId = agentId; self.team = team; self.roles = roles
        self.isExecutive = isExecutive; self.channelIds = channelIds; self.itemIds = itemIds; self.heldItemIds = heldItemIds
        self.reportIds = reportIds; self.teamsBelow = teamsBelow
    }

    /// An agent of another company (or no agent at all) is refused with `forbidden("not in your company")`: the same answer
    /// either way.
    public static func load(store: Store, companyId: String, reader: Reader) throws -> ReaderContext {
        try store.writer.read { db in try load(db: db, catalog: store.catalog, companyId: companyId, reader: reader) }
    }

    static func load(db: Database, catalog: PackCatalog, companyId: String, reader: Reader) throws -> ReaderContext {
        guard case .agent(let agentId) = reader else { return ReaderContext(reader: reader, companyId: companyId) }
        guard let agent = try Agent.fetchOne(db, key: agentId), agent.companyId == companyId,
              let company = try Company.fetchOne(db, key: companyId)
        else { throw WorkError.forbidden("not in your company") }

        let template = catalog.template(role: agent.role, pack: company.packId)
        var roles: Set<String> = [agent.role]
        roles.formUnion(template.covers)
        if let acting = agent.actingRole { roles.insert(acting) }
        let isExecutive = template.kind == .executive || agent.actingRole == "ceo"

        // The subtree under the agent, over its own company's reporting lines only.
        var children: [String: [String]] = [:]
        var teamOf: [String: String] = [:]
        for row in try Row.fetchAll(db, sql: "SELECT id, managerId, team FROM agent WHERE companyId = ?", arguments: [companyId]) {
            let id: String = row["id"]
            if let manager: String = row["managerId"] { children[manager, default: []].append(id) }
            if let team: String = row["team"] { teamOf[id] = team }
        }
        var reportIds: Set<String> = []
        var queue = children[agent.id] ?? []
        while let next = queue.popLast() {
            guard next != agent.id, reportIds.insert(next).inserted else { continue }
            queue += children[next] ?? []
        }
        let teamsBelow = Set(reportIds.compactMap { teamOf[$0] })

        let channelIds = Set(try String.fetchAll(db, sql: """
            SELECT m.channelId FROM channelMember m JOIN channel c ON c.id = m.channelId
            WHERE m.member = ? AND c.companyId = ?
            """, arguments: [agent.id, companyId]))
        let leased = Set(try String.fetchAll(db, sql: "SELECT itemId FROM workLease WHERE agentId = ? AND companyId = ?",
                                             arguments: [agent.id, companyId]))
        var itemIds = leased, held = leased
        for row in try Row.fetchAll(db, sql: "SELECT id, authorId, ownerId, reviewerId FROM workItem WHERE companyId = ?",
                                    arguments: [companyId]) {
            let id: String = row["id"]
            let author: String? = row["authorId"], owner: String? = row["ownerId"], reviewer: String? = row["reviewerId"]
            if owner == agent.id { held.insert(id) }
            if author == agent.id || owner == agent.id || reviewer == agent.id || owner.map(reportIds.contains) == true {
                itemIds.insert(id)
            }
        }
        return ReaderContext(reader: reader, companyId: companyId, agentId: agent.id, team: agent.team, roles: roles,
                             isExecutive: isExecutive, channelIds: channelIds, itemIds: itemIds, heldItemIds: held,
                             reportIds: reportIds, teamsBelow: teamsBelow)
    }
}

/// The access engine. Two stages and no early return past the reader checks: stage 1 gives the base level from the doc's
/// class and reader set, stage 2 caps it by restrictions and sensitivity. Every search hit and every document read goes
/// through it; the SQL prefilter is only an optimization.
enum MemoryAccess {
    static func level(_ ctx: ReaderContext, access: AccessClass, sensitivity: Sensitivity, readerSet: Set<String>?,
                      restrictions: [Restriction], futureHolders: Bool) -> AccessLevel {
        switch ctx.reader {
        case .owner: return .full                                     // secret: metadata only, no values are ever stored
        case .concierge: return sensitivity == .secret ? .none : .full
        case .agent: break
        }
        guard let agentId = ctx.agentId else { return .none }

        // Stage 1: the base level.
        var level: AccessLevel
        if sensitivity == .hrPerf || sensitivity == .secret || access == .ownerOnly {
            level = .none
        } else if let readerSet {
            var holder = false
            if futureHolders, case .item(let i) = access { holder = ctx.heldItemIds.contains(i) }
            level = readerSet.contains(agentId) || holder ? .full : .none
        } else {
            switch access {
            case .company: level = .full
            case .team(let t): level = ctx.team == t || ctx.teamsBelow.contains(t) ? .full : .none
            case .role(let r): level = ctx.roles.contains(r) ? .full : .none
            case .item(let i): level = ctx.itemIds.contains(i) ? .full : .none
            case .channel(let c), .dm(let c): level = ctx.channelIds.contains(c) ? .full : .none
            case .agent(let a): level = a == agentId ? .full : ctx.reportIds.contains(a) ? .summary : .none
            case .ownerOnly: level = .none
            }
        }

        // Stage 2: the caps. A restricted doc without restrictions is executives only.
        if level != .none {
            let caps: [Restriction] = sensitivity == .restricted && restrictions.isEmpty ? [["@executive"]] : restrictions
            for r in caps where r.isDisjoint(with: ctx.roles) && !(r.contains("@executive") && ctx.isExecutive) {
                level = .none
            }
        }
        return level
    }
}
