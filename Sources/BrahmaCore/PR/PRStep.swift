import Foundation

/// The PR landings' periodic step (Plan X8 Task 4; spec §8.5.1 steps 3–4). Each `tick`, every open landing that is due (one
/// pass per landing every `interval`, longer after an error) gets one pass:
/// - `pushing`, `pushed`, `opening`: Task 3's `PRLandingMachine.advance` (push, then open the PR, reconciling first);
/// - `open`: the PR's status — `GET /pulls/{n}` (`mergeable_state`), the check runs on the pushed commit and the reviews. A
///   check on the head that concluded `failure`, `timed_out`, `cancelled` or `action_required` → `checksFailed`; else a
///   reviewer whose latest decisive review requests changes → `changesRequested`; both bring the item back to its owner agent
///   with GitHub's feedback (`PRFeedback`, `Store.returnPRFeedback`) while the landing stays open — the agent's resubmit
///   reaches `begin` again through the merge queue and the new verified commit is pushed to the same branch (no `--force`).
///   Else `mergeable_state == "clean"` → `mergeable`. "Required" is GitHub's word, never read from branch protection (X8 reads
///   none): `clean` means every required check and review is satisfied; `blocked` with every check green and nothing
///   requested is recorded as waiting for a required review (GitHub gives no count without a protection read).
/// - `checksFailed`, `changesRequested`, `mergeable`: watched for a close upstream (`closedUpstream`, the owner agent told);
///   merging is Tasks 5–6.
///
/// "Paused" holds everything — no GitHub call, no state change: the owner's stop, a paused company, or a merge hold that does
/// not lift itself (`Store.liftsItself`). A GitHub error, a definitive rejection (a refused push or open) or any other hold
/// recorded by a pass backs the landing off (`firstBackoff`, doubling to `maxBackoff`; in memory, as the merge queue's) with
/// its state kept and `lastError` saying why; an owner card being waited on is polled at the normal interval. Every write is
/// a compare-and-set on what the pass read (`Store.casPRLanding`, `returnPRFeedback`, `closePRLandingUpstream`).
///
/// Not wired into `Orchestrator.schedule`: the tick needs a production `GitHubAPI`, and there is none on this tree (PR mode is
/// dormant; X4's channel core wires it, after the merge step).
public actor PRStep {
    /// Seconds between two passes over one landing.
    public static let interval: TimeInterval = 60
    /// The first back-off after a failed pass; it doubles per failure, up to `maxBackoff`.
    public static let firstBackoff: TimeInterval = 120
    public static let maxBackoff: TimeInterval = 1800
    /// `lastError` of an open landing that waits for a review (`brahma why`: "PR #n waiting for a required review").
    public static let waitingForReviewText = "waiting for a required review"

    let store: Store
    let machine: PRLandingMachine
    /// When each landing is next due, and its current back-off.
    private var due: [String: Date] = [:]
    private var backoff: [String: TimeInterval] = [:]
    private var ticking = false

    public init(store: Store, machine: PRLandingMachine) {
        self.store = store; self.machine = machine
    }

    var github: any GitHubAPI { machine.github }

    /// One step: every due landing of every company not paused, oldest update first.
    public func tick(now: Date) async {
        guard !ticking else { return }
        ticking = true
        defer { ticking = false }
        let companies: [Company]
        do { companies = try store.companies() } catch {
            return note("the companies could not be read: \(error)")
        }
        var open = Set<String>()
        for company in companies {
            let landings: [PRLanding]
            do { landings = try store.openPRLandings(companyId: company.id) } catch {
                note("\(company.name): the landings could not be read: \(error)")
                continue
            }
            open.formUnion(landings.map(\.itemId))
            for landing in landings where (due[landing.itemId] ?? .distantPast) <= now {
                // Re-read every time: a stop, a pause or a hold that came during this tick holds the rest of it.
                guard !paused(companyId: company.id) else { break }
                let ok = await pass(landing, now: now)
                schedule(landing.itemId, ok: ok, now: now)
            }
        }
        due = due.filter { open.contains($0.key) }
        backoff = backoff.filter { open.contains($0.key) }
    }

    /// The owner's stop, a paused company, or a merge hold that does not lift itself. A read that fails counts as paused.
    func paused(companyId: String) -> Bool {
        do {
            if try store.engineStopped() != nil { return true }
            guard let company = try store.company(id: companyId) else { return true }
            return company.status != .running || (company.mergeHold != nil && !Store.liftsItself(company.mergeHold))
        } catch {
            note("company \(companyId): the stop and hold could not be read (held): \(error)")
            return true
        }
    }

    private func schedule(_ itemId: String, ok: Bool, now: Date) {
        if ok {
            backoff[itemId] = nil
            due[itemId] = now.addingTimeInterval(Self.interval)
        } else {
            let delay = backoff[itemId].map { min($0 * 2, Self.maxBackoff) } ?? Self.firstBackoff
            backoff[itemId] = delay
            due[itemId] = now.addingTimeInterval(delay)
        }
    }

    /// One pass over one landing; false backs it off.
    private func pass(_ landing: PRLanding, now: Date) async -> Bool {
        switch landing.state {
        case .pushing, .pushed, .opening:
            await machine.advance(itemId: landing.itemId)
            let after: PRLanding?
            do { after = try store.prLanding(itemId: landing.itemId) } catch {
                note("\(landing.itemId): the landing could not be read: \(error)")
                return false
            }
            // The machine clears `lastError` on every step that moved; one it records is a refusal, a failure or a hold.
            guard let after, after.state.isOpen, let why = after.lastError else { return true }
            return why.hasPrefix(PRLandingMachine.waitingText(""))
        case .open, .checksFailed, .changesRequested, .mergeable:
            return await statusStep(landing, now: now)
        default:
            return true
        }
    }

    // MARK: Status

    private func statusStep(_ landing: PRLanding, now: Date) async -> Bool {
        guard let number = landing.prNumber else { return true }   // nothing on GitHub to read yet
        // An open landing records why it waits; one already brought back keeps its status line (the error is logged).
        func failed(_ why: String) -> Bool {
            guard landing.state == .open else {
                note("\(landing.itemId): \(why)")
                return false
            }
            return hold(landing, why)
        }
        guard let repo = machine.repo(landing.companyId) else { return failed(PRLandingMachine.noRepoText) }
        let pr: GitHubPR
        do {
            guard let read = try await github.pull(repo, number: number) else { return failed("PR #\(number) was not found on GitHub") }
            pr = read
        } catch {
            return failed("could not read PR #\(number) on GitHub: \(Store.flat("\(error)", max: 200))")
        }
        if !pr.isOpen {
            guard !pr.merged else { return touch(landing, now: now, lastError: landing.lastError) }   // the merge step's (Tasks 5–6)
            do {
                try store.closePRLandingUpstream(itemId: landing.itemId, number: number, from: landing.state, sha: landing.pushedSHA, now: now)
            } catch {
                note("\(landing.itemId): the close of PR #\(number) could not be recorded: \(error)")
                return false
            }
            return true
        }
        // Already brought back or mergeable: nothing more to read until the owner agent resubmits (or the merge step runs).
        guard landing.state == .open else { return touch(landing, now: now, lastError: landing.lastError) }
        guard pr.headSHA == landing.pushedSHA else {
            return hold(landing, "PR #\(number)'s head on GitHub is \(pr.headSHA.prefix(7)), not the pushed \(landing.pushedSHA.prefix(7)): "
                        + "the branch moved outside Brahma")
        }
        let checks: [GitHubCheckRun], reviews: [GitHubReview]
        do {
            checks = try await github.checkRuns(repo, sha: landing.pushedSHA).filter { $0.headSHA == landing.pushedSHA }
            reviews = try await github.reviews(repo, number: number)
        } catch {
            return hold(landing, "could not read the checks and reviews of PR #\(number) on GitHub: \(Store.flat("\(error)", max: 200))")
        }
        let failing = checks.filter(\.isFailing)
        let requested = Self.changesRequested(reviews)
        if !failing.isEmpty || !requested.isEmpty {
            return bringBack(landing, number: number, pr: pr, failing: failing, requested: requested, reviews: reviews, now: now)
        }
        if pr.mergeableState == "clean" {
            return transition(landing) { $0.state = .mergeable; $0.lastError = nil; $0.lastPolled = now }
        }
        let waitingForReview = pr.mergeableState == "blocked" && checks.allSatisfy(\.isGreen)
        return touch(landing, now: now, lastError: waitingForReview ? Self.waitingForReviewText : nil)
    }

    /// The reviews that request changes now: per reviewer (logins compared as `TrustList` does), the latest decisive one
    /// (`APPROVED`, `CHANGES_REQUESTED`, `DISMISSED`), when it is `CHANGES_REQUESTED`. Oldest first.
    static func changesRequested(_ reviews: [GitHubReview]) -> [GitHubReview] {
        var latest: [String: GitHubReview] = [:]
        for review in reviews.sorted(by: { $0.id < $1.id }) where ["APPROVED", "CHANGES_REQUESTED", "DISMISSED"].contains(review.state) {
            latest[TrustList.normalize(review.user.login)] = review
        }
        return latest.values.filter { $0.state == "CHANGES_REQUESTED" }.sorted { $0.id < $1.id }
    }

    /// `checksFailed` (any failing check) or `changesRequested`: the feedback — the failing checks, the reviews requesting
    /// changes and the comments on the pushed commit — goes back with the item.
    private func bringBack(_ landing: PRLanding, number: Int, pr: GitHubPR, failing: [GitHubCheckRun], requested: [GitHubReview],
                           reviews: [GitHubReview], now: Date) -> Bool {
        let state: PRLandingState = failing.isEmpty ? .changesRequested : .checksFailed
        let status: String
        if let first = failing.first {
            let kind = pr.mergeableState == "blocked" ? "required check" : "check"
            let more = failing.count > 1 ? " and \(failing.count - 1) more" : ""
            status = "\(kind) \"\(PRFeedback.shownName(first.name))\"\(more) failing (brought back as feedback)"
        } else {
            status = "changes requested by \(requested.map { "@" + PRFeedback.shownName($0.user.login) }.joined(separator: ", ")) (brought back as feedback)"
        }
        let detail = "PR #\(number) on GitHub: \(state == .checksFailed ? "a check failed" : "a reviewer requested changes"). "
            + "GitHub's feedback is in the item's PR feedback. Fix it and submit again: the new commit updates the same pull request."
        let comments = reviews.filter { review in
            requested.contains { $0.id == review.id } || (review.state == "COMMENTED" && review.commitId == landing.pushedSHA && !review.body.isEmpty)
        }
        do {
            _ = try store.redact("")   // loads the redactor if it has not (fail closed: `make` refuses an unloaded one)
            let trust = TrustList(logins: try store.trustedLogins(companyId: landing.companyId).map(\.login))
            let message = try PRFeedback.make(checks: failing, reviews: comments, trust: trust, redactor: store.redactor)
            return try store.returnPRFeedback(itemId: landing.itemId, number: number, from: landing.state, sha: landing.pushedSHA, to: state,
                                              status: status, detail: detail, feedback: message, now: now)
        } catch {
            return hold(landing, "PR #\(number): GitHub's feedback could not be brought back: \(Store.flat("\(error)", max: 200))")
        }
    }

    // MARK: Records

    /// Keeps the state, records why; false (backs off).
    private func hold(_ landing: PRLanding, _ why: String) -> Bool {
        transition(landing) { $0.lastError = why }
        return false
    }

    /// A good read: `lastPolled`, and `lastError` as given (a good read clears an earlier read error).
    private func touch(_ landing: PRLanding, now: Date, lastError: String?) -> Bool {
        transition(landing) { $0.lastPolled = now; $0.lastError = lastError }
        return true
    }

    /// Compare-and-set on the state and commit this pass read (`Store.casPRLanding`); true unless the write failed (a landing
    /// that moved on meanwhile is no error: the next pass reads it anew).
    @discardableResult
    private func transition(_ landing: PRLanding, _ change: (inout PRLanding) -> Void) -> Bool {
        do {
            try store.casPRLanding(itemId: landing.itemId, from: [landing.state], sha: landing.pushedSHA, now: machine.clock(), change)
            return true
        } catch {
            note("\(landing.itemId): the landing could not be recorded: \(error)")
            return false
        }
    }

    private nonisolated func note(_ text: String) {
        FileHandle.standardError.write(Data("brahma PR step: \(text)\n".utf8))
    }
}
