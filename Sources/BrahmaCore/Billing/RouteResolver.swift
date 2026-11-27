import Foundation

/// The route that serves one model class for one agent (Plan X1 Task 12): a provider, that provider's model id, and the scope
/// it was found at. A nil `ResolvedRoute` means the runtime default (no route: the subscription, or Anthropic pass-through).
public struct ResolvedRoute: Equatable, Sendable {
    public var provider: String
    public var model: String
    public var scope: RouteScope

    public init(provider: String, model: String, scope: RouteScope) {
        self.provider = provider; self.model = model; self.scope = scope
    }
}

/// Which route serves a class: the agent's own, then its role's (`actingRole ?? role`), then the company's.
public enum RouteResolver {
    public static func resolve(agent: Agent, class c: ModelClass, routes: [ModelRoute]) -> ResolvedRoute? {
        resolve(companyId: agent.companyId, role: agent.actingRole ?? agent.role, agentId: agent.id, class: c, routes: routes)
    }

    /// The same order for a role (or the company alone when `role` is nil) with no agent: what `brahma company models`
    /// shows. Only `companyId`'s routes count, whatever else `routes` holds.
    public static func resolve(companyId: String, role: String?, agentId: String? = nil, class c: ModelClass,
                               routes: [ModelRoute]) -> ResolvedRoute? {
        let candidates = routes.filter { $0.companyId == companyId && $0.modelClass == c.rawValue }
        func at(_ scope: RouteScope, _ subject: String?) -> ResolvedRoute? {
            guard let subject, let r = candidates.first(where: { $0.scope == scope && $0.subject == subject }) else { return nil }
            return ResolvedRoute(provider: r.provider, model: r.model, scope: scope)
        }
        return at(.agent, agentId) ?? at(.role, role) ?? at(.company, "")
    }
}

/// What a route must name before it is set (Plan X1 Task 12, Rulings 59 and 62): shared by `brahma company models` and
/// `brahma agent model`; Task 13's probe applies `isSearchCapable` too.
public enum RouteRules {
    /// A model id that lets the provider search the web for the model (OpenRouter's `:online` suffix, `*search*` ids such as
    /// `*-search-preview`): network access the tool policy cannot see. Refused on routes in X1 (Ruling 59).
    public static func isSearchCapable(_ model: String) -> Bool {
        model.lowercased().hasSuffix(":online") || model.lowercased().contains("search")
    }

    /// Why `providerId`/`model` may not be routed, or nil: an unknown provider; a provider record `ProviderHost.validate`
    /// refuses with its key secret (the gateway would refuse it anyway); a search-capable model; a model with no price (the
    /// gateway refuses an unpriced model), with the command that prices it.
    public static func refusal(providerId: String, model: String, provider: Provider?, prices: PriceBook) -> String? {
        guard let provider else { return "no such provider: \(providerId) (see `brahma providers`)" }
        guard !model.isEmpty else { return "name a model as <provider>/<model>, e.g. anthropic/claude-sonnet-5-5" }
        if case .failure(let why) = ProviderHost.validate(baseURL: provider.baseURL, adapter: AdapterId(rawValue: provider.adapter),
                                                          lan: provider.lan, keySecret: provider.keySecret) {
            return "provider \(provider.id) is refused: \(why.reason)"
        }
        if isSearchCapable(model) {
            return "\(providerId)/\(model) lets the provider search the web for the model, which agent tool rules cannot see; "
                + "search-capable models are not routed"
        }
        if prices.price(provider: providerId, model: model) == nil {
            return "\(providerId)/\(model) has no price, so the gateway would refuse it: "
                + "run `brahma settings model-price \(providerId)/\(model) <usd-in> <usd-out>` first"
        }
        return nil
    }
}
