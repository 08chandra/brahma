import ArgumentParser
import Foundation
import BrahmaCore
import BrahmaKeychain

/// Owner-side secrets. Values go to the vault (the macOS Keychain; a dev/demo home's file store with
/// `BRAHMA_SECRET_STORE=file`), never to the database, and never into an agent's hands unless they are test keys.
struct SecretGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "secret", abstract: "Store, list and remove a company's secrets (owner only).",
        subcommands: [Set.self, List.self, Remove.self, Load.self])

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Store a secret. The value is read from standard input (or prompted for in a terminal).")
        @Argument(help: "Company name or slug.") var company: String
        @Argument(help: "Secret name: A-Z, 0-9 and _, for example STRIPE_KEY.") var name: String
        @Flag(help: "A test key: an agent working on an item may be given it in its environment. Without this the secret is engine-held.")
        var test = false

        func run() throws {
            try requireOwnerShell()
            guard SecretName.isValid(name) else { throw fail(SecretError.invalidName.message) }
            let (store, _) = try openStore()
            let selected = try resolveCompany(store, company)
            let value: String
            do {
                if isatty(STDIN_FILENO) != 0 {
                    guard let line = getpass("Value for \(name): ") else { throw SecretError.emptyValue }
                    // Not `String(cString:)`, which would repair bytes that are not UTF-8 into a different value.
                    guard let typed = String(validatingCString: line) else { throw SecretError.notUTF8 }
                    value = typed
                    guard !value.isEmpty else { throw SecretError.emptyValue }
                } else {
                    value = try SecretInput.read(from: .standardInput)
                }
                try store.setSecret(companyId: selected.id, name: name, value: value, isTest: test, vault: try cliSecretVault(interactive: true))
            } catch let e as SecretError {
                throw fail(e.message)
            }
            print("stored \(name) for \(safe(selected.name)) (\(test ? "test key: agents may be given it for an item" : "engine-held: agents never receive it"))")
            if value.count < Redactor.minLength {
                print("note: values shorter than \(Redactor.minLength) characters are not redacted from messages and logs")
            }
        }
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(abstract: "List a company's secrets (names and flags; never values).")
        @Argument(help: "Company name or slug.") var company: String

        func run() throws {
            let (store, _) = try openStore()
            let selected = try resolveCompany(store, company)
            let secrets = try store.secrets(companyId: selected.id)
            guard !secrets.isEmpty else { print("no secrets"); return }
            print("name  kind  created  updated  last used")
            for s in secrets {
                let parts = [s.name, s.isTest ? "test" : "engine-held", stamp(s.createdAt), stamp(s.updatedAt),
                             s.lastUsedAt.map(stamp) ?? "never"]
                print(safe(parts.joined(separator: "  ")))
            }
        }

        private func stamp(_ date: Date) -> String {
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US_POSIX")
            f.timeZone = cliTimeZone
            f.dateFormat = "yyyy-MM-dd HH:mm"
            return f.string(from: date)
        }
    }

    /// Loads every secret now, interactively: macOS may ask to allow access (choose Always Allow). This is how the owner
    /// unpauses agents held because a background read needed permission; the engine and `brahma mcp` retry at once.
    struct Load: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Load every secret now (macOS may ask you to allow access) so paused agents resume.")
        @Argument(help: "Company name or slug (optional; every company's secrets are loaded).") var company: String?

        func run() throws {
            try requireOwnerShell()
            let (store, _) = try openStore()
            if let company { _ = try resolveCompany(store, company) }
            let report: (loaded: Int, failed: [(name: String, reason: String)])
            do { report = try store.ownerLoadSecrets(vault: try cliSecretVault(interactive: true)) } catch let e as SecretError {
                throw fail(e.message)
            }
            guard report.failed.isEmpty else {
                for f in report.failed { FileHandle.standardError.write(Data("brahma: \(safe(f.name)): \(safe(f.reason))\n".utf8)) }
                throw fail("could not load \(report.failed.count) secret(s); agents stay paused")
            }
            print("loaded \(report.loaded) secret\(report.loaded == 1 ? "" : "s")")
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "rm", abstract: "Remove a secret.")
        @Argument(help: "Company name or slug.") var company: String
        @Argument(help: "Secret name.") var name: String

        func run() throws {
            try requireOwnerShell()
            guard SecretName.isValid(name) else { throw fail(SecretError.invalidName.message) }
            let (store, _) = try openStore()
            let selected = try resolveCompany(store, company)
            do {
                try store.deleteSecret(companyId: selected.id, name: name, vault: try cliSecretVault(interactive: true))
            } catch let e as SecretError {
                throw fail(e.message)
            }
            print("removed \(name) from \(safe(selected.name))")
        }
    }
}
