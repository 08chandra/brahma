import Foundation

/// The git methods the merge queue uses (Plan 4a Task 1b). Every one goes through 3a's hardened command (`GitWorkspace`'s `main`
/// for the workspace repository, `engineCommand` for the engine's own merge repository): forced `-c` overrides, no global config,
/// attributes from the empty tree, the repository config allowlist. No method builds its own argv for a bare `git`.
///
/// The queue's rebase and merge work is done in the engine's merge repository (`<home>/run/merge/<companyId>.git`, made afresh,
/// fed by SHA, fsck'd), exactly as 3a's `landVerified` does, never in a checkout inside the agent-writable workspace
/// (`<ws>/.brahma/wt/.merge` was retired by 3a). The finished candidate's objects go back to the workspace by bundle
/// (`handBack`), where the secret scan, the export for the check and the landing read them. The caller holds the company's
/// `GitLock`; the methods that move `main` also take 3a's main lock (shared with owner accepts and quarantines).
public enum FastForwardResult: Equatable, Sendable {
    case ok
    /// `main` moved, but the root checkout could not follow it (its files and index still hold the old tree). Nothing is rolled
    /// back; the caller records the landing and holds the queue for the owner (never an index-only update that would make
    /// the old files look like the owner's edits).
    case mainMovedRootBehind
    /// The root checkout's own edits (an untracked file in the way, a modified one) stop the fast-forward; nothing moved.
    case blockedByLocalChanges
    /// `main` is not an ancestor of the commit (it moved): nothing moved.
    case notFastForward
    /// The root checkout is not on `main` (`ref`, or "a detached HEAD"): nothing moved.
    case rootNotOnMain(ref: String)
}

/// What building a candidate (the item's verified commit on top of `main`) came to.
enum CandidateResult: Equatable, Sendable {
    /// `rebased` is the verified commit replayed on the base (the commit itself when the base is already its ancestor);
    /// `candidate` is what lands: `rebased`, or the `--no-ff` merge commit over it.
    case built(rebased: String, candidate: String)
    /// The rebase conflicted; `files` are exact names (NUL-split), `mainSide` is the base.
    case conflict(files: [String], mergeBase: String, mainSide: String)
}

extension GitWorkspace {
    // MARK: Reads

    /// The commit `rev` names, nil when there is none. `main` means `refs/heads/main` (a tag called `main` never stands in).
    public func revParse(_ rev: String) throws -> String? {
        try Self.validRef(rev)
        return try head(of: rev == "main" ? Self.mainRef : rev)
    }

    /// `git rev-list --count <range>`.
    public func revListCount(_ range: String) throws -> Int {
        try Self.validRef(range)
        let out = try main.run(["rev-list", "--count", range])
        guard let n = Int(out.text) else {
            throw GitError.failed(command: "rev-list --count", status: -1, stderr: "unreadable count")
        }
        return n
    }

    /// `git diff --shortstat <base> <head>` (` 1 file changed, 1 insertion(+)`; empty when nothing differs).
    public func shortstat(base: String, head: String) throws -> String {
        try Self.validRef(base); try Self.validRef(head)
        return try main.run(["diff", "--shortstat", "--no-ext-diff", "--no-textconv", base, head]).text
    }

    /// The full ref the root checkout is on; nil for a detached `HEAD`.
    public func rootBranch() throws -> String? { try checkedOutRef() }

    /// Writes one of the engine's own refs (`refs/brahma/...`): the pre-merge marker, say. Nothing else is accepted.
    public func updateRef(_ ref: String, to commit: String) throws {
        try Self.validRef(ref); try Self.validCommit(commit)
        guard ref.hasPrefix("refs/brahma/"), !ref.contains("..") else {
            throw GitError.failed(command: "update-ref \(ref.prefix(60))", status: -1, stderr: "only refs/brahma/ refs are written here")
        }
        try main.run(["update-ref", "--no-deref", ref, commit])
    }

    // MARK: The root checkout
    //
    // There is deliberately no method that commits what is uncommitted at the root onto `main`: 3a quarantines it
    // (`quarantineRoot`) and it reaches `main` only through the owner's accept (Plan 4a Task 1b fix round, ruling S1).

    /// Fast-forwards `main` to `commit` with the root checkout following, the checkout being on `main` (checked first, under
    /// main's lock). Never overwrites the root's own edits: they stop it (`blockedByLocalChanges`). Nothing moved unless `.ok`.
    public func fastForwardMain(to commit: String) throws -> FastForwardResult {
        try Self.validCommit(commit)
        return try withMainLock(infrastructure: true) {
            guard let ref = try checkedOutRef() else { return .rootNotOnMain(ref: "a detached HEAD") }
            guard ref == Self.mainRef else { return .rootNotOnMain(ref: Self.shown(ref)) }
            guard try !mainIsSymbolic() else {
                throw GitError.failed(command: "update-ref refs/heads/main", status: -1, stderr: "main is a symbolic ref")
            }
            guard let current = try head(of: Self.mainRef), try isAncestor(current, of: commit) else { return .notFastForward }
            // Not `merge --ff-only`: it rewrites the root's files and index before it updates the ref, so a ref it cannot lock
            // (the company's fault) would leave the root half-advanced and the next batch would commit that as the owner's edits.
            // Here nothing is touched until the two-tree update is known to be possible (`read-tree --dry-run` never overwrites an
            // edit or an untracked file), then `main` moves by compare-and-swap, then the root follows (3a's `moveMainLocked`).
            guard try main.run(["read-tree", "-m", "-u", "-n", current, commit], allowFailure: true).status == 0 else {
                return .blockedByLocalChanges
            }
            let moved = try main.run(["update-ref", "--no-deref", Self.mainRef, commit, current], allowFailure: true)
            guard moved.status == 0 else {
                // The ref could not be written: a lock something else holds is the company's fault; anything else, main moved.
                if moved.stderr.contains(".lock") {
                    throw MergeInfrastructureError(underlying: GitError.failed(command: "update-ref \(Self.mainRef)", status: moved.status,
                                                                                stderr: String(moved.stderr.prefix(2000))))
                }
                return .notFastForward
            }
            // `main` has moved: from here nothing may throw (the caller would put a landed request back in the queue). A
            // `read-tree` that cannot run at all (no temporary space, git cannot be started) is the same as one that fails.
            do {
                try followProbe?()
                guard try main.run(["read-tree", "-m", "-u", current, commit], allowFailure: true).status == 0 else {
                    return .mainMovedRootBehind
                }
            } catch {
                return .mainMovedRootBehind
            }
            return .ok
        }
    }

    /// The merge queue's self-heal (3a's A3), under main's lock: git lock files in the workspace repository that nobody has held
    /// for a minute and a planted `shallow` or `info/grafts` are removed; the names are returned for the owner's alert. Anything
    /// else that blocks a merge stays and fails it as the company's fault.
    func healWorkspace() throws -> [String] {
        try withMainLock(infrastructure: true) { try MergeInfrastructureError.wrapping { try healWorkspaceRepositoryLocked() } }
    }

    // MARK: Candidates (the engine's merge repository)

    /// Builds what the queue would land for `head` (the request's verified commit) on `base` (`main`'s head, read under the lock):
    /// inside the engine lock, in a repository made afresh with only `base` and `head` fetched into it by SHA,
    /// - when `base` is not an ancestor of `head`, `head` is rebased onto it (`rebase --onto base <merge base> head`, 3a's
    ///   flags; the rebase is never aborted, its state is cleared by the engine) and 3a's `checkRebase` accepts the result
    ///   only if it is exactly the replay (commit count and tree against `merge-tree`);
    /// - `mergeMessage` non-nil (the `merge` strategy): the candidate is a `--no-ff` merge commit over the rebased head (parents
    ///   `base` and the rebased head, the rebased head's tree: what `merge --no-ff` produces when `base` is its ancestor);
    /// - the candidate's objects are handed to the workspace by bundle (no ref moves anywhere).
    /// A conflict lists the files exactly (`diff --name-only --diff-filter=U -z`, split on NUL). A commit git cannot fetch, check
    /// out, rebase or compare fails as `GitError` (the item's); the engine's own steps fail as `MergeInfrastructureError`.
    func buildCandidate(key: String, head verified: String, onto base: String, mergeMessage: String?,
                        tamper: ([String]) -> Void = { _ in }) throws -> CandidateResult {
        try Self.validKey(key); try Self.validCommit(verified); try Self.validCommit(base)
        return try withEngineLock {
            let git = try MergeInfrastructureError.wrapping {
                let fresh = try freshEngineRepository()
                retireWorkspaceMergeCheckouts()
                return fresh
            }
            try fetchLandingInputs(git, mainHead: base, verified: verified, tamper: tamper)
            dropPreviousEngineRepository()
            guard let mergeBase = try Self.mergeBase(git, base, verified) else {
                throw GitError.failed(command: "merge-base", status: -1, stderr: "item/\(key) shares no history with main")
            }
            var rebased = verified
            if try !Self.isAncestor(git, base, of: verified) {
                try MergeInfrastructureError.wrapping { try assertEngineState() }
                // `checkoutDetached`: the engine repository's working tree is made to be the commit, nothing left over.
                try git.run(["checkout", "--quiet", "--force", "--no-recurse-submodules", "--detach", verified])
                try git.run(["clean", "-ffdx", "--quiet"])
                rebaseProbe?(.before)
                let out = try git.run(Self.rebaseConfig + [
                    "rebase", "--quiet", "--no-update-refs", "--no-autostash", "--no-autosquash", "--reapply-cherry-picks",
                    "--empty=keep", "--no-fork-point", "--onto", base, mergeBase, verified,
                ], allowFailure: true)
                rebaseProbe?(.after)
                guard out.status == 0 else {
                    let listing = try git.run(["diff", "--no-ext-diff", "--no-textconv", "--name-only", "-z", "--diff-filter=U"], allowFailure: true)
                    let files = String(decoding: listing.stdout, as: UTF8.self)
                        .split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
                    try MergeInfrastructureError.wrapping { try clearMergeState(admin: mergeRepositoryPath, detachAt: base) }
                    guard !files.isEmpty else {
                        // Not a conflict: git could not rebase at all.
                        throw GitError.failed(command: "rebase --onto \(base.prefix(7))", status: out.status, stderr: String(out.stderr.prefix(2000)))
                    }
                    return .conflict(files: files, mergeBase: mergeBase, mainSide: base)
                }
                // HEAD is read once and from then on only that SHA is used.
                rebased = try git.run(["rev-parse", "--verify", "HEAD^{commit}"]).text
                try Self.validCommit(rebased)
                try MergeInfrastructureError.wrapping { try clearMergeState(admin: mergeRepositoryPath, detachAt: rebased) }
                try checkRebase(git, rebased, of: verified, base: mergeBase, onto: base, key: key)
            }
            var candidate = rebased
            if let mergeMessage {
                let tree = try git.run(["rev-parse", "--verify", "\(rebased)^{tree}"]).text
                candidate = try git.run(["commit-tree", tree, "-p", base, "-p", rebased, "-m", mergeMessage]).text
                try Self.validCommit(candidate)
            }
            if candidate != verified {
                try MergeInfrastructureError.wrapping { try handBack(git, result: candidate, prerequisites: [base, verified]) }
            }
            return .built(rebased: rebased, candidate: candidate)
        }
    }
}
