import Foundation
@testable import BrahmaCore
@testable import BrahmaAppModel

/// Map test fixtures. `@testable import BrahmaCore` reaches the internal memberwise inits of `Agent` and `Sprint`.

let mapFixtureEpoch = Date(timeIntervalSince1970: 1_799_971_200)

/// One agent per planned seat, in plan order: id `"a-<handle>"`, `managerId` from `managerHandle`, `createdAt` one second
/// apart (so creation order is plan order) and `states` cycled.
func agentsFromPlan(_ plan: OrgPlan, companyId: String = "c", states: [AgentState] = [.ready]) -> [Agent] {
    let states = states.isEmpty ? [.ready] : states
    return plan.agents.enumerated().map { i, p in
        var a = Agent(id: "a-\(p.handle)", companyId: companyId, name: p.handle, role: p.role, model: "sonnet",
                      sessionId: "s-\(p.handle)", sessionStarted: false, state: states[i % states.count], blocker: nil,
                      requestedBlocker: nil, paused: false, readySince: nil,
                      createdAt: mapFixtureEpoch.addingTimeInterval(Double(i)))
        a.managerId = p.managerHandle.map { "a-\($0)" }
        a.team = p.team
        return a
    }
}

func plan(_ n: Int, pack: IndustryPack) -> OrgPlan {
    try! OrgGenerator.generate(goal: "", count: n, pack: pack)
}

func roleKinds(_ pack: IndustryPack) -> [String: RoleKind] {
    Dictionary(pack.roles.map { ($0.id, $0.kind) }, uniquingKeysWith: { first, _ in first })
}

func sprintFixture(number: Int, team: String?, status: SprintStatus) -> Sprint {
    Sprint(id: "sprint-\(number)", companyId: "c", number: number, team: team, goal: "Goal \(number)", cadence: .sprint,
           status: status, milestoneItemId: nil, askId: nil, createdAt: mapFixtureEpoch)
}
