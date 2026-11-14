import Foundation
import BrahmaKeychain

/// Any Keychain call in this process crashes instead of prompting the owner (see the BrahmaCoreTests twin).
let keychainTrapArmed: Bool = {
    if ProcessInfo.processInfo.environment["BRAHMA_LIVE_KEYCHAIN"] == "1" { return false }
    KeychainAccessLog.forbid()
    return true
}()

/// A directory for this test case under the process root (`TestScratch.swift`), removed when the case ends.
func tempDir() throws -> URL {
    _ = keychainTrapArmed
    return try Scratch.dir()
}
