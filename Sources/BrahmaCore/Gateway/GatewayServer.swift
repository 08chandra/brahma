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
    /// 503 refusals in progress (capped by `GatewayLimits.maxBusyRefusals`).
    private var busyRefusals = 0
    private var listener: (fd: Int32, port: UInt16)?
    private var accepting = false
    private var stopped = false
    private let acceptDone = DispatchSemaphore(value: 0)
    private let timing: GatewayTiming
    /// Test seam: runs after a request's body is read and before the pre-dispatch re-check.
    private let beforeDispatch: (@Sendable (TurnGrant) -> Void)?

    public convenience init(registry: TurnTokenRegistry, handler: any GatewayHandler) {
        self.init(registry: registry, handler: handler, timing: .pinned, beforeDispatch: nil)
    }

    /// `timing` and `beforeDispatch` are for tests.
    init(registry: TurnTokenRegistry, handler: any GatewayHandler, timing: GatewayTiming, beforeDispatch: (@Sendable (TurnGrant) -> Void)?) {
        self.registry = registry; self.handler = handler; self.timing = timing; self.beforeDispatch = beforeDispatch
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
        // Whether `fd` is still this listener's: after EBADF/POLLNVAL it may already be closed (and its number reused), so the
        // loop leaves without closing it.
        var ownsDescriptor = true
        loop: while !isStopped {
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 200)
            if ready < 0 {
                if errno == EBADF { ownsDescriptor = false; break loop }
                if errno == EINVAL { break loop }
                continue  // EINTR, EAGAIN
            }
            if ready == 0 { continue }
            if Int32(pfd.revents) & Int32(POLLNVAL) != 0 { ownsDescriptor = false; break loop }
            let client: Int32
            switch Result(catching: { () throws(LoopbackListenerError) in try LoopbackListener.accept(fd) }) {
            case .success(let fd):
                client = fd
            case .failure(.accept(let code)) where code == EMFILE || code == ENFILE:
                // Out of descriptors: back off instead of spinning (EgressProxy's rule).
                failures += 1
                Thread.sleep(forTimeInterval: Double(min(1000, 50 << min(failures - 1, 20))) / 1000)
                continue
            case .failure(.accept(let code)) where code == EBADF:
                ownsDescriptor = false
                break loop
            case .failure(.accept(let code)) where code == EINVAL || code == ENOTSOCK || code == EOPNOTSUPP:
                break loop  // not a listening socket any more: never spin on it
            case .failure(.configureClient), .failure(.peerNotLoopback):
                continue  // that one connection was closed; the listener is fine
            case .failure:
                continue  // EAGAIN, an aborted handshake
            }
            failures = 0
            switch register(client) {
            case .admitted(let wire): Task { await self.run(wire) }
            case .busy(let wire): Task { await self.refuseBusy(wire) }
            case .overflow(let wire): wire.close()
            case .unusable: continue
            }
        }
        if ownsDescriptor { _ = closeSocket(fd) }
        lock.withLock { accepting = false; listener = nil }
        acceptDone.signal()
    }

    // MARK: Connections

    /// Serves one HTTP/1.1 connection (keep-alive) until the client closes it, a refusal, an error or `stop`. Takes ownership of
    /// `fd` and closes it before returning.
    public func serve(connection fd: Int32) async {
        switch register(fd) {
        case .admitted(let wire): await run(wire)
        case .busy(let wire): await refuseBusy(wire)
        case .overflow(let wire): wire.close()
        case .unusable: return
        }
    }

    private enum Admission { case admitted(Wire), busy(Wire), overflow(Wire), unusable }

    /// Tracks a new connection. Past the cap (or after `stop`) it is to be answered 503 — unless `maxBusyRefusals` 503s are
    /// already being sent, when it is closed unanswered (so a flood cannot hold unbounded refusals); a socket that cannot be
    /// made non-blocking and SIGPIPE-free is closed at once.
    private func register(_ fd: Int32) -> Admission {
        guard let wire = Wire(fd: fd, ioStall: timing.ioStall) else { return .unusable }
        enum Slot { case connection, refusal, none }
        let slot: Slot = lock.withLock {
            if !stopped, connections.count < GatewayLimits.maxConnections {
                nextConnection += 1
                wire.id = nextConnection
                connections[wire.id] = wire
                return .connection
            }
            guard busyRefusals < GatewayLimits.maxBusyRefusals else { return .none }
            busyRefusals += 1
            return .refusal
        }
        switch slot {
        case .connection: return .admitted(wire)
        case .refusal: return .busy(wire)
        case .none: return .overflow(wire)
        }
    }

    /// The 503 at the connection cap, sent like every refusal (write side shut, bounded drain), then closed.
    private func refuseBusy(_ wire: Wire) async {
        await HTTPConnection(wire: wire, timing: timing).refuse(.busy)
        wire.close()
        lock.withLock { busyRefusals -= 1 }
    }

    /// 503 refusals being sent now (tests).
    var busyRefusalsInProgress: Int { lock.withLock { busyRefusals } }

    private func run(_ wire: Wire) async {
        defer {
            _ = lock.withLock { connections.removeValue(forKey: wire.id) }
            wire.close()
        }
        let connection = HTTPConnection(wire: wire, timing: timing)
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
        let wire = connection.wire
        // Armed before the body: a revocation, a stop or the end of the grace while the body is still arriving cuts the socket,
        // so the read ends and the request is never dispatched (X1-33).
        lease.arm { wire.cut() }
        guard let body = await connection.readBody(framing.contentLength) else { return false }
        // Between the body and dispatch a cut only marks the lease, so the check below can still answer 401 on the open socket.
        lease.disarm()
        beforeDispatch?(lease.grant)
        guard lease.mayContinue() else {
            await connection.refuse(.unauthorized)
            return false
        }
        let request = GatewayRequest(endpoint: framing.endpoint, query: framing.query,
                                     headers: head.headers.filter { $0.name != "x-api-key" && $0.name != "authorization" },
                                     body: body)
        let reply = GatewayReply(wire: wire, lease: lease, close: framing.close)
        let handler = self.handler
        let task = Task {
            // A cut that lands between the check above and the arming below cancels this task before the handler starts.
            guard !Task.isCancelled, lease.mayContinue() else { return }
            await handler.handle(request, grant: lease.grant, reply: reply)
        }
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
    private let timing: GatewayTiming
    private var buffer: [UInt8] = []
    private var heads = 0

    init(wire: Wire, timing: GatewayTiming) { self.wire = wire; self.timing = timing }

    enum Next { case head(RequestHead), refused(HTTPRefusal), closed }

    /// Waits for the next request head: a fresh connection's first byte within `firstByte`, a keep-alive connection's next
    /// request within `keepAliveIdle`; then the rest of the head within `headTimeout`.
    func nextHead() async -> Next {
        var deadline = AwakeTime.deadline(after: heads == 0 ? timing.firstByte : timing.keepAliveIdle)
        heads += 1
        var started = !buffer.isEmpty
        if started { deadline = AwakeTime.deadline(after: timing.headTimeout) }
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
                deadline = AwakeTime.deadline(after: timing.headTimeout)
            }
        }
    }

    /// Exactly `count` body bytes (what was buffered first); nil when the client stalls for `ioStall`, runs past the overall
    /// body allowance for `count` bytes, goes away, or the connection is cut.
    func readBody(_ count: Int) async -> Data? {
        let overall = AwakeTime.deadline(after: timing.bodyAllowance(count))
        var body = Data(buffer.prefix(count))
        buffer.removeFirst(min(count, buffer.count))
        while body.count < count {
            let want = min(256 * 1024, count - body.count)
            let deadline = min(overall, AwakeTime.deadline(after: timing.ioStall))
            guard case .data(let bytes) = await wire.read(max: want, deadline: deadline) else { return nil }
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
    enum State { case pending, streaming, complete, failed, closed }
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
            // A reply finished meanwhile stays closed.
            if state != .closed { state = ok ? to : .failed }
        }
        return ok
    }

    /// Called by the server after the handler returns: reports how the reply ended and closes it for good — every later call
    /// (say from a task the handler left behind) returns false and writes nothing, so it can never reach the next response on
    /// a keep-alive connection. A write still in progress counts as an unfinished reply.
    func finish() -> Outcome {
        lock.withLock {
            defer { state = .closed }
            if busy { return .incomplete }
            switch state {
            case .pending: return .unanswered
            case .streaming, .failed, .closed: return .incomplete
            case .complete: return .complete
            }
        }
    }
}

/// One client socket: non-blocking, no SIGPIPE, with blocking reads and writes run on its own serial queue (never on the
/// cooperative pool) in awake-time poll slices. `cut` shuts the socket down from any thread, which wakes those waits at once.
///
/// Every `recv`, `send` and `shutdown` runs under the lock that `close` takes, after checking the socket is still open, so no
/// call can ever reach a closed descriptor or one the process has since reused for another connection.
final class Wire: @unchecked Sendable {
    let fd: Int32
    var id: UInt64 = 0
    private let ioStall: Duration
    private let queue: DispatchQueue
    private let lock = NSLock()
    private var closed = false
    private var isCut = false
    private var cutAction: (@Sendable () -> Void)?

    /// Takes ownership of `fd`. Nil (and `fd` closed) when it cannot be made close-on-exec, non-blocking and SIGPIPE-free.
    init?(fd: Int32, ioStall: Duration) {
        let flags = fcntl(fd, F_GETFL)
        var ok = fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 && flags >= 0 && fcntl(fd, F_SETFL, flags | O_NONBLOCK) == 0
        #if canImport(Darwin)
        var one: Int32 = 1
        ok = ok && setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size)) == 0
        #endif
        guard ok else {
            _ = closeSocket(fd)
            return nil
        }
        self.fd = fd
        self.ioStall = ioStall
        queue = DispatchQueue(label: "brahma-gateway-conn")
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
            queue.async { c.resume(returning: self.writeBlocking(bytes, deadline: AwakeTime.deadline(after: self.ioStall))) }
        }
    }

    /// Shuts the write side, drains at most 64 KiB for at most 250 ms, then shuts the rest.
    func lingerAndShut() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            queue.async {
                self.lock.withLock { if !self.closed && !self.isCut { _ = shutdown(self.fd, Int32(SHUT_WR)) } }
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

    /// Runs one socket call under the lock, only while the socket is open and not cut; nil otherwise. Returns the call's
    /// result and its errno.
    private func io(_ call: () -> Int) -> (n: Int, errno: Int32)? {
        lock.withLock {
            guard !closed, !isCut else { return nil }
            let n = call()
            return (n, errno)
        }
    }

    /// Up to `max` bytes: waits (in poll slices) for the first, then takes whatever else is already there.
    func readBlocking(max: Int, deadline: SuspendingClock.Instant) -> ReadResult {
        var chunk = [UInt8](repeating: 0, count: max)
        var got = 0
        while true {
            guard let (n, code) = chunk.withUnsafeMutableBytes({ buf in io { recv(fd, buf.baseAddress! + got, buf.count - got, 0) } }) else {
                return .eof
            }
            if n > 0 {
                got += n
                if got < max { continue }
                return .data(chunk)
            }
            if got > 0 { return .data(Array(chunk[0..<got])) }
            if n == 0 { return .eof }
            guard code == EAGAIN || code == EWOULDBLOCK || code == EINTR else { return .eof }
            guard AwakeTime.now < deadline else { return .timeout }
            var pfd = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            _ = poll(&pfd, 1, 250)
        }
    }

    @discardableResult
    func writeBlocking(_ bytes: [UInt8], deadline: SuspendingClock.Instant) -> Bool {
        var offset = 0
        while offset < bytes.count {
            guard let (n, code) = bytes[offset...].withUnsafeBytes({ buf in io { send(fd, buf.baseAddress, buf.count, Self.sendFlags) } }) else {
                return false
            }
            if n > 0 { offset += n; continue }
            guard n < 0, code == EAGAIN || code == EWOULDBLOCK || code == EINTR else { return false }
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
