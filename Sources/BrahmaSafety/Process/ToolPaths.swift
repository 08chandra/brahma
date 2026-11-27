import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Why the engine's tools could not be resolved (`ToolPaths.resolve`).
public enum ToolPathsError: Error, Equatable, Sendable, CustomStringConvertible {
    /// No `git` in a safe `PATH` directory.
    case gitMissing
    /// The `git` found is older than 2.43 (3a's `--attr-source` floor); its version, or "unknown".
    case gitTooOld(String)
    /// No `claude` in a safe `PATH` directory. The CLI may run without it; the orchestrator's turns need it.
    case claudeMissing
    /// Asked before this process installed its tools with the real forbidden roots (`install`, `installFromEngine`; Ruling
    /// S-c1): nothing is ever looked up on `PATH` without them.
    case notInstalled

    public var description: String {
        switch self {
        case .gitMissing:
            return "no git found in a safe PATH directory (\(ToolPaths.safeDirectoryRule)); install git 2.43 or newer"
        case .gitTooOld(let version):
            return "git \(version) is older than 2.43; Brahma needs git 2.43 or newer"
        case .claudeMissing:
            return "no claude found in a safe PATH directory (\(ToolPaths.safeDirectoryRule)); is Claude Code installed?"
        case .notInstalled:
            return "Brahma's tools are not resolved yet in this process (the company workspaces and data homes they must lie "
                + "outside are not known); nothing is looked up on PATH before they are"
        }
    }
}

/// The engine's tools by absolute path (Plan S, spec §6.5, B9), resolved once at engine start: a later `PATH` change takes
/// effect at the next start. Every child the engine starts names its executable from here (`Spawn` refuses anything else).
///
/// - Candidate directories are the engine's own `PATH` entries that are absolute, safe to name in a profile, exist, belong to
///   root or this user, are not world-writable, are not group-writable unless the group is `trustedWriterGroup` (macOS
///   `admin`: Homebrew, Ruling S5-1) and the path lies inside a `trustedGroupPrefixes` entry (the Homebrew prefix only,
///   Ruling S5-1b), and lie inside no company workspace or data home (resolved paths, `SandboxPath`).
/// - `git`, `claude` and `curl` are the first regular executable of that name there (`curl` prefers `/usr/bin/curl`: LibreSSL
///   with a file CA bundle). The executable is judged where it resolves: that file meets the same owner and mode rule, and
///   the directory it lies in is a candidate directory too (so a link out of a safe directory into a workspace or a shared
///   writable directory is skipped).
/// - The macOS `/usr/bin/git` shim (any spelling that resolves to it) is replaced by its real target (`xcrun --find git`,
///   asked once per process), which must pass the same rules; inside a sandbox the shim would need xcrun's cache writes.
/// - `sandbox-exec`, `/bin/sh`, `unzip` and `tar` are fixed absolute paths.
/// - git must be 2.43 or newer.
public struct ToolPaths: Sendable, Equatable {
    public let git: String
    /// Nil when no `claude` was found (the CLI may run without it; `requireClaude`).
    public let claude: String?
    public let unzip: String
    public let tar: String
    public let curl: String
    public let sh: String
    public let sandboxExec: String
    /// `git --version`'s number (`2.50.1`).
    public let gitVersion: String

    public init(git: String, claude: String?, unzip: String = ToolPaths.fixedUnzip, tar: String = ToolPaths.fixedTar,
                curl: String = ToolPaths.preferredCurl, sh: String = ToolPaths.fixedSh,
                sandboxExec: String = ToolPaths.fixedSandboxExec, gitVersion: String) {
        self.git = git; self.claude = claude; self.unzip = unzip; self.tar = tar; self.curl = curl; self.sh = sh
        self.sandboxExec = sandboxExec; self.gitVersion = gitVersion
    }

    public static let fixedSh = "/bin/sh"
    public static let fixedSandboxExec = "/usr/bin/sandbox-exec"
    public static let fixedUnzip = "/usr/bin/unzip"
    public static let fixedTar = "/usr/bin/tar"
    public static let preferredCurl = "/usr/bin/curl"
    /// The macOS xcrun shim, replaced by its real target.
    public static let gitShim = "/usr/bin/git"
    /// git 2.43: `--attr-source` reaches the child git processes a command spawns (3a's floor).
    public static let minimumGitMajor = 2
    public static let minimumGitMinor = 43
    /// How long `git --version` or `xcrun --find` may take.
    public static let probeTimeout: Duration = .seconds(30)

    /// The rule a candidate directory meets, as the errors and the doctor say it.
    public static let safeDirectoryRule = "absolute, owned by root or you, not world-writable, not group-writable unless the group is admin inside the Homebrew prefix only (/opt/homebrew, /usr/local), outside every company workspace and data home"

    /// macOS `admin` (gid 80): Homebrew's prefix is group-writable by it; its members can already sudo (Ruling S5-1). A
    /// constant (no group lookup); membership is not required. None elsewhere.
    #if os(macOS)
    public static let trustedWriterGroup: gid_t? = 80
    #else
    public static let trustedWriterGroup: gid_t? = nil
    #endif
    /// Where the trusted writer group's exception applies at all (Ruling S5-1b): the Homebrew prefixes, judged on resolved
    /// paths with component boundaries (`/opt/homebrewX` is outside). Anywhere else a group-writable path is refused,
    /// whatever its group.
    public static let trustedGroupPrefixes = ["/opt/homebrew", "/usr/local"]

    /// The `claude` to start, or `ToolPathsError.claudeMissing`.
    public func requireClaude() throws -> String {
        guard let claude else { throw ToolPathsError.claudeMissing }
        return claude
    }

    // MARK: Resolution

    /// The candidate directories of `path` (see the type's comment), in `PATH` order, each once.
    public static func candidateDirectories(path: String, forbiddenRoots: [URL],
                                            trustedGroup: gid_t? = ToolPaths.trustedWriterGroup,
                                            trustedPrefixes: [String] = ToolPaths.trustedGroupPrefixes) -> [String] {
        let forbidden = forbiddenRoots.map { SandboxPath.resolve($0.path) }
        var seen: Set<String> = []
        var out: [String] = []
        for entry in path.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        where seen.insert(entry).inserted && isSafeDirectory(entry, forbidden: forbidden, trustedGroup: trustedGroup,
                                                                                          trustedPrefixes: trustedPrefixes) {
            out.append(entry)
        }
        return out
    }

    /// Resolves the tools from `path` (the engine's `PATH`). `xcrunFind` answers `xcrun --find <name>` (the shim's target);
    /// `gitVersion` answers the version number of a git (`git --version`). Both are seams for tests, as are `trustedGroup` and
    /// `trustedPrefixes`.
    public static func resolve(path: String, forbiddenRoots: [URL], xcrunFind: (String) -> String?,
                               gitVersion: (String) -> String? = ToolPaths.probeGitVersion,
                               trustedGroup: gid_t? = ToolPaths.trustedWriterGroup,
                               trustedPrefixes: [String] = ToolPaths.trustedGroupPrefixes) -> Result<ToolPaths, ToolPathsError> {
        let forbidden = forbiddenRoots.map { SandboxPath.resolve($0.path) }
        let dirs = candidateDirectories(path: path, forbiddenRoots: forbiddenRoots, trustedGroup: trustedGroup,
                                        trustedPrefixes: trustedPrefixes)
        func usable(_ path: String) -> Bool {
            isUsableExecutable(path, forbidden: forbidden, trustedGroup: trustedGroup, trustedPrefixes: trustedPrefixes)
        }
        var found: String?
        for dir in dirs {
            let candidate = dir + "/git"
            guard usable(candidate) else { continue }
            if isShim(candidate) {
                if let real = xcrunFind("git"), !isShim(real), usable(real) {
                    found = real
                    break
                }
                #if os(macOS)
                continue          // the shim alone would need xcrun (and its cache writes) at every call
                #endif
            }
            found = candidate
            break
        }
        guard let git = found else { return .failure(.gitMissing) }
        let asked = gitVersion(git)
        guard let version = asked, isSupportedGit(version) else { return .failure(.gitTooOld(asked ?? "unknown")) }
        let curl = usable(preferredCurl) ? preferredCurl
            : (find("curl", in: dirs, forbidden: forbidden, trustedGroup: trustedGroup, trustedPrefixes: trustedPrefixes) ?? preferredCurl)
        let claude = find("claude", in: dirs, forbidden: forbidden, trustedGroup: trustedGroup, trustedPrefixes: trustedPrefixes)
        return .success(ToolPaths(git: git, claude: claude,
                                  curl: curl, gitVersion: version))
    }

    /// The first usable executable `name` (a bare name) in the candidate directories of `path`, under the same rules as
    /// `resolve`; nil when there is none or `name` is not a bare name.
    public static func lookup(_ name: String, path: String, forbiddenRoots: [URL],
                              trustedGroup: gid_t? = ToolPaths.trustedWriterGroup,
                              trustedPrefixes: [String] = ToolPaths.trustedGroupPrefixes) -> String? {
        find(name, in: candidateDirectories(path: path, forbiddenRoots: forbiddenRoots, trustedGroup: trustedGroup,
                                            trustedPrefixes: trustedPrefixes),
             forbidden: forbiddenRoots.map { SandboxPath.resolve($0.path) }, trustedGroup: trustedGroup, trustedPrefixes: trustedPrefixes)
    }

    /// The first usable executable `name` in `dirs`; nil when none (or `name` is not a bare name).
    static func find(_ name: String, in dirs: [String], forbidden: [String], trustedGroup: gid_t?, trustedPrefixes: [String]) -> String? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        return dirs.lazy.map { $0 + "/" + name }.first {
            isUsableExecutable($0, forbidden: forbidden, trustedGroup: trustedGroup, trustedPrefixes: trustedPrefixes)
        }
    }

    /// The one owner and mode rule (Ruling S5-1), for a directory and an executable alike: owned by root or this user, never
    /// world-writable, group-writable only when its group is `trustedGroup` AND `resolved` (the path `st` describes, already
    /// resolved) lies inside one of `trustedPrefixes` (Ruling S5-1b: the Homebrew prefixes only; resolved, component-bounded).
    static func isTrustedOwnerAndMode(_ st: stat, resolved: String, trustedGroup: gid_t?, trustedPrefixes: [String]) -> Bool {
        guard st.st_uid == 0 || st.st_uid == getuid() else { return false }
        guard st.st_mode & S_IWOTH == 0 else { return false }
        guard st.st_mode & S_IWGRP == 0 else {
            guard let trustedGroup, st.st_gid == trustedGroup else { return false }
            return trustedPrefixes.contains { SandboxPath.isInside(resolved, SandboxPath.resolve($0)) }
        }
        return true
    }

    /// An absolute directory, safe to name in a profile, that exists (links followed), meets the owner and mode rule, and
    /// resolves inside no forbidden root (already resolved).
    static func isSafeDirectory(_ dir: String, forbidden: [String], trustedGroup: gid_t?, trustedPrefixes: [String]) -> Bool {
        guard dir.hasPrefix("/"), !SandboxPath.isUnsafe(dir) else { return false }
        var st = stat()
        guard stat(dir, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return false }
        let real = SandboxPath.resolve(dir)
        guard isTrustedOwnerAndMode(st, resolved: real, trustedGroup: trustedGroup, trustedPrefixes: trustedPrefixes) else { return false }
        return !forbidden.contains { SandboxPath.isInside(real, $0) }
    }

    /// An executable judged where it resolves: a regular file this process may execute, meeting the owner and mode rule,
    /// lying inside no forbidden root, in a directory that is itself safe (a link out of a safe directory into a workspace
    /// or a shared writable directory is refused).
    static func isUsableExecutable(_ path: String, forbidden: [String], trustedGroup: gid_t?, trustedPrefixes: [String]) -> Bool {
        guard path.hasPrefix("/"), !SandboxPath.isUnsafe(path) else { return false }
        let real = SandboxPath.resolve(path)
        guard real.hasPrefix("/") else { return false }
        var st = stat()
        guard stat(real, &st) == 0, st.st_mode & S_IFMT == S_IFREG, access(real, X_OK) == 0 else { return false }
        guard isTrustedOwnerAndMode(st, resolved: real, trustedGroup: trustedGroup, trustedPrefixes: trustedPrefixes) else { return false }
        guard !forbidden.contains(where: { SandboxPath.isInside(real, $0) }) else { return false }
        return isSafeDirectory(parent(of: real), forbidden: forbidden, trustedGroup: trustedGroup, trustedPrefixes: trustedPrefixes)
    }

    /// `path` names the macOS git shim, in whatever spelling (`/usr/bin//git`, `/usr/../usr/bin/git`, a link to it).
    static func isShim(_ path: String) -> Bool {
        SandboxPath.key(SandboxPath.resolve(path)) == SandboxPath.key(gitShim)
    }

    static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/"), slash != path.startIndex else { return "/" }
        return String(path[..<slash])
    }

    /// `major.minor` at least 2.43.
    public static func isSupportedGit(_ version: String) -> Bool {
        let numbers = version.split(whereSeparator: { !$0.isNumber }).prefix(2).compactMap { Int($0) }
        guard let major = numbers.first else { return false }
        let minor = numbers.count > 1 ? numbers[1] : 0
        return major > minimumGitMajor || major == minimumGitMajor && minor >= minimumGitMinor
    }

    /// The first `N.N[.N]` in `text` (`git version 2.50.1 (Apple Git-155)` → `2.50.1`).
    public static func versionNumber(in text: String) -> String? {
        guard let match = text.range(of: "[0-9]+\\.[0-9]+(\\.[0-9]+)?", options: .regularExpression) else { return nil }
        return String(text[match])
    }

    // MARK: Probes (asked once per process per input)

    private final class Memo: @unchecked Sendable {
        let lock = NSLock()
        var versions: [String: String?] = [:]
        var found: [String: String?] = [:]
    }
    private static let memo = Memo()

    /// `<git> --version`'s number, asked once per git per process; nil when it cannot be read.
    public static func probeGitVersion(_ git: String) -> String? {
        if let known = memo.lock.withLock({ memo.versions[git] }) { return known }
        var answer: String?
        do {
            let out = try Spawn.run(git, ["--version"], cwd: URL(fileURLWithPath: "/", isDirectory: true),
                                    env: ["PATH": "/usr/bin:/bin", "GIT_CONFIG_NOSYSTEM": "1", "GIT_CONFIG_GLOBAL": "/dev/null"],
                                    timeout: probeTimeout, outputCap: 4096)
            if out.status == 0 { answer = versionNumber(in: String(decoding: out.stdout, as: UTF8.self)) }
        } catch {
            answer = nil
        }
        memo.lock.withLock { memo.versions[git] = .some(answer) }
        return answer
    }

    /// `xcrun --find <name>` (macOS), asked once per name per process; nil elsewhere or when it cannot answer.
    public static func systemXcrunFind(_ name: String) -> String? {
        #if os(macOS)
        if let known = memo.lock.withLock({ memo.found[name] }) { return known }
        var env = ["PATH": "/usr/bin:/bin"]
        for key in ["DEVELOPER_DIR", "HOME", "TMPDIR"] { if let v = ProcessInfo.processInfo.environment[key] { env[key] = v } }
        var answer: String?
        do {
            let out = try Spawn.run("/usr/bin/xcrun", ["--find", name], cwd: URL(fileURLWithPath: "/", isDirectory: true), env: env,
                                    timeout: probeTimeout, outputCap: 4096)
            let text = String(decoding: out.stdout, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            if out.status == 0, text.hasPrefix("/"), !text.contains("\n") { answer = text }
        } catch {
            answer = nil
        }
        memo.lock.withLock { memo.found[name] = .some(answer) }
        return answer
        #else
        return nil
        #endif
    }

    // MARK: The engine's tools (one per process)

    private final class Slot: @unchecked Sendable {
        let lock = NSLock()
        var result: Result<ToolPaths, ToolPathsError>?
        var path = ""
        var forbidden: [URL] = []
    }
    private static let processSlot = Slot()
    /// `withIsolatedSlot`'s slot (tests), else nil.
    @TaskLocal private static var isolatedSlot: Slot?
    private static var slot: Slot { isolatedSlot ?? processSlot }

    /// The engine's tools, as the last `install` / `installFromEngine` of this process set them; `.notInstalled` before any
    /// (Ruling S-c1: no lazy, rootless resolution from `PATH`, ever).
    public static func engine() -> Result<ToolPaths, ToolPathsError> {
        slot.lock.withLock { slot.result } ?? .failure(.notInstalled)
    }

    /// Resolves from `path` (this process's `PATH`) with `forbiddenRoots` and makes the result the engine's tools, replacing
    /// what an earlier install set (the app's post-login-shell `PATH` wins). Returns it. The engine installs through
    /// `installForEngine` (BrahmaCore: every company workspace and data home); tests install here directly.
    @discardableResult
    public static func install(forbiddenRoots: [URL], path: String = ProcessInfo.processInfo.environment["PATH"] ?? "")
        -> Result<ToolPaths, ToolPathsError> {
        let resolved = resolve(path: path, forbiddenRoots: forbiddenRoots, xcrunFind: systemXcrunFind)
        let target = slot
        target.lock.withLock { target.result = resolved; target.path = path; target.forbidden = forbiddenRoots }
        return resolved
    }

    /// The git an engine handed to a process it started (`brahma mcp --git`, Ruling S5-4), checked again here under the same
    /// rules as `resolve`: absolute, safe to name, a regular executable meeting the owner and mode rule, in a safe directory,
    /// outside every `forbiddenRoots` entry (resolved), not the macOS shim, and 2.43 or newer. Missing or refused: `gitMissing`;
    /// too old: `gitTooOld`. Never a `PATH` walk.
    public static func validateEngineGit(_ git: String?, forbiddenRoots: [URL],
                                         gitVersion: (String) -> String? = ToolPaths.probeGitVersion,
                                         trustedGroup: gid_t? = ToolPaths.trustedWriterGroup,
                                         trustedPrefixes: [String] = ToolPaths.trustedGroupPrefixes) -> Result<ToolPaths, ToolPathsError> {
        let forbidden = forbiddenRoots.map { SandboxPath.resolve($0.path) }
        guard let git, isUsableExecutable(git, forbidden: forbidden, trustedGroup: trustedGroup, trustedPrefixes: trustedPrefixes) else {
            return .failure(.gitMissing)
        }
        #if os(macOS)
        guard !isShim(git) else { return .failure(.gitMissing) }   // the shim would need xcrun (and its cache writes)
        #endif
        let asked = gitVersion(git)
        guard let version = asked, isSupportedGit(version) else { return .failure(.gitTooOld(asked ?? "unknown")) }
        return .success(ToolPaths(git: git, claude: nil, gitVersion: version))
    }

    /// `validateEngineGit`, made this process's tools (no `PATH`: `engineTool` finds nothing else). Returns it.
    @discardableResult
    public static func installFromEngine(git: String?, forbiddenRoots: [URL],
                                         gitVersion: (String) -> String? = ToolPaths.probeGitVersion,
                                         trustedGroup: gid_t? = ToolPaths.trustedWriterGroup,
                                         trustedPrefixes: [String] = ToolPaths.trustedGroupPrefixes) -> Result<ToolPaths, ToolPathsError> {
        let checked = validateEngineGit(git, forbiddenRoots: forbiddenRoots, gitVersion: gitVersion, trustedGroup: trustedGroup,
                                        trustedPrefixes: trustedPrefixes)
        let target = slot
        target.lock.withLock { target.result = checked; target.path = ""; target.forbidden = forbiddenRoots }
        return checked
    }

    /// Test seam (S5 fix 3, R2): `install` into the PROCESS slot, whatever `withIsolatedSlot` the caller runs in, and only
    /// while that slot is still empty (a test process's one seed install; an install that came first is kept). Returns
    /// whether it installed. Internal: reached only through `@testable import`; production installs through `install`.
    @discardableResult
    static func installProcessWide(forbiddenRoots: [URL], path: String = ProcessInfo.processInfo.environment["PATH"] ?? "") -> Bool {
        let target = processSlot
        if isInstalledProcessWide { return false }
        let resolved = resolve(path: path, forbiddenRoots: forbiddenRoots, xcrunFind: systemXcrunFind)
        return target.lock.withLock {
            guard target.result == nil else { return false }
            target.result = resolved; target.path = path; target.forbidden = forbiddenRoots
            return true
        }
    }

    /// Whether the process slot (never an isolated one) holds an install (test seam, S5 fix 3).
    static var isInstalledProcessWide: Bool { processSlot.lock.withLock { processSlot.result != nil } }

    /// Whether this process installed its tools yet (`engine` and `engineTool` refuse with `.notInstalled` until it did).
    public static var isInstalled: Bool { slot.lock.withLock { slot.result != nil } }

    /// Runs `body` against a private, empty slot of its own (a test seam: what `body` installs or asks stays in it, on this
    /// task; work `body` hands to another thread sees the process's slot).
    public static func withIsolatedSlot<T>(_ body: () throws -> T) rethrows -> T {
        try $isolatedSlot.withValue(Slot()) { try body() }
    }

    /// A tool named by its bare name (an owner-configured `claude`, the doctor's `npm`), found in the engine's candidate
    /// directories under the same rules; nil when there is none or `name` is not a bare name. Throws `.notInstalled` before
    /// the process installed its tools (Ruling S-c1). The forbidden roots are the ones known at the last `install` (a company
    /// created since is not among them until the next engine start).
    public static func engineTool(named name: String) throws -> String? {
        let (known, path, forbiddenRoots) = slot.lock.withLock { (slot.result, slot.path, slot.forbidden) }
        guard let known else { throw ToolPathsError.notInstalled }
        if name == "claude", case .success(let tools) = known, let claude = tools.claude { return claude }
        return lookup(name, path: path, forbiddenRoots: forbiddenRoots)
    }

    /// The git paths the helper accepts in a request: the resolved one.
    public static var gitCandidates: Set<String> { gitCandidates(of: engine()) }

    public static func gitCandidates(of result: Result<ToolPaths, ToolPathsError>) -> Set<String> {
        if case .success(let tools) = result { return [tools.git] }
        return []
    }
}
