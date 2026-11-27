import Foundation

/// The `anthropic` adapter (Plan X1 Task 8): the client already speaks the provider's API, so the body goes through as the
/// policy checked it — the serialization of the checked `StrictJSON` tree, never the bytes received (Ruling X1-35: keys in
/// the order received, numbers exactly as received) — with two fields changed: `model`, replaced by the routed model when the
/// request named an alias, and `metadata.user_id` (a device id: identifying, not needed upstream), removed (Ruling 43). The client's credential is never forwarded: the provider key goes in
/// `x-api-key`, and only the allowlisted headers go with it. The response streams through unchanged while a tap reads the usage.
public struct AnthropicAdapter: ProviderAdapter {
    public let id = AdapterId.anthropic
    public let version = "1"

    /// The API version sent when the client sends none.
    public static let defaultVersion = "2023-06-01"

    /// Client headers forwarded upstream (Ruling 43): what `claude` sends that the provider uses, nothing that names a host, a
    /// connection, a length, an encoding or a credential.
    static let forwardedHeaders: Set<String> = [
        "anthropic-version", "anthropic-beta", "content-type", "accept", "x-app", "user-agent", "x-claude-code-session-id",
    ]
    static let forwardedPrefix = "x-stainless-"
    /// Never forwarded, whatever list a later edit makes (defence in depth; the key is set by the adapter alone).
    static let neverForwarded: Set<String> = [
        "x-api-key", "authorization", "host", "connection", "content-length", "accept-encoding", "transfer-encoding", "cookie",
        "proxy-authorization", "te", "upgrade", "keep-alive", "trailer",
    ]
    static let maxHeaderValue = 512
    /// The largest non-streamed response, or upstream error body, relayed.
    static let maxResponseBytes = 64 << 20
    static let maxErrorBytes = 64 << 10
    /// An SSE event longer than this is relayed without being read by the tap (usage events are a few hundred bytes).
    static let maxEventBytes = 4 << 20

    public init() {}

    // MARK: Requests

    public func upstream(_ r: CanonicalRequest, body: StrictJSON, model: String, endpoint: GatewayEndpoint, headers: [GatewayHeader],
                         provider: Provider, key: String) throws(GatewayError) -> UpstreamRequest {
        guard provider.host == provider.host.lowercased(), !provider.host.hasPrefix("*."), DomainMatcher.isValidPattern(provider.host),
              DomainMatcher.isHostName(provider.host) else {
            throw .unavailable("provider \(provider.id) has no valid host")
        }
        let path = endpoint == .messages ? "/v1/messages" : "/v1/messages/count_tokens"
        guard let url = URL(string: "https://\(provider.host)\(path)"), url.host == provider.host else {
            throw .unavailable("provider \(provider.id) has no valid host")
        }
        return UpstreamRequest(url: url, method: "POST", headers: Self.headers(from: headers, key: key),
                               body: Self.body(body, model: model == r.model ? nil : model).serialized())
    }

    /// The allowlisted client headers whose values are short printable ASCII (`anthropic-beta`: `^[a-z0-9,._-]{1,512}$`), plus
    /// the key, a JSON content type and an API version when the client sent none.
    static func headers(from client: [GatewayHeader], key: String) -> [String: String] {
        var out: [String: String] = [:]
        for h in client {
            let name = h.name.lowercased()
            guard !neverForwarded.contains(name), forwardedHeaders.contains(name) || name.hasPrefix(forwardedPrefix),
                  out[name] == nil, isPrintable(h.value) else { continue }
            if name == "anthropic-beta", !isBetaList(h.value) { continue }
            out[name] = h.value
        }
        if out["content-type"] == nil { out["content-type"] = "application/json" }
        if out["anthropic-version"] == nil { out["anthropic-version"] = defaultVersion }
        out["x-api-key"] = key
        return out
    }

    static func isPrintable(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return (1...maxHeaderValue).contains(bytes.count) && bytes.allSatisfy { (0x20...0x7e).contains($0) }
    }

    static func isBetaList(_ value: String) -> Bool {
        value.utf8.allSatisfy { ($0 >= UInt8(ascii: "a") && $0 <= UInt8(ascii: "z")) || ($0 >= UInt8(ascii: "0") && $0 <= UInt8(ascii: "9"))
            || $0 == UInt8(ascii: ",") || $0 == UInt8(ascii: ".") || $0 == UInt8(ascii: "_") || $0 == UInt8(ascii: "-") }
    }

    /// The tree to send: `model` replaced when `model` is given, `metadata.user_id` removed; everything else as checked.
    static func body(_ tree: StrictJSON, model: String?) -> StrictJSON {
        var out = tree
        if let model { out = out.setting("model", to: .string(model)) }
        if let metadata = out["metadata"], case .object = metadata, metadata["user_id"] != nil {
            out = out.setting("metadata", to: metadata.removing("user_id"))
        }
        return out
    }

    /// Ruling 55: Anthropic bills no errored request.
    public func billsNothing(status: Int) -> Bool { status >= 400 }

    /// The provider counts: `count_tokens` goes upstream.
    public func countTokensLocally(_ body: StrictJSON) -> Int? { nil }

    // MARK: Responses

    public func translate(status: Int, headers: [String: String], body: AsyncThrowingStream<Data, Error>, streamed: Bool,
                          into reply: GatewayReply, redact: @Sendable (String) -> String) async throws(GatewayError) -> UsageOutcome {
        guard (200...299).contains(status) else {
            throw await Self.upstreamError(status: status, body: body, redact: redact)
        }
        if streamed, headers["content-type"]?.lowercased().hasPrefix("text/event-stream") == true {
            return try await relayEvents(body, into: reply, redact: redact)
        }
        let whole = try await Self.collect(body, limit: Self.maxResponseBytes)
        // A whole message's usage is final; a body cut short parses to none (and the meter charges the estimate).
        let outcome = AnthropicUsageTap.outcome(ofMessage: whole)
        // A cancelled task's stream ends early: what was collected may be cut short, so it is never relayed as a 200. Its
        // usage is still returned when the body is a whole message (Ruling 52(a)).
        guard !Task.isCancelled, !reply.isCut else { return outcome }
        guard !whole.isEmpty else { throw .upstream(status: 502, message: "Brahma: the provider sent an empty response") }
        await reply.send(status: status, json: whole)
        return outcome
    }

    /// Relays the event stream as whole events, reading the usage on the way; an upstream failure mid-stream ends the stream
    /// with an `error` event. Stops (returning what it read, incomplete) when the reply is cut or the task is cancelled. The
    /// usage is complete only when the stream ended normally after its terminal usage report (Ruling X1-37).
    private func relayEvents(_ body: AsyncThrowingStream<Data, Error>, into reply: GatewayReply,
                             redact: @Sendable (String) -> String) async throws(GatewayError) -> UsageOutcome {
        var tap = AnthropicUsageTap()
        var pending = Data()
        var started = false
        var iterator = body.makeAsyncIterator()
        while true {
            let chunk: Data?
            do {
                chunk = try await iterator.next()
            } catch {
                guard started else { throw .upstream(status: 502, message: "Brahma: the provider stream failed") }
                if !Task.isCancelled, !reply.isCut {
                    await reply.event(CanonicalStreamEvent.error(type: "api_error", message: "Brahma: the provider stream failed").sse())
                    await reply.endEvents()
                }
                return tap.outcome(endedNormally: false)
            }
            if Task.isCancelled || reply.isCut { return tap.outcome(endedNormally: false) }
            guard let chunk else { break }
            pending.append(chunk)
            var out = Data()
            while let end = Self.eventEnd(in: pending) {
                let event = pending.prefix(upTo: end)
                pending.removeSubrange(pending.startIndex..<end)
                out.append(tap.relay(Data(event), redact: redact))
            }
            if pending.count > Self.maxEventBytes {
                out.append(pending)
                pending.removeAll()
            }
            guard !out.isEmpty else { continue }
            if !started {
                guard await reply.startEvents() else { return tap.outcome(endedNormally: false) }
                started = true
            }
            guard await reply.event(out) else { return tap.outcome(endedNormally: false) }
        }
        if !started {
            guard !pending.isEmpty else { throw .upstream(status: 502, message: "Brahma: the provider sent an empty stream") }
            guard await reply.startEvents() else { return tap.outcome(endedNormally: false) }
        }
        if !pending.isEmpty { await reply.event(tap.relay(pending, redact: redact)) }
        await reply.endEvents()
        // The provider's stream ended normally: its usage is final if its terminal report arrived (whatever the client did
        // with the last bytes, the provider has billed for exactly this).
        return tap.outcome(endedNormally: true)
    }

    /// The index just past the first event's terminating blank line (`\n\n` or `\r\n\r\n`), or nil.
    static func eventEnd(in data: Data) -> Int? {
        let lf = data.range(of: Data("\n\n".utf8)).map(\.upperBound)
        let crlf = data.range(of: Data("\r\n\r\n".utf8)).map(\.upperBound)
        switch (lf, crlf) {
        case (let a?, let b?): return min(a, b)
        case (let a?, nil): return a
        case (nil, let b?): return b
        case (nil, nil): return nil
        }
    }

    static func collect(_ body: AsyncThrowingStream<Data, Error>, limit: Int) async throws(GatewayError) -> Data {
        var out = Data()
        do {
            for try await chunk in body {
                out.append(chunk)
                guard out.count <= limit else { throw GatewayError.upstream(status: 502, message: "Brahma: the provider response is too large") }
            }
        } catch let error as GatewayError {
            throw error
        } catch {
            throw .upstream(status: 502, message: "Brahma: the provider response failed")
        }
        return out
    }

    /// An upstream error as the gateway relays it: the provider's error type and message (redacted, bounded), its status —
    /// except 401 and 403 (the provider refused the engine's key), which become a 400 so `claude` ends the turn at once
    /// instead of retrying for minutes (X1-0).
    static func upstreamError(status: Int, body: AsyncThrowingStream<Data, Error>, redact: @Sendable (String) -> String) async -> GatewayError {
        var raw = Data()
        var iterator = body.makeAsyncIterator()
        while raw.count < maxErrorBytes {
            let chunk: Data?
            do { chunk = try await iterator.next() } catch { break }  // relay what arrived before the failure
            guard let chunk else { break }
            raw.append(chunk.prefix(maxErrorBytes - raw.count))
        }
        var detail = String(decoding: raw, as: UTF8.self)
        if let json = AnthropicUsageTap.object(raw), let error = json["error"] as? [String: Any], let message = error["message"] as? String {
            detail = ((error["type"] as? String).map { $0 + ": " } ?? "") + message
        }
        detail = String(redact(detail).prefix(1000))
        let relayed = status == 401 || status == 403 ? GatewayRefusal.status : ((100...599).contains(status) ? status : 502)
        let shown = detail.isEmpty ? "" : ": " + detail
        return .upstream(status: relayed, message: "Brahma: the provider answered HTTP \(status)\(shown)")
    }
}

/// Reads the usage out of a Messages response: `message_start.message.usage` and the final `message_delta.usage` of a stream,
/// or `usage` of a whole message. Each count is the larger of what the two events report (the delta's counts are cumulative;
/// taking the larger never under-meters), clamped by `GatewayUsage`.
struct AnthropicUsageTap {
    private var counts: [String: Int] = [:]
    private var seen = false
    /// The terminal usage report (`message_delta` with usage) arrived, and then `message_stop`.
    private var finalReport = false
    private var stopped = false

    static let fields = ["input_tokens", "output_tokens", "cache_read_input_tokens", "cache_creation_input_tokens"]

    var usage: GatewayUsage? {
        guard seen else { return nil }
        return GatewayUsage(inputTokens: counts["input_tokens", default: 0], outputTokens: counts["output_tokens", default: 0],
                            cacheReadTokens: counts["cache_read_input_tokens", default: 0],
                            cacheWriteTokens: counts["cache_creation_input_tokens", default: 0])
    }

    /// One whole SSE event, returned as it should be relayed: unchanged, except an `error` event, whose text is redacted.
    mutating func relay(_ event: Data, redact: (String) -> String) -> Data {
        let text = String(decoding: event, as: UTF8.self)
        let data = text.split(omittingEmptySubsequences: false, whereSeparator: { $0 == "\n" || $0 == "\r\n" })
            .filter { $0.hasPrefix("data:") }
            .map { $0.dropFirst(5).drop { $0 == " " } }
            .joined(separator: "\n")
        guard !data.isEmpty else { return event }
        if read(event: data) == "error" { return Data(redact(text).utf8) }
        return event
    }

    /// Reads one event's `data` JSON; returns its `type`.
    @discardableResult
    mutating func read(event json: String) -> String? {
        guard let object = Self.object(Data(json.utf8)), let type = object["type"] as? String else { return nil }
        switch type {
        case "message_start": merge((object["message"] as? [String: Any])?["usage"])
        case "message_delta":
            if object["usage"] is [String: Any] { finalReport = true }
            merge(object["usage"])
        case "message_stop": stopped = finalReport
        default: break
        }
        return type
    }

    /// What the stream's usage came to: complete only when it `endedNormally` after the terminal report and `message_stop`.
    func outcome(endedNormally: Bool) -> UsageOutcome {
        UsageOutcome(usage: usage, complete: endedNormally && finalReport && stopped)
    }

    /// The usage of a whole (non-streamed) message, or nil when it reports none.
    static func usage(ofMessage body: Data) -> GatewayUsage? {
        var tap = AnthropicUsageTap()
        tap.merge(object(body)?["usage"])
        return tap.usage
    }

    /// A whole message's usage is its final word; a body with none (or cut short, so not JSON) is incomplete.
    static func outcome(ofMessage body: Data) -> UsageOutcome {
        let usage = usage(ofMessage: body)
        return UsageOutcome(usage: usage, complete: usage != nil)
    }

    private mutating func merge(_ usage: Any?) {
        guard let usage = usage as? [String: Any] else { return }
        seen = true
        for field in Self.fields {
            guard let n = Self.count(usage[field]) else { continue }
            counts[field] = max(counts[field, default: 0], n)
        }
    }

    /// A token count as an `Int` clamped to the meter's range; nil for anything that is not a number.
    static func count(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, String(cString: number.objCType) != "c" else { return nil }
        let d = number.doubleValue
        guard d.isFinite else { return nil }
        return Int(min(max(d, 0), Double(GatewayUsage.maxTokens)))
    }

    static func object(_ data: Data) -> [String: Any]? {
        do {
            return try JSONSerialization.jsonObject(with: data) as? [String: Any]
        } catch {
            return nil
        }
    }
}
