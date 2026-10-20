import ArgumentParser
import Foundation
import AgentCompanyCore

struct CompanyGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "company", abstract: "Create and manage companies.",
        subcommands: [Create.self, List.self, Pause.self, Resume.self, Mode.self, Weight.self])

    struct Create: ParsableCommand {
        @Argument(help: "Company name.") var name: String
        @Option(help: "What the company is for.") var goal: String

        func run() throws {
            let (store, paths) = try openStore()
            let c = try store.createCompany(name: name, goal: goal, workspacesRoot: paths.workspaces)
            print("\(c.id)  \(c.workspacePath)")
        }
    }

    struct List: ParsableCommand {
        func run() throws {
            let (store, _) = try openStore()
            print("name  status  mode  weight  agents(running/ready/blocked/sleeping)")
            for c in try store.companies() {
                let agents = try store.agents(companyId: c.id)
                func n(_ s: AgentState) -> Int { agents.filter { $0.state == s }.count }
                print(safe("\(c.name)  \(c.status.rawValue)  \(c.usageMode.rawValue)  \(c.priorityWeight)  "
                      + "\(n(.running))/\(n(.ready))/\(n(.blocked))/\(n(.sleeping))"))
            }
        }
    }

    struct Pause: ParsableCommand {
        @Argument var company: String
        func run() throws { try set(company, .paused) }
    }

    struct Resume: ParsableCommand {
        @Argument var company: String
        func run() throws { try set(company, .running) }
    }

    struct Mode: ParsableCommand {
        @Argument var company: String
        @Argument(help: "low, balanced or max.") var mode: UsageMode
        func run() throws { try update(company) { $0.usageMode = mode } }
    }

    struct Weight: ParsableCommand {
        @Argument var company: String
        @Argument(help: "Scheduling weight (1 or more).") var weight: Int
        func run() throws {
            guard weight >= 1 else { throw fail("weight must be at least 1") }
            try update(company) { $0.priorityWeight = weight }
        }
    }

    private static func set(_ query: String, _ status: CompanyStatus) throws {
        try update(query) { $0.status = status }
    }

    private static func update(_ query: String, _ change: (inout Company) -> Void) throws {
        let (store, _) = try openStore()
        var c = try resolveCompany(store, query)
        change(&c)
        try store.updateCompany(c)
        print(safe("\(c.name): \(c.status.rawValue), \(c.usageMode.rawValue) mode, weight \(c.priorityWeight)"))
    }
}

extension UsageMode: ExpressibleByArgument {}
