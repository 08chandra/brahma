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
        let mgr: Agent, eng: Agent, eng2: Agent, rev: Agent, outsider: Agent
        let vault: MemoryVault
        var store: Store { world.store }
        var now: Date { world.clock.now }
        var root: URL { URL(fileURLWithPath: company.workspacePath, isDirectory: true) }
        var ws: GitWorkspace { GitWorkspace(root: root) }

        init(profile: PermissionProfile = .workspace,
             planSelector: @escaping @Sendable (Agent, WorkItem, Company) -> Bool = { _, _, _ in false }) throws {
            let v = MemoryVault()
            vault = v
            world = try World(planSelector: planSelector, vault: v)
            company = try world.company("Acme", profile: profile)
            other = try world.company("Bolt", profile: profile)
            mgr = try world.hire(company, "mgr", role: "manager")
            let (store, companyId, managerId) = (world.store, company.id, mgr.id)
            func report(_ n: String) throws -> Agent {
                try store.hire(companyId: companyId, name: n, role: "engineer", model: "sonnet", managerId: managerId)
            }
            eng = try report("eng-1")
            eng2 = try report("eng-2")
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
        func approve(_ i: WorkItem, by reviewer: Agent? = nil) throws {
            let a = reviewer ?? rev
            let turn = try store.startTurn(agentId: a.id, now: now)
            try store.setTurnContext(turnId: turn.id, kind: .review, itemId: i.id)
            _ = try store.review(itemId: i.id, by: a.id, decision: .approve, notes: "fine", approveFlags: true,
                                 currentHead: try branchHead(i), now: now)
        }
        /// A commit the holder makes with its own git in its worktree.
        func commitInWorktree(_ i: WorkItem, _ files: [String: String], message: String = "work") throws {
            let wt = ws.worktreePath(key: i.key)
            for (path, text) in files { try write(path, text, in: wt) }
            try GitFixture.plainGit(["add", "-A"], in: wt)
            try GitFixture.plainGit(["commit", "-q", "-m", message], in: wt)
        }
        func activity() throws -> [String] { try store.events(afterId: 0, companyId: company.id).map(\.text) }
        func alerts() throws -> [Ask] { try asks().filter { $0.kind == .engineAlert } }
        /// One holder work turn whose script runs `body` in the worktree.
        func turn(_ a: Agent, _ body: @escaping @Sendable (TurnRequest) throws -> Void = { _ in }) async throws {
            world.fake.script(a.name, .init(sideEffect: body))
            try world.dm(company, a)
            try await cycle()
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
        #expect(refusal.contains("src/config.txt")); #expect(refusal.lowercased().contains("rewrite"), "the recovery is an in-turn rewrite")
        #expect(!refusal.contains(value))
        #expect(try w.fresh(i).status == .inProgress)
        #expect(try w.store.latestVerification(itemId: i.id) == nil)
        #expect(!(try dumpDatabase(w.store)).contains(value))
        // The percent-encoded form is found too; removing the value makes the change acceptable.
        let encoded = value.addingPercentEncoding(withAllowedCharacters: CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")) ?? ""
        #expect(encoded != value)
        try w.write("src/config.txt", "url=https://x/?k=\(encoded)\n", in: wt)
        #expect(w.failure { try w.submit(i, w.eng) }.contains("known secret STRIPE_TEST_KEY"))
        // The value is in two earlier commits of the branch: a clean file is not enough, the branch is rewritten (in this turn).
        try w.write("src/config.txt", "key=from-the-environment\n", in: wt)
        #expect(w.failure { try w.submit(i, w.eng) }.contains("known secret STRIPE_TEST_KEY"), "history is scanned too")
        try GitFixture.plainGit(["reset", "-q", "--soft", try w.mainHead()], in: wt)
        try GitFixture.plainGit(["commit", "-q", "-m", "clean"], in: wt)
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

    @Test func submitRefusesSecretInHistory() throws {
        let w = try W()
        try w.commitMain(["README.md": "hello\n"])
        let i = try w.item(); let wt = try w.claim(i, w.eng)
        try w.commitInWorktree(i, [".env": "AWS=\(aws)\n"], message: "oops")
        let leak = try #require(try w.branchHead(i))
        try FileManager.default.removeItem(at: wt.appending(path: ".env"))
        try w.commitInWorktree(i, ["src/work.txt": "work\n"], message: "remove .env")
        let refusal = w.failure { try w.submit(i, w.eng) }
        #expect(refusal.contains("aws-key"), Comment(rawValue: refusal)); #expect(refusal.contains(".env"))
        #expect(refusal.contains("commit \(leak.prefix(7))"), Comment(rawValue: refusal)); #expect(!refusal.contains(aws))
        #expect(refusal.lowercased().contains("rewrite"), "the recovery is an in-turn rewrite")
        #expect(try w.fresh(i).status == .inProgress)
        // The holder rewrites in its turn: the leaked commit is gone, the submit passes (same turn: continuity held at start).
        try GitFixture.plainGit(["reset", "-q", "--soft", try w.mainHead()], in: wt)
        try GitFixture.plainGit(["commit", "-q", "-m", "clean"], in: wt)
        #expect(try w.submit(i, w.eng).hasPrefix("Submitted \(i.key)"))
    }

    @Test func scanSeesBinaryAndAttributeMarkedFiles() throws {
        let w = try W()
        // (a) main marks a path binary and another -diff; (c) ordinary text under the engine's forced attributes.
        try w.commitMain(["README.md": "hello\n", ".gitattributes": "*.bin binary\n*.dat -diff\n"])
        let i = try w.item(); let wt = try w.claim(i, w.eng)
        try w.write("creds.bin", "key: \(aws)\n", in: wt)
        let a = w.failure { try w.submit(i, w.eng) }
        #expect(a.contains("aws-key") && a.contains("creds.bin"), Comment(rawValue: a))
        try FileManager.default.removeItem(at: wt.appending(path: "creds.bin"))
        try w.write("creds.dat", "key: \(aws)\n", in: wt)
        let d = w.failure { try w.submit(i, w.eng) }
        #expect(d.contains("aws-key") && d.contains("creds.dat"), Comment(rawValue: d))
        // (b) a file git itself sees as binary (a NUL byte) is scanned as text or refused, never passed.
        try FileManager.default.removeItem(at: wt.appending(path: "creds.dat"))
        try Data("x\u{0}y\n\(aws)\n".utf8).write(to: wt.appending(path: "blob.bin"))
        let b = w.failure { try w.submit(i, w.eng) }
        #expect(b.contains("aws-key") || b.contains("binary"), Comment(rawValue: b))
        #expect(!b.contains(aws)); #expect(try w.fresh(i).status == .inProgress)
        // (c) plain text still caught (regression against the `-diff` override making every file binary).
        try FileManager.default.removeItem(at: wt.appending(path: "blob.bin"))
        try w.write("src/plain.txt", "\(aws)\n", in: wt)
        #expect(w.failure { try w.submit(i, w.eng) }.contains("aws-key"))
    }

    @Test func binaryLinesAreFailClosedFindings() {
        let diff = """
            diff --git a/x.bin b/x.bin
            new file mode 100644
            index 0000000..1111111
            Binary files /dev/null and b/x.bin differ
            """
        let found = SecretScan.findings(diff: diff, knownValues: [])
        #expect(found.count == 1); #expect(found.first?.contains("x.bin") == true); #expect(found.first?.contains("binary") == true)
        let patch = "diff --git a/y.bin b/y.bin\nindex 1..2 100644\nGIT binary patch\nliteral 5\nMcmZQzWMnpa\n\n"
        #expect(SecretScan.findings(diff: patch, knownValues: []).contains { $0.contains("y.bin") })
        // Per-commit output names the commit; a secret-looking file name is a finding of its own.
        let log = "commit " + String(repeating: "a", count: 40) + "\n\ndiff --git a/\(aws).json b/\(aws).json\nnew file mode 100644\n--- /dev/null\n+++ b/\(aws).json\n@@ -0,0 +1 @@\n+{}\n"
        let named = SecretScan.findings(diff: log, knownValues: [])
        #expect(named.contains { $0.contains("aws-key") && $0.contains("file name") && $0.contains("commit aaaaaaa") }, "\(named)")
        #expect(!named.contains { $0.contains(aws) })
    }

    @Test func submitRefusesSecretInFilePath() throws {
        let w = try W()
        try w.commitMain(["README.md": "hello\n"])
        let i = try w.item(); let wt = try w.claim(i, w.eng)
        try w.write("keys/\(aws).pem", "nothing here\n", in: wt)
        let refusal = w.failure { try w.submit(i, w.eng) }
        #expect(refusal.contains("aws-key") && refusal.contains("file name"), Comment(rawValue: refusal))
        #expect(!refusal.contains(aws)); #expect(try w.fresh(i).status == .inProgress)
    }

    @Test func orphanBranchScanUsesTheEmptyTree() throws {
        let w = try W()
        try w.commitMain(["README.md": "hello\n"])
        let i = try w.item()
        // A branch with no common history is planted before the claim (what an agent can do with plain git).
        let orphan = try GitFixture.plainGit(["commit-tree", try GitFixture.plainGit(["hash-object", "-t", "tree", "-w", "--stdin"], in: w.root), "-m", "orphan"], in: w.root)
        try GitFixture.plainGit(["branch", w.ws.branch(key: i.key), orphan], in: w.root)
        let wt = try w.claim(i, w.eng)
        #expect(try w.fresh(i).baseCommit == nil)
        try w.write("src/creds.txt", "\(aws)\n", in: wt)
        let refusal = w.failure { try w.submit(i, w.eng) }
        #expect(refusal.contains("aws-key"), Comment(rawValue: refusal))
        try w.write("src/creds.txt", "clean\n", in: wt)
        try GitFixture.plainGit(["reset", "-q", "--soft", orphan], in: wt)
        try GitFixture.plainGit(["add", "-A"], in: wt)
        try GitFixture.plainGit(["commit", "-q", "-m", "clean"], in: wt)
        #expect(try w.submit(i, w.eng).hasPrefix("Submitted \(i.key)"))
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
        #expect(!(try w.fresh(i).branchMoved))
        // A rewrite between turns (back to the claim head) breaks continuity at the next turn's start: flagged, and the submit
        // is refused until a manager re-adopts the branch; then it is the recorded head again.
        try GitFixture.plainGit(["update-ref", w.ws.branchRef(key: i.key), atClaim], in: w.root)
        try await w.turn(w.eng)
        #expect(try w.fresh(i).branchMoved); #expect(try w.fresh(i).leaseHeadCommit == afterTurn, "the record does not follow the move")
        #expect(try w.activity().contains { $0.contains("moved outside") && $0.contains(i.key) })
        #expect(try w.alerts().contains { $0.title.contains(i.key) })
        try w.write("src/again.txt", "again\n", in: wt)
        #expect(w.failure { try w.submit(i, w.eng) } == "\(i.key)'s branch moved outside your turn; ask your manager")
        let own = w.failure { try w.call(w.eng, "readopt_branch", ["key": .string(i.key)]) }
        #expect(own.contains("manager") || own.contains("role"), "the holder cannot re-adopt its own branch: \(own)")
        #expect(try w.call(w.mgr, "readopt_branch", ["key": .string(i.key)]).contains(i.key))
        let readopted = try w.fresh(i)
        #expect(!readopted.branchMoved); #expect(readopted.leaseHeadCommit == atClaim)
        #expect(try w.submit(i, w.eng).hasPrefix("Submitted \(i.key)"))
    }

    @Test func rewriteInOneTurnRefusesSubmitInTheNext() async throws {
        let w = try W()
        try w.commitMain(["README.md": "hello\n"])
        let i = try w.item(); let wt = try w.claim(i, w.eng)
        try await w.turn(w.eng) { _ in   // the record moves to the holder's own commit
            try "a\n".write(to: wt.appending(path: "a.txt"), atomically: true, encoding: .utf8)
            try GitFixture.plainGit(["add", "-A"], in: wt)
            try GitFixture.plainGit(["commit", "-q", "-m", "a"], in: wt)
        }
        let recorded = try #require(try w.fresh(i).leaseHeadCommit)
        #expect(recorded == (try w.branchHead(i)))
        // In its next turn the holder rewrites the branch (a reset and a new commit) but does not submit: continuity held at
        // the start of that turn, so the rewrite is its own, but the record does not advance to a non-descendant...
        try await w.turn(w.eng) { _ in
            try GitFixture.plainGit(["reset", "-q", "--hard", "HEAD~1"], in: wt)
            try "b\n".write(to: wt.appending(path: "b.txt"), atomically: true, encoding: .utf8)
            try GitFixture.plainGit(["add", "-A"], in: wt)
            try GitFixture.plainGit(["commit", "-q", "-m", "rewritten"], in: wt)
        }
        // ...and the submit in the turn after is refused.
        #expect(try w.fresh(i).leaseHeadCommit == recorded); #expect(try w.fresh(i).branchMoved)
        try await w.turn(w.eng) { _ in
            let out = (try? CompanyTools(store: w.store, companyId: w.company.id, agentId: w.eng.id)
                .call(name: "submit_for_review", arguments: ["key": .string(i.key), "summary": .string("done")])) ?? "refused"
            guard out == "refused" else { throw FakeError(description: out) }
        }
        #expect(try w.world.turns(w.eng).last?.outcome == .succeeded)
        #expect(try w.fresh(i).status == .inProgress)
        #expect(w.failure { try w.submit(i, w.eng) } == "\(i.key)'s branch moved outside your turn; ask your manager")
    }

    @Test func conflictRebaseResubmitInTurnAccepted() async throws {
        let w = try W()
        try w.commitMain(["src/work.txt": "base\n"])
        let a = try w.item("a", reviewer: w.mgr), b = try w.item("b", reviewer: w.mgr)
        let wa = try w.claim(a, w.eng), wb = try w.claim(b, w.eng2)
        try w.write("src/work.txt", "from a\n", in: wa)
        try w.write("src/work.txt", "from b\n", in: wb)
        try w.submit(a, w.eng); try w.submit(b, w.eng2)
        try await w.cycle()
        try w.approve(a, by: w.mgr); try w.approve(b, by: w.mgr)
        for _ in 0..<6 where try w.fresh(a).status != .done { try await w.cycle() }
        #expect(try w.fresh(a).status == .done)
        for _ in 0..<4 where try w.fresh(b).status != .inProgress { try await w.cycle() }
        #expect(try w.fresh(b).status == .inProgress, "b's rebase conflicted and it is back with its holder")
        #expect(try w.events(b).contains { $0.kind == .mergeConflict })
        // The holder follows the conflict brief in its turn: rebase onto main, resolve, resubmit. All in one turn: accepted.
        let main = try w.mainHead()
        try await w.turn(w.eng2) { _ in
            let tools = CompanyTools(store: w.store, companyId: w.company.id, agentId: w.eng2.id)
            _ = try GitFixture.plainGit(["rebase", main], in: wb, allowFailure: true)
            try "merged\n".write(to: wb.appending(path: "src/work.txt"), atomically: true, encoding: .utf8)
            try GitFixture.plainGit(["add", "-A"], in: wb)
            try GitFixture.plainGit(["-c", "core.editor=true", "rebase", "--continue"], in: wb, env: ["GIT_EDITOR": "true"])
            let out = try tools.call(name: "submit_for_review", arguments: ["key": .string(b.key), "summary": .string("rebased")])
            guard out.hasPrefix("Submitted \(b.key)") else { throw FakeError(description: out) }
        }
        let last = try w.world.turns(w.eng2).last
        #expect(last?.outcome == .succeeded, Comment(rawValue: last?.summary ?? ""))
        #expect(try w.fresh(b).status == .inReview); #expect(!(try w.fresh(b).branchMoved))
        #expect(try w.fresh(b).leaseHeadCommit == (try w.branchHead(b)), "the accepted submit is the recorded head")
        #expect(try w.ws.isAncestor(main, of: try #require(try w.branchHead(b))))
    }

    @Test func mergeStepRescans() async throws {
        let w = try W()
        try w.commitMain(["README.md": "hello\n"])
        let value = "leak-value-abcdef-123456"
        let i = try w.item(reviewer: w.rev); let wt = try w.claim(i, w.eng)
        // The value is committed, then removed in a later commit: the endpoint diff is clean, the history is not.
        try w.commitInWorktree(i, ["src/config.txt": "token=\(value)\n"], message: "leak")
        let leak = try #require(try w.branchHead(i))
        try FileManager.default.removeItem(at: wt.appending(path: "src/config.txt"))
        try w.commitInWorktree(i, ["src/work.txt": "work\n"], message: "cleanup")
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
        #expect(event.text.contains("commit \(leak.prefix(7))"), "the finding names the commit")
        #expect(try w.dms(to: w.eng).contains { $0.contains("known secret LEAK_KEY") && $0.lowercased().contains("rewrite") })
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

    @Test func failedScrubWithholdsTheLog() throws {
        // A store that has secrets but has not loaded them (a fresh process whose vault is down) must not leave a raw log.
        let home = try tempDir()
        let path = home.appending(path: "brahma.sqlite").path
        let vault = MemoryVault()
        let first = try Store(path: path)
        let company = try first.createCompany(name: "Acme", goal: "g", workspacesRoot: home.appending(path: "ws"))
        try first.setSecret(companyId: company.id, name: "LOG_KEY", value: "log-key-value-12345", isTest: true, vault: vault)
        try first.close()
        let reopened = try Store(path: path)
        #expect(reopened.secretsHeld)
        let log = home.appending(path: "check.log")
        try "env LOG_KEY=log-key-value-12345\n".write(to: log, atomically: true, encoding: .utf8)
        #expect(throws: (any Error).self) { try reopened.scrubCheckLog(log) }
        #expect(!FileManager.default.fileExists(atPath: log.path), "a log that cannot be scrubbed is removed")
        // A loaded store scrubs in place; a link where the log should be is refused and removed too.
        _ = try reopened.reloadRedactorIfNeeded(vault: vault, force: true)
        try "env LOG_KEY=log-key-value-12345\n".write(to: log, atomically: true, encoding: .utf8)
        try reopened.scrubCheckLog(log)
        #expect(try String(contentsOf: log, encoding: .utf8) == "env LOG_KEY=[redacted LOG_KEY]\n")
        let target = home.appending(path: "target.txt")
        try "keep me\n".write(to: target, atomically: true, encoding: .utf8)
        let link = home.appending(path: "link.log")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: target)
        #expect(throws: (any Error).self) { try reopened.scrubCheckLog(link) }
        #expect(!FileManager.default.fileExists(atPath: link.path)); #expect(try String(contentsOf: target, encoding: .utf8) == "keep me\n")
        #expect(throws: (any Error).self) { try Redactor().scrubFile(target) }   // never loaded: refuses rather than passing the file
        try reopened.close()
    }

    @Test func provideSecretIsAtomicAndGenericApproveRefuses() throws {
        let w = try W()
        _ = try w.call(w.eng, "request_secret", ["name": .string("ATOMIC_KEY"), "reason": .string("r"), "test": .bool(true)])
        let ask = try #require(try w.asks().first)
        // The generic owner approve does not approve a secret request: there is nothing to approve without a value.
        let generic = w.failure { try w.store.ownerDecide(askId: ask.id, approve: true, note: "ok"); return "approved" }
        #expect(generic.contains("provide"), Comment(rawValue: generic))
        #expect(try w.store.ask(id: ask.id)?.status == .pendingOwner)
        #expect(try w.store.secrets(companyId: w.company.id).isEmpty)
        // Rejecting it is still the owner's call.
        _ = try w.store.ownerDecide(askId: ask.id, approve: false, note: "no")
        // A request decided meanwhile cannot be provided for, and the vault keeps no value from the attempt.
        #expect(throws: WorkError.self) { try w.store.provideSecret(askId: ask.id, value: "late-value-123456", isTest: true, vault: w.vault) }
        #expect(try w.vault.value(companyId: w.company.id, name: "ATOMIC_KEY") == nil)
        #expect(try w.store.secrets(companyId: w.company.id).isEmpty)
    }

    @Test func nonWorkTurnsGetNoSecretsOrKeepNames() async throws {
        let w = try W(profile: .sandboxed, planSelector: { _, item, _ in item.title == "Planned" })
        try w.set("TEST_KEY", "test-key-value-12345", test: true)
        // A review turn of an agent that holds a key elsewhere: nothing injected, nothing kept.
        let mine = try w.item("Mine"); try w.claim(mine, w.rev)
        _ = try w.call(w.rev, "use_secret", ["name": .string("TEST_KEY")])
        try w.commitMain(["README.md": "hello\n"])
        let theirs = try w.item("Theirs", reviewer: w.rev); let wt = try w.claim(theirs, w.eng)
        try w.write("src/work.txt", "work\n", in: wt)
        try w.submit(theirs, w.eng)
        try await w.cycle()   // the check
        try await w.cycle()   // the review turn of rev
        let review = try #require(w.requests(w.rev).last { $0.kind == .review })
        #expect(review.secrets.isEmpty)
        #expect(!(try String(contentsOfFile: try #require(review.shellPrefix), encoding: .utf8)).contains("TEST_KEY"))
        // A plan turn on the leased item: nothing injected, nothing kept.
        let planned = try w.item("Planned"); try w.claim(planned, w.eng2)
        _ = try w.call(w.eng2, "use_secret", ["name": .string("TEST_KEY")])
        try w.world.dm(w.company, w.eng2)
        try await w.cycle()
        let plan = try #require(w.requests(w.eng2).last)
        #expect(plan.kind == .plan); #expect(plan.secrets.isEmpty)
        #expect(!(try String(contentsOfFile: try #require(plan.shellPrefix), encoding: .utf8)).contains("TEST_KEY"))
    }

    // MARK: 4-wire fix round 2

    /// Moves the item branch to a commit that does not descend from the recorded head (as something outside the holder's
    /// turns could) and runs the turn-start continuity check, which flags it.
    private func moveAndFlag(_ w: W, _ i: WorkItem, holder: Agent) throws {
        let recorded = try #require(try w.fresh(i).leaseHeadCommit)
        let tree = try GitFixture.plainGit(["rev-parse", "\(recorded)^{tree}"], in: w.root)
        let orphan = try GitFixture.plainGit(["commit-tree", tree, "-m", "moved \(UUID().uuidString)"], in: w.root)
        try GitFixture.plainGit(["update-ref", w.ws.branchRef(key: i.key), orphan], in: w.root)
        #expect(!(try w.store.checkBranchContinuity(item: try w.fresh(i), agent: holder, head: try w.branchHead(i), now: w.now)))
        #expect(try w.fresh(i).branchMoved)
    }

    @Test func readoptAuthorityAndFlagHandling() throws {
        let w = try W()
        try w.commitMain(["README.md": "hello\n"])
        let mgr2 = try w.store.hire(companyId: w.company.id, name: "mgr-2", role: "manager", model: "sonnet")
        let ceo = try w.store.hire(companyId: w.company.id, name: "ceo", role: "ceo", model: "sonnet")
        let i = try w.item(); try w.claim(i, w.eng)
        // Nothing flagged: nothing to re-adopt (a lead cannot silently adopt a move before it is detected).
        let unflagged = w.failure { try w.call(w.mgr, "readopt_branch", ["key": .string(i.key)]) }
        #expect(unflagged.contains("nothing to re-adopt"), Comment(rawValue: unflagged))
        try moveAndFlag(w, i, holder: w.eng)
        // N4: an item already flagged is not flagged again at the next turn start (no repeated activity, event or alert).
        let (activity, events, alerts) = (try w.activity().count, try w.events(i).count, try w.alerts().count)
        #expect(!(try w.store.checkBranchContinuity(item: try w.fresh(i), agent: w.eng, head: try w.branchHead(i), now: w.now)))
        #expect(try w.activity().count == activity); #expect(try w.events(i).count == events); #expect(try w.alerts().count == alerts)
        // The holder (an engineer) and an unrelated lead are refused; the holder's direct manager may, and is recorded.
        #expect(throws: WorkError.self) { try w.store.readoptBranch(itemId: i.id, by: .agent(w.eng.id), head: try w.branchHead(i)) }
        let unrelated = w.failure { try w.call(mgr2, "readopt_branch", ["key": .string(i.key)]) }
        #expect(unrelated.contains("only the manager"), Comment(rawValue: unrelated))
        #expect(try w.fresh(i).branchMoved)
        #expect(try w.call(w.mgr, "readopt_branch", ["key": .string(i.key)]).contains(i.key))
        #expect(!(try w.fresh(i).branchMoved))
        #expect(try w.events(i).contains { $0.actorId == w.mgr.id && $0.text.contains("re-adopted") && $0.text.contains("@mgr") })
        // The owner may.
        try moveAndFlag(w, i, holder: w.eng)
        let byOwner = try w.store.readoptBranch(itemId: i.id, by: .owner, head: try w.branchHead(i))
        #expect(!byOwner.branchMoved); #expect(byOwner.leaseHeadCommit == (try w.branchHead(i)))
        #expect(try w.events(i).contains { $0.actorId == "owner" && $0.text.contains("re-adopted") })
        // A lead that holds the item cannot re-adopt its own branch (S12); an executive can.
        let j = try w.item("Lead's own"); try w.claim(j, w.mgr)
        try moveAndFlag(w, j, holder: w.mgr)
        let own = w.failure { try w.call(w.mgr, "readopt_branch", ["key": .string(j.key)]) }
        #expect(own.contains("you hold"), Comment(rawValue: own)); #expect(try w.fresh(j).branchMoved)
        #expect(try w.call(ceo, "readopt_branch", ["key": .string(j.key)]).contains(j.key))
        #expect(!(try w.fresh(j).branchMoved))
        // N5: a high-risk tool (quota-counted, out of plan turns, denied under taint).
        #expect(CompanyTools.highRiskTools.contains("readopt_branch"))
    }

    @Test func flaggedHolderCannotClearTheFlagByReclaiming() throws {
        let w = try W()
        try w.commitMain(["README.md": "hello\n"])
        let i = try w.item(); try w.claim(i, w.eng)
        try moveAndFlag(w, i, holder: w.eng)
        _ = try w.call(w.eng, "release_lease", ["key": .string(i.key)])
        let wt = try w.claim(i, w.eng)
        #expect(try w.fresh(i).branchMoved, "a claim records the head but never clears the flag")
        #expect(try w.fresh(i).leaseHeadCommit == (try w.branchHead(i)))
        try w.write("src/work.txt", "work\n", in: wt)
        #expect(w.failure { try w.submit(i, w.eng) } == "\(i.key)'s branch moved outside your turn; ask your manager")
        #expect(try w.fresh(i).status == .inProgress)
    }

    @Test func continuityReadsTheItemAgain() throws {
        // N3: a stale snapshot (taken before an engine move was recorded) does not flag the engine's own move.
        let w = try W()
        try w.commitMain(["README.md": "hello\n"])
        let i = try w.item(); let wt = try w.claim(i, w.eng)
        let stale = try w.fresh(i)
        try w.commitInWorktree(i, ["src/a.txt": "a\n"])
        let moved = try #require(try w.branchHead(i))
        try w.store.recordLeaseHead(itemId: i.id, commit: moved)
        _ = wt
        #expect(try w.store.checkBranchContinuity(item: stale, agent: w.eng, head: moved, now: w.now))
        #expect(!(try w.fresh(i).branchMoved))
    }

    @Test func crlfAndCombiningMarkLinesAreScanned() throws {
        // N2, unit: a combining mark after the `+` does not hide the line; a CRLF line is its own line, also for known values.
        let zwj = "diff --git a/c b/c\n--- a/c\n+++ b/c\n@@ -0,0 +1 @@\n+\u{200D}\(aws)\n"
        #expect(SecretScan.findings(diff: zwj, knownValues: []).contains { $0.contains("aws-key") })
        #expect(SecretScan.findings(diff: "+\u{301}\(aws)\n", knownValues: []).count == 1, "bare fragment too")
        let value = "crlf-known-value-123"
        let crlf = "diff --git a/c.env b/c.env\n--- a/c.env\n+++ b/c.env\n@@ -1 +1 @@\n-API=changeme\r\n+API=\(value)\r\n"
        let known = SecretScan.findings(diff: crlf, knownValues: [("CRLF_KEY", value)])
        #expect(known == ["known secret CRLF_KEY in c.env (added line 1)"], "\(known)")
    }

    @Test func crlfEditsAreCaughtByBothScans() throws {
        let w = try W()
        try w.commitMain(["c.env": "API=changeme\r\nNAME=x\r\n"])
        let i = try w.item(); let wt = try w.claim(i, w.eng)
        let main = try w.mainHead()
        // scanDiff: a modification of an existing CRLF file (patterns and known values).
        let value = "crlf-known-value-123"
        try w.commitInWorktree(i, ["c.env": "API=\(aws)\r\nNAME=\(value)\r\n"], message: "edit")
        let leak = try #require(try w.branchHead(i))
        let diff = try w.ws.scanDiff(base: main, head: leak).text
        #expect(diff.contains("\r\n"), "the fixture really is CRLF")
        let endpoint = SecretScan.findings(diff: diff, knownValues: [("CRLF_KEY", value)])
        #expect(endpoint.contains { $0.contains("aws-key") && $0.contains("c.env") }, "\(endpoint)")
        #expect(endpoint.contains { $0.contains("known secret CRLF_KEY") }, "\(endpoint)")
        // scanLog: modified then reverted in a later commit (the endpoint diff is empty): the history still carries it.
        try w.commitInWorktree(i, ["c.env": "API=changeme\r\nNAME=x\r\n", "src/w.txt": "w\n"], message: "revert")
        #expect(SecretScan.findings(diff: try w.ws.scanDiff(base: main, head: try #require(try w.branchHead(i))).text, knownValues: [])
            .isEmpty)
        let refusal = w.failure { try w.submit(i, w.eng) }
        #expect(refusal.contains("aws-key") && refusal.contains("commit \(leak.prefix(7))"), Comment(rawValue: refusal))
        #expect(!refusal.contains(aws)); _ = wt
    }

    @Test func commitMessagesAreScannedAndFindingsDeduped() throws {
        let w = try W()
        try w.commitMain(["README.md": "hello\n"])
        let i = try w.item(); let wt = try w.claim(i, w.eng)
        try w.commitInWorktree(i, ["src/w.txt": "w\n"], message: "use key \(aws)")
        let refusal = w.failure { try w.submit(i, w.eng) }
        #expect(refusal.contains("aws-key in a commit message or header"), Comment(rawValue: refusal))
        #expect(!refusal.contains(aws))
        #expect(refusal.contains("If that turn ends without an accepted submit"), "the refusal names the recovery path")
        // Author fields too, through the same scan.
        try GitFixture.plainGit(["reset", "-q", "--soft", try w.mainHead()], in: wt)
        try GitFixture.plainGit(["-c", "user.email=\(aws)@example.com", "commit", "-q", "-m", "clean"], in: wt)
        #expect(w.failure { try w.submit(i, w.eng) }.contains("aws-key in a commit message or header"))
        // One finding per (rule, place): the same secret in a commit and in the endpoint diff is reported once.
        try GitFixture.plainGit(["reset", "-q", "--soft", try w.mainHead()], in: wt)
        try w.write(".env", "AWS=\(aws)\n", in: wt)
        try GitFixture.plainGit(["add", "-A"], in: wt)
        try GitFixture.plainGit(["commit", "-q", "-m", "env"], in: wt)
        let found = try SecretScan.check(git: w.ws, base: try w.mainHead(), head: try #require(try w.branchHead(i)), knownValues: [])
        #expect(found.filter { $0.hasPrefix("aws-key in .env") }.count == 1, "\(found)")
    }

    @Test func secondConcurrentProvideLeavesTheWinnersValue() throws {
        let w = try W()
        _ = try w.call(w.eng, "request_secret", ["name": .string("RACE_KEY"), "reason": .string("r"), "test": .bool(true)])
        let ask = try #require(try w.asks().first)
        /// The first provide lands while the second is between its pre-check and its write (two taps, or the app and the CLI).
        final class RacingVault: SecretVault, @unchecked Sendable {
            let inner: MemoryVault
            var hook: (() throws -> Void)?
            init(inner: MemoryVault) { self.inner = inner }
            func set(companyId: String, name: String, value: String) throws { try inner.set(companyId: companyId, name: name, value: value) }
            func value(companyId: String, name: String) throws -> String? {
                if let h = hook { hook = nil; try h() }
                return try inner.value(companyId: companyId, name: name)
            }
            func delete(companyId: String, name: String) throws { try inner.delete(companyId: companyId, name: name) }
        }
        let racing = RacingVault(inner: w.vault)
        let (store, vault) = (w.store, w.vault)
        racing.hook = { _ = try store.provideSecret(askId: ask.id, value: "first-value-123456", isTest: false, vault: vault) }
        #expect(throws: WorkError.self) {
            try w.store.provideSecret(askId: ask.id, value: "second-value-12345", isTest: true, vault: racing)
        }
        #expect(try w.vault.value(companyId: w.company.id, name: "RACE_KEY") == "first-value-123456", "the winner's value stays")
        #expect(try w.store.secrets(companyId: w.company.id).map(\.isTest) == [false], "under the winner's flag")
        #expect(try w.store.ask(id: ask.id)?.status == .approved)
        // A vault that cannot store leaves the ask pending and no row behind.
        _ = try w.call(w.eng, "request_secret", ["name": .string("DOWN_KEY"), "reason": .string("r"), "test": .bool(true)])
        let down = try #require(try w.asks().first { $0.title == "Secret DOWN_KEY" })
        struct Down: Error {}
        final class FailingVault: SecretVault, @unchecked Sendable {
            func set(companyId: String, name: String, value: String) throws { throw Down() }
            func value(companyId: String, name: String) throws -> String? { nil }
            func delete(companyId: String, name: String) throws {}
        }
        #expect(throws: Down.self) { try w.store.provideSecret(askId: down.id, value: "down-value-123456", isTest: true, vault: FailingVault()) }
        #expect(try w.store.ask(id: down.id)?.status.isPending == true)
        #expect(!(try w.store.secrets(companyId: w.company.id).contains { $0.name == "DOWN_KEY" }))
    }

    @Test func auditTurnsGetNoSecretsOrKeepNames() async throws {
        let w = try W(profile: .sandboxed)
        try w.set("TEST_KEY", "test-key-value-12345", test: true)
        // The auditor holds a key for an item of its own; its audit turn gets nothing.
        let mine = try w.item("Mine"); try w.claim(mine, w.rev)
        _ = try w.call(w.rev, "use_secret", ["name": .string("TEST_KEY")])
        try w.commitMain(["README.md": "hello\n"])
        let base = try w.mainHead()
        try w.commitMain(["src/audited.txt": "audited\n"])
        let merged = try w.mainHead()
        let done = try w.item("Audited", command: nil, reviewer: w.rev)   // the sample is routed to the item's reviewer
        try w.db { db in
            var sample = ReviewAudit(itemId: done.id, companyId: w.company.id, sampledActive: 0, authorId: w.eng.id)
            sample.baseCommit = base; sample.mergedCommit = merged
            try sample.insert(db)
        }
        try await w.cycle()
        let audit = try #require(w.requests(w.rev).last { $0.kind == .audit }, "an audit turn ran")
        #expect(audit.secrets.isEmpty)
        let prefix = audit.shellPrefix.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) } ?? ""
        #expect(!prefix.contains("TEST_KEY"))
    }

    // MARK: 4-wire fix round 3

    @Test func reassignDoesNotLaunderReadoptAuthority() throws {
        let w = try W()
        try w.commitMain(["README.md": "hello\n"])
        let mgr2 = try w.store.hire(companyId: w.company.id, name: "mgr-2", role: "manager", model: "sonnet")
        let eng3 = try w.store.hire(companyId: w.company.id, name: "eng-3", role: "engineer", model: "sonnet", managerId: mgr2.id)
        // (a) A flagged lead holder hands its item to its own report, who claims it; the lead still cannot re-adopt.
        let j = try w.item("Lead's own"); try w.claim(j, w.mgr)
        try moveAndFlag(w, j, holder: w.mgr)
        #expect(try w.fresh(j).branchMovedHolderId == w.mgr.id)
        _ = try w.call(w.mgr, "release_lease", ["key": .string(j.key)])
        _ = try w.call(w.mgr, "update_work_item", ["key": .string(j.key), "owner": .string(w.eng.name)])
        try w.claim(j, w.eng)
        #expect(try w.fresh(j).branchMoved, "a reassignment keeps the flag")
        let a = w.failure { try w.call(w.mgr, "readopt_branch", ["key": .string(j.key)]) }
        #expect(a.contains("you held"), Comment(rawValue: a)); #expect(try w.fresh(j).branchMoved)
        // (b) An unrelated lead reassigns someone else's flagged item to its own report, who claims it; still refused.
        let i = try w.item(); try w.claim(i, w.eng2)
        try moveAndFlag(w, i, holder: w.eng2)
        _ = try w.call(mgr2, "update_work_item", ["key": .string(i.key), "owner": .string(eng3.name)])
        try w.claim(i, eng3)
        #expect(try w.fresh(i).branchMoved)
        let b = w.failure { try w.call(mgr2, "readopt_branch", ["key": .string(i.key)]) }
        #expect(b.contains("only the manager of the agent that held"), Comment(rawValue: b)); #expect(try w.fresh(i).branchMoved)
        // The flagged holder's manager may, after the reassignment; the flag and its holder clear together.
        #expect(try w.call(w.mgr, "readopt_branch", ["key": .string(i.key)]).contains(i.key))
        #expect(!(try w.fresh(i).branchMoved)); #expect(try w.fresh(i).branchMovedHolderId == nil)
    }

    @Test func moveWhileUnleasedIsFlaggedAtClaim() throws {
        let w = try W()
        try w.commitMain(["README.md": "hello\n"])
        let ceo = try w.store.hire(companyId: w.company.id, name: "ceo", role: "ceo", model: "sonnet")
        let i = try w.item(); try w.claim(i, w.eng)
        // The holder's own commits, then a release in the same turn: the next claim takes them as recorded, no flag.
        try w.commitInWorktree(i, ["src/a.txt": "a\n"])
        _ = try w.call(w.eng, "release_lease", ["key": .string(i.key)])
        try w.claim(i, w.eng)
        #expect(!(try w.fresh(i).branchMoved)); #expect(try w.fresh(i).leaseHeadCommit == (try w.branchHead(i)))
        // A move while nobody holds it is flagged at the next claim, not adopted.
        _ = try w.call(w.eng, "release_lease", ["key": .string(i.key)])
        let recorded = try #require(try w.fresh(i).leaseHeadCommit)
        let tree = try GitFixture.plainGit(["rev-parse", "\(recorded)^{tree}"], in: w.root)
        let orphan = try GitFixture.plainGit(["commit-tree", tree, "-m", "while unleased"], in: w.root)
        try GitFixture.plainGit(["update-ref", w.ws.branchRef(key: i.key), orphan], in: w.root)
        let wt = try w.claim(i, w.eng)
        #expect(try w.fresh(i).branchMoved); #expect(try w.fresh(i).branchMovedHolderId == nil)
        #expect(try w.fresh(i).leaseHeadCommit == recorded, "the foreign head is not adopted")
        try w.write("src/b.txt", "b\n", in: wt)
        #expect(w.failure { try w.submit(i, w.eng) } == "\(i.key)'s branch moved outside your turn; ask your manager")
        // Nobody held it: no holder's manager qualifies; an executive does.
        let byManager = w.failure { try w.call(w.mgr, "readopt_branch", ["key": .string(i.key)]) }
        #expect(byManager.contains("only the manager"), Comment(rawValue: byManager))
        #expect(try w.call(ceo, "readopt_branch", ["key": .string(i.key)]).contains(i.key))
        #expect(!(try w.fresh(i).branchMoved))
    }

    @Test func quotedAndSpacedFileNamesAreScanned() throws {
        // Unit: a quoted header (a tab in the name) and a directory ending in " b", both for empty files (no ---/+++ lines).
        let quoted = "diff --git \"a/\(aws)\\tt\" \"b/\(aws)\\tt\"\nnew file mode 100644\nindex 0000000..e69de29\n"
        #expect(SecretScan.findings(diff: quoted, knownValues: []).contains { $0.contains("aws-key in a file name") })
        let spaced = "diff --git a/\(aws) b/z b/\(aws) b/z\nnew file mode 100644\nindex 0000000..e69de29\n"
        #expect(SecretScan.findings(diff: spaced, knownValues: []).contains { $0.contains("aws-key in a file name") })
        // After a quoted header the path is that file's, not the previous one's.
        let next = "diff --git a/one b/one\n--- /dev/null\n+++ b/one\n@@ -0,0 +1 @@\n+fine\n"
            + "diff --git \"a/x\\ty\" \"b/x\\ty\"\nnew file mode 100644\n--- /dev/null\n+++ \"b/x\\ty\"\n@@ -0,0 +1 @@\n+\(aws)\n"
        #expect(SecretScan.findings(diff: next, knownValues: []) == ["aws-key in x\ty (added line 1)"])
        #expect(SecretScan.headerNewName(ArraySlice("a/p b/q b/p b/q".utf8)).map { String(decoding: $0, as: UTF8.self) } == "p b/q")
        // Real git: empty files with such names are refused at submit.
        let w = try W()
        try w.commitMain(["README.md": "hello\n"])
        let i = try w.item(); let wt = try w.claim(i, w.eng)
        try w.write("\(aws)\tt", "", in: wt)
        let tab = w.failure { try w.submit(i, w.eng) }
        #expect(tab.contains("aws-key") && tab.contains("file name"), Comment(rawValue: tab)); #expect(!tab.contains(aws))
        try GitFixture.plainGit(["reset", "-q", "--hard", try w.mainHead()], in: wt)   // the rewrite drops that commit
        try w.write("\(aws) b/z", "", in: wt)
        let dir = w.failure { try w.submit(i, w.eng) }
        #expect(dir.contains("aws-key") && dir.contains("file name"), Comment(rawValue: dir))
    }

    @Test func extraCommitHeadersAreScanned() throws {
        let w = try W()
        try w.commitMain(["README.md": "hello\n"])
        let i = try w.item(); let wt = try w.claim(i, w.eng)
        try w.commitInWorktree(i, ["src/w.txt": "w\n"])
        let parent = try #require(try w.branchHead(i))
        let tree = try GitFixture.plainGit(["rev-parse", "\(parent)^{tree}"], in: w.root)
        let object = "tree \(tree)\nparent \(parent)\nauthor a <a@b> 1 +0000\ncommitter a <a@b> 1 +0000\nx-note \(aws)\n\nplain message\n"
        let file = try tempDir().appending(path: "commit.txt")
        try object.write(to: file, atomically: true, encoding: .utf8)
        let crafted = try GitFixture.plainGit(["hash-object", "-t", "commit", "-w", "--literally", file.path], in: w.root)
        try GitFixture.plainGit(["reset", "-q", "--hard", crafted], in: wt)   // the holder's own move, in its turn
        let refusal = w.failure { try w.submit(i, w.eng) }
        #expect(refusal.contains("aws-key in a commit message or header") && refusal.contains("commit \(crafted.prefix(7))"),
                Comment(rawValue: refusal))
        #expect(!refusal.contains(aws))
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
