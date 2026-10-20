import ArgumentParser
import Foundation
import AgentCompanyCore

struct Hire: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Hire an agent into a company.")

    @Argument var company: String
    @Argument(help: "Agent handle (lowercase letters, digits, - and _).") var handle: String
    @Option(help: "Role, e.g. ceo, cto, engineer.") var role: String
    @Option(help: "opus, sonnet or haiku.") var model: String

    func run() throws {
        guard ["opus", "sonnet", "haiku"].contains(model) else { throw fail("model must be opus, sonnet or haiku") }
        let (store, _) = try openStore()
        let c = try resolveCompany(store, company)
        do {
            let a = try store.hire(companyId: c.id, name: handle, role: role, model: model)
            print(safe("hired @\(a.name) (\(a.role), \(a.model)) into \(c.name)"))
        } catch StoreError.duplicateName {
            throw fail("@\(handle.lowercased()) already exists in \(c.name)")
        } catch StoreError.invalidName {
            throw fail("invalid handle '\(handle)'")
        }
    }
}

struct Kill: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Kill an agent. A running turn finishes in the orchestrator, but the agent stays killed.")

    @Argument var company: String
    @Argument var handle: String

    func run() throws {
        let (store, _) = try openStore()
        let a = try resolveAgent(store, company: try resolveCompany(store, company), handle: handle)
        do {
            _ = try store.transition(agentId: a.id, to: .killed)
        } catch is LifecycleError {
            throw fail("@\(a.name) is already killed")
        }
        print("@\(a.name) killed")
    }
}

struct Pause: ParsableCommand {
    static let configuration = CommandConfiguration(
        abstract: "Pause an agent (a running agent finishes its turn first, then sleeps).")

    @Argument var company: String
    @Argument var handle: String

    func run() throws {
        let (store, _) = try openStore()
        let a = try resolveAgent(store, company: try resolveCompany(store, company), handle: handle)
        guard a.state != .killed else { throw fail("@\(a.name) is killed") }
        let r = try store.setPaused(agentId: a.id, true)
        print(r.state == .running ? "@\(r.name) will pause after its current turn" : "@\(r.name) paused (\(r.state.rawValue))")
    }
}

struct Wake: ParsableCommand {
    static let configuration = CommandConfiguration(abstract: "Unpause an agent and make it ready.")

    @Argument var company: String
    @Argument var handle: String

    func run() throws {
        let (store, _) = try openStore()
        let a = try resolveAgent(store, company: try resolveCompany(store, company), handle: handle)
        guard a.state != .killed else { throw fail("@\(a.name) is killed") }
        let r = try store.setPaused(agentId: a.id, false)
        print("@\(r.name) is \(r.state.rawValue)")
    }
}
