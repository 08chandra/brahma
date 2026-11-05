import Foundation

/// The smoke check of a deployed site (Plan L Task 7): the hosting's smoke requests against the adapter's smoke base, in
/// rounds until every request passes in the same round or `attempts` rounds have run, `interval` apart (CDN propagation).
///
/// - No requests means `GET /` (as the deploy proposal says).
/// - A request passes when its status is its `expectStatus`, or any 2xx when it has none. A redirect is never followed
///   (`HTTPProbing` answers the 3xx itself), so `GET / ` answered 301 fails unless it expects 301.
/// - `expectText`, when set, must be in the first 64 KB of the body of the `/` request (a `GET /` is added for it when the
///   list has no `/` request, so the text is never silently unchecked).
/// - Every URL is the base with the request's path appended, and must stay on the base's host.
/// - Cancellation (the owner's stop, the engine's shutdown) ends it at once: no further request or wait, and not `ok`.
/// The results are the last round's. Response bodies and errors are agent-controlled text (`SmokeResult`).
public enum DeploySmoke {
    public static let attempts = 6
    public static let interval: Duration = .seconds(10)
    /// Each request's own timeout (`SmokeRequest`'s pinned 10 s).
    public static let requestTimeout: Duration = .seconds(10)
    /// How much of a body `expectText` is looked for in.
    public static let textWindow = 65_536

    public static func run(base: URL, requests: [SmokeRequest], expectText: String?, http: any HTTPProbing,
                           sleep: @Sendable (Duration) async -> Void) async -> (ok: Bool, results: [SmokeResult]) {
        var list = requests.isEmpty ? [SmokeRequest(method: "GET", path: "/")] : requests
        if let text = expectText, !text.isEmpty, !list.contains(where: { $0.path == "/" }) {
            list.insert(SmokeRequest(method: "GET", path: "/"), at: 0)
        }
        var results: [SmokeResult] = []
        for attempt in 1...attempts {
            // Cancelled (the owner's stop, the engine's shutdown: `ReleaseExecutor.stoppable`): no further request or wait.
            if Task.isCancelled { break }
            results = []
            for request in list {
                if Task.isCancelled { break }
                results.append(await probe(base: base, request: request, expectText: request.path == "/" ? expectText : nil, http: http))
            }
            if !Task.isCancelled, results.count == list.count, results.allSatisfy(\.ok) { return (true, results) }
            if attempt < attempts, !Task.isCancelled { await sleep(interval) }
        }
        return (false, results)
    }

    /// One request, once.
    public static func probe(base: URL, request: SmokeRequest, expectText: String?, http: any HTTPProbing) async -> SmokeResult {
        guard let url = url(base: base, path: request.path) else {
            return SmokeResult(url: base.absoluteString + request.path, method: request.method, status: nil, millis: 0, bodyPrefix: "",
                               ok: false, error: "the smoke path does not stay on \(base.host ?? "the site")")
        }
        let started = AwakeTime.now
        let answer = await http.send(method: request.method, url: url, body: request.body.map { Data($0.utf8) }, timeout: requestTimeout)
        let elapsed = started.duration(to: AwakeTime.now)
        let millis = Int(elapsed.components.seconds) * 1000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        let body = String(decoding: answer.body.prefix(textWindow), as: UTF8.self)
        var error = answer.error
        var ok = false
        if let status = answer.status, error == nil {
            if let expected = request.expectStatus { ok = status == expected } else { ok = (200...299).contains(status) }
            if !ok { error = request.expectStatus.map { "expected \($0), got \(status)" } ?? "expected a 2xx status, got \(status)" }
            if ok, let text = expectText, !text.isEmpty, !body.contains(text) {
                ok = false
                error = "the page does not contain the expected text"
            }
        } else if error == nil {
            error = "no response"
        }
        return SmokeResult(url: url.absoluteString, method: request.method, status: answer.status, millis: millis,
                           bodyPrefix: String(body.prefix(SmokeRequest.bodyKept)), ok: ok, error: error)
    }

    /// `base` with `path` appended (a trailing `/` of the base is dropped first), only when the result keeps the base's
    /// scheme, host and port.
    static func url(base: URL, path: String) -> URL? {
        guard SmokeRequest.isSmokePath(path) else { return nil }
        var prefix = base.absoluteString
        while prefix.hasSuffix("/") { prefix.removeLast() }
        guard let url = URL(string: prefix + path), url.scheme == base.scheme, url.host == base.host, url.port == base.port,
              url.user == nil, url.password == nil else { return nil }
        return url
    }
}
