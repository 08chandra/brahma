import Testing
import Foundation
@testable import BrahmaCore

/// Every timeout and hang backstop counts awake time (`AwakeTime`), the clock of the idle backstop: a Mac that sleeps through
/// a wait never makes it expire with the work it guards merely frozen.
@Suite(.scratch) struct AwakeTimeTests {
    @Test func theSharedClockIsTheIdleBackstopsAndTheChecks() {
        #expect(Orchestrator.idleBackstopClock is SuspendingClock)
        #expect(type(of: AwakeTime.clock) == SuspendingClock.self)
        // The thread-side reading and the clock share one base (uptime): they agree to well within a second.
        let a = AwakeTime.uptime(), b = ProcessCheckRunner.uptime()
        #expect(abs(a - b) < 1)
    }

    /// No deadline on a clock that counts sleep, anywhere in the sources or the tests: `ContinuousClock` is not used at all,
    /// and the sources build no deadline from `Date` (`Task.sleep(for:)` stays only as a poll interval or settle delay).
    @Test func noDeadlineCountsSystemSleep() throws {
        var offenders: [String] = []
        for dir in ["Sources", "Tests"] {
            for (path, text) in try EngineGitGuardTests.sources(under: dir) where !path.hasSuffix("AwakeTimeTests.swift") {
                let code = EngineGitGuardTests.code(text)
                if code.contains("ContinuousClock") { offenders.append("\(path): ContinuousClock") }
                if dir == "Sources", code.range(of: #"Date\(\)\.addingTimeInterval\(|Date\(\)\s*<"#, options: .regularExpression) != nil {
                    offenders.append("\(path): a Date deadline")
                }
            }
        }
        #expect(offenders.isEmpty, "\(offenders)")
    }
}
