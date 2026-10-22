import ArgumentParser

@main
struct Brahma: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "brahma",
        abstract: "Brahma command line.",
        subcommands: [
            CompanyGroup.self, Hire.self, Say.self, Log.self, Search.self, Status.self,
            Kill.self, Pause.self, Wake.self, Run.self, MCP.self, OrgGroup.self, Doctor.self, OwnerGroup.self, SettingsGroup.self, ItemsGroup.self,
            Inbox.self, Approve.self, Answer.self, DevGroup.self,
        ]
    )
}
