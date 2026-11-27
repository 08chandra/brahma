import Foundation

/// A directory for this test case under the process root (`TestScratch.swift`), removed when the case ends. The other targets'
/// twins arm the Keychain trap first; this target links only `BrahmaSafety`, which holds no Keychain code
/// (`NoKeychainTests.brahmaCoreHasNoKeychainCode` scans it), so there is nothing to trap.
func tempDir() throws -> URL {
    try Scratch.dir()
}
