import Foundation
import Testing
import GRDB
@testable import BrahmaCore

/// The PR landing machine (Plan X8 Task 3): push → open through the one gate, the open-pr request GitHub gets, reconciling an
/// unknown push or open by reading GitHub back, a PR closed upstream, and the owner card for an ask (Ruling 26).
@Suite(.scratch, .serialized) struct PRLandingMachineTests {
    static let repo = GitHubRepoRef(owner: "acme", name: "app")
    static let granted = RulesGate(granted: [GitHubActionType.pushBranch.name, GitHubActionType.openPR.name])

    /// A push runner that is GitHub's side of the push: a landed push puts the commit on the fake's branch. Runs no git.
    final class GitHubPushRunner: GitPushRunning, @unchecked Sendable {
        enum Mode { case land, reject, hangUp, authFail }
        let github: FakeGitHub
        private let lock = NSLock()
        private var currentMode = Mode.land
        private var refspecs: [String] = []
        private var argv: [[String]] = []
        private var hook: (@Sendable () -> Void)?

        init(github: FakeGitHub) { self.github = github }

        var mode: Mode {
            get { lock.withLock { currentMode } }
            set { lock.withLock { currentMode = newValue } }
        }
        /// Every `<sha>:<ref>` pushed.
        var pushes: [String] { lock.withLock { refspecs } }
        /// Every push's whole argument list (after `git`).
        var pushArguments: [[String]] { lock.withLock { argv } }
        func onPush(_ hook: (@Sendable () -> Void)?) { lock.withLock { self.hook = hook } }

        func run(args: [String], env: [String: String], credential: TokenHandle?, workingDirectory: URL, timeout: Duration,
                 outputCap: Int) throws -> GitPushProcessResult {
            if args.contains("cat-file") { return GitPushProcessResult(status: 0, stdout: Data(), stderr: Data(), timedOut: false) }
            guard args.contains("push"), let spec = args.last, let colon = spec.firstIndex(of: ":") else {
                return GitPushProcessResult(status: 2, stdout: Data(), stderr: Data("unexpected git call\n".utf8), timedOut: false)
            }
            let (mode, hook) = lock.withLock { refspecs.append(spec); argv.append(args); return (currentMode, self.hook) }
            hook?()
            switch mode {
            case .land:
                let sha = String(spec[..<colon]), branch = String(spec[spec.index(after: colon)...].dropFirst("refs/heads/".count))
                // GitHub moves the branch, and every open PR on it follows.
                github.update(PRLandingMachineTests.repo) { r in
                    r.branches[branch] = sha
                    for i in r.pulls.indices where r.pulls[i].head == branch && r.pulls[i].state == "open" { r.pulls[i].headSHA = sha }
                }
                return GitPushProcessResult(status: 0, stdout: Data("*\t\(spec)\t[new branch]\nDone\n".utf8), stderr: Data(), timedOut: false)
            case .reject:
                return GitPushProcessResult(status: 1, stdout: Data("!\t\(spec)\t[remote rejected] (protected branch hook declined)\nDone\n".utf8),
                                            stderr: Data("error: failed to push some refs\n".utf8), timedOut: false)
            case .hangUp:
                return GitPushProcessResult(status: 128, stdout: Data(), stderr: Data("fatal: the remote end hung up unexpectedly\n".utf8),
                                            timedOut: false)
            case .authFail:
                // The token lacks the right (or was revoked): git over HTTPS gets GitHub's 403.
                let stderr = "remote: Permission to acme/app.git denied to brahma-bot.\n"
                    + "fatal: unable to access 'https://github.com/acme/app.git/': The requested URL returned error: 403\n"
                return GitPushProcessResult(status: 128, stdout: Data(), stderr: Data(stderr.utf8), timedOut: false)
            }
        }
    }

    /// The one gate, switchable mid-test, recording what it was asked.
    final class SwitchGate: PRActionGate, @unchecked Sendable {
        private let lock = NSLock()
        private var current: any PRActionGate
        private var seen: [PRActionRequest] = []
        init(_ gate: any PRActionGate) { current = gate }
        var inner: any PRActionGate {
            get { lock.withLock { current } }
            set { lock.withLock { current = newValue } }
        }
        var requests: [PRActionRequest] { lock.withLock { seen } }
        func decide(_ r: PRActionRequest) async -> PRActionDecision {
            let gate = lock.withLock { seen.append(r); return current }
            return await gate.decide(r)
        }
    }

    /// Landing states seen at each GitHub call.
    final class StateLog: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        func add(_ s: String) { lock.withLock { seen.append(s) } }
        var states: [String] { lock.withLock { seen } }
        /// Consecutive repeats folded.
        var steps: [String] { states.reduce(into: []) { if $0.last != $1 { $0.append($1) } } }
    }

    static func state(_ store: Store, _ itemId: String) -> String {
        do { return try store.prLanding(itemId: itemId)?.state.rawValue ?? "none" } catch { return "unreadable" }
    }

    struct World {
        let env: GitPushTests.Env
        let github: FakeGitHub
        let runner: GitHubPushRunner
        let gate: SwitchGate
        let machine: PRLandingMachine
        let eng: Agent
        var store: Store { env.store }

        /// `firstPushDone`: an earlier push of the company reached GitHub, so the first-push ask is behind it.
        init(firstPushDone: Bool = true, gate: any PRActionGate = PRLandingMachineTests.granted, defaultBranch: String = "main",
             visibility: String = "private", remoteMain: (any RemoteMainFetching)? = nil) throws {
            env = try GitPushTests.Env()
            try env.setToken(["machine", "push", "Tq5Wn2Ld8"].joined(separator: "-"))
            if firstPushDone { try env.seedEarlierPush() }
            github = FakeGitHub(PRLandingMachineTests.repo, visibility: visibility, defaultBranch: defaultBranch)
            runner = GitHubPushRunner(github: github)
            self.gate = SwitchGate(gate)
            // The stage's own gate is never used: the machine decides through its gate.
            let stage = env.stage(github: github, gate: NoChannelGate(), push: GitPush(runner: runner, tempRoot: try tempDir()))
            machine = PRLandingMachine(store: env.store, github: github, gate: self.gate, push: stage, repo: { _ in PRLandingMachineTests.repo },
                                       remoteMain: remoteMain)
            eng = try env.store.hire(companyId: env.company.id, name: "eng-1", role: "engineer", model: "sonnet")
        }

        /// An item owned by @eng-1 whose verified commit (files on `base`) the merge queue handed to a PR.
        func handedOff(_ title: String, _ files: [String: String], summary: String? = nil) throws -> (WorkItem, String) {
            var item = try store.createWorkItem(companyId: env.company.id, by: .owner,
                                                draft: WorkItemDraft(type: .task, title: title, acceptanceCriteria: "- it works", ownerId: eng.id))
            if let summary {
                try store.writer.write { db in
                    try db.execute(sql: "UPDATE workItem SET submitSummary = ? WHERE id = ?", arguments: [summary, item.id])
                }
                item = try #require(try store.workItem(id: item.id))
            }
            let sha = try env.commit(files)
            try handOff(item, sha)
            return (item, sha)
        }

        /// What `markHandedToPR` records: a `handedToPR` request for the item with its base and candidate.
        func handOff(_ item: WorkItem, _ sha: String) throws {
            try store.writer.write { db in
                let n = (try Int.fetchOne(db, sql: "SELECT MAX(number) FROM mergeRequest WHERE companyId = ?", arguments: [item.companyId]) ?? 0) + 1
                var request = MergeRequest(companyId: item.companyId, itemId: item.id, number: n, status: .handedToPR, headCommit: sha,
                                           enqueuedAt: Date(timeIntervalSince1970: 1_800_000_000))
                request.baseCommit = env.base
                request.candidateCommit = sha
                try request.insert(db)
            }
        }

        func landing(_ item: WorkItem) throws -> PRLanding { try #require(try store.prLanding(itemId: item.id)) }

        func cards() throws -> [Ask] {
            try store.writer.read { db in try Ask.filter(Column("kind") == AskKind.prAction).order(Column("number")).fetchAll(db) }
        }

        func approvals() throws -> [PRActionApproval] {
            try store.writer.read { db in try PRActionApproval.order(Column("createdAt"), Column("askId")).fetchAll(db) }
        }
    }

    // MARK: Brief

    @Test func pushThenOpen() async throws {
        let w = try World()
        let (item, sha) = try w.handedOff("Add the login page", ["src/login.swift": "let login = true\n"])
        let log = StateLog()
        let (store, id) = (w.store, item.id)
        w.github.onRequest { _ in log.add(Self.state(store, id)) }
        w.runner.onPush { log.add(Self.state(store, id)) }
        await w.machine.begin(item: item, verifiedSHA: sha)
        let landing = try w.landing(item)
        #expect(landing.state == .open, "\(landing)")
        #expect(landing.lastError == nil)
        #expect(landing.prNumber == 1 && landing.prURL == "https://github.com/acme/app/pull/1")
        #expect(landing.branch == "brahma/\(item.key)-add-the-login-page" && landing.pushedSHA == sha)
        // pushing (the branch read, the visibility read and the push) → pushed (the repository read) → opening (the POST) → open.
        #expect(log.steps == ["pushing", "pushed", "opening"], "\(log.states)")
        #expect(w.runner.pushes == ["\(sha):refs/heads/\(landing.branch)"])
        #expect(w.github.openRequests.count == 1)
        #expect(w.github.snapshot(Self.repo)?.branches[landing.branch] == sha)
        #expect(w.gate.requests.map(\.type) == [.pushBranch, .openPR])
        #expect(try w.cards().isEmpty, "nothing asked: no card")
        // The same hand-off again (a recovery) pushes and opens nothing more.
        await w.machine.begin(item: item, verifiedSHA: sha)
        #expect(w.runner.pushes.count == 1 && w.github.openRequests.count == 1)
        #expect(try w.landing(item).state == .open)
    }

    /// Production's gate refuses everything: the landing holds at `pushing` with the rule, nothing is pushed, opened or asked.
    /// A push GitHub rejects holds the same way, with GitHub's reason.
    @Test func refusedPushHoldsWithError() async throws {
        let w = try World(gate: NoChannelGate())
        let (item, sha) = try w.handedOff("Refused", ["r.txt": "r\n"])
        await w.machine.begin(item: item, verifiedSHA: sha)
        var landing = try w.landing(item)
        #expect(landing.state == .pushing && landing.lastError == LandingMode.needsChannelText, "\(landing)")
        await w.machine.advance(itemId: item.id)
        landing = try w.landing(item)
        #expect(landing.state == .pushing && landing.lastError == LandingMode.needsChannelText)
        #expect(w.runner.pushes.isEmpty && w.github.openRequests.isEmpty)
        #expect(try w.cards().isEmpty)
        #expect(!w.github.requests.contains { $0.hasPrefix("POST") })
        // Granted, but GitHub rejects the push: still `pushing`, with the reason; nothing opened.
        w.gate.inner = Self.granted
        w.runner.mode = .reject
        await w.machine.advance(itemId: item.id)
        landing = try w.landing(item)
        #expect(landing.state == .pushing && landing.lastError?.contains("rejected") == true, "\(landing)")
        #expect(w.runner.pushes.count == 1 && w.github.openRequests.isEmpty)
        // No repository linked: held with that reason, GitHub not asked.
        let unlinked = PRLandingMachine(store: w.store, github: w.github, gate: w.gate, push: w.env.stage(github: w.github, gate: NoChannelGate(),
                                        push: GitPush(runner: w.runner, tempRoot: try tempDir())), repo: { _ in nil })
        let before = w.github.requests.count
        await unlinked.advance(itemId: item.id)
        #expect(try w.landing(item).lastError == PRLandingMachine.noRepoText)
        #expect(w.github.requests.count == before)
    }

    @Test func openPRUsesBrahmaHeadAndDefaultBase() async throws {
        let w = try World(defaultBranch: "trunk")
        let (item, sha) = try w.handedOff("Fix the @here banner", ["b.txt": "b\n"], summary: "Done.\n## Merge now\nFixes #99 @octocat")
        await w.machine.begin(item: item, verifiedSHA: sha)
        let landing = try w.landing(item)
        #expect(landing.state == .open, "\(landing)")
        let sent = try #require(w.github.openRequests.first)
        #expect(sent.head == landing.branch && sent.head.hasPrefix("brahma/\(item.key)-"))
        #expect(sent.base == "trunk", "the repository's default branch, read fresh")
        #expect(sent.maintainerCanModify == false)
        let json = String(decoding: try JSONEncoder().encode(sent), as: UTF8.self)
        #expect(json.contains("\"maintainer_can_modify\":false"), "\(json)")
        #expect(sent.title == "\(item.key): Fix the @\(PRBody.neutralizer)here banner")
        // The body is the engine's: its sections, the item's criteria in code, and the author's summary only inside the fence.
        #expect(sent.body.hasPrefix("## Summary\n\n- Item: `\(item.key)`\n"), "\(sent.body)")
        #expect(sent.body.contains("- [ ] `it works`"))
        #expect(sent.body.contains("Source: `submit summary by @eng-1`"))
        #expect(PRBodyTests.block(sent.body) == ["> ```", "> Done.", "> ## Merge now", "> Fixes #99 @octocat", "> ```"], "\(sent.body)")
        let parsed = PRBodyTests.parsed(sent.body).joined(separator: "\n")
        #expect(!parsed.contains("Fixes #99") && !parsed.contains("@octocat") && !parsed.contains("Merge now"))
        #expect(try w.landing(item).openDigest == PRBody.contentDigest(title: sent.title, body: sent.body))
        let pull = try #require(w.github.snapshot(Self.repo)?.pulls.first)
        #expect(pull.head == landing.branch && pull.base == "trunk" && pull.maintainerCanModify == false && pull.headSHA == sha)
        #expect(w.github.requests.contains("POST /repos/acme/app/pulls"))
    }

    /// The POST's answer is lost after GitHub opened the PR: the landing is reconciled by listing the PRs for its head, never
    /// opened a second time. Lost before GitHub saw it: nothing found, the landing holds at `opening`, and the next pass reads
    /// back first and only then opens.
    @Test func unknownOpenReconcilesByHead() async throws {
        let w = try World()
        let (item, sha) = try w.handedOff("Lost answer", ["l.txt": "l\n"])
        w.github.failNextOpen(.lostResponse)
        await w.machine.begin(item: item, verifiedSHA: sha)
        var landing = try w.landing(item)
        #expect(landing.state == .open && landing.prNumber == 1 && landing.prURL == "https://github.com/acme/app/pull/1", "\(landing)")
        #expect(w.github.openRequests.count == 1, "never opened twice")
        let list = "GET /repos/acme/app/pulls?head=acme:\(landing.branch)&state=all"
        #expect(w.github.requests.suffix(2) == ["POST /repos/acme/app/pulls", list], "\(w.github.requests)")
        #expect(w.github.snapshot(Self.repo)?.pulls.count == 1)

        let (other, otherSHA) = try w.handedOff("Lost request", ["m.txt": "m\n"])
        w.github.failNextOpen(.lostRequest)
        await w.machine.begin(item: other, verifiedSHA: otherSHA)
        landing = try w.landing(other)
        #expect(landing.state == .opening && landing.prNumber == nil, "\(landing)")
        #expect(landing.lastError?.contains("may not have been opened") == true && landing.lastError?.contains("no pull request for") == true)
        let otherList = "GET /repos/acme/app/pulls?head=acme:\(landing.branch)&state=all"
        let before = w.github.requests.count
        await w.machine.advance(itemId: other.id)
        landing = try w.landing(other)
        #expect(landing.state == .open && landing.prNumber == 2, "\(landing)")
        let after = Array(w.github.requests.dropFirst(before))
        let listed = try #require(after.firstIndex(of: otherList)), posted = try #require(after.firstIndex(of: "POST /repos/acme/app/pulls"))
        #expect(listed < posted, "read back before opening again: \(after)")
        #expect(w.github.snapshot(Self.repo)?.pulls.filter { $0.head == landing.branch }.count == 1)
        // GitHub stored the body with CRLF line endings: still the engine's content (Ruling 28 normalizes before digesting).
        #expect(PRBody.contentDigest(title: "t", body: "a\r\nb\r\n") == PRBody.contentDigest(title: "t", body: "a\nb\n"))
        #expect(PRBody.contentDigest(title: "t", body: "a\nb") != PRBody.contentDigest(title: "t", body: "a\nc"))
    }

    /// Ruling 28: a PR someone else opened on the engine's branch before its POST (GitHub then refuses the engine's with 422)
    /// is never adopted — its title and body are not what the engine sent. The landing holds for the owner, never posts again
    /// while that PR is open, and opens its own once it is closed.
    @Test func foreignPROnHeadIsNeverAdopted() async throws {
        let w = try World()
        let (item, sha) = try w.handedOff("Taken head", ["f.txt": "f\n"])
        let branch = try #require(PRBranch.name(key: item.key, title: item.title).value)
        w.github.update(Self.repo) {
            $0.branches[branch] = sha
            $0.pulls.append(FakeGitHub.PullRequest(number: 9, head: branch, headSHA: sha, base: "main", baseSHA: "", title: "Merge me",
                                                   body: "Fixes #1 @everyone"))
        }
        await w.machine.begin(item: item, verifiedSHA: sha)
        var landing = try w.landing(item)
        let text = "a pull request Brahma did not open exists on \(branch) (#9); close it or abandon the landing"
        #expect(landing.state == .opening && landing.prNumber == nil && landing.lastError == text, "\(landing)")
        #expect(w.github.openRequests.count == 1 && w.runner.pushes.isEmpty, "the branch held the commit: no push; one POST, refused")
        // While it is open: held, and no second POST.
        await w.machine.advance(itemId: item.id)
        landing = try w.landing(item)
        #expect(landing.prNumber == nil && landing.lastError == text)
        #expect(w.github.openRequests.count == 1)
        // The engine's own content on the right head but against another base is not adopted either.
        let ours = try #require(w.github.openRequests.first)
        w.github.update(Self.repo) { $0.pulls[0].title = ours.title; $0.pulls[0].body = ours.body; $0.pulls[0].base = "release" }
        await w.machine.advance(itemId: item.id)
        #expect(try w.landing(item).prNumber == nil && w.landing(item).lastError == text)
        // Closed: the engine opens its own.
        w.github.update(Self.repo) { $0.pulls[0].state = "closed" }
        await w.machine.advance(itemId: item.id)
        landing = try w.landing(item)
        #expect(landing.state == .open && landing.prNumber == 10, "\(landing)")
        #expect(w.github.openRequests.count == 2)
    }

    @Test func closedUpstreamNotifies() async throws {
        let w = try World()
        let (item, sha) = try w.handedOff("Closed later", ["c.txt": "c\n"])
        await w.machine.begin(item: item, verifiedSHA: sha)
        #expect(try w.landing(item).state == .open)
        // Still open on GitHub: nothing changes.
        await w.machine.advance(itemId: item.id)
        #expect(try w.landing(item).state == .open)
        w.github.update(Self.repo) { $0.pulls[0].state = "closed" }
        await w.machine.advance(itemId: item.id)
        let landing = try w.landing(item)
        #expect(landing.state == .closedUpstream && landing.lastError == "PR #1 was closed on GitHub without merging", "\(landing)")
        // The item's owner agent gets a work notice, and only it.
        let notices = try w.store.writer.read { db in
            try Row.fetchAll(db, sql: """
                SELECT n.agentId, n.wakes, e.kind, e.text FROM workNotice n JOIN workItemEvent e ON e.id = n.eventId
                WHERE e.itemId = ? AND e.kind = 'mergeFailed'
                """, arguments: [item.id])
        }
        #expect(notices.count == 1, "\(notices)")
        #expect(notices.first?["agentId"] as String? == w.eng.id)
        #expect(notices.first?["wakes"] as Bool? == true)
        #expect((notices.first?["text"] as String?)?.contains("PR #1 was closed on GitHub without merging") == true)
        // Closed is final: later passes read nothing and change nothing.
        let calls = w.github.requests.count
        await w.machine.advance(itemId: item.id)
        #expect(w.github.requests.count == calls)
        #expect(try w.landing(item).state == .closedUpstream)
        // A merged PR is not a close upstream: the landing is merged (Task 5's merge step).
        let (merged, mergedSHA) = try w.handedOff("Merged upstream", ["d.txt": "d\n"])
        await w.machine.begin(item: merged, verifiedSHA: mergedSHA)
        w.github.humanMerge(Self.repo, number: 2)
        await w.machine.advance(itemId: merged.id)
        #expect(try w.landing(merged).state == .merged)
    }

    // MARK: Ruling 26

    /// The company's first push asks: one owner card (re-ticks file no second), nothing pushed while it waits; the owner's
    /// approval runs exactly one push; a resubmitted item (a new sha) needs a new card, and the old pending one is superseded;
    /// a decline runs nothing.
    @Test func askFilesOneOwnerCardAndApprovalRunsOnce() async throws {
        let w = try World(firstPushDone: false)
        let (item, sha) = try w.handedOff("First push", ["src/a.swift": "let a = 1\n", "docs/b.md": "b\n"])
        await w.machine.begin(item: item, verifiedSHA: sha)
        var landing = try w.landing(item)
        let reason = "the company's first push to GitHub asks you first"
        #expect(landing.state == .pushing && landing.lastError == "waiting for the owner: \(reason)", "\(landing)")
        var cards = try w.cards()
        #expect(cards.count == 1)
        let card = try #require(cards.first)
        #expect(card.kind == .prAction && card.kind.isReservedKind && card.status == .pendingOwner && card.requesterId == "system")
        #expect(card.itemId == item.id && card.requestId == "pr-push-branch-\(item.id)-\(sha)")
        let details = try #require(card.payload?.details)
        for fact in ["Action: push-branch (modify; reversible)", "Item: \(item.key)", "Ref: refs/heads/\(landing.branch)", "Commit: \(sha)",
                     "Why it asks: \(reason)", "Diffstat: 2 files changed, 2 insertions(+)", "    | docs/b.md\n    | src/a.swift"] {
            #expect(details.contains(fact), "\(fact): \(details)")
        }
        // Re-ticks: no second card, no push.
        await w.machine.advance(itemId: item.id)
        await w.machine.advance(itemId: item.id)
        #expect(try w.cards().count == 1)
        #expect(w.runner.pushes.isEmpty)
        // The owner approves it: exactly one push, then the PR (open-pr is within the grant).
        try w.store.ownerDecide(askId: card.id, approve: true)
        #expect(try w.approvals().map { $0.isUsable } == [true])
        await w.machine.advance(itemId: item.id)
        landing = try w.landing(item)
        #expect(landing.state == .open, "\(landing)")
        #expect(w.runner.pushes == ["\(sha):refs/heads/\(landing.branch)"])
        #expect(try w.approvals().allSatisfy { $0.consumedAt != nil }, "used once")
        await w.machine.advance(itemId: item.id)
        #expect(w.runner.pushes.count == 1)

        // Resubmitted (a new sha) to a repository made public: the old approval does not carry; a new card.
        w.github.update(Self.repo) { $0.visibility = "public" }
        let sha2 = try w.env.commit(["src/a.swift": "let a = 2\n"])
        try w.handOff(item, sha2)
        await w.machine.begin(item: item, verifiedSHA: sha2)
        cards = try w.cards()
        #expect(cards.count == 2 && cards[1].requestId == "pr-push-branch-\(item.id)-\(sha2)" && cards[1].status == .pendingOwner)
        #expect(w.runner.pushes.count == 1)
        #expect(try w.landing(item).lastError == "waiting for the owner: the repository is public, not private")
        // Resubmitted again before the owner decided: that card is superseded, a third is filed.
        let sha3 = try w.env.commit(["src/a.swift": "let a = 3\n"])
        try w.handOff(item, sha3)
        await w.machine.begin(item: item, verifiedSHA: sha3)
        cards = try w.cards()
        #expect(cards.map(\.status) == [.approved, .superseded, .pendingOwner])
        // The owner declines: nothing runs, and the landing says so.
        try w.store.ownerDecide(askId: cards[2].id, approve: false, note: "not this one")
        await w.machine.advance(itemId: item.id)
        #expect(try w.landing(item).lastError == "the owner declined: the repository is public, not private")
        #expect(w.runner.pushes.count == 1)
        #expect(try w.cards().count == 3)
    }

    /// An approval answers the gate's `ask`, never its `refuse`: with the kill switch on, the approved push does not run and
    /// the approval stays unused.
    @Test func refuseBeatsApproval() async throws {
        let w = try World(firstPushDone: false)
        let (item, sha) = try w.handedOff("Approved then refused", ["k.txt": "k\n"])
        await w.machine.begin(item: item, verifiedSHA: sha)
        let card = try #require(try w.cards().first)
        try w.store.ownerDecide(askId: card.id, approve: true)
        w.gate.inner = RulesGate(killSwitch: true, granted: Self.granted.granted)
        await w.machine.advance(itemId: item.id)
        let landing = try w.landing(item)
        #expect(landing.state == .pushing && landing.lastError == "kill switch", "\(landing)")
        #expect(w.runner.pushes.isEmpty)
        #expect(try w.approvals().map(\.isUsable) == [true], "unused")
        #expect(w.gate.requests.last?.type == .pushBranch)
        // The switch off again: the approval runs the push.
        w.gate.inner = Self.granted
        await w.machine.advance(itemId: item.id)
        #expect(try w.landing(item).state == .open)
        #expect(w.runner.pushes.count == 1)
        // The approval answers only the exact request it was given for: another item, another action or any changed fact
        // stays an ask; a refuse stays a refuse.
        let approvedRequest = PRActionRequest(type: .pushBranch, companyId: "c", itemId: item.id, taintedSession: true, itemTainted: false,
                                              externalInput: false, firstUse: false, repoVisibility: "private")
        let inner = RulesGate(granted: [])
        guard case .ask(let reason) = await inner.decide(approvedRequest) else { Issue.record("the rules did not ask"); return }
        let url = Self.repo.pushURL
        let approval = (askId: "A", digest: PRActionDigest.of(approvedRequest, reason: reason, sha: sha, repoURL: url, open: nil))
        let cardGate = CardGate(inner: inner, action: .pushBranch, itemId: item.id, sha: sha, repoURL: url, open: nil, approved: approval)
        #expect(await cardGate.decide(approvedRequest) == .auto)
        var other = approvedRequest
        other.itemId = "another"
        #expect(await cardGate.decide(other) == .ask(reason: reason))
        var otherAction = approvedRequest
        otherAction.type = .openPR
        #expect(await cardGate.decide(otherAction) == .ask(reason: reason))
        var changed = approvedRequest
        changed.repoVisibility = "public"
        guard case .ask = await cardGate.decide(changed) else { Issue.record("a changed request was answered"); return }
        let refusing = CardGate(inner: RulesGate(killSwitch: true), action: .pushBranch, itemId: item.id, sha: sha, repoURL: url, open: nil,
                                approved: approval)
        #expect(await refusing.decide(approvedRequest) == .refuse(rule: "kill switch"))
        // Fix round 2 (M1): another repository is another request.
        let elsewhere = CardGate(inner: inner, action: .pushBranch, itemId: item.id, sha: sha, repoURL: "https://github.com/acme/other.git",
                                 open: nil, approved: approval)
        #expect(await elsewhere.decide(approvedRequest) == .ask(reason: reason))
        // And for a push, the change itself (diffstat, paths) is part of what was approved.
        let payload = PushPayload(sha: sha, ref: "refs/heads/brahma/X", url: url, itemKey: item.key, diffstat: " 1 file changed", paths: ["a.txt"],
                                  touchesWorkflows: false)
        var withPayload = approvedRequest
        withPayload.payload = payload
        var otherPaths = withPayload
        otherPaths.payload?.paths = ["b.txt"]
        #expect(PRActionDigest.of(withPayload, reason: reason, sha: sha, repoURL: url, open: nil)
                != PRActionDigest.of(otherPaths, reason: reason, sha: sha, repoURL: url, open: nil))
    }

    /// A `pushing` landing (a failed or unconfirmed push, a crash after sending) reads the branch on GitHub before pushing
    /// again: holding the commit, it is `pushed` without a push; else it is pushed once.
    @Test func pushingRowReconcilesBeforeRepush() async throws {
        let w = try World()
        let (item, sha) = try w.handedOff("Hung up", ["h.txt": "h\n"])
        let branch = try #require(PRBranch.name(key: item.key, title: item.title).value)
        // The connection drops after GitHub took the pack: the stage reconciles by the branch and finds it pushed.
        w.runner.mode = .hangUp
        w.github.update(Self.repo) { $0.branches[branch] = sha }
        try w.store.upsertPRLanding(PRLanding(itemId: item.id, companyId: item.companyId, branch: branch, pushedSHA: sha, state: .pushing,
                                              lastError: "the push may not have landed", updatedAt: Date(timeIntervalSince1970: 1_800_000_000)))
        await w.machine.advance(itemId: item.id)
        #expect(w.runner.pushes.isEmpty, "the branch already holds the commit: no second push")
        #expect(w.github.requests.first == "GET /repos/acme/app/branches/\(branch)", "\(w.github.requests)")
        #expect(try w.landing(item).state == .open)

        // Not there: pushed once (and a hang-up then is reconciled by the stage, never pushed a third time).
        let (lost, lostSHA) = try w.handedOff("Never landed", ["n.txt": "n\n"])
        let lostBranch = try #require(PRBranch.name(key: lost.key, title: lost.title).value)
        try w.store.upsertPRLanding(PRLanding(itemId: lost.id, companyId: lost.companyId, branch: lostBranch, pushedSHA: lostSHA, state: .pushing,
                                              lastError: "the push failed", updatedAt: Date(timeIntervalSince1970: 1_800_000_000)))
        await w.machine.advance(itemId: lost.id)
        #expect(w.runner.pushes == ["\(lostSHA):refs/heads/\(lostBranch)"])
        let landing = try w.landing(lost)
        #expect(landing.state == .pushing && landing.lastError?.contains("does not hold") == true, "\(landing)")
        // GitHub unreadable: nothing pushed blind.
        w.github.setDown(true)
        await w.machine.advance(itemId: lost.id)
        #expect(w.runner.pushes.count == 1)
        #expect(try w.landing(lost).lastError?.hasPrefix("could not read \(lostBranch) on GitHub") == true)
    }

    /// Ruling 21: only the owner abandons a landing; an abandoned landing is never taken up again for the same commit.
    @Test func abandonIsTheOwnersAndFinal() async throws {
        let w = try World(gate: NoChannelGate())
        let (item, sha) = try w.handedOff("Abandon me", ["z.txt": "z\n"])
        await w.machine.begin(item: item, verifiedSHA: sha)
        for sender in [Sender.agent(w.eng.id), .system] {
            await #expect(throws: WorkError.forbidden(Store.prAbandonOwnerOnly)) { try await w.machine.abandon(itemId: item.id, reason: "x", by: sender) }
        }
        try await w.machine.abandon(itemId: item.id, reason: "not needed", by: .owner)
        let abandoned = try w.landing(item)
        #expect(abandoned.state == .abandoned && abandoned.lastError == "abandoned by the owner: not needed")
        w.gate.inner = Self.granted
        await w.machine.begin(item: item, verifiedSHA: sha)
        await w.machine.advance(itemId: item.id)
        #expect(try w.landing(item).state == .abandoned)
        #expect(w.runner.pushes.isEmpty)
    }

    // MARK: Fix round 1

    /// The rules, plus: every `open-pr` asks the owner.
    struct AskOpenGate: PRActionGate {
        func decide(_ r: PRActionRequest) async -> PRActionDecision {
            if r.type == .openPR { return .ask(reason: "open-pr asks the owner") }
            return await PRLandingMachineTests.granted.decide(r)
        }
    }

    /// Errors a hook could not throw.
    final class Errors: @unchecked Sendable {
        private let lock = NSLock()
        private var seen: [String] = []
        func add(_ e: Error) { lock.withLock { seen.append("\(e)") } }
        var all: [String] { lock.withLock { seen } }
    }

    /// I1: every landing write is a compare-and-set on what the pass read. An owner's abandon during the push, before the POST or
    /// during it, and a newer commit during the POST, are never overwritten: no push is recorded over them, no PR is opened for
    /// an abandoned landing, and the old commit's PR is not attached to the new commit before the new one is pushed.
    @Test func landingWritesNeverOverwriteAConcurrentChange() async throws {
        let w = try World()
        let errors = Errors()
        let store = w.store
        // Abandoned while the push runs: the push lands on GitHub, but the landing stays abandoned and nothing is opened.
        let (a, aSHA) = try w.handedOff("Abandon during push", ["a.txt": "a\n"])
        w.runner.onPush {
            do { try store.abandonPRLanding(itemId: a.id, reason: "stop", by: .owner) } catch { errors.add(error) }
        }
        await w.machine.begin(item: a, verifiedSHA: aSHA)
        w.runner.onPush(nil)
        #expect(try w.landing(a).state == .abandoned && w.landing(a).lastError == "abandoned by the owner: stop")
        #expect(w.runner.pushes.count == 1 && w.github.openRequests.isEmpty)
        // Abandoned after the push, before the POST (on the repository read of the open step): no POST.
        let (b, bSHA) = try w.handedOff("Abandon before open", ["b.txt": "b\n"])
        w.github.onRequest { line in
            guard line == "GET /repos/acme/app", PRLandingMachineTests.state(store, b.id) == "pushed" else { return }
            do { try store.abandonPRLanding(itemId: b.id, reason: "no", by: .owner) } catch { errors.add(error) }
        }
        await w.machine.begin(item: b, verifiedSHA: bSHA)
        #expect(try w.landing(b).state == .abandoned)
        #expect(w.github.openRequests.isEmpty, "no PR for an abandoned landing")
        // Abandoned while the POST is in flight: the PR exists on GitHub, the landing stays abandoned with no PR recorded.
        let (c, cSHA) = try w.handedOff("Abandon during open", ["c.txt": "c\n"])
        w.github.onRequest { line in
            guard line == "POST /repos/acme/app/pulls" else { return }
            do { try store.abandonPRLanding(itemId: c.id, reason: "late", by: .owner) } catch { errors.add(error) }
        }
        await w.machine.begin(item: c, verifiedSHA: cSHA)
        #expect(try w.landing(c).state == .abandoned && w.landing(c).prNumber == nil)
        #expect(w.github.openRequests.count == 1)
        // A newer commit handed off while the POST for the older one is in flight.
        let (d, d1) = try w.handedOff("Resubmitted during open", ["d.txt": "1\n"])
        let d2 = try w.env.commit(["d.txt": "2\n"])
        try w.handOff(d, d2)
        let branch = try #require(PRBranch.name(key: d.key, title: d.title).value)
        w.github.onRequest { line in
            guard line == "POST /repos/acme/app/pulls" else { return }
            do { _ = try store.beginPRLanding(item: d, sha: d2, branch: branch, now: Date()) } catch { errors.add(error) }
        }
        await w.machine.begin(item: d, verifiedSHA: d1)
        w.github.onRequest(nil)
        var landing = try w.landing(d)
        #expect(landing.state == .pushing && landing.pushedSHA == d2 && landing.prNumber == nil, "sha1's PR not attached to sha2: \(landing)")
        #expect(w.runner.pushes.last == "\(d1):refs/heads/\(branch)")
        // The next pass pushes the new commit first; only then is the PR (whose head followed the branch) the landing's.
        await w.machine.advance(itemId: d.id)
        landing = try w.landing(d)
        #expect(w.runner.pushes.suffix(2) == ["\(d1):refs/heads/\(branch)", "\(d2):refs/heads/\(branch)"])
        #expect(landing.state == .open && landing.pushedSHA == d2, "\(landing)")
        let pr = try #require(w.github.snapshot(Self.repo)?.pulls.first { $0.number == landing.prNumber })
        #expect(pr.headSHA == d2 && pr.head == branch)
        #expect(errors.all.isEmpty, "\(errors.all)")
    }

    /// Rulings X8-21 and 29: an approval answers only the request the owner saw. A renamed item (another PR title), a new commit
    /// or a repository made public after the approval: nothing runs, the old card answers nothing, and a fresh card is filed.
    @Test func approvalBindsToWhatTheOwnerSaw() async throws {
        let w = try World(gate: AskOpenGate())
        let (item, sha) = try w.handedOff("Original title", ["o.txt": "o\n"])
        await w.machine.begin(item: item, verifiedSHA: sha)
        var cards = try w.cards()
        try #require(cards.count == 1)
        #expect(cards[0].requestId == "pr-open-pr-\(item.id)-\(sha)", "\(cards.map(\.requestId))")
        #expect(cards[0].payload?.details?.contains("Title (from the item: agent-influenced, untrusted): \(item.key): Original title") == true)
        try w.store.ownerDecide(askId: cards[0].id, approve: true)
        _ = try w.store.updateWorkItem(id: item.id, by: .owner, patch: WorkItemPatch(title: "Renamed title"))
        await w.machine.advance(itemId: item.id)
        #expect(w.github.openRequests.isEmpty, "the approved title is not what would be sent")
        cards = try w.cards()
        try #require(cards.count == 2)
        #expect(cards[1].status == .pendingOwner && cards[1].requestId == "pr-open-pr-\(item.id)-\(sha)-2")
        #expect(try w.approvals().map(\.askId) == [cards[1].id], "the old card answers nothing")
        #expect(try w.landing(item).lastError == "waiting for the owner: open-pr asks the owner")
        try w.store.ownerDecide(askId: cards[1].id, approve: true)
        await w.machine.advance(itemId: item.id)
        #expect(w.github.openRequests.map(\.title) == ["\(item.key): Renamed title"])
        #expect(try w.landing(item).state == .open)
        #expect(try w.approvals().allSatisfy { $0.consumedAt != nil })

        // A new commit: the approval for the old one does not open the PR for the new one.
        let (other, o1) = try w.handedOff("Other", ["p.txt": "1\n"])
        await w.machine.begin(item: other, verifiedSHA: o1)
        let first = try #require(try w.cards().last)
        try w.store.ownerDecide(askId: first.id, approve: true)
        let o2 = try w.env.commit(["p.txt": "2\n"])
        try w.handOff(other, o2)
        let posts = w.github.openRequests.count
        await w.machine.begin(item: other, verifiedSHA: o2)
        #expect(w.github.openRequests.count == posts)
        #expect(try w.cards().last?.requestId == "pr-open-pr-\(other.id)-\(o2)")

        // A repository made public after the owner approved the first push: no push; a fresh card shows the new facts.
        let v = try World(firstPushDone: false)
        let (pushed, pushSHA) = try v.handedOff("Visibility", ["v.txt": "v\n"])
        await v.machine.begin(item: pushed, verifiedSHA: pushSHA)
        let approved = try #require(try v.cards().first)
        try v.store.ownerDecide(askId: approved.id, approve: true)
        v.github.update(Self.repo) { $0.visibility = "public" }
        await v.machine.advance(itemId: pushed.id)
        #expect(v.runner.pushes.isEmpty)
        let fresh = try v.cards()
        try #require(fresh.count == 2)
        #expect(fresh[1].status == .pendingOwner && fresh[0].status == .approved)
        #expect(try v.approvals().map(\.askId) == [fresh[1].id])
        try v.store.ownerDecide(askId: fresh[1].id, approve: true)
        await v.machine.advance(itemId: pushed.id)
        #expect(v.runner.pushes.count == 1)

        // Fix round 2 (M1): the company's repository is relinked after the owner approved a push: no push to the other
        // repository on that approval; a fresh card names it.
        let r = try World(firstPushDone: false)
        let (moved, movedSHA) = try r.handedOff("Relinked", ["r.txt": "r\n"])
        await r.machine.begin(item: moved, verifiedSHA: movedSHA)
        let approvedCard = try #require(try r.cards().first)
        try r.store.ownerDecide(askId: approvedCard.id, approve: true)
        let otherRepo = GitHubRepoRef(owner: "acme", name: "other")
        let otherGitHub = FakeGitHub(otherRepo)
        let relinked = PRLandingMachine(store: r.store, github: otherGitHub, gate: r.gate,
                                        push: r.env.stage(github: otherGitHub, gate: NoChannelGate(), push: GitPush(runner: r.runner, tempRoot: try tempDir())),
                                        repo: { _ in otherRepo })
        await relinked.advance(itemId: moved.id)
        #expect(r.runner.pushes.isEmpty, "the approval named acme/app")
        let relinkCards = try r.cards()
        try #require(relinkCards.count == 2)
        #expect(relinkCards[1].status == .pendingOwner && relinkCards[1].payload?.details?.contains("Repository: https://github.com/acme/other.git") == true)
        #expect(try r.approvals().map(\.askId) == [relinkCards[1].id])
    }

    /// I4: whatever the agent text, the card fits the ask's limit and files; it shows every engine line of the body (the
    /// headings, the cut notice, every `Fixes #n`) and cuts only agent text; the body's agent block stays within 4 KiB rendered.
    @Test func cardAlwaysFilesAndShowsEveryEngineLine() async throws {
        let w = try World(gate: AskOpenGate())
        let criteria = (1...50).map { "criterion \($0) " + String(repeating: "&", count: 280) }.joined(separator: "\n")
        let created = try w.store.createWorkItem(companyId: w.env.company.id, by: .owner,
                                                 draft: WorkItemDraft(type: .task, title: "Big", ownerId: w.eng.id))
        let summary = Array(repeating: "&", count: 2000).joined(separator: "\n")
        // Past the store's own 10,000-character limit on criteria (an older or imported item): the card must still file.
        try await w.store.writer.write { db in
            try db.execute(sql: "UPDATE workItem SET submitSummary = ?, originURL = ?, acceptanceCriteria = ? WHERE id = ?",
                           arguments: [summary, "https://github.com/acme/app/issues/7", criteria, created.id])
        }
        let item = try #require(try w.store.workItem(id: created.id))
        let sha = try w.env.commit(["big.txt": "b\n"])
        try w.handOff(item, sha)
        await w.machine.begin(item: item, verifiedSHA: sha)
        let card = try #require(try w.cards().first)
        let details = try #require(card.payload?.details)
        #expect(details.count <= Store.maxAskText)
        for line in ["    | ## Summary", "    | ## Acceptance criteria", "    | ## Agent notes (untrusted)", "    | Fixes #7",
                     "    | (the notes were cut to 4 KiB rendered; they had \(summary.utf8.count) bytes)"] {
            #expect(details.contains(line), "\(line)")
        }
        #expect(details.contains("of agent text not shown]"))
        let body = try PRBodyInputs.recorded(store: w.store, item: item, repo: Self.repo).render(item: item)
        #expect((PRBodyTests.block(body).joined(separator: "\n") + "\n").utf8.count <= PRBody.notesCap)

        // A push of many long paths: its card files too, every fact shown.
        let p = try World(firstPushDone: false)
        var files: [String: String] = [:]
        for i in 0..<200 { files["dir/\(String(repeating: "n", count: 150))-\(i).txt"] = "\(i)\n" }
        let (many, manySHA) = try p.handedOff("Many", files)
        await p.machine.begin(item: many, verifiedSHA: manySHA)
        let pushCard = try #require(try p.cards().first)
        let pushDetails = try #require(pushCard.payload?.details)
        #expect(pushDetails.count <= Store.maxAskText && pushDetails.contains("Diffstat: 200 files changed") && pushDetails.contains("not shown]"))
    }
}
