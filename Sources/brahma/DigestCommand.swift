import ArgumentParser
import Foundation
import BrahmaCore

/// What `brahma digest` and `brahma dev digest` build: since the last stored digest, else the last 24 hours.
func buildDigest(store: Store, company: Company, now: Date = Date()) throws -> Digest {
    let since = try store.lastDigestEnd(companyId: company.id) ?? now.addingTimeInterval(-86_400)
    return try DigestBuilder.build(store: store, companyId: company.id, since: since, now: now, tz: store.ownerTimeZone())
}

struct DigestCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "digest",
        abstract: "Show the latest daily digest, or --preview what the next one would say (nothing is stored). Owner only.")
    @Argument var company: String
    @Flag(help: "Build a digest now without storing it.") var preview = false

    func run() throws {
        try requireOwnerShell()
        let (store, _) = try openStore()
        let c = try resolveCompany(store, company)
        if preview {
            print(safe(try buildDigest(store: store, company: c).markdown), terminator: "")
        } else if let latest = try store.latestDigest(companyId: c.id) {
            print(safe(latest.markdown), terminator: "")
        } else {
            print("no digest yet for \(safe(c.name)); try --preview")
        }
    }
}
