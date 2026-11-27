import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Serves one admitted request (Task 8's `ModelGateway`). It answers through `reply`, the only writer of the socket.
public protocol GatewayHandler: Sendable {
    func handle(_ r: GatewayRequest, grant: TurnGrant, reply: GatewayReply) async
}

/// The model gateway's HTTP/1.1 front (Plan X1 Task 7): loopback only, keep-alive, the two Messages endpoints, a live turn token
/// on every request, bounded heads and bodies, and responses as a JSON body or chunked SSE. Anything else is refused in the
/// Anthropic error shape before a handler runs, and the connection is closed.
public final class GatewayServer: @unchecked Sendable {
    private let registry: TurnTokenRegistry
    private let handler: any GatewayHandler
    private let lock = NSLock()
    private var connections: [UInt64: Wire] = [:]
    private var nextConnection: UInt64 = 0
    private var listener: (fd: Int32, port: UInt16)?
    private var accepting = false
    private var stopped = false
    private let acceptDone = DispatchSemaphore(value: 0)

    public init(registry: TurnTokenRegistry, handler: any GatewayHandler) {
        self.registry = registry; self.handler = handler
    }

    // MARK: Listening

    /// Binds `127.0.0.1:<ephemeral>` and starts the accept loop on a dedicated thread; returns the port. Idempotent while
    /// running; a stopped server does not start again.
    public func start() throws(LoopbackListenerError) -> UInt16 {
        lock.lock()
        defer { lock.unlock() }
        if let listener { return listener.port }
        guard !stopped else { throw .setup(step: "start after stop", errno: 0) }
        let bound = try LoopbackListener.listen()
        let flags = fcntl(bound.fd, F_GETFL)
        guard flags >= 0, fcntl(bound.fd, F_SETFL, flags | O_NONBLOCK) == 0 else {
            let code = errno
            _ = closeSocket(bound.fd)
            throw .setup(step: "make the listener non-blocking", errno: code)
        }
        listener = bound
        accepting = true
        let thread = Thread { [self] in acceptLoop(bound.fd) }
        thread.name = "brahma-gateway-accept"
        thread.start()
        return bound.port
    }

    /// Stops accepting (joins the accept thread, which closes the port) and cuts every open connection; their handlers are
    /// cancelled and each `serve` closes its socket as it returns. Idempotent.
    public func stop() {
        let (wasAccepting, open): (Bool, [Wire]) = lock.withLock {
            defer { stopped = true }
            return (!stopped && listener != nil, Array(connections.values))
        }
        if wasAccepting { acceptDone.wait() }
        open.forEach { $0.cut() }
    }

    /// Whether the accept thread is running.
    public var isAccepting: Bool { lock.withLock { accepting } }
    /// Connections being served now.
    public var activeConnections: Int { lock.withLock { connections.count } }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func acceptLoop(_ fd: Int32) {
        var failures = 0
        while !isStopped {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&pfd, 1, 200) > 0 else { continue }
            let client: Int32
            switch Result(catching: { () throws(LoopbackListenerError) in try LoopbackListener.accept(fd) }) {
            case .success(let fd):
                client = fd
            case .failure(.accept(let code)) where code == EMFILE || code == ENFILE:
                // Out of descriptors: back off instead of spinning (EgressProxy's rule).
                failures += 1
                Thread.sleep(forTimeInterval: Double(min(1000, 50 << min(failures - 1, 20))) / 1000)
                continue
            case .failure:
                continue  // EAGAIN, an aborted handshake, or a refused non-loopback peer (already closed).
            }
            failures = 0
            guard let wire = register(client) else { continue }
            Task { await self.run(wire) }
        }
        _ = closeSocket(fd)
        lock.withLock { accepting = false; listener = nil }
        acceptDone.signal()
    }

    // MARK: Connections

    /// Serves one HTTP/1.1 connection (keep-alive) until the client closes it, a refusal, an error or `stop`. Takes ownership of
    /// `fd` and closes it before returning.
    public func serve(connection fd: Int32) async {
        guard let wire = register(fd) else { return }
        await run(wire)
    }

    /// Tracks a new connection; past the cap (or after `stop`) it is answered 503 and closed instead.
    private func register(_ fd: Int32) -> Wire? {
        let wire = Wire(fd: fd)
        let admitted: Bool = lock.withLock {
            guard !stopped, connections.count < GatewayLimits.maxConnections else { return false }
            nextConnection += 1
            wire.id = nextConnection
            connections[wire.id] = wire
            return true
        }
        guard admitted else {
            wire.writeBlocking(Self.refusalBytes(.busy), deadline: AwakeTime.deadline(after: .seconds(1)))
            wire.close()
            return nil
        }
        return wire
    }

    private func run(_ wire: Wire) async {
        defer {
            _ = lock.withLock { connections.removeValue(forKey: wire.id) }
            wire.close()
        }
        let connection = HTTPConnection(wire: wire)
        while true {
            switch await connection.nextHead() {
            case .closed:
                return
            case .refused(let refusal):
                await connection.refuse(refusal)
                return
            case .head(let head):
                guard await exchange(head, on: connection) else { return }
            }
        }
    }

    /// One request/response. Returns whether the connection may carry another request.
    private func exchange(_ head: RequestHead, on connection: HTTPConnection) async -> Bool {
        let framing: RequestFraming
        switch HTTPHead.frame(head) {
        case .failure(let refusal):
            await connection.refuse(refusal)
            return false
        case .success(let f):
            framing = f
        }
        guard let credential = framing.credential, let lease = registry.open(credential) else {
            await connection.refuse(.unauthorized)
            return false
        }
        defer { lease.finish() }
        guard let body = await connection.readBody(framing.contentLength) else { return false }
        let request = GatewayRequest(endpoint: framing.endpoint, query: framing.query,
                                     headers: head.headers.filter { $0.name != "x-api-key" && $0.name != "authorization" },
                                     body: body)
        let wire = connection.wire
        let reply = GatewayReply(wire: wire, lease: lease, close: framing.close)
        let handler = self.handler
        let task = Task { await handler.handle(request, grant: lease.grant, reply: reply) }
        // A cut — from the registry (revocation, stop, grace over) or from `stop()` — shuts the socket and cancels the handler.
        wire.whileServing { task.cancel() }
        lease.arm { wire.cut() }
        await withTaskCancellationHandler { await task.value } onCancel: { task.cancel() }
        wire.whileServing(nil)
        switch reply.finish() {
        case .unanswered:
            // Fail closed: never an empty 200.
            await connection.refuse(.noResponse)
            return false
        case .incomplete:
            // A stream that was not ended is cut without its terminating chunk, so the client sees a broken stream.
            return false
        case .complete:
            return !framing.close && !lease.wasCut && !wire.wasCut
        }
    }

    static func refusalBytes(_ r: HTTPRefusal) -> [UInt8] {
        let body = GatewayRefusal.body(type: r.type, message: r.message)
        var headers = [("Content-Type", "application/json"), ("Content-Length", String(body.count)), ("Connection", "close")]
        if r.status == 405 { headers.append(("Allow", GatewayRoutes.method)) }
        return HTTPHead.responseHead(status: r.status, headers: headers) + Array(body)
    }
}

/// The reading side of one connection: buffered bytes, the next head, a body.
final class HTTPConnection {
    let wire: Wire
    private var buffer: [UInt8] = []

    init(wire: Wire) { self.wire = wire }

    enum Next { case head(RequestHead), refused(HTTPRefusal), closed }

    /// Waits for the next request head: up to `keepAliveIdle` for its first byte, then `headTimeout` for the rest.
    func nextHead() async -> Next {
        var deadline = AwakeTime.deadline(after: GatewayLimits.keepAliveIdle)
        var started = !buffer.isEmpty
        if started { deadline = AwakeTime.deadline(after: GatewayLimits.headTimeout) }
        while true {
            switch HTTPHead.scan(buffer) {
            case .refused(let refusal):
                return .refused(refusal)
            case .complete(let end):
                let parsed = HTTPHead.parse(buffer[0..<end])
                buffer.removeFirst(end)
                switch parsed {
                case .success(let head): return .head(head)
                case .failure(let refusal): return .refused(refusal)
                }
            case .incomplete:
                break
            }
            guard case .data(let bytes) = await wire.read(max: 16 * 1024, deadline: deadline) else { return .closed }
            buffer += bytes
            if !started {
                started = true
                deadline = AwakeTime.deadline(after: GatewayLimits.headTimeout)
            }
        }
    }

    /// Exactly `count` body bytes (what was buffered first); nil when the client stalls or goes away.
    func readBody(_ count: Int) async -> Data? {
        var body = Data(buffer.prefix(count))
        buffer.removeFirst(min(count, buffer.count))
        while body.count < count {
            let want = min(256 * 1024, count - body.count)
            guard case .data(let bytes) = await wire.read(max: want, deadline: AwakeTime.deadline(after: GatewayLimits.ioStall)) else {
                return nil
            }
            body.append(contentsOf: bytes)
        }
        return body
    }

    /// Sends a refusal and ends the connection: the write side is shut, then a little of whatever the client is still sending
    /// is drained (bounded), so closing does not reset the connection before the client reads the refusal.
    func refuse(_ refusal: HTTPRefusal) async {
        _ = await wire.write(GatewayServer.refusalBytes(refusal))
        await wire.lingerAndShut()
    }
}

/// The reply to one request: a JSON body (`send`), or an SSE stream (`startEvents`, `event`…, `endEvents`) sent with chunked
/// transfer coding and flushed event by event. The only writer of the socket. Each call returns whether its bytes were written;
/// false once the client is gone or the turn's token was cut (revoked, stopped, or its end-of-turn grace ran out).
public final class GatewayReply: @unchecked Sendable {
    enum State { case pending, streaming, complete, failed }
    enum Outcome { case unanswered, incomplete, complete }

    private let wire: Wire
    private let lease: GatewayLease
    private let close: Bool
    private let lock = NSLock()
    private var state = State.pending
    private var busy = false

    init(wire: Wire, lease: GatewayLease, close: Bool) {
        self.wire = wire; self.lease = lease; self.close = close
    }

    /// A whole JSON response (any status 200–599; upstream errors are relayed this way).
    @discardableResult
    public func send(status: Int, json body: Data) async -> Bool {
        guard (200...599).contains(status) else { return false }
        let head = HTTPHead.responseHead(status: status, headers: [
            ("Content-Type", "application/json"), ("Content-Length", String(body.count)), ("Connection", close ? "close" : "keep-alive"),
        ])
        return await write(head + Array(body), from: .pending, to: .complete)
    }

    /// A refusal in the Anthropic error shape (Task 8–9 cap and policy refusals: `GatewayRefusal.status`/`.type`).
    @discardableResult
    public func refuse(status: Int, type: String, message: String) async -> Bool {
        await send(status: status, json: GatewayRefusal.body(type: type, message: message))
    }

    /// Starts an SSE response (`text/event-stream`, chunked).
    @discardableResult
    public func startEvents(status: Int = 200) async -> Bool {
        guard (200...599).contains(status) else { return false }
        let head = HTTPHead.responseHead(status: status, headers: [
            ("Content-Type", "text/event-stream"), ("Cache-Control", "no-cache"), ("Transfer-Encoding", "chunked"),
            ("Connection", close ? "close" : "keep-alive"),
        ])
        return await write(head, from: .pending, to: .streaming)
    }

    /// Writes one chunk (one or more whole SSE events) and flushes it. An empty chunk writes nothing (it would end the stream).
    @discardableResult
    public func event(_ bytes: Data) async -> Bool {
        if bytes.isEmpty { return lock.withLock { state == .streaming } }
        let chunk = Array(String(bytes.count, radix: 16).utf8) + [13, 10] + Array(bytes) + [13, 10]
        return await write(chunk, from: .streaming, to: .streaming)
    }

    /// Ends the stream with the terminating chunk.
    @discardableResult
    public func endEvents() async -> Bool {
        await write(Array("0\r\n\r\n".utf8), from: .streaming, to: .complete)
    }

    /// Whether the request was cut (token revoked, stop, grace over) or the connection broke.
    public var isCut: Bool { lease.wasCut || wire.wasCut || lock.withLock { state == .failed } }

    private func write(_ bytes: [UInt8], from: State, to: State) async -> Bool {
        let claimed: Bool = lock.withLock {
            guard state == from, !busy else { return false }
            busy = true
            return true
        }
        guard claimed else { return false }
        var ok = false
        if lease.mayContinue() { ok = await wire.write(bytes) }
        lock.withLock {
            busy = false
            state = ok ? to : .failed
        }
        return ok
    }

    /// Called by the server after the handler returns.
    func finish() -> Outcome {
        lock.withLock {
            switch state {
            case .pending: .unanswered
            case .streaming, .failed: .incomplete
            case .complete: .complete
            }
        }
    }
}

/// One client socket: non-blocking, no SIGPIPE, with blocking reads and writes run on its own serial queue (never on the
/// cooperative pool) in awake-time poll slices. `cut` shuts the socket down from any thread, which wakes those waits at once.
final class Wire: @unchecked Sendable {
    let fd: Int32
    var id: UInt64 = 0
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var closed = false
    private var isCut = false
    private var cutAction: (@Sendable () -> Void)?

    init(fd: Int32) {
        self.fd = fd
        queue = DispatchQueue(label: "brahma-gateway-conn")
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        let flags = fcntl(fd, F_GETFL)
        if flags >= 0 { _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK) }
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    enum ReadResult: Sendable { case data([UInt8]), eof, timeout }

    var wasCut: Bool { lock.withLock { isCut } }

    /// Shuts the socket down (both directions) unless it is already closed, and runs the serving action (cancels the
    /// handler). Idempotent.
    func cut() {
        let action: (@Sendable () -> Void)? = lock.withLock {
            guard !closed, !isCut else { return nil }
            isCut = true
            _ = shutdown(fd, Int32(SHUT_RDWR))
            defer { cutAction = nil }
            return cutAction
        }
        action?()
    }

    /// What a cut must also stop while a handler runs (nil when it returns). Runs at once if the wire is already cut.
    func whileServing(_ action: (@Sendable () -> Void)?) {
        let runNow: Bool = lock.withLock {
            if isCut { return action != nil }
            cutAction = action
            return false
        }
        if runNow { action?() }
    }

    func close() {
        lock.withLock {
            guard !closed else { return }
            closed = true
            _ = closeSocket(fd)
        }
    }

    func read(max: Int, deadline: SuspendingClock.Instant) async -> ReadResult {
        await withCheckedContinuation { c in queue.async { c.resume(returning: self.readBlocking(max: max, deadline: deadline)) } }
    }

    func write(_ bytes: [UInt8]) async -> Bool {
        await withCheckedContinuation { c in
            queue.async { c.resume(returning: self.writeBlocking(bytes, deadline: AwakeTime.deadline(after: GatewayLimits.ioStall))) }
        }
    }

    /// Shuts the write side, drains at most 64 KiB for at most 250 ms, then shuts the rest.
    func lingerAndShut() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                _ = shutdown(self.fd, Int32(SHUT_WR))
                var drained = 0
                let deadline = AwakeTime.deadline(after: .milliseconds(250))
                while drained < 64 * 1024, case .data(let bytes) = self.readBlocking(max: 16 * 1024, deadline: deadline) {
                    drained += bytes.count
                }
                self.cut()
                c.resume()
            }
        }
    }

    private var cutNow: Bool { lock.withLock { isCut || closed } }

    /// Up to `max` bytes: waits (in poll slices) for the first, then takes whatever else is already there.
    func readBlocking(max: Int, deadline: SuspendingClock.Instant) -> ReadResult {
        var chunk = [UInt8](repeating: 0, count: max)
        var got = 0
        while true {
            if cutNow { return .eof }
            let n = chunk.withUnsafeMutableBytes { recv(fd, $0.baseAddress! + got, $0.count - got, 0) }
            if n > 0 {
                got += n
                if got < max { continue }
                return .data(chunk)
            }
            if got > 0 { return .data(Array(chunk[0..<got])) }
            if n == 0 { return .eof }
            guard errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR else { return .eof }
            guard AwakeTime.now < deadline else { return .timeout }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            _ = poll(&pfd, 1, 250)
        }
    }

    @discardableResult
    func writeBlocking(_ bytes: [UInt8], deadline: SuspendingClock.Instant) -> Bool {
        var offset = 0
        while offset < bytes.count {
            if cutNow { return false }
            let n = bytes[offset...].withUnsafeBytes { send(fd, $0.baseAddress, $0.count, Self.sendFlags) }
            if n > 0 { offset += n; continue }
            guard n < 0, errno == EAGAIN || errno == EWOULDBLOCK || errno == EINTR else { return false }
            guard AwakeTime.now < deadline else { return false }
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            _ = poll(&pfd, 1, 250)
        }
        return true
    }

    #if canImport(Darwin)
    static let sendFlags: Int32 = 0
    #else
    static let sendFlags = Int32(MSG_NOSIGNAL)
    #endif
}
