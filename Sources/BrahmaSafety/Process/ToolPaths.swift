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

    public var description: String {
        switch self {
        case .gitMissing:
            return "no git found in a safe PATH directory (\(ToolPaths.safeDirectoryRule)); install git 2.43 or newer"
        case .gitTooOld(let version):
            return "git \(version) is older than 2.43; Brahma needs git 2.43 or newer"
        case .claudeMissing:
            return "no claude found in a safe PATH directory (\(ToolPaths.safeDirectoryRule)); is Claude Code installed?"
        }
    }
}

/// The engine's tools by absolute path (Plan S, spec §6.5, B9), resolved once at engine start: a later `PATH` change takes
/// effect at the next start. Every child the engine starts names its executable from here (`Spawn` refuses anything else).
///
/// - Candidate directories are the engine's own `PATH` entries that are absolute, exist, belong to root or this user, are
///   neither group- nor world-writable, and lie inside no company workspace or data home (resolved paths, `SandboxPath`).
/// - `git`, `claude` and `curl` are the first regular executable of that name there (`curl` prefers `/usr/bin/curl`: LibreSSL
///   with a file CA bundle). An executable that resolves into a forbidden root is skipped.
/// - The macOS `/usr/bin/git` shim is replaced by its real target (`xcrun --find git`, asked once per process), which must
///   pass the same rules; inside a sandbox the shim would need xcrun's cache writes.
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
    public static let safeDirectoryRule = "absolute, owned by root or you, not group- or world-writable, outside every company workspace and data home"

    /// The `claude` to start, or `ToolPathsError.claudeMissing`.
    public func requireClaude() throws -> String {
        guard let claude else { throw ToolPathsError.claudeMissing }
        return claude
    }

    // MARK: Resolution

    /// The candidate directories of `path` (see the type's comment), in `PATH` order, each once.
    public static func candidateDirectories(path: String, forbiddenRoots: [URL]) -> [String] {
        let forbidden = forbiddenRoots.map { SandboxPath.resolve($0.path) }
        var seen: Set<String> = []
        var out: [String] = []
        for entry in path.split(separator: ":", omittingEmptySubsequences: true).map(String.init)
        where seen.insert(entry).inserted && isSafeDirectory(entry, forbidden: forbidden) {
            out.append(entry)
        }
        return out
    }

    /// Resolves the tools from `path` (the engine's `PATH`). `xcrunFind` answers `xcrun --find <name>` (the shim's target);
    /// `gitVersion` answers the version number of a git (`git --version`). Both are seams for tests.
    public static func resolve(path: String, forbiddenRoots: [URL], xcrunFind: (String) -> String?,
                               gitVersion: (String) -> String? = ToolPaths.probeGitVersion) -> Result<ToolPaths, ToolPathsError> {
        let forbidden = forbiddenRoots.map { SandboxPath.resolve($0.path) }
        let dirs = candidateDirectories(path: path, forbiddenRoots: forbiddenRoots)
        var found: String?
        for dir in dirs {
            let candidate = dir + "/git"
            guard isUsableExecutable(candidate, forbidden: forbidden) else { continue }
            if candidate == gitShim {
                if let real = xcrunFind("git"), real != gitShim, isUsableExecutable(real, forbidden: forbidden),
                   isSafeDirectory(parent(of: real), forbidden: forbidden) {
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
        let curl = isUsableExecutable(preferredCurl, forbidden: forbidden) ? preferredCurl
            : (find("curl", in: dirs, forbidden: forbidden) ?? preferredCurl)
        return .success(ToolPaths(git: git, claude: find("claude", in: dirs, forbidden: forbidden), curl: curl, gitVersion: version))
    }

    /// The first usable executable `name` in `dirs`; nil when none (or `name` is not a bare name).
    static func find(_ name: String, in dirs: [String], forbidden: [String]) -> String? {
        guard !name.isEmpty, !name.contains("/") else { return nil }
        return dirs.lazy.map { $0 + "/" + name }.first { isUsableExecutable($0, forbidden: forbidden) }
    }

    /// An absolute directory that exists, belongs to root or this user, is neither group- nor world-writable, and resolves
    /// inside no forbidden root (already resolved).
    static func isSafeDirectory(_ dir: String, forbidden: [String]) -> Bool {
        guard dir.hasPrefix("/") else { return false }
        var st = stat()
        guard stat(dir, &st) == 0, st.st_mode & S_IFMT == S_IFDIR else { return false }
        guard st.st_uid == 0 || st.st_uid == getuid() else { return false }
        guard st.st_mode & (S_IWGRP | S_IWOTH) == 0 else { return false }
        let real = SandboxPath.resolve(dir)
        return !forbidden.contains { SandboxPath.isInside(real, $0) }
    }

    /// A regular file this process may execute, whose resolved path lies inside no forbidden root (a link out of a safe
    /// directory into a workspace is refused).
    static func isUsableExecutable(_ path: String, forbidden: [String]) -> Bool {
        guard path.hasPrefix("/") else { return false }
        var st = stat()
        guard stat(path, &st) == 0, st.st_mode & S_IFMT == S_IFREG, access(path, X_OK) == 0 else { return false }
        let real = SandboxPath.resolve(path)
        return !forbidden.contains { SandboxPath.isInside(real, $0) }
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
    private static let slot = Slot()

    /// The engine's tools: what `install` set (the orchestrator at its start, the CLI when it opens the store), else resolved
    /// on first use from this process's `PATH` (no forbidden roots known yet) and kept.
    public static func engine() -> Result<ToolPaths, ToolPathsError> {
        if let known = slot.lock.withLock({ slot.result }) { return known }
        let path = ProcessInfo.processInfo.environment["PATH"] ?? ""
        let resolved = resolve(path: path, forbiddenRoots: [], xcrunFind: systemXcrunFind)
        return slot.lock.withLock {
            if let known = slot.result { return known }
            slot.result = resolved; slot.path = path; slot.forbidden = []
            return resolved
        }
    }

    /// Resolves from this process's `PATH` with `forbiddenRoots` (the company workspaces and data homes) and makes the result
    /// the engine's tools. Returns it.
    @discardableResult
    public static func install(forbiddenRoots: [URL], path: String = ProcessInfo.processInfo.environment["PATH"] ?? "")
        -> Result<ToolPaths, ToolPathsError> {
        let resolved = resolve(path: path, forbiddenRoots: forbiddenRoots, xcrunFind: systemXcrunFind)
        slot.lock.withLock { slot.result = resolved; slot.path = path; slot.forbidden = forbiddenRoots }
        return resolved
    }

    /// Whether the engine's tools have been resolved in this process yet (`engine` would otherwise run git to resolve them).
    public static var isResolved: Bool { slot.lock.withLock { slot.result != nil } }

    /// A tool named by its bare name (an owner-configured `claude`, the doctor's `npm`), found in the engine's candidate
    /// directories under the same rules; nil when there is none or `name` is not a bare name.
    public static func engineTool(named name: String) -> String? {
        let resolved = engine()
        if name == "claude", case .success(let tools) = resolved, let claude = tools.claude { return claude }
        let (path, forbiddenRoots) = slot.lock.withLock { (slot.path, slot.forbidden) }
        return find(name, in: candidateDirectories(path: path, forbiddenRoots: forbiddenRoots),
                    forbidden: forbiddenRoots.map { SandboxPath.resolve($0.path) })
    }

    /// The git paths the helper accepts in a request: the resolved one.
    public static var gitCandidates: Set<String> { gitCandidates(of: engine()) }

    public static func gitCandidates(of result: Result<ToolPaths, ToolPathsError>) -> Set<String> {
        if case .success(let tools) = result { return [tools.git] }
        return []
    }
}
