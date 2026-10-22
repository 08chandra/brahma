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
            try requireOwnerShell()
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            do { try store.acceptMainCommit(companyId: c.id, ref: ref) } catch let e as WorkError { throw fail(e.message) }
            let head = try store.company(id: c.id)?.mainCommit ?? "?"
            if let ref {
                print(safe("\(c.name): \(ref) merged; main is at \(head.prefix(7))"))
            } else {
                print(safe("\(c.name): main accepted at \(head.prefix(7))"))
            }
        }
    }
}
