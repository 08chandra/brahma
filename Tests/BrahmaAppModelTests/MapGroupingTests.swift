import Testing
import Foundation
@testable import BrahmaCore
@testable import BrahmaAppModel

@Suite struct MapGroupingTests {
    let software = SoftwarePack.pack

    @Test func departmentRules() {
        #expect(Department.of(role: "ceo", kind: .executive) == .csuite)                // 1
        #expect(Department.of(role: "HR-Partner", kind: .individual) == .people)         // 2
        #expect(Department.of(role: "qa", kind: .individual) == .quality)                // 3
        #expect(Department.of(role: "designer", kind: .individual) == .design)           // 4
        #expect(Department.of(role: "researcher", kind: .individual) == .research)       // 5
        #expect(Department.of(role: "accountant", kind: nil) == .finance)                // 6
        #expect(Department.of(role: "engineer", kind: .individual) == .engineering)      // 7
        #expect(Department.of(role: "warehouse", kind: nil) == .operations)              // 8
        #expect(Department.of(role: "sales", kind: nil) == .sales)                       // 9
        #expect(Department.of(role: "janitor", kind: nil) == .engineering)               // 10
        #expect(Department.of(role: "director", kind: .manager) == .engineering)
        #expect(Department.of(role: "ceo-cpo", kind: .executive) == .csuite)
        // First match wins: devops is engineering (7) before ops (8).
        #expect(Department.of(role: "devops", kind: .individual) == .engineering)
    }

    @Test func groupsFromGeneratedOrg() throws {
        let generated = try OrgGenerator.generate(goal: "", count: 30, pack: software)
        let agents = agentsFromPlan(generated)
        let groups = MapGrouping.make(agents: agents, roleKinds: roleKinds(software))
        #expect(groups.first?.id == "csuite")
        #expect(groups.first?.title == "C-SUITE")
        let teams = groups.filter { $0.id.hasPrefix("team:") }
        #expect(!teams.isEmpty)
        #expect(teams.allSatisfy { $0.department == .engineering })
        let designer = try #require(agents.first { $0.role == "designer" })
        #expect(groups.first { $0.memberIds.contains(designer.id) }?.id == "dept:design")
        for t in teams {
            let name = String(t.id.dropFirst("team:".count))
            let manager = try #require(agents.first { $0.role == "manager" && $0.team == name })
            #expect(t.leadId == manager.id)
            #expect(t.title == name.uppercased())
        }
        // Every agent is in exactly one group.
        #expect(groups.flatMap(\.memberIds).sorted() == agents.map(\.id).sorted())
    }

    @Test func emptyAndAllKilled() {
        #expect(MapGrouping.make(agents: [], roleKinds: roleKinds(software)) == [])
        let killed = agentsFromPlan(plan(12, pack: software), states: [.killed])
        let groups = MapGrouping.make(agents: killed, roleKinds: roleKinds(software))
        #expect(!groups.isEmpty)
        #expect(groups.allSatisfy { $0.activeCount == 0 })
    }

    func agent(_ handle: String, role: String, team: String?, manager: String? = nil, at t: Double,
               state: AgentState = .ready) -> Agent {
        var a = Agent(id: "a-\(handle)", companyId: "c", name: handle, role: role, model: "sonnet", sessionId: "s",
                      sessionStarted: false, state: state, blocker: nil, requestedBlocker: nil, paused: false,
                      readySince: nil, createdAt: mapFixtureEpoch.addingTimeInterval(t))
        a.team = team
        a.managerId = manager.map { "a-\($0)" }
        return a
    }

    @Test func orderingAndTeamDepartment() {
        let kinds = roleKinds(software)
        let agents = [
            agent("zed", role: "engineer", team: "team-10", at: 1),
            agent("amy", role: "engineer", team: "team-10", at: 1),        // same createdAt: handle order
            agent("d1", role: "designer", team: "team-2", at: 0),
            agent("q1", role: "qa", team: "team-2", at: 0.5),
            agent("m2", role: "manager", team: "team-2", at: 3),
            agent("m3", role: "manager", team: "team-2", manager: nil, at: 4, state: .killed),
            agent("x1", role: "designer", team: "team-2", manager: "m2", at: 5),
            agent("boss", role: "manager", team: "solo", at: 2),
            agent("dev", role: "devops", team: nil, at: 0),
            agent("ceo", role: "ceo", team: "team-2", at: 9),                // executives ignore their team
        ]
        let groups = MapGrouping.make(agents: agents, roleKinds: kinds)
        // csuite, then teams by numeric-aware name (team-2 before team-10), then departments in enum order.
        #expect(groups.map(\.id) == ["csuite", "team:solo", "team:team-2", "team:team-10", "dept:engineering"])
        let t10 = groups.first { $0.id == "team:team-10" }!
        #expect(t10.memberIds == ["a-amy", "a-zed"])
        #expect(t10.leadId == nil)
        let t2 = groups.first { $0.id == "team:team-2" }!
        #expect(t2.department == .design)                                  // design 2 vs quality 1
        #expect(t2.leadId == "a-m2")                                       // the manager with the most reports
        #expect(t2.activeCount == 4)
        #expect(t2.memberIds == ["a-d1", "a-q1", "a-m2", "a-m3", "a-x1"])
        #expect(groups.first { $0.id == "team:solo" }?.department == .engineering)   // only managers
        #expect(groups.first { $0.id == "csuite" }?.memberIds == ["a-ceo"])
    }

    @Test func departmentTiesGoToEnumOrder() {
        let kinds = roleKinds(software)
        let agents = [agent("q", role: "qa", team: "t", at: 0), agent("d", role: "designer", team: "t", at: 1)]
        #expect(MapGrouping.make(agents: agents, roleKinds: kinds).first?.department == .design)
    }

    @Test func endpointOrderAndEdgeKey() {
        #expect(MapEndpoint.owner < .agent("a"))
        #expect(MapEndpoint.agent("a") < .agent("b"))
        #expect(!(MapEndpoint.owner < .owner))
        #expect(EdgeKey(.agent("b"), .agent("a")) == EdgeKey(.agent("a"), .agent("b")))
        #expect(EdgeKey(.agent("b"), .owner).a == .owner)
    }

    @Test func rectsAndModes() {
        let r = MapRect(x: 0, y: 0, w: 10, h: 10)
        #expect(r.mid == MapPoint2(x: 5, y: 5))
        #expect(r.intersects(MapRect(x: 5, y: 5, w: 10, h: 10)))
        #expect(!r.intersects(MapRect(x: 10, y: 0, w: 10, h: 10)))      // touching edges do not overlap
        #expect(MapMode.org.title == "ORG")
        #expect(Department.csuite.title == "C-SUITE")
        #expect(Department.allCases.map(\.title).allSatisfy { $0 == $0.uppercased() })
    }
}
