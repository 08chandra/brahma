import Foundation

/// The engine's bounded shutdown (Plan 4a Task 9c). The owner's quit and stop must be prompt: everything the engine has in
/// flight is cancelled and then waited for together (the turn kill, `PreviewRunner.stopAll`, litestream's and caffeinate's
/// stops side by side, never one after the other), the whole wait bounded by `bound`. When the bound passes the shutdown
/// proceeds to exit anyway: what was still running is named (engine-written names only) for the log, and the process groups
/// the engine recorded are killed (`killEngineProcesses`). A second quit request during the shutdown goes through `force`:
/// the same kill, the in-progress turns recorded `interrupted`, and the caller exits at once. Nothing here signals a process
/// the engine did not record: the groups are `EmergencyStop.engineGroups` (every source start-time checked), never a scan.
public enum EngineShutdown {
    /// The hard bound on the whole shutdown (awake time).
    public static let bound: Duration = .seconds(10)

    /// One piece of the shutdown, waited for under the bound, by its engine-written name.
    public struct Step: Sendable {
        public var name: String
        public var run: @Sendable () async -> Void

        public init(name: String, _ run: @escaping @Sendable () async -> Void) {
            self.name = name
            self.run = run
        }
    }

    /// Runs every step at once and returns once all have finished, or once `bound` of awake time has passed, whichever comes
    /// first: the names of the steps still running then (empty when all finished in time). The timer runs on its own thread
    /// (`ResumeOnce.fire(afterAwake:)`), not on the cooperative pool, so steps that block pool threads cannot delay it. A step
    /// left running is not cancelled here (its work was cancelled by the caller already); it simply no longer holds the exit.
    public static func run(_ steps: [Step], bound: Duration = bound) async -> [String] {
        guard !steps.isEmpty else { return [] }
        let pending = Pending(names: steps.map(\.name))
        let once = ResumeOnce()
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            once.install(continuation)
            for step in steps {
                Task.detached {
                    await step.run()
                    if pending.finished(step.name) { once.fire() }
                }
            }
            once.fire(afterAwake: bound)
        }
        return pending.left
    }

    /// Runs blocking `body` on its own thread (not the actor, not the cooperative pool) and returns when it is done.
    public static func onThread(_ body: @escaping @Sendable () -> Void) async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            Thread.detachNewThread {
                body()
                continuation.resume()
            }
        }
    }

    /// What the forced exit or an expired bound killed: the groups signalled and the litestream line, if any.
    public struct Killed: Equatable, Sendable {
        public var groups: EmergencyStop.Signalled
        public var litestream: String?

        public init(groups: EmergencyStop.Signalled = .init(), litestream: String? = nil) {
            self.groups = groups
            self.litestream = litestream
        }
    }

    /// Best-effort SIGKILL of everything the engine recorded as its own: SIGTERM then at once SIGKILL to
    /// `EmergencyStop.engineGroups` (the one stop every path shares), and the litestream its pid file names (argv-checked;
    /// `WALShipper.killRecorded`). caffeinate (`-w <engine pid>`) ends by itself when the engine exits. Blocking.
    public static func killEngineProcesses(store: Store, paths: BrahmaPaths) -> Killed {
        Killed(groups: EmergencyStop.signalEngineGroups(store: store, paths: paths, grace: 0),
               litestream: WALShipper.killRecorded(paths: paths))
    }

    /// The second quit request, from the process that holds the engine lock (the caller checks: another engine's work is never
    /// touched): `killEngineProcesses`, then the in-progress turns recorded `interrupted` and their agents put back to `ready`
    /// (`recoverInterruptedTurns`, the same write the next engine's start would make). Blocking; what was killed is returned
    /// for the caller's log.
    public static func force(store: Store, paths: BrahmaPaths, now: Date = Store.now()) -> Killed {
        let killed = killEngineProcesses(store: store, paths: paths)
        _ = try? store.recoverInterruptedTurns(now: now)
        return killed
    }

    /// `bound` as the log shows it (`10 s`, `0.3 s`).
    public static func seconds(_ d: Duration) -> String {
        let s = Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18
        return s == s.rounded() ? "\(Int(s)) s" : String(format: "%.1f s", s)
    }

    /// The step names not yet finished.
    private final class Pending: @unchecked Sendable {
        private let lock = NSLock()
        private var names: [String]

        init(names: [String]) { self.names = names }

        /// Removes `name`; true when it was the last one.
        func finished(_ name: String) -> Bool {
            lock.withLock {
                if let i = names.firstIndex(of: name) { names.remove(at: i) }
                return names.isEmpty
            }
        }

        var left: [String] { lock.withLock { names } }
    }
}

/// Resumes its continuation exactly once, whichever caller fires first (the engine's bounded waits and the app's engine host).
public final class ResumeOnce: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<Void, Never>?
    private var fired = false
    private var cleanup: (@Sendable () -> Void)?

    public init() {}

    /// Installs the continuation; one installed after `fire` already ran is resumed at once.
    public func install(_ c: CheckedContinuation<Void, Never>) {
        let now = lock.withLock { () -> Bool in
            if fired { return true }
            continuation = c
            return false
        }
        if now { c.resume() }
    }

    /// Whether `fire` has run.
    public var hasFired: Bool { lock.withLock { fired } }

    /// Runs `body` when `fire` is first called (at once when it already was).
    public func onFire(_ body: @escaping @Sendable () -> Void) {
        let runNow = lock.withLock { () -> Bool in
            if fired { return true }
            cleanup = body
            return false
        }
        if runNow { body() }
    }

    /// Fires after `bound` of awake time unless fired before, from a dedicated thread (a hard timer: the cooperative pool's
    /// load cannot delay it). The thread polls `AwakeTime` every 50 ms and ends as soon as the race is decided.
    public func fire(afterAwake bound: Duration) {
        let deadline = AwakeTime.deadline(after: bound)
        Thread.detachNewThread { [self] in
            while !hasFired, AwakeTime.now < deadline { usleep(50_000) }
            fire()
        }
    }

    public func fire() {
        let (c, cleanup) = lock.withLock { () -> (CheckedContinuation<Void, Never>?, (@Sendable () -> Void)?) in
            guard !fired else { return (nil, nil) }
            fired = true
            defer { continuation = nil; self.cleanup = nil }
            return (continuation, self.cleanup)
        }
        c?.resume()
        cleanup?()
    }
}
