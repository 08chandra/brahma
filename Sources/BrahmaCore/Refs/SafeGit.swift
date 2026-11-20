import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Why `SafeGit` refused or failed. Every case is a refusal of this call, never a retry.
public enum SafeGitError: Error, Equatable, Sendable {
    /// Not `^[0-9a-f]{7,40}$`, or no commit by that id.
    case badRev
    /// The commit is not reachable from any of the refs the caller named.
    case unreachable
    /// The blob is larger than the cap for its kind (the size, from `cat-file -s`, checked before any read).
    case tooLarge(Int)
    /// Git ran past the timeout and was killed.
    case timedOut
    /// Git's output passed the cap.
    case outputTooLarge
    /// A ref name that is not an engine record's shape, or a share ref id with a slash, `..` or a leading `-`.
    case badRef
    /// A path with a component `SafeFS` refuses.
    case badPath
    /// Git failed (or `GitCommand` refused the repository): what it said.
    case git(String)
    /// A file could not be read through `SafeFS`, or the engine's own files failed.
    case io(String)
    /// A worktree diff with more changed paths than `maxDiffFiles` or more bytes than `maxDiffBytes`: refused whole, never
    /// partly shown (`bytes` is what had been summed when the cap was passed).
    case tooManyChanges(files: Int, bytes: Int)
    /// `expireAndPrune` found this many of the purged objects still in the repository afterwards: the purge is incomplete and
    /// the owner must be told. Never reported as success.
    case purgeIncomplete(remaining: Int)
}

extension SafeGitError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .badRev: return "not a commit id"
        case .unreachable: return "commit is not reachable from the named refs"
        case .tooLarge(let n): return "blob of \(n) bytes is over the cap"
        case .timedOut: return "git timed out"
        case .outputTooLarge: return "git output passed the cap"
        case .badRef: return "not a ref the engine records"
        case .badPath: return "not a valid path"
        case .git(let s), .io(let s): return s
        case .tooManyChanges(let files, let bytes): return "too many/too large changes to diff (\(files) files, \((bytes + (1 << 20) - 1) >> 20) MB)"
        case .purgeIncomplete(let remaining): return "purge incomplete: \(remaining) object(s) still in the repository"
        }
    }
}

/// The seam between `SafeGit` and a git process: `args` is the full command line after `git` and `env` the full environment,
/// both built by `GitCommand` (`commandLine`), so a fake records exactly what git would have been given.
public protocol GitProcessRunning: Sendable {
    /// Runs git. Throws `SafeGitError.timedOut` when the timeout killed it and `.outputTooLarge` when stdout passed `outputCap`.
    func run(args: [String], env: [String: String], stdin: Data?, timeout: Duration, outputCap: Int) throws -> (status: Int32, stdout: Data, stderr: Data)
    /// As `run`, with the open directory git must be started in (`fchdir`, `-C .`, `GIT_WORK_TREE=.`): a worktree diff's
    /// processes. A fake that only records may leave this to the default, which forwards to `run`; anything that starts git
    /// must honour it (the live runner refuses an anchored command line it was not given the descriptor for).
    func run(args: [String], env: [String: String], stdin: Data?, timeout: Duration, outputCap: Int, workTreeDescriptor: Int32?) throws -> (status: Int32, stdout: Data, stderr: Data)
}

extension GitProcessRunning {
    public func run(args: [String], env: [String: String], stdin: Data?, timeout: Duration, outputCap: Int, workTreeDescriptor: Int32?) throws -> (status: Int32, stdout: Data, stderr: Data) {
        try run(args: args, env: env, stdin: stdin, timeout: timeout, outputCap: outputCap)
    }
}

/// Runs the command line through `GitCommand` (`runPrepared`: output to files under `tempRoot`, the timeout, the capture cap).
public struct LiveGitRunner: GitProcessRunning {
    /// Where git's captured output goes; the engine passes its data home's 0700 `tmp` (A-I1b). Nil: the process temp dir.
    public var tempRoot: URL?
    /// Tests only: handed the executable and argv of every git this runner starts (`GitCommand.spawnObserver`).
    var spawnObserver: (@Sendable (_ executable: String, _ argv: [String]) -> Void)?

    public init(tempRoot: URL? = nil) { self.tempRoot = tempRoot }

    public func run(args: [String], env: [String: String], stdin: Data?, timeout: Duration, outputCap: Int) throws -> (status: Int32, stdout: Data, stderr: Data) {
        try run(args: args, env: env, stdin: stdin, timeout: timeout, outputCap: outputCap, workTreeDescriptor: nil)
    }

    public func run(args: [String], env: [String: String], stdin: Data?, timeout: Duration, outputCap: Int, workTreeDescriptor: Int32?) throws -> (status: Int32, stdout: Data, stderr: Data) {
        guard let gitDir = env["GIT_DIR"], let workTree = env["GIT_WORK_TREE"] else { throw SafeGitError.io("git environment without GIT_DIR") }
        // An anchored command line (`GIT_WORK_TREE=.`) without its descriptor would run in this process's directory: refused.
        guard (workTree == ".") == (workTreeDescriptor != nil) else { throw SafeGitError.io("anchored git command line without its work tree descriptor") }
        var git = GitCommand(gitDir: URL(fileURLWithPath: gitDir, isDirectory: true), workTree: URL(fileURLWithPath: workTree, isDirectory: true), commonDir: nil)
        git.timeoutSeconds = SafeGit.seconds(timeout)
        git.workTreeDescriptor = workTreeDescriptor
        git.spawnObserver = spawnObserver
        if let tempRoot { git.tempRoot = tempRoot }
        let out: GitCommand.Output
        do {
            out = try git.runPrepared(args: args, environment: env, maxOutput: outputCap, stdin: stdin.map { .data($0) } ?? .none)
        } catch let e as GitError {
            throw SafeGitError.git(e.description)
        }
        if out.timedOut { throw SafeGitError.timedOut }
        if out.cut { throw SafeGitError.outputTooLarge }
        return (out.status, out.stdout, Data(out.stderr.utf8))
    }
}

/// The one way Collab code runs git over agent-named inputs: shas verified by shape and reachability from engine-recorded
/// refs, sizes checked before reads, every call through 3a's hardened `GitCommand` with `GIT_DIR=<ws>/.git` (the common dir,
/// never an item's admin dir, so no per-worktree config is read), `GIT_LITERAL_PATHSPECS=1`, `--end-of-options` before every
/// rev and `--` before every path. Only `refs/brahma/shares/*` is ever written.
public struct SafeGit: Sendable {
    public static let maxTextBytes = 2_097_152
    public static let maxBinaryBytes = 52_428_800
    public static let maxDiffLines = 5000
    /// `worktreeDiff` caps: more changed paths, or more bytes in them, refuses the whole diff (`ChangesLimits`: at most 2000
    /// paths listed; 200 MiB of file bytes to hash).
    public static let maxDiffFiles = 2000
    public static let maxDiffBytes = 200 << 20
    public static let timeout: Duration = .seconds(10)
    public static let outputCap = 8_388_608
    /// A `.gitignore` larger than this is not handed to git (`worktreeDiff`): fewer rules, more listed.
    static let maxIgnoreFileBytes = 1 << 20
    static let extraEnvironment = ["GIT_LITERAL_PATHSPECS": "1"]
    static let extraConfig = ["-c", "core.untrackedCache=false", "-c", "core.excludesFile=/dev/null"]
    static let sharesPrefix = "refs/brahma/shares/"
    static let noDiffPrograms = ["--no-textconv", "--no-ext-diff", "--no-color", "--no-renames"]

    public struct TreeEntry: Equatable, Sendable {
        public var path: String
        public var mode: String
        public var sha: String
        /// Nil for a submodule entry.
        public var size: Int?
    }

    public struct DiffText: Sendable {
        /// Per path: lines added and removed; nil for a binary file.
        public var stat: [(path: String, added: Int?, removed: Int?)]
        public var patch: String
        /// The patch was cut at `maxDiffLines` (a patch past git's output cap is refused: `.outputTooLarge`, or in a worktree
        /// diff `.tooManyChanges`).
        public var truncated: Bool
    }

    public struct WorktreeDiff: Sendable {
        /// `status` is `A`, `M`, `D` or `T`; `added`/`removed` nil for a binary file; `bytes` the file's size now (0 when deleted).
        public var files: [(path: String, status: String, added: Int?, removed: Int?, bytes: Int)]
        public var patch: String
        /// Path → blob id of the bytes `SafeFS` read (written to the repository), for every file present.
        public var blobShas: [String: String]
        public var truncated: Bool
    }

    public let workspace: URL
    let runner: any GitProcessRunning
    /// Per git process, and the whole budget of one `worktreeDiff` call.
    let callTimeout: Duration
    let maxDiffFiles: Int
    let maxDiffBytes: Int
    /// `worktreeDiff`: the bytes of path text the walk may keep (and `check-ignore` be given or give back); past it the diff is
    /// `.tooManyChanges`. `outputCap`; tests lower it.
    var listingByteCap = SafeGit.outputCap
    /// Tests only: handed the size of every chunk hashed for a same-size id comparison in `worktreeDiff`.
    var hashChunkProbe: (@Sendable (Int) -> Void)?

    public init(workspace: URL, runner: any GitProcessRunning = LiveGitRunner(), timeout: Duration = SafeGit.timeout,
                maxDiffFiles: Int = SafeGit.maxDiffFiles, maxDiffBytes: Int = SafeGit.maxDiffBytes) {
        self.workspace = workspace
        self.runner = runner
        self.callTimeout = timeout
        self.maxDiffFiles = maxDiffFiles
        self.maxDiffBytes = maxDiffBytes
    }

    // MARK: Revs and refs

    /// `s` as a full commit id, when it is a sha (7–40 lowercase hex), names a commit and is reachable from at least one of
    /// `refs` (engine records: `main`, `item/<KEY>`, `refs/brahma/shares/<id>`).
    public func verifyRev(_ s: String, reachableFrom refs: [String]) throws -> String {
        try Self.checkRevShape(s)
        let qualified = try refs.map(Self.qualifiedRef)
        let r = try run(["rev-parse", "--verify", "--quiet", "--end-of-options", "\(s)^{commit}"], allowFailure: true)
        guard r.status == 0, let sha = Self.fullSha(r.stdout) else { throw SafeGitError.badRev }
        for ref in qualified {
            if try run(["merge-base", "--is-ancestor", "--end-of-options", sha, ref], allowFailure: true).status == 0 { return sha }
        }
        throw SafeGitError.unreachable
    }

    /// The commit at `branch` (`main`, `item/<KEY>`, or a fully qualified ref).
    public func head(_ branch: String) throws -> String { try head(branch, budget: nil) }

    private func head(_ branch: String, budget: Budget?) throws -> String {
        let ref = try Self.qualifiedRef(branch)
        let r = try run(["rev-parse", "--verify", "--quiet", "--end-of-options", "\(ref)^{commit}"], allowFailure: true, budget: budget)
        guard r.status == 0, let sha = Self.fullSha(r.stdout) else { throw SafeGitError.git("\(ref) is not a branch of this repository") }
        return sha
    }

    public func mergeBase(_ a: String, _ b: String) throws -> String {
        let r = try run(["merge-base", "--end-of-options", try Self.revArg(a), try Self.revArg(b)], allowFailure: true)
        guard r.status == 0, let sha = Self.fullSha(r.stdout) else { throw SafeGitError.git("no merge base of \(a) and \(b)") }
        return sha
    }

    public func isAncestor(_ a: String, of b: String) throws -> Bool {
        let r = try run(["merge-base", "--is-ancestor", "--end-of-options", try Self.revArg(a), try Self.revArg(b)], allowFailure: true)
        switch r.status {
        case 0: return true
        case 1: return false
        default: throw SafeGitError.git(Self.text(r.stderr))
        }
    }

    // MARK: Objects

    public func blobSize(rev: String, path: String) throws -> Int {
        let r = try run(["cat-file", "-s", "--end-of-options", try Self.object(rev, path)], allowFailure: true)
        guard r.status == 0, let size = Int(Self.text(r.stdout)) else { throw SafeGitError.git("\(path) is not a blob of \(rev)") }
        return size
    }

    /// The blob's bytes, after its size is checked against `maxTextBytes` (or `maxBinaryBytes`).
    public func catFile(rev: String, path: String, binary: Bool) throws -> Data {
        let size = try blobSize(rev: rev, path: path)
        let cap = binary ? Self.maxBinaryBytes : Self.maxTextBytes
        guard size <= cap else { throw SafeGitError.tooLarge(size) }
        let data = try output(["cat-file", "-p", "--end-of-options", try Self.object(rev, path)], outputCap: max(Self.outputCap, cap + 1))
        guard data.count <= cap else { throw SafeGitError.tooLarge(data.count) }
        return data
    }

    public func lsTree(rev: String, cap: Int) throws -> (entries: [TreeEntry], truncated: Bool) {
        let out = try output(["ls-tree", "-r", "-l", "-z", "--end-of-options", try Self.sha(rev)])
        var entries: [TreeEntry] = []
        for record in out.split(separator: 0, omittingEmptySubsequences: true) {
            guard let tab = record.firstIndex(of: 9) else { continue }
            let meta = String(decoding: record[record.startIndex..<tab], as: UTF8.self).split(whereSeparator: { $0 == " " })
            let path = String(decoding: record[record.index(after: tab)...], as: UTF8.self)
            guard meta.count == 4 else { continue }
            entries.append(TreeEntry(path: path, mode: String(meta[0]), sha: String(meta[2]), size: Int(meta[3])))
            if entries.count > cap { return (Array(entries.prefix(cap)), true) }
        }
        return (entries, false)
    }

    /// The patch and numstat between two commits, `--no-textconv --no-ext-diff`, cut at `maxDiffLines`.
    public func diff(base: String, head: String, path: String?) throws -> DiffText {
        let revs = ["--end-of-options", try Self.sha(base), try Self.sha(head), "--"] + (try path.map { [try Self.checkPath($0)] } ?? [])
        return try diffText(["diff"] + Self.noDiffPrograms, revs)
    }

    public func show(commit: String) throws -> (subject: String, author: String, diff: DiffText) {
        let sha = try Self.sha(commit)
        let header = Self.text(try output(["log", "-1", "--format=%s%x00%an", "--no-textconv", "--no-ext-diff", "--end-of-options", sha, "--"]))
            .split(separator: "\u{0}", omittingEmptySubsequences: false).map(String.init)
        let diff = try diffText(["show", "--format="] + Self.noDiffPrograms, ["--end-of-options", sha, "--"])
        return (header.first ?? "", header.count > 1 ? header[1] : "", diff)
    }

    /// The commits in `from..to`, newest first.
    public func revList(_ from: String, _ to: String) throws -> [String] {
        Self.lines(try output(["rev-list", "--end-of-options", "\(try Self.sha(from))..\(try Self.sha(to))"]))
    }

    /// The commits of `range` (`a..b`, or one rev) touching `path`, newest first.
    public func logShas(range: String, path: String) throws -> [String] {
        let rangeArg = try range.components(separatedBy: "..").map(Self.sha).joined(separator: "..")
        return Self.lines(try output(["log", "--format=%H", "--no-textconv", "--no-ext-diff", "--end-of-options", rangeArg, "--", try Self.checkPath(path)]))
    }

    /// Path → unix time of the most recent of the last `commits` commits from `rev` that touched it.
    public func recentPaths(rev: String, commits: Int) throws -> [String: Int] {
        let out = Self.text(try output(["log", "--format=%x01%ct", "--name-only", "--no-textconv", "--no-ext-diff", "--no-renames",
                                        "-n", String(max(1, commits)), "--end-of-options", try Self.sha(rev), "--"]))
        var result: [String: Int] = [:]
        var time = 0
        for line in out.split(separator: "\n") {
            if line.hasPrefix("\u{01}") { time = Int(line.dropFirst()) ?? 0; continue }
            let path = String(line)
            if !path.isEmpty, result[path] == nil { result[path] = time }
        }
        return result
    }

    /// Writes the bytes `SafeFS` checked as a blob (`hash-object -w --stdin --no-filters`) and returns its id.
    public func hashObject(from file: SafeFile) throws -> String {
        let data: Data
        do { data = try file.readAll() } catch { throw SafeGitError.io("\(error)") }
        guard let sha = Self.fullSha(try output(["hash-object", "-w", "--stdin", "--no-filters"], stdin: data)) else {
            throw SafeGitError.git("hash-object gave no id")
        }
        return sha
    }

    // MARK: Share refs (the only writes)

    /// Points `refs/brahma/shares/<id>` at `sha`, which must be a full commit id the caller has `verifyRev`ed (an
    /// abbreviation is `.badRev`).
    public func updateShareRef(_ messageRefId: String, to sha: String) throws {
        try Self.checkRevShape(sha)
        guard sha.utf8.count == 40 || sha.utf8.count == 64 else { throw SafeGitError.badRev }
        try output(["update-ref", "--end-of-options", try Self.shareRef(messageRefId), sha])
    }

    public func deleteShareRef(_ messageRefId: String) throws {
        try output(["update-ref", "-d", "--end-of-options", try Self.shareRef(messageRefId)])
    }

    /// Purges `purged` (full object ids the engine knows a deleted or moved share pinned): every reflog of the repository, the
    /// worktrees' `HEAD` reflogs included (`reflog expire --expire=now --expire-unreachable=now --all`; item-branch reflog
    /// entries go with it, said plainly), then every unreachable loose object (`prune --expire=now`), then `repack -a -d`
    /// so a copy already in a pack dies too. Fail-closed: afterwards one `cat-file --batch-check` asks for every id, and any
    /// object still present (reachable from a branch, an index, a worktree `HEAD`) is `.purgeIncomplete(remaining:)`; success
    /// is never reported while a purged object survives.
    ///
    /// Its only caller is the owner's purge, which must hold the engine's git lock and must refuse while any turn of the
    /// company is running: pruning while an agent writes the object store can orphan a commit that agent is making.
    public func expireAndPrune(purged: [String]) throws {
        for oid in purged { try Self.checkRevShape(oid); guard oid.utf8.count == 40 || oid.utf8.count == 64 else { throw SafeGitError.badRev } }
        try output(["reflog", "expire", "--expire=now", "--expire-unreachable=now", "--all"])
        try output(["prune", "--expire=now"])
        try output(["repack", "-a", "-d", "-q"])
        guard !purged.isEmpty else { return }
        let report = Self.lines(try output(["cat-file", "--batch-check"], stdin: Data((purged.joined(separator: "\n") + "\n").utf8)))
        let remaining = purged.count - report.filter { $0.hasSuffix(" missing") }.count
        if remaining > 0 { throw SafeGitError.purgeIncomplete(remaining: remaining) }
    }

    // MARK: Worktree diffs

    /// The changes in the item worktree `<ws>/.brahma/wt/<KEY>` against `against` (an engine-verified tree-ish; nil: the tip
    /// of `item/<KEY>`, so only uncommitted changes).
    ///
    /// What is guaranteed: NO git process of this call has the agent's worktree as its work tree, its directory, or any path
    /// it opens. The worktree is the directory `SafeFS` opens for the key (`O_NOFOLLOW` at `wt` and at the key) and holds for
    /// the whole call; right before and right after every git process the path 3a names for the key must still be that very
    /// directory (`Anchor.check`: a real directory, same device and inode), else the whole diff is refused with a text naming
    /// only the engine's key. Every git process runs with an engine-owned work tree (`<call dir>/shadow`) and a private index
    /// in a fresh per-call directory under `tempDir` (`mkdtemp`, 0700, removed when the call ends; `tempDir` must be
    /// engine-owned). Phases:
    /// 1. The base, objects only: `read-tree` into the private index, `ls-tree -r -l` for the base's paths, modes, ids, sizes.
    ///    The worktree, descriptors only: `WorktreeListing.walk` from the held directory. It omits nothing git would list:
    ///    nothing is pruned (the engine has no gitignore parser of its own), every directory under which the base tracks a
    ///    path is walked whole, and anything it cannot account for refuses the whole diff — a directory or entry it cannot
    ///    list, open or read (`io`), a `.git` entry in a directory under which the base tracks paths (`io`), more than
    ///    `WorktreeListing.maxEntries` entries, `listingByteCap` (`outputCap`) bytes of path text or `maxDepth` levels
    ///    (`.tooManyChanges`). Not listed, as git lists none: `.git` entries, devices, pipes, sockets, a submodule's directory.
    ///    An untracked directory holding a nested repository (by a check narrower than git's) is one entry `<dir>/`, status
    ///    `A`, nothing in it read; any other `.git` there is skipped and the directory walked. For every walked path the base
    ///    does not track, ONE `git check-ignore --stdin` (stdin and output bounded by `listingByteCap`, `.tooManyChanges`
    ///    past it) decides ignores, reading engine-owned copies of the `.gitignore` files in the shadow work tree; each copy's
    ///    bytes come through `SafeFS` (regular, one link, this user's, at most 1 MiB, judged on the opened descriptor's
    ///    `fstat`, copied up to that size) and a `.gitignore` that fails that is not copied: git then sees fewer rules, so more
    ///    paths are listed, never fewer.
    /// 2. Changes: a base path not present is deleted; a present path not in the base (and not ignored) is added; a path in
    ///    both is modified when mode or size differ, else when its blob id — computed in the engine (`SHA1`/`SHA256`) from the
    ///    bytes streamed through `SafeFS` in 64 KiB chunks, the time budget checked per chunk — differs, so an unchanged file
    ///    never leaves the engine and never sits in memory whole. The file is opened for at most the size the walk recorded;
    ///    one that changed size meanwhile counts as modified without being read here (phase 3 takes it under its caps).
    /// 3. Each changed file's checked bytes (a link: its target) are copied to an engine-owned file under the call directory,
    ///    one descriptor at a time, summed against `maxDiffBytes` before any hashing; ONE `hash-object -w --no-filters
    ///    --stdin-paths` hashes the copies, one `update-index --index-info` (and one `--force-remove`) fills the index, and
    ///    `diff --cached` against the base compares objects only.
    /// Bounded: a constant number of git processes (at most 10); `WorktreeListing.maxEntries` entries walked, `maxDiffFiles`
    /// changed paths, `maxDiffBytes` changed bytes, `maxBinaryBytes` per file, git output at its cap — each refuses the whole
    /// diff with `.tooManyChanges`; one time budget (`timeout`) for the call. No agent-controlled or git-reported name reaches
    /// an error's text. The agent's own index is never read or written.
    public func worktreeDiff(key: String, worktree: URL, against: String? = nil, tempDir: URL, fs: SafeFS) throws -> WorktreeDiff {
        guard (try? GitWorkspace.validKey(key)) != nil else { throw SafeGitError.badRef }
        guard worktree.standardizedFileURL.path == GitWorkspace(root: workspace).worktreePath(key: key).standardizedFileURL.path else {
            throw SafeGitError.io("the worktree given is not .brahma/wt/\(key)")
        }
        let budget = Budget(limit: callTimeout)
        let base: String
        if let against { try Self.checkRevShape(against); base = against } else { base = try head("item/\(key)", budget: budget) }
        let tree: EngineFiles.OpenDirectory
        do { tree = try fs.worktreeDirectory(key: key) } catch { throw SafeGitError.io("the worktree of \(key) is not in place (\(Self.brief(error)))") }
        let anchor: Anchor
        do { anchor = Anchor(directory: tree, path: worktree, key: key, id: try tree.identity()) } catch { throw SafeGitError.io("the worktree of \(key) cannot be inspected") }
        try anchor.check()
        // One directory for this call alone: the private index, the engine-owned work tree every process gets, the byte copies.
        let callDir = try Self.makeCallDirectory(in: tempDir)
        defer { try? FileManager.default.removeItem(at: callDir) }
        let index = callDir.appending(path: "index")
        let shadow = callDir.appending(path: "shadow", directoryHint: .isDirectory)
        let blobDir = callDir.appending(path: "blobs", directoryHint: .isDirectory)
        guard mkdir(shadow.path, 0o700) == 0, mkdir(blobDir.path, 0o700) == 0 else { throw SafeGitError.io("cannot create the diff's directories") }
        @discardableResult
        func engineGit(_ args: [String], stdin: Data? = nil) throws -> Data {
            try output(args, workTree: shadow, anchor: anchor, index: index, stdin: stdin, budget: budget)
        }
        var changed: [(status: String, path: String, kind: WorktreeListing.Kind?)] = []
        func listing(_ args: [String]) throws -> [Data] {
            do { return try engineGit(args).split(separator: 0, omittingEmptySubsequences: true) }
            catch SafeGitError.outputTooLarge { throw SafeGitError.tooManyChanges(files: changed.count, bytes: 0) }
        }
        func unreadable(_ error: any Error) -> SafeGitError { SafeGitError.io("a changed path cannot be read (\(Self.brief(error)))") }
        // Phase 1: the base (objects only) and the worktree (descriptors only).
        try engineGit(["read-tree", "--end-of-options", base])
        var baseEntries: [String: (mode: String, sha: String, size: Int?)] = [:]
        var sha256 = false
        for record in try listing(["ls-tree", "-r", "-l", "-z", "--end-of-options", base]) {
            guard let tab = record.firstIndex(of: 9) else { continue }
            let meta = String(decoding: record[record.startIndex..<tab], as: UTF8.self).split(whereSeparator: { $0 == " " })
            guard meta.count == 4 else { continue }
            let sha = String(meta[2])
            sha256 = sha256 || sha.utf8.count == 64
            baseEntries[String(decoding: record[record.index(after: tab)...], as: UTF8.self)] = (String(meta[0]), sha, Int(meta[3]))
        }
        // Every directory under which the base tracks a path (the root included) is walked whole and never skipped: a `.git`
        // entry in one refuses the diff. A submodule's directory (`160000`) is not walked (compared as a gitlink, i.e. skipped).
        var trackedDirectories: Set<String> = [], gitlinks: Set<String> = []
        for (path, entry) in baseEntries {
            if entry.mode == "160000" { gitlinks.insert(path) }
            var dir = Substring(path)
            while let slash = dir.lastIndex(of: "/") {
                dir = dir[..<slash]
                if !trackedDirectories.insert(String(dir)).inserted { break }
            }
        }
        let found: WorktreeListing
        do {
            found = try WorktreeListing.walk(tree, trackedDirectories: trackedDirectories, gitlinks: gitlinks, maxPathBytes: listingByteCap) { try budget.check() }
        } catch let e as SafeGitError {
            throw e
        } catch WorktreeListing.Refusal.tooLarge(let entries, let bytes) {
            throw SafeGitError.tooManyChanges(files: entries, bytes: bytes)
        } catch WorktreeListing.Refusal.repositoryInTrackedDirectory {
            throw SafeGitError.io("the worktree of \(key) holds a .git entry in a tracked directory")
        } catch {
            throw SafeGitError.io("the worktree of \(key) cannot be listed")
        }
        let present = Dictionary(found.entries.map { ($0.path, $0.kind) }, uniquingKeysWith: { a, _ in a })
        // Ignore verdicts for every walked path the base does not track (nothing was pruned): git reads engine-owned copies of
        // the `.gitignore` files. A nested repository's directory is made in the shadow too, so git judges it as a directory.
        var ignored: Set<String> = []
        // `check-ignore` refuses `GIT_LITERAL_PATHSPECS` and reads its paths as pathspecs: a name that could carry pathspec magic
        // (a leading `:`) is never asked about and simply listed as a change.
        let candidates = (found.entries.map(\.path) + found.repositories).filter { baseEntries[$0] == nil && !$0.hasPrefix(":") }
        if !candidates.isEmpty {
            for rel in found.ignoreFiles {
                // Through `SafeFS`, judged on the opened descriptor's `fstat` (regular, one link, this user's, at most 1 MiB) and
                // copied up to that size: one that fails is not copied, so git sees fewer rules and lists more, never less.
                guard let file = try? fs.open(rel, in: tree, key: key, maxBytes: Self.maxIgnoreFileBytes) else { continue }
                let copy = shadow.appending(path: rel)
                try Self.makeShadowDirectory(copy.deletingLastPathComponent())
                try Self.write(file: file, to: copy.path)
            }
            for rel in found.repositories { try Self.makeShadowDirectory(shadow.appending(path: rel, directoryHint: .isDirectory)) }
            var stdin = Data()
            for path in candidates { stdin.append(contentsOf: path.utf8); stdin.append(0) }
            guard stdin.count <= listingByteCap else { throw SafeGitError.tooManyChanges(files: candidates.count, bytes: stdin.count) }
            let r: (status: Int32, stdout: Data, stderr: Data)
            do {
                r = try run(["check-ignore", "-z", "--stdin", "--no-index"], workTree: shadow, anchor: anchor, index: index, stdin: stdin, outputCap: listingByteCap,
                            allowFailure: true, budget: budget, literalPathspecs: false)
            } catch SafeGitError.outputTooLarge {
                throw SafeGitError.tooManyChanges(files: candidates.count, bytes: stdin.count)
            }
            guard r.status == 0 || r.status == 1 else { throw SafeGitError.git("git check-ignore failed (\(r.status))") }
            for raw in r.stdout.split(separator: 0, omittingEmptySubsequences: true) { ignored.insert(String(decoding: raw, as: UTF8.self)) }
        }
        let repositories = found.repositories.filter { !ignored.contains($0) }
        // Phase 2: what changed. Same mode and size: the blob id, computed here, decides.
        for (path, entry) in baseEntries where present[path] == nil && entry.mode != "160000" { changed.append(("D", path, nil)) }
        var compared = 0
        for entry in found.entries {
            guard let known = baseEntries[entry.path] else {
                if !ignored.contains(entry.path) { changed.append(("A", entry.path, entry.kind)) }
                continue
            }
            if known.mode == "160000" { continue }
            switch entry.kind {
            case .file(let size, let executable):
                if known.mode != (executable ? "100755" : "100644") || known.size != size { changed.append(("M", entry.path, entry.kind)); continue }
                compared += 1
                if compared % 64 == 0 { try budget.check() }
                // Opened for exactly the size the walk saw: a file that grew or shrank meanwhile is modified, unread here.
                let file: SafeFile
                do { file = try fs.open(entry.path, in: tree, key: key, maxBytes: size) } catch SafeFSError.tooLarge {
                    changed.append(("M", entry.path, entry.kind)); continue
                } catch { throw unreadable(error) }
                guard file.size == size else { changed.append(("M", entry.path, entry.kind)); continue }
                do { if try Self.blobId(of: file, sha256: sha256, budget: budget, probe: hashChunkProbe) != known.sha { changed.append(("M", entry.path, entry.kind)) } }
                catch let e as SafeGitError { throw e } catch { throw unreadable(error) }
            case .link(let target):
                if known.mode != "120000" || Self.blobId(of: target, sha256: sha256) != known.sha { changed.append(("M", entry.path, entry.kind)) }
            }
        }
        guard changed.count + repositories.count <= maxDiffFiles else { throw SafeGitError.tooManyChanges(files: changed.count + repositories.count, bytes: 0) }
        changed.sort { $0.path < $1.path }
        // Phase 3: each changed path's checked bytes copied to the call directory, one descriptor at a time, summed before hashing.
        var copies: [(path: String, size: Int, mode: String)] = []
        var removals = Data(), paths = Data()
        var total = 0
        for change in changed {
            guard let kind = change.kind else { removals.append(contentsOf: change.path.utf8); removals.append(0); continue }
            let copy = blobDir.appending(path: "\(copies.count)").path
            switch kind {
            case .file:
                let file: SafeFile
                do { file = try fs.open(change.path, in: tree, key: key, maxBytes: Self.maxBinaryBytes) } catch SafeFSError.tooLarge(let size) {
                    throw SafeGitError.tooManyChanges(files: changed.count, bytes: total + size)
                } catch { throw unreadable(error) }
                total += file.size
                guard total <= maxDiffBytes else { throw SafeGitError.tooManyChanges(files: changed.count, bytes: total) }
                try Self.write(file: file, to: copy)
                copies.append((change.path, file.size, file.executable ? "100755" : "100644"))
            case .link(let target):
                total += target.count
                guard total <= maxDiffBytes else { throw SafeGitError.tooManyChanges(files: changed.count, bytes: total) }
                try Self.write(bytes: target, to: copy)
                copies.append((change.path, target.count, "120000"))
            }
            paths.append(contentsOf: copy.utf8); paths.append(UInt8(ascii: "\n"))
        }
        try budget.check()
        var blobShas: [String: String] = [:]
        var indexInfo = Data()
        if !copies.isEmpty {
            // `--stdin-paths` takes one path per line: these are the engine's own names under the call directory, never an agent's.
            let shas = Self.lines(try engineGit(["hash-object", "-w", "--no-filters", "--stdin-paths"], stdin: paths))
            guard shas.count == copies.count, shas.allSatisfy({ Self.fullSha(Data($0.utf8)) != nil }) else {
                throw SafeGitError.git("hash-object gave \(shas.count) ids for \(copies.count) files")
            }
            for (entry, sha) in zip(copies, shas) {
                blobShas[entry.path] = sha
                indexInfo.append(contentsOf: "\(entry.mode) \(sha)\t\(entry.path)".utf8); indexInfo.append(0)
            }
        }
        if !removals.isEmpty { try engineGit(["update-index", "-z", "--force-remove", "--stdin"], stdin: removals) }
        if !indexInfo.isEmpty { try engineGit(["update-index", "-z", "--index-info"], stdin: indexInfo) }
        // Now the index holds exactly the bytes checked: every comparison below is between objects.
        let cached = ["diff", "--cached"] + Self.noDiffPrograms
        let names = try listing(cached + ["--name-status", "-z", "--end-of-options", base, "--"])
        var statuses: [(path: String, status: String)] = []
        var i = 0
        while i + 1 < names.count {
            statuses.append((String(decoding: names[i + 1], as: UTF8.self), String(decoding: names[i], as: UTF8.self)))
            i += 2
        }
        let text: DiffText
        do { text = try diffText(cached, ["--end-of-options", base, "--"], workTree: shadow, anchor: anchor, index: index, budget: budget) }
        catch SafeGitError.outputTooLarge { throw SafeGitError.tooManyChanges(files: changed.count, bytes: total) }
        let counts = Dictionary(text.stat.map { ($0.path, ($0.added, $0.removed)) }, uniquingKeysWith: { a, _ in a })
        let sizes = Dictionary(copies.map { ($0.path, $0.size) }, uniquingKeysWith: { a, _ in a })
        var files = statuses.map { (path: $0.path, status: $0.status, added: counts[$0.path]?.0, removed: counts[$0.path]?.1, bytes: sizes[$0.path] ?? 0) }
        // A nested repository: one untracked entry `<dir>/`, as git lists it; nothing in it is read or diffed.
        files += repositories.map { (path: $0 + "/", status: "A", added: nil, removed: nil, bytes: 0) }
        files.sort { $0.path.utf8.lexicographicallyPrecedes($1.path.utf8) }
        return WorktreeDiff(files: files, patch: text.patch, blobShas: blobShas, truncated: text.truncated)
    }

    /// Git's blob id of the file's bytes (`blob <size>\0` + bytes), computed in the engine from the held descriptor in 64 KiB
    /// chunks (SHA-1, or SHA-256 for such a repository), the time budget checked per chunk; nothing but one chunk is in memory.
    static func blobId(of file: SafeFile, sha256: Bool, budget: Budget? = nil, probe: (@Sendable (Int) -> Void)? = nil) throws -> String {
        let header = Data("blob \(file.size)\u{0}".utf8)
        if sha256 {
            var hash = SHA256.Hasher()
            hash.update(header)
            try file.forEachChunk { chunk in try budget?.check(); probe?(chunk.count); hash.update(chunk) }
            return SHA256.hex(digest: hash.finalize())
        }
        var hash = SHA1()
        hash.update(header)
        try file.forEachChunk { chunk in try budget?.check(); probe?(chunk.count); hash.update(chunk) }
        return SHA1.hex(digest: hash.finalize())
    }

    /// Git's blob id of `bytes` (a link's target).
    static func blobId(of bytes: Data, sha256: Bool) -> String {
        var all = Data("blob \(bytes.count)\u{0}".utf8)
        all.append(bytes)
        if sha256 { return SHA256.hex(all) }
        var hash = SHA1()
        hash.update(all)
        return SHA1.hex(digest: hash.finalize())
    }

    /// A fresh engine-owned file at `path` (`O_EXCL | O_NOFOLLOW`, 0600) holding the `SafeFile`'s bytes.
    private static func write(file: SafeFile, to path: String) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SafeGitError.io("cannot create a copy of a changed path") }
        defer { close(fd) }
        do { try file.copy(toFD: fd) } catch { throw SafeGitError.io("a changed path cannot be copied (\(brief(error)))") }
    }

    private static func write(bytes: Data, to path: String) throws {
        let fd = open(path, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw SafeGitError.io("cannot create a copy of a changed path") }
        defer { close(fd) }
        try bytes.withUnsafeBytes { raw in
            var offset = 0
            while offset < raw.count {
                let n = Foundation.write(fd, raw.baseAddress! + offset, raw.count - offset)
                if n < 0 { if errno == EINTR { continue }; throw SafeGitError.io("a changed path cannot be copied") }
                offset += n
            }
        }
    }

    /// The held worktree directory and the check that the path 3a names for the key still is that very directory (`lstat`: a
    /// real directory, same device and inode), made when the diff starts and right before and right after every git process of
    /// the call. The directory is what the walk and every file read use; the check refuses the whole diff, with a text that
    /// names nothing but the engine's key, the moment the path points elsewhere.
    struct Anchor {
        let directory: EngineFiles.OpenDirectory
        let path: URL
        let key: String
        let id: (dev: dev_t, ino: ino_t)
        func check() throws {
            var st = stat()
            guard lstat(path.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR, st.st_dev == id.dev, st.st_ino == id.ino else {
                throw SafeGitError.io("the worktree of \(key) is not in place")
            }
        }
    }

    /// `dir` (under the call's shadow work tree) and its missing parents, 0700.
    private static func makeShadowDirectory(_ dir: URL) throws {
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw SafeGitError.io("cannot create the diff's directories") }
    }

    /// A fresh 0700 directory `diff-XXXXXX` directly in `tempDir` (`mkdtemp`), this call's alone.
    private static func makeCallDirectory(in tempDir: URL) throws -> URL {
        do { try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw SafeGitError.io("cannot create the diff's temporary directory") }
        // `hash-object --stdin-paths` takes one path per line: a newline anywhere in the call directory's path is refused.
        guard !tempDir.path.contains("\n") else { throw SafeGitError.io("the diff's temporary directory path holds a newline") }
        var template = Array((tempDir.path + "/diff-XXXXXX").utf8CString)
        guard mkdtemp(&template) != nil else { throw SafeGitError.io("cannot create the diff's call directory (\(String(cString: strerror(errno))))") }
        return URL(fileURLWithPath: String(decoding: template.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self), isDirectory: true)
    }

    /// An error's text with no agent-named path in it: `SafeFSError` cases carry none (or a sanitized name); anything else
    /// is named by type only.
    private static func brief(_ error: any Error) -> String {
        if let e = error as? SafeFSError {
            if case .io = e { return "cannot be read" }
            return "\(e)"
        }
        return "\(type(of: error))"
    }

    /// One time budget shared by every git process of a call: what is left is each process's timeout; nothing left is
    /// `.timedOut` before the next one starts. Awake time (`AwakeTime`): a system sleep never spends the budget.
    final class Budget: @unchecked Sendable {
        private let start = AwakeTime.now
        let limit: Duration
        init(limit: Duration) { self.limit = limit }
        var remaining: Duration { limit - (AwakeTime.now - start) }
        func check() throws { if remaining <= .zero { throw SafeGitError.timedOut } }
    }

    // MARK: Running

    private func diffText(_ command: [String], _ tail: [String], workTree: URL? = nil, anchor: Anchor? = nil, index: URL? = nil, budget: Budget? = nil) throws -> DiffText {
        let numstat = try output(command + ["--numstat", "-z"] + tail, workTree: workTree, anchor: anchor, index: index, budget: budget)
        var stat: [(path: String, added: Int?, removed: Int?)] = []
        for record in numstat.split(separator: 0, omittingEmptySubsequences: true) {
            let fields = String(decoding: record, as: UTF8.self).split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            stat.append((String(fields[2]), Int(fields[0]), Int(fields[1])))
        }
        let patch = Self.text(try output(command + ["-p"] + tail, workTree: workTree, anchor: anchor, index: index, budget: budget))
        let lines = patch.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > Self.maxDiffLines {
            return DiffText(stat: stat, patch: lines.prefix(Self.maxDiffLines).joined(separator: "\n") + "\n", truncated: true)
        }
        return DiffText(stat: stat, patch: patch, truncated: false)
    }

    /// Stdout of a successful call; a non-zero status is `.git`.
    @discardableResult
    private func output(_ args: [String], workTree: URL? = nil, anchor: Anchor? = nil, index: URL? = nil, stdin: Data? = nil,
                        outputCap: Int = SafeGit.outputCap, budget: Budget? = nil) throws -> Data {
        let r = try run(args, workTree: workTree, anchor: anchor, index: index, stdin: stdin, outputCap: outputCap, allowFailure: false, budget: budget)
        return r.stdout
    }

    /// One git call: the command line and environment come from `GitCommand` (the repository scanned, the forced `-c` flags,
    /// the pinned environment, plus `extraEnvironment`/`extraConfig`), then the runner runs it.
    /// `workTree`: the engine-owned work tree the process gets (a worktree diff's shadow directory); nil: the workspace. Never
    /// an agent's worktree. `anchor`: the held worktree whose path is checked right before and right after the process.
    private func run(_ args: [String], workTree: URL? = nil, anchor: Anchor? = nil, index: URL? = nil, stdin: Data? = nil, outputCap: Int = SafeGit.outputCap,
                     allowFailure: Bool, budget: Budget? = nil, literalPathspecs: Bool = true) throws -> (status: Int32, stdout: Data, stderr: Data) {
        // Within a budgeted call, each process gets what is left of the budget (never more than one call's timeout).
        var timeout = callTimeout
        if let budget {
            try budget.check()
            timeout = min(timeout, budget.remaining)
        }
        var git = GitCommand(gitDir: workspace.appending(path: ".git", directoryHint: .isDirectory), workTree: workTree ?? workspace, commonDir: nil)
        git.indexFile = index
        git.extraEnvironment = literalPathspecs ? Self.extraEnvironment : [:]
        git.extraConfig = Self.extraConfig
        git.timeoutSeconds = Self.seconds(timeout)
        let line: (args: [String], environment: [String: String])
        do { line = try git.commandLine(args) } catch let e as GitError { throw SafeGitError.git(e.description) }
        try anchor?.check()
        let out = try runner.run(args: line.args, env: line.environment, stdin: stdin, timeout: timeout, outputCap: outputCap, workTreeDescriptor: nil)
        try anchor?.check()
        guard out.stdout.count <= outputCap else { throw SafeGitError.outputTooLarge }
        if out.status != 0, !allowFailure {
            // An anchored (worktree) process's stderr may echo agent-named paths: dropped. Elsewhere it is ASCII-folded, capped
            // and stripped of path-like tokens before it is shown.
            let detail = anchor == nil ? Self.sanitizedStderr(out.stderr) : ""
            throw SafeGitError.git("git \(args.first ?? "") failed (\(out.status))" + (detail.isEmpty ? "" : ": \(detail)"))
        }
        return out
    }

    // MARK: Shapes

    static func seconds(_ d: Duration) -> TimeInterval {
        Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
    }

    static func checkRevShape(_ s: String) throws {
        guard (7...40).contains(s.utf8.count), s.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x61...0x66).contains($0) }) else {
            throw SafeGitError.badRev
        }
    }

    /// `s` when it is a sha; `.badRev` otherwise. Every `rev:` parameter (an agent-named commit the caller verified).
    static func sha(_ s: String) throws -> String {
        try checkRevShape(s)
        return s
    }

    /// A sha (checked), or an engine-recorded ref name (qualified): `head`, `mergeBase` and `isAncestor` only.
    static func revArg(_ s: String) throws -> String {
        if (try? checkRevShape(s)) != nil { return s }
        return try qualifiedRef(s)
    }

    /// `main` → `refs/heads/main`, `item/K` → `refs/heads/item/K`; `refs/...` as given. Only ref-name characters, no `..`,
    /// no component empty or starting with `-` or `.`, nothing ending in `.lock`.
    static func qualifiedRef(_ name: String) throws -> String {
        guard !name.isEmpty, !name.contains(".."), !name.hasSuffix("/"), !name.hasSuffix(".lock"),
              name.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || [0x2E, 0x2D, 0x5F, 0x2F].contains($0) }),
              name.split(separator: "/", omittingEmptySubsequences: false).allSatisfy({ !$0.isEmpty && !$0.hasPrefix("-") && !$0.hasPrefix(".") })
        else { throw SafeGitError.badRef }
        return name.hasPrefix("refs/") ? name : "refs/heads/\(name)"
    }

    /// `refs/brahma/shares/<id>`: the id a single component, `[A-Za-z0-9][A-Za-z0-9._-]{0,127}`, no `..`, not `.lock`.
    static func shareRef(_ id: String) throws -> String {
        guard (1...128).contains(id.utf8.count), !id.contains(".."), !id.hasSuffix(".lock"),
              let first = id.utf8.first, (0x30...0x39).contains(first) || (0x41...0x5A).contains(first) || (0x61...0x7A).contains(first),
              id.utf8.allSatisfy({ (0x30...0x39).contains($0) || (0x41...0x5A).contains($0) || (0x61...0x7A).contains($0) || [0x2E, 0x2D, 0x5F].contains($0) })
        else { throw SafeGitError.badRef }
        return sharesPrefix + id
    }

    static func checkPath(_ path: String) throws -> String {
        do { return try SafeFS.components(path).joined(separator: "/") } catch { throw SafeGitError.badPath }
    }

    /// `<sha>:<path>`, the object name of a blob (rev checked as a sha, path as `SafeFS` checks it).
    static func object(_ rev: String, _ path: String) throws -> String {
        try checkRevShape(rev)
        return "\(rev):\(try checkPath(path))"
    }

    static func fullSha(_ data: Data) -> String? {
        let s = text(data)
        return (s.count == 40 || s.count == 64) && s.allSatisfy({ $0.isHexDigit && !$0.isUppercase }) ? s : nil
    }

    /// Git's stderr fit for an error: printable ASCII only (anything else `?`), no token holding a `/` (a path), at most 300.
    static func sanitizedStderr(_ data: Data) -> String {
        let words = text(data).split(whereSeparator: { $0.isWhitespace }).filter { !$0.contains("/") }
        let folded = words.joined(separator: " ").unicodeScalars.map { (0x20...0x7E).contains($0.value) ? Character($0) : "?" }
        return String(folded.prefix(300))
    }

    static func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }

    static func lines(_ data: Data) -> [String] { text(data).split(separator: "\n").map(String.init).filter { !$0.isEmpty } }
}
