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
    // `restoreMain` below commits such edits only onto the *foreign* tip it saves, never onto `main`.

    /// Where the main guard keeps a tip of `main` that was not the engine's (`refs/brahma/foreign/<yyyyMMdd-HHmmss>-<n>`).
    static let foreignPrefix = "refs/brahma/foreign/"

    /// What the main guard saved and put back (`restoreMain`).
    public struct ForeignRestore: Equatable, Sendable {
        /// The engine's ref holding the other tip (with the root's uncommitted edits committed on top, when there were any).
        public var ref: String
        public var savedCommit: String
        /// The root checkout was on `main` and was reset to the recorded head; false when it sat elsewhere and was left alone.
        public var rootReset: Bool
        /// The ref the root checkout is on when it is not `main` (nil for a detached `HEAD`, or when `rootReset`).
        public var rootRef: String?
    }

    /// The main guard's restore (Plan 4a Task 3), under main's lock: `main` must still be `foreignTip` and the record must still
    /// be `recorded` (`recordStillStands`, read under this lock: an owner's `adopt-main`/accept changes `main` and the record
    /// under main's lock, so one that landed since the guard's read is seen here); nil when either moved (the next tick looks
    /// at it afresh). Then
    /// 1. with the root on `main` and dirty, its uncommitted edits are committed on top of `foreignTip` in a private index
    ///    (`quarantineRoot`'s way, `.brahma/` left out), so the owner loses nothing;
    /// 2. the tip (that commit, else `foreignTip`) goes under `refs/brahma/foreign/<stamp>-<n>`, `n` the smallest free suffix
    ///    (created, never overwritten);
    /// 3. `main` goes back to `recorded` by compare-and-swap against `foreignTip` (a symbolic `main` is refused: nil, the guard
    ///    leaves it to 3a's alert);
    /// 4. a root on `main` is reset to `recorded` (`reset --hard`, `clean -fd` keeping `.brahma/`); a root elsewhere is never
    ///    touched (its files, index and `HEAD` stay).
    /// Authors and subjects are never read: only the record decides what `main` is.
    func restoreMain(to recorded: String, from foreignTip: String, stamp: String, recordStillStands: () throws -> Bool) throws -> ForeignRestore? {
        try Self.validCommit(recorded); try Self.validCommit(foreignTip)
        guard stamp.range(of: "^[0-9]{8}-[0-9]{6}$", options: .regularExpression) != nil else {
            throw GitError.failed(command: "restore main", status: -1, stderr: "invalid stamp")
        }
        return try withMainLock {
            guard try head(of: Self.mainRef) == foreignTip, try !mainIsSymbolic(), try recordStillStands() else { return nil }
            let rootRef = try checkedOutRef()
            let onMain = rootRef == Self.mainRef
            var saved = foreignTip
            if onMain, try isDirty(in: root) {
                ensureExclude()
                try? FileManager.default.createDirectory(at: gitTemp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
                let index = gitTemp.appending(path: "brahma-foreign-\(UUID().uuidString).index")
                defer { _ = try? EngineFiles.removeNoFollow(index, under: gitTemp) }
                let staged = main.withIndex(index)
                try staged.run(["read-tree", foreignTip])
                try stage(staged, in: root, relative: "")
                try staged.run(["rm", "-r", "--cached", "--ignore-unmatch", "--quiet", "--", ".brahma"])
                let tree = try staged.run(["write-tree"]).text
                let tipTree = try main.run(["rev-parse", "--verify", "\(foreignTip)^{tree}"]).text
                if tree != tipTree {
                    saved = try main.run(["commit-tree", tree, "-p", foreignTip, "-m", "Uncommitted changes found in the main checkout when main was restored"]).text
                    try Self.validCommit(saved)
                }
            }
            let zero = String(repeating: "0", count: saved.count)
            var ref: String?
            for n in 1...999 {
                let name = Self.foreignPrefix + "\(stamp)-\(n)"
                if try main.run(["update-ref", "--no-deref", name, saved, zero], allowFailure: true).status == 0 { ref = name; break }
            }
            guard let ref else { throw GitError.failed(command: "update-ref foreign", status: -1, stderr: "no free foreign ref name") }
            let moved = try main.run(["update-ref", "--no-deref", Self.mainRef, recorded, foreignTip], allowFailure: true)
            guard moved.status == 0 else {
                throw GitError.failed(command: "update-ref \(Self.mainRef)", status: moved.status, stderr: String(moved.stderr.prefix(2000)))
            }
            if onMain {
                try main.run(["reset", "--hard", "--quiet", "--no-recurse-submodules", recorded])
                try main.run(["clean", "-fd", "--quiet", "-e", ".brahma/"])
            }
            return ForeignRestore(ref: ref, savedCommit: saved, rootReset: onMain, rootRef: onMain ? nil : rootRef)
        }
    }

    /// The owner's `adopt-main <commit>` (Plan 4a Task 3); the caller holds main's lock (`withMainLock`, not re-entrant).
    /// `main` moves from `current` to `commit` by compare-and-swap (false when it is no longer `current`, or is symbolic) and a
    /// root checkout on `main` follows (`reset --hard`); one with uncommitted edits refuses (`GitError`), since they would be
    /// overwritten. A root elsewhere is left alone. `commit` must exist in the repository.
    func swapMainLocked(to commit: String, expecting current: String) throws -> Bool {
        try Self.validCommit(commit); try Self.validCommit(current)
        guard try head(of: Self.mainRef) == current, try !mainIsSymbolic() else { return false }
        guard try main.run(["cat-file", "-e", "\(commit)^{commit}"], allowFailure: true).status == 0 else {
            throw GitError.failed(command: "cat-file -e", status: -1, stderr: "no such commit in the workspace")
        }
        let onMain = try checkedOutRef() == Self.mainRef
        if onMain, try isDirty(in: root) {
            throw GitError.failed(command: "adopt main", status: -1, stderr: "the main checkout has uncommitted changes; commit or stash them first")
        }
        guard try main.run(["update-ref", "--no-deref", Self.mainRef, commit, current], allowFailure: true).status == 0 else { return false }
        if onMain {
            try main.run(["reset", "--hard", "--quiet", "--no-recurse-submodules", commit])
            try main.run(["clean", "-fd", "--quiet", "-e", ".brahma/"])
        }
        return true
    }

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
