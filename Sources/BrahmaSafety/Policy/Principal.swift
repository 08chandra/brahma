import Foundation

/// One party whose bytes an action interprets or whose code it runs: the action's SUBJECT (spec §6.2.1). What the sandbox
/// allows is derived from subjects only, never from who asked for the result (the requester), which is the confused-deputy fix.
///
/// `.owner(companyId:)` is a subject-side value ("these bytes are the owner's"). It is not a capability: the requester-side
/// capability "this process may act as the owner" is BrahmaCore's `OwnerPrincipal` (Plan C Task C6), which only an owner
/// surface can mint. Neither stands in for the other: holding an `OwnerPrincipal` never makes a subject `.owner`, and a
/// `.owner` subject never grants owner reach to a requester. `PrincipalResolver` derives subjects from the engine's records
/// and never mints or consults `OwnerPrincipal` (Ruling A6).
public enum Principal: Hashable, Sendable {
    case owner(companyId: String)
    case agent(AgentPrincipal)
    /// Engine-authored bytes only (canary scratch, doctor probes).
    case engine
    /// Bytes from outside the company (an imported extension, a dropped file not vouched for).
    case external(source: String)
    /// Could not be resolved. `reason` is engine text for logs and the owner note, never shown to agents.
    case unknown(reason: String)

    /// A total order on principals: equal keys only for equal principals, so sorting is independent of input order.
    var sortKey: [String] {
        switch self {
        case .owner(let companyId): return ["0", companyId]
        case .agent(let a): return ["1", a.companyId, a.agentId, a.role, a.profile.rawValue] + a.grantDomains
        case .engine: return ["2"]
        case .external(let source): return ["3", source]
        case .unknown(let reason): return ["4", reason]
        }
    }
}

public struct AgentPrincipal: Hashable, Sendable {
    public let agentId: String
    public let companyId: String
    public let role: String
    /// The agent's profile narrowed by its company, its role profile and the engine ceiling, at resolution time.
    public let profile: PermissionProfile
    /// The agent's granted domains (5-lite grants), already intersected with the company network scope. Sorted, deduplicated.
    public let grantDomains: [String]

    public init(agentId: String, companyId: String, role: String, profile: PermissionProfile, grantDomains: [String]) {
        self.agentId = agentId; self.companyId = companyId; self.role = role; self.profile = profile
        self.grantDomains = Array(Set(grantDomains)).sorted()
    }
}

/// Everyone whose bytes or code one action touches (spec §6.2.2). Never empty: an empty set is `[.unknown("no principal")]`.
/// Least privilege wins (spec §6.2.4): Full needs every member Full-eligible, network grants are the intersection, and any
/// `.unknown`, `.external` or `.engine` member makes the set ineligible for Full and for every grant.
public struct PrincipalSet: Hashable, Sendable {
    /// The reason of the member an empty set becomes.
    public static let noPrincipal = "no principal"

    public let companyId: String
    /// Sorted, deduplicated.
    public let members: [Principal]
    /// The company's own profile narrowed by the engine ceiling.
    public let ownerProfile: PermissionProfile

    public init(companyId: String, members: [Principal], ownerProfile: PermissionProfile) {
        self.companyId = companyId
        self.ownerProfile = ownerProfile
        let unique = Set(members)
        self.members = unique.isEmpty
            ? [.unknown(reason: Self.noPrincipal)]
            : unique.sorted { $0.sortKey.lexicographicallyPrecedes($1.sortKey) }
    }

    public var hasUnknown: Bool {
        members.contains { member in
            if case .unknown = member { return true }
            return false
        }
    }

    /// True only if members is non-empty, contains no `.unknown`/`.external`/`.engine`, every `.agent` (of this company)
    /// narrows to `.full`, and every `.owner` (of this company) has its company profile, after the ceiling (`ownerProfile`),
    /// `.full`. A member of another company is never Full here.
    public var allFull: Bool {
        guard !members.isEmpty else { return false }
        for member in members {
            switch member {
            case .owner(let id):
                guard id == companyId, ownerProfile == .full else { return false }
            case .agent(let a):
                guard a.companyId == companyId, a.profile == .full else { return false }
            case .engine, .external, .unknown:
                return false
            }
        }
        return true
    }

    /// The intersection of every agent member's `grantDomains` (B3); an owner member adds no restriction of its own. Empty
    /// when any member is not `.agent` or `.owner` (or is of another company), and when there is no agent member.
    public var commonGrantDomains: [String] {
        var common: Set<String>?
        for member in members {
            switch member {
            case .owner(let id):
                guard id == companyId else { return [] }
            case .agent(let a):
                guard a.companyId == companyId else { return [] }
                common = common.map { $0.intersection(a.grantDomains) } ?? Set(a.grantDomains)
            case .engine, .external, .unknown:
                return []
            }
        }
        return (common ?? []).sorted()
    }
}
