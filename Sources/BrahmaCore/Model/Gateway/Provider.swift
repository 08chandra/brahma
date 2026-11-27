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

    /// Whether `name` is a provider key name: `ANTHROPIC_API_KEY`, or `BRAHMA_KEY_` followed by upper-case letters, digits and
    /// underscores. Such a name can never be a test key, so no provider key reaches an agent or a check.
    public static func isKeyName(_ name: String) -> Bool {
        if name == anthropicKeyName { return true }
        guard name.hasPrefix(keyNamePrefix) else { return false }
        let rest = name.dropFirst(keyNamePrefix.count)
        return !rest.isEmpty && rest.allSatisfy { ($0 >= "A" && $0 <= "Z") || ($0 >= "0" && $0 <= "9") || $0 == "_" }
    }

    /// A provider id: 1–32 of lower-case letters, digits and `-`, starting with a letter or digit.
    public static func isValidId(_ id: String) -> Bool {
        guard let first = id.first, id.count <= 32, first != "-" else { return false }
        return id.allSatisfy { ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "-" }
    }
}
