import ArgumentParser
import Foundation
import BrahmaCore

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check the installed Claude Code CLI with real probe turns (uses a little of your plan).")

    func run() async throws {
        signal(SIGPIPE, SIG_IGN)
        let (store, _) = try openStore()
        let report = await BrahmaCore.Doctor.run(claudePath: "claude", runner: ClaudeProcessRunner())
        try? store.saveProbe(report)
        for item in report.items {
            print("\(item.status.rawValue.uppercased().padding(toLength: 4, withPad: " ", startingAt: 0))  \(item.name)  \(safe(item.detail))")
        }
        if !report.ok { throw ExitCode.failure }
    }
}
