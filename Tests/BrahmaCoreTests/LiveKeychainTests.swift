#if canImport(Security)
import Foundation
import Testing
import Security
@testable import BrahmaCore
import BrahmaKeychain

/// The only test that touches the real login Keychain. A rebuilt binary has a new ad-hoc signature, so macOS asks for
/// the login password on each access (once per call, so there is exactly ONE test here); run it deliberately: `BRAHMA_LIVE_KEYCHAIN=1 swift test --filter LiveKeychain`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BRAHMA_LIVE_KEYCHAIN"] == "1",
                "set BRAHMA_LIVE_KEYCHAIN=1 to run tests that use the real login Keychain"))
struct LiveKeychainTests {
    private func paths() throws -> BrahmaPaths {
        let d = try tempDir()
        return BrahmaPaths(home: d.appending(path: "home"), workspaces: d.appending(path: "ws"))
    }

    /// The only test that touches the real login Keychain (one prompt per access, so it does everything in one go):
    /// absent -> add -> in-place updates (exactly one item remains) -> remove.
    @Test func keychainStoreRoundTripWritesInPlace() throws {
        let p = try paths(); let store = KeychainOwnerKeyStore()
        defer { store.removeHash(for: p) }
        #expect(store.hash(for: p) == nil)
        try store.setHash("h1", for: p)
        try store.setHash("h2", for: p)
        try store.setHash("h3", for: p)
        #expect(store.hash(for: p) == "h3")
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: KeychainOwnerKeyStore.service,
                                kSecAttrAccount as String: p.canonicalHomePath, kSecMatchLimit as String: kSecMatchLimitAll,
                                kSecReturnAttributes as String: true]
        var out: CFTypeRef?
        #expect(SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess)
        #expect((out as? [Any])?.count == 1)
        store.removeHash(for: p)
        #expect(store.hash(for: p) == nil)
    }
}

/// Touches the real login Keychain, so it is off unless `BRAHMA_LIVE_KEYCHAIN=1`. Uses a unique company id and removes its item.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BRAHMA_LIVE_KEYCHAIN"] == "1", "set BRAHMA_LIVE_KEYCHAIN=1"))
struct LiveKeychainVaultTests {
    @Test
    func roundTripsUpdatesAndDeletes() throws {
        let vault = KeychainVault()
        let company = "test-\(UUID().uuidString)"
        defer { try? vault.delete(companyId: company, name: "KC_TEST_KEY") }
        #expect(try vault.value(companyId: company, name: "KC_TEST_KEY") == nil)
        try vault.set(companyId: company, name: "KC_TEST_KEY", value: "first-value")
        #expect(try vault.value(companyId: company, name: "KC_TEST_KEY") == "first-value")
        try vault.set(companyId: company, name: "KC_TEST_KEY", value: "päss \"wörd\"/2")
        #expect(try vault.value(companyId: company, name: "KC_TEST_KEY") == "päss \"wörd\"/2")
        try vault.delete(companyId: company, name: "KC_TEST_KEY")
        #expect(try vault.value(companyId: company, name: "KC_TEST_KEY") == nil)
        try vault.delete(companyId: company, name: "KC_TEST_KEY")
    }
}
#endif
