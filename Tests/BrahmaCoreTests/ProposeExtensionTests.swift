import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Task 10b: an agent proposes an extension it built in its lab (`propose_extension`), with lab provenance; the built-in
/// `extension-authoring` skill and `brahma-workers` agents.
private struct LabWorld {
    let world: World
    let company: Company
    let eng: Agent
    let cto: Agent

    init(profile: PermissionProfile = .sandboxed, withCTO: Bool = true) throws {
        world = try World()
        company = try world.company("Acme", profile: profile)
        cto = try world.store.hire(companyId: company.id, name: "cto", role: "cto", model: "sonnet")
        if !withCTO { _ = try world.store.transition(agentId: cto.id, to: .killed) }
        eng = try world.store.hire(companyId: company.id, name: "eng-1", role: "engineer", model: "sonnet")
        try SandboxLayout(paths: world.paths, company: company, agentHandle: eng.name).ensure()
    }

    var store: Store { world.store }
    var paths: BrahmaPaths { world.paths }
    var ws: URL { URL(fileURLWithPath: company.workspacePath, isDirectory: false).resolvedForSandbox }
    var lab: URL { ws.appending(path: ".brahma/labs/\(eng.name)", directoryHint: .isDirectory) }

    func tools(_ a: Agent? = nil) -> CompanyTools {
        CompanyTools(store: store, companyId: company.id, agentId: (a ?? eng).id, paths: paths)
    }

    /// Writes a plugin fixture into the lab at `<lab>/<folder>` and commits it.
    @discardableResult
    func commitPlugin(id: String = "brand-voice", folder: String? = nil, files: [String: String] = [:], message: String = "add") throws -> String {
        let fixture = try PluginFixture(id: id, files: files, under: lab)
        if let folder, folder != id {
            try FileManager.default.moveItem(at: fixture.root, to: lab.appending(path: folder))
        }
        try GitFixture.plainGit(["add", "-A"], in: lab)
        try GitFixture.plainGit(["commit", "-qm", message], in: lab)
        return try GitFixture.plainGit(["rev-parse", "HEAD"], in: lab)
    }

    /// Turn-end provenance as the orchestrator records it.
    func recordLab(tainted: Bool) {
        _ = LabProvenance.record(store: store, workspace: ws, handle: eng.name, companyId: company.id, agentId: eng.id, turnId: nil,
                                 tainted: tainted, now: world.clock.now)
    }

    func propose(_ args: [String: JSONValue]) throws -> String {
        try tools().call(name: "propose_extension", arguments: args)
    }

    func refusal(_ args: [String: JSONValue], as a: Agent? = nil) -> String? {
        do { _ = try tools(a).call(name: "propose_extension", arguments: args); return nil } catch let e as ToolError {
            return e.message
        } catch { return "\(error)" }
    }

    static func args(_ path: String, roles: [String] = ["engineer"], summary: String = "House tone for copy.") -> [String: JSONValue] {
        ["path": .string(path), "summary": .string(summary), "roles": .array(roles.map { .string($0) })]
    }

    func extensionAsks() throws -> [Ask] { try store.asks(companyId: company.id).filter { $0.kind == .extension } }
}

@Suite(.scratch) struct ProposeExtensionTests {
    @Test func proposeOutsideLabRefused() throws {
        let w = try LabWorld()
        try w.commitPlugin()
        let message = "propose_extension takes a folder in your lab"
        for path in ["../eng-2/brand-voice", "/etc", w.ws.appending(path: "src").path, "brand-voice/../../x", "",
                     w.ws.appending(path: ".brahma/labs/cto/brand-voice").path, ".git", "brand voice"] {
            let got = w.refusal(LabWorld.args(path))
            #expect(got?.contains(message) == true || got?.contains("must not be empty") == true, "\(path): \(got ?? "accepted")")
        }
        #expect(try w.extensionAsks().isEmpty)
        // The absolute path of a folder in the caller's own lab is accepted.
        let reply = try w.propose(LabWorld.args(w.lab.appending(path: "brand-voice").path))
        #expect(reply.hasPrefix("Proposed A-"), "\(reply)")
    }

    @Test func proposeLintFailureReturnsJsonNoAsk() throws {
        let w = try LabWorld()
        // An error (an MCP server) and, separately, a warning-only package: "lint clean" refuses both.
        try w.commitPlugin(files: [".mcp.json": #"{"mcpServers": {}}"#])
        let got = try #require(w.refusal(LabWorld.args("brand-voice")))
        #expect(got.contains("brahma ext lint --json"), "\(got)")
        #expect(got.contains("\"code\" : \"EXT002\"") || got.contains("\"code\":\"EXT002\""), "\(got)")
        // The JSON is quoted: every line of the list is prefixed.
        let listed = got.split(separator: "\n").drop { !$0.hasPrefix("    | ") }
        #expect(!listed.isEmpty && listed.allSatisfy { $0.hasPrefix("    | ") }, "\(got)")
        #expect(try w.extensionAsks().isEmpty)
        #expect(((try? FileManager.default.contentsOfDirectory(atPath: w.paths.extensionsDir.staging.path)) ?? []).isEmpty, "staging cleaned")
        try FileManager.default.removeItem(at: w.lab.appending(path: "brand-voice/.mcp.json"))
        try w.commitPlugin(id: "brand-voice", files: ["skills/brand-voice/SKILL.md": PluginFixture.skillMD(
            name: "brand-voice", frontmatter: "allowed-tools: Bash")], message: "warn")
        let warned = try #require(w.refusal(LabWorld.args("brand-voice")))
        #expect(warned.contains("EXT011"), "\(warned)")
        #expect(try w.extensionAsks().isEmpty)
    }

    @Test func proposeCreatesReservedExtensionAsk() throws {
        let w = try LabWorld()
        let head = try w.commitPlugin()
        w.recordLab(tainted: false)
        let reply = try w.propose(LabWorld.args("brand-voice", roles: ["engineer", "qa"]))
        let ask = try #require(try w.extensionAsks().first)
        #expect(reply == "Proposed \(ask.ref) (brand-voice). @cto reviews it, then the owner decides. Drafts are never mounted before approval.")
        #expect(ask.kind == .extension); #expect(ask.risk == .high); #expect(ask.category == "prompt-change")
        #expect(ask.requesterId == w.eng.id)
        #expect(ask.status == .pendingInternal); #expect(ask.internalApproverId == w.cto.id)
        #expect(ask.summary == "House tone for copy.")
        #expect(ask.payload?.documentPath == ".brahma/ext-review/\(ask.ref).md")
        let p = try #require(ExtensionAskPayload.read(ask))
        #expect(p.action == "install"); #expect(p.extId == "brand-voice"); #expect(p.roles == ["engineer", "qa"])
        #expect(p.publisher == "company:\(w.company.slug)")
        #expect(p.sourceType == "lab"); #expect(p.sourceSha == head); #expect(p.taintedCommits == [])
        // The staged tree is HEAD's snapshot: a later uncommitted edit in the lab is not in it.
        let staged = try #require(p.stagedPath)
        #expect(FileManager.default.fileExists(atPath: staged + "/skills/brand-voice/SKILL.md"))
        // The cto is told; AskQuota counts it.
        #expect(try w.store.pendingInbox(agentId: w.cto.id).contains { $0.1.text.contains(ask.ref) })
        // With no internal reviewer it goes straight to the owner.
        let solo = try LabWorld(withCTO: false)
        try solo.commitPlugin()
        solo.recordLab(tainted: false)
        let soloReply = try solo.propose(LabWorld.args("brand-voice"))
        #expect(soloReply.contains("the owner decides"), "\(soloReply)")
        #expect(try solo.extensionAsks().first?.status == .pendingOwner)
    }

    @Test func internalApprovalStillNeedsOwner() throws {
        let w = try LabWorld()
        try w.commitPlugin()
        w.recordLab(tainted: false)
        _ = try w.propose(LabWorld.args("brand-voice"))
        let ask = try #require(try w.extensionAsks().first)
        // The cto's turn may read exactly that review page (B-M9), and nobody else's turn reads it.
        let page = w.ws.appending(path: ".brahma/ext-review/\(ask.ref).md")
        #expect(try w.store.extensionReviewPages(reviewerId: w.cto.id) == [".brahma/ext-review/\(ask.ref).md"])
        #expect(try w.store.extensionReviewPages(reviewerId: w.eng.id).isEmpty)
        let ctoScope = try scope(w, w.cto, pages: try w.store.extensionReviewPages(reviewerId: w.cto.id).map { w.ws.appending(path: $0) })
        #expect(ctoScope.readable.map(\.path).contains(page.path))
        let engScope = try scope(w, w.eng, pages: [])
        #expect(!engScope.readable.contains { $0.path.contains("ext-review") })
        // Approving internally moves it on to the owner: prompt-change is reserved, never auto-approved.
        // The cto decides with its own `decide` tool (high risk: its session is clean).
        let reply = try w.tools(w.cto).call(name: "decide", arguments: ["ask": .string(ask.ref), "approve": .bool(true),
                                                                         "note": .string("looks fine")])
        #expect(reply == "\(ask.ref) approved by you; it now waits for the owner's decision.")
        #expect(try w.store.ask(id: ask.id)?.status == .pendingOwner)
        #expect(try w.store.installedExtensions(companyId: w.company.id).isEmpty)
        // Even under the most permissive preset.
        var c = try #require(try w.store.company(id: w.company.id))
        c.autonomy = .auto
        try w.store.updateCompany(c)
        try w.commitPlugin(id: "tone-two")
        w.recordLab(tainted: false)
        _ = try w.propose(LabWorld.args("tone-two"))
        let second = try #require(try w.extensionAsks().first { ExtensionAskPayload.read($0)?.extId == "tone-two" })
        #expect(try w.store.internalDecide(askId: second.id, by: .agent(w.cto.id), approve: true, note: "").status == .pendingOwner)
        // The owner's approval installs it as the company's own.
        try ExtensionLibrary.approve(askId: ask.id, roles: nil, store: w.store, paths: w.paths, now: w.world.clock.now)
        let installed = try #require(try w.store.installedExtensions(companyId: w.company.id).first { $0.id == "brand-voice" })
        #expect(installed.publisher == "company:\(w.company.slug)"); #expect(installed.sourceType == "lab")
        #expect(!installed.provenanceTainted)
    }

    private func scope(_ w: LabWorld, _ a: Agent, pages: [URL]) throws -> SandboxScope {
        try SandboxLayout(paths: w.paths, company: w.company, agentHandle: a.name).ensure()
        return try SandboxScope.forTurn(layout: SandboxLayout(paths: w.paths, company: w.company, agentHandle: a.name), paths: w.paths,
                                        otherWorkspaces: [], backupTargets: [], kind: .work, item: nil, company: w.company,
                                        grants: GrantInputs(), darwinUserTemp: nil, userHome: w.world.userHome, reviewPages: pages)
    }

    @Test func taintedCommitsListed() throws {
        let w = try LabWorld()
        let first = try w.commitPlugin()
        w.recordLab(tainted: true)
        try "more\n".write(to: w.lab.appending(path: "brand-voice/README.md"), atomically: true, encoding: .utf8)
        try GitFixture.plainGit(["add", "-A"], in: w.lab); try GitFixture.plainGit(["commit", "-qm", "readme"], in: w.lab)
        let second = try GitFixture.plainGit(["rev-parse", "HEAD"], in: w.lab)
        w.recordLab(tainted: false)
        // A commit elsewhere in the lab (not touching the folder) does not count.
        try "x\n".write(to: w.lab.appending(path: "notes.txt"), atomically: true, encoding: .utf8)
        try GitFixture.plainGit(["add", "-A"], in: w.lab); try GitFixture.plainGit(["commit", "-qm", "notes"], in: w.lab)
        w.recordLab(tainted: true)
        _ = try w.propose(LabWorld.args("brand-voice"))
        let ask = try #require(try w.extensionAsks().first)
        let p = try #require(ExtensionAskPayload.read(ask))
        #expect(p.taintedCommits == [first], "only the tainted commit touching the folder")
        #expect(p.sourceType == "lab-tainted")
        #expect(!p.taintedCommits!.contains(second))
        let page = try String(contentsOf: w.ws.appending(path: ".brahma/ext-review/\(ask.ref).md"), encoding: .utf8)
        #expect(page.contains("tainted commits: \(first)"), "\(page)")
        // A commit with no record at all (made outside any recorded turn) counts as tainted.
        let other = try LabWorld()
        let unrecorded = try other.commitPlugin()
        try other.store.writer.write { db in try db.execute(sql: "DELETE FROM labCommit") }
        // The tool records the lab first (as this clean session); a commit it cannot record stays tainted.
        _ = try other.propose(LabWorld.args("brand-voice"))
        let otherAsk = try #require(try other.extensionAsks().first)
        let recorded = try #require(ExtensionAskPayload.read(otherAsk))
        #expect(recorded.taintedCommits == [], "recorded as this clean session's own commit: \(unrecorded)")
        #expect(try other.store.labCommitTainted(agentId: other.eng.id, sha: String(repeating: "b", count: 40)))
    }

    @Test func taintedProvenanceTreatedThirdParty() async throws {
        let w = try LabWorld()
        try w.commitPlugin()
        w.recordLab(tainted: true)
        _ = try w.propose(LabWorld.args("brand-voice"))
        let ask = try #require(try w.extensionAsks().first)
        try ExtensionLibrary.approve(askId: ask.id, roles: nil, store: w.store, paths: w.paths, now: w.world.clock.now)
        let installed = try #require(try w.store.installedExtensions(companyId: w.company.id).first)
        #expect(installed.publisher == "company:\(w.company.slug)")
        #expect(installed.provenanceTainted)
        let c = try #require(try w.store.company(id: w.company.id))
        func mounts(_ profile: PermissionProfile) throws -> [String] {
            try ExtensionLibrary.mounts(company: c, role: "engineer", agent: w.eng, grants: GrantInputs(), profile: profile, kind: .work,
                                        store: w.store, paths: w.paths, now: w.world.clock.now).map(\.id)
        }
        #expect(try mounts(.sandboxed) == ["brand-voice"])
        #expect(try mounts(.workspace).isEmpty, "treated as third-party: not mounted on Workspace")
        #expect(try mounts(.full).isEmpty)
        // Its skill invocation taints, as a third-party skill's does.
        let publisher: (String) -> String? = { id in (try? w.store.extensionPublisher(companyId: c.id, extId: id)) ?? nil }
        #expect(TaintPolicy.source(toolName: "Skill", toolInput: ["skill": .string("brand-voice:brand-voice")], publisher: publisher)
                == "skill:brand-voice")
        // A clean-provenance company extension does not taint.
        let clean = try LabWorld()
        try clean.commitPlugin()
        clean.recordLab(tainted: false)
        _ = try clean.propose(LabWorld.args("brand-voice"))
        let cleanAsk = try #require(try clean.extensionAsks().first)
        try ExtensionLibrary.approve(askId: cleanAsk.id, roles: nil, store: clean.store, paths: clean.paths, now: clean.world.clock.now)
        let cleanPublisher: (String) -> String? = { id in (try? clean.store.extensionPublisher(companyId: clean.company.id, extId: id)) ?? nil }
        #expect(TaintPolicy.source(toolName: "Skill", toolInput: ["skill": .string("brand-voice:brand-voice")],
                                   publisher: cleanPublisher) == nil)
    }

    @Test func refusedWhileTainted() throws {
        let w = try LabWorld()
        try w.commitPlugin()
        w.recordLab(tainted: false)
        #expect(TaintPolicy.reviewedHighRisk.contains("propose_extension"))
        #expect(TaintPolicy.isHighRisk("propose_extension"))
        #expect(CompanyToolNames.work.contains("propose_extension"))
        try w.store.markTainted(agentId: w.eng.id, source: "WebFetch")
        let got = try #require(w.refusal(LabWorld.args("brand-voice")))
        // The standard taint refusal (the source shown depends on whether the redactor is loaded in this store).
        #expect(got.hasPrefix("This session has read outside content ("), "\(got)")
        #expect(got.hasSuffix("so propose_extension is off for it. Your next turn starts a fresh session where propose_extension works again."))
        #expect(try #require(try w.store.agent(id: w.eng.id)).freshSessionRequested)
        #expect(try w.extensionAsks().isEmpty)
        // AskQuota: three open owner requests already refuse a fourth ask.
        let q = try LabWorld()
        try q.commitPlugin()
        q.recordLab(tainted: false)
        for n in 0..<AskQuota.perAgent {
            _ = try q.store.requestFromOwner(companyId: q.company.id, by: .agent(q.eng.id), title: "Q\(n)", question: "?")
        }
        #expect(q.refusal(LabWorld.args("brand-voice")) == AskQuota.refusal)
    }

    @Test func draftNeverMounted() async throws {
        let w = try LabWorld()
        try w.commitPlugin()
        w.recordLab(tainted: false)
        _ = try w.propose(LabWorld.args("brand-voice"))
        let ask = try #require(try w.extensionAsks().first)
        _ = try w.store.internalDecide(askId: ask.id, by: .agent(w.cto.id), approve: true, note: "")
        // Pending owner: nothing of it is in the workspace and no turn mounts it.
        #expect(SandboxPath.kind(w.ws.appending(path: ".brahma/ext/brand-voice").path) == .missing)
        try w.world.dm(w.company, w.eng)
        try await w.world.cycle()
        let r = try #require(w.world.fake.requests.last { $0.agent.id == w.eng.id })
        #expect(!r.mounts.contains { $0.path.contains("brand-voice") })
        #expect(!(r.sandbox?.readable ?? []).contains { $0.path.contains("ext-review") }, "the proposer cannot read the review page either")
        #expect(!(r.sandbox?.readable ?? []).contains { $0.path.contains("ext-try") })
        #expect(!(r.sandbox?.readable ?? []).contains { $0.path.hasSuffix("extensions/staging") })
    }

    @Test func builtinAuthoringSkillMountedOnItemless() async throws {
        let w = try LabWorld()
        try BuiltinExtensions.materialize(workspace: URL(fileURLWithPath: w.company.workspacePath, isDirectory: true))
        let c = try #require(try w.store.company(id: w.company.id))
        func mounts(_ kind: TurnKind, itemScoped: Bool, role: String = "engineer") throws -> [ExtensionMount] {
            try ExtensionLibrary.mounts(company: c, role: role, agent: w.eng, grants: GrantInputs(), profile: .workspace, kind: kind,
                                        itemScoped: itemScoped, store: w.store, paths: w.paths, now: w.world.clock.now)
        }
        #expect(try mounts(.work, itemScoped: false).map(\.id) == [BuiltinExtensions.authoringId])
        #expect(try mounts(.notice, itemScoped: false).map(\.publisher) == [ExtensionPublisher.brahma])
        #expect(try mounts(.work, itemScoped: true).isEmpty, "only itemless (lab) turns")
        #expect(try mounts(.review, itemScoped: false).isEmpty)
        for role in w.store.catalog.pack("software")?.roles.map(\.id) ?? [] {
            #expect(try mounts(.work, itemScoped: false, role: role).map(\.id) == [BuiltinExtensions.authoringId], "\(role)")
        }
        // A real itemless turn mounts it, and its skill never taints.
        try w.world.dm(w.company, w.eng)
        try await w.world.cycle()
        let r = try #require(w.world.fake.requests.last { $0.agent.id == w.eng.id })
        #expect(r.mounts.contains { $0.path.contains("/.brahma/ext/\(BuiltinExtensions.authoringId)/") })
        let publisher: (String) -> String? = { id in (try? w.store.extensionPublisher(companyId: c.id, extId: id)) ?? nil }
        #expect(TaintPolicy.source(toolName: "Skill", toolInput: ["skill": .string("extension-authoring:extension-authoring")],
                                   publisher: publisher) == nil)
        // The skill teaches the loop and the hand-off.
        let skill = try #require(BuiltinExtensions.authoring.files["skills/extension-authoring/SKILL.md"])
        for phrase in ["brahma ext new skill", "brahma ext lint --json", "propose_extension", "hooks", "bin/", "plugin.json"] {
            #expect(skill.contains(phrase), "\(phrase)")
        }
        // Nobody may propose or install an extension under a built-in id.
        try w.commitPlugin(id: BuiltinExtensions.authoringId)
        w.recordLab(tainted: false)
        let got = try #require(w.refusal(LabWorld.args(BuiltinExtensions.authoringId)))
        #expect(got.contains("Brahma's own"), "\(got)")
    }

    /// B-M14: `assets/` is not mounted, so a part that reads it is flagged (a warning, which a lab proposal refuses).
    @Test func assetsReferenceIsLinted() throws {
        let f = try PluginFixture(files: ["skills/demo/SKILL.md": PluginFixture.skillMD(
            name: "demo", body: "Read ${CLAUDE_PLUGIN_ROOT}/assets/tone.txt first.\n"), "assets/tone.txt": "calm\n"])
        let r = ExtensionValidator.validate(staged: f.root)
        let hit = try #require(r.issues.first { $0.code == LintCode.assetsUnmounted.rawValue })
        #expect(hit.severity == .warning); #expect(hit.path == "skills/demo/SKILL.md"); #expect(r.errors.isEmpty)
        #expect(LintCode.assetsUnmounted.name == "assets-unmounted")
        #expect(ExtensionValidator.validate(staged: try PluginFixture(id: "plain").root).issues.isEmpty)
    }

    @Test func builtinAgentsHashPinned() throws {
        for builtin in BuiltinExtensions.all {
            let entries = builtin.files.keys.sorted().map { path in
                ExtensionLock.FileEntry(path: path, mode: "0644", sha256: SHA256.hex(Data(builtin.files[path]!.utf8)))
            }
            #expect(ExtensionLock.treeHash(entries: entries) == builtin.pinnedHash, "\(builtin.id)")
            // Each lints clean.
            let dir = try tempDir().appending(path: builtin.id)
            for (path, text) in builtin.files {
                let url = dir.appending(path: path)
                try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                try Data(text.utf8).write(to: url)
            }
            let result = ExtensionValidator.validate(staged: dir)
            #expect(result.issues.isEmpty, "\(builtin.id): \(result.issues)")
        }
        let reader = try #require(BuiltinExtensions.workers.files["agents/brahma-reader.md"])
        #expect(reader.contains("tools: [Read, Bash, Skill]"))
        #expect(reader.contains("disallowedTools: [WebFetch, WebSearch, Agent]"))
        #expect(BuiltinExtensions.workers.id == "brahma-workers")
        // Materialized read-only and verified against the pinned hash; a changed file is put back.
        let ws = try tempDir()
        try BuiltinExtensions.materialize(workspace: ws)
        let dir = BuiltinExtensions.pluginDir(BuiltinExtensions.workers, workspace: ws)
        #expect(try ExtensionLock.treeHash(root: dir) == BuiltinExtensions.workers.pinnedHash)
        let file = dir.appending(path: "agents/brahma-reader.md")
        #expect((try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? Int) == 0o444)
        ExtensionLibrary.makeWritable(dir)
        try Data("tools: [Read, Bash, WebFetch]\n".utf8).write(to: file)
        try BuiltinExtensions.materialize(workspace: ws)
        #expect(try ExtensionLock.treeHash(root: dir) == BuiltinExtensions.workers.pinnedHash)
        // The built-in agents switch is not emitted until the F7-agents gate passes (Task 14u).
        #expect(BuiltinExtensions.agentEnvironment(f7AgentsPassed: false).isEmpty)
        #expect(BuiltinExtensions.agentEnvironment(f7AgentsPassed: true) == ["CLAUDE_AGENT_SDK_DISABLE_BUILTIN_AGENTS": "1"])
        #expect(BuiltinExtensions.f7Gate == "F7-agents")
        #expect(BuiltinExtensions.workersInitAgents == ["brahma-workers:brahma-reader"])
    }
}
