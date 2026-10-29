import Testing
import Foundation
import BrahmaCore
@testable import BrahmaAppModel

@MainActor @Suite(.scratch) struct OrgFormTests {
    @Test func agentCountValidation() {
        var form = CompanyForm(name: "Acme", goal: "Ship")
        #expect(form.agentCount == 6 && form.usageMode == .balanced && form.packId == "software")
        #expect(form.validate() == nil)
        for bad in [-1, 1, 4, 501, 1000] {
            form.agentCount = bad
            #expect(form.validate() == "Agents must be 0 (add them later) or 5–500", "\(bad)")
        }
        for good in [0, 5, 6, 50, 51, 500] {
            form.agentCount = good
            #expect(form.validate() == nil, "\(good)")
        }
        form.agentCount = 50
        #expect(form.warning == nil)
        form.agentCount = 51
        #expect(form.warning == "Org sizes over 50 are experimental.")
        form.agentCount = 6
        form.name = " "
        #expect(form.validate() == "Name is required")
    }

    @Test func previewMatchesGenerator() throws {
        let catalog = PackCatalog.builtin
        let pack = try #require(catalog.pack("software"))
        var form = CompanyForm(name: "Acme", goal: "Ship", agentCount: 40)
        let preview = try #require(form.preview(catalog: catalog, seatBudget: 8))
        let plan = try OrgGenerator.generate(goal: "Ship", count: 40, pack: pack)
        let staffed = OrgGenerator.staff(plan: plan, pack: pack, readyWidth: 0, seatBudget: 8)
        #expect(preview.lines == plan.treeLines(vacant: Set(staffed.vacancies.map(\.handle))))
        #expect(preview.total == 40 && preview.seated == staffed.seated.agents.count && preview.vacant == staffed.vacancies.count)
        #expect(preview.seated + preview.vacant == 40 && preview.warning == nil)
        // A smaller plan tier seats fewer of the same shape.
        let smaller = try #require(form.preview(catalog: catalog, seatBudget: 4))
        #expect(smaller.seated == 4 && smaller.seated < preview.seated && smaller.lines.count == preview.lines.count)
        form.agentCount = 0
        #expect(form.preview(catalog: catalog) == nil)
        form.agentCount = 4
        #expect(form.preview(catalog: catalog) == nil)
        form.agentCount = 60
        #expect(form.preview(catalog: catalog)?.warning == "Org sizes over 50 are experimental.")
        form.packId = "nope"
        #expect(form.preview(catalog: catalog) == nil)
    }

    @Test func previewUsesTheOwnersSeatBudget() async throws {
        let (store, paths) = try makeHome()
        let model = AppModel(store: store, paths: paths)
        let form = CompanyForm(name: "Acme", goal: "Ship", agentCount: 40)
        try store.setPlanTier(.max20x)
        let big = try #require(model.orgPreview(form))
        try store.setPlanTier(.pro)
        let small = try #require(model.orgPreview(form))
        #expect(small.seated == 4 && big.seated > small.seated)
    }

    @Test func createCompanyAppliesOrg() async throws {
        let (store, paths) = try makeHome()
        let model = AppModel(store: store, paths: paths)
        await model.load()
        let company = try await model.createCompany(CompanyForm(name: "Acme", goal: "Ship", agentCount: 20))
        let agents = try store.agents(companyId: company.id)
        let preview = try #require(CompanyForm(name: "Acme", goal: "Ship", agentCount: 20)
            .preview(catalog: store.catalog, seatBudget: store.seatBudget()))
        #expect(agents.count == preview.seated)
        #expect(try store.vacancies(companyId: company.id).count == preview.vacant)
        #expect(agents.contains { $0.role == "ceo" } && agents.contains { $0.managerId != nil })
        #expect(model.selectedCompanyId == company.id)

        // The default is six agents and Balanced; zero is an empty company; the plan tier sets the seats.
        let sixCompany = try await model.createCompany(CompanyForm(name: "Six", goal: "g"))
        let sixPreview = try #require(CompanyForm(name: "Six", goal: "g").preview(catalog: store.catalog, seatBudget: PlanTier.max5x.seatBudget))
        #expect(try store.agents(companyId: sixCompany.id).count == sixPreview.seated)
        #expect(sixPreview.seated + sixPreview.vacant == 6)
        #expect(sixCompany.usageMode == .balanced)
        let empty = try await model.createCompany(CompanyForm(name: "Empty", goal: "g", agentCount: 0))
        #expect(try store.agents(companyId: empty.id).isEmpty)
        try store.setPlanTier(.pro)
        let pro = try await model.createCompany(CompanyForm(name: "Pro", goal: "g", agentCount: 30))
        #expect(try store.agents(companyId: pro.id).count == PlanTier.pro.seatBudget)

        var maxForm = CompanyForm(name: "Max", goal: "g", agentCount: 0)
        maxForm.usageMode = .max
        let maxCompany = try await model.createCompany(maxForm)
        #expect(try store.company(id: maxCompany.id)?.usageMode == .max)

        await #expect(throws: FormError.invalid("Agents must be 0 (add them later) or 5–500")) {
            _ = try await model.createCompany(CompanyForm(name: "Bad", goal: "g", agentCount: 3))
        }
    }

    @Test func hireFormRolesAndAuto() throws {
        let roles = HireForm.roles(catalog: .builtin, packId: "software")
        #expect(roles.contains("engineer") && roles.contains("ceo"))
        #expect(HireForm.roles(catalog: .builtin, packId: "unknown") == HireForm.roleSuggestions)
        #expect(AgentModelChoice.allCases.first == .auto && AgentModelChoice.auto.title == "Auto")
        #expect(AgentModelChoice.auto.rawValue == "auto")
    }

    @Test func agentDetailCarriesOrgFields() async throws {
        let w = try await WorkWorld.make()
        await w.model.setManager(agentId: w.eng.id, managerId: w.cto.id)
        try w.store.setTeam(agentId: w.eng.id, team: "core")
        await w.refresh()
        let detail = try #require(w.model.detail(agentId: w.eng.id))
        #expect(detail.managerHandle == "cto" && detail.team == "core" && detail.reportCount == 0 && detail.actingRole == nil)
        #expect(w.model.detail(agentId: w.cto.id)?.reportCount == 1)
    }
}
