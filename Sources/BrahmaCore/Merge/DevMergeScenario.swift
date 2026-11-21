import Foundation

/// `brahma dev merge-scenario <company>` (Plan 4a Task 10; BRAHMA_DEV=1 only): populates a demo company's merge queue through
/// the real tools and the real queue, so the Merge queue panel and an item's MERGE section have something to show:
/// 1. two items, each claimed by its own agent through `claim_lease`, worked in the worktree the lease gave it, handed in
///    through `submit_for_review`, checked by the engine's own check path (`Orchestrator.performCheck`: the exact commit in a
///    clean checkout under the sandboxed check runner) and approved by its reviewer through the `review` tool from a review
///    turn, which queues the merge request (`M-1`, `M-2`);
/// 2. the queue's batches (`MergeQueue.runNextBatch`, the engine's own queue with its sandboxed runner): the first item is
///    rebased, re-checked (the item's pinned check and the company's main check) and lands on `main`; the second was written on
///    the old `main` and changes the same file, so its rebase conflicts and it is bounced back to its holder.
/// The first item is `itemKey` when given (it must be `ready` with a check), else one the scenario creates; the second is always
/// created here. `file` is what the first item's work writes; the second writes it too, with other content, besides its own.
/// Nothing here writes a merge request, run or batch, or moves `main`: the tools, the check path and the queue do, as in the
/// engine. The scenario holds the engine lock (`OrchestratorLock`) throughout: it refuses while an engine runs on the data home.
public enum DevMergeScenario {
    public static let refusal = "the dev merge scenario needs BRAHMA_DEV=1"
    public static let defaultFile = "streaks.txt"
    /// How many batches the queue is asked for before the scenario gives up (two requests; a re-queue or two is tolerated).
    static let maxBatches = 6
    /// How long the scenario gives the engine's check path for one submission.
    static let checkWait: Duration = .seconds(180)

    public struct Summary: Sendable {
        public var merged: MergeRequest
        public var bounced: MergeRequest
        public var mergedItem: WorkItem
        public var bouncedItem: WorkItem
        public var mainCommit: String?
    }

    /// Runs the scenario for `companyId`. Throws `WorkError` with what is missing or what did not go as planned. `environment` is
    /// the caller's: `BRAHMA_DEV` must be `"1"` and `BRAHMA_AGENT_ID` unset; checks get an environment built from it without
    /// `BRAHMA_DEV` (`ChildEnvironment` never passes it on).
    public static func run(store: Store, paths: BrahmaPaths, companyId: String, vault: any SecretVault, itemKey: String? = nil,
                           file: String = defaultFile, environment: [String: String] = ProcessInfo.processInfo.environment) async throws -> Summary {
        guard environment["BRAHMA_DEV"] == "1", environment["BRAHMA_AGENT_ID"] == nil else { throw WorkError.forbidden(refusal) }
        let lock: OrchestratorLock
        do { lock = try OrchestratorLock.acquire(paths: paths) } catch OrchestratorLockError.alreadyRunning {
            throw WorkError.conflict("an engine is running on this data home; quit the app (or `brahma run`) first")
        }
        defer { withExtendedLifetime(lock) {} }
        return try await carryOut(store: store, paths: paths, companyId: companyId, vault: vault, itemKey: itemKey, file: file,
                                  environment: environment)
    }

    private static func carryOut(store: Store, paths: BrahmaPaths, companyId: String, vault: any SecretVault, itemKey: String?,
                                 file: String, environment: [String: String]) async throws -> Summary {
        guard let company = try store.company(id: companyId) else { throw WorkError.notFound("no such company") }
        guard company.mainCommit != nil else { throw WorkError.invalid("main has no engine-accepted commit yet (brahma main accept)") }
        guard company.status == .running else { throw WorkError.invalid("\(company.name) is paused; the queue merges nothing") }
        let relative = PathOverlap.normalized(file)
        guard relative != PathOverlap.wholeRepo, !relative.hasPrefix("../"), !relative.hasPrefix(".brahma") else {
            throw WorkError.invalid("--file must name a file inside the workspace")
        }
        _ = try store.reloadRedactorIfNeeded(vault: vault, logFailures: false)
        var base = environment
        base["BRAHMA_DEV"] = nil

        // Two agents that can take a lease and hold none, each for one item: engineers, then other individuals, then managers
        // (never an executive). The reviewer, one for both items: untainted (a tainted session cannot review), not a holder;
        // a holder's manager first, then any manager, then an executive or architect.
        let agents = try store.agents(companyId: companyId).filter { $0.state != .killed }.sorted { $0.name < $1.name }
        func kind(_ a: Agent) -> RoleKind { store.catalog.template(role: a.role, pack: company.packId).kind }
        let free = try agents.filter { agent in
            guard kind(agent) != .executive,
                  store.catalog.template(role: agent.role, pack: company.packId).companyTools.contains("claim_lease") else { return false }
            return try store.lease(agentId: agent.id) == nil
        }
        let holders = free.filter { $0.role == "engineer" } + free.filter { $0.role != "engineer" && kind($0) == .individual }
            + free.filter { kind($0) == .manager }
        guard holders.count >= 2 else {
            throw WorkError.invalid("the company needs two individuals or managers that can claim an item and hold no lease")
        }
        let (first, second) = (holders[0], holders[1])
        let managers = Set([first.managerId, second.managerId].compactMap { $0 })
        let reviewers = try agents.filter { a in
            guard a.id != first.id, a.id != second.id, kind(a) != .individual else { return false }
            return try !store.writer.read { try store.writesTainted(db: $0, actorId: a.id) }   // the row or the flag file
        }
        guard let reviewer = reviewers.first(where: { managers.contains($0.id) })
            ?? reviewers.first(where: { kind($0) == .manager }) ?? reviewers.first else {
            throw WorkError.invalid("the company has no untainted manager or executive left to review")
        }

        // The items. The first is the caller's (`ready`, with a check), else made here; the second is always made here and claims
        // only its own file, so the lease system lets both run at once (the conflict comes from what it writes, not what it claims).
        var itemA: WorkItem
        if let itemKey {
            guard let found = try store.workItem(companyId: companyId, key: itemKey) else { throw WorkError.notFound("no work item \(itemKey.uppercased())") }
            guard found.status == .ready else { throw WorkError.invalid("\(found.key) is \(found.status.rawValue), not ready") }
            guard found.checkSpec != nil else { throw WorkError.invalid("\(found.key) has no check; give it one (brahma items edit --check …)") }
            itemA = found
        } else {
            itemA = try store.createWorkItem(companyId: companyId, by: .owner, draft: WorkItemDraft(
                type: "task", title: "Streak counter", description: "Count consecutive days in \(relative).",
                checkSpec: CheckSpec(command: "test -f \(relative)", paths: [relative]), tier: .s, reviewerId: reviewer.id, status: .ready))
        }
        // The caller's reviewer stays unless it cannot review (a holder, or tainted); the owner's edit records the change.
        if !reviewers.contains(where: { $0.id == itemA.reviewerId }) {
            var patch = WorkItemPatch()
            patch.reviewerId = .some(reviewer.id)
            itemA = try store.updateWorkItem(id: itemA.id, by: .owner, patch: patch)
        }
        let own = summaryFile(beside: relative)
        let itemB = try store.createWorkItem(companyId: companyId, by: .owner, draft: WorkItemDraft(
            type: "task", title: "Weekly streak summary", description: "A weekly summary next to the counter.",
            checkSpec: CheckSpec(command: "test -f \(own)", paths: [own]), tier: .s, reviewerId: reviewer.id, status: .ready))

        // The engine, for its check path and its queue only: no turn is started (nothing ticks), the lock above is this process's.
        let orchestrator = Orchestrator(store: store, runner: ClaudeProcessRunner(), paths: paths, mcpExecutable: "brahma",
                                        checkBaseEnvironment: base, vault: vault)
        let git = GitWorkspace(root: URL(fileURLWithPath: company.workspacePath, isDirectory: true))

        try await deliver(itemA, by: first, writing: [relative: "\(itemA.key): 7 days\n"], store: store, paths: paths, vault: vault,
                          orchestrator: orchestrator, git: git)
        try await deliver(itemB, by: second, writing: [own: "\(itemB.key): week 1\n", relative: "\(itemB.key): 0 days\n"], store: store,
                          paths: paths, vault: vault, orchestrator: orchestrator, git: git)

        // The queue, batch by batch, until it has nothing left to do.
        for _ in 0..<maxBatches {
            guard let fresh = try store.company(id: companyId) else { break }
            guard let outcome = await orchestrator.mergeQueue.runNextBatch(company: fresh) else { break }
            if let held = outcome.held { throw WorkError.invalid("the merge queue is held: \(held)") }
        }
        guard let merged = try store.latestMergeRequest(itemId: itemA.id), let bounced = try store.latestMergeRequest(itemId: itemB.id) else {
            throw WorkError.invalid("the approvals queued no merge request")
        }
        guard merged.status == .merged else {
            throw WorkError.invalid("\(merged.ref) (\(itemA.key)) is \(merged.status.rawValue), not merged: \(Store.flat(merged.detail ?? "", max: 300))")
        }
        guard bounced.status == .bounced, bounced.failure == .conflict else {
            throw WorkError.invalid("\(bounced.ref) (\(itemB.key)) is \(bounced.status.rawValue)\(bounced.failure.map { " (\($0.rawValue))" } ?? ""), not bounced on a conflict: \(Store.flat(bounced.detail ?? "", max: 300))")
        }
        guard let doneA = try store.workItem(id: itemA.id), let backB = try store.workItem(id: itemB.id) else { throw WorkError.notFound("an item is gone") }
        return Summary(merged: merged, bounced: bounced, mergedItem: doneA, bouncedItem: backB, mainCommit: try store.company(id: companyId)?.mainCommit)
    }

    /// Claim, write, submit, let the engine's check path verify the commit, approve from a review turn: the item's merge request
    /// is queued at the end.
    private static func deliver(_ item: WorkItem, by holder: Agent, writing files: [String: String], store: Store, paths: BrahmaPaths,
                                vault: any SecretVault, orchestrator: Orchestrator, git: GitWorkspace) async throws {
        let tools = CompanyTools(store: store, companyId: item.companyId, agentId: holder.id, paths: paths, vault: vault)
        _ = try call(tools, "claim_lease", ["key": .string(item.key)])
        let worktree = git.worktreePath(key: item.key)
        for (path, text) in files.sorted(by: { $0.key < $1.key }) {
            let url = worktree.appending(path: path)
            try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            try text.write(to: url, atomically: true, encoding: .utf8)
        }
        _ = try call(tools, "submit_for_review", ["key": .string(item.key), "summary": .string("Wrote \(files.keys.sorted().joined(separator: " and ")).")])

        // The engine's check of the submitted commit, run here as the engine's tick would start it.
        let deadline = AwakeTime.now + checkWait   // awake time, as the engine's own deadlines (AwakeTimeTests)
        while try store.workItem(id: item.id)?.verifiedCommit == nil {
            if let run = try store.queuedVerifications(limit: 20).first(where: { $0.itemId == item.id }),
               let begun = try store.beginVerification(runId: run.id, outputPath: paths.companyDir(run.companyId)
                                                            .appending(path: "check-output/\(run.id).log").path) {
                await orchestrator.performCheck(run: begun)
                continue
            }
            if let latest = try store.latestVerification(itemId: item.id), latest.status != .queued && latest.status != .running {
                throw WorkError.invalid("\(item.key)'s check \(latest.status.rawValue): \(Store.flat(latest.outputTail ?? "", max: 300))")
            }
            // Nothing to run right now (queued for later, or a run another path began): the deadline, then a short wait (M5).
            guard AwakeTime.now < deadline else { throw WorkError.invalid("\(item.key)'s check did not finish") }
            try await AwakeTime.sleep(for: .milliseconds(200))
        }

        // The reviewer the engine settled on, approving from its own review turn through the review tool.
        guard let submitted = try store.workItem(id: item.id), let reviewerId = submitted.reviewerId else {
            throw WorkError.invalid("\(item.key) has no reviewer after its submission")
        }
        let turn = try store.startTurn(agentId: reviewerId)
        try store.setTurnContext(turnId: turn.id, kind: .review, itemId: item.id)
        let review = CompanyTools(store: store, companyId: item.companyId, agentId: reviewerId, reviewItemId: item.id, paths: paths, vault: vault)
        do {
            _ = try call(review, "review", ["key": .string(item.key), "decision": .string("approve"),
                                            "notes": .string("Looks right; the check passed."), "approve_flags": .bool(true)])
        } catch {
            try store.finishTurn(id: turn.id, outcome: .failed, summary: "review could not be given", costUSD: nil)
            throw error
        }
        try store.finishTurn(id: turn.id, outcome: .succeeded, summary: "approved \(item.key)", costUSD: nil)
    }

    /// `streak.txt` → `streak-summary.txt`; `docs/notes` → `docs/notes-summary`.
    static func summaryFile(beside file: String) -> String {
        let name = file as NSString
        let ext = name.pathExtension
        return name.deletingPathExtension + "-summary" + (ext.isEmpty ? "" : "." + ext)
    }

    private static func call(_ tools: CompanyTools, _ name: String, _ arguments: [String: JSONValue]) throws -> String {
        do { return try tools.call(name: name, arguments: arguments) }
        catch let e as ToolError { throw WorkError.invalid("\(name): \(e.message)") }
    }
}
