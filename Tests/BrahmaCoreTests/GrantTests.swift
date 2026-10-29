import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Task 9: access asks (`request_access`), the owner's scoped grants, how they compile into a sandboxed turn, the ledger,
/// and what kills and revocations do to them.
struct GrantWorld {
    let world: World
    let company: Company
    let eng: Agent

    init() throws {
        world = try World()
        company = try world.company("Acme", profile: .sandboxed)
        eng = try world.store.hire(companyId: company.id, name: "eng-1", role: "engineer", model: "sonnet")
    }

    var store: Store { world.store }
    func tools(_ agent: Agent? = nil) -> CompanyTools { CompanyTools(store: store, companyId: company.id, agentId: (agent ?? eng).id) }

    /// `request_access` as the agent calls it.
    @discardableResult
    func request(_ kind: String, _ value: String, by agent: Agent? = nil, item: String? = nil, scope: String? = nil,
                 duration: String? = nil) throws -> String {
        var args: [String: JSONValue] = ["kind": .string(kind), "value": .string(value), "reason": .string("I need it")]
        if let item { args["item"] = .string(item) }
        if let scope { args["scope"] = .string(scope) }
        if let duration { args["duration"] = .string(duration) }
        return try tools(agent).call(name: "request_access", arguments: args)
    }

    func ask(_ ref: String) throws -> Ask { try #require(try store.ask(companyId: company.id, ref: ref)) }

    /// Files an ask and approves it the owner's way; returns the grant.
    @discardableResult
    func grant(_ kind: String, _ value: String, by agent: Agent? = nil, item: String? = nil, scope: GrantScope,
               duration: GrantDuration) throws -> Grant {
        _ = try request(kind, value, by: agent, item: item)
        let ask = try #require(try store.asks(companyId: company.id).last { $0.kind == .grant })
        return try store.approveAccess(askId: ask.id, scope: scope, duration: duration, note: "ok", userHome: world.userHome)
    }

    /// The scope of the agent's next sandboxed turn.
    func nextScope(_ agent: Agent? = nil) async throws -> SandboxScope {
        let a = agent ?? eng
        try world.dm(company, a)
        try await world.cycle()
        let r = try #require(world.fake.requests.last { $0.agent.id == a.id })
        return try #require(r.sandbox)
    }

    func item(_ title: String = "Do it") throws -> WorkItem {
        try store.createWorkItem(companyId: company.id, by: .owner, draft: WorkItemDraft(
            type: .task, title: title, acceptanceCriteria: "it works", checkSpec: CheckSpec(command: "true", paths: ["src/a"]),
            status: .ready), now: world.clock.now)
    }
}

/// The message of a refusal (`ToolError` or `WorkError`), or nil when the call succeeded.
func refusal(_ body: () throws -> Any) -> String? {
    do { _ = try body(); return nil } catch let e as ToolError { return e.message } catch let e as WorkError { return e.message } catch {
        return "\(error)"
    }
}

@Suite struct GrantTests {
    @Test func requestCreatesGrantAsk() throws {
        let g = try GrantWorld()
        let reply = try g.request("web_domain", "Docs.Example.com")
        #expect(reply == "Requested A-1 (web_domain docs.example.com). The owner will decide; you'll get a notice. "
                + "Grants take effect from your next turn.")
        let ask = try g.ask("A-1")
        #expect(ask.kind == .grant); #expect(ask.category == "tooling"); #expect(ask.status == .pendingOwner)
        #expect(ask.risk == .low); #expect(ask.title == "web_domain docs.example.com"); #expect(ask.summary == "I need it")
        #expect(ask.proposedGrant == ProposedGrant(scope: "agent", durationSeconds: nil))
        let details = try #require(Grants.requested(ask))
        #expect(details.kind == .webDomain); #expect(details.value == "docs.example.com"); #expect(details.duration == .sprint)
        _ = try g.request("network_domain", "api.example.com", scope: "role", duration: "always")
        let net = try g.ask("A-2")
        #expect(net.risk == .medium); #expect(net.proposedGrant?.scope == "role")
        #expect(Grants.requested(net)?.duration == .always)
        #expect(GrantKind.webDomain.risk == .low)
        #expect([GrantKind.networkDomain, .readPath, .extension].allSatisfy { $0.risk == .medium })
    }

    @Test func invalidValuesRefused() throws {
        let g = try GrantWorld()
        for (kind, value) in [("network_domain", "localhost"), ("network_domain", "*"), ("network_domain", "10.0.0.1"),
                              ("web_domain", "api.anthropic.com"), ("read_path", "~/.ssh"), ("read_path", "/Volumes/X"),
                              ("read_path", "/Volumes"), ("read_path", "relative/dir"), ("read_path", "/no/such/dir-\(UUID())"),
                              ("plugin", "x"), ("network_domain", "a.example.com\n")] {
            #expect(refusal { try g.request(kind, value) } != nil, "\(kind) \(value.debugDescription) should be refused")
        }
        // An extension is refused until extensions are installable (Task 5a).
        #expect(refusal { try g.request("extension", "acme/linter") }
                == "No extension 'acme/linter'. Build one in your lab and use propose_extension.")
        #expect(try g.store.asks(companyId: g.company.id).isEmpty, "nothing was filed")

        // Read paths: protected places of the owner's home, the data home, other workspaces, /Volumes.
        let home = try tempDir()
        let ssh = home.appending(path: ".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        let data = try tempDir(), other = try tempDir(), ok = try tempDir()
        let paths = BrahmaPaths(home: data, workspaces: data.deletingLastPathComponent())
        func validate(_ v: String) throws -> String {
            try Grants.validate(kind: .readPath, value: v, company: g.company, paths: paths, userHome: home, otherWorkspaces: [other],
                                backupTargets: [])
        }
        for bad in [ssh.path, data.path, other.path, home.path, "/Volumes", "/"] {
            #expect(throws: (any Error).self, "\(bad)") { try validate(bad) }
        }
        #expect(try validate(ok.path) == ok.resolvedForSandbox.path)
    }

    @Test func publicSuffixWildcardRefused() throws {
        let g = try GrantWorld()
        for value in ["*.github.io", "*.vercel.app", "*.co.uk", "*.com"] {
            #expect(refusal { try g.request("web_domain", value) } != nil, "\(value)")
            #expect(refusal { try g.request("network_domain", value) } != nil, "\(value)")
        }
        #expect(try g.request("network_domain", "*.example.com").hasPrefix("Requested A-1"))
    }

    @Test func dedupeAndQuota() throws {
        let g = try GrantWorld()
        let other = try g.store.hire(companyId: g.company.id, name: "eng-2", role: "engineer", model: "sonnet")
        _ = try g.request("web_domain", "a.example.com")
        #expect(try g.request("web_domain", "A.example.com.") == "Already requested as A-1.")
        #expect(try g.request("web_domain", "a.example.com", by: other) == "Already requested as A-1.", "deduped company-wide")
        // The same value of another kind is another request.
        #expect(try g.request("network_domain", "a.example.com").hasPrefix("Requested A-2"))
        _ = try g.request("web_domain", "b.example.com")
        // Three open asks: the quota refuses the fourth (before the dedupe).
        #expect(refusal { try g.request("web_domain", "c.example.com") } == AskQuota.refusal)
        #expect(refusal { try g.request("web_domain", "a.example.com") } == AskQuota.refusal)
        #expect(try g.store.asks(companyId: g.company.id).count == 3)
        // Rejected asks free the quota and the dedupe.
        _ = try g.store.ownerDecide(askId: try g.ask("A-1").id, approve: false)
        #expect(try g.request("web_domain", "a.example.com").hasPrefix("Requested A-4"))
    }

    @Test func crossCompanyAskRefused() throws {
        let g = try GrantWorld()
        let bolt = try g.world.company("Bolt", profile: .sandboxed)
        let boltEng = try g.store.hire(companyId: bolt.id, name: "bolt-eng", role: "engineer", model: "sonnet")
        let boltItem = try g.store.createWorkItem(companyId: bolt.id, by: .owner, draft: WorkItemDraft(
            type: .task, title: "Theirs", acceptanceCriteria: "x", status: .ready))
        // An agent of another company files nothing here, through the tool or the store.
        let viaTool = CompanyTools(store: g.store, companyId: g.company.id, agentId: boltEng.id)
        #expect(refusal { try viaTool.call(name: "request_access", arguments: ["kind": .string("web_domain"), "value": .string("x.example.com"), "reason": .string("r")]) } != nil)
        #expect(throws: WorkError.forbidden("not in your company")) {
            try g.store.requestAccess(companyId: g.company.id, agentId: boltEng.id, kind: .webDomain, value: "x.example.com", reason: "r")
        }
        // Another company's item is out of reach.
        #expect(throws: WorkError.forbidden("not in your company")) {
            try g.store.requestAccess(companyId: g.company.id, agentId: g.eng.id, kind: .webDomain, value: "x.example.com", reason: "r",
                                      itemId: boltItem.id)
        }
        #expect(refusal { try g.request("web_domain", "x.example.com", item: boltItem.key) } != nil)
        // Another company's ask cannot be approved as a grant in this one, nor its grant revoked from here.
        _ = try g.request("web_domain", "x.example.com")
        let ask = try g.ask("A-1")
        let granted = try g.store.approveAccess(askId: ask.id, scope: .agent, duration: .always, note: "", userHome: g.world.userHome)
        #expect(throws: WorkError.self) { try g.store.revokeGrant(companyId: bolt.id, number: granted.number, by: "owner") }
        #expect(try g.store.asks(companyId: bolt.id).isEmpty)
    }

    @Test func approveAgentSprintCompilesIntoNextTurn() async throws {
        let g = try GrantWorld()
        let other = try g.store.hire(companyId: g.company.id, name: "eng-2", role: "engineer", model: "sonnet")
        _ = try g.request("network_domain", "api.example.com")
        _ = try g.request("web_domain", "docs.example.com")
        #expect(!(try await g.nextScope()).network.allowedDomains.contains("api.example.com"), "not before the owner decides")
        let net = try g.store.approveAccess(askId: try g.ask("A-1").id, scope: .agent, duration: .sprint, note: "fine",
                                            userHome: g.world.userHome)
        let web = try g.store.approveAccess(askId: try g.ask("A-2").id, scope: .agent, duration: .sprint, note: "",
                                            userHome: g.world.userHome)
        #expect(net.ref == "G-1"); #expect(web.ref == "G-2")
        #expect(net.kind == .networkDomain); #expect(net.value == "api.example.com"); #expect(net.scope == .agent)
        #expect(net.scopeRef == g.eng.id); #expect(net.requesterId == g.eng.id); #expect(net.duration == .sprint)
        #expect(net.approvedBy == "owner"); #expect(net.askId == (try g.ask("A-1")).id); #expect(net.usesLeft == nil)
        #expect(try g.ask("A-1").status == .approved); #expect(try g.ask("A-1").decidedBy == "owner")
        let scope = try await g.nextScope()
        #expect(scope.network.allowedDomains.contains("api.example.com"))
        #expect(!scope.network.webDomains.contains("api.example.com"), "a Bash domain is not a WebFetch domain")
        #expect(scope.network.webDomains.contains("docs.example.com"))
        #expect(!scope.network.allowedDomains.contains("docs.example.com"))
        // Only the requester: an agent-scope grant is not its teammate's.
        let theirs = try await g.nextScope(other)
        #expect(!theirs.network.allowedDomains.contains("api.example.com"))
        // The ledger counts the use.
        let used = try #require(try g.store.grants(companyId: g.company.id).first { $0.number == 1 })
        #expect(used.useCount >= 1); #expect(used.lastUsedAt != nil)
        // Approving again is refused; a non-grant ask is not approved as one.
        #expect(throws: WorkError.self) {
            try g.store.approveAccess(askId: try g.ask("A-1").id, scope: .agent, duration: .sprint, note: "", userHome: g.world.userHome)
        }
    }

    @Test func plainOwnerApproveCreatesTheRequestedGrant() throws {
        let g = try GrantWorld()
        _ = try g.request("web_domain", "docs.example.com", scope: "role", duration: "always")
        _ = try g.store.ownerDecide(askId: try g.ask("A-1").id, approve: true, note: "yes")
        let grant = try #require(try g.store.grants(companyId: g.company.id).first)
        #expect(grant.scope == .role); #expect(grant.scopeRef == "engineer"); #expect(grant.duration == .always)
        #expect(grant.approvedBy == "owner")
        // A rejected ask grants nothing.
        _ = try g.request("web_domain", "other.example.com")
        _ = try g.store.ownerDecide(askId: try g.ask("A-2").id, approve: false)
        #expect(try g.store.grants(companyId: g.company.id, includeInactive: true).count == 1)
        // Rescinding the approval takes the grant with it.
        _ = try g.store.ownerRescind(askId: try g.ask("A-1").id)
        #expect(try g.store.grants(companyId: g.company.id).isEmpty)
        #expect(try g.store.grants(companyId: g.company.id, includeInactive: true).first?.revokedBy == "owner")
    }

    @Test func onceGrantUsedByOneTurn() async throws {
        let g = try GrantWorld()
        let grant = try g.grant("network_domain", "once.example.com", scope: .once, duration: .always)
        #expect(grant.usesLeft == 1)
        let turnGrant = try g.grant("network_domain", "turn.example.com", scope: .agent, duration: .turn)
        #expect(turnGrant.usesLeft == 1)
        let first = try await g.nextScope()
        #expect(first.network.allowedDomains.contains("once.example.com"))
        #expect(first.network.allowedDomains.contains("turn.example.com"))
        let second = try await g.nextScope()
        #expect(!second.network.allowedDomains.contains("once.example.com"))
        #expect(!second.network.allowedDomains.contains("turn.example.com"))
        let after = try g.store.grants(companyId: g.company.id, includeInactive: true)
        #expect(after.allSatisfy { $0.usesLeft == 0 && $0.useCount == 1 })
        #expect(try g.store.grants(companyId: g.company.id).isEmpty, "used up: no longer active")
        // Consuming a used-up grant takes nothing.
        #expect(try g.store.consumeGrants(ids: [grant.id], turnId: "t", now: Date()).isEmpty)
    }

    @Test func itemScopeFollowsItem() async throws {
        let g = try GrantWorld()
        let item = try g.item(), otherItem = try g.item("Other")
        _ = try g.tools().call(name: "claim_lease", arguments: ["key": .string(item.key)])
        let grant = try g.grant("network_domain", "item.example.com", item: item.key, scope: .item, duration: .always)
        #expect(grant.scopeRef == item.id)
        let other = try g.store.hire(companyId: g.company.id, name: "eng-2", role: "engineer", model: "sonnet")
        let active = { (agent: Agent, itemId: String?) in try g.store.activeGrants(agent: agent, itemId: itemId).map(\.id) }
        #expect(try active(g.eng, item.id) == [grant.id])
        #expect(try active(other, item.id) == [grant.id], "whoever works the item")
        #expect(try active(g.eng, otherItem.id).isEmpty); #expect(try active(g.eng, nil).isEmpty)
        // The leaseholder's turn on the item gets it.
        #expect((try await g.nextScope()).network.allowedDomains.contains("item.example.com"))
        // An item scope needs an item on the ask.
        _ = try g.request("network_domain", "noitem.example.com")
        #expect(throws: WorkError.self) {
            try g.store.approveAccess(askId: try g.ask("A-2").id, scope: .item, duration: .always, note: "", userHome: g.world.userHome)
        }
    }

    @Test func roleScopeCoversMergedRoles() throws {
        let g = try GrantWorld()
        let arch = try g.store.hire(companyId: g.company.id, name: "arch-1", role: "architect", model: "sonnet")
        let cto = try g.store.hire(companyId: g.company.id, name: "cto-1", role: "cto-architect", model: "sonnet")
        let grant = try g.grant("network_domain", "role.example.com", by: arch, scope: .role, duration: .always)
        #expect(grant.scopeRef == "architect")
        #expect(try g.store.activeGrants(agent: arch, itemId: nil).map(\.id) == [grant.id])
        #expect(try g.store.activeGrants(agent: cto, itemId: nil).map(\.id) == [grant.id], "cto-architect covers architect")
        #expect(try g.store.activeGrants(agent: g.eng, itemId: nil).isEmpty)
        // A company grant reaches everyone.
        let all = try g.grant("web_domain", "all.example.com", scope: .company, duration: .always)
        #expect(try g.store.activeGrants(agent: g.eng, itemId: nil).map(\.id) == [all.id])
    }

    @Test func sprintGrantExpiresWithSprint() throws {
        let g = try GrantWorld()
        let sprint = Sprint(id: UUID().uuidString, companyId: g.company.id, number: 1, team: nil, goal: "g", cadence: .sprint,
                            status: .active, createdAt: Date())
        try g.store.writer.write { db in try sprint.insert(db) }
        let grant = try g.grant("network_domain", "sprint.example.com", scope: .agent, duration: .sprint)
        #expect(grant.sprintId == sprint.id); #expect(grant.expiresActive == nil)
        #expect(try g.store.activeGrants(agent: g.eng, itemId: nil).count == 1)
        try g.store.writer.write { db in
            try db.execute(sql: "UPDATE sprint SET status = ? WHERE id = ?", arguments: [SprintStatus.closed.rawValue, sprint.id])
        }
        #expect(try g.store.activeGrants(agent: g.eng, itemId: nil).isEmpty)
        #expect(try g.store.grants(companyId: g.company.id).isEmpty)
        #expect(try g.store.grants(companyId: g.company.id, includeInactive: true).count == 1)
    }

    @Test func noSprintMeansSevenActiveDays() throws {
        let g = try GrantWorld()
        #expect(GrantResolver.noSprintTTL == 7 * 86_400)
        try g.store.advanceActive(companyId: g.company.id, by: 100)
        let wall = g.world.clock.now
        let grant = try g.grant("network_domain", "week.example.com", scope: .agent, duration: .sprint)
        #expect(grant.sprintId == nil); #expect(grant.expiresActive == 100 + GrantResolver.noSprintTTL)
        try g.store.advanceActive(companyId: g.company.id, by: GrantResolver.noSprintTTL - 1)
        #expect(try g.store.activeGrants(agent: g.eng, itemId: nil).count == 1)
        try g.store.advanceActive(companyId: g.company.id, by: 2)
        #expect(try g.store.activeGrants(agent: g.eng, itemId: nil).isEmpty, "seven active days, whatever the clock says")
        #expect(g.world.clock.now == wall)
    }

    @Test func revokeTakesEffectNextTurn() async throws {
        let g = try GrantWorld()
        let grant = try g.grant("network_domain", "revoke.example.com", scope: .agent, duration: .always)
        #expect((try await g.nextScope()).network.allowedDomains.contains("revoke.example.com"))
        let revoked = try g.store.revokeGrant(companyId: g.company.id, number: grant.number, by: "owner")
        #expect(revoked.revokedAt != nil); #expect(revoked.revokedBy == "owner")
        #expect(!(try await g.nextScope()).network.allowedDomains.contains("revoke.example.com"))
        #expect(throws: WorkError.self) { try g.store.revokeGrant(companyId: g.company.id, number: grant.number, by: "owner") }
        #expect(throws: WorkError.self) { try g.store.revokeGrant(companyId: g.company.id, number: 99, by: "owner") }
    }

    @Test func killRevokesAgentGrants() throws {
        let g = try GrantWorld()
        let agentGrant = try g.grant("network_domain", "a.example.com", scope: .agent, duration: .always)
        let onceGrant = try g.grant("network_domain", "b.example.com", scope: .once, duration: .always)
        let roleGrant = try g.grant("network_domain", "c.example.com", scope: .role, duration: .always)
        try g.store.transition(agentId: g.eng.id, to: .killed)
        let all = try g.store.grants(companyId: g.company.id, includeInactive: true)
        for id in [agentGrant.id, onceGrant.id] {
            let gr = try #require(all.first { $0.id == id })
            #expect(gr.revokedAt != nil); #expect(gr.revokedBy == "kill")
        }
        #expect(all.first { $0.id == roleGrant.id }?.revokedAt == nil, "a role grant outlives the agent")
    }

    @Test func readPathGrantIsReadOnly() async throws {
        let g = try GrantWorld()
        let dir = try tempDir()
        _ = try g.store.requestAccess(companyId: g.company.id, agentId: g.eng.id, kind: .readPath, value: dir.path, reason: "data",
                                      userHome: g.world.userHome)
        let ask = try g.ask("A-1")
        #expect(ask.risk == .medium)
        let grant = try g.store.approveAccess(askId: ask.id, scope: .agent, duration: .always, note: "", userHome: g.world.userHome)
        #expect(grant.value == dir.resolvedForSandbox.path)
        let scope = try await g.nextScope()
        let resolved = dir.resolvedForSandbox.path
        #expect(scope.readOnlyDirs.map(\.path).contains(resolved))
        #expect(scope.readable.map(\.path).contains(resolved))
        #expect(!scope.writable.map(\.path).contains { SandboxPath.isInside($0, resolved) || SandboxPath.isInside(resolved, $0) })
        #expect(scope.cwd.path != resolved)
        let r = try #require(g.world.fake.requests.last)
        #expect(TurnProfileCompiler.profile(for: r).addDirs.contains(resolved))
    }

    @Test func ownerOnlyCLI() throws {
        let home = try OwnerTestHome()
        let paths = ownerPaths(home.url)
        let store = try Store(path: paths.database.path, backupsDir: paths.backupsDir)
        let company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: paths.workspaces)
        let eng = try store.hire(companyId: company.id, name: "eng-1", role: "engineer", model: "sonnet")
        _ = try store.requestAccess(companyId: company.id, agentId: eng.id, kind: .webDomain, value: "docs.example.com",
                                    reason: "read \u{1b}[31mdocs")
        try store.close()
        let asAgent = ["BRAHMA_AGENT_ID": eng.id]
        for args in [["access", "acme"], ["access", "approve", "acme", "A-1", "--scope", "agent", "--duration", "always"],
                     ["grants", "acme"], ["grants", "revoke", "acme", "G-1"], ["presets", "acme"],
                     ["presets", "acme", "enable", "auto-low-risk"]] {
            let r = try runBrahma(args, home: home.url, extra: asAgent)
            #expect(r.status != 0 && r.stderr.contains("owner commands"), "\(args)")
        }
        let noOwner = try OwnerTestHome(initOwner: false)
        #expect(try runBrahma(["access", "acme"], home: noOwner.url).status != 0)

        let list = try runBrahma(["access", "acme"], home: home.url)
        #expect(list.status == 0, "\(list.stderr)")
        #expect(list.stdout.contains("A-1") && list.stdout.contains("web_domain docs.example.com") && list.stdout.contains("@eng-1"))
        #expect(!list.stdout.contains("\u{1b}"))
        #expect(try runBrahma(["access", "approve", "acme", "A-1", "--scope", "galaxy"], home: home.url).status != 0)
        let approve = try runBrahma(["access", "approve", "acme", "A-1", "--scope", "agent", "--duration", "always"], home: home.url)
        #expect(approve.status == 0, "\(approve.stderr)")
        #expect(approve.stdout.contains("G-1"))
        let grants = try runBrahma(["grants", "acme"], home: home.url)
        #expect(grants.status == 0 && grants.stdout.contains("G-1") && grants.stdout.contains("docs.example.com"), "\(grants.stderr)")
        let revoke = try runBrahma(["grants", "revoke", "acme", "G-1"], home: home.url)
        #expect(revoke.status == 0, "\(revoke.stderr)")
        #expect(!(try runBrahma(["grants", "acme"], home: home.url)).stdout.contains("G-1"))
        #expect(try runBrahma(["grants", "acme", "--all"], home: home.url).stdout.contains("G-1"))
        let presets = try runBrahma(["presets", "acme"], home: home.url)
        #expect(presets.status == 0 && presets.stdout.contains("readonly-web-engineers") && presets.stdout.contains("off"), "\(presets.stderr)")
        #expect(try runBrahma(["presets", "acme", "enable", "readonly-web-engineers"], home: home.url).status == 0)
        #expect(try runBrahma(["presets", "acme", "enable", "everything"], home: home.url).status != 0)
        let on = try Store(path: paths.database.path, backupsDir: paths.backupsDir)
        #expect(try on.enabledPresets(companyId: company.id) == [.readOnlyWebForEngineers])
        try on.close()
    }
}
