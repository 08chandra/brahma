import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// The sandbox the engine puts around commands agents wrote that it runs itself, outside Claude Code's own sandbox: checks
// now (`SandboxedCheckRunner`), previews later (Plan 4a). macOS uses Seatbelt (`SeatbeltRunner`); every other platform gets
// `UnavailableSandboxRunner`, which fails closed.

/// What a sandboxed command may reach on the network.
public enum SandboxNetwork: Equatable, Sendable {
    /// Nothing at all.
    case none
    /// TLS to the allowed domains, only through the engine's egress proxy (`EgressProxy`).
    case outbound(allow: [String])
    /// As `.outbound`, plus listening on and connecting to its own loopback `ports` (a preview server).
    case loopbackListen(allow: [String], ports: [UInt16])
}

/// What one sandboxed command may touch. Every path is resolved (`URL.resolvedForSandbox`); a policy holding a path that
/// resolves elsewhere (a link on the way) is refused. `writable[0]` holds the command's `TMPDIR`; with `toolchain`, the last
/// writable entry is the cache that holds its `HOME` and tool caches.
public struct SandboxPolicy: Equatable, Sendable {
    public var writable: [URL]
    public var readable: [URL]
    public var network: SandboxNetwork
    public var toolchain: Bool

    public init(writable: [URL], readable: [URL], network: SandboxNetwork, toolchain: Bool) {
        self.writable = writable; self.readable = readable; self.network = network; self.toolchain = toolchain
    }

    /// The domains the egress proxy lets through, or nil for `.none`.
    var allowedDomains: [String]? {
        switch network {
        case .none: nil
        case .outbound(let allow): allow
        case .loopbackListen(let allow, _): allow
        }
    }

    var loopbackPorts: [UInt16] {
        if case .loopbackListen(_, let ports) = network { return ports }
        return []
    }
}

/// Runs agent-written commands under a sandbox policy.
public protocol SandboxedRunner: Sendable {
    /// Runs `command` (`/bin/sh -c`) to completion or `timeout`; never throws (whatever goes wrong is the outcome).
    func run(command: String, cwd: URL, environment: [String: String], timeout: Duration, outputURL: URL,
             policy: SandboxPolicy) async -> CheckOutcome
    /// Starts `command` as a long-running process (a preview); its output goes to `logURL`.
    func spawn(command: String, cwd: URL, environment: [String: String], logURL: URL, policy: SandboxPolicy) throws -> any SandboxedProcess
}

/// A process `SandboxedRunner.spawn` started: the leader of its own process group.
public protocol SandboxedProcess: Sendable {
    var pid: Int32 { get }
    func isAlive() -> Bool
    /// The exit code (or 128 + signal) once it has ended, else nil.
    func exitStatus() -> Int32?
    /// SIGTERM to the group, `grace` of awake time, then SIGKILL; returns once it is reaped.
    func terminate(grace: Duration) async
}

/// What every sandboxed command is kept from, whatever its policy: the owner's home (except what the policy reads or writes
/// in it), `/Volumes`, the engine's data homes, the protected paths and every company workspace the policy does not name.
public struct SandboxBaseline: Equatable, Sendable {
    /// The owner's home, resolved: unreadable except the policy's own entries.
    public var userHome: URL
    /// Never readable or writable, whatever the policy says (`ProtectedPaths`, other companies' workspaces, backup targets);
    /// each as given and resolved. A policy entry overlapping one is refused.
    public var protected: [URL]
    /// `confstr(_CS_DARWIN_USER_TEMP_DIR)`, resolved (`/private/var/folders/…/T`): xcrun's cache lives there.
    public var darwinUserTemp: URL?
    /// `confstr(_CS_DARWIN_USER_CACHE_DIR)`, resolved (`/private/var/folders/…/C`): clang's and SwiftPM's caches.
    public var darwinUserCache: URL?
    /// The per-user Darwin folder (the parent of `confstr(_CS_DARWIN_USER_DIR)`, resolved: `/private/var/folders/<a>/<b>`,
    /// holding T, C and 0): unreadable like the home, except the toolchain's own entries.
    public var darwinUserDir: URL?
    /// The engine's data homes: unreadable and unwritable except a policy entry inside one (a check's own checkout). Added
    /// to the first read rule next to the home and `/Volumes`, so a data home outside `~` (a custom `BRAHMA_HOME`) is
    /// covered too.
    public var engineHomes: [URL]
    /// Every company's workspace: one the policy reads or writes inside of is readable as the policy says, every other one is
    /// denied like a protected path.
    public var companyWorkspaces: [URL]
    /// Why the baseline could not be built completely; while it is set nothing runs (fail closed).
    public var problem: String?

    public init(userHome: URL, protected: [URL], darwinUserTemp: URL?, darwinUserCache: URL?, darwinUserDir: URL? = nil,
                engineHomes: [URL] = [], companyWorkspaces: [URL] = [], problem: String? = nil) {
        self.userHome = userHome; self.protected = protected; self.darwinUserTemp = darwinUserTemp
        self.darwinUserCache = darwinUserCache; self.darwinUserDir = darwinUserDir; self.engineHomes = engineHomes
        self.companyWorkspaces = companyWorkspaces; self.problem = problem
    }

    /// The owner's baseline now: the resolved home, `ProtectedPaths.defaults` plus `otherWorkspaces` and `backupTargets`
    /// (each as given and resolved), the Darwin per-user temp and cache directories, and `paths.home` as the engine home.
    public static func current(paths: BrahmaPaths, otherWorkspaces: [URL], backupTargets: [URL]) -> SandboxBaseline {
        let home = FileManager.default.homeDirectoryForCurrentUser
        func both(_ url: URL) -> [URL] { [url, url.resolvedForSandbox] }
        let protected = dedupe((ProtectedPaths.defaults(userHome: home) + otherWorkspaces + backupTargets).flatMap(both)
                               + claudeTempPlaces)
        #if canImport(Darwin)
        let temp = darwinDirectory(_CS_DARWIN_USER_TEMP_DIR), cache = darwinDirectory(_CS_DARWIN_USER_CACHE_DIR)
        let user = darwinDirectory(_CS_DARWIN_USER_DIR)?.deletingLastPathComponent()
        // On Darwin the per-user folder must be known: without it the profile could not deny reads of T/C/0, so fail closed
        // rather than silently leave them readable (A-I1 gap 2).
        let problem = user == nil ? "could not resolve the per-user Darwin directory (confstr _CS_DARWIN_USER_DIR)" : nil
        #else
        let temp: URL? = nil, cache: URL? = nil, user: URL? = nil, problem: String? = nil
        #endif
        return SandboxBaseline(userHome: home.resolvedForSandbox, protected: protected, darwinUserTemp: temp, darwinUserCache: cache,
                               darwinUserDir: user, engineHomes: [paths.home.resolvedForSandbox], problem: problem)
    }

    #if canImport(Darwin)
    static func darwinDirectory(_ name: Int32) -> URL? {
        let size = confstr(name, nil, 0)
        guard size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard confstr(name, &buffer, size) > 0 else { return nil }
        var path = String(cString: buffer)
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        guard path.hasPrefix("/") else { return nil }
        return URL(fileURLWithPath: path, isDirectory: false).resolvedForSandbox
    }
    #endif

    static func dedupe(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.path).inserted }
    }

    /// Claude Code's temp places under `/tmp`, in both spellings (final review I1): the owner's own sessions
    /// (`claude-<uid>`: edit diffs of the owner's files, background task output), `claude-tool-results`, `claude`, and the
    /// root of every sandboxed agent's private temp directory in every company (`b-<uid>`, `SandboxEnvironment`). No
    /// sandboxed command reads them, as no sandboxed turn does (`SandboxScope.forTurn`).
    static var claudeTempPlaces: [URL] {
        let names = ["claude-\(getuid())", "claude-tool-results", "claude", SandboxEnvironment.defaultClaudeTmpRoot.lastPathComponent]
        return names.flatMap { name in ["/private/tmp/\(name)", "/tmp/\(name)"].map { URL(fileURLWithPath: $0, isDirectory: false) } }
    }
}

public enum SandboxRunners {
    /// `SeatbeltRunner` where `/usr/bin/sandbox-exec` is executable, else `UnavailableSandboxRunner`.
    public static func platformDefault(baseline: @escaping @Sendable () -> SandboxBaseline, proxies: EgressProxyPool,
                                       onStraggler: (@Sendable (StragglerReport) -> Void)? = nil) -> any SandboxedRunner {
        #if canImport(Darwin)
        if access(SeatbeltRunner.sandboxExec, X_OK) == 0 {
            return SeatbeltRunner(baseline: baseline, proxies: proxies, onStraggler: onStraggler)
        }
        #endif
        return UnavailableSandboxRunner()
    }
}

/// The runner where no sandbox exists: nothing runs.
public struct UnavailableSandboxRunner: SandboxedRunner {
    public static let tail = "sandbox unavailable on this platform"

    public init() {}

    public func run(command: String, cwd: URL, environment: [String: String], timeout: Duration, outputURL: URL,
                    policy: SandboxPolicy) async -> CheckOutcome {
        GroupRun.fail(Self.tail, outputURL: outputURL)
    }

    public func spawn(command: String, cwd: URL, environment: [String: String], logURL: URL, policy: SandboxPolicy) throws -> any SandboxedProcess {
        throw SandboxError.unavailable
    }
}

/// What makes a policy safe to render, checked before anything runs.
enum SandboxPolicyCheck {
    /// Throws when:
    /// - the baseline could not be built (`problem`);
    /// - there is no writable entry (`.invalidPath`);
    /// - a policy or baseline path is not absolute, or holds a character no profile string may carry (`.invalidPath`,
    ///   `.unsafePathCharacter`);
    /// - a policy path is not already resolved (a link on the way, or `..`) (`.linkedPath`);
    /// - a policy path overlaps a protected path, or equals or contains the home, an engine home, `/Volumes` or `/`
    ///   (`.overlapsProtected`);
    /// - a writable path equals or contains a company workspace (the workspace deny covers reads only) (`.overlapsProtected`);
    /// - an allowed domain is Anthropic's or not a valid pattern; a loopback port is 0.
    static func validate(_ policy: SandboxPolicy, baseline: SandboxBaseline) throws {
        if let problem = baseline.problem { throw SandboxError.invalidPath("sandbox baseline unavailable: \(problem)") }
        guard !policy.writable.isEmpty else { throw SandboxError.invalidPath("a sandbox policy needs a writable directory") }
        let baselinePaths = [baseline.userHome] + baseline.protected + baseline.engineHomes + baseline.companyWorkspaces
            + [baseline.darwinUserTemp, baseline.darwinUserCache, baseline.darwinUserDir].compactMap { $0 }
        for url in policy.writable + policy.readable + baselinePaths {
            if SandboxPath.isUnsafe(url.path) { throw SandboxError.unsafePathCharacter(url.path) }
            if !url.path.hasPrefix("/") { throw SandboxError.invalidPath(url.path) }
        }
        let roots = [baseline.userHome] + baseline.engineHomes + [URL(fileURLWithPath: "/Volumes"), URL(fileURLWithPath: "/")]
        // The same alias/identity helper as turn scopes (`SandboxScope.checkAllowed`): no alias spelling, and overlaps judged by
        // spelling and by device and inode (a firmlink spelling of a protected place is that place).
        let identities = (SandboxPath.IdentityRoots(baseline.protected), SandboxPath.IdentityRoots(roots))
        for url in policy.writable + policy.readable {
            let path = url.path
            if SandboxPath.resolve(path) != path || path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) {
                throw SandboxError.linkedPath(path)
            }
            try SandboxScope.checkAllowed(url, protected: baseline.protected, deniedRoots: roots, byIdentity: identities)
        }
        for url in policy.writable {
            if let hit = baseline.companyWorkspaces.first(where: { SandboxPath.isInside($0.path, url.path) }) {
                throw SandboxError.overlapsProtected(path: url.path, protected: hit.path)
            }
        }
        for domain in policy.allowedDomains ?? [] {
            if SandboxDomains.isForbidden(domain) { throw SandboxError.forbiddenDomain(SandboxDomains.normalize(domain)) }
            if !DomainMatcher.isValidPattern(domain) { throw SandboxError.invalidDomain(domain) }
        }
        if policy.loopbackPorts.contains(0) { throw SandboxError.invalidPath("loopback port 0") }
    }
}
