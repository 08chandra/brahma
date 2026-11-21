import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Runs a command as `/usr/bin/sandbox-exec -p <profile> /bin/sh -c <command>` (`SeatbeltProfile`), with 3a's process
/// handling (`GroupRun`, `ProcessGroupChild`): its own process group, stdin `/dev/null`, a 1 MB output cap, SIGTERM then
/// `termGrace` (5 s of awake time) then SIGKILL to the group; never a signal to a group it has reaped.
///
/// The environment is `environment` plus:
/// - `TMPDIR=<writable[0]>/.brahma-tmp` (created before the run, removed after `run`);
/// - with `toolchain`, `HOME`, `CARGO_HOME`, `XDG_CACHE_HOME`, `npm_config_cache` and `CLANG_MODULE_CACHE_PATH`, all per-run
///   under TMPDIR (no writable shared cache: nothing a check plants outlives its run);
/// - with outbound or loopback network, `HTTPS_PROXY`, `HTTP_PROXY`, `https_proxy`, `http_proxy`, `ALL_PROXY` =
///   `http://127.0.0.1:<proxy port>` and `NO_PROXY=localhost,127.0.0.1`.
/// A policy that is not safe to render (`SandboxPolicyCheck`) is refused: `run` returns "could not run", `spawn` throws.
/// Each run's profile allows a unique mach global name (`runMarker`); after the run every process still under that sandbox
/// is killed (`SandboxSweep`, B-I4) and reported (`onStraggler`). Killed ones leave the outcome as it was (N2); the outcome
/// becomes inconclusive only when one could not be killed or classified, or the process table could not be read (N1).
public struct SeatbeltRunner: SandboxedRunner {
    public static let sandboxExec = "/usr/bin/sandbox-exec"
    static let tmpName = ".brahma-tmp"

    let baseline: @Sendable () -> SandboxBaseline
    let proxies: EgressProxyPool
    var termGrace: TimeInterval
    var clock: @Sendable () -> TimeInterval
    /// Called (on the check's own thread) whenever a run left processes behind: killed ones (logged, outcome unchanged) or
    /// ones that could not be killed or classified (the outcome is already inconclusive). The engine turns it into an
    /// owner-visible activity line.
    let onStraggler: (@Sendable (StragglerReport) -> Void)?
    /// Tests only: runs between the policy check and the profile render (`prepare`), where a leftover process could swap a
    /// checked path for a link (Task 7, obligation d).
    let afterValidate: (@Sendable () -> Void)?

    public init(baseline: @escaping @Sendable () -> SandboxBaseline, proxies: EgressProxyPool,
                onStraggler: (@Sendable (StragglerReport) -> Void)? = nil) {
        self.init(baseline: baseline, proxies: proxies, termGrace: 5, onStraggler: onStraggler)
    }

    init(baseline: @escaping @Sendable () -> SandboxBaseline, proxies: EgressProxyPool, termGrace: TimeInterval,
         clock: @escaping @Sendable () -> TimeInterval = { AwakeTime.uptime() }, onStraggler: (@Sendable (StragglerReport) -> Void)? = nil,
         afterValidate: (@Sendable () -> Void)? = nil) {
        self.baseline = baseline; self.proxies = proxies; self.termGrace = termGrace; self.clock = clock
        self.onStraggler = onStraggler; self.afterValidate = afterValidate
    }

    /// A unique per-run mach global name the profile allows and the sweep probes for (B-I4).
    static let markerPrefix = "dev.brahma.run."
    static func runMarker() -> String { markerPrefix + UUID().uuidString.lowercased() }

    struct Prepared {
        var arguments: [String]
        var environment: [String: String]
    }

    /// Validates, renders and builds the argv and environment; creates `TMPDIR` (and, with `toolchain`, the cache's tool
    /// directories) without following a link. The profile is rendered from the very paths the check saw (no second resolve:
    /// `resolvePolicyPaths: false`), so a link swapped in between the check and the render cannot widen it (Task 7, obligation
    /// d); the `TMPDIR` step then opens the writable entry with `O_NOFOLLOW`, so a swapped writable entry fails here.
    /// `prepare(program:)` for a shell command (`/bin/sh -c <command>`).
    func prepare(command: String, environment: [String: String], policy: SandboxPolicy, proxyPort: UInt16?, marker: String?) throws -> Prepared {
        try prepare(program: Self.shell(command), environment: environment, policy: policy, proxyPort: proxyPort, marker: marker)
    }

    /// `program` is what `sandbox-exec` runs (argv): `/bin/sh -c <command>` (`shell`), or one program as itself (C2b fix
    /// round 4, `runProgramBlocking`).
    func prepare(program: [String], environment: [String: String], policy: SandboxPolicy, proxyPort: UInt16?, marker: String?) throws -> Prepared {
        let base = baseline()
        try SandboxPolicyCheck.validate(policy, baseline: base)
        afterValidate?()
        let profile = SeatbeltProfile.render(policy: policy, baseline: base, proxyPort: proxyPort, marker: marker, resolvePolicyPaths: false)
        var env = environment
        let first = policy.writable[0]
        // B-I2: every engine file op is anchored at the parent of the writable entry and opened with O_NOFOLLOW, so an entry
        // the check replaced with a link throws instead of being followed to the link's target.
        try Self.ensureUnder(first, Self.tmpName, mode: 0o700)
        env["TMPDIR"] = first.appending(path: Self.tmpName).path
        if policy.toolchain {
            // Every toolchain cache and config dir is per-run, under TMPDIR, thrown away with it: HOME, CARGO_HOME,
            // XDG_CACHE_HOME and the npm cache (config that runs code — .npmrc, config.toml — and, per the re-review, the npm
            // store too: a check gets no writable shared cache at all, so nothing a submission check plants can run in a
            // later check or a merge check). The clang module cache is redirected the same way, so the per-user Darwin cache
            // (C) is never written.
            for (name, dir) in [("HOME", "home"), ("XDG_CACHE_HOME", "xdg"), ("CARGO_HOME", "cargo"), ("npm_config_cache", "npm"),
                                ("CLANG_MODULE_CACHE_PATH", "clang-modules")] {
                try Self.ensureUnder(first, "\(Self.tmpName)/\(dir)", mode: 0o700)
                env[name] = first.appending(path: "\(Self.tmpName)/\(dir)").path
            }
        }
        if policy.allowedDomains != nil, let proxyPort {
            let url = "http://127.0.0.1:\(proxyPort)"
            for name in ["HTTPS_PROXY", "HTTP_PROXY", "https_proxy", "http_proxy", "ALL_PROXY"] { env[name] = url }
            env["NO_PROXY"] = "localhost,127.0.0.1"
        } else {
            for name in ["HTTPS_PROXY", "HTTP_PROXY", "https_proxy", "http_proxy", "ALL_PROXY", "all_proxy", "NO_PROXY", "no_proxy"] {
                env[name] = nil
            }
        }
        return Prepared(arguments: [Self.sandboxExec, "-p", profile] + program, environment: env)
    }

    /// Ensures `<entry>/<sub>` without following a link at `entry` itself: the walk is anchored at `entry`'s parent (an
    /// engine-owned directory the check cannot write) and `entry` is opened with O_NOFOLLOW, so a link planted at `entry`
    /// throws rather than redirecting the engine's `mkdir`/`fchmod` to the link's target (B-I2).
    static func ensureUnder(_ entry: URL, _ sub: String, mode: mode_t) throws {
        try EngineFiles.directory(workspace: entry.deletingLastPathComponent(), "\(entry.lastPathComponent)/\(sub)", mode: mode)
    }

    /// Removes `TMPDIR`, anchored at the writable entry's parent so a link at the entry is not followed (B-I2); the entry is
    /// opened O_NOFOLLOW, and the removal itself works on descriptors only.
    static func removeTemp(_ policy: SandboxPolicy) {
        guard let first = policy.writable.first else { return }
        _ = try? EngineFiles.removeNoFollow(first.appending(path: tmpName), under: first.deletingLastPathComponent())
    }

    public func run(command: String, cwd: URL, environment: [String: String], timeout: Duration, outputURL: URL,
                    policy: SandboxPolicy) async -> CheckOutcome {
        var port: UInt16?
        if let allow = policy.allowedDomains {
            do { port = try await proxies.proxy(for: allow).port } catch {
                return GroupRun.fail("could not run the check: the egress proxy did not start (\(error))", outputURL: outputURL)
            }
        }
        let cancel = GroupRun.CancelFlag()
        let groups = ChildGroups.current
        // `prepare` (the Seatbelt render, the `EngineFiles` mkdir/fchmod of TMPDIR and the per-run caches) and the B-I4 sweep
        // are blocking, so they run on the check's own thread next to the run, never the cooperative pool (B-M6).
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CheckOutcome, Never>) in
                let thread = Thread { [self] in
                    continuation.resume(returning: runHere(program: Self.shell(command), cwd: cwd, environment: environment, timeout: timeout,
                                                           outputURL: outputURL, policy: policy, port: port, cancel: cancel, groups: groups))
                }
                thread.name = "brahma-sandboxed-check"
                thread.start()
            }
        } onCancel: { cancel.set() }
        return outcome
    }

    /// C2b fix round 2: the whole run on the calling thread (every step of it blocks anyway), for synchronous callers that
    /// must not wait on the cooperative pool. A policy with network needs its egress proxy started first (`proxyNow`).
    public func runBlocking(command: String, cwd: URL, environment: [String: String], timeout: Duration, outputURL: URL,
                            policy: SandboxPolicy) -> CheckOutcome {
        let port: UInt16?
        do { port = try policy.allowedDomains.map { try proxies.proxyNow(for: $0).port } } catch {
            return GroupRun.fail("could not run the check: the egress proxy did not start (\(error))", outputURL: outputURL)
        }
        return runHere(program: Self.shell(command), cwd: cwd, environment: environment, timeout: timeout, outputURL: outputURL,
                       policy: policy, port: port, cancel: GroupRun.CancelFlag(), groups: ChildGroups.current)
    }

    /// C2b fix round 4 (R4-4): one program as itself under the policy (no shell), on the calling thread, as the leader of a
    /// new session, its standard output capped (`SandboxedRunner.runProgramBlocking`). No network. A confined policy runs
    /// only one of its own programs.
    public func runProgramBlocking(arguments: [String], cwd: URL, environment: [String: String], timeout: Duration, outputURL: URL,
                                   stdoutURL: URL, stdoutCap: Int, policy: SandboxPolicy) -> CheckOutcome {
        guard let program = arguments.first, policy.allowedDomains == nil, stdoutCap >= 0 else {
            return GroupRun.fail("could not run the program in the sandbox: no program, or a network it may not have", outputURL: outputURL)
        }
        if let confined = policy.confined, !confined.executables.contains(where: { $0.path == program }) {
            return GroupRun.fail("could not run the program in the sandbox: \(program) is not one its policy runs", outputURL: outputURL)
        }
        return runHere(program: arguments, cwd: cwd, environment: environment, timeout: timeout, outputURL: outputURL, policy: policy,
                       port: nil, cancel: GroupRun.CancelFlag(), groups: ChildGroups.current, stdout: (stdoutURL, stdoutCap), newSession: true)
    }

    /// `command` as `sandbox-exec` runs it: through `/bin/sh -c`.
    static func shell(_ command: String) -> [String] { ["/bin/sh", "-c", command] }

    /// One run, start to end, on the current thread: `prepare`, the run, the B-I4 sweep, the temp removal.
    func runHere(program: [String], cwd: URL, environment: [String: String], timeout: Duration, outputURL: URL, policy: SandboxPolicy,
                 port: UInt16?, cancel: GroupRun.CancelFlag, groups: ChildGroups?, stdout: (url: URL, cap: Int)? = nil,
                 newSession: Bool = false) -> CheckOutcome {
        let (grace, clock) = (termGrace, self.clock)
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        // Everything the run starts is newer than this; it bounds the B-I4 sweep so a recycled pid is never killed.
        let since = ProcessTable.startStamp(slack: 1)
        // The per-run marker the profile allows and the sweep probes for; survives the check deleting its own checkout.
        let marker = Self.runMarker()
        let prepared: Prepared
        do { prepared = try prepare(program: program, environment: environment, policy: policy, proxyPort: port, marker: marker) } catch {
            Self.removeTemp(policy)   // a partly created TMPDIR goes too (N6)
            return GroupRun.fail("could not run the check in the sandbox: \(error)", outputURL: outputURL)
        }
        var result = GroupRun.run(executable: Self.sandboxExec, arguments: prepared.arguments,
                                  workingDirectory: cwd, timeout: seconds, outputURL: outputURL,
                                  environment: prepared.environment, termGrace: grace, clock: clock, cancel: cancel,
                                  groups: groups, memoryLimit: policy.memoryLimit, stdout: stdout, newSession: newSession)
        // B-I4: kill anything the run left behind, recognized by the run's marker (even if it deleted its
        // checkout). N2: killed stragglers leave the outcome as it is (tools that daemonize are normal) and are
        // reported; only ones that could not be killed or classified, or an unreadable process table, make the
        // run inconclusive — nothing unaccounted for is ever counted as a pass or a failure.
        let swept = SandboxSweep.run(probe: SandboxProbe(machMarker: marker), since: since)
        if !swept.clean { onStraggler?(StragglerReport(checkout: policy.writable[0], result: swept)) }
        if swept.inconclusive {
            let why = swept.tableUnreadable ? "the process table could not be read"
                : "\(swept.survivors.count) process(es) could not be killed or identified"
            result = CheckOutcome(exitCode: nil, timedOut: false,
                                  tail: (result.tail.isEmpty ? "" : result.tail + "\n")
                                    + "the check left processes running outside its group and \(why); recorded inconclusive")
        }
        Self.removeTemp(policy)
        return result
    }

    public func spawn(command: String, cwd: URL, environment: [String: String], logURL: URL, policy: SandboxPolicy) throws -> any SandboxedProcess {
        let port = try policy.allowedDomains.map { try proxies.proxyNow(for: $0).port }
        let marker = Self.runMarker()
        let prepared = try prepare(program: Self.shell(command), environment: environment, policy: policy, proxyPort: port, marker: marker)
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = open(logURL.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw SandboxError.invalidPath("cannot open the log \(logURL.path)") }
        let since = ProcessTable.startStamp(slack: 1)
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { close(file); throw SandboxError.invalidPath("no pipe for the log") }
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC); _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        let child: ProcessGroupChild
        do {
            child = try ProcessGroupChild.spawn(executable: Self.sandboxExec, arguments: prepared.arguments,
                                                environment: prepared.environment, workingDirectory: cwd, output: fds[1])
        } catch {
            close(fds[0]); close(fds[1]); close(file)
            throw error
        }
        close(fds[1])
        return SeatbeltProcess(child: child, marker: marker, since: since, onStraggler: onStraggler,
                               capture: OutputCapture(readEnd: fds[0], file: file, cap: ProcessCheckRunner.outputCap,
                                                      tailBytes: 4096, marker: ProcessCheckRunner.truncationMarker))
    }
}

/// What a run (or a preview, `checkout` nil) left behind, for the engine's log and the owner's activity feed.
public struct StragglerReport: Sendable {
    /// The run's own checkout/export (its last path component is the verification run id).
    public let checkout: URL?
    let result: SweepResult
    public var killed: [Int32] { result.killed }
    public var survivors: [Int32] { result.survivors }
    public var tableUnreadable: Bool { result.tableUnreadable }
    /// The run was recorded inconclusive because of it.
    public var inconclusive: Bool { result.inconclusive }
}

/// A process `SeatbeltRunner.spawn` started (the leader of its own group). A reaper thread waits for the leader without
/// reaping it, sweeps what is left of its group, then reaps it; every signal goes through `ProcessGroupChild`, so none is
/// ever sent after the reap.
public final class SeatbeltProcess: SandboxedProcess, @unchecked Sendable {
    let child: ProcessGroupChild
    private let capture: OutputCapture
    private let marker: String
    private let since: Double
    private let onStraggler: (@Sendable (StragglerReport) -> Void)?
    private let reaped = DispatchSemaphore(value: 0)

    init(child: ProcessGroupChild, marker: String, since: Double, onStraggler: (@Sendable (StragglerReport) -> Void)?, capture: OutputCapture) {
        self.child = child; self.marker = marker; self.since = since; self.onStraggler = onStraggler; self.capture = capture
        let thread = Thread { [child, capture, reaped, marker, since, onStraggler] in
            child.finish()
            _ = capture.finish(drain: 2)
            // B-I4: once the leader is gone — whether it was terminated or exited on its own — kill anything the preview
            // left behind, recognized by the run's marker.
            let swept = SandboxSweep.run(probe: SandboxProbe(machMarker: marker), since: since)
            if !swept.clean { onStraggler?(StragglerReport(checkout: nil, result: swept)) }
            reaped.signal()
        }
        thread.name = "brahma-sandboxed-reaper"
        thread.start()
    }

    public var pid: Int32 { child.pid }
    public var leaderStart: Double? { child.leaderStart }

    public func isAlive() -> Bool { !child.hasExited() }

    public func exitStatus() -> Int32? {
        guard child.hasExited() else { return nil }
        return ProcessGroupChild.exitCode(child.finish())
    }

    public func terminate(grace: Duration) async {
        if !child.hasExited() {
            child.signalGroup(SIGTERM)
            let deadline = AwakeTime.deadline(after: grace)
            while !child.hasExited(), AwakeTime.now < deadline { try? await AwakeTime.sleep(for: .milliseconds(20)) }
            if !child.hasExited() { child.signalGroup(SIGKILL) }
        }
        // Wait for the reaper (which finishes the leader and runs the straggler sweep).
        let reaped = self.reaped
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                reaped.wait()
                reaped.signal()
                continuation.resume()
            }
        }
    }
}
