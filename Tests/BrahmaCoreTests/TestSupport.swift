import Testing
import Foundation
import GRDB
@testable import BrahmaCore
import BrahmaKeychain

/// Armed on first use (every temp dir touches it): any later Keychain call in this process crashes instead of
/// prompting the owner for the login password. Tests use `InMemoryOwnerKeyStore`, and CLI subprocesses use
/// `BRAHMA_OWNER_KEY_STORE=file`. The one live-Keychain test opts out with `BRAHMA_LIVE_KEYCHAIN=1`.
let keychainTrapArmed: Bool = {
    if ProcessInfo.processInfo.environment["BRAHMA_LIVE_KEYCHAIN"] == "1" { return false }
    KeychainAccessLog.forbid()
    return true
}()

/// A directory for this test case under the process root (`TestScratch.swift`), removed when the case ends.
func tempDir() throws -> URL {
    _ = sigpipeTrapArmed
    _ = keychainTrapArmed
    return try Scratch.dir()
}

/// S5 fix C1: writes `data` to a child's standard input and closes it. A child that exited without reading it fails its own
/// test (its status, its output), never the whole test process with SIGPIPE (`Spawn.writeAll`: EPIPE instead).
func feedChildInput(_ pipe: Pipe, _ data: Data) {
    _ = data.withUnsafeBytes { Spawn.writeAll(pipe.fileHandleForWriting.fileDescriptor, $0) }
    try? pipe.fileHandleForWriting.close()
}

/// S5 fix C1 (diagnosis): a SIGPIPE that still reaches this test process prints the writing thread's stack to stderr before
/// the process ends exactly as it would have (default action, signal 13), so a full run's log names the writer.
let sigpipeTrapArmed: Bool = {
    signal(SIGPIPE) { _ in
        let banner = "\nbrahma tests: SIGPIPE; the writing thread's stack:\n"
        _ = banner.withCString { write(2, $0, strlen($0)) }
        var frames = [UnsafeMutableRawPointer?](repeating: nil, count: 64)
        backtrace_symbols_fd(&frames, backtrace(&frames, 64), 2)
        signal(SIGPIPE, SIG_DFL)
        raise(SIGPIPE)   // blocked while this handler runs: delivered, with the default action, when it returns
    }
    return true
}()

// MARK: owner key helpers for CLI subprocess tests

func brahmaExecutableURL() -> URL { Bundle.module.bundleURL.deletingLastPathComponent().appending(path: "brahma") }

/// The data home the `brahma` test helpers use for a temp dir.
func ownerPaths(_ home: URL) -> BrahmaPaths {
    BrahmaPaths(home: home.appending(path: "home"), workspaces: home.appending(path: "ws"))
}

/// The environment every `brahma` subprocess test uses: a throwaway data home and the file owner-key store, so the
/// CLI never touches the login Keychain.
func cliEnvironment(home: URL) -> [String: String] {
    let paths = ownerPaths(home)
    return ["BRAHMA_HOME": paths.home.path, "BRAHMA_WORKSPACES": paths.workspaces.path, "PATH": "/usr/bin:/bin",
            "BRAHMA_OWNER_KEY_STORE": "file", "BRAHMA_SECRET_STORE": "file"]
}

/// Runs `brahma owner init` under a pseudo-terminal (`script`), the only way to satisfy its TTY check.
/// Returns the exit status.
@discardableResult
func initOwnerKey(home: URL, extraArgs: [String] = []) throws -> Int32 {
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
    p.arguments = ["-q", "/dev/null", brahmaExecutableURL().path, "owner", "init"] + extraArgs
    p.environment = cliEnvironment(home: home)
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

/// A temp data home whose owner key was created with `brahma owner init` (file store: the hash lives in the home).
final class OwnerTestHome: @unchecked Sendable {
    let url: URL
    init(initOwner: Bool = true) throws {
        url = try tempDir()
        if initOwner { try #require(try initOwnerKey(home: url) == 0, "brahma owner init failed under script") }
    }
}

// MARK: secrets helpers

extension MemoryVault {
    /// The vault with one value stored (for tests that set a secret and load it).
    func with(_ companyId: String, _ name: String, _ value: String) -> MemoryVault {
        try? set(companyId: companyId, name: name, value: value)
        return self
    }
}

/// Every column of every table, as text: where a leaked value would have to be to leak.
func dumpDatabase(_ store: Store) throws -> String {
    try store.writer.read { db in
        var out = ""
        for table in try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name NOT LIKE 'sqlite_%'") {
            for row in try Row.fetchAll(db, sql: "SELECT * FROM \"\(table)\"") {
                out += "\(table): " + row.databaseValues.map { "\($0)" }.joined(separator: " | ") + "\n"
            }
        }
        return out
    }
}

// MARK: toolchain

/// Xcode for the sandboxed toolchain tests (`SeatbeltRunnerTests`): its developer directory, and whether it and Seatbelt exist.
enum Toolchain {
    static let developerDir = "/Applications/Xcode.app/Contents/Developer"
    static var seatbeltAvailable: Bool { FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec") }
    static var xcodeAvailable: Bool {
        FileManager.default.isExecutableFile(atPath: developerDir + "/usr/bin/xcodebuild")
            && FileManager.default.isExecutableFile(atPath: "/usr/bin/sandbox-exec")
    }
}

/// 3a's orchestration tests run their companies on the Workspace profile; the Sandboxed profile (5-lite's default for new
/// companies) has its own tests (`SandboxTurnTests`).
@discardableResult
func onWorkspaceProfile(_ store: Store, _ company: Company) throws -> Company {
    try store.updateSandbox(companyId: company.id, SandboxPatch(profile: .workspace), userHome: try tempDir())
    return try store.company(id: company.id) ?? company
}

// MARK: descriptors

/// One owner for a raw descriptor in tests: `close()` closes it at most once, and the owner closes it on deinit if nobody
/// did. A second close of a descriptor number that was already reused by someone else (a `defer` plus an explicit close)
/// trips macOS's EXC_GUARD and kills the test process; this makes that impossible.
final class OwnedFD: @unchecked Sendable {
    private let lock = NSLock()
    private var fd: Int32
    init(_ fd: Int32) { self.fd = fd }
    var raw: Int32 { lock.withLock { fd } }
    func close() {
        let toClose: Int32 = lock.withLock { let f = fd; fd = -1; return f }
        #if canImport(Darwin)
        if toClose >= 0 { _ = Darwin.close(toClose) }
        #else
        if toClose >= 0 { _ = Glibc.close(toClose) }
        #endif
    }
    deinit { close() }
}

/// A child process a test starts and ends itself: its own process group, no inherited stdio, watched by pid (`waitid`), ended
/// by SIGKILL to its group, then a bounded awake-time wait, then reaped. Not Foundation's `Process`: it reports the child's
/// exit through the run loop of the thread that launched it, so in an async test that resumed on another Swift-concurrency
/// worker after an `await`, `waitUntilExit` can wait forever (`cannotInspectOtherProcessesOpenFiles` hung so) and `isRunning`
/// can stay true for a child that is long gone (`stalePidHandled` failed so).
final class OutsideChild {
    private let child: ProcessGroupChild
    var pid: Int32 { child.pid }

    /// `/bin/sh -c script`.
    convenience init(_ script: String) throws { try self.init(executable: "/bin/sh", arguments: ["-c", script]) }

    init(executable: String, arguments: [String]) throws {
        child = try ProcessGroupChild.spawn(executable: executable, arguments: [executable] + arguments, environment: ["PATH": "/usr/bin:/bin"],
                                            workingDirectory: URL(fileURLWithPath: "/", isDirectory: true), output: -1)
    }

    var isRunning: Bool { !child.hasExited() }

    /// Once it has exited: whether a signal ended it (reaps it).
    var endedBySignal: Bool? { child.hasExited() ? child.finish() & 0x7f != 0 : nil }

    /// Kills its group and reaps it; gives up (leaving it unreaped, never signalled again) after `bound` awake seconds.
    func end(bound: TimeInterval = 60) {
        _ = child.signalGroup(SIGKILL)
        let until = AwakeTime.uptime() + bound
        while !child.hasExited(), AwakeTime.uptime() < until { Thread.sleep(forTimeInterval: 0.01) }
        if child.hasExited() { child.finish() }
    }
}
