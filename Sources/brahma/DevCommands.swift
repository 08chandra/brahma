import ArgumentParser
import Foundation
import BrahmaCore

/// Hidden test hooks that act as an agent. They need `BRAHMA_DEV=1` and the owner key, and never run in an agent turn
/// (the engine sets `BRAHMA_AGENT_ID` and never `BRAHMA_DEV` there).
private func requireDev() throws {
    guard ProcessInfo.processInfo.environment["BRAHMA_DEV"] == "1" else {
        throw fail("dev commands need BRAHMA_DEV=1")
    }
    try requireOwnerShell()
}

private func refusing<T>(_ body: () throws -> T) throws -> T {
    do { return try body() } catch let e as WorkError { throw fail(e.message) }
}

struct DevGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dev", abstract: "Developer test hooks (BRAHMA_DEV=1).", shouldDisplay: false,
        subcommands: [Propose.self, Decide.self, Request.self, Access.self, DigestNow.self])

    /// `request_access` as an agent would call it (the seed's pending access ask). Owner-side approval stays `brahma access approve`.
    struct Access: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "File an access request as an agent.")
        @Argument var company: String
        @Option(help: "Handle of the agent asking.") var by: String
        @Option(help: "network_domain, web_domain or read_path.") var kind: String
        @Option var value: String
        @Option var reason: String
        @Option(help: "Work item key.") var item: String?
        @Option(help: "The scope the agent proposes: once, item, agent, role or company.") var scope: GrantScope?
        @Option(help: "The duration the agent asks for: turn, sprint or always.") var duration: GrantDuration?

        func run() throws {
            try requireDev()
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let agent = try resolveAgent(store, company: c, handle: by)
            guard let grantKind = GrantKind(rawValue: kind) else { throw fail("kind must be network_domain, web_domain or read_path") }
            let itemId = try item.map { key -> String in
                guard let i = try store.workItem(companyId: c.id, key: key) else { throw fail("no work item \(key.uppercased())") }
                return i.id
            }
            let result = try refusing {
                try store.requestAccess(companyId: c.id, agentId: agent.id, kind: grantKind, value: value, reason: reason,
                                        itemId: itemId, scope: scope, duration: duration)
            }
            print(safe(describe(result.ask, store: store) + (result.deduped ? " (already requested)" : "")
                       + (result.grant.map { " \($0.ref) by \($0.approvedBy)" } ?? "")))
        }
    }

    struct Propose: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "File an ask as an agent.")
        @Argument var company: String
        @Option(help: "Handle of the agent filing it.") var by: String
        @Option(help: "prd, architecture, sprintPlan, release or other.") var kind: String
        @Option var title: String
        @Option var summary: String
        @Option var category: String?
        @Option(help: "low, medium or high.") var risk: String?
        @Option(help: "Document path inside the workspace.") var document: String?
        @Option(help: "Work item key.") var item: String?
        @Option(help: "Ask reference it replaces.") var supersedes: String?
        @Option(name: .customLong("option"), help: "An option label (repeatable).") var optionLabels: [String] = []
        @Option(name: .customLong("request-id")) var requestId: String?
        @Option(name: .customLong("decision-class"), help: "taste (default) or goalChanging.") var decisionClass: String = "taste"

        func run() throws {
            try requireDev()
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let agent = try resolveAgent(store, company: c, handle: by)
            let riskValue: AskRisk? = try risk.map { r in
                guard let v = AskRisk(rawValue: r.lowercased()) else { throw fail("risk must be low, medium or high") }
                return v
            }
            guard let cls = DecisionClass(rawValue: decisionClass) else { throw fail("decision class must be taste or goalChanging") }
            let itemId = try item.map { key -> String in
                guard let i = try store.workItem(companyId: c.id, key: key) else { throw fail("no work item \(key.uppercased())") }
                return i.id
            }
            let old = try supersedes.map { ref -> String in
                guard let a = try store.ask(companyId: c.id, ref: ref) else { throw fail("no ask \(ref)") }
                return a.id
            }
            let ask = try refusing {
                try store.propose(companyId: c.id, by: .agent(agent.id), kind: AskKind(kind), risk: riskValue, category: category,
                                  title: title, summary: summary, payload: (document != nil || !optionLabels.isEmpty)
                                    ? AskPayload(documentPath: document, options: optionLabels.map { AskOption(label: $0) }) : nil,
                                  itemId: itemId, supersedes: old, requestId: requestId, decisionClass: cls, quotaExempt: .devHook)
            }
            print(safe(describe(ask, store: store)))
        }
    }

    struct DigestNow: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "digest", abstract: "Build and store a digest now.")
        @Argument var company: String

        func run() throws {
            try requireDev()
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let digest = try buildDigest(store: store, company: c)
            try store.saveDigest(companyId: c.id, digest: digest)
            print(safe(digest.markdown), terminator: "")
        }
    }

    struct Decide: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Decide an ask as its internal approver.")
        @Argument var company: String
        @Argument var ask: String
        @Option(help: "Handle of the approver.") var by: String
        @Flag var approve = false
        @Flag var reject = false
        @Option var note: String = ""
        @Option var risk: String?
        @Option var category: String?

        func validate() throws {
            guard approve != reject else { throw ValidationError("pass exactly one of --approve and --reject") }
        }

        func run() throws {
            try requireDev()
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let agent = try resolveAgent(store, company: c, handle: by)
            guard let a = try store.ask(companyId: c.id, ref: ask) else { throw fail("no ask \(ask)") }
            let riskValue = try risk.map { r -> AskRisk in
                guard let v = AskRisk(rawValue: r.lowercased()) else { throw fail("risk must be low, medium or high") }
                return v
            }
            let done = try refusing {
                try store.internalDecide(askId: a.id, by: .agent(agent.id), approve: approve, note: note, category: category, risk: riskValue)
            }
            print(safe(describe(done, store: store)))
        }
    }

    struct Request: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Ask the owner a question as an agent.")
        @Argument var company: String
        @Option(help: "Handle of the agent asking.") var by: String
        @Option var title: String
        @Option var question: String
        @Option var details: String?
        @Option(name: .customLong("expires-hours")) var expiresHours: Double?

        func run() throws {
            try requireDev()
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let agent = try resolveAgent(store, company: c, handle: by)
            let ask = try refusing {
                try store.requestFromOwner(companyId: c.id, by: .agent(agent.id), title: title, question: question, details: details,
                                           expiresInHours: expiresHours, quotaExempt: .devHook)
            }
            print(safe(describe(ask, store: store)))
        }
    }
}

private func describe(_ ask: Ask, store: Store) -> String {
    var line = "\(ask.ref) \(ask.status.rawValue)"
    if let id = ask.internalApproverId, ask.status == .pendingInternal, let a = try? store.agent(id: id) { line += " (approver @\(a.name))" }
    if ask.fyi { line += " (FYI)" }
    return line
}
