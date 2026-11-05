import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import BrahmaCore

/// A `SandboxedRunner` that runs commands unsandboxed (`/bin/sh -c`) through 3a's process-group helpers (`GroupRun` for
/// `run`, `ProcessGroupChild` for `spawn`: its own process group, signalled only while unreaped), and records every call
/// (PR-38). Tests only: the policy is recorded, never enforced.
final class FakeSandbox: SandboxedRunner, @unchecked Sendable {
    struct Call: Equatable, Sendable {
        enum Kind: Equatable, Sendable { case run, spawn }
        var kind: Kind
        var command: String
        var cwd: URL
        var environment: [String: String]
        var policy: SandboxPolicy
        /// `run`'s `outputURL` or `spawn`'s `logURL`.
        var output: URL
    }

    private let lock = NSLock()
    private var recorded: [Call] = []
    /// When set, `spawn` throws it (after recording the call).
    var spawnError: (any Error)?

    private var spawned: [Int32] = []

    /// Callers of `waitForSpawn` still waiting, with what they wait for.
    private var spawnWaiters: [(matches: @Sendable (Call) -> Bool, continuation: CheckedContinuation<Void, Never>)] = []

    var calls: [Call] { lock.withLock { recorded } }

    /// Returns once `spawn` has started a process for a call that `matches` (at once when one already has): an event, never
    /// a timer, so a test can act on a running step under any load.
    func waitForSpawn(_ matches: @escaping @Sendable (Call) -> Bool) async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let now = lock.withLock { () -> Bool in
                if startedCalls.contains(where: matches) { return true }
                spawnWaiters.append((matches, c))
                return false
            }
            if now { c.resume() }
        }
    }

    private var startedCalls: [Call] = []

    private func started(_ call: Call) {
        let ready = lock.withLock { () -> [CheckedContinuation<Void, Never>] in
            startedCalls.append(call)
            let (hit, rest) = (spawnWaiters.filter { $0.matches(call) }, spawnWaiters.filter { !$0.matches(call) })
            spawnWaiters = rest
            return hit.map(\.continuation)
        }
        for c in ready { c.resume() }
    }
    /// The pid (process group) of every process `spawn` started, in order.
    var spawnedPids: [Int32] { lock.withLock { spawned } }
    var lastSpawnedPid: Int32? { spawnedPids.last }
    private func record(_ call: Call) { lock.withLock { recorded.append(call) } }

    func run(command: String, cwd: URL, environment: [String: String], timeout: Duration, outputURL: URL,
             policy: SandboxPolicy) async -> CheckOutcome {
        record(Call(kind: .run, command: command, cwd: cwd, environment: environment, policy: policy, output: outputURL))
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let cancel = GroupRun.CancelFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CheckOutcome, Never>) in
                Thread.detachNewThread {   // scope-escape: the blocking run on its own thread (as SeatbeltRunner); no scratch dirs
                    continuation.resume(returning: GroupRun.run(
                        executable: "/bin/sh", arguments: ["/bin/sh", "-c", command], workingDirectory: cwd, timeout: seconds,
                        outputURL: outputURL, environment: environment, termGrace: 1, clock: { AwakeTime.uptime() }, cancel: cancel))
                }
            }
        } onCancel: { cancel.set() }
    }

    func spawn(command: String, cwd: URL, environment: [String: String], logURL: URL, policy: SandboxPolicy) throws -> any SandboxedProcess {
        record(Call(kind: .spawn, command: command, cwd: cwd, environment: environment, policy: policy, output: logURL))
        if let spawnError { throw spawnError }
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = open(logURL.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw SandboxError.invalidPath("cannot open the log \(logURL.path)") }
        defer { close(file) }
        let child = try ProcessGroupChild.spawn(executable: "/bin/sh", arguments: ["/bin/sh", "-c", command], environment: environment,
                                                workingDirectory: cwd, output: file)
        lock.withLock { spawned.append(child.pid) }
        let process = FakeSandboxProcess(child: child)
        started(Call(kind: .spawn, command: command, cwd: cwd, environment: environment, policy: policy, output: logURL))
        return process
    }
}

/// A process `FakeSandbox.spawn` started. A reaper thread waits for the leader without reaping it, sweeps its group, then
/// reaps it (`ProcessGroupChild.finish`), so no signal is ever sent after the reap.
final class FakeSandboxProcess: SandboxedProcess, @unchecked Sendable {
    let child: ProcessGroupChild
    private let lock = NSLock()
    private var reaped = false

    init(child: ProcessGroupChild) {
        self.child = child
        Thread.detachNewThread { [self] in   // scope-escape: the reaper only waits on the child; no scratch dirs
            child.finish()
            lock.withLock { reaped = true }
        }
    }

    var pid: Int32 { child.pid }
    func isAlive() -> Bool { !child.hasExited() }

    func exitStatus() -> Int32? {
        guard child.hasExited() else { return nil }
        return ProcessGroupChild.exitCode(child.finish())
    }

    func terminate(grace: Duration) async {
        if !child.hasExited() {
            child.signalGroup(SIGTERM)
            let deadline = AwakeTime.deadline(after: grace)
            while !child.hasExited(), AwakeTime.now < deadline { try? await AwakeTime.sleep(for: .milliseconds(20)) }
            if !child.hasExited() { child.signalGroup(SIGKILL) }
        }
        while !lock.withLock({ reaped }) { try? await AwakeTime.sleep(for: .milliseconds(10)) }
    }
}
