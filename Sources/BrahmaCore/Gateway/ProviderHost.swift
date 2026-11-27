import Foundation

/// Plan X1 Task 11: the rules a provider record meets before the gateway may reach it. One rule set, used by
/// `Store.addProvider` (fail closed, Ruling 60), `brahma providers add` and the gateway itself on every request before any key
/// is read (Ruling X1-38: a row written below the store never sends a key anywhere).
///
/// A remote adapter's base URL pins exactly one host: `https`; a host name, never an IP literal, never percent-encoded, never
/// a private or local name (`localhost`, `.local`, `.internal`, `.home.arpa`, `.lan`, …, single labels; the top-level label
/// starts with a letter, so `127.1` and `0x7f.1` are not names); no user info, query or fragment; port 443 spelled exactly
/// so, or none. The pinned host is the lower-cased URL host, the one the egress transport lets through
/// (`EgressUpstreamTransport`, Ruling 22), which also refuses every redirect. LAN providers are refused in X1; X1b's `local`
/// adapter adds its rules here.
///
/// **Key-to-host binding** (Ruling X1-38): the key named by `keySecret` must be a provider key name (`Provider.isKeyName`)
/// and may only go where it belongs:
/// - `ANTHROPIC_API_KEY` only to `api.anthropic.com`, only through the `anthropic` adapter;
/// - a built-in provider's key (`keyDomains`: `BRAHMA_KEY_OPENAI`, `BRAHMA_KEY_OPENROUTER`, `BRAHMA_KEY_GROQ`) only to its
///   provider's domain or a subdomain of it (an owner's `eu.openrouter.ai` may use the OpenRouter key; nothing else may);
/// - any other `BRAHMA_KEY_<X>` is the owner's own key for the provider record that names it, and may serve any host the
///   rules above allow (the owner chose that pairing in the owner shell, and the gateway re-checks it per request).
/// No key at all binds nothing (the gateway then refuses the provider for want of a key).
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
    /// The built-in providers' `BRAHMA_KEY_*` names and the one domain (with its subdomains) each may be sent to.
    public static let keyDomains: [String: String] = [
        "BRAHMA_KEY_OPENAI": "openai.com", "BRAHMA_KEY_OPENROUTER": "openrouter.ai", "BRAHMA_KEY_GROQ": "groq.com",
    ]
    /// Names that only resolve on a private network or this machine, or never resolve publicly (RFC 2606/6761/6762/8375, the
    /// infrastructure `.arpa` zone and common private zones).
    static let privateSuffixes = ["localhost", "local", "internal", "home.arpa", "lan", "intranet", "corp", "localdomain",
                                  "home", "test", "example", "invalid", "mail", "arpa"]

    /// The host `baseURL` pins for `adapter`, or why the record is refused; `keySecret` must be bound to that host. Makes no
    /// network call.
    public static func validate(baseURL: URL, adapter: AdapterId, lan: Bool, keySecret: String?) -> Result<String, Refusal> {
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
        guard baseURL.port == nil || baseURL.port == 443, hasPlainPort(baseURL) else {
            return .failure(Refusal("a provider's base URL must use port 443 (or none)"))
        }
        guard baseURL.host(percentEncoded: true) == baseURL.host(percentEncoded: false) else {
            return .failure(Refusal("a provider's base URL must not percent-encode its host"))
        }
        guard let host = baseURL.host(percentEncoded: false)?.lowercased(), isHostName(host) else {
            return .failure(Refusal("a provider's base URL must name its host, never an IP address or localhost"))
        }
        if let keySecret, let refusal = bindingRefusal(keySecret: keySecret, host: host, adapter: adapter) {
            return .failure(Refusal(refusal))
        }
        return .success(host)
    }

    /// Why `keySecret` may not be sent to `host` through `adapter` (the key-to-host binding above), or nil.
    public static func bindingRefusal(keySecret: String, host: String, adapter: AdapterId) -> String? {
        guard Provider.isKeyName(keySecret) else {
            return "a provider key is named \(Provider.anthropicKeyName) or \(Provider.keyNamePrefix)<PROVIDER>"
        }
        if keySecret == Provider.anthropicKeyName {
            guard host == anthropicHost, adapter == .anthropic else {
                return "\(Provider.anthropicKeyName) is sent only to \(anthropicHost) through the anthropic adapter"
            }
        } else if let domain = keyDomains[keySecret], host != domain, !host.hasSuffix("." + domain) {
            return "\(keySecret) is sent only to \(domain) and its subdomains"
        }
        return nil
    }

    /// A provider key name: `ANTHROPIC_API_KEY` or `^BRAHMA_KEY_[A-Z0-9_]{1,40}$` — `Provider.isKeyName`, the one rule.
    public static func isProviderKeyName(_ n: String) -> Bool { Provider.isKeyName(n) }

    /// The port as written in the URL's authority is absent or exactly `443`: `:00443`, `:0443` and an empty `:` (which
    /// parse as 443 or as no port) are refused.
    static func hasPlainPort(_ url: URL) -> Bool {
        guard let authority = authority(of: url) else { return false }
        // A bracketed IPv6 literal is refused by the host rule; its colons are not a port.
        let hostAndPort = authority.hasPrefix("[") ? String(authority.drop(while: { $0 != "]" }).dropFirst()) : authority
        guard let colon = hostAndPort.lastIndex(of: ":") else { return true }
        return hostAndPort[hostAndPort.index(after: colon)...] == "443"
    }

    /// The raw authority text of an `https://` URL (between `//` and the first `/`, `?` or `#`), as written.
    static func authority(of url: URL) -> String? {
        let text = url.absoluteString
        guard let start = text.range(of: "://")?.upperBound else { return nil }
        let rest = text[start...]
        return String(rest.prefix { $0 != "/" && $0 != "?" && $0 != "#" })
    }

    /// A plain public host name the egress proxy can pin: the domain pattern rules (no wildcard, labels of 1–63 of `a-z0-9-`
    /// not starting or ending with `-`, at least two labels, no trailing dot), never an IP literal of any form, no private or
    /// local suffix, and a top-level label that starts with a letter (no TLD is numeric, while resolvers read `127.1` or
    /// `0x7f.1` as addresses).
    static func isHostName(_ host: String) -> Bool {
        guard !host.hasPrefix("*."), !host.hasSuffix("."), DomainMatcher.isValidPattern(host), DomainMatcher.isHostName(host),
              !privateSuffixes.contains(where: { host == $0 || host.hasSuffix("." + $0) }),
              let tld = host.split(separator: ".").last, let first = tld.unicodeScalars.first else { return false }
        return first >= "a" && first <= "z"
    }
}
