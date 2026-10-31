import Testing
import Foundation
import GRDB
@testable import BrahmaCore

private let aws = "AKIA" + "ABCDEFGHIJKLMNOP"   // split so this file does not itself trip a scanner
private let rsa = "-----BEGIN RSA " + "PRIVATE KEY-----"

/// Task 4-wire: `request_secret` / `use_secret`, test-key injection per lease, the submit and merge leak scans, and the
/// redaction of the remaining agent write paths (asks, hand-offs, review and audit notes, check output).
@Suite(.scratch, .serialized) struct SecretWireTests {
    /// A company with a real git workspace, a manager, an engineer, a reviewer, a second company with its own agent, and the
    /// orchestrator's fakes. `vault` is the orchestrator's vault too, so secrets set here reach the engine's redactor.
    private struct W {
        let world: World
        let company: Company, other: Company
        let mgr: Agent, eng: Agent, rev: Agent, outsider: Agent
        let vault: MemoryVault
        var store: Store { world.store }
        var now: Date { world.clock.now }
        var root: URL { URL(fileURLWithPath: company.workspacePath, isDirectory: true) }
        var ws: GitWorkspace { GitWorkspace(root: root) }

        init(profile: PermissionProfile = .workspace) throws {
            let v = MemoryVault()
            vault = v
            world = try World(vault: v)
            company = try world.company("Acme", profile: profile)
            other = try world.company("Bolt", profile: profile)
            mgr = try world.hire(company, "mgr", role: "manager")
            let (store, companyId, managerId) = (world.store, company.id, mgr.id)
            func report(_ n: String) throws -> Agent {
                try store.hire(companyId: companyId, name: n, role: "engineer", model: "sonnet", managerId: managerId)
            }
            eng = try report("eng-1")
            rev = try report("rev")
            outsider = try store.hire(companyId: other.id, name: "bolt-eng", role: "engineer", model: "sonnet")
        }

        func tools(_ a: Agent) -> CompanyTools { CompanyTools(store: store, companyId: company.id, agentId: a.id) }
        func call(_ a: Agent, _ name: String, _ args: [String: JSONValue]) throws -> String {
            try tools(a).call(name: name, arguments: args)
        }
        func failure(_ body: () throws -> String) -> String {
            do { _ = try body(); return "no error" } catch let e as ToolError { return e.message } catch { return "\(error)" }
        }
        func fresh(_ i: WorkItem) throws -> WorkItem { try #require(try store.workItem(id: i.id)) }
        func requests(_ a: Agent) -> [TurnRequest] { world.fake.requests.filter { $0.agent.id == a.id } }
        func events(_ i: WorkItem) throws -> [WorkItemEvent] { try store.itemEvents(itemId: i.id, limit: 500) }
        func asks() throws -> [Ask] { try store.asks(companyId: company.id) }
        func uses() throws -> [SecretUse] { try store.writer.read { try SecretUse.order(Column("grantedAt"), Column.rowID).fetchAll($0) } }
        func runs(_ i: WorkItem) throws -> [VerificationRun] {
            try store.writer.read { try VerificationRun.filter(Column("itemId") == i.id).order(Column.rowID).fetchAll($0) }
        }
        func cycle() async throws {
            await world.orchestrator.tick()
            try await world.orchestrator.waitUntilIdle(timeout: .seconds(60))
        }
        /// A synchronous store write (the async overload of `writer.write` would be picked inside an async test).
        func db(_ body: @escaping (Database) throws -> Void) throws { try store.writer.write(body) }

        /// Sets a secret in the engine's vault and loads it into the redactor.
        func set(_ name: String, _ value: String, test: Bool = false, in company: Company? = nil) throws {
            try store.setSecret(companyId: (company ?? self.company).id, name: name, value: value, isTest: test, vault: vault, now: now)
            _ = try store.reloadRedactorIfNeeded(vault: vault, force: true)
        }

        func commitMain(_ files: [String: String]) throws {
            for (path, text) in files { try write(path, text, in: root) }
            try GitFixture.plainGit(["add", "-A"], in: root)
            try GitFixture.plainGit(["commit", "-m", "base"], in: root)
            try store.recordMainCommit(companyId: company.id, commit: try GitFixture.plainGit(["rev-parse", "refs/heads/main"], in: root))
        }
        func write(_ path: String, _ text: String, in dir: URL) throws {
            let url = dir.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        func item(_ title: String = "Do it", command: String? = "true", reviewer: Agent? = nil, in company: Company? = nil) throws -> WorkItem {
            let c = company ?? self.company
            let n = (try store.workItems(companyId: c.id)).count + 1
            let spec = command.map { CheckSpec(command: $0, paths: ["src/p\(n)"]) }
            return try store.createWorkItem(companyId: c.id, by: .owner, draft: WorkItemDraft(
                type: .task, title: title, acceptanceCriteria: "it works", checkSpec: spec, reviewerId: reviewer?.id, status: .ready,
                touchPaths: spec == nil ? ["research\(n)"] : []), now: now)
        }
        @discardableResult
        func claim(_ i: WorkItem, _ a: Agent) throws -> URL {
            _ = try call(a, "claim_lease", ["key": .string(i.key)])
            return ws.worktreePath(key: i.key)
        }
        @discardableResult
        func submit(_ i: WorkItem, _ a: Agent, _ summary: String = "did the work") throws -> String {
            try call(a, "submit_for_review", ["key": .string(i.key), "summary": .string(summary)])
        }
        func branchHead(_ i: WorkItem) throws -> String? { try ws.head(of: ws.branchRef(key: i.key)) }
        func mainHead() throws -> String { try GitFixture.plainGit(["rev-parse", "refs/heads/main"], in: root) }
        /// The reviewer approves in a review turn, as the review tool does at the engine level.
        func approve(_ i: WorkItem) throws {
            let turn = try store.startTurn(agentId: rev.id, now: now)
            try store.setTurnContext(turnId: turn.id, kind: .review, itemId: i.id)
            _ = try store.review(itemId: i.id, by: rev.id, decision: .approve, notes: "fine", approveFlags: true,
                                 currentHead: try branchHead(i), now: now)
        }
        func dms(to a: Agent) throws -> [String] {
            try store.writer.read { db in
                try Message.filter(Column("senderId") == "system").order(Column.rowID).fetchAll(db)
            }.compactMap { m in
                guard let ch = try store.writer.read({ try Channel.fetchOne($0, key: m.channelId) }),
                      ch.kind == .dm, ch.name.contains(a.name) else { return nil }
                return m.text
            }
        }
    }

    // MARK: request_secret / provide

    @Test func requestSecretCreatesRequestAsk() throws {
        let w = try W()
        let out = try w.call(w.eng, "request_secret", ["name": .string("STRIPE_TEST_KEY"), "reason": .string("to call the sandbox API"), "test": .bool(true)])
        #expect(out == "Requested A-1 (STRIPE_TEST_KEY). The owner provides secrets in the app.")
        let ask = try #require(try w.asks().first)
        #expect(ask.kind == .request); #expect(ask.status == .pendingOwner); #expect(ask.risk == .high)
        #expect(ask.title == "Secret STRIPE_TEST_KEY"); #expect(ask.summary == "to call the sandbox API")
        #expect(ask.requesterId == w.eng.id); #expect(ask.category == nil)
        let requested = try #require(SecretRequests.requested(ask))
        #expect(requested.name == "STRIPE_TEST_KEY"); #expect(requested.test)
        // The same name asked again is the same ask; nothing is filed twice.
        #expect(try w.call(w.eng, "request_secret", ["name": .string("STRIPE_TEST_KEY"), "reason": .string("again")]) == "Already requested as A-1.")
        #expect(try w.asks().count == 1)
        // Names are checked; a test key must be one that can go into an environment; an existing secret is not re-requested.
        #expect(w.failure { try w.call(w.eng, "request_secret", ["name": .string("stripe-key"), "reason": .string("r")]) }.contains("invalid secret name"))
        #expect(w.failure { try w.call(w.eng, "request_secret", ["name": .string("GIT_SSH_KEY"), "reason": .string("r"), "test": .bool(true)]) }.contains("test key"))
        try w.set("OTHER_KEY", "engine-held-value-1", test: false)
        #expect(w.failure { try w.call(w.eng, "request_secret", ["name": .string("OTHER_KEY"), "reason": .string("r")]) }.contains("already exists"))
        // The quota (fail-safe, in the write that files the ask): three open owner requests per agent.
        _ = try w.call(w.eng, "request_secret", ["name": .string("SECOND_KEY"), "reason": .string("r")])
        _ = try w.call(w.eng, "request_secret", ["name": .string("THIRD_KEY"), "reason": .string("r")])
        #expect(w.failure { try w.call(w.eng, "request_secret", ["name": .string("FOURTH_KEY"), "reason": .string("r")]) } == AskQuota.refusal)
        #expect(try w.asks().count == 3)
        // No value anywhere: the reason is redacted at write like any ask text.
        try w.set("KNOWN_KEY", "known-value-abcdef", test: false)
        _ = try w.store.ownerDecide(askId: ask.id, approve: false, note: "no")
        _ = try w.call(w.eng, "request_secret", ["name": .string("FIFTH_KEY"), "reason": .string("I saw known-value-abcdef in the logs")])
        let fifth = try #require(try w.asks().last { $0.title == "Secret FIFTH_KEY" })
        #expect(fifth.summary == "I saw [redacted KNOWN_KEY] in the logs")
        #expect(!(try dumpDatabase(w.store)).contains("known-value-abcdef"))
    }

    @Test func provideSecretResolvesAsk() throws {
        let w = try W()
        _ = try w.call(w.eng, "request_secret", ["name": .string("STRIPE_TEST_KEY"), "reason": .string("sandbox"), "test": .bool(true)])
        let ask = try #require(try w.asks().first)
        let decided = try w.store.provideSecret(askId: ask.id, value: "sk_test_provided_value_123", isTest: true, vault: w.vault, now: w.now)
        #expect(decided.status == .approved); #expect(decided.ownerNote == "provided")
        let meta = try #require(try w.store.secrets(companyId: w.company.id).first)
        #expect(meta.name == "STRIPE_TEST_KEY"); #expect(meta.isTest)
        #expect(try w.vault.value(companyId: w.company.id, name: "STRIPE_TEST_KEY") == "sk_test_provided_value_123")
        #expect(!(try dumpDatabase(w.store)).contains("sk_test_provided_value_123"), "the value never reaches the database")
        // The requester hears of it, and the key is now usable.
        #expect(try w.dms(to: w.eng).contains { $0.contains("A-1") })
        _ = try w.store.reloadRedactorIfNeeded(vault: w.vault, force: true)
        let i = try w.item(); try w.claim(i, w.eng)
        #expect(try w.call(w.eng, "use_secret", ["name": .string("STRIPE_TEST_KEY")]).hasPrefix("STRIPE_TEST_KEY will be in your environment from your next turn"))
        // Only a pending secret request can be provided for.
        #expect(throws: WorkError.self) { try w.store.provideSecret(askId: ask.id, value: "again-value-12345", isTest: true, vault: w.vault) }
        let question = try w.store.requestFromOwner(companyId: w.company.id, by: .agent(w.eng.id), title: "Q", question: "why?")
        #expect(throws: WorkError.self) { try w.store.provideSecret(askId: question.id, value: "value-for-nothing", isTest: false, vault: w.vault) }
        // An engine-held answer to a test request is the owner's call: the request's flag is only a proposal.
        _ = try w.call(w.eng, "request_secret", ["name": .string("API_TOKEN"), "reason": .string("prod"), "test": .bool(true)])
        let second = try #require(try w.asks().first { $0.title == "Secret API_TOKEN" })
        _ = try w.store.provideSecret(askId: second.id, value: "engine-held-token-123", isTest: false, vault: w.vault)
        #expect(try w.store.secrets(companyId: w.company.id).first { $0.name == "API_TOKEN" }?.isTest == false)
    }

    // MARK: use_secret

    @Test func nonTestSecretIsEngineHeld() throws {
        let w = try W()
        try w.set("STRIPE_KEY", "sk_live_engine_held_12345", test: false)
        let i = try w.item(); try w.claim(i, w.eng)
        #expect(w.failure { try w.call(w.eng, "use_secret", ["name": .string("STRIPE_KEY")]) }
                == "STRIPE_KEY is engine-held: connectors use it for you, and agents never receive it")
        #expect(w.failure { try w.call(w.eng, "use_secret", ["name": .string("NOPE_KEY")]) } == "No secret named NOPE_KEY; ask with request_secret")
        #expect(try w.uses().isEmpty)
        #expect(try w.store.injectableSecrets(agentId: w.eng.id, itemId: i.id).isEmpty)
        // A test key needs a held item.
        try w.set("TEST_KEY", "test-key-value-12345", test: true)
        #expect(w.failure { try w.call(w.rev, "use_secret", ["name": .string("TEST_KEY")]) }.contains("claim"))
        #expect(try w.uses().isEmpty)
    }

    @Test func testSecretInjectedNextTurnOnly() async throws {
        let w = try W(profile: .sandboxed)
        try w.set("TEST_KEY", "test-key-value-12345", test: true)
        let i = try w.item(); try w.claim(i, w.eng)
        // The use is opened during a turn: that turn has nothing, the next one has the key.
        let (store, companyId, agentId) = (w.store, w.company.id, w.eng.id)
        w.world.fake.script("eng-1", .init(sideEffect: { _ in
            let out = try CompanyTools(store: store, companyId: companyId, agentId: agentId).call(name: "use_secret", arguments: ["name": .string("TEST_KEY")])
            guard out == "TEST_KEY will be in your environment from your next turn while you work on \(i.key)" else { throw FakeError(description: out) }
        }))
        try w.world.dm(w.company, w.eng)
        try await w.cycle()
        #expect(try w.world.turns(w.eng).last?.outcome == .succeeded)
        let first = try #require(w.requests(w.eng).last)
        #expect(first.secrets.isEmpty, "the turn that asked does not get it")
        let use = try #require(try w.uses().last)
        #expect(use.agentId == w.eng.id); #expect(use.itemId == i.id); #expect(use.secretName == "TEST_KEY"); #expect(use.endedAt == nil)
        #expect(try w.store.secrets(companyId: w.company.id).first?.lastUsedAt != nil)

        try w.world.dm(w.company, w.eng)
        try await w.cycle()
        let second = try #require(w.requests(w.eng).last)
        #expect(second.secrets == ["TEST_KEY": "test-key-value-12345"])
        #expect(ChildEnvironment.make(base: [:], secrets: second.secrets)["TEST_KEY"] == "test-key-value-12345")
        let prefix = try String(contentsOfFile: try #require(second.shellPrefix), encoding: .utf8)
        #expect(prefix.contains("keep=' TEST_KEY '"), "the Bash prefix keeps the injected name")
        #expect(!(try dumpDatabase(w.store)).contains("test-key-value-12345"))
        // A second use of the same key is one row; a use ends with the lease.
        #expect(try w.call(w.eng, "use_secret", ["name": .string("TEST_KEY")]).hasPrefix("TEST_KEY will be"))
        #expect(try w.uses().count == 1)
        _ = try w.call(w.eng, "release_lease", ["key": .string(i.key)])
        #expect(try w.uses().last?.endedAt != nil)
        #expect(try w.store.injectableSecrets(agentId: w.eng.id, itemId: i.id).isEmpty)
        try w.world.dm(w.company, w.eng)
        try await w.cycle()
        let third = try #require(w.requests(w.eng).last)
        #expect(third.secrets.isEmpty)
        #expect(!(try String(contentsOfFile: try #require(third.shellPrefix), encoding: .utf8)).contains("TEST_KEY"))
    }

    @Test func useEndsWhenTheItemLeavesInProgress() async throws {
        let w = try W()
        try w.set("TEST_KEY", "test-key-value-12345", test: true)
        let i = try w.item(); try w.claim(i, w.eng)
        _ = try w.call(w.eng, "use_secret", ["name": .string("TEST_KEY")])
        // In review the holder keeps its lease and the item's check runs with the key; done ends it.
        try w.write("src/work.txt", "work\n", in: w.ws.worktreePath(key: i.key))
        try w.submit(i, w.eng)
        #expect(try w.fresh(i).status == .inReview)
        #expect(try w.store.injectableSecrets(agentId: w.eng.id, itemId: i.id) == ["TEST_KEY": "test-key-value-12345"])
        try w.db { db in _ = try w.store.engineSetStatus(db: db, itemId: i.id, to: .done, now: w.now) }
        #expect(try w.uses().last?.endedAt != nil)
        #expect(try w.store.injectableSecrets(agentId: w.eng.id, itemId: i.id).isEmpty)
        // A lease that expires ends the use as well.
        let j = try w.item("Second"); try w.claim(j, w.eng)
        _ = try w.call(w.eng, "use_secret", ["name": .string("TEST_KEY")])
        try w.db { db in try db.execute(sql: "UPDATE workLease SET expiresActive = -1 WHERE itemId = ?", arguments: [j.id]) }
        _ = try w.store.reapLeases(now: w.now)
        #expect(try w.uses().last?.endedAt != nil)
        #expect(try w.uses().allSatisfy { $0.endedAt != nil })
    }

    @Test func crossCompanySecretRefused() throws {
        let w = try W()
        try w.set("TEST_KEY", "test-key-value-12345", test: true)
        try w.set("BOLT_KEY", "bolt-key-value-12345", test: true, in: w.other)
        let i = try w.item(); try w.claim(i, w.eng)
        // Another company's agent, through tools built for this company, files and uses nothing here.
        #expect(w.failure { try w.call(w.outsider, "use_secret", ["name": .string("TEST_KEY")]) }.contains("company"))
        #expect(w.failure { try w.call(w.outsider, "request_secret", ["name": .string("NEW_KEY"), "reason": .string("r")]) }.contains("company"))
        #expect(throws: WorkError.forbidden("not in your company")) {
            try w.store.openSecretUse(companyId: w.company.id, agentId: w.outsider.id, name: "TEST_KEY")
        }
        #expect(throws: WorkError.forbidden("not in your company")) {
            try w.store.requestSecret(companyId: w.company.id, agentId: w.outsider.id, name: "NEW_KEY", reason: "r", test: false)
        }
        #expect(try w.asks().isEmpty); #expect(try w.uses().isEmpty)
        // Another company's secret is not visible by name from this one.
        #expect(w.failure { try w.call(w.eng, "use_secret", ["name": .string("BOLT_KEY")]) } == "No secret named BOLT_KEY; ask with request_secret")
        // A use row that names another company's item injects nothing.
        let theirs = try w.item("Theirs", in: w.other)
        try w.db { db in
            let planted = SecretUse(id: "planted", companyId: w.company.id, agentId: w.eng.id, secretName: "TEST_KEY", itemId: theirs.id,
                                    grantedAt: w.now)
            try planted.insert(db)
        }
        #expect(try w.store.injectableSecrets(agentId: w.eng.id, itemId: theirs.id).isEmpty)
        #expect(try w.store.injectableSecrets(agentId: w.outsider.id, itemId: i.id).isEmpty)
        // Only the holder of the item's lease gets its keys.
        _ = try w.call(w.eng, "use_secret", ["name": .string("TEST_KEY")])
        #expect(try w.store.injectableSecrets(agentId: w.eng.id, itemId: i.id) == ["TEST_KEY": "test-key-value-12345"])
        #expect(try w.store.injectableSecrets(agentId: w.rev.id, itemId: i.id).isEmpty)
    }

    // MARK: Checks

    @Test func checkLogScrubbed() async throws {
        let w = try W()
        let value = "sk_test_check_leak_123456"
        try w.set("CHECK_KEY", value, test: true)
        let i = try w.item(command: "run-it"); let wt = try w.claim(i, w.eng)
        _ = try w.call(w.eng, "use_secret", ["name": .string("CHECK_KEY")])
        try w.write("src/work.txt", "work\n", in: wt)
        try w.submit(i, w.eng)
        w.world.checks.onRun { call in
            // The check sees the key in its environment and prints it: the log and the tail are scrubbed, the DB clean.
            CheckOutcome(exitCode: 1, timedOut: false, tail: "env CHECK_KEY=\(call.environment["CHECK_KEY"] ?? "missing")\nfailed")
        }
        try await w.cycle()   // the first failure is re-run once
        try await w.cycle()
        let run = try #require(try w.store.latestVerification(itemId: i.id))
        #expect(run.status == .failed)
        #expect(w.world.checks.calls.last?.environment["CHECK_KEY"] == value, "the item's check gets the test key")
        #expect(run.outputTail?.contains("CHECK_KEY=[redacted CHECK_KEY]") == true, "\(run.outputTail ?? "")")
        let log = try String(contentsOfFile: try #require(run.outputPath), encoding: .utf8)
        #expect(log.contains("[redacted CHECK_KEY]")); #expect(!log.contains(value))
        #expect(!(try dumpDatabase(w.store)).contains(value))
        // Every check log of the item is clean, not only the last run's.
        for r in try w.runs(i) {
            if let path = r.outputPath, let text = try? String(contentsOfFile: path, encoding: .utf8) { #expect(!text.contains(value)) }
            #expect(r.outputTail?.contains(value) != true)
        }
    }

    // MARK: Submit scans

    @Test func submitRefusesKnownSecretInDiff() throws {
        let w = try W()
        let value = "sk_test/known+value_123456"
        try w.set("STRIPE_TEST_KEY", value, test: true)
        try w.commitMain(["README.md": "hello\n"])
        let i = try w.item(); let wt = try w.claim(i, w.eng)
        try w.write("src/config.txt", "key=\(value)\n", in: wt)
        let refusal = w.failure { try w.submit(i, w.eng) }
        #expect(refusal.contains("known secret STRIPE_TEST_KEY"), Comment(rawValue: refusal))
        #expect(refusal.contains("src/config.txt"))
        #expect(!refusal.contains(value))
        #expect(try w.fresh(i).status == .inProgress)
        #expect(try w.store.latestVerification(itemId: i.id) == nil)
        #expect(!(try dumpDatabase(w.store)).contains(value))
        // The percent-encoded form is found too; removing the value makes the change acceptable.
        let encoded = value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
        #expect(encoded != value)
        try w.write("src/config.txt", "url=https://x/?k=\(encoded)\n", in: wt)
        #expect(w.failure { try w.submit(i, w.eng) }.contains("known secret STRIPE_TEST_KEY"))
        try w.write("src/config.txt", "key=from-the-environment\n", in: wt)
        #expect(try w.submit(i, w.eng).hasPrefix("Submitted \(i.key)"))
    }

    @Test(arguments: [aws, rsa]) func submitRefusesPatterns(_ sample: String) throws {
        let w = try W()
        try w.commitMain(["README.md": "hello\n"])
        let i = try w.item(); let wt = try w.claim(i, w.eng)
        try w.write("src/creds.txt", "value: \(sample)\n", in: wt)
        let refusal = w.failure { try w.submit(i, w.eng) }
        #expect(refusal.contains(sample.hasPrefix("AKIA") ? "aws-key" : "private-key"), Comment(rawValue: refusal))
        #expect(!refusal.contains(sample))
        #expect(try w.fresh(i).status == .inProgress)
    }

    @Test func submitRefusesMovedBranch() throws {
        let w = try W()
        try w.commitMain(["README.md": "hello\n"])
        let i = try w.item(); let wt = try w.claim(i, w.eng)
        let recorded = try #require(try w.fresh(i).leaseHeadCommit)
        #expect(recorded == (try w.mainHead()), "the branch head at claim is recorded")
        // Something outside the turn points the branch at a commit that does not descend from the recorded head.
        let tree = try GitFixture.plainGit(["rev-parse", "\(recorded)^{tree}"], in: w.root)
        let orphan = try GitFixture.plainGit(["commit-tree", tree, "-m", "orphan"], in: w.root)
        try GitFixture.plainGit(["update-ref", w.ws.branchRef(key: i.key), orphan], in: w.root)
        try w.write("src/work.txt", "work\n", in: wt)
        #expect(w.failure { try w.submit(i, w.eng) } == "\(i.key)'s branch moved outside your turn; ask your manager")
        #expect(try w.branchHead(i) == orphan, "nothing was committed for a refused submit")
        #expect(try w.fresh(i).status == .inProgress)
        #expect(try w.store.latestVerification(itemId: i.id) == nil)
    }

    @Test func submitAcceptsOwnNewCommits() async throws {
        let w = try W()
        try w.commitMain(["README.md": "hello\n"])
        let i = try w.item(); let wt = try w.claim(i, w.eng)
        let atClaim = try #require(try w.fresh(i).leaseHeadCommit)
        // The holder commits twice in its turn (as its own git does), then submits: fast-forwards of the recorded head pass.
        for n in 1...2 {
            try w.write("src/work\(n).txt", "work \(n)\n", in: wt)
            try GitFixture.plainGit(["add", "-A"], in: wt)
            try GitFixture.plainGit(["commit", "-q", "-m", "work \(n)"], in: wt)
        }
        #expect(try w.submit(i, w.eng).hasPrefix("Submitted \(i.key)"))
        #expect(try w.fresh(i).status == .inReview)
        // The engine records the head again at the end of each of the holder's turns.
        try w.db { db in _ = try w.store.engineSetStatus(db: db, itemId: i.id, to: .inProgress, now: w.now) }
        w.world.fake.script("eng-1", .init(sideEffect: { _ in
            try "later\n".write(to: wt.appending(path: "src/later.txt"), atomically: true, encoding: .utf8)
            try GitFixture.plainGit(["add", "-A"], in: wt)
            try GitFixture.plainGit(["commit", "-q", "-m", "later"], in: wt)
        }))
        try w.world.dm(w.company, w.eng)
        try await w.cycle()
        let afterTurn = try #require(try w.branchHead(i))
        #expect(try w.fresh(i).leaseHeadCommit == afterTurn); #expect(afterTurn != atClaim)
        // A rewrite back to an earlier commit is not a fast-forward of what was recorded: refused.
        try GitFixture.plainGit(["update-ref", w.ws.branchRef(key: i.key), atClaim], in: w.root)
        try w.write("src/again.txt", "again\n", in: wt)
        #expect(w.failure { try w.submit(i, w.eng) } == "\(i.key)'s branch moved outside your turn; ask your manager")
    }

    @Test func mergeStepRescans() async throws {
        let w = try W()
        try w.commitMain(["README.md": "hello\n"])
        let value = "leak-value-abcdef-123456"
        let i = try w.item(reviewer: w.rev); let wt = try w.claim(i, w.eng)
        try w.write("src/config.txt", "token=\(value)\n", in: wt)
        try w.submit(i, w.eng)
        try await w.cycle()   // the check passes
        #expect(try w.fresh(i).verifiedCommit != nil)
        try w.approve(i)
        #expect(try w.fresh(i).mergeState == .pending)
        let before = try w.mainHead()
        // The value becomes a known secret after the approval: the merge step scans again and bounces the item.
        try w.set("LEAK_KEY", value, test: false)
        try await w.cycle(); try await w.cycle()
        #expect(try w.mainHead() == before, "nothing lands")
        let back = try w.fresh(i)
        #expect(back.status == .inProgress); #expect(back.mergeState == .none); #expect(back.verifiedCommit == nil)
        let event = try #require(try w.events(i).last { $0.kind == .verificationFailed })
        #expect(event.text.contains("known secret LEAK_KEY"), Comment(rawValue: event.text)); #expect(!event.text.contains(value))
        #expect(try w.dms(to: w.eng).contains { $0.contains("known secret LEAK_KEY") })
        #expect(try w.store.lease(itemId: i.id)?.agentId == w.eng.id)
        #expect(!(try dumpDatabase(w.store)).contains(value))
    }

    @Test func submitScanIgnoresCraftedCommondir() throws {
        let w = try W()
        try w.commitMain(["README.md": "hello\n"])
        let i = try w.item(); let wt = try w.claim(i, w.eng)
        // A crafted repository whose config runs a program (core.fsmonitor) that leaves a marker; the worktree's `.git`
        // file is pointed at it. The engine resolves the git dir from its own records and never follows that file.
        let crafted = try tempDir().appending(path: "crafted", directoryHint: .isDirectory)
        let marker = crafted.appending(path: "touched")
        try GitFixture.plainGit(["init", "-q", crafted.path], in: w.root)
        try GitFixture.plainGit(["config", "core.fsmonitor", "touch '\(marker.path)'; false"], in: crafted)
        try "gitdir: \(crafted.appending(path: ".git").path)\n".write(to: wt.appending(path: ".git"), atomically: true, encoding: .utf8)
        try w.write("src/creds.txt", "value: \(aws)\n", in: wt)
        let first = w.failure { try w.submit(i, w.eng) }
        #expect(!FileManager.default.fileExists(atPath: marker.path), "the crafted repository's config never ran")
        // The engine refuses a repointed worktree once and puts its own `.git` file back; the next submit scans normally.
        #expect(first.contains("repointed") || first.contains("aws-key"), Comment(rawValue: first))
        let second = w.failure { try w.submit(i, w.eng) }
        #expect(second.contains("aws-key"), Comment(rawValue: second))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        #expect(try w.fresh(i).status == .inProgress)
    }

    // MARK: Redaction on the remaining write paths

    @Test func asksAreRedactedAtWrite() throws {
        let w = try W()
        let s = "ask-secret-line\nsecond-line-55"
        try w.set("ASK_KEY", s, test: false)
        let ask = try w.store.propose(companyId: w.company.id, by: .agent(w.eng.id), kind: .other, category: "engine-code",
                                      title: "Title \(s)", summary: "Summary \(s)",
                                      payload: AskPayload(question: "Q \(s)", details: "D \(s)", options: [
                                          AskOption(label: "L \(s)", pros: "P \(s)", cons: "C \(s)", effort: "E \(s)", risk: "R \(s)")],
                                          recommendation: "Rec \(s)", stakes: "S \(s)", proposal: "Prop \(s)"), now: w.now)
        #expect(ask.title.contains("[redacted ASK_KEY]")); #expect(ask.summary == "Summary [redacted ASK_KEY]")
        let p = try #require(ask.payload)
        for text in [p.question, p.details, p.recommendation, p.stakes, p.proposal, p.options.first?.label, p.options.first?.pros,
                     p.options.first?.cons, p.options.first?.effort, p.options.first?.risk] {
            #expect(text?.contains("[redacted ASK_KEY]") == true, "\(text ?? "nil")")
        }
        let question = try w.store.requestFromOwner(companyId: w.company.id, by: .agent(w.eng.id), title: "T \(s)", question: "Q \(s)", details: "D \(s)")
        #expect(question.title.contains("[redacted ASK_KEY]")); #expect(question.summary == "Q [redacted ASK_KEY]")
        #expect(question.payload?.details == "D [redacted ASK_KEY]")
        #expect(!(try dumpDatabase(w.store)).contains("second-line-55"))
    }

    @Test func handoffBodyIsRedacted() throws {
        let w = try W()
        let s = "handoff-secret\nsecond-line-66"
        try w.set("HANDOFF_KEY", s, test: false)
        let i = try w.item(); try w.claim(i, w.eng)
        _ = try w.call(w.eng, "write_handoff", ["key": .string(i.key), "goal": .string("Goal \(s)"),
                                                "decisions": .array([.string("use \(s)")]), "open_questions": .array([.string("why \(s)?")]),
                                                "file_refs": .array([.string("src/\(s).txt")])])
        let record = try #require(try w.store.latestHandoff(itemId: i.id))
        let text = try String(contentsOfFile: record.path, encoding: .utf8)
        #expect(!text.contains("handoff-secret")); #expect(!text.contains("second-line-66"))
        #expect(text.contains("Goal [redacted HANDOFF_KEY]")); #expect(text.contains("use [redacted HANDOFF_KEY]"))
        #expect(text.contains("why [redacted HANDOFF_KEY]?")); #expect(text.contains("src/[redacted HANDOFF_KEY].txt"))
        #expect(!(try dumpDatabase(w.store)).contains("second-line-66"))
    }

    @Test func reviewAndAuditNotesAreRedacted() async throws {
        let w = try W()
        let s = "review-secret\nsecond-line-77"
        try w.set("REVIEW_KEY", s, test: false)
        try w.commitMain(["README.md": "hello\n"])
        let i = try w.item(reviewer: w.rev); let wt = try w.claim(i, w.eng)
        try w.write("src/work.txt", "work\n", in: wt)
        try w.submit(i, w.eng)
        try await w.cycle()
        let turn = try w.store.startTurn(agentId: w.rev.id, now: w.now)
        try w.store.setTurnContext(turnId: turn.id, kind: .review, itemId: i.id)
        _ = try w.store.review(itemId: i.id, by: w.rev.id, decision: .requestChanges, notes: "remove \(s) please", approveFlags: false,
                               currentHead: try w.branchHead(i), now: w.now)
        let changes = try #require(try w.events(i).last { $0.kind == .changesRequested })
        #expect(changes.text == "remove [redacted REVIEW_KEY] please")
        // The approval note carries the notes too.
        try w.submit(i, w.eng, "again")
        try await w.cycle()
        try w.db { db in _ = try w.store.engineSetStatus(db: db, itemId: i.id, to: .inReview, now: w.now) }
        let turn2 = try w.store.startTurn(agentId: w.rev.id, now: w.now)
        try w.store.setTurnContext(turnId: turn2.id, kind: .review, itemId: i.id)
        _ = try w.store.review(itemId: i.id, by: w.rev.id, decision: .approve, notes: "ok \(s)", approveFlags: true,
                               currentHead: try w.branchHead(i), now: w.now)
        let approvedEvents = try w.events(i).filter { $0.kind == .reviewApproved }
        #expect(approvedEvents.contains { $0.text.contains("[redacted REVIEW_KEY]") }, "\(approvedEvents.map(\.text))")
        // An audit's notes (a failed audit's comment and the sample's notes).
        let done = try w.fresh(i)
        try w.db { db in
            try db.execute(sql: "UPDATE workItem SET status = 'done', mergedCommit = 'abc' WHERE id = ?", arguments: [done.id])
            let sample = ReviewAudit(itemId: done.id, companyId: w.company.id, sampledActive: 0, authorId: w.eng.id, auditorId: w.rev.id)
            try sample.insert(db)
        }
        let auditTurn = try w.store.startTurn(agentId: w.rev.id, now: w.now)
        try w.store.bindAuditTurn(turnId: auditTurn.id, agentId: w.rev.id, itemIds: [done.id])
        _ = try w.store.recordAudit(turnId: auditTurn.id, agentId: w.rev.id, companyId: w.company.id, key: done.key, ok: false,
                                    notes: "leaked \(s)", now: w.now)
        let sample = try #require(try w.store.reviewAudits(companyId: w.company.id).first { $0.itemId == done.id })
        #expect(sample.notes == "leaked [redacted REVIEW_KEY]")
        #expect(!(try dumpDatabase(w.store)).contains("second-line-77"))
    }

    // MARK: Push settings (7b re-review carry-overs)

    @Test func pushCredentialsVersionBumpsBeforeTheVaultIsWritten() throws {
        let store = try Store.inMemory()
        let before = try store.pushCredentialsVersion()
        final class WatchingVault: SecretVault, @unchecked Sendable {
            let inner = MemoryVault(); let store: Store
            let lock = NSLock(); var seen: [Int] = []
            init(store: Store) { self.store = store }
            func set(companyId: String, name: String, value: String) throws {
                lock.withLock { seen.append((try? store.pushCredentialsVersion()) ?? -1) }
                try inner.set(companyId: companyId, name: name, value: value)
            }
            func value(companyId: String, name: String) throws -> String? { try inner.value(companyId: companyId, name: name) }
            func delete(companyId: String, name: String) throws { try inner.delete(companyId: companyId, name: name) }
        }
        let vault = WatchingVault(store: store)
        try PushSettings.setNtfy(store: store, vault: vault, topic: "long-random-topic-9f3a", server: nil, token: "tk_abcdefghijklmnop")
        #expect(vault.lock.withLock { vault.seen } == [before + 1], "the version moved before the token was written")
        #expect(try store.pushCredentialsVersion() > before + 1, "and again when the settings were stored")
        // Every `setPush` bumps the version: nothing can change push settings around `PushSettings` without invalidating a cached channel.
        let v = try store.pushCredentialsVersion()
        try store.setPush(provider: .ntfy, topic: "long-random-topic-9f3a")
        #expect(try store.pushCredentialsVersion() == v + 1)
    }
}
