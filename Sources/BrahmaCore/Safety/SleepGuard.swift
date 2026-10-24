import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Keeps the Mac awake (`caffeinate -i -w <engine pid>`) while agents run, and for `idleGrace` after the last one stops.
///
/// Time: the grace counts awake time (`AwakeTime.uptime()`), never calendar time. A system sleep during the grace must not
/// end it (nothing ran while the Mac slept), and the Mac cannot sleep while caffeinate holds the assertion anyway, so only
/// a forced sleep (lid closed, low battery) could differ. The brief's `now: Date` is kept in the signature and recorded
/// (`lastUpdate`), but no decision depends on it; tests inject the awake clock through `awake`.
///
/// caffeinate watches the engine (`-w`), so it ends by itself if the engine crashes. `shutdown()` ends it on a normal stop.
public final class SleepGuard: @unchecked Sendable {
    /// How long caffeinate stays up after the last agent stopped (awake seconds).
    public static let idleGrace: TimeInterval = 60
    /// After a launch that found no caffeinate, the next try is this many awake seconds later.
    static let retryDelay: TimeInterval = 30

    public typealias Launcher = @Sendable () -> (any SandboxedProcess)?

    private let launcher: Launcher
    private let awake: @Sendable () -> TimeInterval
    private let lock = NSLock()
    private var process: (any SandboxedProcess)?
    private var idleSince: TimeInterval?
    private var nextAttempt: TimeInterval = 0
    private var launches = 0
    private var last: Date?

    public init(launcher: @escaping Launcher, awake: @escaping @Sendable () -> TimeInterval = { AwakeTime.uptime() }) {
        self.launcher = launcher
        self.awake = awake
    }

    /// A guard that never launches anything (tests, hosts without sleep prevention).
    public static var disabled: SleepGuard { SleepGuard(launcher: { nil }) }

    /// True while caffeinate is up.
    public var isActive: Bool { lock.withLock { process?.isAlive() == true } }
    /// How many times caffeinate was launched (tests).
    public var launchCount: Int { lock.withLock { launches } }
    /// The `now` of the latest `update`.
    public var lastUpdate: Date? { lock.withLock { last } }

    /// Called once per engine tick. `running`: turns, checks and merges in flight. `enabled`: the owner's `preventSleep`.
    public func update(running: Int, enabled: Bool, now: Date) {
        let ended: (any SandboxedProcess)? = lock.withLock {
            last = now
            let t = awake()
            if let p = process, !p.isAlive() { process = nil }          // it ended by itself: launched again if still wanted
            guard enabled else { return takeLocked() }
            if running > 0 {
                idleSince = nil
                if process == nil, t >= nextAttempt {
                    if let p = launcher() { process = p; launches += 1 } else { nextAttempt = t + Self.retryDelay }
                }
                return nil
            }
            guard process != nil else { return nil }
            let since = idleSince ?? t
            idleSince = since
            return t - since >= Self.idleGrace ? takeLocked() : nil
        }
        if let ended { Task.detached { await ended.terminate(grace: .milliseconds(500)) } }
    }

    /// Ends caffeinate now and waits for it (the engine is stopping).
    public func shutdown() async {
        let ended = lock.withLock { takeLocked() }
        await ended?.terminate(grace: .milliseconds(500))
    }

    private func takeLocked() -> (any SandboxedProcess)? {
        let p = process
        process = nil; idleSince = nil
        return p
    }

    deinit {
        if let p = process { Task.detached { await p.terminate(grace: .milliseconds(200)) } }
    }
}

/// `/usr/bin/caffeinate -i -w <pid>` as the leader of its own process group (`ProcessGroupChild`), so terminating it takes
/// anything it spawned with it. caffeinate is a system binary and runs unsandboxed.
public final class CaffeinateProcess: SandboxedProcess, @unchecked Sendable {
    public static let systemPath = "/usr/bin/caffeinate"
    let child: ProcessGroupChild

    private init(child: ProcessGroupChild) {
        self.child = child
        // Reaps it whenever it ends, sweeping its group first (`ProcessGroupChild.finish`).
        let thread = Thread { [child] in child.finish() }
        thread.name = "brahma-caffeinate-reaper"
        thread.start()
    }

    /// Nil when `executable` is missing (Linux) or cannot be started. `executable` is a test seam.
    public static func launch(enginePid: Int32, executable: String = systemPath) -> CaffeinateProcess? {
        guard access(executable, X_OK) == 0 else { return nil }
        let child = try? ProcessGroupChild.spawn(executable: executable, arguments: [executable, "-i", "-w", String(enginePid)],
                                                 environment: [:], workingDirectory: URL(fileURLWithPath: "/", isDirectory: true),
                                                 output: -1)
        return child.map(CaffeinateProcess.init)
    }

    /// The launcher the engine uses: caffeinate tied to this process.
    public static func launcher(enginePid: Int32 = getpid()) -> SleepGuard.Launcher {
        { launch(enginePid: enginePid) }
    }

    public var pid: Int32 { child.pid }
    public func isAlive() -> Bool { !child.hasExited() }
    public func exitStatus() -> Int32? { child.hasExited() ? ProcessGroupChild.exitCode(child.finish()) : nil }

    public func terminate(grace: Duration) async {
        if !child.hasExited() {
            child.signalGroup(SIGTERM)
            let deadline = AwakeTime.deadline(after: grace)
            while !child.hasExited(), AwakeTime.now < deadline { try? await AwakeTime.sleep(for: .milliseconds(20)) }
            if !child.hasExited() { child.signalGroup(SIGKILL) }
        }
        // The reaper thread sweeps the group and reaps; wait for that.
        while !child.hasExited() { try? await AwakeTime.sleep(for: .milliseconds(10)) }
        _ = child.finish()
    }
}
