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

/// A failure of a company's merge machinery (main's lock, moving `main`, the engine's merge checkout, a quarantine of the
/// root checkout), not of the item being merged: it never counts against that item (`Store.noteMergeFailure`).
struct MergeInfrastructureError: Error, CustomStringConvertible, LocalizedError {
    let underlying: any Error
    var description: String { "\(underlying)" }
    var errorDescription: String? { description }

    /// Runs `body`, reporting whatever it throws as the company's fault.
    static func wrapping<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let e as MergeInfrastructureError { throw e } catch { throw MergeInfrastructureError(underlying: error) }
    }
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
    /// Extra variables for this context only (a private `GIT_INDEX_FILE`).
    var extraEnvironment: [String: String] = [:]

    func with(_ env: [String: String]) -> GitCommand {
        var copy = self
        copy.extraEnvironment.merge(env) { $1 }
        return copy
    }

    static let timeout: TimeInterval = 60
    static let lockRetries = 3
    static let lockRetryDelay: TimeInterval = 0.2
    static let maxCapture = 8 * 1024 * 1024

    /// Applied to every call, before the subcommand.
    static let configFlags = [
        "-c", "user.name=Brahma", "-c", "user.email=engine@brahma.local", "-c", "commit.gpgsign=false",
        "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "core.pager=cat", "-c", "diff.external=",
        "-c", "protocol.ext.allow=never", "-c", "core.quotepath=false", "-c", "gc.auto=0",
        // BEGIN merge-path hardening (9b fix 3): no attributes file; `GIT_ATTR_SOURCE` (below) replaces the tree's own.
        "-c", "core.attributesFile=/dev/null",
        // END merge-path hardening
    ]

    // BEGIN merge-path hardening (9b fix 3): shared with the GitCommand hardening task; keep this block self-contained.
    /// The empty tree of a SHA-1 repository (git knows it without the object being stored).
    static let emptyTree = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"

    /// The installed git's version as `(major, minor)`, read once; nil when it cannot be read.
    static let gitVersion: (major: Int, minor: Int)? = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "--version"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard let match = text.range(of: "[0-9]+\\.[0-9]+", options: .regularExpression) else { return nil }
        let parts = text[match].split(separator: ".").compactMap { Int($0) }
        return parts.count == 2 ? (parts[0], parts[1]) : nil
    }()

    /// `GIT_ATTR_SOURCE` needs git 2.42 (earlier versions misread it in some commands). Where it is missing, work that
    /// materializes trees is refused (`requireAttributeSource`), not run with the repository's own attributes.
    static var attributeSourceSupported: Bool {
        guard let v = gitVersion else { return false }
        return v.major > 2 || (v.major == 2 && v.minor >= 42)
    }

    static func requireAttributeSource() throws {
        guard attributeSourceSupported else {
            let found = gitVersion.map { "\($0.major).\($0.minor)" } ?? "unknown"
            throw GitError.failed(command: "--version", status: -1, stderr: "git \(found) is older than 2.42; Brahma will not merge with it")
        }
    }
    // END merge-path hardening

    struct Output {
        var status: Int32
        var stdout: Data
        var stderr: String
        /// The output was longer than the capture limit.
        var cut: Bool
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
        // BEGIN merge-path hardening (9b fix 3): refs/replace and grafts never change what the engine sees; attributes come
        // from the empty tree and the repository's `info/attributes` only (never from files in a working tree).
        env["GIT_NO_REPLACE_OBJECTS"] = "1"
        env["GIT_GRAFT_FILE"] = "/dev/null"
        if Self.attributeSourceSupported { env["GIT_ATTR_SOURCE"] = Self.emptyTree }
        // END merge-path hardening
        // A rebase or merge never waits for an editor.
        env["GIT_EDITOR"] = "true"
        env["GIT_SEQUENCE_EDITOR"] = "true"
        for (k, v) in extraEnvironment { env[k] = v }
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
        return Output(status: process.terminationStatus, stdout: stdout, stderr: stderr, cut: cut)
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
    /// Where the engine's own merge checkout lives (`<mergeDirectory>/.merge`). Must not be a place agents can write (a
    /// leaseholder is given `<ws>/.brahma`); the store uses `<home>/run/merge/<companyId>`.
    public let mergeDirectory: URL
    /// How long to wait for an item's lock before giving up on it (the caller skips the item this pass).
    public var lockTimeout: TimeInterval = 10

    /// The moments of a rebase in the merge checkout (`rebaseProbe`).
    enum RebasePhase: Sendable { case before, after }
    /// Tests only: called right before `git rebase` runs in the merge checkout and right after it returns.
    var rebaseProbe: (@Sendable (RebasePhase) -> Void)?

    public init(root: URL, lockDirectory: URL? = nil, mergeDirectory: URL? = nil) {
        self.root = root
        let hash = StableHash.fnv1a64(root.path)
        self.lockDirectory = lockDirectory ?? FileManager.default.temporaryDirectory
            .appending(path: "brahma-locks/\(hash)", directoryHint: .isDirectory)
        self.mergeDirectory = mergeDirectory ?? FileManager.default.temporaryDirectory
            .appending(path: "brahma-merge/\(hash)", directoryHint: .isDirectory)
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
    private func withKeyLock<T>(_ key: String, infrastructure: Bool = false, _ body: () throws -> T) throws -> T {
        try withLockFile(name: key, what: key, infrastructure: infrastructure, body)
    }

    /// Exclusion for everything that moves `refs/heads/main` or resets the root checkout (merges, quarantines, owner
    /// accepts), across processes. Taken after an item's lock when both are needed. (A key never starts with "+".)
    private func withMainLock<T>(infrastructure: Bool = false, _ body: () throws -> T) throws -> T {
        try withLockFile(name: "+main", what: "main", infrastructure: infrastructure, body)
    }

    /// `infrastructure`: a lock that cannot be taken is reported as a `MergeInfrastructureError` (what `body` throws is not).
    private func withLockFile<T>(name: String, what: String, infrastructure: Bool = false, _ body: () throws -> T) throws -> T {
        func failure(_ stderr: String) -> any Error {
            let error = GitError.failed(command: "lock \(what)", status: -1, stderr: stderr)
            return infrastructure ? MergeInfrastructureError(underlying: error) : error
        }
        let dir = lockDirectory
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { throw failure("\(error)") }
        let fd = open(dir.appending(path: "\(name).lock").path, O_CREAT | O_RDWR | O_NOFOLLOW, 0o600)
        guard fd >= 0 else { throw failure("cannot open the lock file") }
        defer { close(fd) }
        let deadline = Date().addingTimeInterval(lockTimeout)
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if errno != EWOULDBLOCK && errno != EINTR { throw failure("cannot take the lock") }
            guard Date() < deadline else { throw failure("\(what) is busy; try again later") }
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

    // MARK: Merging into main

    /// What landing one verified commit came to (`landVerified`).
    enum LandOutcome: Equatable, Sendable {
        /// `refs/heads/item/<KEY>` is not the verified commit (it is `head`): nothing was merged.
        case branchMoved(head: String?)
        /// `main` is not the head the engine expects: nothing was merged.
        case mainMoved(head: String?)
        /// The verified commit is already part of `main` (the engine stopped between merging and recording it).
        case alreadyLanded(mainHead: String)
        /// `main` was fast-forwarded to the verified commit.
        case fastForwarded(mainHead: String)
        /// `main` had moved on: the verified commit was rebased onto it in the engine's merge checkout and the branch moved
        /// to the result, which must pass its check before it lands.
        case rebased(head: String)
        /// The rebase conflicted on these paths and was aborted.
        case conflict(files: [String], mergeBase: String, mainHead: String)
    }

    /// Where the engine's own repository for merge work lives (see `engineRepository`): `<mergeDirectory>.git`, i.e.
    /// `<home>/run/merge/<companyId>.git`. Nothing in it is ever read from the workspace and no agent is given a path to it.
    var mergeRepositoryPath: URL { URL(fileURLWithPath: mergeDirectory.path + ".git", isDirectory: true) }
    /// The engine repository's private working tree, `<home>/run/merge/<companyId>-wt`.
    var mergeWorktreePath: URL { URL(fileURLWithPath: mergeDirectory.path + "-wt", isDirectory: true) }
    /// Where older engines kept the merge checkout, inside the agent-writable `<ws>/.brahma`.
    private var legacyMergeWorktreePath: URL { worktreesDir.appending(path: ".merge", directoryHint: .isDirectory) }

    /// The full ref the root checkout's `HEAD` points at (`refs/heads/main` when all is well); nil for a detached `HEAD`.
    public func checkedOutRef() throws -> String? {
        let out = try main.run(["symbolic-ref", "--quiet", "HEAD"], allowFailure: true)
        return out.status == 0 && !out.text.isEmpty ? out.text : nil
    }

    /// `-c` settings for the engine's rebase: nothing from the repository's config adds steps or moves other refs.
    private static let rebaseConfig = [
        "-c", "rebase.updateRefs=false", "-c", "rebase.autoStash=false", "-c", "rebase.autoSquash=false",
        "-c", "rebase.backend=merge", "-c", "rebase.forkPoint=false", "-c", "rebase.rescheduleFailedExec=false",
        "-c", "rebase.missingCommitsCheck=ignore", "-c", "rerere.enabled=false", "-c", "rerere.autoUpdate=false",
    ]

    /// Lands exactly `verified`, never whatever the branch or the author's worktree holds, inside one critical section (the
    /// item's lock, then main's). Every commit it names is the SHA read under those locks, never a live ref:
    /// 1. `refs/heads/item/<KEY>` must still be `verified` and `refs/heads/main` must be `expectedMain` (`mainHead`);
    /// 2. all merge work happens in the engine's own repository (`engineRepository`): only `verified` and `mainHead` are
    ///    fetched into it from the workspace, by SHA (no refs, no tags, nothing from `refs/replace`), and nothing in the
    ///    workspace's config, attributes, hooks or admin directories is consulted;
    /// 3. a `verified` already in `main` is `alreadyLanded`;
    /// 4. a `verified` that descends from `mainHead` is fast-forwarded: `recordPending(verified)` runs first, then a
    ///    compare-and-swap `update-ref` of the workspace's `refs/heads/main`, then the root checkout follows;
    /// 5. otherwise `git rebase --onto <mainHead> <merge base> <verified>` runs in the engine repository, after the engine
    ///    itself has cleared any rebase state there (it never runs `rebase --abort`). The result `R` is accepted only when
    ///    `main` is still `mainHead`, `mainHead` is an ancestor of `R`, `R` has as many commits on `mainHead` as `verified` has
    ///    (merges aside) on the merge base, and `R`'s tree is the tree of `git merge-tree --write-tree --merge-base=<base>
    ///    <mainHead> <verified>`. Then `R` is fetched back into the workspace and its branch moved (compare-and-swap) to `R`.
    ///    `main` does not move.
    ///
    /// Failures are the company's (`MergeInfrastructureError`) only when they are the engine's own steps: the locks, reading
    /// and moving the workspace's refs, creating and updating the engine repository, handing a result back to the workspace.
    /// A commit git cannot fetch, check out, rebase or merge, a branch with no history in common with `main` and a result that
    /// fails its checks fail as `GitError`: they count against the item.
    func landVerified(key: String, verified: String, expectedMain: String, recordPending: (String) throws -> Void) throws -> LandOutcome {
        try Self.validKey(key); try Self.validCommit(verified); try Self.validCommit(expectedMain)
        return try withKeyLock(key, infrastructure: true) {
            try withMainLock(infrastructure: true) {
                let branchHead = try MergeInfrastructureError.wrapping { try head(of: branchRef(key: key)) }
                guard branchHead == verified else { return .branchMoved(head: branchHead) }
                let mainHead = try MergeInfrastructureError.wrapping { try head(of: Self.mainRef) }
                guard let mainHead, mainHead == expectedMain else { return .mainMoved(head: mainHead) }
                let git = try MergeInfrastructureError.wrapping { () throws -> GitCommand in
                    let git = try engineRepository()
                    retireWorkspaceMergeCheckouts()
                    try Self.clearMergeState(admin: mergeRepositoryPath, detachAt: mainHead)
                    return git
                }
                try fetchIntoEngine(git, commits: [verified, mainHead])
                if try Self.isAncestor(git, verified, of: mainHead) { return .alreadyLanded(mainHead: mainHead) }
                guard let base = try Self.mergeBase(git, mainHead, verified) else {
                    throw GitError.failed(command: "merge-base", status: -1, stderr: "item/\(key) shares no history with main")
                }
                if base == mainHead {
                    try MergeInfrastructureError.wrapping { try moveMainLocked(from: mainHead, to: verified, recordPending: recordPending) }
                    return .fastForwarded(mainHead: verified)
                }
                try git.run(["checkout", "--quiet", "--force", "--detach", verified])
                try git.run(["clean", "-ffdx", "--quiet"])
                rebaseProbe?(.before)
                let out = try git.run(Self.rebaseConfig + [
                    "rebase", "--quiet", "--no-update-refs", "--no-autostash", "--no-autosquash", "--reapply-cherry-picks",
                    "--empty=keep", "--no-fork-point", "--onto", mainHead, base, verified,
                ], allowFailure: true)
                rebaseProbe?(.after)
                guard out.status == 0 else {
                    let listing = try git.run(["diff", "--name-only", "-z", "--diff-filter=U"], allowFailure: true)
                    let files = String(decoding: listing.stdout, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
                    try MergeInfrastructureError.wrapping { try Self.clearMergeState(admin: mergeRepositoryPath, detachAt: mainHead) }
                    _ = try? git.run(["checkout", "--quiet", "--force", "--detach", mainHead], allowFailure: true)
                    let nowMain = try MergeInfrastructureError.wrapping { try head(of: Self.mainRef) }
                    guard nowMain == mainHead else { return .mainMoved(head: nowMain) }
                    if files.isEmpty {
                        // Not a conflict: git could not rebase at all.
                        throw GitError.failed(command: "rebase --onto \(mainHead.prefix(7))", status: out.status, stderr: String(out.stderr.prefix(2000)))
                    }
                    return .conflict(files: files, mergeBase: base, mainHead: mainHead)
                }
                // HEAD is read once and from then on only that SHA is used; the checks below decide whether it is the merge.
                let rebased = try git.run(["rev-parse", "--verify", "HEAD^{commit}"]).text
                try Self.validCommit(rebased)
                try MergeInfrastructureError.wrapping { try Self.clearMergeState(admin: mergeRepositoryPath, detachAt: rebased) }
                let nowMain = try MergeInfrastructureError.wrapping { try head(of: Self.mainRef) }
                guard nowMain == mainHead else { return .mainMoved(head: nowMain) }
                try checkRebase(git, rebased, of: verified, base: base, onto: mainHead, key: key)
                // The result object goes back into the workspace (by SHA, from the engine's own repository); the branch then
                // carries what will be checked and landed. An author who moved it meanwhile wins nothing.
                let moved = try MergeInfrastructureError.wrapping { () throws -> GitCommand.Output in
                    try fetchFromEngine(commit: rebased)
                    return try main.run(["update-ref", branchRef(key: key), rebased, verified], allowFailure: true)
                }
                guard moved.status == 0 else { return .branchMoved(head: try MergeInfrastructureError.wrapping { try head(of: branchRef(key: key)) }) }
                syncItemCheckout(key: key, to: rebased)
                return .rebased(head: rebased)
            }
        }
    }

    /// Throws unless `rebased` is exactly `verified` replayed on `onto`: `onto` is its ancestor, it adds as many commits as
    /// `verified` has (merges aside) since `base`, and its tree is what git merges `base..verified` into `onto` to. Everything
    /// is asked of the engine repository.
    private func checkRebase(_ git: GitCommand, _ rebased: String, of verified: String, base: String, onto: String, key: String) throws {
        func refuse(_ why: String) -> GitError {
            GitError.failed(command: "rebase item/\(key)", status: -1, stderr: "the rebased commit \(rebased.prefix(7)) \(why); nothing was moved")
        }
        guard try Self.isAncestor(git, onto, of: rebased) else { throw refuse("is not on main") }
        let added = try git.run(["rev-list", "--count", "\(onto)..\(rebased)"]).text
        let carried = try git.run(["rev-list", "--count", "--no-merges", "\(base)..\(verified)"]).text
        guard let a = Int(added), let c = Int(carried), a == c else { throw refuse("adds \(added) commits where the verified work has \(carried)") }
        let merged = try git.run(["merge-tree", "--write-tree", "--merge-base=\(base)", onto, verified], allowFailure: true)
        let tree = String(merged.text.split(separator: "\n").first ?? "")
        guard merged.status == 0, tree.range(of: "^[0-9a-f]{40,64}$", options: .regularExpression) != nil else {
            throw refuse("could not be compared with the merge of the verified work (merge-tree \(merged.status))")
        }
        let actual = try git.run(["rev-parse", "--verify", "\(rebased)^{tree}"]).text
        guard actual == tree else { throw refuse("does not hold the merge of the verified work") }
    }

    /// `merge-base --is-ancestor` in `git`: only "yes" and "no" are answers; any other outcome throws.
    private static func isAncestor(_ git: GitCommand, _ ancestor: String, of descendant: String) throws -> Bool {
        let out = try git.run(["merge-base", "--is-ancestor", ancestor, descendant], allowFailure: true)
        guard out.status == 0 || out.status == 1 else {
            throw GitError.failed(command: "merge-base --is-ancestor", status: out.status, stderr: String(out.stderr.prefix(2000)))
        }
        return out.status == 0
    }

    /// `merge-base` in `git`: nil when the two have no history in common; any other failure throws.
    private static func mergeBase(_ git: GitCommand, _ a: String, _ b: String) throws -> String? {
        let out = try git.run(["merge-base", a, b], allowFailure: true)
        if out.status == 0, !out.text.isEmpty { return out.text }
        guard out.status == 1 else { throw GitError.failed(command: "merge-base", status: out.status, stderr: String(out.stderr.prefix(2000))) }
        return nil
    }

    /// Fast-forwards `refs/heads/main` from `old` to `new` (the caller holds main's lock): the expected next head is recorded
    /// first, then a compare-and-swap `update-ref`, then a check that `main` is `new`. The root checkout, when it is on
    /// `main`, follows with a two-tree `read-tree` (which never overwrites local edits).
    private func moveMainLocked(from old: String, to new: String, recordPending: (String) throws -> Void) throws {
        guard try isAncestor(old, of: new) else {
            throw GitError.failed(command: "update-ref \(Self.mainRef)", status: -1, stderr: "not a fast-forward of main")
        }
        try recordPending(new)
        try main.run(["update-ref", Self.mainRef, new, old])
        guard try head(of: Self.mainRef) == new else {
            throw GitError.failed(command: "update-ref \(Self.mainRef)", status: -1, stderr: "main is not at \(new.prefix(7)) after the update")
        }
        if try checkedOutRef() == Self.mainRef {
            _ = try main.run(["read-tree", "-m", "-u", old, new], allowFailure: true)
        }
    }

    /// The author's checkout follows a branch the engine moved (when it is still on that branch); never throws.
    private func syncItemCheckout(key: String, to commit: String) {
        guard hasCheckout(key: key), let git = try? context(for: worktreePath(key: key)),
              let out = try? git.run(["symbolic-ref", "--quiet", "HEAD"], allowFailure: true),
              out.status == 0, out.text == branchRef(key: key) else { return }
        _ = try? git.run(["reset", "--hard", "--quiet", commit], allowFailure: true)
        _ = try? git.run(["clean", "-fd", "--quiet"], allowFailure: true)
    }

    /// Removes every in-progress operation's state from the merge checkout's admin directory (the engine's own rebase, or one
    /// an agent planted) without asking git to undo it, and points its `HEAD` straight at `commit` (detached).
    private static func clearMergeState(admin: URL, detachAt commit: String) throws {
        let fm = FileManager.default
        for name in ["rebase-merge", "rebase-apply", "sequencer", "MERGE_HEAD", "MERGE_MSG", "MERGE_MODE", "MERGE_RR",
                     "CHERRY_PICK_HEAD", "REVERT_HEAD", "REBASE_HEAD", "AUTO_MERGE", "ORIG_HEAD", "BISECT_LOG", "BISECT_START",
                     "index.lock", "MERGE_AUTOSTASH"] {
            let url = admin.appending(path: name)
            if (try? fm.attributesOfItem(atPath: url.path)) != nil { try fm.removeItem(at: url) }
        }
        let head = admin.appending(path: "HEAD")
        if isSymlink(head) { try fm.removeItem(at: head) }
        try (commit + "\n").write(to: head, atomically: true, encoding: .utf8)
    }

    // MARK: The engine's merge repository

    /// The engine's own repository for merge work: a git dir at `<home>/run/merge/<companyId>.git` with a private working tree
    /// at `<home>/run/merge/<companyId>-wt`, outside the workspace and every directory an agent is given. Its config is
    /// written here, in full, every time it is used (no includes, no hooks, no fsmonitor, no `merge.*`, `filter.*` or `diff.*`
    /// drivers) and its `info/attributes` says `* merge=text -filter -diff -text`; every command also runs with
    /// `GIT_CONFIG_NOSYSTEM`, `GIT_CONFIG_GLOBAL=/dev/null`, `core.attributesFile=/dev/null` and `GIT_ATTR_SOURCE` set to the
    /// empty tree (`GitCommand`), so no attribute or config of the workspace can reach a merge. Objects come in only through
    /// `fetchIntoEngine`. Refuses to run on a git older than 2.42.
    private func engineRepository() throws -> GitCommand {
        try GitCommand.requireAttributeSource()
        return try withLockFile(name: "+engine", what: "the merge repository") {
            let fm = FileManager.default
            let repo = mergeRepositoryPath, tree = mergeWorktreePath
            try fm.createDirectory(at: mergeDirectory.deletingLastPathComponent(), withIntermediateDirectories: true,
                                   attributes: [.posixPermissions: 0o700])
            for url in [repo, tree] where Self.isSymlink(url) { try fm.removeItem(at: url) }
            try fm.createDirectory(at: tree, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let git = GitCommand(gitDir: repo, workTree: tree, commonDir: nil)
            if !fm.fileExists(atPath: repo.appending(path: "objects").path) || !fm.fileExists(atPath: repo.appending(path: "HEAD").path) {
                if fm.fileExists(atPath: repo.path) { try fm.removeItem(at: repo) }
                try git.run(["init", "--quiet", "--template="])
            }
            try Self.engineConfig.write(to: repo.appending(path: "config"), atomically: true, encoding: .utf8)
            let info = repo.appending(path: "info", directoryHint: .isDirectory)
            if Self.isSymlink(info) { try fm.removeItem(at: info) }
            try fm.createDirectory(at: info, withIntermediateDirectories: true)
            try Self.engineAttributes.write(to: info.appending(path: "attributes"), atomically: true, encoding: .utf8)
            // Nothing but the engine's own files may steer git here.
            for name in ["config.worktree", "commondir", "shallow", "info/grafts", "objects/info/alternates", "objects/info/http-alternates"] {
                let url = repo.appending(path: name)
                if (try? fm.attributesOfItem(atPath: url.path)) != nil { try fm.removeItem(at: url) }
            }
            return git
        }
    }

    static let engineAttributes = "* merge=text -filter -diff -text\n"

    static let engineConfig = """
        [core]
        \trepositoryformatversion = 0
        \tfilemode = true
        \tbare = false
        \tlogallrefupdates = false
        \thooksPath = /dev/null
        \tfsmonitor = false
        \tattributesFile = /dev/null
        \tautocrlf = false
        \tsymlinks = true
        [gc]
        \tauto = 0
        [rerere]
        \tenabled = false

        """

    /// Fetches exactly `commits` from the workspace repository into the engine repository, by SHA: no refs, no tags, no
    /// `FETCH_HEAD`, so `refs/replace/*` and every other agent-made ref stay behind. A commit git cannot hand over (a missing
    /// or corrupt object) fails as a `GitError`: it is the item's.
    private func fetchIntoEngine(_ engine: GitCommand, commits: [String]) throws {
        try engine.run(Self.fetchFlags + [gitDir.path] + commits)
    }

    /// The engine's own step of handing the result of a rebase to the workspace: its objects, by SHA, from the engine repository.
    private func fetchFromEngine(commit: String) throws {
        try main.run(Self.fetchFlags + [mergeRepositoryPath.path, commit])
    }

    private static let fetchFlags = [
        "-c", "protocol.version=2", "-c", "uploadpack.allowAnySHA1InWant=true", "-c", "fetch.fsckObjects=false",
        "fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--no-recurse-submodules", "--no-auto-gc",
    ]

    /// Retires every merge checkout older engines registered in the workspace (`<ws>/.brahma/wt/.merge`, and the one that
    /// lived at `<mergeDirectory>/.merge` with its admin directory `<ws>/.git/worktrees/-merge`). Links are removed, never
    /// followed; never throws.
    private func retireWorkspaceMergeCheckouts() {
        retireLegacyMergeCheckout()
        let fm = FileManager.default
        let previous = mergeDirectory.appending(path: ".merge", directoryHint: .isDirectory)
        if (try? fm.attributesOfItem(atPath: previous.path)) != nil { try? fm.removeItem(at: previous) }
        let worktrees = gitDir.appending(path: "worktrees", directoryHint: .isDirectory)
        guard !Self.isSymlink(worktrees) else { return }
        for name in ["-merge", ".merge"] {
            let admin = worktrees.appending(path: name)
            if (try? fm.attributesOfItem(atPath: admin.path)) != nil { try? fm.removeItem(at: admin) }
        }
    }

    /// Removes `<ws>/.brahma/wt/.merge` (registered or not); never throws.
    private func retireLegacyMergeCheckout() {
        let fm = FileManager.default
        let legacy = legacyMergeWorktreePath
        guard Self.isSymlink(legacy) || fm.fileExists(atPath: legacy.path) else { return }
        if !Self.isSymlink(legacy), !Self.isSymlink(worktreesDir) {
            _ = try? main.run(["worktree", "remove", "--force", "--force", legacy.path], allowFailure: true)
        }
        if Self.isSymlink(legacy) || fm.fileExists(atPath: legacy.path) { try? fm.removeItem(at: legacy) }
    }

    // MARK: Quarantine of the root checkout

    static let quarantinePrefix = "refs/brahma/quarantine/"

    /// What the engine found uncommitted in the root checkout and moved aside.
    struct Quarantine: Equatable, Sendable {
        var ref: String
        var commit: String
        /// `<status>\t<path>` per changed path, against `main`.
        var nameStatus: [String]
        var stat: String
    }

    static func isQuarantineRef(_ ref: String) -> Bool {
        ref.range(of: "^refs/brahma/quarantine/[0-9]{8}-[0-9]{6}(-[0-9]{1,3})?$", options: .regularExpression) != nil
    }

    /// Moves everything uncommitted in the root checkout onto `refs/brahma/quarantine/<stamp>` (a commit on top of `main`
    /// built in a private index, so `main` and its checkout's index are untouched), then restores the checkout to exactly
    /// `expectedMain` (`reset --hard`, `clean -fd`). Nil when nothing differed from `main`. `main` must be `expectedMain`.
    func quarantineRoot(expectedMain: String, stamp: String) throws -> Quarantine? {
        try Self.validCommit(expectedMain)
        return try withMainLock {
            guard try head(of: Self.mainRef) == expectedMain, try checkedOutRef() == Self.mainRef else {
                throw GitError.failed(command: "quarantine", status: -1, stderr: "main is not where the engine expects it")
            }
            let index = FileManager.default.temporaryDirectory.appending(path: "brahma-quarantine-\(UUID().uuidString).index")
            defer { try? FileManager.default.removeItem(at: index) }
            let staged = main.with(["GIT_INDEX_FILE": index.path])
            try staged.run(["read-tree", expectedMain])
            try staged.run(["add", "-A"])
            let tree = try staged.run(["write-tree"]).text
            let mainTree = try main.run(["rev-parse", "--verify", "\(expectedMain)^{tree}"]).text
            var found: Quarantine?
            if tree != mainTree {
                let commit = try main.run(["commit-tree", tree, "-p", expectedMain, "-m", "Uncommitted changes found in the main checkout"]).text
                try Self.validCommit(commit)
                let zero = String(repeating: "0", count: commit.count)
                var ref: String?
                for n in 1...20 {
                    let name = Self.quarantinePrefix + (n == 1 ? stamp : "\(stamp)-\(n)")
                    if try main.run(["update-ref", name, commit, zero], allowFailure: true).status == 0 { ref = name; break }
                }
                guard let ref else { throw GitError.failed(command: "update-ref quarantine", status: -1, stderr: "no free quarantine name") }
                let listing = try main.run(["diff", "--name-status", "-z", "--no-renames", expectedMain, commit])
                let tokens = String(decoding: listing.stdout, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
                var lines: [String] = []
                var i = 0
                while i + 1 < tokens.count { lines.append("\(tokens[i])\t\(tokens[i + 1])"); i += 2 }
                let stat = try main.run(["diff", "--stat", "--no-color", expectedMain, commit], maxOutput: 1 << 16).text
                found = Quarantine(ref: ref, commit: commit, nameStatus: lines, stat: stat)
            }
            try main.run(["reset", "--hard", "--quiet", expectedMain])
            try main.run(["clean", "-fd", "--quiet"])
            return found
        }
    }

    /// What an owner's accept of a quarantine came to (`mergeQuarantine`).
    enum QuarantineOutcome: Equatable, Sendable {
        /// `main`'s head now (unchanged when the recorded commit was already in `main`).
        case merged(mainHead: String)
        /// The ref no longer points at the commit the engine recorded (it is `head`): nothing was merged.
        case refMoved(head: String?)
    }

    /// The owner accepts a quarantine: `main` takes exactly `commit`, the quarantine commit the engine recorded when it made
    /// `ref` (a fast-forward when `main` has not moved since, else a merge commit built with `merge-tree`, refused on a
    /// conflict). Under main's lock `ref` must still be `commit` (`refMoved` otherwise), `main` must be `expectedMain`, and
    /// its checkout clean and on `main`. Only `commit` is ever merged, never what the ref holds.
    func mergeQuarantine(ref: String, commit: String, expectedMain: String, recordPending: (String) throws -> Void) throws -> QuarantineOutcome {
        guard Self.isQuarantineRef(ref) else { throw GitError.failed(command: "accept", status: -1, stderr: "not a quarantine ref") }
        try Self.validCommit(expectedMain)
        guard commit.range(of: "^[0-9a-f]{40}([0-9a-f]{24})?$", options: .regularExpression) != nil else {
            throw GitError.failed(command: "accept", status: -1, stderr: "the recorded quarantine commit is not a full SHA")
        }
        return try withMainLock {
            let current = try head(of: ref)
            guard current == commit else { return .refMoved(head: current) }
            guard let mainHead = try head(of: Self.mainRef), mainHead == expectedMain else {
                throw GitError.failed(command: "accept", status: -1, stderr: "main is not where the engine expects it")
            }
            if try isAncestor(commit, of: mainHead) { return .merged(mainHead: mainHead) }
            let checkedOut = try checkedOutRef()
            guard checkedOut == Self.mainRef else {
                throw GitError.failed(command: "accept", status: -1, stderr: "the main checkout is on \(checkedOut ?? "a detached HEAD"); switch it back to main")
            }
            guard try !isDirty(in: root) else {
                throw GitError.failed(command: "accept", status: -1, stderr: "the main checkout has uncommitted changes")
            }
            var next = commit
            if try !isAncestor(mainHead, of: commit) {
                let out = try main.run(["merge-tree", "--write-tree", "--name-only", mainHead, commit], allowFailure: true)
                guard out.status == 0 else {
                    throw GitError.failed(command: "accept", status: out.status, stderr: out.status == 1
                        ? "the quarantined changes conflict with main" : String(out.stderr.prefix(500)))
                }
                let tree = String(out.text.split(separator: "\n").first ?? "")
                next = try main.run(["commit-tree", tree, "-p", mainHead, "-p", commit, "-m", "Owner accepted \(ref) (\(commit))"]).text
                try Self.validCommit(next)
            }
            try moveMainLocked(from: mainHead, to: next, recordPending: recordPending)
            return .merged(mainHead: next)
        }
    }

    /// A dry-run merge of the item's branch into `main` (`git merge-tree --write-tree`, git 2.38 or newer): the conflicting
    /// paths, empty when it merges cleanly. Any other outcome (a git too old for it, a missing branch, a timeout, an unrelated
    /// history) throws: it is "unknown", never "clean".
    func mergeConflicts(key: String) throws -> [String] {
        try Self.validKey(key)
        let out = try main.run(["merge-tree", "--write-tree", "--name-only", "-z", Self.mainRef, branchRef(key: key)],
                               allowFailure: true, maxOutput: 1 << 20)
        // `<tree>\0<path>\0<path>\0\0<messages>`: the paths end at the first empty field. Git also exits 1 for refs it cannot
        // merge (with no tree written), so only output that starts with a tree id counts.
        var fields = String(decoding: out.stdout, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
        let tree = fields.first?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let wroteTree = tree.range(of: "^[0-9a-f]{40,64}$", options: .regularExpression) != nil
        if out.status == 0, wroteTree { return [] }
        guard out.status == 1, wroteTree, !out.cut else {
            throw GitError.failed(command: "merge-tree \(key)", status: out.status, stderr: String(out.stderr.prefix(2000)))
        }
        var files: [String] = []
        fields.removeFirst()
        for field in fields {
            if field.isEmpty { break }
            if !files.contains(field) { files.append(field) }
        }
        return files
    }

    /// How many commits `main` has that the item's branch does not.
    public func commitsBehind(key: String) throws -> Int {
        try Self.validKey(key)
        let out = try main.run(["rev-list", "--count", "\(branchRef(key: key))..\(Self.mainRef)"], allowFailure: true)
        return out.status == 0 ? Int(out.text) ?? 0 : 0
    }

    /// Lines of git output split at every `\n` (a `\r\n` pair is one `Character`, so `split(separator: "\n")` would not split
    /// it); the `\r` is left for the quoting to drop.
    static func lines(_ data: Data) -> [String] {
        var lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\n")
        if lines.last == "" { lines.removeLast() }
        return lines
    }

    /// The patch of one path (taken literally, never as a pattern) between two commits, at most `maxLines` lines (the rest is
    /// cut and said so).
    func fileDiff(base: String, head: String, path: String, maxLines: Int = 200) throws -> (text: String, truncated: Bool) {
        try Self.validRef(base); try Self.validRef(head)
        guard !path.isEmpty, !path.hasPrefix("-") else { return ("", false) }
        let out = try main.run(["--literal-pathspecs", "diff", "--no-ext-diff", "--no-textconv", "--no-color", base, head, "--", path],
                               allowFailure: true, maxOutput: 1 << 20)
        let lines = Self.lines(out.stdout)
        let cut = lines.count > maxLines || out.cut
        return (lines.prefix(maxLines).joined(separator: "\n"), cut)
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
    /// left at that place by a crashed run is removed first. `fromEngineRepository`: the checkout is made by the engine's own
    /// repository (the merge-purpose re-check of a rebased commit: no config or attributes of the workspace take part), the
    /// commit being fetched into it by SHA first when it is not there.
    public func addRunWorktree(runId: String, commit: String, fromEngineRepository: Bool = false) throws -> URL {
        try Self.validRunId(runId); try Self.validCommit(commit)
        let paths = CheckPaths(workspace: root)
        if Self.isSymlink(paths.runWorktreesRoot) {
            throw GitError.failed(command: "worktree add \(runId)", status: -1, stderr: "\(paths.runWorktreesRoot.path) is a link")
        }
        try FileManager.default.createDirectory(at: paths.runWorktreesRoot, withIntermediateDirectories: true)
        removeRunWorktree(runId: runId)
        let path = paths.runWorktree(runId: runId)
        guard fromEngineRepository else {
            try main.run(["worktree", "add", "--quiet", "--detach", path.path, commit])
            return path
        }
        let engine = try engineRepository()
        if try engine.run(["cat-file", "-e", "\(commit)^{commit}"], allowFailure: true).status != 0 {
            try fetchIntoEngine(engine, commits: [commit])
        }
        try engine.run(["worktree", "prune"])
        try engine.run(["worktree", "add", "--quiet", "--detach", path.path, commit])
        return path
    }

    /// The engine repository's git context when it exists (nothing is created or rewritten); nil otherwise.
    private var existingEngineRepository: GitCommand? {
        let fm = FileManager.default
        guard !Self.isSymlink(mergeRepositoryPath), !Self.isSymlink(mergeWorktreePath),
              fm.fileExists(atPath: mergeRepositoryPath.appending(path: "HEAD").path), fm.fileExists(atPath: mergeWorktreePath.path)
        else { return nil }
        return GitCommand(gitDir: mergeRepositoryPath, workTree: mergeWorktreePath, commonDir: nil)
    }

    /// Removes one run's checkout (whatever the check left in it), whichever repository made it; never throws.
    public func removeRunWorktree(runId: String) {
        guard (try? Self.validRunId(runId)) != nil else { return }
        let fm = FileManager.default
        let path = CheckPaths(workspace: root).runWorktree(runId: runId)
        if Self.isSymlink(path) {
            try? fm.removeItem(at: path)
        } else if fm.fileExists(atPath: path.path) {
            _ = try? existingEngineRepository?.run(["worktree", "remove", "--force", path.path], allowFailure: true)
            if fm.fileExists(atPath: path.path) { _ = try? main.run(["worktree", "remove", "--force", path.path], allowFailure: true) }
            if fm.fileExists(atPath: path.path) { try? fm.removeItem(at: path) }
        }
        _ = try? main.run(["worktree", "prune"], allowFailure: true)
        _ = try? existingEngineRepository?.run(["worktree", "prune"], allowFailure: true)
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
        _ = try? existingEngineRepository?.run(["worktree", "prune"], allowFailure: true)
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
        let lines = Self.lines(out.stdout)
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
