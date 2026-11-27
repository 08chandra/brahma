import Foundation

/// The PR landings' periodic step (Plan X8 Task 4; spec §8.5.1 steps 3–4). Each `tick`, every open landing that is due (one
/// pass per landing every `interval`, longer after an error) gets one pass:
/// - `pushing`, `pushed`, `opening`: Task 3's `PRLandingMachine.advance` (push, then open the PR, reconciling first);
/// - `open`: the PR's status — `GET /pulls/{n}` (`mergeable_state`), the check runs on the pushed commit and the reviews. A
///   check on the head that concluded `failure`, `timed_out`, `cancelled` or `action_required` → `checksFailed`; else a
///   review requesting changes that may send the item back (Ruling 33, `bouncing`: made on the pushed commit, by a login on
///   the owner's trust list or by the repository's `OWNER`/`MEMBER`/`COLLABORATOR`) → `changesRequested`; both bring the item
///   back to its owner agent with GitHub's feedback (`PRFeedback`, `Store.returnPRFeedback`) while the landing stays open —
///   the agent's resubmit reaches `begin` again through the merge queue and the verified commit is pushed to the same branch
///   (never `--force`; the same commit reopens the landing). Else `mergeable_state == "clean"` → `mergeable`. "Required" is
///   GitHub's word, never read from branch protection (X8 reads none): `clean` means every required check and review is
///   satisfied. Otherwise the open landing records what it waits for (`isStatus`): a re-review by someone whose request for
///   changes is on an older commit, its base (`behind`), its conflicts (`dirty`), or — `blocked` with every check green — a
///   required review (GitHub gives no count without a protection read). An outsider's request for changes never sends the
///   item back (GitHub's protection still decides whether the PR can merge).
///   Not read: legacy commit statuses (`GET /commits/{ref}/status`). A repository whose required checks are statuses shows no
///   failing check runs; its `blocked` reads as waiting for a review — an X4 follow-up.
/// - `checksFailed`, `changesRequested`, `mergeable`: watched for a close upstream (`closedUpstream`, the owner agent told);
///   merging is Tasks 5–6.
///
/// "Paused" holds everything — no GitHub call, no state change: the owner's stop, a paused company, or a merge hold that does
/// not lift itself (`Store.liftsItself`); it is checked before each landing and again right before feedback is written. A
/// GitHub error or any hold recorded by a pass backs the landing off (`firstBackoff`, doubling to `maxBackoff`; in memory, as
/// the merge queue's) with its state kept and `lastError` saying why; an owner card being waited on is polled at the normal
/// interval. A hold for good (`isDurableHold`: a push or open GitHub refused, a PR Brahma did not open on the branch, the
/// branch moved outside Brahma) is retried only every `maxBackoff` and raises ONE owner alert per (item, commit)
/// (`Store.raisePRHoldAlert`, naming `brahma merge abandon-pr`); the alert resolves once the landing moves on. Every write is
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
    static let reReviewPrefix = "waiting for re-review by "
    static let behindText = "behind its base — update needed"
    static let conflictsText = "has conflicts"
    static let headMovedSuffix = "the branch moved outside Brahma"

    /// How a pass went.
    enum Outcome { case ok, retry, durable(String) }

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
                let outcome = await pass(landing, now: now)
                record(landing.itemId, outcome, now: now)
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

    /// Schedules the landing's next pass, raises the hold alert of a hold for good, and resolves it once the landing moved on.
    private func record(_ itemId: String, _ outcome: Outcome, now: Date) {
        let current: PRLanding?
        do { current = try store.prLanding(itemId: itemId) } catch {
            note("\(itemId): the landing could not be read: \(error)")
            current = nil
        }
        switch outcome {
        case .ok:
            backoff[itemId] = nil
            due[itemId] = now.addingTimeInterval(Self.interval)
        case .retry:
            let delay = backoff[itemId].map { min($0 * 2, Self.maxBackoff) } ?? Self.firstBackoff
            backoff[itemId] = delay
            due[itemId] = now.addingTimeInterval(delay)
            return   // a passing error says nothing about a hold for good
        case .durable(let why):
            backoff[itemId] = Self.maxBackoff
            due[itemId] = now.addingTimeInterval(Self.maxBackoff)
            guard let current else { return }
            do { try store.raisePRHoldAlert(itemId: itemId, sha: current.pushedSHA, why: why, now: now) } catch {
                note("\(itemId): the hold alert could not be raised: \(error)")
            }
            return
        }
        // Not held for good any more (moved on, or another commit): its alerts resolve.
        guard current != nil else { return }
        do { try store.resolvePRHoldAlerts(itemId: itemId, now: now) } catch {
            note("\(itemId): the hold alert could not be resolved: \(error)")
        }
    }

    /// One pass over one landing.
    private func pass(_ landing: PRLanding, now: Date) async -> Outcome {
        switch landing.state {
        case .pushing, .pushed, .opening:
            await machine.advance(itemId: landing.itemId)
            let after: PRLanding?
            do { after = try store.prLanding(itemId: landing.itemId) } catch {
                note("\(landing.itemId): the landing could not be read: \(error)")
                return .retry
            }
            // The machine clears `lastError` on every step that moved; one it records is a refusal, a failure or a hold.
            guard let after, after.state.isOpen, let why = after.lastError else { return .ok }
            if why.hasPrefix(PRLandingMachine.waitingText("")) { return .ok }
            return Self.isDurableHold(why) ? .durable(why) : .retry
        case .open, .checksFailed, .changesRequested, .mergeable:
            return await statusStep(landing, now: now)
        default:
            return .ok
        }
    }

    /// A hold no retry soon will lift: GitHub refused the push (`[rejected]`, `[remote rejected]`: the branch moved, a
    /// protection hook) or the open-pr (`GitHub refused`), a PR Brahma did not open is on the branch, the branch moved outside
    /// Brahma.
    static func isDurableHold(_ why: String) -> Bool {
        why.contains("[rejected]") || why.contains("[remote rejected]") || why.hasPrefix("GitHub refused")
            || why.hasPrefix("a pull request Brahma did not open") || why.hasSuffix(headMovedSuffix)
    }

    /// The statuses an open landing records in `lastError` while it waits on GitHub (not errors: polled at the normal interval).
    static func isStatus(_ why: String) -> Bool {
        why == waitingForReviewText || why.hasPrefix(reReviewPrefix) || why == behindText || why == conflictsText
    }

    // MARK: Status

    private func statusStep(_ landing: PRLanding, now: Date) async -> Outcome {
        guard let number = landing.prNumber else { return .ok }   // nothing on GitHub to read yet
        // An open landing records why it waits; one already brought back keeps its status line (the error is logged).
        func failed(_ why: String) -> Outcome {
            guard landing.state == .open else {
                note("\(landing.itemId): \(why)")
                return .retry
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
                return .retry
            }
            return .ok
        }
        // Already brought back or mergeable: nothing more to read until the owner agent resubmits (or the merge step runs).
        guard landing.state == .open else { return touch(landing, now: now, lastError: landing.lastError) }
        guard pr.headSHA == landing.pushedSHA else {
            let why = "PR #\(number)'s head on GitHub is \(pr.headSHA.prefix(7)), not the pushed \(landing.pushedSHA.prefix(7)): " + Self.headMovedSuffix
            transition(landing) { $0.lastError = why }
            return .durable(why)
        }
        let checks: [GitHubCheckRun], reviews: [GitHubReview], trust: TrustList
        do {
            checks = try await github.checkRuns(repo, sha: landing.pushedSHA).filter { $0.headSHA == landing.pushedSHA }
            reviews = try await github.reviews(repo, number: number)
        } catch {
            return hold(landing, "could not read the checks and reviews of PR #\(number) on GitHub: \(Store.flat("\(error)", max: 200))")
        }
        do { trust = TrustList(logins: try store.trustedLogins(companyId: landing.companyId).map(\.login)) } catch {
            return hold(landing, "the trusted logins could not be read: \(Store.flat("\(error)", max: 200))")
        }
        let failing = checks.filter(\.isFailing)
        let requested = Self.changesRequested(reviews)
        let bouncing = Self.bouncing(requested, head: landing.pushedSHA, trust: trust)
        if !failing.isEmpty || !bouncing.isEmpty {
            return bringBack(landing, number: number, pr: pr, failing: failing, requested: bouncing, reviews: reviews, trust: trust, now: now)
        }
        if pr.mergeableState == "clean" {
            transition(landing) { $0.state = .mergeable; $0.lastError = nil; $0.lastPolled = now }
            return .ok
        }
        // Waiting on GitHub: the first that applies.
        let stale = requested.filter { Self.mayBounce($0, trust: trust) && $0.commitId != landing.pushedSHA }
        let status: String?
        if !stale.isEmpty {
            status = Self.reReviewPrefix + stale.map { "@" + PRFeedback.shownName($0.user.login) }.joined(separator: ", ")
        } else if pr.mergeableState == "behind" {
            status = Self.behindText
        } else if pr.mergeableState == "dirty" {
            status = Self.conflictsText
        } else if pr.mergeableState == "blocked" && checks.allSatisfy(\.isGreen) {
            status = Self.waitingForReviewText
        } else {
            status = nil
        }
        return touch(landing, now: now, lastError: status)
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

    /// Ruling 33: a review may send the item back only when its author is on the owner's trust list or is the repository's
    /// `OWNER`, `MEMBER` or `COLLABORATOR` — on a public repository anyone can review.
    static func mayBounce(_ review: GitHubReview, trust: TrustList) -> Bool {
        trust.isTrusted(login: review.user.login) || GitHubReview.repositoryAssociations.contains(review.authorAssociation)
    }

    /// Ruling 33: of the requests for changes (`changesRequested`), those that send the item back now — made on the pushed
    /// commit (`head`) by an author who `mayBounce`. One on an older commit waits for a re-review instead.
    static func bouncing(_ requested: [GitHubReview], head: String, trust: TrustList) -> [GitHubReview] {
        requested.filter { $0.commitId == head && mayBounce($0, trust: trust) }
    }

    /// `checksFailed` (any failing check) or `changesRequested`: the feedback — the failing checks, the reviews sending it back
    /// and the comments on the pushed commit by authors who `mayBounce` — goes back with the item.
    private func bringBack(_ landing: PRLanding, number: Int, pr: GitHubPR, failing: [GitHubCheckRun], requested: [GitHubReview],
                           reviews: [GitHubReview], trust: TrustList, now: Date) -> Outcome {
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
            requested.contains { $0.id == review.id }
                || (review.state == "COMMENTED" && review.commitId == landing.pushedSHA && !review.body.isEmpty && Self.mayBounce(review, trust: trust))
        }
        let written: Bool
        do {
            _ = try store.redact("")   // loads the redactor if it has not (fail closed: `make` refuses an unloaded one)
            let message = try PRFeedback.make(checks: failing, reviews: comments, trust: trust, redactor: store.redactor)
            // A stop, a pause or a hold that came while GitHub was read: nothing is written.
            guard !paused(companyId: landing.companyId) else { return .ok }
            written = try store.returnPRFeedback(itemId: landing.itemId, number: number, from: landing.state, sha: landing.pushedSHA, to: state,
                                                 status: status, detail: detail, feedback: message, now: now)
        } catch {
            return hold(landing, "PR #\(number): GitHub's feedback could not be brought back: \(Store.flat("\(error)", max: 200))")
        }
        guard !written else { return .ok }
        // Nothing written: the landing moved on meanwhile (the next pass reads it anew), or no merge request is handed to this PR.
        return hold(landing, "PR #\(number): no merge request is handed to this pull request for \(landing.pushedSHA.prefix(7)); "
                    + "GitHub's feedback was not brought back")
    }

    // MARK: Records

    /// Keeps the state, records why; backs off.
    private func hold(_ landing: PRLanding, _ why: String) -> Outcome {
        transition(landing) { $0.lastError = why }
        return .retry
    }

    /// A good read: `lastPolled`, and `lastError` as given (a good read clears an earlier read error).
    private func touch(_ landing: PRLanding, now: Date, lastError: String?) -> Outcome {
        transition(landing) { $0.lastPolled = now; $0.lastError = lastError }
        return .ok
    }

    /// Compare-and-set on the state and commit this pass read (`Store.casPRLanding`): a landing that moved on meanwhile is not
    /// written (the next pass reads it anew).
    @discardableResult
    private func transition(_ landing: PRLanding, _ change: (inout PRLanding) -> Void) -> Bool {
        do {
            return try store.casPRLanding(itemId: landing.itemId, from: [landing.state], sha: landing.pushedSHA, now: machine.clock(), change)
        } catch {
            note("\(landing.itemId): the landing could not be recorded: \(error)")
            return false
        }
    }

    private nonisolated func note(_ text: String) {
        FileHandle.standardError.write(Data("brahma PR step: \(text)\n".utf8))
    }
}
