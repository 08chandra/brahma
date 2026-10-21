import Foundation
import BrahmaCore
#if canImport(Security)
import Security
#endif

/// The owner-key hash store for this platform: the Keychain on macOS, a 0600 hash file elsewhere.
public enum PlatformOwnerKeyStore {
    public static func make() -> any OwnerKeyStore {
        #if canImport(Security)
        return KeychainOwnerKeyStore()
        #else
        return FileOwnerKeyStore()
        #endif
    }
}

#if canImport(Security)
/// A generic-password Keychain item: service `dev.brahma.owner`, account = the canonical (realpath) data-home path (so test
/// homes never touch the real owner's item). The item is created with an access list that trusts any application,
/// so both the app and the `brahma` CLI read it without a prompt. Until 5-lite, an agent shell can read it too.
public struct KeychainOwnerKeyStore: OwnerKeyStore {
    public static let service = "dev.brahma.owner"

    public init() {}

    private func query(_ paths: BrahmaPaths) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
         kSecAttrAccount as String: paths.canonicalHomePath]
    }

    public func hash(for paths: BrahmaPaths) -> String? {
        var q = query(paths)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    public func setHash(_ hash: String, for paths: BrahmaPaths) throws {
        removeHash(for: paths)
        var access: SecAccess?
        guard SecAccessCreate("Brahma owner key" as CFString, nil, &access) == errSecSuccess, let access else {
            throw OwnerKeyError.cannotWrite("Keychain access list could not be created")
        }
        var q = query(paths)
        q[kSecValueData as String] = Data(hash.utf8)
        q[kSecAttrAccess as String] = access
        let status = SecItemAdd(q as CFDictionary, nil)
        guard status == errSecSuccess else { throw OwnerKeyError.cannotWrite("Keychain add failed (OSStatus \(status))") }
    }

    public func removeHash(for paths: BrahmaPaths) {
        // `SecItemDelete` fails with errSecInvalidOwnerEdit when the item was created by the other binary (app vs
        // CLI); the legacy per-item delete does not check the owner, so either side can replace the hash.
        var q = query(paths)
        q[kSecReturnRef as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        guard SecItemCopyMatching(q as CFDictionary, &out) == errSecSuccess, let items = out as? [AnyObject] else { return }
        for item in items { SecKeychainItemDelete(item as! SecKeychainItem) }
    }
}
#endif
