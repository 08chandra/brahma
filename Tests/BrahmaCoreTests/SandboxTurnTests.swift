import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// The orchestrator's sandboxed turns (Task 1b): the company's profile per turn, the scope, the settings file, the shell
/// prefix, and what happens when the scope is refused.
private struct SandboxTurnWorld {
    let world: World
    let company: Company
    let eng: Agent

    init(engineProfile: PermissionProfile? = nil, profile: PermissionProfile = .sandboxed) throws {
        world = try World(profile: engineProfile)
        company = try world.company("Acme", profile: profile)
        eng = try world.store.hire(companyId: company.id, name: "eng-1", role: "engineer", model: "sonnet")
    }

    var store: Store { world.store }
    var ws: URL { URL(fileURLWithPath: company.workspacePath, isDirectory: false).resolvedForSandbox }
    var layout: SandboxLayout { SandboxLayout(paths: world.paths, company: company, agentHandle: eng.name) }
    var lab: URL { ws.appending(path: ".brahma/labs/\(eng.name)") }
    func requests() -> [TurnRequest] { world.fake.requests.filter { $0.agent.id == eng.id } }
    func tools() -> CompanyTools { CompanyTools(store: store, companyId: company.id, agentId: eng.id) }
    func events() throws -> [ActivityEvent] { try store.events(afterId: 0, companyId: company.id) }
    func ownerAlerts() throws -> [Ask] { try store.asks(companyId: company.id).filter { $0.kind == .engineAlert } }

    func item(_ title: String = "Do it") throws -> WorkItem {
        try store.createWorkItem(companyId: company.id, by: .owner, draft: WorkItemDraft(
            type: .task, title: title, acceptanceCriteria: "it works", checkSpec: CheckSpec(command: "true", paths: ["src/a"]),
            status: .ready), now: world.clock.now)
    }
}

private func value(_ a: [String], _ flag: String) -> String? { a.firstIndex(of: flag).map { a[$0 + 1] } }

@Suite struct SandboxTurnTests {
    @Test func itemlessSandboxedTurnRunsInTheLabWithItsSettingsFile() async throws {
        let w = try SandboxTurnWorld()
        try w.world.dm(w.company, w.eng)
        try await w.world.cycle()
        let r = try #require(w.requests().last)
        #expect(r.profile == .sandboxed)
        let scope = try #require(r.sandbox)
        #expect(r.workingDirectory == w.lab.path); #expect(scope.cwd.path == w.lab.path)
        #expect(SandboxPath.kind(w.lab.appending(path: ".git").path) == .directory, "layout.ensure() ran")
        // The settings file: 0600, the compiled settings, named on the argv.
        let path = try #require(r.settingsFilePath)
        #expect(path == w.world.paths.runDir.appending(path: "\(w.eng.id).settings.json").path)
        #expect((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) == 0o600)
        let profile = TurnProfileCompiler.profile(for: r)
        #expect(try String(contentsOfFile: path, encoding: .utf8) == TurnProfileCompiler.settingsJSON(profile))
        let decoded = try JSONDecoder().decode(ClaudeSettings.self, from: Data(contentsOf: URL(fileURLWithPath: path)))
        #expect(decoded.sandbox?.enabled == true); #expect(decoded.sandbox?.allowUnsandboxedCommands == false)
        let a = TurnProfileCompiler.arguments(profile)
        #expect(value(a, "--settings") == path); #expect(a.contains("--restricted"))
        // The shell prefix: written 0755 under .brahma/bin, named in the environment.
        let prefix = try #require(r.shellPrefix)
        #expect(prefix == w.layout.shellPrefix.path)
        #expect((try FileManager.default.attributesOfItem(atPath: prefix)[.posixPermissions] as? Int) == 0o755)
        #expect(profile.environment["CLAUDE_CODE_SHELL_PREFIX"] == prefix)
        try TurnProfileCompiler.validate(profile)
        // The role prompt says so.
        #expect(r.appendSystemPrompt?.contains(RolePrompt.sandboxLine) == true)
        #expect(try w.world.turns(w.eng).last?.outcome == .succeeded)
    }

    @Test func leaseholderRunsInItsWorktree() async throws {
        let w = try SandboxTurnWorld()
        let i = try w.item()
        _ = try w.tools().call(name: "claim_lease", arguments: ["key": .string(i.key)])
        try w.world.dm(w.company, w.eng)
        try await w.world.cycle()
        let r = try #require(w.requests().last)
        let scope = try #require(r.sandbox)
        #expect(scope.cwd.path == w.ws.appending(path: ".brahma/wt/\(i.key)").path)
        #expect(r.workingDirectory == scope.cwd.path)
        #expect(scope.writable.map(\.path).contains(w.ws.appending(path: ".git/refs/heads/item/\(i.key)").path))
        #expect(TurnProfileCompiler.profile(for: r).addDirs.isEmpty, "no extra directory: the worktree is the cwd")
    }

    @Test func companyProfilesUnderTheEngineCeiling() async throws {
        // No ceiling: the company's own profile.
        var w = try SandboxTurnWorld(profile: .full)
        try w.world.dm(w.company, w.eng)
        try await w.world.cycle()
        #expect(w.requests().last?.profile == .full)
        #expect(w.requests().last?.sandbox == nil)
        // A ceiling narrows it.
        w = try SandboxTurnWorld(engineProfile: .workspace, profile: .full)
        try w.world.dm(w.company, w.eng)
        try await w.world.cycle()
        #expect(w.requests().last?.profile == .workspace)
        w = try SandboxTurnWorld(engineProfile: .sandboxed, profile: .full)
        try w.world.dm(w.company, w.eng)
        try await w.world.cycle()
        #expect(w.requests().last?.profile == .sandboxed)
        // It never widens one.
        w = try SandboxTurnWorld(engineProfile: .full, profile: .sandboxed)
        try w.world.dm(w.company, w.eng)
        try await w.world.cycle()
        #expect(w.requests().last?.profile == .sandboxed)
        // A role's override is the company's choice for that role.
        w = try SandboxTurnWorld(profile: .sandboxed)
        try w.store.updateSandbox(companyId: w.company.id, SandboxPatch(roleProfiles: ["engineer": .workspace]), userHome: try tempDir())
        try w.world.dm(w.company, w.eng)
        try await w.world.cycle()
        #expect(w.requests().last?.profile == .workspace)
        #expect(PermissionProfile.narrower(.full, .sandboxed) == .sandboxed)
        #expect(PermissionProfile.narrower(.workspace, .full) == .workspace)
    }

    @Test func workspaceTurnsDenyTheDataHomeAndOtherWorkspaces() async throws {
        let w = try SandboxTurnWorld(profile: .workspace)
        let other = try w.world.company("Bolt")
        try w.world.dm(w.company, w.eng)
        try await w.world.cycle()
        let r = try #require(w.requests().last)
        #expect(r.sandbox == nil)
        let denied = r.deniedPaths.map(\.path)
        #expect(denied.contains(w.world.paths.home.path))
        #expect(denied.contains(other.workspacePath))
        let settings = TurnProfileCompiler.profile(for: r).settings
        #expect(settings.permissions?.deny?.contains("Read(/\(w.world.paths.home.path)/**)") == true)
        let path = try #require(r.settingsFilePath)
        #expect((try FileManager.default.attributesOfItem(atPath: path)[.posixPermissions] as? Int) == 0o600)
        #expect(!(r.appendSystemPrompt ?? "").contains(RolePrompt.sandboxLine))
    }

    @Test func linkedOwnPlaceFailsTheTurnAlertsAndIsRepaired() async throws {
        let w = try SandboxTurnWorld()
        try w.world.dm(w.company, w.eng)
        try await w.world.cycle()
        #expect(try w.world.turns(w.eng).last?.outcome == .succeeded)
        // The agent replaces its own lab with a link to somewhere else.
        let elsewhere = try tempDir()
        try FileManager.default.removeItem(at: w.lab)
        try FileManager.default.createSymbolicLink(atPath: w.lab.path, withDestinationPath: elsewhere.path)
        try w.world.dm(w.company, w.eng, "again")
        try await w.world.cycle()
        let failed = try #require(try w.world.turns(w.eng).last)
        #expect(failed.outcome == .failed)
        #expect(failed.summary?.contains("sandbox scope:") == true, "\(failed.summary ?? "")")
        #expect(w.requests().count == 1, "no process was started")
        let alert = try #require(try w.ownerAlerts().last)
        #expect(alert.summary.contains(".brahma/labs/eng-1 is a symbolic link"), "\(alert.summary)")
        #expect(alert.summary.contains("removed the link"))
        // Repaired: the link is gone (its target untouched) and the lab is a real directory again.
        #expect(SandboxPath.kind(w.lab.path) == .directory)
        #expect(FileManager.default.fileExists(atPath: elsewhere.path))
        // The next turn runs.
        w.world.clock.advance(3600)
        try await w.world.cycle()
        #expect(try w.world.turns(w.eng).last?.outcome == .succeeded)
        #expect(w.requests().count == 2)
    }

    @Test func linkedPlaceThatIsNotTheAgentsIsNotRepaired() async throws {
        let w = try SandboxTurnWorld()
        let i = try w.item()
        _ = try w.tools().call(name: "claim_lease", arguments: ["key": .string(i.key)])
        // An intermediate directory of the item's reflog (engine-made, shared by every item) is a link.
        let logs = w.ws.appending(path: ".git/logs/refs/heads/item")
        let elsewhere = try tempDir()
        try? FileManager.default.removeItem(at: logs)
        try FileManager.default.createSymbolicLink(atPath: logs.path, withDestinationPath: elsewhere.path)
        try w.world.dm(w.company, w.eng)
        try await w.world.cycle()
        let failed = try #require(try w.world.turns(w.eng).last)
        #expect(failed.outcome == .failed)
        #expect(failed.summary?.contains("sandbox scope:") == true, "\(failed.summary ?? "")")
        #expect(try w.ownerAlerts().contains { $0.summary.contains(".git/logs/refs/heads/item is a symbolic link") })
        #expect(SandboxPath.kind(logs.path) == .link, "not the agent's own place: the owner decides")
        #expect(w.requests().isEmpty)
    }

    @Test func skippedUnsafeEntriesAreLogged() async throws {
        let w = try SandboxTurnWorld()
        try FileManager.default.createDirectory(at: w.ws.appending(path: "it's"), withIntermediateDirectories: true)
        try w.world.dm(w.company, w.eng)
        try await w.world.cycle()
        #expect(try w.world.turns(w.eng).last?.outcome == .succeeded)
        #expect(try w.events().contains { $0.text.contains("left out of the sandbox") && $0.text.contains("it's") })
    }

    @Test func earlierTurnProcessesStillRunningRefuseTheTurn() async throws {
        let w = try SandboxTurnWorld()
        w.world.fake.survivors = [4242]
        try w.world.dm(w.company, w.eng)
        try await w.world.cycle()
        let failed = try #require(try w.world.turns(w.eng).last)
        #expect(failed.outcome == .failed)
        #expect(failed.summary?.contains("still running") == true, "\(failed.summary ?? "")")
        #expect(w.requests().isEmpty)
    }

    @Test func sandboxScopeRecheckRefusesALinkPlantedAfterCompute() throws {
        let root = URL(fileURLWithPath: SandboxPath.resolve(try tempDir().path), isDirectory: false)
        let ws = root.appending(path: "ws")
        let cwd = ws.appending(path: ".brahma/labs/eng-1")
        try FileManager.default.createDirectory(at: cwd, withIntermediateDirectories: true)
        let scope = SandboxScope(workspace: ws, cwd: cwd, writable: [cwd], readable: [cwd], readOnlyDirs: [], denyRead: [],
                                 denyWrite: [], protected: [], network: NetworkScope(allowedDomains: [], webDomains: [], allowLocalBinding: false),
                                 toolchainTempWrite: nil)
        try scope.recheckBeforeSpawn()
        try FileManager.default.removeItem(at: cwd)
        try FileManager.default.createSymbolicLink(atPath: cwd.path, withDestinationPath: root.path)
        #expect(throws: SandboxError.linkedPath(cwd.path)) { try scope.recheckBeforeSpawn() }
        try FileManager.default.removeItem(at: cwd)
        #expect(throws: SandboxError.self) { try scope.recheckBeforeSpawn() }
    }
}
