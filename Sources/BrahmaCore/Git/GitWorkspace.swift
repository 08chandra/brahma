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
///
/// Programs a repository can name for git to run (filters, textconv, diff and merge drivers, gpg, credential helpers,
/// askpass, ssh, proxies, submodule recursion) are kept out in two layers. The guarantee is the command line: every call
/// forces each such setting off (`configFlags`, `environment()`), and reads attributes from the empty tree
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

    /// What the repository's `info/attributes` must hold (`RepoConfigGuard.ensureAttributes`): the shared override, or for
    /// the engine's merge repository its own stronger line (`GitWorkspace.engineAttributes`), never something weaker.
    var attributes = GitCommand.attributesOverride

    func withIndex(_ url: URL) -> GitCommand { var copy = self; copy.indexFile = url; return copy }

    static let timeout: TimeInterval = 60
    static let lockRetries = 3
    static let lockRetryDelay: TimeInterval = 0.2
    static let maxCapture = 8 * 1024 * 1024

    /// Applied to every call, before the subcommand: what git may run is switched off whatever any config says (command-line
    /// config outranks every file, and reaches child git processes, such as one in a nested repository, too).
    static let configFlags = [
        "-c", "user.name=Brahma", "-c", "user.email=engine@brahma.local", "-c", "commit.gpgsign=false", "-c", "tag.gpgSign=false",
        "-c", "core.fsmonitor=false", "-c", "core.hooksPath=/dev/null", "-c", "core.pager=cat", "-c", "diff.external=",
        "-c", "core.sshCommand=/usr/bin/false", "-c", "core.gitProxy=", "-c", "core.askPass=/usr/bin/false",
        "-c", "credential.helper=", "-c", "gpg.program=/usr/bin/false", "-c", "gpg.ssh.program=/usr/bin/false",
        "-c", "gpg.x509.program=/usr/bin/false", "-c", "log.showSignature=false", "-c", "merge.verifySignatures=false",
        "-c", "submodule.recurse=false", "-c", "diff.ignoreSubmodules=dirty", "-c", "protocol.allow=never",
        "-c", "protocol.ext.allow=never", "-c", "core.alternateRefsCommand=", "-c", "uploadpack.packObjectsHook=",
        "-c", "core.editor=/usr/bin/false", "-c", "sequence.editor=/usr/bin/false",
        "-c", "core.quotepath=false", "-c", "gc.auto=0",
        "-c", "core.attributesFile=/dev/null", "-c", "advice.graftFileDeprecated=false",
    ]

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

    /// The installed git's version as `git --version` prints it (`2.52.0`), read once; nil when it cannot be read.
    static let gitVersionText: String? = {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        process.arguments = ["git", "--version"]
        process.environment = ChildEnvironment.make(base: ProcessInfo.processInfo.environment, purpose: .general)
        let pipe = Pipe()
        process.standardOutput = pipe; process.standardError = FileHandle.nullDevice; process.standardInput = FileHandle.nullDevice
        guard (try? process.run()) != nil else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(decoding: data, as: UTF8.self)
        guard process.terminationStatus == 0, let match = text.range(of: "[0-9]+\\.[0-9]+(\\.[0-9]+)?", options: .regularExpression)
        else { return nil }
        return String(text[match])
    }()

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
        var text: String { String(decoding: stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines) }
    }

    func environment() -> [String: String] {
        var env = ChildEnvironment.make(base: ProcessInfo.processInfo.environment, purpose: .general)
        env["GIT_DIR"] = gitDir.path
        env["GIT_WORK_TREE"] = workTree.path
        // Always pinned: without it git follows a `commondir` file in the git dir (the workspace's own `.git` included) to
        // a config, attributes and refs the engine never checked.
        env["GIT_COMMON_DIR"] = (commonDir ?? gitDir).path
        if let indexFile { env["GIT_INDEX_FILE"] = indexFile.path }
        env["GIT_CONFIG_GLOBAL"] = "/dev/null"
        env["GIT_CONFIG_NOSYSTEM"] = "1"
        env["GIT_ATTR_NOSYSTEM"] = "1"
        env["GIT_NO_REPLACE_OBJECTS"] = "1"
        env["GIT_GRAFT_FILE"] = "/dev/null"
        env["GIT_TERMINAL_PROMPT"] = "0"
        env["GIT_ASKPASS"] = "/usr/bin/false"
        env["SSH_ASKPASS"] = "/usr/bin/false"
        env["GIT_OPTIONAL_LOCKS"] = "0"
        // Never inherited (the allowlist keeps them out already); named so that no later change lets one through.
        for name in ["GIT_EXTERNAL_DIFF", "GIT_SSH", "GIT_SSH_COMMAND", "GIT_PROXY_COMMAND", "GIT_CONFIG_PARAMETERS", "GIT_CONFIG_COUNT",
                     "GIT_EXEC_PATH", "GIT_PAGER", "GIT_EDITOR", "GIT_SEQUENCE_EDITOR"] { env[name] = nil }
        return env
    }

    /// `attrSource`: the tree attributes are read from (the empty tree of the repository's hash), nil on an older git.
    func arguments(_ args: [String], attrSource: String?) -> [String] {
        ["git", "-C", workTree.path] + (attrSource.map { ["--attr-source=\($0)"] } ?? []) + Self.configFlags
            + (allowsLocalFetch ? ["-c", "protocol.file.allow=always"] : []) + args
    }

    /// Before each attempt: an older git may only run tree-free plumbing; the repository's config must hold only allowed
    /// keys; the engine's attributes override is put back. Returns the attribute source for the call.
    private func prepare(_ args: [String]) throws -> String? {
        if !attrSourceSupported, !Self.isTreeFree(args) {
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
        while true {
            // Scanned again before a retry: the config may have changed while git waited for the lock.
            let attrSource = try prepare(args)
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

    /// Is this config key one the engine runs git with? Only what git itself and the engine write, and inert settings;
    /// everything else (any program, helper, driver, include, remote or alias) refuses the repository. Keys come canonical
    /// from `git config --list`: section and variable lowercased, a subsection as written (dots and all).
    static func isAllowed(_ key: String) -> Bool {
        let lower = key.lowercased()
        guard let firstDot = lower.firstIndex(of: "."), let lastDot = lower.lastIndex(of: ".") else { return false }
        let section = lower[..<firstDot], variable = lower[lower.index(after: lastDot)...]
        let hasSubsection = firstDot != lastDot
        switch section {
        case "core":
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
                if !isAllowed(key) { refused.append(GitWorkspace.shown(key)) }
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
        if lstat(file.path, &st) == 0, st.st_mode & S_IFMT != S_IFREG { try? FileManager.default.removeItem(at: file) }
        do { try Data(content.utf8).write(to: file, options: .atomic) } catch {
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
    /// The base of the engine's own merge repository (`<mergeDirectory>.git`, its working tree `<mergeDirectory>-wt`, its
    /// bundles and exports). Must not be a place agents can write (a leaseholder is given `<ws>/.brahma`); the store uses
    /// `<home>/run/merge/<companyId>`.
    public let mergeDirectory: URL
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
                                  stderr: "the worktree of \(key) was repointed (\(detail)); what the engine records was put back and nothing was run in it")
        }
        return (GitCommand(gitDir: adminDir(key: key), workTree: worktreePath(key: key), commonDir: gitDir, onRefused: onUnsafeRepository), key)
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
    /// refs/heads/main`) would make every update of the item branch move its target. Packed refs are never symbolic.
    private func symbolicItemRef(key: String) -> String? {
        let ref = branchRef(key: key)
        let url = gitDir.appending(path: ref)
        var st = stat()
        guard lstat(url.path, &st) == 0 else { return nil }
        switch st.st_mode & S_IFMT {
        case S_IFLNK: return "\(ref) is a symbolic ref (a link)"
        case S_IFREG:
            guard let text = Self.regularText(url), text.hasPrefix("ref:") else { return nil }
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
        if let symbolic = symbolicItemRef(key: key) { problems.append(symbolic) }
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

    /// Where the engine's own repository for merge work lives (see `freshEngineRepository`): `<mergeDirectory>.git`, i.e.
    /// `<home>/run/merge/<companyId>.git`. Nothing in it is ever read from the workspace and no agent is given a path to it.
    var mergeRepositoryPath: URL { URL(fileURLWithPath: mergeDirectory.path + ".git", isDirectory: true) }
    /// The engine repository's private working tree, `<home>/run/merge/<companyId>-wt`.
    var mergeWorktreePath: URL { URL(fileURLWithPath: mergeDirectory.path + "-wt", isDirectory: true) }
    /// The engine merge repository's git context: the shared `GitCommand` hardening and config allowlist (its git dir is
    /// pinned as its own common dir), with the engine's stronger attributes line (`engineAttributes`) kept in its
    /// `info/attributes`. A refusal there is the company's fault (the engine wrote that config), not a workspace alert.
    private var engineCommand: GitCommand {
        var git = GitCommand(gitDir: mergeRepositoryPath, workTree: mergeWorktreePath, commonDir: nil)
        git.attributes = Self.engineAttributes
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
    private static let rebaseConfig = [
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
    func landVerified(key: String, verified: String, expectedMain: String, recordPending: (String) throws -> Void,
                      tamper: ([String]) -> Void = { _ in }) throws -> LandOutcome {
        try Self.validKey(key); try Self.validCommit(verified); try Self.validCommit(expectedMain)
        return try withKeyLock(key, infrastructure: true) {
            try withMainLock(infrastructure: true) {
                let removed = try MergeInfrastructureError.wrapping { try clearStaleWorkspaceLocks(key: key) }
                if !removed.isEmpty { tamper(removed) }
                let branchHead = try MergeInfrastructureError.wrapping { try head(of: branchRef(key: key)) }
                guard branchHead == verified else { return .branchMoved(head: branchHead) }
                let mainHead = try MergeInfrastructureError.wrapping { try head(of: Self.mainRef) }
                guard let mainHead, mainHead == expectedMain else { return .mainMoved(head: mainHead) }
                return try withEngineLock {
                    try landLocked(key: key, verified: verified, mainHead: mainHead, recordPending: recordPending)
                }
            }
        }
    }

    /// `landVerified` from step 3 on; the caller holds the item's, main's and the engine repository's locks.
    private func landLocked(key: String, verified: String, mainHead: String, recordPending: (String) throws -> Void) throws -> LandOutcome {
        let git = try MergeInfrastructureError.wrapping { () throws -> GitCommand in
            let git = try freshEngineRepository()
            retireWorkspaceMergeCheckouts()
            return git
        }
        try fetchLandingInputs(git, mainHead: mainHead, verified: verified)
        if try Self.isAncestor(git, verified, of: mainHead) { return .alreadyLanded(mainHead: mainHead) }
        guard let base = try Self.mergeBase(git, mainHead, verified) else {
            throw GitError.failed(command: "merge-base", status: -1, stderr: "item/\(key) shares no history with main")
        }
        if base == mainHead {
            try MergeInfrastructureError.wrapping { try moveMainLocked(from: mainHead, to: verified, recordPending: recordPending) }
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
            try MergeInfrastructureError.wrapping { try Self.clearMergeState(admin: mergeRepositoryPath, detachAt: mainHead) }
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
        try MergeInfrastructureError.wrapping { try Self.clearMergeState(admin: mergeRepositoryPath, detachAt: rebased) }
        let nowMain = try MergeInfrastructureError.wrapping { try head(of: Self.mainRef) }
        guard nowMain == mainHead else { return .mainMoved(head: nowMain) }
        try checkRebase(git, rebased, of: verified, base: base, onto: mainHead, key: key)
        // The result's objects go back into the workspace (a bundle made by the engine's own repository); the branch then
        // carries what will be checked and landed. An author who moved it meanwhile wins nothing.
        let moved = try MergeInfrastructureError.wrapping { () throws -> GitCommand.Output in
            try handBack(git, result: rebased, prerequisites: [mainHead, verified])
            return try main.run(["update-ref", branchRef(key: key), rebased, verified], allowFailure: true)
        }
        guard moved.status == 0 else { return .branchMoved(head: try MergeInfrastructureError.wrapping { try head(of: branchRef(key: key)) }) }
        syncItemCheckout(key: key, to: rebased)
        return .rebased(head: rebased)
    }

    /// Throws unless `rebased` is exactly `verified` replayed on `onto`: `onto` is its ancestor, it adds as many commits as
    /// `verified` has (merges aside) since `base`, and its tree is what git merges `base..verified` into `onto` to. Everything
    /// is asked of the engine repository (whose config and attributes are written again right before the merge-tree).
    private func checkRebase(_ git: GitCommand, _ rebased: String, of verified: String, base: String, onto: String, key: String) throws {
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

    /// Removes every in-progress operation's state from the merge repository's git dir (the engine's own rebase, or one
    /// planted there) without asking git to undo it, and points its `HEAD` straight at `commit` (detached).
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

    // MARK: Agent-writable state that blocks a merge

    /// A git lock file nobody has touched for this long is left behind, not held: git holds its locks for milliseconds.
    static let staleLockAge: TimeInterval = 30

    /// Removes the lock files of the workspace repository that a landing of `key` needs (`main`'s and the item branch's ref
    /// locks, `packed-refs.lock`, `HEAD.lock`, the root checkout's `index.lock`) when nobody has touched them for
    /// `staleLockAge`. The workspace repository is agent-writable, so such a file is tampering, not the company's fault: the
    /// names removed are returned for the owner's alert. A lock younger than that is left alone (git may be using it); the
    /// step that needs it then fails as the company's fault and is retried. Links are removed, never followed.
    private func clearStaleWorkspaceLocks(key: String) throws -> [String] {
        let fm = FileManager.default
        var removed: [String] = []
        for name in ["refs/heads/main.lock", "refs/heads/item/\(key).lock", "packed-refs.lock", "HEAD.lock", "index.lock"] {
            // Never through a directory that was swapped for a link.
            var parent = (name as NSString).deletingLastPathComponent
            var linked = false
            while !parent.isEmpty {
                if Self.isSymlink(gitDir.appending(path: parent)) { linked = true }
                parent = (parent as NSString).deletingLastPathComponent
            }
            let url = gitDir.appending(path: name)
            guard !linked, let attributes = try? fm.attributesOfItem(atPath: url.path) else { continue }
            let touched = attributes[.modificationDate] as? Date ?? .distantPast
            guard Date().timeIntervalSince(touched) >= Self.staleLockAge else { continue }
            try fm.removeItem(at: url)
            removed.append(name)
        }
        return removed
    }

    // MARK: The engine's merge repository

    /// Exclusion for the engine's merge repository (landings and merge-check exports), across processes. Taken after main's
    /// lock when both are needed. A lock that cannot be taken is the company's fault.
    private func withEngineLock<T>(_ body: () throws -> T) throws -> T {
        try withLockFile(name: "+engine", what: "the merge repository", infrastructure: true, body)
    }

    /// The engine's own repository for merge work, made afresh (the caller holds the engine lock): whatever was at
    /// `<home>/run/merge/<companyId>.git` and its private working tree `<home>/run/merge/<companyId>-wt` is deleted (a link is
    /// removed, never followed) and a new repository is initialized there, outside the workspace and every directory an agent
    /// is given. No object, ref, rebase state or setting from an earlier use (or written into it since) survives; objects come
    /// in only through `fetchIntoEngine`. Refuses to run on a git older than 2.43.
    private func freshEngineRepository() throws -> GitCommand {
        try GitCommand.requireAttributeSource()
        let fm = FileManager.default
        let repo = mergeRepositoryPath, tree = mergeWorktreePath
        try fm.createDirectory(at: mergeDirectory.deletingLastPathComponent(), withIntermediateDirectories: true,
                               attributes: [.posixPermissions: 0o700])
        for url in [repo, tree] where (try? fm.attributesOfItem(atPath: url.path)) != nil { try fm.removeItem(at: url) }
        try fm.createDirectory(at: tree, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
        let git = engineCommand
        try git.run(["init", "--quiet", "--template="])
        try assertEngineState()
        return git
    }

    /// Writes the engine repository's `config` and `info/attributes` in full (no includes, no hooks, no fsmonitor, no
    /// `merge.*`, `filter.*` or `diff.*` drivers; `* merge=text -filter -diff -text ...`) and removes every file that could
    /// steer git there (`config.worktree`, `commondir`, `shallow`, grafts, alternates, linked worktrees, hooks). Called when
    /// the repository is made and again right before the checkout that starts a rebase, the merge-tree and the archive. Every
    /// command also runs through the shared `GitCommand` hardening (`engineCommand`): the forced `-c` overrides, no global or
    /// system config, `--attr-source` set to the empty tree, the config allowlist, and `engineAttributes` kept in place.
    private func assertEngineState() throws {
        let fm = FileManager.default
        let repo = mergeRepositoryPath
        guard !Self.isSymlink(repo), fm.fileExists(atPath: repo.appending(path: "objects").path) else {
            throw GitError.failed(command: "merge repository", status: -1, stderr: "the engine's merge repository is missing")
        }
        let config = repo.appending(path: "config")
        if Self.isSymlink(config) { try fm.removeItem(at: config) }
        try Self.engineConfig.write(to: config, atomically: true, encoding: .utf8)
        let info = repo.appending(path: "info", directoryHint: .isDirectory)
        if Self.isSymlink(info) { try fm.removeItem(at: info) }
        try fm.createDirectory(at: info, withIntermediateDirectories: true)
        let attributes = info.appending(path: "attributes")
        if Self.isSymlink(attributes) { try fm.removeItem(at: attributes) }
        try Self.engineAttributes.write(to: attributes, atomically: true, encoding: .utf8)
        for name in ["config.worktree", "commondir", "shallow", "info/grafts", "objects/info/alternates", "objects/info/http-alternates",
                     "worktrees", "hooks"] {
            let url = repo.appending(path: name)
            if (try? fm.attributesOfItem(atPath: url.path)) != nil { try fm.removeItem(at: url) }
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
    private func fetchLandingInputs(_ engine: GitCommand, mainHead: String, verified: String) throws {
        try MergeInfrastructureError.wrapping { try refuseShallowWorkspace() }
        do {
            try fetchIntoEngine(engine, commits: [mainHead, verified])
        } catch {
            do { try fetchIntoEngine(engine, commits: [mainHead]) } catch let mainError {
                throw MergeInfrastructureError(underlying: GitError.failed(
                    command: "fetch main", status: -1, stderr: "main's history (\(mainHead.prefix(7))) could not be fetched: \(mainError)"))
            }
            throw error
        }
    }

    /// Fetches exactly `commits` from the workspace repository into the engine repository, by SHA: no refs, no tags, no
    /// `FETCH_HEAD`, so `refs/replace/*` and every other agent-made ref stay behind. Always a real transfer (`--refetch`: git
    /// never skips a commit because it seems to be there), every object checked by fsck, over the local file transport only
    /// (`protocol.allow=never`, `protocol.file.allow=always`, the stock `git-upload-pack`). A commit git cannot hand over (a
    /// missing or corrupt object) fails as a `GitError`.
    private func fetchIntoEngine(_ engine: GitCommand, commits: [String]) throws {
        var fetcher = engine
        fetcher.allowsLocalFetch = true
        try fetcher.run(Self.fetchFlags + [gitDir.path] + commits)
    }

    /// With `GitCommand.configFlags` (`protocol.allow=never`) and `allowsLocalFetch` (`protocol.file.allow=always`).
    private static let fetchFlags = [
        "-c", "protocol.version=2",
        "-c", "uploadpack.allowAnySHA1InWant=true",
        "-c", "fetch.fsckObjects=true", "-c", "transfer.fsckObjects=true", "-c", "fetch.unpackLimit=1", "-c", "transfer.unpackLimit=1",
        "fetch", "--quiet", "--refetch", "--no-tags", "--no-write-fetch-head", "--no-recurse-submodules", "--no-auto-gc",
        "--upload-pack=git-upload-pack",
    ]

    /// The engine's own step of handing the result of a rebase to the workspace: the engine repository bundles `result`'s
    /// objects on top of `prerequisites` and the workspace repository unbundles them (`git bundle unbundle`, which only runs
    /// `index-pack`). No transport runs in the workspace, so nothing in its config (`url.*.insteadOf`, `core.sshCommand`,
    /// remotes) takes part.
    private func handBack(_ engine: GitCommand, result: String, prerequisites: [String]) throws {
        let fm = FileManager.default
        let ref = "refs/brahma/result"
        try engine.run(["update-ref", "--no-deref", ref, result])
        let bundle = URL(fileURLWithPath: mergeDirectory.path + "-result.bundle")
        if (try? fm.attributesOfItem(atPath: bundle.path)) != nil { try fm.removeItem(at: bundle) }
        defer { try? fm.removeItem(at: bundle) }
        try engine.run(["bundle", "create", "--quiet", bundle.path, ref] + prerequisites.map { "^\($0)" })
        try main.run(["bundle", "unbundle", bundle.path])
        guard try main.run(["cat-file", "-e", "\(result)^{commit}"], allowFailure: true).status == 0 else {
            throw GitError.failed(command: "bundle unbundle", status: -1, stderr: "\(result.prefix(7)) did not reach the workspace")
        }
    }

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
            let staged = main.withIndex(index)
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

    /// A clean detached checkout of exactly `commit` at `<ws>/.brahma/wt-check/<runId>`, for an engine-run check of a
    /// submission. Anything left at that place by a crashed run is removed first.
    public func addRunWorktree(runId: String, commit: String) throws -> URL {
        let path = try freshRunPlace(runId: runId, commit: commit)
        try main.run(["worktree", "add", "--quiet", "--detach", path.path, commit])
        return path
    }

    /// The merge check of a rebased commit: a `.git`-free export of exactly `commit` at `<ws>/.brahma/wt-check/<runId>`
    /// (the same place as a submission's check). Under the engine repository's lock the commit is fetched (fsck'd, by SHA)
    /// into a fresh engine repository, written out with `git archive` (no attribute of the tree leaves anything out or
    /// substitutes anything) and unpacked into a new directory. No worktree is linked to the engine repository, so the check
    /// has no path back to its config or objects. Anything left at that place by a crashed run is removed first.
    public func addEngineExport(runId: String, commit: String) throws -> URL {
        let path = try freshRunPlace(runId: runId, commit: commit)
        let fm = FileManager.default
        let archive = URL(fileURLWithPath: mergeDirectory.path + "-export-\(runId).tar")
        defer { try? fm.removeItem(at: archive) }
        try withEngineLock {
            let git = try MergeInfrastructureError.wrapping { try freshEngineRepository() }
            try MergeInfrastructureError.wrapping { try refuseShallowWorkspace() }
            try fetchIntoEngine(git, commits: [commit])
            try MergeInfrastructureError.wrapping {
                if (try? fm.attributesOfItem(atPath: archive.path)) != nil { try fm.removeItem(at: archive) }
                try assertEngineState()
            }
            // The commit is in the engine repository by now (fetched and fsck'd): writing it out is the engine's own step.
            try MergeInfrastructureError.wrapping {
                _ = try git.run(["archive", "--format=tar", "--output=\(archive.path)", "\(commit)^{commit}"])
            }
        }
        do {
            try MergeInfrastructureError.wrapping {
                try fm.createDirectory(at: path, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
                try Self.untar(archive, into: path)
            }
            // A tree cannot hold `.git` (fsck refuses it on the fetch); an export never has one either way.
            if (try? fm.attributesOfItem(atPath: path.appending(path: ".git").path)) != nil {
                throw GitError.failed(command: "archive", status: -1, stderr: "the export of \(commit.prefix(7)) holds a .git")
            }
        } catch {
            try? fm.removeItem(at: path)
            throw error
        }
        return path
    }

    /// `<ws>/.brahma/wt-check/<runId>`, with whatever a crashed run left there removed.
    private func freshRunPlace(runId: String, commit: String) throws -> URL {
        try Self.validRunId(runId); try Self.validCommit(commit)
        let paths = CheckPaths(workspace: root)
        if Self.isSymlink(paths.runWorktreesRoot) {
            throw GitError.failed(command: "worktree add \(runId)", status: -1, stderr: "\(paths.runWorktreesRoot.path) is a link")
        }
        try FileManager.default.createDirectory(at: paths.runWorktreesRoot, withIntermediateDirectories: true)
        removeRunWorktree(runId: runId)
        return paths.runWorktree(runId: runId)
    }

    /// Unpacks a tar file made by `git archive` with `/usr/bin/tar`, which refuses absolute paths, `..` and extraction
    /// through links.
    private static func untar(_ archive: URL, into dir: URL) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/tar")
        process.arguments = ["-x", "-f", archive.path, "-C", dir.path]
        process.environment = ChildEnvironment.make(base: ProcessInfo.processInfo.environment, purpose: .general)
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch {
            throw GitError.failed(command: "archive", status: -1, stderr: "could not unpack the export: \(error)")
        }
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw GitError.failed(command: "archive", status: process.terminationStatus, stderr: "could not unpack the export")
        }
    }

    /// Removes one run's checkout or export (whatever the check left in it); never throws.
    public func removeRunWorktree(runId: String) {
        guard (try? Self.validRunId(runId)) != nil else { return }
        let fm = FileManager.default
        let path = CheckPaths(workspace: root).runWorktree(runId: runId)
        if Self.isSymlink(path) {
            try? fm.removeItem(at: path)
        } else if fm.fileExists(atPath: path.path) {
            if fm.fileExists(atPath: path.appending(path: ".git").path) {
                _ = try? main.run(["worktree", "remove", "--force", path.path], allowFailure: true)
            }
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
            try addAll(git)
            let staged = try git.run(["diff", "--cached", "--quiet"], allowFailure: true)
            if staged.status == 0 { return nil }
            guard staged.status == 1 else {
                throw GitError.failed(command: "diff --cached --quiet", status: staged.status, stderr: staged.stderr)
            }
            try git.run(["commit", "--quiet", "--no-verify", "-m", message])
            return try git.run(["rev-parse", "HEAD"]).text
        }
        let ref = branchRef(key: key)
        guard let tip = try ownTip(git, ref) else {
            throw GitError.failed(command: "commit \(key)", status: -1, stderr: "\(ref) does not exist")
        }
        testHook?("checked")
        let index = FileManager.default.temporaryDirectory.appending(path: "brahma-index-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: index) }
        let private_ = git.withIndex(index)
        try private_.run(["read-tree", tip])
        try addAll(private_)
        let tree = try private_.run(["write-tree"]).text
        if tree == (try git.run(["rev-parse", "--verify", "\(tip)^{tree}"]).text) { try verifyAfter(key: key); return nil }
        let commit = try git.run(["commit-tree", tree, "-p", tip, "-m", message]).text
        // `--no-deref`: should the item ref have become symbolic meanwhile, it is overwritten, never followed to its target.
        try git.run(["update-ref", "--no-deref", "-m", message, ref, commit, tip])
        // The worktree's own index follows the branch, so the checkout is clean afterwards.
        try? git.run(["read-tree", commit])
        try verifyAfter(key: key)
        return commit
    }

    /// `git add -A`, but never into a nested repository the index already records (a gitlink): there `add` runs `git status`
    /// inside it, with that repository's own config and attributes, filters and all. Gitlinks stay as recorded; a new
    /// nested repository is still added (as a gitlink, without running anything in it).
    static let maxGitlinks = 1000

    private func addAll(_ git: GitCommand) throws {
        let listing = try git.run(["ls-files", "-s", "-z"])
        if listing.cut { throw GitError.failed(command: "ls-files", status: -1, stderr: "the index listing is too long") }
        var excludes: [String] = []
        for entry in listing.stdout.split(separator: 0, omittingEmptySubsequences: true) where entry.starts(with: Data("160000 ".utf8)) {
            guard let tab = entry.firstIndex(of: UInt8(ascii: "\t")),
                  let path = String(data: Data(entry[entry.index(after: tab)...]), encoding: .utf8) else {
                throw GitError.failed(command: "add", status: -1, stderr: "a nested repository has a path that is not UTF-8")
            }
            excludes.append(":(exclude,literal)\(path)")
        }
        guard excludes.count <= Self.maxGitlinks else {
            throw GitError.failed(command: "add", status: -1, stderr: "more than \(Self.maxGitlinks) nested repositories")
        }
        try git.run(["add", "-A", "--", "."] + excludes)
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
        !(try context(for: dir).run(["status", "--porcelain", "--ignore-submodules=dirty"]).text.isEmpty)
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

    /// The size of the change between two commits, for risk-tiered review: added plus deleted lines over all files, every path
    /// touched (renames are counted as a delete and an add, so both names are listed), and whether a binary file changed or
    /// the listing was cut (either makes the change unmeasurable).
    public func changeStats(base: String, head: String) throws -> (lines: Int, paths: [String], binary: Bool, truncated: Bool) {
        try Self.validRef(base); try Self.validRef(head)
        let out = try main.run(["diff", "--numstat", "-z", "--no-renames", "--no-ext-diff", "--no-textconv", "--no-color", base, head],
                               maxOutput: 1 << 20)
        var lines = 0, binary = false
        var paths: [String] = []
        for record in String(decoding: out.stdout, as: UTF8.self).split(separator: "\0", omittingEmptySubsequences: true) {
            let fields = record.split(separator: "\t", maxSplits: 2, omittingEmptySubsequences: false)
            guard fields.count == 3 else { return (lines, paths, binary, true) }
            if let added = Int(fields[0]), let deleted = Int(fields[1]) { lines += added + deleted } else { binary = true }
            paths.append(String(fields[2]))
        }
        return (lines, paths, binary, out.cut)
    }

    /// `"<short sha> <subject>"` for the newest `limit` commits in `base..head`.
    public func log(base: String, head: String, limit: Int = 5) throws -> [String] {
        try Self.validRef(base); try Self.validRef(head)
        let out = try main.run(["log", "--no-color", "--no-show-signature", "--format=%h %s", "-n", String(max(limit, 1)), "\(base)..\(head)"])
        return out.text.split(separator: "\n").map(String.init)
    }
}
