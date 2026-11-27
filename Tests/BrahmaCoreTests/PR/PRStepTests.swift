import Foundation
import Testing
import GRDB
@testable import BrahmaCore

/// The PR step (Plan X8 Task 4, spec §8.5.1 step 4): every `PRStep.interval` it reads each open landing's pull request, its
/// check runs and its reviews; `clean` → `mergeable`; a failing check or a request for changes returns the item to its owner
/// agent as feedback while the landing stays open; GitHub errors back off; a paused company, a held queue or the owner's stop
/// hold everything.
@Suite(.scratch, .serialized) struct PRStepTests {
    typealias World = PRLandingMachineTests.World
    static let repo = PRLandingMachineTests.repo
    static let t0 = Date(timeIntervalSince1970: 1_900_000_000)

    /// The item is approved and its merge request was handed to a PR (what the queue leaves: In review, verifying).
    static func inReview(_ store: Store, _ item: WorkItem) throws {
        try store.writer.write { db in
            try db.execute(sql: "UPDATE workItem SET status = 'inReview', mergeState = 'verifying', verifiedCommit = 'x' WHERE id = ?",
                           arguments: [item.id])
        }
    }

    /// An open PR for a fresh item (protection as given), its item In review.
    static func openPR(_ w: World, _ title: String, protection: FakeGitHub.Protection = .init(requiredChecks: ["ci"])) async throws -> (WorkItem, String) {
        w.github.update(repo) { $0.protection = protection }
        let (item, sha) = try w.handedOff(title, ["\(title.count)-\(UUID().uuidString.prefix(6)).txt": "\(title)\n"])
        try inReview(w.store, item)
        await w.machine.begin(item: item, verifiedSHA: sha)
        #expect(try w.landing(item).state == .open)
        return (item, sha)
    }

    /// A synchronous write (the async `write` overload is picked inside async tests).
    static func execute(_ store: Store, _ sql: String, _ arguments: StatementArguments) throws {
        try store.writer.write { db in try db.execute(sql: sql, arguments: arguments) }
    }

    static func setStatus(_ store: Store, _ companyId: String, _ status: CompanyStatus) throws {
        try store.writer.write { db in try db.execute(sql: "UPDATE company SET status = ? WHERE id = ?", arguments: [status.rawValue, companyId]) }
    }

    static func notices(_ store: Store, _ item: WorkItem, kind: WorkEventKind) throws -> [Row] {
        try store.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT n.agentId, n.wakes, e.text, e.taintedOrigin FROM workNotice n JOIN workItemEvent e ON e.id = n.eventId
                WHERE e.itemId = ? AND e.kind = ?
                """, arguments: [item.id, kind.rawValue])
        }
    }

    static func request(_ store: Store, _ item: WorkItem) throws -> MergeRequest? {
        try store.writer.read { db in try MergeRequest.filter(Column("itemId") == item.id).order(Column("number").desc).fetchOne(db) }
    }

    @Test func cleanBecomesMergeable() async throws {
        let w = try World()
        let step = PRStep(store: w.store, machine: w.machine)
        let (item, sha) = try await Self.openPR(w, "Green")
        // The required check is still running: the landing stays open, nothing comes back.
        w.github.update(Self.repo) { $0.checkRuns = [.init(name: "ci", headSHA: sha, conclusion: nil, status: "in_progress")] }
        await step.tick(now: Self.t0)
        var landing = try w.landing(item)
        #expect(landing.state == .open && landing.lastError == nil && landing.lastPolled != nil, "\(landing)")
        #expect(w.github.requests.contains("GET /repos/acme/app/commits/\(sha)/check-runs"))
        #expect(w.github.requests.contains("GET /repos/acme/app/pulls/1/reviews"))
        // Green, but not due before the interval.
        w.github.update(Self.repo) { $0.checkRuns = [.init(name: "ci", headSHA: sha, conclusion: "success")] }
        let calls = w.github.requests.count
        await step.tick(now: Self.t0.addingTimeInterval(1))
        #expect(try w.github.requests.count == calls && w.landing(item).state == .open)
        await step.tick(now: Self.t0.addingTimeInterval(PRStep.interval))
        landing = try w.landing(item)
        #expect(landing.state == .mergeable && landing.lastError == nil, "\(landing)")
        #expect(try w.store.workItem(id: item.id)?.status == .inReview, "a mergeable PR returns nothing")
        #expect(try w.store.itemEvents(itemId: item.id).allSatisfy { $0.kind != .prFeedback })
    }

    /// Blocked with every check green and nothing requested: the landing waits for a review, and `brahma why` says so; an
    /// approval at the head makes it mergeable.
    @Test func waitingForReviewIsNamed() async throws {
        let w = try World()
        let step = PRStep(store: w.store, machine: w.machine)
        let (item, sha) = try await Self.openPR(w, "Needs review", protection: .init(requiredChecks: ["ci"], requiredReviews: 1))
        w.github.update(Self.repo) { $0.checkRuns = [.init(name: "ci", headSHA: sha, conclusion: "success")] }
        await step.tick(now: Self.t0)
        #expect(try w.landing(item).state == .open && w.landing(item).lastError == PRStep.waitingForReviewText)
        let reasons = try w.store.stallReport(companyId: w.env.company.id).reasons
        #expect(reasons.contains("@eng-1 waits: PR #1 waiting for a required review"), "\(reasons)")
        w.github.update(Self.repo) { $0.pulls[0].reviews = [.init(user: "maintainer", state: "APPROVED", commitId: sha)] }
        await step.tick(now: Self.t0.addingTimeInterval(PRStep.interval))
        #expect(try w.landing(item).state == .mergeable)
        #expect(try w.store.stallReport(companyId: w.env.company.id).reasons.allSatisfy { !$0.contains("PR #1") })
    }

    /// A required check failed: the item goes back to In progress for its owner agent with GitHub's feedback (a waking notice),
    /// its merge request is bounced (no lockout left), and the landing stays open and watched. The feedback comes once.
    @Test func failedCheckReturnsItem() async throws {
        let w = try World()
        let step = PRStep(store: w.store, machine: w.machine)
        let (item, sha) = try await Self.openPR(w, "Red check")
        w.github.update(Self.repo) {
            $0.checkRuns = [.init(name: "ci", headSHA: sha, conclusion: "failure", output: "FAIL testLogin\nexpected 1, got 2"),
                            .init(name: "lint", headSHA: sha, conclusion: "success")]
        }
        await step.tick(now: Self.t0)
        let landing = try w.landing(item)
        #expect(landing.state == .checksFailed && landing.state.isOpen && landing.prNumber == 1, "\(landing)")
        #expect(landing.lastError == "required check \"ci\" failing (brought back as feedback)")
        let back = try #require(try w.store.workItem(id: item.id))
        #expect(back.status == .inProgress && back.mergeState == .none && back.verifiedCommit == nil, "\(back)")
        #expect(try Self.request(w.store, item)?.status == .bounced)
        #expect(try !w.store.isMerging(itemId: item.id))
        let feedback = try Self.notices(w.store, item, kind: .prFeedback)
        #expect(feedback.count == 1 && feedback.first?["agentId"] as String? == w.eng.id && feedback.first?["wakes"] as Bool? == true, "\(feedback)")
        let text = try #require(feedback.first?["text"] as String?)
        #expect(text.hasPrefix("github: PR #1 feedback\n") && text.contains("    | FAIL testLogin") && !text.contains("lint"), "\(text)")
        #expect(feedback.first?["taintedOrigin"] as Bool? == true)
        let returned = try Self.notices(w.store, item, kind: .mergeFailed)
        #expect(returned.count == 1 && (returned.first?["text"] as String?)?.contains("PR #1") == true, "\(returned)")
        #expect((returned.first?["text"] as String?)?.contains("FAIL") == false, "GitHub's text stays out of the engine's notice")
        let reasons = try w.store.stallReport(companyId: w.env.company.id).reasons
        #expect(reasons.contains("@eng-1 waits: PR #1 blocked — required check \"ci\" failing (brought back as feedback)"), "\(reasons)")
        // Later ticks bring nothing back twice; the PR is still watched (a close upstream still ends the landing).
        await step.tick(now: Self.t0.addingTimeInterval(PRStep.interval))
        #expect(try Self.notices(w.store, item, kind: .prFeedback).count == 1)
        #expect(try w.landing(item).state == .checksFailed)
        w.github.update(Self.repo) { $0.pulls[0].state = "closed" }
        await step.tick(now: Self.t0.addingTimeInterval(2 * PRStep.interval))
        #expect(try w.landing(item).state == .closedUpstream)
    }

    @Test func changesRequestedReturnsItem() async throws {
        let w = try World()
        let step = PRStep(store: w.store, machine: w.machine)
        let (item, sha) = try await Self.openPR(w, "Review me", protection: .init(requiredReviews: 1))
        w.github.update(Self.repo) {
            $0.pulls[0].reviews = [.init(user: "rev-bot", state: "CHANGES_REQUESTED", commitId: sha, body: "Please rename `f` to `fetchUser`.",
                                         association: "COLLABORATOR"),
                                   .init(user: "bystander", state: "COMMENTED", commitId: sha, body: "Also add a test.", association: "MEMBER"),
                                   .init(user: "friend", state: "COMMENTED", commitId: "old", body: "stale note", association: "MEMBER"),
                                   .init(user: "drive-by", state: "COMMENTED", commitId: sha, body: "outsider note")]
        }
        await step.tick(now: Self.t0)
        let landing = try w.landing(item)
        #expect(landing.state == .changesRequested && landing.lastError == "changes requested by @rev-bot (brought back as feedback)", "\(landing)")
        #expect(try w.store.workItem(id: item.id)?.status == .inProgress)
        #expect(try Self.request(w.store, item)?.status == .bounced)
        let text = try #require(try Self.notices(w.store, item, kind: .prFeedback).first?["text"] as String?)
        #expect(text.contains("Untrusted content from GitHub review by @rev-bot (CHANGES_REQUESTED)"), "\(text)")
        #expect(text.contains("    | Please rename `f` to `fetchUser`.") && text.contains("    | Also add a test.") && !text.contains("stale note"))
        #expect(!text.contains("outsider note"), "an outsider's comment is not brought back (Ruling 33)")
        let reasons = try w.store.stallReport(companyId: w.env.company.id).reasons
        #expect(reasons.contains("@eng-1 waits: PR #1 blocked — changes requested by @rev-bot (brought back as feedback)"), "\(reasons)")
        // Only a reviewer's latest decisive review counts: changes requested, then approved, is not a request for changes.
        let later = [GitHubReview(id: 1, user: GitHubUser(login: "a"), state: "CHANGES_REQUESTED", body: "x", commitId: sha),
                     GitHubReview(id: 2, user: GitHubUser(login: "A"), state: "COMMENTED", body: "y", commitId: sha),
                     GitHubReview(id: 3, user: GitHubUser(login: "A"), state: "APPROVED", body: "", commitId: sha),
                     GitHubReview(id: 4, user: GitHubUser(login: "b"), state: "APPROVED", body: "", commitId: sha),
                     GitHubReview(id: 5, user: GitHubUser(login: "b"), state: "CHANGES_REQUESTED", body: "z", commitId: sha)]
        #expect(PRStep.changesRequested(later).map(\.id) == [5])
        // Ruling 33: only on the pushed commit, and only by a trusted login or the repository's own people.
        func review(_ id: Int, _ login: String, _ commit: String, _ association: String) -> GitHubReview {
            GitHubReview(id: id, user: GitHubUser(login: login), state: "CHANGES_REQUESTED", body: "", commitId: commit, authorAssociation: association)
        }
        let trust = TrustList(logins: ["Trusted"])
        let candidates = [review(1, "owner-of-repo", sha, "OWNER"), review(2, "member", sha, "MEMBER"), review(3, "collab", sha, "COLLABORATOR"),
                          review(4, "trusted", sha, "NONE"), review(5, "contributor", sha, "CONTRIBUTOR"), review(6, "stranger", sha, "NONE"),
                          review(7, "member-old", "old", "MEMBER")]
        #expect(PRStep.bouncing(candidates, head: sha, trust: trust).map(\.id) == [1, 2, 3, 4])
    }

    /// I1 / Ruling 33: a request for changes on an older commit does not send the resubmitted item back again: the landing
    /// waits for a re-review (named in `brahma why`), and an outsider's request at the head never sends it back at all.
    @Test func staleOrOutsiderReviewDoesNotBounce() async throws {
        let w = try World()
        let step = PRStep(store: w.store, machine: w.machine)
        let (item, sha) = try await Self.openPR(w, "Rereview", protection: .init(requiredReviews: 1))
        w.github.update(Self.repo) {
            $0.pulls[0].reviews = [.init(user: "rev-bot", state: "CHANGES_REQUESTED", commitId: sha, body: "Rename it.", association: "COLLABORATOR")]
        }
        await step.tick(now: Self.t0)
        #expect(try w.landing(item).state == .changesRequested)
        // Fixed and resubmitted: the old review (on the old commit) is still there.
        let fixed = try w.env.commit(["rereview.txt": "renamed\n"])
        try w.handOff(item, fixed)
        try Self.inReview(w.store, item)
        await w.machine.begin(item: item, verifiedSHA: fixed)
        #expect(try w.landing(item).state == .open)
        await step.tick(now: Self.t0.addingTimeInterval(PRStep.interval))
        let landing = try w.landing(item)
        #expect(landing.state == .open && landing.lastError == "waiting for re-review by @rev-bot", "\(landing)")
        #expect(try w.store.workItem(id: item.id)?.status == .inReview, "sent back again by a stale review")
        #expect(try Self.notices(w.store, item, kind: .prFeedback).count == 1)
        #expect(try w.store.stallReport(companyId: w.env.company.id).reasons.contains("@eng-1 waits: PR #1 waiting for re-review by @rev-bot"))
        // An outsider requests changes at the head: not sent back (GitHub's protection still decides whether it can merge).
        let (other, otherSHA) = try await Self.openPR(w, "Outsider", protection: .init(requiredReviews: 1))
        w.github.update(Self.repo) {
            $0.pulls[1].reviews = [.init(user: "stranger", state: "CHANGES_REQUESTED", commitId: otherSHA, body: "Approve my PR instead.")]
        }
        await step.tick(now: Self.t0.addingTimeInterval(2 * PRStep.interval))
        #expect(try w.landing(other).state == .open && w.store.workItem(id: other.id)?.status == .inReview)
        #expect(try Self.notices(w.store, other, kind: .prFeedback).isEmpty)
    }

    /// I2: the item resubmitted with the same verified commit (a check re-run green on GitHub) reopens its landing, which is
    /// read again — not left `checksFailed` with the item locked in review.
    @Test func sameCommitResubmitReopens() async throws {
        let w = try World()
        let step = PRStep(store: w.store, machine: w.machine)
        let (item, sha) = try await Self.openPR(w, "Flaky CI")
        w.github.update(Self.repo) { $0.checkRuns = [.init(name: "ci", headSHA: sha, conclusion: "failure", output: "flake")] }
        await step.tick(now: Self.t0)
        #expect(try w.landing(item).state == .checksFailed)
        w.github.update(Self.repo) { $0.checkRuns = [.init(name: "ci", headSHA: sha, conclusion: "success")] }
        try w.handOff(item, sha)
        try Self.inReview(w.store, item)
        await w.machine.begin(item: item, verifiedSHA: sha)
        #expect(try w.landing(item).state == .open && w.landing(item).lastError == nil)
        #expect(w.runner.pushes.count == 1, "the same commit is not pushed again")
        await step.tick(now: Self.t0.addingTimeInterval(PRStep.interval))
        #expect(try w.landing(item).state == .mergeable)
    }

    /// Fix round 1 minors: `behind` and `dirty` are named in `brahma why`; feedback needs the merge request handed to the PR
    /// (without one nothing is written).
    @Test func behindConflictsAndNoRequest() async throws {
        let w = try World()
        let step = PRStep(store: w.store, machine: w.machine)
        let (item, _) = try await Self.openPR(w, "Behind", protection: .init())
        w.github.update(Self.repo) { $0.pulls[0].mergeableOverride = "behind" }
        await step.tick(now: Self.t0)
        #expect(try w.landing(item).state == .open && w.landing(item).lastError == PRStep.behindText)
        #expect(try w.store.stallReport(companyId: w.env.company.id).reasons.contains("@eng-1 waits: PR #1 behind its base — update needed"))
        w.github.update(Self.repo) { $0.pulls[0].mergeableOverride = "dirty" }
        await step.tick(now: Self.t0.addingTimeInterval(PRStep.interval))
        #expect(try w.store.stallReport(companyId: w.env.company.id).reasons.contains("@eng-1 waits: PR #1 has conflicts"))
        // No merge request handed to the PR (withdrawn): a failing check writes nothing but the hold.
        let (other, otherSHA) = try await Self.openPR(w, "No request")
        try Self.execute(w.store, "UPDATE mergeRequest SET status = 'cancelled' WHERE itemId = ?", [other.id])
        w.github.update(Self.repo) { $0.checkRuns = [.init(name: "ci", headSHA: otherSHA, conclusion: "failure")] }
        await step.tick(now: Self.t0.addingTimeInterval(2 * PRStep.interval))
        let held = try w.landing(other)
        #expect(held.state == .open && held.lastError?.contains("no merge request is handed to this pull request") == true, "\(held)")
        #expect(try Self.notices(w.store, other, kind: .prFeedback).isEmpty)
        #expect(try w.store.workItem(id: other.id)?.status == .inReview)
    }

    static func alerts(_ store: Store) throws -> [Ask] {
        try store.writer.read { db in
            try Ask.filter(Column("kind") == AskKind.engineAlert && Column("subjectId").like("hold:prhold:%")).order(Column("number")).fetchAll(db)
        }
    }

    /// I3: a hold for good — a push GitHub refused, the branch moved outside Brahma — tells the owner once (an engine alert
    /// naming `brahma merge abandon-pr`), is retried only every `maxBackoff`, and the alert resolves when the owner abandons
    /// the landing (the item goes back to its owner agent).
    @Test func durableHoldAlertsTheOwnerOnce() async throws {
        let w = try World()
        let step = PRStep(store: w.store, machine: w.machine)
        let (item, sha) = try w.handedOff("Refused for good", ["f.txt": "f\n"])
        try Self.inReview(w.store, item)
        w.runner.mode = .reject
        try _ = w.store.beginPRLanding(item: item, sha: sha, branch: "brahma/\(item.key)-refused-for-good", now: Self.t0)
        await step.tick(now: Self.t0)
        #expect(w.runner.pushes.count == 1)
        var alerts = try Self.alerts(w.store)
        #expect(alerts.count == 1 && alerts.first?.status == .pendingOwner, "\(alerts)")
        let text = try #require(alerts.first?.summary)
        #expect(text.contains("\(item.key)'s pull request is held. GitHub said: ") && text.contains("rejected"), "\(text)")
        #expect(text.contains("brahma merge abandon-pr \(w.env.company.slug) \(item.key)") && text.contains("never force-pushes"), "\(text)")
        // Not retried before `maxBackoff`; retried then, and still one alert.
        await step.tick(now: Self.t0.addingTimeInterval(PRStep.firstBackoff * 4))
        #expect(w.runner.pushes.count == 1)
        await step.tick(now: Self.t0.addingTimeInterval(PRStep.maxBackoff))
        #expect(w.runner.pushes.count == 2)
        #expect(try Self.alerts(w.store).count == 1)
        // Dismissed by the owner: still never raised again for this commit.
        try Self.execute(w.store, "UPDATE ask SET status = 'answered' WHERE id = ?", [alerts[0].id])
        await step.tick(now: Self.t0.addingTimeInterval(2 * PRStep.maxBackoff))
        #expect(try Self.alerts(w.store).count == 1)
        try Self.execute(w.store, "UPDATE ask SET status = 'pendingOwner' WHERE id = ?", [alerts[0].id])
        // The owner abandons: the item goes back to its owner agent, the alert resolves.
        try w.store.abandonPRLanding(itemId: item.id, reason: "branch moved", by: .owner)
        #expect(try w.store.workItem(id: item.id)?.status == .inProgress)
        #expect(try Self.request(w.store, item)?.status == .bounced)
        alerts = try Self.alerts(w.store)
        #expect(alerts.count == 1 && alerts.first?.status != .pendingOwner, "\(alerts)")

        // The branch moved outside Brahma: held for good, one alert.
        w.runner.mode = .land
        let (moved, movedSHA) = try await Self.openPR(w, "Moved head")
        w.github.update(Self.repo) { $0.pulls[$0.pulls.count - 1].headSHA = "f00d" + String(movedSHA.dropFirst(4)) }
        await step.tick(now: Self.t0.addingTimeInterval(3 * PRStep.maxBackoff))
        await step.tick(now: Self.t0.addingTimeInterval(4 * PRStep.maxBackoff))
        #expect(try w.landing(moved).lastError?.hasSuffix(PRStep.headMovedSuffix) == true)
        #expect(try Self.alerts(w.store).filter { $0.summary.contains(moved.key) }.count == 1)
    }

    /// A GitHub error keeps the state, records why, and the landing is not read again before the back-off; a push GitHub
    /// rejects is not retried every tick either.
    @Test func apiErrorBacksOffAndKeepsState() async throws {
        let w = try World()
        let step = PRStep(store: w.store, machine: w.machine)
        let (item, sha) = try await Self.openPR(w, "Flaky GitHub")
        w.github.update(Self.repo) { $0.checkRuns = [.init(name: "ci", headSHA: sha, conclusion: "failure")] }
        w.github.setDown(true)
        await step.tick(now: Self.t0)
        var landing = try w.landing(item)
        #expect(landing.state == .open && landing.lastError?.hasPrefix("could not read PR #1 on GitHub") == true, "\(landing)")
        #expect(try w.store.workItem(id: item.id)?.status == .inReview)
        w.github.setDown(false)
        let calls = w.github.requests.count
        await step.tick(now: Self.t0.addingTimeInterval(PRStep.interval))
        #expect(w.github.requests.count == calls, "read again before the back-off")
        await step.tick(now: Self.t0.addingTimeInterval(PRStep.firstBackoff))
        landing = try w.landing(item)
        #expect(landing.state == .checksFailed, "\(landing)")
        #expect(w.github.requests.count > calls)

        // A push whose outcome was lost (not a refusal: retried): held with the reason, not pushed again before the back-off (then
        // once, doubled after). A push GitHub refused waits `maxBackoff` (durableHoldAlertsTheOwnerOnce).
        let (other, otherSHA) = try w.handedOff("Lost push", ["r.txt": "r\n"])
        w.runner.mode = .hangUp
        try _ = w.store.beginPRLanding(item: other, sha: otherSHA, branch: "brahma/\(other.key)-lost-push", now: Self.t0)
        let start = Self.t0.addingTimeInterval(10 * PRStep.maxBackoff)
        await step.tick(now: start)
        #expect(w.runner.pushes.filter { $0.hasPrefix(otherSHA) }.count == 1)
        #expect(try w.landing(other).state == .pushing && w.landing(other).lastError?.contains("may not have landed") == true)
        await step.tick(now: start.addingTimeInterval(PRStep.interval))
        #expect(w.runner.pushes.filter { $0.hasPrefix(otherSHA) }.count == 1, "a failed push retried every tick")
        await step.tick(now: start.addingTimeInterval(PRStep.firstBackoff))
        #expect(w.runner.pushes.filter { $0.hasPrefix(otherSHA) }.count == 2)
        await step.tick(now: start.addingTimeInterval(PRStep.firstBackoff * 2.5))
        #expect(w.runner.pushes.filter { $0.hasPrefix(otherSHA) }.count == 2, "the back-off doubles")
        await step.tick(now: start.addingTimeInterval(PRStep.firstBackoff * 3))
        #expect(w.runner.pushes.filter { $0.hasPrefix(otherSHA) }.count == 3)
    }

    /// The owner agent fixes the red check and the item is approved again: the queue hands the new verified commit over, the
    /// gate is asked about the push again, the same branch is updated without `--force` and the same PR follows it. If the
    /// branch moved on GitHub meanwhile, the push is refused and the landing says so to the owner (`brahma why`).
    @Test func resubmitPushesSameBranchNoForce() async throws {
        let w = try World()
        let step = PRStep(store: w.store, machine: w.machine)
        let (item, sha) = try await Self.openPR(w, "Fix and resubmit")
        let branch = try w.landing(item).branch
        w.github.update(Self.repo) { $0.checkRuns = [.init(name: "ci", headSHA: sha, conclusion: "failure", output: "red")] }
        await step.tick(now: Self.t0)
        #expect(try w.landing(item).state == .checksFailed)
        let asked = w.gate.requests.count
        // Resubmitted: a new verified commit handed over for the same item.
        let fixed = try w.env.commit(["fixed.txt": "green\n"])
        try w.handOff(item, fixed)
        try Self.inReview(w.store, item)
        await w.machine.begin(item: item, verifiedSHA: fixed)
        let landing = try w.landing(item)
        #expect(landing.state == .open && landing.pushedSHA == fixed && landing.branch == branch && landing.prNumber == 1, "\(landing)")
        #expect(w.runner.pushes == ["\(sha):refs/heads/\(branch)", "\(fixed):refs/heads/\(branch)"])
        // Ruling X8-31′: the first push of the branch is plain; the resubmit replaces exactly the commit Brahma pushed before.
        let pushArgs = w.runner.pushArguments
        #expect(pushArgs.count == 2 && !pushArgs[0].contains { $0.hasPrefix("--force-with-lease") }, "\(pushArgs)")
        #expect(pushArgs.last?.filter { $0.hasPrefix("--force") } == ["--force-with-lease=refs/heads/\(branch):\(sha)"], "\(pushArgs)")
        for args in pushArgs {
            #expect(!args.contains { $0 == "--force" || $0 == "-f" || $0.hasPrefix("+") || $0 == "--delete" }, "\(args)")
        }
        #expect(try w.store.prLanding(itemId: item.id)?.leaseSHA == sha)
        #expect(w.github.openRequests.count == 1, "the same pull request follows the branch")
        let pushAsk = try #require(w.gate.requests.dropFirst(asked).first)
        #expect(pushAsk.type == .pushBranch && pushAsk.payload?.sha == fixed, "the push of the new commit went through the gate")
        #expect(w.github.snapshot(Self.repo)?.pulls.first?.headSHA == fixed)
        // Green now: mergeable.
        w.github.update(Self.repo) { $0.checkRuns.append(.init(name: "ci", headSHA: fixed, conclusion: "success")) }
        await step.tick(now: Self.t0.addingTimeInterval(PRStep.interval))
        #expect(try w.landing(item).state == .mergeable)

        // Someone pushed to the branch on GitHub: the lease is stale, the resubmit is refused (their commit stays), the landing
        // holds and the owner is told once.
        let (other, otherSHA) = try await Self.openPR(w, "Moved upstream")
        w.github.update(Self.repo) { $0.checkRuns.append(.init(name: "ci", headSHA: otherSHA, conclusion: "failure")) }
        await step.tick(now: Self.t0.addingTimeInterval(2 * PRStep.interval))
        #expect(try w.landing(other).state == .checksFailed)
        let otherBranch = try w.landing(other).branch
        let theirs = "f00d" + String(otherSHA.dropFirst(4))
        w.github.update(Self.repo) { $0.branches[otherBranch] = theirs }
        let again = try w.env.commit(["again.txt": "again\n"])
        try w.handOff(other, again)
        await w.machine.begin(item: other, verifiedSHA: again)
        let held = try w.landing(other)
        #expect(held.state == .pushing && held.lastError?.contains("[rejected] (stale info)") == true
                && held.lastError?.contains("someone else pushed") == true, "\(held)")
        #expect(w.github.snapshot(Self.repo)?.branches[otherBranch] == theirs, "never overwritten")
        #expect(w.runner.pushArguments.last?.contains("--force-with-lease=refs/heads/\(otherBranch):\(otherSHA)") == true)
        let reasons = try w.store.stallReport(companyId: w.env.company.id).reasons
        #expect(reasons.contains { $0.hasPrefix("@eng-1 waits: PR #2 held — ") && $0.contains("rejected") }, "\(reasons)")
        await step.tick(now: Self.t0.addingTimeInterval(3 * PRStep.maxBackoff))
        #expect(try Self.alerts(w.store).filter { $0.summary.contains(other.key) && $0.summary.contains("someone else pushed") }.count == 1)
    }

    /// "Paused" on this tree: a paused company, a merge hold that does not lift itself, or the owner's stop. The step makes no
    /// GitHub call and changes nothing; once lifted it carries on (a PR-unavailable hold lifts itself and does not pause it).
    @Test func pausedChannelHolds() async throws {
        let w = try World()
        let step = PRStep(store: w.store, machine: w.machine)
        let (item, sha) = try await Self.openPR(w, "Paused open")
        w.github.update(Self.repo) { $0.checkRuns = [.init(name: "ci", headSHA: sha, conclusion: "failure")] }
        let (pending, pendingSHA) = try w.handedOff("Paused push", ["p.txt": "p\n"])
        try _ = w.store.beginPRLanding(item: pending, sha: pendingSHA, branch: "brahma/\(pending.key)-paused-push", now: Self.t0)
        let before = try w.store.openPRLandings(companyId: w.env.company.id)
        let company = w.env.company.id
        func expectHeld(_ why: String, at now: Date) async throws {
            let (calls, pushes) = (w.github.requests.count, w.runner.pushes.count)
            await step.tick(now: now)
            #expect(w.github.requests.count == calls, "\(why): GitHub was called")
            #expect(w.runner.pushes.count == pushes, "\(why): pushed")
            #expect(try w.store.openPRLandings(companyId: company) == before, "\(why): a landing changed")
        }
        try Self.setStatus(w.store, company, .paused)
        try await expectHeld("paused company", at: Self.t0)
        try Self.setStatus(w.store, company, .running)
        try w.store.setMergeHold(companyId: company, reason: "held by the owner", now: Self.t0)
        try await expectHeld("merge hold", at: Self.t0.addingTimeInterval(1))
        try w.store.setMergeHold(companyId: company, reason: nil, now: Self.t0)
        try w.store.emergencyStop(note: nil, by: "owner", now: Self.t0)
        try await expectHeld("owner stop", at: Self.t0.addingTimeInterval(2))
        try w.store.resumeAfterStop(now: Self.t0)
        // A stop that comes while GitHub is being read: nothing is written (paused is checked again before the feedback).
        let store = w.store
        w.github.onRequest { line in
            guard line.hasSuffix("/reviews") else { return }
            do { try store.emergencyStop(note: nil, by: "owner", now: Self.t0) } catch { Issue.record("\(error)") }
        }
        await step.tick(now: Self.t0.addingTimeInterval(2.5))
        #expect(try w.landing(item).state == .open && w.store.workItem(id: item.id)?.status == .inReview)
        #expect(try Self.notices(w.store, item, kind: .prFeedback).isEmpty)
        w.github.onRequest(nil)
        try w.store.resumeAfterStop(now: Self.t0)
        try w.store.setMergeHold(companyId: company, reason: Store.prNoRemoteMainHold, now: Self.t0)
        await step.tick(now: Self.t0.addingTimeInterval(3 + PRStep.interval))
        #expect(try w.landing(item).state == .checksFailed)
        #expect(try w.landing(pending).state == .open && w.runner.pushes.contains { $0.hasPrefix(pendingSHA) })
    }

    // MARK: Plan X8 Task 5 (carried from Task 4)

    /// A PR closed on GitHub without merging gives the item back: its handed-to-PR request is bounced in the same write as the
    /// close, so nothing stays locked in review, and the holder hears once.
    @Test func closedUpstreamReleasesTheItem() async throws {
        let w = try World()
        let step = PRStep(store: w.store, machine: w.machine)
        let (item, _) = try await Self.openPR(w, "Closed by a maintainer")
        w.github.update(Self.repo) { $0.pulls[0].state = "closed" }
        await step.tick(now: Self.t0)
        let landing = try w.landing(item)
        #expect(landing.state == .closedUpstream && landing.lastError == "PR #1 was closed on GitHub without merging", "\(landing)")
        let back = try #require(try w.store.workItem(id: item.id))
        #expect(back.status == .inProgress && back.mergeState == .none && back.verifiedCommit == nil, "\(back)")
        #expect(try Self.request(w.store, item)?.status == .bounced)
        #expect(try !w.store.isMerging(itemId: item.id))
        let notices = try Self.notices(w.store, item, kind: .mergeFailed)
        #expect(notices.count == 1 && notices.first?["agentId"] as String? == w.eng.id, "\(notices)")
        #expect((notices.first?["text"] as String?)?.contains("PR #1 was closed on GitHub without merging") == true)
        // A close whose request is gone (already released) still ends the landing and tells the owner agent.
        let (other, _) = try await Self.openPR(w, "Closed after its request went")
        try Self.execute(w.store, "UPDATE mergeRequest SET status = 'bounced' WHERE itemId = ?", [other.id])
        w.github.update(Self.repo) { $0.pulls[1].state = "closed" }
        await step.tick(now: Self.t0.addingTimeInterval(PRStep.interval))
        #expect(try w.landing(other).state == .closedUpstream)
        #expect(try Self.notices(w.store, other, kind: .mergeFailed).count == 1)
    }

    /// The hold alert names the commit the pass held on and only an open landing: a landing that moved on during the pass (a
    /// newer commit, an abandon) raises nothing, and a head-moved hold whose record did not land is no hold for good.
    @Test func holdAlertNamesThePassCommitAndOnlyAnOpenLanding() async throws {
        let w = try World()
        let step = PRStep(store: w.store, machine: w.machine)
        let (item, sha) = try await Self.openPR(w, "Moves twice")
        // The head moved on GitHub, and while the engine reads the PR the item is resubmitted (a newer commit).
        w.github.update(Self.repo) { $0.pulls[0].headSHA = "f00d" + String(sha.dropFirst(4)) }
        let sha2 = try w.env.commit(["twice.txt": "2\n"])
        try w.handOff(item, sha2)
        let (store, github) = (w.store, w.github)
        github.onRequest { line in
            guard line == "GET /repos/acme/app/pulls/1" else { return }
            github.onRequest(nil)
            do { _ = try store.beginPRLanding(item: item, sha: sha2, branch: "brahma/x", now: Self.t0) } catch { Issue.record("\(error)") }
        }
        await step.tick(now: Self.t0)
        var landing = try w.landing(item)
        #expect(landing.pushedSHA == sha2 && landing.state == .pushing && landing.lastError == nil, "\(landing)")
        #expect(try Self.alerts(w.store).isEmpty, "no alert for a hold the landing moved past")

        // Abandoned while the engine reads the PR: nothing raised either.
        let (other, otherSHA) = try await Self.openPR(w, "Abandoned mid-read")
        w.github.update(Self.repo) { $0.pulls[$0.pulls.count - 1].headSHA = "f00d" + String(otherSHA.dropFirst(4)) }
        github.onRequest { line in
            guard line == "GET /repos/acme/app/pulls/2" else { return }
            github.onRequest(nil)
            do { try store.abandonPRLanding(itemId: other.id, reason: "", by: .owner) } catch { Issue.record("\(error)") }
        }
        await step.tick(now: Self.t0.addingTimeInterval(PRStep.maxBackoff))
        landing = try w.landing(other)
        #expect(landing.state == .abandoned, "\(landing)")
        #expect(try Self.alerts(w.store).isEmpty)
        // And directly: a closed landing is never alerted.
        #expect(try !w.store.raisePRHoldAlert(itemId: other.id, sha: otherSHA, why: "held", now: Self.t0))
        #expect(try Self.alerts(w.store).isEmpty)
    }

    /// A push GitHub refuses for the credential (403, an authentication failure) is a hold for good: one alert, retried only
    /// every `maxBackoff`.
    @Test func pushAuthFailureIsAHoldForGood() async throws {
        for why in ["remote: Permission to denied to bot. fatal: unable to access The requested URL returned error: 403",
                    "fatal: Authentication failed for", "fatal: could not read Username for terminal prompts disabled",
                    "remote: Invalid username or password.", "The requested URL returned error: 401"] {
            #expect(PRStep.isDurableHold(why), "\(why)")
        }
        #expect(!PRStep.isDurableHold("fatal: the remote end hung up unexpectedly"))
        let w = try World()
        let step = PRStep(store: w.store, machine: w.machine)
        let (item, sha) = try w.handedOff("Token refused", ["t.txt": "t\n"])
        try Self.inReview(w.store, item)
        w.runner.mode = .authFail
        try _ = w.store.beginPRLanding(item: item, sha: sha, branch: "brahma/\(item.key)-token-refused", now: Self.t0)
        await step.tick(now: Self.t0)
        #expect(w.runner.pushes.count == 1)
        let landing = try w.landing(item)
        #expect(landing.state == .pushing && landing.lastError?.contains("returned error: 403") == true, "\(landing)")
        let alerts = try Self.alerts(w.store)
        #expect(alerts.count == 1 && alerts.first?.summary.contains("GitHub said: ") == true, "\(alerts.map(\.summary))")
        await step.tick(now: Self.t0.addingTimeInterval(PRStep.firstBackoff * 4))
        #expect(w.runner.pushes.count == 1)
        await step.tick(now: Self.t0.addingTimeInterval(PRStep.maxBackoff))
        #expect(try w.runner.pushes.count == 2 && Self.alerts(w.store).count == 1)
    }
}
