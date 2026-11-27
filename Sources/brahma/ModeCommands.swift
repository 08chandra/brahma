import ArgumentParser
import Foundation
import BrahmaCore

/// `brahma mode …` (Task 14u): the probe gates of the installed CLI, and why Ultra cannot run for a company.
struct ModeGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "mode", abstract: "Work-mode probe gates and Ultra status.",
        subcommands: [Gates.self, UltraStatusCommand.self])

    /// The installed CLI's fingerprint (a `stat`; the probe gates' key).
    static func fingerprint() throws -> (path: String, key: String) {
        let path = try ExtLint.claudePath() ?? "claude"
        do { return (path, try CLIFingerprint.of(claudePath: path).key) } catch { throw fail("\(error)") }
    }

    struct Gates: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "gates",
            abstract: "List the probe gates of the installed claude CLI per shape; --run runs the missing live gates (haiku, at most $0.05 each).")
        @Flag(help: "Run the gates that have not passed (live: uses a little of your plan).") var run = false

        func run() async throws {
            let (path, key) = try ModeGroup.fingerprint()
            let (store, paths) = try openStore()
            if run {
                try requireOwnerShell()
                signal(SIGPIPE, SIG_IGN)
                let hook = Bundle.main.executablePath ?? CommandLine.arguments[0]
                let runner = LiveProbeGates(paths: paths, environment: .owner, runner: ClaudeProcessRunner(claudePath: path),
                                            hookExecutable: hook)
                for r in try await ProbeGates.runMissing(runner: runner, store: store, fingerprint: key) {
                    print("ran  \(r.shape.rawValue)  \(r.gate)  \(r.passed ? "PASS" : "FAIL")  \(safe(r.detail))")
                }
            }
            let rows = try store.probeGateRows(fingerprint: key)
            print("claude \(safe(path)) (fingerprint \(key))")
            for shape in ProbeShape.allCases {
                for gate in ProbeGates.catalog(shape) {
                    let row = rows.first { $0.shape == shape.rawValue && $0.gate == gate }
                    let status = row.map { $0.passed ? "PASS" : "FAIL" } ?? "----"
                    let detail = row?.detail ?? ProbeGates.pendingOwner[gate] ?? "not run"
                    print("\(status)  \(shape.rawValue.padding(toLength: 15, withPad: " ", startingAt: 0))  "
                          + "\(gate.padding(toLength: 10, withPad: " ", startingAt: 0))  \(safe(detail))")
                }
            }
        }
    }

    struct UltraStatusCommand: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "ultra-status", abstract: "Why Ultra cannot run for a company right now (empty: it could, when approved).")
        @Argument(help: "Company name or slug.") var company: String

        func run() async throws {
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let fingerprint = try? ModeGroup.fingerprint().key
            let reasons = store.ultraStatus(companyId: c.id, fingerprint: fingerprint)
            if let a = try store.ultraAllowance(companyId: c.id, now: Date()) {
                print("Ultra allowance \(Int((c.ultraShare * 100).rounded()))% of share: $\(String(format: "%.2f", a.totalLE)) LE, "
                      + "used $\(String(format: "%.2f", a.usedLE)), left $\(String(format: "%.2f", max(0, a.leftLE)))")
            } else {
                print("Ultra allowance \(Int((c.ultraShare * 100).rounded()))% of share (not calibrated yet)")
            }
            if reasons.isEmpty { print("Ultra: available when approved") }
            for r in reasons { print("- \(safe(r))") }
        }
    }
}

extension SettingsGroup {
    /// `brahma settings ultra-share <co> <0–50>`: the share of the company's weekly share its Ultra runs may use.
    struct UltraShare: ParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "ultra-share", abstract: "Show or set the percentage of a company's weekly share Ultra runs may use (0-50; 0 turns Ultra off).")
        @Argument(help: "Company name or slug.") var company: String
        @Argument(help: "Percent, 0 to 50; omit to show the current one.") var percent: Int?

        func run() throws {
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            if let percent {
                guard (0...50).contains(percent) else { throw fail("ultra share must be between 0 and 50 percent") }
                try requireOwnerShell()
                try store.setUltraShare(companyId: c.id, percent: percent)
            }
            let share = try store.company(id: c.id)?.ultraShare ?? c.ultraShare
            print("ultra share (\(safe(c.slug))): \(Int((share * 100).rounded()))% of the weekly share")
        }
    }
}
