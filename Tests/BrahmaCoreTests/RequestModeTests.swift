import Foundation
import Testing
@testable import BrahmaCore

/// Who may ask for more (design §3.5). `nextTurnOnly` and `assigneeRequestCappedAtR2` live in InboxTests
/// (`requestModeNextTurnOnly`, `assigneeRequestCappedAtR2`, Task 11a) and `schemasCannotSetIntensityOrFloor` in WorkItemTests
/// (Task 6); this suite adds the rest of the 3a list.
@Suite(.scratch) struct RequestModeTests {
    private struct R {
        let store: Store, company: Company
        let mgr: Agent, eng: Agent, other: Agent
        let now = Date(timeIntervalSince1970: 1_800_000_000)

        init() throws {
            store = try Store.inMemory()
            company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
            mgr = try store.hire(companyId: company.id, name: "mgr", role: "manager", model: "sonnet")
            eng = try store.hire(companyId: company.id, name: "eng-1", role: "engineer", model: "sonnet", managerId: mgr.id)
            other = try store.hire(companyId: company.id, name: "eng-2", role: "engineer", model: "sonnet", managerId: mgr.id)
        }

        func item(_ title: String = "Hard thing") throws -> WorkItem {
            try store.createWorkItem(companyId: company.id, by: .owner, draft: WorkItemDraft(
                type: .task, title: title, ownerId: eng.id, status: .ready), now: now)
        }

        func ask(_ item: WorkItem, _ mode: String, _ id: String, at: Date? = nil) throws -> ModeRequestResult {
            try store.requestMode(companyId: company.id, by: eng.id, itemKey: item.key, mode: mode, reason: "stuck", requestId: id,
                                  now: at ?? now)
        }
    }

    @Test func nextTurnOnly() throws {
        // The floor a request raises is read when the next turn starts; the inputs of a turn already running never change.
        let r = try R()
        let item = try r.item()
        var before = ModeInputs(); before.hasItem = true; before.tier = .s; before.rungFloor = item.rungFloor
        let running = ModePolicy.select(before)
        #expect(try r.ask(item, "deep", "n1").kind == .raised)
        #expect(running.rung == .r1, "the decision made at the turn's start stands")
        var next = before; next.rungFloor = try #require(try r.store.workItem(id: item.id)).rungFloor
        #expect(ModePolicy.select(next).rung == .r2)
    }

    @Test func rateLimitedAndCooldown() throws {
        let r = try R()
        // Three requests per agent per active day, across items.
        let items = try (0..<4).map { try r.item("Item \($0)") }
        for i in 0..<3 { #expect(try r.ask(items[i], "deep", "d\(i)").kind == .raised) }
        #expect(throws: WorkError.self) { try r.ask(items[3], "deep", "d3") }
        // An Ultra request is recorded and routed (Task 14u: an owner boost ask under `important`); asking again on the same
        // item within an active day hits the cooldown.
        let r2 = try R()
        let u = try r2.item()
        let first = try r2.ask(u, "ultra", "u1")
        #expect(first.kind == .ultraAsked); #expect(first.message.hasPrefix("Asked the owner for one Ultra run on \(u.key)"))
        #expect(try r2.store.modeRequests(itemId: u.id).map(\.mode) == ["ultra"])
        let again = try r2.ask(u, "ultra", "u2")
        #expect(again.kind == .coolingDown); #expect(again.message.contains("cooldown"))
        #expect(try r2.ask(u, "ultra", "u1").kind == .duplicate, "a repeated request id is answered with nothing changed")
    }

    @Test func highRiskUnderTaint() throws {
        // `request_mode` is in the high-risk set: under taint (5-lite) it is refused, and on a fan-out turn it uses the one
        // high-risk call.
        #expect(CompanyTools.highRiskTools.contains("request_mode"))
        let r = try R()
        let item = try r.item()
        let tools = CompanyTools(store: r.store, companyId: r.company.id, agentId: r.eng.id,
                                 quotas: ModeQuotas(posts: 10, itemsCreated: 3, comments: 20, highRisk: 0))
        #expect(throws: ToolError.self) {
            try tools.call(name: "request_mode", arguments: ["key": .string(item.key), "mode": .string("deep"),
                                                             "reason": .string("x"), "request_id": .string("h1")])
        }
        #expect(try r.store.workItem(id: item.id)?.rungFloor == 0)
    }

    @Test func managerIntensityCappedThorough() throws {
        let r = try R()
        let item = try r.item()
        let thorough = try r.store.updateWorkItem(id: item.id, by: .agent(r.mgr.id), patch: WorkItemPatch(intensity: .thorough), now: r.now)
        #expect(thorough.intensity == .thorough)
        #expect(throws: WorkError.self) {
            try r.store.updateWorkItem(id: item.id, by: .agent(r.mgr.id), patch: WorkItemPatch(intensity: .ultra), now: r.now)
        }
        #expect(try r.store.updateWorkItem(id: item.id, by: .owner, patch: WorkItemPatch(intensity: .ultra), now: r.now).intensity == .ultra)
        // Thorough means a floor of R2 for the policy.
        var i = ModeInputs(); i.hasItem = true; i.tier = .s; i.intensity = .thorough
        #expect(ModePolicy.select(i).rung == .r2)
    }

    @Test func assigneeCannotSetIntensity() throws {
        let r = try R()
        let item = try r.item()
        #expect(throws: WorkError.self) {
            try r.store.updateWorkItem(id: item.id, by: .agent(r.eng.id), patch: WorkItemPatch(intensity: .thorough), now: r.now)
        }
        #expect(throws: WorkError.self) {
            try r.store.updateWorkItem(id: item.id, by: .agent(r.other.id), patch: WorkItemPatch(intensity: .thorough), now: r.now)
        }
        #expect(try r.store.workItem(id: item.id)?.intensity == .auto)
        // The tool surface has no field for it at all.
        let tools = CompanyTools(store: r.store, companyId: r.company.id, agentId: r.eng.id)
        for spec in tools.specs() { #expect(spec.inputSchema.objectValue?["properties"]?.objectValue?["intensity"] == nil) }
    }
}
