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
        // S25: a commit with no record (made in this very turn, say) is tainted for the proposal, and proposing records nothing:
        // it is still unrecorded afterwards.
        let other = try LabWorld()
        let unrecorded = try other.commitPlugin()
        try other.store.writer.write { db in try db.execute(sql: "DELETE FROM labCommit") }
        let reply = try other.propose(LabWorld.args("brand-voice"))
        #expect(reply.contains("goes straight to the owner"), "\(reply)")
        let otherAsk = try #require(try other.extensionAsks().first)
        let recorded = try #require(ExtensionAskPayload.read(otherAsk))
        #expect(recorded.taintedCommits == [unrecorded])
        #expect(recorded.sourceType == "lab-tainted")
        #expect(try other.store.labCommits(agentId: other.eng.id).isEmpty, "proposing records nothing")
        #expect(try other.store.labCommitTainted(agentId: other.eng.id, sha: unrecorded))
    }

    /// S25: provenance follows content. A file a tainted session committed elsewhere, renamed or copied into the folder by a
    /// clean commit, keeps its blob id: the proposal is tainted and names the tainted commit.
    @Test(arguments: ["rename", "copy"])
    func contentFromTaintedCommitIsTainted(_ how: String) throws {
        let w = try LabWorld()
        try FileManager.default.createDirectory(at: w.lab.appending(path: "drafts"), withIntermediateDirectories: true)
        try "Write in a calm, plain voice.\n".write(to: w.lab.appending(path: "drafts/tone.md"), atomically: true, encoding: .utf8)
        try GitFixture.plainGit(["add", "-A"], in: w.lab); try GitFixture.plainGit(["commit", "-qm", "draft"], in: w.lab)
        let tainted = try GitFixture.plainGit(["rev-parse", "HEAD"], in: w.lab)
        w.recordLab(tainted: true)
        _ = try PluginFixture(id: "brand-voice", under: w.lab)
        let target = "brand-voice/skills/brand-voice/reference/tone.md"
        try FileManager.default.createDirectory(at: w.lab.appending(path: "brand-voice/skills/brand-voice/reference"), withIntermediateDirectories: true)
        if how == "rename" {
            try GitFixture.plainGit(["mv", "drafts/tone.md", target], in: w.lab)
        } else {
            try FileManager.default.copyItem(at: w.lab.appending(path: "drafts/tone.md"), to: w.lab.appending(path: target))
        }
        try GitFixture.plainGit(["add", "-A"], in: w.lab); try GitFixture.plainGit(["commit", "-qm", "skill"], in: w.lab)
        let clean = try GitFixture.plainGit(["rev-parse", "HEAD"], in: w.lab)
        w.recordLab(tainted: false)
        #expect(!(try w.store.labCommitTainted(agentId: w.eng.id, sha: clean)), "the folder's own commits are all clean")
        _ = try w.propose(LabWorld.args("brand-voice"))
        let ask = try #require(try w.extensionAsks().first)
        let p = try #require(ExtensionAskPayload.read(ask))
        #expect(p.taintedCommits == [tainted], "\(how)")
        #expect(p.sourceType == "lab-tainted")
    }

    /// I1: a tainted proposal goes straight to the owner; no agent's turn may read its review page.
    @Test func taintedProposalIsOwnerOnly() throws {
        let w = try LabWorld()
        try w.commitPlugin()
        w.recordLab(tainted: true)
        let reply = try w.propose(LabWorld.args("brand-voice"))
        let ask = try #require(try w.extensionAsks().first)
        #expect(reply == "Proposed \(ask.ref) (brand-voice). Its content comes in part from lab commits made by a session that read outside "
                + "content, or not yet recorded (a commit is recorded when the turn that made it ends), so it goes straight to the owner. "
                + "Drafts are never mounted before approval.")
        #expect(ask.status == .pendingOwner); #expect(ask.internalApproverId == nil)
        for a in [w.cto, w.eng] { #expect(try w.store.extensionReviewPages(reviewerId: a.id).isEmpty) }
        #expect(!(try w.store.pendingInbox(agentId: w.cto.id)).contains { $0.1.text.contains(ask.ref) }, "the cto is not asked")
        let page = w.ws.appending(path: ".brahma/ext-review/\(ask.ref).md")
        #expect(SandboxPath.kind(page.path) == .file, "the owner's page is written")
        let ctoScope = try scope(w, w.cto, pages: try w.store.extensionReviewPages(reviewerId: w.cto.id).map { w.ws.appending(path: $0) })
        #expect(!ctoScope.readable.contains { $0.path.contains("ext-review") })
    }

    /// I2: once a tainted session has worked in the lab (the sticky mark), every proposal from it goes to the owner and mounts
    /// as third-party, even content a clean session committed (the uncommitted hand-off); only the owner clears the mark.
    @Test func labMarkSendsProposalsToTheOwner() throws {
        let w = try LabWorld()
        // A tainted session writes the skill and leaves it uncommitted.
        try w.store.markTainted(agentId: w.eng.id, source: "WebFetch", now: w.world.clock.now)
        _ = try PluginFixture(id: "brand-voice", under: w.lab)
        #expect(try w.store.labTaint(agentId: w.eng.id) != nil, "the mark is set")
        // A later clean session commits it; its commit is recorded clean.
        try w.store.writer.write { db in try db.execute(sql: "UPDATE agent SET sessionTainted = 0, taintSources = '' WHERE id = ?", arguments: [w.eng.id]) }
        try GitFixture.plainGit(["add", "-A"], in: w.lab); try GitFixture.plainGit(["commit", "-qm", "skill"], in: w.lab)
        w.recordLab(tainted: false)
        let reply = try w.propose(LabWorld.args("brand-voice"))
        #expect(reply.contains("has worked in your lab"), "\(reply)")
        let ask = try #require(try w.extensionAsks().first)
        #expect(ask.status == .pendingOwner); #expect(ask.internalApproverId == nil)
        let p = try #require(ExtensionAskPayload.read(ask))
        #expect(p.sourceType == "lab-tainted"); #expect(p.taintedCommits == []); #expect(p.labMark?.contains("WebFetch") == true)
        let page = try String(contentsOf: w.ws.appending(path: ".brahma/ext-review/\(ask.ref).md"), encoding: .utf8)
        #expect(page.contains("a session that read outside content has worked in this lab"), "\(page)")
        // The mark is sticky: a fresh session, a review's throwaway reset and the turn end leave it.
        try w.store.endThrowawaySessionTaint(agentId: w.eng.id)
        #expect(try w.store.labTaint(agentId: w.eng.id) != nil)
        // No company tool can clear it; the owner can, and it is recorded.
        #expect(!CompanyToolNames.all.contains { $0.contains("taint") || $0.contains("lab") })
        #expect(try w.store.clearLabTaint(companyId: w.company.id, agentId: w.eng.id))
        #expect(try w.store.labTaint(agentId: w.eng.id) == nil)
        #expect(try w.store.events(afterId: 0, companyId: w.company.id).contains { $0.text.contains("cleared @eng-1's lab mark") })
        // The next clean proposal routes to the reviewer again, with the exact provenance line.
        try w.commitPlugin(id: "tone-two")
        w.recordLab(tainted: false)
        let next = try w.propose(LabWorld.args("tone-two"))
        #expect(next.contains("@cto reviews it"), "\(next)")
        let second = try #require(try w.extensionAsks().first { ExtensionAskPayload.read($0)?.extId == "tone-two" })
        let secondPage = try String(contentsOf: w.ws.appending(path: ".brahma/ext-review/\(second.ref).md"), encoding: .utf8)
        #expect(secondPage.contains("no tainted session has worked in this lab since the owner last cleared it"))
        #expect(secondPage.contains("commit content is not traced beyond object ids"))
        // Another company's owner path cannot clear it.
        #expect(throws: WorkError.self) { try w.store.clearLabTaint(companyId: "other", agentId: w.eng.id) }
    }

    /// Taint held only in the flag file (the database write failed, Task 10 M2): at the turn's end the lab is marked and the
    /// turn's commits are recorded tainted, never clean; a flag a crash left marks the lab at engine start.
    @Test func flagFileOnlyTaintMarksTheLab() async throws {
        let w = try LabWorld()
        let home = w.paths.home
        let agentId = w.eng.id
        w.world.fake.script(w.eng.name, FakeTurnRunner.Script(sideEffect: { r in
            // The hook could not reach the database: only its flag file says the session is tainted.
            TaintFlag.write(home: home, agentId: agentId, source: TaintPolicy.hookErrorSource)
            let lab = URL(fileURLWithPath: r.workingDirectory)
            try "planted\n".write(to: lab.appending(path: "planted.md"), atomically: true, encoding: .utf8)
            try GitFixture.plainGit(["add", "-A"], in: lab); try GitFixture.plainGit(["commit", "-qm", "planted"], in: lab)
        }))
        try w.world.dm(w.company, w.eng)
        try await w.world.cycle()
        #expect(!(try #require(try w.store.agent(id: w.eng.id)).sessionTainted), "the row never heard of it")
        let head = try GitFixture.plainGit(["rev-parse", "HEAD"], in: w.lab)
        let rows = try w.store.labCommits(agentId: w.eng.id)
        #expect(rows.first { $0.sha == head }?.tainted == true, "recorded tainted, never clean")
        #expect(try w.store.labTaint(agentId: w.eng.id)?.source == TaintPolicy.hookErrorSource)
        // Engine start: a flag left behind (a crash) marks its agent's lab.
        let other = try LabWorld()
        TaintFlag.write(home: other.paths.home, agentId: other.eng.id, source: TaintPolicy.hookErrorSource)
        #expect(try other.store.labTaint(agentId: other.eng.id) == nil)
        try await other.world.orchestrator.start()
        #expect(try other.store.labTaint(agentId: other.eng.id) != nil)
        #expect(try other.store.labTaint(agentId: other.cto.id) == nil, "sandboxed: only its own lab")
    }

    /// S30: when the turn end cannot write the lab mark (an injected write failure), the taint is not cleared: the flag file
    /// stays and the next turn is still tainted.
    @Test func unwrittenLabMarkKeepsTheTaint() async throws {
        let w = try LabWorld()
        let (home, agentId, store) = (w.paths.home, w.eng.id, w.store)
        w.world.fake.script(w.eng.name, FakeTurnRunner.Script(sideEffect: { _ in
            // A refused high-risk call asked for a fresh session; then the hook could only write its flag file.
            try store.markTainted(agentId: agentId, source: "WebFetch")
            try store.requestFreshSession(agentId: agentId)
            TaintFlag.write(home: home, agentId: agentId, source: TaintPolicy.hookErrorSource)
            // The injected failure: every lab-mark write from here on fails.
            try store.writer.write { db in try db.execute(sql: "DROP TABLE labTaint") }
        }))
        try w.world.dm(w.company, w.eng)
        try await w.world.cycle()
        let flag = try #require(TaintFlag.url(home: home, agentId: agentId))
        #expect(TaintFlag.exists(flag), "the flag file stays")
        let after = try #require(try w.store.agent(id: agentId))
        #expect(after.sessionTainted, "the next turn is still tainted"); #expect(after.freshSessionRequested)
        #expect(throws: (any Error).self) { _ = try w.store.turnEndTaint(agentId: agentId, home: home) }
        // The next turn runs tainted: its high-risk call is refused, and its end keeps the flag again.
        try w.world.dm(w.company, w.eng, "again")
        w.world.clock.advance(3600)
        try await w.world.cycle()
        #expect(TaintFlag.exists(flag))
        #expect(try #require(try w.store.agent(id: agentId)).sessionTainted)
        #expect(w.refusal(LabWorld.args("brand-voice"))?.hasPrefix("This session has read outside content") == true)
    }

    /// Residual 2, as ruled: without a sandbox a tainted session's Bash can write any lab of the company, so every lab there is
    /// marked (fail closed). On Sandboxed only its own lab is.
    @Test func taintWithoutSandboxMarksEveryLab() throws {
        let w = try LabWorld(profile: .workspace)
        let qa = try w.store.hire(companyId: w.company.id, name: "qa-1", role: "qa", model: "sonnet")
        try w.store.markTainted(agentId: w.eng.id, source: "WebFetch", now: w.world.clock.now)
        for a in [w.eng, w.cto, qa] { #expect(try w.store.labTaint(agentId: a.id) != nil, "\(a.name)") }
        #expect(try w.store.labTaint(agentId: qa.id)?.source.contains("@eng-1 on the workspace profile") == true)
        // A clean proposal by another agent of that company now goes to the owner.
        let sandboxed = try LabWorld()
        try sandboxed.store.markTainted(agentId: sandboxed.eng.id, source: "WebFetch", now: sandboxed.world.clock.now)
        #expect(try sandboxed.store.labTaint(agentId: sandboxed.eng.id) != nil)
        #expect(try sandboxed.store.labTaint(agentId: sandboxed.cto.id) == nil)
    }

    /// S31: the unsandboxed mark is the company's, so an agent hired after it starts marked; its proposal goes to the owner
    /// until the owner clears the company mark, and then routes normally.
    @Test func companyMarkTaintsLaterHires() throws {
        let w = try LabWorld(profile: .workspace)
        try w.store.markTainted(agentId: w.eng.id, source: "WebFetch", now: w.world.clock.now)
        #expect(try w.store.companyLabTaint(companyId: w.company.id)?.profile == "workspace")
        let late = try w.store.hire(companyId: w.company.id, name: "eng-2", role: "engineer", model: "sonnet")
        #expect(try w.store.labTaint(agentId: late.id)?.source.hasPrefix("company: @eng-1 on the workspace profile") == true)
        try SandboxLayout(paths: w.paths, company: w.company, agentHandle: late.name).ensure()
        let lab = w.ws.appending(path: ".brahma/labs/\(late.name)")
        func propose(_ id: String) throws -> Ask {
            _ = try PluginFixture(id: id, under: lab)
            try GitFixture.plainGit(["add", "-A"], in: lab); try GitFixture.plainGit(["commit", "-qm", id], in: lab)
            _ = LabProvenance.record(store: w.store, workspace: w.ws, handle: late.name, companyId: w.company.id, agentId: late.id,
                                     turnId: nil, tainted: false, now: w.world.clock.now)
            _ = try CompanyTools(store: w.store, companyId: w.company.id, agentId: late.id, paths: w.paths)
                .call(name: "propose_extension", arguments: LabWorld.args(id))
            return try #require(try w.extensionAsks().first { ExtensionAskPayload.read($0)?.extId == id })
        }
        let first = try propose("late-one")
        #expect(first.status == .pendingOwner); #expect(first.internalApproverId == nil)
        #expect(ExtensionAskPayload.read(first)?.labMark?.contains("company:") == true)
        // Clearing only the agent's own row leaves the company mark in force.
        _ = try w.store.clearLabTaint(companyId: w.company.id, agentId: late.id)
        #expect(try w.store.labTaint(agentId: late.id) != nil)
        // The owner clears the company: every mark there goes, recorded; the next clean proposal reaches the cto.
        #expect(try w.store.clearCompanyLabTaint(companyId: w.company.id))
        #expect(try w.store.companyLabTaint(companyId: w.company.id) == nil)
        for a in [w.eng, w.cto, late] { #expect(try w.store.labTaint(agentId: a.id) == nil, "\(a.name)") }
        #expect(try w.store.events(afterId: 0, companyId: w.company.id).contains { $0.text.contains("cleared the company's lab mark") })
        let second = try propose("late-two")
        #expect(second.internalApproverId == w.cto.id); #expect(second.status == .pendingInternal)
    }

    /// S31: while a tainted Full-profile session has run since the last owner clear, no lab commit of any company is recorded
    /// clean; once the owner clears it, clean records resume.
    @Test func fullProfileTaintRefusesCleanRecords() throws {
        let w = try LabWorld(profile: .full)
        let other = try w.world.company("Beta", profile: .sandboxed)
        let bee = try w.store.hire(companyId: other.id, name: "bee", role: "engineer", model: "sonnet")
        try w.store.markTainted(agentId: w.eng.id, source: "WebFetch", now: w.world.clock.now)
        #expect(try w.store.companyLabTaint(companyId: w.company.id)?.profile == "full")
        let sha = { (c: Character) in String(repeating: c, count: 40) }
        _ = try w.store.recordLabCommits(agentId: bee.id, turnId: nil, shas: [sha("a")], tainted: false)
        _ = try w.store.recordLabCommits(agentId: w.cto.id, turnId: nil, shas: [sha("b")], tainted: false)
        #expect(try w.store.labCommitTainted(agentId: bee.id, sha: sha("a")), "another company's lab too")
        #expect(try w.store.labCommitTainted(agentId: w.cto.id, sha: sha("b")))
        #expect(try w.store.clearCompanyLabTaint(companyId: w.company.id))
        _ = try w.store.recordLabCommits(agentId: bee.id, turnId: nil, shas: [sha("c")], tainted: false)
        #expect(!(try w.store.labCommitTainted(agentId: bee.id, sha: sha("c"))))
        // A Workspace mark does not refuse other companies' clean records.
        let ws = try LabWorld(profile: .workspace)
        try ws.store.markTainted(agentId: ws.eng.id, source: "WebFetch", now: ws.world.clock.now)
        _ = try ws.store.recordLabCommits(agentId: ws.cto.id, turnId: nil, shas: [sha("d")], tainted: false)
        #expect(!(try ws.store.labCommitTainted(agentId: ws.cto.id, sha: sha("d"))))
    }

    /// Round 2c: a hire never adopts a lab that is already there; it goes to trash unread, the owner is alerted, the new agent
    /// gets an empty lab. An existing agent's lab is never touched.
    @Test func preexistingLabIsNotAdopted() throws {
        let w = try LabWorld(profile: .workspace)
        let lab = w.ws.appending(path: ".brahma/labs/eng-9")
        try FileManager.default.createDirectory(at: lab.appending(path: "skills"), withIntermediateDirectories: true)
        try "planted\n".write(to: lab.appending(path: "skills/planted.md"), atomically: true, encoding: .utf8)
        _ = try w.store.hire(companyId: w.company.id, name: "eng-9", role: "engineer", model: "sonnet")
        #expect(SandboxPath.kind(lab.path) == .directory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: lab.path).isEmpty, "a fresh, empty lab")
        let trash = w.ws.appending(path: ".brahma/trash/eng-9")
        let moved = try #require(try FileManager.default.contentsOfDirectory(atPath: trash.path).first)
        #expect(moved.hasSuffix("-lab"))
        #expect(FileManager.default.fileExists(atPath: trash.appending(path: "\(moved)/skills/planted.md").path))
        let alerts = try w.store.asks(companyId: w.company.id).filter { $0.kind == .engineAlert }
        #expect(alerts.contains { $0.title.contains("eng-9") || $0.summary.contains("eng-9") }, "\(alerts.map(\.summary))")
        // An existing agent's lab stays as it is (a duplicate hire is refused before anything moves).
        try "mine\n".write(to: w.lab.appending(path: "mine.md"), atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try w.store.hire(companyId: w.company.id, name: "eng-1", role: "engineer", model: "sonnet") }
        #expect(FileManager.default.fileExists(atPath: w.lab.appending(path: "mine.md").path))
        // A link planted as a lab is moved aside itself, never followed.
        let outside = try tempDir().appending(path: "outside")
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(at: w.ws.appending(path: ".brahma/labs/eng-8"), withDestinationURL: outside)
        _ = try w.store.hire(companyId: w.company.id, name: "eng-8", role: "engineer", model: "sonnet")
        #expect(SandboxPath.kind(w.ws.appending(path: ".brahma/labs/eng-8").path) == .directory)
        #expect(FileManager.default.fileExists(atPath: outside.path))
    }

    /// M8: an empty file carries no content; a tainted commit that added one elsewhere does not taint the folder.
    @Test func emptyBlobsDoNotDecideProvenance() throws {
        let w = try LabWorld()
        try FileManager.default.createDirectory(at: w.lab.appending(path: "drafts"), withIntermediateDirectories: true)
        try Data().write(to: w.lab.appending(path: "drafts/empty.txt"))
        try GitFixture.plainGit(["add", "-A"], in: w.lab); try GitFixture.plainGit(["commit", "-qm", "draft"], in: w.lab)
        w.recordLab(tainted: true)
        let fixture = try PluginFixture(id: "brand-voice", under: w.lab)
        try FileManager.default.createDirectory(at: fixture.root.appending(path: "assets"), withIntermediateDirectories: true)
        // A different name: a subtree holding only `empty.txt` would be the same tree as `drafts/` (identical content).
        try Data().write(to: fixture.root.appending(path: "assets/blank.txt"))
        try GitFixture.plainGit(["add", "-A"], in: w.lab); try GitFixture.plainGit(["commit", "-qm", "skill"], in: w.lab)
        w.recordLab(tainted: false)
        _ = try w.propose(LabWorld.args("brand-voice"))
        let ask = try #require(try w.extensionAsks().first)
        let p = try #require(ExtensionAskPayload.read(ask))
        #expect(p.taintedCommits == []); #expect(p.sourceType == "lab"); #expect(ask.internalApproverId == w.cto.id)
    }

    /// B-M9 on Workspace: Claude's file tools are denied `ext-try` and every review page that is not this agent's.
    @Test func workspaceTurnsDenyOtherReviewPages() async throws {
        let w = try LabWorld(profile: .workspace)
        try w.commitPlugin()
        w.recordLab(tainted: false)
        _ = try w.propose(LabWorld.args("brand-voice"))           // A-1: the cto pre-checks it
        try w.commitPlugin(id: "tone-two")
        _ = try w.propose(LabWorld.args("tone-two"))              // A-2: unrecorded, so owner-only
        let asks = try w.extensionAsks()
        let mine = try #require(asks.first { $0.internalApproverId == w.cto.id })
        let ownerOnly = try #require(asks.first { $0.internalApproverId == nil })
        func denied(_ a: Agent) async throws -> [String] {
            try w.world.dm(w.company, a)
            try await w.world.cycle()
            let r = try #require(w.world.fake.requests.last { $0.agent.id == a.id })
            #expect(r.profile == .workspace)
            return r.deniedPaths.map(\.path)
        }
        let cto = try await denied(w.cto)
        #expect(cto.contains { $0.hasSuffix("/.brahma/ext-try") })
        #expect(cto.contains { $0.hasSuffix("/.brahma/ext-review/\(ownerOnly.ref).md") })
        #expect(!cto.contains { $0.hasSuffix("/.brahma/ext-review/\(mine.ref).md") }, "its own page stays readable")
        #expect(!cto.contains { $0.hasSuffix("/.brahma/ext-review") }, "no directory deny over its own page")
        let eng = try await denied(w.eng)
        #expect(eng.contains { $0.hasSuffix("/.brahma/ext-review") }); #expect(eng.contains { $0.hasSuffix("/.brahma/ext-try") })
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
