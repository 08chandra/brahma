import Testing
import Foundation
import GRDB
@testable import BrahmaCore

@Suite(.serialized) struct LeaseTests {
    /// A company with a real git workspace, one manager and three engineers, on the orchestrator's `World`.
    private struct L {
        let world: World
        var store: Store { world.store }
        let company: Company
        let mgr: Agent, eng: Agent, eng2: Agent, rev: Agent
        var now: Date { world.clock.now }
        var ws: GitWorkspace { GitWorkspace(root: URL(fileURLWithPath: company.workspacePath)) }

        init(store: Store? = nil, hardCap: Int = 16) throws {
            world = try World(store: store, config: World.config(hardCap: hardCap))
            company = try world.company("Acme")
            mgr = try world.hire(company, "mgr", role: "manager")
            eng = try world.hire(company, "eng-1", role: "engineer")
            eng2 = try world.hire(company, "eng-2", role: "engineer")
            rev = try world.hire(company, "rev", role: "engineer")
        }

        func active() -> Double { store.activeNow(companyId: company.id) }

        /// A ready task with an executable check; `paths` are its claimed paths.
        @discardableResult
        func item(_ title: String = "Do it", type: WorkItemType = .task, status: WorkItemStatus = .ready,
                  paths: [String]? = nil, touch: [String] = [], check: Bool = true, owner: Agent? = nil, reviewer: Agent? = nil,
                  team: String? = nil, priority: Int = 2) throws -> WorkItem {
            let n = (try store.workItems(companyId: company.id)).count + 1
            let spec = check ? CheckSpec(command: "true", paths: paths ?? ["src/p\(n)"]) : nil
            return try store.createWorkItem(companyId: company.id, by: .owner, draft: WorkItemDraft(
                type: type, title: title, checkSpec: spec, priority: priority, ownerId: owner?.id, reviewerId: reviewer?.id,
                team: team, status: status, touchPaths: touch), now: now)
        }

        func claim(_ i: WorkItem, _ a: Agent) throws -> WorkLease {
            try store.claimLease(itemId: i.id, agentId: a.id, now: now)
        }

        func tools(_ a: Agent) -> CompanyTools { CompanyTools(store: store, companyId: company.id, agentId: a.id) }
        func refusal(_ i: WorkItem, _ a: Agent) throws -> String {
            do { _ = try claim(i, a); return "claimed" } catch let e as WorkError { return e.message }
        }
        func allLeases() throws -> [WorkLease] { try store.writer.read { try WorkLease.fetchAll($0) } }
        func engineSet(_ i: WorkItem, _ status: WorkItemStatus) throws {
            try store.writer.write { db in _ = try store.engineSetStatus(db: db, itemId: i.id, to: status, now: now) }
        }
        func fresh(_ i: WorkItem) throws -> WorkItem { try #require(try store.workItem(id: i.id)) }
    }

    @Test func claimCreatesWorktreeAndSetsOwner() throws {
        let l = try L()
        let i = try l.item(paths: ["src/a"])
        let out = try l.tools(l.eng).call(name: "claim_lease", arguments: ["key": .string(i.key)])
        let wt = l.ws.worktreePath(key: i.key)
        let progress = ProgressFile.path(workspace: URL(fileURLWithPath: l.company.workspacePath), key: i.key)
        let pattern = "^You hold \(i.key) until \\d{2}:\\d{2}\\. Work only in your worktree: \(NSRegularExpression.escapedPattern(for: wt.path)) "
            + "\\(branch item/\(i.key)\\)\\. Progress file: \(NSRegularExpression.escapedPattern(for: progress.path))\\.$"
        #expect(out.range(of: pattern, options: .regularExpression) != nil, "\(out)")
        #expect(FileManager.default.fileExists(atPath: wt.appending(path: ".git").path))
        #expect(FileManager.default.fileExists(atPath: progress.path))
        let item = try l.fresh(i)
        #expect(item.ownerId == l.eng.id); #expect(item.status == .inProgress); #expect(item.everStarted)
        #expect(item.firstClaimedAt != nil); #expect(item.firstClaimedActive == l.active())
        let lease = try #require(try l.store.lease(itemId: i.id))
        #expect(lease.agentId == l.eng.id); #expect(lease.expiresActive == l.active() + WorkLease.ttl)
        #expect(try l.store.lease(agentId: l.eng.id)?.itemId == i.id)
        #expect(try l.store.itemEvents(itemId: i.id).map(\.kind).contains(.leaseClaimed))
        #expect(WorkLease.ttl == 7200)
        // A second claim by someone else does not touch the worktree and is refused.
        let (_, text) = try Self.failure { try l.tools(l.eng2).call(name: "claim_lease", arguments: ["key": .string(i.key)]) }
        #expect(text.contains("is leased by @eng-1 until"))
    }

    @Test func claimThatFailsInGitReleasesTheLease() throws {
        let l = try L()
        let i = try l.item(paths: ["src/a"])
        // A plain file where the worktree directory must go makes `git worktree add` fail.
        let wt = l.ws.worktreePath(key: i.key)
        try FileManager.default.createDirectory(at: wt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "in the way".write(to: wt, atomically: true, encoding: .utf8)
        let (_, text) = try Self.failure { try l.tools(l.eng).call(name: "claim_lease", arguments: ["key": .string(i.key)]) }
        #expect(!text.isEmpty)
        #expect(try l.store.lease(itemId: i.id) == nil)
        let item = try l.fresh(i)
        #expect(item.status == .ready); #expect(item.ownerId == nil)
        let kinds = try l.store.itemEvents(itemId: i.id).map(\.kind)
        #expect(kinds.contains(.leaseClaimed)); #expect(kinds.contains(.leaseReleased))
        // The file this call did not create is still there.
        #expect(try String(contentsOf: wt, encoding: .utf8) == "in the way")
    }

    @Test func claimRefusals() throws {
        let l = try L()
        let epic = try l.item("epic", type: .epic, status: .backlog, check: false)
        #expect(try l.refusal(epic, l.eng) == "\(epic.key) is a epic; claim one of its tasks")
        let backlog = try l.item("b", status: .backlog)
        #expect(try l.refusal(backlog, l.eng) == "\(backlog.key) is backlog")
        let dep1 = try l.item("d1", status: .backlog), dep2 = try l.item("d2", status: .backlog)
        let waits = try l.item("w")
        try l.store.addDependency(itemId: waits.id, dependsOn: dep2.id, by: .owner)
        try l.store.addDependency(itemId: waits.id, dependsOn: dep1.id, by: .owner)
        #expect(try l.refusal(waits, l.eng) == "\(waits.key) waits on \(dep1.key), \(dep2.key)")
        let nocheck = try l.item("n", check: false)
        #expect(try l.refusal(nocheck, l.eng) == "\(nocheck.key) has no executable check yet; ask its author or reviewer to add one")
        let leased = try l.item("l")
        let lease = try l.claim(leased, l.eng2)
        let until = l.store.formatTime(lease.expiresAt(activeNow: l.active(), now: l.now))
        #expect(try l.refusal(leased, l.mgr) == "\(leased.key) is leased by @eng-2 until \(until)")
        let assigned = try l.item("a", owner: l.rev)
        #expect(try l.refusal(assigned, l.eng) == "\(assigned.key) is assigned to @rev")
        let reviewing = try l.item("r", reviewer: l.eng)
        #expect(try l.refusal(reviewing, l.eng) == "you are this item's reviewer")
        // eng2 already holds `leased`.
        let other = try l.item("o")
        #expect(try l.refusal(other, l.eng2) == "you already hold \(leased.key); release it first")
        // And the holder cannot claim its own item twice either.
        #expect(try l.refusal(leased, l.eng2) == "you already hold \(leased.key); release it first")
        #expect(try l.refusal(other, l.eng) == "claimed")
    }

    @Test func claimIsCompanyScoped() throws {
        let l = try L()
        let other = try l.store.createCompany(name: "Beta", goal: "g", workspacesRoot: try tempDir())
        let theirs = try l.store.createWorkItem(companyId: other.id, by: .owner, draft: WorkItemDraft(
            type: .task, title: "t", checkSpec: CheckSpec(command: "true", paths: ["x"]), status: .ready), now: l.now)
        #expect(throws: WorkError.forbidden("not in your company")) { try l.claim(theirs, l.eng) }
        #expect(throws: WorkError.forbidden("not in your company")) {
            try l.store.releaseLease(itemId: theirs.id, agentId: l.eng.id, note: nil, now: l.now)
        }
    }

    @Test func spikeNeedsNoCheck() throws {
        let l = try L()
        let spike = try l.item("investigate", type: .spike, touch: ["research"], check: false)
        _ = try l.claim(spike, l.eng)
        #expect(try l.fresh(spike).status == .inProgress)
    }

    @Test func singleWriterUnderConcurrentClaims() throws {
        let dir = try tempDir()
        let store = try Store(path: dir.appending(path: "t.sqlite").path)
        let l = try L(store: store)
        let extra = try (0..<6).map { try l.world.hire(l.company, "w-\($0)", role: "engineer") }
        let agents = [l.eng, l.eng2, l.rev] + extra
        let i = try l.item(paths: ["src/one"])
        let results = ResultBox()
        let (itemId, ids, now) = (i.id, agents.map(\.id), l.now)
        DispatchQueue.concurrentPerform(iterations: ids.count) { n in
            do { _ = try store.claimLease(itemId: itemId, agentId: ids[n], now: now); results.add(true) }
            catch { results.add(false) }
        }
        #expect(results.all.filter { $0 }.count == 1); #expect(results.all.count == agents.count)
        #expect(try store.writer.read { try WorkLease.fetchCount($0) } == 1)
        let holder = try #require(try store.lease(itemId: i.id)).agentId
        #expect(try l.fresh(i).ownerId == holder)
    }

    @Test func expiredLeaseAllowsNewClaim() throws {
        let l = try L()
        let i = try l.item()
        _ = try l.claim(i, l.eng)
        try l.store.advanceActive(companyId: l.company.id, by: 7201)
        // Without a tick: the new claim reaps the expired lease inline.
        #expect(try l.refusal(i, l.eng2) == "\(i.key) is assigned to @eng-1")
        #expect(try l.store.lease(itemId: i.id) == nil)
        #expect(try l.fresh(i).status == .ready); #expect(try l.fresh(i).ownerId == l.eng.id)
        #expect(try l.store.itemEvents(itemId: i.id).map(\.kind).contains(.leaseExpired))
        // A manager unassigns it; now anyone may take it.
        try l.store.updateWorkItem(id: i.id, by: .agent(l.mgr.id), patch: WorkItemPatch(ownerId: .some(nil)), now: l.now)
        #expect(try l.refusal(i, l.eng2) == "claimed")
        #expect(try l.fresh(i).ownerId == l.eng2.id)
    }

    @Test func reapReturnsExpiredLeasesAndTellsTheManager() throws {
        let l = try L()
        let report = try l.store.hire(companyId: l.company.id, name: "report", role: "engineer", model: "sonnet", managerId: l.mgr.id)
        let i = try l.item()
        _ = try l.claim(i, report)
        #expect(try l.store.reapLeases(now: l.now).isEmpty)
        try l.store.advanceActive(companyId: l.company.id, by: 7201)
        let reaped = try l.store.reapLeases(now: l.now)
        #expect(reaped.map(\.itemId) == [i.id])
        #expect(try l.fresh(i).status == .ready); #expect(try l.fresh(i).ownerId == report.id)
        #expect(try l.store.lease(itemId: i.id) == nil)
        let notices = try l.store.pendingNotices(agentId: l.mgr.id)
        #expect(notices.contains { $0.event.kind == .leaseExpired && $0.itemKey == i.key })
        #expect(try l.store.reapLeases(now: l.now).isEmpty)
    }

    @Test func pausedCompanyLeaseDoesNotExpire() throws {
        let l = try L()
        let i = try l.item()
        _ = try l.claim(i, l.eng)
        try l.store.accrueActiveTime(now: l.now)
        var c = try #require(try l.store.company(id: l.company.id)); c.status = .paused; try l.store.updateCompany(c)
        let later = l.now.addingTimeInterval(10 * 3600)
        let before = l.active()
        try l.store.accrueActiveTime(now: later)
        #expect(l.active() == before)
        #expect(try l.store.reapLeases(now: later).isEmpty)
        #expect(try l.store.lease(itemId: i.id) != nil)
    }

    @Test func reapAutoCommitsWorktree() async throws {
        let l = try L()
        let i = try l.item()
        _ = try l.tools(l.eng).call(name: "claim_lease", arguments: ["key": .string(i.key)])
        let wt = l.ws.worktreePath(key: i.key)
        try "work in progress".write(to: wt.appending(path: "wip.txt"), atomically: true, encoding: .utf8)
        try l.store.advanceActive(companyId: l.company.id, by: 7201)
        try await l.world.cycle()
        #expect(try l.store.lease(itemId: i.id) == nil)
        #expect(try l.fresh(i).status == .ready)
        #expect(!FileManager.default.fileExists(atPath: wt.path))
        let tip = try #require(try l.ws.head(of: l.ws.branch(key: i.key)))
        #expect(try GitFixture.plainGit(["log", "-1", "--format=%s", tip], in: l.ws.root) == "\(i.key): auto-commit before release")
        #expect(try GitFixture.plainGit(["show", "\(tip):wip.txt"], in: l.ws.root) == "work in progress")
    }

    @Test func inReviewLeaseNeverExpires() throws {
        let l = try L()
        let i = try l.item()
        _ = try l.claim(i, l.eng)
        try l.engineSet(i, .inReview)
        try l.store.advanceActive(companyId: l.company.id, by: 100_000)
        #expect(try l.store.reapLeases(now: l.now).isEmpty)
        #expect(try l.store.lease(itemId: i.id) != nil); #expect(try l.fresh(i).status == .inReview)
    }

    @Test func killReapsLeases() async throws {
        let l = try L()
        let held = try l.item("held"), owned = try l.item("owned", status: .backlog, owner: l.eng), done = try l.item("done", owner: l.eng)
        try l.engineSet(done, .done)
        _ = try l.tools(l.eng).call(name: "claim_lease", arguments: ["key": .string(held.key)])
        let wt = l.ws.worktreePath(key: held.key)
        try "unsaved".write(to: wt.appending(path: "u.txt"), atomically: true, encoding: .utf8)
        try l.store.transition(agentId: l.eng.id, to: .killed, now: l.now)
        // In the same transaction as the kill: the lease is marked expired, ownership is cleared on undone items.
        let lease = try #require(try l.store.lease(itemId: held.id))
        #expect(lease.expiresActive == -1)
        #expect(try l.fresh(held).ownerId == nil); #expect(try l.fresh(owned).ownerId == nil)
        #expect(try l.fresh(done).ownerId == l.eng.id)
        let events = try l.store.itemEvents(itemId: owned.id)
        #expect(events.contains { $0.kind == .assigned && $0.text == "unassigned: @eng-1 was killed" })
        // The next tick reaps it, removes the row and the worktree, and keeps the work on the branch.
        try await l.world.cycle()
        #expect(try l.store.lease(itemId: held.id) == nil); #expect(try l.fresh(held).status == .ready)
        #expect(!FileManager.default.fileExists(atPath: wt.path))
        let tip = try #require(try l.ws.head(of: l.ws.branch(key: held.key)))
        #expect(try GitFixture.plainGit(["show", "\(tip):u.txt"], in: l.ws.root) == "unsaved")
        // A second agent can take the item over.
        #expect(try l.refusal(held, l.eng2) == "claimed")
    }

    @Test func turnRenewsLease() async throws {
        let l = try L()
        let i = try l.item()
        _ = try l.claim(i, l.eng)
        try l.store.advanceActive(companyId: l.company.id, by: 3000)
        try l.world.dm(l.company, l.eng)
        try await l.world.cycle()
        let lease = try #require(try l.store.lease(itemId: i.id))
        #expect(lease.expiresActive == l.active() + WorkLease.ttl)
        #expect(lease.expiresActive >= 3000 + WorkLease.ttl)
        // A failed turn does not renew.
        l.world.fake.script("eng-1", .init(events: [], error: FakeError(description: "boom")))
        try l.store.advanceActive(companyId: l.company.id, by: 1000)
        let before = lease.expiresActive
        try l.world.dm(l.company, l.eng)
        try await l.world.cycle()
        #expect(try l.store.lease(itemId: i.id)?.expiresActive == before)
    }

    @Test func leaseTurnRunsInWorktree() async throws {
        let l = try L()
        let i = try l.item()
        _ = try l.tools(l.eng).call(name: "claim_lease", arguments: ["key": .string(i.key)])
        try l.world.dm(l.company, l.eng)
        try await l.world.cycle()
        let request = try #require(l.world.fake.requests.last)
        let wt = l.ws.worktreePath(key: i.key).path
        #expect(request.workingDirectory == wt)
        #expect(request.addDirs == [wt, l.company.workspacePath + "/.brahma"])
        // A teammate without a lease stays in the company workspace.
        try l.world.dm(l.company, l.eng2)
        try await l.world.cycle()
        // (eng-1 still holds its item and keeps working, so pick eng-2's request.)
        let plain = try #require(l.world.fake.requests.last { $0.agent.name == "eng-2" })
        #expect(plain.workingDirectory == l.company.workspacePath); #expect(plain.addDirs.isEmpty)
    }

    @Test func staleHolderCannotUpdateStatus() throws {
        let l = try L()
        let i = try l.item()
        _ = try l.claim(i, l.eng)
        // While it holds the lease the holder may block the item.
        try l.store.updateWorkItem(id: i.id, by: .agent(l.eng.id), patch: WorkItemPatch(status: .blocked, blockedReason: "waiting"), now: l.now)
        try l.store.updateWorkItem(id: i.id, by: .agent(l.eng.id), patch: WorkItemPatch(status: .inProgress), now: l.now)
        // The lease expires and a manager gives the item to someone else.
        try l.store.advanceActive(companyId: l.company.id, by: 7201)
        _ = try l.store.reapLeases(now: l.now)
        try l.store.updateWorkItem(id: i.id, by: .agent(l.mgr.id), patch: WorkItemPatch(ownerId: .some(l.eng2.id)), now: l.now)
        #expect(throws: WorkError.self) {
            try l.store.updateWorkItem(id: i.id, by: .agent(l.eng.id), patch: WorkItemPatch(status: .blocked, blockedReason: "x"), now: l.now)
        }
        #expect(try l.fresh(i).status == .ready)
        #expect(throws: WorkError.self) {
            try l.store.updateWorkItem(id: i.id, by: .agent(l.eng.id), patch: WorkItemPatch(notes: .some("mine")), now: l.now)
        }
    }

    @Test func releaseLeaseReturnsItemToReady() throws {
        let l = try L()
        let i = try l.item()
        _ = try l.claim(i, l.eng)
        #expect(throws: WorkError.self) { try l.store.releaseLease(itemId: i.id, agentId: l.eng2.id, note: nil, now: l.now) }
        try l.store.releaseLease(itemId: i.id, agentId: l.eng.id, note: "switching to something urgent", now: l.now)
        #expect(try l.store.lease(itemId: i.id) == nil); #expect(try l.fresh(i).status == .ready)
        let released = try #require(try l.store.itemEvents(itemId: i.id).last { $0.kind == .leaseReleased })
        #expect(released.text.contains("switching to something urgent"))
        #expect(throws: WorkError.self) { try l.store.releaseLease(itemId: i.id, agentId: l.eng.id, note: nil, now: l.now) }
    }

    @Test func releaseNoteIsRedactedRawFirst() throws {
        let l = try L()
        let s = "lease-secret\nsecond-line-7"
        let vault = MemoryVault().with(l.company.id, "LEASE_KEY", s)
        try l.store.setSecret(companyId: l.company.id, name: "LEASE_KEY", value: s, isTest: false, vault: vault)
        _ = try l.store.reloadRedactorIfNeeded(vault: vault)
        let i = try l.item()
        _ = try l.claim(i, l.eng)
        try l.store.releaseLease(itemId: i.id, agentId: l.eng.id, note: "pasted \(s) by mistake", now: l.now)
        let released = try #require(try l.store.itemEvents(itemId: i.id).last { $0.kind == .leaseReleased })
        #expect(released.text.contains("[redacted LEASE_KEY]"), "\(released.text)")
        #expect(!(try dumpDatabase(l.store)).contains("second-line-7"))
    }

    // MARK: Merge safety

    @Test func overlappingItemsCannotBothBeInProgress() throws {
        let l = try L()
        let a = try l.item("a", paths: ["src"]), b = try l.item("b", paths: ["src/x/y.swift"])
        let c = try l.item("c", type: .spike, touch: ["src/*.swift"], check: false)
        _ = try l.claim(a, l.eng)
        #expect(try l.refusal(b, l.eng2) == "\(b.key) overlaps \(a.key) (src); wait until it merges")
        #expect(try l.refusal(c, l.eng2) == "\(c.key) overlaps \(a.key) (src); wait until it merges")
        try l.store.releaseLease(itemId: a.id, agentId: l.eng.id, note: nil, now: l.now)
        #expect(try l.refusal(b, l.eng2) == "claimed")
        // inReview still counts as in flight.
        try l.engineSet(b, .inReview)
        #expect(try l.refusal(c, l.eng) == "\(c.key) overlaps \(b.key) (src/x/y.swift); wait until it merges")
    }

    @Test func itemsWithoutPathsClaimTheWholeRepo() throws {
        let l = try L()
        let spike = try l.item("whole", type: .spike, check: false)
        let narrow = try l.item("narrow", paths: ["docs"])
        _ = try l.claim(spike, l.eng)
        #expect(try l.refusal(narrow, l.eng2) == "\(narrow.key) overlaps \(spike.key) (.); wait until it merges")
    }

    @Test func disjointItemsRunInParallel() throws {
        let l = try L()
        let a = try l.item("a", paths: ["src/a"]), b = try l.item("b", paths: ["src/b"]), c = try l.item("c", paths: ["docs"], touch: ["README.md"])
        #expect(try l.refusal(a, l.eng) == "claimed")
        #expect(try l.refusal(b, l.eng2) == "claimed")
        #expect(try l.refusal(c, l.rev) == "claimed")
    }

    @Test func hotPathItemsSerialize() throws {
        let l = try L()
        let a = try l.item("a", paths: ["Package.swift"]), b = try l.item("b", paths: ["package.json"]), c = try l.item("c", paths: ["src/plain"])
        let routes = try l.item("r", paths: ["app/routes.rb"])
        _ = try l.claim(a, l.eng)
        #expect(try l.refusal(b, l.eng2) == "\(b.key) touches a hot path (package.json) and \(a.key) already does (Package.swift); wait until it merges")
        #expect(try l.refusal(routes, l.eng2).hasPrefix("\(routes.key) touches a hot path (app/routes.rb)"))
        #expect(try l.refusal(c, l.eng2) == "claimed")
        // The owner's setting decides what is hot.
        #expect(l.store.hotPaths() == WorkPolicy.defaultHotPaths)
        try l.store.setHotPaths(["only/this/**"])
        #expect(l.store.hotPaths() == ["only/this/**"])
        #expect(try l.refusal(b, l.rev) == "claimed")
        try l.store.setHotPaths(nil)
        #expect(l.store.hotPaths() == WorkPolicy.defaultHotPaths)
    }

    @Test func pathOverlapRules() {
        #expect(PathOverlap.overlaps(["."], ["anything/at/all"]))
        #expect(PathOverlap.overlaps(["src"], ["src/a/b.swift"]))
        #expect(PathOverlap.overlaps(["src/a/b.swift"], ["./src/"]))
        #expect(!PathOverlap.overlaps(["src/a"], ["src/ab"]))
        #expect(!PathOverlap.overlaps(["src/a"], ["Tests"]))
        #expect(PathOverlap.overlaps(["src/**/*.swift"], ["src/deep"]))
        #expect(!PathOverlap.overlaps(["Tests/**"], ["Sources/**"]))
        #expect(PathOverlap.overlaps(["*.md"], ["docs/guide.md"]))
        #expect(PathOverlap.overlaps([], ["x"]))   // nothing declared = the whole repo
        #expect(PathOverlap.firstOverlap(["a", "b"], ["c", "b/x"]) == "b/x")
        #expect(PathOverlap.normalized("./a//b/") == "a/b")
    }

    @Test func touchPathsAreValidatedAndEditable() throws {
        let l = try L()
        #expect(throws: WorkError.self) { try l.item(touch: ["/abs"]) }
        #expect(throws: WorkError.self) { try l.item(touch: ["../up"]) }
        let i = try l.item(touch: ["docs", "src/**"])
        #expect(try l.fresh(i).touchPaths == ["docs", "src/**"])
        try l.store.updateWorkItem(id: i.id, by: .agent(l.mgr.id), patch: WorkItemPatch(touchPaths: ["only"]), now: l.now)
        #expect(try l.fresh(i).touchPaths == ["only"])
        // A spec field: the assignee cannot change it.
        _ = try l.claim(i, l.eng)
        #expect(throws: WorkError.self) {
            try l.store.updateWorkItem(id: i.id, by: .agent(l.eng.id), patch: WorkItemPatch(touchPaths: []), now: l.now)
        }
    }

    // MARK: Engine dispatch

    @Test func engineDispatchesReadyItemToIdleIC() async throws {
        let l = try L()
        let a = try l.item("urgent", priority: 0), b = try l.item("later", priority: 3)
        try await l.world.cycle()
        // One item per idle IC: eng-1, eng-2 and rev are all idle, so the three... only two items exist.
        let leases = try l.allLeases()
        #expect(Set(leases.map(\.itemId)) == [a.id, b.id])
        let urgent = try #require(try l.store.lease(itemId: a.id))
        #expect(try l.fresh(a).status == .inProgress); #expect(try l.fresh(a).ownerId == urgent.agentId)
        #expect(FileManager.default.fileExists(atPath: l.ws.worktreePath(key: a.key).path))
        let claimed = try #require(try l.store.itemEvents(itemId: a.id).first { $0.kind == .leaseClaimed })
        #expect(claimed.text == "assigned by the engine"); #expect(claimed.actorId == "system")
        // The manager never gets an item, and the agent runs its next turn inside the worktree.
        #expect(try l.store.lease(agentId: l.mgr.id) == nil)
        try await l.world.cycle()
        let request = try #require(l.world.fake.requests.first { $0.agent.id == urgent.agentId })
        #expect(request.workingDirectory == l.ws.worktreePath(key: a.key).path)
    }

    @Test func dispatchRespectsTeamAndDependencies() async throws {
        let l = try L()
        let web = try l.store.hire(companyId: l.company.id, name: "web-1", role: "engineer", model: "sonnet", managerId: nil, team: "web")
        let opsOnly = try l.item("ops only", team: "ops")
        let backlogDep = try l.item("dep", status: .backlog)
        let waiting = try l.item("waiting")
        try l.store.addDependency(itemId: waiting.id, dependsOn: backlogDep.id, by: .owner)
        let reviewing = try l.item("review mine", reviewer: web)
        let nocheck = try l.item("unchecked", touch: ["z"], check: false)
        let mine = try l.item("web item", owner: web, team: "web")
        try await l.world.cycle()
        #expect(try l.store.lease(agentId: web.id)?.itemId == mine.id)
        // eng-1, eng-2 and rev are on no team: they only take items with no team and nothing in the way.
        let leased = try l.allLeases().map(\.itemId)
        #expect(!leased.contains(waiting.id)); #expect(!leased.contains(nocheck.id)); #expect(!leased.contains(opsOnly.id))
        #expect(try l.store.lease(agentId: l.mgr.id) == nil)
        // The agents on no team take the unteamed item that web-1 reviews.
        #expect(leased.contains(reviewing.id))
        // The item whose reviewer is web-1 is never given to web-1.
        #expect(try l.store.lease(itemId: reviewing.id)?.agentId != web.id)
    }

    @Test func dispatchSkipsOverlappingItem() async throws {
        let l = try L()
        // Only eng-2 is idle: the others are busy or paused.
        try l.store.setPaused(agentId: l.rev.id, true); try l.store.setPaused(agentId: l.eng.id, true)
        let busy = try l.item("busy", paths: ["src"])
        _ = try l.claim(busy, l.mgr)
        let clash = try l.item("clash", paths: ["src/deep"], priority: 0)
        let free = try l.item("free", paths: ["docs"], priority: 3)
        try await l.world.cycle()
        #expect(try l.store.lease(itemId: clash.id) == nil)
        #expect(try l.store.lease(agentId: l.eng2.id)?.itemId == free.id)
    }

    @Test func dispatchWaitsWhileHeldOrPaused() async throws {
        let l = try L()
        _ = try l.item("work")
        _ = try l.store.setHold(reason: .disk, detail: "test", now: l.now)
        try await l.world.cycle()
        #expect(try l.allLeases().isEmpty)
        try l.store.clearHold(now: l.now)
        var c = try #require(try l.store.company(id: l.company.id)); c.status = .paused; try l.store.updateCompany(c)
        try await l.world.cycle()
        #expect(try l.allLeases().isEmpty)
    }

    @Test func sweepIgnoresEngineCheckouts() async throws {
        let l = try L()
        let root = l.ws.root
        // A registered worktree for an item with no lease row, with unsaved work.
        let orphan = try l.ws.addWorktree(key: "ACME-9")
        try "keep me".write(to: orphan.appending(path: "o.txt"), atomically: true, encoding: .utf8)
        // Engine checkouts of later plans, a registered non-item worktree and a stray directory.
        let wtDir = root.appending(path: ".brahma/wt")
        let preview = wtDir.appending(path: ".preview"), merge = wtDir.appending(path: ".merge"), feature = wtDir.appending(path: "feature")
        try GitFixture.plainGit(["worktree", "add", "--detach", preview.path], in: root)
        try GitFixture.plainGit(["worktree", "add", "-b", "feature/x", feature.path], in: root)
        try "scratch".write(to: preview.appending(path: "p.txt"), atomically: true, encoding: .utf8)
        try FileManager.default.createDirectory(at: merge, withIntermediateDirectories: true)
        try await l.world.cycle()
        #expect(!FileManager.default.fileExists(atPath: orphan.path))
        let tip = try #require(try l.ws.head(of: "item/ACME-9"))
        #expect(try GitFixture.plainGit(["show", "\(tip):o.txt"], in: root) == "keep me")
        #expect(FileManager.default.fileExists(atPath: preview.appending(path: "p.txt").path))
        #expect(FileManager.default.fileExists(atPath: feature.path)); #expect(FileManager.default.fileExists(atPath: merge.path))
    }

    @Test func blockingCountsCoverOwnedAndLeasedItems() throws {
        let l = try L()
        let x = try l.item("x", owner: l.eng), y = try l.item("y", paths: ["y"])
        let d1 = try l.item("d1", status: .backlog), d2 = try l.item("d2", status: .backlog), d3 = try l.item("d3", status: .backlog)
        try l.store.addDependency(itemId: d1.id, dependsOn: x.id, by: .owner)
        try l.store.addDependency(itemId: d2.id, dependsOn: x.id, by: .owner)
        try l.store.addDependency(itemId: d3.id, dependsOn: y.id, by: .owner)
        _ = try l.claim(y, l.eng2)
        let counts = try l.store.blockingCounts()
        #expect(counts[l.eng.id] == 2); #expect(counts[l.eng2.id] == 1); #expect(counts[l.mgr.id] == nil)
        try l.engineSet(d1, .done)
        #expect(try l.store.blockingCounts()[l.eng.id] == 1)
        // A dependent the holder wrote and linked itself does not raise its own importance.
        let own = try l.store.createWorkItem(companyId: l.company.id, by: .agent(l.eng2.id), draft: WorkItemDraft(type: .task, title: "mine"), now: l.now)
        try l.store.addDependency(itemId: own.id, dependsOn: y.id, by: .agent(l.eng2.id))
        #expect(try l.store.blockingCounts()[l.eng2.id] == 1)
    }

    @Test func dispatchBoundedByFreeSlots() async throws {
        let l = try L(hardCap: 2)
        // Holders who say they are stuck sleep (a holder who does not keeps its slot and works on).
        l.world.fake.defaultScript = .init(text: "stuck\nSTATUS: BLOCKED")
        for n in 0..<4 { _ = try l.world.hire(l.company, "extra-\(n)", role: "engineer") }   // 7 idle engineers
        for n in 0..<7 { try l.item("item \(n)", paths: ["src/d\(n)"]) }
        try await l.world.cycle()
        #expect(try l.allLeases().count == 2)
        // The two are ready to run and hold the slots: a later pass leases nothing more until they have gone.
        l.world.clock.advance(10)
        await l.world.orchestrator.tick()
        #expect(try l.allLeases().count == 2)
        try await l.world.orchestrator.waitUntilIdle(timeout: .seconds(60))
        // Their turns are over (the agents sleep, holding their leases); the next pass hands out two more.
        l.world.clock.advance(10)
        try await l.world.cycle()
        #expect(try l.allLeases().count == 4)
    }

    @Test func leaseTurnNeverRunsOutsideItsWorktree() async throws {
        let l = try L()
        let i = try l.item()
        _ = try l.claim(i, l.eng)
        // No worktree exists and a file in its place stops git from making one.
        let wt = l.ws.worktreePath(key: i.key)
        try FileManager.default.createDirectory(at: wt.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "in the way".write(to: wt, atomically: true, encoding: .utf8)
        try l.world.dm(l.company, l.eng)
        for attempt in 1...3 {
            try await l.world.cycle()
            #expect(l.world.fake.requests.filter { $0.agent.id == l.eng.id }.isEmpty)
            #expect(try l.world.turns(l.eng).count == attempt)
            #expect(try l.world.turns(l.eng).last?.outcome == .interrupted)
            // Not a failure of the agent: ready again, no backoff.
            let agent = try l.world.agent(l.eng)
            #expect(agent.state == .ready); #expect(agent.consecutiveFailures == 0)
            let errors = try l.store.events(afterId: 0).filter { $0.kind == .error && $0.text.contains("turn not started") }
            if attempt < 3 {
                // Tried again after the short delay, with the lease kept and no event yet.
                #expect(try l.store.lease(itemId: i.id) != nil); #expect(errors.isEmpty)
                l.world.clock.advance(EngineHealth.infraCooldown + 1)
            } else {
                // After three tries in a row the lease is given back, with one error event.
                #expect(try l.store.lease(itemId: i.id) == nil); #expect(try l.fresh(i).status == .ready)
                #expect(errors.count == 1); #expect(errors[0].text.contains(i.key)); #expect(errors[0].text.contains("lease released"))
            }
        }
    }

    @Test func dispatchIgnoresLeaseholdersAdmissionWouldRefuse() async throws {
        let l = try L(hardCap: 1)
        // Acme's leaseholder is ready but its company is paused, so admission will never run it...
        let held = try l.item("held")
        _ = try l.claim(held, l.eng)
        try l.store.transition(agentId: l.eng.id, to: .ready)
        var acme = try #require(try l.store.company(id: l.company.id)); acme.status = .paused; try l.store.updateCompany(acme)
        // ...and must not take the only slot from Beta.
        let beta = try l.world.company("Beta")
        let beng = try l.world.hire(beta, "beng", role: "engineer")
        let work = try l.store.createWorkItem(companyId: beta.id, by: .owner, draft: WorkItemDraft(
            type: .task, title: "beta work", checkSpec: CheckSpec(command: "true", paths: ["src/beta"]), status: .ready), now: l.now)
        try await l.world.cycle()
        #expect(try l.store.lease(itemId: work.id)?.agentId == beng.id)
        #expect(try l.store.lease(itemId: held.id)?.agentId == l.eng.id)
    }

    @Test func dispatchHoldsBackForCompaniesAtTheirOwnCap() async throws {
        let l = try L()
        // Low mode on a max20x plan allows two concurrent turns per company; two are already running.
        _ = try l.world.hire(l.company, "spare", role: "engineer")
        for n in 0..<3 { try l.item("w\(n)") }
        let gate = Gate()
        l.world.fake.defaultScript = .init(gate: gate)
        try l.world.dm(l.company, l.rev); try l.world.dm(l.company, l.mgr)
        await l.world.orchestrator.tick()
        #expect(await l.world.orchestrator.runningCount() == 2)
        l.world.clock.advance(10)
        await l.world.orchestrator.tick()
        gate.open()
        try await l.world.orchestrator.waitUntilIdle(timeout: .seconds(60))
        #expect(try l.allLeases().isEmpty)
    }

    @Test func sweepSkipsOnlyTheBusyItem() async throws {
        let l = try L()
        l.store.gitLockTimeout.seconds = 0   // one non-blocking attempt: "busy" is immediate
        _ = try l.ws.addWorktree(key: "ACME-8")
        _ = try l.ws.addWorktree(key: "ACME-9")
        let git = l.store.gitWorkspace(root: l.ws.root, companyId: l.company.id)
        try FileManager.default.createDirectory(at: git.lockDirectory, withIntermediateDirectories: true)
        let fd = open(git.lockDirectory.appending(path: "ACME-8.lock").path, O_CREAT | O_RDWR, 0o600)
        #expect(flock(fd, LOCK_EX) == 0)
        defer { close(fd) }
        await l.world.orchestrator.sweepNow(company: l.company)
        #expect(FileManager.default.fileExists(atPath: l.ws.worktreePath(key: "ACME-8").path))
        #expect(!FileManager.default.fileExists(atPath: l.ws.worktreePath(key: "ACME-9").path))
    }

    @Test func hotPathListCapMatchesValidation() throws {
        let l = try L()
        try l.store.setHotPaths((0..<100).map { "dir\($0)/**" })
        #expect(l.store.hotPaths().count == 100)
        do { try l.store.setHotPaths((0..<101).map { "dir\($0)/**" }); Issue.record("expected a refusal") }
        catch SettingsError.invalid(let why) { #expect(why.contains("hot-path list")); #expect(why.contains("100")) }
        #expect(throws: WorkError.self) { try l.item(touch: (0..<51).map { "p\($0)" }) }
    }

    @Test func repoConfigFilterRefusesClaimsWithOneAlert() throws {
        let l = try L()
        let root = URL(fileURLWithPath: l.company.workspacePath)
        let marker = try tempDir().appending(path: "clean-ran")
        try GitFixture.plainGit(["config", "filter.evil.clean", "touch '\(marker.path)'; cat"], in: root)
        let i = try l.item(paths: ["src/a"])
        for _ in 0..<3 {
            let (failed, _) = try Self.failure { try l.tools(l.eng).call(name: "claim_lease", arguments: ["key": .string(i.key)]) }
            #expect(failed)
        }
        #expect(try l.store.lease(itemId: i.id) == nil)
        #expect(!FileManager.default.fileExists(atPath: l.ws.worktreePath(key: i.key).path))
        #expect(!FileManager.default.fileExists(atPath: marker.path))
        let alerts = try l.store.asks(companyId: l.company.id).filter { $0.kind == .engineAlert && $0.summary.contains("filter.evil.clean") }
        #expect(alerts.count == 1)
        let dms = try l.store.writer.read { db in
            try Message.filter(Column("senderId") == "system").fetchAll(db).filter { $0.text.contains("filter.evil.clean") }
        }
        #expect(dms.count == 1, "one owner alert, not one per refused call")
        #expect(try l.store.asks(companyId: l.company.id).filter { $0.kind == .engineAlert }.count == 1, "and not a main-changed alert too")
        // With the definition removed the claim goes through.
        try GitFixture.plainGit(["config", "--remove-section", "filter.evil"], in: root)
        let (failed, _) = try Self.failure { try l.tools(l.eng).call(name: "claim_lease", arguments: ["key": .string(i.key)]) }
        #expect(!failed)
    }

    static func failure(_ body: () throws -> String) throws -> (Bool, String) {
        do { _ = try body(); return (false, "") } catch let e as ToolError { return (true, e.message) }
    }
}

final class ResultBox: @unchecked Sendable {
    private let lock = NSLock(); private var items: [Bool] = []
    func add(_ b: Bool) { lock.lock(); items.append(b); lock.unlock() }
    var all: [Bool] { lock.lock(); defer { lock.unlock() }; return items }
}
