import ArgumentParser
import Foundation
import BrahmaCore

/// A company's releases (Plan L Task 8). `list` and `show` are read-only; `rollback` and `smoke` are owner-write commands.
/// Only the engine (`ReleaseExecutor`) ever runs a deploy, a rollback or a smoke run: these commands record the owner's
/// request. Every agent-controlled field (notes, failure reasons, output tails, smoke bodies and errors) prints through `safe()`.
struct ReleaseGroup: ParsableCommand {
    static let configuration = CommandConfiguration(
        commandName: "release", abstract: "A company's releases: list them, show one, roll one back, or smoke-test main.",
        subcommands: [List.self, Show.self, Rollback.self, Smoke.self], defaultSubcommand: List.self)

    /// `R-<n>  <version>  <status>  <sha7>  <url|->  smoke <passed|failed|—>  by @<proposer>[  rollback <status>]`.
    static func line(_ r: Release, names: [String: String]) -> String {
        let url = r.productionURL ?? r.deployURL ?? "-"
        var parts = [r.ref, r.version, r.status.rawValue, r.sha7, url, "smoke \(r.smokeStatus ?? "—")",
                     "by @\(names[r.proposedById] ?? "unknown")"]
        if let rollback = r.rollbackStatus { parts.append("rollback \(rollback.rawValue)") }
        return safe(parts.joined(separator: "  "))
    }

    /// The release's agent names by id (the proposer's handle).
    static func names(_ store: Store, _ company: Company) throws -> [String: String] {
        Dictionary(try store.agents(companyId: company.id).map { ($0.id, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    static func release(_ store: Store, _ company: Company, _ ref: String) throws -> Release {
        guard let r = try store.release(companyId: company.id, ref: ref) else { throw fail("no release \(ref)") }
        return r
    }

    /// Agent text as indented lines (each through `safe()`).
    static func block(_ text: String) -> String {
        text.split(separator: "\n", omittingEmptySubsequences: false).map { "    " + safe(String($0)) }.joined(separator: "\n")
    }

    struct List: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "List a company's releases, newest first, then the smoke check's result on main.")
        @Argument(help: "Company name or slug.") var company: String

        func run() throws {
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let names = try ReleaseGroup.names(store, c)
            let releases = try store.releases(companyId: c.id)
            if releases.isEmpty { print("(no releases)") }
            for r in releases { print(ReleaseGroup.line(r, names: names)) }
            let smoke: String
            if c.smokeCheck == nil {
                smoke = "no smoke check"
            } else if let main = c.mainCommit, let result = try store.latestResult(companyId: c.id, commit: main) {
                smoke = result.status.rawValue
            } else {
                smoke = "not run"
            }
            print("main \(c.mainCommit.map { String($0.prefix(7)) } ?? "-"): smoke \(smoke)")
        }
    }

    struct Show: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Show one release: its exact deploy and rollback commands, smoke results and output.")
        @Argument(help: "Company name or slug.") var company: String
        @Argument(help: "The release, e.g. R-2.") var ref: String

        func run() throws {
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let r = try ReleaseGroup.release(store, c, ref)
            print(ReleaseGroup.line(r, names: try ReleaseGroup.names(store, c)))
            print("commit: \(r.commit)")
            print("provider: \(r.provider.title), project \(safe(r.project))")
            if let notes = r.notes { print("notes:\n\(ReleaseGroup.block(notes))") }
            if let reason = r.failedReason { print("failed: \(safe(reason))") }
            if let url = r.deployURL { print("deploy URL: \(safe(url))") }
            print("build: \(safe(r.build.map { HostingCommand.oneLine($0, max: 300) } ?? "none")) → \(safe(r.outputDir ?? "-"))")
            print("deploy (engine, token $\(r.plan.tokenSecret), in order):\n\(ReleaseGroup.block(r.plan.display))")
            print("rollback (recorded):\n\(ReleaseGroup.block(r.rollbackPlan.display))")
            var rollback = "rollback: \(r.rollbackStatus?.rawValue ?? "none")"
            if let at = r.rollbackRequestedAt { rollback += ", requested \(clock(at))" }
            if let at = r.rollbackStartedAt { rollback += ", started \(clock(at))" }
            if let at = r.rolledBackAt { rollback += ", rolled back \(clock(at))" }
            print(rollback)
            if !r.smokeResults.isEmpty {
                print("smoke results:")
                for s in r.smokeResults {
                    let outcome = s.ok ? "ok" : (s.error ?? "failed")
                    print("    " + safe("\(s.method) \(s.url) \(s.status.map(String.init) ?? "-") \(outcome)"))
                }
            }
            if let tail = r.outputTail, !tail.isEmpty { print("output (end):\n\(ReleaseGroup.block(tail))") }
            if let tail = r.rollbackOutputTail, !tail.isEmpty { print("rollback output (end):\n\(ReleaseGroup.block(tail))") }
        }
    }

    struct Rollback: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Roll a deployed or failed release back: the engine runs its recorded rollback commands (owner only).")
        @Argument(help: "Company name or slug.") var company: String
        @Argument(help: "The release, e.g. R-2.") var ref: String

        func run() throws {
            try requireOwnerShell()
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let r: Release
            do { r = try store.requestRollback(companyId: c.id, releaseRef: ref, by: .owner) } catch let e as WorkError { throw fail(e.message) }
            print("Rolling back \(r.ref); the engine runs:")
            for line in r.rollbackPlan.display.split(separator: "\n") { print(safe(String(line))) }
        }
    }

    struct Smoke: ParsableCommand {
        static let configuration = CommandConfiguration(
            abstract: "Ask the engine to run the smoke check on main now (owner only).")
        @Argument(help: "Company name or slug.") var company: String

        func run() throws {
            try requireOwnerShell()
            let (store, _) = try openStore()
            let c = try resolveCompany(store, company)
            let run: MainSmokeRun
            do { run = try store.requestManualSmoke(companyId: c.id, by: .owner) } catch let e as WorkError { throw fail(e.message) }
            print("Smoke run of main \(run.sha7) queued; the engine runs it.")
        }
    }
}
