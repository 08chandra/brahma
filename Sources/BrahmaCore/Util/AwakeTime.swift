import Foundation

/// The one clock every timeout, deadline and hang backstop counts on: awake time.
///
/// `SuspendingClock` stands still while the Mac sleeps (on Darwin it is `mach_absolute_time`, the base of `DispatchTime`
/// too), so a system sleep never expires a wait whose work was frozen along with it. `ContinuousClock`, `Task.sleep(for:)`
/// and `Date` all count the sleep: a 60 s backstop that spans a night fires on wake although nothing it guards has run. The
/// idle backstop (`Orchestrator.idleBackstopClock`), check timeouts (`ProcessCheckRunner.uptime`), git's lock waits, the turn
/// wall clock, the doctor's probe and the app's stop bound all use this, and so do the tests' polling deadlines.
public enum AwakeTime {
    public static let clock = SuspendingClock()

    public static var now: SuspendingClock.Instant { clock.now }

    /// `duration` of awake time from now.
    public static func deadline(after duration: Duration) -> SuspendingClock.Instant { clock.now.advanced(by: duration) }

    /// Sleeps for `duration` of awake time.
    public static func sleep(for duration: Duration) async throws { try await clock.sleep(for: duration) }

    /// Awake seconds since boot, for blocking code that polls on a thread (the same base as `clock`).
    public static func uptime() -> TimeInterval { TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1_000_000_000 }
}
