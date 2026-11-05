import ArgumentParser
import Foundation
import BrahmaCore
import BrahmaKeychain

/// Human tasks (Plan L Task 9): what the owner does by hand. `list` and `show` are read-only; `done` and `decline` are
/// owner-write commands (refused in an agent's shell). Secrets are read from standard input, one line per `--secret`, never
/// from argv. Every agent-written field (titles, steps, link titles, the post text, the reason) prints through `safe()`.
struct HumanTaskGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "task", abstract: "Human tasks the agents asked you to do: list them, show one, mark it done or decline it.",
        subcommands: [List.self, Show.self, Done.self, Decline.self], defaultSubcommand: List.self)

    static func names(_ store: Store, _ company: Company) throws -> [String: String] {
        Dictionary(try store.agents(companyId: company.id).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    static func itemKey(_ store: Store, _ ask: Ask) throws -> String {
        guard let id = ask.itemId else { return "-" }
        return try store.workItem(id: id)?.key ?? "-"
    }

    /// `A-<n>  <title>  @<requester>  <item|->`.
    static func line(_ store: Store, _ ask: Ask, names: [String: String]) throws -> String {
        let who = ask.requesterId == "system" ? "system" : names[ask.requesterId] ?? "unknown"
        return safe([ask.ref, ask.title, "@\(who)", try itemKey(store, ask)].joined(separator: "  "))
    }

    static func task(_ store: Store, _ company: Company, _ ref: String) throws -> (Ask, HumanTask) {
        guard let ask = try store.ask(companyId: company.id, ref: ref), ask.kind == .humanTask, let task = HumanTask.from(ask) else {
            throw fail("no human task \(ref) in \(company.name)")
        }
        return (ask, task)
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List the company's pending human tasks.")
        @Argument(help: "Company name or slug.") var company: String

        func run() throws {
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let names = try HumanTaskGroup.names(store, c)
            let pending = try store.asks(companyId: c.id, statuses: [.pendingOwner, .pendingInternal]).filter { $0.kind == .humanTask }
            if pending.isEmpty { print("(no human tasks)") }
            for ask in pending { print(try HumanTaskGroup.line(store, ask, names: names)) }
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Show one human task: its steps, links (with their hosts) and fields.")
        @Argument(help: "Company name or slug.") var company: String
        @Argument(help: "The task, e.g. A-2.") var ref: String

        func run() throws {
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let (ask, task) = try HumanTaskGroup.task(store, c, ref)
            print(try HumanTaskGroup.line(store, ask, names: try HumanTaskGroup.names(store, c)))
            print("status: \(ask.status.rawValue)")
            print("why: \(safe(HostingCommand.oneLine(ask.summary, max: 1000)))")
            if !task.steps.isEmpty {
                print("steps:")
                for (i, step) in task.steps.enumerated() { print("    \(i + 1). \(safe(step))") }
            }
            if !task.links.isEmpty {
                print("links:")
                for link in task.links { print("    " + safe("\(link.title) — \(link.host)  \(link.url)")) }
            }
            if let post = task.postText {
                print("post:")
                for line in post.split(separator: "\n", omittingEmptySubsequences: false) { print("    | " + safe(String(line))) }
            }
            if !task.fields.isEmpty {
                if task.template == nil { print(HumanTaskPolicy.customFieldCaption) }
                print("fields:")
                for f in task.fields {
                    let how = f.isSecret ? "--secret \(f.name) (read from standard input)" : "--field \(f.name)=…"
                    var parts = ["\(f.name) (\(f.kind.rawValue)\(f.required ? ", required" : ""))", f.label]
                    if let p = f.prefix { parts.append("starts with \(p)") }
                    parts.append(how)
                    print("    " + safe(parts.joined(separator: "  ")))
                }
            }
            if let answer = ask.ownerAnswer { print("answer: \(safe(answer))") }
            if ask.status.isPending { print("Mark it done: brahma task done \(c.slug) \(ask.ref) …  or decline: brahma task decline \(c.slug) \(ask.ref) --note …") }
        }
    }

    struct Done: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Mark a human task done with its fields. Each --secret NAME reads one line from standard input (or prompts in a terminal).")
        @Argument(help: "Company name or slug.") var company: String
        @Argument(help: "The task, e.g. A-2.") var ref: String
        @Option(name: .customLong("field"), help: "A non-secret field, name=value (repeatable).") var fields: [String] = []
        @Option(name: .customLong("secret"), help: "A secret field's name; its value is read from standard input (repeatable).")
        var secrets: [String] = []

        func run() throws {
            try requireOwnerShell()
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let (ask, task) = try HumanTaskGroup.task(store, c, ref)
            let byName = Dictionary(task.fields.map { ($0.name, $0) }, uniquingKeysWith: { a, _ in a })
            var values: [String: String] = [:]
            for pair in fields {
                guard let eq = pair.firstIndex(of: "=") else { throw fail("--field takes name=value") }
                let name = String(pair[..<eq]), value = String(pair[pair.index(after: eq)...])
                guard let f = byName[name] else { throw fail("\(name) is not a field of \(ask.ref)") }
                // A key never goes through argv (it would be in the shell history and the process list).
                guard !f.isSecret else { throw fail("\(name) is a secret: pass --secret \(name) and paste it on standard input") }
                values[name] = value
            }
            for name in secrets {
                guard let f = byName[name] else { throw fail("\(name) is not a field of \(ask.ref)") }
                guard f.isSecret else { throw fail("\(name) is not a secret: pass --field \(name)=…") }
                values[name] = try Self.readSecret(f)
            }
            let done: Ask
            do {
                done = try store.completeHumanTask(companyId: c.id, askId: ask.id, values: values, vault: try cliSecretVault(interactive: true))
            } catch let e as WorkError { throw fail(e.message) } catch let e as SecretError { throw fail(e.message) }
            print(safe("\(done.ref) done: \(done.title)"))
            let saved = task.fields.filter { $0.isSecret && values[$0.name] != nil }.map(\.name)
            if !saved.isEmpty { print("saved to the vault: \(saved.joined(separator: ", "))") }
        }

        /// One line: prompted without echo in a terminal, else the next line of standard input.
        static func readSecret(_ f: HumanTaskField) throws -> String {
            if isatty(STDIN_FILENO) != 0 {
                guard let line = getpass("\(f.label) (\(f.name)): ") else { throw fail("no value for \(f.name)") }
                guard let typed = String(validatingCString: line) else { throw fail(SecretError.notUTF8.message) }
                return typed
            }
            guard let line = readLine(strippingNewline: true) else { throw fail("no value for \(f.name) on standard input") }
            return line
        }
    }

    struct Decline: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Decline a human task; the agent is told why.")
        @Argument(help: "Company name or slug.") var company: String
        @Argument(help: "The task, e.g. A-2.") var ref: String
        @Option(help: "Why (the requester sees it).") var note: String

        func run() throws {
            try requireOwnerShell()
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let (ask, _) = try HumanTaskGroup.task(store, c, ref)
            do { _ = try store.declineHumanTask(companyId: c.id, askId: ask.id, note: note) } catch let e as WorkError { throw fail(e.message) }
            print(safe("\(ask.ref) declined: \(ask.title)"))
        }
    }
}
