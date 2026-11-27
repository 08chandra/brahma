import Foundation

/// Plan X1 Task 11: the rules a provider record meets before the gateway may reach it. One rule set, used by
/// `Store.addProvider` (fail closed, Ruling 60), `brahma providers add` and the gateway itself on every request (defence in
/// depth against a row written below the store).
///
/// A remote adapter's base URL pins exactly one host: `https`, a host name (never an IP literal or `localhost`; the top-level
/// label starts with a letter, so `127.1` and `0x7f.1` are not names), no user info, no query or fragment, port 443 or none.
/// The pinned host is the lower-cased URL host, the one the egress transport lets through (`EgressUpstreamTransport`, Ruling
/// 22), which also refuses every redirect. LAN providers are refused in X1; X1b's `local` adapter adds its rules here.
public enum ProviderHost {
    /// Why a provider record is refused, in words for the owner.
    public struct Refusal: Error, Equatable, Sendable, CustomStringConvertible {
        public let reason: String
        public init(_ reason: String) { self.reason = reason }
        public var description: String { reason }
    }

    /// The adapters that reach a provider over the internet: every X1 adapter.
    public static let remoteAdapters: Set<AdapterId> = [.anthropic, .openAICompatible]
    public static let lanRefusal = "LAN providers arrive with local servers in X1b"
    /// The one host the Anthropic key (`Provider.anthropicKeyName`) is ever sent to.
    public static let anthropicHost = "api.anthropic.com"

    /// The host `baseURL` pins for `adapter`, or why the record is refused. Makes no network call.
    public static func validate(baseURL: URL, adapter: AdapterId, lan: Bool) -> Result<String, Refusal> {
        if lan { return .failure(Refusal(lanRefusal)) }
        guard remoteAdapters.contains(adapter) else {
            return .failure(Refusal("no adapter \(adapter.rawValue): X1 has anthropic and openai-compatible"))
        }
        guard baseURL.scheme == "https" else { return .failure(Refusal("a provider's base URL must be https")) }
        guard baseURL.user == nil, baseURL.password == nil else {
            return .failure(Refusal("a provider's base URL must not hold a user name or password"))
        }
        guard baseURL.query == nil, baseURL.fragment == nil else {
            return .failure(Refusal("a provider's base URL must not hold a query or a fragment"))
        }
        guard baseURL.port == nil || baseURL.port == 443 else {
            return .failure(Refusal("a provider's base URL must use port 443 (or none)"))
        }
        guard let host = baseURL.host?.lowercased(), isHostName(host) else {
            return .failure(Refusal("a provider's base URL must name its host, never an IP address or localhost"))
        }
        return .success(host)
    }

    /// A provider key name: `ANTHROPIC_API_KEY` or `^BRAHMA_KEY_[A-Z0-9_]{1,40}$` — `Provider.isKeyName`, the one rule.
    public static func isProviderKeyName(_ n: String) -> Bool { Provider.isKeyName(n) }

    /// A plain host name the egress proxy can pin: the domain pattern rules (no wildcard, no `localhost`, labels of 1–63 of
    /// `a-z0-9-` not starting or ending with `-`, at least two labels, no trailing dot), never an IP literal of any form,
    /// and a top-level label that starts with a letter (no TLD is numeric, while resolvers read `127.1` or `0x7f.1` as
    /// addresses).
    static func isHostName(_ host: String) -> Bool {
        guard !host.hasPrefix("*."), !host.hasSuffix("."), DomainMatcher.isValidPattern(host), DomainMatcher.isHostName(host),
              let tld = host.split(separator: ".").last, let first = tld.unicodeScalars.first else { return false }
        return first >= "a" && first <= "z"
    }
}
