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
    /// The owner's machine as the World's orchestrator sees it (a temp home, no Darwin temp dir).
    var env: SandboxEnvironment { SandboxEnvironment(userHome: world.userHome, darwinUserTemp: nil, shell: "/bin/zsh") }
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
        return try store.approveAccess(askId: ask.id, scope: scope, duration: duration, note: "ok", environment: env)
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

@Suite(.scratch) struct GrantTests {
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
        // An extension is refused until extensions are installable (Task 5a).
        #expect(refusal { try g.request("extension", "acme/linter") }
                == "No extension 'acme/linter'. Build one in your lab and use propose_extension.")
        for (kind, value) in [("network_domain", "localhost"), ("network_domain", "*"), ("network_domain", "10.0.0.1"),
                              ("web_domain", "api.anthropic.com"), ("plugin", "x"), ("network_domain", "a.example.com\n")] {
            #expect(refusal { try g.request(kind, value) } != nil, "\(kind) \(value.debugDescription) should be refused")
        }
        #expect(try g.store.asks(companyId: g.company.id).isEmpty, "nothing was filed")
        // Every read-path refusal reads the same to the agent (no probe of the owner's tree); the owner sees why.
        let other = try g.store.hire(companyId: g.company.id, name: "eng-2", role: "engineer", model: "sonnet")
        for value in ["~/.ssh", "/Volumes/X", "/Volumes", "relative/dir", "/no/such/dir-\(UUID())"] {
            #expect(refusal { try g.request("read_path", value, by: other) } == Grants.pathRefusal, "\(value)")
        }
        let refused = try g.store.accessRefusals(companyId: g.company.id)
        #expect(refused.count >= 5); #expect(refused.contains { $0.value == "/Volumes" && !$0.detail.isEmpty })

        // Read paths: protected places of the owner's home, the data home, other workspaces, /Volumes.
        let home = try tempDir()
        let ssh = home.appending(path: ".ssh")
        try FileManager.default.createDirectory(at: ssh, withIntermediateDirectories: true)
        let data = try tempDir(), otherWs = try tempDir(), ok = try tempDir(), temp = try tempDir()
        let ownWs = URL(fileURLWithPath: g.company.workspacePath).appending(path: "docs")
        try FileManager.default.createDirectory(at: ownWs, withIntermediateDirectories: true)
        let inTemp = temp.appending(path: "data")
        try FileManager.default.createDirectory(at: inTemp, withIntermediateDirectories: true)
        let paths = BrahmaPaths(home: data, workspaces: data.deletingLastPathComponent())
        let env = SandboxEnvironment(userHome: home, darwinUserTemp: temp, shell: "/bin/zsh")
        func validate(_ v: String) throws -> String {
            try Grants.validate(kind: .readPath, value: v, company: g.company, paths: paths, environment: env, otherWorkspaces: [otherWs],
                                backupTargets: [])
        }
        // Protected places, and every place a turn can write: the workspace (its .git and .brahma too) and the Darwin temp dir.
        for bad in [ssh.path, data.path, otherWs.path, home.path, "/Volumes", "/", ownWs.path, g.company.workspacePath,
                    g.company.workspacePath + "/.git", temp.path, inTemp.path] {
            #expect(throws: (any Error).self, "\(bad)") { try validate(bad) }
        }
        #expect(try validate(ok.path) == ok.resolvedForSandbox.path)
    }

    @Test func publicSuffixWildcardRefused() throws {
        let g = try GrantWorld()
        let bad = ["*.github.io", "*.vercel.app", "*.co.uk", "*.com", "*.foo.github.io", "*.s3.us-east-1.amazonaws.com",
                   "*.trycloudflare.com", "*.fly.dev", "*.onrender.com", "*.r2.dev", "*.ngrok.app", "*.web.core.windows.net"]
        for value in bad {
            #expect(throws: (any Error).self, "\(value)") {
                try Grants.validate(kind: .webDomain, value: value, company: g.company, paths: g.world.paths, environment: g.env)
            }
        }
        // Bash egress grants are exact hosts only; a web grant may be a wildcard under a registrable name.
        #expect(refusal { try g.request("network_domain", "*.example.com") } != nil)
        #expect(try g.request("web_domain", "*.example.com").hasPrefix("Requested A-1"))
        #expect(try g.request("network_domain", "api.fly.dev").hasPrefix("Requested A-2"), "an exact host under one is fine")
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
        let granted = try g.store.approveAccess(askId: ask.id, scope: .agent, duration: .always, note: "", environment: g.env)
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
                                            environment: g.env)
        let web = try g.store.approveAccess(askId: try g.ask("A-2").id, scope: .agent, duration: .sprint, note: "",
                                            environment: g.env)
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
            try g.store.approveAccess(askId: try g.ask("A-1").id, scope: .agent, duration: .sprint, note: "", environment: g.env)
        }
    }

    @Test func plainApproveRefusesGrantAsks() throws {
        let g = try GrantWorld()
        _ = try g.request("web_domain", "docs.example.com", scope: "company", duration: "always")
        // The agent's proposal is never applied silently: the owner names the scope and duration.
        let message = refusal { try g.store.ownerDecide(askId: try g.ask("A-1").id, approve: true, note: "yes") }
        #expect(message == "approve access with: brahma access approve \(g.company.slug) A-1 --scope … --duration …")
        #expect(try g.ask("A-1").status == .pendingOwner)
        #expect(try g.store.grants(companyId: g.company.id, includeInactive: true).isEmpty)
        // Rejecting stays a plain decision.
        _ = try g.store.ownerDecide(askId: try g.ask("A-1").id, approve: false)
        #expect(try g.ask("A-1").status == .rejected)
        // Rescinding an approval takes the grant with it, and the ledger says so.
        let grant = try g.grant("web_domain", "other.example.com", scope: .agent, duration: .always)
        _ = try g.store.ownerRescind(askId: try #require(grant.askId))
        #expect(try g.store.grants(companyId: g.company.id).isEmpty)
        #expect(try g.store.grants(companyId: g.company.id, includeInactive: true).first { $0.id == grant.id }?.revokedBy == "owner")
        #expect(try g.store.events(afterId: 0, companyId: g.company.id).contains { $0.text.contains("\(grant.ref) revoked") })
    }

    @Test func refusalsAreRateLimited() throws {
        let g = try GrantWorld()
        for n in 0..<AccessRefusals.perActiveDay {
            #expect(refusal { try g.request("read_path", "/no/such/\(n)") } == Grants.pathRefusal)
        }
        // Even a good request is refused now, and nothing is filed: probing is bounded.
        #expect(refusal { try g.request("web_domain", "fine.example.com") } == AccessRefusals.message)
        #expect(try g.store.asks(companyId: g.company.id).isEmpty)
        // A new active day opens the window again.
        try g.store.advanceActive(companyId: g.company.id, by: AccessRefusals.window + 1)
        #expect(try g.request("web_domain", "fine.example.com").hasPrefix("Requested A-1"))
    }

    @Test func readPathLinkedBeforeApprovalRefused() throws {
        let g = try GrantWorld()
        let root = try tempDir()
        let data = root.appending(path: "data"), secret = root.appending(path: "secret")
        for d in [data, secret] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        _ = try g.store.requestAccess(companyId: g.company.id, agentId: g.eng.id, kind: .readPath, value: data.path, reason: "r",
                                      environment: g.env)
        // The agent swaps the directory for a link before the owner looks.
        try FileManager.default.removeItem(at: data)
        try FileManager.default.createSymbolicLink(at: data, withDestinationURL: secret)
        #expect(throws: (any Error).self) {
            try g.store.approveAccess(askId: try g.ask("A-1").id, scope: .agent, duration: .always, note: "", environment: g.env)
        }
        #expect(try g.ask("A-1").status == .pendingOwner)
        #expect(try g.store.grants(companyId: g.company.id, includeInactive: true).isEmpty)
        // A link anywhere on the way is refused at request time too.
        let via = root.appending(path: "via")
        try FileManager.default.createSymbolicLink(at: via, withDestinationURL: root)
        #expect(!Grants.isPinned(via.appending(path: "secret").path))
        #expect(Grants.isPinned(secret.resolvedForSandbox.path))
    }

    /// Carry-over (Task 9 re-review 2): an alias spelling is refused with its own reason, not as an overlap.
    @Test func aliasSpellingHasItsOwnReason() throws {
        let probe = URL(fileURLWithPath: "/System/Volumes/Data/Applications/Xcode.app/Contents/Developer")
        do {
            try SandboxScope.checkAllowed(probe, protected: [], deniedRoots: [])
            Issue.record("an alias spelling was allowed")
        } catch let e as SandboxError {
            guard case .aliasSpelling(let path, let alias) = e else { Issue.record("\(e)"); return }
            #expect(path == probe.path); #expect(alias == "/System/Volumes")
            #expect(e.description.contains("alias spelling"))
        }
    }

    /// Carry-over: identity roots keep a root that does not exist yet (by the lineage of its existing part), and build the
    /// lineage from the resolved root.
    @Test func identityRootsKeepMissingRootsAndResolveLinks() throws {
        let base = try tempDir().resolvedForSandbox
        let parent = base.appending(path: "parent")
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let missing = parent.appending(path: "not-yet/inside")
        #expect(SandboxPath.IdentityRoots([missing]).overlapping(parent.path) == missing.path, "the parent contains it")
        #expect(SandboxPath.IdentityRoots([missing]).containedIn(base.path) == missing.path, "an ancestor contains it")
        let unrelated = base.appending(path: "unrelated")
        try FileManager.default.createDirectory(at: unrelated, withIntermediateDirectories: true)
        #expect(SandboxPath.IdentityRoots([missing]).overlapping(unrelated.path) == nil)
        let link = base.appending(path: "via")
        try FileManager.default.createSymbolicLink(atPath: link.path, withDestinationPath: parent.path)
        #expect(SandboxPath.IdentityRoots([link.appending(path: "not-yet")]).overlapping(parent.path) != nil)
    }

    /// Carry-over: the check policy validation goes through the same alias/identity helper as turn scopes.
    @Test func sandboxPolicyCheckRefusesAliasSpellings() throws {
        let home = try tempDir().resolvedForSandbox
        let secret = home.appending(path: ".ssh")
        try FileManager.default.createDirectory(at: secret, withIntermediateDirectories: true)
        let writable = try tempDir().resolvedForSandbox
        let baseline = SandboxBaseline(userHome: home, protected: [secret], darwinUserTemp: nil, darwinUserCache: nil)
        let firm = "/System/Volumes/Data" + secret.path
        let policy = SandboxPolicy(writable: [writable], readable: [URL(fileURLWithPath: firm)], network: .none, toolchain: false)
        #expect(throws: SandboxError.self) { try SandboxPolicyCheck.validate(policy, baseline: baseline) }
        let fine = SandboxPolicy(writable: [writable], readable: [], network: .none, toolchain: false)
        try SandboxPolicyCheck.validate(fine, baseline: baseline)
    }

    @Test func aliasSpellingsRefused() throws {
        let g = try GrantWorld()
        let home = try tempDir().resolvedForSandbox
        try FileManager.default.createDirectory(at: home.appending(path: ".ssh"), withIntermediateDirectories: true)
        let x = URL(fileURLWithPath: g.company.workspacePath).appending(path: "x")
        try FileManager.default.createDirectory(at: x, withIntermediateDirectories: true)
        let env = SandboxEnvironment(userHome: home, darwinUserTemp: nil, shell: "/bin/zsh")
        func validate(_ v: String) throws -> String {
            try Grants.validate(kind: .readPath, value: v, company: g.company, paths: g.world.paths, environment: env)
        }
        let ws = URL(fileURLWithPath: g.company.workspacePath).resolvedForSandbox.path
        for bad in ["/System/Volumes/Data" + home.path, "/System/Volumes/Data" + home.path + "/.ssh", "/.nofollow" + home.path,
                    "/.resolve/1" + home.path, "/System/Volumes/Data" + ws + "/x"] {
            #expect(throws: (any Error).self, "\(bad)") { try validate(bad) }
        }
        // By identity (device and inode), the firmlink spelling is the place itself.
        let firm = "/System/Volumes/Data" + home.path
        if SandboxPath.kind(firm) == .directory {
            #expect(SandboxPath.IdentityRoots([home]).overlapping(firm) == home.path)
            #expect(SandboxPath.IdentityRoots([home.appending(path: ".ssh")]).overlapping(firm) != nil, "it contains .ssh")
        }
        // The same helper guards the owner's toolchain paths.
        #expect(throws: (any Error).self) {
            try g.store.updateSandbox(companyId: g.company.id, SandboxPatch(toolchainReadPaths: [firm]), userHome: home)
        }
    }

    @Test func claudeDefaultWritablePlacesRefused() throws {
        let g = try GrantWorld()
        let home = try tempDir().resolvedForSandbox
        let npm = home.appending(path: ".npm/_logs")
        try FileManager.default.createDirectory(at: npm, withIntermediateDirectories: true)
        let claudeTmp = URL(fileURLWithPath: "/private/tmp/claude-brahma-test-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: claudeTmp.appending(path: "x"), withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: claudeTmp) }
        let env = SandboxEnvironment(userHome: home, darwinUserTemp: nil, shell: "/bin/zsh")
        for bad in [npm.path, home.appending(path: ".npm").path, claudeTmp.path, claudeTmp.path + "/x",
                    "/tmp/" + claudeTmp.lastPathComponent, "/private/tmp", "/tmp"] {
            #expect(throws: (any Error).self, "\(bad)") {
                try Grants.validate(kind: .readPath, value: bad, company: g.company, paths: g.world.paths, environment: env)
            }
        }
    }

    /// Final review I2: the agents' private temp root (`/private/tmp/b-<uid>`, or the environment's own root) and anything under
    /// it or containing it is never a grantable read path, nor an owner toolchain read path; a neighbouring directory in /tmp is.
    @Test func agentTempRootIsNeverGranted() throws {
        let g = try GrantWorld()
        let fm = FileManager.default
        let root = "/private/tmp/b-\(getuid())"
        let createdRoot = !fm.fileExists(atPath: root)
        if createdRoot { try fm.createDirectory(atPath: root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }   // exec-bit fixture: a directory mode
        let child = URL(fileURLWithPath: root).appending(path: "bt\(String(UUID().uuidString.prefix(4)).lowercased())")
        try fm.createDirectory(at: child.appending(path: "deeper"), withIntermediateDirectories: true)
        let custom = URL(fileURLWithPath: "/private/tmp/brahma-agents-test-\(UUID().uuidString)")
        try fm.createDirectory(at: custom.appending(path: "abc123"), withIntermediateDirectories: true)
        let neighbour = URL(fileURLWithPath: "/private/tmp/brahma-grant-ok-\(UUID().uuidString)")
        try fm.createDirectory(at: neighbour, withIntermediateDirectories: true)
        defer {
            try? fm.removeItem(at: child); try? fm.removeItem(at: custom); try? fm.removeItem(at: neighbour)
            if createdRoot { try? fm.removeItem(atPath: root) }
        }
        let home = try tempDir().resolvedForSandbox
        func validate(_ value: String, root claudeTmpRoot: URL?) throws {
            let env = SandboxEnvironment(userHome: home, darwinUserTemp: nil, shell: "/bin/zsh", claudeTmpRoot: claudeTmpRoot)
            _ = try Grants.validate(kind: .readPath, value: value, company: g.company, paths: g.world.paths, environment: env)
        }
        for claudeTmpRoot in [nil, URL(fileURLWithPath: root)] {
            for bad in [root, "/tmp/b-\(getuid())", child.path, child.path + "/deeper", "/tmp/b-\(getuid())/" + child.lastPathComponent] {
                #expect(throws: (any Error).self, "\(bad) was grantable") { try validate(bad, root: claudeTmpRoot) }
            }
        }
        // An environment with its own root: that root and its children are refused, by identity.
        for bad in [custom.path, custom.path + "/abc123"] {
            #expect(throws: (any Error).self, "\(bad) was grantable") { try validate(bad, root: custom) }
        }
        #expect(Grants.inClaudeTemp(custom.path + "/abc123", claudeTmpRoot: custom))
        // A neighbouring directory in /tmp stays grantable: the refusal is about the agents' temp places only.
        #expect(throws: Never.self) { try validate(neighbour.path, root: URL(fileURLWithPath: root)) }
        // The turn's own check (`SandboxScope.forTurn`, which every grant and toolchain path goes through) refuses them too.
        #expect(throws: (any Error).self) {
            try g.store.updateSandbox(companyId: g.company.id, SandboxPatch(toolchainReadPaths: [child.path]), userHome: home)
        }
    }

    @Test func lostOneUseGrantRebuildsTheScope() async throws {
        let g = try GrantWorld()
        let once = try g.grant("network_domain", "once.example.com", scope: .once, duration: .always)
        let always = try g.grant("network_domain", "always.example.com", scope: .agent, duration: .always)
        let agent = try #require(try g.store.agent(id: g.eng.id))
        var prepared = try await g.world.orchestrator.prepareSandbox(agent: agent, company: g.company, kind: .work, item: nil,
                                                                     turnId: "t-1")
        #expect(prepared.scope.network.allowedDomains.contains("once.example.com"))
        // Another launch takes the one-use grant between preparing and launching.
        #expect(try g.store.consumeGrants(ids: [once.id], turnId: "t-0", now: Date()).isEmpty)
        try await g.world.orchestrator.consumeSandboxGrants(&prepared, agent: agent, company: g.company, item: nil, turnId: "t-1")
        #expect(prepared.grants.map(\.id) == [always.id])
        #expect(!prepared.scope.network.allowedDomains.contains("once.example.com"))
        #expect(prepared.scope.network.allowedDomains.contains("always.example.com"))
        #expect(try g.store.grants(companyId: g.company.id).first { $0.id == always.id }?.useCount == 1)
    }

    @Test func swapRightBeforeSpawnDropsTheGrant() async throws {
        let g = try GrantWorld()
        let root = try tempDir()
        let data = root.appending(path: "data"), secret = root.appending(path: "secret")
        for d in [data, secret] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        _ = try g.store.requestAccess(companyId: g.company.id, agentId: g.eng.id, kind: .readPath, value: data.path, reason: "r",
                                      environment: g.env)
        let grant = try g.store.approveAccess(askId: try g.ask("A-1").id, scope: .agent, duration: .always, note: "", environment: g.env)
        let agent = try #require(try g.store.agent(id: g.eng.id))
        let prepared = try await g.world.orchestrator.prepareSandbox(agent: agent, company: g.company, kind: .work, item: nil,
                                                                     turnId: "t-1")
        #expect(prepared.scope.grantReadDirs.map(\.path) == [grant.value])
        try FileManager.default.removeItem(at: data)
        try FileManager.default.createSymbolicLink(at: data, withDestinationURL: secret)
        var scope = prepared.scope
        #expect(try scope.recheckBeforeSpawnDroppingGrants().map(\.path) == [grant.value], "dropped, the turn not refused")
        #expect(!scope.readOnlyDirs.map(\.path).contains(grant.value)); #expect(!scope.readable.map(\.path).contains(grant.value))
    }

    @Test func missingReadPathIsLeftOutNotRevoked() async throws {
        let g = try GrantWorld()
        let dir = try tempDir().appending(path: "data")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        _ = try g.store.requestAccess(companyId: g.company.id, agentId: g.eng.id, kind: .readPath, value: dir.path, reason: "r",
                                      environment: g.env)
        let grant = try g.store.approveAccess(askId: try g.ask("A-1").id, scope: .agent, duration: .always, note: "", environment: g.env)
        try FileManager.default.removeItem(at: dir)
        #expect(!(try await g.nextScope()).readOnlyDirs.map(\.path).contains(grant.value))
        #expect(try g.store.grants(companyId: g.company.id).first?.revokedAt == nil, "a missing directory is not a swap")
        #expect(try g.store.allNotices().filter { $0.companyId == g.company.id }.isEmpty)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        #expect((try await g.nextScope()).readOnlyDirs.map(\.path).contains(grant.value))
    }

    /// Extension grants are real since Task 5a, so their refusals count like every other (5a fix round 1, M7).
    @Test func extensionRefusalsUseTheBudget() throws {
        let g = try GrantWorld()
        for n in 0..<AccessRefusals.perActiveDay {
            #expect(refusal { try g.request("extension", "local/x\(n)") }?.hasPrefix("No extension") == true)
        }
        #expect(refusal { try g.request("web_domain", "fine.example.com") } == AccessRefusals.message)
        #expect(Grants.pathRefusal.contains("brahma access"))
    }

    @Test func readPathSwappedAfterApprovalIsDropped() async throws {
        let g = try GrantWorld()
        let root = try tempDir()
        let data = root.appending(path: "data"), secret = root.appending(path: "secret")
        for d in [data, secret] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        _ = try g.store.requestAccess(companyId: g.company.id, agentId: g.eng.id, kind: .readPath, value: data.path, reason: "r",
                                      environment: g.env)
        let grant = try g.store.approveAccess(askId: try g.ask("A-1").id, scope: .agent, duration: .always, note: "", environment: g.env)
        #expect((try await g.nextScope()).readOnlyDirs.map(\.path).contains(grant.value))
        try FileManager.default.removeItem(at: data)
        try FileManager.default.createSymbolicLink(at: data, withDestinationURL: secret)
        let scope = try await g.nextScope()
        let paths = scope.readOnlyDirs.map(\.path) + scope.readable.map(\.path)
        #expect(!paths.contains(grant.value)); #expect(!paths.contains(secret.resolvedForSandbox.path))
        let after = try #require(try g.store.grants(companyId: g.company.id, includeInactive: true).first)
        #expect(after.revokedAt != nil); #expect(after.revokedBy == "engine")
        #expect(try g.store.allNotices().contains { $0.companyId == g.company.id && $0.body.contains(grant.ref) })
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
        // Consuming is all-or-nothing: a used-up grant is reported lost and nothing else is taken.
        let fresh = try g.grant("network_domain", "fresh.example.com", scope: .once, duration: .always)
        #expect(try g.store.consumeGrants(ids: [grant.id, fresh.id], turnId: "t", now: Date()) == [grant.id])
        #expect(try g.store.grants(companyId: g.company.id).first { $0.id == fresh.id }?.usesLeft == 1)
        #expect(try g.store.consumeGrants(ids: [fresh.id], turnId: "t", now: Date()).isEmpty)
    }

    @Test func notLaunchedTurnKeepsItsOneUseGrant() async throws {
        let g = try GrantWorld()
        // A model outside the allowlist: the turn is prepared, then not launched.
        let odd = try g.store.hire(companyId: g.company.id, name: "odd-1", role: "engineer", model: "not-a-model")
        let grant = try g.grant("network_domain", "once.example.com", by: odd, scope: .once, duration: .always)
        try g.world.dm(g.company, odd)
        try await g.world.cycle()
        #expect(!g.world.fake.requests.contains { $0.agent.id == odd.id })
        #expect(try g.store.grants(companyId: g.company.id).first { $0.id == grant.id }?.usesLeft == 1)
    }

    @Test func reviewAndAuditTurnsSkipOneUseAndItemGrants() throws {
        let g = try GrantWorld()
        let item = try g.item()
        _ = try g.tools().call(name: "claim_lease", arguments: ["key": .string(item.key)])
        let once = try g.grant("network_domain", "once.example.com", scope: .once, duration: .always)
        let turn = try g.grant("network_domain", "turn.example.com", scope: .agent, duration: .turn)
        let onItem = try g.grant("network_domain", "item.example.com", item: item.key, scope: .item, duration: .always)
        let always = try g.grant("network_domain", "always.example.com", scope: .agent, duration: .always)
        #expect(Set(try g.store.activeGrants(agent: g.eng, itemId: item.id, kind: .work).map(\.id)) == [once.id, turn.id, onItem.id, always.id])
        for kind in [TurnKind.review, .audit] {
            #expect(try g.store.activeGrants(agent: g.eng, itemId: item.id, kind: kind).map(\.id) == [always.id], "\(kind)")
        }
    }

    @Test func teamSprintBeforeCompanySprint() throws {
        let g = try GrantWorld()
        try g.store.writer.write { db in try db.execute(sql: "UPDATE agent SET team = 'core' WHERE id = ?", arguments: [g.eng.id]) }
        let company = Sprint(id: UUID().uuidString, companyId: g.company.id, number: 1, team: nil, goal: "g", cadence: .sprint,
                             status: .active, createdAt: Date())
        let team = Sprint(id: UUID().uuidString, companyId: g.company.id, number: 2, team: "core", goal: "g", cadence: .sprint,
                          status: .active, createdAt: Date())
        try g.store.writer.write { db in try company.insert(db); try team.insert(db) }
        #expect(try g.grant("network_domain", "t.example.com", scope: .agent, duration: .sprint).sprintId == team.id)
        let other = try g.store.hire(companyId: g.company.id, name: "eng-2", role: "engineer", model: "sonnet")
        #expect(try g.grant("network_domain", "c.example.com", by: other, scope: .agent, duration: .sprint).sprintId == company.id)
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
            try g.store.approveAccess(askId: try g.ask("A-2").id, scope: .item, duration: .always, note: "", environment: g.env)
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
        #expect(try g.store.events(afterId: 0, companyId: g.company.id).contains { $0.text.contains("revoked") && $0.text.contains("kill") })
    }

    @Test func readPathGrantIsReadOnly() async throws {
        let g = try GrantWorld()
        let dir = try tempDir()
        _ = try g.store.requestAccess(companyId: g.company.id, agentId: g.eng.id, kind: .readPath, value: dir.path, reason: "data",
                                      environment: g.env)
        let ask = try g.ask("A-1")
        #expect(ask.risk == .medium)
        let grant = try g.store.approveAccess(askId: ask.id, scope: .agent, duration: .always, note: "", environment: g.env)
        #expect(grant.value == dir.resolvedForSandbox.path)
        let scope = try await g.nextScope()
        let resolved = dir.resolvedForSandbox.path
        #expect(scope.readOnlyDirs.map(\.path).contains(resolved))
        #expect(scope.readable.map(\.path).contains(resolved))
        #expect(!scope.writable.map(\.path).contains { SandboxPath.isInside($0, resolved) || SandboxPath.isInside(resolved, $0) })
        #expect(scope.cwd.path != resolved)
        let r = try #require(g.world.fake.requests.last)
        #expect(TurnProfileCompiler.profile(for: r).addDirs.contains(resolved))
        // The settings write-deny it, for the sandbox and for Edit/Write.
        let profile = TurnProfileCompiler.profile(for: r)
        let settings = try JSONDecoder().decode(ClaudeSettings.self, from: Data(try TurnProfileCompiler.settingsJSON(profile).utf8))
        #expect(settings.sandbox?.filesystem?.denyWrite?.contains(resolved) == true)
        #expect(settings.sandbox?.filesystem?.allowWrite?.contains(resolved) != true)
        let deny = try #require(settings.permissions?.deny)
        #expect(deny.contains("Edit(/\(resolved)/**)")); #expect(deny.contains("Write(/\(resolved)/**)"))
        // An unlimited grant's use is counted, not logged every turn.
        #expect(try g.store.grants(companyId: g.company.id).first?.useCount == 1)
        #expect(!(try g.store.events(afterId: 0, companyId: g.company.id)).contains { $0.text.contains("uses \(grant.ref)") })
    }

    @Test func ownerOnlyCLI() throws {
        let home = try OwnerTestHome()
        let paths = ownerPaths(home.url)
        let store = try Store(path: paths.database.path, backupsDir: paths.backupsDir)
        let company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: paths.workspaces)
        let eng = try store.hire(companyId: company.id, name: "eng-1", role: "engineer", model: "sonnet")
        _ = try store.requestAccess(companyId: company.id, agentId: eng.id, kind: .webDomain, value: "docs.example.com",
                                    reason: "read \u{1b}[31mdocs")
        _ = try store.requestAccess(companyId: company.id, agentId: eng.id, kind: .webDomain, value: "*.docs.example.org", reason: "all docs")
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
        #expect(list.stdout.contains("*.docs.example.org") && list.stdout.contains("WILDCARD"), "\(list.stdout)")
        #expect(try runBrahma(["access", "approve", "acme", "A-1", "--scope", "galaxy", "--duration", "always"], home: home.url).status != 0)
        #expect(try runBrahma(["access", "approve", "acme", "A-1", "--scope", "agent"], home: home.url).status != 0, "--duration is required")
        #expect(try runBrahma(["access", "approve", "acme", "A-1", "--duration", "always"], home: home.url).status != 0, "--scope is required")
        #expect(try runBrahma(["approve", "acme", "A-1"], home: home.url).stderr.contains("brahma access approve"))
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
