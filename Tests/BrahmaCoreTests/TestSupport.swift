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

func tempDir() throws -> URL {
    _ = keychainTrapArmed
    let url = FileManager.default.temporaryDirectory
        .appending(path: "brahma-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

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
