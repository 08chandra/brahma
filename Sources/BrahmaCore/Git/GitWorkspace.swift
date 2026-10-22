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
/// Programs a repository can name for git to run on content (filters, textconv, diff and merge drivers) are kept out in
/// two layers. Before every call the repository's own config files are read (`RepoConfigGuard`); one that defines a
/// filter, a textconv or diff command, a merge driver, `core.hooksPath`, `core.sshCommand`, `core.fsmonitor` or an
/// include is refused: nothing runs, `onRefused` hears what was found (the store files one owner alert). And every call
/// reads attributes from the empty tree (`--attr-source`, git 2.42+), never from a checkout's `.gitattributes`, with
/// `core.attributesFile=/dev/null` and the engine's override (`attributesOverride`) as `info/attributes`. Replace refs and
/// grafts are ignored, so the objects the engine reviews, checks and merges are the ones their ids name.
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

    func withIndex(_ url: URL) -> GitCommand { var copy = self; copy.indexFile = url; return copy }

    static let timeout: TimeInterval = 60
    static let lockRetries = 3
    static let lockRetryDelay: TimeInterval = 0.2
    static let maxCapture = 8 * 1024 * 1024

    /// Applied to every call, before the subcommand.
    static let configFlags = [
        "-c", "user.name=Brahma", "-c", "user.email=engine@brahma.local", "-c", "commit.gpgsign=false",
        "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "core.pager=cat", "-c", "diff.external=",
        "-c", "protocol.ext.allow=never", "-c", "core.quotepath=false", "-c", "gc.auto=0",
        "-c", "core.attributesFile=/dev/null", "-c", "advice.graftFileDeprecated=false",
    ]

    /// The engine's `info/attributes` (it outranks every other attributes file): no filter, no diff driver (git decides text
    /// or binary as usual), the built-in text merge. `-diff` would make every review diff "Binary files differ".
    static let attributesOverride = "* -filter !diff merge=text\n"
    static let refusalPrefix = "Brahma runs no git in this repository: "
    static let emptyTreeSHA1 = "4b825dc642cb6eb9a060e54bf8d69288fbee4904"
    static let emptyTreeSHA256 = "6ef19b41225c5369f1c104d45d8d85efa9b057b53b14b4b9b939dd74decc5321"

    /// `--attr-source` arrived in git 2.42.
    static func supportsAttrSource(versionLine: String) -> Bool {
        guard versionLine.hasPrefix("git version ") else { return false }
        let numbers = versionLine.dropFirst("git version ".count).split(whereSeparator: { !$0.isNumber }).prefix(2).compactMap { Int($0) }
        guard numbers.count == 2 else { return false }
        return numbers[0] > 2 || numbers[0] == 2 && numbers[1] >= 42
    }

    /// Asked once per process.
    static let installedSupportsAttrSource: Bool = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "--version"]
        process.environment = ChildEnvironment.make(base: ProcessInfo.processInfo.environment, purpose: .general)
        let out = Pipe()
        process.standardOutput = out; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return false }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return process.terminationStatus == 0 && supportsAttrSource(versionLine: String(decoding: data, as: UTF8.self))
    }()

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
        var text: String { String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func environment() -> [String: String] {
        var env = ChildEnvironment.make(base: ProcessInfo.processInfo.environment, purpose: .general)
        env["GIT_DIR"] = gitDir.path
        env["GIT_WORK_TREE"] = workTree.path
        if let commonDir { env["GIT_COMMON_DIR"] = commonDir.path }
        if let indexFile { env["GIT_INDEX_FILE"] = indexFile.path }
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_ATTR_NOSYSTEM"] = "1"
        env["GIT_NO_REPLACE_OBJECTS"] = "1"
        env["GIT_GRAFT_FILE"] = "/dev/null"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        return env
    }

    /// `attrSource`: the tree attributes are read from (the empty tree of the repository's hash), nil on an older git.
    func arguments(_ args: [String], attrSource: String?) -> [String] {
        ["git", "-C", workTree.path] + (attrSource.map { ["--attr-source=\($0)"] } ?? []) + Self.configFlags + args
    }

    /// Before any git runs: an older git may only run tree-free plumbing; the repository's config must name no program;
    /// the engine's attributes override is put back. Returns the attribute source for the call.
    private func prepare(_ args: [String]) throws -> String? {
        if !attrSourceSupported, !Self.isTreeFree(args) {
            throw GitError.failed(command: args.joined(separator: " "), status: -1,
                                  stderr: "this git is older than 2.42 and cannot be kept from repository attributes; install a newer git")
        }
        if skipsRepositoryCheck { return attrSourceSupported ? Self.emptyTreeSHA1 : nil }
        let common = commonDir ?? gitDir
        var sha256 = false
        var problems: [String] = []
        var seen: Set<String> = []
        for file in [common.appending(path: "config"), common.appending(path: "config.worktree"), gitDir.appending(path: "config.worktree")]
        where seen.insert(file.standardizedFileURL.path).inserted {
            let scan = RepoConfigGuard.scan(file, with: self)
            if let refused = scan.refused { problems.append("\(GitWorkspace.shown(file.path)) \(refused)") }
            if file.lastPathComponent == "config", scan.sha256 { sha256 = true }
        }
        if problems.isEmpty, let problem = RepoConfigGuard.ensureAttributes(commonDir: common) { problems.append(problem) }
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
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_CEILING_DIRECTORIES"] = "/"
        return try runOnce(["git", "-C", "/", "config", "--file", file.path, "--no-includes", "--null", "--list"],
                           environment: env, label: "config --list", maxOutput: 1 << 20)
    }

    /// Runs git with stdin `/dev/null` and a 60 s timeout. Stderr containing `index.lock` is retried 3 times at 200 ms.
    /// A non-zero status throws unless `allowFailure`.
    @discardableResult
    func run(_ args: [String], allowFailure: Bool = false, maxOutput: Int = GitCommand.maxCapture) throws -> Output {
        var attempt = 0
        let attrSource = try prepare(args)
        while true {
            let out = try runOnce(arguments(args, attrSource: attrSource), environment: environment(),
                                  label: args.joined(separator: " "), maxOutput: maxOutput)
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

    private func runOnce(_ argv: [String], environment: [String: String], label: String, maxOutput: Int) throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = argv
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        // Output goes to files, not pipes: concurrent children cannot hold each other's pipe ends open, and a grandchild
        // that outlives git cannot keep us waiting for end of file.
        let base = FileManager.default.temporaryDirectory.appending(path: "brahma-git-\(UUID().uuidString)")
        let outURL = base.appendingPathExtension("out"), errURL = base.appendingPathExtension("err")
        guard FileManager.default.createFile(atPath: outURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              FileManager.default.createFile(atPath: errURL.path, contents: nil, attributes: [.posixPermissions: 0o600]),
              let outHandle = FileHandle(forWritingAtPath: outURL.path), let errHandle = FileHandle(forWritingAtPath: errURL.path)
        else { throw GitError.failed(command: label, status: -1, stderr: "no temporary space for git output") }
        defer {
            try? outHandle.close(); try? errHandle.close()
            try? FileManager.default.removeItem(at: outURL); try? FileManager.default.removeItem(at: errURL)
        }
        process.standardOutput = outHandle
        process.standardError = errHandle
        do { try process.run() } catch {
            throw GitError.failed(command: label, status: -1, stderr: "\(error)")
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

    /// Does this config key name a program git would run, or pull in another file? Keys come canonical from
    /// `git config --list`: section and variable lowercased, a subsection as written (dots and all).
    static func isRefused(_ key: String) -> Bool {
        let lower = key.lowercased()
        guard let firstDot = lower.firstIndex(of: "."), let lastDot = lower.lastIndex(of: ".") else { return false }
        let section = lower[..<firstDot], variable = lower[lower.index(after: lastDot)...]
        let hasSubsection = firstDot != lastDot
        switch section {
        case "filter", "include", "includeif": return true
        case "diff": return hasSubsection && (variable == "textconv" || variable == "command")
        case "merge": return hasSubsection && variable == "driver"
        case "core": return !hasSubsection && ["hookspath", "sshcommand", "fsmonitor"].contains(variable)
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
                if isRefused(key) { refused.append(GitWorkspace.shown(key)) }
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

    /// Writes the engine's `info/attributes` when it is not exactly that. Nil when done (or when there is no repository yet:
    /// `git init` has not run); else why not.
    static func ensureAttributes(commonDir: URL) -> String? {
        var st = stat()
        guard lstat(commonDir.path, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return nil }
        let info = commonDir.appending(path: "info", directoryHint: .isDirectory)
        if lstat(info.path, &st) == 0 {
            guard st.st_mode & S_IFMT == S_IFDIR else { return "\(GitWorkspace.shown(info.path)) is not a real directory" }
        } else if (try? FileManager.default.createDirectory(at: info, withIntermediateDirectories: false)) == nil {
            return "cannot create \(GitWorkspace.shown(info.path))"
        }
        let file = info.appending(path: "attributes")
        if lstat(file.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, st.st_size == GitCommand.attributesOverride.utf8.count,
           FileManager.default.contents(atPath: file.path) == Data(GitCommand.attributesOverride.utf8) {
            return nil
        }
        if lstat(file.path, &st) == 0, st.st_mode & S_IFMT != S_IFREG { try? FileManager.default.removeItem(at: file) }
        do { try Data(GitCommand.attributesOverride.utf8).write(to: file, options: .atomic) } catch {
            return "cannot write \(GitWorkspace.shown(file.path))"
        }
        return nil
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
    private var main: GitCommand { GitCommand(gitDir: gitDir, workTree: root, commonDir: nil, onRefused: onUnsafeRepository) }

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
                                  stderr: "the worktree of \(key) was repointed (\(detail)); it was restored and nothing was run in it")
        }
        return (GitCommand(gitDir: adminDir(key: key), workTree: worktreePath(key: key), commonDir: gitDir, onRefused: onUnsafeRepository), key)
    }

    private static func isRealDirectory(_ url: URL) -> Bool {
        var st = stat()
        return lstat(url.path, &st) == 0 && st.st_mode & S_IFMT == S_IFDIR
    }

    /// After an operation that was started on a checked worktree: if its links were rewritten meanwhile, restore them and
    /// report (the operation itself never used `HEAD`, so it landed on the item's branch).
    private func verifyAfter(key: String) {
        guard Self.isRealDirectory(adminDir(key: key)) else { return }
        let problems = linkProblems(key: key)
        guard !problems.isEmpty else { return }
        heal(key: key)
        onWorktreeTamper?(key, problems.joined(separator: "; "))
    }

    /// Test seam: called with a stage name between the worktree check and the operation that follows it.
    var testHook: (@Sendable (String) -> Void)?

    /// Every path form the engine accepts for one location: as the engine writes it, and as git writes it (`realpath`).
    private static func forms(_ url: URL) -> Set<String> {
        var out: Set<String> = [url.path]
        if let real = realPath(Array(url.path.utf8)) { out.insert(real) }
        return out
    }

    private static func regularText(_ url: URL) -> String? {
        var st = stat()
        guard lstat(url.path, &st) == 0, st.st_mode & S_IFMT == S_IFREG else { return nil }
        return try? String(contentsOf: url, encoding: .utf8)
    }

    /// What differs from the engine's record of one item worktree; empty when it is as the engine created it.
    private func linkProblems(key: String) -> [String] {
        let admin = adminDir(key: key), tree = worktreePath(key: key)
        var problems: [String] = []
        if Self.regularText(admin.appending(path: "HEAD")) != "ref: \(branchRef(key: key))\n" { problems.append("HEAD is not \(branchRef(key: key))") }
        let commondir = Self.regularText(admin.appending(path: "commondir"))?.trimmingCharacters(in: .newlines)
        if commondir != "../.." { problems.append("commondir was changed") }
        let gitdir = Self.regularText(admin.appending(path: "gitdir"))?.trimmingCharacters(in: .newlines)
        if gitdir.map({ !Self.forms(tree).map { "\($0)/.git" }.contains($0) }) ?? true { problems.append("gitdir was changed") }
        let link = Self.regularText(tree.appending(path: ".git"))?.trimmingCharacters(in: .newlines)
        if link.map({ !Self.forms(admin).map { "gitdir: \($0)" }.contains($0) }) ?? true { problems.append(".git was changed") }
        return problems
    }

    /// Rewrites `HEAD` and the three pointers that tie a worktree to this repository from the engine's own records. Git
    /// resolves refs through `commondir` whatever `GIT_COMMON_DIR` says, so an agent that repointed it would otherwise make
    /// a commit move a branch in another repository.
    private func heal(key: String) {
        let admin = adminDir(key: key)
        func ensure(_ url: URL, _ text: String) {
            guard Self.regularText(url) != text else { return }
            var st = stat()
            if lstat(url.path, &st) == 0, st.st_mode & S_IFMT != S_IFREG { try? FileManager.default.removeItem(at: url) }
            try? text.write(to: url, atomically: true, encoding: .utf8)
        }
        ensure(admin.appending(path: "HEAD"), "ref: \(branchRef(key: key))\n")
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

    /// Stages everything and commits it; the new commit, or nil when there was nothing to commit.
    ///
    /// In an item worktree the commit is built outside `HEAD`: a private index is read from the item branch's tip, the work
    /// is added to it, `write-tree` and `commit-tree` make the commit, and `refs/heads/item/<KEY>` is advanced with
    /// `update-ref <ref> <new> <expected old>`. Whatever `HEAD` says at that moment (a turn may rewrite it between the check
    /// and here), no other branch can move, and a branch that moved meanwhile makes the swap fail.
    @discardableResult
    public func commitAll(in dir: URL, message: String) throws -> String? {
        let (git, key) = try resolve(dir)
        guard let key else {
            try git.run(["add", "-A"])
            let staged = try git.run(["diff", "--cached", "--quiet"], allowFailure: true)
            if staged.status == 0 { return nil }
            guard staged.status == 1 else {
                throw GitError.failed(command: "diff --cached --quiet", status: staged.status, stderr: staged.stderr)
            }
            try git.run(["commit", "--quiet", "--no-verify", "-m", message])
            return try git.run(["rev-parse", "HEAD"]).text
        }
        let ref = branchRef(key: key)
        guard let tip = try head(of: ref) else {
            throw GitError.failed(command: "commit \(key)", status: -1, stderr: "\(ref) does not exist")
        }
        testHook?("checked")
        let index = FileManager.default.temporaryDirectory.appending(path: "brahma-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: index) }
        let private_ = git.withIndex(index)
        try private_.run(["read-tree", tip])
        try private_.run(["add", "-A"])
        let tree = try private_.run(["write-tree"]).text
        if tree == (try git.run(["rev-parse", "--verify", "\(tip)^{tree}"]).text) { verifyAfter(key: key); return nil }
        let commit = try git.run(["commit-tree", tree, "-p", tip, "-m", message]).text
        try git.run(["update-ref", "-m", message, ref, commit, tip])
        // The worktree's own index follows the branch, so the checkout is clean afterwards.
        try? git.run(["read-tree", commit])
        verifyAfter(key: key)
        return commit
    }

    /// The commit a checkout's branch points at (for an item worktree: `refs/heads/item/<KEY>`, never `HEAD`).
    public func headCommit(in dir: URL) throws -> String {
        let (git, key) = try resolve(dir)
        guard let key else { return try git.run(["rev-parse", "HEAD"]).text }
        return try git.run(["rev-parse", "--verify", "\(branchRef(key: key))^{commit}"]).text
    }

    /// Puts the checkout back on `commit` and removes everything untracked (the write barrier of a plan turn). In an item
    /// worktree the branch is moved with a compare-and-swap and the index and files are reset with `read-tree`; `HEAD` is
    /// neither read nor written.
    public func resetHard(in dir: URL, to commit: String) throws {
        try Self.validCommit(commit)
        let (git, key) = try resolve(dir)
        guard let key else {
            try git.run(["reset", "--hard", "--quiet", commit])
            try git.run(["clean", "-fdq"])
            return
        }
        let ref = branchRef(key: key)
        testHook?("checked")
        let current = try git.run(["rev-parse", "--verify", "\(ref)^{commit}"]).text
        try git.run(["read-tree", "--reset", "-u", commit])
        if current != commit { try git.run(["update-ref", ref, commit, current]) }
        try git.run(["clean", "-fdq"])
        verifyAfter(key: key)
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
        let fm = FileManager.default

        // The repository's own files. New ones go first, deepest first, so a directory or link put in place of a file goes too.
        // Files over the size cap and entries over the count cap are not read: new ones are deleted, and either fails the check.
        let indexKey = "worktrees/\(key)/index"
        let captured = repoFiles(key: key)
        let after = captured.files
        func known(_ rel: String) -> Bool { before.files[rel] != nil || before.files.keys.contains { $0.hasPrefix(rel + "/") } }
        func put(_ rel: String, _ file: RepoFile) {
            do { try Self.restore(file, at: gitDir.appending(path: rel)) } catch { failures.append("restore \(Self.shown(rel)): \(error)") }
        }
        for rel in captured.oversize.sorted() {
            failures.append("repository file \(Self.shown(rel)) is larger than \(Self.repoFileLimit) bytes")
            if let file = before.files[rel] { found.append("changed \(Self.shown(rel))"); put(rel, file) }
            else { found.append("new \(Self.shown(rel))"); try? fm.removeItem(at: gitDir.appending(path: rel)) }
        }
        for rel in captured.overflow.sorted() {
            failures.append("more than \(Self.repoEntryLimit) repository files (at \(Self.shown(rel)))")
            if !known(rel) { found.append("new \(Self.shown(rel))"); try? fm.removeItem(at: gitDir.appending(path: rel)) }
        }
        for rel in after.keys.filter({ before.files[$0] == nil }).sorted(by: { $0.count > $1.count }) {
            found.append("new \(Self.shown(rel))")
            do { try fm.removeItem(at: gitDir.appending(path: rel)) } catch { failures.append("remove \(Self.shown(rel)): \(error)") }
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
            if st.st_size > repoFileLimit { capture.oversize.append(rel); return }
            capture.files[rel] = RepoFile(data: FileManager.default.contents(atPath: url.path) ?? Data(), mode: mode, link: nil)
        case S_IFLNK: capture.files[rel] = RepoFile(data: nil, mode: mode, link: (try? FileManager.default.destinationOfSymbolicLink(atPath: url.path)) ?? "")
        default: capture.files[rel] = RepoFile(data: nil, mode: mode, link: "special")
        }
    }

    /// Puts one repository file back as it was, permission bits included (an executable hook stays executable).
    private static func restore(_ file: RepoFile, at url: URL) throws {
        let fm = FileManager.default
        var st = stat()
        if lstat(url.path, &st) == 0, st.st_mode & S_IFMT != S_IFREG || file.data == nil { try fm.removeItem(at: url) }
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
