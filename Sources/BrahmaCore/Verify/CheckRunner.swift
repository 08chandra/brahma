import Foundation

/// Runs a check command. Never throws: whatever goes wrong is part of the outcome.
public protocol CheckRunning: Sendable {
    func run(command: String, workingDirectory: URL, timeout: TimeInterval, outputURL: URL,
             environment: [String: String]) async -> CheckOutcome
}

/// `/bin/sh -c <command>` in its own process group, stdin `/dev/null`, exactly the environment it is given. The first
/// 1 MB of output goes to `outputURL` (`[output truncated]` appended once); the outcome carries the real last 4000
/// characters. On timeout the whole group gets SIGTERM, and SIGKILL `termGrace` seconds later. When the shell exits, every
/// process still in its group is killed. A process that left the group (its own `setsid`, or a double fork) is NOT caught
/// here — only a sandboxed check's stragglers are swept, by their sandbox (`SeatbeltRunner.sweepStragglers`, B-I4); an
/// unsandboxed Full check can still leave one running. The process handling (`GroupRun`, `ProcessGroupChild`) is shared
/// with `SeatbeltRunner`; it never signals a group it has reaped and never touches a descriptor after it was closed.
public struct ProcessCheckRunner: CheckRunning {
    public static let outputCap = GroupRun.outputCap
    public static let tailChars = GroupRun.tailChars
    public static let truncationMarker = GroupRun.truncationMarker

    public var termGrace: TimeInterval
    /// Seconds on a clock that does not advance while the Mac sleeps, so a night's sleep cannot expire a check's timeout.
    public var clock: @Sendable () -> TimeInterval

    public init(termGrace: TimeInterval = 5, clock: @escaping @Sendable () -> TimeInterval = ProcessCheckRunner.uptime) {
        self.termGrace = termGrace; self.clock = clock
    }

    /// Monotonic uptime (mach absolute time / `CLOCK_MONOTONIC`): excludes time the system spent asleep.
    public static let uptime: @Sendable () -> TimeInterval = { AwakeTime.uptime() }

    public func run(command: String, workingDirectory: URL, timeout: TimeInterval, outputURL: URL,
                    environment: [String: String]) async -> CheckOutcome {
        let cancel = GroupRun.CancelFlag()
        let (grace, clock) = (termGrace, self.clock)
        let groups = ChildGroups.current
        return await withTaskCancellationHandler {
            await withCheckedContinuation { (continuation: CheckedContinuation<CheckOutcome, Never>) in
                // A thread of its own: a check can run for an hour and must not occupy a Dispatch or Swift concurrency worker.
                let thread = Thread {
                    continuation.resume(returning: GroupRun.run(executable: "/bin/sh", arguments: ["/bin/sh", "-c", command],
                                                                workingDirectory: workingDirectory, timeout: timeout,
                                                                outputURL: outputURL, environment: environment, termGrace: grace,
                                                                clock: clock, cancel: cancel, groups: groups))
                }
                thread.name = "brahma-check"
                thread.start()
            }
        } onCancel: { cancel.set() }
    }
}
