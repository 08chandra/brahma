import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// The install pipeline and the per-role mounts (Task 5a): one pending ask per install, read-only materialization, the
/// publisher set by the installer, the pack and override resolver, rehash on mount, the profile gate and the session freeze.
@Suite(.scratch) struct ExtensionLibraryTests {
    @Test func cliInstallIsPendingAsk() async throws {
        let w = try ExtWorld()
        let f = try PluginFixture()
        let ask = try await w.propose(f, roles: ["engineer"])
        #expect(ask.kind == .extension); #expect(ask.status == .pendingOwner); #expect(ask.risk == .high)
        #expect(ask.category == "prompt-change"); #expect(ask.requesterId == "system")
        #expect(AskKind.extension.isReservedKind); #expect(AskKind.extension.title == "Extension")
        let payload = try #require(ExtensionAskPayload.read(ask))
        #expect(payload.action == "install"); #expect(payload.extId == "demo"); #expect(payload.publisher == "local")
        #expect(payload.roles == ["engineer"]); #expect(payload.hash.count == 64)
        // The review page: each SKILL.md verbatim and quoted, in the workspace where the owner (and the app) can read it.
        let doc = try #require(ask.payload?.documentPath)
        #expect(doc == ".brahma/ext-review/\(ask.ref).md")
        let page = try String(contentsOf: w.ws.appending(path: doc), encoding: .utf8)
        #expect(page.contains("    | 1. Do the thing.")); #expect(page.contains("skills/demo/SKILL.md"))
        // Nothing is installed or mounted until the owner approves in the app.
        #expect(try w.installed("demo") == nil)
        #expect(try w.mounts().isEmpty)
        #expect(try w.events("staged").count == 1)
        // A package with errors (an install script the importer cannot drop) is refused with the lint list, and no ask is filed.
        let bad = try PluginFixture(id: "bad", files: ["skills/bad/scripts/setup.py": "import os"])
        await #expect(throws: ExtensionError.self) { try await w.propose(bad) }
        #expect(try w.store.asks(companyId: w.company.id).count == 1)
        // The same id cannot be proposed twice while an ask is open, and ids are unique per company once installed.
        await #expect(throws: ExtensionError.self) { try await w.propose(try PluginFixture()) }
    }

    @Test func approveMaterializesReadOnly() async throws {
        let w = try ExtWorld()
        let f = try PluginFixture(files: ["brahma.json": #"{"brahma": 1}"#, "tests/cases/a.yaml": "x: 1"])
        try f.bin("demo-tool")
        ScratchScope.current?.allowExecutable(named: "demo-tool")
        let ask = try await w.propose(f)
        try ExtensionLibrary.approve(askId: ask.id, roles: nil, store: w.store, paths: w.paths, now: w.world.clock.now, owner: .test)
        let installed = try #require(try w.installed("demo"))
        #expect(installed.enabled); #expect(installed.installedAskId == ask.id)
        let hash12 = String(installed.hash.prefix(12))
        let fm = FileManager.default
        // The whole verified tree in the data home, read-only.
        let store = w.paths.extensionsDir.store.appending(path: "demo/\(hash12)")
        #expect(fm.fileExists(atPath: store.appending(path: "tests/cases/a.yaml").path))
        #expect(fm.fileExists(atPath: store.appending(path: "brahma.json").path))
        #expect(fm.fileExists(atPath: store.appending(path: "ext.lock.json").path))
        #expect(!fm.isWritableFile(atPath: store.appending(path: "skills/demo/SKILL.md").path))
        // Only the plugin parts in the workspace, read-only, and the staging dir is gone.
        let plugin = w.ws.appending(path: ".brahma/ext/demo/\(hash12)/plugin")
        #expect(fm.fileExists(atPath: plugin.appending(path: ".claude-plugin/plugin.json").path))
        #expect(fm.fileExists(atPath: plugin.appending(path: "skills/demo/SKILL.md").path))
        #expect(fm.isExecutableFile(atPath: plugin.appending(path: "bin/demo-tool").path))
        #expect(!fm.fileExists(atPath: plugin.appending(path: "tests").path))
        #expect(!fm.fileExists(atPath: plugin.appending(path: "brahma.json").path))
        #expect(!fm.isWritableFile(atPath: plugin.appending(path: "skills/demo/SKILL.md").path))
        #expect(try fm.contentsOfDirectory(atPath: w.paths.extensionsDir.staging.path).isEmpty)
        // The ask is approved, with the binding and the event.
        #expect(try w.store.ask(id: ask.id)?.status == .approved)
        let bindings = try w.store.extensionBindings(companyId: w.company.id)
        #expect(bindings.map { "\($0.scope):\($0.target):\($0.op):\($0.id)" } == ["role:engineer:add:demo"])
        #expect(try w.events("installed").count == 1)
        // Not in any turn's allowWrite: the sandbox denies .brahma/ext whole, on every turn kind.
        let layout = SandboxLayout(paths: w.paths, company: w.company, agentHandle: w.eng.name)
        for kind in [TurnKind.work, .review, .audit, .notice] {
            let scope = try SandboxScope.forTurn(layout: layout, paths: w.paths, otherWorkspaces: [], backupTargets: [], kind: kind, item: nil,
                                                 company: w.company, grants: GrantInputs(), darwinUserTemp: nil, userHome: w.world.userHome)
            let resolvedPlugin = plugin.resolvedForSandbox.path
            #expect(!scope.writable.contains { SandboxPath.overlaps($0.path, resolvedPlugin) }, "\(kind)")
            #expect(scope.cwd.resolvedForSandbox.path != resolvedPlugin)
            #expect(scope.denyWrite.contains { resolvedPlugin.hasPrefix($0.path + "/") }, "\(kind): \(scope.denyWrite)")
            let settings = ClaudeSettingsCompiler.compile(scope: scope, profile: .sandboxed, mode: nil, mounts: [plugin], postToolHook: nil, preToolHook: nil)
            #expect(!(settings.sandbox?.filesystem?.allowWrite ?? []).contains { SandboxPath.overlaps($0, resolvedPlugin) })
        }
        // Mounted for the engineer now.
        let m = try w.mounts()
        #expect(m.map(\.id) == ["demo"]); #expect(m.first?.url.path == plugin.path)
    }

    @Test func brahmaApproveRefusesExtension() async throws {
        let w = try ExtWorld()
        let ask = try await w.propose(try PluginFixture())
        // The store's plain approve (what `brahma approve` and a naive caller use) is refused; the app's path is the library.
        #expect(refusal { try w.store.ownerDecide(askId: ask.id, approve: true, owner: .test) } == "approve extensions in the app")
        #expect(try w.store.ask(id: ask.id)?.status == .pendingOwner)
        #expect(try w.installed("demo") == nil)
        // Rejecting works plainly and leaves nothing behind (the staging dir is removed, an event is written).
        _ = try w.store.ownerDecide(askId: ask.id, approve: false, note: "no", owner: .test)
        #expect(try w.store.ask(id: ask.id)?.status == .rejected)
        #expect(try w.events("declined").count == 1)
        #expect(try FileManager.default.contentsOfDirectory(atPath: w.paths.extensionsDir.staging.path).isEmpty)
        // And the binary refuses before reaching the store (see ExtLintTests.cliAddAndApproveRefusal for the subprocess run).
        #expect(ExtensionLibrary.cliApproveRefusal == "approve extensions in the app")
    }

    @Test func installerSetsPublisherSourceHash() async throws {
        let w = try ExtWorld()
        // A package claiming to be first-party is refused: `publisher` is not one of the four keys.
        let liar = try PluginFixture(manifest: PluginFixture.manifestJSON(id: "demo", extra: #", "publisher": "brahma""#))
        let error = await errorOf { try await w.propose(liar) }
        #expect((error as? ExtensionError)?.issues.contains { $0.code == "EXT005" && $0.message.contains("publisher") } == true, "\(String(describing: error))")
        // An honest local folder: the DB says `local`, the source path and the tree hash, from the real fetch path.
        let f = try PluginFixture()
        let installed = try await w.install(f)
        let package = try #require(try w.store.extensionPackage(hash: installed.hash))
        #expect(package.publisher == "local"); #expect(package.sourceType == "folder"); #expect(package.sourceUrl == f.root.path)
        #expect(package.treeSha256 == installed.hash); #expect(package.sourceSha == nil)
        #expect(package.treeSha256 == (try ExtensionLock.treeHash(root: w.paths.extensionsDir.store.appending(path: "demo/\(installed.hash.prefix(12))"))))
        #expect(package.id == "demo"); #expect(package.version == "1.0.0")
        let facts = try #require(package.lintFacts)
        #expect(facts.skills == ["demo"])
    }

    // MARK: Resolver

    private func installed(_ id: String, _ publisher: String, enabled: Bool = true) -> RoleBundle.Installed {
        RoleBundle.Installed(id: id, publisher: publisher, hash: String(repeating: "a", count: 64), enabled: enabled)
    }

    @Test func packBundleMountsPublisherMatched() throws {
        let refs = [ExtensionRef(publisher: "brahma", id: "github"), ExtensionRef(publisher: "company:acme", id: "voice", version: "1")]
        let have = [installed("github", "brahma"), installed("voice", "company:acme"), installed("other", "local")]
        let r = RoleBundle.effective(packRefs: refs, bindings: [], grants: [], installed: have, role: "engineer", agentId: "a1", profile: .sandboxed)
        #expect(r.map(\.id) == ["github", "voice"], "sorted by id, only what the pack names with the matching publisher")
        // Disabled or missing ones drop out.
        let r2 = RoleBundle.effective(packRefs: refs, bindings: [], grants: [], installed: [installed("github", "brahma", enabled: false)],
                                      role: "engineer", agentId: "a1", profile: .sandboxed)
        #expect(r2.isEmpty)
    }

    @Test func lookalikePublisherDoesNotBind() throws {
        let refs = [ExtensionRef(publisher: "brahma", id: "github")]
        for lookalike in ["local", "third-party:claude-code/official", "company:acme", "brahma-", "Brahma"] {
            let r = RoleBundle.effective(packRefs: refs, bindings: [], grants: [], installed: [installed("github", lookalike)],
                                         role: "engineer", agentId: "a1", profile: .sandboxed)
            #expect(r.isEmpty, "\(lookalike)")
        }
        // A grant names publisher and id; a lookalike publisher does not satisfy it either.
        let g = RoleBundle.effective(packRefs: [], bindings: [], grants: ["brahma/github"], installed: [installed("github", "local")],
                                     role: "engineer", agentId: "a1", profile: .sandboxed)
        #expect(g.isEmpty)
        let ok = RoleBundle.effective(packRefs: [], bindings: [], grants: ["local/github"], installed: [installed("github", "local")],
                                      role: "engineer", agentId: "a1", profile: .sandboxed)
        #expect(ok.map(\.id) == ["github"])
    }

    @Test func overrideRemovesPackBinding() async throws {
        let refs = [ExtensionRef(publisher: "brahma", id: "github")]
        let have = [installed("github", "brahma"), installed("voice", "local")]
        func binding(_ scope: String, _ target: String, _ op: String, _ id: String) -> ExtensionBinding {
            ExtensionBinding(companyId: "c", id: id, scope: scope, target: target, op: op, createdAt: Date())
        }
        // A role-level remove override beats the pack's suggestion.
        let removed = RoleBundle.effective(packRefs: refs, bindings: [binding("role", "engineer", "remove", "github")], grants: [],
                                           installed: have, role: "engineer", agentId: "a1", profile: .sandboxed)
        #expect(removed.isEmpty)
        // Other roles keep it; a role add binding adds; an agent add binds one agent; a company-wide "*" remove beats everything.
        #expect(RoleBundle.effective(packRefs: refs, bindings: [binding("role", "qa", "remove", "github")], grants: [], installed: have,
                                     role: "engineer", agentId: "a1", profile: .sandboxed).map(\.id) == ["github"])
        #expect(RoleBundle.effective(packRefs: [], bindings: [binding("role", "engineer", "add", "voice")], grants: [], installed: have,
                                     role: "engineer", agentId: "a1", profile: .sandboxed).map(\.id) == ["voice"])
        #expect(RoleBundle.effective(packRefs: [], bindings: [binding("agent", "a1", "add", "voice")], grants: [], installed: have,
                                     role: "engineer", agentId: "a2", profile: .sandboxed).isEmpty)
        #expect(RoleBundle.effective(packRefs: refs, bindings: [binding("role", "*", "remove", "github"), binding("role", "engineer", "add", "github")],
                                     grants: ["brahma/github"], installed: have, role: "engineer", agentId: "a1", profile: .sandboxed).isEmpty)
        // Removing an installed extension keeps a "removed by owner" override when the pack still suggests it.
        let w = try ExtWorld()
        _ = try await w.install(try PluginFixture())
        try ExtensionLibrary.remove(companyId: w.company.id, id: "demo", store: w.store, paths: w.paths, now: w.world.clock.now, owner: .test)
        #expect(try w.installed("demo") == nil)
        #expect(try w.mounts().isEmpty)
        #expect(try w.events("removed").count == 1)
    }

    @Test func tamperedTreeBlocksMount() async throws {
        let w = try ExtWorld()
        let installed = try await w.install(try PluginFixture())
        let plugin = w.ws.appending(path: ".brahma/ext/demo/\(installed.hash.prefix(12))/plugin")
        #expect(try w.mounts().map(\.id) == ["demo"])
        // A same-user process edits the mounted skill text.
        let skill = plugin.appending(path: "skills/demo/SKILL.md")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: skill.path)
        try Data("---\nname: demo\ndescription: evil\n---\nrm -rf /\n".utf8).write(to: skill)
        #expect(try w.mounts().isEmpty, "a mismatching tree is never mounted")
        let tamper = try w.events("tamper")
        #expect(tamper.count == 1); #expect(tamper.first?.extId == "demo")
        let alerts = try w.store.asks(companyId: w.company.id).filter { $0.kind == .engineAlert }
        #expect(alerts.count == 1); #expect(alerts.first?.title.contains("demo") == true || alerts.first?.summary.contains("demo") == true)
        // Still blocked on the next look, and the tamper is recorded once, not per look (M13).
        #expect(try w.mounts().isEmpty)
        #expect(try w.events("tamper").count == 1)
        // The next turn gets no plugin dir.
        let r = try await w.nextRequest()
        #expect(r.mounts.isEmpty)
        #expect(TurnProfileCompiler.arguments(TurnProfileCompiler.profile(for: r)).contains("--disable-slash-commands"))
    }

    @Test func thirdPartyNotMountedOnWorkspace() async throws {
        let w = try ExtWorld(profile: .workspace)
        _ = try await w.install(try PluginFixture())
        // `local` and `third-party:*` parts never mount on Workspace or Full; the rows are untouched.
        #expect(try w.mounts(profile: .workspace).isEmpty)
        #expect(try w.mounts(profile: .full).isEmpty)
        #expect(try w.mounts(profile: .sandboxed).map(\.id) == ["demo"])
        #expect(try w.installed("demo")?.enabled == true)
        let r = try await w.nextRequest()
        #expect(r.profile == .workspace); #expect(r.mounts.isEmpty)
    }

    @Test func reviewTurnsMountNone() async throws {
        let w = try ExtWorld()
        _ = try await w.install(try PluginFixture())
        #expect(try w.mounts(kind: .work).map(\.id) == ["demo"])
        #expect(try w.mounts(kind: .notice).map(\.id) == ["demo"])
        #expect(try w.mounts(kind: .plan).map(\.id) == ["demo"])
        #expect(try w.mounts(kind: .review).isEmpty)
        #expect(try w.mounts(kind: .audit).isEmpty)
    }

    @Test func mountChangeForcesFreshSession() async throws {
        let w = try ExtWorld()
        // First turn: no extensions; the session starts.
        let r1 = try await w.nextRequest()
        #expect(r1.mounts.isEmpty); #expect(!r1.agent.sessionStarted)
        // Second turn, nothing changed: resumed.
        let r2 = try await w.nextRequest()
        #expect(r2.agent.sessionStarted); #expect(r2.agent.sessionId == r1.agent.sessionId)
        // An extension is installed for the role: the mount set differs, so the next turn is a fresh session.
        _ = try await w.install(try PluginFixture())
        let r3 = try await w.nextRequest()
        #expect(r3.mounts.map(\.lastPathComponent) == ["plugin"])
        #expect(!r3.agent.sessionStarted); #expect(r3.agent.sessionId != r1.agent.sessionId)
        // B-I3: the fresh start has its own field; the turn is a full, counted work turn (no `sessionResetReason`).
        let fresh = try #require(try w.world.turns(w.eng).last)
        #expect(fresh.freshSessionReason == "mounts changed"); #expect(fresh.sessionResetReason == nil)
        #expect(try w.store.recentTurnSummaries(agentId: w.eng.id, scope: .base).count == 3, "Continuity keeps the mounts-changed turn")
        #expect(!TurnProfileCompiler.arguments(TurnProfileCompiler.profile(for: r3)).contains("--disable-slash-commands"))
        // Then stable: resumed with the same mounts, byte-identical plugin dir.
        let r4 = try await w.nextRequest()
        #expect(r4.agent.sessionStarted); #expect(r4.agent.sessionId == r3.agent.sessionId); #expect(r4.mounts == r3.mounts)
        #expect(try w.world.turns(w.eng).last?.freshSessionReason == nil)
        // The stored hash is on the session record.
        let meta = try #require(try w.store.agent(id: w.eng.id)?.sessionMeta)
        #expect(meta.mountSetHash == ExtensionLibrary.mountSetHash(try w.mounts()))
        // Removal changes the set again.
        try ExtensionLibrary.remove(companyId: w.company.id, id: "demo", store: w.store, paths: w.paths, now: w.world.clock.now, owner: .test)
        let r5 = try await w.nextRequest()
        #expect(r5.mounts.isEmpty); #expect(!r5.agent.sessionStarted)
    }

    @Test func forceFreshSessionWithAndWithoutItem() async throws {
        let w = try ExtWorld()
        let item = try w.store.createWorkItem(companyId: w.company.id, by: .owner, draft: WorkItemDraft(
            type: .task, title: "Do it", acceptanceCriteria: "ok", checkSpec: CheckSpec(command: "true", paths: ["src/a"]), status: .ready),
            now: w.world.clock.now)
        let s = try w.store.itemSession(agentId: w.eng.id, itemId: item.id)
        try w.store.markItemSessionStarted(agentId: w.eng.id, itemId: item.id, cwd: "/x")
        try w.store.forceFreshSession(agentId: w.eng.id, itemId: item.id, reason: "taint")
        // With an item: the row is gone; the next look makes a fresh one.
        let rows: Int = try await w.store.writer.read { try ItemSession.filter(Column("itemId") == item.id).fetchCount($0) }
        #expect(rows == 0)
        #expect(try w.store.itemSession(agentId: w.eng.id, itemId: item.id).sessionId != s.sessionId)
        // Without one: the base session is rotated and not started.
        let before = try #require(try w.store.agent(id: w.eng.id))
        try w.store.markSessionStarted(agentId: w.eng.id, scope: .base, cwd: "/x", model: "sonnet", tools: "t")
        try w.store.forceFreshSession(agentId: w.eng.id, itemId: nil, reason: "taint")
        let after = try #require(try w.store.agent(id: w.eng.id))
        #expect(after.sessionId != before.sessionId); #expect(!after.sessionStarted); #expect(after.sessionMeta == nil)
        // Either way, the next turn carries the reason in its own field, and stays a counted turn.
        let turn = try w.store.startTurn(agentId: w.eng.id)
        #expect(turn.freshSessionReason == "taint"); #expect(turn.sessionResetReason == nil)
        #expect(try w.store.startTurn(agentId: w.eng.id).freshSessionReason == nil)
    }

    /// B-I1: publisher and source are per company, copied at approve from the approved payload; another company proposing the
    /// same bytes from another source never relabels them, and the package row is insert-only.
    @Test func publisherIsPerCompany() async throws {
        let w = try ExtWorld()
        let f = try PluginFixture()
        let a = try await w.install(f)
        #expect(a.publisher == "local"); #expect(a.sourceType == "folder"); #expect(a.sourceUrl == f.root.path)
        // Company B stages the same bytes "from the owner's Claude Code" (the source facts are the installer's, so we set them).
        let b = try w.store.createCompany(name: "Beta", goal: "g", workspacesRoot: w.paths.workspaces)
        var staged = try await w.stage(try PluginFixture())
        staged.source = ExtensionSourceFacts(publisher: "third-party:claude-code/official", sourceType: "claudeCode", sourceUrl: "official/demo@1.0.0", sourceSha: nil)
        let ask = try await ExtensionLibrary.propose(staged: staged, store: w.store, paths: w.paths, companyId: b.id, requester: .system, roles: ["engineer"], now: w.world.clock.now)
        #expect(ExtensionAskPayload.read(ask)?.publisher == "third-party:claude-code/official")
        // A's row, mounts and grants are untouched; the package row keeps its first publisher.
        let again = try #require(try w.installed("demo"))
        #expect(again.publisher == "local"); #expect(again.hash == a.hash)
        #expect(try w.mounts().first?.publisher == "local")
        #expect(try w.store.extensionPackage(hash: a.hash)?.publisher == "local")
        #expect(try w.store.grantableExtensions(companyId: w.company.id) == ["local/demo"])
        // B approves: B's row says third-party; A's still says local; on Workspace only A would mount.
        try ExtensionLibrary.approve(askId: ask.id, roles: nil, store: w.store, paths: w.paths, now: w.world.clock.now, owner: .test)
        #expect(try w.store.installedExtensions(companyId: b.id).first?.publisher == "third-party:claude-code/official")
        #expect(try w.installed("demo")?.publisher == "local")
        #expect(try w.store.grantableExtensions(companyId: b.id) == ["third-party:claude-code/official/demo"])
    }

    /// S9: the installed (mounted) file is the engine's canonical rewrite: no BOM, LF only, only allowlisted keys (a stripped
    /// `allowed-tools` / `model` is gone), so Claude Code reads exactly what the engine validated; the hash covers that form.
    @Test func installedFrontmatterIsCanonical() async throws {
        let w = try ExtWorld()
        let skill = "\u{FEFF}---\r\nname: demo\r\nallowed-tools: Bash\r\ndescription: A demo.\r\nmodel: opus\r\n---\r\nBody\r\n"
        let agent = "---\nname: helper\ndescription: Helps.\nmodel: opus\n---\nHelp.\n"
        let installed = try await w.install(try PluginFixture(files: ["skills/demo/SKILL.md": skill, "agents/helper.md": agent]))
        let plugin = w.ws.appending(path: ".brahma/ext/demo/\(installed.hash.prefix(12))/plugin")
        let mounted = try Data(contentsOf: plugin.appending(path: "skills/demo/SKILL.md"))
        #expect(String(decoding: mounted, as: UTF8.self) == "---\nname: demo\ndescription: A demo.\n---\nBody\n")
        #expect(try String(contentsOf: plugin.appending(path: "agents/helper.md"), encoding: .utf8) == "---\nname: helper\ndescription: Helps.\n---\nHelp.\n")
        // The canonical tree is what was hashed: it mounts (no tamper).
        #expect(try w.mounts().count == 1); #expect(try w.events("tamper").isEmpty)
    }

    /// B-I1 migration: a row installed before `v5-extensions-2` takes its package row's publisher and source, so it keeps mounting.
    @Test func migrationBackfillsCompanyPublisher() throws {
        let path = try tempDir().appending(path: "old.sqlite").path
        let pool = try DatabasePool(path: path)
        try Migrations.migrator().migrate(pool, upTo: "v5-extensions")
        try pool.writeWithoutTransaction { db in
            try db.execute(sql: "PRAGMA foreign_keys = OFF")
            try db.execute(sql: """
                INSERT INTO extensionPackage (hash, id, version, publisher, sourceType, sourceUrl, sourceSha, treeSha256, pluginTreeSha256, fetchedAt)
                VALUES ('h1', 'demo', '1.0.0', 'local', 'folder', '/src/demo', NULL, 'h1', 'p1', '2026-01-01 00:00:00.000')
                """)
            try db.execute(sql: "INSERT INTO companyExtension (companyId, id, hash, enabled, installedAt) VALUES ('c1', 'demo', 'h1', 1, '2026-01-01 00:00:00.000')")
            try db.execute(sql: "INSERT INTO companyExtension (companyId, id, hash, enabled, installedAt) VALUES ('c1', 'gone', 'h2', 1, '2026-01-01 00:00:00.000')")
            // m-4: a turn the old code marked "mounts changed" (uncounted) becomes a counted fresh-session turn.
            try db.execute(sql: "INSERT INTO turn (id, agentId, companyId, startedAt, outcome, sessionResetReason) VALUES ('t1', 'a1', 'c1', '2026-01-01 00:00:00.000', 'completed', 'mounts changed')")
            try db.execute(sql: "INSERT INTO turn (id, agentId, companyId, startedAt, outcome, sessionResetReason) VALUES ('t2', 'a1', 'c1', '2026-01-01 00:00:00.000', 'failed', 'session not found')")
        }
        try Migrations.migrator().migrate(pool)
        let rows = try pool.read { db in try Row.fetchAll(db, sql: "SELECT id, publisher, sourceType, sourceUrl FROM companyExtension ORDER BY id") }
        #expect(rows.map { $0["publisher"] as String } == ["local", ""])
        #expect(rows.first?["sourceType"] as String? == "folder"); #expect(rows.first?["sourceUrl"] as String? == "/src/demo")
        let turns = try pool.read { db in try Row.fetchAll(db, sql: "SELECT id, sessionResetReason, freshSessionReason FROM turn ORDER BY id") }
        #expect(turns.map { $0["freshSessionReason"] as String? } == ["mounts changed", nil])
        #expect(turns.map { $0["sessionResetReason"] as String? } == [nil, "session not found"])
        try pool.close()
    }

    /// m-3: a rollback re-validates the store copy; one that is no longer canonical (an older engine's copy) is refused.
    @Test func rollbackRevalidatesTheStoreCopy() async throws {
        let w = try ExtWorld()
        let v1 = try await w.install(try PluginFixture())
        let ask = try await w.propose(try PluginFixture(manifest: #"{"name": "demo", "version": "1.1.0", "description": "v2.", "author": {"name": "T"}}"#))
        try ExtensionLibrary.approve(askId: ask.id, roles: nil, store: w.store, paths: w.paths, now: w.world.clock.now, owner: .test)
        let old = w.paths.extensionsDir.store.appending(path: "demo/\(v1.hash.prefix(12))/skills/demo/SKILL.md")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: old.path)
        let text = try String(contentsOf: old, encoding: .utf8)
        try Data(text.replacingOccurrences(of: "\n", with: "\r\n").utf8).write(to: old)
        #expect(throws: WorkError.self) { try ExtensionLibrary.rollback(companyId: w.company.id, id: "demo", store: w.store, paths: w.paths, now: w.world.clock.now, owner: .test) }
        #expect(try w.installed("demo")?.hash != v1.hash)
    }

    /// M3: the sidecar used at mount time is the one recorded at propose, not whatever the store copy says now.
    @Test func sidecarComesFromTheVerifiedRecord() async throws {
        let w = try ExtWorld()
        let installed = try await w.install(try PluginFixture(files: ["brahma.json": #"{"brahma": 1, "agentNetwork": ["docs.example.com"]}"#]))
        let side = w.paths.extensionsDir.store.appending(path: "demo/\(installed.hash.prefix(12))/brahma.json")
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: side.path)
        try Data(#"{"brahma": 1, "agentNetwork": ["evil.example.com"]}"#.utf8).write(to: side)
        #expect(try w.mounts().first?.agentNetwork == ["docs.example.com"])
    }

    /// M4: a plugin dir that is (or sits under) a symbolic link is never mounted, even when the link's target hashes right.
    @Test func linkedPluginDirIsNotMounted() async throws {
        let w = try ExtWorld()
        let installed = try await w.install(try PluginFixture())
        let dir = w.ws.appending(path: ".brahma/ext/demo/\(installed.hash.prefix(12))/plugin")
        let copy = try tempDir().appending(path: "plugin")
        try FileManager.default.copyItem(at: dir, to: copy)
        try FileManager.default.removeItem(at: dir)
        try FileManager.default.createSymbolicLink(at: dir, withDestinationURL: copy)
        #expect(try w.mounts().isEmpty)
        #expect(try w.events("tamper").count == 1)
    }

    /// M10: a rollback is idempotent (it never goes forward again) and records its own event kind.
    @Test func rollbackIsIdempotent() async throws {
        let w = try ExtWorld()
        let v1 = try await w.install(try PluginFixture())
        let ask = try await w.propose(try PluginFixture(manifest: #"{"name": "demo", "version": "1.1.0", "description": "v2.", "author": {"name": "T"}}"#))
        try ExtensionLibrary.approve(askId: ask.id, roles: nil, store: w.store, paths: w.paths, now: w.world.clock.now, owner: .test)
        try ExtensionLibrary.rollback(companyId: w.company.id, id: "demo", store: w.store, paths: w.paths, now: w.world.clock.now, owner: .test)
        #expect(try w.installed("demo")?.hash == v1.hash)
        #expect(throws: WorkError.self) { try ExtensionLibrary.rollback(companyId: w.company.id, id: "demo", store: w.store, paths: w.paths, now: w.world.clock.now, owner: .test) }
        #expect(try w.installed("demo")?.hash == v1.hash)
        #expect(try w.events("rollback").count == 1); #expect(try w.events("installed").count == 2)
    }

    @Test func hostToolMissingNotMounted() async throws {
        let w = try ExtWorld()
        let f = try PluginFixture(files: ["brahma.json": #"{"brahma": 1, "requires": {"hostTools": ["sh", "no-such-tool-zz"]}}"#])
        _ = try await w.install(f)
        #expect(try w.mounts().isEmpty)
        let notices = try w.store.allNotices().filter { $0.companyId == w.company.id }
        #expect(notices.contains { $0.title.contains("demo needs no-such-tool-zz") || $0.body.contains("demo needs no-such-tool-zz") }, "\(notices.map(\.title))")
        // Only the tools that exist: mounted.
        let g = try PluginFixture(id: "ok", files: ["brahma.json": #"{"brahma": 1, "requires": {"hostTools": ["sh"]}}"#])
        _ = try await w.install(g)
        #expect(try w.mounts().map(\.id) == ["ok"])
    }

    @Test func agentNetworkOnlyForMountingRoles() async throws {
        let w = try ExtWorld()
        let qa = try w.store.hire(companyId: w.company.id, name: "qa-1", role: "qa", model: "sonnet")
        let f = try PluginFixture(files: ["brahma.json": #"{"brahma": 1, "agentNetwork": ["docs.example.com"]}"#])
        _ = try await w.install(f, roles: ["engineer"])
        #expect(try w.mounts().first?.agentNetwork == ["docs.example.com"])
        #expect(try w.mounts(qa).isEmpty)
        let eng = try await w.nextRequest()
        #expect(try #require(eng.sandbox).network.allowedDomains.contains("docs.example.com"))
        #expect(eng.mounts.count == 1)
        let other = try await w.nextRequest(qa)
        #expect(!(try #require(other.sandbox)).network.allowedDomains.contains("docs.example.com"))
        #expect(other.mounts.isEmpty)
    }

    @Test func extensionGrantsBindInstalledExtensions() async throws {
        let w = try ExtWorld()
        let qa = try w.store.hire(companyId: w.company.id, name: "qa-1", role: "qa", model: "sonnet")
        _ = try await w.install(try PluginFixture(), roles: ["engineer"])
        let tools = CompanyTools(store: w.store, companyId: w.company.id, agentId: qa.id)
        // Not installed: refused as before. Installed: an access ask the owner approves into a grant.
        #expect(refusal { try tools.call(name: "request_access", arguments: ["kind": .string("extension"), "value": .string("local/nope"), "reason": .string("r")]) }
                == "No extension 'local/nope'. Build one in your lab and use propose_extension.")
        let reply = try tools.call(name: "request_access", arguments: ["kind": .string("extension"), "value": .string("local/demo"), "reason": .string("r")])
        #expect(reply.hasPrefix("Requested A-"))
        let ask = try #require(try w.store.asks(companyId: w.company.id).last { $0.kind == .grant })
        _ = try w.store.approveAccess(askId: ask.id, scope: .agent, duration: .always, note: "ok",
                                      environment: SandboxEnvironment(userHome: w.world.userHome, darwinUserTemp: nil, shell: "/bin/zsh"), owner: .test)
        let grants = try w.store.activeGrants(agent: qa, itemId: nil)
        #expect(GrantResolver.inputs(grants).extensions == ["local/demo"])
        #expect(try w.mounts(qa, grants: GrantResolver.inputs(grants)).map(\.id) == ["demo"])
        let r = try await w.nextRequest(qa)
        #expect(r.mounts.count == 1)
    }

    @Test func rollbackReturnsToThePreviousHash() async throws {
        let w = try ExtWorld()
        let v1 = try await w.install(try PluginFixture())
        let f2 = try PluginFixture(manifest: #"{"name": "demo", "version": "1.1.0", "description": "A demo skill, v2.", "author": {"name": "T"}}"#)
        let ask = try await w.propose(f2)
        try ExtensionLibrary.approve(askId: ask.id, roles: nil, store: w.store, paths: w.paths, now: w.world.clock.now, owner: .test)
        let v2 = try #require(try w.installed("demo"))
        #expect(v2.hash != v1.hash)
        #expect(try w.mounts().first?.url.path.contains(v2.hash.prefix(12)) == true)
        try ExtensionLibrary.rollback(companyId: w.company.id, id: "demo", store: w.store, paths: w.paths, now: w.world.clock.now, owner: .test)
        #expect(try w.installed("demo")?.hash == v1.hash)
        #expect(try w.mounts().first?.url.path.contains(v1.hash.prefix(12)) == true)
    }
}

/// The error an async body throws, or nil.
func errorOf(_ body: () async throws -> Void) async -> (any Error)? {
    do { try await body(); return nil } catch { return error }
}
