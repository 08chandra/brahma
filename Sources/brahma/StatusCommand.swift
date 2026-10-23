import ArgumentParser
import Foundation
import BrahmaCore

struct Status: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Show every company's agents and the latest usage.")

    func run() throws {
        let (store, _) = try openStore()
        for c in try store.companies() {
            let agents = try store.agents(companyId: c.id)
            let names = Dictionary(uniqueKeysWithValues: agents.map { ($0.id, $0.name) })
            var header = "\(c.name) [\(c.slug)]  \(c.status.rawValue)  \(c.usageMode.rawValue) mode  weight \(c.priorityWeight)"
            // A company with its own reserve is paced against that, not the owner-wide share.
            if let reserve = c.ownerReserve, let pace = UsageGate.pace(try store.latestRateLimit(), reserve: reserve, now: Date()) {
                header += "  7D \(pace.text) (reserve \(Int((reserve * 100).rounded()))%)"
            }
            print(safe(header))
            print("  inbox: \(try store.ownerWaitingCount(companyId: c.id)) waiting")
            if !agents.contains(where: { $0.state == .running }) {
                let report = try store.stallReport(companyId: c.id)
                if let first = report.reasons.first { print(safe("  0 running: \(first)")) }
            }
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
        print(usageLine(try store.latestRateLimit(), store: store))
        if let hold = try store.engineHold() {
            print(safe("engine paused: \(hold.reason.rawValue) — \(hold.detail)"))
        }
    }

    func usageLine(_ info: RateLimitInfo?, store: Store) -> String {
        guard let info else { return "usage: no data yet" }
        func pct(_ v: Double?) -> String { v.map { "\(Int(($0 * 100).rounded()))%" } ?? "n/a" }
        var line = "usage: 5h \(pct(info.fiveHourUtilization)) · 7d \(pct(info.sevenDayUtilization))"
        if let resets = info.resetsAt { line += " · resets \(clock(resets))" }
        if let pace = UsageGate.pace(info, reserve: 1 - store.weeklyShare(), now: Date()) { line += " · 7D \(pace.text)" }
        if let perDollar = (try? store.usageCalibration())?.pctPerDollar {
            let today = perDollar * 100 * store.costToday(now: Date())
            line += " · ≈\(String(format: today < 10 ? "%.1f" : "%.0f", today))% of week today"
        }
        return line
    }
}
