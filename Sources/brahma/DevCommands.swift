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

struct DevGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "dev", abstract: "Developer test hooks (BRAHMA_DEV=1).", shouldDisplay: false,
        subcommands: [Propose.self, Decide.self, Request.self, Access.self, DigestNow.self, ReleaseScenario.self, Claim.self, Tool.self,
                      SeedTurn.self])

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

    /// Plan L Task 12: R-1 deployed and R-2 proposed through the real deploy path against the dev host (a folder under the
    /// data home served on loopback, never a provider), plus two pending human tasks. Refuses while an engine runs.
    struct ReleaseScenario: AsyncParsableCommand {
        static let configuration = CommandConfiguration(commandName: "release-scenario",
                                                        abstract: "Deploy R-1 and propose R-2 against the local dev host.")
        @Argument var company: String
        @Option(help: "Work item key the Stripe test-keys task is linked to.") var item: String?
        @Option(name: .customLong("expect-text"), help: "Text the deployed page's / must contain.") var expectText: String?

        func run() async throws {
            try requireDev()
            let (store, paths) = try openStore()
            let c = try resolveCompany(store, company)
            let summary: DevReleaseScenario.Summary
            do {
                summary = try await DevReleaseScenario.run(store: store, paths: paths, companyId: c.id,
                                                           vault: try cliSecretVault(interactive: false), itemKey: item,
                                                           expectText: expectText)
            } catch let e as WorkError { throw fail(e.message) }
            print(safe("smoke \(summary.smoke.status.rawValue) at \(summary.smoke.commit.prefix(7))"))
            print(safe("\(summary.deployed.ref) \(summary.deployed.status.rawValue) \(summary.deployed.productionURL ?? "-")"))
            print(safe("\(summary.proposed.ref) \(summary.proposed.status.rawValue) (\(summary.deployAsk.ref) waits on the owner)"))
            for ask in summary.humanTasks { print(safe("\(ask.ref) human task: \(ask.title)")) }
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

    /// `claim_lease` as the agent would call it, through the same tool path as an agent's MCP server (the main-rewritten guard,
    /// the worktree, the progress file and the check baseline all happen): the seed's in-progress item with a reviewer.
    struct Claim: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Claim a work item as an agent.")
        @Argument var company: String
        @Argument(help: "Work item key.") var key: String
        @Option(help: "Handle of the agent claiming it.") var by: String

        func run() throws {
            try requireDev()
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let agent = try resolveAgent(store, company: c, handle: by)
            let tools = CompanyTools(store: store, companyId: c.id, agentId: agent.id)
            do {
                print(safe(try tools.call(name: "claim_lease", arguments: ["key": .string(key)])))
            } catch let e as ToolError {
                throw fail(e.message)
            } catch let e as WorkError {
                throw fail(e.message)
            }
        }
    }

    /// Calls one company tool as an agent would (the seed's handbook pages and remembered facts: `kb_write`, `remember`).
    /// `--taint` first marks the agent's session as having read outside content, so what it writes is tainted.
    struct Tool: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "Call a company tool as an agent.")
        @Argument var company: String
        @Argument(help: "Tool name, e.g. remember or kb_write.") var name: String
        @Option(help: "Handle of the agent calling it.") var by: String
        @Option(help: "The arguments as a JSON object.") var args: String = "{}"
        @Option(help: "Mark the agent's session tainted by this source first.") var taint: String?

        func run() throws {
            try requireDev()
            let (store, paths) = try openStore()
            let c = try resolveCompany(store, company)
            let agent = try resolveAgent(store, company: c, handle: by)
            guard let arguments = try? JSONDecoder().decode([String: JSONValue].self, from: Data(args.utf8)) else {
                throw fail("--args must be a JSON object")
            }
            if let taint { try store.markTainted(agentId: agent.id, source: taint) }
            let tools = CompanyTools(store: store, companyId: c.id, agentId: agent.id, paths: paths,
                                     vault: try cliSecretVault(interactive: false))
            do {
                print(safe(try tools.call(name: name, arguments: arguments)))
            } catch let e as ToolError {
                throw fail(e.message)
            } catch let e as WorkError {
                throw fail(e.message)
            }
        }
    }

    /// Plan ML Task 9 (the replay's seed): a finished turn of an agent, its tool calls as activity lines, and a captured
    /// transcript of what it said. The transcript is a JSON-lines file written for the occasion under the data home's tmp
    /// directory (removed after) and captured exactly like a real turn's: redacted, compressed, 0600.
    struct SeedTurn: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "turn", abstract: "Record a finished turn with a captured transcript as an agent.")
        @Argument var company: String
        @Option(help: "Handle of the agent whose turn it is.") var by: String
        @Option(help: "The turn's summary.") var summary: String
        @Option(help: "The task the transcript's prompt states.") var prompt: String = "Continue your work."
        @Option(help: "A line the agent says in the transcript (repeatable).") var say: [String] = []
        @Option(help: "A tool the turn called (repeatable): an activity line and a tool_use record.") var tool: [String] = []

        func run() throws {
            try requireDev()
            let (store, paths) = try openStore()
            let c = try resolveCompany(store, company)
            let agent = try resolveAgent(store, company: c, handle: by)
            // The capture redacts with every secret loaded, or holds (writes nothing).
            _ = try store.reloadRedactorIfNeeded(vault: try cliSecretVault(interactive: false), logFailures: false)
            let turn = try store.startTurn(agentId: agent.id)
            var records: [[String: Any]] = [["type": "user", "message": ["role": "user", "content": prompt]]]
            for line in say {
                records.append(["type": "assistant", "message": ["role": "assistant", "content": [["type": "text", "text": line]]]])
            }
            for name in tool {
                try store.appendEvent(ActivityEvent(companyId: c.id, agentId: agent.id, turnId: turn.id, kind: .toolUse,
                                                    text: "@\(agent.name) \(name)", createdAt: Store.now()))
                records.append(["type": "assistant", "message": ["role": "assistant",
                                                                  "content": [["type": "tool_use", "name": name, "input": [:] as [String: Any]]]]])
            }
            let dir = try paths.ensureTmpDir().appending(path: "dev-turn-\(UUID().uuidString)", directoryHint: .isDirectory)
            defer { try? FileManager.default.removeItem(at: dir) }
            let source = TranscriptSource(configDir: dir)
            let sessionId = UUID().uuidString.lowercased()
            let file = source.projectsDir.appending(path: "-dev/\(sessionId).jsonl")
            try FileManager.default.createDirectory(at: file.deletingLastPathComponent(), withIntermediateDirectories: true)
            var data = Data()
            for record in records {
                data.append(try JSONSerialization.data(withJSONObject: record, options: [.sortedKeys]))
                data.append(0x0A)
            }
            try data.write(to: file)
            let outcome = TranscriptCapture(paths: paths, source: source).capture(turn: turn, sessionId: sessionId, store: store)
            _ = try store.finishTurn(id: turn.id, outcome: .succeeded, summary: summary, costUSD: nil)
            guard case .captured = outcome else { throw fail("turn \(turn.id) recorded, but its transcript was not captured: \(outcome)") }
            print(turn.id)
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
