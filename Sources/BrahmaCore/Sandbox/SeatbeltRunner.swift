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
/// is killed (`SandboxSweep`, B-I4) and the outcome becomes inconclusive if there were any.
public struct SeatbeltRunner: SandboxedRunner {
    public static let sandboxExec = "/usr/bin/sandbox-exec"
    static let tmpName = ".brahma-tmp"

    let baseline: @Sendable () -> SandboxBaseline
    let proxies: EgressProxyPool
    var termGrace: TimeInterval
    var clock: @Sendable () -> TimeInterval
    /// Called (on the check's own thread) with the pids a run left behind that the sweep could not account for, so the
    /// engine can log them and raise owner-visible activity. The outcome is already inconclusive by then.
    let onStraggler: (@Sendable ([pid_t]) -> Void)?

    public init(baseline: @escaping @Sendable () -> SandboxBaseline, proxies: EgressProxyPool,
                onStraggler: (@Sendable ([pid_t]) -> Void)? = nil) {
        self.init(baseline: baseline, proxies: proxies, termGrace: 5, onStraggler: onStraggler)
    }

    init(baseline: @escaping @Sendable () -> SandboxBaseline, proxies: EgressProxyPool, termGrace: TimeInterval,
         clock: @escaping @Sendable () -> TimeInterval = { AwakeTime.uptime() }, onStraggler: (@Sendable ([pid_t]) -> Void)? = nil) {
        self.baseline = baseline; self.proxies = proxies; self.termGrace = termGrace; self.clock = clock
        self.onStraggler = onStraggler
    }

    /// A unique per-run mach global name the profile allows and the sweep probes for (B-I4).
    static let markerPrefix = "dev.brahma.run."
    static func runMarker() -> String { markerPrefix + UUID().uuidString.lowercased() }

    struct Prepared {
        var arguments: [String]
        var environment: [String: String]
    }

    /// Validates, renders and builds the argv and environment; creates `TMPDIR` (and, with `toolchain`, the cache's tool
    /// directories) without following a link.
    func prepare(command: String, environment: [String: String], policy: SandboxPolicy, proxyPort: UInt16?, marker: String?) throws -> Prepared {
        let base = baseline()
        try SandboxPolicyCheck.validate(policy, baseline: base)
        let profile = SeatbeltProfile.render(policy: policy, baseline: base, proxyPort: proxyPort, marker: marker)
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
        return Prepared(arguments: [Self.sandboxExec, "-p", profile, "/bin/sh", "-c", command], environment: env)
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
        let (grace, clock) = (termGrace, self.clock)
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        // Everything the run starts is newer than this; it bounds the B-I4 sweep so a recycled pid is never killed.
        let since = ProcessTable.startStamp(slack: 1)
        // The per-run marker the profile allows and the sweep probes for; survives the check deleting its own checkout.
        let marker = Self.runMarker()
        let onStraggler = self.onStraggler
        // `prepare` (the Seatbelt render, the `EngineFiles` mkdir/fchmod of TMPDIR and the per-run caches) and the B-I4 sweep
        // are blocking, so they run on the check's own thread next to the run, never the cooperative pool (B-M6).
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CheckOutcome, Never>) in
                let thread = Thread { [self] in
                    let prepared: Prepared
                    do { prepared = try prepare(command: command, environment: environment, policy: policy, proxyPort: port, marker: marker) } catch {
                        continuation.resume(returning: GroupRun.fail("could not run the check in the sandbox: \(error)", outputURL: outputURL))
                        return
                    }
                    var result = GroupRun.run(executable: Self.sandboxExec, arguments: prepared.arguments,
                                              workingDirectory: cwd, timeout: seconds, outputURL: outputURL,
                                              environment: prepared.environment, termGrace: grace, clock: clock, cancel: cancel)
                    // B-I4: kill anything the run left behind, recognized by the run's marker (even if it deleted its
                    // checkout). Survivors (ours that would not die, or a sandboxed process we could not classify — fail
                    // closed) make the outcome inconclusive, so nothing escaped is ever counted as a pass or a failure.
                    let swept = SandboxSweep.run(probe: SandboxProbe(machMarker: marker), since: since)
                    if !swept.clean {
                        onStraggler?(swept.all)
                        let left = swept.survivors.isEmpty ? "" : " (\(swept.survivors.count) could not be killed)"
                        result = CheckOutcome(exitCode: nil, timedOut: false,
                                              tail: (result.tail.isEmpty ? "" : result.tail + "\n")
                                                + "the check left \(swept.all.count) process(es) running outside its own group\(left); recorded inconclusive")
                    }
                    Self.removeTemp(policy)
                    continuation.resume(returning: result)
                }
                thread.name = "brahma-sandboxed-check"
                thread.start()
            }
        } onCancel: { cancel.set() }
        return outcome
    }

    public func spawn(command: String, cwd: URL, environment: [String: String], logURL: URL, policy: SandboxPolicy) throws -> any SandboxedProcess {
        let port = try policy.allowedDomains.map { try proxies.proxyNow(for: $0).port }
        let marker = Self.runMarker()
        let prepared = try prepare(command: command, environment: environment, policy: policy, proxyPort: port, marker: marker)
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

/// A process `SeatbeltRunner.spawn` started (the leader of its own group). A reaper thread waits for the leader without
/// reaping it, sweeps what is left of its group, then reaps it; every signal goes through `ProcessGroupChild`, so none is
/// ever sent after the reap.
public final class SeatbeltProcess: SandboxedProcess, @unchecked Sendable {
    let child: ProcessGroupChild
    private let capture: OutputCapture
    private let marker: String
    private let since: Double
    private let onStraggler: (@Sendable ([pid_t]) -> Void)?
    private let reaped = DispatchSemaphore(value: 0)

    init(child: ProcessGroupChild, marker: String, since: Double, onStraggler: (@Sendable ([pid_t]) -> Void)?, capture: OutputCapture) {
        self.child = child; self.marker = marker; self.since = since; self.onStraggler = onStraggler; self.capture = capture
        let thread = Thread { [child, capture, reaped, marker, since, onStraggler] in
            child.finish()
            _ = capture.finish(drain: 2)
            // B-I4: once the leader is gone — whether it was terminated or exited on its own — kill anything the preview
            // left behind, recognized by the run's marker.
            let swept = SandboxSweep.run(probe: SandboxProbe(machMarker: marker), since: since)
            if !swept.clean { onStraggler?(swept.all) }
            reaped.signal()
        }
        thread.name = "brahma-sandboxed-reaper"
        thread.start()
    }

    public var pid: Int32 { child.pid }

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
