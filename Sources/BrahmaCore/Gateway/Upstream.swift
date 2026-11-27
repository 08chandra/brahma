import Foundation

/// One request to a provider. `headers` hold the provider key (the adapter's credential header) for as long as the request is
/// in flight: never log, store or echo one.
public struct UpstreamRequest: Sendable {
    public var url: URL
    public var method: String
    /// Names lower-cased.
    public var headers: [String: String]
    public var body: Data

    public init(url: URL, method: String, headers: [String: String], body: Data) {
        self.url = url; self.method = method; self.headers = headers; self.body = body
    }
}

/// A provider's answer: the status and headers at once, the body as it arrives. Dropping or cancelling the body stream stops
/// the transfer.
public struct UpstreamResponse: Sendable {
    public var status: Int
    /// Names lower-cased.
    public var headers: [String: String]
    public var body: AsyncThrowingStream<Data, Error>

    public init(status: Int, headers: [String: String], body: AsyncThrowingStream<Data, Error>) {
        self.status = status; self.headers = headers; self.body = body
    }
}

/// Sends gateway requests to providers.
public protocol UpstreamTransport: Sendable {
    func send(_ r: UpstreamRequest) async throws(GatewayError) -> UpstreamResponse
}

/// The production transport (Plan X1 Task 8, Ruling 22): every request goes through an `EgressProxy` pinned to the request's
/// one host — the gateway-only constructor, called only here — so the gateway reaches exactly the provider hosts it is
/// configured for, at public addresses resolved once, on port 443. The URL must be `https://<host name>/…` with no user info
/// and no port but 443. Redirects are refused (a 3xx reaches the gateway as the answer, never followed); no cookies, no cache.
/// On platforms without `URLSession` proxies it refuses every request (`unavailable`).
public struct EgressUpstreamTransport: UpstreamTransport {
    /// A response that sends nothing for this long fails (URLSession's request timeout is the idle time between packets).
    public static let idleTimeout: TimeInterval = 300
    /// The longest any one response may take in all.
    public static let resourceTimeout: TimeInterval = 3600

    private let proxies = Proxies()

    public init() {}

    /// Stops every proxy this transport started.
    public func stop() { proxies.stopAll() }

    /// The one host a URL may name, or a refusal: `https`, a host name (never an IP literal or `localhost`), port 443 or none,
    /// no user info.
    static func pinnedHost(_ url: URL) throws(GatewayError) -> String {
        guard url.scheme == "https", url.user == nil, url.password == nil, url.port == nil || url.port == 443,
              let host = url.host?.lowercased(), !host.hasPrefix("*."), DomainMatcher.isValidPattern(host), DomainMatcher.isHostName(host)
        else { throw .unavailable("the provider URL must be https://<host name> on port 443") }
        return host
    }

    /// The proxy pinned to `host`, started on first use and kept until `stop`.
    func proxy(for host: String) throws(GatewayError) -> EgressProxy {
        try proxies.proxy(for: host)
    }

    private final class Proxies: @unchecked Sendable {
        private let lock = NSLock()
        private var byHost: [String: EgressProxy] = [:]

        func proxy(for host: String) throws(GatewayError) -> EgressProxy {
            let made: Result<EgressProxy, GatewayError> = lock.withLock {
                if let existing = byHost[host] { return .success(existing) }
                do {
                    let proxy = try EgressProxy(gatewayHost: host)
                    byHost[host] = proxy
                    return .success(proxy)
                } catch {
                    return .failure(.unavailable("the gateway could not start its egress proxy for \(host)"))
                }
            }
            return try made.get()
        }

        func stopAll() {
            let all: [EgressProxy] = lock.withLock {
                defer { byHost = [:] }
                return Array(byHost.values)
            }
            all.forEach { $0.stop() }
        }
    }

    #if canImport(Darwin)
    public func send(_ r: UpstreamRequest) async throws(GatewayError) -> UpstreamResponse {
        let host = try Self.pinnedHost(r.url)
        let proxy = try proxy(for: host)
        try Self.checkCancellation()
        var request = URLRequest(url: r.url)
        request.httpMethod = r.method
        request.httpBody = r.body
        request.httpShouldHandleCookies = false
        for (name, value) in r.headers { request.setValue(value, forHTTPHeaderField: name) }

        let (stream, continuation) = AsyncThrowingStream<Data, Error>.makeStream()
        let delegate = StreamingDelegate(continuation: continuation)
        let session = URLSession(configuration: Self.configuration(proxyPort: proxy.port), delegate: delegate, delegateQueue: nil)
        let task = session.dataTask(with: request)
        // Dropping or cancelling the body stream cancels the transfer.
        continuation.onTermination = { _ in task.cancel() }
        let head: Result<(Int, [String: String]), GatewayError> = await withTaskCancellationHandler {
            await withCheckedContinuation { (c: CheckedContinuation<Result<(Int, [String: String]), GatewayError>, Never>) in
                delegate.onHead(c)
                task.resume()
                // Invalidates once the task ends; the session keeps its delegate until then.
                session.finishTasksAndInvalidate()
            }
        } onCancel: {
            task.cancel()
        }
        let (status, headers) = try head.get()
        return UpstreamResponse(status: status, headers: headers, body: stream)
    }

    private static func checkCancellation() throws(GatewayError) {
        if Task.isCancelled { throw .unavailable("the request was cancelled") }
    }

    /// An ephemeral configuration whose only route out is the pinned proxy on `127.0.0.1:<proxyPort>`.
    static func configuration(proxyPort: UInt16) -> URLSessionConfiguration {
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.urlCredentialStorage = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.timeoutIntervalForRequest = idleTimeout
        config.timeoutIntervalForResource = resourceTimeout
        config.waitsForConnectivity = false
        config.httpMaximumConnectionsPerHost = 16
        config.connectionProxyDictionary = [
            kCFNetworkProxiesHTTPSEnable as String: 1,
            kCFNetworkProxiesHTTPSProxy as String: "127.0.0.1",
            kCFNetworkProxiesHTTPSPort as String: Int(proxyPort),
            kCFNetworkProxiesHTTPEnable as String: 0,
            kCFNetworkProxiesProxyAutoConfigEnable as String: 0,
        ]
        return config
    }

    /// Feeds one data task into the response: the head once, then the body chunks; refuses every redirect.
    private final class StreamingDelegate: NSObject, URLSessionDataDelegate, @unchecked Sendable {
        private let lock = NSLock()
        private let continuation: AsyncThrowingStream<Data, Error>.Continuation
        private var head: CheckedContinuation<Result<(Int, [String: String]), GatewayError>, Never>?
        private var answered = false

        init(continuation: AsyncThrowingStream<Data, Error>.Continuation) { self.continuation = continuation }

        func onHead(_ c: CheckedContinuation<Result<(Int, [String: String]), GatewayError>, Never>) {
            lock.withLock { head = c }
        }

        private func answer(_ result: Result<(Int, [String: String]), GatewayError>) {
            let waiting: CheckedContinuation<Result<(Int, [String: String]), GatewayError>, Never>? = lock.withLock {
                guard !answered else { return nil }
                answered = true
                defer { head = nil }
                return head
            }
            waiting?.resume(returning: result)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive response: URLResponse,
                        completionHandler: @escaping (URLSession.ResponseDisposition) -> Void) {
            guard let http = response as? HTTPURLResponse else {
                answer(.failure(.upstream(status: 502, message: "Brahma: the provider sent no HTTP response")))
                completionHandler(.cancel)
                return
            }
            var headers: [String: String] = [:]
            for (name, value) in http.allHeaderFields {
                if let name = name as? String, let value = value as? String { headers[name.lowercased()] = value }
            }
            answer(.success((http.statusCode, headers)))
            completionHandler(.allow)
        }

        func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
            continuation.yield(data)
        }

        func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: (any Error)?) {
            if let error {
                // Never the error's text (it can name the URL): its code only.
                let code = (error as? URLError).map { " (code \($0.code.rawValue))" } ?? ""
                answer(.failure(.upstream(status: 502, message: "Brahma: the provider could not be reached" + code)))
                continuation.finish(throwing: error)
            } else {
                answer(.failure(.upstream(status: 502, message: "Brahma: the provider sent no response")))
                continuation.finish()
            }
        }
    }
    #else
    public func send(_ r: UpstreamRequest) async throws(GatewayError) -> UpstreamResponse {
        _ = try Self.pinnedHost(r.url)
        throw .unavailable("the gateway upstream is not available on this platform yet")
    }
    #endif
}
