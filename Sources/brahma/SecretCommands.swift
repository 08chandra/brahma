import ArgumentParser
import Foundation
import BrahmaCore

/// Owner-side secrets. Values go to the vault (the macOS Keychain), never to the database, and never into an agent's
/// hands unless they are test keys.
struct SecretGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "secret", abstract: "Store, list and remove a company's secrets (owner only).",
        subcommands: [Set.self, List.self, Remove.self])

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
                    value = String(cString: line)
                    guard !value.isEmpty else { throw SecretError.emptyValue }
                } else {
                    value = try SecretInput.read(from: .standardInput)
                }
                try store.setSecret(companyId: selected.id, name: name, value: value, isTest: test, vault: SecretVaults.platformDefault())
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
                try store.deleteSecret(companyId: selected.id, name: name, vault: SecretVaults.platformDefault())
            } catch let e as SecretError {
                throw fail(e.message)
            }
            print("removed \(name) from \(safe(selected.name))")
        }
    }
}
