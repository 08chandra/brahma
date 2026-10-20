import ArgumentParser

struct AgentCo: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "agentco",
        abstract: "Agent Company command line."
    )
}

AgentCo.main()
