import ArgumentParser
import Foundation
import BrahmaCore

/// `brahma company profile <co> sandboxed|workspace|full [--role <id>]`: the profile a company's agent turns run under.
struct CompanyProfile: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "profile",
        abstract: "Set the profile a company's agent turns run under: sandboxed (the default), workspace or full.",
        discussion: "sandboxed confines each turn to its own places in the workspace; workspace lets the agent's shell run "
            + "anywhere you can; WARNING: full gives agents access to your whole Mac. With --role, only that role's agents. "
            + "'brahma run --profile' can only narrow these, never widen them.")

    @Argument var company: String
    @Argument(help: "sandboxed, workspace or full.") var profile: PermissionProfile
    @Option(help: "A role id: only this role's agents (overrides the company's profile for them).") var role: String?

    func run() throws {
        try requireOwnerShell()
        let (store, _) = try openStore()
        let c = try resolveCompany(store, company)
        if let role {
            let agents = try store.agents(companyId: c.id)
            let known = store.catalog.pack(c.packId)?.role(role) != nil || agents.contains { $0.role == role }
            guard known else { throw fail(SandboxEditError.unknownRole(role).description) }
        }
        do { try store.updateSandbox(companyId: c.id, .profile(profile, role: role, company: c)) } catch { throw fail("\(error)") }
        let updated = try store.company(id: c.id) ?? c
        let target = role.map { "role \($0)" } ?? "every agent"
        print(safe("\(updated.name): \(target) runs \(profile.rawValue)" + (profile == .full ? " (WARNING: the whole Mac)" : "")))
    }
}

/// `brahma network <co>` and its edits: the domains and paths a company's sandboxed turns may reach.
struct Network: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Show or change what a company's sandboxed turns may reach.",
        discussion: """
            brahma network <co>                          list the effective lists (defaults marked)
            brahma network <co> add|rm <domain> [--web]  Bash egress domain (--web: WebFetch domain)
            brahma network <co> local on|off             whether agents may listen on loopback
            brahma network <co> toolchain add|rm <path>  an extra read-only toolchain path (absolute or ~/...)
            """)

    @Argument var company: String
    @Argument(help: "add|rm <domain>, local on|off, or toolchain add|rm <path>.") var words: [String] = []
    @Flag(help: "The WebFetch list instead of Bash egress.") var web = false

    enum Action: Equatable {
        case list
        case domain(SandboxListEdit)
        case local(Bool)
        case toolchain(SandboxListEdit)
    }

    static func action(_ words: [String], web: Bool) throws -> Action {
        switch words.count {
        case 0: return .list
        case 2 where words[0] == "add": return .domain(.add(words[1]))
        case 2 where words[0] == "rm": return .domain(.remove(words[1]))
        case 2 where words[0] == "local" && !web:
            switch words[1] {
            case "on": return .local(true)
            case "off": return .local(false)
            default: break
            }
        case 3 where words[0] == "toolchain" && !web:
            switch words[1] {
            case "add": return .toolchain(.add(words[2]))
            case "rm": return .toolchain(.remove(words[2]))
            default: break
            }
        default: break
        }
        throw ValidationError("expected nothing, 'add|rm <domain>', 'local on|off' or 'toolchain add|rm <path>'"
                              + (web ? " (--web goes only with add|rm)" : ""))
    }

    func validate() throws { _ = try Self.action(words, web: web) }

    func run() throws {
        let action = try Self.action(words, web: web)
        if action != .list { try requireOwnerShell() }
        let (store, _) = try openStore()
        let c = try resolveCompany(store, company)
        let patch: SandboxPatch
        do {
            switch action {
            case .list:
                print(safe(c.name))
                for line in CompanyNetwork.listing(company: c) { print(safe(line)) }
                return
            case .domain(let edit): patch = try .domains(edit, web: web, company: c)
            case .local(let on): patch = SandboxPatch(allowLocalBinding: on)
            case .toolchain(let edit): patch = try .toolchain(edit, company: c)
            }
            try store.updateSandbox(companyId: c.id, patch)
        } catch {
            throw fail("\(error)")
        }
        let updated = try store.company(id: c.id) ?? c
        print(safe(updated.name))
        for line in CompanyNetwork.listing(company: updated) { print(safe(line)) }
    }
}
