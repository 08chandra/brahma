import Foundation
import Testing
@testable import BrahmaCore

/// Per-turn MCP quotas, counted inside the turn's one `brahma mcp` process (design §4.1), and the plan turn's read-mostly
/// surface.
@Suite struct MCPQuotaTests {
    private struct Q {
        let store: Store
        let company: Company
        let mgr: Agent
        let eng: Agent

        init() throws {
            store = try Store.inMemory()
            company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
            mgr = try store.hire(companyId: company.id, name: "mgr", role: "manager", model: "sonnet")
            eng = try store.hire(companyId: company.id, name: "eng", role: "engineer", model: "sonnet", managerId: mgr.id)
        }

        func tools(_ quotas: ModeQuotas?, agent: Agent? = nil, planTurn: Bool = false) -> CompanyTools {
            CompanyTools(store: store, companyId: company.id, agentId: (agent ?? eng).id, quotas: quotas, planTurn: planTurn)
        }
    }

    private func call(_ t: CompanyTools, _ name: String, _ args: [String: JSONValue]) -> (ok: Bool, text: String) {
        do { return (true, try t.call(name: name, arguments: args)) } catch let e as ToolError { return (false, e.message) }
        catch { return (false, "\(error)") }
    }

    @Test func perTurnQuotaByMode() throws {
        let q = try Q()
        let t = q.tools(ModeCaps.quick.quotas)
        let post: [String: JSONValue] = ["channel": .string("general"), "text": .string("hi")]
        for _ in 0..<3 { #expect(call(t, "post_message", post).ok) }
        let refused = call(t, "post_message", post)
        #expect(!refused.ok); #expect(refused.text.contains("3 posts and DMs per turn"))
        #expect(!call(t, "send_dm", ["to": .string("@mgr"), "text": .string("x")]).ok, "DMs share the post quota")
        // Items: one in Quick.
        let item: [String: JSONValue] = ["type": .string("task"), "title": .string("A")]
        #expect(call(t, "create_work_item", item).ok)
        #expect(!call(t, "create_work_item", item).ok)
        // A failed call does not use the quota; reading tools are never counted.
        let fresh = q.tools(ModeCaps.quick.quotas)
        #expect(!call(fresh, "post_message", ["channel": .string("nope"), "text": .string("x")]).ok)
        for _ in 0..<3 { #expect(call(fresh, "post_message", post).ok) }
        for _ in 0..<20 { #expect(call(fresh, "list_agents", [:]).ok) }
        // No quotas (review turns, Plan 1 turns): unlimited.
        let none = q.tools(nil)
        for _ in 0..<12 { #expect(call(none, "post_message", post).ok) }
    }

    /// Fix 1 Q1: the quotas ride on the credential row, and the counts live in the database per turn, so two servers of one
    /// turn share them. A work or plan credential with none recorded gets the strictest; a review credential has none.
    @Test func quotasRideOnTheCredentialAndCountPerTurn() throws {
        let q = try Q()
        _ = try q.store.transition(agentId: q.eng.id, to: .ready)
        let (_, turn) = try #require(try q.store.beginTurn(agentId: q.eng.id, now: Store.now()))
        let quotas = ModeQuotas(posts: 2, itemsCreated: 1, comments: 4, highRisk: 1)
        let token = try q.store.issueTurnCredential(turnId: turn.id, quotas: quotas)
        let ctx = try #require(q.store.turnCredentialContext(token: token, companyId: q.company.id, agentId: q.eng.id))
        #expect(ctx.quotas == quotas); #expect(ctx.turnId == turn.id); #expect(ctx.kind == "work")
        func server() -> CompanyTools {
            CompanyTools(store: q.store, companyId: q.company.id, agentId: q.eng.id, quotas: ctx.quotas, quotaTurnId: ctx.turnId)
        }
        let a = server(), b = server()
        let post: [String: JSONValue] = ["channel": .string("general"), "text": .string("hi")]
        #expect(!call(a, "post_message", ["channel": .string("nope"), "text": .string("x")]).ok)
        #expect(try q.store.turnQuotaUsed(turnId: turn.id, kind: "posts") == 0, "a failed call gives its unit back")
        #expect(call(a, "post_message", post).ok); #expect(call(b, "post_message", post).ok)
        let refused = call(a, "post_message", post)
        #expect(!refused.ok); #expect(refused.text.contains("2 posts and DMs per turn"))
        #expect(!call(b, "send_dm", ["to": .string("@mgr"), "text": .string("x")]).ok)
        #expect(try q.store.turnQuotaUsed(turnId: turn.id, kind: "posts") == 2)
        // Fail closed: no quotas recorded on a work or plan credential.
        let bare = try q.store.issueTurnCredential(turnId: turn.id)
        #expect(q.store.turnCredentialContext(token: bare, companyId: q.company.id, agentId: q.eng.id)?.quotas == .strictest)
        #expect(ModeQuotas.strictest == ModeQuotas(posts: 3, itemsCreated: 0, comments: 5, highRisk: 0))
        let plan = try q.store.issueTurnCredential(turnId: turn.id, kind: "plan", itemId: "i1")
        #expect(q.store.turnCredentialContext(token: plan, companyId: q.company.id, agentId: q.eng.id)?.quotas == .strictest)
        let review = try q.store.issueTurnCredential(turnId: turn.id, kind: "review", itemId: "i1")
        let rctx = try #require(q.store.turnCredentialContext(token: review, companyId: q.company.id, agentId: q.eng.id))
        #expect(rctx.quotas == nil)
    }

    @Test func subagentCallsShareParentQuota() throws {
        // Every sub-agent and workflow agent of a turn talks to the same MCP server process (p8/p9: one pid), so one counter.
        let q = try Q()
        let tools = q.tools(ModeQuotas(posts: 2, itemsCreated: 0, comments: 0))
        let parent = MCPServer(tools: tools), child = MCPServer(tools: tools)
        func post(_ s: MCPServer, _ id: Int) throws -> Bool {
            let line = try #require(s.handle(line: #"{"jsonrpc":"2.0","id":\#(id),"method":"tools/call","params":{"name":"post_message","arguments":{"channel":"general","text":"x"}}}"#))
            return !line.contains("\"isError\":true")
        }
        #expect(try post(parent, 1)); #expect(try post(child, 2)); #expect(try !post(parent, 3)); #expect(try !post(child, 4))
    }

    @Test func subagentHighRiskCallsQuotaOne() throws {
        let q = try Q()
        var d = ModePolicy.select({ var i = ModeInputs(); i.hasItem = true; i.tier = .s; i.subagentGate = true; return i }())
        #expect(d.quotas.highRisk == 1, "a turn with sub-agents on allows one high-risk company call")
        d.subagents = .off
        let t = q.tools(ModeQuotas(posts: 10, itemsCreated: 3, comments: 20, highRisk: 1), agent: q.mgr)
        let ask: [String: JSONValue] = ["title": .string("Q"), "question": .string("Which?")]
        #expect(call(t, "request_from_owner", ask).ok)
        let second = call(t, "request_from_owner", ask)
        #expect(!second.ok); #expect(second.text.contains("high-risk"))
        #expect(CompanyTools.highRiskTools.isSuperset(of: ["decide", "propose_decision", "escalate_decision", "request_from_owner",
                                                           "request_mode", "plan_sprint", "close_sprint", "confirm_spec"]))
    }

    @Test func planTurnDropsMutatingTools() throws {
        let q = try Q()
        let t = q.tools(ModeCaps.plan.quotas, planTurn: true)
        let names = Set(t.specs().map(\.name))
        for gone in ["claim_lease", "release_lease", "submit_for_review", "update_work_item", "create_work_item", "link_dependency",
                     "write_handoff", "confirm_spec", "decide", "propose_decision", "request_mode", "create_channel", "set_blocked"] {
            #expect(!names.contains(gone), "\(gone)")
        }
        for kept in ["show_work_item", "list_work", "read_channel", "post_message", "comment_work_item"] { #expect(names.contains(kept)) }
        let refused = call(t, "release_lease", ["key": .string("ACME-1")])
        #expect(!refused.ok); #expect(refused.text.contains("plan turn"))
        // Read-only tools say so, so the CLI's plan mode lets them run (probe V-4).
        let show = try #require(t.specs().first { $0.name == "show_work_item" })
        #expect(show.readOnly)
        #expect(!(try #require(t.specs().first { $0.name == "post_message" })).readOnly)
    }
}
