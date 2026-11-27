import Foundation

/// One company's (or the engine's) PR landings, item by item (Plan X8 Tasks 3 and 5, spec §8.5.1 steps 3–7): the merge queue
/// hands a verified commit to `begin`; the machine pushes it (`PushBranchStage`), opens the pull request (`open-pr`, body by
/// `PRBody`), watches it for a close upstream, and once Task 4's `PRStep` found it `mergeable`, merges it or waits for it to be
/// merged. Task 4's `PRStep` calls `advance` for every open landing each tick (the waits on checks and reviews are its own).
///
/// `pushing` → `pushed` → `opening` → `open` (→ `mergeable` by `PRStep`) → `merging` → `merged`. The merge (Task 5, spec §8.5.1
/// step 6, §8.4.5 rule 4, §9.3.4): by default a human merges on GitHub and the landing waits for GitHub to report it `merged`.
/// With the company's `--engine-merge`, while GitHub says the pushed commit is the head and `mergeable_state` is `clean`, the
/// machine files `merge-pr` through the one gate — irreversible, so it always asks: one owner card bound to the PR number, the
/// head commit, the method and the base (`PRActionDigest.Merge`); the approval presses merge once (`merging` and the approval
/// spent in one write before the `PUT`), with `sha` pinned. 409 (the branch moved) and 405 (not mergeable) go back to `open`;
/// any other refusal holds for good; an unknown outcome is read back (`merging` only ever reads), never sent again — every
/// further merge needs a fresh card. Never a bypass field, a protection or settings call, or a branch deleted. After `merged`,
/// the remote `main` is fetched (`RemoteMainFetching`) and the item completes through the merge queue's own landing record
/// (`Store.completePRLanding`); without a fetch the landing stays `merged` and says it waits for one.
///
/// Every transition is written to `prLanding` as a compare-and-set on the (state, commit) the pass read (`Store.casPRLanding`,
/// and `Store.startPRMerge` for `merging`): when an owner's abandon, a newer `begin` or a close upstream got there first,
/// nothing is written and the pass stops — no push is recorded over it, no PR is opened and no merge is sent for it. A refused or failed action
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
    /// The remote `main` fetch a merged landing waits for before its item completes (Task 6's `RemoteMain`; the merge queue's
    /// own). Nil: merged landings wait, their items not Done.
    let remoteMain: (any RemoteMainFetching)?
    /// Items with a pass in flight: a second `advance` for one of them returns at once (the actor is reentrant across awaits).
    private var busy: Set<String> = []

    public init(store: Store, github: any GitHubAPI, gate: any PRActionGate, push: PushBranchStage,
                repo: @escaping @Sendable (String) -> GitHubRepoRef?, clock: @escaping @Sendable () -> Date = Store.now,
                remoteMain: (any RemoteMainFetching)? = nil) {
        self.store = store; self.github = github; self.gate = gate; self.push = push; self.repo = repo; self.clock = clock
        self.remoteMain = remoteMain
    }

    static let noRepoText = "no GitHub repository is linked to this company"
    static func waitingText(_ reason: String) -> String { "waiting for the owner: \(reason)" }
    static func declinedText(_ reason: String) -> String { "the owner declined: \(reason)" }
    static func foreignPRText(_ branch: String, _ number: Int) -> String {
        "a pull request Brahma did not open exists on \(branch) (#\(number)); close it or abandon the landing"
    }
    /// A merged landing whose item waits for the remote `main` fetch (none wired).
    static let waitingForFetchText = "PR merged; waiting for the remote main fetch"
    /// How a merge refused for good reads (`PRStep.isDurableHold`: the owner is told once).
    static let mergeHeldMarker = " cannot be merged by Brahma: "
    static func mergeHeldText(_ number: Int, _ why: String) -> String { "PR #\(number)\(mergeHeldMarker)\(why)" }

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
            case .open, .checksFailed, .changesRequested:
                await watchStep(landing, item, repo)
            case .mergeable, .merging:
                await mergeStep(landing, item, repo)
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
        let cardGate = CardGate(inner: gate, action: .pushBranch, itemId: item.id, sha: landing.pushedSHA, repoURL: repo.pushURL, open: nil,
                                approved: card.approval)
        switch await push.gated(by: cardGate).run(item: item, repo: repo, verifiedSHA: landing.pushedSHA, base: base, git: git,
                                                    branch: landing.branch, lease: Self.lease(landing)) {
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

    /// Ruling X8-31′: a resubmit to the engine's own PR branch replaces the commit Brahma last pushed and recorded there — only
    /// when the branch is in the `brahma/` namespace and Brahma opened the PR on it (it has the PR's number and the digest of what
    /// it sent, Ruling 28). Anything else is a plain push, never forced.
    static func lease(_ landing: PRLanding) -> String? {
        guard let lease = landing.leaseSHA, lease != landing.pushedSHA, landing.branch.hasPrefix(PRBranch.prefix),
              landing.prNumber != nil, landing.openDigest != nil else { return nil }
        return lease
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
        let cardGate = CardGate(inner: gate, action: .openPR, itemId: item.id, sha: landing.pushedSHA, repoURL: repo.pushURL, open: request,
                                approved: card.approval)
        switch await cardGate.decide(action) {
        case .refuse(let rule):
            return hold(landing, rule)
        case .ask(let reason):
            return fileCard(landing, action: .openPR, reason: reason,
                            digest: PRActionDigest.of(action, reason: reason, sha: landing.pushedSHA, repoURL: repo.pushURL, open: request), replacing: card,
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

    /// A PR closed on GitHub without being merged ends the landing `closedUpstream` and gives the item back. A merged one is
    /// `merged` (a human pressed merge on GitHub).
    private func watchStep(_ landing: PRLanding, _ item: WorkItem, _ repo: GitHubRepoRef) async {
        guard let number = landing.prNumber else { return }
        let pr: GitHubPR?
        do { pr = try await github.pull(repo, number: number) } catch {
            return hold(landing, "could not read PR #\(number) on GitHub: \(Store.flat("\(error)", max: 200))")
        }
        guard let pr else { return hold(landing, "PR #\(number) was not found on GitHub") }
        if pr.merged { return await mergedUpstream(landing, pr: pr, repo: repo) }
        if !pr.isOpen {
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

    // MARK: merge-pr (Task 5)

    /// `mergeable` and `merging`. GitHub is read first: merged → `mergedUpstream` (proven, or held); closed → `closedUpstream`.
    /// A `merging` landing only reconciles (its merge's answer was lost): not merged → back to `open`. Without `--engine-merge` a
    /// human merges on GitHub and this only watches. With it: GitHub must still say the pushed commit is the head and `clean`
    /// (else back to `open`, where the checks and reviews are read again), then `merge-pr` through the gate — and, whatever the
    /// gate answered short of `refuse`, only on the owner's approval of exactly this request (rule 4) — then the `PUT`.
    private func mergeStep(_ landing: PRLanding, _ item: WorkItem, _ repo: GitHubRepoRef) async {
        guard let number = landing.prNumber else { return hold(landing, "no pull request is recorded for \(landing.branch)") }
        let pr: GitHubPR
        do {
            guard let read = try await github.pull(repo, number: number) else { return hold(landing, "PR #\(number) was not found on GitHub") }
            pr = read
        } catch {
            return hold(landing, "could not read PR #\(number) on GitHub: \(Store.flat("\(error)", max: 200))")
        }
        if pr.merged { return await mergedUpstream(landing, pr: pr, repo: repo) }
        if !pr.isOpen {
            do {
                try store.closePRLandingUpstream(itemId: item.id, number: number, from: landing.state, sha: landing.pushedSHA, now: clock())
            } catch {
                note("\(item.key): the close of PR #\(number) could not be recorded: \(error)")
            }
            return
        }
        let now = clock()
        if landing.state == .merging {
            return reopenAfterMerge(landing, "the merge of PR #\(number) may not have run (its answer was lost); GitHub reports it not merged")
        }
        let engineMerge: Bool
        do { engineMerge = try store.landing(companyId: landing.companyId).engineMerge } catch {
            return hold(landing, "the company's landing mode could not be read: \(Store.flat("\(error)", max: 200))")
        }
        // The default: the owner merges on GitHub; the landing waits for GitHub to say so.
        guard engineMerge else {
            transition(landing, from: [.mergeable]) { $0.lastPolled = now; $0.lastError = nil }
            return
        }
        // GitHub no longer says the pushed commit can merge: the open step reads its checks and reviews again.
        guard pr.headSHA == landing.pushedSHA, pr.mergeableState == "clean" else {
            transition(landing, from: [.mergeable]) { $0.state = .open; $0.lastPolled = now; $0.lastError = nil }
            return
        }
        let card: PRActionCardState
        do { card = try store.prActionCardState(companyId: landing.companyId, itemId: item.id, action: .mergePR, sha: landing.pushedSHA) } catch {
            return hold(landing, "the owner's cards could not be read: \(Store.flat("\(error)", max: 200))")
        }
        if let held = Self.heldByCard(card) { return hold(landing, held) }
        let info: RepoInfo
        do { info = try await github.repo(repo) } catch {
            return hold(landing, "could not read \(repo.owner)/\(repo.name) on GitHub: \(Store.flat("\(error)", max: 200))")
        }
        guard pr.baseRef == info.defaultBranch else {
            return hold(landing, Self.mergeHeldText(number, "its base is \(Store.flat(pr.baseRef, max: 100)), not the default branch "
                                                    + "\(Store.flat(info.defaultBranch, max: 100)); merge it yourself or abandon the landing"))
        }
        guard let method = MergeMethod.preferred(info) else {
            return hold(landing, Self.mergeHeldText(number, "the repository allows no merge method (merge, squash or rebase); "
                                                    + "allow one on GitHub, or merge it yourself"))
        }
        let facts = PRActionDigest.Merge(number: number, head: pr.headSHA, method: method, base: pr.baseRef)
        let action: PRActionRequest
        do {
            action = PRActionRequest(type: .mergePR, companyId: item.companyId, itemId: item.id, payload: nil,
                                     taintedSession: try PushBranchStage.sessionTainted(item, store: store), itemTainted: item.taintedOrigin,
                                     externalInput: false, firstUse: false, repoVisibility: info.visibility)
        } catch {
            return hold(landing, "could not prepare the merge: \(Store.flat("\(error)", max: 200))")
        }
        let cardGate = CardGate(inner: gate, action: .mergePR, itemId: item.id, sha: landing.pushedSHA, repoURL: repo.pushURL, open: nil,
                                merge: facts, approved: card.approval)
        func digest(_ reason: String) -> String {
            PRActionDigest.of(action, reason: reason, sha: landing.pushedSHA, repoURL: repo.pushURL, open: nil, merge: facts)
        }
        let reason: String
        switch await cardGate.decide(action) {
        case .refuse(let rule):
            return hold(landing, rule)
        case .ask(let asked):
            reason = asked
        case .auto:
            // Rule 4 (§8.4.5): irreversible. The machine presses merge only on the owner's approval of exactly this request,
            // whatever the gate answered: the approval the gate's own ask matched, or one for this request asked under rule 4.
            if cardGate.answeredByApproval, let approval = card.approval {
                return await sendMerge(landing, repo, number: number, method: method, approvalAskId: approval.askId)
            }
            reason = GitHubRules.irreversibleMergeText
            if let approval = card.approval, approval.digest == digest(reason) {
                return await sendMerge(landing, repo, number: number, method: method, approvalAskId: approval.askId)
            }
        }
        // GitHub refused exactly this merge for good on the owner's last approval: not asked again until something changes.
        if case .spent(_, let spent) = card, spent == digest(reason) { return }
        let checks: [GitHubCheckRun], reviews: [GitHubReview]
        do {
            checks = try await github.checkRuns(repo, sha: pr.headSHA).filter { $0.headSHA == pr.headSHA }
            reviews = try await github.reviews(repo, number: number)
        } catch {
            return hold(landing, "\(Self.waitingText(reason)) (the checks and reviews for the card could not be read: "
                        + "\(Store.flat("\(error)", max: 160)))")
        }
        fileCard(landing, action: .mergePR, reason: reason, digest: digest(reason), replacing: card,
                 card: PRActionCard.mergePR(item: item, repo: repo, pr: pr, merge: facts, checks: checks, reviews: reviews, reason: reason))
    }

    /// The `PUT`, on the owner's approval `approvalAskId`: `merging` and the approval spent in one write first, so a crash, a lost
    /// answer or any refusal is read back, never merged again on this approval. Not written (moved on, the approval not usable,
    /// a stop) → nothing is sent.
    private func sendMerge(_ landing: PRLanding, _ repo: GitHubRepoRef, number: Int, method: MergeMethod, approvalAskId: String) async {
        guard !PRStep.paused(store, companyId: landing.companyId) else { return }
        do {
            guard try store.startPRMerge(itemId: landing.itemId, sha: landing.pushedSHA, approvalAskId: approvalAskId, now: clock()) else { return }
        } catch {
            return hold(landing, "the merge could not be recorded: \(Store.flat("\(error)", max: 200))")
        }
        var sent = landing
        sent.state = .merging
        let result: GitHubMergeResult
        do {
            result = try await github.mergePR(repo, number: number, MergePullRequest(sha: landing.pushedSHA, mergeMethod: method))
        } catch GitHubAPIError.rejected(let status, let message) where status == 409 || status == 405 {
            // 409: the branch is not at the pinned commit any more; 405: GitHub will not merge it now. Never a bypass: back to
            // `open`, read again; another merge needs a fresh card.
            let why = status == 409 ? "the branch moved" : "not mergeable"
            return reopenAfterMerge(sent, "GitHub did not merge PR #\(number) (\(status), \(why)): \(Store.flat(message, max: 200))")
        } catch GitHubAPIError.rejected(let status, let message) {
            // For good: held, the owner told once; the same request is not asked again (its approval stays `spent`).
            transition(sent, from: [.merging]) {
                $0.state = .mergeable
                $0.lastError = Self.mergeHeldText(number, "GitHub refused the merge (\(status)): \(Store.flat(message, max: 200))")
            }
            return
        } catch {
            return await reconcileMerge(sent, repo, number, why: Store.flat("\(error)", max: 160))
        }
        guard result.merged else { return await reconcileMerge(sent, repo, number, why: "GitHub answered without merging") }
        // The head was pinned (`sha`) and the base checked against the default branch read in this pass: what merged is the
        // pushed commit, into the default branch; the merge commit is GitHub's answer.
        guard Self.isSHA(result.sha) else {
            return holdMerged(sent, mergedSHA: nil, "GitHub merged PR #\(number) but reported no merge commit")
        }
        await recordMerged(sent, mergedSHA: result.sha)
    }

    /// A merge whose outcome is unknown: GitHub says. Merged → `mergedUpstream`; not merged → back to `open` (the approval is
    /// spent: a fresh card asks before any other merge); unreadable → still `merging` (read again later, never merged again blind).
    private func reconcileMerge(_ sent: PRLanding, _ repo: GitHubRepoRef, _ number: Int, why: String) async {
        do {
            guard let pr = try await github.pull(repo, number: number) else {
                return hold(sent, "the merge of PR #\(number) may have run (\(why)), and GitHub did not find the PR; it is read again, "
                            + "never merged again blind")
            }
            if pr.merged { return await mergedUpstream(sent, pr: pr, repo: repo) }
            reopenAfterMerge(sent, "the merge of PR #\(number) may not have run (\(why)); GitHub reports it not merged")
        } catch {
            hold(sent, "the merge of PR #\(number) may have run (\(why)); GitHub could not be read (\(Store.flat("\(error)", max: 120))); "
                 + "it is read again, never merged again blind")
        }
    }

    /// A merge that did not happen goes back to `open`; its spent approval is forgotten (the next `clean` asks on a fresh card).
    private func reopenAfterMerge(_ landing: PRLanding, _ why: String) {
        do { try store.forgetSpentMergeCard(itemId: landing.itemId, sha: landing.pushedSHA) } catch {
            note("\(landing.itemId): a spent merge approval could not be forgotten: \(error)")
        }
        let now = clock()
        transition(landing, from: [.merging]) { $0.state = .open; $0.lastPolled = now; $0.lastError = why }
    }

    /// PRStep's way in (a merged PR seen while reading an open landing's status): one pass at a time per item.
    func mergedOnGitHub(_ landing: PRLanding, pr: GitHubPR) async {
        guard busy.insert(landing.itemId).inserted else { return }
        defer { busy.remove(landing.itemId) }
        guard let repo = self.repo(landing.companyId) else { return hold(landing, Self.noRepoText) }
        await mergedUpstream(landing, pr: pr, repo: repo)
    }

    /// GitHub reports the PR merged (by a human, or by the engine's merge whose answer was lost). Recorded as the item's landing
    /// only when GitHub's facts prove it is the commit Brahma verified (Ruling 35, X8-34): the PR's head is the pushed commit, its
    /// base the default branch (read now), and GitHub names a merge commit — the rest of the proof follows the fetch
    /// (`completeStep`). Anything else, or a PR merged after its item was brought back ("merged outside Brahma", X8-32c(c)), is
    /// `merged` and held: the verified commit never recorded as landed, the owner told once.
    private func mergedUpstream(_ landing: PRLanding, pr: GitHubPR, repo: GitHubRepoRef) async {
        let number = pr.number
        if landing.state == .checksFailed || landing.state == .changesRequested {
            return holdMerged(landing, mergedSHA: pr.mergeCommitSHA,
                              "merged outside Brahma: PR #\(number) was merged on GitHub after its item was brought back with GitHub's feedback")
        }
        guard pr.headSHA == landing.pushedSHA else {
            return holdMerged(landing, mergedSHA: pr.mergeCommitSHA, "merged with changes Brahma did not push: PR #\(number)'s head on GitHub was "
                              + "\(Store.flat(String(pr.headSHA.prefix(12)), max: 12)), not the pushed \(landing.pushedSHA.prefix(12))")
        }
        let info: RepoInfo
        do { info = try await github.repo(repo) } catch {
            return hold(landing, "PR #\(number) is merged on GitHub; could not read \(repo.owner)/\(repo.name) to check its base: "
                        + "\(Store.flat("\(error)", max: 160))")
        }
        guard pr.baseRef == info.defaultBranch else {
            return holdMerged(landing, mergedSHA: pr.mergeCommitSHA, "PR #\(number) was merged into \(Store.flat(pr.baseRef, max: 100)), "
                              + "not the default branch \(Store.flat(info.defaultBranch, max: 100))")
        }
        guard let merge = pr.mergeCommitSHA, Self.isSHA(merge) else {
            return holdMerged(landing, mergedSHA: nil, "GitHub reports PR #\(number) merged but names no merge commit")
        }
        await recordMerged(landing, mergedSHA: merge)
    }

    static func isSHA(_ s: String) -> Bool { s.range(of: "^[0-9a-f]{40}$", options: .regularExpression) != nil }

    /// `merged` (compare-and-set on what the pass read), then the item completes once the fetch proves it.
    private func recordMerged(_ landing: PRLanding, mergedSHA: String) async {
        let now = clock()
        guard transition(landing, from: [landing.state], {
            $0.state = .merged; $0.mergedSHA = mergedSHA; $0.lastError = nil; $0.lastPolled = now
        }) else { return }
        do { try store.supersedePendingPRActionCards(itemId: landing.itemId, now: now) } catch {
            note("\(landing.itemId): a pending card of the merged PR could not be superseded: \(error)")
        }
        await completeStep(itemId: landing.itemId)
    }

    /// Merged on GitHub, not proven Brahma's verified commit: `Store.holdMergedPRLanding` (held, item back, the owner told once).
    private func holdMerged(_ landing: PRLanding, mergedSHA: String?, _ why: String) {
        do { try store.holdMergedPRLanding(itemId: landing.itemId, sha: landing.pushedSHA, from: [landing.state], mergedSHA: mergedSHA, why: why, now: clock()) } catch {
            note("\(landing.itemId): the merged PR's hold could not be recorded: \(error)")
        }
    }

    /// A merged landing whose item has not completed (its merge request still handed to the PR), one pass at a time per item.
    public func complete(itemId: String) async {
        guard busy.insert(itemId).inserted else { return }
        defer { busy.remove(itemId) }
        await completeStep(itemId: itemId)
    }

    /// The remote `main` is fetched, then the proof finished (Ruling 35, X8-32c(a), X8-34): not rewound; the merge commit on the
    /// fetched tip; a merge commit with more than one parent carries the pushed commit (a squash or rebase has one parent: the
    /// head match and the commit on main are the proof). Proven → the item completes through the merge queue's own landing
    /// record (`Store.completePRLanding`, on the engine's `Blocking`: it runs git), the method recorded. Not proven → held
    /// (`holdMergedPRLanding`). No fetch wired, or a fetch or check that failed: the landing stays `merged` and says why.
    private func completeStep(itemId: String) async {
        let landing: PRLanding
        do {
            guard let l = try store.prLandingAwaitingCompletion(itemId: itemId) else { return }
            landing = l
        } catch {
            return note("\(itemId): the merged landing could not be read: \(error)")
        }
        guard let remoteMain else { return setMergedStatus(landing, Self.waitingForFetchText) }
        guard let number = landing.prNumber, let merge = landing.mergedSHA, Self.isSHA(merge) else {
            return holdMerged(landing, mergedSHA: landing.mergedSHA, "no merge commit is recorded for the merged pull request")
        }
        let fetched: FetchResult
        do { fetched = try await remoteMain.fetch(companyId: landing.companyId) } catch {
            return setMergedStatus(landing, "PR merged; the remote main fetch failed: \(Store.flat("\(error)", max: 200))")
        }
        if fetched.rewound {
            return holdMerged(landing, mergedSHA: merge, "the remote main was rewritten (now \(fetched.newTip.prefix(12))); PR #\(number)'s "
                              + "merge \(merge.prefix(12)) is not proven on it")
        }
        let parents: [String]
        do {
            guard try await remoteMain.isAncestor(merge, of: fetched.newTip, companyId: landing.companyId) else {
                return holdMerged(landing, mergedSHA: merge, "the fetched remote main (\(fetched.newTip.prefix(12))) does not contain PR "
                                  + "#\(number)'s merge commit \(merge.prefix(12))")
            }
            parents = try await remoteMain.parents(of: merge, companyId: landing.companyId)
            if parents.count > 1, try await !remoteMain.isAncestor(landing.pushedSHA, of: merge, companyId: landing.companyId) {
                return holdMerged(landing, mergedSHA: merge, "PR #\(number)'s merge commit \(merge.prefix(12)) does not carry the pushed "
                                  + "commit \(landing.pushedSHA.prefix(12))")
            }
        } catch {
            return setMergedStatus(landing, "PR merged; the merge could not be checked on the fetched main: \(Store.flat("\(error)", max: 200))")
        }
        let how = parents.count > 1 ? "a merge commit" : "squash or rebase"
        let (store, clock, sha) = (self.store, self.clock, landing.pushedSHA)
        do {
            _ = try await push.blocking.tryRun {
                try store.completePRLanding(itemId: itemId, sha: sha, mergedCommit: merge, number: number, how: how, now: clock())
            }
        } catch {
            return setMergedStatus(landing, "PR merged; the item could not be completed: \(Store.flat("\(error)", max: 200))")
        }
        setMergedStatus(landing, nil)
    }

    private func setMergedStatus(_ landing: PRLanding, _ why: String?) {
        transition(landing, from: [.merged]) { $0.lastError = why }
    }

    // MARK: Owner cards

    /// Why an action waits on its card, or nil when it may go to the gate.
    static func heldByCard(_ card: PRActionCardState) -> String? {
        switch card {
        case .waiting(let reason): waitingText(reason)
        case .declined(let reason): declinedText(reason)
        case .none, .approved, .spent: nil
        }
    }

    /// Files the card for the request the gate asked about. An approved card it replaces (its request no longer matches what
    /// would run) is voided first, so the owner sees the new request on a fresh card.
    private func fileCard(_ landing: PRLanding, action: GitHubActionType, reason: String, digest: String, replacing old: PRActionCardState,
                          card: PRActionCard) {
        do {
            if case .approved(let askId, _) = old { try store.voidPRActionCard(askId: askId, now: clock()) }
            if case .spent(let askId, _) = old { try store.voidPRActionCard(askId: askId, now: clock()) }
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
    /// The repository the action is for (a push's own payload names it too).
    let repoURL: String
    let open: OpenPullRequest?
    /// For `merge-pr`: the PR, head, method and base the merge would use (Task 5).
    let merge: PRActionDigest.Merge?
    let approved: (askId: String, digest: String)?
    private let lock = NSLock()
    private var lastAsk: String?
    private var answered = false

    init(inner: any PRActionGate, action: GitHubActionType, itemId: String, sha: String, repoURL: String, open: OpenPullRequest?,
         merge: PRActionDigest.Merge? = nil, approved: (askId: String, digest: String)?) {
        self.inner = inner; self.action = action; self.itemId = itemId; self.sha = sha; self.repoURL = repoURL; self.open = open
        self.merge = merge; self.approved = approved
    }

    /// The digest of the last ask about this action of this item.
    var askedDigest: String? { lock.withLock { lastAsk } }
    /// The last `auto` was the owner's approval answering the inner gate's ask (not the inner gate's own `auto`).
    var answeredByApproval: Bool { lock.withLock { answered } }

    func decide(_ r: PRActionRequest) async -> PRActionDecision {
        let decision = await inner.decide(r)
        guard case .ask(let reason) = decision, r.type == action, r.itemId == itemId else { return decision }
        let digest = PRActionDigest.of(r, reason: reason, sha: sha, repoURL: repoURL, open: open, merge: merge)
        lock.withLock { lastAsk = digest }
        if let approved, approved.digest == digest {
            lock.withLock { answered = true }
            return .auto
        }
        return decision
    }
}
