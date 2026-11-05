import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Task 10b: `brahma ext try` — the owner runs one throwaway Quick turn with a working folder mounted as `<id>@dev`.
private struct TryWorld {
    let world: World
    let company: Company

    init(profile: PermissionProfile = .sandboxed) throws {
        world = try World()
        company = try world.company("Acme", profile: profile)
        // A real team member, to show the try handle never joins the roster.
        _ = try world.store.hire(companyId: company.id, name: "eng-1", role: "engineer", model: "sonnet")
    }

    var store: Store { world.store }
    var ws: URL { URL(fileURLWithPath: company.workspacePath, isDirectory: false).resolvedForSandbox }

    func run(_ fixture: PluginFixture, prompt: String = "Use the demo skill once.") async throws -> ExtensionTryResult {
        try await ExtensionTry.run(path: fixture.root, companyId: company.id, role: "engineer", prompt: prompt,
                                   orchestrator: world.orchestrator, now: world.clock.now)
    }

    func refusal(_ fixture: PluginFixture) async -> String? {
        do { _ = try await run(fixture); return nil } catch let e as ExtensionError { return e.message } catch let e as WorkError {
            return e.message
        } catch { return "\(error)" }
    }

    /// What the dev turn saw while it ran (captured from the fake runner's side effect).
    final class Seen: @unchecked Sendable {
        private let lock = NSLock()
        private var _devDir: String?
        private var _devMode: Int?
        var devDir: String? { lock.withLock { _devDir } }
        var devMode: Int? { lock.withLock { _devMode } }
        func note(dir: String, mode: Int?) { lock.withLock { _devDir = dir; _devMode = mode } }
    }

    func script(_ seen: Seen? = nil, skills: [String] = ["demo:demo"], cost: Double = 0.02) {
        let session = "try-session"
        world.fake.defaultScript = FakeTurnRunner.Script(events: [
            .initialized(sessionId: session, model: "haiku"),
            .initInfo(InitInfo(sessionId: session, model: "haiku", tools: ["Bash", "Read", "Skill"], agents: [], skills: skills)),
            .toolUse(name: "Skill", inputDigest: "d"),
            .result(TurnResult(isError: false, subtype: "success", text: "It said hello in the house tone.", costUSD: cost,
                               apiErrorStatus: nil, sessionId: session)),
        ], sideEffect: { r in
            guard let seen, let dev = r.mounts.first(where: { $0.path.contains("/.brahma/ext-try/") }) else { return }
            let skill = dev.appending(path: "skills/demo/SKILL.md").path
            seen.note(dir: dev.path, mode: (try? FileManager.default.attributesOfItem(atPath: skill)[.posixPermissions]) as? Int)
        })
    }

    /// Installs an extension for the engineer role (the app's propose-and-approve path).
    func install(_ fixture: PluginFixture) async throws {
        let staged = try await ExtensionImporter.stage(source: .folder(fixture.root), paths: world.paths, sandbox: RecordingRunner())
        let ask = try await ExtensionLibrary.propose(staged: staged, store: store, paths: world.paths, companyId: company.id,
                                                     requester: .system, roles: ["engineer"], now: world.clock.now)
        try ExtensionLibrary.approve(askId: ask.id, roles: nil, store: store, paths: world.paths, now: world.clock.now)
    }
}

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

@Suite(.scratch) struct ExtensionTryTests {
    @Test func tryRunsOneTurnNoAsk() async throws {
        let w = try TryWorld()
        w.script()
        let fixture = try PluginFixture()
        let asks = try w.store.asks(companyId: w.company.id).count
        let result = try await w.run(fixture, prompt: "Say hello with the demo skill.")
        #expect(w.world.fake.requests.count == 1)
        let r = try #require(w.world.fake.requests.first)
        #expect(r.agent.name.hasPrefix("try-")); #expect(r.agent.name.count == "try-".count + 8)
        #expect(r.agent.name == result.handle)
        #expect(r.kind == .work); #expect(r.profile == .sandboxed)
        #expect(r.agent.model == "haiku"); #expect(!r.agent.sessionStarted, "a fresh session")
        #expect(r.prompt.contains("Say hello with the demo skill."))
        #expect(r.appendSystemPrompt?.contains(RolePrompt.sandboxLine) == true, "the role's own template")
        #expect(try w.store.asks(companyId: w.company.id).count == asks, "no ask is created")
        #expect(result.extId == "demo")
        #expect(ExtensionTry.summary(result).contains("demo@dev"))
    }

    @Test func tryMountsDevCopyReadOnly() async throws {
        let w = try TryWorld()
        // An extension the role already mounts stays mounted next to the dev copy.
        try await w.install(try PluginFixture(id: "house"))
        let seen = TryWorld.Seen()
        w.script(seen)
        _ = try await w.run(try PluginFixture())
        let r = try #require(w.world.fake.requests.first)
        let dev = try #require(seen.devDir)
        #expect(dev.hasPrefix(w.ws.appending(path: ".brahma/ext-try/").path)); #expect(dev.hasSuffix("/plugin"))
        #expect(seen.devMode == 0o444, "the dev copy is read-only")
        #expect(r.mounts.map(\.path).contains { $0.contains("/.brahma/ext/house/") }, "the role's normal mounts too")
        let scope = try #require(r.sandbox)
        #expect(scope.readable.map(\.path).contains(dev)); #expect(scope.readOnlyDirs.map(\.path).contains(dev))
        #expect(!scope.writable.contains { $0.path.hasPrefix(dev) })
        #expect(r.addDirs.contains(dev))
        let settings = TurnProfileCompiler.profile(for: r).settings
        #expect(settings.sandbox?.filesystem?.denyWrite?.contains(dev) == true)
        // Only that one turn: an ordinary turn of a real agent never reads ext-try.
        #expect(!SandboxScope.readableDotBrahma.contains("ext-try"))
        #expect(SandboxScope.engineOnlyDotBrahma.contains("ext-try"))
        // The try dir is removed afterwards.
        #expect(SandboxPath.kind(dev) == .missing)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: w.ws.appending(path: ".brahma/ext-try").path)) ?? []).isEmpty)
    }

    @Test func tryRefusedOnWorkspaceProfile() async throws {
        let w = try TryWorld(profile: .workspace)
        w.script()
        let got = try #require(await w.refusal(try PluginFixture()))
        #expect(got == ExtensionTry.profileRefusal, "\(got)")
        #expect(w.world.fake.requests.isEmpty)
    }

    @Test func tryRefusedWithLintErrors() async throws {
        let w = try TryWorld()
        w.script()
        let got = try #require(await w.refusal(try PluginFixture(files: [".mcp.json": #"{"mcpServers": {}}"#])))
        #expect(got.contains("EXT002"), "\(got)")
        #expect(w.world.fake.requests.isEmpty)
        #expect(SandboxPath.kind(w.ws.appending(path: ".brahma/ext-try").path) != .directory
                || ((try? FileManager.default.contentsOfDirectory(atPath: w.ws.appending(path: ".brahma/ext-try").path)) ?? []).isEmpty)
        // Warnings alone do not refuse a try.
        _ = try await w.run(try PluginFixture(id: "warned", files: ["skills/warned/SKILL.md": PluginFixture.skillMD(
            name: "warned", frontmatter: "allowed-tools: Bash")]))
        #expect(w.world.fake.requests.count == 1)
    }

    @Test func tryRecordedAsDevRunNotRoster() async throws {
        let w = try TryWorld()
        w.script(skills: ["demo:demo", "extension-authoring:extension-authoring"], cost: 0.02)
        let result = try await w.run(try PluginFixture())
        #expect(result.costUSD == 0.02); #expect(result.skills.contains("demo:demo")); #expect(result.tools == ["Skill"])
        let event = try #require(try w.store.extensionEvents(companyId: w.company.id, extId: "demo").first { $0.kind == "try" })
        let detail = try #require(event.detail)
        for part in ["demo@dev", result.handle, "role engineer", "$0.02", "skills demo:demo", "tools Skill", "transcript"] {
            #expect(detail.contains(part), "\(part) in \(detail)")
        }
        // Never a team member: no agent row, no turn row, no places left behind.
        let roster = try w.store.agents(companyId: w.company.id)
        #expect(!roster.contains { $0.name.hasPrefix("try-") }); #expect(roster.count == 1)
        let turns: Int = try await w.store.writer.read { (db: Database) throws -> Int in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM turn") ?? 0 }
        #expect(turns == 0)
        for place in [".brahma/home/\(result.handle)", ".brahma/labs/\(result.handle)", ".brahma/notes/agents/\(result.handle).md",
                      ".brahma/bin/shell-\(result.handle).sh"] {
            #expect(SandboxPath.kind(w.ws.appending(path: place).path) == .missing, "\(place)")
        }
        #expect(!(try w.store.events(afterId: 0, companyId: w.company.id)).contains { $0.text.contains("@\(result.handle)") && $0.kind == .toolUse })
        // The summary goes through safe() in the CLI: agent text is flattened here already.
        #expect(!ExtensionTry.summary(result).contains("\u{1B}"))
    }

    @Test func tryCapsAreQuick() async throws {
        let w = try TryWorld()
        w.script()
        _ = try await w.run(try PluginFixture())
        let r = try #require(w.world.fake.requests.first)
        let a = TurnProfileCompiler.arguments(TurnProfileCompiler.profile(for: r))
        func value(_ flag: String) -> String? { a.firstIndex(of: flag).map { a[$0 + 1] } }
        #expect(value("--max-budget-usd") == "0.30")
        #expect(value("--max-turns") == "10")
        #expect(value("--model") == "haiku")
        #expect(r.mode?.mode == .quick)
        #expect(a.contains("--restricted"))
    }

    /// M2: the emergency stop refuses a trial before it starts, and stops one that runs: its process ends and its places go.
    @Test func tryHonoursTheEmergencyStop() async throws {
        let w = try TryWorld()
        w.script()
        try w.store.emergencyStop(note: nil, by: "owner", now: w.world.clock.now)
        #expect(await w.refusal(try PluginFixture()) == ExtensionTry.stoppedRefusal)
        #expect(w.world.fake.requests.isEmpty)
        try await w.store.writer.write { db in try db.execute(sql: "DELETE FROM engineStop") }

        let hold = Gate(), started = Gate()
        w.world.fake.defaultScript = FakeTurnRunner.Script(gate: hold)
        let seen = TryWorld.Seen()
        w.world.fake.onRun = { r in seen.note(dir: r.agent.name, mode: nil); started.open() }
        let fixture = try PluginFixture()
        let trial = Task { await w.refusal(fixture) }
        await started.wait()
        await w.world.stopPoll.waiting()
        let handle = try #require(seen.devDir)
        #expect(SandboxPath.kind(w.ws.appending(path: ".brahma/labs/\(handle)").path) == .directory, "running")
        try w.store.emergencyStop(note: nil, by: "owner", now: w.world.clock.now)
        w.world.stopPoll.step()
        #expect(await trial.value == ExtensionTry.stoppedRefusal)
        hold.open()
        for place in [".brahma/home/\(handle)", ".brahma/labs/\(handle)", ".brahma/notes/agents/\(handle).md", ".brahma/bin/shell-\(handle).sh"] {
            #expect(SandboxPath.kind(w.ws.appending(path: place).path) == .missing, "\(place)")
        }
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: w.ws.appending(path: ".brahma/ext-try").path)) ?? []).isEmpty)
        #expect(try w.store.extensionEvents(companyId: w.company.id).filter { $0.kind == "try" }.isEmpty, "a stopped trial is not recorded")
    }

    /// M2: what a killed trial left is swept (by the next trial and at engine start), and only once it is stale.
    @Test func staleTrialPlacesAreSwept() throws {
        let w = try TryWorld()
        let paths = w.world.paths
        let id = "try-" + UUID().uuidString.lowercased()
        let leftovers = [w.ws.appending(path: ".brahma/ext-try/\(UUID().uuidString.lowercased())/plugin/x.md"),
                         w.ws.appending(path: ".brahma/home/try-abcdef12/x"), w.ws.appending(path: ".brahma/labs/try-abcdef12/x"),
                         w.ws.appending(path: ".brahma/notes/agents/try-abcdef12.md"), w.ws.appending(path: ".brahma/bin/shell-try-abcdef12.sh"),
                         paths.runDir.appending(path: "\(id).settings.json"), paths.runDir.appending(path: "\(id).mcp.json"),
                         paths.runDir.appending(path: "taint/\(id)")]
        let kept = [w.ws.appending(path: ".brahma/home/eng-1/x"), paths.runDir.appending(path: "eng.settings.json")]
        for url in leftovers + kept {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        let workspace = URL(fileURLWithPath: w.company.workspacePath, isDirectory: true)
        #expect(ExtensionTry.sweepStale(paths: paths, workspace: workspace, now: Date()).isEmpty, "a trial running now keeps its places")
        let removed = ExtensionTry.sweepStale(paths: paths, workspace: workspace, now: Date().addingTimeInterval(7200))
        #expect(removed.count == leftovers.count, "\(removed)")
        for url in leftovers { #expect(!FileManager.default.fileExists(atPath: url.path), "\(url.path)") }
        for url in kept { #expect(FileManager.default.fileExists(atPath: url.path), "\(url.path)") }
    }

    /// The CLI: owner-only, lint errors refuse before any turn, and `company create` writes the built-ins.
    @Test func cliTryIsOwnerOnlyAndLinted() throws {
        let owner = try OwnerTestHome(); defer { withExtendedLifetime(owner) {} }
        let home = owner.url
        let created = try brahma(["company", "create", "Acme", "--goal", "g", "--agents", "0"], home: home)
        try #require(created.status == 0, "\(created.stderr)")
        let workspace = try #require(created.stdout.split(separator: " ").last.map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) })
        let authoring = BuiltinExtensions.pluginDir(BuiltinExtensions.authoring, workspace: URL(fileURLWithPath: workspace))
        #expect(try ExtensionLock.treeHash(root: authoring) == BuiltinExtensions.authoring.pinnedHash)
        let bad = try PluginFixture(files: [".mcp.json": #"{"mcpServers": {}}"#])
        let refused = try brahma(["ext", "try", bad.root.path, "--company", "Acme", "--role", "engineer", "--prompt", "hi"], home: home)
        #expect(refused.status != 0); #expect(refused.stderr.contains("EXT002"), "\(refused.stderr)")
        let agent = try brahma(["ext", "try", try PluginFixture(id: "good").root.path, "--company", "Acme", "--role", "engineer",
                                "--prompt", "hi"], home: home, env: ["BRAHMA_AGENT_ID": "a1"])
        #expect(agent.status != 0)
    }
}
