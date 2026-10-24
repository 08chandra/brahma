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
    case notConfigured

    public var description: String {
        switch self {
        case .notHTTPS: "the push server must be an https:// URL"
        case .badServer: "the push server URL is not usable (no user info, query or fragment allowed)"
        case .badTopic: "the topic may use only letters, digits, - and _ (1 to 64 characters)"
        case .missingCredential(let name): "the \(name) is not set for phone alerts"
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

    /// Read like the engine's secret reload: through the vault in the background, never prompting. A vault that cannot
    /// answer is a missing credential for this push (it fails and retries later), not a reason to ask the owner.
    public static func read(_ vault: any SecretVault, _ name: String) -> String? {
        guard let value = try? vault.value(companyId: scope, name: name), !value.isEmpty else { return nil }
        return value
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

    static func formEncode(_ pairs: [(String, String)]) -> Data {
        var allowed = CharacterSet.alphanumerics
        allowed.insert(charactersIn: "-._~")
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

    /// The channel for the owner's settings, with credentials read from the vault without prompting. Nil when phone alerts
    /// are off; throws when they are on but cannot be sent (no topic, an http:// server, a missing credential).
    public static func make(prefs: OwnerPrefs, vault: any SecretVault, transport: any PushTransport = URLSessionPushTransport()) throws -> (any PushChannel)? {
        switch prefs.pushProvider {
        case nil: return nil
        case .ntfy?:
            guard let topic = prefs.pushTopic else { throw PushError.badTopic }
            return try NtfyChannel(server: prefs.pushServer, topic: topic, token: OwnerCredential.read(vault, OwnerCredential.ntfyToken),
                                   transport: transport)
        case .pushover?:
            guard let app = OwnerCredential.read(vault, OwnerCredential.pushoverAppToken) else {
                throw PushError.missingCredential("Pushover app token")
            }
            guard let user = OwnerCredential.read(vault, OwnerCredential.pushoverUserKey) else {
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
