import Testing
import Foundation

func tempDir() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "brahma-test-\(UUID().uuidString)", directoryHint: .isDirectory)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

// MARK: owner key helpers for CLI subprocess tests

import BrahmaCore
import BrahmaKeychain

func brahmaExecutableURL() -> URL { Bundle.module.bundleURL.deletingLastPathComponent().appending(path: "brahma") }

/// The data home the `brahma` test helpers use for a temp dir.
func ownerPaths(_ home: URL) -> BrahmaPaths {
    BrahmaPaths(home: home.appending(path: "home"), workspaces: home.appending(path: "ws"))
}

/// Runs `brahma owner init` under a pseudo-terminal (`script`), the only way to satisfy its TTY check.
/// Returns the exit status.
@discardableResult
func initOwnerKey(home: URL, extraArgs: [String] = []) throws -> Int32 {
    let paths = ownerPaths(home)
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/script")
    p.arguments = ["-q", "/dev/null", brahmaExecutableURL().path, "owner", "init"] + extraArgs
    p.environment = ["BRAHMA_HOME": paths.home.path, "BRAHMA_WORKSPACES": paths.workspaces.path, "PATH": "/usr/bin:/bin"]
    p.standardInput = FileHandle.nullDevice
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    try p.run()
    p.waitUntilExit()
    return p.terminationStatus
}

/// A temp data home whose owner key was created with `brahma owner init`; its Keychain item (account = the home
/// path) is deleted when the test releases it.
final class OwnerTestHome: @unchecked Sendable {
    let url: URL
    init(initOwner: Bool = true) throws {
        url = try tempDir()
        if initOwner { try #require(try initOwnerKey(home: url) == 0, "brahma owner init failed under script") }
    }
    deinit { KeychainOwnerKeyStore().removeHash(for: ownerPaths(url)) }
}
