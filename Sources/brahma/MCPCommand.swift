import ArgumentParser
import Foundation
import BrahmaCore
import BrahmaKeychain

struct MCP: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp", abstract: "Run the company MCP server for one agent over stdio.")

    @Option(help: "Path to the SQLite database.") var db: String
    @Option(help: "Company id.") var company: String
    @Option(help: "Agent id.") var agent: String
    @Option(help: "Credential kind the turn token was issued for.") var kind: String = "work"
    @Option(help: "Item id the turn token is bound to (review turns).") var item: String?
    @Option(name: .customLong("review-item"), help: "Item key of a review turn: the server offers the review tools for that item only.")
    var reviewItem: String?
    @Flag(name: .customLong("audit"), help: "An audit turn: the server offers the audit tool for the turn's batch only.")
    var audit = false

    func run() throws {
        signal(SIGPIPE, SIG_IGN)
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
        let store = try Store(path: db, catalog: catalog)
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
        let vault: any SecretVault
        do { vault = try PlatformSecretVault.resolve(paths: secretPaths).vault } catch {
            FileHandle.standardError.write(Data("brahma mcp: \(error)\n".utf8))
            throw ExitCode.failure
        }
        let check: @Sendable () throws -> Void = {
            try store.prepareForToolCall(vault: vault) { FileHandle.standardError.write(Data("brahma mcp: \($0)\n".utf8)) }
        }
        try? check()
        let server = MCPServer(tools: CompanyTools(store: store, companyId: company, agentId: me.id, reviewItemId: reviewItemId,
                                                   auditTurnId: auditTurnId, quotas: quotas, quotaTurnId: context.turnId,
                                                   planTurn: planTurn), beforeCall: check)
        server.serve(input: .standardInput, output: .standardOutput)
    }
}
