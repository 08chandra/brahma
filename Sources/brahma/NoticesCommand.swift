import ArgumentParser
import Foundation
import BrahmaCore

struct Notices: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List notices for the owner (read-only): undelivered ones, or --all.")

    @Flag(help: "Include notices that were already delivered.") var all = false

    func run() throws {
        let (store, _) = try openStore()
        let notices = all ? try store.allNotices() : try store.undeliveredNotices()
        guard !notices.isEmpty else { print(all ? "no notices" : "no undelivered notices"); return }
        let slugs = Dictionary(uniqueKeysWithValues: try store.companies().map { ($0.id, $0.slug) })
        let zone = store.ownerTimeZone()
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        print("when (\(zone.identifier))  company  kind  urgency  delivered  title: body")
        for n in notices {
            let parts = [
                f.string(from: n.createdAt), n.companyId.flatMap { slugs[$0] } ?? "all", n.kind.rawValue, n.urgency.rawValue,
                n.deliveredAt == nil ? "no" : "yes",
            ]
            print(safe(parts.joined(separator: "  ") + "  \(n.title): \(n.body)"))
        }
    }
}
