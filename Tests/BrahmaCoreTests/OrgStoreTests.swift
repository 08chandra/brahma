import Testing
import Foundation
import GRDB
@testable import BrahmaCore

@Suite(.scratch) struct OrgStoreTests {
    private let software = PackCatalog.builtin.pack("software")!

    private func make() throws -> (Store, Company) {
        let s = try Store.inMemory()
        let root = try tempDir()
        return (s, try onWorkspaceProfile(s, try s.createCompany(name: "Acme", goal: "g", workspacesRoot: root)))
    }

    @Test func newCompaniesDefaultToBalancedSoftware() throws {
        let (_, c) = try make()
        #expect(c.usageMode == .balanced); #expect(c.packId == "software"); #expect(c.packVersion == 1)
        let s = try Store.inMemory()
        #expect(throws: OrgError.unknownPack) { try s.createCompany(name: "X", goal: "g", workspacesRoot: try tempDir(), packId: "nope") }
    }

    @Test func applyOrgHiresAutoModelWithReportingLines() throws {
        let (s, c) = try make()
        let plan = try OrgGenerator.generate(goal: "g", count: 9, pack: software)
        let hired = try s.applyOrg(companyId: c.id, plan: plan, pack: software)
        #expect(hired.count == 9); #expect(hired.allSatisfy { $0.model == "auto" })
        let eng1 = try #require(try s.agent(companyId: c.id, name: "eng-1"))
        let cto = try #require(try s.agent(companyId: c.id, name: "cto"))
        #expect(eng1.managerId == cto.id); #expect(eng1.team == "core"); #expect(eng1.trustLevel == "T1")
        #expect(try s.reports(agentId: cto.id).count == 6)
        let ceo = try #require(try s.agent(companyId: c.id, name: "ceo"))
        #expect(ceo.managerId == nil)
        let exec = try #require(try s.channel(companyId: c.id, name: "exec"))
        #expect(Set(try s.members(channelId: exec.id)) == [ceo.id, cto.id, "owner"])
        let arch = try #require(try s.channel(companyId: c.id, name: "architecture"))
        #expect(try s.members(channelId: arch.id) == [cto.id])
        let team = try #require(try s.channel(companyId: c.id, name: "team-core"))
        #expect(try s.members(channelId: team.id).count == 7)
        #expect(try s.orgTreeLines(companyId: c.id).first == "ceo (CEO & CPO)")
        #expect(try s.orgTreeLines(companyId: c.id).count == 9)
    }

    @Test func applyOrgIsAllOrNothing() throws {
        let (s, c) = try make()
        _ = try s.hire(companyId: c.id, name: "eng-2", role: "engineer", model: "sonnet")
        let plan = try OrgGenerator.generate(goal: "g", count: 5, pack: software)
        do { _ = try s.applyOrg(companyId: c.id, plan: plan, pack: software); Issue.record("expected throw") }
        catch OrgError.invalidPlan(let issues) { #expect(issues.contains { $0.handle == "eng-2" }) }
        #expect(try s.agents(companyId: c.id).count == 1)
        #expect(try s.channel(companyId: c.id, name: "exec") == nil)
        // A plan that fails inside the transaction rolls back too.
        var broken = try OrgGenerator.generate(goal: "g", count: 5, pack: software)
        broken.agents[3].team = nil
        broken.add(role: "engineer", handle: "bad handle!", manager: "ceo", team: nil)
        #expect(throws: OrgError.self) { try s.applyOrg(companyId: c.id, plan: broken, pack: software) }
        #expect(try s.agents(companyId: c.id).count == 1)
    }

    @Test func setManagerRejectsCycleAndEighthReport() throws {
        let (s, c) = try make()
        let boss = try s.hire(companyId: c.id, name: "boss", role: "manager", model: "auto")
        let mid = try s.hire(companyId: c.id, name: "mid", role: "manager", model: "auto", managerId: boss.id, team: nil)
        #expect(throws: OrgError.cycle) { try s.setManager(agentId: boss.id, managerId: mid.id) }
        #expect(throws: OrgError.cycle) { try s.setManager(agentId: boss.id, managerId: boss.id) }
        for i in 1...6 { _ = try s.hire(companyId: c.id, name: "w-\(i)", role: "engineer", model: "auto", managerId: boss.id, team: nil) }
        #expect(try s.reports(agentId: boss.id).count == 7)
        let extra = try s.hire(companyId: c.id, name: "extra", role: "engineer", model: "auto")
        #expect(throws: OrgError.tooManyReports(manager: "boss", count: 8)) { try s.setManager(agentId: extra.id, managerId: boss.id) }
        // Re-affirming an existing report is fine; moving to none works.
        try s.setManager(agentId: mid.id, managerId: boss.id)
        try s.setManager(agentId: mid.id, managerId: nil)
        #expect(try s.agent(id: mid.id)?.managerId == nil)
        _ = try s.transition(agentId: boss.id, to: .killed)
        #expect(throws: OrgError.managerKilled) { try s.setManager(agentId: extra.id, managerId: boss.id) }
        try s.setTeam(agentId: extra.id, team: "core")
        #expect(try s.agent(id: extra.id)?.team == "core")
    }

    @Test func systemHandleReserved() throws {
        let (s, c) = try make()
        #expect(throws: StoreError.invalidName) { try s.hire(companyId: c.id, name: "system", role: "x", model: "auto") }
        #expect(throws: StoreError.invalidName) { try s.hire(companyId: c.id, name: "System", role: "x", model: "auto") }
    }

    @Test func nextHandleSkipsKilled() throws {
        let (s, c) = try make()
        #expect(try s.nextHandle(companyId: c.id, prefix: "eng") == "eng-1")
        var last: Agent?
        for i in 1...4 { last = try s.hire(companyId: c.id, name: "eng-\(i)", role: "engineer", model: "auto") }
        let third = try #require(try s.agent(companyId: c.id, name: "eng-3"))
        _ = try s.transition(agentId: third.id, to: .killed)
        _ = try s.transition(agentId: last!.id, to: .killed)
        #expect(try s.nextHandle(companyId: c.id, prefix: "eng") == "eng-5")
        #expect(throws: StoreError.duplicateName) { try s.hire(companyId: c.id, name: "eng-3", role: "engineer", model: "auto") }
    }

    @Test func storeUsesInjectedCatalog() throws {
        var custom = software; custom.id = "custom"; custom.title = "Custom"
        let s = try Store.inMemory(catalog: PackCatalog(packs: [custom]))
        let c = try s.createCompany(name: "C", goal: "g", workspacesRoot: try tempDir(), packId: "custom")
        #expect(c.packId == "custom"); #expect(s.catalog.pack("custom")?.title == "Custom")
        #expect(throws: OrgError.unknownPack) { try s.createCompany(name: "D", goal: "g", workspacesRoot: try tempDir(), packId: "software") }
    }

    @Test func modelPolicyResolvesAuto() throws {
        // `ModePolicy.select` replaced `ModelPolicy.resolve` for auto agents (Task 14c); these are its turns without an item.
        let eng = software.role("engineer")!, designer = software.role("designer")!
        func r(_ model: String, _ role: RoleTemplate = eng, _ mode: UsageMode = .balanced, kind: TurnKind = .work,
               prd: Bool = false, architecture: Bool = false) -> String {
            var i = ModeInputs()
            i.agentModel = model; i.roleModel = role.models[mode.rawValue]; i.usageMode = mode; i.turnKind = kind
            i.decidingPRD = prd; i.decidingArchitecture = architecture
            return ModePolicy.select(i).model
        }
        #expect(r("haiku", eng, .max, architecture: true) == "haiku")
        #expect(r("auto") == "sonnet"); #expect(r("auto", designer, .low) == "haiku")
        #expect(r("auto", eng, .balanced, architecture: true) == "opus")
        #expect(r("auto", eng, .low, prd: true) == "opus")
        #expect(r("auto", designer, .low, kind: .review) == "sonnet")
        #expect(r("auto", eng, .balanced, kind: .notice) == "haiku")
        #expect(r("auto", eng, .balanced, kind: .notice, prd: true) == "opus")
        #expect(r("opus", eng, .low, kind: .notice) == "opus")
        var odd = eng; odd.models = [:]
        #expect(r("auto", odd) == "sonnet")
    }

    @Test func orchestratorSendsResolvedModel() async throws {
        let (s, c) = try make()
        try s.setPlanTier(.max20x)   // low mode seats two turns, as in Plan 1
        let designer = try s.hire(companyId: c.id, name: "design-1", role: "designer", model: "auto")
        var low = c; low.usageMode = .low; try s.updateCompany(low)
        let eng = try s.hire(companyId: c.id, name: "eng-1", role: "engineer", model: "auto")
        let fixed = try s.hire(companyId: c.id, name: "eng-2", role: "engineer", model: "opus")
        let fake = FakeTurnRunner()
        let root = try tempDir()
        let o = Orchestrator(store: s, runner: fake, paths: BrahmaPaths(home: root.appending(path: "h"), workspaces: root),
                             config: .init(), mcpExecutable: "/usr/local/bin/brahma")
        let router = MessageRouter(store: s)
        for a in [designer, eng] { _ = try router.sendDM(companyId: c.id, from: .owner, to: a.name, text: "go") }
        await o.tick()
        try await o.waitUntilIdle(timeout: .seconds(300))
        _ = try router.sendDM(companyId: c.id, from: .owner, to: fixed.name, text: "go")
        await o.tick()
        try await o.waitUntilIdle(timeout: .seconds(300))
        let models = Dictionary(uniqueKeysWithValues: fake.requests.map { ($0.agent.name, $0.agent.model) })
        #expect(models == ["design-1": "haiku", "eng-1": "sonnet", "eng-2": "opus"])
        #expect(try s.agent(id: eng.id)?.model == "auto")
    }

    @Test func fillVacancyHires() throws {
        let (s, c) = try make()
        let plan = try OrgGenerator.generate(goal: "g", count: 12, pack: software)
        let (seated, vacancies) = OrgGenerator.staff(plan: plan, pack: software, readyWidth: 0, seatBudget: 8)
        let hired = try s.applyOrg(companyId: c.id, plan: seated, pack: software, vacancies: vacancies)
        #expect(hired.count == 6)
        let open = try s.vacancies(companyId: c.id)
        #expect(open.count == 6); #expect(Set(open.map(\.handle)) == Set(vacancies.map(\.handle)))
        // Reserved: neither hire nor nextHandle hands out a vacancy's handle.
        let v = try #require(open.first { $0.role == "qa" })
        #expect(throws: StoreError.duplicateName) { try s.hire(companyId: c.id, name: v.handle, role: "qa", model: "auto") }
        #expect(try s.nextHandle(companyId: c.id, prefix: "qa") == "qa-\((Int(v.handle.dropFirst(3)) ?? 0) + 1)")
        let a = try s.fillVacancy(companyId: c.id, handle: v.handle)
        #expect(a.model == "auto"); #expect(a.role == "qa"); #expect(a.team == v.team)
        #expect(a.managerId == (try s.agent(companyId: c.id, name: try #require(v.managerHandle)))?.id)
        #expect(try s.vacancies(companyId: c.id).count == 5)
        #expect(throws: StoreError.notFound) { try s.fillVacancy(companyId: c.id, handle: v.handle) }
        #expect(throws: StoreError.notFound) { try s.fillVacancy(companyId: c.id, handle: "nobody") }
    }

    @Test func fillVacancyFallsBackToNearestExistingAncestor() throws {
        let (s, c) = try make()
        let ceo = try s.hire(companyId: c.id, name: "ceo", role: "ceo", model: "auto")
        let vac = [PlannedAgent(handle: "mgr-1", role: "manager", managerHandle: "ceo", team: "t"),
                   PlannedAgent(handle: "eng-1", role: "engineer", managerHandle: "mgr-1", team: "t")]
        let seated = OrgPlan(goal: "g", agents: [])
        _ = try s.applyOrg(companyId: c.id, plan: seated, pack: software, vacancies: vac)
        let a = try s.fillVacancy(companyId: c.id, handle: "eng-1")
        #expect(a.managerId == ceo.id)
    }
}
