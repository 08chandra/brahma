import Foundation
import Testing
import GRDB
@testable import BrahmaCore

/// The merge (Plan X8 Task 5; spec §8.5.1 step 6, §8.4.5 rule 4, §9.3.4): by default a human merges on GitHub and the landing
/// waits for GitHub to report `merged`; with `--engine-merge` the engine files a `merge-pr` request that always asks the owner
/// (irreversible), and the owner's approval presses merge exactly once, with the head commit pinned. 409 (the branch moved) and
/// 405 (not mergeable) go back to `open`; an unknown outcome is reconciled by reading the PR, never by merging again. Never a
/// bypass, never a protection or settings change, never a branch deleted. After `merged` the remote `main` is fetched and the
/// item completes through the merge queue's own landing record.
@Suite(.scratch, .serialized) struct EngineMergeTests {
    typealias World = PRLandingMachineTests.World
    static let repo = PRLandingMachineTests.repo
    static let t0 = Date(timeIntervalSince1970: 1_900_000_000)
    /// Every action type granted (`merge-pr` too): merging still asks.
    static let grantedAll = RulesGate(granted: Set(GitHubActionType.all.map(\.name)))
    static let fetchedTip = String(repeating: "c0ffee12", count: 5)

    /// The remote-main fetch Task 6 supplies, faked: records each call.
    final class FakeRemoteMain: RemoteMainFetching, @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        private var failing = false
        var calls: [String] { lock.withLock { seen } }
        func fail(_ value: Bool) { lock.withLock { failing = value } }
        func fetch(companyId: String) async throws -> FetchResult {
            let fail = lock.withLock { seen.append(companyId); return failing }
            if fail { throw FakeGitHub.Failure.unavailable }
            return FetchResult(newTip: EngineMergeTests.fetchedTip, commits: [EngineMergeTests.fetchedTip], rewound: false)
        }
    }

    /// Tick times far enough apart that every landing is due (past any back-off).
    final class Ticks: @unchecked Sendable {
        private var n = 0
        func next() -> Date { n += 1; return EngineMergeTests.t0.addingTimeInterval(Double(n) * PRStep.maxBackoff) }
    }

    /// A world whose company is in PR mode, `engineMerge` as given.
    static func world(engineMerge: Bool, gate: any PRActionGate = grantedAll, fetcher: FakeRemoteMain? = FakeRemoteMain()) throws -> World {
        let w = try World(gate: gate, remoteMain: fetcher)
        try w.store.setLanding(.pr, engineMerge: engineMerge, companyId: w.env.company.id, by: .owner)
        return w
    }

    /// An open PR (#1) whose required check passed and a maintainer approved: the next tick makes it `mergeable`.
    static func mergeable(_ w: World, _ step: PRStep, _ ticks: Ticks, _ title: String) async throws -> (WorkItem, String) {
        let (item, sha) = try await PRStepTests.openPR(w, title)
        w.github.update(repo) {
            $0.checkRuns.append(.init(name: "ci", headSHA: sha, conclusion: "success"))
            $0.pulls[0].reviews = [.init(user: "Maintainer-1", state: "APPROVED", commitId: sha, association: "MEMBER")]
        }
        await step.tick(now: ticks.next())
        #expect(try w.landing(item).state == .mergeable)
        return (item, sha)
    }

    static func puts(_ w: World) -> [String] { w.github.requests.filter { $0.hasPrefix("PUT ") } }

    static func mergeCards(_ w: World) throws -> [Ask] { try w.cards().filter { $0.subjectId?.hasPrefix("pr:merge-pr@") == true } }

    static func mergeRequestRow(_ w: World, _ item: WorkItem) throws -> MergeRequest? { try PRStepTests.request(w.store, item) }

    /// The merge queue's "merged into main" activity lines of the item.
    static func mergedLines(_ store: Store, _ item: WorkItem) throws -> [String] {
        try store.writer.read { db in
            try String.fetchAll(db, sql: "SELECT text FROM activityEvent WHERE text LIKE ?", arguments: ["\(item.key) merged into main (%"])
        }
    }

    /// The whole request log of a flow: no protection call of any method, no settings change, no delete, and no body that
    /// names a bypass.
    static func expectNoBypassOrProtection(_ w: World, sourceLocation: SourceLocation = #_sourceLocation) {
        let log = w.github.requests
        #expect(!log.contains { $0.contains("/protection") }, "\(log)", sourceLocation: sourceLocation)
        #expect(!log.contains { $0.hasPrefix("PATCH ") || $0.hasPrefix("DELETE ") }, "\(log)", sourceLocation: sourceLocation)
        #expect(log.filter { $0.hasPrefix("PUT ") }.allSatisfy { $0.hasSuffix("/merge") }, "\(log)", sourceLocation: sourceLocation)
        #expect(!w.github.mergeBodies.contains { $0.lowercased().contains("bypass") }, sourceLocation: sourceLocation)
        let opened = w.github.openRequests.map { request -> String in
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.sortedKeys]
            do { return String(decoding: try encoder.encode(request), as: UTF8.self) } catch { return "unencodable" }
        }
        #expect(!opened.contains { $0.contains("\"bypass") }, sourceLocation: sourceLocation)
    }

    // MARK: Brief

    /// Without `--engine-merge` the engine never presses merge and files no merge card: a mergeable landing waits; the owner
    /// merges on GitHub; GitHub's `merged` makes the landing `merged` and the item Done.
    @Test func defaultWaitsForHumanMerge() async throws {
        let w = try Self.world(engineMerge: false)
        let step = PRStep(store: w.store, machine: w.machine)
        let ticks = Ticks()
        let (item, _) = try await Self.mergeable(w, step, ticks, "Human merges")
        for _ in 0..<3 { await step.tick(now: ticks.next()) }
        let waiting = try w.landing(item)
        #expect(waiting.state == .mergeable && waiting.lastError == nil, "\(waiting)")
        #expect(Self.puts(w).isEmpty && w.github.mergeBodies.isEmpty)
        #expect(try Self.mergeCards(w).isEmpty, "no card without --engine-merge")
        #expect(try w.store.workItem(id: item.id)?.status == .inReview)
        // The owner merges on GitHub.
        w.github.humanMerge(Self.repo, number: 1)
        await step.tick(now: ticks.next())
        let merged = try w.landing(item)
        let pr = try #require(w.github.snapshot(Self.repo)?.pulls.first)
        #expect(merged.state == .merged && merged.mergedSHA == pr.mergeCommitSHA && merged.lastError == nil, "\(merged)")
        #expect(try w.store.workItem(id: item.id)?.status == .done)
        #expect(Self.puts(w).isEmpty)
        Self.expectNoBypassOrProtection(w)
    }

    /// `merge-pr` is irreversible: X4's rules ask even when every action type, `merge-pr` included, is granted and nothing else
    /// would ask. The machine files one owner card showing the PR, its head, GitHub's mergeability, the checks and approvals.
    /// The production gate refuses: no card, no merge.
    @Test func engineMergeAlwaysAsks() async throws {
        let request = PRActionRequest(type: .mergePR, companyId: "c", itemId: "i", taintedSession: false, itemTainted: false,
                                      externalInput: false, firstUse: false, repoVisibility: "private")
        #expect(await Self.grantedAll.decide(request) == .ask(reason: "merging a pull request cannot be undone"))
        #expect(await Self.grantedAll.decide(PRActionRequest(type: .openPR, companyId: "c", itemId: "i", taintedSession: false, itemTainted: false,
                                                              externalInput: false, firstUse: false, repoVisibility: "private")) == .auto)
        #expect(await NoChannelGate().decide(request) == .refuse(rule: LandingMode.needsChannelText))

        let w = try Self.world(engineMerge: true)
        let step = PRStep(store: w.store, machine: w.machine)
        let ticks = Ticks()
        let (item, sha) = try await Self.mergeable(w, step, ticks, "Engine merges")
        await step.tick(now: ticks.next())
        let landing = try w.landing(item)
        #expect(landing.state == .mergeable && landing.lastError == "waiting for the owner: merging a pull request cannot be undone", "\(landing)")
        let cards = try Self.mergeCards(w)
        #expect(cards.count == 1 && cards.first?.status == .pendingOwner && cards.first?.kind == .prAction)
        let card = try #require(cards.first)
        #expect(card.requestId == "pr-merge-pr-\(item.id)-\(sha)" && card.payload?.reversible == .oneWay)
        let details = try #require(card.payload?.details)
        for fact in ["Action: merge-pr (modify; irreversible)", "Item: \(item.key)", "Pull request: #1", "Head: \(landing.branch) at \(sha)",
                     "Base: main", "Merge method: merge", "mergeable_state (GitHub): clean", "Title (on GitHub: agent-influenced, untrusted): ",
                     "    | ci: completed, success", "    | @Maintainer-1 APPROVED at \(sha.prefix(7)) (MEMBER)"] {
            #expect(details.contains(fact), "\(fact): \(details)")
        }
        #expect(Self.puts(w).isEmpty)
        // Re-ticks: no second card, no merge.
        await step.tick(now: ticks.next())
        await step.tick(now: ticks.next())
        #expect(try Self.mergeCards(w).count == 1 && Self.puts(w).isEmpty)
        // The owner merges on GitHub instead: the card can decide nothing any more.
        w.github.humanMerge(Self.repo, number: 1)
        await step.tick(now: ticks.next())
        #expect(try w.landing(item).state == .merged && Self.mergeCards(w).map(\.status) == [.superseded])
        #expect(Self.puts(w).isEmpty)

        // The production gate: refused, nothing asked, nothing merged.
        let refused = try Self.world(engineMerge: true)
        let refusedStep = PRStep(store: refused.store, machine: refused.machine)
        let (other, _) = try await Self.mergeable(refused, refusedStep, Ticks(), "Refused merge")
        refused.gate.inner = NoChannelGate()
        await refusedStep.tick(now: ticks.next())
        #expect(try refused.landing(other).lastError == LandingMode.needsChannelText)
        #expect(try Self.mergeCards(refused).isEmpty && Self.puts(refused).isEmpty)
    }

    /// The approved merge sends exactly `{ merge_method, sha }`: the pushed commit and the repository's preferred method.
    @Test func mergePinsSHA() async throws {
        #expect(MergeMethod.preferred(RepoInfo(visibility: "private", defaultBranch: "main")) == .merge)
        #expect(MergeMethod.preferred(RepoInfo(visibility: "private", defaultBranch: "main", allowMergeCommit: false)) == .squash)
        #expect(MergeMethod.preferred(RepoInfo(visibility: "private", defaultBranch: "main", allowMergeCommit: false, allowSquashMerge: false)) == .rebase)
        #expect(MergeMethod.preferred(RepoInfo(visibility: "private", defaultBranch: "main", allowMergeCommit: false, allowSquashMerge: false,
                                               allowRebaseMerge: false)) == nil)

        let w = try Self.world(engineMerge: true)
        let step = PRStep(store: w.store, machine: w.machine)
        let ticks = Ticks()
        w.github.update(Self.repo) { $0.allowMergeCommit = false }
        let (item, sha) = try await Self.mergeable(w, step, ticks, "Pinned")
        await step.tick(now: ticks.next())
        let card = try #require(try Self.mergeCards(w).first)
        #expect(card.payload?.details?.contains("Merge method: squash") == true)
        _ = try w.store.ownerDecide(askId: card.id, approve: true)
        await step.tick(now: ticks.next())
        #expect(Self.puts(w) == ["PUT /repos/acme/app/pulls/1/merge"])
        #expect(w.github.mergeBodies == ["{\"merge_method\":\"squash\",\"sha\":\"\(sha)\"}"], "\(w.github.mergeBodies)")
        #expect(try w.landing(item).state == .merged)
        Self.expectNoBypassOrProtection(w)
    }

    /// The branch moved after the card (409: `sha` is not the head): nothing merged, the landing goes back to `open` (not a
    /// hold for good), the approval is spent; the open step then holds on the moved head.
    @Test func movedBranchReturnsToOpen() async throws {
        let w = try Self.world(engineMerge: true)
        let step = PRStep(store: w.store, machine: w.machine)
        let ticks = Ticks()
        let (item, sha) = try await Self.mergeable(w, step, ticks, "Moved branch")
        await step.tick(now: ticks.next())
        _ = try w.store.ownerDecide(askId: try #require(try Self.mergeCards(w).first).id, approve: true)
        // Someone pushes to the branch right after the engine read the PR, before its merge reaches GitHub.
        let moved = "beef" + String(sha.dropFirst(4))
        let github = w.github
        github.onRequest { line in
            guard line == "GET /repos/acme/app/pulls/1" else { return }
            github.onRequest(nil)
            github.update(EngineMergeTests.repo) { $0.pulls[0].headSHA = moved }
        }
        await step.tick(now: ticks.next())
        #expect(Self.puts(w).count == 1 && w.github.mergeBodies.first?.contains(sha) == true)
        var landing = try w.landing(item)
        #expect(landing.state == .open && landing.lastError?.contains("409") == true, "\(landing)")
        #expect(w.github.snapshot(Self.repo)?.pulls.first?.merged == false)
        #expect(try w.approvals().filter { $0.action == "merge-pr" }.allSatisfy { $0.consumedAt != nil })
        #expect(try PRStepTests.alerts(w.store).isEmpty, "a 409 is not a hold for good")
        await step.tick(now: ticks.next())
        landing = try w.landing(item)
        #expect(landing.state == .open && landing.lastError?.hasSuffix(PRStep.headMovedSuffix) == true, "\(landing)")
        #expect(Self.puts(w).count == 1)
        Self.expectNoBypassOrProtection(w)
    }

    /// GitHub says the PR is not mergeable (405): back to `open`, nothing retried; a later `clean` needs a fresh card.
    @Test func notMergeableReturnsToOpen() async throws {
        let w = try Self.world(engineMerge: true)
        let step = PRStep(store: w.store, machine: w.machine)
        let ticks = Ticks()
        let (item, sha) = try await Self.mergeable(w, step, ticks, "Not mergeable")
        await step.tick(now: ticks.next())
        _ = try w.store.ownerDecide(askId: try #require(try Self.mergeCards(w).first).id, approve: true)
        w.github.failNextMerge(.rejected(405, "Pull Request is not mergeable"))
        await step.tick(now: ticks.next())
        let landing = try w.landing(item)
        #expect(landing.state == .open && landing.lastError?.contains("405") == true, "\(landing)")
        #expect(try PRStepTests.alerts(w.store).isEmpty, "a 405 is not a hold for good")
        #expect(try w.store.workItem(id: item.id)?.status == .inReview)
        // Read again: clean → mergeable → a fresh card; nothing merges without it.
        await step.tick(now: ticks.next())
        await step.tick(now: ticks.next())
        let cards = try Self.mergeCards(w)
        #expect(cards.count == 2 && cards[1].status == .pendingOwner && cards[1].requestId == "pr-merge-pr-\(item.id)-\(sha)-2",
                "\(cards.map { "\($0.requestId ?? "-") \($0.status)" })")
        #expect(Self.puts(w).count == 1)
        // GitHub stops calling it clean while the card waits: back to open before any merge.
        w.github.update(Self.repo) { $0.pulls[0].mergeableOverride = "blocked" }
        await step.tick(now: ticks.next())
        #expect(try w.landing(item).state == .open)
        Self.expectNoBypassOrProtection(w)
    }

    /// Over whole flows — a merge, a 409, a 405, an unknown outcome — the engine sends no protection call, no settings change,
    /// no delete (the `brahma/` branch is left for GitHub's auto-delete or the owner) and no bypass field.
    @Test func neverSendsBypassOrProtectionCalls() async throws {
        // The request type has nothing but the pinned sha and the method.
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let body = try JSONSerialization.jsonObject(with: try encoder.encode(MergePullRequest(sha: String(repeating: "a", count: 40), mergeMethod: .rebase)))
        #expect((body as? [String: String]).map { Set($0.keys) } == ["sha", "merge_method"])

        for failure in [nil, FakeGitHub.MergeFailure.rejected(409, "Head branch was modified."), .rejected(405, "Pull Request is not mergeable"),
                        .lostResponse, .lostRequest] {
            let w = try Self.world(engineMerge: true)
            let step = PRStep(store: w.store, machine: w.machine)
            let ticks = Ticks()
            let (item, _) = try await Self.mergeable(w, step, ticks, "Flow")
            await step.tick(now: ticks.next())
            _ = try w.store.ownerDecide(askId: try #require(try Self.mergeCards(w).first).id, approve: true)
            w.github.failNextMerge(failure)
            for _ in 0..<4 { await step.tick(now: ticks.next()) }
            #expect(Self.puts(w).count == 1, "\(String(describing: failure))")
            let branch = try w.landing(item).branch
            #expect(w.github.snapshot(Self.repo)?.branches[branch] != nil, "the brahma/ branch is never deleted")
            Self.expectNoBypassOrProtection(w)
        }
    }

    /// A merge whose outcome is unknown is reconciled by reading the PR: merged → `merged` (and Done); not merged → `open`, the
    /// approval spent; GitHub unreadable → still `merging`, read again later. Never a second merge without a fresh card.
    @Test func unknownMergeReconcilesNeverRetries() async throws {
        // Lost before GitHub saw it: not merged.
        do {
            let w = try Self.world(engineMerge: true)
            let step = PRStep(store: w.store, machine: w.machine)
            let ticks = Ticks()
            let (item, _) = try await Self.mergeable(w, step, ticks, "Lost request")
            await step.tick(now: ticks.next())
            _ = try w.store.ownerDecide(askId: try #require(try Self.mergeCards(w).first).id, approve: true)
            w.github.failNextMerge(.lostRequest)
            await step.tick(now: ticks.next())
            let landing = try w.landing(item)
            #expect(landing.state == .open && landing.lastError?.contains("may not have run") == true, "\(landing)")
            let afterPut = try #require(w.github.requests.lastIndex(of: "PUT /repos/acme/app/pulls/1/merge"))
            #expect(w.github.requests[(afterPut + 1)...].contains("GET /repos/acme/app/pulls/1"), "read back")
            for _ in 0..<3 { await step.tick(now: ticks.next()) }
            #expect(Self.puts(w).count == 1)
            #expect(try Self.mergeCards(w).count == 2 && Self.mergeCards(w)[1].status == .pendingOwner)
        }
        // Merged, but the answer was lost: the read-back finds it merged.
        do {
            let w = try Self.world(engineMerge: true)
            let step = PRStep(store: w.store, machine: w.machine)
            let ticks = Ticks()
            let (item, _) = try await Self.mergeable(w, step, ticks, "Lost response")
            await step.tick(now: ticks.next())
            _ = try w.store.ownerDecide(askId: try #require(try Self.mergeCards(w).first).id, approve: true)
            w.github.failNextMerge(.lostResponse)
            await step.tick(now: ticks.next())
            let landing = try w.landing(item)
            #expect(landing.state == .merged && landing.mergedSHA == w.github.snapshot(Self.repo)?.pulls.first?.mergeCommitSHA, "\(landing)")
            #expect(try w.store.workItem(id: item.id)?.status == .done)
            await step.tick(now: ticks.next())
            #expect(Self.puts(w).count == 1)
        }
        // GitHub unreadable after the merge was sent: `merging` stays, read again later, never merged again.
        do {
            let w = try Self.world(engineMerge: true)
            let step = PRStep(store: w.store, machine: w.machine)
            let ticks = Ticks()
            let (item, _) = try await Self.mergeable(w, step, ticks, "Down after merge")
            await step.tick(now: ticks.next())
            _ = try w.store.ownerDecide(askId: try #require(try Self.mergeCards(w).first).id, approve: true)
            let github = w.github
            github.onRequest { line in
                guard line.hasPrefix("PUT ") else { return }
                github.onRequest(nil)
                github.setDown(true)
            }
            w.github.failNextMerge(.lostResponse)
            await step.tick(now: ticks.next())
            var landing = try w.landing(item)
            #expect(landing.state == .merging && landing.lastError?.contains("never merged again blind") == true, "\(landing)")
            await step.tick(now: ticks.next())
            #expect(try w.landing(item).state == .merging)
            w.github.setDown(false)
            await step.tick(now: ticks.next())
            landing = try w.landing(item)
            #expect(landing.state == .merged, "\(landing)")
            #expect(Self.puts(w).count == 1)
        }
    }

    /// After `merged`: the remote `main` is fetched and the item completes through the merge queue's landing record (its
    /// handed-to-PR request `merged`, one "merged into main" line, Done). `main` and `company.mainCommit` are the fetch's to
    /// move (Task 6), never this step's; GitHub's branch is left alone.
    @Test func mergedMakesItemDone() async throws {
        let fetcher = FakeRemoteMain()
        let w = try Self.world(engineMerge: true, fetcher: fetcher)
        let step = PRStep(store: w.store, machine: w.machine)
        let ticks = Ticks()
        let mainBefore = try w.store.company(id: w.env.company.id)?.mainCommit
        let (item, _) = try await Self.mergeable(w, step, ticks, "Lands")
        await step.tick(now: ticks.next())
        _ = try w.store.ownerDecide(askId: try #require(try Self.mergeCards(w).first).id, approve: true)
        await step.tick(now: ticks.next())
        let landing = try w.landing(item)
        let pr = try #require(w.github.snapshot(Self.repo)?.pulls.first)
        #expect(pr.merged && landing.state == .merged && landing.mergedSHA == pr.mergeCommitSHA && landing.lastError == nil, "\(landing)")
        #expect(fetcher.calls == [w.env.company.id])
        let done = try #require(try w.store.workItem(id: item.id))
        #expect(done.status == .done && done.mergedCommit == pr.mergeCommitSHA, "\(done)")
        let request = try #require(try Self.mergeRequestRow(w, item))
        #expect(request.status == .merged && request.mergedCommit == pr.mergeCommitSHA)
        let lines = try Self.mergedLines(w.store, item)
        #expect(lines.count == 1 && lines.first?.hasPrefix("\(item.key) merged into main (") == true, "\(lines)")
        #expect(try w.store.company(id: w.env.company.id)?.mainCommit == mainBefore)
        // Done is done: later ticks fetch and record nothing more.
        await step.tick(now: ticks.next())
        #expect(fetcher.calls.count == 1)
        #expect(w.github.snapshot(Self.repo)?.branches[landing.branch] != nil)
        Self.expectNoBypassOrProtection(w)
    }

    // MARK: Controller

    /// Approve → exactly one merge; later ticks send nothing.
    @Test func approvedMergeCardRunsOnce() async throws {
        let w = try Self.world(engineMerge: true)
        let step = PRStep(store: w.store, machine: w.machine)
        let ticks = Ticks()
        let (item, _) = try await Self.mergeable(w, step, ticks, "Once")
        await step.tick(now: ticks.next())
        await step.tick(now: ticks.next())
        #expect(Self.puts(w).isEmpty)
        let card = try #require(try Self.mergeCards(w).first)
        _ = try w.store.ownerDecide(askId: card.id, approve: true)
        await step.tick(now: ticks.next())
        #expect(Self.puts(w).count == 1)
        #expect(try w.approvals().filter { $0.action == "merge-pr" }.map { $0.consumedAt != nil } == [true])
        for _ in 0..<3 { await step.tick(now: ticks.next()) }
        await w.machine.advance(itemId: item.id)
        #expect(Self.puts(w).count == 1 && w.github.mergeBodies.count == 1)
        #expect(try w.landing(item).state == .merged && Self.mergeCards(w).count == 1)
    }

    /// The approval answers exactly the merge it showed: the head moving (or the method changing) after the approval runs
    /// nothing; the head moved outside Brahma holds; a resubmitted commit needs its own card, and only that one merges it.
    @Test func headMovedAfterApprovalNeedsNewCard() async throws {
        let w = try Self.world(engineMerge: true)
        let step = PRStep(store: w.store, machine: w.machine)
        let ticks = Ticks()
        let (item, sha) = try await Self.mergeable(w, step, ticks, "Moves after approval")
        await step.tick(now: ticks.next())
        let first = try #require(try Self.mergeCards(w).first)
        _ = try w.store.ownerDecide(askId: first.id, approve: true)
        // The method changes after the approval: what would run is not what the owner saw.
        w.github.update(Self.repo) { $0.allowMergeCommit = false }
        await step.tick(now: ticks.next())
        #expect(Self.puts(w).isEmpty)
        var cards = try Self.mergeCards(w)
        #expect(cards.count == 2 && cards[1].payload?.details?.contains("Merge method: squash") == true && cards[1].status == .pendingOwner)
        _ = try w.store.ownerDecide(askId: cards[1].id, approve: true)
        // The head moves on GitHub after that approval: nothing merges; the landing goes back to open and holds.
        w.github.update(Self.repo) { $0.pulls[0].headSHA = "f00d" + String(sha.dropFirst(4)) }
        await step.tick(now: ticks.next())
        await step.tick(now: ticks.next())
        #expect(Self.puts(w).isEmpty)
        #expect(try w.landing(item).state == .open && w.landing(item).lastError?.hasSuffix(PRStep.headMovedSuffix) == true)
        // The item is resubmitted (a new verified commit): pushed to the same branch, the PR follows; the approval for `sha`
        // answers nothing; a fresh card for the new commit is what merges it.
        let sha2 = try w.env.commit(["moved.txt": "2\n"])
        try w.handOff(item, sha2)
        try PRStepTests.inReview(w.store, item)
        await w.machine.begin(item: item, verifiedSHA: sha2)
        w.github.update(Self.repo) { $0.checkRuns.append(.init(name: "ci", headSHA: sha2, conclusion: "success")) }
        #expect(try w.landing(item).state == .open && w.landing(item).pushedSHA == sha2)
        await step.tick(now: ticks.next())   // clean → mergeable
        await step.tick(now: ticks.next())   // a card for sha2
        #expect(Self.puts(w).isEmpty)
        cards = try Self.mergeCards(w)
        let fresh = try #require(cards.last)
        #expect(fresh.requestId == "pr-merge-pr-\(item.id)-\(sha2)" && fresh.status == .pendingOwner, "\(cards.map { $0.requestId ?? "-" })")
        _ = try w.store.ownerDecide(askId: fresh.id, approve: true)
        await step.tick(now: ticks.next())
        #expect(w.github.mergeBodies == ["{\"merge_method\":\"squash\",\"sha\":\"\(sha2)\"}"], "\(w.github.mergeBodies)")
        #expect(try w.landing(item).state == .merged)
    }

    /// No fetch wired: the landing records `merged`, says it waits for the remote main fetch, and the item is not Done; once a
    /// fetch is wired, the next pass completes it.
    @Test func noFetcherHoldsMergedNotDone() async throws {
        let w = try Self.world(engineMerge: false, fetcher: nil)
        let step = PRStep(store: w.store, machine: w.machine)
        let ticks = Ticks()
        let (item, _) = try await Self.mergeable(w, step, ticks, "No fetch yet")
        w.github.humanMerge(Self.repo, number: 1)
        await step.tick(now: ticks.next())
        var landing = try w.landing(item)
        #expect(landing.state == .merged && landing.lastError == "PR merged; waiting for the remote main fetch", "\(landing)")
        #expect(try w.store.workItem(id: item.id)?.status == .inReview)
        #expect(try Self.mergeRequestRow(w, item)?.status == .handedToPR)
        await step.tick(now: ticks.next())
        #expect(try w.store.workItem(id: item.id)?.status == .inReview)
        // A failing fetch keeps it waiting, with why.
        let fetcher = FakeRemoteMain()
        fetcher.fail(true)
        let stage = w.env.stage(github: w.github, gate: NoChannelGate(), push: GitPush(runner: w.runner, tempRoot: try tempDir()))
        let wired = PRLandingMachine(store: w.store, github: w.github, gate: w.gate, push: stage, repo: { _ in EngineMergeTests.repo },
                                     remoteMain: fetcher)
        let wiredStep = PRStep(store: w.store, machine: wired)
        await wiredStep.tick(now: ticks.next())
        landing = try w.landing(item)
        #expect(landing.state == .merged && landing.lastError?.hasPrefix("PR merged; the remote main fetch failed") == true, "\(landing)")
        #expect(try w.store.workItem(id: item.id)?.status == .inReview)
        fetcher.fail(false)
        await wiredStep.tick(now: ticks.next())
        landing = try w.landing(item)
        #expect(landing.lastError == nil, "\(landing)")
        #expect(try w.store.workItem(id: item.id)?.status == .done)
        #expect(try Self.mergeRequestRow(w, item)?.status == .merged)
    }

    /// A repository that allows no merge method is a merge refused for good: held in `mergeable`, the owner told once.
    @Test func noMergeMethodHoldsAndAlertsOnce() async throws {
        let w = try Self.world(engineMerge: true)
        let step = PRStep(store: w.store, machine: w.machine)
        let ticks = Ticks()
        let (item, _) = try await Self.mergeable(w, step, ticks, "No method")
        w.github.update(Self.repo) { $0.allowMergeCommit = false; $0.allowSquashMerge = false; $0.allowRebaseMerge = false }
        await step.tick(now: ticks.next())
        await step.tick(now: ticks.next())
        let landing = try w.landing(item)
        #expect(landing.state == .mergeable && landing.lastError?.contains("allows no merge method") == true, "\(landing)")
        #expect(try Self.mergeCards(w).isEmpty && Self.puts(w).isEmpty)
        let alerts = try PRStepTests.alerts(w.store)
        #expect(alerts.count == 1 && alerts.first?.summary.contains("GitHub said: ") == true, "\(alerts.map(\.summary))")
    }
}
