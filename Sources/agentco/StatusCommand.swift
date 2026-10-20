import ArgumentParser
import Foundation
import AgentCompanyCore

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show every company's agents and the latest usage.")

    func run() throws {
        let (store, _) = try openStore()
        for c in try store.companies() {
            let agents = try store.agents(companyId: c.id)
            let names = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0.name) })
            print(safe("\(c.name) [\(c.slug)]  \(c.status.rawValue)  \(c.usageMode.rawValue) mode  weight \(c.priorityWeight)"))
            for a in agents {
                var parts = ["  @\(a.name)", a.state.rawValue]
                if a.paused { parts.append("paused") }
                let blocker = describe(a.blocker, names: names)
                if !blocker.isEmpty { parts.append(blocker) }
                if let t = try store.lastTurn(agentId: a.id) {
                    parts.append("last turn: \(t.outcome.rawValue) \(clock(t.startedAt))")
                } else {
                    parts.append("no turns yet")
                }
                print(safe(parts.joined(separator: "  ")))
            }
        }
        print(usageLine(try store.latestRateLimit()))
    }

    func usageLine(_ info: RateLimitInfo?) -> String {
        guard let info else { return "usage: no data yet" }
        func pct(_ v: Double?) -> String { v.map { "\(Int(($0 * 100).rounded()))%" } ?? "n/a" }
        var line = "usage: 5h \(pct(info.fiveHourUtilization)) · 7d \(pct(info.sevenDayUtilization))"
        if let resets = info.resetsAt { line += " · resets \(clock(resets))" }
        return line
    }
}
