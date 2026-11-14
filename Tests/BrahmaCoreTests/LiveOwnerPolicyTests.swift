import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// The live goal-to-URL test's owner (Plan L Task 15 fix round 1, I2): it approves only the kinds its brief names (the gate,
/// the architecture, the deploy) plus an explicit benign allowlist (the sprint-plan gate), declines human tasks, answers
/// questions, and declines everything else (logged). Reserved matters, money, outbound messages, grants, boosts and
/// engine alerts are never approved by it (§6.24).
@Suite(.scratch) struct LiveOwnerPolicyTests {
    @Test func approvesOnlyTheBriefsKindsAndDeclinesTheRest() {
        for kind: AskKind in [.prd, .architecture, .deploy, .sprintPlan] {
            #expect(LiveOwnerPolicy.action(for: kind) == .approve, "\(kind)")
        }
        #expect(LiveOwnerPolicy.action(for: .humanTask) == .declineHumanTask)
        #expect(LiveOwnerPolicy.action(for: .info) == .answer)
        // Every reserved matter but the deploy (the brief's) and the human task (declined its own way) is declined.
        for kind in AskKind.reserved where kind != .deploy && kind != .humanTask {
            #expect(LiveOwnerPolicy.action(for: kind) == .decline, "\(kind)")
        }
        for kind: AskKind in [.boost, .engineAlert, .other, .release, AskKind("someFutureKind")] {
            #expect(LiveOwnerPolicy.action(for: kind) == .decline, "\(kind)")
        }
        // The allowlist is exactly what the policy documents; nothing reserved is on it.
        #expect(LiveOwnerPolicy.approved == [.prd, .architecture, .deploy, .sprintPlan])
        #expect(LiveOwnerPolicy.approved.allSatisfy { !$0.isReservedKind || $0 == .deploy })
    }

    /// A pending grant request (a reserved matter) and a plain decision are declined through the owner's decision path, and
    /// the touch says so; no grant is made.
    @Test func settlesAReservedAskByDeclining() throws {
        let g = try GrantWorld()
        _ = try g.request("web_domain", "example.org")
        let grantAsk = try g.ask("A-1")
        #expect(grantAsk.status == .pendingOwner)
        let touch = try LiveOwnerPolicy.settle(grantAsk, store: g.store, companyId: g.company.id)
        #expect(touch.hasPrefix("decline A-1"), Comment(rawValue: touch))
        #expect(try g.ask("A-1").status == .rejected)
        #expect(try g.store.grants(companyId: g.company.id, includeInactive: true).isEmpty)

        let other = try g.store.propose(companyId: g.company.id, by: .agent(g.eng.id), kind: .other, risk: .high, category: "general",
                                        title: "Pick a name", summary: "why", payload: nil, viaOwner: true)
        #expect(other.status == .pendingOwner)
        let second = try LiveOwnerPolicy.settle(other, store: g.store, companyId: g.company.id)
        #expect(second.hasPrefix("decline \(other.ref)"), Comment(rawValue: second))
        #expect(try g.store.ask(id: other.id)?.status == .rejected)
    }
}
