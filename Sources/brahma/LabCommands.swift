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
        abstract: "Clear an agent's lab mark (owner only), after you have checked what is in its lab.",
        discussion: "Until then every extension the agent proposes goes straight to you and mounts as third-party.")
    @Argument(help: "Company name or slug.") var company: String
    @Argument(help: "The agent's handle.") var agent: String

    func run() throws {
        try requireOwnerShell()
        let (store, _) = try openStore()
        let c = try resolveCompany(store, company)
        let a = try resolveAgent(store, company: c, handle: agent)
        let cleared: Bool
        do { cleared = try store.clearLabTaint(companyId: c.id, agentId: a.id) } catch let e as WorkError { throw fail(e.message) }
        print(safe(cleared ? "cleared @\(a.name)'s lab mark" : "@\(a.name)'s lab carries no mark"))
    }
}
