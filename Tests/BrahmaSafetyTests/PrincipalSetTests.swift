import Testing
import Foundation
@testable import BrahmaSafety

/// Plan S Task S6 (spec §6.2.2, §6.2.4): a `PrincipalSet` is never empty, least privilege wins (one member that is not
/// Full-eligible makes the whole set not Full, and any `.unknown`, `.external` or `.engine` member takes every grant away),
/// network grants are the intersection of the agents' grants (B3), and the set does not depend on the order it was built in.
@Suite(.scratch) struct PrincipalSetTests {
    static func agent(_ id: String, company: String = "c1", profile: PermissionProfile = .full, grants: [String] = []) -> Principal {
        .agent(AgentPrincipal(agentId: id, companyId: company, role: "engineer", profile: profile, grantDomains: grants))
    }

    @Test func emptyBecomesUnknown() {
        let set = PrincipalSet(companyId: "c1", members: [], ownerProfile: .full)
        #expect(set.members == [.unknown(reason: "no principal")])
        #expect(set.hasUnknown)
        #expect(!set.allFull)
        #expect(set.commonGrantDomains == [])
    }

    /// Property: whatever else a member list holds, one `.unknown`, `.external` or `.engine` member makes the set ineligible
    /// for Full and for every grant (spec §6.2.4), even when every other member is a Full agent or the owner of a Full company.
    @Test func unknownNeverFull() {
        var rng = FuzzConfig.generator()
        let pool: [Principal] = [
            Self.agent("a", grants: ["x.example", "y.example"]), Self.agent("b", grants: ["y.example"]),
            Self.agent("c", profile: .workspace), .owner(companyId: "c1"),
        ]
        let spoilers: [Principal] = [
            .unknown(reason: "no agent ghost in the company's records"), .unknown(reason: "the lookup failed"),
            .external(source: "extension acme/tool"), .engine,
        ]
        for n in 0..<FuzzConfig.cases {
            var members = (0..<Int.random(in: 0...6, using: &rng)).map { _ in pool.randomElement(using: &rng)! }
            for _ in 0..<Int.random(in: 1...3, using: &rng) {
                members.insert(spoilers.randomElement(using: &rng)!, at: Int.random(in: 0...members.count, using: &rng))
            }
            let set = PrincipalSet(companyId: "c1", members: members, ownerProfile: .full)
            #expect(!set.allFull, "seed \(FuzzConfig.seed) case \(n): \(members)")
            #expect(set.commonGrantDomains == [], "seed \(FuzzConfig.seed) case \(n): \(members)")
        }
    }

    /// B3: the network grants of a set are the intersection of its agents' grants; the owner adds no restriction of its own.
    @Test func grantsIntersect() {
        let a = Self.agent("a", grants: ["x", "y"]), b = Self.agent("b", grants: ["y", "z"])
        #expect(PrincipalSet(companyId: "c1", members: [a, b], ownerProfile: .full).commonGrantDomains == ["y"])
        #expect(PrincipalSet(companyId: "c1", members: [a], ownerProfile: .full).commonGrantDomains == ["x", "y"])
        #expect(PrincipalSet(companyId: "c1", members: [a, .owner(companyId: "c1")], ownerProfile: .full).commonGrantDomains == ["x", "y"])
        #expect(PrincipalSet(companyId: "c1", members: [a, Self.agent("c", grants: [])], ownerProfile: .full).commonGrantDomains == [])
        #expect(PrincipalSet(companyId: "c1", members: [.owner(companyId: "c1")], ownerProfile: .full).commonGrantDomains == [],
                "no agent: no grant")
    }

    /// Members are sorted and deduplicated, so the set (and everything derived from it) is the same for any order.
    @Test func orderInvariant() {
        var rng = FuzzConfig.generator()
        let pool: [Principal] = [
            Self.agent("a", grants: ["x", "y"]), Self.agent("b", profile: .workspace, grants: ["y"]), Self.agent("a", company: "c2"),
            .owner(companyId: "c1"), .owner(companyId: "c2"), .engine, .external(source: "s"), .unknown(reason: "r1"),
            .unknown(reason: "r2"),
        ]
        for n in 0..<FuzzConfig.cases {
            let members = (0..<Int.random(in: 0...8, using: &rng)).map { _ in pool.randomElement(using: &rng)! }
            let one = PrincipalSet(companyId: "c1", members: members, ownerProfile: .full)
            let other = PrincipalSet(companyId: "c1", members: members.shuffled(using: &rng) + members.prefix(2), ownerProfile: .full)
            #expect(one == other, "seed \(FuzzConfig.seed) case \(n): \(members)")
            #expect(one.members == other.members && one.allFull == other.allFull && one.commonGrantDomains == other.commonGrantDomains)
            #expect(Set(one.members).count == one.members.count, "deduplicated")
        }
    }

    /// The positive control of least privilege: Full needs every member Full-eligible, of the set's own company, and the
    /// company's own profile (after the ceiling) Full for an owner member.
    @Test func fullNeedsEveryMemberFull() {
        let owner = Principal.owner(companyId: "c1")
        #expect(PrincipalSet(companyId: "c1", members: [Self.agent("a"), Self.agent("b"), owner], ownerProfile: .full).allFull)
        #expect(PrincipalSet(companyId: "c1", members: [owner], ownerProfile: .full).allFull)
        #expect(!PrincipalSet(companyId: "c1", members: [owner], ownerProfile: .workspace).allFull, "the owner follows the company")
        #expect(!PrincipalSet(companyId: "c1", members: [Self.agent("a"), Self.agent("b", profile: .workspace)], ownerProfile: .full).allFull)
        #expect(!PrincipalSet(companyId: "c1", members: [Self.agent("a", profile: .sandboxed)], ownerProfile: .full).allFull)
        #expect(!PrincipalSet(companyId: "c1", members: [Self.agent("a", company: "c2")], ownerProfile: .full).allFull,
                "an agent of another company is never Full here")
        #expect(!PrincipalSet(companyId: "c1", members: [.owner(companyId: "c2")], ownerProfile: .full).allFull,
                "another company's owner is never Full here")
        #expect(PrincipalSet(companyId: "c1", members: [Self.agent("a", company: "c2", grants: ["x"])], ownerProfile: .full)
                    .commonGrantDomains == [], "nor does it bring grants")
    }
}
