import ArgumentParser
import Foundation
import BrahmaCore
import BrahmaKeychain

struct MCP: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp", abstract: "Run the company MCP server for one agent over stdio.")

    @Option(help: "Path to the SQLite database (else BRAHMA_MCP_DB).") var db: String?
    @Option(help: "Company id (else BRAHMA_MCP_COMPANY).") var company: String?
    @Option(help: "Agent id (else BRAHMA_MCP_AGENT).") var agent: String?
    @Option(help: "Credential kind the turn token was issued for.") var kind: String = "work"
    @Option(help: "Item id the turn token is bound to (review turns).") var item: String?
    @Option(name: .customLong("review-item"), help: "Item key of a review turn: the server offers the review tools for that item only.")
    var reviewItem: String?
    @Flag(name: .customLong("audit"), help: "An audit turn: the server offers the audit tool for the turn's batch only.")
    var audit = false
    @Option(name: .customLong("show-request"), help: "The concierge's show request (only with --agent concierge).")
    var showRequest: String?
    @Option(help: "The engine's git, by absolute path (re-checked here; never looked up on PATH).") var git: String?

    func run() throws {
        signal(SIGPIPE, SIG_IGN)
        // The flags, or the server's env block (a sandboxed turn's prefix starts it as just `brahma mcp`); both must agree.
        let launch: MCPLaunch
        do {
            launch = try MCPLaunch.resolve(db: db, company: company, agent: agent, reviewItem: reviewItem, audit: audit,
                                           showRequest: showRequest, environment: ProcessInfo.processInfo.environment)
        } catch {
            FileHandle.standardError.write(Data("brahma mcp: \(error)\n".utf8))
            throw ExitCode.failure
        }
        let db = launch.db, company = launch.company, agent = launch.agent
        let reviewItem = launch.reviewItem, audit = launch.audit
        if let turnAgent = ProcessInfo.processInfo.environment["BRAHMA_AGENT_ID"], turnAgent != agent {
            FileHandle.standardError.write(Data("brahma mcp: --agent does not match this turn's agent\n".utf8))
            throw ExitCode.failure
        }
        // Fail closed: the per-turn token (from the 0600 MCP config's env) must match an in-progress turn of
        // exactly this company, agent, kind and item.
        guard let token = ProcessInfo.processInfo.environment[MCPConfig.tokenVariable], !token.isEmpty else {
            FileHandle.standardError.write(Data("brahma mcp: missing turn credential\n".utf8))
            throw ExitCode.failure
        }
        let packs = BrahmaPaths.fromEnvironment().packsDir
        let catalog = PackCatalog.loadOrBuiltin(directory: packs) { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
        // Controller Ruling C6-3: this is an agent's process, before any Store opens: no owner principal can be minted in it, so no
        // owner-only Store API is reachable from a tool, however one were wired. An unknown role here refuses (fail closed).
        OwnerPrincipal.enterAgentProcess()
        do { try OwnerPrincipal.requireAgentProcess() } catch {
            FileHandle.standardError.write(Data("brahma mcp: \(error)\n".utf8))
            throw ExitCode.failure
        }
        let store = try Store(path: db, catalog: catalog)
        // Plan C Task C4c: the concierge's server. Its process runs as `BRAHMA_AGENT_ID=concierge` (so no owner command runs from
        // it), its token must name the live run of exactly this request in this company, and it serves only the concierge's
        // four tools, read as `.concierge`. Archives and PDFs are refused in its `open_ref` (no gate broker: fail closed).
        if agent == ConciergeCaps.agentId {
            guard ProcessInfo.processInfo.environment["BRAHMA_AGENT_ID"] == ConciergeCaps.agentId, let request = launch.showRequest,
                  store.conciergeCredentialIsValid(token: token, companyId: company, requestId: request) else {
                FileHandle.standardError.write(Data("brahma mcp: concierge credential invalid or run ended\n".utf8))
                throw ExitCode.failure
            }
            let secretPaths = BrahmaPaths(home: URL(fileURLWithPath: db).deletingLastPathComponent(),
                                          workspaces: BrahmaPaths.fromEnvironment().workspaces)
            let vault: any SecretVault
            do {
                let selection = try PlatformSecretVault.resolve(paths: secretPaths)
                try PlatformSecretVault.refuseMemory(selection)
                vault = selection.vault
            } catch {
                FileHandle.standardError.write(Data("brahma mcp: \(error)\n".utf8))
                throw ExitCode.failure
            }
            let check: @Sendable () throws -> Void = {
                try store.prepareForToolCall(vault: vault) { FileHandle.standardError.write(Data("brahma mcp: \($0)\n".utf8)) }
            }
            try? check()
            MCPServer(tools: CompanyTools(store: store, companyId: company, agentId: ConciergeCaps.agentId, paths: secretPaths, vault: vault,
                                          conciergeRequestId: request), beforeCall: check)
                .serve(input: .standardInput, output: .standardOutput)
            return
        }
        // The credential comes first, and it alone decides the mode: a review token opens the review tools for its own item and
        // nothing else; no flag can widen it or turn another token into a review server.
        guard let context = store.turnCredentialContext(token: token, companyId: company, agentId: agent) else {
            FileHandle.standardError.write(Data("brahma mcp: turn credential invalid or turn ended\n".utf8))
            throw ExitCode.failure
        }
        var reviewItemId: String?
        var auditTurnId: String?
        var planTurn = false
        if context.kind == "audit" {
            // An audit credential is bound to its turn, whose batch the store holds; it names no item and no review.
            guard context.itemId == nil, reviewItem == nil else {
                FileHandle.standardError.write(Data("brahma mcp: turn credential invalid or turn ended\n".utf8))
                throw ExitCode.failure
            }
            auditTurnId = context.turnId
        } else if audit {
            FileHandle.standardError.write(Data("brahma mcp: --audit does not match this turn's credential\n".utf8))
            throw ExitCode.failure
        } else if context.kind == "plan" {
            // A plan turn's token: the read-mostly surface, whatever the flags say.
            guard reviewItem == nil, context.itemId != nil else {
                FileHandle.standardError.write(Data("brahma mcp: turn credential invalid or turn ended\n".utf8))
                throw ExitCode.failure
            }
            planTurn = true
        } else if context.kind == "review" {
            guard let itemId = context.itemId else {
                FileHandle.standardError.write(Data("brahma mcp: turn credential invalid or turn ended\n".utf8))
                throw ExitCode.failure
            }
            if let key = reviewItem {
                guard let found = try store.workItem(companyId: company, key: key), found.id == itemId else {
                    FileHandle.standardError.write(Data("brahma mcp: --review-item does not match this turn's credential\n".utf8))
                    throw ExitCode.failure
                }
            }
            reviewItemId = itemId
        } else if reviewItem != nil || context.kind != kind || context.itemId != item {
            FileHandle.standardError.write(Data("brahma mcp: turn credential invalid or turn ended\n".utf8))
            throw ExitCode.failure
        }
        guard let me = try store.agent(id: agent), me.companyId == company else {
            FileHandle.standardError.write(Data("brahma mcp: unknown agent \(agent) in company \(company)\n".utf8))
            throw ExitCode.failure
        }
        // The turn's mode quotas come from its credential row (the strictest when none were recorded), never from this process's
        // environment, and are counted in the database per turn; review and audit turns have none.
        let quotas = reviewItemId == nil && auditTurnId == nil ? context.quotas ?? .strictest : nil
        // The secret store is resolved against the database's own home (a dev/demo home's `BRAHMA_SECRET_STORE=file` arrives
        // through the MCP config; it is refused for the default home). Secrets added or removed by the owner apply to the next
        // tool call, not the next turn, and every call is refused while any secret is not loaded (fail closed).
        let secretPaths = BrahmaPaths(home: URL(fileURLWithPath: db).deletingLastPathComponent(),
                                      workspaces: BrahmaPaths.fromEnvironment().workspaces)
        // Ruling S5-4: before any git, this server's git is the engine's (`--git`), re-checked with the engine's rules against
        // the data homes, the workspaces directory and this company's workspace. None given, or one refused: every git of this
        // server refuses (`gitMissing`); nothing is ever looked up on PATH.
        let companyWorkspace: String?
        do { companyWorkspace = try store.company(id: company)?.workspacePath } catch { companyWorkspace = nil }
        if case .failure(let problem) = ToolPaths.installForMCPServer(git: git, paths: BrahmaPaths.fromEnvironment(),
                                                                       databaseHome: secretPaths.home, companyWorkspace: companyWorkspace) {
            FileHandle.standardError.write(Data("brahma mcp: the engine's git is unavailable here, so its git tools refuse: \(problem)\n".utf8))
        }
        let vault: any SecretVault
        do {
            let selection = try PlatformSecretVault.resolve(paths: secretPaths)   // non-interactive: never prompts
            try PlatformSecretVault.refuseMemory(selection)
            vault = selection.vault
        } catch {
            FileHandle.standardError.write(Data("brahma mcp: \(error)\n".utf8))
            throw ExitCode.failure
        }
        let check: @Sendable () throws -> Void = {
            try store.prepareForToolCall(vault: vault) { FileHandle.standardError.write(Data("brahma mcp: \($0)\n".utf8)) }
        }
        try? check()
        let server = MCPServer(tools: CompanyTools(store: store, companyId: company, agentId: me.id, reviewItemId: reviewItemId,
                                                   auditTurnId: auditTurnId, quotas: quotas, quotaTurnId: context.turnId,
                                                   planTurn: planTurn,
                                                   // The hook's fail-closed mark: present, every high-risk call is refused.
                                                   taintFlag: TaintFlag.url(home: secretPaths.home, agentId: me.id),
                                                   // `remember` refuses a fact holding a stored secret's value.
                                                   vault: vault,
                                                   // C3b (Ruling 48): archives and PDFs in `share`, `open_ref` and attachments
                                                   // are gated by the engine, outside the turn's sandbox; no helper runs here.
                                                   archives: EngineGateArchives(broker: QueuedRefGate(store: store, turnId: context.turnId))),
                               beforeCall: check)
        server.serve(input: .standardInput, output: .standardOutput)
    }
}
