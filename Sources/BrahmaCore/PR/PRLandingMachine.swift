import Foundation

/// One company's (or the engine's) PR landings, item by item (Plan X8 Task 3, spec §8.5.1 steps 3–4): the merge queue hands a
/// verified commit to `begin`; the machine pushes it (`PushBranchStage`), opens the pull request (`open-pr`, body by `PRBody`)
/// and watches it for a close upstream. Task 4's `PRStep` calls `advance` for every open landing each tick; the waits on checks,
/// reviews and the merge are Tasks 4–6.
///
/// `pushing` → `pushed` → `opening` → `open`. Every transition is written to `prLanding`; a refused or failed action records
/// `lastError` and the state stays (the next `advance` tries again, reconciling first). Every action goes through the one gate
/// (`PRActionGate`; production's `NoChannelGate` refuses everything, so nothing reaches GitHub on this tree):
/// - `refuse`: `lastError` is the rule;
/// - `ask`: one owner card (`AskKind.prAction`, `Store.filePRActionCard`), `lastError` "waiting for the owner: <reason>"; the
///   owner's approval lets exactly that action for exactly that commit run once even though the gate would ask again (that is
///   the answer to the ask, not a second path), never when the gate refuses; a decline stops it ("the owner declined: ...").
/// Reconciling, never pushing or opening blind: a `pushing` landing first reads the branch on GitHub (it may already hold the
/// commit), and an `opening` one first lists the pull requests for its head.
public actor PRLandingMachine: PRLandingBeginning {
    let store: Store
    let github: any GitHubAPI
    let gate: any PRActionGate
    let push: PushBranchStage
    /// The company's GitHub repository (a channel core will supply it); nil holds every landing of the company.
    let repo: @Sendable (_ companyId: String) -> GitHubRepoRef?
    let clock: @Sendable () -> Date
    /// Items with a pass in flight: a second call for one of them returns at once (the actor is reentrant across awaits).
    private var busy: Set<String> = []

    public init(store: Store, github: any GitHubAPI, gate: any PRActionGate, push: PushBranchStage,
                repo: @escaping @Sendable (String) -> GitHubRepoRef?, clock: @escaping @Sendable () -> Date = Store.now) {
        self.store = store; self.github = github; self.gate = gate; self.push = push; self.repo = repo; self.clock = clock
    }

    static let noRepoText = "no GitHub repository is linked to this company"
    static func waitingText(_ reason: String) -> String { "waiting for the owner: \(reason)" }
    static func declinedText(_ reason: String) -> String { "the owner declined: \(reason)" }

    // MARK: Entry points

    /// The merge queue's hand-off: records the landing at `pushing` (idempotent for the same commit) and takes it as far as it goes.
    public func begin(item: WorkItem, verifiedSHA: String) async {
        let branch = PRBranch.name(key: item.key, title: item.title).value ?? PRBranch.prefix + item.key
        do {
            guard try store.beginPRLanding(item: item, sha: verifiedSHA, branch: branch, now: clock()) else { return }
        } catch {
            note("\(item.key): the landing could not be recorded: \(error)")
            return
        }
        await advance(itemId: item.id)
    }

    /// One pass for one item: `pushing` pushes (then opens), `pushed`/`opening` opens, an open PR is checked for a close upstream.
    public func advance(itemId: String) async {
        guard busy.insert(itemId).inserted else { return }
        defer { busy.remove(itemId) }
        var pushedThisPass = false
        while true {
            let landing: PRLanding, item: WorkItem
            do {
                guard let l = try store.prLanding(itemId: itemId), l.state.isOpen, let i = try store.workItem(id: itemId) else { return }
                (landing, item) = (l, i)
            } catch {
                note("\(itemId): the landing could not be read: \(error)")
                return
            }
            guard let repo = self.repo(landing.companyId) else { return hold(landing, Self.noRepoText) }
            switch landing.state {
            case .pushing where !pushedThisPass:
                await pushStep(landing, item, repo)
                pushedThisPass = true
                continue   // pushed now: open in the same pass
            case .pushed, .opening:
                await openStep(landing, item, repo)
            case .open, .checksFailed, .changesRequested, .mergeable:
                await watchStep(landing, item, repo)
            default:
                break
            }
            return
        }
    }

    /// Every landing of the company still being watched, oldest first (Task 4's `PRStep`).
    public func advanceAll(companyId: String) async {
        let ids: [String]
        do { ids = try store.openPRLandings(companyId: companyId).map(\.itemId) } catch {
            note("company \(companyId): the landings could not be read: \(error)")
            return
        }
        for id in ids { await advance(itemId: id) }
    }

    /// Owner only (Ruling 21): the owner gives up on the item's landing. Nothing is closed or deleted on GitHub.
    public func abandon(itemId: String, reason: String, by sender: Sender) throws {
        try store.abandonPRLanding(itemId: itemId, reason: reason, by: sender, now: clock())
    }

    // MARK: push-branch

    private func pushStep(_ landing: PRLanding, _ item: WorkItem, _ repo: GitHubRepoRef) async {
        let card: PRActionCardState
        do { card = try store.prActionCardState(companyId: landing.companyId, itemId: item.id, action: .pushBranch, sha: landing.pushedSHA) } catch {
            return hold(landing, "the owner's cards could not be read: \(Store.flat("\(error)", max: 200))")
        }
        if let held = Self.heldByCard(card) { return hold(landing, held) }
        // Reconcile: GitHub may already hold the commit (an unknown push, a crash after sending). Never a blind second push.
        do {
            if try await github.branch(repo, name: landing.branch)?.sha == landing.pushedSHA {
                return transition(landing.itemId, consuming: card) { $0.state = .pushed; $0.lastError = nil }
            }
        } catch {
            return hold(landing, "could not read \(landing.branch) on GitHub: \(Store.flat("\(error)", max: 200))")
        }
        let base: String
        let git: GitWorkspace
        do {
            guard let b = try store.prHandOffBase(itemId: item.id, sha: landing.pushedSHA),
                  let company = try store.company(id: landing.companyId) else {
                return hold(landing, "no merge-queue hand-off records the base of \(landing.pushedSHA.prefix(7))")
            }
            base = b
            git = store.gitWorkspace(root: URL(fileURLWithPath: company.workspacePath, isDirectory: true), companyId: company.id)
        } catch {
            return hold(landing, "the hand-off could not be read: \(Store.flat("\(error)", max: 200))")
        }
        let stage = push.gated(by: gateFor(card, action: .pushBranch, itemId: item.id))
        switch await stage.run(item: item, repo: repo, verifiedSHA: landing.pushedSHA, base: base, git: git, branch: landing.branch) {
        case .pushed:
            consume(card)
        case .needsOwner(let reason, let payload):
            fileCard(landing, action: .pushBranch, reason: reason, card: PRActionCard.push(item: item, payload: payload, reason: reason))
        case .refused(let why):
            hold(landing, why)
        case .failed:
            break   // the stage recorded it: still `pushing`, with `lastError`
        }
    }

    // MARK: open-pr

    private func openStep(_ landing: PRLanding, _ item: WorkItem, _ repo: GitHubRepoRef) async {
        let card: PRActionCardState
        do { card = try store.prActionCardState(companyId: landing.companyId, itemId: item.id, action: .openPR, sha: landing.pushedSHA) } catch {
            return hold(landing, "the owner's cards could not be read: \(Store.flat("\(error)", max: 200))")
        }
        if let held = Self.heldByCard(card) { return hold(landing, held) }
        // Reconcile: an earlier open whose answer was lost, or this branch's PR from an earlier push of the item.
        if landing.state == .opening || landing.prNumber != nil {
            do {
                if let pr = try await existingPR(landing, repo) { return opened(landing.itemId, pr, consuming: card) }
            } catch {
                return hold(landing, "could not read the pull requests of \(landing.branch): \(Store.flat("\(error)", max: 200))")
            }
        }
        let info: RepoInfo
        let request: OpenPullRequest
        let action: PRActionRequest
        do {
            info = try await github.repo(repo)
            let body = try PRBodyInputs.recorded(store: store, item: item, repo: repo).render(item: item)
            request = OpenPullRequest(title: PRBody.title(item: item), head: landing.branch, base: info.defaultBranch, body: body)
            action = PRActionRequest(type: .openPR, companyId: item.companyId, itemId: item.id, payload: nil,
                                     taintedSession: try PushBranchStage.sessionTainted(item, store: store), itemTainted: item.taintedOrigin,
                                     externalInput: false, firstUse: !(try store.hasOpenedPRLanding(companyId: item.companyId)),
                                     repoVisibility: info.visibility)
        } catch {
            return hold(landing, "could not prepare the pull request: \(Store.flat("\(error)", max: 200))")
        }
        switch await gateFor(card, action: .openPR, itemId: item.id).decide(action) {
        case .refuse(let rule):
            return hold(landing, rule)
        case .ask(let reason):
            return fileCard(landing, action: .openPR, reason: reason,
                            card: PRActionCard.openPR(item: item, repo: repo, request: request, sha: landing.pushedSHA, reason: reason))
        case .auto:
            break
        }
        // Sending: recorded first, so a crash or a lost answer is reconciled by the head, never opened blind again.
        transition(landing.itemId) { $0.state = .opening; $0.lastError = nil }
        let why: String
        do {
            let pr = try await github.openPR(repo, request)
            return opened(landing.itemId, pr, consuming: card)
        } catch GitHubAPIError.rejected(let status, let message) {
            why = "GitHub refused the pull request (\(status)): \(Store.flat(message, max: 200))"
        } catch {
            why = "the pull request may not have been opened (\(Store.flat("\(error)", max: 160)))"
        }
        // Read back: GitHub says whether a PR for the head exists (it refuses a second open PR for one head anyway).
        do {
            if let pr = try await existingPR(landing, repo) { return opened(landing.itemId, pr, consuming: card) }
            hold(landing, "\(why); no pull request for \(landing.branch) was found")
        } catch {
            hold(landing, "\(why); GitHub could not be read: \(Store.flat("\(error)", max: 120))")
        }
    }

    /// The PR for the landing's branch: its recorded one while open, else from the list for `<owner>:<branch>` — an open one at
    /// the pushed commit first, then any open one, then a closed one at the pushed commit (the watch then ends the landing).
    private func existingPR(_ landing: PRLanding, _ repo: GitHubRepoRef) async throws -> GitHubPR? {
        if let number = landing.prNumber, let pr = try await github.pull(repo, number: number), pr.isOpen, pr.headRef == landing.branch {
            return pr
        }
        let all = try await github.pulls(repo, head: "\(repo.owner):\(landing.branch)", state: "all").filter { $0.headRef == landing.branch }
        return all.first { $0.isOpen && $0.headSHA == landing.pushedSHA }
            ?? all.first { $0.isOpen }
            ?? all.filter { !$0.isOpen && $0.headSHA == landing.pushedSHA }.max { $0.number < $1.number }
    }

    private func opened(_ itemId: String, _ pr: GitHubPR, consuming card: PRActionCardState) {
        transition(itemId, consuming: card) { $0.state = .open; $0.prNumber = pr.number; $0.prURL = pr.htmlURL; $0.lastError = nil }
    }

    // MARK: Watch

    /// A PR closed on GitHub without being merged ends the landing `closedUpstream` and tells the item's owner agent. A merged
    /// one is left for the merge step (Tasks 5–6).
    private func watchStep(_ landing: PRLanding, _ item: WorkItem, _ repo: GitHubRepoRef) async {
        guard let number = landing.prNumber else { return }
        let pr: GitHubPR?
        do { pr = try await github.pull(repo, number: number) } catch {
            return hold(landing, "could not read PR #\(number) on GitHub: \(Store.flat("\(error)", max: 200))")
        }
        guard let pr else { return hold(landing, "PR #\(number) was not found on GitHub") }
        if !pr.isOpen, !pr.merged {
            do { try store.closePRLandingUpstream(itemId: item.id, number: number, now: clock()) } catch {
                note("\(item.key): the close of PR #\(number) could not be recorded: \(error)")
            }
            return
        }
        transition(landing.itemId) { $0.lastPolled = self.clock() }
    }

    // MARK: Owner cards

    /// Why an action waits on its card, or nil when it may go to the gate.
    static func heldByCard(_ card: PRActionCardState) -> String? {
        switch card {
        case .waiting(let reason): waitingText(reason)
        case .declined(let reason): declinedText(reason)
        case .none, .approved: nil
        }
    }

    /// The gate, or — when the owner approved exactly this action — the gate with its `ask` for it answered.
    private func gateFor(_ card: PRActionCardState, action: GitHubActionType, itemId: String) -> any PRActionGate {
        guard case .approved = card else { return gate }
        return OwnerApprovedGate(inner: gate, action: action, itemId: itemId)
    }

    private func fileCard(_ landing: PRLanding, action: GitHubActionType, reason: String, card: PRActionCard) {
        do {
            try store.filePRActionCard(companyId: landing.companyId, itemId: landing.itemId, action: action, sha: landing.pushedSHA,
                                       reason: reason, card: card, now: clock())
        } catch {
            return hold(landing, "\(Self.waitingText(reason)) (the card could not be filed: \(Store.flat("\(error)", max: 160)))")
        }
        hold(landing, Self.waitingText(reason))
    }

    private func consume(_ card: PRActionCardState) {
        guard case .approved(let askId) = card else { return }
        do { try store.consumePRActionApproval(askId: askId, now: clock()) } catch {
            note("the approval \(askId) could not be marked used: \(error)")
        }
    }

    // MARK: Records

    /// The state stays; `lastError` says why.
    private func hold(_ landing: PRLanding, _ why: String) {
        transition(landing.itemId) { $0.lastError = why }
    }

    private func transition(_ itemId: String, consuming card: PRActionCardState = .none, _ change: (inout PRLanding) -> Void) {
        do { try store.updatePRLanding(itemId: itemId, now: clock(), change) } catch {
            note("\(itemId): the landing could not be recorded: \(error)")
            return
        }
        consume(card)
    }

    private nonisolated func note(_ text: String) {
        FileHandle.standardError.write(Data("brahma PR landing: \(text)\n".utf8))
    }
}

/// The gate for one action the owner approved (Ruling 26): the inner gate still decides, and its `ask` for exactly that action
/// of that item is answered by the approval. A `refuse` stands; any other request is the inner gate's alone.
struct OwnerApprovedGate: PRActionGate {
    let inner: any PRActionGate
    let action: GitHubActionType
    let itemId: String

    func decide(_ r: PRActionRequest) async -> PRActionDecision {
        let decision = await inner.decide(r)
        guard case .ask = decision, r.type == action, r.itemId == itemId else { return decision }
        return .auto
    }
}
