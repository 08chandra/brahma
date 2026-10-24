import Foundation
import BrahmaCore
#if canImport(Security)
import Security
#endif

/// The secrets vault for this process, chosen in ONE place. Unset `BRAHMA_SECRET_STORE` means the platform vault (the
/// Keychain on macOS, `UnavailableVault` elsewhere). `file` (`FileVault`, a 0600 file in the data home) and `memory`
/// (`MemoryVault`, this process only) are for temp/demo data homes and are REFUSED for the default data home, so production
/// can never run on them; any other value is refused. Only the `brahma` CLI's production paths and the app call this;
/// library code and tests get a vault passed in (`MemoryVault`, `FileVault`, `UnavailableVault`).
public enum PlatformSecretVault {
    public static let environmentVariable = SecretStore.environmentVariable

    public enum Kind: Equatable, Sendable { case keychain, file, memory, unavailable }

    public struct Refusal: Error, CustomStringConvertible {
        public let description: String
    }

    public struct Selection: Sendable {
        public let vault: any SecretVault
        public let kind: Kind
        /// One line for stderr (and the app's banner) when a non-production store is in use.
        public let warning: String?
        /// Whether the vault may ask the owner (a Keychain prompt). Only explicit owner actions resolve an interactive one:
        /// `brahma secret set|rm|load` and the app's Load secrets. Background reads (the engine, `brahma mcp`, other CLI
        /// commands' lazy load, app boot) never prompt: a read that would is a per-secret failure.
        public var interactive: Bool = false
    }

    public static func resolve(environment: [String: String], paths: BrahmaPaths,
                               defaultHome: URL = BrahmaPaths.from(environment: [:]).home, interactive: Bool = false) throws -> Selection {
        guard let value = environment[environmentVariable] else { return platform(interactive: interactive) }
        guard value == "file" || value == "memory" else {
            throw Refusal(description: "\(environmentVariable)=\(value) is not supported (only 'file' or 'memory', for temp/demo data homes; unset it to use the Keychain)")
        }
        if let reason = PlatformOwnerKeyStore.defaultHomeIdentity(paths: paths, defaultHome: defaultHome) {
            throw Refusal(description: "\(environmentVariable)=\(value) is for temp/demo data homes only; refusing for the default data home \(defaultHome.path) (\(reason))")
        }
        if value == "file" {
            return Selection(vault: FileVault(home: paths.home), kind: .file,
                             warning: "using a file-backed secret store (dev/demo home only)", interactive: interactive)
        }
        return Selection(vault: MemoryVault(), kind: .memory,
                         warning: "using an in-memory secret store (dev/demo home only; values last only as long as this process)",
                         interactive: interactive)
    }

    /// `resolve` against the process environment.
    public static func resolve(paths: BrahmaPaths, interactive: Bool = false) throws -> Selection {
        try resolve(environment: ProcessInfo.processInfo.environment, paths: paths, interactive: interactive)
    }

    /// The refusal the production entry points (the CLI, `brahma mcp`, the app) give for `memory`: its values would vanish
    /// with the process (later processes would be held), and a child `brahma mcp` cannot share it.
    public static func refuseMemory(_ selection: Selection) throws {
        guard selection.kind == .memory else { return }
        throw Refusal(description: "\(environmentVariable)=memory is for in-process tests only; use 'file' for a temp/demo data home")
    }

    private static func platform(interactive: Bool) -> Selection {
        #if canImport(Security)
        return Selection(vault: KeychainVault(interactive: interactive), kind: .keychain, warning: nil, interactive: interactive)
        #else
        return Selection(vault: UnavailableVault(), kind: .unavailable, warning: nil, interactive: interactive)
        #endif
    }
}

/// The applications a secret's Keychain item trusts: ONLY the running Brahma binary (the real path of the current
/// executable: the `brahma` CLI or the Brahma app's executable) and its sibling when it exists, found by the app-bundle
/// conventions `make-app.sh` and `ToolLocator.mcpHelper` use:
/// - the bundled CLI `<X>.app/Contents/Helpers/brahma` trusts `<X>.app/Contents/MacOS/Brahma`;
/// - an app executable `<X>.app/Contents/MacOS/<exe>` trusts `<X>.app/Contents/Helpers/brahma`, else a `brahma` beside it;
/// - a standalone `brahma` trusts `BrahmaApp` beside it, and a standalone `BrahmaApp` trusts `brahma` beside it.
/// Never `/usr/bin/security`, never nil, never an empty list (the vault refuses to write without at least one entry).
public enum KeychainTrust {
    static let neverTrusted: Set<String> = ["/usr/bin/security"]

    /// The real (symlink-free) path of the running executable.
    public static func currentExecutablePath() -> String? {
        #if canImport(Darwin)
        var size: UInt32 = 0
        _ = _NSGetExecutablePath(nil, &size)
        var buffer = [CChar](repeating: 0, count: Int(size) + 1)
        guard _NSGetExecutablePath(&buffer, &size) == 0 else { return nil }
        return realPath(String(cString: buffer))
        #else
        return realPath("/proc/self/exe")
        #endif
    }

    public static func realPath(_ path: String) -> String? {
        guard let resolved = realpath(path, nil) else { return nil }
        defer { free(resolved) }
        return String(cString: resolved)
    }

    /// The trusted list for this process.
    public static func trustedApplicationPaths() -> [String] {
        guard let executable = currentExecutablePath() else { return [] }
        return trustedApplicationPaths(executable: executable)
    }

    /// The trusted list for `executable` (an absolute, already-resolved path): it first, then its sibling if `isExecutable`
    /// finds one. Each entry is resolved to its real path when it exists.
    public static func trustedApplicationPaths(executable: String,
                                               isExecutable: (String) -> Bool = { FileManager.default.isExecutableFile(atPath: $0) },
                                               resolve: (String) -> String = { realPath($0) ?? $0 }) -> [String] {
        guard executable.hasPrefix("/"), !neverTrusted.contains(executable) else { return [] }
        var out: [String] = []
        func add(_ path: String) {
            let real = resolve(path)
            guard real.hasPrefix("/"), !neverTrusted.contains(real), !neverTrusted.contains(path), !out.contains(real) else { return }
            out.append(real)
        }
        add(executable)
        guard !out.isEmpty else { return [] }
        let exe = executable as NSString
        let dir = exe.deletingLastPathComponent as NSString
        let name = exe.lastPathComponent
        let contents = dir.deletingLastPathComponent as NSString
        let inBundle = contents.lastPathComponent == "Contents" && (contents.deletingLastPathComponent as NSString).pathExtension == "app"
        var candidates: [String] = []
        if inBundle && dir.lastPathComponent == "Helpers" && name == "brahma" {
            candidates = [contents.appendingPathComponent("MacOS/Brahma")]
        } else if inBundle && dir.lastPathComponent == "MacOS" {
            candidates = [contents.appendingPathComponent("Helpers/brahma"), dir.appendingPathComponent("brahma")]
        } else if name == "brahma" {
            candidates = [dir.appendingPathComponent("BrahmaApp")]
        } else if name == "BrahmaApp" {
            candidates = [dir.appendingPathComponent("brahma")]
        }
        // Only the first sibling found, exactly as the app's own lookup picks one.
        if let sibling = candidates.first(where: { $0 != executable && isExecutable($0) }) { add(sibling) }
        return out
    }
}

#if canImport(Security)
/// A generic-password Keychain item per secret: service `dev.brahma.secrets`, account `<companyId>:<name>`,
/// `kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly`. Every Security call goes through `sec`, so `KeychainAccessLog`
/// counts it and the tests' trap catches it.
///
/// Access control: each item is created with `SecAccessCreate` and an EXPLICIT trusted-application list
/// (`SecTrustedApplicationCreateFromPath`) holding only the running Brahma binary and its sibling (`KeychainTrust`), so the
/// app, the CLI and the per-turn `brahma mcp` read it without a prompt, and every other program (`/usr/bin/security`, an
/// agent's own tools) gets the system prompt instead of the value. Residual risk (README: "Keychain asks once per app
/// build to allow access"): a trusted entry pins the binary's code identity; an unsigned or ad-hoc-signed binary that is
/// rebuilt or re-signed is a different application, so macOS asks once per item per binary build (and only the binaries
/// on the list of the build that last wrote the item are trusted) until "Always Allow" adds it.
///
/// Reads are NON-interactive unless the vault was made `interactive` (explicit owner actions only): the query carries
/// `kSecUseAuthenticationUIFail` and user interaction is switched off around the read (`SecKeychainSetUserInteractionAllowed`,
/// restored after, under a process-wide lock), so a read that would prompt fails with errSecInteractionNotAllowed, a
/// per-secret failure the redactor retries with backoff. No background read can raise a dialog or block on one.
///
/// Replacing a value deletes the old item and adds a new one with the current trusted list, never an in-place update: that
/// also replaces an item written by older code whose access list trusted any application, and changing an existing
/// item's access list in place needs its change-ACL right, which prompts. A failed add after the delete leaves no value
/// (the redactor then fails closed until it is set again) and says so.
public struct KeychainVault: SecretVault {
    public static let service = "dev.brahma.secrets"

    private let trustedPaths: @Sendable () -> [String]
    public let interactive: Bool

    /// Serializes reads, because the user-interaction switch is process-wide.
    private static let readLock = NSLock()

    public init(interactive: Bool = false) {
        self.interactive = interactive
        trustedPaths = { KeychainTrust.trustedApplicationPaths() }
    }

    /// Background readers (the push dispatcher) hold this: the same items, read without ever prompting.
    public func nonInteractive() -> any SecretVault { interactive ? KeychainVault(interactive: false) : self }

    /// Every Security framework call goes through here so `KeychainAccessLog` sees it.
    private func sec<T>(_ call: String, _ body: () -> T) -> T {
        KeychainAccessLog.record(call)
        return body()
    }

    private func query(_ companyId: String, _ name: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword, kSecAttrService as String: Self.service,
         kSecAttrAccount as String: "\(companyId):\(name)"]
    }

    public func value(companyId: String, name: String) throws -> String? {
        var q = query(companyId, name)
        q[kSecReturnData as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitOne
        if !interactive { q[kSecUseAuthenticationUI as String] = kSecUseAuthenticationUIFail }
        var out: CFTypeRef?
        let status: OSStatus = Self.readLock.withLock {
            guard !interactive else { return sec("SecItemCopyMatching") { SecItemCopyMatching(q as CFDictionary, &out) } }
            var allowed: DarwinBoolean = true
            _ = sec("SecKeychainGetUserInteractionAllowed") { SecKeychainGetUserInteractionAllowed(&allowed) }
            _ = sec("SecKeychainSetUserInteractionAllowed") { SecKeychainSetUserInteractionAllowed(false) }
            defer { _ = sec("SecKeychainSetUserInteractionAllowed") { SecKeychainSetUserInteractionAllowed(allowed.boolValue) } }
            return sec("SecItemCopyMatching") { SecItemCopyMatching(q as CFDictionary, &out) }
        }
        if status == errSecItemNotFound { return nil }
        if status == errSecInteractionNotAllowed || status == errSecAuthFailed { throw SecretError.needsPermission }
        guard status == errSecSuccess, let data = out as? Data else { throw SecretError.vaultFailed("read failed (OSStatus \(status))") }
        return try SecretValue.decode(data)
    }

    public func set(companyId: String, name: String, value: String) throws {
        // The access list first: if it cannot be built, the old item is left alone.
        let access = try makeAccess(label: "Brahma secret \(name)")
        let hadOld = try removeItems(companyId: companyId, name: name)
        var add = query(companyId, name)
        add[kSecValueData as String] = Data(value.utf8)
        add[kSecAttrAccess as String] = access
        add[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let status = sec("SecItemAdd") { SecItemAdd(add as CFDictionary, nil) }
        guard status == errSecSuccess else {
            throw SecretError.vaultFailed("add failed (OSStatus \(status))" + (hadOld ? "; the previous value was removed, set it again" : ""))
        }
    }

    public func delete(companyId: String, name: String) throws {
        _ = try removeItems(companyId: companyId, name: name)
    }

    /// The trusted-application access list for a new item. Throws rather than ever passing nil or an empty list.
    func makeAccess(label: String) throws -> SecAccess {
        let paths = trustedPaths()
        guard !paths.isEmpty else { throw SecretError.vaultFailed("the running executable could not be identified for the access list") }
        var apps: [SecTrustedApplication] = []
        for path in paths {
            var app: SecTrustedApplication?
            let status = sec("SecTrustedApplicationCreateFromPath") { SecTrustedApplicationCreateFromPath(path, &app) }
            guard status == errSecSuccess, let app else {
                throw SecretError.vaultFailed("the access list could not be built for \(path) (OSStatus \(status))")
            }
            apps.append(app)
        }
        var access: SecAccess?
        let status = sec("SecAccessCreate") { SecAccessCreate(label as CFString, apps as CFArray, &access) }
        guard status == errSecSuccess, let access else { throw SecretError.vaultFailed("the access list could not be created (OSStatus \(status))") }
        return access
    }

    /// Deletes every item for the secret. `SecItemDelete` fails with errSecInvalidOwnerEdit for an item the other binary
    /// (app vs CLI) created; the legacy per-item delete does not check the owner. Returns whether there was one.
    private func removeItems(companyId: String, name: String) throws -> Bool {
        var q = query(companyId, name)
        q[kSecReturnRef as String] = true
        q[kSecMatchLimit as String] = kSecMatchLimitAll
        var out: CFTypeRef?
        let status = sec("SecItemCopyMatching") { SecItemCopyMatching(q as CFDictionary, &out) }
        if status == errSecItemNotFound { return false }
        guard status == errSecSuccess, let items = out as? [AnyObject] else { throw SecretError.vaultFailed("lookup failed (OSStatus \(status))") }
        for item in items {
            let s = sec("SecKeychainItemDelete") { SecKeychainItemDelete(item as! SecKeychainItem) }
            guard s == errSecSuccess else { throw SecretError.vaultFailed("delete failed (OSStatus \(s))") }
        }
        return !items.isEmpty
    }
}
#endif
