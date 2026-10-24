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
/// - with `toolchain`, `HOME`, `npm_config_cache`, `XDG_CACHE_HOME` and `CARGO_HOME` under the last writable entry (the
///   cache): `home`, `npm`, `xdg`, `cargo`;
/// - with outbound or loopback network, `HTTPS_PROXY`, `HTTP_PROXY`, `https_proxy`, `http_proxy`, `ALL_PROXY` =
///   `http://127.0.0.1:<proxy port>` and `NO_PROXY=localhost,127.0.0.1`.
/// A policy that is not safe to render (`SandboxPolicyCheck`) is refused: `run` returns "could not run", `spawn` throws.
public struct SeatbeltRunner: SandboxedRunner {
    public static let sandboxExec = "/usr/bin/sandbox-exec"
    static let tmpName = ".brahma-tmp"

    let baseline: @Sendable () -> SandboxBaseline
    let proxies: EgressProxyPool
    var termGrace: TimeInterval
    var clock: @Sendable () -> TimeInterval

    public init(baseline: @escaping @Sendable () -> SandboxBaseline, proxies: EgressProxyPool) {
        self.init(baseline: baseline, proxies: proxies, termGrace: 5)
    }

    init(baseline: @escaping @Sendable () -> SandboxBaseline, proxies: EgressProxyPool, termGrace: TimeInterval,
         clock: @escaping @Sendable () -> TimeInterval = { AwakeTime.uptime() }) {
        self.baseline = baseline; self.proxies = proxies; self.termGrace = termGrace; self.clock = clock
    }

    struct Prepared {
        var arguments: [String]
        var environment: [String: String]
    }

    /// Validates, renders and builds the argv and environment; creates `TMPDIR` (and, with `toolchain`, the cache's tool
    /// directories) without following a link.
    func prepare(command: String, environment: [String: String], policy: SandboxPolicy, proxyPort: UInt16?) throws -> Prepared {
        let base = baseline()
        try SandboxPolicyCheck.validate(policy, baseline: base)
        let profile = SeatbeltProfile.render(policy: policy, baseline: base, proxyPort: proxyPort)
        var env = environment
        let first = policy.writable[0]
        try EngineFiles.directory(workspace: first, Self.tmpName, mode: 0o700)
        env["TMPDIR"] = first.appending(path: Self.tmpName).path
        if policy.toolchain, let cache = policy.writable.last {
            for (name, dir) in [("HOME", "home"), ("npm_config_cache", "npm"), ("XDG_CACHE_HOME", "xdg"), ("CARGO_HOME", "cargo")] {
                try EngineFiles.directory(workspace: cache, dir, mode: 0o700)
                env[name] = cache.appending(path: dir).path
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

    /// Removes `TMPDIR` (through descriptors: a link the command planted there is removed, never followed).
    static func removeTemp(_ policy: SandboxPolicy) {
        guard let first = policy.writable.first else { return }
        _ = try? EngineFiles.removeNoFollow(first.appending(path: tmpName), under: first)
    }

    public func run(command: String, cwd: URL, environment: [String: String], timeout: Duration, outputURL: URL,
                    policy: SandboxPolicy) async -> CheckOutcome {
        var port: UInt16?
        if let allow = policy.allowedDomains {
            do { port = try await proxies.proxy(for: allow).port } catch {
                return GroupRun.fail("could not run the check: the egress proxy did not start (\(error))", outputURL: outputURL)
            }
        }
        let prepared: Prepared
        do { prepared = try prepare(command: command, environment: environment, policy: policy, proxyPort: port) } catch {
            Self.removeTemp(policy)
            return GroupRun.fail("could not run the check in the sandbox: \(error)", outputURL: outputURL)
        }
        let cancel = GroupRun.CancelFlag()
        let (grace, clock) = (termGrace, self.clock)
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let outcome = await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CheckOutcome, Never>) in
                let thread = Thread {
                    continuation.resume(returning: GroupRun.run(executable: Self.sandboxExec, arguments: prepared.arguments,
                                                                workingDirectory: cwd, timeout: seconds, outputURL: outputURL,
                                                                environment: prepared.environment, termGrace: grace, clock: clock,
                                                                cancel: cancel))
                }
                thread.name = "brahma-sandboxed-check"
                thread.start()
            }
        } onCancel: { cancel.set() }
        Self.removeTemp(policy)
        return outcome
    }

    public func spawn(command: String, cwd: URL, environment: [String: String], logURL: URL, policy: SandboxPolicy) throws -> any SandboxedProcess {
        let port = try policy.allowedDomains.map { try proxies.proxyNow(for: $0).port }
        let prepared = try prepare(command: command, environment: environment, policy: policy, proxyPort: port)
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = open(logURL.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw SandboxError.invalidPath("cannot open the log \(logURL.path)") }
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
        return SeatbeltProcess(child: child, capture: OutputCapture(readEnd: fds[0], file: file, cap: ProcessCheckRunner.outputCap,
                                                                    tailBytes: 4096, marker: ProcessCheckRunner.truncationMarker))
    }
}

/// A process `SeatbeltRunner.spawn` started (the leader of its own group). A reaper thread waits for the leader without
/// reaping it, sweeps what is left of its group, then reaps it; every signal goes through `ProcessGroupChild`, so none is
/// ever sent after the reap.
public final class SeatbeltProcess: SandboxedProcess, @unchecked Sendable {
    let child: ProcessGroupChild
    private let capture: OutputCapture
    private let reaped = DispatchSemaphore(value: 0)

    init(child: ProcessGroupChild, capture: OutputCapture) {
        self.child = child; self.capture = capture
        let thread = Thread { [child, capture, reaped] in
            child.finish()
            _ = capture.finish(drain: 2)
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
