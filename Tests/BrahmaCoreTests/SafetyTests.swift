import Testing
import Foundation
@testable import BrahmaCore

@Test(.scratch) func secondOrchestratorLockFailsUntilFirstIsReleased() throws {
    let root = try tempDir()
    let paths = BrahmaPaths(home: root.appending(path: "home"), workspaces: root.appending(path: "ws"))
    var first: OrchestratorLock? = try OrchestratorLock.acquire(paths: paths)
    #expect(throws: OrchestratorLockError.alreadyRunning) { _ = try OrchestratorLock.acquire(paths: paths) }
    #expect(first != nil)
    first = nil
    _ = try OrchestratorLock.acquire(paths: paths)
}

/// Ruling R42(b): a probe that holds a shared lock for an instant (`SoakEngine.startedAt`) overlapping a real start must not
/// refuse it: `acquire` retries a busy lock for up to 5 × 20 ms before it says another engine is running.
@Test(.scratch) func briefSharedProbeDoesNotRefuseAStart() throws {
    let root = try tempDir()
    let paths = BrahmaPaths(home: root.appending(path: "home"), workspaces: root.appending(path: "ws"))
    try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
    let fd = open(paths.home.appending(path: "orchestrator.lock").path, O_RDWR | O_CREAT | O_CLOEXEC, 0o600)
    try #require(fd >= 0)
    try #require(flock(fd, LOCK_SH | LOCK_NB) == 0)
    let probe = Thread {
        Thread.sleep(forTimeInterval: 0.01)
        flock(fd, LOCK_UN)
        close(fd)
    }
    probe.start()
    let lock = try OrchestratorLock.acquire(paths: paths)
    withExtendedLifetime(lock) {}
}

/// Ruling R42(b): a lock another engine really holds is still refused, after the retries (about 100 ms).
@Test(.scratch) func heldExclusiveLockStillRefusedAfterRetries() throws {
    let root = try tempDir()
    let paths = BrahmaPaths(home: root.appending(path: "home"), workspaces: root.appending(path: "ws"))
    let first = try OrchestratorLock.acquire(paths: paths)
    let started = AwakeTime.uptime()
    #expect(throws: OrchestratorLockError.alreadyRunning) { _ = try OrchestratorLock.acquire(paths: paths) }
    let waited = AwakeTime.uptime() - started
    #expect(waited >= 0.09 && waited < 5, "refused after \(waited) s")
    withExtendedLifetime(first) {}
}

/// The flake behind `secondOrchestratorLockFailsUntilFirstIsReleased` under load: while another thread of this process is
/// spawning a child, the child briefly holds a copy of every descriptor (`O_CLOEXEC` ones too, until its exec closes them),
/// so a lock that was only `close`d stayed held by that copy and the very next acquire saw `.alreadyRunning`. Releasing
/// unlocks explicitly before closing, so no copy can keep it.
@Test(.scratch) func orchestratorLockIsFreeTheMomentItIsReleasedWhileChildrenSpawn() throws {
    let root = try tempDir()
    let paths = BrahmaPaths(home: root.appending(path: "home"), workspaces: root.appending(path: "ws"))
    let stop = LockFlag()
    let spawners = (0..<4).map { _ in
        Thread {
            while !stop.isSet {
                let p = Process()
                p.executableURL = URL(fileURLWithPath: "/usr/bin/true")
                p.standardInput = FileHandle.nullDevice; p.standardOutput = FileHandle.nullDevice; p.standardError = FileHandle.nullDevice
                if (try? p.run()) != nil { p.waitUntilExit() }
            }
        }
    }
    spawners.forEach { $0.start() }
    defer { stop.set() }
    var refused = 0
    for _ in 0..<3000 {
        do { _ = try OrchestratorLock.acquire(paths: paths) } catch OrchestratorLockError.alreadyRunning { refused += 1 }
    }
    #expect(refused == 0, "a released lock was still held \(refused) times out of 3000")
}

private final class LockFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.withLock { value = true } }
    var isSet: Bool { lock.withLock { value } }
}

@Test(.scratch) func sanitizerNeutralisesControlCharacters() {
    #expect(TerminalText.sanitize("a\u{1B}[2Jb") == "a [2Jb")
    #expect(TerminalText.sanitize("x\u{9B}31my") == "x 31my")
    #expect(TerminalText.sanitize("p\u{7F}q") == "p q")
    #expect(TerminalText.sanitize("line1\nline2\ttab\r") == "line1 line2 tab ")
    #expect(TerminalText.sanitize("héllo ✓ 日本") == "héllo ✓ 日本")
}
