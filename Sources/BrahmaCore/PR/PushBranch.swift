import Foundation

/// What one `push-branch` came to.
public enum PushBranchOutcome: Equatable, Sendable {
    /// On GitHub: the branch holds the verified commit (pushed, or an unknown push reconciled by reading the branch).
    case pushed(PushPayload)
    /// The gate asked: nothing was pushed; the owner's card shows `payload` (`diffstat`, `paths`).
    case needsOwner(reason: String, payload: PushPayload)
    /// Refused before anything reached GitHub: the branch name, a pre-push scan, the gate, the op's checks, the token.
    case refused(String)
    /// The push was tried and did not land (a rejection, or an unknown outcome the branch did not confirm). Never retried here.
    case failed(String)
}

/// The `push-branch` flow (spec §8.5.1 step 3, §9.4), engine-side end to end:
/// 1. the branch name (`PRBranch`), then `PrePushScan` — a hit refuses and no `PRActionRequest` is filed;
/// 2. the repository's visibility, read fresh (`GitHubAPI.repo`), and the request through the one gate (`PRActionGate`);
/// 3. `auto` only: the landing is recorded `pushing` (sending), the token read from the secret store into a `TokenHandle`, and
///    `GitPush` run; `pushed` records `pushed`; `unknown` is reconciled by reading the branch (`GitHubAPI.branch`: its head is
///    the commit → pushed, else failed), never by pushing again.
/// The scans, the token read and the push run through the engine's `Blocking` (threads of their own, never a Swift concurrency
/// worker: `Blocking.swift`); only the GitHub reads and the database records are awaited on the caller's task.
public struct PushBranchStage: Sendable {
    let store: Store
    let github: any GitHubAPI
    let gate: any PRActionGate
    let push: GitPush
    let blobs: any BlobPointerScanning
    /// The push token for a company, from the secret store at the moment of use (`TokenHandle.load`).
    let token: @Sendable (_ companyId: String) throws -> TokenHandle
    /// The company's secret values the scan looks for (`Store.knownSecretValues`).
    let knownValues: @Sendable (_ companyId: String) -> [(String, String)]
    let clock: @Sendable () -> Date
    /// Where the git work runs: the engine's own (`Orchestrator.blocking`) when Task 3 wires the stage, else one of its own.
    let blocking: Blocking

    public init(store: Store, github: any GitHubAPI, gate: any PRActionGate, push: GitPush, blobs: any BlobPointerScanning,
                token: @escaping @Sendable (String) throws -> TokenHandle, knownValues: @escaping @Sendable (String) -> [(String, String)],
                clock: @escaping @Sendable () -> Date = Store.now) {
        self.init(store: store, github: github, gate: gate, push: push, blobs: blobs, token: token, knownValues: knownValues, clock: clock,
                  blocking: Blocking())
    }

    /// The engine's: its `Blocking`, so the push's git shares the engine's slots.
    init(store: Store, github: any GitHubAPI, gate: any PRActionGate, push: GitPush, blobs: any BlobPointerScanning,
         token: @escaping @Sendable (String) throws -> TokenHandle, knownValues: @escaping @Sendable (String) -> [(String, String)],
         clock: @escaping @Sendable () -> Date = Store.now, blocking: Blocking) {
        self.store = store; self.github = github; self.gate = gate; self.push = push; self.blobs = blobs
        self.token = token; self.knownValues = knownValues; self.clock = clock; self.blocking = blocking
    }

    /// The production token source: `GITHUB_PUSH_TOKEN` of the company, engine-only, read without prompting.
    public static func vaultToken(store: Store, vault: any SecretVault) -> @Sendable (String) throws -> TokenHandle {
        { companyId in try TokenHandle.load(companyId: companyId, name: LandingSwitch.tokenSecretName, store: store, vault: vault) }
    }

    /// Pushes `verifiedSHA` (already rebased onto `base`, the remote `main` it was verified on) for `item` to `repo`.
    public func run(item: WorkItem, repo: GitHubRepoRef, verifiedSHA: String, base: String, git: GitWorkspace) async -> PushBranchOutcome {
        let named = PRBranch.name(key: item.key, title: item.title)
        guard case .allowed(let branch) = named else { return .refused(named.refusal ?? "no branch name") }
        let target = PushTarget(itemKey: item.key, ref: PRBranch.ref(branch), url: repo.pushURL)
        // 1. The scans, before any request exists.
        let scanned: PRDecision<PushPayload>
        let (blobs, known) = (self.blobs, knownValues(item.companyId))
        do {
            scanned = try await blocking.tryRun {
                try PrePushScan.run(target: target, base: base, head: verifiedSHA, git: git, blobs: blobs, knownValues: known)
            }
        } catch {
            return .refused("the pre-push scan could not run: \(Store.flat("\(error)", max: 200))")
        }
        guard case .allowed(let payload) = scanned else { return .refused(scanned.refusal ?? "the pre-push scan refused") }
        // 2. The request, with the visibility read now (never the connect-time value), through the one gate.
        let visibility: String
        do { visibility = try await github.repo(repo).visibility } catch {
            return .refused("could not read \(repo.owner)/\(repo.name) on GitHub: \(Store.flat("\(error)", max: 200))")
        }
        let request: PRActionRequest
        do {
            request = PRActionRequest(type: .pushBranch, companyId: item.companyId, itemId: item.id, payload: payload,
                                      taintedSession: try sessionTainted(item), itemTainted: item.taintedOrigin, externalInput: false,
                                      firstUse: !(try store.hasPushedPRLanding(companyId: item.companyId)), repoVisibility: visibility)
        } catch {
            return .refused("could not read the item's state: \(Store.flat("\(error)", max: 200))")
        }
        switch await gate.decide(request) {
        case .refuse(let rule): return .refused(rule)
        case .ask(let reason): return .needsOwner(reason: reason, payload: payload)
        case .auto: break
        }
        // 3. Sending: recorded first, so a crash after this point is reconciled, not pushed blind a second time.
        do { try record(item, branch: branch, sha: verifiedSHA, state: .pushing, error: nil) } catch {
            return .refused("could not record the push: \(Store.flat("\(error)", max: 200))")
        }
        let handle: TokenHandle
        let (token, companyId) = (self.token, item.companyId)
        do { handle = try await blocking.tryRun { try token(companyId) } } catch {
            return fail(item, branch, verifiedSHA, "the push token \(LandingSwitch.tokenSecretName) is not usable: \(Store.flat("\(error)", max: 160))")
        }
        let outcome: GitPushOutcome
        let (push, pushRequest) = (self.push, GitPushRequest(gitCommonDir: git.root.appending(path: ".git", directoryHint: .isDirectory),
                                                        sha: verifiedSHA, ref: target.ref, url: target.url))
        do {
            outcome = try await blocking.tryRun { try push.run(pushRequest, token: handle) }
        } catch {
            return fail(item, branch, verifiedSHA, "the push could not start: \(Store.flat("\(error)", max: 200))")
        }
        switch outcome {
        case .pushed:
            return pushed(item, branch, payload)
        case .refused(let why), .failed(let why):
            return fail(item, branch, verifiedSHA, why)
        case .unknown(let why):
            // Never a blind retry: GitHub says what the branch holds.
            do {
                if try await github.branch(repo, name: branch)?.sha == verifiedSHA { return pushed(item, branch, payload) }
                return fail(item, branch, verifiedSHA, "the push may not have landed (\(why)) and \(branch) does not hold \(verifiedSHA.prefix(7))")
            } catch {
                return fail(item, branch, verifiedSHA, "the push may not have landed (\(why)); GitHub could not be read: \(Store.flat("\(error)", max: 120))")
            }
        }
    }

    private func sessionTainted(_ item: WorkItem) throws -> Bool {
        guard let owner = item.ownerId else { return false }
        // An owner the store no longer has cannot be shown clean: tainted.
        guard let agent = try store.agent(id: owner) else { return true }
        return agent.sessionTainted
    }

    private func record(_ item: WorkItem, branch: String, sha: String, state: PRLandingState, error: String?) throws {
        var landing = try store.prLanding(itemId: item.id)
            ?? PRLanding(itemId: item.id, companyId: item.companyId, branch: branch, pushedSHA: sha, state: state, updatedAt: clock())
        landing.branch = branch
        landing.pushedSHA = sha
        landing.state = state
        landing.lastError = error
        landing.updatedAt = clock()
        try store.upsertPRLanding(landing)
    }

    private func pushed(_ item: WorkItem, _ branch: String, _ payload: PushPayload) -> PushBranchOutcome {
        do { try record(item, branch: branch, sha: payload.sha, state: .pushed, error: nil) } catch {
            // GitHub has the branch; the record is what failed. The next reconcile reads the branch again.
            return .failed("pushed, but the record failed: \(Store.flat("\(error)", max: 200))")
        }
        return .pushed(payload)
    }

    private func fail(_ item: WorkItem, _ branch: String, _ sha: String, _ why: String) -> PushBranchOutcome {
        do { try record(item, branch: branch, sha: sha, state: .pushing, error: why) } catch {
            return .failed("\(why); the record failed too: \(Store.flat("\(error)", max: 120))")
        }
        return .failed(why)
    }
}
