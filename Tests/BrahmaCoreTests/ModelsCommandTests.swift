import Testing
import Foundation
@testable import BrahmaCore

/// Plan X1 Task 12: `brahma company models <co> [--role <role>] [<class>=<p/m>…]`, `brahma company models <co> clear [--role
/// <role>]` and `brahma agent model <co> <handle> <class>=<p/m>|<class>=inherit`. Showing refuses inside an agent turn;
/// changing needs the owner shell. A route names an existing provider and a priced model; setting one queues a probe.
@Suite(.scratch) struct ModelsCommandTests {
    private func brahma(_ args: [String], home: URL, extra: [String: String] = [:]) throws -> BrahmaResult {
        let p = Process()
        p.executableURL = brahmaExecutableURL()
        p.arguments = args
        p.environment = cliEnvironment(home: home).merging(extra) { $1 }
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err; p.standardInput = FileHandle.nullDevice
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile(), e = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return BrahmaResult(status: p.terminationStatus, stdout: String(decoding: o, as: UTF8.self), stderr: String(decoding: e, as: UTF8.self))
    }

    /// A company with one engineer, `eng-1`.
    private func world() throws -> (OwnerTestHome, URL) {
        let owner = try OwnerTestHome(); let home = owner.url
        #expect(try brahma(["company", "create", "Acme", "--goal", "g", "--agents", "0"], home: home).status == 0)
        let hired = try brahma(["hire", "Acme", "eng-1", "--role", "engineer", "--model", "sonnet"], home: home)
        #expect(hired.status == 0, "\(hired.stderr)")
        return (owner, home)
    }

    private func routes(_ home: URL) throws -> [ModelRoute] {
        let store = try Store(path: ownerPaths(home).database.path)
        defer { try? store.close() }
        let company = try #require(try store.companies().first)
        return try store.routes(companyId: company.id)
    }

    private func queuedProbes(_ home: URL) throws -> [String] {
        let store = try Store(path: ownerPaths(home).database.path)
        defer { try? store.close() }
        return try store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT provider || '/' || model FROM modelProbeRequest WHERE status = 'queued' ORDER BY createdAt, rowid")
        }
    }

    @Test func setResolveClear() throws {
        let (_, home) = try world()
        let empty = try brahma(["company", "models", "Acme"], home: home)
        #expect(empty.status == 0, "\(empty.stderr)")
        #expect(empty.stdout == """
            model routes for Acme
            deep     runtime default (no route)
            standard runtime default (no route)
            fast     runtime default (no route)

            """, "\(empty.stdout)")

        let set = try brahma(["company", "models", "Acme", "deep=anthropic/claude-opus-5-5", "fast=anthropic/claude-haiku-5-5"], home: home)
        #expect(set.status == 0, "\(set.stderr)")
        #expect(set.stdout == """
            deep → anthropic/claude-opus-5-5 for Acme; probe queued
            fast → anthropic/claude-haiku-5-5 for Acme; probe queued

            """, "\(set.stdout)")
        let role = try brahma(["company", "models", "Acme", "--role", "engineer", "deep=anthropic/claude-sonnet-5-5"], home: home)
        #expect(role.status == 0, "\(role.stderr)")
        #expect(role.stdout == "deep → anthropic/claude-sonnet-5-5 for role engineer in Acme; probe queued\n", "\(role.stdout)")
        #expect(try queuedProbes(home) == ["anthropic/claude-opus-5-5", "anthropic/claude-haiku-5-5", "anthropic/claude-sonnet-5-5"])

        let company = try brahma(["company", "models", "Acme"], home: home)
        #expect(company.stdout == """
            model routes for Acme
            deep     anthropic/claude-opus-5-5  (company)
            standard runtime default (no route)
            fast     anthropic/claude-haiku-5-5  (company)
            overrides:
              role engineer  deep → anthropic/claude-sonnet-5-5

            """, "\(company.stdout)")
        let forRole = try brahma(["company", "models", "Acme", "--role", "engineer"], home: home)
        #expect(forRole.stdout == """
            model routes for role engineer in Acme
            deep     anthropic/claude-sonnet-5-5  (role engineer)
            standard runtime default (no route)
            fast     anthropic/claude-haiku-5-5  (company)

            """, "\(forRole.stdout)")

        // Replacing a route keeps one row per class; a new role gets a note when nobody holds it.
        #expect(try brahma(["company", "models", "Acme", "fast=anthropic/claude-sonnet-5-5"], home: home).status == 0)
        let nobody = try brahma(["company", "models", "Acme", "--role", "designer", "standard=anthropic/claude-sonnet-5-5"], home: home)
        #expect(nobody.stdout.hasSuffix("note: no agent in Acme has role designer now\n"), "\(nobody.stdout)")
        #expect(try routes(home).map { "\($0.scope.rawValue):\($0.subject):\($0.modelClass)=\($0.provider)/\($0.model)" } == [
            "company::deep=anthropic/claude-opus-5-5", "company::fast=anthropic/claude-sonnet-5-5",
            "role:designer:standard=anthropic/claude-sonnet-5-5", "role:engineer:deep=anthropic/claude-sonnet-5-5"])

        // `clear` removes one scope's routes only.
        let clearRole = try brahma(["company", "models", "Acme", "clear", "--role", "engineer"], home: home)
        #expect(clearRole.status == 0 && clearRole.stdout == "cleared the routes of role engineer in Acme\n", "\(clearRole.stdout)\(clearRole.stderr)")
        #expect(try routes(home).map(\.scope) == [.company, .company, .role])
        let clearCompany = try brahma(["company", "models", "Acme", "clear"], home: home)
        #expect(clearCompany.status == 0 && clearCompany.stdout == "cleared the company routes of Acme\n")
        #expect(try routes(home).map(\.subject) == ["designer"])

        // Malformed assignments are refused before anything is written.
        for (args, why) in [(["deep"], "'deep' is not <class>=<provider>/<model>"), (["huge=anthropic/x"], "the class is deep, standard or fast"),
                            (["deep=claude-opus-5-5"], "name a model as <provider>/<model>"),
                            (["deep=anthropic/claude-opus-5-5", "deep=anthropic/claude-sonnet-5-5"], "deep is assigned twice"),
                            (["clear", "deep=anthropic/claude-opus-5-5"], "`clear` takes no assignment")] {
            let r = try brahma(["company", "models", "Acme"] + args, home: home)
            #expect(r.status == 1 && r.stderr.contains(why), "\(args): \(r.stderr)")
        }
        #expect(try brahma(["company", "models", "Acme", "--role", "Bad Role"], home: home).stderr.contains("a role is 1-64 of"))
        #expect(try routes(home).count == 1)
    }

    @Test func unknownProviderRefused() throws {
        let (_, home) = try world()
        for args in [["company", "models", "Acme", "deep=nope/model-1"], ["agent", "model", "Acme", "eng-1", "deep=nope/model-1"]] {
            let r = try brahma(args, home: home)
            #expect(r.status == 1, "\(args)")
            // (After the owner key's file-store warning the test home prints.)
            #expect(r.stderr.hasSuffix("brahma: no such provider: nope (see `brahma providers`)\n"), "\(args): \(r.stderr)")
        }
        #expect(try routes(home).isEmpty)
        #expect(try queuedProbes(home).isEmpty)
    }

    /// An unpriced model is refused with the command that prices it; once priced, it routes. A search-capable one is refused
    /// even when priced (Ruling 59).
    @Test func unpricedModelRefusedWithHint() throws {
        let (_, home) = try world()
        let refused = try brahma(["company", "models", "Acme", "standard=openrouter/vendor/model-1"], home: home)
        #expect(refused.status == 1)
        #expect(refused.stderr.hasSuffix("brahma: openrouter/vendor/model-1 has no price, so the gateway would refuse it: run "
                + "`brahma settings model-price openrouter/vendor/model-1 <usd-in> <usd-out>` first\n"), "\(refused.stderr)")
        #expect(try routes(home).isEmpty)
        #expect(try brahma(["settings", "model-price", "openrouter/vendor/model-1", "0.5", "1.5"], home: home).status == 0)
        let routed = try brahma(["company", "models", "Acme", "standard=openrouter/vendor/model-1"], home: home)
        #expect(routed.status == 0, "\(routed.stderr)")
        #expect(try routes(home).map(\.model) == ["vendor/model-1"])
        #expect(try queuedProbes(home) == ["openrouter/vendor/model-1"])

        for model in ["vendor/model-1:online", "vendor/gpt-x-search-preview"] {
            #expect(try brahma(["settings", "model-price", "openrouter/\(model)", "0.5", "1.5"], home: home).status == 0)
            let search = try brahma(["agent", "model", "Acme", "eng-1", "fast=openrouter/\(model)"], home: home)
            #expect(search.status == 1 && search.stderr.contains("search-capable models are not routed"), "\(search.stderr)")
        }
        #expect(try routes(home).count == 1)
    }

    @Test func agentInheritClears() throws {
        let (_, home) = try world()
        #expect(try brahma(["company", "models", "Acme", "deep=anthropic/claude-opus-5-5"], home: home).status == 0)
        let own = try brahma(["agent", "model", "Acme", "@eng-1", "deep=anthropic/claude-sonnet-5-5"], home: home)
        #expect(own.status == 0, "\(own.stderr)")
        #expect(own.stdout == "deep → anthropic/claude-sonnet-5-5 for @eng-1 in Acme; probe queued\n", "\(own.stdout)")
        #expect(try brahma(["agent", "model", "Acme", "eng-1", "fast=anthropic/claude-haiku-5-5"], home: home).status == 0)
        let shown = try brahma(["company", "models", "Acme"], home: home).stdout
        #expect(shown.contains("overrides:\n  @eng-1  deep → anthropic/claude-sonnet-5-5\n  @eng-1  fast → anthropic/claude-haiku-5-5\n"), "\(shown)")
        #expect(try routes(home).filter { $0.scope == .agent }.map(\.modelClass) == ["deep", "fast"])

        // `inherit` removes that class only; the agent then resolves to the company's route.
        let inherit = try brahma(["agent", "model", "Acme", "eng-1", "deep=inherit"], home: home)
        #expect(inherit.status == 0, "\(inherit.stderr)")
        #expect(inherit.stdout == "deep for @eng-1 inherits: anthropic/claude-opus-5-5  (company)\n", "\(inherit.stdout)")
        #expect(try routes(home).filter { $0.scope == .agent }.map(\.modelClass) == ["fast"])
        let none = try brahma(["agent", "model", "Acme", "eng-1", "standard=inherit"], home: home)
        #expect(none.stdout == "standard for @eng-1 inherits: runtime default (no route)\n", "\(none.stdout)")
        #expect(try brahma(["agent", "model", "Acme", "nobody", "deep=inherit"], home: home).stderr.contains("no agent @nobody in Acme"))
    }

    /// Every form refuses inside an agent turn, before any argument is checked, and changes nothing.
    @Test func refusedInsideAgentTurn() throws {
        let (_, home) = try world()
        for args in [["company", "models", "Acme"], ["company", "models", "Acme", "deep=anthropic/claude-opus-5-5"],
                     ["company", "models", "Acme", "clear"], ["company", "models", "Nope", "huge=x"],
                     ["agent", "model", "Acme", "eng-1", "deep=anthropic/claude-opus-5-5"], ["agent", "model", "Acme", "eng-1", "deep=inherit"]] {
            let r = try brahma(args, home: home, extra: ["BRAHMA_AGENT_ID": "a1"])
            #expect(r.status == 1, "\(args)")
            #expect(r.stdout.isEmpty, "\(args): \(r.stdout)")
            #expect(r.stderr.contains("owner commands can't run inside an agent turn"), "\(args): \(r.stderr)")
        }
        #expect(try routes(home).isEmpty)
    }
}
