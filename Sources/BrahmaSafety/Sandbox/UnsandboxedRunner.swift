import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The runner a Full company's previews use (PR-5: as its checks run unsandboxed): `/bin/sh -c` in its own process group
/// through 3a's helpers (`GroupRun`, `ProcessGroupChild`, `OutputCapture`), the policy unenforced.
public struct UnsandboxedPreviewRunner: SandboxedRunner {
    public init() {}

    public func run(command: String, cwd: URL, environment: [String: String], timeout: Duration, outputURL: URL,
                    policy: SandboxPolicy) async -> CheckOutcome {
        let seconds = Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18
        let cancel = GroupRun.CancelFlag()
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CheckOutcome, Never>) in
                let thread = Thread {
                    continuation.resume(returning: GroupRun.run(
                        executable: "/bin/sh", arguments: ["/bin/sh", "-c", command], workingDirectory: cwd, timeout: seconds,
                        outputURL: outputURL, environment: environment, termGrace: 5, clock: { AwakeTime.uptime() }, cancel: cancel))
                }
                thread.name = "brahma-preview-build"
                thread.start()
            }
        } onCancel: { cancel.set() }
    }

    public func spawn(command: String, cwd: URL, environment: [String: String], logURL: URL, policy: SandboxPolicy) throws -> any SandboxedProcess {
        try FileManager.default.createDirectory(at: logURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        let file = open(logURL.path, O_WRONLY | O_CREAT | O_APPEND | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw SandboxError.invalidPath("cannot open the log \(logURL.path)") }
        var fds: [Int32] = [0, 0]
        guard pipe(&fds) == 0 else { close(file); throw SandboxError.invalidPath("no pipe for the log") }
        _ = fcntl(fds[0], F_SETFD, FD_CLOEXEC); _ = fcntl(fds[1], F_SETFD, FD_CLOEXEC)
        let child: ProcessGroupChild
        do {
            child = try ProcessGroupChild.spawn(executable: "/bin/sh", arguments: ["/bin/sh", "-c", command], environment: environment,
                                                workingDirectory: cwd, output: fds[1])
        } catch {
            close(fds[0]); close(fds[1]); close(file)
            throw error
        }
        close(fds[1])
        return PlainGroupProcess(child: child, capture: OutputCapture(readEnd: fds[0], file: file, cap: GroupRun.outputCap,
                                                                      tailBytes: 4096, marker: GroupRun.truncationMarker))
    }
}

/// A process `UnsandboxedPreviewRunner.spawn` started: a reaper thread waits for the leader without reaping it, ends the
/// output capture, then reaps it (`ProcessGroupChild.finish`), so no signal is sent after the reap.
final class PlainGroupProcess: SandboxedProcess, @unchecked Sendable {
    let child: ProcessGroupChild
    private let reaped = DispatchSemaphore(value: 0)

    init(child: ProcessGroupChild, capture: OutputCapture) {
        self.child = child
        let thread = Thread { [child, capture, reaped] in
            child.finish()
            _ = capture.finish(drain: 2)
            reaped.signal()
        }
        thread.name = "brahma-preview-reaper"
        thread.start()
    }

    var pid: Int32 { child.pid }
    var leaderStart: Double? { child.leaderStart }
    func isAlive() -> Bool { !child.hasExited() }

    func exitStatus() -> Int32? {
        guard child.hasExited() else { return nil }
        return ProcessGroupChild.exitCode(child.finish())
    }

    func terminate(grace: Duration) async {
        if !child.hasExited() {
            child.signalGroup(SIGTERM)
            let deadline = AwakeTime.deadline(after: grace)
            while !child.hasExited(), AwakeTime.now < deadline {
                // Cancelled: the grace still runs out on the clock and the group is SIGKILLed below (paced, not spun).
                do { try await AwakeTime.sleep(for: .milliseconds(20)) } catch { usleep(20_000) }
            }
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
