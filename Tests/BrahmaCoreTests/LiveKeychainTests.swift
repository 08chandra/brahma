#if canImport(Security)
import Foundation
import Testing
import Security
@testable import BrahmaCore
import BrahmaKeychain

/// The only test that touches the real login Keychain. A rebuilt binary has a new ad-hoc signature, so macOS asks for
/// the login password on each access (once per call, so there is exactly ONE test here); run it deliberately: `BRAHMA_LIVE_KEYCHAIN=1 swift test --filter LiveKeychain`.
@Suite(.scratch, .enabled(if: ProcessInfo.processInfo.environment["BRAHMA_LIVE_KEYCHAIN"] == "1",
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

/// The secrets vault's one live test (off unless `BRAHMA_LIVE_KEYCHAIN=1`): round trip, then the F1 access-control probe —
/// `/usr/bin/security` is not on the item's trusted-application list, so it must never print the value (a prompt, a denial or
/// the 5 s timeout all count as "not read"). Uses a unique company id and always deletes its item.
@Suite(.scratch, .enabled(if: ProcessInfo.processInfo.environment["BRAHMA_LIVE_KEYCHAIN"] == "1", "set BRAHMA_LIVE_KEYCHAIN=1"))
struct LiveKeychainVaultTests {
    /// Runs `/usr/bin/security find-generic-password -w` as a child with a hard 5 s timeout (then SIGKILL) and returns its
    /// stdout. Output goes to a file, not a pipe, so a stuck child can never block the read.
    private func securityReads(account: String) throws -> String {
        let out = try tempDir().appending(path: "security-out.txt")
        guard FileManager.default.createFile(atPath: out.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CocoaError(.fileWriteUnknown)
        }
        let sink = try FileHandle(forWritingTo: out)
        defer { try? sink.close() }
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", KeychainVault.service, "-a", account, "-w"]
        p.standardOutput = sink; p.standardError = FileHandle.nullDevice; p.standardInput = FileHandle.nullDevice
        let done = DispatchSemaphore(value: 0)
        p.terminationHandler = { _ in done.signal() }
        try p.run()
        if done.wait(timeout: .now() + 5) == .timedOut {
            kill(p.processIdentifier, SIGKILL)
            _ = done.wait(timeout: .now() + 2)
        }
        return String(decoding: try Data(contentsOf: out), as: UTF8.self)
    }

    @Test func roundTripsAndOnlyTrustedBinariesRead() throws {
        let vault = KeychainVault()
        let company = "test-\(UUID().uuidString)"
        let name = "KC_TEST_KEY", account = "\(company):KC_TEST_KEY"
        defer { try? vault.delete(companyId: company, name: name) }
        #expect(try vault.value(companyId: company, name: name) == nil)
        let first = "first-\(UUID().uuidString)"
        try vault.set(companyId: company, name: name, value: first)
        #expect(try vault.value(companyId: company, name: name) == first, "the trusted binary itself reads it")
        #expect(!(try securityReads(account: account)).contains(first), "/usr/bin/security read the secret without being trusted")
        // Replacing the value rebuilds the item with the same restricted list.
        let second = "päss \"wörd\"/\(UUID().uuidString)"
        try vault.set(companyId: company, name: name, value: second)
        #expect(try vault.value(companyId: company, name: name) == second)
        #expect(!(try securityReads(account: account)).contains(second))
        try vault.delete(companyId: company, name: name)
        #expect(try vault.value(companyId: company, name: name) == nil)
        try vault.delete(companyId: company, name: name)
    }
}
#endif
