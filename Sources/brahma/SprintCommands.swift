import ArgumentParser
import Foundation
import BrahmaCore

/// `brahma sprint <company>`: the open sprints with their items; `brahma sprint list <company>`: every sprint. Read-only.
struct SprintGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "sprint", abstract: "Show the open sprints and their progress.",
        subcommands: [Show.self, List.self], defaultSubcommand: Show.self)

    static func header(_ s: Sprint, _ p: SprintProgress) -> String {
        "\(s.name) · \(s.scopeLabel) · \(s.status.rawValue) · \(p.done)/\(p.total) done · goal: \(s.goal)"
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "show", abstract: "Open sprints (planned, active, in review) with their items.")
        @Argument var company: String

        func run() throws {
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let open = try store.sprints(companyId: c.id, statuses: Set(SprintStatus.open))
            if open.isEmpty { print("(no open sprint)"); return }
            for (i, s) in open.enumerated() {
                if i > 0 { print("") }
                let p = try store.sprintProgress(s)
                print(safe(SprintGroup.header(s, p)))
                for item in p.items {
                    print(safe("  \(item.key)  \(item.status.title)  \(item.title)"))
                }
            }
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "list", abstract: "Every sprint, oldest first.")
        @Argument var company: String

        func run() throws {
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let all = try store.sprints(companyId: c.id)
            if all.isEmpty { print("(no sprints)"); return }
            for s in all {
                if s.status.isOpen {
                    let p = try store.sprintProgress(s)
                    print(safe("\(s.name)  \(s.scopeLabel)  \(s.status.rawValue)  \(p.done)/\(p.total)  \(s.goal)"))
                } else {
                    let first = s.summary?.components(separatedBy: "\n").first ?? ""
                    print(safe("\(s.name)  \(s.scopeLabel)  \(s.status.rawValue)  \(s.goal)" + (first.isEmpty ? "" : " — \(first)")))
                }
            }
        }
    }
}
