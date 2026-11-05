import ArgumentParser

@main
struct Brahma: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "brahma",
        abstract: "Brahma command line.",
        subcommands: [
            CompanyGroup.self, Hire.self, Say.self, Log.self, Search.self, Status.self,
            Kill.self, Pause.self, Wake.self, Run.self, MCP.self, OrgGroup.self, Doctor.self, OwnerGroup.self, SettingsGroup.self, ItemsGroup.self, Timers.self,
            Inbox.self, Approve.self, Answer.self, Rescind.self, Why.self, MainGroup.self, SprintGroup.self, DevGroup.self, PerfGroup.self, HookGroup.self,
            PrefsGroup.self, PushGroup.self, Notices.self, SecretGroup.self, Network.self, BackupGroup.self, RestoreCommand.self, ExportCommand.self, TranscriptCommand.self, DigestCommand.self, AccessGroup.self, GrantsGroup.self, Presets.self, ExtGroup.self, PreviewGroup.self,
            StopCommand.self, ResumeCommand.self, ModeGroup.self, HostingCommand.self, ReleaseGroup.self, HumanTaskGroup.self,
        ]
    )
}
