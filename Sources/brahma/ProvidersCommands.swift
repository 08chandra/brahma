import ArgumentParser
import Foundation
import BrahmaCore

/// Plan X1 Task 11: the model providers the gateway may reach, owner-wide. Listing refuses inside an agent turn (Ruling 21);
/// adding and removing need the owner shell. A provider's key lives in each company's vault, engine-held, under the name the
/// provider gives (`brahma secret set <company> <NAME>`); this command never reads or shows a key value, and makes no
/// network call.
struct ProvidersGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "providers",
        abstract: "List, add and remove the model providers the gateway may reach.",
        discussion: """
            A provider is an adapter, an https base URL whose host is the only one the gateway reaches for it, and the name \
            of the secret holding its key. Keys are set per company with `brahma secret set`, engine-held: agents never \
            receive them. The four built-in providers cannot be removed.

            EXAMPLES:
              brahma providers
              brahma providers list --company acme
              brahma providers add openrouter-eu --adapter openai-compatible --base-url https://eu.openrouter.ai/api/v1 --key-secret BRAHMA_KEY_OPENROUTER_EU
              brahma providers remove openrouter-eu
            """,
        subcommands: [List.self, Add.self, Remove.self],
        defaultSubcommand: List.self)

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List every provider: id, adapter, pinned host, key secret name; with --company, whether that company's key is set.",
            discussion: """
                Shows whether a key is set, never its value.

                EXAMPLES:
                  brahma providers list
                  brahma providers list --company acme
                """)

        @Option(help: ArgumentHelp("Company name or slug: also show whether its key for each provider is set.", valueName: "company"))
        var company: String?

        func run() throws {
            try refuseInsideAgentTurn()  // first: inside a turn nothing else is checked (Ruling 21)
            let (store, _) = try openStore()
            let selected = try company.map { try resolveCompany(store, $0) }
            let secrets = try selected.map { try store.secrets(companyId: $0.id) } ?? []
            for p in try store.providers() {
                var parts = [p.id, p.adapter, p.host, p.keySecret ?? "none", p.builtin ? "built-in" : "added"]
                if p.lan { parts.append("LAN") }
                if let selected {
                    let row = p.keySecret.flatMap { key in secrets.first { $0.name == key } }
                    switch row {
                    case nil: parts.append("key not set for \(selected.name)")
                    case let s? where s.isTest: parts.append("key flagged test in \(selected.name): refused until set engine-held")
                    case .some: parts.append("key set for \(selected.name)")
                    }
                }
                print(safe(parts.joined(separator: "  ")))
            }
        }
    }

    struct Add: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Add a provider (owner only). Makes no network call.",
            discussion: """
                The base URL must be https://<host name> (never an IP address or localhost) on port 443, with no user name, \
                password, query or fragment; its host is the only one the gateway reaches for this provider, and a redirect \
                away from it is refused. The key secret is ANTHROPIC_API_KEY (sent only to api.anthropic.com) or \
                BRAHMA_KEY_<PROVIDER>; set its value per company with `brahma secret set <company> <NAME>`, never --test. \
                LAN providers arrive with local servers in X1b.

                EXAMPLES:
                  brahma providers add openrouter-eu --adapter openai-compatible --base-url https://eu.openrouter.ai/api/v1 --key-secret BRAHMA_KEY_OPENROUTER_EU
                  brahma secret set acme BRAHMA_KEY_OPENROUTER_EU
                """)

        @Argument(help: ArgumentHelp("Provider id: 2-32 of a-z, 0-9 and -, starting with a letter.", valueName: "id"))
        var id: String
        @Option(help: ArgumentHelp("The adapter: openai-compatible or anthropic.", valueName: "adapter"))
        var adapter: String
        @Option(name: .customLong("base-url"), help: ArgumentHelp("The provider's https base URL, e.g. https://eu.openrouter.ai/api/v1.", valueName: "url"))
        var baseURL: String
        @Option(name: .customLong("key-secret"), help: ArgumentHelp("The name of the secret holding the key: ANTHROPIC_API_KEY or BRAHMA_KEY_<PROVIDER>.", valueName: "NAME"))
        var keySecret: String?

        func run() throws {
            try refuseInsideAgentTurn()  // first: inside a turn nothing else is checked (Ruling 21)
            guard Provider.isValidId(id) else { throw fail(Provider.idRule) }
            guard let url = URL(string: baseURL, encodingInvalidCharacters: false) else { throw fail("--base-url is not a URL") }
            let host: String
            switch ProviderHost.validate(baseURL: url, adapter: AdapterId(rawValue: adapter), lan: false) {
            case .failure(let refusal): throw fail(refusal.reason)
            case .success(let pinned): host = pinned
            }
            if let keySecret {
                guard SecretName.isValid(keySecret) else { throw fail(SecretError.invalidName.message) }
                guard ProviderHost.isProviderKeyName(keySecret) else {
                    throw fail("--key-secret must be \(Provider.anthropicKeyName) or \(Provider.keyNamePrefix)<PROVIDER>: "
                               + "use \(Self.suggestedKeyName(for: keySecret, id: id))")
                }
            }
            try requireOwnerShell()
            let (store, _) = try openStore()
            let provider = Provider(id: id, adapter: adapter, baseURL: url, host: host, keySecret: keySecret, createdAt: Date())
            do { try store.addProvider(provider) } catch { throw fail("\(error)") }
            let key = keySecret ?? "none"
            print(safe("added provider \(id): \(adapter) \(url.absoluteString) (host \(host), key \(key))"))
            if let keySecret {
                print(safe("set its key per company, engine-held: brahma secret set <company> \(keySecret)"))
            } else {
                print("it has no key secret: the gateway refuses it until one is named")
            }
        }

        /// The provider key name to suggest for a refused `--key-secret`: its stem (`OPENROUTER_API_KEY` → `OPENROUTER`) under
        /// `BRAHMA_KEY_`, or the provider id's when the name gives none.
        static func suggestedKeyName(for name: String, id: String) -> String {
            var stem = name
            for suffix in ["_API_KEY", "_API_TOKEN", "_KEY", "_TOKEN", "_SECRET"] where stem.hasSuffix(suffix) {
                stem.removeLast(suffix.count)
                break
            }
            let fromName = Provider.keyNamePrefix + stem
            if !["", "API"].contains(stem), !name.hasPrefix("BRAHMA_"), !name.hasPrefix("ANTHROPIC_"), Provider.isKeyName(fromName) {
                return fromName
            }
            return Provider.keyNamePrefix + id.uppercased().replacingOccurrences(of: "-", with: "_")
        }
    }

    struct Remove: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Remove an added provider (owner only). Refused for a built-in, and while a route or cap names it.",
            discussion: """
                EXAMPLES:
                  brahma providers remove openrouter-eu
                """)

        @Argument(help: ArgumentHelp("Provider id.", valueName: "id")) var id: String

        func run() throws {
            try refuseInsideAgentTurn()  // first (Ruling 21)
            try requireOwnerShell()
            let (store, _) = try openStore()
            do { try store.removeProvider(id: id) } catch { throw fail("\(error)") }
            print(safe("removed provider \(id)"))
        }
    }
}
