import ArgumentParser
import Foundation
import BrahmaCore

// Plan X1 Task 12: model routes. A route says which provider and model serve a model class (deep, standard, fast) for a
// company, one of its roles, or one agent; the agent's own wins over its role's (`actingRole ?? role`), which wins over the
// company's (`RouteResolver`). No route: the runtime default (the subscription, or Anthropic pass-through on an API-key
// company). Showing refuses inside an agent turn (Ruling 21); changing needs the owner shell. Setting a route never runs a
// probe: it queues one (Task 13), and makes no network call.

/// `<class>=<provider>/<model>` (or `<class>=inherit` where allowed): the class and the text after `=`.
private func splitAssignment(_ text: String) throws -> (ModelClass, String) {
    guard let eq = text.firstIndex(of: "="), let c = ModelClass(rawValue: String(text[..<eq])) else {
        throw fail("'\(text)' is not <class>=<provider>/<model>: the class is deep, standard or fast")
    }
    return (c, String(text[text.index(after: eq)...]))
}

/// `<provider>/<model>`, split at the first `/` (a model id may hold more, as `openrouter/vendor/model-1` does).
private func splitTarget(_ text: String) throws -> (provider: String, model: String) {
    guard let slash = text.firstIndex(of: "/"), slash != text.startIndex, text.index(after: slash) != text.endIndex else {
        throw fail("name a model as <provider>/<model>, e.g. anthropic/claude-sonnet-5-5")
    }
    return (String(text[..<slash]), String(text[text.index(after: slash)...]))
}

/// Refuses (with `RouteRules.refusal`'s words) a target the gateway could not serve.
private func requireRoutable(_ store: Store, _ target: (provider: String, model: String)) throws {
    let prices = PriceBook(owner: try store.priceRows())
    if let why = RouteRules.refusal(providerId: target.provider, model: target.model,
                                    provider: try store.provider(id: target.provider), prices: prices) {
        throw fail(why)
    }
}

/// Sets `route` and queues its probe (Task 13) in one transaction, printing one line.
private func setAndQueue(_ store: Store, _ route: ModelRoute, label: String) throws {
    do {
        try store.setRouteQueuingProbe(route, requestedBy: "owner")
    } catch {
        throw fail("\(error)")
    }
    print(safe("\(route.modelClass) → \(route.provider)/\(route.model) for \(label); probe queued"))
}

/// What serves a class and where that was found, or the runtime default.
private func describe(_ r: ResolvedRoute?, role: String?) -> String {
    guard let r else { return "runtime default (no route)" }
    let from: String
    switch r.scope {
    case .company: from = "company"
    case .role: from = "role \(role ?? "")"
    case .agent: from = "agent"
    }
    return safe("\(r.provider)/\(r.model)  (\(from))")
}

/// One class's line of the table.
private func routeLine(_ c: ModelClass, _ r: ResolvedRoute?, role: String?) -> String {
    c.rawValue.padding(toLength: 9, withPad: " ", startingAt: 0) + describe(r, role: role)
}

private let roleRule = "a role is 1-64 of a-z, 0-9, - and _"

private func isRoleName(_ role: String) -> Bool { role.range(of: "^[a-z0-9_-]{1,64}$", options: .regularExpression) != nil }

extension CompanyGroup {
    struct Models: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "models",
            abstract: "Show or set which provider and model serve each model class (deep, standard, fast) for a company or a role.",
            discussion: """
                With no assignment, prints the resolved table: for each class, the route that serves it (the role's, else \
                the company's) or the runtime default. An assignment <class>=<provider>/<model> sets a route (owner only): \
                the provider must exist (`brahma providers`) and the model must have a price (`brahma settings \
                model-price`); search-capable models are refused. `clear` removes every route of the company, or of the \
                role with --role. An agent's own route (`brahma agent model`) wins over its role's, which wins over the \
                company's. Setting a route queues a capability probe; it never runs one here.

                EXAMPLES:
                  brahma company models acme
                  brahma company models acme deep=anthropic/claude-opus-5-5 fast=anthropic/claude-haiku-5-5
                  brahma company models acme --role engineer standard=openrouter/vendor/model-1
                  brahma company models acme clear --role engineer
                """)

        @Argument(help: ArgumentHelp("Company name or slug.", valueName: "company")) var company: String
        @Argument(help: ArgumentHelp("<class>=<provider>/<model> (deep, standard, fast), or `clear`; none to show the table.",
                                     valueName: "assignment"))
        var assignments: [String] = []
        @Option(help: ArgumentHelp("Set, clear or show the routes of this role instead of the company's.", valueName: "role"))
        var role: String?

        func run() throws {
            try refuseInsideAgentTurn()  // first: inside a turn nothing else is checked (Ruling 21)
            if let role, !isRoleName(role) { throw fail(roleRule) }
            guard !assignments.isEmpty else { return try show() }
            let scope: RouteScope = role == nil ? .company : .role
            let subject = role ?? ""
            if assignments.contains("clear") {
                guard assignments == ["clear"] else { throw fail("`clear` takes no assignment") }
                try requireOwnerShell()
                let (store, _) = try openStore()
                let c = try resolveCompany(store, company)
                do { try store.clearRoutes(companyId: c.id, scope: scope, subject: subject) } catch { throw fail("\(error)") }
                print(safe(role.map { "cleared the routes of role \($0) in \(c.name)" } ?? "cleared the company routes of \(c.name)"))
                return
            }
            var parsed: [(ModelClass, (provider: String, model: String))] = []
            for text in assignments {
                let (c, value) = try splitAssignment(text)
                guard !parsed.contains(where: { $0.0 == c }) else { throw fail("\(c.rawValue) is assigned twice") }
                parsed.append((c, try splitTarget(value)))
            }
            try requireOwnerShell()
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            for (_, target) in parsed { try requireRoutable(store, target) }
            let label = role.map { "role \($0) in \(c.name)" } ?? c.name
            for (cls, target) in parsed {
                try setAndQueue(store, ModelRoute(companyId: c.id, scope: scope, subject: subject, modelClass: cls.rawValue,
                                                  provider: target.provider, model: target.model), label: label)
            }
            if let role {
                let held = try store.agents(companyId: c.id).contains { ($0.actingRole ?? $0.role) == role }
                if !held { print(safe("note: no agent in \(c.name) has role \(role) now")) }
            }
        }

        /// The resolved table, then every role and agent route that overrides it.
        private func show() throws {
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let routes = try store.routes(companyId: c.id)
            print(safe(role.map { "model routes for role \($0) in \(c.name)" } ?? "model routes for \(c.name)"))
            for cls in ModelClass.allCases {
                print(routeLine(cls, RouteResolver.resolve(companyId: c.id, role: role, class: cls, routes: routes), role: role))
            }
            let agents = try store.agents(companyId: c.id)
            let overrides = routes.filter { r in
                switch r.scope {
                case .company: false
                case .role: role == nil
                case .agent: role == nil || agents.first { $0.id == r.subject }.map { ($0.actingRole ?? $0.role) == role } == true
                }
            }
            guard !overrides.isEmpty else { return }
            print("overrides:")
            for r in overrides {
                let who = r.scope == .role ? "role \(r.subject)" : "@" + (agents.first { $0.id == r.subject }?.name ?? r.subject)
                print(safe("  \(who)  \(r.modelClass) → \(r.provider)/\(r.model)"))
            }
        }
    }
}

/// `brahma agent …`: per-agent settings. X1 adds `model`.
struct AgentGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agent",
        abstract: "Per-agent settings.",
        discussion: """
            EXAMPLES:
              brahma agent model acme eng-1 deep=anthropic/claude-opus-5-5
              brahma agent model acme eng-1 deep=inherit
            """,
        subcommands: [Model.self])

    struct Model: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Route one model class for one agent (owner only), or make it inherit its role's or company's route again.",
            discussion: """
                <class>=<provider>/<model> sets the agent's own route for the class (deep, standard or fast); it wins over \
                its role's and its company's. <class>=inherit removes it. The provider must exist and the model must have a \
                price (`brahma settings model-price`); search-capable models are refused. Setting a route queues a \
                capability probe; it never runs one here.

                EXAMPLES:
                  brahma agent model acme eng-1 deep=anthropic/claude-opus-5-5
                  brahma agent model acme @eng-1 fast=openai/example-model
                  brahma agent model acme eng-1 deep=inherit
                """)

        @Argument(help: ArgumentHelp("Company name or slug.", valueName: "company")) var company: String
        @Argument(help: ArgumentHelp("Agent handle.", valueName: "handle")) var handle: String
        @Argument(help: ArgumentHelp("<class>=<provider>/<model> or <class>=inherit.", valueName: "assignment")) var assignment: String

        func run() throws {
            try refuseInsideAgentTurn()  // first (Ruling 21)
            let (cls, value) = try splitAssignment(assignment)
            let target = value == "inherit" ? nil : try splitTarget(value)
            try requireOwnerShell()
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let agent = try resolveAgent(store, company: c, handle: handle)
            guard let target else {
                do {
                    try store.clearRoute(companyId: c.id, scope: .agent, subject: agent.id, modelClass: cls.rawValue)
                } catch {
                    throw fail("\(error)")
                }
                let now = RouteResolver.resolve(agent: agent, class: cls, routes: try store.routes(companyId: c.id))
                print(safe("\(cls.rawValue) for @\(agent.name) inherits: ") + describe(now, role: agent.actingRole ?? agent.role))
                return
            }
            try requireRoutable(store, target)
            try setAndQueue(store, ModelRoute(companyId: c.id, scope: .agent, subject: agent.id, modelClass: cls.rawValue,
                                              provider: target.provider, model: target.model), label: "@\(agent.name) in \(c.name)")
        }
    }
}
