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
        // N2: with no claude the doctor reports it missing and runs nothing by a bare name (no `plugin-details-inert` against
        // a name resolved in the current directory).
        let claude = try ExtLint.claudePath()
        let report: DoctorReport
        if let claude {
            report = await BrahmaCore.Doctor.run(claudePath: claude, runner: ClaudeProcessRunner(),
                                                 hookExecutable: hook, sandbox: sandbox,
                                                 canary: SandboxCanary(environment: .owner, sandbox: sandbox, hookExecutable: hook,
                                                                       baseline: Orchestrator.ownerSandboxBaseline(store: store, paths: paths)),
                                                 canaryPaths: paths)
        } else {
            let override = ProcessInfo.processInfo.environment["BRAHMA_CLAUDE"].flatMap { $0.isEmpty ? nil : $0 }
            let why = override.map { "BRAHMA_CLAUDE (\($0)) is not an executable file" } ?? "\(ToolPathsError.claudeMissing)"
            report = DoctorReport(cliVersion: nil, items: [DoctorItem(name: "version", status: .fail, detail: "claude was not found: \(why)")],
                                  checkedAt: .now)
        }
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
        let fingerprint = claude.flatMap { try? CLIFingerprint.of(claudePath: $0).key }
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
