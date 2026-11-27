import ArgumentParser
import Foundation
import BrahmaCore

// Owner commands for access grants (Task 9): the open access asks, approving one with a scope and duration, the grant
// ledger, revoking, and the access presets. Every one of them is owner-only. Rejecting an access ask is `brahma approve
// <co> A-<n> --reject`.

extension GrantScope: ExpressibleByArgument {}
extension GrantDuration: ExpressibleByArgument {}

/// `brahma access <co>` and `brahma access approve <co> A-<n> --scope … --duration …`.
struct AccessGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "access",
        abstract: "Agents' access requests: list the open ones, or approve one with a scope and duration.",
        discussion: "Reject one with 'brahma approve <co> A-<n> --reject'.",
        subcommands: [AccessList.self, AccessApprove.self], defaultSubcommand: AccessList.self)
}

struct AccessList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "The open access requests of a company.")

    @Argument(help: "Company name or slug.") var company: String

    func run() throws {
        try requireOwnerShell()
        let (store, _) = try openStore()
        let c = try resolveCompany(store, company)
        let open = try store.asks(companyId: c.id, statuses: [.pendingInternal, .pendingOwner]).filter { $0.kind == .grant }
        let handles = Dictionary(try store.agents(companyId: c.id).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        if open.isEmpty { print(safe("\(c.name): no open access requests")) }
        for ask in open {
            let wanted = Grants.requested(ask)
            let who = handles[ask.requesterId].map { "@\($0)" } ?? ask.requesterId
            let wildcard = wanted?.value.hasPrefix("*.") == true ? "  [WILDCARD: every subdomain]" : ""
            print(safe("\(ask.ref)  \(ask.title)\(wildcard)  \(who)  risk \(ask.risk.rawValue)  "
                       + "asks for scope \(ask.proposedGrant?.scope ?? "agent"), duration \(wanted?.duration.rawValue ?? "?")"))
            if !ask.summary.isEmpty { print(safe("    | " + ask.summary.replacingOccurrences(of: "\n", with: "\n    | "))) }
        }
        if !open.isEmpty {
            print("Approve: brahma access approve \(c.slug) A-<n> --scope once|item|agent|role|company --duration turn|sprint|always")
        }
        let refused = try store.accessRefusals(companyId: c.id, limit: 10)
        if !refused.isEmpty {
            print("Refused requests (newest first):")
            for r in refused {
                print(safe("  @\(handles[r.agentId] ?? "?")  \(r.kind) \(r.value)  \(r.detail)"))
            }
        }
    }
}

struct AccessApprove: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "approve", abstract: "Approve an access request as a grant.")

    @Argument(help: "Company name or slug.") var company: String
    @Argument(help: "Ask reference, e.g. A-3.") var ask: String
    @Option(help: "once, item, agent, role or company (required: the agent's proposal is only shown in 'brahma access').")
    var scope: GrantScope
    @Option(help: "turn, sprint or always (required).") var duration: GrantDuration
    @Option(help: "Why.") var note: String = ""

    func run() throws {
        let owner = try requireOwnerShell()
        let (store, _) = try openStore()
        let c = try resolveCompany(store, company)
        guard let a = try store.ask(companyId: c.id, ref: ask) else { throw fail("no ask \(ask) in \(c.name)") }
        let grant: Grant
        do { grant = try store.approveAccess(askId: a.id, scope: scope, duration: duration, note: note, owner: owner) } catch let e as WorkError {
            throw fail(e.message)
        } catch {
            throw fail("\(error)")
        }
        print(safe("\(a.ref) approved: \(grant.ref) \(grant.kind.rawValue) \(grant.value) (\(grant.scope.rawValue), \(grant.duration.rawValue))"))
    }
}

/// `brahma grants <co> [--all]` and `brahma grants revoke <co> G-<n>`.
struct GrantsGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "grants",
        abstract: "The grant ledger: list the live grants (--all: every grant), or revoke one.",
        subcommands: [GrantsList.self, GrantsRevoke.self], defaultSubcommand: GrantsList.self)
}

struct GrantsList: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "list", abstract: "A company's grants.")

    @Argument(help: "Company name or slug.") var company: String
    @Flag(help: "Every grant, also revoked, expired and used-up ones.") var all = false

    func run() throws {
        try requireOwnerShell()
        let (store, _) = try openStore()
        let c = try resolveCompany(store, company)
        let grants = try store.grants(companyId: c.id, includeInactive: all)
        let live = Set(try store.grants(companyId: c.id).map(\.id))
        guard !grants.isEmpty else { print(safe("\(c.name): no \(all ? "" : "live ")grants")); return }
        let handles = Dictionary(try store.agents(companyId: c.id).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
        for g in grants {
            let target: String
            switch g.scope {
            case .agent: target = "@" + (g.scopeRef.flatMap { handles[$0] } ?? "?")
            case .once: target = "once @" + (g.requesterId.flatMap { handles[$0] } ?? "?")
            case .role: target = "role \(g.scopeRef ?? "?")"
            case .item: target = "item \(g.scopeRef.flatMap { try? store.workItem(id: $0)?.key } ?? "?")"
            case .company: target = "company"
            }
            var state = live.contains(g.id) ? "live" : (g.revokedAt != nil ? "revoked by \(g.revokedBy ?? "?")" : "inactive")
            if let uses = g.usesLeft { state += ", \(uses) use\(uses == 1 ? "" : "s") left" }
            print(safe("\(g.ref)  \(g.kind.rawValue) \(g.value)  \(target)  \(g.duration.rawValue)  by \(g.approvedBy)  "
                       + "used \(g.useCount)×  \(state)"))
        }
    }
}

struct GrantsRevoke: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "revoke", abstract: "Revoke a grant; it is gone from the next turn.")

    @Argument(help: "Company name or slug.") var company: String
    @Argument(help: "Grant reference, e.g. G-3.") var grant: String

    func run() throws {
        try requireOwnerShell()
        let (store, _) = try openStore()
        let c = try resolveCompany(store, company)
        var text = grant.trimmingCharacters(in: .whitespaces).lowercased()
        if text.hasPrefix("g-") { text.removeFirst(2) }
        guard let number = Int(text) else { throw fail("expected a grant like G-3") }
        do {
            let g = try store.revokeGrant(companyId: c.id, number: number, by: "owner")
            print(safe("\(g.ref) revoked: \(g.kind.rawValue) \(g.value)"))
        } catch let e as WorkError {
            throw fail(e.message)
        }
    }
}

extension AccessPreset: ExpressibleByArgument {}

/// `brahma presets <co> [enable|disable <id>]`.
struct Presets: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show or turn on/off a company's access presets (both off by default).",
        discussion: """
            readonly-web-engineers  engineers, QA, DevOps, security and architects may read well-known docs sites (exact hosts)
            auto-low-risk           under the auto autonomy preset, low-risk web reads are approved for the sprint
            Neither ever approves a medium or high risk or a reserved matter.
            """)

    @Argument(help: "Company name or slug.") var company: String
    @Argument(help: "enable|disable <preset id>.") var words: [String] = []

    func validate() throws {
        guard words.isEmpty || (words.count == 2 && ["enable", "disable"].contains(words[0])) else {
            throw ValidationError("expected nothing or 'enable|disable <preset>'")
        }
        if words.count == 2, AccessPreset(rawValue: words[1]) == nil {
            throw ValidationError("no preset '\(words[1])'; presets: \(AccessPreset.allCases.map(\.rawValue).joined(separator: ", "))")
        }
    }

    func run() throws {
        let owner = try requireOwnerShell()
        let (store, _) = try openStore()
        let c = try resolveCompany(store, company)
        if words.count == 2, let preset = AccessPreset(rawValue: words[1]) {
            try store.setPreset(companyId: c.id, preset, enabled: words[0] == "enable", owner: owner)
        }
        let on = try store.enabledPresets(companyId: c.id)
        print(safe(c.name))
        for preset in AccessPreset.allCases { print("  \(preset.rawValue)  \(on.contains(preset) ? "on" : "off")") }
    }
}
