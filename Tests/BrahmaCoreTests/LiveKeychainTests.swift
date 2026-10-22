import Foundation
import Testing
import Security
@testable import BrahmaCore
import BrahmaKeychain

/// The only tests that touch the real login Keychain. A rebuilt binary has a new ad-hoc signature, so macOS asks for
/// the login password on each access; run these deliberately: `BRAHMA_LIVE_KEYCHAIN=1 swift test --filter LiveKeychain`.
@Suite(.enabled(if: ProcessInfo.processInfo.environment["BRAHMA_LIVE_KEYCHAIN"] == "1",
                "set BRAHMA_LIVE_KEYCHAIN=1 to run tests that use the real login Keychain"))
struct LiveKeychainTests {
    private func paths() throws -> BrahmaPaths {
        let d = try tempDir()
        return BrahmaPaths(home: d.appending(path: "home"), workspaces: d.appending(path: "ws"))
    }

    @Test func keychainWriteIsInPlace() throws {
        let p = try paths(); let store = KeychainOwnerKeyStore()
        defer { store.removeHash(for: p) }
        try store.setHash("h1", for: p)
        try store.setHash("h2", for: p)
        try store.setHash("h3", for: p)
        #expect(store.hash(for: p) == "h3")
        // Exactly one item remains: the write updates rather than deleting and re-adding.
        let q: [String: Any] = [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: KeychainOwnerKeyStore.service,
                                kSecAttrAccount as String: p.canonicalHomePath, kSecMatchLimit as String: kSecMatchLimitAll,
                                kSecReturnAttributes as String: true]
        var out: CFTypeRef?
        #expect(SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess)
        #expect((out as? [Any])?.count == 1)
    }


    @Test func keychainStoreRoundTrip() throws {
        let p = try paths(); let store = KeychainOwnerKeyStore()
        defer { store.removeHash(for: p) }
        #expect(store.hash(for: p) == nil)
        try store.setHash("h1", for: p)
        try store.setHash("h2", for: p)
        #expect(store.hash(for: p) == "h2")
        store.removeHash(for: p)
        #expect(store.hash(for: p) == nil)
    }
}
