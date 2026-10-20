import ArgumentParser
import Foundation
import AgentCompanyCore

struct MCP: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mcp", abstract: "Run the company MCP server for one agent over stdio.")

    @Option(help: "Path to the SQLite database.") var db: String
    @Option(help: "Company id.") var company: String
    @Option(help: "Agent id.") var agent: String

    func run() throws {
        signal(SIGPIPE, SIG_IGN)
        let store = try Store(path: db)
        guard let me = try store.agent(id: agent), me.companyId == company else {
            FileHandle.standardError.write(Data("agentco mcp: unknown agent \(agent) in company \(company)\n".utf8))
            throw ExitCode.failure
        }
        let server = MCPServer(tools: CompanyTools(store: store, companyId: company, agentId: me.id))
        server.serve(input: .standardInput, output: .standardOutput)
    }
}

struct AgentCo: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agentco",
        abstract: "Agent Company command line.",
        subcommands: [MCP.self]
    )
}

AgentCo.main()
