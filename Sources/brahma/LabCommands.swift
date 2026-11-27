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
    @Argument(help: "Company name or slug (not with --machine-wide).") var company: String?
    @Argument(help: "The agent's handle (omit it to clear the company's mark and all of its agents').") var agent: String?
    @Flag(name: .customLong("machine-wide"),
          help: "Clear the machine-wide mark a Full-profile session left (it could write any company's labs).") var machineWide = false

    func run() throws {
        let owner = try requireOwnerShell()
        let (store, paths) = try openStore()
        if machineWide {
            guard company == nil, agent == nil else { throw fail("--machine-wide takes no company or agent") }
            // One critical section under the engine lock: refused while a tainted session is active; every lab-like repository
            // of every workspace is snapshotted tainted before the mark goes.
            let cleared: Bool
            do { cleared = try LabProvenance.clearMachineMark(store: store, paths: paths, owner: owner) } catch let e as LabProvenance.ClearRefused {
                throw fail("refused: \(e.message)")
            }
            print(safe(cleared
                ? "cleared the machine-wide lab mark. A Full-profile session that read outside content could write ANY company's "
                  + "labs: review every company's labs before trusting what they propose; their commits from before now stay tainted."
                : "no machine-wide lab mark stands"))
            return
        }
        guard let company else { throw fail("name a company, or use --machine-wide") }
        let c = try resolveCompany(store, company)
        guard let agent else {
            let cleared: Bool
            do { cleared = try LabProvenance.clearCompanyMark(store: store, paths: paths, companyId: c.id, owner: owner) }
            catch let e as LabProvenance.ClearRefused { throw fail("refused: \(e.message)") }
            catch let e as WorkError { throw fail(e.message) }
            print(safe(cleared ? "cleared \(c.name)'s lab marks" : "\(c.name) carries no lab mark"))
            if try store.machineLabTaint()?.source != nil {
                print("the machine-wide mark still applies to every lab: brahma lab clear-taint --machine-wide")
            }
            return
        }
        let a = try resolveAgent(store, company: c, handle: agent)
        let cleared: Bool
        do { cleared = try store.clearLabTaint(companyId: c.id, agentId: a.id, owner: owner) } catch let e as WorkError { throw fail(e.message) }
        print(safe(cleared ? "cleared @\(a.name)'s lab mark" : "@\(a.name)'s lab carries no mark"))
        if try store.companyLabTaint(companyId: c.id) != nil {
            print(safe("\(c.name)'s company mark still applies to every lab: brahma lab clear-taint \(c.slug)"))
        }
        if try store.machineLabTaint()?.source != nil {
            print("the machine-wide mark still applies to every lab: brahma lab clear-taint --machine-wide")
        }
    }
}
