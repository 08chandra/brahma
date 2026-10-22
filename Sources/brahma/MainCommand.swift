import ArgumentParser
import Foundation
import BrahmaCore

struct MainGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "main", abstract: "The main branch of a company's workspace.", subcommands: [Accept.self])

    struct Accept: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "accept",
            abstract: "Accept main as it is now, after it changed outside Brahma (owner only). Claims and merges start again.")
        @Argument var company: String

        func run() throws {
            try requireOwnerShell()
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            do { try store.acceptMainCommit(companyId: c.id) } catch let e as WorkError { throw fail(e.message) }
            let head = try store.company(id: c.id)?.mainCommit ?? "?"
            print(safe("\(c.name): main accepted at \(head.prefix(7))"))
        }
    }
}
