import ArgumentParser
import Foundation
import BrahmaCore

struct OrgGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "org", abstract: "Show and change the org chart.",
        subcommands: [Show.self, Move.self, Vacancies.self, Fill.self], defaultSubcommand: Show.self)

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "show", abstract: "Print the reporting tree.")
        @Argument var company: String
        func run() throws {
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let lines = try store.orgTreeLines(companyId: c.id)
            if lines.isEmpty { print("(no agents)") }
            for line in lines { print(safe(line)) }
        }
    }

    struct Move: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Change an agent's manager and/or team.")
        @Argument var company: String
        @Argument var handle: String
        @Option(help: "New manager handle, or 'none'.") var manager: String?
        @Option(help: "New team name, or 'none'.") var team: String?

        func run() throws {
            guard manager != nil || team != nil else { throw fail("give --manager and/or --team") }
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let a = try resolveAgent(store, company: c, handle: handle)
            do {
                if let manager {
                    let id = manager.lowercased() == "none" ? nil : try resolveAgent(store, company: c, handle: manager).id
                    try store.setManager(agentId: a.id, managerId: id)
                }
                if let team { try store.setTeam(agentId: a.id, team: team.lowercased() == "none" ? nil : team) }
            } catch OrgError.cycle {
                throw fail("that would create a reporting cycle")
            } catch OrgError.tooManyReports(let m, let n) {
                throw fail("@\(m) would have \(n) direct reports (max \(OrgGenerator.maxReports))")
            } catch OrgError.managerKilled {
                throw fail("that manager is killed")
            }
            print(safe("@\(a.name) moved"))
        }
    }

    struct Vacancies: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List open seats.")
        @Argument var company: String
        func run() throws {
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let open = try store.vacancies(companyId: c.id)
            if open.isEmpty { print("(no vacancies)") }
            for v in open {
                print(safe("\(v.handle)  \(v.role)  manager: \(v.managerHandle ?? "none")  team: \(v.team ?? "none")"))
            }
        }
    }

    struct Fill: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Hire into a vacant seat.")
        @Argument var company: String
        @Argument var handle: String
        func run() throws {
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let h = handle.hasPrefix("@") ? String(handle.dropFirst()) : handle
            do {
                let a = try store.fillVacancy(companyId: c.id, handle: h)
                print(safe("hired @\(a.name) (\(a.role)) into \(c.name)"))
            } catch StoreError.notFound {
                throw fail("no vacancy @\(h.lowercased()) in \(c.name)")
            }
        }
    }
}
