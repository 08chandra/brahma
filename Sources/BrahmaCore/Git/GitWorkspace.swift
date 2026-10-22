import Foundation

/// A git command that did not succeed.
public enum GitError: Error, Equatable, CustomStringConvertible, LocalizedError {
    case failed(command: String, status: Int32, stderr: String)

    public var description: String {
        switch self {
        case .failed(let command, let status, let stderr):
            "git \(command) failed (\(status))" + (stderr.isEmpty ? "" : ": \(stderr)")
        }
    }
    public var errorDescription: String? { description }
}

/// One line of `git diff --name-status`: `A`, `M`, `D`, `R100`, ...; for a rename or copy, the new path.
public struct GitChange: Equatable, Sendable {
    public var status: String
    public var path: String
    /// For a rename or copy, the path it came from.
    public var oldPath: String?
    public init(status: String, path: String, oldPath: String? = nil) { self.status = status; self.path = path; self.oldPath = oldPath }
}

/// The one way the engine runs git (worktrees, commits, diffs, name-status, log, merges, rebases, `isDirty`).
///
/// A repository is never discovered from an agent-writable path. The git dir is always given explicitly, from the
/// engine's own records: `<ws>/.git` for the workspace, `<ws>/.git/worktrees/<KEY>` (with `GIT_COMMON_DIR=<ws>/.git`)
/// for an item's worktree. Nothing is read from the worktree's `.git` file or the admin directory's `commondir`. Hooks,
/// fsmonitor, external diff and pagers are switched off, global and system config are ignored, and the process gets
/// `ChildEnvironment`'s allowlist, so a crafted `.git`, config or hook inside a worktree cannot run anything.
struct GitCommand: Sendable {
    let gitDir: URL
    let workTree: URL
    /// Set for a linked worktree: the workspace's own `.git`.
    let commonDir: URL?

    static let timeout: TimeInterval = 60
    static let lockRetries = 3
    static let lockRetryDelay: TimeInterval = 0.2
    static let maxCapture = 8 * 1024 * 1024

    /// Applied to every call, before the subcommand.
    static let configFlags = [
        "-c", "user.name=Brahma", "-c", "user.email=engine@brahma.local", "-c", "commit.gpgsign=false",
        "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "core.pager=cat", "-c", "diff.external=",
        "-c", "protocol.ext.allow=never", "-c", "core.quotepath=false", "-c", "gc.auto=0",
    ]

    struct Output {
        var status: Int32
        var stdout: Data
        var stderr: String
        /// The output was longer than the capture limit.
        var cut: Bool
        /// The 60 s timeout killed git.
        var timedOut = false
        var text: String { String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func environment() -> [String: String] {
        var env = ChildEnvironment.make(base: ProcessInfo.processInfo.environment, purpose: .general)
        env["GIT_DIR"] = gitDir.path
        env["GIT_WORK_TREE"] = workTree.path
        if let commonDir { env["GIT_COMMON_DIR"] = commonDir.path }
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_ATTR_NOSYSTEM"] = "1"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        return env
    }

    func arguments(_ args: [String]) -> [String] {
        ["git", "-C", workTree.path] + Self.configFlags + args
    }

    /// Runs git with stdin `/dev/null` and a 60 s timeout. Stderr containing `index.lock` is retried 3 times at 200 ms.
    /// A non-zero status throws unless `allowFailure`.
    @discardableResult
    func run(_ args: [String], allowFailure: Bool = false, maxOutput: Int = GitCommand.maxCapture) throws -> Output {
        var attempt = 0
        while true {
            let out = try runOnce(args, maxOutput: maxOutput)
            if out.status == 0 || allowFailure && !out.stderr.contains("index.lock") { return out }
            if out.stderr.contains("index.lock"), attempt < Self.lockRetries {
                attempt += 1
                Thread.sleep(forTimeInterval: Self.lockRetryDelay)
                continue
            }
            if allowFailure { return out }
            throw GitError.failed(command: args.joined(separator: " "), status: out.status,
                                  stderr: String(out.stderr.prefix(2000)))
        }
    }

    private func runOnce(_ args: [String], maxOutput: Int) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = arguments(args)
        process.environment = environment()
        process.standardInput = FileHandle.nullDevice
        // Output goes to files, not pipes: concurrent children cannot hold each other's pipe ends open, and a grandchild
        // that outlives git cannot keep us waiting for end of file.
        let base = FileManager.default.temporaryDirectory.appending(path: "brahma-git-\(UUID().uuidString)")
        let outURL = base.appendingPathExtension("out"), errURL = base.appendingPathExtension("err")
        guard FileManager.default.createFile(atPath: outURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              FileManager.default.createFile(atPath: errURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let outHandle = FileHandle(forWritingAtPath: outURL.path), let errHandle = FileHandle(forWritingAtPath: errURL.path)
        else { throw GitError.failed(command: args.joined(separator: " "), status: -1, stderr: "no temporary space for git output") }
        defer {
            try? outHandle.close(); try? errHandle.close()
            try? FileManager.default.removeItem(at: outURL); try? FileManager.default.removeItem(at: errURL)
        }
        process.standardOutput = outHandle
        process.standardError = errHandle
        do { try process.run() } catch {
            throw GitError.failed(command: args.joined(separator: " "), status: -1, stderr: "\(error)")
        }
        let timedOut = TimeoutFlag()
        let timer = DispatchWorkItem { timedOut.mark(); process.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + Self.timeout, execute: timer)
        process.waitUntilExit()
        timer.cancel()
        func read(_ url: URL, limit: Int) -> (Data, Bool) {
            guard let h = try? FileHandle(forReadingFrom: url) else { return (Data(), false) }
            defer { try? h.close() }
            let data = (try? h.read(upToCount: limit)) ?? Data()
            let more = ((try? h.read(upToCount: 1)) ?? Data()).isEmpty == false
            return (data, more)
        }
        let (stdout, cut) = read(outURL, limit: maxOutput)
        var stderr = String(decoding: read(errURL, limit: 64 * 1024).0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if timedOut.cut { stderr = "timed out after \(Int(Self.timeout)) s" + (stderr.isEmpty ? "" : ": \(stderr)") }
        return Output(status: process.terminationStatus, stdout: stdout, stderr: stderr, cut: cut, timedOut: timedOut.cut)
    }
}

/// A flag set from a timer thread.
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var over = false
    func mark() { lock.lock(); over = true; lock.unlock() }
    var cut: Bool { lock.lock(); defer { lock.unlock() }; return over }
}

/// The git repository of one company workspace. The workspace itself is the repo (branch `main`); each leased item gets a
/// worktree at `<ws>/.brahma/wt/<KEY>` on branch `item/<KEY>`.
public struct GitWorkspace: Sendable {
    public let root: URL
    /// Where the per-item lock files live. Must not be a place agents can write; the default is a per-workspace directory
    /// under the system temporary directory.
    public let lockDirectory: URL
    /// How long to wait for an item's lock before giving up on it (the caller skips the item this pass).
    public var lockTimeout: TimeInterval = 10

    public init(root: URL, lockDirectory: URL? = nil) {
        self.root = root
        self.lockDirectory = lockDirectory ?? FileManager.default.temporaryDirectory
            .appending(path: "brahma-locks/\(StableHash.fnv1a64(root.path))", directoryHint: .isDirectory)
    }

    // MARK: Layout

    var worktreesDir: URL { root.appending(path: ".brahma/wt", directoryHint: .isDirectory) }
    public func worktreePath(key: String) -> URL { worktreesDir.appending(path: key, directoryHint: .isDirectory) }
    public func branch(key: String) -> String { "item/\(key)" }
    /// Every ref the engine reads is fully qualified, so a tag named `main` or `item/<KEY>` can never stand in for the branch.
    public static let mainRef = "refs/heads/main"
    public func branchRef(key: String) -> String { "refs/heads/item/\(key)" }
    private var gitDir: URL { root.appending(path: ".git", directoryHint: .isDirectory) }
    private func adminDir(key: String) -> URL { gitDir.appending(path: "worktrees/\(key)", directoryHint: .isDirectory) }
    private var main: GitCommand { GitCommand(gitDir: gitDir, workTree: root, commonDir: nil) }

    private static func resolved(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

    private static func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    private static func validKey(_ key: String) throws {
        guard key.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil else {
            throw GitError.failed(command: "worktree \(key)", status: -1, stderr: "invalid item key")
        }
    }

    private static func validRef(_ ref: String) throws {
        guard !ref.isEmpty, !ref.hasPrefix("-"), !ref.contains(where: { $0.isWhitespace || $0.isNewline || $0.asciiValue.map { $0 < 32 } ?? false }) else {
            throw GitError.failed(command: "ref \(ref.prefix(40))", status: -1, stderr: "invalid ref")
        }
    }

    /// The git context for the workspace itself or one of its item worktrees; any other directory is refused.
    private func context(for dir: URL) throws -> GitCommand {
        let target = Self.resolved(dir)
        if target == Self.resolved(root) { return main }
        let parent = Self.resolved(dir.deletingLastPathComponent())
        let key = dir.lastPathComponent
        guard parent == Self.resolved(worktreesDir), (try? Self.validKey(key)) != nil,
              dir.deletingLastPathComponent().lastPathComponent == "wt" else {
            throw GitError.failed(command: "-C \(dir.lastPathComponent)", status: -1, stderr: "not a checkout managed by Brahma")
        }
        // A worktree replaced by a link to somewhere else is not an engine checkout.
        guard !Self.isSymlink(dir), !Self.isSymlink(worktreesDir), FileManager.default.fileExists(atPath: adminDir(key: key).path) else {
            throw GitError.failed(command: "-C \(key)", status: -1, stderr: "\(key) is not a registered worktree")
        }
        heal(key: key)
        return GitCommand(gitDir: adminDir(key: key), workTree: worktreePath(key: key), commonDir: gitDir)
    }

    /// Rewrites the three pointers that tie a worktree to this repository from the engine's own records. Git resolves
    /// refs through `commondir` whatever `GIT_COMMON_DIR` says, so an agent that repointed it would otherwise make a
    /// commit move a branch in another repository.
    private func heal(key: String) {
        let admin = adminDir(key: key)
        func ensure(_ url: URL, _ text: String) {
            if (try? String(contentsOf: url, encoding: .utf8)) != text { try? text.write(to: url, atomically: true, encoding: .utf8) }
        }
        ensure(admin.appending(path: "commondir"), "../..\n")
        ensure(admin.appending(path: "gitdir"), "\(worktreePath(key: key).path)/.git\n")
        ensure(worktreePath(key: key).appending(path: ".git"), "gitdir: \(admin.path)\n")
    }

    // MARK: Repository

    /// Makes `<ws>` a git repository on `main` with every existing file imported, and keeps `.brahma/` out of it.
    public func ensureRepo() throws {
        let fm = FileManager.default
        var isDir: ObjCBool = false
        let exists = fm.fileExists(atPath: gitDir.path, isDirectory: &isDir)
        if exists, !isDir.boolValue || Self.isSymlink(gitDir) {
            throw GitError.failed(command: "init", status: -1, stderr: ".git in the workspace is not a plain directory")
        }
        try fm.createDirectory(at: root, withIntermediateDirectories: true)
        if !exists {
            try main.run(["init", "--quiet", "--template="])
            try main.run(["symbolic-ref", "HEAD", "refs/heads/main"])
        }
        try ensureExclude()
        if try head(of: "refs/heads/main") == nil {
            if try head(of: "HEAD") != nil {
                try main.run(["branch", "main", "HEAD"])
            } else {
                try main.run(["add", "-A"])
                try main.run(["commit", "--quiet", "--allow-empty", "--no-verify", "-m", "Import existing files"])
            }
        }
    }

    private func ensureExclude() throws {
        let info = gitDir.appending(path: "info", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: info, withIntermediateDirectories: true)
        let file = info.appending(path: "exclude")
        let current = (try? String(contentsOf: file, encoding: .utf8)) ?? ""
        guard !current.split(separator: "\n").contains(".brahma/") else { return }
        let prefix = current.isEmpty || current.hasSuffix("\n") ? "" : "\n"
        try (current + prefix + ".brahma/\n").write(to: file, atomically: true, encoding: .utf8)
    }

    // MARK: Worktrees

    /// Creates `<ws>/.brahma/wt/<KEY>` on `item/<KEY>` (a new branch from `main`, or the existing branch) or returns the
    /// checkout that is already registered. Anything else in that place is an error and is never touched.
    @discardableResult
    public func addWorktree(key: String) throws -> URL {
        try Self.validKey(key)
        return try withKeyLock(key) { try addWorktreeLocked(key: key) }
    }

    /// True when `<ws>/.brahma/wt/<KEY>` is a real directory registered as a worktree of this repository.
    public func hasCheckout(key: String) -> Bool {
        var isDir: ObjCBool = false
        let path = worktreePath(key: key)
        return (try? Self.validKey(key)) != nil && FileManager.default.fileExists(atPath: path.path, isDirectory: &isDir) && isDir.boolValue
            && !Self.isSymlink(path) && FileManager.default.fileExists(atPath: adminDir(key: key).path)
    }

    /// Per-item exclusion shared by every process that touches this workspace: an exclusive `flock` on
    /// `<lockDirectory>/<KEY>.lock`. Adding and removing the worktree of one item never interleave, so a removal that
    /// decided "nobody holds this" cannot delete the checkout a new claim has just found and reused. The wait is bounded.
    private func withKeyLock<T>(_ key: String, _ body: () throws -> T) throws -> T {
        let dir = lockDirectory
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let fd = open(dir.appending(path: "\(key).lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw GitError.failed(command: "lock \(key)", status: -1, stderr: "cannot open the lock file") }
        defer { close(fd) }
        let deadline = Date().addingTimeInterval(lockTimeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if errno != EWOULDBLOCK && errno != EINTR { throw GitError.failed(command: "lock \(key)", status: -1, stderr: "cannot take the lock") }
            guard Date() < deadline else { throw GitError.failed(command: "lock \(key)", status: -1, stderr: "\(key) is busy; try again later") }
            Thread.sleep(forTimeInterval: 0.02)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private func addWorktreeLocked(key: String) throws -> URL {
        let fm = FileManager.default
        let path = worktreePath(key: key)
        if Self.isSymlink(worktreesDir) {
            throw GitError.failed(command: "worktree add \(key)", status: -1, stderr: "\(worktreesDir.path) is a link")
        }
        try fm.createDirectory(at: worktreesDir, withIntermediateDirectories: true)
        if fm.fileExists(atPath: path.path) || Self.isSymlink(path) {
            if fm.fileExists(atPath: adminDir(key: key).path), !Self.isSymlink(path) { return path }
            throw GitError.failed(command: "worktree add \(key)", status: -1,
                                  stderr: "\(path.path) already exists and is not a checkout of this workspace")
        }
        try main.run(["worktree", "prune"])
        let name = branch(key: key)
        if try head(of: branchRef(key: key)) != nil {
            try main.run(["worktree", "add", "--quiet", path.path, name])
        } else {
            try main.run(["worktree", "add", "--quiet", "-b", name, path.path, Self.mainRef])
        }
        guard fm.fileExists(atPath: adminDir(key: key).path) else {
            throw GitError.failed(command: "worktree add \(key)", status: -1, stderr: "git registered the worktree under another name")
        }
        return path
    }

    /// Commits whatever is in the worktree as `"<KEY>: auto-commit before release"`, removes its directory and keeps the
    /// branch. A directory that is not a registered checkout is left alone; one that was tampered with is deleted.
    ///
    /// `keepIf` is asked under the item's lock, after any concurrent add has finished: when it returns true (a lease exists
    /// now) nothing is removed, and when it throws nothing is removed either (an unreadable database is not "no lease").
    public func removeWorktree(key: String, keepIf: () throws -> Bool) throws {
        try Self.validKey(key)
        try withKeyLock(key) {
            if try keepIf() { return }
            try removeWorktreeLocked(key: key)
        }
    }

    private func removeWorktreeLocked(key: String) throws {
        let fm = FileManager.default
        let path = worktreePath(key: key)
        if Self.isSymlink(path) {
            try? fm.removeItem(at: path)
        } else if fm.fileExists(atPath: path.path), fm.fileExists(atPath: adminDir(key: key).path) {
            try commitAll(in: path, message: "\(key): auto-commit before release")
            let removed = try main.run(["worktree", "remove", "--force", path.path], allowFailure: true)
            // A checkout whose link back was rewritten cannot be removed by git; its work is committed, so delete it.
            if removed.status != 0 { try? fm.removeItem(at: path) }
        }
        try? main.run(["worktree", "prune"])
    }

    /// Registered `item/<KEY>` worktrees under `<ws>/.brahma/wt`. Names starting with "." (engine checkouts such as
    /// `.preview`, `.release`, `.merge`) and worktrees on other branches are never listed.
    public func itemWorktrees() throws -> [(key: String, path: URL)] {
        let listing = try main.run(["worktree", "list", "--porcelain"]).text
        let wt = Self.resolved(worktreesDir)
        var found: [(String, URL)] = []
        var path: String?
        let lines: [String] = listing.split(separator: "\n", omittingEmptySubsequences: false).map(String.init) + [""]
        for line in lines {
            if line.hasPrefix("worktree ") {
                path = String(line.dropFirst("worktree ".count))
            } else if line.hasPrefix("branch "), let p = path {
                let url = URL(fileURLWithPath: p)
                let key = url.lastPathComponent
                if !key.hasPrefix("."), (try? Self.validKey(key)) != nil, Self.resolved(url.deletingLastPathComponent()) == wt,
                   line == "branch refs/heads/item/\(key)" {
                    found.append((key, worktreePath(key: key)))
                }
            } else if line.isEmpty {
                path = nil
            }
        }
        return found
    }

    public func deleteBranch(key: String) throws {
        try Self.validKey(key)
        try main.run(["branch", "-D", branch(key: key)])
    }

    // MARK: Check checkouts

    private static func validRunId(_ id: String) throws {
        guard id.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil else {
            throw GitError.failed(command: "worktree \(id.prefix(40))", status: -1, stderr: "invalid run id")
        }
    }

    private static func validCommit(_ commit: String) throws {
        guard commit.range(of: "^[0-9a-fA-F]{7,64}$", options: .regularExpression) != nil else {
            throw GitError.failed(command: "commit \(commit.prefix(40))", status: -1, stderr: "invalid commit")
        }
    }

    /// A clean detached checkout of exactly `commit` at `<ws>/.brahma/wt-check/<runId>`, for an engine-run check. Anything
    /// left at that place by a crashed run is removed first.
    public func addRunWorktree(runId: String, commit: String) throws -> URL {
        try Self.validRunId(runId); try Self.validCommit(commit)
        let paths = CheckPaths(workspace: root)
        if Self.isSymlink(paths.runWorktreesRoot) {
            throw GitError.failed(command: "worktree add \(runId)", status: -1, stderr: "\(paths.runWorktreesRoot.path) is a link")
        }
        try FileManager.default.createDirectory(at: paths.runWorktreesRoot, withIntermediateDirectories: true)
        removeRunWorktree(runId: runId)
        let path = paths.runWorktree(runId: runId)
        try main.run(["worktree", "add", "--quiet", "--detach", path.path, commit])
        return path
    }

    /// Removes one run's checkout (whatever the check left in it); never throws.
    public func removeRunWorktree(runId: String) {
        guard (try? Self.validRunId(runId)) != nil else { return }
        let fm = FileManager.default
        let path = CheckPaths(workspace: root).runWorktree(runId: runId)
        if Self.isSymlink(path) {
            try? fm.removeItem(at: path)
        } else if fm.fileExists(atPath: path.path) {
            _ = try? main.run(["worktree", "remove", "--force", path.path], allowFailure: true)
            if fm.fileExists(atPath: path.path) { try? fm.removeItem(at: path) }
        }
        _ = try? main.run(["worktree", "prune"], allowFailure: true)
    }

    /// Start-up: no check is running, so every leftover run checkout goes.
    public func removeRunWorktrees() {
        let dir = CheckPaths(workspace: root).runWorktreesRoot
        guard !Self.isSymlink(dir), let names = try? FileManager.default.contentsOfDirectory(atPath: dir.path) else { return }
        for name in names {
            if (try? Self.validRunId(name)) != nil { removeRunWorktree(runId: name) }
            else { try? FileManager.default.removeItem(at: dir.appending(path: name)) }
        }
        _ = try? main.run(["worktree", "prune"], allowFailure: true)
    }

    // MARK: Commits and refs

    /// Stages everything and commits it; the new `HEAD`, or nil when there was nothing to commit.
    @discardableResult
    public func commitAll(in dir: URL, message: String) throws -> String? {
        let git = try context(for: dir)
        try git.run(["add", "-A"])
        let staged = try git.run(["diff", "--cached", "--quiet"], allowFailure: true)
        if staged.status == 0 { return nil }
        guard staged.status == 1 else {
            throw GitError.failed(command: "diff --cached --quiet", status: staged.status, stderr: staged.stderr)
        }
        try git.run(["commit", "--quiet", "--no-verify", "-m", message])
        return try git.run(["rev-parse", "HEAD"]).text
    }

    /// The commit a checkout's `HEAD` points at.
    public func headCommit(in dir: URL) throws -> String {
        try context(for: dir).run(["rev-parse", "HEAD"]).text
    }

    /// Puts the checkout back on `commit` and removes everything untracked (the write barrier of a plan turn).
    public func resetHard(in dir: URL, to commit: String) throws {
        try Self.validCommit(commit)
        let git = try context(for: dir)
        try git.run(["reset", "--hard", "--quiet", commit])
        try git.run(["clean", "-fdq"])
    }

    // MARK: Plan-turn write barrier

    /// How much output one barrier git call may produce; more fails closed.
    public var planBarrierOutputLimit = 32 * 1024 * 1024

    /// The barrier could not tell whether the turn wrote: `found` is what it saw (and put back) before it failed.
    public struct PlanBarrierError: Error, CustomStringConvertible {
        public var found: [String]
        public var reason: String
        public var description: String { "barrier check failed: \(reason)" }
    }

    /// What a plan turn must leave exactly as it found it besides tracked and untracked files (which `isDirty` and `HEAD`
    /// cover): the ignored files of the checkout, every ref, what the index says, and the repository's own files.
    public struct PlanBarrier: Sendable {
        /// Ignored file (raw path bytes from `git status -z`, relative to the checkout) → its `lstat` stamp.
        var ignored: [Data: FileStamp]
        /// Path relative to the git directory → the file (see `barrierPaths`, plus this worktree's admin directory).
        var files: [String: RepoFile]
        /// `for-each-ref` of the checkout: ref → object and symbolic target.
        var refs: [String: RefValue]
        /// `ls-files -s -v -z`: entries, modes, ids and the skip-worktree / assume-unchanged bits. The index file itself is
        /// compared by this, not byte for byte: any `git status` (the CLI's own included) may rewrite its stat cache.
        var index: Data
    }

    /// Enough of `lstat` to see that a file changed without reading it (size, modification time, inode, device, mode).
    struct FileStamp: Equatable, Sendable {
        var size: Int64, seconds: Int, nanoseconds: Int, inode: UInt64, device: Int32, mode: UInt16
        static let missing = FileStamp(size: -1, seconds: 0, nanoseconds: 0, inode: 0, device: 0, mode: 0)
    }

    /// One file of the repository: its content and permission bits, or a symlink's target (`special` for anything else).
    struct RepoFile: Equatable, Sendable { var data: Data?; var mode: UInt16; var link: String? }

    struct RefValue: Equatable, Sendable { var oid: String; var symref: String }

    /// Common-directory paths the barrier snapshots (a directory: every file in it). `packed-refs` is covered by the ref
    /// listing (which reads it) and put back ref by ref, never by rewriting the file: another agent's `git gc` may repack
    /// it during the turn, and old bytes would move their branches back.
    static let barrierPaths = ["HEAD", "config", "info", "hooks", "objects/info/alternates", "objects/info/http-alternates"]

    /// Snapshot before a plan turn. Throws (and so no plan turn starts) when any listing fails, times out or is cut.
    public func planBarrier(key: String, in dir: URL) throws -> PlanBarrier {
        try Self.validKey(key)
        let git = try context(for: dir)
        let ignored = try ignoredFiles(git, in: dir)
        let refs = try refList(git, key: key)
        let index = try barrierRun(git, ["ls-files", "-s", "-v", "-z"])
        return PlanBarrier(ignored: ignored, files: repoFiles(key: key), refs: refs, index: index)
    }

    /// Compares the checkout with `before`, puts back what a plan turn changed and says what it was (empty when nothing).
    /// Repository files are restored (content and mode), refs are moved back, new refs and new ignored files are deleted;
    /// changed or removed ignored files are only reported. Throws `PlanBarrierError` (fail closed) when a listing fails,
    /// times out or is cut, after putting back what it could.
    public func enforcePlanBarrier(_ before: PlanBarrier, key: String, in dir: URL) throws -> [String] {
        try Self.validKey(key)
        let git: GitCommand
        do { git = try context(for: dir) } catch { throw PlanBarrierError(found: [], reason: "\(error)") }
        var found: [String] = [], failures: [String] = []
        let fm = FileManager.default

        // The repository's own files. New ones go first, deepest first, so a directory or link put in place of a file goes too.
        let indexKey = "worktrees/\(key)/index"
        let after = repoFiles(key: key)
        for rel in after.keys.filter({ before.files[$0] == nil }).sorted(by: { $0.count > $1.count }) {
            found.append("new \(Self.shown(rel))")
            try? fm.removeItem(at: gitDir.appending(path: rel))
        }
        for (rel, file) in before.files.sorted(by: { $0.key < $1.key }) where rel != indexKey && after[rel] != file {
            found.append(after[rel] == nil ? "removed \(rel)" : "changed \(rel)")
            Self.restore(file, at: gitDir.appending(path: rel))
        }

        // The index, by what it says.
        do {
            if try barrierRun(git, ["ls-files", "-s", "-v", "-z"]) != before.index {
                found.append("changed index")
                if let file = before.files[indexKey] { Self.restore(file, at: gitDir.appending(path: indexKey)) }
            }
        } catch {
            failures.append("index: \(error)")
            if let file = before.files[indexKey] { Self.restore(file, at: gitDir.appending(path: indexKey)) }
        }

        // Every ref (loose or packed) but other items' branches.
        do {
            let now = try refList(git, key: key)
            for (ref, value) in before.refs.sorted(by: { $0.key < $1.key }) where now[ref] != value {
                found.append(now[ref] == nil ? "removed ref \(ref)" : "moved ref \(ref)")
                if value.symref.isEmpty { try git.run(["update-ref", "--no-deref", ref, value.oid]) }
                else { try git.run(["symbolic-ref", ref, value.symref]) }
            }
            for ref in now.keys.sorted() where before.refs[ref] == nil {
                found.append("new ref \(Self.shown(ref))")
                try git.run(["update-ref", "--no-deref", "-d", ref])
            }
        } catch { failures.append("refs: \(error)") }

        // Ignored files: new ones are deleted (inside the checkout only), changed or removed ones reported.
        do {
            let now = try ignoredFiles(git, in: dir)
            let base = Self.realPath(Array(dir.path.utf8))
            for rel in now.keys.filter({ before.ignored[$0] == nil }).sorted(by: { $0.lexicographicallyPrecedes($1) }) {
                found.append("new ignored file \(Self.shown(rel))")
                Self.removeInside(dir: dir, base: base, relative: rel)
            }
            for (rel, stamp) in before.ignored.sorted(by: { $0.key.lexicographicallyPrecedes($1.key) }) {
                if now[rel] == nil { found.append("removed ignored file \(Self.shown(rel))") }
                else if now[rel] != stamp { found.append("changed ignored file \(Self.shown(rel))") }
            }
        } catch { failures.append("ignored files: \(error)") }

        if !failures.isEmpty { throw PlanBarrierError(found: found, reason: failures.joined(separator: "; ")) }
        return found
    }

    /// One barrier listing: a failure, a timeout or output past `planBarrierOutputLimit` throws.
    private func barrierRun(_ git: GitCommand, _ args: [String]) throws -> Data {
        let out = try git.run(args, maxOutput: planBarrierOutputLimit)
        if out.timedOut { throw GitError.failed(command: args[0], status: -1, stderr: "timed out") }
        if out.cut { throw GitError.failed(command: args[0], status: -1, stderr: "output longer than \(planBarrierOutputLimit) bytes") }
        return out.stdout
    }

    /// `git status --porcelain=v1 -z --ignored -uall`: one `!!` entry per ignored file, raw bytes, nothing quoted.
    private func ignoredFiles(_ git: GitCommand, in dir: URL) throws -> [Data: FileStamp] {
        let tokens = try barrierRun(git, ["status", "--porcelain=v1", "-z", "--ignored", "-uall"]).split(separator: 0, omittingEmptySubsequences: true)
        var ignored: [Data: FileStamp] = [:]
        let root = Array(dir.path.utf8)
        var i = 0
        while i < tokens.count {
            let entry = Data(tokens[i]); i += 1
            guard entry.count > 3 else { continue }
            let xy = entry.prefix(2)
            // A rename or copy carries its old path as the next token.
            if xy.contains(UInt8(ascii: "R")) || xy.contains(UInt8(ascii: "C")) { i += 1 }
            guard xy == Data("!!".utf8) else { continue }
            let rel = Data(entry.dropFirst(3))
            ignored[rel] = Self.stamp(root + [UInt8(ascii: "/")] + Array(rel))
        }
        return ignored
    }

    /// Every ref but the branches of other items, which their leaseholders and the engine move while this turn runs (a
    /// plan turn that moved one is not caught; it cannot touch this checkout or `main`).
    private func refList(_ git: GitCommand, key: String) throws -> [String: RefValue] {
        let own = branchRef(key: key)
        let data = try barrierRun(git, ["for-each-ref", "--format=%(refname)%00%(objectname)%00%(symref)"])
        var refs: [String: RefValue] = [:]
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, parts[0].hasPrefix("refs/") else {
                throw GitError.failed(command: "for-each-ref", status: -1, stderr: "unexpected line")
            }
            try Self.validRef(parts[0])
            if parts[2].isEmpty { try Self.validCommit(parts[1]) } else { try Self.validRef(parts[2]) }
            if parts[0].hasPrefix("refs/heads/item/"), parts[0] != own { continue }
            refs[parts[0]] = RefValue(oid: parts[1], symref: parts[2])
        }
        return refs
    }

    private func repoFiles(key: String) -> [String: RepoFile] {
        var files: [String: RepoFile] = [:]
        for rel in Self.barrierPaths + ["worktrees/\(key)"] { Self.capture(gitDir, rel, into: &files) }
        return files
    }

    private static func capture(_ base: URL, _ rel: String, into files: inout [String: RepoFile]) {
        let url = base.appending(path: rel)
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return }
        let mode = UInt16(st.st_mode & 0o7777)
        switch st.st_mode & S_IFMT {
        case S_IFREG: files[rel] = RepoFile(data: FileManager.default.contents(atPath: url.path) ?? Data(), mode: mode, link: nil)
        case S_IFDIR:
            for name in ((try? FileManager.default.contentsOfDirectory(atPath: url.path)) ?? []).sorted() {
                capture(base, rel + "/" + name, into: &files)
            }
        case S_IFLNK: files[rel] = RepoFile(data: nil, mode: mode, link: (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? "")
        default: files[rel] = RepoFile(data: nil, mode: mode, link: "special")
        }
    }

    /// Puts one repository file back as it was, permission bits included (an executable hook stays executable).
    private static func restore(_ file: RepoFile, at url: URL) {
        let fm = FileManager.default
        var st = stat()
        if lstat(url.path, &st) == 0, st.st_mode & S_IFMT != S_IFREG || file.data == nil { try? fm.removeItem(at: url) }
        try? fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let link = file.link {
            if link != "special" { try? fm.createSymbolicLink(atPath: url.path, withDestinationPath: link) }
            return
        }
        try? (file.data ?? Data()).write(to: url, options: .atomic)
        _ = chmod(url.path, mode_t(file.mode))
    }

    private static func stamp(_ path: [UInt8]) -> FileStamp {
        var st = stat()
        let ok = (path + [0]).withUnsafeBytes { raw in lstat(raw.baseAddress!.assumingMemoryBound(to: CChar.self), &st) } == 0
        guard ok else { return .missing }
        return FileStamp(size: Int64(st.st_size), seconds: st.st_mtimespec.tv_sec, nanoseconds: st.st_mtimespec.tv_nsec,
                         inode: UInt64(st.st_ino), device: st.st_dev, mode: st.st_mode)
    }

    /// Deletes `relative` under `dir` unless it would leave the checkout (absolute, `..`, or a parent that resolves outside).
    /// `realpath(3)` (Foundation's resolver drops `/private` and would never match it).
    private static func realPath(_ path: [UInt8]) -> String? {
        var buffer = [CChar](repeating: 0, count: Int(PATH_MAX) + 1)
        let real = (path + [0]).withUnsafeBytes { raw in realpath(raw.baseAddress!.assumingMemoryBound(to: CChar.self), &buffer) }
        return real == nil ? nil : String(cString: buffer)
    }

    private static func removeInside(dir: URL, base: String?, relative: Data) {
        let parts = relative.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: true)
        guard relative.first != UInt8(ascii: "/"), !parts.isEmpty, !parts.contains(where: { Data($0) == Data("..".utf8) }) else { return }
        let path = Array(dir.path.utf8) + [UInt8(ascii: "/")] + Array(relative)
        let parent = Array(dir.path.utf8) + parts.dropLast().flatMap { [UInt8(ascii: "/")] + Array($0) }
        guard let base, let resolvedParent = realPath(parent),
              resolvedParent == base || resolvedParent.hasPrefix(base + "/") else { return }
        if let text = String(bytes: path, encoding: .utf8) {
            try? FileManager.default.removeItem(atPath: text)
        } else {
            _ = (path + [0]).withUnsafeBytes { raw in unlink(raw.baseAddress!.assumingMemoryBound(to: CChar.self)) }
        }
    }

    /// A path for a message: as is when it is plain, else quoted with escapes (no newline or quote reaches a message raw).
    static func shown(_ path: Data) -> String { shown(String(decoding: path, as: UTF8.self)) }
    static func shown(_ path: String) -> String {
        path.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f || $0 == "\"" || $0 == "\\" } ? path.debugDescription : path
    }

    public func isDirty(in dir: URL) throws -> Bool {
        !(try context(for: dir).run(["status", "--porcelain"]).text.isEmpty)
    }

    /// The commit `ref` points at, or nil when there is no such ref.
    public func head(of ref: String) throws -> String? {
        try Self.validRef(ref)
        let out = try main.run(["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"], allowFailure: true)
        return out.status == 0 && !out.text.isEmpty ? out.text : nil
    }

    public func mergeBase(_ a: String, _ b: String) throws -> String? {
        try Self.validRef(a); try Self.validRef(b)
        let out = try main.run(["merge-base", a, b], allowFailure: true)
        return out.status == 0 && !out.text.isEmpty ? out.text : nil
    }

    /// True when `ancestor` is `descendant` or one of its ancestors. A missing commit is not an ancestor.
    public func isAncestor(_ ancestor: String, of descendant: String) throws -> Bool {
        try Self.validRef(ancestor); try Self.validRef(descendant)
        return try main.run(["merge-base", "--is-ancestor", ancestor, descendant], allowFailure: true).status == 0
    }

    /// Changed paths between two commits, at most `limit`.
    public func nameStatus(base: String, head: String, limit: Int = 2000) throws -> (entries: [GitChange], truncated: Bool) {
        try Self.validRef(base); try Self.validRef(head)
        let out = try main.run(["diff", "--name-status", "-z", "--no-ext-diff", "--no-textconv", "--no-color", base, head])
        let tokens = String(decoding: out.stdout, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
        var entries: [GitChange] = []
        var i = 0
        var truncated = out.cut
        while i < tokens.count {
            let status = tokens[i]
            let paths = status.hasPrefix("R") || status.hasPrefix("C") ? 2 : 1
            guard i + paths < tokens.count else { break }
            let path = tokens[i + paths]
            if entries.count >= limit { truncated = true; break }
            entries.append(GitChange(status: status, path: path, oldPath: paths == 2 ? tokens[i + 1] : nil))
            i += paths + 1
        }
        return (entries, truncated)
    }

    /// The contents of the regular files (not links) at `paths` in `commit`'s tree, at most `limit` of them, read from the
    /// object database. Paths that are not files in that commit are absent from the result. Nothing is read from a working tree.
    public func blobs(at commit: String, paths: [String], limit: Int) throws -> [String: Data] {
        try Self.validCommit(commit)
        let wanted = paths.filter { !$0.isEmpty && !$0.hasPrefix(":") && !$0.hasPrefix("-") }
        guard !wanted.isEmpty, limit > 0 else { return [:] }
        let listing = try main.run(["ls-tree", "-z", "--full-tree", commit, "--"] + wanted, allowFailure: true, maxOutput: 1 << 20)
        guard listing.status == 0 else { return [:] }
        var hashes: [String: String] = [:]
        for entry in String(decoding: listing.stdout, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: true) {
            let halves = entry.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard halves.count == 2 else { continue }
            let meta = halves[0].split(separator: " ")
            let path = String(halves[1])
            guard meta.count == 3, meta[1] == "blob", meta[0] == "100644" || meta[0] == "100755", wanted.contains(path),
                  meta[2].range(of: "^[0-9a-f]{40,64}$", options: .regularExpression) != nil else { continue }
            hashes[path] = String(meta[2])
        }
        var out: [String: Data] = [:]
        for path in wanted where out.count < limit {
            guard let hash = hashes[path] else { continue }
            let blob = try main.run(["cat-file", "blob", hash])
            if blob.cut { throw GitError.failed(command: "cat-file blob", status: -1, stderr: "\(path) is too large to snapshot") }
            out[path] = blob.stdout
        }
        return out
    }

    /// The patch between two commits, cut to `maxLines` lines and `maxChars` characters.
    public func diff(base: String, head: String, maxLines: Int = 400, maxChars: Int = 40_000) throws -> (text: String, truncated: Bool) {
        try Self.validRef(base); try Self.validRef(head)
        let out = try main.run(["diff", "--no-ext-diff", "--no-textconv", "--no-color", base, head],
                               maxOutput: max(maxChars * 4, 1 << 16))
        let full = String(decoding: out.stdout, as: UTF8.self)
        var lines = full.split(separator: "\n", omittingEmptySubsequences: false)
        if lines.last == "" { lines.removeLast() }
        var truncated = out.cut
        var kept = lines
        if kept.count > maxLines { kept = Array(kept.prefix(maxLines)); truncated = true }
        var text = kept.joined(separator: "\n")
        if text.count > maxChars { text = String(text.prefix(maxChars)); truncated = true }
        return (text, truncated)
    }

    /// `"<short sha> <subject>"` for the newest `limit` commits in `base..head`.
    public func log(base: String, head: String, limit: Int = 5) throws -> [String] {
        try Self.validRef(base); try Self.validRef(head)
        let out = try main.run(["log", "--no-color", "--format=%h %s", "-n", String(max(limit, 1)), "\(base)..\(head)"])
        return out.text.split(separator: "\n").map(String.init)
    }
}
