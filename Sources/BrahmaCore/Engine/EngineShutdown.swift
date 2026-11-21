import Foundation

/// The engine's bounded shutdown (Plan 4a Task 9c). The owner's quit and stop must be prompt: everything the engine has in
/// flight is cancelled and then waited for together (the turn kill and `PreviewRunner.stopAll` side by side, never one after
/// the other), the whole wait bounded by `bound`. When the bound passes the shutdown proceeds to exit anyway, and what was
/// still running is named (engine-written names only) for the log. A second quit request during the shutdown goes through
/// `force`: a best-effort SIGKILL of every process group the engine recorded (turns, checks, merges, previews), the
/// in-progress turns recorded `interrupted`, and the caller exits at once. Nothing here signals a process the engine did
/// not start: the groups come from the engine's own records (`EmergencyStop.recordedGroups`), never from a scan.
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
    /// first: the names of the steps still running then (empty when all finished in time). A step left running is not
    /// cancelled here (its work was cancelled by the caller already); it simply no longer holds the exit.
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
            let timer = Task.detached {
                try? await AwakeTime.sleep(for: bound)
                once.fire()
            }
            once.onFire { timer.cancel() }
        }
        return pending.left
    }

    /// The second quit request: SIGTERM then at once SIGKILL to every process group the engine recorded: the turns' leaders
    /// the runner recorded at spawn (`Store.recordedTurnLeaders`, under `<runDir>/turns`: a turn the first quit already
    /// recorded `interrupted` still has its `claude` winding down, and only this record still names it), the in-progress
    /// turns' pids in the database, the checks' and merges' children and the previews' servers (`EmergencyStop.recordedGroups`).
    /// Each pid counts only while its start time still matches its record, so a reused pid is never signalled. Then the
    /// in-progress turns are recorded `interrupted` and their agents put back to `ready` (`recoverInterruptedTurns`, the same
    /// write the next engine's start would make). Blocking; what was signalled is returned for the caller's log.
    public static func force(store: Store, paths: BrahmaPaths, now: Date = Store.now()) -> EmergencyStop.Signalled {
        let groups = EmergencyStop.recordedGroups(store: store).union(Store.recordedTurnLeaders(paths: paths))
        let signalled = EmergencyStop.signalGroups(groups, grace: 0)
        _ = try? store.recoverInterruptedTurns(now: now)
        return signalled
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

/// Resumes its continuation exactly once, whichever caller fires first (the engine's one bounded wait; the app's engine host
/// has the same race on its side of the boundary).
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

    /// Runs `body` when `fire` is first called (at once when it already was).
    public func onFire(_ body: @escaping @Sendable () -> Void) {
        let runNow = lock.withLock { () -> Bool in
            if fired { return true }
            cleanup = body
            return false
        }
        if runNow { body() }
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
