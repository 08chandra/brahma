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

/// An injectable awake-time clock (the plan's `AwakeClock`, Ruling 40): `now` is awake time since a fixed origin, and `sleep`
/// returns once `now` reaches the deadline. Production uses `SystemAwakeClock` (`AwakeTime.clock`); tests advance a manual one,
/// so grace periods are exact without waiting.
public protocol AwakeClock: Sendable {
    /// Awake time elapsed since this clock's origin.
    var now: Duration { get }
    /// Returns once `now >= deadline`; throws `CancellationError` when the calling task is cancelled first.
    func sleep(until deadline: Duration) async throws
}

/// `AwakeTime.clock` as an `AwakeClock` (origin: when the value was made).
public struct SystemAwakeClock: AwakeClock {
    private let origin: SuspendingClock.Instant

    public init() { origin = AwakeTime.now }

    public var now: Duration { origin.duration(to: AwakeTime.now) }

    public func sleep(until deadline: Duration) async throws {
        try await AwakeTime.clock.sleep(until: origin.advanced(by: deadline), tolerance: nil)
    }
}
