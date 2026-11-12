import ArgumentParser
import Foundation
import BrahmaCore

struct OrgGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "org", abstract: "Show and change the org chart.",
        subcommands: [Show.self, Move.self, Vacancies.self, Vacancy.self, Fill.self, Acting.self], defaultSubcommand: Show.self)

    struct Acting: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Name the acting CEO (owner only).")
        @Argument var company: String
        @Argument var handle: String

        func run() throws {
            try requireOwnerShell()
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let a = try resolveAgent(store, company: c, handle: handle)
            do { _ = try store.setActingCEO(companyId: c.id, agentId: a.id) } catch OrgError.managerKilled {
                throw fail("@\(a.name) is killed")
            }
            print(safe("@\(a.name) is acting CEO of \(c.name)"))
        }
    }

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
            try requireOwnerShell()
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
                let note = v.note.isEmpty ? "" : "  note: \(v.note)"
                print(safe("\(v.handle)  \(v.role)  manager: \(v.managerHandle ?? "none")  team: \(v.team ?? "none")\(note)"))
            }
        }
    }

    /// Plan 4b: the owner adds and removes open seats. Both writes; the note is owner-only text, redacted by the store.
    struct Vacancy: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Add or remove an open seat (owner only).",
                                                        subcommands: [Add.self, Remove.self])

        struct Add: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Open a seat for a role; its handle is picked for you.")
            @Argument var company: String
            @Option(help: "A role of the company's pack, e.g. engineer.") var role: String
            @Option(help: "The seated agent the hire will report to (default: the board).") var manager: String?
            @Option(help: "Team name: lowercase letters, digits, - and _.") var team: String?
            @Option(help: "Owner-only note, at most \(Store.vacancyNoteLimit) characters.") var note: String = ""

            func run() throws {
                try requireOwnerShell()
                let (store, _) = try openStore()
                let c = try resolveCompany(store, company)
                do {
                    let v = try store.addVacancy(companyId: c.id, role: role, managerHandle: manager, team: team, note: note)
                    print(safe("Vacancy @\(v.handle) for \(v.role) under @\(v.managerHandle ?? "board")"))
                } catch let e as WorkError {
                    throw fail(e.message)
                } catch StoreError.notFound {
                    throw fail("no company named '\(company)'")
                }
            }
        }

        struct Remove: ParsableCommand {
            static let configuration = CommandConfiguration(abstract: "Take an open seat back (its handle stays reserved).")
            @Argument var company: String
            @Argument var handle: String

            func run() throws {
                try requireOwnerShell()
                let (store, _) = try openStore()
                let c = try resolveCompany(store, company)
                let h = Store.normalizedHandle(handle)
                do {
                    try store.removeVacancy(companyId: c.id, handle: h)
                    print(safe("removed vacancy @\(h)"))
                } catch let e as WorkError {
                    throw fail(e.message)
                } catch StoreError.notFound {
                    throw fail("no open vacancy @\(h) in \(c.name)")
                }
            }
        }
    }

    struct Fill: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Hire into a vacant seat.")
        @Argument var company: String
        @Argument var handle: String
        func run() throws {
            try requireOwnerShell()
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
