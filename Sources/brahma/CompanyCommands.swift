import ArgumentParser
import Foundation
import BrahmaCore

struct CompanyGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "company", abstract: "Create and manage companies.",
        subcommands: [Create.self, List.self, Pause.self, Resume.self, Mode.self, Weight.self])

    struct Create: ParsableCommand {
        @Argument(help: "Company name.") var name: String
        @Option(help: "What the company is for.") var goal: String
        @Option(help: "Agents in the full org shape (0 for an empty company, otherwise 5 to 500).") var agents: Int = 6
        @Option(help: "Industry pack id.") var pack: String = "software"
        @Flag(help: "Print the org that would be created and change nothing.") var dryRun = false

        func run() throws {
            try requireOwnerShell()
            guard agents == 0 || OrgGenerator.range.contains(agents) else {
                throw fail("--agents must be 0 or between \(OrgGenerator.range.lowerBound) and \(OrgGenerator.range.upperBound)")
            }
            let paths = BrahmaPaths.fromEnvironment()
            let catalog = PackCatalog.loadOrBuiltin(directory: paths.packsDir) { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
            guard let industry = catalog.pack(pack) else { throw fail("unknown pack '\(pack)'") }
            var staffed: (seated: OrgPlan, vacancies: [PlannedAgent])?
            var full: OrgPlan?
            if agents > 0 {
                if agents > 50 { print("Note: org sizes over 50 are experimental.") }
                let plan = try OrgGenerator.generate(goal: goal, count: agents, pack: industry)
                full = plan
                staffed = OrgGenerator.staff(plan: plan, pack: industry, readyWidth: 0, seatBudget: 8)
            }
            if dryRun {
                guard let full, let staffed else { print("(empty company)"); return }
                for line in full.treeLines(vacant: Set(staffed.vacancies.map(\.handle))) { print(safe(line)) }
                return
            }
            let (store, paths2) = try openStore()
            let c = try store.createCompany(name: name, goal: goal, workspacesRoot: paths2.workspaces, packId: pack)
            print("\(c.id)  \(c.workspacePath)")
            if let staffed {
                let hired = try store.applyOrg(companyId: c.id, plan: staffed.seated, pack: industry, vacancies: staffed.vacancies)
                print("hired \(hired.count) of \(agents); \(staffed.vacancies.count) seats vacant")
            }
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
        func run() throws { try requireOwnerShell(); try set(company, .paused) }
    }

    struct Resume: ParsableCommand {
        @Argument var company: String
        func run() throws { try requireOwnerShell(); try set(company, .running) }
    }

    struct Mode: ParsableCommand {
        @Argument var company: String
        @Argument(help: "low, balanced or max.") var mode: UsageMode
        func run() throws { try requireOwnerShell(); try update(company) { $0.usageMode = mode } }
    }

    struct Weight: ParsableCommand {
        @Argument var company: String
        @Argument(help: "Scheduling weight (1 or more).") var weight: Int
        func run() throws {
            try requireOwnerShell()
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
