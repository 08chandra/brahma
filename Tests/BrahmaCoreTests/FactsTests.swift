import Foundation
import Testing
import GRDB
@testable import BrahmaCore

/// Per-item outcome facts and `brahma perf facts` (Task 14b).
@Suite(.scratch, .serialized) struct FactsTests {
    private struct F {
        let world: World
        let company: Company
        let mgr: Agent, eng: Agent, rev: Agent
        var store: Store { world.store }
        var now: Date { world.clock.now }
        var root: URL { URL(fileURLWithPath: company.workspacePath, isDirectory: true) }
        var ws: GitWorkspace { GitWorkspace(root: root) }

        init() throws {
            let w = try World()
            let c = try w.company("Acme")
            world = w; company = c
            mgr = try w.store.hire(companyId: c.id, name: "mgr", role: "manager", model: "sonnet")
            eng = try w.store.hire(companyId: c.id, name: "eng-1", role: "engineer", model: "sonnet", managerId: mgr.id)
            rev = try w.store.hire(companyId: c.id, name: "rev", role: "engineer", model: "sonnet", managerId: mgr.id)
        }

        func tools(_ a: Agent) -> CompanyTools { CompanyTools(store: store, companyId: company.id, agentId: a.id) }
        func fresh(_ i: WorkItem) throws -> WorkItem { try #require(try store.workItem(id: i.id)) }
        func cycle() async throws {
            await world.orchestrator.tick()
            try await world.orchestrator.waitUntilIdle(timeout: .seconds(300))
        }

        @discardableResult
        func item(_ title: String = "Do it", type: WorkItemType = .task, by author: Sender = .owner, parent: WorkItem? = nil,
                  tier: EffortTier = .m) throws -> WorkItem {
            let n = (try store.workItems(companyId: company.id)).count + 1
            let spec = type == .story || type == .epic ? nil : CheckSpec(command: "true", paths: ["src/p\(n)"])
            return try store.createWorkItem(companyId: company.id, by: author, draft: WorkItemDraft(
                type: type, title: title, checkSpec: spec, tier: tier, reviewerId: spec == nil ? nil : rev.id, parentId: parent?.id,
                status: spec == nil ? .backlog : .ready), now: now)
        }

        func claim(_ i: WorkItem) throws {
            _ = try tools(eng).call(name: "claim_lease", arguments: ["key": .string(i.key)])
        }

        func change(_ i: WorkItem, _ text: String) throws {
            let n = i.number
            let url = ws.worktreePath(key: i.key).appending(path: "src/p\(n)/work.txt")
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
            _ = try tools(eng).call(name: "submit_for_review", arguments: ["key": .string(i.key), "summary": .string("did it")])
        }

        /// Ticks until the item leaves review undecided by a reviewer (its check finished) or `limit` passes.
        func runChecks(_ i: WorkItem, limit: Int = 8) async throws {
            for _ in 0..<limit {
                let item = try fresh(i)
                let pending = try await store.writer.read { db in
                    try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM verificationRun WHERE itemId = ? AND status IN ('queued', 'running')",
                                     arguments: [i.id]) ?? 0
                }
                if item.status != .inReview || (pending == 0 && item.verifiedRevision != nil) { return }
                try await cycle()
            }
        }

        func review(_ i: WorkItem, _ d: ReviewDecision, flags: Bool = false) throws {
            let turn = try store.startTurn(agentId: rev.id, now: now)
            try store.setTurnContext(turnId: turn.id, kind: .review, itemId: i.id)
            _ = try store.review(itemId: i.id, by: rev.id, decision: d, notes: "notes", approveFlags: flags,
                                 currentHead: try ws.head(of: ws.branchRef(key: i.key)), now: now)
            try store.writer.write { db in
                try db.execute(sql: "UPDATE turn SET outcome = 'succeeded', endedAt = ?, costLE = 0.5 WHERE id = ?", arguments: [now, turn.id])
            }
        }

        @discardableResult
        func drive(_ i: WorkItem, limit: Int = 12) async throws -> WorkItem {
            for _ in 0..<limit {
                if try fresh(i).status == .done { break }
                try await cycle()
            }
            return try fresh(i)
        }

        func fact(_ i: WorkItem) throws -> ItemFact { try #require(try store.itemFact(itemId: i.id)) }
    }

    @Test func factsRecordedOnMerge() async throws {
        let f = try F()
        let i = try f.item(tier: .m)
        try f.claim(i)
        try f.change(i, "one")
        try await f.runChecks(i)
        try f.review(i, .requestChanges)
        #expect(try f.fresh(i).status == .inProgress)
        try f.change(i, "two")
        try await f.runChecks(i)
        try f.review(i, .approve)
        #expect(try await f.drive(i).status == .done)
        let fact = try f.fact(i)
        #expect(fact.companyId == f.company.id); #expect(fact.type == "task"); #expect(fact.tier == "m")
        #expect(fact.ownerId == f.eng.id); #expect(fact.reviewerId == f.rev.id)
        #expect(!fact.firstPass, "a review asked for changes")
        #expect(fact.verificationRuns >= 2); #expect(fact.failedRuns == 0); #expect(fact.flakyRuns == 0); #expect(fact.inconclusiveRuns == 0)
        #expect(fact.reworkRounds == 1); #expect(fact.reviewRejections == 1)
        #expect(fact.tierMaxTurns == 15); #expect(fact.tierMaxTokens == 1_000_000); #expect(fact.tierMaxCostLE == 10)
        let usage = try f.store.itemUsage(itemId: i.id)
        #expect(fact.turnsUsed == usage.turns); #expect(fact.tokensUsed == usage.tokens); #expect(fact.costLE == usage.costLE)
        #expect(abs(fact.reviewCostLE - 1.0) < 1e-9, "both review turns")
        #expect(fact.cycleActiveSeconds != nil); #expect(fact.blockedActiveSeconds == 0)
        #expect(fact.checkAuthorId == "owner"); #expect(fact.checkAuthorRole == "owner")
        #expect(fact.mergeConflicts == 0); #expect(!fact.autoMerged); #expect(!fact.audited); #expect(fact.auditVerdict == nil)

        // A clean first pass.
        let j = try f.item("Second", tier: .m)
        try f.claim(j)
        try f.change(j, "only")
        try await f.runChecks(j)
        try f.review(j, .approve)
        #expect(try await f.drive(j).status == .done)
        #expect(try f.fact(j).firstPass)
        #expect(try f.store.itemFacts(companyId: f.company.id).count == 2)
    }

    @Test func blockedActiveTimeSummed() async throws {
        let f = try F()
        let i = try f.item()
        try f.claim(i)
        let start = try f.store.activeNow(companyId: f.company.id)
        func set(_ s: WorkItemStatus) throws {
            _ = try f.store.updateWorkItem(id: i.id, by: .agent(f.eng.id),
                                           patch: WorkItemPatch(status: s, blockedReason: s == .blocked ? "waiting" : nil), now: f.now)
        }
        try f.store.advanceActive(companyId: f.company.id, by: 10)
        try set(.blocked)
        try f.store.advanceActive(companyId: f.company.id, by: 100)
        try set(.inProgress)
        try f.store.advanceActive(companyId: f.company.id, by: 50)
        try set(.blocked)
        try f.store.advanceActive(companyId: f.company.id, by: 30)
        try set(.inProgress)
        try f.change(i, "work")
        try await f.runChecks(i)
        try f.review(i, .approve)
        #expect(try await f.drive(i).status == .done)
        let fact = try f.fact(i)
        #expect(fact.blockedActiveSeconds == 130)
        let cycle = try #require(fact.cycleActiveSeconds)
        #expect(Double(cycle) >= 190 - 1e-9); #expect(Double(cycle) <= (try f.store.activeNow(companyId: f.company.id)) - start + 1)
    }

    @Test func checkAuthorProvenance() async throws {
        let f = try F()
        // The manager edits the owner's check: the manager is its author.
        let i = try f.item("Edited")
        _ = try f.store.updateWorkItem(id: i.id, by: .agent(f.mgr.id),
                                       patch: WorkItemPatch(checkSpec: .some(CheckSpec(command: "true # stricter", paths: ["src/p1"]))), now: f.now)
        // An item the manager wrote, check untouched: its author is.
        let j = try f.item("Written", by: .agent(f.mgr.id))
        for item in [i, j] {
            try f.claim(item)
            try f.change(item, "work")
            try await f.runChecks(item)
            try f.review(item, .approve)
            #expect(try await f.drive(item).status == .done)
        }
        #expect(try f.fact(i).checkAuthorId == f.mgr.id); #expect(try f.fact(i).checkAuthorRole == "manager")
        #expect(try f.fact(j).checkAuthorId == f.mgr.id); #expect(try f.fact(j).checkAuthorRole == "manager")
    }

    @Test func flakyAndInconclusiveCounted() async throws {
        let f = try F()
        let i = try f.item()
        try f.claim(i)
        // Inconclusive (the check could not run), then a real failure, then a pass on the re-run: flaky.
        f.world.checks.enqueue(CheckOutcome(exitCode: nil, timedOut: false, tail: "could not start"), FakeCheckRunner.fail(),
                               FakeCheckRunner.pass)
        try f.change(i, "work")
        try await f.cycle()
        try f.store.advanceActive(companyId: f.company.id, by: Store.inconclusiveDelay + 1)
        try await f.runChecks(i)
        #expect(try f.fresh(i).reviewFlags.contains(Store.flakeFlag))
        try f.review(i, .approve, flags: true)
        #expect(try await f.drive(i).status == .done)
        let fact = try f.fact(i)
        #expect(fact.inconclusiveRuns == 1)
        #expect(fact.failedRuns == 1); #expect(fact.flakyRuns == 1)
        #expect(fact.verificationRuns >= 2, "the failure and the flaky pass (and the merge check, if any)")
        #expect(!fact.firstPass, "the first conclusive run failed")
    }

    @Test func infraExcluded() async throws {
        let f = try F()
        let i = try f.item()
        try f.claim(i)
        func turn(infra: Bool = false, reset: Bool = false, tokens: Int) throws {
            var t = try f.store.startTurn(agentId: f.eng.id, now: f.now)
            t.itemId = i.id; t.outcome = infra || reset ? .failed : .succeeded; t.infra = infra; t.endedAt = f.now
            t.inputTokens = tokens; t.costLE = Double(tokens) / 1000
            if reset { t.sessionResetReason = "session not found" }
            try f.store.writer.write { db in try t.update(db) }
        }
        try turn(tokens: 1000)
        try turn(infra: true, tokens: 50_000)
        try turn(reset: true, tokens: 70_000)
        try f.change(i, "work")
        try await f.runChecks(i)
        try f.review(i, .approve)
        #expect(try await f.drive(i).status == .done)
        let fact = try f.fact(i)
        // The engine's own turns of the engineer in between report no usage.
        #expect(fact.tokensUsed == 1000, "infrastructure and session-reset turns are not counted")
        #expect(fact.costLE < 2)
        #expect(fact.turnsUsed == (try f.store.itemUsage(itemId: i.id)).turns)
    }

    @Test func containersHaveNoFacts() async throws {
        let f = try F()
        let story = try f.item("Story", type: .story)
        let task = try f.item("Child", parent: story)
        try f.claim(task)
        try f.change(task, "work")
        try await f.runChecks(task)
        try f.review(task, .approve)
        #expect(try await f.drive(task).status == .done)
        #expect(try f.fresh(story).status == .done, "the container rule")
        #expect(try f.store.itemFact(itemId: task.id) != nil)
        #expect(try f.store.itemFact(itemId: story.id) == nil)
    }

    @Test func auditVerdictRecorded() throws {
        let f = try F()
        let i = try f.item()
        try f.store.writer.write { db in
            try db.execute(sql: "UPDATE workItem SET status = 'done', autoApproved = 1, doneAt = ? WHERE id = ?", arguments: [f.now, i.id])
            let item = try #require(try WorkItem.fetchOne(db, key: i.id))
            try ReviewAudit(itemId: i.id, companyId: f.company.id, sampledActive: 0).insert(db)
            try OutcomeFactsObserver(catalog: .builtin).itemCompleted(item, db: db)
        }
        #expect(try f.fact(i).autoMerged); #expect(try f.fact(i).audited); #expect(try f.fact(i).auditVerdict == nil)
        try f.store.writer.write { db in try Store.recordAuditFact(db: db, itemId: i.id, verdict: "failed") }
        #expect(try f.fact(i).auditVerdict == "failed")
    }

    @Test func factsObserverIsFirst() throws {
        struct Other: WorkItemObserver { func itemCompleted(_ item: WorkItem, db: Database) throws {} }
        let store = try Store.inMemory(observers: [Other()])
        // Plan ML: the episode recorder is the second default observer.
        #expect(store.observers.count == 3); #expect(store.observers.first is OutcomeFactsObserver)
        #expect(store.observers[1] is EpisodeObserver); #expect(store.observers.last is Other)
    }

    // MARK: CLI

    private func brahma(_ args: [String], home: URL) throws -> (status: Int32, stdout: String, stderr: String) {
        let url = brahmaExecutableURL()
        try #require(FileManager.default.isExecutableFile(atPath: url.path), "build the brahma product first")
        let p = Process()
        p.executableURL = url
        p.arguments = args
        p.environment = cliEnvironment(home: home)
        let out = Pipe(), err = Pipe()
        p.standardOutput = out; p.standardError = err
        p.standardInput = FileHandle.nullDevice
        try p.run()
        let o = out.fileHandleForReading.readDataToEndOfFile(), r = err.fileHandleForReading.readDataToEndOfFile()
        p.waitUntilExit()
        return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: r, as: UTF8.self))
    }

    @Test func perfFactsCLI() throws {
        let owner = try OwnerTestHome(); defer { withExtendedLifetime(owner) {} }
        let home = owner.url
        #expect(try brahma(["company", "create", "Acme", "--goal", "g"], home: home).status == 0)
        let empty = try brahma(["perf", "facts", "Acme"], home: home)
        #expect(empty.status == 0, "\(empty.stderr)"); #expect(empty.stdout == "(no outcome facts yet)\n")
        #expect(try brahma(["items", "add", "Acme", "--title", "Parser", "--check", "true", "--ready"], home: home).status == 0)
        #expect(try brahma(["items", "add", "Acme", "--title", "Lexer", "--check", "true", "--ready"], home: home).status == 0)
        let store = try Store(path: ownerPaths(home).database.path)
        let company = try #require(try store.companies().first)
        let eng = try #require(try store.agents(companyId: company.id).first { $0.name == "eng-1" })
        try store.writer.write { db in
            for (n, item) in try WorkItem.filter(Column("companyId") == company.id).order(Column("number")).fetchAll(db).enumerated() {
                try db.execute(sql: "UPDATE workItem SET status = 'done', ownerId = ?, doneAt = ? WHERE id = ?",
                               arguments: [eng.id, Date(timeIntervalSince1970: Double(1000 + n)), item.id])
                var fresh = try #require(try WorkItem.fetchOne(db, key: item.id))
                fresh.title = "x\u{1B}[2J"
                var fact = try OutcomeFactsObserver.fact(db: db, item: fresh, now: Date(timeIntervalSince1970: Double(1000 + n)))
                fact.turnsUsed = 3 + n; fact.costLE = 1.25
                try fact.save(db)
            }
        }
        let out = try brahma(["perf", "facts", "Acme"], home: home)
        #expect(out.status == 0, "\(out.stderr)")
        let lines = out.stdout.split(separator: "\n").map(String.init)
        #expect(lines.count == 2)
        #expect(lines[0].hasPrefix("ACME-2  task  M  reworked  runs 0 (0 failed, 0 flaky, 0 inconclusive)"), "newest first: \(lines[0])")
        #expect(lines[0].contains("turns 4/15, tokens 0k/1000k, $1.25/$10.00 + review $0.00"))
        #expect(lines[0].contains("check by @owner (owner)")); #expect(lines[0].contains("owner @eng-1"))
        #expect(lines[1].hasPrefix("ACME-1  "))
        let one = try brahma(["perf", "facts", "Acme", "--limit", "1"], home: home)
        #expect(one.stdout.split(separator: "\n").count == 1)
        #expect(try brahma(["perf", "facts", "Acme", "--limit", "0"], home: home).status != 0)
        #expect(try brahma(["perf", "facts", "Nope"], home: home).status != 0)
    }
}
