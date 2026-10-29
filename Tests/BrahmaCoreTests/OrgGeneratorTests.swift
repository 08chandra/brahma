import Testing
import Foundation
@testable import BrahmaCore

@Suite(.scratch) struct OrgGeneratorTests {
    private let software = PackCatalog.builtin.pack("software")!

    @Test(arguments: [
        (5, ["ceo-cpo": 1, "cto-architect": 1, "engineer": 2, "qa": 1]),
        (9, ["ceo-cpo": 1, "cto-architect": 1, "engineer": 5, "qa": 1, "designer": 1]),
        (10, ["ceo": 1, "cpo": 1, "cto": 1, "manager": 1, "engineer": 4, "qa": 1, "designer": 1]),
        (20, ["ceo": 1, "cpo": 1, "cto": 1, "manager": 2, "engineer": 10, "qa": 2, "designer": 1, "architect": 1, "devops": 1]),
        (50, ["ceo": 1, "cpo": 1, "cto": 1, "manager": 5, "engineer": 27, "qa": 5, "designer": 3, "architect": 2, "devops": 2,
              "security": 1, "director": 2]),
        (300, ["ceo": 1, "cpo": 1, "cto": 1, "manager": 31, "engineer": 183, "qa": 31, "designer": 16, "architect": 11,
               "devops": 8, "security": 4, "director": 13]),
    ] as [(Int, [String: Int])])
    func roleCountsMatchRatios(n: Int, counts: [String: Int]) throws {
        #expect(try OrgGenerator.generate(goal: "g", count: n, pack: software).roleCounts() == counts)
    }

    @Test func invariantsHoldForEverySize() throws {
        for n in 5...500 {
            let plan = try OrgGenerator.generate(goal: "g", count: n, pack: software)
            #expect(plan.agents.count == n, "size \(n)")
            #expect(plan.validate(pack: software).isEmpty, "size \(n): \(plan.validate(pack: software))")
            #expect(Set(plan.agents.map(\.handle)).count == n, "size \(n)")
            #expect(plan.agents.filter { $0.managerHandle == nil }.count == 1, "size \(n)")
            for a in plan.agents { #expect(plan.reports(of: a.handle).count <= OrgGenerator.maxReports, "size \(n) \(a.handle)") }
        }
    }

    @Test func smallCompanyShape() throws {
        let plan = try OrgGenerator.generate(goal: "g", count: 5, pack: software)
        #expect(plan.agents.map(\.handle) == ["ceo", "cto", "eng-1", "eng-2", "qa-1"])
        #expect(plan.agents.first { $0.handle == "eng-1" }?.team == "core")
        #expect(plan.agents.first { $0.handle == "qa-1" }?.team == "core")
        #expect(plan.agents.first { $0.handle == "qa-1" }?.managerHandle == "cto")
        #expect(plan.agents.first { $0.handle == "cto" }?.managerHandle == "ceo")
    }

    @Test func outOfRangeThrows() {
        #expect(throws: OrgError.countOutOfRange) { try OrgGenerator.generate(goal: "g", count: 4, pack: software) }
        #expect(throws: OrgError.countOutOfRange) { try OrgGenerator.generate(goal: "g", count: 501, pack: software) }
        #expect(OrgGenerator.range == 5...500); #expect(OrgGenerator.maxReports == 7)
    }

    @Test func editsKeepPlanConsistent() throws {
        var plan = try OrgGenerator.generate(goal: "g", count: 5, pack: software)
        plan.add(role: "engineer", handle: "eng-3", manager: "cto", team: "core")
        #expect(plan.reports(of: "cto").count == 4); #expect(plan.validate(pack: software).isEmpty)
        // Removing a manager moves its reports up.
        plan.remove(handle: "cto")
        #expect(plan.reports(of: "ceo").map(\.handle) == ["eng-1", "eng-2", "qa-1", "eng-3"])
        #expect(plan.validate(pack: software).isEmpty)
        plan.rename("eng-3", to: "eng-9")
        #expect(plan.agents.contains { $0.handle == "eng-9" }); #expect(plan.reports(of: "ceo").contains { $0.handle == "eng-9" })
        #expect(throws: OrgError.cycle) { try plan.setManager(handle: "ceo", manager: "eng-9") }
        try plan.setManager(handle: "qa-1", manager: "eng-1")
        #expect(plan.reports(of: "eng-1").map(\.handle) == ["qa-1"])
        for i in 0..<6 { plan.add(role: "engineer", handle: "x-\(i)", manager: "ceo", team: nil) }
        #expect(plan.validate(pack: software).contains { $0.message.contains("reports") })
        plan.add(role: "engineer", handle: "x-0", manager: "ghost", team: nil)
        let messages = plan.validate(pack: software).map(\.message).joined(separator: "|")
        #expect(messages.contains("duplicate")); #expect(messages.contains("unknown manager"))
        var bad = try OrgGenerator.generate(goal: "g", count: 5, pack: software)
        bad.add(role: "engineer", handle: "system", manager: "ceo", team: nil)
        #expect(!bad.validate(pack: software).isEmpty)
    }

    @Test func treeLinesIndentByDepth() throws {
        let plan = try OrgGenerator.generate(goal: "g", count: 5, pack: software)
        #expect(plan.treeLines() == ["ceo (CEO & CPO)", "  cto (CTO & Architect)", "    eng-1 (Engineer)", "    eng-2 (Engineer)",
                                     "    qa-1 (QA)"])
        #expect(plan.treeLines(vacant: ["qa-1"]).last == "    qa-1 (QA) (vacant)")
    }

    @Test func staffKeepsTriggerRolesVacant() throws {
        let plan = try OrgGenerator.generate(goal: "g", count: 20, pack: software)
        let (seated, vacancies) = OrgGenerator.staff(plan: plan, pack: software, readyWidth: 100, seatBudget: 100)
        let triggers = Set(software.triggerRoles)
        #expect(triggers == ["qa", "designer", "security"])
        #expect(seated.agents.allSatisfy { !triggers.contains($0.role) })
        #expect(vacancies.allSatisfy { triggers.contains($0.role) })
        #expect(vacancies.count == 3); #expect(seated.agents.count == 17)
        #expect(seated.validate(pack: software).isEmpty)
    }

    @Test func staffCapsSeatsByBudget() throws {
        let plan = try OrgGenerator.generate(goal: "g", count: 50, pack: software)
        let (seated, vacancies) = OrgGenerator.staff(plan: plan, pack: software, readyWidth: 0, seatBudget: 8)
        #expect(seated.agents.count == 6); #expect(seated.agents.count + vacancies.count == 50)
        #expect(seated.agents.prefix(3).map(\.handle) == ["ceo", "cpo", "cto"])
        // Executives and directors come first, so every seated agent has a seated manager.
        #expect(seated.validate(pack: software).isEmpty)
        let small = try OrgGenerator.generate(goal: "g", count: 12, pack: software)
        let (s2, v2) = OrgGenerator.staff(plan: small, pack: software, readyWidth: 0, seatBudget: 8)
        #expect(s2.agents.count == 6); #expect(v2.count == 6)
        // Wide backlog raises the cap up to the budget only.
        let (s3, _) = OrgGenerator.staff(plan: plan, pack: software, readyWidth: 40, seatBudget: 24)
        #expect(s3.agents.count == 24)
        let (s4, _) = OrgGenerator.staff(plan: plan, pack: software, readyWidth: 40, seatBudget: 100)
        #expect(s4.agents.count == 41)
    }
}
