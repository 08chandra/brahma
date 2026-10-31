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

    init(engineProfile: PermissionProfile? = nil, profile: PermissionProfile = .sandboxed,
         canSeeSandboxes: @escaping @Sendable () -> Bool = { true }) throws {
        world = try World(profile: engineProfile, canSeeSandboxes: canSeeSandboxes)
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
    var home: URL { ws.appending(path: ".brahma/home/\(eng.name)") }
    var trash: URL { ws.appending(path: ".brahma/trash/\(eng.name)") }

    /// A turn that fails at its scope, then (after the backoff) one that runs.
    func failThenRun() async throws -> (failed: Turn, next: Turn) {
        try world.dm(company, eng, "again")
        try await world.cycle()
        let failed = try #require(try world.turns(eng).last)
        world.clock.advance(3600)
        try world.dm(company, eng, "and again")
        try await world.cycle()
        return (failed, try #require(try world.turns(eng).last))
    }

    func item(_ title: String = "Do it") throws -> WorkItem {
        try store.createWorkItem(companyId: company.id, by: .owner, draft: WorkItemDraft(
            type: .task, title: title, acceptanceCriteria: "it works", checkSpec: CheckSpec(command: "true", paths: ["src/a"]),
            status: .ready), now: world.clock.now)
    }
}

private func value(_ a: [String], _ flag: String) -> String? { a.firstIndex(of: flag).map { a[$0 + 1] } }

@Suite(.scratch) struct SandboxTurnTests {
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
        #expect(try String(contentsOfFile: path, encoding: .utf8) == (try TurnProfileCompiler.settingsJSON(profile)))
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
        #expect(alert.summary.contains("repaired"))
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

    /// B-I4: wrong-kind or linked entries anywhere in the agent's own places are repaired: a link is removed (never followed),
    /// anything else is moved to the engine-only `.brahma/trash/<h>/` (no data lost), then the places are recreated. The
    /// owner hears what was there; the next turn runs.
    @Test func selfBrickedPlacesAreRepaired() async throws {
        for (what, plant) in [
            ("lab .git link", { (w: SandboxTurnWorld) throws in
                let git = w.lab.appending(path: ".git")
                try FileManager.default.removeItem(at: git)
                try FileManager.default.createSymbolicLink(atPath: git.path, withDestinationPath: try tempDir().path)
            }),
            ("file at the cache", { (w: SandboxTurnWorld) throws in
                let cache = w.home.appending(path: "cache")
                try FileManager.default.removeItem(at: cache)
                try Data("x".utf8).write(to: cache)
            }),
            ("directory at the notes file", { (w: SandboxTurnWorld) throws in
                let notes = w.ws.appending(path: ".brahma/notes/agents/\(w.eng.name).md")
                try FileManager.default.removeItem(at: notes)
                try FileManager.default.createDirectory(at: notes.appending(path: "inside"), withIntermediateDirectories: true)
            }),
        ] as [(String, (SandboxTurnWorld) throws -> Void)] {
            let w = try SandboxTurnWorld()
            try w.world.dm(w.company, w.eng)
            try await w.world.cycle()
            #expect(try w.world.turns(w.eng).last?.outcome == .succeeded, "\(what)")
            try plant(w)
            let (failed, next) = try await w.failThenRun()
            #expect(failed.outcome == .failed, "\(what)"); #expect(failed.summary?.contains("sandbox scope:") == true, "\(what)")
            #expect(next.outcome == .succeeded, "\(what): the next turn runs")
            let alert = try #require(try w.ownerAlerts().last, "\(what)")
            #expect(alert.summary.contains("repaired"), "\(what): \(alert.summary)")
            if what != "lab .git link" {
                #expect(!SandboxPath.entries(w.trash.path).isEmpty, "\(what): moved to the trash, not deleted")
            }
        }
    }

    /// B-I2: when the engine cannot see what a sandbox allows (its self-test failed), sandboxed turns do not start.
    @Test func blindContainmentRefusesSandboxedTurns() async throws {
        let w = try SandboxTurnWorld(canSeeSandboxes: { false })
        try w.world.dm(w.company, w.eng)
        try await w.world.cycle()
        let failed = try #require(try w.world.turns(w.eng).last)
        #expect(failed.outcome == .failed)
        #expect(failed.summary?.contains("cannot see sandboxed processes") == true, "\(failed.summary ?? "")")
        #expect(w.requests().isEmpty)
    }

    /// The marker, the record directory and the sentinel (M4: re-asserted before each sandboxed turn).
    @Test func sandboxedTurnCarriesMarkerRecordsAndSentinel() async throws {
        let w = try SandboxTurnWorld()
        try? FileManager.default.removeItem(at: w.world.paths.sentinel)
        try w.world.dm(w.company, w.eng)
        try await w.world.cycle()
        let r = try #require(w.requests().last)
        #expect(r.containmentMarker?.hasPrefix("dev.brahma.turn.") == true)
        #expect(r.turnRecordDirectory?.path == w.world.paths.runDir.appending(path: "turns").path)
        #expect(try String(contentsOf: w.world.paths.sentinel, encoding: .utf8) == "sentinel")
        let settings = try JSONDecoder().decode(ClaudeSettings.self, from: Data(contentsOf: URL(fileURLWithPath: try #require(r.settingsFilePath))))
        #expect(settings.sandbox?.network?.allowMachLookup == [r.containmentMarker!])
    }

    /// M1: every turn, whatever its profile, waits for the agent's earlier turn first; leftovers it killed are logged (M4).
    @Test func everyProfileWaitsAndLeftoversAreReported() async throws {
        let w = try SandboxTurnWorld(profile: .workspace)
        w.world.fake.leftovers = TurnLeftovers(killed: [4343], survivors: [])
        try w.world.dm(w.company, w.eng)
        try await w.world.cycle()
        #expect(try w.world.turns(w.eng).last?.outcome == .succeeded)
        #expect(try w.events().contains { $0.text.contains("4343") && $0.text.contains("left over") })
        w.world.fake.leftovers = TurnLeftovers(killed: [], survivors: [4242])
        w.world.clock.advance(3600)
        try w.world.dm(w.company, w.eng, "again")
        try await w.world.cycle()
        let failed = try #require(try w.world.turns(w.eng).last)
        #expect(failed.outcome == .failed); #expect(failed.summary?.contains("still running") == true)
        #expect(try w.ownerAlerts().contains { $0.summary.contains("4242") })
    }

    /// M6: a workspace turn's denies name the data home and the other workspaces in both forms, and fail the turn (not drop the
    /// denies) when the company list cannot be read.
    @Test func workspaceDeniesInBothForms() async throws {
        let w = try SandboxTurnWorld(profile: .workspace)
        try w.world.dm(w.company, w.eng)
        try await w.world.cycle()
        let denied = Set(try #require(w.requests().last).deniedPaths.map(\.path))
        #expect(denied.contains(w.world.paths.home.path)); #expect(denied.contains(w.world.paths.home.resolvedForSandbox.path))
    }

    /// Fix round 2 (B-N5): a wait that cannot finish (its deadline, a corrupt record) refuses the turn AND tells the owner once;
    /// its wording does not depend on the profile.
    @Test func throwingWaitAlertsTheOwner() async throws {
        let w = try SandboxTurnWorld(profile: .workspace)
        w.world.fake.waitError = TurnRecords.Corrupt(path: "/x/turns/a.turn", quarantinedTo: "/x/turns/quarantine/a.turn")
        try w.world.dm(w.company, w.eng)
        try await w.world.cycle()
        let failed = try #require(try w.world.turns(w.eng).last)
        #expect(failed.outcome == .failed)
        #expect(failed.summary?.contains("sandbox scope:") == false, "\(failed.summary ?? "")")
        #expect(failed.summary?.contains("earlier turn") == true, "\(failed.summary ?? "")")
        #expect(try w.ownerAlerts().contains { $0.summary.contains("/x/turns/a.turn") })
    }

    /// Fix round 2 (B-N6): a failed containment self-test is an owner alert, not only per-turn summaries.
    @Test func blindContainmentAlertsTheOwner() async throws {
        let w = try SandboxTurnWorld(canSeeSandboxes: { false })
        try w.world.dm(w.company, w.eng)
        try await w.world.cycle()
        #expect(try w.ownerAlerts().contains { $0.summary.contains("cannot see sandboxed processes") })
    }

    @Test func earlierTurnProcessesStillRunningRefuseTheTurn() async throws {
        let w = try SandboxTurnWorld()
        w.world.fake.leftovers = TurnLeftovers(killed: [], survivors: [4242])
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
