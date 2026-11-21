import ArgumentParser
import Foundation
import BrahmaCore

/// `brahma stop`: the owner's emergency stop (Task 7c). The row is written first; then this command itself signals every
/// process group the engine recorded (`EmergencyStop.signalEngineGroups`: SIGTERM, then SIGKILL after `EmergencyStop.grace`
/// awake seconds), so a wedged or absent engine cannot keep agents running. A running engine also cancels its turns and checks at its next tick. Idempotent.
struct StopCommand: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "stop",
        abstract: "Stop every agent, check, preview and deploy in all companies now (owner only). Nothing runs until 'brahma resume'.")
    @Option(help: "Why (kept with the stop).") var note: String?

    func run() throws {
        try requireOwnerShell()
        let (store, paths) = try openStore()
        let row = try store.emergencyStop(note: note, by: "cli", now: Date())
        let signalled = EmergencyStop.signalEngineGroups(store: store, paths: paths)
        print(EmergencyStop.statusLine(row, timeZone: store.ownerTimeZone()))
        if !signalled.terminated.isEmpty {
            let killed = signalled.killed.isEmpty ? "" : " (\(signalled.killed.count) needed SIGKILL)"
            print("signalled \(signalled.terminated.count) turn process group(s)\(killed)")
        }
        print("Nothing runs until you run 'brahma resume'.")
    }
}

struct ResumeCommand: ParsableCommand {
    static let configuration = CommandConfiguration(commandName: "resume", abstract: "End the owner's stop: scheduling starts again (owner only).")

    func run() throws {
        try requireOwnerShell()
        let (store, _) = try openStore()
        print(try store.resumeAfterStop(now: Date()) ? "Resumed: agents may run again." : "Not stopped.")
    }
}
