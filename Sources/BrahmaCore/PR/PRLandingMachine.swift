import Foundation

/// One company's (or the engine's) PR landings, item by item (Plan X8 Task 3, spec §8.5.1 steps 3–4): the merge queue hands a
/// verified commit to `begin`; the machine pushes it (`PushBranchStage`), opens the pull request (`open-pr`, body by `PRBody`)
/// and watches it for a close upstream. Task 4's `PRStep` calls `advance` for every open landing each tick; the waits on checks,
/// reviews and the merge are Tasks 4–6.
///
/// `pushing` → `pushed` → `opening` → `open`. Every transition is written to `prLanding` as a compare-and-set on the (state,
/// commit) the pass read (`Store.casPRLanding`): when an owner's abandon, a newer `begin` or a close upstream got there first,
/// nothing is written and the pass stops — no push is recorded over it and no PR is opened for it. A refused or failed action
/// records `lastError` and the state stays (the next `advance` tries again, reconciling first). Every action goes through the one
/// gate (`PRActionGate`; production's `NoChannelGate` refuses everything, so nothing reaches GitHub on this tree):
/// - `refuse`: `lastError` is the rule;
/// - `ask`: one owner card (`AskKind.prAction`, `Store.filePRActionCard`) bound to the digest of exactly the request it shows
///   (`PRActionDigest`), `lastError` "waiting for the owner: <reason>"; the owner's approval answers a later `ask` only for a
///   request with the same digest (`CardGate`), never a `refuse`; any change — title, body, base, commit, visibility, taint,
///   first use, reason — voids the card and files a fresh one; a decline stops it ("the owner declined: ...").
/// Reconciling, never pushing or opening blind: a `pushing` landing first reads the branch on GitHub (it may already hold the
/// commit), and an `opening` one (or one with a PR) first reads the pull requests on its head — adopting only the engine's own
/// (Ruling 28: base, head commit and content digest as sent); any other open PR there holds the landing for the owner.
public actor PRLandingMachine: PRLandingBeginning {
    let store: Store
    let github: any GitHubAPI
    let gate: any PRActionGate
    let push: PushBranchStage
    /// The company's GitHub repository (a channel core will supply it); nil holds every landing of the company.
    let repo: @Sendable (_ companyId: String) -> GitHubRepoRef?
    let clock: @Sendable () -> Date
    /// Items with a pass in flight: a second `advance` for one of them returns at once (the actor is reentrant across awaits).
    private var busy: Set<String> = []

    public init(store: Store, github: any GitHubAPI, gate: any PRActionGate, push: PushBranchStage,
                repo: @escaping @Sendable (String) -> GitHubRepoRef?, clock: @escaping @Sendable () -> Date = Store.now) {
        self.store = store; self.github = github; self.gate = gate; self.push = push; self.repo = repo; self.clock = clock
    }

    static let noRepoText = "no GitHub repository is linked to this company"
    static func waitingText(_ reason: String) -> String { "waiting for the owner: \(reason)" }
    static func declinedText(_ reason: String) -> String { "the owner declined: \(reason)" }
    static func foreignPRText(_ branch: String, _ number: Int) -> String {
        "a pull request Brahma did not open exists on \(branch) (#\(number)); close it or abandon the landing"
    }

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
    /// The pass stops as soon as the landing is not the one it started on (another commit) or did not move as its step wrote.
    public func advance(itemId: String) async {
        guard busy.insert(itemId).inserted else { return }
        defer { busy.remove(itemId) }
        var startSHA: String?
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
            if let startSHA, startSHA != landing.pushedSHA { return }
            startSHA = landing.pushedSHA
            guard let repo = self.repo(landing.companyId) else { return hold(landing, Self.noRepoText) }
            switch landing.state {
            case .pushing where !pushedThisPass:
                await pushStep(landing, item, repo)
                pushedThisPass = true
                continue   // pushed now: open in the same pass (re-read: the CAS tells whether it still is ours)
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
                if transition(landing, from: [.pushing], { $0.state = .pushed; $0.lastError = nil }) { consume(card) }
                return
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
        let cardGate = CardGate(inner: gate, action: .pushBranch, itemId: item.id, sha: landing.pushedSHA, open: nil, approved: card.approval)
        switch await push.gated(by: cardGate).run(item: item, repo: repo, verifiedSHA: landing.pushedSHA, base: base, git: git,
                                                    branch: landing.branch) {
        case .pushed:
            consume(card)
        case .needsOwner(let reason, let payload):
            guard let digest = cardGate.askedDigest else { return hold(landing, Self.waitingText(reason)) }
            fileCard(landing, action: .pushBranch, reason: reason, digest: digest, replacing: card,
                     card: PRActionCard.push(item: item, payload: payload, reason: reason))
        case .refused(let why):
            hold(landing, why)
        case .failed:
            break   // the stage recorded it (still `pushing`, with `lastError`), unless the landing moved on meanwhile
        }
    }

    // MARK: open-pr

    private func openStep(_ landing: PRLanding, _ item: WorkItem, _ repo: GitHubRepoRef) async {
        let card: PRActionCardState
        do { card = try store.prActionCardState(companyId: landing.companyId, itemId: item.id, action: .openPR, sha: landing.pushedSHA) } catch {
            return hold(landing, "the owner's cards could not be read: \(Store.flat("\(error)", max: 200))")
        }
        if let held = Self.heldByCard(card) { return hold(landing, held) }
        let info: RepoInfo
        do { info = try await github.repo(repo) } catch {
            return hold(landing, "could not read \(repo.owner)/\(repo.name) on GitHub: \(Store.flat("\(error)", max: 200))")
        }
        // Reconcile: an earlier open whose answer was lost, or this branch's PR from an earlier push of the item.
        if landing.state == .opening || landing.prNumber != nil {
            do {
                switch try await headPR(landing, repo, base: info.defaultBranch) {
                case .ours(let pr): return opened(landing, from: [landing.state], pr, consuming: card)
                case .foreign(let pr): return hold(landing, Self.foreignPRText(landing.branch, pr.number))
                case .none: break
                }
            } catch {
                return hold(landing, "could not read the pull requests of \(landing.branch): \(Store.flat("\(error)", max: 200))")
            }
        }
        let request: OpenPullRequest
        let bodyLines: [PRBody.Line]
        let action: PRActionRequest
        do {
            let inputs = try PRBodyInputs.recorded(store: store, item: item, repo: repo)
            bodyLines = inputs.lines(item: item)
            request = OpenPullRequest(title: PRBody.title(item: item), head: landing.branch, base: info.defaultBranch,
                                      body: bodyLines.map(\.text).joined(separator: "\n") + "\n")
            action = PRActionRequest(type: .openPR, companyId: item.companyId, itemId: item.id, payload: nil,
                                     taintedSession: try PushBranchStage.sessionTainted(item, store: store), itemTainted: item.taintedOrigin,
                                     externalInput: false, firstUse: !(try store.hasOpenedPRLanding(companyId: item.companyId)),
                                     repoVisibility: info.visibility)
        } catch {
            return hold(landing, "could not prepare the pull request: \(Store.flat("\(error)", max: 200))")
        }
        let cardGate = CardGate(inner: gate, action: .openPR, itemId: item.id, sha: landing.pushedSHA, open: request, approved: card.approval)
        switch await cardGate.decide(action) {
        case .refuse(let rule):
            return hold(landing, rule)
        case .ask(let reason):
            return fileCard(landing, action: .openPR, reason: reason,
                            digest: PRActionDigest.of(action, reason: reason, sha: landing.pushedSHA, open: request), replacing: card,
                            card: PRActionCard.openPR(item: item, repo: repo, request: request, body: bodyLines, sha: landing.pushedSHA,
                                                      reason: reason))
        case .auto:
            break
        }
        // Sending: recorded first (with what is sent), so a crash or a lost answer is reconciled by the head, never opened blind
        // again. Not recorded (the landing moved on, or the write failed) → nothing is sent.
        let digest = PRBody.contentDigest(title: request.title, body: request.body)
        guard transition(landing, from: [landing.state], { $0.state = .opening; $0.lastError = nil; $0.openDigest = digest }) else { return }
        var sent = landing
        sent.state = .opening
        sent.openDigest = digest
        let why: String
        do {
            let pr = try await github.openPR(repo, request)
            return opened(sent, from: [.opening], pr, consuming: card)
        } catch GitHubAPIError.rejected(let status, let message) {
            why = "GitHub refused the pull request (\(status)): \(Store.flat(message, max: 200))"
        } catch {
            why = "the pull request may not have been opened (\(Store.flat("\(error)", max: 160)))"
        }
        // Read back: GitHub says whether the engine's PR exists on the head (it refuses a second open PR for one head anyway).
        do {
            switch try await headPR(sent, repo, base: info.defaultBranch) {
            case .ours(let pr): opened(sent, from: [.opening], pr, consuming: card)
            case .foreign(let pr): hold(sent, Self.foreignPRText(sent.branch, pr.number))
            case .none: hold(sent, "\(why); no pull request for \(sent.branch) was found")
            }
        } catch {
            hold(sent, "\(why); GitHub could not be read: \(Store.flat("\(error)", max: 120))")
        }
    }

    enum HeadPR { case ours(GitHubPR), foreign(GitHubPR), none }

    /// The pull requests on the landing's branch (its recorded one, and `GET /pulls?head=<owner>:<branch>&state=all`). One is the
    /// engine's (Ruling 28) only when its base is the default branch read now, its head is the pushed commit and its title and
    /// body digest to what the engine sent (`openDigest`); the open one of those first, else the newest. Any other open PR on the
    /// head is foreign: never adopted.
    private func headPR(_ landing: PRLanding, _ repo: GitHubRepoRef, base: String) async throws -> HeadPR {
        var candidates: [GitHubPR] = []
        if let number = landing.prNumber, let pr = try await github.pull(repo, number: number), pr.headRef == landing.branch {
            candidates.append(pr)
        }
        for pr in try await github.pulls(repo, head: "\(repo.owner):\(landing.branch)", state: "all")
        where pr.headRef == landing.branch && !candidates.contains(where: { $0.number == pr.number }) {
            candidates.append(pr)
        }
        func ours(_ pr: GitHubPR) -> Bool {
            guard let sent = landing.openDigest else { return false }
            return pr.baseRef == base && pr.headSHA == landing.pushedSHA && PRBody.contentDigest(title: pr.title, body: pr.body) == sent
        }
        let mine = candidates.filter(ours)
        if let pr = mine.filter(\.isOpen).max(by: { $0.number < $1.number }) ?? mine.max(by: { $0.number < $1.number }) { return .ours(pr) }
        if let pr = candidates.filter(\.isOpen).min(by: { $0.number < $1.number }) { return .foreign(pr) }
        return .none
    }

    private func opened(_ landing: PRLanding, from states: Set<PRLandingState>, _ pr: GitHubPR, consuming card: PRActionCardState) {
        if transition(landing, from: states, { $0.state = .open; $0.prNumber = pr.number; $0.prURL = pr.htmlURL; $0.lastError = nil }) {
            consume(card)
        } else {
            note("\(landing.itemId): PR #\(pr.number) is on GitHub, but the landing moved on meanwhile; it was not recorded")
        }
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
            do {
                try store.closePRLandingUpstream(itemId: item.id, number: number, from: landing.state, sha: landing.pushedSHA, now: clock())
            } catch {
                note("\(item.key): the close of PR #\(number) could not be recorded: \(error)")
            }
            return
        }
        let now = clock()
        transition(landing, from: [landing.state]) { $0.lastPolled = now }
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

    /// Files the card for the request the gate asked about. An approved card it replaces (its request no longer matches what
    /// would run) is voided first, so the owner sees the new request on a fresh card.
    private func fileCard(_ landing: PRLanding, action: GitHubActionType, reason: String, digest: String, replacing old: PRActionCardState,
                          card: PRActionCard) {
        do {
            if case .approved(let askId, _) = old { try store.voidPRActionCard(askId: askId, now: clock()) }
            try store.filePRActionCard(companyId: landing.companyId, itemId: landing.itemId, action: action, sha: landing.pushedSHA,
                                       reason: reason, digest: digest, card: card, now: clock())
        } catch {
            return hold(landing, "\(Self.waitingText(reason)) (the card could not be filed: \(Store.flat("\(error)", max: 160)))")
        }
        hold(landing, Self.waitingText(reason))
    }

    private func consume(_ card: PRActionCardState) {
        guard case .approved(let askId, _) = card else { return }
        do { try store.consumePRActionApproval(askId: askId, now: clock()) } catch {
            note("the approval \(askId) could not be marked used: \(error)")
        }
    }

    // MARK: Records

    /// The state stays; `lastError` says why (only while the landing is still where this pass read it).
    private func hold(_ landing: PRLanding, _ why: String) {
        transition(landing, from: [landing.state]) { $0.lastError = why }
    }

    /// Compare-and-set on (`states`, the landing's commit); true when written.
    @discardableResult
    private func transition(_ landing: PRLanding, from states: Set<PRLandingState>, _ change: (inout PRLanding) -> Void) -> Bool {
        do { return try store.casPRLanding(itemId: landing.itemId, from: states, sha: landing.pushedSHA, now: clock(), change) } catch {
            note("\(landing.itemId): the landing could not be recorded: \(error)")
            return false
        }
    }

    private nonisolated func note(_ text: String) {
        FileHandle.standardError.write(Data("brahma PR landing: \(text)\n".utf8))
    }
}

extension PRActionCardState {
    /// The approved card's ask and the digest its approval answers, if approved.
    var approval: (askId: String, digest: String)? {
        if case .approved(let askId, let digest) = self { return (askId, digest) }
        return nil
    }
}

/// The gate for one action of one item (Ruling 26, Rulings X8-21 and 29): the inner gate decides; when it asks about exactly
/// that action of that item, the ask's digest (`PRActionDigest`: the request, the PR content for `open-pr`, the reason) is
/// remembered, and an owner approval with that very digest answers it (`auto`). A `refuse` stands; another digest stays an ask
/// (the machine files a fresh card); any other request is the inner gate's alone.
final class CardGate: PRActionGate, @unchecked Sendable {
    let inner: any PRActionGate
    let action: GitHubActionType
    let itemId: String
    let sha: String
    let open: OpenPullRequest?
    let approved: (askId: String, digest: String)?
    private let lock = NSLock()
    private var lastAsk: String?

    init(inner: any PRActionGate, action: GitHubActionType, itemId: String, sha: String, open: OpenPullRequest?,
         approved: (askId: String, digest: String)?) {
        self.inner = inner; self.action = action; self.itemId = itemId; self.sha = sha; self.open = open; self.approved = approved
    }

    /// The digest of the last ask about this action of this item.
    var askedDigest: String? { lock.withLock { lastAsk } }

    func decide(_ r: PRActionRequest) async -> PRActionDecision {
        let decision = await inner.decide(r)
        guard case .ask(let reason) = decision, r.type == action, r.itemId == itemId else { return decision }
        let digest = PRActionDigest.of(r, reason: reason, sha: sha, open: open)
        lock.withLock { lastAsk = digest }
        if let approved, approved.digest == digest { return .auto }
        return decision
    }
}
