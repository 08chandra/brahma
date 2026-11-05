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
        let cwd = TryWorld.Seen()
        w.world.fake.onRun = { r in seen.note(dir: r.agent.name, mode: nil); cwd.note(dir: r.workingDirectory, mode: nil); started.open() }
        let fixture = try PluginFixture()
        let trial = Task { await w.refusal(fixture) }
        await started.wait()
        await w.world.stopPoll.waiting()
        let handle = try #require(seen.devDir)
        let lab = try #require(cwd.devDir)
        #expect(lab.hasPrefix(w.ws.appending(path: ".brahma/ext-try/").path) && lab.hasSuffix("/lab"), "\(lab)")
        #expect(SandboxPath.kind(lab) == .directory, "running")
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

    /// M2, S29: what a killed trial left is swept (by the next trial and at engine start), only once it is stale, only under the
    /// trial root and its own run files, never a real agent's places, never through a link.
    @Test func staleTrialPlacesAreSwept() throws {
        let w = try TryWorld()
        let paths = w.world.paths
        let id = "try-" + UUID().uuidString.lowercased()
        let leftovers = [w.ws.appending(path: ".brahma/ext-try/\(UUID().uuidString.lowercased())/home/x"),
                         paths.runDir.appending(path: "\(id).settings.json"), paths.runDir.appending(path: "\(id).mcp.json"),
                         paths.runDir.appending(path: "taint/\(id)")]
        // Places named like a trial's in the per-agent directories (a real agent's), and an existing agent's run file.
        let agentNamed = "try-" + UUID().uuidString.lowercased()
        let kept = [w.ws.appending(path: ".brahma/home/try-1a2b3c4d/x"), w.ws.appending(path: ".brahma/labs/try-1a2b3c4d/x"),
                    w.ws.appending(path: ".brahma/notes/agents/try-1a2b3c4d.md"), w.ws.appending(path: ".brahma/bin/shell-try-1a2b3c4d.sh"),
                    paths.runDir.appending(path: "\(agentNamed).settings.json"), paths.runDir.appending(path: "eng.settings.json")]
        for url in leftovers + kept {
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("x".utf8).write(to: url)
        }
        // A link where a trial root would be: removed itself, never followed.
        let outside = try tempDir().appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try Data("keep".utf8).write(to: outside.appending(path: "f"))
        let link = w.ws.appending(path: ".brahma/ext-try/\(UUID().uuidString.lowercased())")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: outside)
        let workspace = URL(fileURLWithPath: w.company.workspacePath, isDirectory: true)
        #expect(ExtensionTry.sweepStale(paths: paths, workspace: workspace, existing: [agentNamed], now: Date()).isEmpty,
                "a trial running now keeps its places")
        let removed = ExtensionTry.sweepStale(paths: paths, workspace: workspace, existing: [agentNamed], now: Date().addingTimeInterval(7200))
        #expect(removed.count == leftovers.count + 1, "\(removed)")
        for url in leftovers { #expect(!FileManager.default.fileExists(atPath: url.path), "\(url.path)") }
        for url in kept { #expect(FileManager.default.fileExists(atPath: url.path), "\(url.path)") }
        #expect(SandboxPath.kind(link.path) == .missing); #expect(FileManager.default.fileExists(atPath: outside.appending(path: "f").path))
    }

    /// S29: a trial's places live under its own `.brahma/ext-try/<id>`; its scope writes only there (never another trial's), and
    /// its clean-up removes only that root.
    @Test func trialPlacesStayUnderItsOwnRoot() async throws {
        let w = try TryWorld()
        let other = w.ws.appending(path: ".brahma/ext-try/\(UUID().uuidString.lowercased())")
        try FileManager.default.createDirectory(at: other.appending(path: "lab"), withIntermediateDirectories: true)
        w.script()
        _ = try await w.run(try PluginFixture())
        let r = try #require(w.world.fake.requests.first)
        let scope = try #require(r.sandbox)
        let root = scope.cwd.deletingLastPathComponent()
        #expect(root.deletingLastPathComponent().path == w.ws.appending(path: ".brahma/ext-try").path, "\(scope.cwd.path)")
        #expect(scope.cwd.lastPathComponent == "lab")
        for w2 in scope.writable { #expect(w2.path.hasPrefix(root.path + "/"), "\(w2.path)") }
        let deny = Set(scope.denyWrite.map(\.path))
        #expect(deny.contains(other.path), "another trial's root")
        #expect(deny.contains(root.appending(path: "plugin").path)); #expect(deny.contains(root.appending(path: "bin").path))
        #expect(!deny.contains(w.ws.appending(path: ".brahma/ext-try").path), "its own root stays writable below")
        #expect(r.shellPrefix?.hasSuffix("/.brahma/ext-try/\(root.lastPathComponent)/bin/shell-\(r.agent.name).sh") == true, "\(r.shellPrefix ?? "")")
        for place in [".brahma/home/\(r.agent.name)", ".brahma/labs/\(r.agent.name)", ".brahma/notes/agents/\(r.agent.name).md",
                      ".brahma/bin/shell-\(r.agent.name).sh"] {
            #expect(SandboxPath.kind(w.ws.appending(path: place).path) == .missing, "never created: \(place)")
        }
        #expect(SandboxPath.kind(root.path) == .missing, "its own root is removed")
        #expect(SandboxPath.kind(other.appending(path: "lab").path) == .directory, "another trial's root is left alone")
    }

    /// S29: `try-` is reserved: no hire and no org plan may take it.
    @Test func trialHandlesAreReserved() throws {
        let w = try TryWorld()
        for name in ["try-1a2b3c4d", "TRY-1a2b3c4d", "try-x"] {
            #expect(throws: StoreError.self) { try w.store.hire(companyId: w.company.id, name: name, role: "engineer", model: "sonnet") }
        }
        #expect(ExtensionTry.isReservedHandle("T\u{0052}Y-abc".lowercased()))
        _ = try w.store.hire(companyId: w.company.id, name: "tryhard", role: "engineer", model: "sonnet")
        var plan = OrgPlan(goal: "g", agents: [])
        plan.add(role: "ceo-cpo", handle: "ceo", manager: nil, team: nil)
        plan.add(role: "engineer", handle: "try-1a2b3c4d", manager: "ceo", team: nil)
        let pack = try #require(w.store.catalog.pack("software"))
        #expect(plan.validate(pack: pack).contains { $0.handle == "try-1a2b3c4d" && $0.message.contains("reserved") })
    }

    /// I2: only the owner's shell clears a lab mark; an agent's process is refused and the mark stays.
    @Test func cliLabClearTaintIsOwnerOnly() throws {
        let owner = try OwnerTestHome(); defer { withExtendedLifetime(owner) {} }
        let home = owner.url
        let created = try brahma(["company", "create", "Acme", "--goal", "g", "--agents", "0"], home: home)
        try #require(created.status == 0, "\(created.stderr)")
        let store = try Store(path: home.appending(path: "home/brahma.sqlite").path)
        let company = try #require(try store.companies().first)
        let eng = try store.hire(companyId: company.id, name: "eng", role: "engineer", model: "sonnet")
        try store.markTainted(agentId: eng.id, source: "WebFetch")
        let agent = try brahma(["lab", "clear-taint", "Acme", "eng"], home: home, env: ["BRAHMA_AGENT_ID": eng.id])
        #expect(agent.status != 0); #expect(try store.labTaint(agentId: eng.id) != nil)
        let cleared = try brahma(["lab", "clear-taint", "Acme", "eng"], home: home)
        #expect(cleared.status == 0, "\(cleared.stderr)"); #expect(cleared.stdout.contains("cleared @eng's lab mark"))
        #expect(try store.labTaint(agentId: eng.id) == nil)
        #expect(try brahma(["lab", "clear-taint", "Acme", "eng"], home: home).stdout.contains("carries no mark"))
        // S31: the company form, owner only too.
        try store.writer.write { db in
            try db.execute(sql: "INSERT INTO companyTaint (companyId, source, profile, markedAt) VALUES (?, 'x', 'workspace', ?)",
                           arguments: [company.id, Date()])
        }
        #expect(try brahma(["lab", "clear-taint", "Acme"], home: home, env: ["BRAHMA_AGENT_ID": eng.id]).status != 0)
        #expect(try store.companyLabTaint(companyId: company.id) != nil)
        let companyCleared = try brahma(["lab", "clear-taint", "Acme"], home: home)
        #expect(companyCleared.status == 0, "\(companyCleared.stderr)"); #expect(companyCleared.stdout.contains("lab marks"))
        #expect(try store.companyLabTaint(companyId: company.id) == nil)
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
