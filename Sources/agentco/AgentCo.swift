import ArgumentParser

@main
struct AgentCo: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agentco",
        abstract: "Agent Company command line.",
        subcommands: [
            CompanyGroup.self, Hire.self, Say.self, Log.self, Search.self, Status.self,
            Kill.self, Pause.self, Wake.self, Run.self, MCP.self,
        ]
    )
}
