import ArgumentParser
import Foundation
import BrahmaCore

/// `brahma vouch …`: the owner vouches for what Brahma could not verify (Plan C P2, Ruling 26). Owner only
/// (`requireOwnerShell`: refused from an agent's shell, `BRAHMA_AGENT_ID`, and without the owner key); no agent tool reaches it.
struct VouchGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vouch",
        abstract: "Vouch for what Brahma could not verify (owner only).",
        subcommands: [VouchRestore.self])

    /// `brahma vouch restore <company>`: after a restore over a database that could not be read, every commit the restored
    /// database can't place reads as outside content (a restore epoch). This clears the company's epochs and the commit rows
    /// they recorded (`Store.vouchRestoredCommits`; each clearing sequenced, an owner activity line). A turn's own tainted
    /// commits are not cleared here: they clear through review or the item's vouch.
    struct VouchRestore: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "restore",
            abstract: "Clear a restore's unplaced-commit taint in a company (owner only).")
        @Argument(help: "Company name or slug.") var company: String

        func run() throws {
            try requireOwnerShell()
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let cleared = try store.vouchRestoredCommits(companyId: c.id, now: Date())
            if cleared.epochs == 0 && cleared.commits == 0 {
                print(safe("\(c.name): no restore left anything to vouch for."))
            } else {
                print(safe("\(c.name): vouched for the commits a restore could not place (\(cleared.epochs) restore(s), "
                           + "\(cleared.commits) commit(s)); they now read by the usual rules."))
            }
        }
    }
}
