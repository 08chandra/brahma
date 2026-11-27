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

    /// The engine refused to run git because the repository's config names a program (`GitCommand`); nothing ran.
    var isRepositoryRefusal: Bool {
        if case .failed(_, -1, let stderr) = self { return stderr.hasPrefix(GitCommand.refusalPrefix) }
        return false
    }

    /// Whether an error's text (one already turned into a string, as `WorktreeUnavailable.reason`) is such a refusal.
    static func isRepositoryRefusal(text: String) -> Bool { text.contains(GitCommand.refusalPrefix) }
}

/// A failure of a company's merge machinery (main's lock, moving `main`, the engine's merge checkout, a quarantine of the
/// root checkout), not of the item being merged: it never counts against that item (the queue requeues it uncounted).
struct MergeInfrastructureError: Error, CustomStringConvertible, LocalizedError {
    let underlying: any Error
    var description: String { "\(underlying)" }
    var errorDescription: String? { description }

    /// Runs `body`, reporting whatever it throws as the company's fault.
    static func wrapping<T>(_ body: () throws -> T) throws -> T {
        do { return try body() } catch let e as MergeInfrastructureError { throw e } catch let e as StoppedByOwner { throw e }
        catch { throw MergeInfrastructureError(underlying: error) }
    }
}

/// The commit a merge check runs on cannot be written out faithfully for its export, because of its own tree: `git archive`
/// refuses it, tar refuses a path in it (an over-long name, say), or two of its paths collide on the data home's volume
/// (names that differ only in case on a case-insensitive volume). The item's fault, never the company's (A1).
struct UnexportableTree: Error, CustomStringConvertible, LocalizedError {
    let reason: String
    var description: String { reason }
    var errorDescription: String? { reason }
}

/// `main`'s history could not be fetched from the workspace repository for an export; the caller may restore it
/// (`restoreMainHistory`, under main's lock) and try once more. Otherwise it is the company's fault.
private struct MainHistoryMissing: Error {
    let mainHead: String
    let underlying: MergeInfrastructureError
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
///
/// Programs a repository can name for git to run (filters, textconv, diff and merge drivers, gpg, credential helpers,
/// askpass, ssh, proxies, submodule recursion) are kept out in two layers. The guarantee is the command line: every call
/// forces each such setting off (`configFlags`, `environment()`) for the git it runs and the git processes that one spawns
/// in the same repository (a local fetch's `git-upload-pack` in the other repository does not get them: git drops
/// `GIT_CONFIG_PARAMETERS` for it, so the engine scans that repository right before such a fetch, `fetchIntoEngine`), and
/// reads attributes from the empty tree
/// (`--attr-source`, git 2.43+), never from a checkout's `.gitattributes`, with `core.attributesFile=/dev/null` and the
/// engine's override (`attributesOverride`) as `info/attributes`. On top of that, before every attempt (retries included)
/// the repository's own config files are read (`RepoConfigGuard`): a key outside a short allowlist of what git and the
/// engine write refuses the call, nothing runs, and `onRefused` hears what was found (the store files one owner alert).
/// Replace refs and grafts are ignored, so the objects the engine reviews, checks and merges are the ones their ids name.
struct GitCommand: Sendable {
    let gitDir: URL
    let workTree: URL
    /// Set for a linked worktree: the workspace's own `.git`.
    let commonDir: URL?
    /// A private index (`GIT_INDEX_FILE`) for building a commit without touching the worktree's own index.
    var indexFile: URL? = nil
    /// Told what was wrong each time the repository is refused (its config names a program git would run).
    var onRefused: (@Sendable (_ detail: String) -> Void)? = nil
    /// Test seam: the flags and environment alone, without reading the repository's config first.
    var skipsRepositoryCheck = false
    /// Whether this git takes `--attr-source`. Test seam; always the installed git's answer in the engine.
    var attrSourceSupported = GitCommand.installedSupportsAttrSource
    /// `-c protocol.file.allow=always`, for the engine's own fetches from a local repository; every other protocol stays off.
    var allowsLocalFetch = false
    /// `-c protocol.https.allow=always`, for the engine's own fetch of a repository the owner imports from an https URL
    /// (`GitWorkspace.importRepository`, Plan L Task 14) and nothing else; every other protocol stays off, and curl follows a
    /// redirect only to a protocol git allows, so never off https.
    var allowsHTTPSFetch = false
    /// How long one attempt may run before it is killed (`timeout` for every engine call; an import's fetch and checkout get
    /// `RepoImport.cloneTimeout`).
    var timeoutSeconds: TimeInterval = GitCommand.timeout
    /// While git runs, the bytes under `directory` (links not followed) are summed every `sizeWatchInterval`; past `limit` git
    /// is killed and the result says so (`Output.oversize`). An import's fetch: a server cannot fill the disk before the
    /// size cap refuses the repository.
    var sizeWatch: (directory: URL, limit: Int64)? = nil
    static let sizeWatchInterval: TimeInterval = 0.25
    /// While `sizeWatch` runs, git's captured stderr may grow to this many bytes (stdout to `maxOutput` plus this) before git
    /// is killed (`Output.flooded`): a network peer's `remote:` lines must not fill the data home (Task 14 fix round 1, I2).
    static let maxWatchedStderr: Int64 = 1 << 20
    /// `HOME` and `XDG_CONFIG_HOME` for this git (an empty engine directory): nothing from the owner's home, such as
    /// `~/.netrc` credentials curl would send, reaches the import's network fetch (Task 14 fix round 1, M1).
    var homeDirectory: URL? = nil
    /// Test seam: the environment `ChildEnvironment` filters (nil: this process's).
    var baseEnvironment: [String: String]? = nil
    /// Called between a failed attempt (git met an `index.lock`) and its retry, before the retry is scanned again. Tests change
    /// the repository there instead of racing a timer.
    var beforeRetry: (@Sendable (_ attempt: Int) -> Void)? = nil

    /// What the repository's `info/attributes` must hold (`RepoConfigGuard.ensureAttributes`): the shared override, or for
    /// the engine's merge repository its own stronger line (`GitWorkspace.engineAttributes`), never something weaker.
    var attributes = GitCommand.attributesOverride

    /// Where git's captured stdout/stderr files go (`brahma-git-*`). The engine points this at a 0700 directory under its own
    /// data home (A-I1b), so a sandboxed check can never read another company's in-flight git output in the shared per-user
    /// temp dir; the default (`NSTemporaryDirectory`) is for tests and standalone callers.
    var tempRoot: URL = FileManager.default.temporaryDirectory

    func withIndex(_ url: URL) -> GitCommand { var copy = self; copy.indexFile = url; return copy }

    /// The one `core.hooksPath` value the config allowlist admits: `<workspace>/.brahma/hooks`, set by `GitWorkspace` only for a
    /// company workspace (never a lab under `.brahma/labs`, the merge repository or a standalone repo). Nil admits none.
    var engineHooksPath: String? = nil

    /// Tests only: handed the `tempRoot` of every git run, to prove the engine's captured output never lands in the shared
    /// per-user temp dir (A-I1b). Injected per `GitWorkspace` instance (not a global), so it is set only where a test wants it.
    var tempRootObserver: (@Sendable (URL) -> Void)?

    /// Set for a merge's git (Task 7c fix round 1, S15): each git is spawned as the leader of its own process group and
    /// recorded there until it is reaped, so the owner's stop can signal it even when the engine is wedged.
    var childGroups: ChildGroups?

    /// Variables added to the child's environment after `ChildEnvironment`'s allowlist and before the pinned ones (`GIT_DIR`,
    /// the config and prompt switches), which win: a caller may add (`SafeGit`: `GIT_LITERAL_PATHSPECS=1`), never override.
    var extraEnvironment: [String: String] = [:]
    /// `-c key=value` pairs added BEFORE `configFlags`, so a later hardened flag always wins (add, never override; `SafeGit`:
    /// `core.untrackedCache=false`, `core.excludesFile=/dev/null`).
    var extraConfig: [String] = []
    /// When set, git is started inside this open directory (`fchdir` in the child, `ProcessGroupChild.spawn`) and told
    /// `-C .` / `GIT_WORK_TREE=.`: the work tree is the directory the descriptor holds, never `workTree`'s path, which an
    /// agent could retarget between a check and git's own `chdir` (`SafeGit.worktreeDiff`). The caller keeps it open.
    var workTreeDescriptor: Int32? = nil
    /// Tests only: handed the executable and argv of every git this command starts.
    var spawnObserver: (@Sendable (_ executable: String, _ argv: [String]) -> Void)? = nil

    static let timeout: TimeInterval = 60
    static let lockRetries = 3
    static let lockRetryDelay: TimeInterval = 0.2
    static let maxCapture = 8 * 1024 * 1024

    /// `GitHardening.flags`: what git may run is switched off whatever any config says (see there).
    static let configFlags = GitHardening.flags

    /// The engine's `info/attributes` (it outranks every other attributes file): no filter, no diff driver (git decides text
    /// or binary as usual), the built-in text merge, and nothing left out of or substituted in what `git archive` writes.
    /// `-diff` would make every review diff "Binary files differ".
    static let attributesOverride = "* -filter !diff merge=text -export-ignore -export-subst\n"
    static let refusalPrefix = "Brahma runs no git in this repository: "
    static let emptyTreeSHA1 = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    static let emptyTreeSHA256 = "6ef19b41225c5369f1c104d45d8d85efa9b057b53b14b4b9b939dd74decc5321"

    /// `--attr-source` arrived in git 2.42; from 2.43 it also reaches the child git processes a command spawns (a
    /// checkout's) as `GIT_ATTR_SOURCE`, so 2.43 is the floor.
    static func supportsAttrSource(versionLine: String) -> Bool {
        guard versionLine.hasPrefix("git version ") else { return false }
        let numbers = versionLine.dropFirst("git version ".count).split(whereSeparator: { !$0.isNumber }).prefix(2).compactMap { Int($0) }
        guard numbers.count == 2 else { return false }
        return numbers[0] > 2 || numbers[0] == 2 && numbers[1] >= 43
    }

    /// The engine's git (`ToolPaths.git`, B9): resolved once per process from the safe absolute `PATH` directories, by
    /// absolute path, at least 2.43, never `/usr/bin/env git` and never a lookup in the child's working directory. Before the
    /// process installed its tools (with the real forbidden roots) every git refuses (`notInstalled`, Ruling S-c1).
    static func tools() -> Result<ToolPaths, ToolPathsError> {
        ToolPaths.engine()
    }

    /// The absolute git every engine call starts, or the reason there is none (as a `GitError` of `command`).
    static func executable(command: String) throws -> String {
        switch tools() {
        case .success(let tools): return tools.git
        case .failure(let problem): throw GitError.failed(command: command, status: -1, stderr: "\(problem)")
        }
    }

    /// Whether the engine's git takes `--attr-source` (`ToolPaths` resolves only a git of at least 2.43).
    static var installedSupportsAttrSource: Bool {
        if case .success(let tools) = tools() { return supportsAttrSource(versionLine: "git version \(tools.gitVersion)") }
        return false
    }

    /// The engine's git version as `git --version` prints it (`2.52.0`); nil when it cannot be read.
    static var gitVersionText: String? {
        switch tools() {
        case .success(let tools): return tools.gitVersion
        case .failure(.gitTooOld(let version)): return version == "unknown" ? nil : version
        case .failure: return nil
        }
    }

    /// The engine's merge work materializes trees: it is refused, not run with the repository's attributes, on a git
    /// without `--attr-source` (`installedSupportsAttrSource`).
    static func requireAttributeSource() throws {
        guard installedSupportsAttrSource else {
            throw GitError.failed(command: "--version", status: -1,
                                  stderr: "git \(gitVersionText ?? "of unknown version") is older than 2.43; Brahma will not merge with it")
        }
    }

    /// What an older git (no `--attr-source`) may still run: ref and object plumbing that never reads attributes, never
    /// writes a checkout and never compares content. Everything else is refused there.
    static func isTreeFree(_ args: [String]) -> Bool {
        guard let sub = args.first else { return false }
        if sub == "worktree" { return args.dropFirst().first.map { ["list", "prune"].contains($0) } ?? false }
        return ["rev-parse", "symbolic-ref", "update-ref", "for-each-ref", "merge-base", "branch", "init", "cat-file",
                "commit-tree", "ls-tree", "config"].contains(sub)
    }

    struct Output {
        var status: Int32
        var stdout: Data
        var stderr: String
        /// The output was longer than the capture limit.
        var cut: Bool
        /// The 60 s timeout killed git.
        var timedOut = false
        /// `sizeWatch` killed git: the directory outgrew its limit.
        var oversize = false
        /// `sizeWatch` killed git: its captured output outgrew `maxWatchedStderr`.
        var flooded = false
        /// `sizeWatch` killed git: this directory of the watched tree could not be listed, so its size is unknown.
        var unmeasurable: String? = nil
        var text: String { String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func environment() -> [String: String] {
        var env = ChildEnvironment.make(base: baseEnvironment ?? ProcessInfo.processInfo.environment, purpose: .general)
        for (name, value) in extraEnvironment { env[name] = value }
        // Only absolute entries: an empty or relative one names the child's working directory, which may be an agent's.
        env["PATH"] = Self.absoluteEntries(of: env["PATH"])
        env["GIT_DIR"] = gitDir.path
        env["GIT_WORK_TREE"] = workTreeDescriptor == nil ? workTree.path : "."
        // Always pinned: without it git follows a `commondir` file in the git dir (the workspace's own `.git` included) to
        // a config, attributes and refs the engine never checked.
        env["GIT_COMMON_DIR"] = (commonDir ?? gitDir).path
        if let indexFile { env["GIT_INDEX_FILE"] = indexFile.path }
        for (name, value) in GitHardening.environment { env[name] = value }
        if let homeDirectory {
            env["HOME"] = homeDirectory.path
            env["XDG_CONFIG_HOME"] = homeDirectory.path
        }
        // Never inherited (the allowlist keeps them out already); named so that no later change lets one through.
        for name in GitHardening.neverInherited { env[name] = nil }
        return env
    }

    /// git's arguments after argv[0] (the absolute `ToolPaths.git`). `attrSource`: the tree attributes are read from (the
    /// empty tree of the repository's hash), nil on an older git.
    func arguments(_ args: [String], attrSource: String?) -> [String] {
        ["-C", workTreeDescriptor == nil ? workTree.path : "."] + (attrSource.map { ["--attr-source=\($0)"] } ?? []) + extraConfig + Self.configFlags
            + (allowsLocalFetch ? ["-c", "protocol.file.allow=always"] : [])
            + (allowsHTTPSFetch ? ["-c", "protocol.https.allow=always"] : []) + args
    }

    /// One call's full command line (after `git`) and environment, exactly as `run` would start it, with the repository scanned
    /// first as before every run (`prepare`: config allowlist, attributes override). For `SafeGit`'s runner seam: a test fake
    /// records what git would have been given; `LiveGitRunner` hands it to `runPrepared`.
    func commandLine(_ args: [String]) throws -> (args: [String], environment: [String: String]) {
        let attrSource = try prepare(args)
        return (arguments(args, attrSource: attrSource), environment())
    }

    /// Runs the command line `commandLine` built (one attempt, no `index.lock` retry; `SafeGit` never takes the index lock).
    func runPrepared(args: [String], environment: [String: String], maxOutput: Int, stdin: Stdin) throws -> Output {
        try runOnce(args, environment: environment, label: args.joined(separator: " "), maxOutput: maxOutput, stdin: stdin)
    }

    /// Before each attempt: an older git may only run tree-free plumbing; the repository's config must hold only allowed
    /// keys; the engine's attributes override is put back. Returns the attribute source for the call.
    private func prepare(_ args: [String]) throws -> String? {
        if !attrSourceSupported, !Self.isTreeFree(args) {
            // No engine git at all (not installed yet, none found): that is the reason, not its version (S5 fix 3).
            if case .failure(let problem) = Self.tools() {
                throw GitError.failed(command: args.joined(separator: " "), status: -1, stderr: "\(problem)")
            }
            throw GitError.failed(command: args.joined(separator: " "), status: -1,
                                  stderr: "this git is older than 2.43 and cannot be kept from repository attributes; install a newer git")
        }
        if skipsRepositoryCheck { return attrSourceSupported ? Self.emptyTreeSHA1 : nil }
        let common = commonDir ?? gitDir
        var sha256 = false
        var problems: [String] = []
        // The workspace's own `.git` never has a `commondir` (only a linked worktree's admin directory does).
        if commonDir == nil {
            var st = stat()
            let file = gitDir.appending(path: "commondir")
            if lstat(file.path, &st) == 0 { problems.append("\(GitWorkspace.shown(file.path)) exists (a commondir file redirects the repository)") }
        }
        var seen: Set<String> = []
        for file in [common.appending(path: "config"), common.appending(path: "config.worktree"), gitDir.appending(path: "config.worktree")]
        where seen.insert(file.standardizedFileURL.path).inserted {
            let scan = RepoConfigGuard.scan(file, with: self)
            if let refused = scan.refused { problems.append("\(GitWorkspace.shown(file.path)) \(refused)") }
            if file.lastPathComponent == "config", scan.sha256 { sha256 = true }
        }
        if problems.isEmpty, let problem = RepoConfigGuard.ensureAttributes(commonDir: common, content: attributes) { problems.append(problem) }
        if !problems.isEmpty {
            let detail = problems.joined(separator: "; ")
            onRefused?(detail)
            throw GitError.failed(command: args.first ?? "", status: -1,
                                  stderr: "\(Self.refusalPrefix)\(detail)")
        }
        guard attrSourceSupported else { return nil }
        return sha256 ? Self.emptyTreeSHA256 : Self.emptyTreeSHA1
    }

    /// `git config --file <file> --list` with nothing else read: no repository, no includes, no other config.
    fileprivate func listConfig(_ file: URL) throws -> Output {
        var env = ChildEnvironment.make(base: ProcessInfo.processInfo.environment, purpose: .general)
        env["PATH"] = Self.absoluteEntries(of: env["PATH"])
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_CEILING_DIRECTORIES"] = "/"
        return try runOnce(["-C", "/", "config", "--file", file.path, "--no-includes", "--null", "--list"],
                           environment: env, label: "config --list", maxOutput: 1 << 20)
    }

    /// What git reads on its stdin: nothing (`/dev/null`, the default), the bytes given, or a stream `body` writes into a pipe
    /// on its own thread while git runs (the engine feeding file bytes from descriptors it checked, `GitWorkspace.stage`).
    /// A stream runs once: it is not replayed on an `index.lock` retry (the commands that take one never lock the index).
    enum Stdin {
        case none
        case data(Data)
        case stream(@Sendable (StdinPipe) throws -> Void)
    }

    /// The write end of git's stdin for `Stdin.stream`. `write` sends every byte or throws (git went away, the timeout killed
    /// it); a broken pipe is an error here, never a SIGPIPE to the engine (`Spawn.writeAll`, C1).
    final class StdinPipe: @unchecked Sendable {
        private let fd: Int32
        fileprivate init(fd: Int32) { self.fd = fd }
        func write(_ data: Data) throws {
            try data.withUnsafeBytes { try write($0) }
        }
        func write(_ bytes: UnsafeRawBufferPointer) throws {
            let failed = Spawn.writeAll(fd, bytes)
            guard failed == 0 else {
                throw GitError.failed(command: "stdin", status: -1, stderr: "git stopped reading its input (\(String(cString: strerror(failed))))")
            }
        }
        fileprivate func finish() { close(fd) }
    }

    /// Runs git with a 60 s timeout; stdin is `/dev/null` unless `stdin` says otherwise. Stderr containing `index.lock` is
    /// retried 3 times at 200 ms (not for a stream). A non-zero status throws unless `allowFailure`.
    @discardableResult
    func run(_ args: [String], allowFailure: Bool = false, maxOutput: Int = GitCommand.maxCapture, stdin: Stdin = .none) throws -> Output {
        var attempt = 0
        while true {
            // Scanned again before a retry: the config may have changed while git waited for the lock.
            let attrSource = try prepare(args)
            let out = try runOnce(arguments(args, attrSource: attrSource), environment: environment(),
                                  label: args.joined(separator: " "), maxOutput: maxOutput, stdin: stdin)
            if out.status == 0 || allowFailure && !out.stderr.contains("index.lock") { return out }
            var retriable = true
            if case .stream = stdin { retriable = false }
            if retriable, out.stderr.contains("index.lock"), attempt < Self.lockRetries {
                attempt += 1
                beforeRetry?(attempt)
                Thread.sleep(forTimeInterval: Self.lockRetryDelay)
                continue
            }
            if allowFailure { return out }
            throw GitError.failed(command: args.joined(separator: " "), status: out.status,
                                  stderr: String(out.stderr.prefix(2000)))
        }
    }

    /// The error a stdin feeder met, handed back to the thread that waits for git.
    private final class FeedResult: @unchecked Sendable {
        let done = DispatchSemaphore(value: 0)
        var error: (any Error)?
    }

    /// `path` with only its absolute entries (the engine's PATH comes through `ChildEnvironment`; an empty or relative entry
    /// would be looked up in the child's working directory).
    static func absoluteEntries(of path: String?) -> String {
        (path ?? "").split(separator: ":", omittingEmptySubsequences: true).filter { $0.hasPrefix("/") }.joined(separator: ":")
    }

    /// The directory every engine git starts in (B9, spec §6.5): the repository's common dir when the command names one (an
    /// agent worktree's), otherwise `/` — never an agent's worktree, nor a repository's own `.git` (a lab's is agent-writable,
    /// M1); `/` too while the common dir does not exist. git still works on the repository and work tree it is told (`-C`,
    /// `GIT_DIR`, `GIT_WORK_TREE`) and reads nothing from where it starts.
    var engineDirectory: URL {
        let root = URL(fileURLWithPath: "/", isDirectory: true)
        guard let dir = commonDir else { return root }
        var st = stat()
        if stat(dir.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR { return dir }
        return root
    }

    /// `args` are git's arguments after argv[0].
    private func runOnce(_ args: [String], environment: [String: String], label: String, maxOutput: Int, stdin: Stdin = .none) throws -> Output {
        EngineGitGuard.willRunGit("git \(label)")
        // The executable is the engine's `ToolPaths.git`, exec'd directly as argv[0]: never `/usr/bin/env git`, never a
        // lookup on the child's PATH or in its working directory.
        let executable = try Self.executable(command: label)
        let argv = [executable] + args
        spawnObserver?(executable, argv)
        var feed: (pipe: Pipe, result: FeedResult)?
        switch stdin {
        case .none: break
        case .data, .stream: feed = (Pipe(), FeedResult())
        }
        // Output goes to files, not pipes: concurrent children cannot hold each other's pipe ends open, and a grandchild
        // that outlives git cannot keep us waiting for end of file.
        tempRootObserver?(tempRoot)
        try? FileManager.default.createDirectory(at: tempRoot, withIntermediateDirectories: true,
                                                 attributes: [.posixPermissions: 0o700])
        let base = tempRoot.appending(path: "brahma-git-\(UUID().uuidString)")
        let outURL = base.appendingPathExtension("out"), errURL = base.appendingPathExtension("err")
        guard FileManager.default.createFile(atPath: outURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              FileManager.default.createFile(atPath: errURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let outHandle = FileHandle(forWritingAtPath: outURL.path), let errHandle = FileHandle(forWritingAtPath: errURL.path)
        else { throw GitError.failed(command: label, status: -1, stderr: "no temporary space for git output") }
        defer {
            try? outHandle.close(); try? errHandle.close()
            _ = try? EngineFiles.removeNoFollow(outURL, under: tempRoot); _ = try? EngineFiles.removeNoFollow(errURL, under: tempRoot)
        }
        // Every git leads its own process group (as Foundation's `Process` made it too) and starts in `engineDirectory`
        // (`Spawn`); a merge's git is also recorded for the owner's stop until it is reaped (`childGroups`); a git anchored to
        // a work tree descriptor (`workTreeDescriptor`, `SafeGit`) is `fchdir`ed into it before exec.
        let grouped: ProcessGroupChild
        do {
            let input = feed.map { $0.pipe.fileHandleForReading.fileDescriptor } ?? -1
            grouped = try ProcessGroupChild.spawn(
                executable: executable, arguments: argv, environment: environment, workingDirectory: engineDirectory,
                output: outHandle.fileDescriptor, stdin: input, stderr: errHandle.fileDescriptor, workingDirectoryFD: workTreeDescriptor)
        } catch {
            if let feed { try? feed.pipe.fileHandleForReading.close(); try? feed.pipe.fileHandleForWriting.close() }
            throw GitError.failed(command: label, status: -1, stderr: "\(error)")
        }
        if let feed {
            // Only git holds the read end now, so it sees end of file when the feeder closes the write end.
            try? feed.pipe.fileHandleForReading.close()
            let writer = StdinPipe(fd: dup(feed.pipe.fileHandleForWriting.fileDescriptor))
            try? feed.pipe.fileHandleForWriting.close()
            let result = feed.result
            Thread {
                defer { writer.finish(); result.done.signal() }
                do {
                    switch stdin {
                    case .data(let data): try writer.write(data)
                    case .stream(let body): try body(writer)
                    case .none: break
                    }
                } catch { result.error = error }
            }.start()
        }
        let record = childGroups?.record(grouped.pid)
        let timedOut = TimeoutFlag()
        let timer = DispatchWorkItem { timedOut.mark(); grouped.signalGroup(SIGTERM) }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeoutSeconds, execute: timer)
        // The size watch polls on a thread of its own: a busy shared dispatch pool must never let git outgrow the cap.
        let oversize = TimeoutFlag(), flooded = TimeoutFlag(), watchDone = TimeoutFlag()
        let unmeasurable = PathFlag()
        if let sizeWatch {
            let stop = GitStopper(grouped: grouped)
            let outputCap = Int64(maxOutput) + Self.maxWatchedStderr
            @Sendable func bytes(_ url: URL) -> Int64 {
                var st = stat()
                return lstat(url.path, &st) == 0 ? Int64(st.st_size) : 0
            }
            Thread {
                while !watchDone.cut {
                    do {
                        if try EngineFiles.treeBytes(sizeWatch.directory, stopAbove: sizeWatch.limit) > sizeWatch.limit {
                            oversize.mark()
                        } else if bytes(errURL) > Self.maxWatchedStderr || bytes(outURL) > outputCap {
                            flooded.mark()
                        }
                    } catch let unmeasured as EngineFiles.Unmeasurable {
                        unmeasurable.set(unmeasured.path)
                    } catch {
                        unmeasurable.set(sizeWatch.directory.path)
                    }
                    if oversize.cut || flooded.cut || unmeasurable.path != nil {
                        if !watchDone.cut { stop.stop() }
                        return
                    }
                    Thread.sleep(forTimeInterval: Self.sizeWatchInterval)
                }
            }.start()
        }
        // Foundation's convention: the exit code, or the number of the signal that ended it.
        let raw = grouped.finish()
        var groupedStatus: Int32 = raw & 0x7f == 0 ? (raw >> 8) & 0xff : raw & 0x7f
        if grouped.lostTrack { groupedStatus = -1 }
        childGroups?.forget(record, pid: grouped.pid)
        timer.cancel()
        watchDone.mark()
        // Git has exited, so the feeder's next write fails and it finishes; nothing waits on a live pipe.
        feed?.result.done.wait()
        func read(_ url: URL, limit: Int) -> (Data, Bool) {
            guard let h = try? FileHandle(forReadingFrom: url) else { return (Data(), false) }
            defer { try? h.close() }
            let data = (try? h.read(upToCount: limit)) ?? Data()
            let more = ((try? h.read(upToCount: 1)) ?? Data()).isEmpty == false
            return (data, more)
        }
        let (stdout, cut) = read(outURL, limit: maxOutput)
        var stderr = String(decoding: read(errURL, limit: 64 * 1024).0, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        if timedOut.cut { stderr = "timed out after \(Int(timeoutSeconds)) s" + (stderr.isEmpty ? "" : ": \(stderr)") }
        if oversize.cut, let sizeWatch { stderr = "stopped: the repository grew past \(sizeWatch.limit) bytes" + (stderr.isEmpty ? "" : ": \(stderr)") }
        if flooded.cut { stderr = "stopped: git's output passed \(Self.maxWatchedStderr) bytes" + (stderr.isEmpty ? "" : ": \(stderr)") }
        if let dir = unmeasurable.path { stderr = "stopped: \(dir) could not be measured" + (stderr.isEmpty ? "" : ": \(stderr)") }
        var status = groupedStatus
        if let error = feed?.result.error {
            // The input ended early: whatever git made of the part it got does not count as success.
            if status == 0 { status = -1 }
            stderr = "\(error)" + (stderr.isEmpty ? "" : ": \(stderr)")
        }
        if oversize.cut || flooded.cut || unmeasurable.path != nil, status == 0 { status = -1 }
        return Output(status: status, stdout: stdout, stderr: stderr, cut: cut, timedOut: timedOut.cut, oversize: oversize.cut,
                      flooded: flooded.cut, unmeasurable: unmeasurable.path)
    }
}

/// Reads a repository's config files for what the engine refuses to run git with. A scan is kept per file while the file's
/// `lstat` (device, inode, size, modification and change times) stays the same; the stamp is taken before the file is read,
/// so a write during the read changes it and the file is read again next time.
enum RepoConfigGuard {
    struct Scan: Sendable {
        /// What makes the file refused ("sets filter.x.clean, include.path"), or nil.
        var refused: String?
        /// `extensions.objectFormat = sha256`.
        var sha256 = false
    }

    private struct Stamp: Hashable, Sendable {
        var device: Int32, inode: UInt64, size: Int64, mtime: Int, mtimeNS: Int, ctime: Int, ctimeNS: Int
    }

    private final class Cache: @unchecked Sendable {
        private let lock = NSLock()
        private var entries: [String: (Stamp, Scan)] = [:]
        func get(_ path: String, _ stamp: Stamp) -> Scan? {
            lock.lock(); defer { lock.unlock() }
            guard let (s, scan) = entries[path], s == stamp else { return nil }
            return scan
        }
        func set(_ path: String, _ stamp: Stamp, _ scan: Scan) {
            lock.lock(); defer { lock.unlock() }
            if entries.count > 4096 { entries.removeAll() }
            entries[path] = (stamp, scan)
        }
    }
    private static let cache = Cache()

    /// Is this config key one the engine runs git with? Only what git itself and the engine write, and inert settings;
    /// everything else (any program, helper, driver, include, remote or alias) refuses the repository. Keys come canonical
    /// from `git config --list`: section and variable lowercased, a subsection as written (dots and all).
    static func isAllowed(_ key: String, value: String = "", hooksPath: String? = nil) -> Bool {
        let lower = key.lowercased()
        guard let firstDot = lower.firstIndex(of: "."), let lastDot = lower.lastIndex(of: ".") else { return false }
        let section = lower[..<firstDot], variable = lower[lower.index(after: lastDot)...]
        let hasSubsection = firstDot != lastDot
        switch section {
        case "core":
            // `core.hooksPath` only when it names exactly the engine's own hooks directory of this workspace (`CompanyHooks`);
            // engine git overrides it with `/dev/null` anyway, so this admits the agents' advisory hook and nothing else.
            if !hasSubsection, variable == "hookspath", let hooksPath { return value == hooksPath }
            return !hasSubsection && ["repositoryformatversion", "filemode", "bare", "logallrefupdates", "ignorecase",
                                      "precomposeunicode", "symlinks", "worktree"].contains(variable)
        // Only the extensions the engine works with: another ref storage (reftable) or a partial clone breaks its checks.
        case "extensions": return !hasSubsection && (variable == "worktreeconfig" || variable == "objectformat")
        case "pack", "index", "worktree": return !hasSubsection
        case "user": return !hasSubsection && (variable == "name" || variable == "email")
        // Tracking only: a remote would need `remote.*`, which is not allowed.
        case "branch": return hasSubsection && (variable == "remote" || variable == "merge")
        // `gc.recentObjectsHook` runs a command; every other gc setting is inert.
        case "gc": return variable != "recentobjectshook"
        case "init": return !hasSubsection && variable == "defaultbranch"
        default: return false
        }
    }

    static func scan(_ file: URL, with git: GitCommand) -> Scan {
        var st = stat()
        guard lstat(file.path, &st) == 0 else {
            return errno == ENOENT ? Scan() : Scan(refused: "cannot be examined")
        }
        guard st.st_mode & S_IFMT == S_IFREG else { return Scan(refused: "is not a regular file") }
        let stamp = Stamp(device: st.st_dev, inode: UInt64(st.st_ino), size: Int64(st.st_size),
                          mtime: st.st_mtimespec.tv_sec, mtimeNS: st.st_mtimespec.tv_nsec,
                          ctime: st.st_ctimespec.tv_sec, ctimeNS: st.st_ctimespec.tv_nsec)
        if let known = cache.get(file.path, stamp) { return known }
        let result: Scan
        // A git that could not start or was cut off says nothing about the file: refused this time, asked again next time.
        guard let out = try? git.listConfig(file), !out.cut, !out.timedOut else { return Scan(refused: "cannot be read by git") }
        if out.status == 0 {
            var refused: [String] = []
            var sha256 = false
            for entry in out.stdout.split(separator: 0, omittingEmptySubsequences: true) {
                let text = String(decoding: entry, as: UTF8.self)
                let key = String(text.prefix { $0 != "\n" })
                let value = text.contains("\n") ? String(text[text.index(after: text.firstIndex(of: "\n")!)...]) : ""
                if !isAllowed(key, value: value, hooksPath: git.engineHooksPath) { refused.append(GitWorkspace.shown(key)) }
                if key.lowercased() == "extensions.objectformat", value.lowercased() == "sha256" { sha256 = true }
            }
            let unique = refused.reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            let named = unique.prefix(6).joined(separator: ", ") + (unique.count > 6 ? " and \(unique.count - 6) more" : "")
            result = Scan(refused: unique.isEmpty ? nil : "sets \(named)", sha256: sha256)
        } else {
            result = Scan(refused: "cannot be read by git")
        }
        cache.set(file.path, stamp, result)
        return result
    }

    /// Writes `content` (the engine's override) as `info/attributes` when it is not exactly that. Nil when done (or when
    /// there is no repository yet: `git init` has not run); else why not. A common dir that is a link (or not a directory) is
    /// refused: git would read the attributes wherever it points.
    static func ensureAttributes(commonDir: URL, content: String = GitCommand.attributesOverride) -> String? {
        var st = stat()
        guard lstat(commonDir.path, &st) == 0 else { return nil }
        guard st.st_mode & S_IFMT == S_IFDIR else { return "\(GitWorkspace.shown(commonDir.path)) is not a real directory" }
        let info = commonDir.appending(path: "info", directoryHint: .isDirectory)
        if lstat(info.path, &st) == 0 {
            guard st.st_mode & S_IFMT == S_IFDIR else { return "\(GitWorkspace.shown(info.path)) is not a real directory" }
        } else if (try? FileManager.default.createDirectory(at: info, withIntermediateDirectories: false)) == nil {
            return "cannot create \(GitWorkspace.shown(info.path))"
        }
        let file = info.appending(path: "attributes")
        if lstat(file.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size == content.utf8.count,
           FileManager.default.contents(atPath: file.path) == Data(content.utf8) {
            return nil
        }
        if lstat(file.path, &st) == 0, st.st_mode & S_IFMT != S_IFREG {
            // Through descriptors from the common dir's parent: a part swapped for a link meanwhile is never followed.
            guard case .removed? = try? EngineFiles.removeNoFollow(file, under: commonDir.deletingLastPathComponent()) else {
                return "cannot replace \(GitWorkspace.shown(file.path))"
            }
        }
        do { try Data(content.utf8).write(to: file, options: .atomic) } catch {
            return "cannot write \(GitWorkspace.shown(file.path))"
        }
        return nil
    }
}

/// Stops one git run from the size watch's thread (the process objects are only signalled, never otherwise touched there).
private final class GitStopper: @unchecked Sendable {
    let grouped: ProcessGroupChild
    init(grouped: ProcessGroupChild) { self.grouped = grouped }
    func stop() { grouped.signalGroup(SIGTERM) }
}

/// A flag set from a timer thread.
private final class TimeoutFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var over = false
    func mark() { lock.lock(); over = true; lock.unlock() }
    var cut: Bool { lock.lock(); defer { lock.unlock() }; return over }
}

/// The first path set, shared with the size-watch thread.
private final class PathFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?
    func set(_ path: String) { lock.lock(); if value == nil { value = path }; lock.unlock() }
    var path: String? { lock.lock(); defer { lock.unlock() }; return value }
}

/// The git repository of one company workspace. The workspace itself is the repo (branch `main`); each leased item gets a
/// worktree at `<ws>/.brahma/wt/<KEY>` on branch `item/<KEY>`.
public struct GitWorkspace: Sendable {
    public let root: URL
    /// Where the per-item lock files live. Must not be a place agents can write; the default is a per-workspace directory
    /// under the system temporary directory.
    public let lockDirectory: URL
    /// The base of the engine's own merge repository (`<mergeDirectory>.git`, its working tree `<mergeDirectory>-wt`, its
    /// bundles and exports). Must not be a place agents can write (a leaseholder is given `<ws>/.brahma`); the store uses
    /// `<home>/run/merge/<companyId>`.
    public let mergeDirectory: URL
    /// The data home merge-check exports are unpacked under, at `<exportHome>/run/exports/<runId>` (`exportPath`). Must not
    /// be a place agents can write; the store uses its data home.
    public let exportHome: URL
    /// How long to wait for an item's lock before giving up on it (the caller skips the item this pass).
    public var lockTimeout: TimeInterval = 10
    /// Called once for each time an item worktree is found repointed (its `HEAD` off `item/<KEY>`, or `gitdir`, `commondir`
    /// or `.git` not as the engine wrote them), with the key and what was wrong. The worktree has been restored by then and
    /// the operation that found it refused. The store files the engine alert.
    /// Whether the engine's database holds a lease for the item with this key. The plan barrier keeps a new `item/<KEY>`
    /// branch the engine itself created (a lease, or a worktree it made); without this hook there is no lease record.
    public var hasLease: (@Sendable (_ key: String) throws -> Bool)?
    public var onWorktreeTamper: (@Sendable (_ key: String, _ detail: String) -> Void)?
    /// Called each time a git call is refused because the repository's config names a program git would run (a filter,
    /// textconv, diff or merge driver, hooks path, ssh command, fsmonitor) or includes another file; `detail` says which
    /// file and keys. Nothing ran. The store files one owner alert while it stays that way.
    public var onUnsafeRepository: (@Sendable (_ detail: String) -> Void)?
    /// Called each time a link or an odd file is found on the way to `.brahma/wt` or the data home's `run/checkouts` and
    /// `run/exports` (or a checkout or export there moved while git or tar wrote into it). Nothing was created or removed
    /// through it. The store files the engine alert.
    public var onUnsafeEngineFile: (@Sendable (UnsafeEngineFile) -> Void)?
    /// Tests only: called with an engine checkout's place once it is created, right before git or tar is run into it.
    var checkoutProbe: (@Sendable (URL) -> Void)?
    /// Tests only: called with the place after its last check, the moment before git or tar is started on it.
    var spawnProbe: (@Sendable (URL) -> Void)?

    /// The moments of a rebase in the merge checkout (`rebaseProbe`).
    enum RebasePhase: Sendable { case before, after }
    /// Tests only: called right before `git rebase` runs in the merge checkout and right after it returns.
    var rebaseProbe: (@Sendable (RebasePhase) -> Void)?
    /// Tests only: called by the merge queue's `fastForwardMain` right after `main` moved, before the root checkout follows.
    var followProbe: (@Sendable () throws -> Void)?
    /// Tests only: called by the merge queue's self-heal with the path (relative to the workspace's git dir) of each directory
    /// it is about to walk into, and with each planted history file's name (`shallow`, `info/grafts`) right before it is removed.
    var healProbe: (@Sendable (String) -> Void)?
    /// How much `ls-tree` output the export's collision check reads (`refuseCollidingPaths`); a tree with more is refused.
    var collisionListingLimit = 64 << 20
    /// Tests only: handed to every workspace git command as its `beforeRetry` (between a try that met an `index.lock` and
    /// its retry), so a test can clear the lock there instead of racing a timer.
    var gitRetryProbe: (@Sendable (_ attempt: Int) -> Void)?

    /// Where the engine's git commands keep their captured output and private index files (A-I1b): a 0700 directory under the
    /// engine's data home (`<exportHome>/tmp`), never the shared per-user temp dir a sandboxed check could read.
    let gitTemp: URL
    /// Tests only: handed each git command's `tempRoot`, so a test can prove the engine never writes to the shared per-user
    /// temp dir (A-I1b). Injected on the instance; nil in production (no global).
    var gitTempObserver: (@Sendable (URL) -> Void)?
    /// A merge's workspace (Task 7c fix round 1): every git it runs leads its own process group, recorded here for the
    /// owner's stop (`GitCommand.childGroups`).
    var childGroups: ChildGroups?

    public init(root: URL, lockDirectory: URL? = nil, mergeDirectory: URL? = nil, exportHome: URL? = nil) {
        self.root = root
        let hash = StableHash.fnv1a64(root.path)
        let export = exportHome ?? FileManager.default.temporaryDirectory
            .appending(path: "brahma-exports/\(hash)", directoryHint: .isDirectory)
        self.exportHome = export
        self.lockDirectory = lockDirectory ?? FileManager.default.temporaryDirectory
            .appending(path: "brahma-locks/\(hash)", directoryHint: .isDirectory)
        self.mergeDirectory = mergeDirectory ?? FileManager.default.temporaryDirectory
            .appending(path: "brahma-merge/\(hash)", directoryHint: .isDirectory)
        self.gitTemp = export.appending(path: "tmp", directoryHint: .isDirectory)
    }

    /// The installed git's version (`2.52.0`), nil when it cannot be read. The first use runs `git --version` (once per
    /// process), so the engine asks for it only in a blocking body.
    static var installedGitVersion: String? { GitCommand.gitVersionText }
    /// Whether the installed git is one the engine merges with (2.43 or newer, `--attr-source`); asked the same way.
    static var installedGitMerges: Bool { GitCommand.installedSupportsAttrSource }

    // MARK: Layout

    var worktreesDir: URL { root.appending(path: ".brahma/wt", directoryHint: .isDirectory) }
    public func worktreePath(key: String) -> URL { worktreesDir.appending(path: key, directoryHint: .isDirectory) }
    public func branch(key: String) -> String { "item/\(key)" }
    /// Every ref the engine reads is fully qualified, so a tag named `main` or `item/<KEY>` can never stand in for the branch.
    public static let mainRef = "refs/heads/main"
    public func branchRef(key: String) -> String { "refs/heads/item/\(key)" }
    var gitDir: URL { root.appending(path: ".git", directoryHint: .isDirectory) }
    private func adminDir(key: String) -> URL { gitDir.appending(path: "worktrees/\(key)", directoryHint: .isDirectory) }
    /// `<root>/.brahma/hooks` for a company workspace; nil when the root lies inside a `.brahma` directory (a lab).
    private var engineHooksPath: String? {
        root.pathComponents.contains(".brahma") ? nil : root.appending(path: ".brahma/hooks").path
    }

    var main: GitCommand {
        var git = GitCommand(gitDir: gitDir, workTree: root, commonDir: nil, onRefused: onUnsafeRepository)
        git.engineHooksPath = engineHooksPath
        git.beforeRetry = gitRetryProbe
        git.tempRoot = gitTemp
        git.tempRootObserver = gitTempObserver
        git.childGroups = childGroups
        return git
    }

    private static func resolved(_ url: URL) -> String { url.resolvingSymlinksInPath().standardizedFileURL.path }

    static func isSymlink(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeSymbolicLink
    }

    static func validKey(_ key: String) throws {
        guard key.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil else {
            throw GitError.failed(command: "worktree \(key)", status: -1, stderr: "invalid item key")
        }
    }

    static func validRef(_ ref: String) throws {
        guard !ref.isEmpty, !ref.hasPrefix("-"), !ref.contains(where: { $0.isWhitespace || $0.isNewline || $0.asciiValue.map { $0 < 32 } ?? false }) else {
            throw GitError.failed(command: "ref \(ref.prefix(40))", status: -1, stderr: "invalid ref")
        }
    }

    /// The git context for the workspace itself or one of its item worktrees; any other directory is refused.
    private func context(for dir: URL) throws -> GitCommand { try resolve(dir).git }

    /// The context and, for an item worktree, its key (nil for the workspace itself).
    private func resolve(_ dir: URL) throws -> (git: GitCommand, key: String?) {
        let target = Self.resolved(dir)
        if target == Self.resolved(root) { return (main, nil) }
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
        // The repository's own directories must be real directories before anything is read or healed through them: a link
        // there would send the heal (and git) into another repository. Refused and reported; there is nothing to restore.
        for (url, name) in [(gitDir, ".git"), (gitDir.appending(path: "worktrees"), ".git/worktrees"), (adminDir(key: key), ".git/worktrees/\(key)")]
        where !Self.isRealDirectory(url) {
            let detail = "\(name) is not a real directory"
            onWorktreeTamper?(key, detail)
            throw GitError.failed(command: "-C \(key)", status: -1, stderr: "the worktree of \(key) was repointed (\(detail)); nothing was run in it")
        }
        // The invariant behind every engine commit, merge, reset and rebase here: `HEAD` is the symref to this item's own
        // branch and the three links are as the engine made them. Anything else (a turn that pointed `HEAD` at `main`, say,
        // would make a plain commit move `main`) is refused, reported once and put back from the engine's record. The check
        // alone cannot be atomic with the operation, so engine commits and resets never go through `HEAD` at all
        // (`commitAll`, `resetHard`) and look again afterwards (`verifyAfter`).
        let problems = linkProblems(key: key)
        if !problems.isEmpty {
            heal(key: key)
            let detail = problems.joined(separator: "; ")
            onWorktreeTamper?(key, detail)
            throw GitError.failed(command: "-C \(key)", status: -1,
                                  stderr: "the worktree of \(key) was repointed (\(detail)); what the engine records was put back and nothing was run in it")
        }
        var git = GitCommand(gitDir: adminDir(key: key), workTree: worktreePath(key: key), commonDir: gitDir, onRefused: onUnsafeRepository)
        git.engineHooksPath = engineHooksPath
        git.beforeRetry = gitRetryProbe
        git.tempRoot = gitTemp
        git.tempRootObserver = gitTempObserver
        git.childGroups = childGroups
        return (git, key)
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
    }

    /// After an operation that was started on a checked worktree: if its links were rewritten meanwhile, restore them and
    /// report (the operation itself never used `HEAD` and never followed a symbolic item ref, so it landed on the item's
    /// branch). A repository directory that became a link is reported and fails the operation (there is nothing to restore).
    private func verifyAfter(key: String) throws {
        for (url, name) in [(gitDir, ".git"), (gitDir.appending(path: "worktrees"), ".git/worktrees"), (adminDir(key: key), ".git/worktrees/\(key)")]
        where !Self.isRealDirectory(url) {
            let detail = "\(name) is not a real directory"
            onWorktreeTamper?(key, detail)
            throw GitError.failed(command: "-C \(key)", status: -1, stderr: "the worktree of \(key) was repointed during the operation (\(detail))")
        }
        let problems = linkProblems(key: key)
        guard !problems.isEmpty else { return }
        heal(key: key)
        onWorktreeTamper?(key, problems.joined(separator: "; "))
    }

    /// Why `refs/heads/item/<KEY>` is not a plain ref, or nil. A symbolic item ref (`git symbolic-ref refs/heads/item/K
    /// refs/heads/main`) would make every update of the item branch move its target. Packed refs are never symbolic. A ref
    /// file the bounded no-follow reader refuses (another hard link, padded past the bound, unreadable) is reported too, never
    /// taken for a plain ref (S2 fix round 1, I1): a genuine loose ref is at most 41 bytes with one link, this user's.
    private func symbolicItemRef(key: String) -> String? {
        let ref = branchRef(key: key)
        let url = gitDir.appending(path: ref)
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        switch st.st_mode & S_IFMT {
        case S_IFLNK: return "\(ref) is a symbolic ref (a link)"
        case S_IFREG:
            let text: String
            do { text = try SafeRead.smallText(ref, under: try Place.resolved(gitDir, kind: .directory)) } catch { return "\(ref) is not a plain ref file (\(error))" }
            guard text.hasPrefix("ref:") else { return nil }
            let target = String(text.dropFirst(4).trimmingCharacters(in: .whitespacesAndNewlines).prefix(200))
            return "\(ref) is a symbolic ref to \(Self.shown(target))"
        default: return "\(ref) is not a ref file"
        }
    }

    /// Test seam: called with a stage name between the worktree check and the operation that follows it.
    var testHook: (@Sendable (String) -> Void)?

    /// Every path form the engine accepts for one location: as the engine writes it, and as git writes it (`realpath`).
    private static func forms(_ url: URL) -> Set<String> {
        var out: Set<String> = [url.path]
        if let real = realPath(Array(url.path.utf8)) { out.insert(real) }
        return out
    }

    /// The text of the pointer file `name` under `dir` (an admin directory, a worktree, the repository's `.git`), read without
    /// following a link and bounded (`SafeRead.smallText` under `dir` as a verified `Place`, 4 KiB: S2, spec §7.1; S7). Nil when it is a link, not a plain regular
    /// file of this user's, oversized or unreadable: every caller treats nil as "changed" (fail closed).
    private static func regularText(_ name: String, under dir: URL) -> String? {
        do { return try SafeRead.smallText(name, under: try Place.resolved(dir, kind: .directory)) } catch { return nil }
    }

    /// What differs from the engine's record of one item worktree; empty when it is as the engine created it.
    private func linkProblems(key: String) -> [String] {
        let admin = adminDir(key: key), tree = worktreePath(key: key)
        var problems: [String] = []
        if Self.regularText("HEAD", under: admin) != "ref: \(branchRef(key: key))\n" { problems.append("HEAD is not \(branchRef(key: key))") }
        let commondir = Self.regularText("commondir", under: admin)?.trimmingCharacters(in: .newlines)
        if commondir != "../.." { problems.append("commondir was changed") }
        let gitdir = Self.regularText("gitdir", under: admin)?.trimmingCharacters(in: .newlines)
        if gitdir.map({ !Self.forms(tree).map { "\($0)/.git" }.contains($0) }) ?? true { problems.append("gitdir was changed") }
        let link = Self.regularText(".git", under: tree)?.trimmingCharacters(in: .newlines)
        if link.map({ !Self.forms(admin).map { "gitdir: \($0)" }.contains($0) }) ?? true { problems.append(".git was changed") }
        if let symbolic = symbolicItemRef(key: key) { problems.append(symbolic) }
        return problems
    }

    /// Rewrites `HEAD` and the three pointers that tie a worktree to this repository from the engine's own records. Git
    /// resolves refs through `commondir` whatever `GIT_COMMON_DIR` says, so an agent that repointed it would otherwise make
    /// a commit move a branch in another repository.
    private func heal(key: String) {
        let admin = adminDir(key: key)
        func ensure(_ name: String, under dir: URL, _ text: String) {
            guard Self.regularText(name, under: dir) != text else { return }
            let url = dir.appending(path: name)
            var st = stat()
            if lstat(url.path, &st) == 0, st.st_mode & S_IFMT != S_IFREG { _ = try? EngineFiles.removeNoFollow(url, under: root) }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        ensure("HEAD", under: admin, "ref: \(branchRef(key: key))\n")
        ensure("commondir", under: admin, "../..\n")
        ensure("gitdir", under: admin, "\(worktreePath(key: key).path)/.git\n")
        ensure(".git", under: worktreePath(key: key), "gitdir: \(admin.path)\n")
    }

    // MARK: Repository

    /// Makes `<ws>` a git repository on `main` with every existing file imported, and keeps `.brahma/` out of it.
    /// `core.hooksPath` as the workspace's config FILES have it (`config`, then `config.worktree`, which wins), or nil
    /// (`--file`: the engine's own `-c core.hooksPath=/dev/null` would otherwise answer). Nil also when either file is a link.
    public func hooksPath() throws -> String? {
        var git = main
        git.skipsRepositoryCheck = true   // a config read; see `setHooksPath`
        var found: String?
        for name in ["config", "config.worktree"] {
            let file = gitDir.appending(path: name)
            guard SandboxPath.kind(file.path) == .file else { if SandboxPath.kind(file.path) == .link { return nil }; continue }
            let out = try git.run(["config", "--file", file.path, "--get", "core.hooksPath"], allowFailure: true)
            if out.status == 0 { found = out.text.trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        return found
    }

    /// Points `core.hooksPath` at the engine's hooks directory (`CompanyHooks.install`) in `config`, and removes it from
    /// `config.worktree` (which would win). Refused when either file is a symbolic link. The repository check is skipped for
    /// these config writes: a config set to another value would refuse every engine command, this one included, and `git
    /// config` runs no hook, filter, driver or helper (the command-line config still switches them all off).
    public func setHooksPath(_ dir: URL) throws {
        for name in ["config", "config.worktree"] where SandboxPath.kind(gitDir.appending(path: name).path) == .link {
            throw GitError.failed(command: "config core.hooksPath", status: -1, stderr: ".git/\(name) is a symbolic link; refused")
        }
        var git = main
        git.skipsRepositoryCheck = true
        if SandboxPath.kind(gitDir.appending(path: "config.worktree").path) == .file {
            _ = try git.run(["config", "--file", gitDir.appending(path: "config.worktree").path, "--unset-all", "core.hooksPath"], allowFailure: true)
        }
        try git.run(["config", "core.hooksPath", dir.path])
    }

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
        ensureExclude()
        if try head(of: "refs/heads/main") == nil {
            if try head(of: "HEAD") != nil {
                try main.run(["branch", "main", "HEAD"])
            } else {
                // The owner's existing files, through the engine's own staging (never `add -A`; `.brahma/` stays out, M2).
                try stage(main, in: root, relative: "")
                try main.run(["commit", "--quiet", "--allow-empty", "--no-verify", "-m", "Import existing files"])
            }
        }
    }

    /// What `.git/info/exclude` must list: the engine's directory, and the `TMPDIR` a sandboxed check gets inside its
    /// checkout (`SeatbeltRunner`), so neither shows up as untracked work.
    static let excludedEntries = [".brahma/", ".brahma-tmp/"]

    /// The largest `.git/info/exclude` the engine reads; a bigger one is left alone (reported), never truncated or appended to.
    static let excludeReadLimit = 1 << 20

    /// Makes `.git/info/exclude` list `excludedEntries`, through `EngineFiles` anchored at the workspace: `.git` and
    /// `.git/info` are opened one part at a time without following a link (a link or non-directory at either is refused),
    /// and the file itself is read from its own descriptor only when it passes `EngineFiles.copyProblem` (a regular file with
    /// a single link that this user owns). Its bytes are kept exactly (no text decoding); when entries are missing, a fresh
    /// file (those bytes plus the missing lines) is renamed over the name, so a link at the name is replaced, never written
    /// through. A file that fails `copyProblem` (S7: another hard link, perhaps an owner secret an agent linked there; a link;
    /// a FIFO; another user's) is never read: the name gets a fresh file holding only the engine's entries. An oversized
    /// file, or one whose read fails part-way, is left as it is. Every odd shape is reported (`onUnsafeEngineFile`) and
    /// nothing throws, so an agent that can write `.git` cannot block `ensureRepo` or `quarantineRoot` (N5).
    func ensureExclude() {
        let dir = ".git/info", name = "exclude"
        let report = { (problem: UnsafeEngineFile) in onUnsafeEngineFile?(problem) }
        do {
            var current = Data()
            var carried = true
            switch try EngineFiles.entry(workspace: root, dir: dir, name: name) {
            case .missing:
                break
            case .unsafe(let problem):
                // Never read: replaced by a fresh file with the engine's entries alone (a directory there throws below).
                report(problem)
                carried = false
            case .regular:
                do {
                    guard let data = try EngineFiles.read(workspace: root, dir: dir, name: name, limit: Self.excludeReadLimit + 1) else { break }
                    guard data.count <= Self.excludeReadLimit else {
                        report(UnsafeEngineFile(path: gitDir.appending(path: "info/exclude").path,
                                                problem: "is larger than \(Self.excludeReadLimit) bytes; left as it is"))
                        return
                    }
                    current = data
                } catch let problem as UnsafeEngineFile {
                    // Swapped since the look, or a read that failed part-way: left as it is (never rewritten from a part).
                    report(UnsafeEngineFile(path: problem.path, problem: "\(problem.problem); left as it is"))
                    return
                }
            }
            let lines = current.split(separator: 0x0A, omittingEmptySubsequences: true).map { Array($0) }
            let missing = Self.excludedEntries.filter { !lines.contains(Array($0.utf8)) }
            guard !missing.isEmpty || !carried else { return }
            var text = current
            if !text.isEmpty, text.last != 0x0A { text.append(0x0A) }
            text.append(Data(missing.map { $0 + "\n" }.joined().utf8))
            try EngineFiles.replace(text, workspace: root, dir: dir, name: name)
        } catch let problem as UnsafeEngineFile {
            report(problem)
        } catch {
            report(UnsafeEngineFile(path: gitDir.appending(path: "info/exclude").path, problem: "cannot be updated (\(error))"))
        }
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
    func withMainLock<T>(infrastructure: Bool = false, _ body: () throws -> T) throws -> T {
        try withLockFile(name: "+main", what: "main", infrastructure: infrastructure, body)
    }

    /// Exclusion for a repository's worktree records (`.git/worktrees/*`), shared by everything that writes them or reads all
    /// of them: `git worktree add` (it creates `<id>/commondir` empty and fills it in after, and checks every other worktree's
    /// branch through theirs), `worktree prune` (it deletes a record whose `gitdir` is not written yet), `worktree list` and
    /// `branch -D`, and the engine's own removals of checkouts and records. Without it two of them in one repository fail
    /// with "failed to read .git/worktrees/<id>/commondir" or "could not open .../locked". Held inside the caller's
    /// blocking body: in this process by a per-repository gate (`RepositoryGate`, so the engine and the MCP tools, each with
    /// their own `GitWorkspace`, take turns), across processes by `<lockDirectory>/+worktrees.lock` (under the data home).
    /// Re-entrant on its thread. Taken after an item's lock, never before one.
    private func withWorktreeRecords<T>(_ body: () throws -> T) throws -> T {
        try RepositoryGate.gate(for: Self.resolved(gitDir)).run { outermost in
            outermost ? try withLockFile(name: "+worktrees", what: "the worktree records", body) : try body()
        }
    }

    /// `infrastructure`: a lock that cannot be taken is reported as a `MergeInfrastructureError` (what `body` throws is not).
    private func withLockFile<T>(name: String, what: String, infrastructure: Bool = false, _ body: () throws -> T) throws -> T {
        func failure(_ stderr: String) -> any Error {
            let error = GitError.failed(command: "lock \(what)", status: -1, stderr: stderr)
            return infrastructure ? MergeInfrastructureError(underlying: error) : error
        }
        let dir = lockDirectory
        do { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) } catch { throw failure("\(error)") }
        // Close-on-exec: a git or check spawned meanwhile must not carry the lock file (the lock itself is released by
        // `LOCK_UN` below, whoever else still holds a copy of the descriptor).
        let fd = open(dir.appending(path: "\(name).lock").path, O_CREAT | O_RDWR | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw failure("cannot open the lock file") }
        defer { close(fd) }
        // Bounded in awake time (`AwakeTime`): a system sleep while waiting is not a busy lock.
        let deadline = AwakeTime.uptime() + lockTimeout
        while flock(fd, LOCK_EX | LOCK_NB) != 0 {
            if errno != EWOULDBLOCK && errno != EINTR { throw failure("cannot take the lock") }
            guard AwakeTime.uptime() < deadline else { throw failure("\(what) is busy; try again later") }
            Thread.sleep(forTimeInterval: 0.02)
        }
        defer { flock(fd, LOCK_UN) }
        return try body()
    }

    private func addWorktreeLocked(key: String) throws -> URL {
        try withWorktreeRecords { try addWorktreeRecorded(key: key) }
    }

    private func addWorktreeRecorded(key: String) throws -> URL {
        let fm = FileManager.default
        let path = worktreePath(key: key)
        let command = "worktree add \(key)"
        // `.brahma/wt` is walked from the workspace without following a link, so a linked `.brahma` cannot send the checkout
        // elsewhere; the checkout's own place is created through that directory and checked around git (`intoPlace`).
        let wt = try engineDirectory(".brahma/wt", command: command)
        switch wt.kind(of: key) {
        case .missing: break
        case .directory where fm.fileExists(atPath: adminDir(key: key).path): return path
        default:
            throw GitError.failed(command: command, status: -1, stderr: "\(path.path) already exists and is not a checkout of this workspace")
        }
        try main.run(["worktree", "prune"])
        let name = branch(key: key)
        let existing = try head(of: branchRef(key: key)) != nil
        try intoPlace(key, in: wt, registered: true, command: command) { _ in
            if existing {
                try main.run(["worktree", "add", "--quiet", path.path, name])
            } else {
                try main.run(["worktree", "add", "--quiet", "-b", name, path.path, Self.mainRef])
            }
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
    ///
    /// Returns the engine's own auto-commit (its parent, the branch tip it was stacked on, and the new commit) when there was
    /// uncommitted work, so the caller can record it as the item's head (`Store.removeItemWorktree`, 4-wire fix round 4).
    @discardableResult
    public func removeWorktree(key: String, keepIf: () throws -> Bool) throws -> AutoCommit? {
        try Self.validKey(key)
        return try withKeyLock(key) { () -> AutoCommit? in
            if try keepIf() { return nil }
            return try removeWorktreeLocked(key: key)
        }
    }

    /// The engine's own commit of a worktree's leftover work: `commit` has the single parent `parent`.
    public struct AutoCommit: Equatable, Sendable {
        public var parent: String
        public var commit: String
    }

    private func removeWorktreeLocked(key: String) throws -> AutoCommit? {
        var made: AutoCommit?
        let command = "worktree remove \(key)"
        let wt = try engineDirectory(".brahma/wt", command: command)
        switch wt.kind(of: key) {
        case .link:
            try? wt.remove(key)
        case .directory where FileManager.default.fileExists(atPath: adminDir(key: key).path):
            if let c = try commitAllWithParent(in: worktreePath(key: key), message: "\(key): auto-commit before release"),
               let parent = c.parent { made = AutoCommit(parent: parent, commit: c.commit) }
            // The work is committed. The checkout goes through the walked directory's descriptor, never by a path a link on
            // the way could send elsewhere (so not `git worktree remove`); git then forgets it (`prune`).
            try withWorktreeRecords { try removeEngineEntry(key, in: wt, command: command) }
        default:
            break
        }
        _ = try? withWorktreeRecords { _ = try? main.run(["worktree", "prune"]) }
        return made
    }

    // MARK: Engine checkout places under .brahma

    /// `<ws>/<relative>` (`.brahma/wt`; an older engine's `.brahma/wt-check`) as a real directory, walked from the workspace
    /// without following a link and created when missing. A link or odd file on the way is reported (`onUnsafeEngineFile`)
    /// and refused.
    private func engineDirectory(_ relative: String, command: String) throws -> EngineFiles.OpenDirectory {
        do { return try EngineFiles.openWalked(workspace: root, relative) } catch let problem as UnsafeEngineFile {
            onUnsafeEngineFile?(problem)
            throw GitError.failed(command: command, status: -1, stderr: "\(problem)")
        }
    }

    /// Removes `name` from the engine directory through its descriptor (`EngineFiles.removeEntry`); a problem is reported.
    private func removeEngineEntry(_ name: String, in dir: EngineFiles.OpenDirectory, command: String) throws {
        do { try dir.remove(name) } catch let problem as UnsafeEngineFile {
            onUnsafeEngineFile?(problem)
            throw GitError.failed(command: command, status: -1, stderr: "\(problem)")
        }
    }

    /// Creates the new directory `name` in `parent` and runs `body`, which hands it to git (by path) or tar (by descriptor).
    /// Right before and right after `body` both directories must still be where the walk found them (`isInPlace`: the
    /// kernel's path and the (device, inode) at the named path): one that moved (a part of the way swapped for a link) is
    /// reported and refused. A git worktree (`registered`) must also have its `.git` file in this very directory afterwards:
    /// a way swapped for a link while git ran and swapped back would have sent the checkout elsewhere. Whenever `body` fails
    /// or the place moved, the place is removed through `parent`'s descriptor, and for a git worktree git's record of it too.
    /// `placeFault` turns a failure of the place itself (made or moved) into the caller's kind of error (a merge-check export
    /// reports it as the company's fault).
    private func intoPlace(_ name: String, in parent: EngineFiles.OpenDirectory, mode: mode_t = 0o755, registered: Bool,
                           command: String, placeFault: (any Error) -> any Error = { $0 },
                           _ body: (EngineFiles.OpenDirectory) throws -> Void) throws {
        let place: EngineFiles.OpenDirectory
        do { place = try parent.makeDirectory(name, mode: mode) } catch let problem as UnsafeEngineFile {
            onUnsafeEngineFile?(problem)
            throw placeFault(GitError.failed(command: command, status: -1, stderr: "\(problem)"))
        } catch {
            throw placeFault(error)
        }
        func discard() {
            try? parent.remove(name)
            if registered { try? EngineFiles.remove(workspace: root, dir: ".git/worktrees", name: name) }
        }
        func moved() -> any Error {
            discard()
            let problem = UnsafeEngineFile(path: place.shown.path, problem: "moved while \(command) used it; it was refused and removed")
            onUnsafeEngineFile?(problem)
            return placeFault(GitError.failed(command: command, status: -1, stderr: "\(problem)"))
        }
        checkoutProbe?(place.shown)
        guard place.isInPlace, parent.isInPlace else { throw moved() }
        spawnProbe?(place.shown)
        do { try body(place) } catch {
            guard place.isInPlace, parent.isInPlace else { throw moved() }
            discard()
            throw error
        }
        guard place.isInPlace, parent.isInPlace, !registered || place.kind(of: ".git") == .other else { throw moved() }
    }

    /// Registered `item/<KEY>` worktrees under `<ws>/.brahma/wt`. Names starting with "." (engine checkouts such as
    /// `.preview`, `.release`, `.merge`) and worktrees on other branches are never listed.
    public func itemWorktrees() throws -> [(key: String, path: URL)] {
        let listing = try withWorktreeRecords { try main.run(["worktree", "list", "--porcelain"]).text }
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
        // `branch -D` reads every worktree's record (it refuses a branch checked out anywhere).
        try withWorktreeRecords { _ = try main.run(["branch", "-D", branch(key: key)]) }
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

    /// Where the engine's own repository for merge work lives (see `freshEngineRepository`): `<mergeDirectory>.git`, i.e.
    /// `<home>/run/merge/<companyId>.git`. Nothing in it is ever read from the workspace and no agent is given a path to it.
    var mergeRepositoryPath: URL { URL(fileURLWithPath: mergeDirectory.path + ".git", isDirectory: true) }
    /// The engine repository's private working tree, `<home>/run/merge/<companyId>-wt`.
    var mergeWorktreePath: URL { URL(fileURLWithPath: mergeDirectory.path + "-wt", isDirectory: true) }
    /// The engine merge repository's git context: the shared `GitCommand` hardening and config allowlist (its git dir is
    /// pinned as its own common dir), with the engine's stronger attributes line (`engineAttributes`) kept in its
    /// `info/attributes`. A refusal there is the company's fault (the engine wrote that config), not a workspace alert.
    var engineCommand: GitCommand {
        var git = GitCommand(gitDir: mergeRepositoryPath, workTree: mergeWorktreePath, commonDir: nil)
        git.attributes = Self.engineAttributes
        git.tempRoot = gitTemp
        git.tempRootObserver = gitTempObserver
        git.childGroups = childGroups
        return git
    }
    /// Where older engines kept the merge checkout, inside the agent-writable `<ws>/.brahma`.
    private var legacyMergeWorktreePath: URL { worktreesDir.appending(path: ".merge", directoryHint: .isDirectory) }

    /// The full ref the root checkout's `HEAD` points at (`refs/heads/main` when all is well); nil for a detached `HEAD`.
    public func checkedOutRef() throws -> String? {
        let out = try main.run(["symbolic-ref", "--quiet", "HEAD"], allowFailure: true)
        return out.status == 0 && !out.text.isEmpty ? out.text : nil
    }

    /// `-c` settings for the engine's rebase: nothing from the repository's config adds steps or moves other refs.
    static let rebaseConfig = [
        "-c", "rebase.updateRefs=false", "-c", "rebase.autoStash=false", "-c", "rebase.autoSquash=false",
        "-c", "rebase.backend=merge", "-c", "rebase.forkPoint=false", "-c", "rebase.rescheduleFailedExec=false",
        "-c", "rebase.missingCommitsCheck=ignore", "-c", "rerere.enabled=false", "-c", "rerere.autoUpdate=false",
    ]

    /// Lands exactly `verified`, never whatever the branch or the author's worktree holds, inside one critical section (the
    /// item's lock, then main's, then the engine repository's). Every commit it names is the SHA read under those locks, never
    /// a live ref:
    /// 1. git lock files in the workspace repository that nobody has held for `staleLockAge` (agent-writable state that would
    ///    block the merge) are removed and reported through `tamper`;
    /// 2. `refs/heads/item/<KEY>` must still be `verified` and `refs/heads/main` must be `expectedMain` (`mainHead`);
    /// 3. all merge work happens in the engine's own repository, made afresh for this landing (`freshEngineRepository`): only
    ///    `mainHead` and `verified` are fetched into it from the workspace, by SHA, fsck'd, over the local file transport only
    ///    (no refs, no tags, nothing from `refs/replace`), and nothing in the workspace's config, attributes, hooks or admin
    ///    directories is consulted. Its config and attributes are written again right before the checkout for the rebase, and the merge-tree;
    /// 4. a `verified` already in `main` is `alreadyLanded`;
    /// 5. a `verified` that descends from `mainHead` is fast-forwarded: `recordPending(verified)` runs first, then a
    ///    compare-and-swap `update-ref` of the workspace's `refs/heads/main`, then the root checkout follows;
    /// 6. otherwise `git rebase --onto <mainHead> <merge base> <verified>` runs in the engine repository (it never runs
    ///    `rebase --abort`; the engine clears rebase state itself). The result `R` is accepted only when `main` is still
    ///    `mainHead`, `mainHead` is an ancestor of `R`, `R` has as many commits on `mainHead` as `verified` has (merges aside)
    ///    on the merge base, and `R`'s tree is the tree of `git merge-tree --write-tree --merge-base=<base> <mainHead>
    ///    <verified>`. Then `R`'s objects are handed to the workspace as a bundle (`handBack`: no transport) and its branch is
    ///    moved (compare-and-swap) to `R`. `main` does not move.
    ///
    /// Failures are the company's (`MergeInfrastructureError`) when they are the engine's own steps or main's: the locks,
    /// reading and moving the workspace's refs, making and steering the engine repository, a shallow workspace, `main`'s
    /// history that cannot be fetched, handing a result back to the workspace. A verified commit git cannot fetch (fsck
    /// refuses it, an object is missing), check out, rebase or merge, a branch with no history in common with `main` and a
    /// result that fails its checks fail as `GitError`: they count against the item.
    ///
    /// `beforeRefMove` runs with the ref's name right before each ref this landing moves (the item branch's compare-and-swap
    /// after a rebase, `main`'s compare-and-swap): whatever it throws (the owner's stop, `StoppedByOwner`) leaves that ref
    /// where it was and ends the landing.
    func landVerified(key: String, verified: String, expectedMain: String, recordPending: (String) throws -> Void,
                      tamper: ([String]) -> Void = { _ in }, beforeRefMove: (String) throws -> Void = { _ in }) throws -> LandOutcome {
        try Self.validKey(key); try Self.validCommit(verified); try Self.validCommit(expectedMain)
        return try withKeyLock(key, infrastructure: true) {
            try withMainLock(infrastructure: true) {
                let repaired = try MergeInfrastructureError.wrapping { try healWorkspaceRepositoryLocked() }
                if !repaired.isEmpty { tamper(repaired) }
                let branchHead = try MergeInfrastructureError.wrapping { try head(of: branchRef(key: key)) }
                guard branchHead == verified else { return .branchMoved(head: branchHead) }
                let mainHead = try MergeInfrastructureError.wrapping { try head(of: Self.mainRef) }
                guard let mainHead, mainHead == expectedMain else { return .mainMoved(head: mainHead) }
                return try withEngineLock {
                    try landLocked(key: key, verified: verified, mainHead: mainHead, recordPending: recordPending, tamper: tamper,
                                   beforeRefMove: beforeRefMove)
                }
            }
        }
    }

    /// `landVerified` from step 3 on; the caller holds the item's, main's and the engine repository's locks.
    private func landLocked(key: String, verified: String, mainHead: String, recordPending: (String) throws -> Void,
                            tamper: ([String]) -> Void, beforeRefMove: (String) throws -> Void) throws -> LandOutcome {
        let git = try MergeInfrastructureError.wrapping { () throws -> GitCommand in
            let git = try freshEngineRepository()
            retireWorkspaceMergeCheckouts()
            return git
        }
        try fetchLandingInputs(git, mainHead: mainHead, verified: verified, tamper: tamper)
        dropPreviousEngineRepository()
        if try Self.isAncestor(git, verified, of: mainHead) { return .alreadyLanded(mainHead: mainHead) }
        guard let base = try Self.mergeBase(git, mainHead, verified) else {
            throw GitError.failed(command: "merge-base", status: -1, stderr: "item/\(key) shares no history with main")
        }
        if base == mainHead {
            try MergeInfrastructureError.wrapping {
                try moveMainLocked(from: mainHead, to: verified, recordPending: recordPending, beforeRefMove: beforeRefMove)
            }
            return .fastForwarded(mainHead: verified)
        }
        // The engine repository's config and attributes are written again before anything there touches a tree.
        try MergeInfrastructureError.wrapping { try assertEngineState() }
        try git.run(["checkout", "--quiet", "--force", "--no-recurse-submodules", "--detach", verified])
        try git.run(["clean", "-ffdx", "--quiet"])
        rebaseProbe?(.before)
        let out = try git.run(Self.rebaseConfig + [
            "rebase", "--quiet", "--no-update-refs", "--no-autostash", "--no-autosquash", "--reapply-cherry-picks",
            "--empty=keep", "--no-fork-point", "--onto", mainHead, base, verified,
        ], allowFailure: true)
        rebaseProbe?(.after)
        guard out.status == 0 else {
            let listing = try git.run(["diff", "--no-ext-diff", "--no-textconv", "--name-only", "-z", "--diff-filter=U"], allowFailure: true)
            let files = String(decoding: listing.stdout, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: true).map(String.init)
            try MergeInfrastructureError.wrapping { try clearMergeState(admin: mergeRepositoryPath, detachAt: mainHead) }
            _ = try? git.run(["checkout", "--quiet", "--force", "--no-recurse-submodules", "--detach", mainHead], allowFailure: true)
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
        try MergeInfrastructureError.wrapping { try clearMergeState(admin: mergeRepositoryPath, detachAt: rebased) }
        let nowMain = try MergeInfrastructureError.wrapping { try head(of: Self.mainRef) }
        guard nowMain == mainHead else { return .mainMoved(head: nowMain) }
        try checkRebase(git, rebased, of: verified, base: base, onto: mainHead, key: key)
        // The result's objects go back into the workspace (a bundle made by the engine's own repository); the branch then
        // carries what will be checked and landed. An author who moved it meanwhile wins nothing.
        let moved = try MergeInfrastructureError.wrapping { () throws -> GitCommand.Output in
            try handBack(git, result: rebased, prerequisites: [mainHead, verified])
            try beforeRefMove(branchRef(key: key))
            return try main.run(["update-ref", branchRef(key: key), rebased, verified], allowFailure: true)
        }
        guard moved.status == 0 else { return .branchMoved(head: try MergeInfrastructureError.wrapping { try head(of: branchRef(key: key)) }) }
        syncItemCheckout(key: key, to: rebased)
        return .rebased(head: rebased)
    }

    /// Throws unless `rebased` is exactly `verified` replayed on `onto`: `onto` is its ancestor, it adds as many commits as
    /// `verified` has (merges aside) since `base`, and its tree is what git merges `base..verified` into `onto` to. Everything
    /// is asked of the engine repository (whose config and attributes are written again right before the merge-tree).
    func checkRebase(_ git: GitCommand, _ rebased: String, of verified: String, base: String, onto: String, key: String) throws {
        func refuse(_ why: String) -> GitError {
            GitError.failed(command: "rebase item/\(key)", status: -1, stderr: "the rebased commit \(rebased.prefix(7)) \(why); nothing was moved")
        }
        guard try Self.isAncestor(git, onto, of: rebased) else { throw refuse("is not on main") }
        let added = try git.run(["rev-list", "--count", "\(onto)..\(rebased)"]).text
        let carried = try git.run(["rev-list", "--count", "--no-merges", "\(base)..\(verified)"]).text
        guard let a = Int(added), let c = Int(carried), a == c else { throw refuse("adds \(added) commits where the verified work has \(carried)") }
        try MergeInfrastructureError.wrapping { try assertEngineState() }
        let merged = try git.run(["merge-tree", "--write-tree", "--merge-base=\(base)", onto, verified], allowFailure: true)
        let tree = String(merged.text.split(separator: "\n").first ?? "")
        guard merged.status == 0, tree.range(of: "^[0-9a-f]{40,64}$", options: .regularExpression) != nil else {
            throw refuse("could not be compared with the merge of the verified work (merge-tree \(merged.status))")
        }
        let actual = try git.run(["rev-parse", "--verify", "\(rebased)^{tree}"]).text
        guard actual == tree else { throw refuse("does not hold the merge of the verified work") }
    }

    /// `merge-base --is-ancestor` in `git`: only "yes" and "no" are answers; any other outcome throws.
    static func isAncestor(_ git: GitCommand, _ ancestor: String, of descendant: String) throws -> Bool {
        let out = try git.run(["merge-base", "--is-ancestor", ancestor, descendant], allowFailure: true)
        guard out.status == 0 || out.status == 1 else {
            throw GitError.failed(command: "merge-base --is-ancestor", status: out.status, stderr: String(out.stderr.prefix(2000)))
        }
        return out.status == 0
    }

    /// `merge-base` in `git`: nil when the two have no history in common; any other failure throws.
    static func mergeBase(_ git: GitCommand, _ a: String, _ b: String) throws -> String? {
        let out = try git.run(["merge-base", a, b], allowFailure: true)
        if out.status == 0, !out.text.isEmpty { return out.text }
        guard out.status == 1 else { throw GitError.failed(command: "merge-base", status: out.status, stderr: String(out.stderr.prefix(2000))) }
        return nil
    }

    /// Whether `refs/heads/main` has been made a symbolic ref (to an item branch, say): the engine neither follows nor moves it.
    public func mainIsSymbolic() throws -> Bool {
        !(try main.run(["for-each-ref", "--format=%(symref)", Self.mainRef]).text.isEmpty)
    }

    /// Fast-forwards `refs/heads/main` from `old` to `new` (the caller holds main's lock): the expected next head is recorded
    /// first, then a compare-and-swap `update-ref`, then a check that `main` is `new`. The root checkout, when it is on
    /// `main`, follows with a two-tree `read-tree` (which never overwrites local edits).
    private func moveMainLocked(from old: String, to new: String, recordPending: (String) throws -> Void,
                                beforeRefMove: (String) throws -> Void = { _ in }) throws {
        guard try isAncestor(old, of: new) else {
            throw GitError.failed(command: "update-ref \(Self.mainRef)", status: -1, stderr: "not a fast-forward of main")
        }
        guard try !mainIsSymbolic() else {
            throw GitError.failed(command: "update-ref \(Self.mainRef)", status: -1, stderr: "main is a symbolic ref")
        }
        try recordPending(new)
        // The last moment before `main` moves (the owner's stop is read here; the caller clears the pending record).
        try beforeRefMove(Self.mainRef)
        try main.run(["update-ref", "--no-deref", Self.mainRef, new, old])
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
        // Never through `HEAD`: `resetHard` resets the index and tree by `read-tree` and moves only this item's ref (compare-and-swap).
        try? resetHard(in: worktreePath(key: key), to: commit)
    }

    /// Removes every in-progress operation's state from the merge repository's git dir (the engine's own rebase, or one
    /// planted there) without asking git to undo it, and points its `HEAD` straight at `commit` (detached).
    func clearMergeState(admin: URL, detachAt commit: String) throws {
        for name in ["rebase-merge", "rebase-apply", "sequencer", "MERGE_HEAD", "MERGE_MSG", "MERGE_MODE", "MERGE_RR",
                     "CHERRY_PICK_HEAD", "REVERT_HEAD", "REBASE_HEAD", "AUTO_MERGE", "ORIG_HEAD", "BISECT_LOG", "BISECT_START",
                     "index.lock", "MERGE_AUTOSTASH"] {
            try removeEngineItem(admin.appending(path: name))
        }
        let head = admin.appending(path: "HEAD")
        if Self.isSymlink(head) { try removeEngineItem(head) }
        try (commit + "\n").write(to: head, atomically: true, encoding: .utf8)
    }

    // MARK: Agent-writable state that blocks a merge

    /// A git lock file nobody has touched for this long is left behind, not held: git holds its locks for milliseconds.
    static let staleLockAge: TimeInterval = 60

    /// What the merge-queue self-heal reports when it fetched objects of `main`'s history back into the workspace.
    static let restoredHistoryNote = "objects of main's history that were missing (restored from Brahma's merge repository)"

    /// The merge queue's self-heal (A3); the caller holds main's lock. The workspace repository is agent-writable, so state in
    /// it that would hold every merge is tampering, not the company's fault: it is repaired and the names are returned for
    /// the owner's alert.
    /// - every `*.lock` file in the common git dir (`objects` aside) nobody has touched for `staleLockAge` (a younger one is
    ///   left alone: git may be using it; the step that needs it then fails as the company's fault and is retried);
    /// - a planted `shallow` (the engine never makes a shallow repository; merges need full history) and `info/grafts`.
    /// Nothing is followed through a link; a link in the way is removed as the file it stands for.
    func healWorkspaceRepositoryLocked() throws -> [String] {
        try clearStaleWorkspaceLocks() + removePlantedHistoryFiles()
    }

    /// `shallow` and `info/grafts` in the workspace repository, removed (links too, never followed); their names.
    private func removePlantedHistoryFiles() throws -> [String] {
        guard Self.isRealDirectory(gitDir) else { return [] }
        var removed: [String] = []
        for name in ["shallow", "info/grafts"] {
            healProbe?(name)
            // Through descriptors from the workspace (`.git` and `info` opened without following a link): a part of the way
            // that is a link (`info` swapped meanwhile) is never followed, and nothing is removed through it.
            if case .removed = try EngineFiles.removeNoFollow(gitDir.appending(path: name), under: root) { removed.append(name) }
        }
        return removed
    }

    /// Whether a `shallow` or `info/grafts` is there (`removePlantedHistoryFiles` would remove something).
    private var hasPlantedHistoryFiles: Bool {
        ["shallow", "info/grafts"].contains { (try? FileManager.default.attributesOfItem(atPath: gitDir.appending(path: $0).path)) != nil }
    }

    /// Removes every `*.lock` file under the workspace's common git dir (`objects` aside, no link followed, at most 16 levels
    /// deep) that nobody has touched for `staleLockAge`; the paths removed, relative to the git dir.
    private func clearStaleWorkspaceLocks() throws -> [String] {
        guard Self.isRealDirectory(gitDir) else { return [] }
        let now = Date().timeIntervalSince1970
        // Descriptor-relative (`EngineFiles.removeFilesNoFollow`): every directory is opened by name in its parent's
        // descriptor with `O_NOFOLLOW` and every lock unlinked relative to its own directory's descriptor, so a directory
        // swapped for a link mid-walk is never followed. Bounded in depth and in entries looked at.
        return try EngineFiles.removeFilesNoFollow(under: root, ".git", maxDepth: 16, maxEntries: Self.lockWalkEntryLimit,
                                                   enter: { relative in
            guard relative != "objects" else { return false }
            healProbe?(relative)
            return true
        }, shouldRemove: { relative, st in
            let type = st.st_mode & S_IFMT
            guard relative.hasSuffix(".lock"), type == S_IFREG || type == S_IFLNK else { return false }
            let touched = Double(st.st_mtimespec.tv_sec) + Double(st.st_mtimespec.tv_nsec) / 1e9
            return now - touched >= Self.staleLockAge
        })
    }

    /// How many entries of the workspace's git dir the stale-lock walk looks at, at most (`objects` is never walked).
    static let lockWalkEntryLimit = 20_000

    /// The merge queue's self-heal for missing objects (A3); the caller holds main's and the engine repository's locks.
    /// The previous engine repository (`previousRepositoryPath`, kept from the last landing or export until a fetch works
    /// again) holds `main`'s history as it was fetched then. When it has `mainHead`, it bundles that history and the
    /// workspace repository unbundles it (`index-pack`: every object is checked against its id; no transport runs there).
    /// True when the objects were handed over; false when there is nothing to restore them from.
    private func restoreMainHistory(_ mainHead: String) throws -> Bool {
        let fm = FileManager.default
        let previous = previousRepositoryPath
        guard !Self.isSymlink(previous), fm.fileExists(atPath: previous.appending(path: "objects").path) else { return false }
        var source = GitCommand(gitDir: previous, workTree: mergeDirectory.deletingLastPathComponent(), commonDir: nil)
        source.attributes = Self.engineAttributes
        source.tempRoot = gitTemp
        source.tempRootObserver = gitTempObserver
        source.childGroups = childGroups
        guard try source.run(["cat-file", "-e", "\(mainHead)^{commit}"], allowFailure: true).status == 0 else { return false }
        try source.run(["update-ref", "--no-deref", "refs/brahma/heal", mainHead])
        let bundle = URL(fileURLWithPath: mergeDirectory.path + "-heal.bundle")
        try removeEngineItem(bundle)
        defer { _ = try? removeEngineItem(bundle) }
        guard try source.run(["bundle", "create", "--quiet", bundle.path, "refs/brahma/heal"], allowFailure: true).status == 0 else { return false }
        try main.run(["bundle", "unbundle", bundle.path])
        return true
    }

    // MARK: The engine's merge repository

    /// Exclusion for the engine's merge repository (landings and merge-check exports), across processes. Taken after main's
    /// lock when both are needed. A lock that cannot be taken is the company's fault.
    func withEngineLock<T>(_ body: () throws -> T) throws -> T {
        try withLockFile(name: "+engine", what: "the merge repository", infrastructure: true, body)
    }

    /// The engine's own repository for merge work, made afresh (the caller holds the engine lock): whatever was at
    /// `<home>/run/merge/<companyId>.git` and its private working tree `<home>/run/merge/<companyId>-wt` is deleted (a link is
    /// removed, never followed) and a new repository is initialized there, outside the workspace and every directory an agent
    /// is given. No object, ref, rebase state or setting from an earlier use (or written into it since) survives; objects come
    /// in only through `fetchIntoEngine`. Refuses to run on a git older than 2.43.
    func freshEngineRepository() throws -> GitCommand {
        try GitCommand.requireAttributeSource()
        let fm = FileManager.default
        let repo = mergeRepositoryPath, tree = mergeWorktreePath, previous = previousRepositoryPath
        try fm.createDirectory(at: mergeDirectory.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        // The last repository is kept aside (`previousRepositoryPath`) while no fetch has worked since: it is what main's
        // history can be restored from (`restoreMainHistory`). One that is already kept stays; this one then goes.
        if (try? fm.attributesOfItem(atPath: repo.path)) != nil {
            if !Self.isSymlink(repo), (try? fm.attributesOfItem(atPath: previous.path)) == nil {
                try fm.moveItem(at: repo, to: previous)
            } else {
                try removeEngineItem(repo)
            }
        }
        try removeEngineItem(tree)
        try fm.createDirectory(at: tree, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let git = engineCommand
        try git.run(["init", "--quiet", "--template="])
        try assertEngineState()
        return git
    }

    /// The engine repository before the current one, at `<mergeDirectory>-prev.git`, kept until a fetch into the current one
    /// has worked (`dropPreviousEngineRepository`).
    var previousRepositoryPath: URL { URL(fileURLWithPath: mergeDirectory.path + "-prev.git", isDirectory: true) }

    /// Removes `url` (the engine repository, its working tree, a bundle or archive beside it, or something inside them) through
    /// descriptors from `<home>/run/merge` (`EngineFiles.removeNoFollow`): a link is removed, never followed, and nothing is
    /// removed through a part of the way that is a link. No path is rebuilt.
    @discardableResult
    func removeEngineItem(_ url: URL) throws -> EngineFiles.Removal {
        try EngineFiles.removeNoFollow(url, under: mergeDirectory.deletingLastPathComponent())
    }

    /// A fetch into the current engine repository worked: it holds `main`'s history now, so the previous one goes.
    func dropPreviousEngineRepository() {
        _ = try? removeEngineItem(previousRepositoryPath)
    }

    /// Writes the engine repository's `config` and `info/attributes` in full (no includes, no hooks, no fsmonitor, no
    /// `merge.*`, `filter.*` or `diff.*` drivers; `* merge=text -filter -diff -text ...`) and removes every file that could
    /// steer git there (`config.worktree`, `commondir`, `shallow`, grafts, alternates, linked worktrees, hooks). Called when
    /// the repository is made and again right before the checkout that starts a rebase, the merge-tree and the archive. Every
    /// command also runs through the shared `GitCommand` hardening (`engineCommand`): the forced `-c` overrides, no global or
    /// system config, `--attr-source` set to the empty tree, the config allowlist, and `engineAttributes` kept in place.
    func assertEngineState() throws {
        let fm = FileManager.default
        let repo = mergeRepositoryPath
        guard !Self.isSymlink(repo), fm.fileExists(atPath: repo.appending(path: "objects").path) else {
            throw GitError.failed(command: "merge repository", status: -1, stderr: "the engine's merge repository is missing")
        }
        let config = repo.appending(path: "config")
        if Self.isSymlink(config) { try removeEngineItem(config) }
        try Self.engineConfig.write(to: config, atomically: true, encoding: .utf8)
        let info = repo.appending(path: "info", directoryHint: .isDirectory)
        if Self.isSymlink(info) { try removeEngineItem(info) }
        try fm.createDirectory(at: info, withIntermediateDirectories: true)
        let attributes = info.appending(path: "attributes")
        if Self.isSymlink(attributes) { try removeEngineItem(attributes) }
        try Self.engineAttributes.write(to: attributes, atomically: true, encoding: .utf8)
        for name in ["config.worktree", "commondir", "shallow", "info/grafts", "objects/info/alternates", "objects/info/http-alternates",
                     "worktrees", "hooks"] {
            // A part of the way that is a link (`objects/info`) is the engine repository gone wrong: refused, never followed.
            if case .blocked(let problem) = try removeEngineItem(repo.appending(path: name)) {
                throw GitError.failed(command: "merge repository", status: -1, stderr: "\(problem)")
            }
        }
    }

    /// No attribute of a tree can change what the engine merges or what a merge check sees: no drivers, no filters, no
    /// end-of-line or encoding conversion, no `$Id$` expansion, nothing left out of or substituted in an export.
    static let engineAttributes = "* merge=text -filter -diff -text -eol -ident -export-ignore -export-subst -working-tree-encoding\n"

    /// Only keys the shared allowlist (`RepoConfigGuard.isAllowed`) takes, so the engine repository passes the same check as
    /// every other repository. What the earlier version also wrote is forced on every call instead: `core.hooksPath`,
    /// `core.fsmonitor` and `core.attributesFile` by `GitCommand.configFlags`, `rerere.enabled` by `rebaseConfig`;
    /// `core.autocrlf` is off with no global or system config, and the attributes leave no end-of-line conversion.
    static let engineConfig = """
        [core]
        \trepositoryformatversion = 0
        \tfilemode = true
        \tbare = false
        \tlogallrefupdates = false
        \tsymlinks = true
        [gc]
        \tauto = 0

        """

    /// A shallow workspace repository cannot hand over full history: the company's fault, never the item's.
    private func refuseShallowWorkspace() throws {
        if (try? FileManager.default.attributesOfItem(atPath: gitDir.appending(path: "shallow").path)) != nil {
            throw GitError.failed(command: "fetch", status: -1, stderr: "the workspace repository is shallow; merges need its full history")
        }
    }

    /// Fetches `mainHead` and `verified` into the engine repository. When that fails, `mainHead` alone decides whose fault it
    /// is: `main`'s history that cannot be fetched (and a shallow workspace) is the company's (`MergeInfrastructureError`),
    /// anything else is the verified commit's (`GitError`).
    ///
    /// `main`'s history that cannot be fetched is first restored from the previous engine repository (`restoreMainHistory`,
    /// reported through `tamper`); only when that is not possible, or does not help, is it the company's fault.
    func fetchLandingInputs(_ engine: GitCommand, mainHead: String, verified: String, tamper: ([String]) -> Void) throws {
        try MergeInfrastructureError.wrapping { try refuseShallowWorkspace() }
        testHook?("fetch")
        do {
            try fetchIntoEngine(engine, commits: [mainHead, verified])
        } catch {
            // A refused workspace config (its own alert) is the company's fault as it stands: nothing is fetched, bundled or
            // restored through a repository the engine will not run git in.
            if (error as? GitError)?.isRepositoryRefusal == true { throw MergeInfrastructureError(underlying: error) }
            if let fault = mainHistoryFault(engine, mainHead: mainHead) {
                if (fault.underlying as? GitError)?.isRepositoryRefusal == true { throw fault }
                guard try MergeInfrastructureError.wrapping({ try restoreMainHistory(mainHead) }) else { throw fault }
                tamper([Self.restoredHistoryNote])
                if mainHistoryFault(engine, mainHead: mainHead) != nil { throw fault }
                try fetchIntoEngine(engine, commits: [mainHead, verified])
                return
            }
            throw error
        }
    }

    /// Nil when `mainHead` alone can be fetched into the engine repository; otherwise the company's fault to report.
    private func mainHistoryFault(_ engine: GitCommand, mainHead: String) -> MergeInfrastructureError? {
        do { try fetchIntoEngine(engine, commits: [mainHead]); return nil } catch let mainError {
            if let fault = mainError as? MergeInfrastructureError { return fault }
            if (mainError as? GitError)?.isRepositoryRefusal == true { return MergeInfrastructureError(underlying: mainError) }
            return MergeInfrastructureError(underlying: GitError.failed(
                command: "fetch main", status: -1, stderr: "main's history (\(mainHead.prefix(7))) could not be fetched: \(mainError)"))
        }
    }

    /// Fetches exactly `commits` from the workspace repository into the engine repository, by SHA: no refs, no tags, no
    /// `FETCH_HEAD`, so `refs/replace/*` and every other agent-made ref stay behind. Always a real transfer (`--refetch`: git
    /// never skips a commit because it seems to be there), every object checked by fsck, over the local file transport only
    /// (`protocol.allow=never`, `protocol.file.allow=always`, the stock `git-upload-pack`). A commit git cannot hand over (a
    /// missing or corrupt object) fails as a `GitError`.
    ///
    /// The fetch runs in the engine repository's context, but the `git-upload-pack` it spawns runs in the workspace
    /// repository, with that repository's config and without the forced `-c` overrides (git drops `GIT_CONFIG_PARAMETERS`
    /// for a local transport's child). So right before it, the workspace repository is asked for each commit through
    /// `main` (`cat-file -e`): its config passes the allowlist scan first (a refusal is `GitError.isRepositoryRefusal`,
    /// nothing is fetched), and a commit it does not hold fails here, as a `GitError`.
    private func fetchIntoEngine(_ engine: GitCommand, commits: [String]) throws {
        for commit in commits { try main.run(["cat-file", "-e", "\(commit)^{commit}"]) }
        var fetcher = engine
        fetcher.allowsLocalFetch = true
        try fetcher.run(Self.fetchFlags + [gitDir.path] + commits)
    }

    /// With `GitCommand.configFlags` (`protocol.allow=never`) and `allowsLocalFetch` (`protocol.file.allow=always`). Protocol
    /// v2 is what lets the engine want a commit by its id (`uploadpack.*` set on this command line would never reach the
    /// workspace's `git-upload-pack`).
    private static let fetchFlags = [
        "-c", "protocol.version=2",
        "-c", "fetch.fsckObjects=true", "-c", "transfer.fsckObjects=true", "-c", "fetch.unpackLimit=1", "-c", "transfer.unpackLimit=1",
        "fetch", "--quiet", "--refetch", "--no-tags", "--no-write-fetch-head", "--no-recurse-submodules", "--no-auto-gc",
        "--upload-pack=git-upload-pack",
    ]

    /// The engine's own step of handing the result of a rebase to the workspace: the engine repository bundles `result`'s
    /// objects on top of `prerequisites` and the workspace repository unbundles them (`git bundle unbundle`, which only runs
    /// `index-pack`). No transport runs in the workspace, so nothing in its config (`url.*.insteadOf`, `core.sshCommand`,
    /// remotes) takes part.
    func handBack(_ engine: GitCommand, result: String, prerequisites: [String]) throws {
        let ref = "refs/brahma/result"
        try engine.run(["update-ref", "--no-deref", ref, result])
        let bundle = URL(fileURLWithPath: mergeDirectory.path + "-result.bundle")
        try removeEngineItem(bundle)
        defer { _ = try? removeEngineItem(bundle) }
        try engine.run(["bundle", "create", "--quiet", bundle.path, ref] + prerequisites.map { "^\($0)" })
        try main.run(["bundle", "unbundle", bundle.path])
        guard try main.run(["cat-file", "-e", "\(result)^{commit}"], allowFailure: true).status == 0 else {
            throw GitError.failed(command: "bundle unbundle", status: -1, stderr: "\(result.prefix(7)) did not reach the workspace")
        }
    }

    /// Retires every merge checkout older engines registered in the workspace (`<ws>/.brahma/wt/.merge`, and the one that
    /// lived at `<mergeDirectory>/.merge` with its admin directory `<ws>/.git/worktrees/-merge`). Links are removed, never
    /// followed; never throws.
    func retireWorkspaceMergeCheckouts() {
        retireLegacyMergeCheckout()
        _ = try? removeEngineItem(mergeDirectory.appending(path: ".merge", directoryHint: .isDirectory))
        _ = try? withWorktreeRecords {
            for name in ["-merge", ".merge"] {
                _ = try? EngineFiles.removeNoFollow(gitDir.appending(path: "worktrees/\(name)"), under: root)
            }
        }
    }

    /// Removes `<ws>/.brahma/wt/.merge` (registered or not); never throws.
    private func retireLegacyMergeCheckout() {
        let fm = FileManager.default
        let legacy = legacyMergeWorktreePath
        guard Self.isSymlink(legacy) || fm.fileExists(atPath: legacy.path),
              let wt = try? engineDirectory(".brahma/wt", command: "worktree remove .merge") else { return }
        // Through the walked directory's descriptor (a link is unlinked, never followed); its admin directory goes with the
        // others in `retireWorkspaceMergeCheckouts`.
        _ = try? withWorktreeRecords {
            try? removeEngineEntry(".merge", in: wt, command: "worktree remove .merge")
            _ = try? main.run(["worktree", "prune"], allowFailure: true)
        }
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
            // `.brahma/` is the engine's (check snapshots, plans, notes, hand-offs): put back in the exclude file if an agent took
            // it out, and kept out of the quarantine commit and the clean whatever that file says.
            ensureExclude()
            try? FileManager.default.createDirectory(at: gitTemp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let index = gitTemp.appending(path: "brahma-quarantine-\(UUID().uuidString).index")
            defer { _ = try? EngineFiles.removeNoFollow(index, under: gitTemp) }
            let staged = main.withIndex(index)
            try staged.run(["read-tree", expectedMain])
            // The engine's staging never takes `.brahma/` (M2); the `rm --cached` drops anything `main` already tracks there.
            try stage(staged, in: root, relative: "")
            try staged.run(["rm", "-r", "--cached", "--ignore-unmatch", "--quiet", "--", ".brahma"])
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
            try main.run(["clean", "-fd", "--quiet", "-e", ".brahma/"])
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
    /// its checkout clean and on `main`. Only `commit` is ever merged, never what the ref holds. `recordMerged` runs with the
    /// new head while main's lock is still held (Plan 4a Task 3: the record is written under the lock the main guard's restore
    /// re-reads it under, so the guard never sees the move without its record).
    func mergeQuarantine(ref: String, commit: String, expectedMain: String, recordPending: (String) throws -> Void,
                         recordMerged: (String) throws -> Void = { _ in }) throws -> QuarantineOutcome {
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
            if try isAncestor(commit, of: mainHead) {
                try recordMerged(mainHead)      // nothing moves; the ask is still settled under the lock
                return .merged(mainHead: mainHead)
            }
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
            try recordMerged(next)
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

    /// Where the merge check of run `runId` runs: `<exportHome>/run/exports/<runId>` (`BrahmaPaths.exportDir(runId:)`).
    public func exportPath(runId: String) -> URL {
        exportHome.appending(path: "\(Self.exportsRelative)/\(runId)", directoryHint: .isDirectory)
    }

    static let exportsRelative = "run/exports"

    /// Where the check of a submission runs (run `runId`): `<exportHome>/run/checkouts/<runId>`
    /// (`BrahmaPaths.checkoutDir(runId:)`), a detached worktree under the data home, never in the workspace.
    public func checkoutPath(runId: String) -> URL {
        exportHome.appending(path: "\(Self.checkoutsRelative)/\(runId)", directoryHint: .isDirectory)
    }

    static let checkoutsRelative = "run/checkouts"
    /// Where older engines put submission checkouts, inside the agent-writable workspace; only swept at start-up now.
    static let legacyRunChecksRelative = ".brahma/wt-check"

    private static func validRunId(_ id: String) throws {
        guard id.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil else {
            throw GitError.failed(command: "worktree \(id.prefix(40))", status: -1, stderr: "invalid run id")
        }
    }

    static func validCommit(_ commit: String) throws {
        guard commit.range(of: "^[0-9a-fA-F]{7,64}$", options: .regularExpression) != nil else {
            throw GitError.failed(command: "commit \(commit.prefix(40))", status: -1, stderr: "invalid commit")
        }
    }

    /// A clean detached checkout of exactly `commit` at `<exportHome>/run/checkouts/<runId>` (`checkoutPath`), for an
    /// engine-run check of a submission: under the engine's data home, never in the workspace. The place is made 0700 through
    /// the walk from the data home (no link followed) and checked around git (`intoPlace`). Anything left at that place by a
    /// crashed run is removed first.
    public func addRunWorktree(runId: String, commit: String) throws -> URL {
        let command = "worktree add \(runId)"
        return try withWorktreeRecords {
            let checks = try freshRunPlace(runId: runId, commit: commit, command: command)
            let path = checkoutPath(runId: runId)
            try intoPlace(runId, in: checks, mode: 0o700, registered: true, command: command) { _ in
                try main.run(["worktree", "add", "--quiet", "--detach", path.path, commit])
            }
            return path
        }
    }

    /// The merge check of a rebased commit: a `.git`-free export of exactly `commit` at `<exportHome>/run/exports/<runId>`
    /// (`exportPath`), under the engine's data home and never in the workspace. Under the engine repository's lock the
    /// commit is fetched (fsck'd, by SHA) into a fresh engine repository and written out with `git archive` (no attribute of
    /// the tree leaves anything out or substitutes anything). The export directory is made 0700 through the safe walk from
    /// the data home, and tar unpacks the archive (read from its descriptor) with its working directory set from that
    /// directory's descriptor, relative names only and `-k`: it is never handed a path a swapped link could send elsewhere.
    /// No worktree is linked to the engine repository, so the check has no path back to its config or objects. Anything
    /// left at that place by a crashed run is removed first.
    ///
    /// Whose fault a failure is (A1): the engine's own steps (the engine repository and its lock, the shallow check,
    /// `assertEngineState`, the export directory and its place, `main`'s history that cannot be fetched even after the
    /// self-heal) throw `MergeInfrastructureError`, the company's fault. What only the item's own tree causes (the commit
    /// cannot be fetched or archived, tar refuses a path, two paths collide on this volume, a `.git` in it) throws
    /// `UnexportableTree`, the item's fault. Agent-planted state found on the way (`shallow`, `info/grafts`, objects of
    /// `main`'s history gone) is repaired under main's lock and reported through `tamper` (A3).
    public func addEngineExport(runId: String, commit: String, tamper: ([String]) -> Void = { _ in }) throws -> URL {
        let command = "archive \(runId)"
        try Self.validRunId(runId); try Self.validCommit(commit)
        let exports = try MergeInfrastructureError.wrapping { try exportsDirectory(command: command) }
        try MergeInfrastructureError.wrapping { try removeEngineEntry(runId, in: exports, command: command) }
        if hasPlantedHistoryFiles {
            let repaired = try withMainLock(infrastructure: true) { try MergeInfrastructureError.wrapping { try removePlantedHistoryFiles() } }
            if !repaired.isEmpty { tamper(repaired) }
        }
        let archive = URL(fileURLWithPath: mergeDirectory.path + "-export-\(runId).tar")
        defer { _ = try? removeEngineItem(archive) }
        do {
            try withEngineLock { try archiveLocked(commit: commit, to: archive, exports: exports) }
        } catch let missing as MainHistoryMissing {
            // Restored under main's lock, then main's and the engine repository's (the landing's order), and tried once more.
            let restored = try withMainLock(infrastructure: true) {
                try withEngineLock { try MergeInfrastructureError.wrapping { try restoreMainHistory(missing.mainHead) } }
            }
            guard restored else { throw missing.underlying }
            tamper([Self.restoredHistoryNote])
            do { try withEngineLock { try archiveLocked(commit: commit, to: archive, exports: exports) } } catch let again as MainHistoryMissing {
                throw again.underlying
            }
        }
        let tarball = open(archive.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard tarball >= 0 else {
            throw MergeInfrastructureError(underlying: GitError.failed(command: "archive", status: -1,
                                                                       stderr: "could not open the export of \(commit.prefix(7))"))
        }
        defer { close(tarball) }
        try intoPlace(runId, in: exports, mode: 0o700, registered: false, command: command,
                      placeFault: { MergeInfrastructureError(underlying: $0) }) { place in
            do { try Self.untar(tarball, into: place) } catch let refused as UnexportableTree { throw refused } catch {
                throw MergeInfrastructureError(underlying: error)
            }
            // A tree cannot hold `.git` (fsck refuses it on the fetch); an export never has one either way.
            if place.kind(of: ".git") != .missing {
                throw UnexportableTree(reason: "the export of \(commit.prefix(7)) holds a .git")
            }
        }
        return exportPath(runId: runId)
    }

    /// `addEngineExport`'s work in the engine repository; the caller holds its lock. Fetches `commit` (when that fails,
    /// `main`'s head alone decides: `main` not fetchable is `MainHistoryMissing`, otherwise it is the commit's fault), refuses
    /// a tree whose paths collide on the exports' volume, and writes the archive.
    private func archiveLocked(commit: String, to archive: URL, exports: EngineFiles.OpenDirectory) throws {
        let git = try MergeInfrastructureError.wrapping { try freshEngineRepository() }
        try MergeInfrastructureError.wrapping { try refuseShallowWorkspace() }
        do { try fetchIntoEngine(git, commits: [commit]) } catch {
            // A refused repository config (its own alert) or the engine's own fault stays what it is.
            if error is MergeInfrastructureError || (error as? GitError)?.isRepositoryRefusal == true { throw error }
            guard let mainHead = try MergeInfrastructureError.wrapping({ try head(of: Self.mainRef) }) else {
                throw MergeInfrastructureError(underlying: error)
            }
            if let fault = mainHistoryFault(git, mainHead: mainHead) {
                if (fault.underlying as? GitError)?.isRepositoryRefusal == true { throw fault }
                throw MainHistoryMissing(mainHead: mainHead, underlying: fault)
            }
            throw UnexportableTree(reason: "\(commit.prefix(7)) could not be fetched from the workspace repository (\(Self.oneLine(error)))")
        }
        dropPreviousEngineRepository()
        try MergeInfrastructureError.wrapping {
            try removeEngineItem(archive)
            try assertEngineState()
        }
        try refuseCollidingPaths(git, commit: commit, on: exports)
        let out = try MergeInfrastructureError.wrapping {
            try git.run(["archive", "--format=tar", "--output=\(archive.path)", "\(commit)^{commit}"], allowFailure: true)
        }
        guard out.status == 0 else {
            throw UnexportableTree(reason: "git could not archive \(commit.prefix(7)) (\(Self.oneLine(out.stderr)))")
        }
    }

    /// Two paths of the tree that are different bytes but one name on the exports' volume would be unpacked as one, silently
    /// (`tar -k` keeps the first): such a tree is refused. macOS volumes never tell Unicode normalization forms apart (NFC
    /// and NFD of one name are one file); a case-insensitive volume (the exports' own, asked of its descriptor) also folds
    /// case. Names are keyed by their case folding (`.caseInsensitive`, close to APFS's) under Swift's canonical
    /// equivalence, and two names collide when their keys match while their bytes differ (`utf8.elementsEqual`). A listing
    /// too long to read whole is refused rather than exported unchecked.
    private func refuseCollidingPaths(_ git: GitCommand, commit: String, on exports: EngineFiles.OpenDirectory) throws {
        #if canImport(Darwin)
        let foldsCase = fpathconf(exports.fd, _PC_CASE_SENSITIVE) != 1
        #else
        return
        #endif
        let out = try MergeInfrastructureError.wrapping {
            try git.run(["ls-tree", "-r", "-t", "-z", "--full-tree", "\(commit)^{commit}"], allowFailure: true, maxOutput: collisionListingLimit)
        }
        guard out.status == 0 else { throw UnexportableTree(reason: "git could not list \(commit.prefix(7)) (\(Self.oneLine(out.stderr)))") }
        guard !out.cut else {
            throw UnexportableTree(reason: "the tree of \(commit.prefix(7)) is too large to inspect for colliding paths (over \(collisionListingLimit) bytes listed)")
        }
        var seen: [String: (path: String, tree: Bool)] = [:]
        var collisions: [String] = []
        for raw in out.stdout.split(separator: 0, omittingEmptySubsequences: true) {
            let entry = String(decoding: raw, as: UTF8.self)
            guard let tab = entry.firstIndex(of: "\t") else { continue }
            let path = String(entry[entry.index(after: tab)...])
            let tree = entry[..<tab].split(separator: " ").dropFirst().first == "tree"
            let folded = foldsCase ? path.folding(options: [.caseInsensitive], locale: nil) : path
            if let other = seen[folded], !other.path.utf8.elementsEqual(path.utf8), !(other.tree && tree) {
                collisions.append("\(Self.flatName(other.path)) and \(Self.flatName(path))")
                if collisions.count == 3 { break }
            } else if seen[folded] == nil {
                seen[folded] = (path, tree)
            }
        }
        guard collisions.isEmpty else {
            throw UnexportableTree(reason: "paths that differ only in case or Unicode form collide on this volume: \(collisions.joined(separator: "; "))")
        }
    }

    private static func oneLine(_ error: any Error) -> String { oneLine("\(error)") }
    private static func oneLine(_ text: String) -> String {
        String(text.split(whereSeparator: \.isNewline).joined(separator: " ").prefix(300))
    }
    private static func flatName(_ path: String) -> String {
        String(path.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7f }.map(Character.init).prefix(120))
    }

    /// `<exportHome>/run/exports`, walked from the data home without following a link (created when missing); a link or
    /// odd file on the way is reported and refused.
    private func exportsDirectory(command: String) throws -> EngineFiles.OpenDirectory {
        do { return try EngineFiles.openWalked(workspace: exportHome, Self.exportsRelative) } catch let problem as UnsafeEngineFile {
            onUnsafeEngineFile?(problem)
            throw GitError.failed(command: command, status: -1, stderr: "\(problem)")
        }
    }

    /// The walked `<exportHome>/run/exports`, or nil when nothing is there yet (it is not created just to be emptied) or it
    /// is refused (reported).
    private func existingExports(command: String) -> EngineFiles.OpenDirectory? {
        let dir = exportHome.appending(path: Self.exportsRelative, directoryHint: .isDirectory)
        guard (try? FileManager.default.attributesOfItem(atPath: dir.path)) != nil || Self.isSymlink(dir) else { return nil }
        return try? exportsDirectory(command: command)
    }

    /// `<exportHome>/run/checkouts` (walked from the data home without links, created when missing), with whatever a
    /// crashed run left at `<runId>` in it removed.
    private func freshRunPlace(runId: String, commit: String, command: String) throws -> EngineFiles.OpenDirectory {
        try Self.validRunId(runId); try Self.validCommit(commit)
        let checks = try checkoutsDirectory(command: command)
        try removeEngineEntry(runId, in: checks, command: command)
        _ = try? main.run(["worktree", "prune"], allowFailure: true)
        return checks
    }

    /// `<exportHome>/run/checkouts`, walked from the data home without following a link (created when missing); a link or
    /// odd file on the way is reported and refused.
    private func checkoutsDirectory(command: String) throws -> EngineFiles.OpenDirectory {
        do { return try EngineFiles.openWalked(workspace: exportHome, Self.checkoutsRelative) } catch let problem as UnsafeEngineFile {
            onUnsafeEngineFile?(problem)
            throw GitError.failed(command: command, status: -1, stderr: "\(problem)")
        }
    }

    /// The walked `<exportHome>/run/checkouts`, or nil when nothing is there yet or it is refused (reported).
    private func existingCheckouts(command: String) -> EngineFiles.OpenDirectory? {
        let dir = exportHome.appending(path: Self.checkoutsRelative, directoryHint: .isDirectory)
        guard (try? FileManager.default.attributesOfItem(atPath: dir.path)) != nil || Self.isSymlink(dir) else { return nil }
        return try? checkoutsDirectory(command: command)
    }

    /// Unpacks a tar file made by `git archive` (read from `archive`, a descriptor) with `ToolPaths.tar` (`/usr/bin/tar`) into
    /// `place`. tar is spawned (`Spawn`, in the engine's process group as before, waited for without a timeout as before) with
    /// its working directory set from `place`'s descriptor (`posix_spawn_file_actions_addfchdir_np`), so it writes relative
    /// to that directory wherever its path now leads; `-k` never overwrites a file, and tar refuses absolute paths, `..` and
    /// extraction through links. Every other descriptor is closed in the child.
    static func untar(_ archive: Int32, into place: EngineFiles.OpenDirectory) throws {
        let environment = ChildEnvironment.make(base: ProcessInfo.processInfo.environment, purpose: .general)
        let tar: Spawn.Child
        do {
            tar = try Spawn.start(ToolPaths.fixedTar, ["-x", "-k", "-f", "-"], cwd: URL(fileURLWithPath: "/", isDirectory: true),
                                  cwdDescriptor: place.fd, env: environment, stdin: .descriptor(archive), group: false)
        } catch {
            throw GitError.failed(command: "archive", status: -1, stderr: "could not unpack the export: \(error)")
        }
        let status = tar.waitStatus()
        guard !tar.lostTrack else {
            throw GitError.failed(command: "archive", status: -1, stderr: "could not wait for tar: its exit status was lost")
        }
        // tar ran and refused: what it was given is the commit's tree (a path it or the volume refuses, an over-long name).
        guard status == 0 else {
            throw UnexportableTree(reason: "its files could not be unpacked for the merge check (tar exit \(status >> 8); a path tar or the volume refuses, such as an over-long name)")
        }
    }

    /// Removes one run's checkout (through the walked `<exportHome>/run/checkouts`) and its export (through the walked
    /// `<exportHome>/run/exports`), never by a path; git then forgets a checkout (`prune`). Never throws.
    public func removeRunWorktree(runId: String) {
        guard (try? Self.validRunId(runId)) != nil else { return }
        let command = "worktree remove \(runId)"
        if let exports = existingExports(command: command) { try? removeEngineEntry(runId, in: exports, command: command) }
        guard let checks = existingCheckouts(command: command) else { return }
        _ = try? withWorktreeRecords {
            try? removeEngineEntry(runId, in: checks, command: command)
            _ = try? main.run(["worktree", "prune"], allowFailure: true)
        }
    }

    /// Start-up: no check is running, so every leftover run checkout and export goes, and so do the checkouts older engines
    /// left in the workspace's `.brahma/wt-check`.
    public func removeRunWorktrees() {
        if let exports = existingExports(command: "export prune") {
            for name in (try? exports.names()) ?? [] { try? removeEngineEntry(name, in: exports, command: "export prune") }
        }
        _ = try? withWorktreeRecords {
            if let checks = existingCheckouts(command: "worktree prune") {
                for name in (try? checks.names()) ?? [] { try? removeEngineEntry(name, in: checks, command: "worktree prune") }
            }
            if let legacy = existingLegacyRunChecks(command: "worktree prune") {
                for name in (try? legacy.names()) ?? [] { try? removeEngineEntry(name, in: legacy, command: "worktree prune") }
            }
            _ = try? main.run(["worktree", "prune"], allowFailure: true)
        }
    }

    /// The walked `.brahma/wt-check` of an older engine, or nil when nothing is there (it is not created just to be emptied)
    /// or it is refused (reported).
    private func existingLegacyRunChecks(command: String) -> EngineFiles.OpenDirectory? {
        let dir = root.appending(path: Self.legacyRunChecksRelative, directoryHint: .isDirectory)
        guard (try? FileManager.default.attributesOfItem(atPath: dir.path)) != nil || Self.isSymlink(dir) else { return nil }
        return try? engineDirectory(Self.legacyRunChecksRelative, command: command)
    }

    // MARK: Commits and refs

    /// Stages everything (`stage`: the engine feeds each file from a descriptor it checked; no `git add` reads the tree) and
    /// commits it; the new commit, or nil when there was nothing to commit.
    ///
    /// In an item worktree the commit is built outside `HEAD`: a private index is read from the item branch's tip, the work
    /// is staged into it, `write-tree` and `commit-tree` make the commit, and `refs/heads/item/<KEY>` is advanced with
    /// `update-ref <ref> <new> <expected old>`. Whatever `HEAD` says at that moment (a turn may rewrite it between the check
    /// and here), no other branch can move, and a branch that moved meanwhile makes the swap fail.
    @discardableResult
    public func commitAll(in dir: URL, message: String) throws -> String? {
        try commitAllWithParent(in: dir, message: message)?.commit
    }

    /// `commitAll`, also naming the branch tip the commit was stacked on (nil outside an item worktree).
    func commitAllWithParent(in dir: URL, message: String) throws -> (parent: String?, commit: String)? {
        let (git, key) = try resolve(dir)
        guard let key else {
            try stage(git, in: dir, relative: "")
            let staged = try git.run(["diff", "--cached", "--quiet"], allowFailure: true)
            if staged.status == 0 { return nil }
            guard staged.status == 1 else {
                throw GitError.failed(command: "diff --cached --quiet", status: staged.status, stderr: staged.stderr)
            }
            try git.run(["commit", "--quiet", "--no-verify", "-m", message])
            return (nil, try git.run(["rev-parse", "HEAD"]).text)
        }
        let ref = branchRef(key: key)
        guard let tip = try ownTip(git, ref) else {
            throw GitError.failed(command: "commit \(key)", status: -1, stderr: "\(ref) does not exist")
        }
        testHook?("checked")
        try? FileManager.default.createDirectory(at: gitTemp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let index = gitTemp.appending(path: "brahma-index-\(UUID().uuidString)")
        defer { _ = try? EngineFiles.removeNoFollow(index, under: gitTemp) }
        let private_ = git.withIndex(index)
        try private_.run(["read-tree", tip])
        try stage(private_, in: dir, relative: ".brahma/wt/" + key)
        let tree = try private_.run(["write-tree"]).text
        if tree == (try git.run(["rev-parse", "--verify", "\(tip)^{tree}"]).text) { try verifyAfter(key: key); return nil }
        let commit = try git.run(["commit-tree", tree, "-p", tip, "-m", message]).text
        // `--no-deref`: should the item ref have become symbolic meanwhile, it is overwritten, never followed to its target.
        try git.run(["update-ref", "--no-deref", "-m", message, ref, commit, tip])
        // The worktree's own index follows the branch, so the checkout is clean afterwards.
        _ = try? git.run(["read-tree", commit])
        try verifyAfter(key: key)
        return (tip, commit)
    }

    /// The most paths `stage` leaves out of one commit; more refuses the commit.
    static let maxUnsafeAdds = 1000

    /// The largest file of a nested repository (`HEAD`, a loose ref, `packed-refs`) the engine reads to record a gitlink.
    static let gitlinkReadLimit = 1 << 20

    /// How many checked file descriptors `stage` may hold open at once while it feeds blobs (NB1). The feeder opens, checks,
    /// feeds and closes one file at a time, so one is enough; the cap fails closed should that ever change. Test seam.
    var stagingDescriptorCap = 8

    /// `maxUnsafeAdds` for this workspace value. Test seam (fix round 7: the count runs before any blob is written).
    var unsafeAddLimit = GitWorkspace.maxUnsafeAdds

    /// A top-level name as the engine compares it (S11.2): case-folded (`.caseInsensitive`, close to APFS's) and in the
    /// canonical composed form, so `.BRAHMA` or a decomposed spelling names the same directory as `.brahma`.
    static func foldedName(_ bytes: [UInt8]) -> String {
        String(decoding: bytes, as: UTF8.self).folding(options: [.caseInsensitive], locale: nil).precomposedStringWithCanonicalMapping
    }

    /// The engine's own top-level directories (`excludedEntries`), folded.
    static let engineNames: Set<String> = Set(excludedEntries.map { foldedName(Array($0.dropLast().utf8)) })

    /// Whether a top-level name is one of the engine's own directories, by folded name.
    static func isEngineName(_ bytes: [UInt8]) -> Bool { engineNames.contains(foldedName(bytes)) }

    /// Engine-fed staging (I1, fix round 5): what `git add -A` did for the engine, without git ever reading the checkout.
    ///
    /// `commitAll` on an item worktree runs inside the agent's own turn (submit, release), with the agent's processes alive.
    /// A `git add` that reads the tree by path can be raced: a listed innocent file swapped for a hard link to an owner secret,
    /// or an ignored one un-ignored between the listing and the add, and git writes the secret's blob into the shared object
    /// database, which item turns can read. So no `add` runs on an agent tree (nor on the root checkout). Instead:
    /// - the candidates are listed once (`ls-files --others --modified --deleted --exclude-standard` on the command's own
    ///   index, so `.gitignore` and the exclude file are honoured as git honours them). A path whose first part is one of
    ///   the engine's directories, by folded name (`isEngineName`: case and canonical form, S11.2) or by (device, inode), is
    ///   never one, whatever the exclude file says (M2); one whose first part folds to `.git` is refused;
    /// - each is reached through descriptors only (`EngineFiles.staged`: every part `O_NOFOLLOW`, the verdict from `fstat` of
    ///   the open descriptor) and must pass `EngineFiles.copyProblem` on that descriptor; its bytes go from that descriptor
    ///   to `git fast-import` (blobs only, marks exported), one file at a time inside the feeder (opened, checked, fed,
    ///   closed; `stagingDescriptorCap` fails closed, NB1), and the index takes them with `update-index -z --index-info`
    ///   (`<mode> <id>\t<path>`: `--cacheinfo` for every entry in one stdin, mode `0` removing a deleted one);
    /// - a path that is gone, or whose way is now blocked by a file or a link (nothing read, NB4), becomes a deletion;
    /// - a symbolic link is stored as a link (mode 120000, its target as the blob) only when `linkProblem` is nil: no `..`
    ///   part, an absolute target inside the checkout once `.` parts are dropped, and no link among the directories it
    ///   passes through (checked through descriptors); otherwise it is refused (S11.1 / NB3);
    /// - a nested repository (new, listed as `dir/`; or tracked as a gitlink, listed as `dir` when its HEAD moved, NB2) is
    ///   recorded as a gitlink of its `HEAD`, read through the same descriptors (no git runs in it); one whose HEAD cannot be
    ///   read keeps its recorded commit (new: refused), with an alert;
    /// - a refused path is left out and reported (`onUnsafeEngineFile`, also when the commit then fails), the file stays
    ///   where it is; more than `maxUnsafeAdds` refusals (counted in a first pass, before any blob is written, and again
    ///   after the feed), a listing that fails or is cut, or a file that changes size while it is fed, refuses the commit
    ///   (fail closed). A way the engine cannot open (EACCES, EMFILE, EIO, ...) is a refusal; only ENOTDIR / ELOOP delete.
    /// Nothing travels on argv: the listing and the entries both go over stdin / stdout with NUL separators (M3).
    func stage(_ git: GitCommand, in dir: URL, relative: String) throws {
        let listing = try git.run(["ls-files", "-z", "--others", "--modified", "--deleted", "--exclude-standard"], maxOutput: planBarrierOutputLimit)
        if listing.timedOut || listing.cut {
            throw GitError.failed(command: "stage", status: -1, stderr: "cannot list the files to commit (\(listing.timedOut ? "timed out" : "listing too long"))")
        }
        // The tracked gitlinks (NB2): a nested repository whose HEAD moved lists as `sub` (a directory) and must be updated,
        // never deleted; one whose HEAD cannot be read keeps its recorded commit.
        let indexed = try git.run(["ls-files", "-s", "-z"], maxOutput: planBarrierOutputLimit)
        if indexed.timedOut || indexed.cut {
            throw GitError.failed(command: "stage", status: -1, stderr: "cannot list the index (\(indexed.timedOut ? "timed out" : "listing too long"))")
        }
        var gitlinksSeen: [Data: String] = [:]
        for entry in indexed.stdout.split(separator: 0, omittingEmptySubsequences: true) where entry.starts(with: Data("160000 ".utf8)) {
            guard let tab = entry.firstIndex(of: UInt8(ascii: "\t")) else { continue }
            let fields = String(decoding: entry[..<tab], as: UTF8.self).split(separator: " ")
            guard fields.count == 3 else { continue }
            gitlinksSeen[Data(entry[entry.index(after: tab)...])] = String(fields[1])
        }
        testHook?("listed")
        let top = try EngineFiles.openWalked(workspace: root, relative)
        let roots: Set<String> = [top.real, dir.path, dir.standardizedFileURL.path]
        // The engine's directories by identity too (S11.2): whatever a listing calls them, the same inode is never staged.
        let engineIdentities = Self.excludedEntries.compactMap { EngineFiles.identity(in: top, name: Array($0.dropLast().utf8)) }
        struct Candidate { var bytes: [UInt8]; var parts: [[UInt8]]; var isDirectory: Bool; var shown: String }
        var found: [Candidate] = []
        var problems: [UnsafeEngineFile] = []
        var seen = Set<Data>()
        for raw in listing.stdout.split(separator: 0, omittingEmptySubsequences: true) where seen.insert(Data(raw)).inserted {
            let isDirectory = raw.last == UInt8(ascii: "/")
            let bytes = Array(isDirectory ? raw.dropLast() : raw[...])
            let parts = bytes.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: true).map(Array.init)
            guard let first = parts.first else { continue }
            if Self.isEngineName(first) { continue }
            if let identity = EngineFiles.identity(in: top, name: first), engineIdentities.contains(where: { $0 == identity }) { continue }
            let shown = dir.path + "/" + String(decoding: bytes, as: UTF8.self)
            if Self.foldedName(first) == ".git" {
                problems.append(UnsafeEngineFile(path: shown, problem: "has a reserved name; left out of the commit"))
                continue
            }
            found.append(Candidate(bytes: bytes, parts: parts, isDirectory: isDirectory, shown: shown))
        }
        struct Entry { var mode: String; var mark: Int?; var id: String?; var path: [UInt8] }
        /// What one candidate comes to, decided through descriptors only (`EngineFiles.staged`, `linkProblem`, `gitlinkHead`).
        /// `.file` holds an open, checked descriptor the caller closes.
        enum Verdict {
            case remove
            case file(fd: Int32, size: Int64, executable: Bool)
            case link(target: [UInt8])
            case gitlink(id: String)
            /// A tracked gitlink whose HEAD cannot be read: the recorded commit stays, the owner is told.
            case keptGitlink(id: String, problem: UnsafeEngineFile)
            case refuse(UnsafeEngineFile)
        }
        let recordedGitlinks = gitlinksSeen
        @Sendable func refusal(_ shown: String, _ problem: String) -> Verdict {
            .refuse(UnsafeEngineFile(path: shown, problem: "\(problem); left out of the commit"))
        }
        @Sendable func gitlinkVerdict(_ c: Candidate, recorded: String?) -> Verdict {
            do { return .gitlink(id: try gitlinkHead(top, c.parts, shown: c.shown)) }
            catch let problem as UnsafeEngineFile {
                if let recorded {
                    return .keptGitlink(id: recorded, problem: UnsafeEngineFile(path: c.shown, problem: "is a nested repository whose HEAD cannot be read (\(problem.problem)); its recorded commit is kept"))
                }
                return refusal(c.shown, "is a nested repository whose HEAD cannot be read: \(problem.problem)")
            } catch {
                return refusal(c.shown, "is a nested repository whose HEAD cannot be read: \(error)")
            }
        }
        @Sendable func verdict(_ c: Candidate) -> Verdict {
            // `ls-files --others` lists a new nested repository as `dir/`.
            if c.isDirectory { return gitlinkVerdict(c, recorded: nil) }
            switch EngineFiles.staged(in: top, relative: c.parts, shown: c.shown) {
            case .missing, .unreachable:
                // Gone, or a file or link now stands where a directory on the way was (NB4): the index entry goes.
                return .remove
            case .directory:
                let recorded = recordedGitlinks[Data(c.bytes)]
                if recorded != nil || EngineFiles.wayKind(in: top, relative: c.parts + [Array(".git".utf8)]) == .real {
                    return gitlinkVerdict(c, recorded: recorded)
                }
                // A directory in its place, whose files list on their own.
                return .remove
            case .file(let fd, let size, let executable):
                return .file(fd: fd, size: size, executable: executable)
            case .link(let target):
                if let problem = Self.linkProblem(target: target, from: c.parts.dropLast(), top: top, roots: roots) {
                    return refusal(c.shown, "is a symbolic link that \(problem)")
                }
                return .link(target: target)
            case .refused(let problem):
                return refusal(c.shown, problem.problem)
            }
        }
        /// What the feeder collects while it runs on its own thread; read here only after git has exited.
        final class Staging: @unchecked Sendable {
            var entries: [Entry] = []
            var problems: [UnsafeEngineFile] = []
            var marks = 0
            var open = 0
        }
        let staging = Staging()
        staging.problems = problems
        // Every refusal collected is reported, whether the commit goes ahead or fails later (fast-import, the cap, a file
        // that changes size): `runOnce` waits for the feeder before it returns or throws, so nothing writes `staging` here.
        defer { for problem in staging.problems { onUnsafeEngineFile?(problem) } }
        var ids: [Int: String] = [:]
        let candidates = found
        let cap = stagingDescriptorCap, limit = unsafeAddLimit
        // The refusal count first, before any blob is written (a commit with too many refusals leaves no objects behind):
        // each candidate is judged as the feeder will judge it, one descriptor at a time, and closed again. The feeder
        // judges each again from a fresh descriptor (what it feeds is what it checked), and the count is taken again after.
        var counted = problems
        for c in candidates where counted.count <= limit {
            if !c.isDirectory, cap <= 0 {
                throw GitError.failed(command: "stage", status: -1, stderr: "the staging would hold more than \(cap) descriptors")
            }
            switch verdict(c) {
            case .file(let fd, _, _): close(fd)
            case .refuse(let problem), .keptGitlink(_, let problem): counted.append(problem)
            case .remove, .link, .gitlink: break
            }
        }
        if counted.count > limit {
            staging.problems = counted
            throw GitError.failed(command: "stage", status: -1, stderr: "more than \(limit) files that cannot be committed safely")
        }
        if !candidates.isEmpty {
            try? FileManager.default.createDirectory(at: gitTemp, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            let marks = gitTemp.appending(path: "brahma-marks-\(UUID().uuidString)")
            defer { _ = try? EngineFiles.removeNoFollow(marks, under: gitTemp) }
            // One file at a time (NB1): opened, checked, fed and closed inside the feeder, so the engine holds one checked
            // descriptor however many files the agent made.
            try git.run(["fast-import", "--quiet", "--done", "--export-marks=\(marks.path)"], stdin: .stream { pipe in
                var buffer = [UInt8](repeating: 0, count: 256 * 1024)
                func blob(_ count: Int64, _ feed: () throws -> Void) throws -> Int {
                    staging.marks += 1
                    try pipe.write(Data("blob\nmark :\(staging.marks)\ndata \(count)\n".utf8))
                    try feed()
                    try pipe.write(Data("\n".utf8))
                    return staging.marks
                }
                for c in candidates {
                    if !c.isDirectory {
                        guard staging.open < cap else {
                            throw GitError.failed(command: "stage", status: -1, stderr: "the staging would hold more than \(cap) descriptors")
                        }
                    }
                    switch verdict(c) {
                    case .remove:
                        staging.entries.append(Entry(mode: "0", path: c.bytes))
                    case .gitlink(let id):
                        staging.entries.append(Entry(mode: "160000", id: id, path: c.bytes))
                    case .keptGitlink(let id, let problem):
                        staging.entries.append(Entry(mode: "160000", id: id, path: c.bytes))
                        staging.problems.append(problem)
                    case .file(let fd, let size, let executable):
                        staging.open += 1
                        defer { close(fd); staging.open -= 1 }
                        let mark = try blob(size) {
                            var left = size
                            while left > 0 {
                                let got = Foundation.read(fd, &buffer, Int(min(Int64(buffer.count), left)))
                                if got < 0 { if errno == EINTR { continue }; throw GitError.failed(command: "fast-import", status: -1, stderr: "\(c.shown) cannot be read") }
                                if got == 0 { throw GitError.failed(command: "fast-import", status: -1, stderr: "\(c.shown) changed while it was being committed") }
                                try buffer.withUnsafeBytes { try pipe.write(UnsafeRawBufferPointer(rebasing: $0[0..<got])) }
                                left -= Int64(got)
                            }
                        }
                        staging.entries.append(Entry(mode: executable ? "100755" : "100644", mark: mark, path: c.bytes))
                    case .link(let target):
                        let mark = try blob(Int64(target.count)) { try pipe.write(Data(target)) }
                        staging.entries.append(Entry(mode: "120000", mark: mark, path: c.bytes))
                    case .refuse(let problem):
                        staging.problems.append(problem)
                    }
                }
                try pipe.write(Data("done\n".utf8))
            })
            if staging.marks > 0 {
                guard let exported = EngineFiles.readNoFollow(marks, under: gitTemp, limit: planBarrierOutputLimit) else {
                    throw GitError.failed(command: "fast-import", status: -1, stderr: "the marks file cannot be read")
                }
                for line in String(decoding: exported, as: UTF8.self).split(separator: "\n") {
                    let fields = line.split(separator: " ")
                    guard fields.count == 2, fields[0].hasPrefix(":"), let mark = Int(fields[0].dropFirst()) else { continue }
                    let id = String(fields[1])
                    guard id.count == 40 || id.count == 64, id.allSatisfy({ $0.isHexDigit }) else { continue }
                    ids[mark] = id
                }
                guard ids.count == staging.marks else {
                    throw GitError.failed(command: "fast-import", status: -1, stderr: "\(staging.marks - ids.count) blobs were not written")
                }
            }
        }
        // Taken again: the tree can change between the count and the feed.
        guard staging.problems.count <= limit else {
            throw GitError.failed(command: "stage", status: -1, stderr: "more than \(limit) files that cannot be committed safely")
        }
        let entries = staging.entries
        if entries.isEmpty { return }
        let zero: String
        if let any = ids.values.first { zero = String(repeating: "0", count: any.count) }
        else if let any = entries.compactMap(\.id).first { zero = String(repeating: "0", count: any.count) }
        else { zero = String(repeating: "0", count: try git.run(["rev-parse", "--show-object-format"]).text == "sha256" ? 64 : 40) }
        var info = Data()
        for entry in entries {
            guard let first = entry.path.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: true).first,
                  !Self.isEngineName(Array(first)), Self.foldedName(Array(first)) != ".git" else {
                throw GitError.failed(command: "stage", status: -1, stderr: "an index entry names a reserved directory")
            }
            let id = entry.mode == "0" ? zero : (entry.id ?? ids[entry.mark ?? 0] ?? zero)
            info.append(contentsOf: "\(entry.mode) \(id)\t".utf8)
            info.append(contentsOf: entry.path)
            info.append(0)
        }
        try git.run(["update-index", "-z", "--index-info"], stdin: .data(info))
    }

    /// Why a symbolic link at `from` (the directory parts of its path inside the checkout) with `target` is not stored, or
    /// nil when it is (S11.1 / NB3): no empty target, no NUL, no `..` part anywhere; an absolute target, with its `.` parts
    /// dropped, must be one of `roots` or under one; and every directory the target passes through inside the checkout must
    /// be a real directory (checked through descriptors against `top`), never itself a link.
    static func linkProblem(target: [UInt8], from: ArraySlice<[UInt8]>, top: EngineFiles.OpenDirectory, roots: Set<String>) -> String? {
        guard !target.isEmpty, !target.contains(0) else { return "has an empty or odd target" }
        let parts = target.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: true).filter { $0 != [0x2e] }.map(Array.init)
        if parts.contains([0x2e, 0x2e]) { return "has a `..` part in its target" }
        var way: [[UInt8]]
        if target.first == UInt8(ascii: "/") {
            guard String(bytes: target, encoding: .utf8) != nil else { return "has a target that is not UTF-8" }
            let normalized = "/" + parts.map { String(decoding: $0, as: UTF8.self) }.joined(separator: "/")
            guard let root = roots.first(where: { normalized == $0 || normalized.hasPrefix($0 + "/") }) else { return "points outside the checkout" }
            way = normalized.dropFirst(root.count).split(separator: "/", omittingEmptySubsequences: true).map { Array(String($0).utf8) }
        } else {
            // A target of only `.` parts names the link's own directory, which `staged` has already walked.
            if parts.isEmpty { return nil }
            way = Array(from) + parts
        }
        // The last part is the target's own name; only the directories before it are walked.
        guard !way.isEmpty else { return nil }
        way.removeLast()
        return EngineFiles.wayKind(in: top, relative: way) == .blocked ? "passes through a symbolic link" : nil
    }

    /// The commit a nested repository's `HEAD` names, read through descriptors (`.git/HEAD`, then the loose ref it points at,
    /// else `packed-refs`); never a git run inside it. Throws `UnsafeEngineFile` when it cannot be read or resolved.
    private func gitlinkHead(_ top: EngineFiles.OpenDirectory, _ parts: [[UInt8]], shown: String) throws -> String {
        let gitParts = parts + [Array(".git".utf8)]
        func read(_ more: [String], _ what: String) throws -> String {
            let path = gitParts + more.map { Array($0.utf8) }
            guard let data = try EngineFiles.readStaged(in: top, relative: path, limit: Self.gitlinkReadLimit, shown: "\(shown)/.git/\(more.joined(separator: "/"))") else {
                throw UnsafeEngineFile(path: shown, problem: "\(what) is missing")
            }
            return String(decoding: data, as: UTF8.self)
        }
        func commit(_ text: String) -> String? {
            let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
            return (t.count == 40 || t.count == 64) && t.allSatisfy(\.isHexDigit) ? t : nil
        }
        let head = try read(["HEAD"], "HEAD").trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = commit(head) { return id }
        guard head.hasPrefix("ref: ") else { throw UnsafeEngineFile(path: shown, problem: "HEAD is neither a commit nor a ref") }
        let ref = String(head.dropFirst("ref: ".count))
        let refParts = ref.split(separator: "/").map(String.init)
        guard !refParts.isEmpty, refParts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." }),
              ref.unicodeScalars.allSatisfy({ CharacterSet.alphanumerics.contains($0) || "/_.-".unicodeScalars.contains($0) }) else {
            throw UnsafeEngineFile(path: shown, problem: "HEAD names an odd ref")
        }
        if let loose = try? read(refParts, ref), let id = commit(loose) { return id }
        if let packed = try? read(["packed-refs"], "packed-refs") {
            for line in packed.split(separator: "\n") where line.hasSuffix(" " + ref) {
                if let id = commit(String(line.dropLast(ref.count + 1))) { return id }
            }
        }
        throw UnsafeEngineFile(path: shown, problem: "\(ref) cannot be resolved")
    }

    /// The commit a checkout's branch points at (for an item worktree: `refs/heads/item/<KEY>`, never `HEAD`).
    public func headCommit(in dir: URL) throws -> String {
        let (git, key) = try resolve(dir)
        guard let key else { return try git.run(["rev-parse", "HEAD"]).text }
        return try git.run(["rev-parse", "--verify", "\(branchRef(key: key))^{commit}"]).text
    }

    /// The commit the item ref itself holds, read without following it: a ref that is symbolic now is refused (it was a
    /// plain ref at the worktree check, so it changed meanwhile), and nil when there is no such ref.
    private func ownTip(_ git: GitCommand, _ ref: String) throws -> String? {
        let out = try git.run(["for-each-ref", "--format=%(refname)%00%(symref)%00%(objectname)%00%(objecttype)", ref])
        for line in out.text.split(separator: "\n") {
            let parts = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 4, parts[0] == ref else { continue }
            guard parts[1].isEmpty else {
                throw GitError.failed(command: "update-ref \(ref)", status: -1, stderr: "\(ref) is a symbolic ref to \(Self.shown(parts[1]))")
            }
            guard parts[3] == "commit" else { throw GitError.failed(command: "update-ref \(ref)", status: -1, stderr: "\(ref) is not a commit") }
            try Self.validCommit(parts[2])
            return parts[2]
        }
        return nil
    }

    /// Puts the checkout back on `commit` and removes everything untracked (the write barrier of a plan turn). In an item
    /// worktree the branch is moved with a compare-and-swap and the index and files are reset with `read-tree`; `HEAD` is
    /// neither read nor written.
    public func resetHard(in dir: URL, to commit: String) throws {
        try Self.validCommit(commit)
        let (git, key) = try resolve(dir)
        guard let key else {
            try git.run(["reset", "--hard", "--quiet", "--no-recurse-submodules", commit])
            try git.run(["clean", "-fdq"])
            return
        }
        let ref = branchRef(key: key)
        testHook?("checked")
        guard let current = try ownTip(git, ref) else {
            throw GitError.failed(command: "reset \(key)", status: -1, stderr: "\(ref) does not exist")
        }
        try git.run(["read-tree", "--reset", "-u", "--no-recurse-submodules", commit])
        if current != commit { try git.run(["update-ref", "--no-deref", ref, commit, current]) }
        try git.run(["clean", "-fdq"])
        try verifyAfter(key: key)
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
        /// Every `refs/heads/item/*` branch there was (the engine's; they are not compared, but no new one may appear).
        var itemBranches: Set<String>
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
        let (refs, itemBranches) = try refList(git, key: key)
        let index = try barrierRun(git, ["ls-files", "-s", "-v", "-z"])
        let captured = repoFiles(key: key)
        if let over = captured.oversize.first {
            throw GitError.failed(command: "barrier", status: -1, stderr: "repository file \(Self.shown(over)) is larger than \(Self.repoFileLimit) bytes")
        }
        if let over = captured.overflow.first {
            throw GitError.failed(command: "barrier", status: -1, stderr: "more than \(Self.repoEntryLimit) repository files (at \(Self.shown(over)))")
        }
        return PlanBarrier(ignored: ignored, files: captured.files, refs: refs, itemBranches: itemBranches, index: index)
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

        // The repository's own files. New ones go first, deepest first, so a directory or link put in place of a file goes too.
        // Files over the size cap and entries over the count cap are not read: new ones are deleted, and either fails the check.
        let indexKey = "worktrees/\(key)/index"
        let captured = repoFiles(key: key)
        let after = captured.files
        func known(_ rel: String) -> Bool { before.files[rel] != nil || before.files.keys.contains { $0.hasPrefix(rel + "/") } }
        func put(_ rel: String, _ file: RepoFile) {
            do { try Self.restore(file, at: gitDir.appending(path: rel), under: root) } catch { failures.append("restore \(Self.shown(rel)): \(error)") }
        }
        // Through descriptors from the workspace: a link is removed, never followed; a part of the way that is a link fails
        // the check (nothing is removed through it).
        func removeNew(_ rel: String) {
            do {
                if case .blocked(let problem) = try EngineFiles.removeNoFollow(gitDir.appending(path: rel), under: root) {
                    failures.append("remove \(Self.shown(rel)): \(problem)")
                }
            } catch { failures.append("remove \(Self.shown(rel)): \(error)") }
        }
        for rel in captured.oversize.sorted() {
            failures.append("repository file \(Self.shown(rel)) is larger than \(Self.repoFileLimit) bytes")
            if let file = before.files[rel] { found.append("changed \(Self.shown(rel))"); put(rel, file) }
            else { found.append("new \(Self.shown(rel))"); removeNew(rel) }
        }
        for rel in captured.overflow.sorted() {
            failures.append("more than \(Self.repoEntryLimit) repository files (at \(Self.shown(rel)))")
            if !known(rel) { found.append("new \(Self.shown(rel))"); removeNew(rel) }
        }
        for rel in after.keys.filter({ before.files[$0] == nil }).sorted(by: { $0.count > $1.count }) {
            found.append("new \(Self.shown(rel))")
            removeNew(rel)
        }
        for (rel, file) in before.files.sorted(by: { $0.key < $1.key }) where rel != indexKey && after[rel] != file && !captured.oversize.contains(rel) {
            found.append(after[rel] == nil ? "removed \(rel)" : "changed \(rel)")
            put(rel, file)
        }

        // The index, by what it says.
        do {
            if try barrierRun(git, ["ls-files", "-s", "-v", "-z"]) != before.index {
                found.append("changed index")
                if let file = before.files[indexKey] { put(indexKey, file) }
            }
        } catch {
            failures.append("index: \(error)")
            if let file = before.files[indexKey] { put(indexKey, file) }
        }

        // Every ref (loose or packed) but the engine-managed ones.
        do {
            let (now, nowBranches) = try refList(git, key: key)
            for (ref, value) in before.refs.sorted(by: { $0.key < $1.key }) where now[ref] != value {
                found.append(now[ref] == nil ? "removed ref \(ref)" : "moved ref \(ref)")
                if value.symref.isEmpty { try git.run(["update-ref", "--no-deref", ref, value.oid]) }
                else { try git.run(["symbolic-ref", ref, value.symref]) }
            }
            for ref in now.keys.sorted() where before.refs[ref] == nil {
                found.append("new ref \(Self.shown(ref))")
                try git.run(["update-ref", "--no-deref", "-d", ref])
            }
            // An item branch that did not exist is planted: the engine would later claim that item onto whatever it holds.
            // Unless the engine made it: a claim during the turn creates `item/<K>` with a lease and a worktree. That is checked
            // again under the key's lock, which a claim in progress holds.
            for ref in nowBranches.subtracting(before.itemBranches).sorted() {
                let itemKey = String(ref.dropFirst("refs/heads/item/".count))
                let planted: Bool
                if (try? Self.validKey(itemKey)) == nil { planted = true }
                else { planted = try withKeyLock(itemKey) { try !engineRecords(key: itemKey) } }
                guard planted else { continue }
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

    /// The engine has a record of this item: a lease, or a worktree it created (registered, `HEAD` on the item's branch).
    private func engineRecords(key: String) throws -> Bool {
        if try hasLease?(key) == true { return true }
        return hasCheckout(key: key) && linkProblems(key: key).isEmpty
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
        let tokens = try barrierRun(git, ["status", "--porcelain=v1", "-z", "--ignored", "-uall", "--ignore-submodules=dirty"]).split(separator: 0, omittingEmptySubsequences: true)
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
            let stamp = Self.stamp(root + [UInt8(ascii: "/")] + Array(rel))
            // A directory entry (a nested repository, say) stands for contents the stamp cannot vouch for.
            if rel.last == UInt8(ascii: "/") || stamp.mode & UInt16(S_IFMT) == UInt16(S_IFDIR) {
                throw GitError.failed(command: "status", status: -1, stderr: "cannot verify ignored directory \(Self.shown(rel))")
            }
            ignored[rel] = stamp
        }
        return ignored
    }

    /// Every ref but the engine-managed ones, which the engine and other leaseholders move while this turn runs and which
    /// the barrier must never put back: `main` (protected by the exact main guard, `checkMain`), `refs/brahma/*` (the
    /// engine's quarantine refs) and other items' branches. This item's branch, tags and everything else are covered.
    static func engineManaged(_ ref: String, ownBranch: String) -> Bool {
        ref == mainRef || ref.hasPrefix("refs/brahma/") || (ref.hasPrefix("refs/heads/item/") && ref != ownBranch)
    }

    private func refList(_ git: GitCommand, key: String) throws -> (refs: [String: RefValue], itemBranches: Set<String>) {
        let own = branchRef(key: key)
        let data = try barrierRun(git, ["for-each-ref", "--format=%(refname)%00%(objectname)%00%(symref)"])
        var refs: [String: RefValue] = [:]
        var itemBranches: Set<String> = []
        for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
            let parts = line.split(separator: "\0", omittingEmptySubsequences: false).map(String.init)
            guard parts.count == 3, parts[0].hasPrefix("refs/") else {
                throw GitError.failed(command: "for-each-ref", status: -1, stderr: "unexpected line")
            }
            try Self.validRef(parts[0])
            if parts[2].isEmpty { try Self.validCommit(parts[1]) } else { try Self.validRef(parts[2]) }
            if parts[0].hasPrefix("refs/heads/item/") { itemBranches.insert(parts[0]) }
            if Self.engineManaged(parts[0], ownBranch: own) { continue }
            refs[parts[0]] = RefValue(oid: parts[1], symref: parts[2])
        }
        return (refs, itemBranches)
    }

    /// What the barrier reads of the repository's own files. A regular file over `repoFileLimit` is named in `oversize` and
    /// never read; a directory that would take a root past `repoEntryLimit` entries is named in `overflow` and never read.
    struct RepoCapture { var files: [String: RepoFile] = [:]; var oversize: [String] = []; var overflow: [String] = []; var seen = 0 }
    static let repoFileLimit = 1 << 20
    /// The worktree's own index (compared by what `ls-files` says, but snapshotted to be put back) has its own cap: a
    /// repository of ten thousand files passes 1 MB.
    static let indexFileLimit = 256 << 20
    static let repoEntryLimit = 500

    private func repoFiles(key: String) -> RepoCapture {
        var capture = RepoCapture()
        // Each root has its own budget, so a pile planted in one cannot hide what is in another.
        for rel in Self.barrierPaths + ["worktrees/\(key)"] { capture.seen = 0; Self.capture(gitDir, rel, into: &capture) }
        return capture
    }

    /// Up to `limit + 1` names of a directory, so a directory of millions of entries is never listed whole.
    private static func names(of path: String, limit: Int) -> [String] {
        guard let dir = opendir(path) else { return [] }
        defer { closedir(dir) }
        var out: [String] = []
        while out.count <= limit, let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) { $0.withMemoryRebound(to: CChar.self, capacity: Int(NAME_MAX) + 1) { String(cString: $0) } }
            if name != "." && name != ".." { out.append(name) }
        }
        return out
    }

    private static func capture(_ base: URL, _ rel: String, into capture: inout RepoCapture) {
        let url = base.appending(path: rel)
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return }
        let mode = UInt16(st.st_mode & 0o7777)
        if st.st_mode & S_IFMT == S_IFDIR {
            // A directory that would take the root over its budget is named whole and not read.
            let listed = names(of: url.path, limit: repoEntryLimit)
            guard capture.seen + listed.count <= repoEntryLimit else { capture.overflow.append(rel); return }
            for name in listed.sorted() { Self.capture(base, rel + "/" + name, into: &capture) }
            return
        }
        guard capture.seen < repoEntryLimit else { capture.overflow.append(rel); return }
        capture.seen += 1
        switch st.st_mode & S_IFMT {
        case S_IFREG:
            let limit = rel.hasPrefix("worktrees/") && rel.hasSuffix("/index") && rel.split(separator: "/").count == 3 ? indexFileLimit : repoFileLimit
            if st.st_size > limit { capture.oversize.append(rel); return }
            capture.files[rel] = RepoFile(data: FileManager.default.contents(atPath: url.path) ?? Data(), mode: mode, link: nil)
        case S_IFLNK: capture.files[rel] = RepoFile(data: nil, mode: mode, link: (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? "")
        default: capture.files[rel] = RepoFile(data: nil, mode: mode, link: "special")
        }
    }

    /// Puts one repository file back as it was, permission bits included (an executable hook stays executable).
    private static func restore(_ file: RepoFile, at url: URL, under root: URL) throws {
        let fm = FileManager.default
        var st = stat()
        if lstat(url.path, &st) == 0, st.st_mode & S_IFMT != S_IFREG || file.data == nil {
            if case .blocked(let problem) = try EngineFiles.removeNoFollow(url, under: root) { throw problem }
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let link = file.link {
            if link != "special" { try fm.createSymbolicLink(atPath: url.path, withDestinationPath: link) }
            return
        }
        try (file.data ?? Data()).write(to: url, options: .atomic)
        guard chmod(url.path, mode_t(file.mode)) == 0 else {
            throw GitError.failed(command: "chmod", status: errno, stderr: "cannot set the permissions of \(url.lastPathComponent)")
        }
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
        return real == nil ? nil : String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
    }

    /// Every directory on the way is opened from the checkout's own descriptor without following a link
    /// (`EngineFiles.removeNoFollow`), so a part that is a link (or swapped for one meanwhile) is never followed.
    private static func removeInside(dir: URL, base: String?, relative: Data) {
        let parts = relative.split(separator: UInt8(ascii: "/"), omittingEmptySubsequences: true)
        guard relative.first != UInt8(ascii: "/"), !parts.isEmpty, !parts.contains(where: { Data($0) == Data("..".utf8) }),
              let base else { return }
        _ = try? EngineFiles.removeNoFollow(relative: Array(relative), under: URL(fileURLWithPath: base, isDirectory: true))
    }

    /// A path for a message: as is when it is plain, else quoted with escapes (no newline or quote reaches a message raw).
    static func shown(_ path: Data) -> String { shown(String(decoding: path, as: UTF8.self)) }
    static func shown(_ path: String) -> String {
        path.unicodeScalars.contains { $0.value < 0x20 || $0.value == 0x7f || $0 == "\"" || $0 == "\\" } ? path.debugDescription : path
    }

    public func isDirty(in dir: URL) throws -> Bool {
        // The engine's own directory is never "uncommitted work", whatever the agent-writable `info/exclude` says.
        !(try context(for: dir).run(["status", "--porcelain", "--ignore-submodules=dirty", "--", ".", ":(exclude).brahma"]).text.isEmpty)
    }

    /// The commit `ref` points at, or nil when there is no such ref.
    public func head(of ref: String) throws -> String? {
        try Self.validRef(ref)
        let out = try main.run(["rev-parse", "--verify", "--quiet", "\(ref)^{commit}"], allowFailure: true)
        return out.status == 0 && !out.text.isEmpty ? out.text : nil
    }

    // MARK: Backups

    /// Every ref and the object it names (`for-each-ref`), one `<id> <ref>` per line: what a backup bundle holds, so an equal
    /// listing means an equal bundle.
    public func refListing() throws -> String {
        try main.run(["for-each-ref", "--format=%(objectname) %(refname)"]).text
    }

    /// `git bundle create <file> --all`. False when the repository has nothing to bundle (no refs yet).
    @discardableResult
    public func createBundle(at file: URL) throws -> Bool {
        let out = try main.run(["bundle", "create", file.path, "--all"], allowFailure: true)
        if out.status == 0 { return true }
        if out.stderr.contains("empty bundle") { return false }
        throw GitError.failed(command: "bundle create", status: out.status, stderr: String(out.stderr.prefix(2000)))
    }

    /// `git bundle verify <file>` against this repository (throws when the bundle is damaged or needs missing history).
    public func verifyBundle(at file: URL) throws {
        try main.run(["bundle", "verify", file.path])
    }

    /// How many commits `to` has that `from` does not; nil when either is unknown here.
    public func commitCount(from: String, to: String) throws -> Int? {
        try Self.validRef(from); try Self.validRef(to)
        let out = try main.run(["rev-list", "--count", "\(from)..\(to)"], allowFailure: true)
        return out.status == 0 ? Int(out.text) : nil
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

    /// The engine's backup ref (Plan L): before each deploy it names the release commit, "the last known-good main".
    public static let mainBackupRef = "refs/brahma/main-backup"

    /// `refs/brahma/releases/<version>` (PR-29: an engine-managed namespace the plan barrier leaves alone, never a
    /// `refs/tags/release/*` tag). Throws for a version that cannot be one ref component.
    public static func releaseRef(version: String) throws -> String {
        guard isValidReleaseVersion(version) else {
            throw GitError.failed(command: "release ref", status: -1, stderr: "invalid release version")
        }
        return "refs/brahma/releases/\(version)"
    }

    /// A release version that is one valid ref component under `refs/brahma/releases/` (`ReleasePolicy.validVersion` applies
    /// this same rule at propose time, final-review m3): `^[0-9A-Za-z][0-9A-Za-z.+-]{0,31}$`, no `..`, no trailing `.`, no
    /// `.lock` suffix in any case. Pure: runs no git.
    public static func isValidReleaseVersion(_ version: String) -> Bool {
        version.range(of: "^[0-9A-Za-z][0-9A-Za-z.+-]{0,31}$", options: .regularExpression) != nil
            && !version.contains("..") && !version.hasSuffix(".") && !version.lowercased().hasSuffix(".lock")
    }

    /// Before a deploy (Plan L Task 7): `update-ref refs/brahma/main-backup <commit>`, then `refs/brahma/releases/<version>`
    /// = `commit`, created only when absent (`update-ref <ref> <commit> ""`). Already there at `commit`: kept (returns false).
    /// There at another commit: throws, nothing is moved (a release ref is never rewritten). Both refs are written in the
    /// workspace's repository through the hardened `GitCommand`, from engine records only (never a build's `.git`).
    @discardableResult
    public func writeReleaseRefs(version: String, commit: String) throws -> Bool {
        try Self.validCommit(commit)
        let release = try Self.releaseRef(version: version)
        let existing = try main.run(["rev-parse", "--verify", "--quiet", "\(release)^{commit}"], allowFailure: true)
        let full = try main.run(["rev-parse", "--verify", "\(commit)^{commit}"]).text
        if existing.status == 0 {
            guard existing.text == full else {
                throw GitError.failed(command: "update-ref", status: -1, stderr: "\(release) already names another commit")
            }
        }
        try main.run(["update-ref", "-m", "brahma: release \(version)", Self.mainBackupRef, full])
        if existing.status == 0 { return false }
        try main.run(["update-ref", "-m", "brahma: release \(version)", release, full, ""])
        return true
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

    /// The whole patch between two commits for the leak scan (`SecretScan.check`): no context lines, no rename detection (a
    /// renamed file's lines are added lines), up to git's capture limit (`cut` says there was more). Through `GitCommand`
    /// like every engine call: the git dir comes from the engine's records, never from a worktree's `.git` file.
    func scanDiff(base: String, head: String) throws -> (text: String, cut: Bool, limitMB: Int) {
        try Self.validRef(base); try Self.validRef(head)
        // `--text`: every file is shown as text, whatever a `.gitattributes` says or a NUL byte suggests; the engine's forced
        // `-diff` attribute (which would make every file "binary") is overridden too. What git still cannot show as text is a
        // fail-closed finding (`SecretScan.findings`).
        let out = try main.run(["diff", "--text", "--no-ext-diff", "--no-textconv", "--no-color", "--no-renames", "-U0", base, head])
        return (String(decoding: out.stdout, as: UTF8.self), out.cut, GitCommand.maxCapture >> 20)
    }

    /// Every commit in `base..head` with its patch (merges against each parent, `--cc`), for the leak scan: each commit's
    /// hash on a `commit <hash>` line, then its diff in the same form as `scanDiff`.
    func scanLog(base: String, head: String) throws -> (text: String, cut: Bool) {
        try Self.validRef(base); try Self.validRef(head)
        let out = try main.run(["log", "--format=commit %H", "--encoding=none", "--no-decorate", "-p", "-U0", "--text", "--no-ext-diff", "--no-textconv", "--no-color",
                                "--no-renames", "--cc", "--no-show-signature", "\(base)..\(head)"])
        return (String(decoding: out.stdout, as: UTF8.self), out.cut)
    }

    /// Every commit object in `base..head` as stored (`--pretty=raw`: every header, extra ones included, and the message),
    /// for the leak scan (`SecretScan.messageFindings`): each record starts with a `commit <hash>` line. Bounded by the
    /// capture limit like the other scans (`cut` fails closed).
    func scanMessages(base: String, head: String) throws -> (text: String, cut: Bool) {
        try Self.validRef(base); try Self.validRef(head)
        // `--encoding=none`: the bytes as stored, never re-encoded from a commit's `encoding` header (an IBM037 or UTF-16
        // header would turn the record into text no pattern matches; 4-wire fix round 4, B2). `--no-decorate`: a
        // `log.decorate` setting cannot change the `commit <hash>` lines.
        let out = try main.run(["log", "--pretty=raw", "--encoding=none", "--no-decorate", "--no-color", "--no-show-signature",
                                "--no-abbrev", "\(base)..\(head)"])
        return (String(decoding: out.stdout, as: UTF8.self), out.cut)
    }

    /// The empty tree of this repository (its hash algorithm's), the base of a scan for a branch with no common history.
    func emptyTree() throws -> String {
        try main.run(["hash-object", "-t", "tree", "/dev/null"]).text
    }

    /// Whether `commit`'s tree has a directory (a tree entry, not a link or a submodule) at `path`, read from the object
    /// database; nothing is read from a working tree. Plan L decides from it whether a Pages deploy stages `functions/`
    /// (PR-24), so the plan is the same at propose time and when the executor renders it again.
    public func treeHasDirectory(at commit: String, path: String) throws -> Bool {
        try Self.validCommit(commit)
        guard !path.isEmpty, !path.hasPrefix(":"), !path.hasPrefix("-"), !path.hasPrefix("/"), !path.hasSuffix("/") else { return false }
        let listing = try main.run(["--literal-pathspecs", "ls-tree", "-z", "--full-tree", commit, "--", path],
                                   allowFailure: true, maxOutput: 1 << 16)
        guard listing.status == 0 else { return false }
        for entry in String(decoding: listing.stdout, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: true) {
            let halves = entry.split(separator: "\t", maxSplits: 1, omittingEmptySubsequences: false)
            guard halves.count == 2, String(halves[1]) == path else { continue }
            let meta = halves[0].split(separator: " ")
            if meta.count == 3, meta[0] == "040000", meta[1] == "tree" { return true }
        }
        return false
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

    /// The change between two commits as risk-tiered review measures it (no renames: a rename is a delete and an add, so both
    /// names are listed). Three listings of the same diff: `--raw` (paths, modes, deletions), `--numstat` (lines, binaries) and
    /// the zero-context patch (bytes). Any listing cut short sets `truncated`, which makes the change unmeasurable.
    public func changeStats(base: String, head: String) throws -> ChangeStats {
        try Self.validRef(base); try Self.validRef(head)
        let common = ["--no-renames", "--no-ext-diff", "--no-textconv", "--no-color", "--ignore-submodules=none"]
        var stats = ChangeStats()

        let raw = try main.run(["diff", "--raw", "-z", "--no-abbrev"] + common + [base, head], maxOutput: 1 << 20)
        stats.truncated = stats.truncated || raw.cut
        let fields = String(decoding: raw.stdout, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: true)
        var i = 0
        while i < fields.count {
            let meta = fields[i].split(separator: " ")
            guard fields[i].hasPrefix(":"), meta.count == 5, i + 1 < fields.count else { stats.truncated = true; break }
            let (old, new, status) = (String(meta[0].dropFirst()), String(meta[1]), String(meta[4]))
            stats.paths.append(String(fields[i + 1]))
            if status.hasPrefix("D") || new == "000000" { stats.deleted = true }
            // Only plain files may change: no executable bit, symlink or submodule on either side.
            if ![old, new].allSatisfy({ $0 == "100644" || $0 == "000000" }) { stats.specialMode = true }
            i += 2
        }

        let numstat = try main.run(["diff", "--numstat", "-z"] + common + [base, head], maxOutput: 1 << 20)
        stats.truncated = stats.truncated || numstat.cut
        for record in String(decoding: numstat.stdout, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: true) {
            let f = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard f.count == 3 else { stats.truncated = true; break }
            if let added = Int(f[0]), let deleted = Int(f[1]) { stats.lines += added + deleted } else { stats.binary = true }
        }

        // Bytes: every added or deleted line's content (its newline included), read only inside hunks, so a header line can
        // never be counted and a content line can never start a header (it begins with +, -, space or \).
        let patch = try main.run(["diff", "--unified=0", "--no-prefix"] + common + [base, head], maxOutput: Self.statsPatchLimit)
        if patch.cut { stats.bytes = Int.max } else {
            var inHunk = false
            for line in patch.stdout.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
                if line.starts(with: Array("diff --git ".utf8)) { inHunk = false; continue }
                if line.starts(with: Array("@@".utf8)) { inHunk = true; continue }
                guard inHunk, let first = line.first else { continue }
                if first == UInt8(ascii: "+") || first == UInt8(ascii: "-") { stats.bytes += line.count }
            }
        }
        return stats
    }

    /// Patch output read for `changeStats` byte counting; anything longer is far over any cap.
    static let statsPatchLimit = 1 << 18

    /// `"<short sha> <subject>"` for the newest `limit` commits in `base..head`.
    public func log(base: String, head: String, limit: Int = 5) throws -> [String] {
        try Self.validRef(base); try Self.validRef(head)
        let out = try main.run(["log", "--no-color", "--no-show-signature", "--format=%h %s", "-n", String(max(limit, 1)), "\(base)..\(head)"])
        return out.text.split(separator: "\n").map(String.init)
    }
}

/// What `GitWorkspace.changeStats` measured.
public struct ChangeStats: Sendable, Equatable {
    /// Added plus deleted lines over all text files.
    public var lines = 0
    /// Bytes of the added and deleted lines (newlines included).
    public var bytes = 0
    /// Every path touched, old and new names of a rename both listed.
    public var paths: [String] = []
    public var binary = false
    /// A file was deleted (or renamed away).
    public var deleted = false
    /// A changed path is (or was) an executable, a symlink or a submodule.
    public var specialMode = false
    /// A listing could not be read in full.
    public var truncated = false

    public init() {}
}

// MARK: Standalone repositories

extension GitWorkspace {
    /// Makes `dir` its own repository on `main` (`git init --quiet --template= -b main` through `GitCommand`): an agent's lab
    /// (`SandboxLayout.ensure`). No template, so no sample hooks. The caller has walked `dir` as a real directory and checked
    /// that `dir/.git` does not exist yet. Blocking.
    static func initStandaloneRepository(at dir: URL) throws {
        var git = GitCommand(gitDir: dir.appending(path: ".git", directoryHint: .isDirectory), workTree: dir, commonDir: nil)
        // Its captured output goes inside the new repo's own `.git`, never the shared per-user temp dir (A-I1b).
        git.tempRoot = dir.appending(path: ".git/brahma-tmp", directoryHint: .isDirectory)
        try git.run(["init", "--quiet", "--template=", "-b", "main"])
    }

    /// Lab provenance (Task 10, fix round 1 I3): every commit object in the repository's object store (loose and packed,
    /// reachable from any ref or from none: a tag, a note, a detached HEAD or a bare `commit-tree` included), at most `limit`.
    /// The repository is this workspace's root (an agent's lab), read through `GitCommand` (its config scanned, programs off).
    /// Blocking.
    /// A listing that did not cover every object (git's output cut, or `limit` commits reached) throws: recording part of it
    /// could later record a buried tainted commit as clean (fix round 2, I3-a).
    public func labCommits(limit: Int = 100_000, maxOutput: Int = 16 << 20) throws -> [String] {
        let out = try main.run(["cat-file", "--batch-all-objects", "--unordered", "--batch-check=%(objectname) %(objecttype)"],
                               maxOutput: maxOutput)
        guard !out.cut else {
            throw GitError.failed(command: "cat-file --batch-all-objects", status: -1, stderr: "the object listing was cut at \(maxOutput) bytes")
        }
        var shas: [String] = []
        for line in out.text.split(separator: "\n") {
            let parts = line.split(separator: " ")
            guard parts.count == 2, parts[1] == "commit" else { continue }
            shas.append(String(parts[0]))
            guard shas.count < limit else {
                throw GitError.failed(command: "cat-file --batch-all-objects", status: -1, stderr: "more than \(limit) commits")
            }
        }
        return shas
    }

    // MARK: Lab proposals (Task 10b)

    /// A folder path inside a lab as `propose_extension` takes it: 1–8 components of `[A-Za-z0-9][A-Za-z0-9._-]*` (at most 64
    /// characters each), none `.git`. No pathspec magic, no `..`, nothing git or a shell could read two ways.
    public static func isLabFolderPath(_ path: String) -> Bool {
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard (1...8).contains(parts.count) else { return false }
        return parts.allSatisfy { p in
            p.range(of: "^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$", options: .regularExpression) != nil && p.lowercased() != ".git"
                && !p.hasSuffix(".") && !p.contains("..")
        }
    }

    /// The lab's `HEAD` commit, or nil when it has none yet. The repository is this workspace's root (an agent's lab), read
    /// through `GitCommand` (its config scanned, programs off). Blocking.
    public func labHead() throws -> String? {
        let out = try main.run(["rev-parse", "--verify", "--quiet", "HEAD^{commit}"], allowFailure: true)
        guard out.status == 0, !out.text.isEmpty else { return nil }
        try Self.validCommit(out.text)
        return out.text
    }

    /// Every commit reachable from `commit` that touched `path` (full history: no merge side is pruned), newest first. These are
    /// the commits since the folder first appeared whose provenance a proposal reports. A listing that was cut throws. Blocking.
    public func labPathCommits(commit: String, path: String, maxOutput: Int = 4 << 20) throws -> [String] {
        try Self.validCommit(commit)
        guard Self.isLabFolderPath(path) else { throw GitError.failed(command: "rev-list", status: -1, stderr: "invalid lab path") }
        let out = try main.run(["rev-list", "--full-history", commit, "--", path], maxOutput: maxOutput)
        guard !out.cut else { throw GitError.failed(command: "rev-list", status: -1, stderr: "the commit listing was cut at \(maxOutput) bytes") }
        return try out.text.split(separator: "\n").map { line in
            let sha = String(line)
            try Self.validCommit(sha)
            return sha
        }
    }

    /// The empty blob and the empty tree (SHA-1 and SHA-256): they carry no content, so they never decide provenance (M8).
    static let emptyObjectIds: Set<String> = [
        "e69de29bb2d1d6434b8b29ae775ad8c2e48c5391", "4b825dc642cb6eb9a060e54bf8d69288fbee4904",
        "473a0f4c3be8a93681a267e3b1e9a7dcda1185436fe141f7749120a303721813",
        "6ef19b41225c5369f1c104d45d8d85efa9b057b53b14b4b9b939dd74decc5321",
    ]

    /// The object ids of the folder at `<commit>:<path>`: its own tree and every tree and blob below it (S25: the proposal's
    /// provenance is decided by content). A listing that was cut throws. Blocking.
    public func labFolderObjects(commit: String, path: String, maxOutput: Int = 4 << 20) throws -> Set<String> {
        try Self.validCommit(commit)
        guard Self.isLabFolderPath(path) else { throw GitError.failed(command: "ls-tree", status: -1, stderr: "invalid lab path") }
        let tree = try main.run(["rev-parse", "--verify", "--quiet", "\(commit):\(path)"], allowFailure: true)
        let kind = try main.run(["cat-file", "-t", "\(commit):\(path)"], allowFailure: true)
        guard tree.status == 0, kind.status == 0, kind.text == "tree" else {
            throw GitError.failed(command: "ls-tree", status: -1, stderr: "\(path) is not a folder in the lab's last commit")
        }
        let out = try main.run(["ls-tree", "-r", "-t", "-z", "\(commit):\(path)"], maxOutput: maxOutput)
        guard !out.cut else { throw GitError.failed(command: "ls-tree", status: -1, stderr: "the folder listing was cut at \(maxOutput) bytes") }
        var ids: Set<String> = [tree.text]
        for raw in out.stdout.split(separator: 0) {
            let entry = String(decoding: raw, as: UTF8.self)
            let fields = entry.prefix { $0 != "\t" }.split(separator: " ")
            if fields.count == 3 { ids.insert(String(fields[2])) }
        }
        return ids.subtracting(Self.emptyObjectIds)
    }

    /// Per commit, the tree and blob ids it introduced: the new side of its raw diff against each parent (a root commit against
    /// the empty tree), recursing into trees (S25). Renames and copies need no detection here: a moved or copied file keeps its
    /// blob id, so it is matched by content wherever it lands. A merge's diffs against every parent are unioned (more, never
    /// less). Commits go on stdin, never argv. A listing that was cut throws. Blocking.
    public func labIntroducedObjects(commits: [String], maxOutput: Int = 64 << 20) throws -> [String: Set<String>] {
        guard !commits.isEmpty else { return [:] }
        for c in commits { try Self.validCommit(c) }
        let input = Data((commits.joined(separator: "\n") + "\n").utf8)
        let out = try main.run(["log", "--no-walk=unsorted", "--stdin", "--no-color", "--no-show-signature", "--no-renames", "--raw", "-r", "-t",
                                "--root", "-m", "--no-abbrev", "--format=commit %H"], maxOutput: maxOutput, stdin: .data(input))
        guard !out.cut else { throw GitError.failed(command: "log --raw", status: -1, stderr: "the history listing was cut at \(maxOutput) bytes") }
        var result: [String: Set<String>] = [:]
        var current: String?
        for line in out.text.split(separator: "\n") {
            if line.hasPrefix("commit ") { current = String(line.dropFirst(7)); continue }
            guard line.hasPrefix(":"), let current else { continue }
            let fields = line.prefix { $0 != "\t" }.split(separator: " ")
            guard fields.count >= 5 else { continue }
            let dst = String(fields[3])
            guard dst.contains(where: { $0 != "0" }), !Self.emptyObjectIds.contains(dst) else { continue }
            result[current, default: []].insert(dst)
        }
        return result
    }

    /// Writes `<commit>:<path>` (a tree: the folder as committed, nothing uncommitted) as a tar file at `tar` with `git archive`
    /// (the engine's attributes: nothing left out or substituted), then unpacks it into `into` with `untar` (relative names only,
    /// `-k`, from the directory's descriptor). Blocking.
    func labArchive(commit: String, path: String, tar: URL, into: EngineFiles.OpenDirectory) throws {
        try Self.validCommit(commit)
        guard Self.isLabFolderPath(path) else { throw GitError.failed(command: "archive", status: -1, stderr: "invalid lab path") }
        let kind = try main.run(["cat-file", "-t", "\(commit):\(path)"], allowFailure: true)
        guard kind.status == 0, kind.text == "tree" else {
            throw GitError.failed(command: "archive", status: -1, stderr: "\(path) is not a folder in the lab's last commit")
        }
        // The extension limits before anything is written: the file count and the bytes the tree declares (no submodules).
        let listing = try main.run(["ls-tree", "-r", "-l", "-z", "\(commit):\(path)"], allowFailure: true, maxOutput: 1 << 20)
        guard listing.status == 0, !listing.cut else {
            throw GitError.failed(command: "archive", status: -1, stderr: "the folder could not be listed within the limits")
        }
        var files = 0
        var bytes: Int64 = 0
        for raw in listing.stdout.split(separator: 0) {
            let entry = String(decoding: raw, as: UTF8.self)
            let fields = entry.prefix { $0 != "\t" }.split(separator: " ", omittingEmptySubsequences: true)
            guard fields.count == 4 else { continue }
            guard fields[1] == "blob" else {
                throw GitError.failed(command: "archive", status: -1, stderr: "the folder holds a \(fields[1]) entry; only files and folders")
            }
            files += 1
            bytes += Int64(fields[3]) ?? Int64(ExtensionLimits.maxBytes)
            guard files <= ExtensionLimits.maxFiles, bytes <= Int64(ExtensionLimits.maxBytes) else {
                throw GitError.failed(command: "archive", status: -1,
                                      stderr: "the folder is over the extension limits (\(ExtensionLimits.maxFiles) files, \(ExtensionLimits.maxBytes) bytes)")
            }
        }
        let out = try main.run(["archive", "--format=tar", "--output=\(tar.path)", "\(commit):\(path)"], allowFailure: true)
        guard out.status == 0 else { throw GitError.failed(command: "archive", status: out.status, stderr: Self.oneLine(out.stderr)) }
        let fd = open(tar.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw GitError.failed(command: "archive", status: -1, stderr: "could not open the archive") }
        defer { close(fd) }
        try Self.untar(fd, into: into)
    }
}

// MARK: Import (Plan L Task 14)

/// Where an import fetches from (`GitWorkspace.importRepository`).
enum ImportTransport: Sendable {
    /// A local repository: its folder, whose `.git` is a real directory.
    case local(URL)
    /// An https URL (no credentials; `RepoSource.parse`).
    case https(URL)
}

/// What an import left in its new repository.
struct ImportedRepository: Sendable, Equatable {
    /// `refs/heads/main`.
    var head: String
    /// The source's current branch (`HEAD` when it was detached).
    var branch: String
    /// The source's commit at that branch.
    var upstreamHead: String
    /// Only the tip came over (https, or a source that is itself shallow): `main` is one root commit with its tree.
    var shallow: Bool
    /// Commits on `main`.
    var commits: Int
}

/// The import's limits.
struct ImportCaps: Sendable {
    var maxBytes: Int64
    var maxFiles: Int
    var timeout: TimeInterval
}

extension GitWorkspace {
    /// The import's upload-pack for a folder (fix round 2, S2-b): `--strict`, so it serves exactly the scanned `<folder>/.git`
    /// and never probes `<path>/.git` (a repository hidden at `<folder>/.git/.git`) first.
    static let importUploadPack = "--upload-pack=git-upload-pack --strict"
    /// Where the fetched branch lands before `main` is set from it; deleted right after.
    static let importRef = "refs/brahma/import"
    /// The largest `ls-tree` listing the import's inspection reads; a longer one is over any file cap.
    static let importListingLimit = 64 << 20
    static let lfsPointerPrefix = "version https://git-lfs.github.com/spec/v1"

    /// Makes `dir` (which must not exist; its parent must) a fresh repository holding the source's current branch as `main`,
    /// checked out, with no remote, no hook, no copied config, nothing from the source's `.git` (Plan L Task 14).
    ///
    /// The engine's own git, the same hardened `GitCommand` as every other engine call: `init --template=` (no sample hooks),
    /// then one `fetch` by URL and refspec into `importRef` (no `remote.*` config is ever written, so the allowlist admits the
    /// repository afterwards), checked by fsck, no tags, no submodule recursion, `FETCH_HEAD` not written. The transport is
    /// allowed for that one call only: `allowsLocalFetch` for a folder (whose config is scanned for programs first, because the
    /// `git-upload-pack` git starts there reads it without the engine's `-c` overrides: `scanImportSource`), `allowsHTTPSFetch`
    /// for an https URL (TLS verified, a redirect followed only for the first request and only to https, credential helpers
    /// and prompts off). An https fetch is `--depth 1`; a shallow result (https, or a shallow source) becomes one root commit
    /// with the fetched tree, because the engine never keeps a shallow repository (its merges need full history). While the
    /// fetch runs, `.git` is watched against `caps.maxBytes`.
    ///
    /// Before anything is checked out, the tree is inspected (`inspectImport`): over the file cap, over the size cap (the
    /// working tree the tree declares plus `.git`), or Git LFS, refuses with `RepoImportError`. The checkout reads attributes
    /// from the empty tree with the engine's override (no filter, so no LFS smudge), with hooks and fsmonitor off.
    /// `caFile`: tests only, a certificate the https fetch trusts (a loopback server's).
    static func importRepository(_ transport: ImportTransport, shown: String, into dir: URL, caps: ImportCaps, tempRoot: URL,
                                 caFile: URL? = nil, baseEnvironment: [String: String]? = nil) throws -> ImportedRepository {
        let fm = FileManager.default
        try fm.createDirectory(at: dir, withIntermediateDirectories: false)
        var git = GitCommand(gitDir: dir.appending(path: ".git", directoryHint: .isDirectory), workTree: dir, commonDir: nil)
        git.tempRoot = tempRoot
        git.baseEnvironment = baseEnvironment
        try git.run(["init", "--quiet", "--template="])
        try git.run(["symbolic-ref", "HEAD", Self.mainRef])

        // The network steps run with an empty engine home (no `~/.netrc`, no XDG config), and their output and `.git` are
        // watched against the caps.
        let home = tempRoot.appending(path: "import-home-\(UUID().uuidString)", directoryHint: .isDirectory)
        try fm.createDirectory(at: home, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        defer { try? fm.removeItem(at: home) }
        var remote = git
        remote.timeoutSeconds = caps.timeout
        remote.homeDirectory = home
        remote.sizeWatch = (dir.appending(path: ".git", directoryHint: .isDirectory), caps.maxBytes)
        let target: String
        var transportFlags = ["-c", "protocol.version=2"]
        var options: [String] = []
        switch transport {
        case .local(let source):
            // The explicit `.git` (S2): never the folder itself, so git never probes for a repository around it.
            target = try resolveImportSource(source, shown: shown, with: git).path
            remote.allowsLocalFetch = true
            options = [Self.importUploadPack]
        case .https(let url):
            remote.allowsHTTPSFetch = true
            target = url.absoluteString
            transportFlags += ["-c", "http.sslVerify=true", "-c", "http.followRedirects=initial", "-c", "http.emptyAuth=false"]
            if let caFile { transportFlags += ["-c", "http.sslCAInfo=\(caFile.path)"] }
        }

        /// A watched network step: past the size cap it is the size refusal; a repository that could not be measured is its own
        /// refusal (naming the directory); flooded output or any other failure is git's.
        func network(_ args: [String], maxOutput: Int = GitCommand.maxCapture) throws -> GitCommand.Output {
            let out = try remote.run(args, allowFailure: true, maxOutput: maxOutput)
            if out.oversize { throw RepoImportError(message: RepoImport.sizeMessage) }
            if let dir = out.unmeasurable { throw RepoImportError(message: RepoImport.unmeasuredMessage(dir)) }
            guard out.status == 0, !out.flooded else {
                throw GitError.failed(command: args.first(where: { !$0.hasPrefix("-") && !$0.contains("=") }) ?? "fetch",
                                      status: out.status, stderr: String(out.stderr.prefix(2000)))
            }
            return out
        }
        // The source's current branch: `ref: refs/heads/<b>\tHEAD` (a symref), then `<sha>\tHEAD`.
        let listed = try network(transportFlags + ["ls-remote", "--symref"] + options + [target, "HEAD"], maxOutput: 64 << 10)
        var ref = "HEAD", branch = "HEAD", sawHead = false
        for line in listed.text.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1).map(String.init)
            guard parts.count == 2, parts[1] == "HEAD" else { continue }
            if parts[0].hasPrefix("ref: ") {
                let named = String(parts[0].dropFirst(5))
                guard named.hasPrefix("refs/heads/"), (try? validRef(named)) != nil else { continue }
                ref = named
                branch = String(named.dropFirst("refs/heads/".count))
            } else {
                sawHead = true
            }
        }
        guard sawHead else { throw GitError.failed(command: "ls-remote", status: -1, stderr: "the repository has no commits") }

        let depth: [String]
        if case .https = transport { depth = ["--depth", "1"] } else { depth = [] }
        _ = try network(transportFlags + [
            "-c", "fetch.fsckObjects=true", "-c", "transfer.fsckObjects=true",
            "fetch", "--quiet", "--no-tags", "--no-write-fetch-head", "--no-recurse-submodules", "--no-auto-gc",
        ] + depth + options + [target, "+\(ref):\(Self.importRef)"])

        let upstream = try git.run(["rev-parse", "--verify", "--quiet", "\(Self.importRef)^{commit}"]).text
        try validCommit(upstream)
        let shallowFile = dir.appending(path: ".git/shallow")
        let shallow = fm.fileExists(atPath: shallowFile.path) || Self.isSymlink(shallowFile)
        if shallow {
            // One root commit with the fetched tree: the tip, without the history the engine could never hand over.
            let tree = try git.run(["rev-parse", "--verify", "--quiet", "\(Self.importRef)^{tree}"]).text
            let message = "Import \(Self.oneLine(shown)) at \(upstream)"
            let root = try git.run(["commit-tree", tree, "-m", message]).text
            try validCommit(root)
            try git.run(["update-ref", Self.mainRef, root])
            guard case .removed = try EngineFiles.removeNoFollow(shallowFile, under: dir) else {
                throw GitError.failed(command: "fetch", status: -1, stderr: "could not drop the shallow history")
            }
        } else {
            try git.run(["update-ref", Self.mainRef, upstream])
        }
        try git.run(["update-ref", "-d", Self.importRef])

        // The inspection reads every tree entry and greps every blob: the import's timeout, not the 60 s of a quick call.
        var slow = git
        slow.timeoutSeconds = caps.timeout
        try inspectImport(slow, dir: dir, caps: caps)

        try slow.run(["-c", "core.protectHFS=true", "-c", "core.protectNTFS=true", "reset", "--hard", "--quiet", Self.mainRef])
        let head = try git.run(["rev-parse", "--verify", "--quiet", "\(Self.mainRef)^{commit}"]).text
        let commits = Int(try git.run(["rev-list", "--count", Self.mainRef]).text) ?? 0
        return ImportedRepository(head: head, branch: branch, upstreamHead: upstream, shallow: shallow, commits: commits)
    }

    /// The import's refusals for the repository at `dir` (`main`): more files than `caps.maxFiles`, more bytes than
    /// `caps.maxBytes` (what `main`'s tree declares, which is what a checkout writes, plus `.git` as it is on disk), or Git LFS
    /// (a `.gitattributes` anywhere with a `filter=lfs` line, or a tracked file of at most 1 KB that is an LFS pointer). Read
    /// from the object database only; nothing is checked out.
    static func inspectImport(_ git: GitCommand, dir: URL, caps: ImportCaps) throws {
        let listing = try git.run(["ls-tree", "-r", "-l", "-z", "--full-tree", Self.mainRef], maxOutput: importListingLimit)
        if listing.cut { throw RepoImportError(message: RepoImport.filesMessage(caps.maxFiles)) }
        var files = 0
        var bytes: Int64 = 0
        var attributes: [(object: String, size: Int64)] = []
        var sizes: [String: Int64] = [:]
        var links: [(path: String, object: String)] = []
        var entries: [(path: String, mode: String)] = []
        for raw in listing.stdout.split(separator: 0, omittingEmptySubsequences: true) {
            guard let tab = raw.firstIndex(of: 0x09) else { continue }
            let fields = String(decoding: raw[raw.startIndex..<tab], as: UTF8.self).split(separator: " ", omittingEmptySubsequences: true)
            let path = String(decoding: raw[raw.index(after: tab)...], as: UTF8.self)
            // Every entry, of every type (C1/S3): nothing lands in the engine's own directories or a `.git`.
            if let problem = importEntryProblem(path: path, mode: fields.first.map(String.init) ?? "", target: nil, links: []) {
                throw RepoImportError(message: problem)
            }
            if fields.count == 4, fields[0] == "120000" { links.append((path, String(fields[2]))) }
            entries.append((path, fields.first.map(String.init) ?? ""))
            guard fields.count == 4, fields[1] == "blob" else { continue }
            let size = Int64(fields[3]) ?? 0
            files += 1
            bytes += size
            sizes[path] = size
            if path == ".gitattributes" || path.hasSuffix("/.gitattributes") { attributes.append((String(fields[2]), size)) }
        }
        if files > caps.maxFiles { throw RepoImportError(message: RepoImport.filesMessage(caps.maxFiles)) }
        let gitBytes: Int64
        do {
            gitBytes = try EngineFiles.treeBytes(dir.appending(path: ".git", directoryHint: .isDirectory), stopAbove: caps.maxBytes)
        } catch let unmeasured as EngineFiles.Unmeasurable {
            throw RepoImportError(message: RepoImport.unmeasuredMessage(unmeasured.path))
        }
        if bytes > caps.maxBytes || gitBytes > caps.maxBytes - bytes { throw RepoImportError(message: RepoImport.sizeMessage) }
        // Symbolic links (S3, S4): the rules for agents' commits, on the tree and with names folded as the volume folds them
        // (no absolute target, no `..`, no `.`, nothing through a link or under one, nothing into `.git` or the engine's
        // directories, no directory above other links).
        if !links.isEmpty {
            let targets = try importLinkTargets(git, objects: links.map(\.object))
            let index = ImportLinkIndex(links: links.map(\.path))
            var linkTargets: [String: String] = [:]
            for (path, object) in links {
                guard let target = targets[object] else { throw RepoImportError(message: RepoImport.linkMessage(path, "cannot be read")) }
                linkTargets[path] = target
            }
            for entry in entries {
                if let problem = importEntryProblem(path: entry.path, mode: entry.mode, target: linkTargets[entry.path], index: index) {
                    throw RepoImportError(message: problem)
                }
            }
        }
        // LFS by its attributes: any `.gitattributes` (as stored) naming the lfs filter.
        for entry in attributes.prefix(1000) {
            let blob = try git.run(["cat-file", "blob", entry.object], maxOutput: 1 << 20)
            let text = String(decoding: blob.stdout, as: UTF8.self)
            if text.split(whereSeparator: \.isNewline).contains(where: { $0.contains("filter=lfs") }) {
                throw RepoImportError(message: RepoImport.lfsMessage)
            }
        }
        // LFS by its pointers: a small tracked file that starts with the pointer's version line.
        let grep = try git.run(["grep", "-l", "-F", "--no-color", "-e", lfsPointerPrefix, Self.mainRef, "--"], allowFailure: true, maxOutput: 1 << 20)
        if grep.status == 0 {
            for line in grep.text.split(separator: "\n").prefix(100) {
                let path = String(line.dropFirst("\(Self.mainRef):".count))
                guard let size = sizes[path], size <= 1024 else { continue }
                let blob = try git.run(["cat-file", "blob", "\(Self.mainRef):\(path)"], maxOutput: 4096)
                if blob.stdout.starts(with: Data(lfsPointerPrefix.utf8)) { throw RepoImportError(message: RepoImport.lfsMessage) }
            }
        } else if grep.status != 1 {
            throw GitError.failed(command: "grep", status: grep.status, stderr: Self.oneLine(grep.stderr))
        }
    }

    /// The largest symbolic-link target the import reads; a longer one is refused as odd.
    static let importLinkTargetLimit = 4096

    /// The import's symbolic links as the volume compares names (`foldedPath`), and every directory above one of them.
    struct ImportLinkIndex {
        let links: Set<String>
        let ancestors: Set<String>
        init<S: Sequence>(links raw: S) where S.Element == String {
            var links = Set<String>(), ancestors = Set<String>()
            for path in raw {
                let folded = GitWorkspace.foldedPath(path)
                links.insert(folded)
                var prefix = ""
                for part in folded.split(separator: "/").dropLast() {
                    prefix = prefix.isEmpty ? String(part) : prefix + "/" + part
                    ancestors.insert(prefix)
                }
            }
            self.links = links
            self.ancestors = ancestors
        }
    }

    /// A tree path with every part folded (`foldedName`: case-folded, composed), as a case-insensitive, normalizing volume
    /// compares it.
    static func foldedPath(_ path: String) -> String {
        path.split(separator: "/", omittingEmptySubsequences: true).map { foldedName(Array($0.utf8)) }.joined(separator: "/")
    }

    /// `importEntryProblem` with the tree's link paths (`links`) indexed here.
    static func importEntryProblem(path: String, mode: String, target: String?, links: Set<String>) -> String? {
        importEntryProblem(path: path, mode: mode, target: target, index: ImportLinkIndex(links: links))
    }

    /// Why one tree entry of an import is refused (the message the owner reads), or nil. Names are compared folded (`foldedName`),
    /// as the workspace's volume compares them (fix round 2, S4).
    /// - Any path whose first part is one of the engine's own top-level names, or whose any part is `.git`.
    /// - Any path under a directory that is itself a symbolic link of the tree (`Docs` a link, `docs/x` a file).
    /// - For a symbolic link (`120000`, with its `target`): an empty, NUL-holding or over-long target; an absolute one; a `..`
    ///   part; a target that names the link's own directory or the checkout root (`.`); a way into `.git` or an engine name;
    ///   a way through another link of the tree; or a directory above other links of the tree.
    static func importEntryProblem(path: String, mode: String, target: String?, index: ImportLinkIndex) -> String? {
        let parts = path.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        guard let first = parts.first else { return RepoImport.reservedMessage(path) }
        if isEngineName(Array(first.utf8)) { return RepoImport.reservedMessage(first) }
        if let dotGit = parts.first(where: { foldedName(Array($0.utf8)) == ".git" }) { return RepoImport.reservedMessage(dotGit) }
        if !index.links.isEmpty {
            var prefix = ""
            for part in parts.dropLast() {
                prefix = prefix.isEmpty ? foldedName(Array(part.utf8)) : prefix + "/" + foldedName(Array(part.utf8))
                if index.links.contains(prefix) { return RepoImport.underLinkMessage(path) }
            }
        }
        guard mode == "120000", let target else { return nil }
        let bytes = Array(target.utf8)
        guard !bytes.isEmpty, !bytes.contains(0), bytes.count <= importLinkTargetLimit else {
            return RepoImport.linkMessage(path, "has an empty or odd target")
        }
        if bytes.first == UInt8(ascii: "/") { return RepoImport.linkMessage(path, "has an absolute target") }
        let targetParts = target.split(separator: "/", omittingEmptySubsequences: true).map(String.init).filter { $0 != "." }
        if targetParts.contains("..") { return RepoImport.linkMessage(path, "has a `..` part in its target") }
        if targetParts.isEmpty { return RepoImport.linkMessage(path, "names its own directory or the checkout root") }
        let way = Array(parts.dropLast()) + targetParts
        if let top = way.first, isEngineName(Array(top.utf8)) || way.contains(where: { foldedName(Array($0.utf8)) == ".git" }) {
            return RepoImport.linkMessage(path, "points into .git or a name Brahma reserves")
        }
        var prefix = ""
        for part in way.dropLast() {
            prefix = prefix.isEmpty ? foldedName(Array(part.utf8)) : prefix + "/" + foldedName(Array(part.utf8))
            if index.links.contains(prefix) { return RepoImport.linkMessage(path, "passes through a symbolic link") }
        }
        if index.ancestors.contains(foldedPath(way.joined(separator: "/"))) {
            return RepoImport.linkMessage(path, "points at a directory that holds other links")
        }
        return nil
    }

    /// The targets of the import's symbolic links, by object id, read in one `cat-file --batch` (bounded; more output than the
    /// capture limit refuses the import).
    static func importLinkTargets(_ git: GitCommand, objects: [String]) throws -> [String: String] {
        let unique = Array(Set(objects))
        let out = try git.run(["cat-file", "--batch"], stdin: .data(Data(unique.map { $0 + "\n" }.joined().utf8)))
        if out.cut { throw RepoImportError(message: RepoImport.linkMessage("(many)", "are too many to check")) }
        var targets: [String: String] = [:]
        var data = out.stdout[...]
        while let newline = data.firstIndex(of: 0x0A) {
            let header = String(decoding: data[data.startIndex..<newline], as: UTF8.self).split(separator: " ")
            data = data[data.index(after: newline)...]
            guard header.count == 3, header[1] == "blob", let size = Int(header[2]), size >= 0, data.count >= size else { break }
            let body = data.prefix(size)
            targets[String(header[0])] = size <= importLinkTargetLimit ? String(decoding: body, as: UTF8.self) : nil
            data = data.dropFirst(size)
            if data.first == 0x0A { data = data.dropFirst() }
        }
        return targets
    }

    /// `inspectImport` for an imported workspace (`RepoImport.inspect`).
    static func inspectImportedWorkspace(_ dir: URL, caps: ImportCaps, tempRoot: URL) throws {
        var git = GitCommand(gitDir: dir.appending(path: ".git", directoryHint: .isDirectory), workTree: dir, commonDir: nil)
        git.tempRoot = tempRoot
        git.timeoutSeconds = caps.timeout
        try inspectImport(git, dir: dir, caps: caps)
    }

    /// Before a local fetch: the `git-upload-pack` git starts in the source repository reads that repository's config without
    /// the engine's `-c` overrides, so a config that names a program refuses the import, and nothing runs there. Narrower
    /// than `RepoConfigGuard`'s allowlist (an owner's repository has remotes, branches and tool settings, all inert for a
    /// fetch): includes, filters, credentials, pagers, and every key that names a command, a driver, a hook path, an
    /// external program or a non-boolean fsmonitor. The source's `.git` must be a real directory (not a linked worktree's
    /// `.git` file, not a link) without a `commondir` redirect.
    static func scanImportSource(_ source: URL, shown: String, with git: GitCommand) throws {
        let dotGit = source.appending(path: ".git", directoryHint: .isDirectory)
        guard isRealDirectory(dotGit), !FileManager.default.fileExists(atPath: dotGit.appending(path: "commondir").path) else {
            throw RepoImportError(message: "\(oneLine(shown)) is a linked worktree or submodule checkout; pass the repository's own folder")
        }
        var found: [String] = []
        for name in ["config", "config.worktree"] {
            let file = dotGit.appending(path: name)
            var st = stat()
            guard lstat(file.path, &st) == 0 else { continue }
            guard st.st_mode & S_IFMT == S_IFREG else {
                throw RepoImportError(message: "\(oneLine(shown))'s .git/\(name) is not a regular file; import a fresh clone instead")
            }
            let out = try git.listConfig(file)
            guard out.status == 0, !out.cut, !out.timedOut else {
                throw RepoImportError(message: "\(oneLine(shown))'s .git/\(name) cannot be read by git; import a fresh clone instead")
            }
            for entry in out.stdout.split(separator: 0, omittingEmptySubsequences: true) {
                let text = String(decoding: entry, as: UTF8.self)
                let key = String(text.prefix { $0 != "\n" })
                let value = text.contains("\n") ? String(text[text.index(after: text.firstIndex(of: "\n")!)...]) : ""
                if importSourceRuns(key, value: value), !found.contains(Self.shown(key)) { found.append(Self.shown(key)) }
            }
        }
        guard found.isEmpty else {
            let named = found.prefix(6).joined(separator: ", ") + (found.count > 6 ? " and \(found.count - 6) more" : "")
            throw RepoImportError(message: "the repo's git config sets \(named), which Brahma does not run git with; import a fresh "
                                    + "clone instead (git clone \(oneLine(shown)) <new folder>, then pass the new folder)")
        }
    }

    /// The source's explicit `.git` (S2), after `scanImportSource`: it must hold `HEAD`, `objects` and `refs` as a plain
    /// repository does, and git, asked with exactly that `GIT_DIR` (`rev-parse --absolute-git-dir`, no repository check: the
    /// owner's repository has remotes, and nothing is written into it), must name the same real directory. The fetch then
    /// reads from that directory, never from the folder (no discovery around it).
    static func resolveImportSource(_ source: URL, shown: String, with git: GitCommand) throws -> URL {
        try scanImportSource(source, shown: shown, with: git)
        let dotGit = source.appending(path: ".git", directoryHint: .isDirectory)
        var st = stat()
        let head = lstat(dotGit.appending(path: "HEAD").path, &st) == 0 && st.st_mode & S_IFMT == S_IFREG
        // Nothing at `.git/.git` (S2-b): a repository or gitfile there is what a non-strict upload-pack would serve instead.
        let nested = lstat(dotGit.appending(path: ".git").path, &st) == 0
        guard head, !nested, isRealDirectory(dotGit.appending(path: "objects")), isRealDirectory(dotGit.appending(path: "refs")) else {
            throw RepoImportError(message: RepoImport.notARepositoryMessage(shown))
        }
        var probe = GitCommand(gitDir: dotGit, workTree: source, commonDir: nil)
        probe.skipsRepositoryCheck = true
        probe.tempRoot = git.tempRoot
        let out = try probe.run(["rev-parse", "--absolute-git-dir"], allowFailure: true, maxOutput: 64 << 10)
        let resolved = URL(fileURLWithPath: out.text).resolvingSymlinksInPath().standardizedFileURL.path
        guard out.status == 0, resolved == dotGit.resolvingSymlinksInPath().standardizedFileURL.path else {
            throw RepoImportError(message: RepoImport.notARepositoryMessage(shown))
        }
        return dotGit
    }

    /// Whether a source config key could make git (or a program it starts) run something, or reach the network, during a
    /// fetch from it.
    static func importSourceRuns(_ key: String, value: String) -> Bool {
        let lower = key.lowercased()
        guard let firstDot = lower.firstIndex(of: "."), let lastDot = lower.lastIndex(of: ".") else { return true }
        let section = String(lower[..<firstDot]), variable = String(lower[lower.index(after: lastDot)...])
        if ["include", "includeif", "filter", "credential", "pager"].contains(section) { return true }
        // M6: a partial clone's upload-pack may fetch missing objects from its promisor remote on its own; a repository format
        // git does not know is refused rather than guessed at.
        if lower == "extensions.partialclone" { return true }
        if section == "remote", firstDot != lastDot, ["promisor", "partialclonefilter"].contains(variable) { return true }
        if lower == "core.repositoryformatversion" {
            return !["0", "1"].contains(value.trimmingCharacters(in: .whitespaces))
        }
        if lower == "core.fsmonitor" {
            return !["true", "false", "yes", "no", "on", "off", "1", "0", ""].contains(value.lowercased().trimmingCharacters(in: .whitespaces))
        }
        return ["hookspath", "sshcommand", "gitproxy", "askpass", "alternaterefscommand", "editor", "pager", "external", "command",
                "textconv", "driver", "cmd", "program", "packobjectshook", "helper", "uploadpack", "receivepack"].contains(variable)
    }
}
