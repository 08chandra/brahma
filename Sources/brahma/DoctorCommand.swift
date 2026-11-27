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
        let hook = Bundle.main.executablePath ?? CommandLine.arguments[0]
        let sandbox = Orchestrator.ownerSandboxRunner(store: store, paths: paths)
        let claude = try ExtLint.claudePath() ?? "claude"
        let report = await BrahmaCore.Doctor.run(claudePath: claude, runner: ClaudeProcessRunner(),
                                                 hookExecutable: hook, sandbox: sandbox,
                                                 canary: SandboxCanary(environment: .owner, sandbox: sandbox, hookExecutable: hook,
                                                                       baseline: Orchestrator.ownerSandboxBaseline(store: store, paths: paths)),
                                                 canaryPaths: paths)
        try? store.saveProbe(report)
        for item in report.items {
            print("\(item.status.rawValue.uppercased().padding(toLength: 4, withPad: " ", startingAt: 0))  \(item.name)  \(safe(item.detail))")
        }
        // B9: the engine's tools by absolute path (resolved when the store was opened, as the engine does at its start).
        let tools = BrahmaCore.Doctor.toolPathsItem()
        print("\(tools.status.rawValue.uppercased().padding(toLength: 4, withPad: " ", startingAt: 0))  \(tools.name)  \(safe(tools.detail))")
        if let item = BrahmaCore.Doctor.planTierItem(configured: store.planTier(), reported: report.reportedSubscription) {
            print("\(item.status.rawValue.uppercased().padding(toLength: 4, withPad: " ", startingAt: 0))  \(item.name)  \(safe(item.detail))")
        }
        // F9 (Task 14u): why Ultra cannot run, per running company (informational; never fails the doctor).
        let fingerprint = try? CLIFingerprint.of(claudePath: claude).key
        for company in (try? store.companies()) ?? [] where company.status == .running {
            let reasons = store.ultraStatus(companyId: company.id, fingerprint: fingerprint)
            if !reasons.isEmpty { print("INFO  ultra  \(safe(company.slug)): \(safe(reasons.joined(separator: "; ")))") }
        }
        for item in await BrahmaCore.Doctor.backupItems(store: store) {
            print("\(item.status.rawValue.uppercased().padding(toLength: 4, withPad: " ", startingAt: 0))  \(item.name)  \(safe(item.detail))")
        }
        if let item = await BrahmaCore.Doctor.npmItem(store: store) {
            print("\(item.status.rawValue.uppercased().padding(toLength: 4, withPad: " ", startingAt: 0))  \(item.name)  \(safe(item.detail))")
        }
        if !report.ok || tools.status == .fail { throw ExitCode.failure }
        // A passing doctor is what ends an account or CLI hold (the running engine sees it on its next tick).
        try? store.clearHoldAfterDoctor(now: Date())
    }
}
