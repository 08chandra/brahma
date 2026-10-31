import ArgumentParser
import Foundation
import BrahmaCore

struct Doctor: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "doctor",
        abstract: "Check the installed Claude Code CLI with real probe turns (uses a little of your plan).")

    func run() async throws {
        try requireOwnerShell()
        signal(SIGPIPE, SIG_IGN)
        let (store, paths) = try openStore()
        let report = await BrahmaCore.Doctor.run(claudePath: ExtLint.claudePath() ?? "claude", runner: ClaudeProcessRunner(),
                                                 hookExecutable: Bundle.main.executablePath ?? CommandLine.arguments[0],
                                                 sandbox: Orchestrator.ownerSandboxRunner(store: store, paths: paths))
        try? store.saveProbe(report)
        for item in report.items {
            print("\(item.status.rawValue.uppercased().padding(toLength: 4, withPad: " ", startingAt: 0))  \(item.name)  \(safe(item.detail))")
        }
        if let item = BrahmaCore.Doctor.planTierItem(configured: store.planTier(), reported: report.reportedSubscription) {
            print("\(item.status.rawValue.uppercased().padding(toLength: 4, withPad: " ", startingAt: 0))  \(item.name)  \(safe(item.detail))")
        }
        for item in await BrahmaCore.Doctor.backupItems(store: store) {
            print("\(item.status.rawValue.uppercased().padding(toLength: 4, withPad: " ", startingAt: 0))  \(item.name)  \(safe(item.detail))")
        }
        if !report.ok { throw ExitCode.failure }
        // A passing doctor is what ends an account or CLI hold (the running engine sees it on its next tick).
        try? store.clearHoldAfterDoctor(now: Date())
    }
}
