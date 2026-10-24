import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// Phone alerts through a push service (Task 7b). Privacy rule (pinned): a payload holds only engine-written text, unless
// the owner chose `titles`, and then only the flattened, redacted ask title cut to 80 characters (see `NoticeDelivery.plan`).

public enum PushProvider: String, Codable, Sendable, CaseIterable { case ntfy, pushover }

/// How much a push says: `counts` is engine text only; `titles` adds each ask's own title (flattened, redacted, 80 characters).
public enum PushDetail: String, Codable, Sendable, CaseIterable { case counts, titles }

public enum PushPriority: String, Sendable { case normal, urgent }

public struct PushResult: Equatable, Sendable {
    public var ok: Bool
    public var status: Int?
    public var error: String?
    public init(ok: Bool, status: Int? = nil, error: String? = nil) { self.ok = ok; self.status = status; self.error = error }
}

public protocol PushChannel: Sendable {
    func send(title: String, body: String, priority: PushPriority, deepLink: String?) async -> (ok: Bool, status: Int?, error: String?)
}

public enum PushError: Error, Equatable, Sendable, CustomStringConvertible {
    case notHTTPS
    case badServer
    case badTopic
    case missingCredential(String)
    /// A credential with a space, a control character (CR, LF, NUL...) or a non-ASCII character: refused when stored and
    /// when used, so it can never split a header. Names the credential, never its value.
    case badCredential(String)
    /// The vault could not answer (a locked Keychain, an unreadable store): this push fails and is retried later.
    case credentialUnavailable(String)
    /// The ntfy token in the vault was stored for another server (or for none): it is never sent to this one.
    case tokenForOtherServer
    case notConfigured

    public var description: String {
        switch self {
        case .notHTTPS: "the push server must be an https:// URL"
        case .badServer: "the push server URL is not usable (no user info, query or fragment allowed)"
        case .badTopic: "the topic may use only letters, digits, - and _ (1 to 64 characters)"
        case .missingCredential(let name): "the \(name) is not set for phone alerts"
        case .badCredential(let name): "the \(name) must be printable ASCII with no spaces or control characters"
        case .credentialUnavailable(let name): "the vault could not read \(name) for phone alerts"
        case .tokenForOtherServer: "the ntfy token was stored for another server; set it again with --token-stdin"
        case .notConfigured: "phone alerts are off"
        }
    }
}

/// The owner-level credentials of the push services. They live in the `SecretVault` under the account `owner:<NAME>`
/// (the vault's company slot is the fixed word `owner`, which no company id can be). They never get a `secret` row, so
/// they are not in any company's secrets, are never injectable into an agent, and are not in the redactor's agent list.
public enum OwnerCredential {
    public static let scope = "owner"
    public static let ntfyToken = "NTFY_TOKEN"
    public static let pushoverAppToken = "PUSHOVER_APP_TOKEN"
    public static let pushoverUserKey = "PUSHOVER_USER_KEY"

    /// The ONE place an owner credential is read from the vault (the engine's dispatcher and `brahma push test` both come
    /// here). Nil when it is not stored; `credentialUnavailable` when the vault cannot answer (the push fails and is retried
    /// later, never "no token"). The engine reads only when a push is due and the channel is not cached (`PushDispatcher`).
    /// Lane-merge item: route this read through the vault's non-interactive flag, so a background read can never prompt.
    public static func readOwnerCredential(_ vault: any SecretVault, _ name: String) throws -> String? {
        let value: String?
        do { value = try vault.value(companyId: scope, name: name) } catch { throw PushError.credentialUnavailable(name) }
        guard let value, !value.isEmpty else { return nil }
        return value
    }

    /// A credential is 1 to 512 printable ASCII characters with no space (`!` to `~`): no CR, LF, NUL or other control.
    public static func valid(_ value: String) -> Bool {
        let bytes = Array(value.utf8)
        return (1...512).contains(bytes.count) && bytes.allSatisfy { (0x21...0x7E).contains($0) }
    }

    /// The vault value of an ntfy token: the server it was stored for, a newline, the token. The newline cannot occur in
    /// either part (servers are validated URLs, tokens are `valid`), and a token is only sent to the server it names.
    static func boundNtfyToken(_ token: String, server: String) throws -> String {
        guard valid(token) else { throw PushError.badCredential("ntfy token") }
        return try PushURL.normalized(server: server) + "\n" + token
    }

    /// The token stored for `server`; `tokenForOtherServer` when it names another server or none (a raw value).
    static func ntfyToken(from stored: String, server: String) throws -> String {
        // By bytes: "\r\n" is one Character, so a Character search could miss the newline.
        let bytes = Array(stored.utf8)
        guard let cut = bytes.firstIndex(of: 0x0A) else { throw PushError.tokenForOtherServer }
        let bound = String(decoding: bytes[..<cut], as: UTF8.self), token = String(decoding: bytes[(cut + 1)...], as: UTF8.self)
        guard bound == (try PushURL.normalized(server: server)) else { throw PushError.tokenForOtherServer }
        return token
    }
}

enum PushURL {
    /// A topic is a path segment: letters, digits, `-` and `_`.
    static func validTopic(_ topic: String) -> Bool {
        let bytes = Array(topic.utf8)
        return (1...64).contains(bytes.count) && bytes.allSatisfy {
            ($0 >= 0x30 && $0 <= 0x39) || ($0 >= 0x41 && $0 <= 0x5A) || ($0 >= 0x61 && $0 <= 0x7A) || $0 == 0x2D || $0 == 0x5F
        }
    }

    /// The server as validated components: `https` only, a host, no user info, query or fragment.
    static func validate(server: String) throws -> URLComponents {
        guard let parts = URLComponents(string: server.trimmingCharacters(in: .whitespaces)) else { throw PushError.badServer }
        guard parts.scheme?.lowercased() == "https" else { throw PushError.notHTTPS }
        guard let host = parts.host, !host.isEmpty, parts.user == nil, parts.password == nil, parts.query == nil,
              parts.fragment == nil else { throw PushError.badServer }
        return parts
    }

    /// A header value: one line, no control characters; non-ASCII text goes out as an RFC 2047 encoded word (ntfy decodes it).
    static func headerValue(_ text: String) -> String {
        let clean = String(String.UnicodeScalarView(text.unicodeScalars.map {
            CharacterSet.controlCharacters.contains($0) || CharacterSet.newlines.contains($0) ? " " : $0
        })).trimmingCharacters(in: .whitespaces)
        if clean.unicodeScalars.allSatisfy({ $0.isASCII }) { return clean }
        return "=?UTF-8?B?\(Data(clean.utf8).base64EncodedString())?="
    }

    /// The server as one comparable string: lower-case scheme and host, the port, the path without a trailing slash.
    static func normalized(server: String) throws -> String {
        let parts = try validate(server: server)
        var path = parts.percentEncodedPath
        while path.hasSuffix("/") { path.removeLast() }
        return "https://" + (parts.host ?? "").lowercased() + (parts.port.map { ":\($0)" } ?? "") + path
    }

    /// `application/x-www-form-urlencoded` over the ASCII unreserved set only (`A-Z a-z 0-9 - . _ ~`); everything else,
    /// non-ASCII letters included, is percent-encoded as UTF-8.
    static let formAllowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")

    static func formEncode(_ pairs: [(String, String)]) -> Data {
        let allowed = formAllowed
        func enc(_ s: String) -> String { s.addingPercentEncoding(withAllowedCharacters: allowed) ?? "" }
        return Data(pairs.map { "\(enc($0.0))=\(enc($0.1))" }.joined(separator: "&").utf8)
    }
}

/// Sends one request. The default refuses redirects, keeps no cookies and no cache, and gives up after 10 s of awake time.
public protocol PushTransport: Sendable {
    func perform(_ request: URLRequest) async -> (status: Int?, error: String?)
}

public struct URLSessionPushTransport: PushTransport {
    public static let timeout: Duration = .seconds(10)

    public init() {}

    /// An ephemeral session: no cookies, no cache, 10 s, and a delegate that refuses every redirect.
    public static func makeSession() -> URLSession {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = 10
        config.timeoutIntervalForResource = 10
        config.waitsForConnectivity = false
        return URLSession(configuration: config, delegate: RefuseRedirects(), delegateQueue: nil)
    }

    final class RefuseRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    public func perform(_ request: URLRequest) async -> (status: Int?, error: String?) {
        let session = Self.makeSession()
        defer { session.finishTasksAndInvalidate() }
        // The session's own timeouts are wall-clock; this race is the awake-time bound.
        return await withTaskGroup(of: (status: Int?, error: String?)?.self) { group in
            group.addTask {
                do {
                    let (_, response) = try await session.data(for: request)
                    guard let http = response as? HTTPURLResponse else { return (nil, "no HTTP response") }
                    return (http.statusCode, nil)
                } catch {
                    // Never the error's text: it names the URL, and the topic is the secret of an ntfy channel.
                    return (nil, "network error" + ((error as? URLError).map { " (code \($0.code.rawValue))" } ?? ""))
                }
            }
            group.addTask {
                try? await AwakeTime.sleep(for: Self.timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            if first == nil, Task.isCancelled { return (nil, "cancelled") }
            return first ?? (nil, "timed out")
        }
    }
}

/// ntfy: `POST <server>/<topic>`, the text as the body, `Title`, `Priority` and `Tags` headers, and `Authorization: Bearer`
/// when the owner set a token (`owner:NTFY_TOKEN`).
public struct NtfyChannel: PushChannel {
    public let server: URLComponents
    public let topic: String
    let token: String?
    let transport: any PushTransport

    public init(server: String, topic: String, token: String?, transport: any PushTransport = URLSessionPushTransport()) throws {
        self.server = try PushURL.validate(server: server)
        guard PushURL.validTopic(topic) else { throw PushError.badTopic }
        if let token, !token.isEmpty, !OwnerCredential.valid(token) { throw PushError.badCredential("ntfy token") }
        self.topic = topic; self.token = token.flatMap { $0.isEmpty ? nil : $0 }; self.transport = transport
    }

    /// The request, built and not sent.
    public func request(title: String, body: String, priority: PushPriority, deepLink: String?) -> URLRequest {
        var parts = server
        let base = parts.path.hasSuffix("/") ? String(parts.path.dropLast()) : parts.path
        parts.path = base + "/" + topic
        var request = URLRequest(url: parts.url!, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        request.httpBody = Data(body.utf8)
        request.setValue(PushURL.headerValue(title), forHTTPHeaderField: "Title")
        request.setValue(priority == .urgent ? "5" : "3", forHTTPHeaderField: "Priority")
        request.setValue(priority == .urgent ? "rotating_light" : "bell", forHTTPHeaderField: "Tags")
        request.setValue("text/plain; charset=utf-8", forHTTPHeaderField: "Content-Type")
        if let deepLink, !deepLink.isEmpty { request.setValue(PushURL.headerValue(deepLink), forHTTPHeaderField: "Click") }
        if let token { request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization") }
        return request
    }

    public func send(title: String, body: String, priority: PushPriority, deepLink: String?) async -> (ok: Bool, status: Int?, error: String?) {
        let r = await transport.perform(request(title: title, body: body, priority: priority, deepLink: deepLink))
        return PushChannels.result(status: r.status, error: r.error)
    }
}

/// Pushover: `POST https://api.pushover.net/1/messages.json`, form-encoded, with the app token and the user key from the vault.
public struct PushoverChannel: PushChannel {
    public static let endpoint = URL(string: "https://api.pushover.net/1/messages.json")!
    let appToken: String
    let userKey: String
    let transport: any PushTransport

    public init(appToken: String, userKey: String, transport: any PushTransport = URLSessionPushTransport()) throws {
        guard !appToken.isEmpty else { throw PushError.missingCredential("Pushover app token") }
        guard !userKey.isEmpty else { throw PushError.missingCredential("Pushover user key") }
        guard OwnerCredential.valid(appToken) else { throw PushError.badCredential("Pushover app token") }
        guard OwnerCredential.valid(userKey) else { throw PushError.badCredential("Pushover user key") }
        self.appToken = appToken; self.userKey = userKey; self.transport = transport
    }

    public func request(title: String, body: String, priority: PushPriority, deepLink: String?) -> URLRequest {
        var request = URLRequest(url: Self.endpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 10)
        request.httpMethod = "POST"
        request.httpShouldHandleCookies = false
        var fields: [(String, String)] = [("token", appToken), ("user", userKey), ("title", String(title.prefix(250))),
                                          ("message", String(body.prefix(1024))), ("priority", priority == .urgent ? "1" : "0")]
        if let deepLink, !deepLink.isEmpty { fields.append(("url", deepLink)) }
        request.httpBody = PushURL.formEncode(fields)
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        return request
    }

    public func send(title: String, body: String, priority: PushPriority, deepLink: String?) async -> (ok: Bool, status: Int?, error: String?) {
        let r = await transport.perform(request(title: title, body: body, priority: priority, deepLink: deepLink))
        return PushChannels.result(status: r.status, error: r.error)
    }
}

public enum PushChannels {
    /// Success is a 2xx and nothing else (a refused redirect is a 3xx, so a failure).
    static func result(status: Int?, error: String?) -> (ok: Bool, status: Int?, error: String?) {
        if let status, (200..<300).contains(status) { return (true, status, nil) }
        return (false, status, error ?? (status.map { "HTTP \($0)" } ?? "failed"))
    }

    /// The channel for the owner's settings, with credentials read through `OwnerCredential.readOwnerCredential`. Nil when
    /// phone alerts are off; throws when they are on but cannot be sent (no topic, an http:// server, a missing or unreadable
    /// credential, an ntfy token stored for another server). Each call reads the vault: the engine caches the result.
    public static func make(prefs: OwnerPrefs, vault: any SecretVault, transport: any PushTransport = URLSessionPushTransport()) throws -> (any PushChannel)? {
        switch prefs.pushProvider {
        case nil: return nil
        case .ntfy?:
            guard let topic = prefs.pushTopic else { throw PushError.badTopic }
            let token = try OwnerCredential.readOwnerCredential(vault, OwnerCredential.ntfyToken).map {
                try OwnerCredential.ntfyToken(from: $0, server: prefs.pushServer)
            }
            return try NtfyChannel(server: prefs.pushServer, topic: topic, token: token, transport: transport)
        case .pushover?:
            guard let app = try OwnerCredential.readOwnerCredential(vault, OwnerCredential.pushoverAppToken) else {
                throw PushError.missingCredential("Pushover app token")
            }
            guard let user = try OwnerCredential.readOwnerCredential(vault, OwnerCredential.pushoverUserKey) else {
                throw PushError.missingCredential("Pushover user key")
            }
            return try PushoverChannel(appToken: app, userKey: user, transport: transport)
        }
    }
}

/// One phone push, already worded under the privacy rule.
public struct PushedNotice: Equatable, Sendable {
    public var title: String
    public var body: String
    public var urgent: Bool
    /// Always nil today: a link to an ask needs a URL scheme the phone can open, and agent text never becomes one.
    public var deepLink: String?
    /// What is marked `pushedAt` once this push got a 2xx.
    public var askIds: [String]
    public var noticeIds: [Int64]
    public var companyId: String?

    public init(title: String, body: String, urgent: Bool, deepLink: String? = nil, askIds: [String] = [], noticeIds: [Int64] = [],
                companyId: String? = nil) {
        self.title = title; self.body = body; self.urgent = urgent; self.deepLink = deepLink
        self.askIds = askIds; self.noticeIds = noticeIds; self.companyId = companyId
    }
}
