import ArgumentParser
import Foundation
import BrahmaCore

/// Read-only: why little or nothing is running in a company.
struct Why: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Explain why a company has nothing running.")
    @Argument var company: String

    func run() throws {
        let (store, _) = try openStore()
        let c = try resolveCompany(store, company)
        let report = try store.stallReport(companyId: c.id)
        print("\(report.running) running.")
        for reason in report.reasons { print(safe(reason)) }
    }
}
