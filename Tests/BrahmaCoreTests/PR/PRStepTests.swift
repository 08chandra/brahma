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
            $0.pulls[0].reviews = [.init(user: "rev-bot", state: "CHANGES_REQUESTED", commitId: sha, body: "Please rename `f` to `fetchUser`."),
                                   .init(user: "bystander", state: "COMMENTED", commitId: sha, body: "Also add a test."),
                                   .init(user: "friend", state: "COMMENTED", commitId: "old", body: "stale note")]
        }
        await step.tick(now: Self.t0)
        let landing = try w.landing(item)
        #expect(landing.state == .changesRequested && landing.lastError == "changes requested by @rev-bot (brought back as feedback)", "\(landing)")
        #expect(try w.store.workItem(id: item.id)?.status == .inProgress)
        #expect(try Self.request(w.store, item)?.status == .bounced)
        let text = try #require(try Self.notices(w.store, item, kind: .prFeedback).first?["text"] as String?)
        #expect(text.contains("Untrusted content from GitHub review by @rev-bot (CHANGES_REQUESTED)"), "\(text)")
        #expect(text.contains("    | Please rename `f` to `fetchUser`.") && text.contains("    | Also add a test.") && !text.contains("stale note"))
        let reasons = try w.store.stallReport(companyId: w.env.company.id).reasons
        #expect(reasons.contains("@eng-1 waits: PR #1 blocked — changes requested by @rev-bot (brought back as feedback)"), "\(reasons)")
        // Only a reviewer's latest decisive review counts: changes requested, then approved, is not a request for changes.
        let later = [GitHubReview(id: 1, user: GitHubUser(login: "a"), state: "CHANGES_REQUESTED", body: "x", commitId: sha),
                     GitHubReview(id: 2, user: GitHubUser(login: "A"), state: "COMMENTED", body: "y", commitId: sha),
                     GitHubReview(id: 3, user: GitHubUser(login: "A"), state: "APPROVED", body: "", commitId: sha),
                     GitHubReview(id: 4, user: GitHubUser(login: "b"), state: "APPROVED", body: "", commitId: sha),
                     GitHubReview(id: 5, user: GitHubUser(login: "b"), state: "CHANGES_REQUESTED", body: "z", commitId: sha)]
        #expect(PRStep.changesRequested(later).map(\.id) == [5])
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

        // A push GitHub rejects: held with GitHub's reason, and not pushed again before the back-off (then once, doubled after).
        let (other, otherSHA) = try w.handedOff("Rejected push", ["r.txt": "r\n"])
        w.runner.mode = .reject
        try _ = w.store.beginPRLanding(item: other, sha: otherSHA, branch: "brahma/\(other.key)-rejected-push", now: Self.t0)
        let start = Self.t0.addingTimeInterval(10 * PRStep.maxBackoff)
        await step.tick(now: start)
        #expect(w.runner.pushes.filter { $0.hasPrefix(otherSHA) }.count == 1)
        #expect(try w.landing(other).state == .pushing && w.landing(other).lastError?.contains("rejected") == true)
        await step.tick(now: start.addingTimeInterval(PRStep.interval))
        #expect(w.runner.pushes.filter { $0.hasPrefix(otherSHA) }.count == 1, "a rejected push retried every tick")
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
        for args in w.runner.pushArguments {
            #expect(!args.contains { $0 == "--force" || $0 == "-f" || $0.hasPrefix("--force-with-lease") || $0.hasPrefix("+") }, "\(args)")
        }
        #expect(w.github.openRequests.count == 1, "the same pull request follows the branch")
        let pushAsk = try #require(w.gate.requests.dropFirst(asked).first)
        #expect(pushAsk.type == .pushBranch && pushAsk.payload?.sha == fixed, "the push of the new commit went through the gate")
        #expect(w.github.snapshot(Self.repo)?.pulls.first?.headSHA == fixed)
        // Green now: mergeable.
        w.github.update(Self.repo) { $0.checkRuns.append(.init(name: "ci", headSHA: fixed, conclusion: "success")) }
        await step.tick(now: Self.t0.addingTimeInterval(PRStep.interval))
        #expect(try w.landing(item).state == .mergeable)

        // Someone pushed to the branch on GitHub: the next resubmit's push is refused (never forced) and the owner is told.
        let (other, otherSHA) = try await Self.openPR(w, "Moved upstream")
        w.github.update(Self.repo) { $0.checkRuns.append(.init(name: "ci", headSHA: otherSHA, conclusion: "failure")) }
        await step.tick(now: Self.t0.addingTimeInterval(2 * PRStep.interval))
        #expect(try w.landing(other).state == .checksFailed)
        w.runner.mode = .reject
        let again = try w.env.commit(["again.txt": "again\n"])
        try w.handOff(other, again)
        await w.machine.begin(item: other, verifiedSHA: again)
        let held = try w.landing(other)
        #expect(held.state == .pushing && held.lastError?.contains("rejected") == true, "\(held)")
        let reasons = try w.store.stallReport(companyId: w.env.company.id).reasons
        #expect(reasons.contains { $0.hasPrefix("@eng-1 waits: PR #2 held — ") && $0.contains("rejected") }, "\(reasons)")
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
        try w.store.setMergeHold(companyId: company, reason: Store.prNoRemoteMainHold, now: Self.t0)
        await step.tick(now: Self.t0.addingTimeInterval(3))
        #expect(try w.landing(item).state == .checksFailed)
        #expect(try w.landing(pending).state == .open && w.runner.pushes.contains { $0.hasPrefix(pendingSHA) })
    }
}
