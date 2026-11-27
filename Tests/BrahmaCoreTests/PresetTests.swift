import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Task 9: the two access presets. Both are off by default and never approve a medium or higher risk or a reserved matter.
@Suite(.scratch) struct PresetTests {
    @Test func webPresetAutoApprovesExactDocsHost() throws {
        let g = try GrantWorld()
        try g.store.setPreset(companyId: g.company.id, .readOnlyWebForEngineers, enabled: true, owner: .test)
        let reply = try g.request("web_domain", "docs.stripe.com")
        #expect(reply.contains("A-1") && reply.contains("G-1"), "\(reply)")
        let ask = try g.ask("A-1")
        #expect(ask.status == .approved); #expect(ask.decidedBy == "preset:readonly-web-engineers")
        // Decided before it was routed: no "approval needed" line or DM, only the FYI.
        #expect(!(try g.store.events(afterId: 0, companyId: g.company.id)).contains { $0.text.contains("Owner approval needed") })
        #expect(try g.store.allNotices().filter { $0.companyId == g.company.id }.count == 1)
        #expect(ask.ownerNote == "auto: web_domain docs.stripe.com")
        let grant = try #require(try g.store.grants(companyId: g.company.id).first)
        #expect(grant.approvedBy == "preset:readonly-web-engineers")
        #expect(grant.scope == .role); #expect(grant.scopeRef == "engineer"); #expect(grant.duration == .always)
        #expect(grant.askId == ask.id)
        // The owner gets an FYI notice.
        #expect(try g.store.allNotices().contains { $0.companyId == g.company.id && $0.body.contains("docs.stripe.com") })
        // A role the preset does not cover stays pending.
        let designer = try g.store.hire(companyId: g.company.id, name: "des-1", role: "designer", model: "sonnet")
        _ = try g.request("web_domain", "react.dev", by: designer)
        #expect(try g.ask("A-2").status == .pendingOwner)
        // A merged role that covers architect does.
        let cto = try g.store.hire(companyId: g.company.id, name: "cto-1", role: "cto-architect", model: "sonnet")
        _ = try g.request("web_domain", "kubernetes.io", by: cto)
        #expect(try g.ask("A-3").status == .approved)
        #expect(AccessPresets.docsHosts.count == 20)
    }

    /// Final wave B1 (controller Ruling C6-4 addition): `request_access` runs in the agent's `brahma mcp` process. There, a
    /// preset the owner turned on still decides (under the `PolicyPrincipal` its evaluator minted, recorded `preset:<id>`, never
    /// the owner); with no matching preset row nothing decides, and the owner-only paths refuse with the generic text. A preset
    /// authority approves only its own access ask with its own grant.
    @Test func agentProcessReachesTheDecisionOnlyThroughAMatchingPreset() throws {
        let g = try GrantWorld()
        try g.store.setPreset(companyId: g.company.id, .readOnlyWebForEngineers, enabled: true, owner: .test)
        let owner = try OwnerPrincipal.test
        #if DEBUG
        try OwnerPrincipal.simulatingAgentProcess {
            _ = try g.request("web_domain", "docs.stripe.com")
            _ = try g.request("web_domain", "example.org")
            #expect(throws: WorkError.self) { try g.store.approveAccess(askId: try g.ask("A-2").id, scope: .agent, duration: .sprint, owner: owner) }
            #expect(throws: WorkError.self) { try g.store.ownerDecide(askId: try g.ask("A-2").id, approve: true, owner: owner) }
            #expect(throws: WorkError.self) { try g.store.setPreset(companyId: g.company.id, .autoModeLowRisk, enabled: true, owner: owner) }
        }
        #endif
        #expect(try g.ask("A-1").status == .approved && g.ask("A-1").decidedBy == "preset:readonly-web-engineers")
        #expect(try g.ask("A-2").status == .pendingOwner, "no preset row decides it")
        #expect(try !g.store.enabledPresets(companyId: g.company.id).contains(.autoModeLowRisk))
        // A preset row the owner never enabled mints nothing.
        try g.store.setPreset(companyId: g.company.id, .readOnlyWebForEngineers, enabled: false, owner: .test)
        _ = try g.request("web_domain", "react.dev")
        #expect(try g.ask("A-3").status == .pendingOwner)
    }

    @Test func webPresetIgnoresWildcardAndUnknownHost() throws {
        let g = try GrantWorld()
        try g.store.setPreset(companyId: g.company.id, .readOnlyWebForEngineers, enabled: true, owner: .test)
        _ = try g.request("web_domain", "*.stripe.com")
        _ = try g.request("web_domain", "example.org")
        #expect(try g.ask("A-1").status == .pendingOwner)
        #expect(try g.ask("A-2").status == .pendingOwner)
        #expect(try g.store.grants(companyId: g.company.id, includeInactive: true).isEmpty)
    }

    @Test func webPresetIgnoresNetworkDomain() throws {
        let g = try GrantWorld()
        try g.store.setPreset(companyId: g.company.id, .readOnlyWebForEngineers, enabled: true, owner: .test)
        _ = try g.request("network_domain", "docs.stripe.com")
        #expect(try g.ask("A-1").status == .pendingOwner)
        #expect(try g.store.grants(companyId: g.company.id, includeInactive: true).isEmpty)
    }

    @Test func autoLowRiskNeedsAutoAutonomy() throws {
        let g = try GrantWorld()
        try g.store.setPreset(companyId: g.company.id, .autoModeLowRisk, enabled: true, owner: .test)
        let designer = try g.store.hire(companyId: g.company.id, name: "des-1", role: "designer", model: "sonnet")
        _ = try g.request("web_domain", "example.org", by: designer)
        #expect(try g.ask("A-1").status == .pendingOwner, "the company's autonomy is not auto")
        try g.store.setAutonomy(companyId: g.company.id, .auto, owner: .test)
        _ = try g.request("web_domain", "example.net", by: designer)
        #expect(try g.ask("A-2").status == .approved)
        let grant = try #require(try g.store.grants(companyId: g.company.id).first)
        #expect(grant.approvedBy == "preset:auto-low-risk")
        #expect(grant.scope == .agent); #expect(grant.scopeRef == designer.id); #expect(grant.duration == .sprint)
        #expect(grant.expiresActive != nil)
        // Only an exact host name.
        _ = try g.request("web_domain", "*.example.io", by: designer)
        #expect(try g.ask("A-3").status == .pendingOwner)
    }

    @Test func floorBlocksMediumAndReserved() throws {
        let store = try Store.inMemory()
        var company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        company.autonomy = .auto
        let pack = try #require(store.catalog.pack("software"))
        let both: Set<AccessPreset> = [.readOnlyWebForEngineers, .autoModeLowRisk]
        func decide(_ kind: GrantKind, _ value: String, risk: AskRisk, pack p: IndustryPack = pack) -> AccessPresets.Decision? {
            AccessPresets.autoDecision(kind: kind, value: value, risk: risk, requesterRole: "engineer", company: company, enabled: both,
                                       pack: p)
        }
        #expect(decide(.webDomain, "docs.stripe.com", risk: .low)?.preset == .readOnlyWebForEngineers)
        #expect(decide(.webDomain, "docs.stripe.com", risk: .medium) == nil)
        #expect(decide(.webDomain, "docs.stripe.com", risk: .high) == nil)
        #expect(decide(.webDomain, "example.org", risk: .medium) == nil)
        for kind in [GrantKind.networkDomain, .readPath, .extension] {
            #expect(decide(kind, "docs.stripe.com", risk: kind.risk) == nil, "\(kind)")
            #expect(decide(kind, "docs.stripe.com", risk: .low) == nil, "\(kind): only web domains")
        }
        var reserved = pack
        reserved.reservedCategories = ["tooling"]
        #expect(decide(.webDomain, "docs.stripe.com", risk: .low, pack: reserved) == nil)
        #expect(decide(.webDomain, "example.org", risk: .low, pack: reserved) == nil)
        #expect(decide(.webDomain, "example.org", risk: .low)?.preset == .autoModeLowRisk)
    }

    @Test func presetsOffByDefault() throws {
        let g = try GrantWorld()
        try g.store.setAutonomy(companyId: g.company.id, .auto, owner: .test)
        #expect(try g.store.enabledPresets(companyId: g.company.id).isEmpty)
        #expect(Set(AccessPreset.allCases.map(\.rawValue)) == ["readonly-web-engineers", "auto-low-risk"])
        _ = try g.request("web_domain", "docs.stripe.com")
        #expect(try g.ask("A-1").status == .pendingOwner)
        // Disabled again after being on: back to the owner.
        try g.store.setPreset(companyId: g.company.id, .readOnlyWebForEngineers, enabled: true, owner: .test)
        try g.store.setPreset(companyId: g.company.id, .readOnlyWebForEngineers, enabled: false, owner: .test)
        _ = try g.request("web_domain", "react.dev")
        #expect(try g.ask("A-2").status == .pendingOwner)
    }
}
