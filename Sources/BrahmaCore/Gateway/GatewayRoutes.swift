import Foundation

/// The two Messages endpoints the gateway serves; everything else is refused.
public enum GatewayEndpoint: String, Sendable, Equatable, Hashable {
    case messages, countTokens
}

/// What the gateway serves (Plan X1 Task 7, pinned): `POST /t/v1/messages` and `POST /t/v1/messages/count_tokens`, with no query
/// or exactly the query `claude` was recorded sending (`beta=true`, inventory (d)). Targets are compared byte for byte against
/// that list — nothing is decoded or normalised — so `..`, `.`, `%2e`, `%2f`, double slashes, fragments, other queries and
/// absolute-form targets can never reach another endpoint.
public enum GatewayRoutes {
    /// The base URL's path (`ANTHROPIC_BASE_URL=http://127.0.0.1:<port>/t/`).
    public static let prefix = "/t/"
    public static let allowed: [String: GatewayEndpoint] = [
        prefix + "v1/messages": .messages,
        prefix + "v1/messages/count_tokens": .countTokens,
    ]
    /// `""` is the target with no `?` at all; a bare `?` is not accepted.
    public static let allowedQueries: [String] = ["", "beta=true"]
    public static let method = "POST"

    /// The endpoint a request line names, or nil when it is not served.
    public static func classify(method: String, target: String) -> GatewayEndpoint? {
        if case .served(let endpoint, _) = route(method: method, target: target) { return endpoint }
        return nil
    }

    enum Route: Equatable {
        case served(GatewayEndpoint, query: String)
        /// Not origin-form, or bytes no origin-form target holds (`#`, space, controls, non-ASCII).
        case malformed
        case notFound
        case methodNotAllowed
    }

    static func route(method: String, target: String) -> Route {
        let bytes = Array(target.utf8)
        guard bytes.first == UInt8(ascii: "/"), bytes.allSatisfy({ (0x21...0x7e).contains($0) && $0 != UInt8(ascii: "#") }) else {
            return .malformed
        }
        let path: String, query: String?
        if let mark = target.firstIndex(of: "?") {
            path = String(target[..<mark]); query = String(target[target.index(after: mark)...])
        } else {
            path = target; query = nil
        }
        guard let endpoint = allowed[path] else { return .notFound }
        if let query, query.isEmpty || !allowedQueries.contains(query) { return .notFound }
        guard method == Self.method else { return .methodNotAllowed }
        return .served(endpoint, query: query ?? "")
    }
}

/// The gateway's request bounds (pinned): request line ≤ 8 KiB, header section ≤ 32 KiB, body ≤ 32 MiB; plus the connection
/// bounds of this task (counted in awake time).
public enum GatewayLimits {
    public static let maxRequestLine = 8 * 1024
    public static let maxHeaderBytes = 32 * 1024
    public static let maxBodyBytes = 32 * 1024 * 1024
    /// Open client connections at once; past it a connection is answered 503 and closed.
    public static let maxConnections = 64
    /// 503 refusals being sent at once (each takes a bounded write and drain); past it a connection is closed unanswered.
    public static let maxBusyRefusals = 16
    /// Requests one engine's gateway has upstream at once (pinned, Ruling 52(f)); past it a request is answered 429
    /// `rate_limit_error` "Brahma: gateway busy" (transient: `claude` backs off and retries).
    public static let maxUpstreamRequests = 32
    /// A fresh connection whose first byte has not arrived after this long is closed (Ruling 42).
    public static let firstByteTimeout: Duration = .seconds(5)
    /// A keep-alive connection with no new request for this long is closed.
    public static let keepAliveIdle: Duration = .seconds(60)
    /// A request head must be complete this long after its first byte (slow-header clients are closed).
    public static let headTimeout: Duration = .seconds(30)
    /// A body read or a response write that makes no progress for this long ends the connection.
    public static let ioStall: Duration = .seconds(30)
    /// The whole body must arrive within `bodyBaseAllowance + contentLength / bodyMinBytesPerSecond`, and never later than
    /// `bodyMaxDuration` after the head (X1-33): `claude` sends the body from memory over loopback at hundreds of MiB/s, so
    /// 1 MiB/s is a floor no legitimate client nears even on a loaded machine, while a trickling client holds an admitted
    /// request for at most 60 s (a 32 MiB body gets 42 s).
    public static let bodyBaseAllowance: Duration = .seconds(10)
    public static let bodyMinBytesPerSecond = 1 << 20
    public static let bodyMaxDuration: Duration = .seconds(60)
}

/// The connection timeouts one server uses: the pinned `GatewayLimits`, or shorter ones in tests.
struct GatewayTiming: Sendable {
    var firstByte: Duration
    var keepAliveIdle: Duration
    var headTimeout: Duration
    var ioStall: Duration
    var bodyBase: Duration
    var bodyBytesPerSecond: Int
    var bodyMax: Duration

    static let pinned = GatewayTiming(
        firstByte: GatewayLimits.firstByteTimeout, keepAliveIdle: GatewayLimits.keepAliveIdle, headTimeout: GatewayLimits.headTimeout,
        ioStall: GatewayLimits.ioStall, bodyBase: GatewayLimits.bodyBaseAllowance, bodyBytesPerSecond: GatewayLimits.bodyMinBytesPerSecond,
        bodyMax: GatewayLimits.bodyMaxDuration)

    /// How long a body of `count` bytes may take in all.
    func bodyAllowance(_ count: Int) -> Duration {
        let proportional = Duration.milliseconds(Int64(count) * 1000 / Int64(max(1, bodyBytesPerSecond)))
        return min(bodyMax, bodyBase + proportional)
    }
}

/// One request header, name lower-cased.
public struct GatewayHeader: Sendable, Equatable {
    public let name: String
    public let value: String
}

/// A request the gateway admitted: a served endpoint, a live turn token (not included: the credential headers are removed before
/// the handler sees the request) and the whole body.
public struct GatewayRequest: Sendable {
    public let endpoint: GatewayEndpoint
    /// `""` or `beta=true`.
    public let query: String
    /// Every header except `x-api-key` and `authorization`, in arrival order.
    public let headers: [GatewayHeader]
    public let body: Data

    /// The first value of a header (name compared case-insensitively).
    public func header(_ name: String) -> String? {
        let name = name.lowercased()
        return headers.first { $0.name == name }?.value
    }
}

/// The Anthropic error body every gateway refusal uses: `{"type":"error","error":{"type":<type>,"message":<message>}}`. The status
/// and type for cap and policy refusals are Ruling 19's (400 `invalid_request_error`: `claude` ends the turn at once instead of
/// retrying a 429 for minutes); messages start with `Brahma: ` and never echo the request.
public enum GatewayRefusal {
    public static let status = 400
    public static let type = "invalid_request_error"

    public static func body(type: String, message: String) -> Data {
        Data(#"{"type":"error","error":{"type":"\#(jsonEscaped(type))","message":"\#(jsonEscaped(message))"}}"#.utf8)
    }

    static func jsonEscaped(_ s: String) -> String {
        var out = ""
        for scalar in s.unicodeScalars {
            switch scalar {
            case "\"": out += "\\\""
            case "\\": out += "\\\\"
            case "\n": out += "\\n"
            case "\r": out += "\\r"
            case "\t": out += "\\t"
            case _ where scalar.value < 0x20 || scalar.value == 0x7f || scalar.value == 0x2028 || scalar.value == 0x2029:
                out += String(format: "\\u%04x", scalar.value)
            default: out.unicodeScalars.append(scalar)
            }
        }
        return out
    }
}

/// A refusal the framing layer sends before any handler runs. Fixed messages only: nothing from the request is echoed.
struct HTTPRefusal: Error, Equatable, Sendable {
    let status: Int
    let type: String
    let message: String

    static let malformed = HTTPRefusal(status: 400, type: "invalid_request_error", message: "Brahma: malformed request")
    static let requestLineTooLong = HTTPRefusal(status: 400, type: "invalid_request_error", message: "Brahma: request line too long")
    static let headersTooLarge = HTTPRefusal(status: 400, type: "invalid_request_error", message: "Brahma: request headers too large")
    static let badHost = HTTPRefusal(status: 400, type: "invalid_request_error", message: "Brahma: the Host header must name 127.0.0.1")
    static let badLength = HTTPRefusal(status: 400, type: "invalid_request_error",
                                       message: "Brahma: exactly one Content-Length is required and Transfer-Encoding is not accepted")
    static let notFound = HTTPRefusal(status: 404, type: "not_found_error", message: "Brahma: only the Messages endpoints are served")
    static let methodNotAllowed = HTTPRefusal(status: 405, type: "invalid_request_error", message: "Brahma: only POST is served")
    static let tooLarge = HTTPRefusal(status: 413, type: "request_too_large", message: "Brahma: request body too large")
    static let unauthorized = HTTPRefusal(status: 401, type: "authentication_error",
                                          message: "Brahma: a valid gateway token for a running turn is required")
    static let busy = HTTPRefusal(status: 503, type: "overloaded_error", message: "Brahma: the gateway is at its connection limit")
    /// A handler that wrote nothing (Ruling 52(e)): a 400, like `GatewayError.unavailable` (Ruling 48) — `claude` retries any
    /// other status for minutes, while a 400 ends the turn at once.
    static let noResponse = HTTPRefusal(status: 400, type: "invalid_request_error", message: "Brahma: no response")
}

/// A parsed request head (request line + header fields), before routing.
struct RequestHead: Equatable {
    let method: String
    let target: String
    /// Names lower-cased, in arrival order.
    let headers: [GatewayHeader]

    func values(_ name: String) -> [String] { headers.filter { $0.name == name }.map(\.value) }
}

/// What a request head says about the body and the connection, once validated.
struct RequestFraming: Equatable {
    let endpoint: GatewayEndpoint
    let query: String
    let contentLength: Int
    /// The one credential presented (`x-api-key`, or `Authorization: Bearer`), nil when there is none or more than one.
    let credential: String?
    let close: Bool
}

/// Strict HTTP/1.1 head parsing. Conservative by design: `claude` sends CRLF lines, single spaces, one Content-Length and no
/// transfer coding (inventory (d)), so anything else is refused rather than interpreted.
enum HTTPHead {
    enum Scan: Equatable {
        /// The head ends at this index (just past CRLF CRLF).
        case complete(end: Int)
        case incomplete
        case refused(HTTPRefusal)
    }

    /// Looks for the end of a head in `buffer`, enforcing the line-ending rules and the size caps as bytes arrive.
    static func scan(_ buffer: [UInt8]) -> Scan {
        let cr = UInt8(ascii: "\r"), lf = UInt8(ascii: "\n")
        var requestLineEnd: Int?
        var i = 0
        while i < buffer.count {
            let b = buffer[i]
            if b == lf {
                // Only CRLF ends a line: a bare LF is refused (never treated as a line break).
                guard i > 0, buffer[i - 1] == cr else { return .refused(.malformed) }
                if let lineEnd = requestLineEnd {
                    if i >= 3, buffer[i - 2] == lf, buffer[i - 3] == cr {
                        // The header section runs from after the request line's CRLF through the final CRLF.
                        guard i + 1 - (lineEnd + 2) <= GatewayLimits.maxHeaderBytes + 2 else { return .refused(.headersTooLarge) }
                        return .complete(end: i + 1)
                    }
                } else {
                    requestLineEnd = i - 1
                    guard i - 1 <= GatewayLimits.maxRequestLine else { return .refused(.requestLineTooLong) }
                }
            } else if b == cr, i + 1 < buffer.count, buffer[i + 1] != lf {
                // A bare CR is refused too.
                return .refused(.malformed)
            }
            i += 1
        }
        if let requestLineEnd {
            if buffer.count - (requestLineEnd + 2) > GatewayLimits.maxHeaderBytes + 2 { return .refused(.headersTooLarge) }
        } else if buffer.count > GatewayLimits.maxRequestLine + 1 {
            return .refused(.requestLineTooLong)
        }
        return .incomplete
    }

    /// Parses a complete head (`bytes` ends with CRLF CRLF, as `scan` found it).
    static func parse(_ bytes: ArraySlice<UInt8>) -> Result<RequestHead, HTTPRefusal> {
        guard bytes.count >= 4 else { return .failure(.malformed) }
        let body = Array(bytes.dropLast(4))
        var lines: [ArraySlice<UInt8>] = []
        var start = 0, i = 0
        while i < body.count {
            if body[i] == UInt8(ascii: "\r") {
                lines.append(body[start..<i])
                i += 2
                start = i
            } else {
                i += 1
            }
        }
        lines.append(body[start..<body.count])
        guard let requestLine = lines.first, let (method, target) = parseRequestLine(requestLine) else { return .failure(.malformed) }
        var headers: [GatewayHeader] = []
        for line in lines.dropFirst() {
            guard let header = parseHeader(line) else { return .failure(.malformed) }
            headers.append(header)
        }
        return .success(RequestHead(method: method, target: target, headers: headers))
    }

    /// `METHOD SP target SP HTTP/1.1`, single spaces, an upper-case method, a printable target.
    static func parseRequestLine(_ line: ArraySlice<UInt8>) -> (String, String)? {
        let parts = line.split(separator: UInt8(ascii: " "), omittingEmptySubsequences: false)
        guard parts.count == 3, (1...16).contains(parts[0].count), !parts[1].isEmpty,
              parts[0].allSatisfy({ (UInt8(ascii: "A")...UInt8(ascii: "Z")).contains($0) }),
              parts[1].allSatisfy({ (0x21...0x7e).contains($0) }),
              Array(parts[2]) == Array("HTTP/1.1".utf8) else { return nil }
        return (String(decoding: parts[0], as: UTF8.self), String(decoding: parts[1], as: UTF8.self))
    }

    /// `name: value` with a token name (no whitespace before the colon, so no obs-fold either) and a value of visible bytes,
    /// spaces and tabs (no controls), valid UTF-8.
    static func parseHeader(_ line: ArraySlice<UInt8>) -> GatewayHeader? {
        guard let colon = line.firstIndex(of: UInt8(ascii: ":")) else { return nil }
        let name = line[line.startIndex..<colon]
        guard !name.isEmpty, name.allSatisfy(isTokenByte) else { return nil }
        var value = line[(colon + 1)...]
        while let f = value.first, f == 0x20 || f == 0x09 { value = value.dropFirst() }
        while let l = value.last, l == 0x20 || l == 0x09 { value = value.dropLast() }
        guard value.allSatisfy({ $0 == 0x09 || (0x20...0x7e).contains($0) || $0 >= 0x80 }),
              let text = String(bytes: value, encoding: .utf8) else { return nil }
        return GatewayHeader(name: String(decoding: name, as: UTF8.self).lowercased(), value: text)
    }

    static func isTokenByte(_ b: UInt8) -> Bool {
        switch b {
        case UInt8(ascii: "a")...UInt8(ascii: "z"), UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "0")...UInt8(ascii: "9"): true
        default: Array("!#$%&'*+-.^_`|~".utf8).contains(b)
        }
    }

    /// Routing, Host, body framing and the credential, in that order; the first failure is the refusal.
    static func frame(_ head: RequestHead) -> Result<RequestFraming, HTTPRefusal> {
        let endpoint: GatewayEndpoint, query: String
        switch GatewayRoutes.route(method: head.method, target: head.target) {
        case .served(let e, let q): endpoint = e; query = q
        case .malformed: return .failure(.malformed)
        case .notFound: return .failure(.notFound)
        case .methodNotAllowed: return .failure(.methodNotAllowed)
        }
        let hosts = head.values("host")
        guard hosts.count == 1, isLoopbackHost(hosts[0]) else { return .failure(.badHost) }
        // One Content-Length, digits only; no Transfer-Encoding of any kind (so no chunked bodies and no CL/TE ambiguity).
        let lengths = head.values("content-length")
        guard head.values("transfer-encoding").isEmpty, lengths.count == 1 else { return .failure(.badLength) }
        let digits = Array(lengths[0].utf8)
        guard (1...10).contains(digits.count), digits.allSatisfy({ (UInt8(ascii: "0")...UInt8(ascii: "9")).contains($0) }),
              let length = Int(lengths[0]) else { return .failure(.badLength) }
        guard length <= GatewayLimits.maxBodyBytes else { return .failure(.tooLarge) }
        let close = head.values("connection").contains { value in
            value.split(separator: ",").contains { $0.trimmingCharacters(in: .whitespaces).lowercased() == "close" }
        }
        return .success(RequestFraming(endpoint: endpoint, query: query, contentLength: length, credential: credential(head), close: close))
    }

    /// The single credential: one `x-api-key`, or one `Authorization: Bearer <token>` (scheme case-insensitive). Two credentials
    /// (even equal ones) or another scheme count as none.
    static func credential(_ head: RequestHead) -> String? {
        let keys = head.values("x-api-key"), auths = head.values("authorization")
        guard keys.count + auths.count == 1 else { return nil }
        if let key = keys.first { return key }
        let parts = auths[0].split(separator: " ", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[0].lowercased() == "bearer", !parts[1].isEmpty else { return nil }
        return String(parts[1])
    }

    /// `127.0.0.1` or `localhost`, with an optional port of 1–5 digits (a DNS-rebinding page sends its own host name).
    static func isLoopbackHost(_ value: String) -> Bool {
        let parts = value.split(separator: ":", omittingEmptySubsequences: false)
        guard (1...2).contains(parts.count), ["127.0.0.1", "localhost"].contains(parts[0].lowercased()) else { return false }
        if parts.count == 2 {
            return (1...5).contains(parts[1].count) && parts[1].allSatisfy { $0.isASCII && $0.isNumber }
        }
        return true
    }

    /// The status line, reason phrase and fixed headers of a response head.
    static func responseHead(status: Int, headers: [(String, String)]) -> [UInt8] {
        var text = "HTTP/1.1 \(status) \(reason(status))\r\n"
        for (name, value) in headers { text += "\(name): \(value)\r\n" }
        text += "\r\n"
        return Array(text.utf8)
    }

    static func reason(_ status: Int) -> String {
        switch status {
        case 200: "OK"
        case 400: "Bad Request"
        case 401: "Unauthorized"
        case 403: "Forbidden"
        case 404: "Not Found"
        case 405: "Method Not Allowed"
        case 413: "Payload Too Large"
        case 429: "Too Many Requests"
        case 500: "Internal Server Error"
        case 502: "Bad Gateway"
        case 503: "Service Unavailable"
        case 504: "Gateway Timeout"
        case 529: "Overloaded"
        default: "Status"
        }
    }
}
