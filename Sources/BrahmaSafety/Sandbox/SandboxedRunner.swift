import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// The sandbox the engine puts around commands agents wrote that it runs itself, outside Claude Code's own sandbox: checks
// now (`SandboxedCheckRunner`), previews later (Plan 4a). macOS uses Seatbelt (`SeatbeltRunner`); every other platform gets
// `UnavailableSandboxRunner`, which fails closed.

/// Runs agent-written commands under a sandbox policy.
public protocol SandboxedRunner: Sendable {
    /// Runs `command` (`/bin/sh -c`) to completion or `timeout`; never throws (whatever goes wrong is the outcome).
    func run(command: String, cwd: URL, environment: [String: String], timeout: Duration, outputURL: URL,
             policy: ValidatedPolicy) async -> CheckOutcome
    /// `run` for a synchronous caller (C2b fix round 2: the secret gate's archive and PDF readers): it never blocks waiting
    /// on the cooperative pool, which callers blocked on it could exhaust. The default runs `run` on a detached task and
    /// waits for it, at most `timeout` + 30 s (then an outcome that timed out); a runner whose work is blocking anyway does
    /// it on the calling thread.
    func runBlocking(command: String, cwd: URL, environment: [String: String], timeout: Duration, outputURL: URL,
                     policy: ValidatedPolicy) -> CheckOutcome
    /// C2b fix round 4 (R4-4): runs one program as itself (`arguments`, argv with `arguments[0]` the program; no shell)
    /// to completion or `timeout`, on the calling thread, as the leader of a new session. Its standard output goes to
    /// `stdoutURL` (created anew), at most `stdoutCap` bytes: one byte more and the run is killed, its tail ending with
    /// `GroupRun.outputExceeded`. Its standard error goes to `outputURL`. The outcome's exit code is the program's own (or
    /// 128 + the signal that ended it). Never throws. A runner that can't run a program this way says it could not run.
    func runProgramBlocking(arguments: [String], cwd: URL, environment: [String: String], timeout: Duration, outputURL: URL,
                            stdoutURL: URL, stdoutCap: Int, policy: ValidatedPolicy) -> CheckOutcome
    /// Starts `command` as a long-running process (a preview); its output goes to `logURL`.
    func spawn(command: String, cwd: URL, environment: [String: String], logURL: URL, policy: ValidatedPolicy) throws -> any SandboxedProcess
    /// The baseline this runner renders its profiles against, now: `SandboxPolicyFactory.decide` validates a policy meant for
    /// this runner against it (Plan S Task S7), and `SeatbeltRunner` checks the validated strings against it again when the
    /// run starts. The default is the owner's (`SandboxBaseline.owner()`).
    func policyBaseline() -> SandboxBaseline
}

extension SandboxedRunner {
    public func policyBaseline() -> SandboxBaseline { SandboxBaseline.owner() }
}

/// The text of a run that never started because its policy was refused (`PolicyDecision.refused`): the same tail a runner
/// gives a policy it refuses (`SeatbeltRunner`: "could not run the check in the sandbox: …").
public enum PolicyRefusal {
    public static func tail(_ why: String) -> String { "could not run the check in the sandbox: \(why)" }
}

extension SandboxedRunner {
    /// `run` under a factory decision for a purpose that only ever runs sandboxed: `.sandboxed` runs; `.refused` is the
    /// outcome of a run that could not start (`PolicyRefusal.tail`), nothing runs; a `.fullOptOut` is never run here (this
    /// runner is the sandbox), so it fails closed the same way.
    public func run(command: String, cwd: URL, environment: [String: String], timeout: Duration, outputURL: URL,
                    decision: PolicyDecision) async -> CheckOutcome {
        switch decision {
        case .sandboxed(let policy):
            return await run(command: command, cwd: cwd, environment: environment, timeout: timeout, outputURL: outputURL, policy: policy)
        case .refused(let why):
            return GroupRun.fail(PolicyRefusal.tail(why), outputURL: outputURL)
        case .fullOptOut:
            return GroupRun.fail(PolicyRefusal.tail("this purpose runs only sandboxed"), outputURL: outputURL)
        }
    }

    /// `runProgramBlocking` under a factory decision, as `run(…decision:)`.
    public func runProgramBlocking(arguments: [String], cwd: URL, environment: [String: String], timeout: Duration, outputURL: URL,
                                   stdoutURL: URL, stdoutCap: Int, decision: PolicyDecision) -> CheckOutcome {
        switch decision {
        case .sandboxed(let policy):
            return runProgramBlocking(arguments: arguments, cwd: cwd, environment: environment, timeout: timeout, outputURL: outputURL,
                                      stdoutURL: stdoutURL, stdoutCap: stdoutCap, policy: policy)
        case .refused(let why):
            return GroupRun.fail(PolicyRefusal.tail(why), outputURL: outputURL)
        case .fullOptOut:
            return GroupRun.fail(PolicyRefusal.tail("this purpose runs only sandboxed"), outputURL: outputURL)
        }
    }
}

extension SandboxedRunner {
    public func runBlocking(command: String, cwd: URL, environment: [String: String], timeout: Duration, outputURL: URL,
                            policy: ValidatedPolicy) -> CheckOutcome {
        let box = BlockingRunBox()
        Task.detached {
            box.value = await run(command: command, cwd: cwd, environment: environment, timeout: timeout, outputURL: outputURL, policy: policy)
            box.done.signal()
        }
        guard box.done.wait(timeout: .now() + (Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18) + 30) == .success, let value = box.value else {
            return CheckOutcome(exitCode: nil, timedOut: true, tail: "the sandboxed run never reported back")
        }
        return value
    }
}

extension SandboxedRunner {
    /// Fails closed: only a runner that implements it runs a program directly.
    public func runProgramBlocking(arguments: [String], cwd: URL, environment: [String: String], timeout: Duration, outputURL: URL,
                                   stdoutURL: URL, stdoutCap: Int, policy: ValidatedPolicy) -> CheckOutcome {
        GroupRun.fail("this sandbox can't run a program directly", outputURL: outputURL)
    }
}

/// The default `runBlocking`'s hand-off between the detached run and the waiting caller.
final class BlockingRunBox: @unchecked Sendable {
    let done = DispatchSemaphore(value: 0)
    var value: CheckOutcome?
}

/// A process `SandboxedRunner.spawn` started: the leader of its own process group.
public protocol SandboxedProcess: Sendable {
    var pid: Int32 { get }
    func isAlive() -> Bool
    /// The exit code (or 128 + signal) once it has ended, else nil.
    func exitStatus() -> Int32?
    /// SIGTERM to the group, `grace` of awake time, then SIGKILL; returns once it is reaped.
    func terminate(grace: Duration) async
    /// The leader's exact start time, read at the spawn while it was unreaped (`ProcessGroupChild.leaderStart`); nil when it
    /// could not be read. A preview records it so a later stop signals only this process (final review I2).
    var leaderStart: Double? { get }
}

extension SandboxedProcess {
    public var leaderStart: Double? { nil }
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
    /// (each as given and resolved), the Darwin per-user temp and cache directories, and `engineHome` (the data home) as the engine home.
    public static func current(engineHome: URL, otherWorkspaces: [URL], backupTargets: [URL]) -> SandboxBaseline {
        current(engineHomes: [engineHome], otherWorkspaces: otherWorkspaces, backupTargets: backupTargets)
    }

    private static func current(engineHomes: [URL], otherWorkspaces: [URL], backupTargets: [URL]) -> SandboxBaseline {
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
                               darwinUserDir: user, engineHomes: engineHomes.map(\.resolvedForSandbox), problem: problem)
    }

    /// The owner's baseline with no engine home: the resolved home, `ProtectedPaths.defaults` and Claude Code's temp places,
    /// and the Darwin per-user directories. What a runner that has no baseline of its own validates against
    /// (`SandboxedRunner.policyBaseline`).
    public static func owner() -> SandboxBaseline {
        current(engineHomes: [], otherWorkspaces: [], backupTargets: [])
    }

    #if canImport(Darwin)
    public static func darwinDirectory(_ name: Int32) -> URL? {
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

    public static func dedupe(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { seen.insert($0.path).inserted }
    }

    /// `/private/tmp/b-<uid>`: the root of every sandboxed agent's private Claude temp directory, in every company.
    public static var defaultClaudeTmpRoot: URL { URL(fileURLWithPath: "/private/tmp/b-\(getuid())", isDirectory: false) }

    /// Claude Code's temp places under `/tmp`, in both spellings (final review I1): the owner's own sessions
    /// (`claude-<uid>`: edit diffs of the owner's files, background task output), `claude-tool-results`, `claude`, and the
    /// root of every sandboxed agent's private temp directory in every company (`b-<uid>`, `SandboxEnvironment`). No
    /// sandboxed command reads them, as no sandboxed turn does (`SandboxScope.forTurn`).
    static var claudeTempPlaces: [URL] {
        // Fix-wave F4: Claude Code's daemon-control and pty socket folders too.
        let names = ["claude-\(getuid())", "claude-tool-results", "claude", defaultClaudeTmpRoot.lastPathComponent,
                     "cc-daemon-\(getuid())", "cc-socks"]
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
                    policy: ValidatedPolicy) async -> CheckOutcome {
        GroupRun.fail(Self.tail, outputURL: outputURL)
    }

    public func runBlocking(command: String, cwd: URL, environment: [String: String], timeout: Duration, outputURL: URL,
                            policy: ValidatedPolicy) -> CheckOutcome {
        GroupRun.fail(Self.tail, outputURL: outputURL)
    }

    public func spawn(command: String, cwd: URL, environment: [String: String], logURL: URL, policy: ValidatedPolicy) throws -> any SandboxedProcess {
        throw SandboxError.unavailable
    }
}
