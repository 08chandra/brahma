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

    /// `brahma vouch file <company> --id <64 hex> --sha256 <64 hex> [--ambiguous-ok] [<path>]` (C2b fix round 5, Ruling 38;
    /// C2b-carry (b)): the secret gate refused a file for its structure (a PDF whose structure couldn't be verified, a
    /// format or archive method it can't open) and printed this command. The owner vouches for exactly that file and those
    /// bytes in that company (`Store.vouchFile`): the file's id (`--id`, its canonical name's hash) and the refused version's
    /// full sha256 (`--sha256`, breaker B-2 and Ruling 40) bind the vouch, and only the version refused LAST for that file
    /// vouches, so a command printed before the file was rewritten vouches nothing. No name decides which file is vouched:
    /// the name (as the refusal showed it) is optional, checked against the file, and any name collision with another
    /// refused file refuses as ambiguous, listing each file with its own command carrying `--ambiguous-ok`, which only
    /// then vouches that file. A vouched PDF is shared only as a flattened re-render of its visible pages (Ruling 42),
    /// checked again like any file; other files pass the structure check, every byte the gate can read still scanned. Any
    /// change to the file ends the vouch. No taint is cleared. An owner activity line; the refusal's alert is closed.
    struct VouchFile: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "file",
            abstract: "Vouch for a file Brahma refused for its structure (owner only).")
        @Argument(help: "Company name or slug.") var company: String
        @Argument(help: "The file's name as the refusal shows it (optional; checked against the file's id).") var path: String?
        @Option(help: "The file's id (64 hex digits), as the refusal prints it (required).") var id: String
        @Option(help: "The refused version's full sha256 (64 hex digits), as the refusal prints it (required).") var sha256: String
        @Flag(name: .customLong("ambiguous-ok"),
              help: "Vouch for this exact file although its name collides with another refused file's (only as the ambiguity refusal prints it).")
        var ambiguousOK = false

        func run() throws {
            try requireOwnerShell()
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let vouch: FileVouch
            do {
                vouch = try store.vouchFile(companyId: c.id, fileId: id, sha256: sha256, name: path, acknowledgeAmbiguity: ambiguousOK,
                                            now: Date())
            } catch let e as WorkError {
                throw fail(e.message)
            }
            print(safe("\(c.name): vouched for \(vouch.shown) (sha256 \(vouch.sha256.prefix(12))…). " + Store.vouchedLine(vouch)))
        }
    }
}
