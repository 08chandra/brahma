import ArgumentParser
import Foundation
import BrahmaCore

struct Timers: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "List engine timers (read-only): schedule, next fire, last fired, enabled.")

    @Argument(help: "Company name or slug. Without it, every timer is listed.") var company: String?

    func run() throws {
        let (store, _) = try openStore()
        let selected = try company.map { try resolveCompany(store, $0) }
        let timers = try store.timers(companyId: selected?.id)
        guard !timers.isEmpty else { print("no timers"); return }
        let zone = store.ownerTimeZone()
        let slugs = Dictionary(uniqueKeysWithValues: try store.companies().map { ($0.id, $0.slug) })
        print("timer  company  schedule  next fire (\(zone.identifier))  last fired  enabled  action")
        for t in timers {
            var action: String
            switch t.action {
            case .job(let name): action = "job \(name)"
            case .turn(let agentId, _): action = "turn @\(try store.agent(id: agentId)?.name ?? "?")"
            }
            let parts = [
                t.name, t.companyId.flatMap { slugs[$0] } ?? "all", t.schedule.summary(timeZone: zone),
                stamp(t.nextFireAt, zone), t.lastFiredAt.map { stamp($0, zone) } ?? "never", t.enabled ? "yes" : "no", action,
            ]
            print(safe(parts.joined(separator: "  ")))
        }
    }

    private func stamp(_ date: Date, _ zone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = zone
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}
