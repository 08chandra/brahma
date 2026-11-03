import Foundation
import BrahmaCore

public struct MenuCompanyRow: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var statusText: String
    public var toggleTitle: String
    public var isRunning: Bool
    /// Why nothing is running in this company (its first stall reason), nil while anything runs.
    public var stallLine: String? = nil
}

public struct MenuBarSummary: Equatable, Sendable {
    public var totals: String
    public var pending: String
    public var engine: String
    public var rows: [MenuCompanyRow]
    public var anyRunningAgents: Bool
    /// Asks waiting for the owner across all companies (shown next to the menu bar icon when above zero).
    public var badge: Int = 0
    /// Why nothing is running, for the first running company with nothing running; nil when all is well.
    public var stall: String? = nil
    /// The owner's emergency stop holds (Task 7c): the menu offers Resume instead of STOP EVERYTHING.
    public var stopped: Bool = false
    /// The stop's first line ("STOPPED by the owner since HH:mm"), nil while not stopped.
    public var stopLine: String? = nil

    public static func make(companies: [CompanySummary], engine: EngineStatus?, stop: EngineStopRow? = nil,
                            timeZone: TimeZone = .current) -> MenuBarSummary {
        let running = companies.reduce(0) { $0 + $1.counts.running }
        let ready = companies.reduce(0) { $0 + $1.counts.ready }
        let totals = companies.isEmpty
            ? "No companies yet"
            : "\(running) running · \(ready) ready across \(companies.count) \(companies.count == 1 ? "company" : "companies")"
        let waiting = companies.reduce(0) { $0 + $1.waitingOnOwner }
        let unread = companies.reduce(0) { $0 + $1.unread }
        let rows = companies.map { c -> MenuCompanyRow in
            let isRunning = c.company.status == .running
            let name = c.company.name
            return MenuCompanyRow(
                id: c.id, name: name,
                statusText: isRunning ? "Running · \(c.counts.running) running · \(c.counts.ready) ready" : "Paused",
                toggleTitle: isRunning ? "Pause \(name)" : "Resume \(name)",
                isRunning: isRunning, stallLine: c.stallLine)
        }
        let stall = rows.first { $0.isRunning && $0.stallLine != nil }.flatMap { row in
            row.stallLine.map { companies.count > 1 ? "\(row.name): \($0)" : $0 }
        }
        return MenuBarSummary(totals: totals, pending: "\(waiting) waiting on you · \(unread) unread",
                              engine: engineLine(engine), rows: rows, anyRunningAgents: running > 0,
                              badge: companies.reduce(0) { $0 + $1.inboxCount }, stall: stall,
                              stopped: stop != nil, stopLine: stop.map { EmergencyStop.statusLine($0, timeZone: timeZone) })
    }

    private static func engineLine(_ status: EngineStatus?) -> String {
        switch status {
        case .embedded?: "Engine: running in Brahma"
        case .external?: "Engine: running in terminal (brahma run)"
        case .starting?: "Engine: starting…"
        case .stopping?: "Engine: stopping…"
        case .stopped?: "Engine: stopped"
        case .failed(let m)?: "Engine: stopped — \(m)"
        case nil: "Engine: not started"
        }
    }
}

extension AppModel {
    public var menuBar: MenuBarSummary {
        MenuBarSummary.make(companies: snapshot.companies, engine: engine?.status, stop: snapshot.stop, timeZone: snapshot.work.timeZone)
    }
}
