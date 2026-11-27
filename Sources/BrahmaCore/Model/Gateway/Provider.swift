import Foundation

/// A model provider the gateway can reach (`provider`, owner-wide, `"vX1-gateway"`). `keySecret` is the NAME of the vault secret
/// holding the provider key, never a value: `ANTHROPIC_API_KEY` or `BRAHMA_KEY_<PROVIDER>` (`isKeyName`), names no agent or check
/// is ever given. The four built-ins are seeded by the migration and cannot be removed.
public struct Provider: Codable, Equatable, Sendable {
    public var id: String
    /// The adapter id (`anthropic`, `openai-compatible`; the gateway's `AdapterId`).
    public var adapter: String
    public var baseURL: URL
    /// The one host the gateway's upstream may reach for this provider.
    public var host: String
    public var keySecret: String?
    /// A provider on the local network (refused in X1; X1b).
    public var lan: Bool
    public var builtin: Bool
    public var createdAt: Date

    public init(id: String, adapter: String, baseURL: URL, host: String, keySecret: String?, lan: Bool = false,
                builtin: Bool = false, createdAt: Date) {
        self.id = id; self.adapter = adapter; self.baseURL = baseURL; self.host = host; self.keySecret = keySecret
        self.lan = lan; self.builtin = builtin; self.createdAt = createdAt
    }

    /// The Anthropic key's name (spec §8.2.1; `ANTHROPIC_*` is never injectable).
    public static let anthropicKeyName = "ANTHROPIC_API_KEY"
    /// Every other provider's key is `BRAHMA_KEY_<PROVIDER>` (`BRAHMA_*` is never injectable).
    public static let keyNamePrefix = "BRAHMA_KEY_"

    /// Whether `name` is a provider key name: `ANTHROPIC_API_KEY`, or `^BRAHMA_KEY_[A-Z0-9_]{1,40}$` (ASCII). The one rule
    /// (`ProviderHost.isProviderKeyName`, Ruling 60). Such a name is stored engine-held only and can never be a test key
    /// (`Store.validateSecret`), so no provider key reaches an agent or a check.
    public static func isKeyName(_ name: String) -> Bool {
        if name == anthropicKeyName { return true }
        guard name.hasPrefix(keyNamePrefix) else { return false }
        let rest = name.utf8.dropFirst(keyNamePrefix.utf8.count)
        return (1...40).contains(rest.count)
            && rest.allSatisfy { (0x41...0x5A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x5F }
    }

    /// A provider id: `^[a-z][a-z0-9-]{1,31}$` (2–32 of lower-case letters, digits and `-`, starting with a letter).
    public static func isValidId(_ id: String) -> Bool {
        let bytes = Array(id.utf8)
        guard (2...32).contains(bytes.count), (0x61...0x7A).contains(bytes[0]) else { return false }
        return bytes.allSatisfy { (0x61...0x7A).contains($0) || (0x30...0x39).contains($0) || $0 == 0x2D }
    }

    /// Why `id` is refused as a provider id.
    public static let idRule = "a provider id is 2-32 of a-z, 0-9 and -, starting with a letter"
}
