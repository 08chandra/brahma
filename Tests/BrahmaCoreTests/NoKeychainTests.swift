import Foundation
import Testing
import BrahmaKeychain

/// The login Keychain prompts for a password on every access from a freshly built, ad-hoc-signed binary, so a test
/// run must never touch it. Three layers, none relying on test order:
///  1. `tempDir()` arms `KeychainAccessLog.forbid()`: any Keychain call later in the process crashes the run.
///  2. A process-wide counter of every Security call, asserted to be 0 here (catches calls made before arming).
///  3. A source scan: only `LiveKeychainTests.swift` (disabled unless `BRAHMA_LIVE_KEYCHAIN=1`) may use the Keychain
///     store; CLI subprocess helpers must use the file store.
@Suite struct NoKeychainTests {
    private var live: Bool { ProcessInfo.processInfo.environment["BRAHMA_LIVE_KEYCHAIN"] == "1" }

    @Test func thisTestRunMadeNoSecurityCalls() throws {
        _ = try tempDir()
        try #require(!live, "live Keychain run")
        #expect(keychainTrapArmed)
        #expect(KeychainAccessLog.callCount == 0)
    }

    @Test func onlyTheLiveSuiteUsesTheKeychainStore() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
        let needles = ["KeychainOwnerKeyStore", "PlatformOwnerKeyStore.make", "import Security", "SecItem"]
        let allowed: Set<String> = ["LiveKeychainTests.swift", "NoKeychainTests.swift", "OwnerKeyTests.swift"]
        var offenders: [String] = []
        for case let file as URL in try #require(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil)) {
            guard file.pathExtension == "swift", !allowed.contains(file.lastPathComponent) else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            if needles.contains(where: text.contains) { offenders.append(file.lastPathComponent) }
        }
        #expect(offenders.isEmpty, "tests must use InMemoryOwnerKeyStore or HomeFileOwnerKeyStore: \(offenders)")
        // OwnerKeyTests may only name the type to assert the default selection, never construct it or call Security.
        let ownerTests = try String(contentsOf: tests.appending(path: "BrahmaCoreTests/OwnerKeyTests.swift"), encoding: .utf8)
        #expect(!ownerTests.contains("KeychainOwnerKeyStore()"))
        #expect(!ownerTests.contains("SecItem"))
    }

    @Test func everyCLISubprocessHelperUsesTheFileStore() throws {
        let tests = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        var checked = 0
        for case let file as URL in try #require(FileManager.default.enumerator(at: tests, includingPropertiesForKeys: nil)) {
            guard file.pathExtension == "swift", file.lastPathComponent != "NoKeychainTests.swift" else { continue }
            let text = try String(contentsOf: file, encoding: .utf8)
            guard text.contains("brahmaExecutableURL()") else { continue }
            checked += 1
            // Helpers build the environment with `cliEnvironment` (file store); TestSupport defines it.
            #expect(text.contains("cliEnvironment(home:"),
                    "\(file.lastPathComponent) launches brahma without BRAHMA_OWNER_KEY_STORE=file")
        }
        #expect(checked >= 4)
        let support = try String(contentsOf: tests.appending(path: "TestSupport.swift"), encoding: .utf8)
        #expect(support.contains("\"BRAHMA_OWNER_KEY_STORE\": \"file\""))
    }
}
