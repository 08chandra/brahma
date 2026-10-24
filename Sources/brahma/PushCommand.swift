import ArgumentParser
import Foundation
import BrahmaCore

struct PushGroup: AsyncParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "push", abstract: "Phone alerts through ntfy or Pushover.", subcommands: [Test.self])

    struct Test: AsyncParsableCommand {
        static let configuration = CommandConfiguration(
            commandName: "test", abstract: "Send one test alert to the service set with 'brahma prefs set push' (owner only).")

        func run() async throws {
            try requireOwnerShell()
            let (store, _) = try openStore()
            let result: PushResult
            do {
                result = try await PushDispatcher.sendTest(store: store, vault: try cliSecretVault())
            } catch let e as PushError {
                throw fail(e.description)
            }
            if result.ok {
                print("sent (HTTP \(result.status ?? 0))")
            } else {
                throw fail("the test alert failed: \(safe(result.status.map { "HTTP \($0)" } ?? result.error ?? "no answer"))")
            }
        }
    }
}
