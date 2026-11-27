import ArgumentParser
import Foundation
import BrahmaCore

/// `brahma vouch …`: the owner vouches for what Brahma could not verify (Plan C P2, Ruling 26; C2b, Ruling 38). Owner only
/// (`requireOwnerShell`: refused from an agent's shell, `BRAHMA_AGENT_ID`, and without the owner key); no agent tool reaches it.
struct VouchGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "vouch",
        abstract: "Vouch for what Brahma could not verify (owner only).",
        subcommands: [VouchRestore.self, VouchFile.self, VouchTaintHold.self])

    /// `brahma vouch restore <company> [--epoch <id>]… [--all]`: after a restore over a database that could not be read, every
    /// commit the restored database can't place reads as outside content (a restore epoch). This lists the company's open
    /// epochs and clears the ones named, with the commit rows they recorded (`Store.vouchRestoredCommits`; each clearing
    /// sequenced, an owner activity line). Final wave B1, Ruling 28: the vouch binds to the exact epochs listed: with one open
    /// epoch it is that one; with more, `--epoch <id>` (repeatable) or `--all` (every epoch this command listed) is required,
    /// and an epoch opened after the listing stays open. A turn's own tainted commits are not cleared here: they clear through
    /// review or the item's vouch.
    struct VouchRestore: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "restore",
            abstract: "List and clear a restore's unplaced-commit taint in a company (owner only).")
        @Argument(help: "Company name or slug.") var company: String
        @Option(name: .customLong("epoch"), help: "A restore epoch id, as listed (repeatable).") var epochs: [String] = []
        @Flag(help: "Every open restore epoch listed.") var all = false

        func run() throws {
            let owner = try requireOwnerShell()
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let open = try store.openRestoreEpochList(companyId: c.id)
            guard !open.isEmpty else {
                print(safe("\(c.name): no restore left anything to vouch for."))
                return
            }
            print(safe("\(c.name): open restore epochs:"))
            for e in open { print(safe("  \(e.id)  restored \(e.createdAt.formatted(.iso8601))  \(e.source)")) }
            let chosen: [String]
            if all {
                guard epochs.isEmpty else { throw fail("give --epoch <id> or --all, not both") }
                chosen = open.map(\.id)
            } else if !epochs.isEmpty {
                let ids = Set(open.map(\.id))
                for e in epochs where !ids.contains(e) { throw fail("\(e) is not an open restore epoch of \(c.name)") }
                chosen = epochs
            } else if open.count == 1 {
                chosen = [open[0].id]
            } else {
                throw fail("\(c.name) has \(open.count) open restore epochs: name the ones to vouch for with --epoch <id>, or --all")
            }
            let cleared = try store.vouchRestoredCommits(companyId: c.id, epochIds: chosen, now: Date(), owner: owner)
            if cleared.epochs == 0 && cleared.commits == 0 {
                print(safe("\(c.name): nothing left to vouch for in the epochs named."))
            } else {
                print(safe("\(c.name): vouched for the commits a restore could not place (\(cleared.epochs) restore(s), "
                           + "\(cleared.commits) commit(s)); they now read by the usual rules."))
            }
        }
    }

    /// `brahma vouch taint-hold <company>` (final wave B1, Ruling 23): a turn's taint could not be recorded at its end, so the
    /// company is held (no turn, dispatch or merge) while the engine retries the record. The owner clears the hold here,
    /// accepting that what those turns' records lack stays unrecorded (`Store.clearTaintHolds`).
    struct VouchTaintHold: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "taint-hold",
            abstract: "Clear a company's hold for a taint record that could not be written (owner only).")
        @Argument(help: "Company name or slug.") var company: String

        func run() throws {
            let owner = try requireOwnerShell()
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let cleared = try store.clearTaintHolds(companyId: c.id, now: Date(), owner: owner)
            print(safe(cleared == 0 ? "\(c.name): no taint hold to clear." : "\(c.name): cleared the taint hold (\(cleared) turn(s)); turns may start again."))
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
