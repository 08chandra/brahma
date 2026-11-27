import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Plan X1 Task 11: `brahma providers [list] [--company <co>]`, `providers add <id> --adapter <a> --base-url <url>
/// [--key-secret <NAME>]` and `providers remove <id>`. Listing is owner-wide and shows only whether a company's key is set,
/// never a value; adding and removing need the owner shell; every form refuses inside an agent turn (Rulings 21, 60). `add`
/// makes no network call.
@Suite(.scratch) struct ProvidersCommandTests {
    /// The built `brahma` with `stdin` fed (the secret value for `brahma secret set`).
    private func brahma(_ args: [String], home: URL, extra: [String: String] = [:], stdin: String = "") throws -> BrahmaResult {
        let p = Process()
        p.executableURL = brahmaExecutableURL()
        p.arguments = args
        p.environment = cliEnvironment(home: home).merging(extra) { $1 }
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = inp
        try p.run()
        inp.fileHandleForWriting.write(Data(stdin.utf8))
        try inp.fileHandleForWriting.close()
        let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return BrahmaResult(status: p.terminationStatus, stdout: String(decoding: o, as: UTF8.self), stderr: String(decoding: e, as: UTF8.self))
    }

    private static let add = ["providers", "add", "acme-llm", "--adapter", "openai-compatible", "--base-url", "https://llm.example.com/v1",
                              "--key-secret", "BRAHMA_KEY_ACME_LLM"]

    @Test func addListRemove() throws {
        let owner = try OwnerTestHome(); let home = owner.url
        #expect(try brahma(["company", "create", "Acme", "--goal", "g", "--agents", "0"], home: home).status == 0)

        let fresh = try brahma(["providers"], home: home)
        #expect(fresh.status == 0, "\(fresh.stderr)")
        #expect(fresh.stdout.contains("anthropic  anthropic  api.anthropic.com  ANTHROPIC_API_KEY  built-in\n"), "\(fresh.stdout)")
        #expect(fresh.stdout.contains("groq  openai-compatible  api.groq.com  BRAHMA_KEY_GROQ  built-in\n"), "\(fresh.stdout)")
        #expect(try brahma(["providers", "list"], home: home).stdout == fresh.stdout)

        let added = try brahma(Self.add, home: home)
        #expect(added.status == 0, "\(added.stderr)")
        #expect(added.stdout.hasPrefix("added provider acme-llm: openai-compatible https://llm.example.com/v1 (host llm.example.com, key BRAHMA_KEY_ACME_LLM)\n"),
                "\(added.stdout)")
        #expect(added.stdout.contains("brahma secret set <company> BRAHMA_KEY_ACME_LLM"), "\(added.stdout)")
        let store = try Store(path: ownerPaths(home).database.path)
        let stored = try #require(try store.provider(id: "acme-llm"))
        #expect(stored.host == "llm.example.com" && !stored.lan && !stored.builtin && stored.adapter == "openai-compatible")
        try store.close()

        let listed = try brahma(["providers", "list"], home: home).stdout
        #expect(listed.contains("acme-llm  openai-compatible  llm.example.com  BRAHMA_KEY_ACME_LLM  added\n"), "\(listed)")
        // With a company: whether its key is set there, never the value.
        let value = "acme-llm-provider-value-123"
        let set = try brahma(["secret", "set", "Acme", "BRAHMA_KEY_ACME_LLM"], home: home, stdin: value + "\n")
        #expect(set.status == 0, "\(set.stderr)")
        let forCompany = try brahma(["providers", "list", "--company", "Acme"], home: home)
        #expect(forCompany.status == 0, "\(forCompany.stderr)")
        #expect(forCompany.stdout.contains("acme-llm  openai-compatible  llm.example.com  BRAHMA_KEY_ACME_LLM  added  key set for Acme\n"),
                "\(forCompany.stdout)")
        #expect(forCompany.stdout.contains("openai  openai-compatible  api.openai.com  BRAHMA_KEY_OPENAI  built-in  key not set for Acme\n"),
                "\(forCompany.stdout)")
        #expect(!forCompany.stdout.contains(value) && !forCompany.stderr.contains(value))
        #expect(try brahma(["providers", "--company", "Nope"], home: home).stderr.contains("no company named 'Nope'"))

        // Refusals: a taken id, an id outside the rule, a URL outside the pinned-host rule, an unknown adapter.
        let again = try brahma(Self.add, home: home)
        #expect(again.status == 1 && again.stderr.contains("provider acme-llm already exists"), "\(again.stderr)")
        for (id, why) in [("Acme", "a provider id is 2-32 of a-z, 0-9 and -, starting with a letter"),
                          ("1abc", "a provider id is 2-32 of a-z, 0-9 and -, starting with a letter"),
                          ("a", "a provider id is 2-32 of a-z, 0-9 and -, starting with a letter"),
                          (String(repeating: "a", count: 33), "a provider id is 2-32 of a-z, 0-9 and -, starting with a letter")] {
            let r = try brahma(["providers", "add", id, "--adapter", "openai-compatible", "--base-url", "https://x.example.com"], home: home)
            #expect(r.status == 1 && r.stderr == "brahma: \(why)\n", "\(id): \(r.stderr)")
        }
        for (url, why) in [("http://x.example.com/v1", "a provider's base URL must be https"),
                           ("https://127.0.0.1/v1", "a provider's base URL must name its host, never an IP address or localhost"),
                           ("https://u:p@x.example.com/v1", "a provider's base URL must not hold a user name or password"),
                           ("https://x.example.com:8443/v1", "a provider's base URL must use port 443 (or none)"),
                           ("https://x.example.com:00443/v1", "a provider's base URL must use port 443 (or none)"),
                           ("https://llm.internal/v1", "a provider's base URL must name its host, never an IP address or localhost"),
                           ("https://exa%6Dple.com/v1", "a provider's base URL must not percent-encode its host"),
                           ("not a url", "--base-url is not a URL")] {
            let r = try brahma(["providers", "add", "xx", "--adapter", "openai-compatible", "--base-url", url], home: home)
            #expect(r.status == 1 && r.stderr == "brahma: \(why)\n", "\(url): \(r.stderr)")
        }
        let local = try brahma(["providers", "add", "xx", "--adapter", "local", "--base-url", "https://x.example.com"], home: home)
        #expect(local.status == 1 && local.stderr.contains("no adapter local: X1 has anthropic and openai-compatible"), "\(local.stderr)")
        // The Anthropic key goes only to Anthropic's host.
        let leak = try brahma(["providers", "add", "xx", "--adapter", "anthropic", "--base-url", "https://proxy.example.com",
                               "--key-secret", "ANTHROPIC_API_KEY"], home: home)
        #expect(leak.status == 1 && leak.stderr.contains("ANTHROPIC_API_KEY is sent only to api.anthropic.com"), "\(leak.stderr)")
        #expect(!(try brahma(["providers"], home: home).stdout.contains("xx  ")), "nothing refused was written")

        // Removing: a built-in and an unknown id are refused; the added one goes.
        let builtin = try brahma(["providers", "remove", "groq"], home: home)
        #expect(builtin.status == 1 && builtin.stderr.contains("groq is a built-in provider and cannot be removed"), "\(builtin.stderr)")
        let unknown = try brahma(["providers", "remove", "nope"], home: home)
        #expect(unknown.status == 1 && unknown.stderr.contains("no such provider: nope"), "\(unknown.stderr)")
        let removed = try brahma(["providers", "remove", "acme-llm"], home: home)
        #expect(removed.status == 0 && removed.stdout == "removed provider acme-llm\n", "\(removed.stdout) \(removed.stderr)")
        #expect(!(try brahma(["providers"], home: home).stdout.contains("acme-llm")))

        let help = try brahma(["providers", "add", "--help"], home: home)
        #expect(help.stdout.contains("EXAMPLES:") && help.stdout.contains("brahma providers add openrouter-eu"), "\(help.stdout)")
        let groupHelp = try brahma(["providers", "--help"], home: home)
        #expect(groupHelp.stdout.contains("EXAMPLES:") && groupHelp.stdout.contains("brahma providers list --company"), "\(groupHelp.stdout)")
    }

    /// `--key-secret` must be a provider key name, with a hint; and never a name that is a test key in any company.
    @Test func keySecretMustBeProviderKeyName() throws {
        let owner = try OwnerTestHome(); let home = owner.url
        #expect(try brahma(["company", "create", "Acme", "--goal", "g", "--agents", "0"], home: home).status == 0)
        func add(_ key: String, id: String = "openrouter-eu") throws -> BrahmaResult {
            try brahma(["providers", "add", id, "--adapter", "openai-compatible", "--base-url", "https://eu.openrouter.ai/api/v1",
                        "--key-secret", key], home: home)
        }
        let r = try add("OPENROUTER_API_KEY")
        #expect(r.status == 1, "\(r.stdout)")
        #expect(r.stderr == "brahma: --key-secret must be ANTHROPIC_API_KEY or BRAHMA_KEY_<PROVIDER>: use BRAHMA_KEY_OPENROUTER\n", "\(r.stderr)")
        // A stem naming another built-in provider's key would be refused for this host (Ruling X1-38): the id's name instead.
        #expect(try add("GROQ_TOKEN").stderr.contains("use BRAHMA_KEY_OPENROUTER_EU"))
        #expect(try add("ACME_TOKEN").stderr.contains("use BRAHMA_KEY_ACME"))
        // The built-in OpenRouter key may serve an OpenRouter subdomain; another built-in key may not.
        let foreign = try add("BRAHMA_KEY_GROQ", id: "groq-eu")
        #expect(foreign.status == 1 && foreign.stderr == "brahma: BRAHMA_KEY_GROQ is sent only to groq.com and its subdomains\n", "\(foreign.stderr)")
        #expect(try add("MY_SECRET_THING").stderr.contains("use BRAHMA_KEY_MY_SECRET_THING"))
        // No usable stem: the hint names the provider id.
        #expect(try add("API_KEY").stderr.contains("use BRAHMA_KEY_OPENROUTER_EU"))
        #expect(try add("lower").stderr.contains("invalid secret name"))
        #expect(try add("BRAHMA_KEY_").stderr.contains("use BRAHMA_KEY_OPENROUTER_EU"))

        // A test key of that name in some company (written by other means: no API makes one) refuses the provider.
        let store = try Store(path: ownerPaths(home).database.path)
        let acme = try #require(try store.companies().first)
        try store.writer.write { db in
            try db.execute(sql: """
                INSERT INTO secret (id, companyId, name, isTest, createdAt, updatedAt) VALUES ('s1', ?, 'BRAHMA_KEY_TAINTED', 1, ?, ?)
                """, arguments: [acme.id, Date(), Date()])
        }
        try store.close()
        let tainted = try add("BRAHMA_KEY_TAINTED")
        #expect(tainted.status == 1, "\(tainted.stdout)")
        #expect(tainted.stderr.contains("BRAHMA_KEY_TAINTED is a test key in Acme"), "\(tainted.stderr)")
        let ok = try add("BRAHMA_KEY_OPENROUTER_EU")
        #expect(ok.status == 0, "\(ok.stderr)")
        #expect(try add("BRAHMA_KEY_OPENROUTER", id: "openrouter-eu2").status == 0)
        let list = try brahma(["providers"], home: home).stdout
        #expect(list.contains("openrouter-eu  openai-compatible  eu.openrouter.ai  BRAHMA_KEY_OPENROUTER_EU  added\n"), "\(list)")
        #expect(!list.contains("TAINTED"))
        // No key secret at all is allowed (the gateway refuses the provider until one is named).
        let keyless = try brahma(["providers", "add", "keyless", "--adapter", "openai-compatible", "--base-url", "https://k.example.com/v1"], home: home)
        #expect(keyless.status == 0, "\(keyless.stderr)")
        #expect(try brahma(["providers"], home: home).stdout.contains("keyless  openai-compatible  k.example.com  none  added\n"))
    }

    @Test func refusedInsideAgentTurn() throws {
        let owner = try OwnerTestHome(); let home = owner.url
        // The refusal comes before any argument check: a bad id or URL still says "agent turn".
        for args in [["providers"], ["providers", "list"], ["providers", "list", "--company", "Nope"], Self.add,
                     ["providers", "add", "Bad", "--adapter", "x", "--base-url", "http://1.2.3.4"], ["providers", "remove", "groq"],
                     ["providers", "remove", "acme-llm"]] {
            let r = try brahma(args, home: home, extra: ["BRAHMA_AGENT_ID": "a1"])
            #expect(r.status == 1, "\(args)")
            #expect(r.stdout.isEmpty, "\(args): \(r.stdout)")
            #expect(r.stderr.contains("owner commands can't run inside an agent turn"), "\(args): \(r.stderr)")
        }
        #expect(!(try brahma(["providers"], home: home).stdout.contains("acme-llm")), "nothing was written")
        #expect(try brahma(["providers"], home: home).stdout.contains("groq  "), "nothing was removed")
        // Adding and removing need the owner key; listing does not.
        let nokey = try OwnerTestHome(initOwner: false)
        for args in [Self.add, ["providers", "remove", "groq"]] {
            let r = try brahma(args, home: nokey.url)
            #expect(r.status == 1 && r.stderr.contains("owner key missing or invalid"), "\(args): \(r.stderr)")
        }
        #expect(try brahma(["providers"], home: nokey.url).status == 0)
    }
}
