import Foundation

extension Orchestrator {
    /// Wall-clock seconds between dispatch passes (the claim queries are cheap but run per idle agent).
    static let dispatchInterval: TimeInterval = 5
    /// Seconds between orphan-worktree sweeps of one company.
    static let sweepInterval: TimeInterval = 60
    /// After a failed worktree, the item is not offered again for this long.
    static let dispatchRetry: TimeInterval = 300

    func noteWorktreeFailure(itemId: String) -> Int {
        worktreeFailures[itemId, default: 0] += 1
        return worktreeFailures[itemId] ?? 0
    }

    func clearWorktreeFailures(itemId: String) { worktreeFailures[itemId] = nil }

    func gitTaskDone(_ key: String) { gitTasks[key] = nil }

    func dispatchDone(agentId: String, failedItem: String?, now: Date) {
        dispatching.remove(agentId)
        if let failedItem { dispatchBackoff[failedItem] = now.addingTimeInterval(Self.dispatchRetry) }
    }

    /// Runs `body` off the actor, tracked in `gitTasks` so `waitUntilIdle` and shutdown see it. One task per key.
    func spawnGit(_ key: String, _ body: @escaping @Sendable () async -> Void) {
        guard gitTasks[key] == nil else { return }
        gitTasks[key] = Task.detached { [self] in
            await body()
            await gitTaskDone(key)
        }
    }

    /// Once per tick, after the clock and health. Never waits on git.
    func leaseMaintenance(now: Date, companies: [Company], reaped: [WorkLease], held: Bool) {
        let byId = Dictionary(uniqueKeysWithValues: companies.map { ($0.id, $0) })
        // 1. Reaped leases lose their worktree (work auto-committed, branch kept).
        for lease in reaped {
            guard let company = byId[lease.companyId], let item = try? store.workItem(id: lease.itemId) else { continue }
            removeWorktreeLater(company: company, key: item.key)
        }
        guard !held else { return }
        // 2. Worktrees no lease row accounts for (a crash between a reap and its removal, an owner reassignment, ...).
        for company in companies where lastSweep[company.id].map({ now.timeIntervalSince($0) >= Self.sweepInterval }) ?? true {
            lastSweep[company.id] = now
            sweepLater(company: company)
        }
    }

    private func removeWorktreeLater(company: Company, key: String) {
        let (store, ws, companyId) = (self.store, URL(fileURLWithPath: company.workspacePath, isDirectory: true), company.id)
        let git = store.gitWorkspace(root: ws, companyId: companyId)
        spawnGit("wt:\(companyId):\(key)") { [self] in
            // Decided under the item's lock: a new claim may have taken the item since it was reaped, and a database
            // error is not "no lease" (nothing is removed then).
            do {
                try git.removeWorktree(key: key, keepIf: { try store.lease(companyId: companyId, key: key) != nil })
            } catch { log("could not remove worktree \(key): \(error)") }
        }
    }

    private func sweepLater(company: Company) {
        let (store, ws, companyId) = (self.store, URL(fileURLWithPath: company.workspacePath, isDirectory: true), company.id)
        guard FileManager.default.fileExists(atPath: ws.appending(path: ".git").path) else { return }
        spawnGit("sweep:\(companyId)") { [self] in
            let git = store.gitWorkspace(root: ws, companyId: companyId)
            let items: [(key: String, path: URL)]
            do { items = try git.itemWorktrees() } catch { log("worktree sweep failed: \(error)"); return }
            // Only registered `item/<KEY>` worktrees; engine checkouts (".preview", ".merge", ...) are never listed. One
            // item that cannot be decided (busy lock, unreadable lease) is skipped; the others are still swept.
            for (key, _) in items {
                do { try git.removeWorktree(key: key, keepIf: { try store.lease(companyId: companyId, key: key) != nil }) }
                catch { log("worktree sweep skipped \(key): \(error)") }
            }
        }
    }

    /// At most as many items as there are slots to run them: the free slots admission left over, less the agents whose
    /// worktree is still being made, and per company its own free concurrency. Idle agents do not pile up leases that expire
    /// unused.
    func dispatchTick(now: Date, companies: [Company], skipping reaped: Set<String>, freeSlots: Int, companyFree: [String: Int]) {
        var budget = freeSlots - dispatching.count
        guard budget > 0 else { return }
        if let last = lastDispatch, now.timeIntervalSince(last) < Self.dispatchInterval { return }
        guard let withReady = try? store.companiesWithReadyItems() else { return }
        dispatchBackoff = dispatchBackoff.filter { $0.value > now }
        var skipping = reaped
        skipping.formUnion(dispatchBackoff.keys)
        var ran = false
        for company in companies where company.status == .running && withReady.contains(company.id) {
            guard var companyBudget = companyFree[company.id], companyBudget > 0 else { continue }
            ran = true
            guard let agents = try? store.agents(companyId: company.id, states: [.ready, .sleeping]),
                  let leased = try? Set(store.leases(companyId: company.id).map(\.agentId)) else { continue }
            companyBudget -= agents.filter { dispatching.contains($0.id) }.count
            var dispatched = 0
            for agent in agents where dispatched < 25 && budget > 0 && companyBudget > 0 && !agent.paused && !leased.contains(agent.id)
                && !dispatching.contains(agent.id)
                && store.catalog.template(role: agent.role, pack: company.packId).kind == .individual {
                guard let claim = try? store.engineClaimNext(agentId: agent.id, skipping: skipping, now: now) else { continue }
                dispatched += 1
                budget -= 1
                companyBudget -= 1
                skipping.insert(claim.item.id)
                dispatching.insert(agent.id)
                startWorktree(company: company, agent: agent, item: claim.item, wasUnowned: claim.wasUnowned)
            }
        }
        if ran { lastDispatch = now }
    }

    /// Creates the worktree of a dispatched item, then wakes the agent. If git fails the lease is given back.
    private func startWorktree(company: Company, agent: Agent, item: WorkItem, wasUnowned: Bool) {
        let (store, ws, clock) = (self.store, URL(fileURLWithPath: company.workspacePath, isDirectory: true), self.clock)
        let git = store.gitWorkspace(root: ws, companyId: company.id)
        spawnGit("dispatch:\(agent.id)") { [self] in
            var failed: String?
            do {
                try git.ensureRepo()
                try git.addWorktree(key: item.key)
                try ProgressFile.ensure(workspace: ws, item: item)
            } catch {
                log("could not create the worktree of \(item.key): \(error)")
                _ = try? store.releaseLease(itemId: item.id, agentId: agent.id, note: "the worktree could not be created",
                                            undoOwner: wasUnowned, now: clock())
                failed = item.id
            }
            if failed == nil {
                _ = try? store.transition(agentId: agent.id, to: .ready, now: clock(), if: { $0.state == .sleeping && !$0.paused })
            }
            await dispatchDone(agentId: agent.id, failedItem: failed, now: clock())
        }
    }
}
