import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import BrahmaCore

// MARK: - Test plumbing shared by the gateway suites (socketpair peers, a recording handler, a manual awake clock)

/// Runs blocking socket code on a thread of its own: never on the cooperative pool, and not on the shared GCD pool either,
/// which a loaded full suite can starve for minutes (Ruling 44).
func offload<T: Sendable>(_ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { c in
        Thread.detachNewThread { c.resume(returning: body()) }  // scope-escape: blocking client socket I/O, no scratch dirs
    }
}

/// How long a test waits in real time for something the server will do. Generous (Ruling 44): a loaded full suite has been
/// seen to stall test threads for minutes, and these bounds only end a test that would otherwise hang — they never decide a
/// pass. Every server deadline itself runs on a manual clock the test advances.
let testPatience = 300

enum TestPeerError: Error, Equatable { case timeout, eof, malformed(String) }

struct TestHead: Sendable {
    var status: Int
    var headers: [String: String]
    var raw: String
}

struct TestResponse: Sendable {
    var head: TestHead
    var body: [UInt8]
    var status: Int { head.status }
    var text: String { String(decoding: body, as: UTF8.self) }
    var json: [String: Any]? { (try? JSONSerialization.jsonObject(with: Data(body))) as? [String: Any] }
    /// `error.type` of an Anthropic error body.
    var errorType: String? { (json?["error"] as? [String: Any])?["type"] as? String }
}

/// The client end of a socketpair (or a TCP connection), with awake-time deadlines on every blocking step.
final class TestPeer: @unchecked Sendable {
    let fd: Int32
    private let lock = NSLock()
    private var buffer: [UInt8] = []
    private var closed = false

    init(fd: Int32) {
        self.fd = fd
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        _ = fcntl(fd, F_SETFL, fcntl(fd, F_GETFL) | O_NONBLOCK)
    }

    deinit { close() }

    func close() {
        let fd: Int32? = lock.withLock { if closed { return nil }; closed = true; return self.fd }
        if let fd { _ = Darwin_close(fd) }
    }

    /// Writes everything (or stops at the first hard error, e.g. the server closed). Returns the bytes written.
    @discardableResult
    func write(_ s: String) async -> Int { await write(Array(s.utf8)) }

    @discardableResult
    func write(_ bytes: [UInt8]) async -> Int {
        let fd = self.fd
        return await offload {
            var offset = 0
            let deadline = AwakeTime.deadline(after: .seconds(testPatience))
            while offset < bytes.count, AwakeTime.now < deadline {
                let n = bytes[offset...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, peerSendFlags) }
                if n > 0 { offset += n; continue }
                if n < 0 && errno != EAGAIN && errno != EINTR { break }
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                _ = poll(&pfd, 1, 50)
            }
            return offset
        }
    }

    /// Writes what fits without blocking (stops at the first EAGAIN). Returns the bytes written.
    func writeAvailable(_ bytes: [UInt8]) -> Int {
        var offset = 0
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, peerSendFlags) }
            if n <= 0 { break }
            offset += n
        }
        return offset
    }

    /// Reads into the buffer until `ready` returns a value, EOF, or the deadline.
    private func fill<T>(within seconds: Int, _ ready: ([UInt8]) -> T?) throws(TestPeerError) -> T {
        let deadline = AwakeTime.deadline(after: .seconds(seconds))
        while true {
            if let found = lock.withLock({ ready(buffer) }) { return found }
            guard AwakeTime.now < deadline else { throw .timeout }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 50) > 0 else { continue }
            var chunk = [UInt8](repeating: 0, count: 64 * 1024)
            let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress, $0.count, 0) }
            if n == 0 { throw .eof }
            if n < 0 { if errno == EAGAIN || errno == EINTR { continue }; throw .eof }
            lock.withLock { buffer.append(contentsOf: chunk[0..<n]) }
        }
    }

    private func take(_ count: Int) -> [UInt8] {
        lock.withLock { let out = Array(buffer.prefix(count)); buffer.removeFirst(min(count, buffer.count)); return out }
    }

    /// Runs a blocking read off the cooperative pool.
    private func run<T: Sendable>(_ body: @escaping @Sendable () throws(TestPeerError) -> T) async throws -> T {
        try await offload { Result(catching: body) }.get()
    }

    private func headSync(within seconds: Int) throws(TestPeerError) -> TestHead {
        let end = try fill(within: seconds) { b in b.firstRange(of: Array("\r\n\r\n".utf8)).map(\.upperBound) }
        let raw = String(decoding: take(end), as: UTF8.self)
        let lines = raw.components(separatedBy: "\r\n").filter { !$0.isEmpty }
        let parts = lines.first?.split(separator: " ", maxSplits: 2) ?? []
        guard parts.count >= 2, parts[0] == "HTTP/1.1", let status = Int(parts[1]) else { throw .malformed(raw) }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { throw .malformed(raw) }
            headers[line[..<colon].lowercased()] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        return TestHead(status: status, headers: headers, raw: raw)
    }

    private func chunkSync(within seconds: Int) throws(TestPeerError) -> [UInt8] {
        let lineEnd = try fill(within: seconds) { b in b.firstRange(of: Array("\r\n".utf8)).map(\.upperBound) }
        let sizeLine = String(decoding: take(lineEnd), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        guard let size = Int(sizeLine, radix: 16) else { throw .malformed("chunk size \(sizeLine)") }
        _ = try fill(within: seconds) { $0.count >= size + 2 ? true : nil }
        let data = take(size)
        guard take(2) == Array("\r\n".utf8) else { throw .malformed("chunk end") }
        return data
    }

    func readHead(within seconds: Int = testPatience) async throws -> TestHead {
        try await run { [self] () throws(TestPeerError) in try headSync(within: seconds) }
    }

    func readBytes(_ count: Int, within seconds: Int = testPatience) async throws -> [UInt8] {
        try await run { [self] () throws(TestPeerError) in
            _ = try fill(within: seconds) { $0.count >= count ? true : nil }
            return take(count)
        }
    }

    /// One chunk of a chunked body (empty for the terminating chunk, whose trailer is consumed too).
    func readChunk(within seconds: Int = testPatience) async throws -> [UInt8] {
        try await run { [self] () throws(TestPeerError) in try chunkSync(within: seconds) }
    }

    /// A whole response: Content-Length bodies are read in full; chunked bodies are read to the terminator and joined.
    func readResponse(within seconds: Int = testPatience) async throws -> TestResponse {
        let head = try await readHead(within: seconds)
        if head.headers["transfer-encoding"] == "chunked" {
            var body: [UInt8] = []
            while true {
                let chunk = try await readChunk(within: seconds)
                if chunk.isEmpty { break }
                body += chunk
            }
            return TestResponse(head: head, body: body)
        }
        let length = Int(head.headers["content-length"] ?? "0") ?? 0
        return TestResponse(head: head, body: try await readBytes(length, within: seconds))
    }

    /// Whether the server closed its end (EOF) within `seconds`, discarding any bytes before it.
    func seesEOF(within seconds: Int = testPatience) async -> Bool {
        await offload { [self] in
            let r = Result { () throws(TestPeerError) in try fill(within: seconds) { _ -> Bool? in nil } }
            if case .failure(.eof) = r { return true }
            return false
        }
    }

    /// Nothing more arrives for `milliseconds` (and the connection is still open).
    func staysQuiet(milliseconds: Int) async -> Bool {
        await offload { [self] in
            if lock.withLock({ !buffer.isEmpty }) { return false }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            return poll(&pfd, 1, Int32(milliseconds)) == 0
        }
    }
}

#if canImport(Darwin)
let peerSendFlags: Int32 = 0
func Darwin_close(_ fd: Int32) -> Int32 { Darwin.close(fd) }
#else
let peerSendFlags = Int32(MSG_NOSIGNAL)
func Darwin_close(_ fd: Int32) -> Int32 { Glibc.close(fd) }
#endif

/// An awake clock the test advances by hand; sleepers wake when it passes their deadline (or throw when cancelled).
final class ManualAwakeClock: AwakeClock, @unchecked Sendable {
    private let lock = NSLock()
    private var current: Duration = .seconds(1000)
    private var nextId: UInt64 = 0
    private var sleepers: [UInt64: (deadline: Duration, c: CheckedContinuation<Void, Error>)] = [:]
    private var cancelled: Set<UInt64> = []

    var now: Duration { lock.withLock { current } }
    var sleeperCount: Int { lock.withLock { sleepers.count } }

    func advance(by d: Duration) {
        let ready: [CheckedContinuation<Void, Error>] = lock.withLock {
            current += d
            let due = sleepers.filter { $0.value.deadline <= current }
            due.keys.forEach { sleepers[$0] = nil }
            return due.values.map(\.c)
        }
        ready.forEach { $0.resume() }
    }

    func sleep(until deadline: Duration) async throws {
        let id: UInt64 = lock.withLock { nextId += 1; return nextId }
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (c: CheckedContinuation<Void, Error>) in
                enum Now { case wake, cancel, wait }
                let now: Now = lock.withLock {
                    if cancelled.remove(id) != nil { return .cancel }
                    if current >= deadline { return .wake }
                    sleepers[id] = (deadline, c)
                    return .wait
                }
                switch now {
                case .wake: c.resume()
                case .cancel: c.resume(throwing: CancellationError())
                case .wait: break
                }
            }
        } onCancel: {
            let c: CheckedContinuation<Void, Error>? = lock.withLock {
                if let s = sleepers.removeValue(forKey: id) { return s.c }
                cancelled.insert(id)
                return nil
            }
            c?.resume(throwing: CancellationError())
        }
    }
}

/// Records every call and runs `behaviour` (default: a 200 JSON echo of the endpoint).
final class RecordingHandler: GatewayHandler, @unchecked Sendable {
    typealias Behaviour = @Sendable (GatewayRequest, TurnGrant, GatewayReply) async -> Void
    private let lock = NSLock()
    private var recorded: [(GatewayRequest, TurnGrant)] = []
    private let behaviour: Behaviour

    init(_ behaviour: @escaping Behaviour = { r, _, reply in
        await reply.send(status: 200, json: Data(#"{"endpoint":"\#(r.endpoint.rawValue)","query":"\#(r.query)"}"#.utf8))
    }) { self.behaviour = behaviour }

    var calls: [(request: GatewayRequest, grant: TurnGrant)] { lock.withLock { recorded.map { ($0.0, $0.1) } } }
    var callCount: Int { lock.withLock { recorded.count } }

    func handle(_ r: GatewayRequest, grant: TurnGrant, reply: GatewayReply) async {
        lock.withLock { recorded.append((r, grant)) }
        await behaviour(r, grant, reply)
    }
}

/// A server over socketpairs: `connect()` hands one end to `serve(connection:)` and returns the other.
struct GatewayHarness {
    /// What the server runs between reading a body and its pre-dispatch check (set by a test, nil by default).
    final class Hook: @unchecked Sendable {
        private let lock = NSLock()
        private var stored: (@Sendable (TurnGrant) -> Void)?
        var action: (@Sendable (TurnGrant) -> Void)? {
            get { lock.withLock { stored } }
            set { lock.withLock { stored = newValue } }
        }
    }

    /// The registry's clock (turn grace).
    let clock: ManualAwakeClock
    /// The server's clock (first byte, idle, head, body and stall deadlines): it stands still unless a test advances it, so
    /// no load can make a connection time out (Ruling 44).
    let serverClock = ManualAwakeClock()
    let registry: TurnTokenRegistry
    let handler: RecordingHandler
    let server: GatewayServer
    let beforeDispatch = Hook()

    init(timing: GatewayTiming = .pinned, _ behaviour: RecordingHandler.Behaviour? = nil) {
        clock = ManualAwakeClock()
        registry = TurnTokenRegistry(clock: clock)
        if let behaviour { handler = RecordingHandler(behaviour) } else { handler = RecordingHandler() }
        let hook = beforeDispatch
        server = GatewayServer(registry: registry, handler: handler, timing: timing, clock: serverClock,
                               beforeDispatch: { hook.action?($0) })
    }

    /// Advances the server clock by `step` until `done` (at most `steps` times): the server computes a deadline when its
    /// connection thread reaches that point, which the test cannot observe, so it steps until the effect shows.
    func advanceServerClock(by step: Duration, steps: Int = 60, until done: () async -> Bool) async -> Bool {
        for _ in 0..<steps {
            serverClock.advance(by: step)
            if await done() { return true }
        }
        return false
    }

    static func grant(_ turn: String = "turn-1") -> TurnGrant {
        TurnGrant(turnId: turn, companyId: "co-1", agentId: "agent-1", itemId: nil, provider: "anthropic",
                  aliases: ["brahma-standard": TurnGrant.RoutedTarget(provider: "anthropic", model: "claude-sonnet-5-5")],
                  passThroughFamilies: ["claude-opus-5-5"], textOnlyModels: [])
    }

    func mint(_ turn: String = "turn-1") -> GatewayToken { registry.mint(Self.grant(turn)) }

    /// A connected peer and the task serving the other end (it ends when the server closes the connection).
    func connect() -> (peer: TestPeer, served: Task<Void, Never>) {
        var fds: [Int32] = [0, 0]
        #if canImport(Darwin)
        let type = SOCK_STREAM
        #else
        let type = Int32(SOCK_STREAM.rawValue)
        #endif
        precondition(socketpair(AF_UNIX, type, 0, &fds) == 0)
        let server = self.server, fd = fds[0]
        let served = Task { await server.serve(connection: fd) }
        return (TestPeer(fd: fds[1]), served)
    }

    /// Sends one raw request on a fresh connection and reads the response; the connection is then closed.
    func exchange(_ raw: String) async throws -> TestResponse {
        let (peer, served) = connect()
        await peer.write(raw)
        let response = try await peer.readResponse()
        peer.close()
        await served.value
        return response
    }
}

/// A raw request in the shape `claude` sends (inventory (d)): POST, Host, the token in `x-api-key`, Content-Length.
func rawRequest(method: String = "POST", target: String = "/t/v1/messages?beta=true", token: String?,
                body: String = #"{"model":"brahma-standard","max_tokens":1,"messages":[]}"#,
                extra: [String] = [], host: String = "127.0.0.1:4000", contentLength: Bool = true) -> String {
    var lines = ["\(method) \(target) HTTP/1.1", "Host: \(host)"]
    if let token { lines.append("x-api-key: \(token)") }
    lines.append("anthropic-version: 2023-06-01")
    if contentLength { lines.append("Content-Length: \(body.utf8.count)") }
    lines += extra
    return lines.joined(separator: "\r\n") + "\r\n\r\n" + body
}

// MARK: - The suite

/// Plan X1 Task 7: HTTP/1.1 framing, the endpoint allowlist, turn-token auth, size caps, keep-alive and chunked SSE.
@Suite(.scratch, .serialized) struct GatewayServerTests {
    @Test func classifyServesOnlyTheTwoEndpointsWithTheRecordedQueries() {
        #expect(GatewayRoutes.prefix == "/t/")
        #expect(GatewayRoutes.allowedQueries == ["", "beta=true"])
        #expect(GatewayRoutes.allowed == ["/t/v1/messages": .messages, "/t/v1/messages/count_tokens": .countTokens])
        let served: [(String, GatewayEndpoint)] = [
            ("/t/v1/messages", .messages), ("/t/v1/messages?beta=true", .messages),
            ("/t/v1/messages/count_tokens", .countTokens), ("/t/v1/messages/count_tokens?beta=true", .countTokens),
        ]
        for (target, endpoint) in served {
            #expect(GatewayRoutes.classify(method: "POST", target: target) == endpoint, "\(target)")
            #expect(GatewayRoutes.classify(method: "GET", target: target) == nil, "\(target)")
        }
        for target in ["/t/v1/messages/../files", "/t/v1/messages/%2e%2e/files", "/t/v1/%2e%2e/files", "/t/v1/messages%2fcount_tokens",
                       "/t/v1/messages%2Fcount_tokens", "//v1/batches", "/t//v1/messages", "/t/./v1/messages", "/t/v1/./messages",
                       "/t/v1/messages/", "/t/v1/messages#x", "/t/v1/messages?beta=true#x", "/t/v1/messages?beta=true&x=1",
                       "/t/v1/messages?x=1&beta=true", "/t/v1/messages?", "/t/v1/messages?beta=false", "/t/v1/messages?BETA=TRUE",
                       "/v1/messages", "/t/v1/batches", "/t/v1/files", "/t/v1/models", "/T/v1/messages", "/t/v1/Messages",
                       "http://evil/t/v1/messages", "http://127.0.0.1:4000/t/v1/messages", "127.0.0.1:443", "*", "",
                       "t/v1/messages", "/t/v1/messages\u{0}", "/t/v1/messages /x", "/t/v1/mes\u{e9}sages"] {
            #expect(GatewayRoutes.classify(method: "POST", target: target) == nil, "\(target.debugDescription)")
        }
    }

    /// Review Focus 4: every smuggling input is refused (404 or 400) before the handler; the recorded query is served.
    @Test func onlyModelEndpointsServed() async throws {
        let h = GatewayHarness()
        let token = h.mint().value
        let ok = { (target: String) in rawRequest(target: target, token: token) }
        // (raw request, expected status)
        let refused: [(String, Int)] = [
            (ok("/t/v1/messages/../files"), 404),
            (ok("/t/v1/messages/%2e%2e/files"), 404),
            (ok("/t/v1/%2e%2e/files"), 404),
            (ok("/t/v1/%2E%2E/v1/files"), 404),
            (ok("/t/v1/messages%2fcount_tokens"), 404),
            (ok("//v1/batches"), 404),
            (ok("/t//v1/batches"), 404),
            (ok("/t/v1/batches"), 404),
            (ok("/t/./v1/messages"), 404),
            (ok("/v1/messages"), 404),
            (ok("/t/v1/messages?beta=true&x=1"), 404),
            (ok("/t/v1/messages?"), 404),
            (ok("http://evil/t/v1/messages"), 400),
            (ok("http://127.0.0.1:4000/t/v1/messages?beta=true"), 400),
            (rawRequest(method: "CONNECT", target: "api.anthropic.com:443", token: token), 400),
            (rawRequest(method: "OPTIONS", target: "*", token: token), 400),
            (ok("/t/v1/messages#frag"), 400),
            (rawRequest(method: "GET", target: "/t/v1/messages", token: token), 405),
            (rawRequest(method: "post", target: "/t/v1/messages", token: token), 400),
            // Request-line and header tricks: bare LF, bare CR, obs-fold, space before the colon, NUL, HTTP/1.0, extra spaces.
            ("POST /t/v1/messages HTTP/1.1\nHost: 127.0.0.1\r\nx-api-key: \(token)\r\nContent-Length: 2\r\n\r\n{}", 400),
            ("POST /t/v1/messages HTTP/1.1\r\nHost: 127.0.0.1\nx-api-key: \(token)\r\nContent-Length: 2\r\n\r\n{}", 400),
            ("POST /t/v1/messages HTTP/1.1\r\nHost: 127.0.0.1\r\nx-api-key: \(token)\r\nContent-Length: 2\n\n{}", 400),
            ("POST /t/v1/messages HTTP/1.1\rHost: 127.0.0.1\r\nx-api-key: \(token)\r\nContent-Length: 2\r\n\r\n{}", 400),
            ("POST /t/v1/files HTTP/1.1\r\nHost: 127.0.0.1\r\nX-Smuggle: a\rPOST /t/v1/messages HTTP/1.1\r\nx-api-key: \(token)\r\nContent-Length: 2\r\n\r\n{}", 400),
            (rawRequest(token: token, extra: ["X-Folded: a", " b"]), 400),
            (rawRequest(token: token, extra: ["X-Space : a"]), 400),
            (rawRequest(token: token, extra: ["X-Nul: a\u{0}b"]), 400),
            ("POST /t/v1/messages HTTP/1.0\r\nHost: 127.0.0.1\r\nx-api-key: \(token)\r\nContent-Length: 2\r\n\r\n{}", 400),
            ("POST  /t/v1/messages HTTP/1.1\r\nHost: 127.0.0.1\r\nx-api-key: \(token)\r\nContent-Length: 2\r\n\r\n{}", 400),
            ("\r\nPOST /t/v1/messages HTTP/1.1\r\nHost: 127.0.0.1\r\nx-api-key: \(token)\r\nContent-Length: 2\r\n\r\n{}", 400),
            // Body framing: duplicate Content-Length, Content-Length with Transfer-Encoding, chunked, missing or odd lengths.
            (rawRequest(token: token, extra: ["Content-Length: 57"]), 400),
            (rawRequest(token: token, extra: ["Transfer-Encoding: chunked"]), 400),
            (rawRequest(token: token, body: "2\r\n{}\r\n0\r\n\r\n", extra: ["Transfer-Encoding: chunked"], contentLength: false), 400),
            (rawRequest(token: token, extra: ["Transfer-Encoding: identity"]), 400),
            (rawRequest(token: token, contentLength: false), 400),
            (rawRequest(token: token, body: "", extra: ["Content-Length: +2"], contentLength: false), 400),
            (rawRequest(token: token, body: "", extra: ["Content-Length: 0x2"], contentLength: false), 400),
            (rawRequest(token: token, body: "", extra: ["Content-Length: 2, 2"], contentLength: false), 400),
            (rawRequest(token: token, body: "", extra: ["Content-Length: -1"], contentLength: false), 400),
            (rawRequest(token: token, body: "", extra: ["Content-Length: 99999999999999999999"], contentLength: false), 400),
            // Host: required once, and naming this machine's loopback (a DNS-rebinding page names its own host).
            (rawRequest(token: token, host: "evil.example"), 400),
            (rawRequest(token: token, host: "api.anthropic.com"), 400),
            (rawRequest(token: token, extra: ["Host: 127.0.0.1:4000"]), 400),
            ("POST /t/v1/messages HTTP/1.1\r\nx-api-key: \(token)\r\nContent-Length: 2\r\n\r\n{}", 400),
        ]
        for (raw, status) in refused {
            let response = try await h.exchange(raw)
            #expect(response.status == status, "\(raw.debugDescription)")
            #expect(response.json?["type"] as? String == "error", "\(raw.debugDescription)")
            #expect(response.head.headers["connection"] == "close", "\(raw.debugDescription)")
            // A refusal never echoes the request: not the token, not the target, not a header.
            #expect(!response.text.contains(token) && !response.text.contains("evil") && !response.text.contains("files")
                    && !response.text.contains("Smuggle") && !response.text.contains("batches"), "\(response.text)")
        }
        #expect(h.handler.callCount == 0, "no refused request reaches the handler")
        // The recorded query and the plain path are served, on both endpoints.
        for (target, endpoint, query) in [("/t/v1/messages?beta=true", "messages", "beta=true"), ("/t/v1/messages", "messages", ""),
                                          ("/t/v1/messages/count_tokens?beta=true", "countTokens", "beta=true")] {
            let response = try await h.exchange(rawRequest(target: target, token: token))
            #expect(response.status == 200, "\(target)")
            #expect(response.json?["endpoint"] as? String == endpoint && response.json?["query"] as? String == query, "\(response.text)")
        }
        #expect(h.handler.callCount == 3)
        // The handler never sees the credential headers.
        for call in h.handler.calls {
            #expect(call.request.header("x-api-key") == nil && call.request.header("authorization") == nil)
            #expect(call.request.header("anthropic-version") == "2023-06-01")
            #expect(call.request.headers.allSatisfy { $0.name == $0.name.lowercased() })
        }
    }

    @Test func tokenRequired() async throws {
        let h = GatewayHarness()
        let token = h.mint()
        let other = h.mint("turn-2")
        let malformed = String(token.value.dropLast()) + "G"
        for raw in [rawRequest(token: nil), rawRequest(token: "abc"), rawRequest(token: malformed),
                    rawRequest(token: token.value.uppercased()), rawRequest(token: String(repeating: "0", count: 64)),
                    rawRequest(token: nil, extra: ["Authorization: Basic \(token.value)"]),
                    rawRequest(token: nil, extra: ["Authorization: Bearer"]),
                    // Two credentials are ambiguous, even when one is valid.
                    rawRequest(token: token.value, extra: ["x-api-key: \(other.value)"]),
                    rawRequest(token: token.value, extra: ["Authorization: Bearer \(token.value)"])] {
            let response = try await h.exchange(raw)
            #expect(response.status == 401, "\(raw.debugDescription)")
            #expect(response.errorType == "authentication_error")
            #expect(!response.text.contains(token.value) && !response.text.contains(other.value))
        }
        // A live token is served; the token of an ended turn is refused immediately after `endTurn`.
        #expect(try await h.exchange(rawRequest(token: token.value)).status == 200)
        h.registry.endTurn(token)
        let ended = try await h.exchange(rawRequest(token: token.value))
        #expect(ended.status == 401 && ended.errorType == "authentication_error")
        #expect(try await h.exchange(rawRequest(token: other.value)).status == 200, "ending one turn leaves the others")
        #expect(h.handler.callCount == 2)
    }

    @Test func tokenInEitherHeader() async throws {
        let h = GatewayHarness()
        let a = h.mint("turn-a"), b = h.mint("turn-b")
        #expect(try await h.exchange(rawRequest(token: a.value)).status == 200)
        #expect(try await h.exchange(rawRequest(token: nil, extra: ["Authorization: Bearer \(b.value)"])).status == 200)
        #expect(try await h.exchange(rawRequest(token: nil, extra: ["authorization: bearer \(b.value)"])).status == 200)
        #expect(try await h.exchange(rawRequest(token: nil, extra: ["X-Api-Key: \(a.value)"])).status == 200)
        #expect(h.handler.calls.map(\.grant.turnId) == ["turn-a", "turn-b", "turn-b", "turn-a"])
    }

    @Test func oversizeRefused() async throws {
        let h = GatewayHarness()
        let token = h.mint().value
        // A body one byte over the cap is refused on Content-Length alone: the server answers while most of it is unsent.
        do {
            let (peer, served) = h.connect()
            let head = rawRequest(token: token, body: "", extra: ["Content-Length: \(GatewayLimits.maxBodyBytes + 1)"], contentLength: false)
            await peer.write(head)
            let sent = peer.writeAvailable([UInt8](repeating: 0x61, count: 1 << 20))
            let response = try await peer.readResponse()
            #expect(response.status == 413 && response.errorType == "request_too_large")
            #expect(sent < GatewayLimits.maxBodyBytes / 4, "the client could not have sent the body: \(sent)")
            peer.close()
            await served.value
        }
        // 33 KiB of headers: refused as malformed (the 431 equivalent).
        let pad = "X-Pad: " + String(repeating: "a", count: 33 * 1024)
        let big = try await h.exchange(rawRequest(token: token, extra: [pad]))
        #expect(big.status == 400 && big.errorType == "invalid_request_error")
        // Many small headers adding up past 32 KiB are refused too.
        let many = (0..<700).map { "X-Pad-\($0): " + String(repeating: "b", count: 40) }
        #expect(try await h.exchange(rawRequest(token: token, extra: many)).status == 400)
        // A request line over 8 KiB, and a head that never ends.
        let longTarget = "/t/v1/messages?" + String(repeating: "q", count: 9 * 1024)
        #expect(try await h.exchange(rawRequest(target: longTarget, token: token)).status == 400)
        do {
            let (peer, served) = h.connect()
            await peer.write("POST /t/v1/messages HTTP/1.1\r\n" + String(repeating: "X-Endless: a\r\n", count: 4000))
            let response = try await peer.readResponse()
            #expect(response.status == 400)
            peer.close()
            await served.value
        }
        // The caps are the pinned values; exactly the cap is admitted.
        #expect(GatewayLimits.maxBodyBytes == 32 << 20 && GatewayLimits.maxHeaderBytes == 32 << 10 && GatewayLimits.maxRequestLine == 8 << 10)
        let atCap = String(repeating: "c", count: 8 * 1024 - "POST  HTTP/1.1".utf8.count - "/t/v1/messages?".utf8.count)
        #expect(try await h.exchange(rawRequest(target: "/t/v1/messages?" + atCap, token: token)).status == 404, "8 KiB line parsed, query refused")
        #expect(h.handler.callCount == 0)
    }

    @Test func bodyAtTheCapIsServed() async throws {
        let h = GatewayHarness { r, _, reply in
            await reply.send(status: 200, json: Data(#"{"bytes":\#(r.body.count)}"#.utf8))
        }
        let token = h.mint().value
        let body = String(repeating: "z", count: GatewayLimits.maxBodyBytes)
        let response = try await h.exchange(rawRequest(token: token, body: body))
        #expect(response.status == 200 && response.json?["bytes"] as? Int == GatewayLimits.maxBodyBytes)
    }

    @Test func keepAliveServesSequentialRequests() async throws {
        let h = GatewayHarness { r, _, reply in
            await reply.send(status: 200, json: Data(#"{"echo":\#(String(decoding: r.body, as: UTF8.self))}"#.utf8))
        }
        let token = h.mint().value
        let (peer, served) = h.connect()
        for i in 0..<3 {
            await peer.write(rawRequest(token: token, body: #"{"n":\#(i)}"#))
            let response = try await peer.readResponse()
            #expect(response.status == 200 && response.head.headers["connection"] != "close")
            #expect(response.text == #"{"echo":{"n":\#(i)}}"#)
        }
        // Two requests written back to back (pipelined) are both answered, in order.
        await peer.write(rawRequest(token: token, body: #"{"n":3}"#) + rawRequest(token: token, body: #"{"n":4}"#))
        #expect(try await peer.readResponse().text == #"{"echo":{"n":3}}"#)
        #expect(try await peer.readResponse().text == #"{"echo":{"n":4}}"#)
        // `Connection: close` is honoured after the response.
        await peer.write(rawRequest(token: token, body: #"{"n":5}"#, extra: ["Connection: close"]))
        let last = try await peer.readResponse()
        #expect(last.status == 200 && last.head.headers["connection"] == "close")
        #expect(await peer.seesEOF())
        await served.value
        #expect(h.handler.callCount == 6)
        #expect(h.server.activeConnections == 0)
    }

    @Test func sseIsChunkedAndFlushed() async throws {
        let gates = [Gate(), Gate(), Gate()]
        let events = (0..<3).map { "event: content_block_delta\ndata: {\"n\":\($0)}\n\n" }
        let h = GatewayHarness { _, _, reply in
            #expect(await reply.startEvents())
            for i in 0..<3 {
                #expect(await reply.event(Data(events[i].utf8)))
                await gates[i].wait()
            }
            #expect(await reply.endEvents())
        }
        let token = h.mint().value
        let (peer, served) = h.connect()
        await peer.write(rawRequest(token: token, body: #"{"stream":true}"#))
        let head = try await peer.readHead()
        #expect(head.status == 200)
        #expect(head.headers["content-type"] == "text/event-stream")
        #expect(head.headers["transfer-encoding"] == "chunked" && head.headers["content-length"] == nil)
        for i in 0..<3 {
            // Event i arrives while the handler is still parked behind gate i, so it was flushed on its own.
            #expect(String(decoding: try await peer.readChunk(), as: UTF8.self) == events[i])
            #expect(await peer.staysQuiet(milliseconds: 50), "nothing past event \(i) before its gate opens")
            gates[i].open()
        }
        #expect(try await peer.readChunk().isEmpty, "the stream ends with the terminating chunk")
        // The connection stays usable after a stream.
        #expect(await peer.staysQuiet(milliseconds: 20))
        peer.close()
        await served.value
    }

    @Test func handlerWithoutAResponseIsAnError() async throws {
        let silent = GatewayHarness { _, _, _ in }
        let response = try await silent.exchange(rawRequest(token: silent.mint().value))
        #expect(response.status == 500 && response.errorType == "api_error", "never an empty 200")
        // A stream the handler abandons is cut without its terminating chunk (the client sees a broken stream, not success).
        let abandoning = GatewayHarness { _, _, reply in
            await reply.startEvents()
            await reply.event(Data("event: ping\ndata: {}\n\n".utf8))
        }
        let (peer, served) = abandoning.connect()
        await peer.write(rawRequest(token: abandoning.mint().value))
        #expect(try await peer.readHead().status == 200)
        #expect(try await peer.readChunk().count > 0)
        #expect(await peer.seesEOF())
        await served.value
        // Replies refuse misuse: no second response, no events before the stream starts, no empty chunk (a terminator).
        let misuse = GatewayHarness { _, _, reply in
            #expect(await reply.event(Data("x".utf8)) == false)
            #expect(await reply.startEvents())
            #expect(await reply.event(Data()) == true, "an empty event writes nothing")
            #expect(await reply.send(status: 200, json: Data("{}".utf8)) == false)
            #expect(await reply.endEvents())
            #expect(await reply.endEvents() == false)
        }
        let streamed = try await misuse.exchange(rawRequest(token: misuse.mint().value))
        #expect(streamed.status == 200 && streamed.body.isEmpty)
    }

    @Test func refusalShapeIsAnthropics() throws {
        let body = GatewayRefusal.body(type: "invalid_request_error", message: "Brahma: a \"quoted\"\nline\u{1}")
        let json = try #require(try JSONSerialization.jsonObject(with: body) as? [String: Any])
        #expect(json["type"] as? String == "error")
        let error = try #require(json["error"] as? [String: Any])
        #expect(error["type"] as? String == "invalid_request_error")
        #expect(error["message"] as? String == "Brahma: a \"quoted\"\nline\u{1}")
        #expect(GatewayRefusal.status == 400 && GatewayRefusal.type == "invalid_request_error")
    }

    /// X1-33 (c): the body has an overall deadline proportional to its declared length, capped, on top of the per-read stall
    /// bound, so a client trickling bytes cannot hold an admitted request open.
    @Test func slowBodyIsCutAtItsOverallDeadline() async throws {
        // The pinned allowance: 10 s + 1 s per MiB, never past 60 s.
        #expect(GatewayLimits.bodyBaseAllowance == .seconds(10) && GatewayLimits.bodyMinBytesPerSecond == 1 << 20
                && GatewayLimits.bodyMaxDuration == .seconds(60))
        #expect(GatewayTiming.pinned.bodyAllowance(0) == .seconds(10))
        #expect(GatewayTiming.pinned.bodyAllowance(GatewayLimits.maxBodyBytes) == .seconds(42))
        #expect(GatewayTiming.pinned.bodyAllowance(Int(Int32.max)) == .seconds(60))
        // Pinned timing on the server clock: 1000 bytes may take 10 s in all; any one read may wait 30 s.
        let h = GatewayHarness()
        let token = h.mint().value
        let (peer, served) = h.connect()
        await peer.write(rawRequest(token: token, body: "", extra: ["Content-Length: 1000"], contentLength: false))
        // One byte per 4 s of server time: no read ever waits near the 30 s stall bound, but the whole body would need 4000 s.
        var cut = false
        for _ in 0..<100 where !cut {
            _ = await peer.write([0x61])
            h.serverClock.advance(by: .seconds(4))
            cut = await peer.seesEOF(within: 1)
        }
        #expect(cut, "cut at the overall body deadline")
        await served.value
        #expect(h.handler.callCount == 0)
    }

    /// Ruling 42 (m2): a fresh connection must send its first byte within `firstByteTimeout`; between keep-alive requests the
    /// longer idle bound applies.
    @Test func freshConnectionMustSpeakFirst() async throws {
        #expect(GatewayLimits.firstByteTimeout == .seconds(5) && GatewayLimits.keepAliveIdle == .seconds(60))
        let h = GatewayHarness()
        let token = h.mint().value
        do {
            let (peer, served) = h.connect()
            // While the server clock stands still nothing times out, however long a loaded machine takes...
            #expect(await peer.staysQuiet(milliseconds: 300))
            // ...and once 5 s have passed on it with no byte, the connection is closed.
            #expect(await h.advanceServerClock(by: .seconds(6)) { await peer.seesEOF(within: 1) })
            await served.value
        }
        do {
            let (peer, served) = h.connect()
            await peer.write(rawRequest(token: token))
            #expect(try await peer.readResponse().status == 200)
            // Between keep-alive requests the first-byte bound no longer applies: 6 s idle is fine...
            h.serverClock.advance(by: .seconds(6))
            await peer.write(rawRequest(token: token))
            #expect(try await peer.readResponse().status == 200)
            // ...and past the 60 s idle bound the connection is closed.
            #expect(await h.advanceServerClock(by: .seconds(61)) { await peer.seesEOF(within: 1) })
            await served.value
        }
    }

    /// Ruling 42 (m1): once the server has finished a request, its reply is closed: a write from a task the handler left
    /// behind is refused and nothing reaches the connection (where the next response is being served).
    @Test func writeAfterFinishIsRefused() async throws {
        final class Box: @unchecked Sendable {
            private let lock = NSLock()
            private var stored: [GatewayReply] = []
            func add(_ r: GatewayReply) { lock.withLock { stored.append(r) } }
            var first: GatewayReply? { lock.withLock { stored.first } }
        }
        let box = Box()
        let h = GatewayHarness { _, _, reply in
            box.add(reply)
            await reply.send(status: 200, json: Data("{}".utf8))
        }
        let token = h.mint().value
        let (peer, served) = h.connect()
        await peer.write(rawRequest(token: token))
        #expect(try await peer.readResponse().status == 200)
        // The second exchange on the connection proves the server finished the first.
        await peer.write(rawRequest(token: token))
        #expect(try await peer.readResponse().status == 200)
        let stale = try #require(box.first)
        #expect(await stale.send(status: 200, json: Data(#"{"stale":true}"#.utf8)) == false)
        #expect(await stale.startEvents() == false)
        #expect(await stale.event(Data("x".utf8)) == false)
        #expect(await stale.endEvents() == false)
        #expect(await peer.staysQuiet(milliseconds: 100), "the stale reply wrote nothing")
        peer.close()
        await served.value
        // Directly, on a socket that is still open: a reply finished before it answered refuses every later write.
        let registry = TurnTokenRegistry(clock: ManualAwakeClock())
        let lease = try #require(registry.open(registry.mint(GatewayHarness.grant()).value))
        var fds: [Int32] = [0, 0]
        #if canImport(Darwin)
        let type = SOCK_STREAM
        #else
        let type = Int32(SOCK_STREAM.rawValue)
        #endif
        #expect(socketpair(AF_UNIX, type, 0, &fds) == 0)
        let other = TestPeer(fd: fds[1])
        let wire = try #require(Wire(fd: fds[0], ioStall: .seconds(1)))
        let reply = GatewayReply(wire: wire, lease: lease, close: false)
        #expect(reply.finish() == .unanswered)
        #expect(await reply.send(status: 200, json: Data("{}".utf8)) == false)
        #expect(await reply.startEvents() == false)
        #expect(await other.staysQuiet(milliseconds: 100), "nothing was written after finish")
        wire.close()
        lease.finish()
        other.close()
    }

    /// Ruling 42 (m1): once closed, a wire never calls recv or send on its descriptor (which may already belong to another
    /// connection).
    @Test func wireNeverTouchesAClosedSocket() throws {
        var fds: [Int32] = [0, 0]
        #if canImport(Darwin)
        let type = SOCK_STREAM
        #else
        let type = Int32(SOCK_STREAM.rawValue)
        #endif
        #expect(socketpair(AF_UNIX, type, 0, &fds) == 0)
        let peer = TestPeer(fd: fds[1])
        let wire = try #require(Wire(fd: fds[0], ioStall: .seconds(1)))
        #expect(wire.writeBlocking(Array("ok".utf8), deadline: wire.deadline(after: .seconds(1))))
        wire.close()
        #expect(wire.writeBlocking(Array("late".utf8), deadline: wire.deadline(after: .seconds(1))) == false)
        if case .eof = wire.readBlocking(max: 16, deadline: wire.deadline(after: .milliseconds(100))) {} else {
            Issue.record("a closed wire must not read")
        }
        peer.close()
        // A descriptor that cannot be configured is refused and closed.
        #expect(Wire(fd: -1, ioStall: .seconds(1)) == nil)
    }

    /// Ruling 42 (m7): past the connection cap a connection gets the 503 refusal (shut and drained like every refusal), and the
    /// served ones are untouched.
    @Test func connectionCapAnswers503() async throws {
        let h = GatewayHarness()  // the server clock stands still: the idle connections that fill the cap never time out
        let token = h.mint().value
        var open: [(TestPeer, Task<Void, Never>)] = []
        for _ in 0..<GatewayLimits.maxConnections { open.append(h.connect()) }
        let deadline = AwakeTime.deadline(after: .seconds(testPatience))
        while h.server.activeConnections < GatewayLimits.maxConnections, AwakeTime.now < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        #expect(h.server.activeConnections == GatewayLimits.maxConnections)
        let (extra, extraServed) = h.connect()
        let busy = try await extra.readResponse()
        #expect(busy.status == 503 && busy.errorType == "overloaded_error" && busy.head.headers["connection"] == "close")
        #expect(await extra.seesEOF())
        await extraServed.value
        // A served connection still works.
        await open[0].0.write(rawRequest(token: token))
        #expect(try await open[0].0.readResponse().status == 200)
        for (peer, served) in open { peer.close(); await served.value }
        #expect(h.server.activeConnections == 0)
    }

    /// The accept loop: a real loopback listener, a request served through it, then a clean stop (thread joined, port closed).
    @Test func acceptLoopServesAndStopsCleanly() async throws {
        let h = GatewayHarness()
        let token = h.mint().value
        let port = try h.server.start()
        #expect(port > 0)
        #expect(try h.server.start() == port, "start is idempotent")
        let fd = try #require(connectLoopback(port: port))
        let peer = TestPeer(fd: fd)
        await peer.write(rawRequest(token: token, host: "127.0.0.1:\(port)"))
        #expect(try await peer.readResponse().status == 200)
        // `stop` joins the accept thread, closes the port and cuts the open keep-alive connection.
        h.server.stop()
        #expect(!h.server.isAccepting)
        #expect(await peer.seesEOF())
        let deadline = AwakeTime.deadline(after: .seconds(testPatience))
        while h.server.activeConnections > 0, AwakeTime.now < deadline { try await Task.sleep(for: .milliseconds(10)) }
        #expect(h.server.activeConnections == 0)
        #expect(connectLoopback(port: port) == nil, "nothing listens after stop")
        h.server.stop()
    }
}

/// A blocking TCP connect to 127.0.0.1:port (nil when refused).
func connectLoopback(port: UInt16, address: String = "127.0.0.1") -> Int32? {
    #if canImport(Darwin)
    let fd = socket(AF_INET, SOCK_STREAM, 0)
    #else
    let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
    #endif
    guard fd >= 0 else { return nil }
    var addr = sockaddr_in()
    addr.sin_family = sa_family_t(AF_INET)
    addr.sin_port = port.bigEndian
    addr.sin_addr.s_addr = inet_addr(address)
    let r = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
        connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
    if r != 0 { _ = Darwin_close(fd); return nil }
    return fd
}
