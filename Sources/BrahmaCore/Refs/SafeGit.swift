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
        }
    }
}

/// The seam between `SafeGit` and a git process: `args` is the full command line after `git` and `env` the full environment,
/// both built by `GitCommand` (`commandLine`), so a fake records exactly what git would have been given.
public protocol GitProcessRunning: Sendable {
    /// Runs git. Throws `SafeGitError.timedOut` when the timeout killed it and `.outputTooLarge` when stdout passed `outputCap`.
    func run(args: [String], env: [String: String], stdin: Data?, timeout: Duration, outputCap: Int) throws -> (status: Int32, stdout: Data, stderr: Data)
}

/// Runs the command line through `GitCommand` (`runPrepared`: output to files under `tempRoot`, the timeout, the capture cap).
public struct LiveGitRunner: GitProcessRunning {
    /// Where git's captured output goes; the engine passes its data home's 0700 `tmp` (A-I1b). Nil: the process temp dir.
    public var tempRoot: URL?

    public init(tempRoot: URL? = nil) { self.tempRoot = tempRoot }

    public func run(args: [String], env: [String: String], stdin: Data?, timeout: Duration, outputCap: Int) throws -> (status: Int32, stdout: Data, stderr: Data) {
        guard let gitDir = env["GIT_DIR"], let workTree = env["GIT_WORK_TREE"] else { throw SafeGitError.io("git environment without GIT_DIR") }
        var git = GitCommand(gitDir: URL(fileURLWithPath: gitDir, isDirectory: true), workTree: URL(fileURLWithPath: workTree, isDirectory: true), commonDir: nil)
        git.timeoutSeconds = SafeGit.seconds(timeout)
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
        /// The patch was cut at `maxDiffLines`, or git's output at its cap.
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

    public func updateShareRef(_ messageRefId: String, to sha: String) throws {
        try Self.checkRevShape(sha)
        try output(["update-ref", try Self.shareRef(messageRefId), sha])
    }

    public func deleteShareRef(_ messageRefId: String) throws {
        try output(["update-ref", "-d", try Self.shareRef(messageRefId)])
    }

    /// Lets go of what deleted share refs kept, now: every reflog entry, then every unreachable loose object. A purged
    /// secret-bearing blob must be gone at once; this is a rare owner action, and an agent's in-flight `git add` can retry.
    public func expireAndPrune() throws {
        try output(["reflog", "expire", "--expire=now", "--all"])
        try output(["prune", "--expire=now"])
    }

    // MARK: Worktree diffs

    /// The changes in the item worktree `<ws>/.brahma/wt/<KEY>` against `against` (an engine-verified tree-ish; nil: the tip
    /// of `item/<KEY>`, so only uncommitted changes), with a private index under `tempDir` (`read-tree`, then the paths git
    /// reports changed or untracked are read through `SafeFS`, their bytes copied to engine-owned files under `tempDir` and
    /// hashed by ONE `hash-object --stdin-paths`, so the patch is made from bytes the engine checked, never from a second look
    /// at the agent's paths, and git never opens one). Bounded: a constant number of git processes whatever the number of
    /// changed paths; more than `maxDiffFiles` paths or `maxDiffBytes` bytes refuses the whole diff before anything is hashed;
    /// the whole call shares one time budget (`timeout`). The agent's own index is never read or written.
    public func worktreeDiff(key: String, worktree: URL, against: String? = nil, tempDir: URL, fs: SafeFS) throws -> WorktreeDiff {
        guard (try? GitWorkspace.validKey(key)) != nil else { throw SafeGitError.badRef }
        let budget = Budget(limit: callTimeout)
        let base: String
        if let against { try Self.checkRevShape(against); base = against } else { base = try head("item/\(key)", budget: budget) }
        do { try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]) }
        catch { throw SafeGitError.io("\(tempDir.path) cannot be created") }
        let index = tempDir.appending(path: "index-\(key)")
        try? FileManager.default.removeItem(at: index)
        @discardableResult
        func wt(_ args: [String], stdin: Data? = nil) throws -> Data { try output(args, workTree: worktree, index: index, stdin: stdin, budget: budget) }
        try wt(["read-tree", "--end-of-options", base])
        // What git sees changed between that tree and the worktree, and what is untracked: names only.
        var changed: [(status: String, path: String)] = []
        let status = try wt(["diff", "--name-status", "-z"] + Self.noDiffPrograms + ["--"]).split(separator: 0, omittingEmptySubsequences: true)
        var i = 0
        while i + 1 < status.count {
            changed.append((String(decoding: status[i], as: UTF8.self), String(decoding: status[i + 1], as: UTF8.self)))
            i += 2
        }
        for raw in try wt(["ls-files", "--others", "--exclude-standard", "-z", "--"]).split(separator: 0, omittingEmptySubsequences: true) {
            changed.append(("A", String(decoding: raw, as: UTF8.self)))
        }
        guard changed.count <= maxDiffFiles else { throw SafeGitError.tooManyChanges(files: changed.count, bytes: 0) }
        // Every present path opened through SafeFS (the descriptor checked, the size from its fstat); the byte cap is judged
        // on those sizes before any byte is copied or hashed.
        var present: [(path: String, file: SafeFile)] = []
        var removals = Data()
        var total = 0
        for (status, path) in changed {
            if status.hasPrefix("D") { removals.append(contentsOf: path.utf8); removals.append(0); continue }
            let file: SafeFile
            do { file = try fs.open(path, inWorktree: key, maxBytes: Self.maxBinaryBytes) } catch { throw SafeGitError.io("\(path): \(error)") }
            total += file.size
            guard total <= maxDiffBytes else { throw SafeGitError.tooManyChanges(files: changed.count, bytes: total) }
            present.append((path, file))
        }
        try budget.check()
        // The checked bytes, copied to fresh engine-owned files, hashed by one git process that never sees an agent path.
        let blobDir = tempDir.appending(path: "blobs-\(key)", directoryHint: .isDirectory)
        try? FileManager.default.removeItem(at: blobDir)
        defer { try? FileManager.default.removeItem(at: blobDir) }
        var blobShas: [String: String] = [:]
        var indexInfo = Data()
        if !present.isEmpty {
            do { try FileManager.default.createDirectory(at: blobDir, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700]) }
            catch { throw SafeGitError.io("\(blobDir.path) cannot be created") }
            // `--stdin-paths` takes one path per line: these are the engine's own names under `tempDir`, never an agent's.
            guard !blobDir.path.contains("\n") else { throw SafeGitError.io("\(blobDir.path) holds a newline") }
            var paths = Data()
            for (n, entry) in present.enumerated() {
                let copy = blobDir.appending(path: "\(n)").path
                let fd = open(copy, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
                guard fd >= 0 else { throw SafeGitError.io("\(copy) cannot be created") }
                defer { close(fd) }
                do { try entry.file.copy(toFD: fd) } catch { throw SafeGitError.io("\(entry.path): \(error)") }
                paths.append(contentsOf: copy.utf8); paths.append(UInt8(ascii: "\n"))
            }
            let shas = Self.lines(try wt(["hash-object", "-w", "--no-filters", "--stdin-paths"], stdin: paths))
            guard shas.count == present.count, shas.allSatisfy({ Self.fullSha(Data($0.utf8)) != nil }) else {
                throw SafeGitError.git("hash-object gave \(shas.count) ids for \(present.count) files")
            }
            for (entry, sha) in zip(present, shas) {
                blobShas[entry.path] = sha
                indexInfo.append(contentsOf: "\(entry.file.executable ? "100755" : "100644") \(sha)\t\(entry.path)".utf8); indexInfo.append(0)
            }
        }
        if !removals.isEmpty { try wt(["update-index", "-z", "--force-remove", "--stdin"], stdin: removals) }
        if !indexInfo.isEmpty { try wt(["update-index", "-z", "--index-info"], stdin: indexInfo) }
        // Now the index holds exactly the bytes checked: every comparison below is between objects.
        let cached = ["diff", "--cached"] + Self.noDiffPrograms
        let names = try wt(cached + ["--name-status", "-z", "--end-of-options", base, "--"]).split(separator: 0, omittingEmptySubsequences: true)
        var statuses: [(path: String, status: String)] = []
        i = 0
        while i + 1 < names.count {
            statuses.append((String(decoding: names[i + 1], as: UTF8.self), String(decoding: names[i], as: UTF8.self)))
            i += 2
        }
        let text = try diffText(cached, ["--end-of-options", base, "--"], workTree: worktree, index: index, budget: budget)
        let counts = Dictionary(text.stat.map { ($0.path, ($0.added, $0.removed)) }, uniquingKeysWith: { a, _ in a })
        let sizes = Dictionary(present.map { ($0.path, $0.file.size) }, uniquingKeysWith: { a, _ in a })
        let files = statuses.map { (path: $0.path, status: $0.status, added: counts[$0.path]?.0, removed: counts[$0.path]?.1, bytes: sizes[$0.path] ?? 0) }
        return WorktreeDiff(files: files, patch: text.patch, blobShas: blobShas, truncated: text.truncated)
    }

    /// One time budget shared by every git process of a call: what is left is each process's timeout; nothing left is
    /// `.timedOut` before the next one starts.
    final class Budget: @unchecked Sendable {
        private let start = ContinuousClock.now
        let limit: Duration
        init(limit: Duration) { self.limit = limit }
        var remaining: Duration { limit - (ContinuousClock.now - start) }
        func check() throws { if remaining <= .zero { throw SafeGitError.timedOut } }
    }

    // MARK: Running

    /// Tests only: runs `args` through the runner as every call does.
    @discardableResult
    func testOnlyRun(_ args: [String]) throws -> Data { try output(args) }

    private func diffText(_ command: [String], _ tail: [String], workTree: URL? = nil, index: URL? = nil, budget: Budget? = nil) throws -> DiffText {
        let numstat = try output(command + ["--numstat", "-z"] + tail, workTree: workTree, index: index, budget: budget)
        var stat: [(path: String, added: Int?, removed: Int?)] = []
        for record in numstat.split(separator: 0, omittingEmptySubsequences: true) {
            let fields = String(decoding: record, as: UTF8.self).split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { continue }
            stat.append((String(fields[2]), Int(fields[0]), Int(fields[1])))
        }
        let patch = Self.text(try output(command + ["-p"] + tail, workTree: workTree, index: index, budget: budget))
        let lines = patch.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.count > Self.maxDiffLines {
            return DiffText(stat: stat, patch: lines.prefix(Self.maxDiffLines).joined(separator: "\n") + "\n", truncated: true)
        }
        return DiffText(stat: stat, patch: patch, truncated: false)
    }

    /// Stdout of a successful call; a non-zero status is `.git`.
    @discardableResult
    private func output(_ args: [String], workTree: URL? = nil, index: URL? = nil, stdin: Data? = nil, outputCap: Int = SafeGit.outputCap,
                        budget: Budget? = nil) throws -> Data {
        let r = try run(args, workTree: workTree, index: index, stdin: stdin, outputCap: outputCap, allowFailure: false, budget: budget)
        return r.stdout
    }

    /// One git call: the command line and environment come from `GitCommand` (the repository scanned, the forced `-c` flags,
    /// the pinned environment, plus `extraEnvironment`/`extraConfig`), then the runner runs it.
    private func run(_ args: [String], workTree: URL? = nil, index: URL? = nil, stdin: Data? = nil, outputCap: Int = SafeGit.outputCap,
                     allowFailure: Bool, budget: Budget? = nil) throws -> (status: Int32, stdout: Data, stderr: Data) {
        // Within a budgeted call, each process gets what is left of the budget (never more than one call's timeout).
        var timeout = callTimeout
        if let budget {
            try budget.check()
            timeout = min(timeout, budget.remaining)
        }
        var git = GitCommand(gitDir: workspace.appending(path: ".git", directoryHint: .isDirectory), workTree: workTree ?? workspace, commonDir: nil)
        git.indexFile = index
        git.extraEnvironment = Self.extraEnvironment
        git.extraConfig = Self.extraConfig
        git.timeoutSeconds = Self.seconds(timeout)
        let line: (args: [String], environment: [String: String])
        do { line = try git.commandLine(args) } catch let e as GitError { throw SafeGitError.git(e.description) }
        let out = try runner.run(args: line.args, env: line.environment, stdin: stdin, timeout: timeout, outputCap: outputCap)
        guard out.stdout.count <= outputCap else { throw SafeGitError.outputTooLarge }
        if out.status != 0, !allowFailure {
            throw SafeGitError.git("git \(args.first ?? "") failed (\(out.status))" + (out.stderr.isEmpty ? "" : ": \(Self.text(out.stderr).prefix(500))"))
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

    static func text(_ data: Data) -> String { String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }

    static func lines(_ data: Data) -> [String] { text(data).split(separator: "\n").map(String.init).filter { !$0.isEmpty } }
}
