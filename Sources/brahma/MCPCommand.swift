import ArgumentParser
import Foundation
import BrahmaCore

struct MCP: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp", abstract: "Run the company MCP server for one agent over stdio.")

    @Option(help: "Path to the SQLite database.") var db: String
    @Option(help: "Company id.") var company: String
    @Option(help: "Agent id.") var agent: String

    func run() throws {
        signal(SIGPIPE, SIG_IGN)
        if let turnAgent = ProcessInfo.processInfo.environment["BRAHMA_AGENT_ID"], turnAgent != agent {
            FileHandle.standardError.write(Data("brahma mcp: --agent does not match this turn's agent\n".utf8))
            throw ExitCode.failure
        }
        let packs = BrahmaPaths.fromEnvironment().packsDir
        let catalog = PackCatalog.loadOrBuiltin(directory: packs) { FileHandle.standardError.write(Data(($0 + "\n").utf8)) }
        let store = try Store(path: db, catalog: catalog)
        guard let me = try store.agent(id: agent), me.companyId == company else {
            FileHandle.standardError.write(Data("brahma mcp: unknown agent \(agent) in company \(company)\n".utf8))
            throw ExitCode.failure
        }
        let server = MCPServer(tools: CompanyTools(store: store, companyId: company, agentId: me.id))
        server.serve(input: .standardInput, output: .standardOutput)
    }
}
