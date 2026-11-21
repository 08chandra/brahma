import ArgumentParser
import Foundation
import BrahmaCore

/// `brahma vouch …`: the owner vouches for what Brahma could not verify (Plan C P2, Ruling 26; C2b, Ruling 38). Owner only
/// (`requireOwnerShell`: refused from an agent's shell, `BRAHMA_AGENT_ID`, and without the owner key); no agent tool reaches it.
struct VouchGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vouch",
        abstract: "Vouch for what Brahma could not verify (owner only).",
        subcommands: [VouchRestore.self, VouchFile.self])

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

    /// `brahma vouch file <company> <path>` (C2b fix round 5, Ruling 38): the secret gate refused a file for its structure
    /// (a PDF whose structure couldn't be verified, a format or archive method it can't open) and named this command. The
    /// owner vouches for exactly the bytes it refused under that name in that company (`Store.vouchFile`; `--sha256` picks
    /// one when the name was refused as more than one version): those bytes then pass the structure check, while every
    /// byte the gate can read is still scanned for stored secrets and secret patterns. Any change to the file ends the
    /// vouch. No taint is cleared. An owner activity line; the refusal's alert is closed.
    struct VouchFile: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "file",
            abstract: "Vouch for a file Brahma refused for its structure (owner only).")
        @Argument(help: "Company name or slug.") var company: String
        @Argument(help: "The file's name as the refusal shows it.") var path: String
        @Option(help: "The refused version's sha256 (at least 12 hex digits), when there is more than one.") var sha256: String?

        func run() throws {
            try requireOwnerShell()
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let vouch: FileVouch
            do {
                vouch = try store.vouchFile(companyId: c.id, canonical: path, sha256: sha256, now: Date())
            } catch let e as WorkError {
                throw fail(e.message)
            }
            print(safe("\(c.name): vouched for \(vouch.shown) (sha256 \(vouch.sha256.prefix(12))…). Brahma passes these exact bytes "
                       + "past its structure check and still refuses a stored secret or a secret pattern it can read in them; "
                       + "any change to the file ends the vouch."))
        }
    }
}
