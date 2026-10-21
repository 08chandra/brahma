import Foundation
import BrahmaCore

public struct MenuCompanyRow: Equatable, Identifiable, Sendable {
    public var id: String
    public var name: String
    public var statusText: String
    public var toggleTitle: String
    public var isRunning: Bool
}

public struct MenuBarSummary: Equatable, Sendable {
    public var totals: String
    public var pending: String
    public var engine: String
    public var rows: [MenuCompanyRow]
    public var anyRunningAgents: Bool

    public static func make(companies: [CompanySummary], engine: EngineStatus?) -> MenuBarSummary {
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
                isRunning: isRunning)
        }
        return MenuBarSummary(totals: totals, pending: "\(waiting) waiting on you · \(unread) unread",
                              engine: engineLine(engine), rows: rows, anyRunningAgents: running > 0)
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
        MenuBarSummary.make(companies: snapshot.companies, engine: engine?.status)
    }
}
