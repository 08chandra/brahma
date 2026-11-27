import Foundation

/// Which adapter serves a provider (`Provider.adapter`). X1 has `anthropic` and `openai-compatible`; X1b adds the rest.
public struct AdapterId: RawRepresentable, Hashable, Codable, Sendable {
    public let rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }

    public static let anthropic = AdapterId(rawValue: "anthropic")
    public static let openAICompatible = AdapterId(rawValue: "openai-compatible")
}

/// Why the gateway did not serve a request, in the shape it answers with (the Anthropic error body). Messages never hold a key:
/// upstream text is redacted with the key's value before it becomes one.
public enum GatewayError: Error, Equatable, Sendable {
    /// The gateway cannot serve the request now (no key, no provider, no transport): HTTP 503. `reason` has no `Brahma:` prefix.
    case unavailable(String)
    /// A policy refusal (Ruling 19: status 400 `invalid_request_error`, message `Brahma: <reason>`), or a cap (Task 9).
    case refused(status: Int, type: String, message: String)
    /// The provider failed or answered with an error (`message` already redacted and prefixed).
    case upstream(status: Int, message: String)

    public var status: Int {
        switch self {
        case .unavailable: 503
        case .refused(let status, _, _), .upstream(let status, _): status
        }
    }

    public var type: String {
        switch self {
        case .unavailable: "api_error"
        case .refused(_, let type, _): type
        case .upstream(let status, _): Self.errorType(status: status)
        }
    }

    public var message: String {
        switch self {
        case .unavailable(let reason): "Brahma: " + reason
        case .refused(_, _, let message), .upstream(_, let message): message
        }
    }

    /// A policy refusal with Ruling 19's status and type.
    static func policy(_ reason: String) -> GatewayError {
        .refused(status: GatewayRefusal.status, type: GatewayRefusal.type, message: "Brahma: " + reason)
    }

    /// The Anthropic error type for an HTTP status.
    static func errorType(status: Int) -> String {
        switch status {
        case 400: "invalid_request_error"
        case 401: "authentication_error"
        case 403: "permission_error"
        case 404: "not_found_error"
        case 413: "request_too_large"
        case 429: "rate_limit_error"
        case 529: "overloaded_error"
        default: "api_error"
        }
    }
}

/// Translates between the gateway's canonical request and one provider's API (Plan X1 Task 8).
///
/// `upstream` receives the provider key as `key` and must put it only into the returned request's credential header: never
/// into the body, the URL, an error, or anything kept. `translate` relays the response to the client through `reply` and
/// returns the usage it read (nil when the provider reported none); it throws only before it has written anything, and every
/// upstream text it relays or throws has passed through `redact` first.
public protocol ProviderAdapter: Sendable {
    var id: AdapterId { get }
    /// Bumped when the adapter's translation changes (the capability probe keys its record by it, Task 13).
    var version: String { get }

    /// The request to send. `rawBody` is the client's body as received (already decoded into `r`); `model` is the upstream
    /// model the grant routed to; `headers` are the client's (credentials already removed by the server).
    func upstream(_ r: CanonicalRequest, rawBody: Data, model: String, endpoint: GatewayEndpoint, headers: [GatewayHeader],
                  provider: Provider, key: String) throws(GatewayError) -> UpstreamRequest

    func translate(status: Int, headers: [String: String], body: AsyncThrowingStream<Data, Error>, streamed: Bool,
                   into reply: GatewayReply, redact: @Sendable (String) -> String) async throws(GatewayError) -> GatewayUsage?
}
