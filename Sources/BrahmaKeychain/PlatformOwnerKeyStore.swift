import Foundation
import BrahmaCore
#if canImport(Security)
import Security
#endif

/// The owner-key hash store for this platform: the Keychain on macOS, a 0600 hash file elsewhere. The environment
/// variable `BRAHMA_OWNER_KEY_STORE=file` selects a 0600 file in the data home instead (dev/demo/test homes only).
public enum PlatformOwnerKeyStore {
    public static let environmentVariable = "BRAHMA_OWNER_KEY_STORE"

    public struct Refusal: Error, CustomStringConvertible {
        public let description: String
    }

    public struct Selection {
        public let store: any OwnerKeyStore
        /// One line for stderr when a non-production store is in use.
        public let warning: String?
    }

    /// Chooses the store for this process. Unset means the platform store. `file` means `HomeFileOwnerKeyStore`, and
    /// is REFUSED when the canonical data home is the default home, so production can never run on it. Any other
    /// value is refused.
    public static func resolve(environment: [String: String], paths: BrahmaPaths,
                               defaultHome: URL = BrahmaPaths.from(environment: [:]).home) throws -> Selection {
        guard let value = environment[environmentVariable] else { return Selection(store: platformStore(), warning: nil) }
        guard value == "file" else {
            throw Refusal(description: "\(environmentVariable)=\(value) is not supported (only 'file'; unset it to use the Keychain)")
        }
        if paths.canonicalHomePath == BrahmaPaths.canonicalPath(defaultHome.path) {
            throw Refusal(description: "\(environmentVariable)=file is for temp/demo data homes only; refusing for the default data home \(defaultHome.path)")
        }
        return Selection(store: HomeFileOwnerKeyStore(),
                         warning: "warning: \(environmentVariable)=file stores the hash in \(paths.home.path)/owner/keyhash, not the Keychain (dev/demo only)")
    }

    /// `resolve` against the process environment.
    public static func resolve(paths: BrahmaPaths) throws -> Selection {
        try resolve(environment: ProcessInfo.processInfo.environment, paths: paths)
    }

    private static func platformStore() -> any OwnerKeyStore {
        #if canImport(Security)
        return KeychainOwnerKeyStore()
        #else
        return FileOwnerKeyStore()
        #endif
    }
}

#if canImport(Security)
/// Process-wide count of every `SecItem*` / `SecKeychain*` / `SecAccess*` call this module makes. Tests use it to
/// prove they never touch the login Keychain (a rebuilt, ad-hoc-signed binary makes macOS ask for the password on
/// every access). `forbid()` arms a trap: any later call crashes loudly instead of prompting.
public enum KeychainAccessLog {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var count = 0
    nonisolated(unsafe) private static var forbidden = false

    public static var callCount: Int { lock.withLock { count } }
    public static func forbid() { lock.withLock { forbidden = true } }

    fileprivate static func record(_ call: String) {
        let trap = lock.withLock { count += 1; return forbidden }
        if trap { fatalError("Keychain access (\(call)) is forbidden in this process; use InMemoryOwnerKeyStore or BRAHMA_OWNER_KEY_STORE=file") }
    }
}

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

    /// Every Security framework call goes through here so `KeychainAccessLog` sees it.
    private func sec<T>(_ call: String, _ body: () -> T) -> T {
        KeychainAccessLog.record(call)
        return body()
    }

    public func hash(for paths: BrahmaPaths) -> String? {
        var q = query(paths)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        var out: CFTypeRef?
        guard sec("SecItemCopyMatching", { SecItemCopyMatching(q as CFDictionary, &out) }) == errSecSuccess,
              let data = out as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// Never destructive: an existing item is updated in place, so a failure leaves the old hash exactly as it was.
    /// (Deleting first and re-adding would lose the old hash whenever the add failed.)
    public func setHash(_ hash: String, for paths: BrahmaPaths) throws {
        let data = Data(hash.utf8)
        let found = sec("SecItemCopyMatching") { SecItemCopyMatching(query(paths) as CFDictionary, nil) }
        if found == errSecSuccess {
            let updated = sec("SecItemUpdate") {
                SecItemUpdate(query(paths) as CFDictionary, [kSecValueData as String: data] as CFDictionary)
            }
            if updated == errSecSuccess { return }
            // The item was created by the other binary (app vs CLI) and the modern update refuses the owner edit;
            // the legacy modify does not check the owner and also changes the data in place.
            var q = query(paths)
            q[kSecReturnRef as String] = true
            q[kSecMatchLimit as String] = kSecMatchLimitOne
            var ref: CFTypeRef?
            guard sec("SecItemCopyMatching", { SecItemCopyMatching(q as CFDictionary, &ref) }) == errSecSuccess, let ref else {
                throw OwnerKeyError.cannotWrite("Keychain item could not be read for update")
            }
            let status = sec("SecKeychainItemModifyAttributesAndData") {
                data.withUnsafeBytes { raw in
                    SecKeychainItemModifyAttributesAndData(ref as! SecKeychainItem, nil, UInt32(data.count), raw.baseAddress)
                }
            }
            guard status == errSecSuccess else { throw OwnerKeyError.cannotWrite("Keychain update failed (OSStatus \(status))") }
            return
        }
        var access: SecAccess?
        guard sec("SecAccessCreate", { SecAccessCreate("Brahma owner key" as CFString, nil, &access) }) == errSecSuccess, let access else {
            throw OwnerKeyError.cannotWrite("Keychain access list could not be created")
        }
        var q = query(paths)
        q[kSecValueData as String] = Data(hash.utf8)
        q[kSecAttrAccess as String] = access
        let status = sec("SecItemAdd") { SecItemAdd(q as CFDictionary, nil) }
        guard status == errSecSuccess else { throw OwnerKeyError.cannotWrite("Keychain add failed (OSStatus \(status))") }
    }

    public func removeHash(for paths: BrahmaPaths) {
        // `SecItemDelete` fails with errSecInvalidOwnerEdit when the item was created by the other binary (app vs
        // CLI); the legacy per-item delete does not check the owner, so either side can replace the hash.
        var q = query(paths)
        q[kSecReturnRef as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        guard sec("SecItemCopyMatching", { SecItemCopyMatching(q as CFDictionary, &out) }) == errSecSuccess,
              let items = out as? [AnyObject] else { return }
        for item in items { _ = sec("SecKeychainItemDelete") { SecKeychainItemDelete(item as! SecKeychainItem) } }
    }
}
#endif
