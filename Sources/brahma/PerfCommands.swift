import ArgumentParser
import Foundation
import BrahmaCore

/// Read-only performance records.
struct PerfGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "perf", abstract: "Show performance records.", subcommands: [Facts.self])

    struct Facts: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Per-item outcome facts of finished work, newest first.")
        @Argument var company: String
        @Option(help: "How many items to show.") var limit = 50

        func validate() throws {
            guard limit >= 1 else { throw ValidationError("--limit must be at least 1") }
        }

        func run() throws {
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let facts = try store.itemFacts(companyId: c.id, limit: limit)
            guard !facts.isEmpty else { print("(no outcome facts yet)"); return }
            let handles = Dictionary(try store.agents(companyId: c.id).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
            for f in facts {
                let key = try store.workItem(id: f.itemId)?.key ?? "?"
                print(safe(FactsText.line(f, key: key, handles: handles)))
            }
        }
    }
}
