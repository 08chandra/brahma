import ArgumentParser
import Foundation
import BrahmaCore

/// `brahma lab` (Task 10b, I2): the sticky lab mark. Once a session that read outside content has worked in an agent's lab,
/// every extension proposed from it goes to the owner and mounts as third-party; only the owner clears that, here.
struct LabGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "lab", abstract: "Agents' labs: the mark a session that read outside content leaves.",
        subcommands: [LabClearTaint.self])
}

struct LabClearTaint: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "clear-taint",
        abstract: "Clear an agent's lab mark, or the company's (owner only), after you have checked what is in the labs.",
        discussion: "Until then every extension the agent (or, for a company mark, anyone in the company) proposes goes straight "
            + "to you and mounts as third-party. Without an agent the company's mark and every agent's lab mark are cleared.")
    @Argument(help: "Company name or slug.") var company: String
    @Argument(help: "The agent's handle (omit it to clear the company's mark and all of its agents').") var agent: String?

    func run() throws {
        try requireOwnerShell()
        let (store, _) = try openStore()
        let c = try resolveCompany(store, company)
        guard let agent else {
            let cleared: Bool
            do { cleared = try store.clearCompanyLabTaint(companyId: c.id) } catch let e as WorkError { throw fail(e.message) }
            print(safe(cleared ? "cleared \(c.name)'s lab marks" : "\(c.name) carries no lab mark"))
            return
        }
        let a = try resolveAgent(store, company: c, handle: agent)
        let cleared: Bool
        do { cleared = try store.clearLabTaint(companyId: c.id, agentId: a.id) } catch let e as WorkError { throw fail(e.message) }
        print(safe(cleared ? "cleared @\(a.name)'s lab mark" : "@\(a.name)'s lab carries no mark"))
        if try store.companyLabTaint(companyId: c.id) != nil {
            print(safe("\(c.name)'s company mark still applies to every lab: brahma lab clear-taint \(c.slug)"))
        }
    }
}
