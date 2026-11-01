import ArgumentParser
import Foundation
import BrahmaCore

/// A company's hosting: `brahma hosting <company>` shows it; `brahma hosting set` (owner only) chooses the provider, project,
/// account and production URL. The build, output folder and smoke checks are an ops agent's (`set_deploy_config`); the
/// provider token is a secret (`brahma secret set <company> CLOUDFLARE_API_TOKEN` or `VERCEL_TOKEN`).
struct HostingCommand: ParsableCommand {
    /// Agent text on one line, at most `max` characters (then `safe()` before printing).
    static func oneLine(_ s: String, max: Int) -> String {
        let flat = s.split(whereSeparator: \.isNewline).joined(separator: " ")
        return flat.count > max ? String(flat.prefix(max)) + "…" : flat
    }

    static let configuration = CommandConfiguration(
        commandName: "hosting", abstract: "Show or set a company's hosting (Cloudflare Pages or Vercel).",
        subcommands: [Show.self, Set.self], defaultSubcommand: Show.self)

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "show", abstract: "Show a company's hosting.")
        @Argument(help: "Company name or slug.") var company: String

        func run() throws {
            let (store, _) = try openStore()
            let selected = try resolveCompany(store, company)
            let s = try store.hosting(companyId: selected.id)
            let provider = s?.provider ?? .default
            let adapter = HostingAdapters.adapter(provider)
            let tokenName = adapter.tokenSecret
            // The listing only: no vault read (a read-only command never touches the vault).
            let token = try store.secrets(companyId: selected.id).contains { $0.name == tokenName }
            if s == nil { print("not configured yet (defaults below)") }
            print("provider: \(provider.title) (\(provider.rawValue)), \(adapter.cli), unverified: needs the owner's provider token")
            print("project: \(safe(s?.project ?? selected.slug))")
            print("account: \(safe(s?.accountId ?? "none"))")
            print("production URL: \(safe(s?.productionURL ?? "none"))")
            print("domain: \(safe(s?.customDomain ?? "none"))")
            print("build: \(safe(s?.build.map { HostingCommand.oneLine($0, max: 300) } ?? "none"))")
            print("output: \(safe(s?.outputDir ?? "none"))")
            let smoke = (s?.smoke ?? []).map { r in
                ([r.method, r.path] + (r.body.map { [$0] } ?? []) + (r.expectStatus.map { ["\($0)"] } ?? [])).joined(separator: " ")
            }
            print("smoke: \(safe(smoke.isEmpty ? "none" : smoke.map { HostingCommand.oneLine($0, max: 200) }.joined(separator: "; ")))")
            if let expect = s?.expectText { print("expect text: \(safe(HostingCommand.oneLine(expect, max: 200)))") }
            print("token: \(token ? "present" : "missing") (\(tokenName))")
            if provider == .vercel { print("note: \(VercelAdapter.hobbyNote)") }
        }
    }

    struct Set: ParsableCommand {
        static let configuration = CommandConfiguration(commandName: "set", abstract: "Set a company's hosting (owner only).")
        @Argument(help: "Company name or slug.") var company: String
        @Option(help: "cloudflare-pages or vercel.") var provider: String?
        @Option(help: "Provider project name: 2–58 lowercase letters, digits and dashes.") var project: String?
        @Option(name: .customLong("account-id"), help: "Cloudflare account ID, or Vercel team/account ID (empty clears).")
        var accountId: String?
        @Option(name: .customLong("production-url"), help: "The site's https:// URL (empty clears).") var productionURL: String?

        func run() throws {
            try requireOwnerShell()
            let chosen: HostingProviderID?
            if let provider {
                guard let p = HostingProviderID(rawValue: provider.lowercased()) else {
                    throw fail("provider must be one of: \(HostingProviderID.allCases.map(\.rawValue).joined(separator: ", "))")
                }
                chosen = p
            } else {
                chosen = nil
            }
            let (store, _) = try openStore()
            let selected = try resolveCompany(store, company)
            let s: HostingSettings
            do {
                s = try store.setHosting(companyId: selected.id, by: .owner, provider: chosen, project: project, accountId: accountId,
                                         productionURL: productionURL)
            } catch let e as WorkError {
                throw fail(e.message)
            }
            print("hosting for \(safe(selected.name)): \(s.provider.title) project \(safe(s.project))")
            if s.provider == .vercel { print("note: \(VercelAdapter.hobbyNote)") }
        }
    }
}
