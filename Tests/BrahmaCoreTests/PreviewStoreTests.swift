import Foundation
import Testing
import GRDB
@testable import BrahmaCore

/// Runs the built `brahma` binary against a throwaway data home.
private func brahma(_ args: [String], home: URL, env: [String: String] = [:]) throws -> (status: Int32, stdout: String, stderr: String) {
    let url = brahmaExecutableURL()
    try #require(FileManager.default.isExecutableFile(atPath: url.path), "build the brahma product first")
    let p = Process()
    p.executableURL = url
    p.arguments = args
    var e = cliEnvironment(home: home)
    e.merge(env) { _, new in new }
    p.environment = e
    let out = Pipe(), err = Pipe()
    p.standardOutput = out; p.standardError = err
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let o = out.fileHandleForReading.readDataToEndOfFile(), r = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: r, as: UTF8.self))
}

/// Task 2: preview surfaces in the Store, `set_preview_command`, per-preview ports, `brahma preview` and the ops tool names.
@Suite(.scratch) struct PreviewStoreTests {
    struct T {
        let store: Store
        let acme: Company, globex: Company
        let devops: Agent, cto: Agent, eng: Agent, globexDevops: Agent

        init() throws {
            store = try Store.inMemory()
            acme = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
            globex = try store.createCompany(name: "Globex", goal: "g", workspacesRoot: try tempDir())
            devops = try store.hire(companyId: acme.id, name: "devops-1", role: "devops", model: "m")
            cto = try store.hire(companyId: acme.id, name: "cto", role: "cto-architect", model: "m")
            eng = try store.hire(companyId: acme.id, name: "eng-1", role: "engineer", model: "m")
            globexDevops = try store.hire(companyId: globex.id, name: "devops-1", role: "devops", model: "m")
        }

        func tools(_ a: Agent) -> CompanyTools { CompanyTools(store: store, companyId: a.companyId, agentId: a.id) }

        /// (ok, text) of one tool call.
        func call(_ a: Agent, _ name: String, _ args: [String: JSONValue]) -> (ok: Bool, text: String) {
            do { return (true, try tools(a).call(name: name, arguments: args)) } catch let e as ToolError { return (false, e.message) } catch { return (false, "\(error)") }
        }

        func set(_ a: Agent, _ name: String, url: String = "http://127.0.0.1:{port}/", extra: [String: JSONValue] = [:]) -> (ok: Bool, text: String) {
            var args: [String: JSONValue] = ["name": .string(name), "kind": .string("web"), "run": .string("npm start"), "url": .string(url)]
            args.merge(extra) { _, new in new }
            return call(a, "set_preview_command", args)
        }

        func surface(_ company: Company, _ name: String) throws -> PreviewSurface {
            try #require(try store.previewSurfaces(companyId: company.id).first { $0.name == name })
        }
    }

    static func message(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch let e as WorkError { return e.message } catch { return "\(error)" }
    }

    // MARK: Tool and store

    @Test func toolSetsSurfaceAndCapApplies() throws {
        let t = try T()
        let set = t.set(t.devops, "web", extra: ["build": .string("npm ci && npm run build"), "smoke": .array([.string("GET /health 200"), .string("get / ")])])
        #expect(set.ok, "\(set.text)"); #expect(set.text == "Preview web (web) set; the engine builds it from main.")
        let web = try t.surface(t.acme, "web")
        #expect(web.setById == t.devops.id); #expect(web.kind == "web"); #expect(web.build == "npm ci && npm run build")
        #expect(web.run == "npm start"); #expect(web.url == "http://127.0.0.1:{port}/"); #expect(web.position == 0)
        #expect(web.smoke == [SmokeRequest(method: "GET", path: "/health", expectStatus: 200), SmokeRequest(method: "GET", path: "/")])
        #expect(web.id == web.id.lowercased())
        // A fresh state row, idle, with no port yet.
        let states = try t.store.previewStates(companyId: t.acme.id)
        #expect(states[web.id]?.status == .idle); #expect(states[web.id]?.port == nil)
        // A second set of the same name by its setter updates in place (same id, same position).
        let again = t.set(t.devops, "web", extra: ["run": .string("npm run dev")])
        #expect(again.ok, "\(again.text)")
        let updated = try t.surface(t.acme, "web")
        #expect(updated.id == web.id); #expect(updated.run == "npm run dev"); #expect(updated.setById == t.devops.id); #expect(updated.position == 0)
        #expect(try t.store.previewSurfaces(companyId: t.acme.id).count == 1)
        // A change asks the engine for a restart.
        #expect(try t.store.previewStates(companyId: t.acme.id)[web.id]?.restartRequestedAt != nil)
        // Validation messages come straight from the model.
        #expect(t.set(t.devops, "Web").text == "preview names are lowercase letters, digits and dashes (max 24)")
        #expect(t.set(t.devops, "api", url: "https://example.com").text == "preview URLs must be http://127.0.0.1, localhost or [::1] with a port")
        #expect(t.set(t.devops, "api", extra: ["kind": .string("cli")]).text == "only web previews are available yet")
        #expect(t.set(t.devops, "api", extra: ["smoke": .array([.string("FETCH /x")])]).text
                == "smoke requests look like \"GET /health 200\" or \"POST /items {json} 201\"")
        // The cap: 8 per company (the first is `web`); the CTO (an executive) may set them too.
        for i in 2...7 { #expect(t.set(t.cto, "p\(i)").ok) }
        #expect(t.set(t.devops, "p8").ok)
        let ninth = t.set(t.devops, "p9")
        #expect(!ninth.ok); #expect(ninth.text == "a company can have at most 8 previews")
        #expect(try t.store.previewSurfaces(companyId: t.acme.id).map(\.position) == Array(0..<8))
        // Updating an existing one is not a new preview.
        #expect(t.set(t.devops, "p8").ok)
        // Other roles have no ops tools.
        let eng = t.set(t.eng, "eng")
        #expect(!eng.ok); #expect(eng.text == "set_preview_command is not available to your role")
        for tool in ["set_smoke_check", "set_deploy_config", "propose_deploy"] {
            #expect(t.call(t.eng, tool, [:]).text == "\(tool) is not available to your role")
        }
        #expect(t.call(t.devops, "propose_deploy", [:]).text == "missing required argument: version")
        #expect(t.call(t.devops, "set_deploy_config", [:]).text == "missing required argument: output_dir")
        #expect(t.call(t.devops, "set_smoke_check", [:]).text == "missing required argument: command")
        #expect(t.call(t.eng, "request_human_task", [:]).text == "missing required argument: reason", "every role has it (Task 9)")
        // Removal, and the tool's company is the acting agent's (Globex never sees Acme's surfaces).
        #expect(try t.store.previewSurfaces(companyId: t.globex.id).isEmpty)
        let gone = t.set(t.devops, "p8", extra: ["remove": .bool(true)])
        #expect(gone.ok, "\(gone.text)"); #expect(gone.text == "Preview p8 removed.")
        #expect(try t.store.previewSurfaces(companyId: t.acme.id).count == 7)
        #expect(try t.store.previewStates(companyId: t.acme.id)["p8"] == nil)
        let missing = t.set(t.devops, "p8", extra: ["remove": .bool(true)])
        #expect(!missing.ok); #expect(missing.text == "no preview named p8")
        // Positions stay stable (no renumbering); a new surface takes the slot after the highest.
        #expect(t.set(t.devops, "p9").ok)
        #expect(try t.surface(t.acme, "p9").position == 7)
        #expect(try t.store.previewSurfaces(companyId: t.acme.id).map(\.name) == ["web", "p2", "p3", "p4", "p5", "p6", "p7", "p9"])
        // The activity feed records both.
        let events = try t.store.events(afterId: 0).filter { $0.kind == .preview }.map(\.text)
        #expect(events.contains("@devops-1 set preview web (web)")); #expect(events.contains("@devops-1 updated preview web (web)"))
        #expect(events.contains("@cto set preview p2 (web)")); #expect(events.contains("@devops-1 removed preview p8"))
    }

    @Test func storeChecksTheSenderAndTheCompany() throws {
        let t = try T()
        let draft = PreviewDraft(name: "web", kind: "web", run: "npm start", url: "http://127.0.0.1:{port}/")
        // The owner may set and remove.
        let web = try t.store.upsertPreviewSurface(companyId: t.acme.id, by: .owner, draft)
        #expect(web.setById == "owner")
        // An agent of another company is "not in your company" (cross-company ids), whatever it asks for.
        let other = Sender.agent(t.globexDevops.id)
        #expect(Self.message { _ = try t.store.upsertPreviewSurface(companyId: t.acme.id, by: other, draft) } == "not in your company")
        #expect(Self.message { _ = try t.store.removePreviewSurface(companyId: t.acme.id, name: "web", by: other) } == "not in your company")
        #expect(Self.message { try t.store.requestPreviewRestart(surfaceId: web.id, by: other) } == "not in your company")
        #expect(Self.message { try t.store.requestPreviewRestart(surfaceId: web.id, by: .system) } == "not in your company")
        // A restart is the owner's or the setter's; another agent of the company is refused.
        let apiDraft = PreviewDraft(name: "api", kind: "web", run: "npm start", url: "http://127.0.0.1:{port}/")
        let api = try t.store.upsertPreviewSurface(companyId: t.acme.id, by: .agent(t.devops.id), apiDraft)
        #expect(api.setById == t.devops.id)
        #expect(Self.message { try t.store.requestPreviewRestart(surfaceId: api.id, by: .agent(t.cto.id)) } == "only the owner or the agent who set a preview may restart it")
        try t.store.requestPreviewRestart(surfaceId: api.id, by: .agent(t.devops.id))
        try t.store.requestPreviewRestart(surfaceId: web.id, by: .owner)
        #expect(try t.store.previewStates(companyId: t.acme.id)[web.id]?.restartRequestedAt != nil)
        _ = try t.store.removePreviewSurface(companyId: t.acme.id, name: "api", by: .agent(t.devops.id))
        #expect(Self.message { try t.store.requestPreviewRestart(surfaceId: "nope", by: .owner) } == "no such preview")
        // savePreviewState round-trips every column; removing the surface cascades to it.
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        var state = try #require(try t.store.previewStates(companyId: t.acme.id)[web.id])
        state.status = .running; state.commit = String(repeating: "a", count: 40); state.port = 47101; state.pid = 4242
        state.resolvedURL = "http://127.0.0.1:47101/"; state.message = nil; state.logPath = ".brahma/preview/logs/web.log"
        state.exits = [now]; state.startedAt = now; state.updatedAt = now
        try t.store.savePreviewState(state)
        let loaded = try #require(try t.store.previewStates(companyId: t.acme.id)[web.id])
        #expect(loaded.status == .running && loaded.port == 47101 && loaded.pid == 4242 && loaded.exits.count == 1)
        #expect(loaded.commit == state.commit && loaded.resolvedURL == state.resolvedURL && loaded.logPath == state.logPath)
        _ = try t.store.removePreviewSurface(companyId: t.acme.id, name: "web", by: .owner)
        #expect(try t.store.previewStates(companyId: t.acme.id).isEmpty)
        #expect(try t.store.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM previewState") } == 0)
    }

    /// C1: an existing surface is changed or removed only by the owner or its setter; an owner-set one is immutable to agents.
    @Test func existingSurfaceChangedOnlyByOwnerOrSetter() throws {
        let t = try T()
        let setter = "only the owner or @devops-1 may change or remove preview web; propose the change with request_from_owner"
        #expect(t.set(t.devops, "web").ok)
        // Another agent's edit and remove are refused (the executive too), and nothing changed.
        let edit = t.set(t.cto, "web", extra: ["run": .string("evil")])
        #expect(!edit.ok); #expect(edit.text == setter)
        let remove = t.set(t.cto, "web", extra: ["remove": .bool(true)])
        #expect(!remove.ok); #expect(remove.text == setter)
        #expect(Self.message { _ = try t.store.removePreviewSurface(companyId: t.acme.id, name: "web", by: .agent(t.eng.id)) } == setter)
        #expect(try t.surface(t.acme, "web").run == "npm start"); #expect(try t.surface(t.acme, "web").setById == t.devops.id)
        // The setter may edit and remove.
        #expect(t.set(t.devops, "web", extra: ["run": .string("npm run dev")]).ok)
        #expect(try t.surface(t.acme, "web").run == "npm run dev")
        #expect(t.set(t.devops, "web", extra: ["remove": .bool(true)]).ok)
        #expect(try t.store.previewSurfaces(companyId: t.acme.id).isEmpty)
        // The owner may edit and remove an agent's surface …
        #expect(t.set(t.devops, "web").ok)
        let draft = PreviewDraft(name: "web", kind: "web", run: "PORT={port} npm start", url: "http://127.0.0.1:{port}/")
        let taken = try t.store.upsertPreviewSurface(companyId: t.acme.id, by: .owner, draft)
        #expect(taken.setById == "owner"); #expect(taken.run == "PORT={port} npm start")
        // … after which it is the owner's: the original setter (and everyone else) is refused, and pointed at an ask.
        let ownerSet = "preview web was set by the owner; propose a change with request_from_owner"
        for agent in [t.devops, t.cto] {
            let e = t.set(agent, "web", extra: ["run": .string("x")]); #expect(!e.ok); #expect(e.text == ownerSet)
            let r = t.set(agent, "web", extra: ["remove": .bool(true)]); #expect(!r.ok); #expect(r.text == ownerSet)
        }
        #expect(try t.surface(t.acme, "web").run == "PORT={port} npm start")
        _ = try t.store.removePreviewSurface(companyId: t.acme.id, name: "web", by: .owner)
        #expect(try t.store.previewSurfaces(companyId: t.acme.id).isEmpty)
        // Every change names its actor in the activity feed.
        let events = try t.store.events(afterId: 0).filter { $0.kind == .preview }.map(\.text)
        #expect(events.contains("@devops-1 updated preview web (web)")); #expect(events.contains("@devops-1 removed preview web"))
        #expect(events.contains("owner updated preview web (web)")); #expect(events.contains("owner removed preview web"))
        #expect(!events.contains { $0.hasPrefix("@cto") })
    }

    // MARK: Ports

    @Test func crossCompanyPortHeld() throws {
        let t = try T()
        // Acme's web preview holds 3000 (running).
        let acmeWeb = try t.store.upsertPreviewSurface(companyId: t.acme.id, by: .owner,
                                                       PreviewDraft(name: "web", kind: "web", run: "npm start", url: "http://127.0.0.1:3000/"))
        var state = try #require(try t.store.previewStates(companyId: t.acme.id)[acmeWeb.id])
        state.status = .running; state.port = 3000; try t.store.savePreviewState(state)
        // Globex asks for the literal 3000: refused, naming the holder.
        let globexWeb = try t.store.upsertPreviewSurface(companyId: t.globex.id, by: .owner,
                                                         PreviewDraft(name: "web", kind: "web", run: "npm start", url: "http://localhost:3000/"))
        #expect(Self.message { _ = try PortAllocator.port(for: globexWeb, store: t.store) }
                == "port 3000 is used by preview acme/web; use {port} in run and url")
        // The holder itself keeps it.
        #expect(try PortAllocator.port(for: acmeWeb, store: t.store) == 3000)
        // Once Acme's is stopped the port is Globex's to use.
        state.status = .stopped; try t.store.savePreviewState(state)
        #expect(try PortAllocator.port(for: globexWeb, store: t.store) == 3000)
        // A literal port nobody records is simply returned (whether or not something else on the machine has it: the
        // server's own bind says so).
        let api = try t.store.upsertPreviewSurface(companyId: t.globex.id, by: .owner,
                                                   PreviewDraft(name: "api", kind: "web", run: "npm start", url: "http://[::1]:3001/x"))
        #expect(try PortAllocator.port(for: api, store: t.store) == 3001)
    }

    @Test func portKeptAcrossRestart() throws {
        let t = try T()
        let web = try t.store.upsertPreviewSurface(companyId: t.acme.id, by: .owner,
                                                   PreviewDraft(name: "web", kind: "web", run: "npm start", url: "http://127.0.0.1:{port}/"))
        // First start: allocated from the range, excluding every recorded port.
        let first = try PortAllocator.port(for: web, store: t.store)
        #expect(PortAllocator.range.contains(first))
        var state = try #require(try t.store.previewStates(companyId: t.acme.id)[web.id])
        state.status = .running; state.port = first; try t.store.savePreviewState(state)
        // Restarted (still running, or stopped and the port free again): the same port.
        #expect(try PortAllocator.port(for: web, store: t.store) == first)
        state.status = .stopped; try t.store.savePreviewState(state)
        #expect(try PortAllocator.port(for: web, store: t.store) == first)
        // Another surface's allocation skips it even while it is stopped (a recorded port is excluded).
        let api = try t.store.upsertPreviewSurface(companyId: t.globex.id, by: .owner,
                                                   PreviewDraft(name: "api", kind: "web", run: "npm start", url: "http://127.0.0.1:{port}/"))
        let second = try PortAllocator.port(for: api, store: t.store)
        #expect(second != first && PortAllocator.range.contains(second))
        // When another surface has since recorded web's port (and is not stopped), web gets a new one.
        var apiState = try #require(try t.store.previewStates(companyId: t.globex.id)[api.id])
        apiState.status = .running; apiState.port = first; try t.store.savePreviewState(apiState)
        let moved = try PortAllocator.port(for: web, store: t.store)
        #expect(moved != first && PortAllocator.range.contains(moved))
    }

    // MARK: Ops tool names and the built gate (PR-35 part 2t)

    @Test func opsToolsAreNamedAndHighRisk() {
        #expect(CompanyToolNames.ops == ["set_preview_command", "set_smoke_check", "set_deploy_config", "propose_deploy"])
        #expect(CompanyToolNames.work.last == "request_human_task")
        #expect(Set(CompanyToolNames.all).isSuperset(of: CompanyToolNames.ops + ["request_human_task"]))
        for tool in CompanyToolNames.ops {
            #expect(CompanyTools.highRiskTools.contains(tool), "\(tool)")
            #expect(CompanyTools.planTurnExcluded.contains(tool), "\(tool)")
        }
        #expect(!CompanyTools.highRiskTools.contains("request_human_task"))
        // The software pack: ops on devops, architect and every executive; nowhere else.
        let pack = PackCatalog.builtin.pack("software")!
        for role in pack.roles {
            let hasOps = Set(role.companyTools).isSuperset(of: CompanyToolNames.ops)
            let expected = role.kind == .executive || role.id == "devops" || role.id == "architect"
            #expect(hasOps == expected, "\(role.id)")
            #expect(role.companyTools.contains("request_human_task"), "\(role.id)")
        }
    }

    // MARK: The taint rule (L-5lite 2t)

    @Test func liveToolsTaintClassified() {
        for tool in CompanyToolNames.ops {
            #expect(TaintPolicy.reviewedHighRisk.contains(tool), "\(tool)")
            #expect(TaintPolicy.isHighRisk(tool), "\(tool)")
        }
        #expect(TaintPolicy.taintSafeTools.contains("request_human_task"), "its handler enforces the tainted-session rule")
        #expect(!TaintPolicy.reviewedHighRisk.contains("request_human_task"))
        // TaintTests.everyToolClassified, restated: every company tool is in exactly one set, and the quota's set is high risk.
        #expect(Set(CompanyToolNames.all).subtracting(TaintPolicy.taintSafeTools) == TaintPolicy.reviewedHighRisk)
        #expect(CompanyTools.highRiskTools.isSubset(of: TaintPolicy.reviewedHighRisk))
    }

    @Test func taintedSessionCannotSetPreview() throws {
        let t = try T()
        try t.store.markTainted(agentId: t.devops.id, source: "WebFetch")
        let refused = t.set(t.devops, "web")
        #expect(!refused.ok)
        #expect(refused.text == TaintPolicy.refusal(tool: "set_preview_command", source: "outside content"))
        #expect(try t.store.previewSurfaces(companyId: t.acme.id).isEmpty)
        #expect(try #require(try t.store.agent(id: t.devops.id)).freshSessionRequested)
        for tool in ["set_smoke_check", "set_deploy_config", "propose_deploy"] {
            #expect(t.call(t.devops, tool, [:]).text == TaintPolicy.refusal(tool: tool, source: "outside content"), "\(tool)")
        }
        // An untainted ops agent still sets it.
        #expect(t.set(t.cto, "web").ok)
    }

    @Test func planTurnHasNoOpsTools() throws {
        let t = try T()
        let plan = CompanyTools(store: t.store, companyId: t.acme.id, agentId: t.devops.id, planTurn: true)
        #expect(Set(plan.specs().map(\.name)).isDisjoint(with: CompanyToolNames.ops))
        do { _ = try plan.call(name: "set_preview_command", arguments: [:]); Issue.record("should be refused") } catch let e as ToolError {
            #expect(e.message == "set_preview_command is not available in a plan turn: write the plan; the next turn carries it out")
        }
    }

    // MARK: CLI

    @Test func previewCLI() throws {
        let owner = try OwnerTestHome(); defer { withExtendedLifetime(owner) {} }
        let home = owner.url
        #expect(try brahma(["company", "create", "Acme", "--goal", "g", "--agents", "0"], home: home).status == 0)
        let none = try brahma(["preview", "Acme"], home: home)
        #expect(none.status == 0, "\(none.stderr)"); #expect(none.stdout == "(no previews)\n")
        let set = try brahma(["preview", "set", "Acme", "web", "--run", "npm start", "--url", "http://127.0.0.1:{port}/",
                              "--build", "npm ci", "--smoke", "GET / 200", "--smoke", "GET /health"], home: home)
        #expect(set.status == 0, "\(set.stderr)"); #expect(set.stdout == "Preview web (web) set; the engine builds it from main.\n")
        let list = try brahma(["preview", "Acme"], home: home)
        #expect(list.status == 0, "\(list.stderr)")
        #expect(list.stdout == "web  web  idle  http://127.0.0.1:{port}/\n", "\(list.stdout)")
        #expect(try brahma(["preview", "list", "Acme"], home: home).stdout == list.stdout)
        // Validation failures are the model's messages, on stderr.
        let bad = try brahma(["preview", "set", "Acme", "Web", "--run", "x", "--url", "http://127.0.0.1:{port}/"], home: home)
        #expect(bad.status != 0); #expect(bad.stderr.contains("preview names are lowercase letters, digits and dashes (max 24)"))
        let badSmoke = try brahma(["preview", "set", "Acme", "api", "--run", "x", "--url", "http://127.0.0.1:{port}/", "--smoke", "nope"], home: home)
        #expect(badSmoke.status != 0); #expect(badSmoke.stderr.contains("smoke requests look like"))
        // Restart marks the state; remove drops the surface.
        let restart = try brahma(["preview", "restart", "Acme", "web"], home: home)
        #expect(restart.status == 0, "\(restart.stderr)"); #expect(restart.stdout == "Preview web will restart.\n")
        #expect(try brahma(["preview", "restart", "Acme", "nope"], home: home).status != 0)
        let remove = try brahma(["preview", "remove", "Acme", "web"], home: home)
        #expect(remove.status == 0, "\(remove.stderr)"); #expect(remove.stdout == "Preview web removed.\n")
        #expect(try brahma(["preview", "Acme"], home: home).stdout == "(no previews)\n")
        // Owner-write commands refuse an agent's shell; list does not.
        let agentEnv = ["BRAHMA_AGENT_ID": "a1"]
        for args in [["preview", "set", "Acme", "web", "--run", "x", "--url", "http://127.0.0.1:{port}/"], ["preview", "remove", "Acme", "web"],
                     ["preview", "restart", "Acme", "web"]] {
            let r = try brahma(args, home: home, env: agentEnv)
            #expect(r.status != 0, "\(args.joined(separator: " "))"); #expect(r.stderr.contains("owner commands can't run inside an agent turn"))
        }
        #expect(try brahma(["preview", "Acme"], home: home, env: agentEnv).status == 0)
    }

    // MARK: Migration

    @Test func migrationCreatesTheTables() throws {
        let t = try T()
        let columns = try t.store.writer.read { db in
            (try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('previewSurface')"),
             try String.fetchAll(db, sql: "SELECT name FROM pragma_table_info('previewState')"))
        }
        #expect(Set(columns.0) == ["id", "companyId", "name", "kind", "position", "build", "run", "url", "smoke", "setById", "createdAt", "updatedAt"])
        #expect(Set(columns.1) == ["surfaceId", "companyId", "status", "commit", "port", "resolvedURL", "pid", "message", "logPath", "exits",
                                   "restartRequestedAt", "startedAt", "updatedAt"])
        // UNIQUE(companyId, name): the same name in two companies is fine; in one it is an upsert, never a second row.
        let draft = PreviewDraft(name: "web", kind: "web", run: "npm start", url: "http://127.0.0.1:{port}/")
        _ = try t.store.upsertPreviewSurface(companyId: t.acme.id, by: .owner, draft)
        _ = try t.store.upsertPreviewSurface(companyId: t.globex.id, by: .owner, draft)
        #expect(try t.store.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM previewSurface") } == 2)
        // Deleting the company cascades.
        try t.store.writer.write { try $0.execute(sql: "DELETE FROM company WHERE id = ?", arguments: [t.globex.id]) }
        #expect(try t.store.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM previewSurface") } == 1)
        #expect(try t.store.writer.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM previewState") } == 1)
    }
}
