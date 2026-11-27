import Testing
import Foundation
@testable import BrahmaCore

// Plan X1 Task 12: which route serves a model class for an agent — its own, then its role's (`actingRole ?? role`), then its
// company's; nil is the runtime default.

private func agent(id: String = "a1", company: String = "c1", role: String = "engineer", acting: String? = nil) -> Agent {
    var a = Agent(id: id, companyId: company, name: "eng-1", role: role, model: "sonnet", sessionId: "s", sessionStarted: false,
                  state: .running, blocker: nil, requestedBlocker: nil, paused: false, readySince: nil,
                  createdAt: Date(timeIntervalSince1970: 0))
    a.actingRole = acting
    return a
}

private func route(_ scope: RouteScope, _ subject: String, _ c: ModelClass, _ target: String, company: String = "c1") -> ModelRoute {
    let parts = target.split(separator: "/", maxSplits: 1).map(String.init)
    return ModelRoute(companyId: company, scope: scope, subject: subject, modelClass: c.rawValue, provider: parts[0], model: parts[1])
}

@Suite struct RouteResolverTests {
    @Test func agentBeatsRoleBeatsCompany() {
        let company = route(.company, "", .deep, "anthropic/claude-opus-5-5")
        let role = route(.role, "engineer", .deep, "openai/role-model")
        let own = route(.agent, "a1", .deep, "openrouter/vendor/agent-model")
        let a = agent()
        #expect(RouteResolver.resolve(agent: a, class: .deep, routes: [company])
                == ResolvedRoute(provider: "anthropic", model: "claude-opus-5-5", scope: .company))
        #expect(RouteResolver.resolve(agent: a, class: .deep, routes: [company, role])
                == ResolvedRoute(provider: "openai", model: "role-model", scope: .role))
        // Order in the list never matters; only scope does.
        for routes in [[company, role, own], [own, role, company], [role, own, company]] {
            #expect(RouteResolver.resolve(agent: a, class: .deep, routes: routes)
                    == ResolvedRoute(provider: "openrouter", model: "vendor/agent-model", scope: .agent))
        }
        // Another agent's or another role's route never applies; a class resolves on its own.
        let other = agent(id: "a2", role: "designer")
        #expect(RouteResolver.resolve(agent: other, class: .deep, routes: [company, role, own])?.scope == .company)
        #expect(RouteResolver.resolve(agent: a, class: .standard, routes: [company, role, own]) == nil)
    }

    @Test func actingRoleUsed() {
        let routes = [route(.role, "engineer", .fast, "openai/eng-fast"), route(.role, "cto", .fast, "openai/cto-fast")]
        #expect(RouteResolver.resolve(agent: agent(), class: .fast, routes: routes)?.model == "eng-fast")
        #expect(RouteResolver.resolve(agent: agent(acting: "cto"), class: .fast, routes: routes)?.model == "cto-fast")
        // Acting as a role with no route: its own role's is not used (the acting role replaces it), the company's is.
        let withCompany = routes + [route(.company, "", .fast, "anthropic/claude-haiku-5-5")]
        #expect(RouteResolver.resolve(agent: agent(acting: "ceo"), class: .fast, routes: withCompany)?.scope == .company)
    }

    @Test func noRouteIsNil() {
        #expect(RouteResolver.resolve(agent: agent(), class: .deep, routes: []) == nil)
        // Another company's routes, however well they match, are never this agent's.
        let foreign = [route(.company, "", .deep, "openai/x", company: "c2"), route(.agent, "a1", .deep, "openai/y", company: "c2"),
                       route(.role, "engineer", .deep, "openai/z", company: "c2")]
        #expect(RouteResolver.resolve(agent: agent(), class: .deep, routes: foreign) == nil)
        // A route for a class this plan does not know never matches a known one.
        let unknown = ModelRoute(companyId: "c1", scope: .company, subject: "", modelClass: "huge", provider: "openai", model: "x")
        for c in ModelClass.allCases { #expect(RouteResolver.resolve(agent: agent(), class: c, routes: [unknown]) == nil) }
    }

    /// Ruling 59: search-capable model ids are refused on routes; Ruling 62: an unknown provider, a refused provider record
    /// and an unpriced model too, each with its reason.
    @Test func routeRules() throws {
        for model in ["vendor/model:online", "gpt-x-search-preview", "Search-1", "vendor/web-SEARCH"] {
            #expect(RouteRules.isSearchCapable(model), "\(model)")
        }
        for model in ["claude-opus-5-5", "vendor/model", "vendor/model:free", "online-1"] {
            #expect(!RouteRules.isSearchCapable(model), "\(model)")
        }
        let prices = PriceBook(owner: [])
        let anthropic = try #require(Provider.builtins.first { $0.id == "anthropic" })
        #expect(RouteRules.refusal(providerId: "anthropic", model: "claude-opus-5-5", provider: anthropic, prices: prices) == nil)
        #expect(RouteRules.refusal(providerId: "nope", model: "m", provider: nil, prices: prices)?.contains("no such provider: nope") == true)
        let unpriced = try #require(RouteRules.refusal(providerId: "anthropic", model: "claude-x", provider: anthropic, prices: prices))
        #expect(unpriced.contains("brahma settings model-price anthropic/claude-x <usd-in> <usd-out>"), "\(unpriced)")
        let priced = PriceBook(owner: [PriceRow(provider: "openrouter", model: "vendor/m:online", inPerMTok: 1, outPerMTok: 2,
                                                cacheReadPerMTok: nil, cacheWritePerMTok: nil, setBy: "owner")])
        let openrouter = try #require(Provider.builtins.first { $0.id == "openrouter" })
        #expect(RouteRules.refusal(providerId: "openrouter", model: "vendor/m:online", provider: openrouter, prices: priced)?
                    .contains("search") == true, "priced, but search-capable")
        var tampered = anthropic
        tampered.baseURL = URL(string: "https://evil.example.com")!
        tampered.host = "evil.example.com"
        #expect(RouteRules.refusal(providerId: "anthropic", model: "claude-opus-5-5", provider: tampered, prices: prices)?
                    .hasPrefix("provider anthropic is refused") == true)
    }
}
