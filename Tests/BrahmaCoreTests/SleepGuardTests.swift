import Testing
import Foundation
@testable import BrahmaCore

/// A caffeinate stand-in: alive until terminated or ended.
private final class FakeCaffeinate: SandboxedProcess, @unchecked Sendable {
    private let lock = NSLock()
    private var alive = true
    private var ended = 0
    let pid: Int32 = 4242
    func isAlive() -> Bool { lock.withLock { alive } }
    func exitStatus() -> Int32? { lock.withLock { alive ? nil : 0 } }
    func terminate(grace: Duration) async { lock.withLock { alive = false; ended += 1 } }
    func die() { lock.withLock { alive = false } }
    var terminations: Int { lock.withLock { ended } }
}

private final class Launches: @unchecked Sendable {
    private let lock = NSLock()
    private(set) var processes: [FakeCaffeinate] = []
    var available = true
    func launch() -> (any SandboxedProcess)? {
        lock.withLock {
            guard available else { return nil }
            let p = FakeCaffeinate(); processes.append(p); return p
        }
    }
    var count: Int { lock.withLock { processes.count } }
    var last: FakeCaffeinate? { lock.withLock { processes.last } }
}

private final class AwakeClock: @unchecked Sendable {
    private let lock = NSLock()
    private var t: TimeInterval = 1000
    func advance(_ s: TimeInterval) { lock.withLock { t += s } }
    var read: TimeInterval { lock.withLock { t } }
}

@Suite(.scratch) struct SleepGuardTests {
    private func make() -> (SleepGuard, Launches, AwakeClock) {
        let launches = Launches(), clock = AwakeClock()
        return (SleepGuard(launcher: { launches.launch() }, awake: { clock.read }), launches, clock)
    }

    private func settle(_ condition: () -> Bool) async throws {
        let deadline = AwakeTime.deadline(after: .seconds(60))
        while !condition(), AwakeTime.now < deadline { try await AwakeTime.sleep(for: .milliseconds(10)) }
    }

    @Test func startsWhileRunningStopsAfterGrace() async throws {
        let (guardian, launches, clock) = make()
        let now = Date()
        guardian.update(running: 1, enabled: true, now: now)
        guardian.update(running: 2, enabled: true, now: now)
        #expect(launches.count == 1 && guardian.isActive)
        // The last agent stops: caffeinate stays for the grace, then goes.
        guardian.update(running: 0, enabled: true, now: now)
        clock.advance(SleepGuard.idleGrace - 1)
        guardian.update(running: 0, enabled: true, now: now)
        #expect(guardian.isActive)
        clock.advance(1)
        guardian.update(running: 0, enabled: true, now: now)
        #expect(!guardian.isActive)
        let process = try #require(launches.last)
        try await settle { process.terminations == 1 }
        #expect(process.terminations == 1)
        // Work again: a new caffeinate.
        guardian.update(running: 1, enabled: true, now: now)
        #expect(launches.count == 2 && guardian.isActive)
    }

    @Test func workDuringGraceCancelsIt() {
        let (guardian, launches, clock) = make()
        let now = Date()
        guardian.update(running: 1, enabled: true, now: now)
        guardian.update(running: 0, enabled: true, now: now)
        clock.advance(50)
        guardian.update(running: 1, enabled: true, now: now)
        guardian.update(running: 0, enabled: true, now: now)
        clock.advance(50)                                              // 100 s since the first idle, 50 since the second
        guardian.update(running: 0, enabled: true, now: now)
        #expect(guardian.isActive && launches.count == 1)
    }

    @Test func disabledNeverLaunches() {
        let (guardian, launches, _) = make()
        guardian.update(running: 3, enabled: false, now: Date())
        #expect(launches.count == 0 && !guardian.isActive)
    }

    @Test func turningItOffStopsAtOnce() async throws {
        let (guardian, launches, _) = make()
        guardian.update(running: 1, enabled: true, now: Date())
        guardian.update(running: 1, enabled: false, now: Date())
        #expect(!guardian.isActive)
        let process = try #require(launches.last)
        try await settle { process.terminations == 1 }
        #expect(process.terminations == 1)
    }

    /// A system sleep moves the calendar, not the awake clock: it must not end the grace.
    @Test func aSystemSleepDoesNotCountTowardTheGrace() {
        let (guardian, _, clock) = make()
        let start = Date()
        guardian.update(running: 1, enabled: true, now: start)
        guardian.update(running: 0, enabled: true, now: start)
        clock.advance(10)
        guardian.update(running: 0, enabled: true, now: start.addingTimeInterval(8 * 3600))   // slept eight hours
        #expect(guardian.isActive)
        #expect(guardian.lastUpdate == start.addingTimeInterval(8 * 3600))
    }

    @Test func shutdownEndsItAndWaits() async {
        let (guardian, launches, _) = make()
        guardian.update(running: 1, enabled: true, now: Date())
        await guardian.shutdown()
        #expect(launches.last?.terminations == 1 && !guardian.isActive)
    }

    @Test func aMissingCaffeinateDegradesAndRetriesLater() {
        let (guardian, launches, clock) = make()
        launches.available = false
        guardian.update(running: 1, enabled: true, now: Date())
        guardian.update(running: 1, enabled: true, now: Date())
        #expect(launches.count == 0 && !guardian.isActive)
        launches.available = true
        guardian.update(running: 1, enabled: true, now: Date())
        #expect(launches.count == 0, "not retried every tick")
        clock.advance(SleepGuard.retryDelay)
        guardian.update(running: 1, enabled: true, now: Date())
        #expect(launches.count == 1 && guardian.isActive)
    }

    @Test func aCaffeinateThatDiedIsLaunchedAgain() {
        let (guardian, launches, _) = make()
        guardian.update(running: 1, enabled: true, now: Date())
        launches.last?.die()
        guardian.update(running: 1, enabled: true, now: Date())
        #expect(launches.count == 2 && guardian.isActive)
    }

    @Test func theEngineKeepsTheMacAwakeWhileATurnRunsAndStopsWithIt() async throws {
        let (guardian, launches, _) = make()
        let w = try World(sleepGuard: guardian)
        let c = try w.company("Acme"); let ceo = try w.hire(c, "ceo")
        let gate = Gate()
        w.fake.script("ceo", .init(gate: gate))
        try w.dm(c, ceo)
        await w.orchestrator.tick()
        #expect(await w.orchestrator.runningCount() == 1)
        await w.orchestrator.tick()
        #expect(launches.count == 1 && guardian.isActive)
        // The owner turns it off in the prefs: the next tick drops it.
        var prefs = try w.store.ownerPrefs(); prefs.preventSleep = false
        try w.store.updateOwnerPrefs(prefs)
        await w.orchestrator.tick()
        #expect(!guardian.isActive)
        prefs.preventSleep = true
        try w.store.updateOwnerPrefs(prefs)
        await w.orchestrator.tick()
        #expect(guardian.isActive && launches.count == 2)
        // Engine shutdown ends it, running or not.
        await w.orchestrator.stopSleepPrevention()
        #expect(!guardian.isActive)
        gate.open()
        try await w.orchestrator.waitUntilIdle(timeout: .seconds(60))
    }
}

@Suite(.scratch) struct CaffeinateProcessTests {
    /// A caffeinate stand-in from the shared fake-tool directory (one executable per body, never a fresh file per test).
    private func script(_ body: String) throws -> URL { try FakeTools.script("caffeinate", body) }

    private func alive(_ pid: Int32) -> Bool { kill(pid, 0) == 0 }

    /// Waits on `condition`, bounded by a generous awake-time deadline (full-suite load can slow a fake launch a lot).
    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = AwakeTime.deadline(after: .seconds(120))
        while !condition(), AwakeTime.now < deadline { try await AwakeTime.sleep(for: .milliseconds(20)) }
    }

    /// The pid a script wrote as one whole line (`echo $! > file`), or nil while the line is not complete yet.
    static func pidLine(_ file: URL) -> Int32? {
        guard let text = try? String(contentsOf: file, encoding: .utf8), text.hasSuffix("\n") else { return nil }
        return Int32(text.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    @Test func missingBinaryIsUnavailable() {
        #expect(CaffeinateProcess.launch(enginePid: 1, executable: "/nonexistent/caffeinate") == nil)
    }

    @Test func runsWithTheEnginePidAndTakesItsWholeGroupDown() async throws {
        let dir = try tempDir()
        let argsFile = dir.appending(path: "args"), childFile = dir.appending(path: "child")
        // Ignores TERM and has a child of its own: only a group KILL ends both. Both live until killed, however slow the suite
        // runs (a child that ended by itself would fail "alive" below by timing). The child's pid line is written last, after
        // the trap and the args: once it reads whole, everything below is in place (a file event, no fixed sleep).
        let exe = try script("trap '' TERM\necho \"$@\" > '\(argsFile.path)'\nsleep 600 &\necho $! > '\(childFile.path)'\nwait")
        let process = try #require(CaffeinateProcess.launch(enginePid: 777, executable: exe.path))
        defer { if process.isAlive() { _ = process.child.signalGroup(SIGKILL) } }
        try await waitUntil { Self.pidLine(childFile) != nil }
        #expect(try String(contentsOf: argsFile, encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines) == "-i -w 777")
        let child = try #require(Self.pidLine(childFile))
        #expect(process.isAlive() && alive(child))
        #expect(getpgid(process.pid) == process.pid, "its own process group")
        await process.terminate(grace: .milliseconds(200))
        #expect(!process.isAlive())
        try await waitUntil { !alive(child) }
        #expect(!alive(child), "the group was swept")
        #expect(!alive(process.pid))
    }

    @Test func terminatingTwiceIsHarmless() async throws {
        let exe = try script("exec sleep 600")
        let process = try #require(CaffeinateProcess.launch(enginePid: 1, executable: exe.path))
        await process.terminate(grace: .milliseconds(200))
        await process.terminate(grace: .milliseconds(200))
        #expect(!process.isAlive())
    }
}
