import ArgumentParser
import Foundation
import BrahmaCore

struct MainGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "main", abstract: "The main branch of a company's workspace.", subcommands: [Accept.self])

    struct Accept: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "accept",
            abstract: "Accept main as it is now, after it changed outside Brahma, or merge a quarantine of the main checkout into it (owner only). Claims and merges start again.")
        @Argument var company: String
        @Argument(help: "A quarantine ref (refs/brahma/quarantine/<yyyyMMdd-HHmmss>) Brahma asked you about: the commit it recorded on that ask is merged into main (refused if the ref has moved).") var ref: String?

        func run() throws {
            let owner = try requireOwnerShell()
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let accepted: MainAcceptance
            do { accepted = try store.acceptMainCommit(companyId: c.id, ref: ref, owner: owner) } catch let e as WorkError { throw fail(e.message) }
            let head = accepted.head.prefix(7)
            if let ref {
                // How Brahma's quarantine ask stands (A2): merged before, decided earlier, or settled by this accept.
                let state = accepted.ask.map { " (\($0.ref) \($0.status.rawValue))" } ?? ""
                if accepted.alreadyMerged {
                    print(safe("\(c.name): \(ref) is already merged\(state); main is at \(head)"))
                } else {
                    print(safe("\(c.name): \(ref) merged\(state); main is at \(head)"))
                }
            } else {
                print(safe("\(c.name): main accepted at \(head)"))
            }
        }
    }
}
