import Foundation
import Testing
import GRDB
@testable import BrahmaCore

/// Release records and the owner-only `deploy` ask (Plan L Task 6): `Store.proposeDeploy` composes the exact deploy and
/// rollback plans through an injected adapter (`FakeHostingAdapter`, PR-25), and only the owner's decision moves a release.
@Suite(.scratch) struct ReleaseTests {
    struct Fx {
        let store: Store
        let company: Company
        let devops: Agent
        let vault: MemoryVault
        let layout: ReleaseLayout
        let fake = FakeHostingAdapter()

        var adapters: HostingAdapters.Lookup { let f = fake; return { _ in f } }
        var main: String { (try? store.company(id: company.id))?.mainCommit ?? "" }

        @discardableResult
        func propose(_ version: String, by agentId: String? = nil, notes: String? = nil, npm: Bool = true,
                     now: Date = Date(timeIntervalSince1970: 1_800_000_000)) throws -> (Release, Ask) {
            try store.proposeDeploy(companyId: company.id, by: agentId ?? devops.id, version: version, notes: notes, now: now,
                                    vault: vault, adapters: adapters, layout: layout, npmPresent: npm)
        }

        func message(_ version: String, by agentId: String? = nil, npm: Bool = true) -> String? {
            do { _ = try propose(version, by: agentId, npm: npm); return nil } catch let e as WorkError { return e.message } catch { return "\(error)" }
        }

        /// A finished `merge` smoke run of `main` with `status`.
        func smoke(_ status: MainSmokeStatus, exit: Int? = nil) throws {
            let commit = main
            try store.writer.write { db in
                let t = Date(timeIntervalSince1970: 1_799_999_000)
                try MainSmokeRun(companyId: company.id, commit: commit, status: status, exitCode: exit ?? (status == .passed ? 0 : 1),
                                 reason: .merge, createdAt: t, startedAt: t, finishedAt: t).insert(db)
            }
        }

        func setStatus(_ release: Release, _ status: ReleaseStatus) throws {
            try store.writer.write { db in
                try db.execute(sql: "UPDATE release SET status = ? WHERE id = ?", arguments: [status.rawValue, release.id])
            }
        }
    }

    static func fixture(name: String = "Acme", token: Bool = true, account: Bool = true, deployConfig: Bool = true,
                        smokeCheck: Bool = true, passed: Bool = true) throws -> Fx {
        let store = try Store.inMemory()
        let c = try store.createCompany(name: name, goal: "g", workspacesRoot: try tempDir())
        let devops = try store.hire(companyId: c.id, name: "devops-1", role: "devops", model: "m")
        let vault = MemoryVault()
        if account { try store.setHosting(companyId: c.id, by: .owner, accountId: "acct-1") }
        if deployConfig {
            try store.setDeployConfig(companyId: c.id, by: devops.id, build: "npm ci && npm run build", outputDir: "dist",
                                      smoke: [SmokeRequest(method: "GET", path: "/", expectStatus: 200), SmokeRequest(method: "GET", path: "/health")],
                                      expectText: "Welcome")
        }
        if smokeCheck { try store.setSmokeCheck(companyId: c.id, by: devops.id, check: CheckSpec(command: "npm test")) }
        if token { try store.setSecret(companyId: c.id, name: "FAKE_HOST_TOKEN", value: "fake-host-token-123456", isTest: false, vault: vault) }
        let layout = ReleaseLayout(root: try tempDir().appending(path: "releases/\(c.id)", directoryHint: .isDirectory))
        let fx = Fx(store: store, company: try #require(try store.company(id: c.id)), devops: devops, vault: vault, layout: layout)
        if smokeCheck, passed { try fx.smoke(.passed) }
        return fx
    }

    // MARK: Proposing

    @Test func proposeRecordsExactPlanAndRollback() throws {
        let fx = try Self.fixture()
        let (r, ask) = try fx.propose("0.1.0", notes: "First public release")
        #expect(r.ref == "R-1"); #expect(r.number == 1); #expect(r.status == .proposed); #expect(r.version == "0.1.0")
        #expect(r.commit == fx.main); #expect(!r.commit.isEmpty)
        #expect(r.previousReleaseId == nil)
        #expect(r.build == "npm ci && npm run build"); #expect(r.outputDir == "dist")
        #expect(r.plan.hash == r.commandsHash); #expect(r.plan.hashIsCurrent)
        #expect(r.plan.cwdPath == fx.layout.releaseDir(1).appending(path: "upload", directoryHint: .isDirectory).path)
        #expect(r.rollbackPlan.cwdPath == fx.layout.placeholderDir.path)
        #expect(r.provider == .cloudflarePages); #expect(r.project == fx.company.slug)
        #expect(r.proposedById == fx.devops.id); #expect(r.askId == ask.id); #expect(r.notes == "First public release")
        // Stored exactly: the row reads back equal, plans included.
        #expect(try fx.store.release(companyId: fx.company.id, ref: "R-1") == r)
        #expect(try fx.store.release(companyId: fx.company.id, ref: "r-1") == r)
        #expect(try fx.store.releases(companyId: fx.company.id).map(\.id) == [r.id])
        // The ask: kind deploy, risk high, to the owner, with the exact proposal.
        #expect(ask.kind == .deploy); #expect(ask.risk == .high); #expect(ask.status == .pendingOwner)
        #expect(ask.subjectId == r.id); #expect(ask.requesterId == fx.devops.id)
        let sha7 = String(r.commit.prefix(7))
        #expect(ask.title == "Deploy 0.1.0 to Cloudflare Pages at \(sha7)")
        let proposal = try #require(ask.payload?.proposal)
        #expect(proposal == """
            Build (sandboxed, no token): npm ci && npm run build → dist
            Smoke on main at \(sha7) just before deploying: npm test
            Deploy (engine, token $FAKE_HOST_TOKEN from Keychain), in order:
            \(r.plan.display)
            Rollback recorded now:
            \(r.rollbackPlan.display)
            Smoke after deploy: the deploy URL GET / 200, GET /health, expecting "Welcome"
            """)
        #expect(proposal.contains(r.plan.display))
        #expect(Store.proposedDeployText(r) == "Proposed R-1 (release 0.1.0 at \(sha7)); waiting on the owner.")
    }

    @Test func secondReleaseRollbackTargetsPrevious() throws {
        let fx = try Self.fixture()
        let (r1, _) = try fx.propose("0.1.0")
        try fx.setStatus(r1, .deployed)
        let (r2, _) = try fx.propose("0.2.0")
        #expect(r2.ref == "R-2"); #expect(r2.previousReleaseId == r1.id)
        #expect(r2.rollbackPlan.cwdPath == r1.plan.cwdPath)
        #expect(r2.rollbackPlan.cwdPath == fx.layout.releaseDir(1).appending(path: "upload", directoryHint: .isDirectory).path)
        #expect(try fx.store.releases(companyId: fx.company.id).map(\.ref) == ["R-2", "R-1"])
        #expect(try fx.store.releases(companyId: fx.company.id, limit: 1).map(\.ref) == ["R-2"])
    }

    @Test func deployAskAlwaysNeedsOwner() throws {
        // The policy (PR-27): deploy and humanTask asks need the owner under every preset, whatever the risk or class.
        for preset in AutonomyPreset.allCases {
            for kind in [AskKind.deploy, .humanTask] {
                for risk in AskRisk.allCases {
                    #expect(AutonomyPolicy.ownerRole(kind: kind, risk: risk, category: nil, preset: preset, pack: SoftwarePack.pack) == .approve)
                }
            }
        }
        let fx = try Self.fixture()
        try fx.store.setAutonomy(companyId: fx.company.id, .auto, owner: .test)
        for p in AccessPreset.allCases { try fx.store.setPreset(companyId: fx.company.id, p, enabled: true, owner: .test) }
        let ceo = try fx.store.hire(companyId: fx.company.id, name: "ceo-1", role: "ceo", model: "m")
        let (r, ask) = try fx.propose("0.1.0")
        #expect(ask.status == .pendingOwner); #expect(ask.internalApproverId == nil)
        // No agent can decide it: not the CEO, not the proposer.
        for agent in [ceo.id, fx.devops.id] {
            #expect(throws: (any Error).self) { try fx.store.internalDecide(askId: ask.id, by: .agent(agent), approve: true, note: "ok") }
            let tools = CompanyTools(store: fx.store, companyId: fx.company.id, agentId: agent)
            #expect(throws: (any Error).self) { try tools.call(name: "decide", arguments: ["ask": .string(ask.ref), "approve": .bool(true), "note": .string("ok")]) }
        }
        #expect(try fx.store.release(companyId: fx.company.id, ref: r.ref)?.status == .proposed)
        // Only the owner's decision approves it.
        let decided = try fx.store.ownerDecide(askId: ask.id, approve: true, owner: .test)
        #expect(decided.status == .approved)
        #expect(try fx.store.release(companyId: fx.company.id, ref: r.ref)?.status == .approved)
    }

    @Test func smokeCheckRequired() throws {
        let fx = try Self.fixture(smokeCheck: false)
        #expect(fx.message("0.1.0") == "set_smoke_check first; deploys need a smoke check on main")
        #expect(try fx.store.releases(companyId: fx.company.id).isEmpty)
    }

    /// Final-review m3: a version git refuses as a ref component is refused when proposed (never later at the backup step),
    /// and versions are unique ignoring case (APFS folds case in loose refs).
    @Test func versionsGitRefusesOrCaseVariantsRefused() throws {
        for bad in ["1..2", "1.", "x.lock", "1.0.LOCK", "a..b.c"] {
            #expect(!ReleasePolicy.validVersion(bad), "\(bad)")
            #expect(throws: (any Error).self) { _ = try GitWorkspace.releaseRef(version: bad) }
        }
        for good in ["1.0.0", "1.2.0-rc.1+b5", "v2", "1.0-lockdown", "lock"] {
            #expect(ReleasePolicy.validVersion(good), "\(good)")
            #expect(try GitWorkspace.releaseRef(version: good) == "refs/brahma/releases/\(good)")
        }
        let fx = try Self.fixture()
        #expect(fx.message("1..2") == ReleasePolicy.badVersion)
        #expect(fx.message("x.lock") == ReleasePolicy.badVersion)
        let (r1, ask1) = try fx.propose("1.0-RC")
        try fx.store.ownerDecide(askId: ask1.id, approve: false, note: "not yet", owner: .test)
        #expect(try fx.store.release(companyId: fx.company.id, ref: r1.ref)?.status == .rejected)
        #expect(fx.message("1.0-rc") == "release 1.0-rc already exists (as 1.0-RC)")
        #expect(try fx.store.releases(companyId: fx.company.id).count == 1)
    }

    /// Final-review m2: the smoke check on main and the deployed site's smoke requests and expected text are pinned to the
    /// release when it is proposed.
    @Test func proposalPinsTheSmokeChecks() throws {
        let fx = try Self.fixture()
        let (r, _) = try fx.propose("0.1.0")
        #expect(r.smokeCheck == CheckSpec(command: "npm test"))
        #expect(r.siteSmoke == [SmokeRequest(method: "GET", path: "/", expectStatus: 200), SmokeRequest(method: "GET", path: "/health")])
        #expect(r.siteExpectText == "Welcome")
        let stored = try #require(try fx.store.release(companyId: fx.company.id, ref: r.ref))
        #expect(stored.smokeCheck == r.smokeCheck && stored.siteSmoke == r.siteSmoke && stored.siteExpectText == r.siteExpectText)
        #expect(stored.deployStartedAt == nil)
    }

    @Test func redMainBlocksProposal() throws {
        let notRun = try Self.fixture(passed: false)
        let sha = String(notRun.main.prefix(7))
        #expect(notRun.message("0.1.0") == "the smoke check has not run on main \(sha) yet")
        try notRun.smoke(.failed, exit: 3)
        #expect(notRun.message("0.1.0") == "main is red: the smoke check failed at \(sha) (exit 3)")
        #expect(try notRun.store.releases(companyId: notRun.company.id).isEmpty)
        #expect(try notRun.store.asks(companyId: notRun.company.id).filter { $0.kind == .deploy }.isEmpty)
    }

    @Test func refusalsInOrder() throws {
        let fx = try Self.fixture()
        // 1. The version.
        #expect(fx.message("bad version!") == "release versions are 1–32 letters, digits, '.', '+' or '-'")
        #expect(fx.message(String(repeating: "1", count: 33)) == "release versions are 1–32 letters, digits, '.', '+' or '-'")
        let (r1, ask1) = try fx.propose("0.1.0")
        // 2. A duplicate version, before the open release.
        #expect(fx.message("0.1.0") == "release 0.1.0 already exists")
        // 3. Another open release.
        #expect(fx.message("0.2.0") == "R-1 is still proposed")
        // Rejected: the release is rejected; a duplicate version stays refused, a new one is allowed.
        try fx.store.ownerDecide(askId: ask1.id, approve: false, note: "not yet", owner: .test)
        #expect(try fx.store.release(companyId: fx.company.id, ref: r1.ref)?.status == .rejected)
        #expect(fx.message("0.1.0") == "release 0.1.0 already exists")
        // 6. No npm: refused and the owner is told.
        #expect(fx.message("0.2.0", npm: false) == "deploying needs Node.js (npm) on this Mac; the owner has been told")
        #expect(try fx.store.allNotices().contains { $0.companyId == fx.company.id && $0.title.contains("Node.js") })
        #expect(try fx.store.releases(companyId: fx.company.id).count == 1)
        // 4. No deploy config (before the smoke check and npm).
        let bare = try Self.fixture(deployConfig: false, smokeCheck: false)
        #expect(bare.message("0.1.0", npm: false) == "set_deploy_config first (output_dir is missing)")
        // 5 before 6 and 7.
        let noSmoke = try Self.fixture(token: false, smokeCheck: false)
        #expect(noSmoke.message("0.1.0", npm: false) == "set_smoke_check first; deploys need a smoke check on main")
        // 6 before 7; 7 before 8.
        let red = try Self.fixture(token: false, passed: false)
        #expect(red.message("0.1.0", npm: false) == "deploying needs Node.js (npm) on this Mac; the owner has been told")
        #expect(red.message("0.1.0")?.hasPrefix("The hosting token is missing; I asked the owner (A-") == true)
        // Only ops roles propose.
        let eng = try fx.store.hire(companyId: fx.company.id, name: "eng-1", role: "engineer", model: "m")
        #expect(fx.message("0.3.0", by: eng.id) == "propose_deploy is not available to your role")
    }

    @Test func missingTokenFilesHostingTask() throws {
        // Final-review m10: the refusal names what is actually missing.
        for (token, account, missing) in [(false, true, "The hosting token is missing"), (true, false, "The hosting account ID is missing"),
                                          (false, false, "The hosting token and account ID are missing")] {
            let fx = try Self.fixture(token: token, account: account)
            let first = try #require(fx.message("0.1.0"))
            let asks = try fx.store.asks(companyId: fx.company.id).filter { $0.kind != .deploy }
            try #require(asks.count == 1)
            let task = asks[0]
            #expect(first == "\(missing); I asked the owner (\(task.ref)). Propose again when it is done.")
            // Task 9 (PR-28): the hosting-account human task, filed by the engine, no quota charged to the agent.
            #expect(task.kind == .humanTask); #expect(task.requesterId == "system"); #expect(task.status == .pendingOwner)
            #expect(HumanTask.from(task)?.template == .hostingAccount)
            #expect(HumanTask.from(task)?.fields.map(\.name) == ["CLOUDFLARE_API_TOKEN", "account_id"])
            #expect(task.title == "Create a Cloudflare account and an API token")
            // Deduped: a second propose names the same ask.
            #expect(fx.message("0.1.0") == first)
            #expect(try fx.store.asks(companyId: fx.company.id).count == 1)
            #expect(try fx.store.releases(companyId: fx.company.id).isEmpty)
        }
        #expect(HumanTasks.hostingAccount(.vercel).title == "Create a Vercel account and a token")
    }

    @Test func releaseKindRedirected() throws {
        let fx = try Self.fixture()
        let tools = CompanyTools(store: fx.store, companyId: fx.company.id, agentId: fx.devops.id)
        do {
            _ = try tools.call(name: "propose_decision", arguments: ["kind": .string("Release"), "title": .string("Ship 0.1.0"),
                                                                    "summary": .string("ready")])
            Issue.record("release kind accepted")
        } catch let e as ToolError {
            #expect(e.message == "propose releases with propose_deploy so they carry the exact deploy and rollback commands")
        }
        #expect(try fx.store.asks(companyId: fx.company.id).isEmpty)
        // The devops card points at propose_deploy, never at propose_decision for the release (PR-26).
        let card = SoftwarePack.pack.roles.first { $0.id == "devops" }?.prompt ?? ""
        #expect(card.contains("propose_deploy")); #expect(!card.contains("raise the release ask with propose_decision"))
        // The tool proposes through the store; its refusals reach the agent verbatim.
        do { _ = try tools.call(name: "propose_deploy", arguments: ["version": .string("no way")]); Issue.record("bad version accepted") }
        catch let e as ToolError { #expect(e.message == "release versions are 1–32 letters, digits, '.', '+' or '-'") }
    }

    // MARK: The owner's decision

    @Test func approvalAppliesOnce() throws {
        let fx = try Self.fixture()
        let (r, ask) = try fx.propose("0.1.0")
        let t1 = Date(timeIntervalSince1970: 1_800_000_100)
        let approved = try fx.store.ownerDecide(askId: ask.id, approve: true, now: t1, owner: .test)
        var row = try #require(try fx.store.release(companyId: fx.company.id, ref: r.ref))
        #expect(row.status == .approved); #expect(row.approvedBy == "owner"); #expect(row.approvedAt == t1)
        // Re-applying the effect is a no-op; so is applying it once the executor has moved on.
        try fx.store.writer.write { db in try fx.store.applyAskEffects(db, ask: approved, now: t1.addingTimeInterval(60)) }
        #expect(try fx.store.release(companyId: fx.company.id, ref: r.ref) == row)
        try fx.setStatus(r, .building)
        row.status = .building
        try fx.store.writer.write { db in try fx.store.applyAskEffects(db, ask: approved, now: t1.addingTimeInterval(120)) }
        #expect(try fx.store.release(companyId: fx.company.id, ref: r.ref) == row)
        // An open approved release blocks the next proposal.
        #expect(fx.message("0.2.0") == "R-1 is still building")
    }

    @Test func rescindBeforeStartCancels() throws {
        let fx = try Self.fixture()
        let (r1, ask1) = try fx.propose("0.1.0")
        try fx.store.ownerDecide(askId: ask1.id, approve: true, owner: .test)
        try fx.store.ownerRescind(askId: ask1.id, note: "wait", owner: .test)
        #expect(try fx.store.release(companyId: fx.company.id, ref: r1.ref)?.status == .cancelled)
        #expect(try !fx.store.allNotices().contains { $0.title.contains("already started") })
        // Rescinded after the executor started: nothing changes, the owner is told how to undo it.
        let (r2, ask2) = try fx.propose("0.2.0")
        try fx.store.ownerDecide(askId: ask2.id, approve: true, owner: .test)
        try fx.setStatus(r2, .deploying)
        try fx.store.ownerRescind(askId: ask2.id, owner: .test)
        #expect(try fx.store.release(companyId: fx.company.id, ref: r2.ref)?.status == .deploying)
        let notice = try #require(try fx.store.allNotices().last { $0.companyId == fx.company.id })
        #expect(notice.title == "R-2 already started")
        #expect(notice.body == "Use Roll back in Releases if you want it undone.")
    }

    @Test func crossCompanyReleaseInvisible() throws {
        let fx = try Self.fixture()
        let (r, _) = try fx.propose("0.1.0")
        let globex = try fx.store.createCompany(name: "Globex", goal: "g", workspacesRoot: try tempDir())
        let theirs = try fx.store.hire(companyId: globex.id, name: "devops-1", role: "devops", model: "m")
        #expect(fx.message("0.2.0", by: theirs.id) == "not in your company")
        #expect(try fx.store.release(companyId: globex.id, ref: "R-1") == nil)
        #expect(try fx.store.releases(companyId: globex.id).isEmpty)
        #expect(try fx.store.release(companyId: fx.company.id, ref: "R-1")?.id == r.id)
        // Globex's tool resolves its own company only: it has no deploy config, so nothing of Acme's is touched.
        let tools = CompanyTools(store: fx.store, companyId: globex.id, agentId: theirs.id)
        do { _ = try tools.call(name: "propose_deploy", arguments: ["version": .string("0.2.0")]); Issue.record("proposed") }
        catch let e as ToolError { #expect(e.message == "set_deploy_config first (output_dir is missing)") }
        #expect(try fx.store.releases(companyId: fx.company.id).count == 1)
    }
}
