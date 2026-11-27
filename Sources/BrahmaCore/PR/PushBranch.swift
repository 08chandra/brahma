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

    /// The same stage deciding through `gate` (the landing machine's: Task 3 answers an owner-approved ask through it).
    func gated(by gate: any PRActionGate) -> PushBranchStage {
        PushBranchStage(store: store, github: github, gate: gate, push: push, blobs: blobs, token: token, knownValues: knownValues, clock: clock,
                        blocking: blocking)
    }

    /// Pushes `verifiedSHA` (already rebased onto `base`, the remote `main` it was verified on) for `item` to `repo`. `branch`:
    /// the landing's branch when it has one (a resubmit updates the same branch even if the item was renamed); it must be a
    /// valid `brahma/` branch, else the name is derived from the item (`PRBranch.name`).
    ///
    /// `lease` (Ruling X8-31′): the commit Brahma last pushed to `existing`, its own PR branch — the push replaces exactly that
    /// commit (`--force-with-lease`), or GitHub refuses it. Taken only together with `existing`; a derived branch never is.
    public func run(item: WorkItem, repo: GitHubRepoRef, verifiedSHA: String, base: String, git: GitWorkspace,
                    branch existing: String? = nil, lease requested: String? = nil) async -> PushBranchOutcome {
        let named: PRDecision<String>
        var lease: String? = nil
        if let existing, existing.hasPrefix(PRBranch.prefix), existing.count > PRBranch.prefix.count, PRBranch.isValidBranchName(existing),
           PRBranch.ref(existing).utf8.count <= PRBranch.maxRefBytes {
            named = .allowed(existing)
            lease = requested
        } else {
            named = PRBranch.name(key: item.key, title: item.title)
        }
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
        guard case .allowed(var payload) = scanned else { return .refused(scanned.refusal ?? "the pre-push scan refused") }
        payload.lease = lease
        // 2. The request, with the visibility read now (never the connect-time value), through the one gate.
        let visibility: String
        do { visibility = try await github.repo(repo).visibility } catch {
            return .refused("could not read \(repo.owner)/\(repo.name) on GitHub: \(Store.flat("\(error)", max: 200))")
        }
        let request: PRActionRequest
        do {
            request = PRActionRequest(type: .pushBranch, companyId: item.companyId, itemId: item.id, payload: payload,
                                      taintedSession: try Self.sessionTainted(item, store: store), itemTainted: item.taintedOrigin, externalInput: false,
                                      firstUse: !(try store.hasPushedPRLanding(companyId: item.companyId)), repoVisibility: visibility)
        } catch {
            return .refused("could not read the item's state: \(Store.flat("\(error)", max: 200))")
        }
        switch await gate.decide(request) {
        case .refuse(let rule): return .refused(rule)
        case .ask(let reason): return .needsOwner(reason: reason, payload: payload)
        case .auto: break
        }
        // 3. Sending: recorded first, so a crash after this point is reconciled, not pushed blind a second time. Only while the
        // landing is still `pushing` this commit (or new): an owner's abandon or a newer commit meanwhile stops the push.
        do {
            guard try record(item, branch: branch, sha: verifiedSHA, state: .pushing, error: nil) else {
                return .refused("the landing moved on before the push (no longer pushing \(verifiedSHA.prefix(7))); nothing was pushed")
            }
        } catch {
            return .refused("could not record the push: \(Store.flat("\(error)", max: 200))")
        }
        let handle: TokenHandle
        let (token, companyId) = (self.token, item.companyId)
        do { handle = try await blocking.tryRun { try token(companyId) } } catch {
            return fail(item, branch, verifiedSHA, "the push token \(LandingSwitch.tokenSecretName) is not usable: \(Store.flat("\(error)", max: 160))")
        }
        let outcome: GitPushOutcome
        let (push, pushRequest) = (self.push, GitPushRequest(gitCommonDir: git.root.appending(path: ".git", directoryHint: .isDirectory),
                                                        sha: verifiedSHA, ref: target.ref, url: target.url, lease: lease))
        do {
            outcome = try await blocking.tryRun { try push.run(pushRequest, token: handle) }
        } catch {
            return fail(item, branch, verifiedSHA, "the push could not start: \(Store.flat("\(error)", max: 200))")
        }
        switch outcome {
        case .pushed:
            return pushed(item, branch, payload)
        case .refused(let why), .failed(let why):
            // A lease GitHub found stale: someone else pushed to the branch since Brahma did. Held; never overwritten.
            if let lease, why.contains("stale info") {
                return fail(item, branch, verifiedSHA, "\(why): \(branch) on GitHub is no longer \(lease.prefix(7)), the commit Brahma last "
                            + "pushed — someone else pushed to it; Brahma never overwrites their commits")
            }
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

    /// Whether the session that produced the item's change is tainted (its owner agent's session).
    static func sessionTainted(_ item: WorkItem, store: Store) throws -> Bool {
        guard let owner = item.ownerId else { return false }
        // An owner the store no longer has cannot be shown clean: tainted.
        guard let agent = try store.agent(id: owner) else { return true }
        return agent.sessionTainted
    }

    /// The landing's record, compare-and-set (`Store.recordPushStage`): false when the landing moved on meanwhile.
    private func record(_ item: WorkItem, branch: String, sha: String, state: PRLandingState, error: String?) throws -> Bool {
        try store.recordPushStage(item: item, branch: branch, sha: sha, state: state, error: error, now: clock())
    }

    private func pushed(_ item: WorkItem, _ branch: String, _ payload: PushPayload) -> PushBranchOutcome {
        do {
            guard try record(item, branch: branch, sha: payload.sha, state: .pushed, error: nil) else {
                return .failed("pushed, but the landing moved on meanwhile (abandoned, closed or a newer commit); the push was not recorded")
            }
        } catch {
            // GitHub has the branch; the record is what failed. The next reconcile reads the branch again.
            return .failed("pushed, but the record failed: \(Store.flat("\(error)", max: 200))")
        }
        return .pushed(payload)
    }

    private func fail(_ item: WorkItem, _ branch: String, _ sha: String, _ why: String) -> PushBranchOutcome {
        do {
            guard try record(item, branch: branch, sha: sha, state: .pushing, error: why) else {
                return .failed("\(why); the landing moved on meanwhile")
            }
        } catch {
            return .failed("\(why); the record failed too: \(Store.flat("\(error)", max: 120))")
        }
        return .failed(why)
    }
}
