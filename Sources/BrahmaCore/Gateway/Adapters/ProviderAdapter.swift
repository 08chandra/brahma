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
    /// The gateway cannot serve the request now (no key, no provider, no adapter, no transport, cancelled): HTTP 400
    /// `invalid_request_error`, "Brahma: unavailable: <reason>" (Ruling 48: `claude` retries anything but a 400 for minutes,
    /// while a 400 ends the turn at once). `reason` has no prefix.
    case unavailable(String)
    /// A policy refusal (Ruling 19: status 400 `invalid_request_error`, message `Brahma: <reason>`), or a cap (Task 9).
    case refused(status: Int, type: String, message: String)
    /// The provider failed or answered with an error (`message` already redacted and prefixed).
    case upstream(status: Int, message: String)

    public var status: Int {
        switch self {
        case .unavailable: GatewayRefusal.status
        case .refused(let status, _, _), .upstream(let status, _): status
        }
    }

    public var type: String {
        switch self {
        case .unavailable: GatewayRefusal.type
        case .refused(_, let type, _): type
        case .upstream(let status, _): Self.errorType(status: status)
        }
    }

    public var message: String {
        switch self {
        case .unavailable(let reason): "Brahma: unavailable: " + reason
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

/// What a response's usage came to (Ruling X1-37): the usage the adapter read, and whether it is the provider's final word —
/// the terminal usage report of a stream that then ended normally (Anthropic: the last `message_delta` with usage, then
/// `message_stop`; the OpenAI adapter's final usage chunk; Gemini's last `usageMetadata`), or the usage of a whole
/// non-streamed message. Anything else (a client cut, a cancel or STOP, an upstream failure midway, a missing terminal event)
/// is incomplete: the usage seen so far can be far below what the provider bills, so the meter charges at least the
/// reservation for it.
public struct UsageOutcome: Sendable, Equatable {
    public var usage: GatewayUsage?
    public var complete: Bool

    public init(usage: GatewayUsage?, complete: Bool) {
        self.usage = usage; self.complete = complete && usage != nil
    }

    /// Nothing read and nothing final.
    public static let none = UsageOutcome(usage: nil, complete: false)
}

/// Translates between the gateway's canonical request and one provider's API (Plan X1 Task 8).
///
/// `upstream` receives the provider key as `key` and must put it only into the returned request's credential header: never
/// into the body, the URL, an error, or anything kept. `translate` relays the response to the client through `reply` and
/// returns the usage it read and whether it is final (`UsageOutcome`); it throws only before it has written anything, and every
/// upstream text it relays or throws has passed through `redact` first.
public protocol ProviderAdapter: Sendable {
    var id: AdapterId { get }
    /// Bumped when the adapter's translation changes (the capability probe keys its record by it, Task 13).
    var version: String { get }

    /// The request to send. `body` is the policy-checked tree of the client's body (`r` is decoded from it): an adapter
    /// sends a serialization of it (or of its translation), never the bytes received (Ruling X1-35). `model` is the upstream
    /// model the grant routed to; `headers` are the client's (credentials already removed by the server).
    func upstream(_ r: CanonicalRequest, body: StrictJSON, model: String, endpoint: GatewayEndpoint, headers: [GatewayHeader],
                  provider: Provider, key: String) throws(GatewayError) -> UpstreamRequest

    func translate(status: Int, headers: [String: String], body: AsyncThrowingStream<Data, Error>, streamed: Bool,
                   into reply: GatewayReply, redact: @Sendable (String) -> String) async throws(GatewayError) -> UsageOutcome

    /// Whether the provider bills nothing for a response with this error `status` (≥ 400) (Ruling 55). True: the request is
    /// settled at zero. False: it is charged its reservation estimate (overcount fails closed where billing is unknown).
    /// `anthropic`: every status ≥ 400 bills nothing (Anthropic does not bill errored requests; charging would book phantom
    /// spend on every `claude` retry). `openai-compatible` (Task 10): 4xx bills nothing, 5xx charges the estimate
    /// (aggregators may bill partial work).
    func billsNothing(status: Int) -> Bool

    /// The `count_tokens` answer when the gateway gives it itself, or nil when the request goes to the provider. A local
    /// answer sends nothing upstream and costs nothing: the gateway neither reads the key nor reserves anything for it.
    /// `anthropic`: nil (the provider counts). `openai-compatible` (Task 10): `ceil(canonicalBytes / 4)`, Chat Completions
    /// having no count endpoint.
    func countTokensLocally(_ body: StrictJSON) -> Int?

    /// Refuses (throws) a request this adapter cannot send, without sending anything: pure, run by the gateway before it
    /// reads the key or reserves anything (Ruling 58 m3), so the real reason is reported and never masked by a cap refusal.
    /// `upstream` still refuses the same requests (it translates the same tree). `anthropic`: nothing to refuse (the body is
    /// sent as checked). `openai-compatible`: the translation's refusals.
    func validate(_ body: StrictJSON, endpoint: GatewayEndpoint) throws(GatewayError)
}
