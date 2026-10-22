import ArgumentParser
import Foundation
import BrahmaCore

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
        if context.kind == "review" {
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
        let server = MCPServer(tools: CompanyTools(store: store, companyId: company, agentId: me.id, reviewItemId: reviewItemId))
        server.serve(input: .standardInput, output: .standardOutput)
    }
}
