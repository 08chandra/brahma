import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// The only way out of a sandboxed check or preview with outbound network: an HTTP CONNECT proxy on loopback that lets a
// TLS connection through only to an allowed domain, on port 443, at a public address, resolved once.

/// Raises the process's open-file soft limit toward its hard limit at engine start, so the egress proxies' pooled sockets
/// (two descriptors per connection) cannot leave the engine without descriptors for its database, git and logs (A-I2).
public enum FileLimit {
    /// The target soft limit: the hard limit, capped at 10240.
    public static let target: UInt64 = 10240

    /// Raises `RLIMIT_NOFILE`'s soft limit to `min(hard, target)`; returns a one-line result for the log, or nil off Darwin.
    @discardableResult
    public static func raise() -> String? {
        #if canImport(Darwin)
        var limit = rlimit()
        guard getrlimit(RLIMIT_NOFILE, &limit) == 0 else { return "could not read RLIMIT_NOFILE (\(errno))" }
        let want = min(limit.rlim_max, rlim_t(target))
        if limit.rlim_cur >= want { return "soft \(limit.rlim_cur), hard \(limit.rlim_max) (unchanged)" }
        limit.rlim_cur = want
        guard setrlimit(RLIMIT_NOFILE, &limit) == 0 else { return "could not raise RLIMIT_NOFILE to \(want) (\(errno))" }
        return "raised soft limit to \(want) (hard \(limit.rlim_max))"
        #else
        return nil
        #endif
    }

    /// The current soft limit (for sizing the proxy descriptor budget), or a conservative default off Darwin / on error.
    static var current: Int {
        #if canImport(Darwin)
        var limit = rlimit()
        if getrlimit(RLIMIT_NOFILE, &limit) == 0 { return Int(min(limit.rlim_cur, rlim_t(Int.max))) }
        #endif
        return 256
    }
}

// MARK: Domains

/// Domain allow-list patterns: an exact name, or `*.parent` for the parent's subdomains only.
public enum DomainMatcher {
    /// Parents a wildcard may never have: anyone can register a name under them.
    public static let publicSuffixes: Set<String> = [
        "com", "net", "org", "io", "dev", "app", "co", "ai", "me", "xyz", "info", "biz", "us", "uk", "co.uk", "org.uk", "com.au",
        "github.io", "githubusercontent.com", "vercel.app", "netlify.app", "pages.dev", "workers.dev", "herokuapp.com", "web.app",
        "firebaseapp.com", "s3.amazonaws.com", "amazonaws.com", "cloudfront.net", "azurewebsites.net", "blob.core.windows.net",
        "appspot.com", "glitch.me", "repl.co", "ngrok.io", "ngrok-free.app",
    ]

    /// Lowercased, one trailing dot dropped.
    static func normalize(_ s: String) -> String {
        var d = s.lowercased()
        if d.hasSuffix("."), d.count > 1 { d.removeLast() }
        return d
    }

    /// `^(\*\.)?[a-z0-9-]+(\.[a-z0-9-]+)+$` (case-insensitive, a trailing dot dropped); not `localhost`, not an IP literal,
    /// not `*` alone; a wildcard's parent is neither a public suffix nor a single label. Labels are 1–63 characters and
    /// neither start nor end with `-`; the whole name is at most 253.
    public static func isValidPattern(_ s: String) -> Bool {
        let p = normalize(s)
        // Only the characters the pattern may hold, checked before the regex: ICU's `$` also matches just before a final
        // line terminator, so without this `"*.co.uk\n"` would slip a public-suffix wildcard past the rule below (A-I3).
        guard p.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" || $0 == "." || $0 == "*" })
        else { return false }
        guard p.range(of: "^(\\*\\.)?[a-z0-9-]+(\\.[a-z0-9-]+)+$", options: .regularExpression) != nil else { return false }
        let wildcard = p.hasPrefix("*.")
        let base = wildcard ? String(p.dropFirst(2)) : p
        guard base.count <= 253, base != "localhost", !base.hasSuffix(".localhost") else { return false }
        let labels = base.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.allSatisfy({ !$0.isEmpty && $0.count <= 63 && !$0.hasPrefix("-") && !$0.hasSuffix("-") }) else { return false }
        // An IPv4 literal (every label numeric); IPv6 never matches the pattern above.
        if labels.allSatisfy({ $0.allSatisfy(\.isNumber) }) { return false }
        if wildcard, labels.count < 2 || publicSuffixes.contains(base) { return false }
        return true
    }

    /// True for a host name (not an IP literal) that equals an allowed name or is a subdomain of an allowed `*.parent`.
    /// Case-insensitive; a trailing dot is dropped. An Anthropic host never matches, whatever the list says.
    public static func matches(host: String, allow: [String]) -> Bool {
        let h = normalize(host)
        guard isHostName(h), !SandboxDomains.isForbidden(h) else { return false }
        for raw in allow {
            // A pattern that is not valid, or is Anthropic's, is skipped whatever the list says (A-M3, defence in depth).
            guard isValidPattern(raw), !SandboxDomains.isForbidden(raw) else { continue }
            let pattern = normalize(raw)
            if pattern.hasPrefix("*.") {
                let parent = String(pattern.dropFirst(2))
                if !parent.isEmpty, h.hasSuffix("." + parent) { return true }
            } else if h == pattern {
                return true
            }
        }
        return false
    }

    /// Letters, digits, `-` and dots between non-empty labels, at least two labels, and not an IP literal of any form.
    static func isHostName(_ h: String) -> Bool {
        guard !h.isEmpty, h.count <= 253 else { return false }
        if isIPLiteral(h) { return false }
        let labels = h.split(separator: ".", omittingEmptySubsequences: false)
        guard labels.count >= 2 else { return false }
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63 && label.unicodeScalars.allSatisfy {
                ($0 >= "a" && $0 <= "z") || ($0 >= "0" && $0 <= "9") || $0 == "-"
            }
        }
    }

    static func isIPLiteral(_ h: String) -> Bool {
        if h.contains(":") || h.hasPrefix("[") { return true }
        var v4 = in_addr(), v6 = in6_addr()
        if inet_pton(AF_INET, h, &v4) == 1 || inet_pton(AF_INET6, h, &v6) == 1 { return true }
        // Every label numeric (`1.2.3.4`, but also `127.1` and other forms resolvers accept).
        return h.split(separator: ".").allSatisfy { $0.allSatisfy(\.isNumber) }
    }
}

// MARK: Addresses

/// Which resolved addresses the proxy may dial: public unicast only.
public enum AddressPolicy {
    /// False for:
    /// - IPv4 `0/8`, `10/8`, `100.64/10`, `127/8`, `169.254/16` (cloud metadata included), `172.16/12`, `192.0.0/24`,
    ///   `192.168/16`, `198.18/15`, multicast (`224/4`) and broadcast, and (stricter than the brief) the rest of `240/4` and
    ///   the documentation ranges `192.0.2/24`, `198.51.100/24`, `203.0.113/24`;
    /// - IPv6 `::`, `::1` (and every other address in `::/96`), `fc00::/7`, `fe80::/10`, `ff00::/8`, and (stricter) `fec0::/10`,
    ///   `2001:db8::/32`, Teredo `2001::/32`, `64:ff9b:1::/48`; an address that embeds an IPv4 one (v4-mapped `::ffff:0:0/96`,
    ///   NAT64 `64:ff9b::/96`, 6to4 `2002::/16`) is judged by that IPv4 address;
    /// - any other address family.
    public static func isPublic(_ addr: sockaddr_storage) -> Bool {
        var storage = addr
        switch Int32(addr.ss_family) {
        case AF_INET:
            let bytes: [UInt8] = withUnsafeBytes(of: &storage) { raw in
                let sin = raw.baseAddress!.assumingMemoryBound(to: sockaddr_in.self)
                return withUnsafeBytes(of: sin.pointee.sin_addr) { Array($0) }
            }
            return isPublicV4(bytes)
        case AF_INET6:
            let b: [UInt8] = withUnsafeBytes(of: &storage) { raw in
                let sin6 = raw.baseAddress!.assumingMemoryBound(to: sockaddr_in6.self)
                return withUnsafeBytes(of: sin6.pointee.sin6_addr) { Array($0) }
            }
            return isPublicV6(b)
        default:
            return false
        }
    }

    static func isPublicV4(_ b: [UInt8]) -> Bool {
        guard b.count == 4 else { return false }
        let (a, x, y) = (b[0], b[1], b[2])
        switch a {
        case 0, 10, 127: return false
        case 100 where x & 0xC0 == 64: return false            // 100.64/10
        case 169 where x == 254: return false                  // 169.254/16
        case 172 where x & 0xF0 == 16: return false            // 172.16/12
        case 192 where x == 0 && (y == 0 || y == 2): return false   // 192.0.0/24, 192.0.2/24
        case 192 where x == 168: return false                  // 192.168/16
        case 198 where x & 0xFE == 18: return false            // 198.18/15
        case 198 where x == 51 && y == 100: return false       // 198.51.100/24
        case 203 where x == 0 && y == 113: return false        // 203.0.113/24
        default: break
        }
        if a >= 224 { return false }                           // multicast 224/4, reserved 240/4, broadcast
        return true
    }

    static func isPublicV6(_ b: [UInt8]) -> Bool {
        guard b.count == 16 else { return false }
        // ::/96: the unspecified address, loopback and the deprecated IPv4-compatible form.
        if b[0..<12].allSatisfy({ $0 == 0 }) { return false }
        // ::ffff:a.b.c.d (v4-mapped).
        if b[0..<10].allSatisfy({ $0 == 0 }) && b[10] == 0xff && b[11] == 0xff { return isPublicV4(Array(b[12..<16])) }
        // 64:ff9b::/96 (NAT64) embeds an IPv4 address; 64:ff9b:1::/48 is local-use.
        if b[0] == 0x00 && b[1] == 0x64 && b[2] == 0xff && b[3] == 0x9b {
            if b[4..<12].allSatisfy({ $0 == 0 }) { return isPublicV4(Array(b[12..<16])) }
            if b[4] == 0 && b[5] == 1 { return false }
        }
        // 2002::/16 (6to4) embeds an IPv4 address in bytes 2–5.
        if b[0] == 0x20 && b[1] == 0x02 { return isPublicV4(Array(b[2..<6])) }
        // 2001:db8::/32 (documentation) and 2001::/32 (Teredo).
        if b[0] == 0x20 && b[1] == 0x01 && ((b[2] == 0x0d && b[3] == 0xb8) || (b[2] == 0 && b[3] == 0)) { return false }
        if b[0] & 0xFE == 0xFC { return false }                 // fc00::/7
        if b[0] == 0xFE && b[1] & 0xC0 == 0x80 { return false }  // fe80::/10
        if b[0] == 0xFE && b[1] & 0xC0 == 0xC0 { return false }  // fec0::/10
        if b[0] == 0xFF { return false }                        // ff00::/8
        return true
    }
}

// MARK: Proxy

/// A CONNECT-only HTTP proxy on `127.0.0.1:<port>` (POSIX sockets, one thread per connection). For `CONNECT host:port`:
/// 1. `port` must be 443;
/// 2. `DomainMatcher.matches(host, allow)`;
/// 3. the host is resolved once (`getaddrinfo`) and every address must pass `AddressPolicy.isPublic`;
/// 4. it dials those vetted addresses (in order, never resolving again: DNS rebinding cannot swap one in);
/// 5. it answers `200 Connection established` and pipes bytes both ways.
/// Any failure is answered `403`, any other method `405`. Timeouts (awake time): 10 s to read the request and to connect,
/// 300 s without traffic.
public final class EgressProxy: @unchecked Sendable {
    public static let allowedPort: UInt16 = 443
    public static let connectTimeout: Duration = .seconds(10)
    public static let idleTimeout: Duration = .seconds(300)
    static let maxRequestBytes = 8192
    static let maxDeniedHosts = 1000
    /// The default per-proxy cap on connections being served at once (A-I2).
    public static let perProxyLimit = 64

    /// Descriptors a piped connection holds: the client socket and the upstream socket.
    static let fdsPerConnection = 2

    /// A shared ceiling, in descriptors, across a set of proxies (the pool gives all of its proxies one). A connection is
    /// admitted only when both its proxy's own cap and this descriptor budget have room, so the proxies together can never
    /// hold more than `limit` descriptors open (A-I2: budget descriptors, not connections).
    public final class Budget: @unchecked Sendable {
        private let lock = NSLock()
        private let limit: Int
        private var used = 0
        public init(limit: Int) { self.limit = limit }
        /// Reserves `cost` descriptors; false (reserving nothing) when that would exceed the budget.
        func acquire(_ cost: Int) -> Bool { lock.withLock { used + cost <= limit ? { used += cost; return true }() : false } }
        func release(_ cost: Int) { lock.withLock { used = max(0, used - cost) } }
    }

    /// The back-off after `failures` accept failures in a row (EMFILE/ENFILE): 50 ms doubling to 1 s, awake time, never a spin.
    static func acceptBackoff(failures: Int) -> Duration {
        let ms = min(1000, 50 << min(failures - 1, 20))
        return .milliseconds(ms)
    }

    private final class ThreadBox { let run: () -> Void; let name: String; init(_ r: @escaping () -> Void, _ n: String) { run = r; name = n } }

    /// Starts `body` on a detached thread with a 512 KiB stack via `pthread_create`, whose non-zero return (out of threads)
    /// is checked, so a failure is a dropped connection rather than a crash. Returns whether the thread started.
    static func startThread(name: String, _ body: @escaping () -> Void) -> Bool {
        let box = Unmanaged.passRetained(ThreadBox(body, name)).toOpaque()
        var attr = pthread_attr_t()
        pthread_attr_init(&attr)
        defer { pthread_attr_destroy(&attr) }
        pthread_attr_setdetachstate(&attr, Int32(PTHREAD_CREATE_DETACHED))
        pthread_attr_setstacksize(&attr, 512 << 10)
        #if canImport(Darwin)
        var tid: pthread_t?
        #else
        var tid = pthread_t()
        #endif
        let rc = pthread_create(&tid, &attr, { arg in
            #if canImport(Darwin)
            let raw = arg
            #else
            let raw = arg!
            #endif
            let box = Unmanaged<ThreadBox>.fromOpaque(raw).takeRetainedValue()
            #if canImport(Darwin)
            pthread_setname_np(box.name)
            #endif
            box.run()
            return nil
        }, box)
        if rc != 0 { Unmanaged<ThreadBox>.fromOpaque(box).release(); return false }
        return true
    }

    public let port: UInt16
    public let allow: [String]

    typealias Resolver = @Sendable (String) -> [sockaddr_storage]?
    private let resolver: Resolver
    private let vet: @Sendable (sockaddr_storage) -> Bool
    /// The port dialled on the vetted address (always 443 outside tests).
    private let dialPort: UInt16
    private let maxConnections: Int
    private let budget: Budget?
    private let listener: Int32
    private let lock = NSLock()
    private var stopped = false
    private var denied: [String] = []
    private var active = 0
    private let acceptDone = DispatchSemaphore(value: 0)

    public convenience init(allow: [String]) throws {
        try self.init(allow: allow, resolver: EgressProxy.systemResolve)
    }

    /// `resolver`, `vet` and `dialPort` are for tests. `maxConnections` caps this proxy; `budget`, when given, is a ceiling
    /// shared with other proxies (the pool's).
    init(allow: [String], resolver: @escaping Resolver, vet: @escaping @Sendable (sockaddr_storage) -> Bool = AddressPolicy.isPublic,
         dialPort: UInt16 = EgressProxy.allowedPort, maxConnections: Int = EgressProxy.perProxyLimit, budget: Budget? = nil) throws {
        self.allow = allow; self.resolver = resolver; self.vet = vet; self.dialPort = dialPort
        self.maxConnections = maxConnections; self.budget = budget
        let fd = socket(AF_INET, Self.streamType, 0)
        guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 64) == 0 else {
            let code = errno
            close(fd)
            throw POSIXError(POSIXErrorCode(rawValue: code) ?? .EADDRINUSE)
        }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        listener = fd
        port = UInt16(bigEndian: addr.sin_port)
        Self.setNonBlocking(fd)
        let thread = Thread { [self] in acceptLoop() }
        thread.name = "brahma-egress-accept"
        thread.start()
    }

    deinit { stop() }

    /// Hosts refused so far (oldest first, at most `maxDeniedHosts`).
    public var deniedHosts: [String] { lock.withLock { denied } }

    /// How many connections this proxy is serving now (tests).
    public var activeConnections: Int { lock.withLock { active } }

    /// Stops accepting (the listening socket is closed by its own thread, which this waits for) and ends every open
    /// connection within a second. Idempotent.
    public func stop() {
        let first: Bool = lock.withLock {
            defer { stopped = true }
            return !stopped
        }
        if first { acceptDone.wait() }
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func deny(_ host: String) {
        let shown = String(host.unicodeScalars.filter { $0.value > 0x20 && $0.value < 0x7f }.map(Character.init).prefix(255))
        lock.withLock {
            denied.append(shown)
            if denied.count > Self.maxDeniedHosts { denied.removeFirst(denied.count - Self.maxDeniedHosts) }
        }
    }

    // MARK: Connections

    private static let serviceBusy = "HTTP/1.1 503 Service Unavailable\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"

    private func acceptLoop() {
        var failures = 0
        while !isStopped {
            var pfd = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
            let ready = poll(&pfd, 1, 200)
            if ready <= 0 { continue }
            let client = accept(listener, nil, nil)
            guard client >= 0 else {
                // Out of descriptors: back off instead of spinning (A-I2); other errors just retry.
                if errno == EMFILE || errno == ENFILE {
                    failures += 1
                    let ns = Self.acceptBackoff(failures: failures).components
                    Thread.sleep(forTimeInterval: Double(ns.seconds) + Double(ns.attoseconds) / 1e18)
                }
                continue
            }
            failures = 0
            _ = fcntl(client, F_SETFD, FD_CLOEXEC)
            Self.noSigPipe(client)
            Self.setNonBlocking(client)
            // Past this proxy's connection cap or the shared descriptor budget (2 fds per connection): 503 and close, never
            // a new worker (A-I2).
            let admitted = lock.withLock { () -> Bool in
                guard !stopped, active < maxConnections else { return false }
                if let budget, !budget.acquire(Self.fdsPerConnection) { return false }
                active += 1
                return true
            }
            guard admitted else {
                _ = Self.blockingWrite(client, Array(Self.serviceBusy.utf8))
                close(client)
                continue
            }
            func releaseSlot() {
                lock.withLock { active -= 1 }
                budget?.release(Self.fdsPerConnection)
            }
            // Thread allocation can fail when the machine is out of threads (pthread_create returns the error; it does not
            // crash). Drop the connection and release its slot rather than leak it. The caps bound how many worker threads
            // can ever exist, so this is a last resort (A-I2).
            let started = Self.startThread(name: "brahma-egress-conn") { [self] in
                handle(client)
                close(client)
                releaseSlot()
            }
            if !started {
                _ = Self.blockingWrite(client, Array(Self.serviceBusy.utf8))
                close(client)
                releaseSlot()
            }
        }
        close(listener)
        acceptDone.signal()
    }

    /// A best-effort blocking write of a short reply to a socket that may be non-blocking (the 503 path, outside a worker).
    private static func blockingWrite(_ fd: Int32, _ bytes: [UInt8]) {
        var offset = 0, tries = 0
        while offset < bytes.count, tries < 100 {
            let n = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n > 0 { offset += n; continue }
            if n < 0 && errno != EAGAIN && errno != EINTR { return }
            tries += 1
            var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
            _ = poll(&pfd, 1, 50)
        }
    }

    private static let forbidden = "HTTP/1.1 403 Forbidden\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    private static let notAllowed = "HTTP/1.1 405 Method Not Allowed\r\nAllow: CONNECT\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
    private static let established = "HTTP/1.1 200 Connection established\r\n\r\n"

    private func handle(_ client: Int32) {
        // Separate budgets: up to 10 s to read the request, then a fresh 10 s to resolve and connect (A-M2).
        guard let (head, rest) = readRequest(client, deadline: AwakeTime.deadline(after: Self.connectTimeout)) else {
            _ = writeAll(client, Array(Self.forbidden.utf8), idle: Self.connectTimeout)
            return
        }
        let deadline = AwakeTime.deadline(after: Self.connectTimeout)
        let line = head.split(separator: "\r\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count == 3, parts[2].hasPrefix("HTTP/1.") else {
            _ = writeAll(client, Array(Self.forbidden.utf8), idle: Self.connectTimeout)
            return
        }
        guard parts[0] == "CONNECT" else {
            _ = writeAll(client, Array(Self.notAllowed.utf8), idle: Self.connectTimeout)
            return
        }
        let target = parts[1]
        guard let colon = target.lastIndex(of: ":"), let port = UInt16(target[target.index(after: colon)...]),
              port == Self.allowedPort else {
            deny(target.split(separator: ":").first.map(String.init) ?? target)
            _ = writeAll(client, Array(Self.forbidden.utf8), idle: Self.connectTimeout)
            return
        }
        let host = DomainMatcher.normalize(String(target[..<colon]))
        guard DomainMatcher.matches(host: host, allow: allow),
              let addresses = resolve(host, deadline: deadline), !addresses.isEmpty, addresses.allSatisfy(vet),
              let upstream = dial(addresses, deadline: deadline) else {
            deny(host)
            _ = writeAll(client, Array(Self.forbidden.utf8), idle: Self.connectTimeout)
            return
        }
        defer { close(upstream) }
        guard writeAll(client, Array(Self.established.utf8), idle: Self.idleTimeout) else { return }
        if !rest.isEmpty, !writeAll(upstream, rest, idle: Self.idleTimeout) { return }
        pipeBoth(client, upstream)
    }

    /// The request head (up to the blank line) and whatever bytes followed it, or nil (too long, closed, timed out). A read
    /// that is merely not ready yet waits in poll slices until `deadline`, so a slow client is not refused after 1 s (A-M1).
    private func readRequest(_ fd: Int32, deadline: SuspendingClock.Instant) -> (String, [UInt8])? {
        var got: [UInt8] = []
        var buffer = [UInt8](repeating: 0, count: 2048)
        let end: [UInt8] = Array("\r\n\r\n".utf8)
        while got.count <= Self.maxRequestBytes {
            if let r = Self.find(end, in: got) {
                return (String(decoding: got[..<r], as: UTF8.self), Array(got[(r + end.count)...]))
            }
            guard !isStopped, AwakeTime.now < deadline else { return nil }
            if !Self.waitFor(fd, POLLIN) { continue }
            let n = read(fd, &buffer, buffer.count)
            if n < 0 { if errno == EINTR || errno == EAGAIN { continue }; return nil }
            if n == 0 { return nil }
            got += buffer[0..<n]
        }
        return nil
    }

    /// `resolver` run on a thread of its own with an awake-time deadline, so a slow DNS answer cannot hold the connection's
    /// thread past the connect budget (A-M2). The resolver thread is counted against the pool's descriptor budget (two slots,
    /// a connection's worth) and released when it finishes — even after the deadline — so a stuck `getaddrinfo` cannot let
    /// resolver threads pile up past the budget (A-I2). Nil on timeout, or when the budget is full.
    private func resolve(_ host: String, deadline: SuspendingClock.Instant) -> [sockaddr_storage]? {
        if let budget, !budget.acquire(Self.fdsPerConnection) { return nil }
        let box = ResolveBox()
        let resolver = self.resolver
        let budget = self.budget
        let started = Self.startThread(name: "brahma-egress-resolve") {
            box.finish(resolver(host))
            budget?.release(Self.fdsPerConnection)
        }
        guard started else { budget?.release(Self.fdsPerConnection); return nil }
        return box.wait(until: deadline)
    }

    private final class ResolveBox: @unchecked Sendable {
        private let sem = DispatchSemaphore(value: 0)
        private let lock = NSLock()
        private var result: [sockaddr_storage]??
        func finish(_ value: [sockaddr_storage]?) { lock.withLock { result = .some(value) }; sem.signal() }
        func wait(until deadline: SuspendingClock.Instant) -> [sockaddr_storage]? {
            while AwakeTime.now < deadline {
                if sem.wait(timeout: .now() + 0.1) == .success { return lock.withLock { result ?? nil } }
            }
            return nil
        }
    }

    private static func find(_ needle: [UInt8], in hay: [UInt8]) -> Int? {
        guard hay.count >= needle.count else { return nil }
        for i in 0...(hay.count - needle.count) where hay[i] == needle[0] && Array(hay[i..<(i + needle.count)]) == needle { return i }
        return nil
    }

    /// One poll slice (at most a second) for `events` on `fd`; true when it is ready.
    private static func waitFor(_ fd: Int32, _ events: Int32) -> Bool {
        var pfd = pollfd(fd: fd, events: Int16(events), revents: 0)
        let r = poll(&pfd, 1, 1000)
        return r > 0
    }

    /// Connects to the first vetted address that answers before `deadline`; nil when none does.
    private func dial(_ addresses: [sockaddr_storage], deadline: SuspendingClock.Instant) -> Int32? {
        for var address in addresses {
            guard !isStopped, AwakeTime.now < deadline else { return nil }
            let family = Int32(address.ss_family)
            let length: socklen_t
            switch family {
            case AF_INET:
                length = socklen_t(MemoryLayout<sockaddr_in>.size)
                withUnsafeMutableBytes(of: &address) { $0.baseAddress!.assumingMemoryBound(to: sockaddr_in.self).pointee.sin_port = dialPort.bigEndian }
            case AF_INET6:
                length = socklen_t(MemoryLayout<sockaddr_in6>.size)
                withUnsafeMutableBytes(of: &address) { $0.baseAddress!.assumingMemoryBound(to: sockaddr_in6.self).pointee.sin6_port = dialPort.bigEndian }
            default: continue
            }
            let fd = socket(family, Self.streamType, 0)
            guard fd >= 0 else { continue }
            _ = fcntl(fd, F_SETFD, FD_CLOEXEC)
            Self.noSigPipe(fd)
            Self.setNonBlocking(fd)
            let r = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, length) } }
            if r == 0 { return fd }
            guard errno == EINPROGRESS || errno == EINTR else { close(fd); continue }
            var connected = false
            while !isStopped, AwakeTime.now < deadline {
                var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&pfd, 1, 250)
                if ready < 0 && errno != EINTR { break }
                if ready <= 0 { continue }
                var err: Int32 = 0
                var len = socklen_t(MemoryLayout<Int32>.size)
                getsockopt(fd, SOL_SOCKET, SO_ERROR, &err, &len)
                connected = err == 0
                break
            }
            if connected { return fd }
            close(fd)
        }
        return nil
    }

    /// Writes all of `bytes`, waiting in poll slices; false when the peer is gone or nothing could be written for `idle`.
    private func writeAll(_ fd: Int32, _ bytes: [UInt8], idle: Duration) -> Bool {
        var offset = 0
        var deadline = AwakeTime.deadline(after: idle)
        while offset < bytes.count {
            let n = bytes[offset...].withUnsafeBytes { write(fd, $0.baseAddress, $0.count) }
            if n > 0 { offset += n; deadline = AwakeTime.deadline(after: idle); continue }
            if n < 0 && errno != EAGAIN && errno != EINTR { return false }
            guard !isStopped, AwakeTime.now < deadline else { return false }
            _ = Self.waitFor(fd, POLLOUT)
        }
        return true
    }

    /// Copies bytes both ways until both directions have ended, the proxy stops, or nothing moves for `idleTimeout`. When
    /// one side ends its sending, the other side's sending half is shut down (TLS close is clean).
    private func pipeBoth(_ a: Int32, _ b: Int32) {
        var aOpen = true, bOpen = true
        var deadline = AwakeTime.deadline(after: Self.idleTimeout)
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while (aOpen || bOpen) && !isStopped && AwakeTime.now < deadline {
            var fds = [pollfd(fd: aOpen ? a : -1, events: Int16(POLLIN), revents: 0),
                       pollfd(fd: bOpen ? b : -1, events: Int16(POLLIN), revents: 0)]
            let ready = poll(&fds, 2, 1000)
            if ready < 0 { if errno == EINTR { continue }; return }
            if ready == 0 { continue }
            for (i, (from, to)) in [(a, b), (b, a)].enumerated() where fds[i].revents != 0 {
                let n = read(from, &buffer, buffer.count)
                if n > 0 {
                    guard writeAll(to, Array(buffer[0..<n]), idle: Self.idleTimeout) else { return }
                    deadline = AwakeTime.deadline(after: Self.idleTimeout)
                } else if n == 0 || (errno != EAGAIN && errno != EINTR) {
                    if i == 0 { aOpen = false } else { bOpen = false }
                    shutdown(to, Int32(SHUT_WR))
                }
            }
        }
    }

    // MARK: Plumbing

    #if canImport(Darwin)
    private static let streamType = SOCK_STREAM
    #else
    private static let streamType = Int32(SOCK_STREAM.rawValue)
    #endif

    private static func setNonBlocking(_ fd: Int32) {
        let flags = fcntl(fd, F_GETFL)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)
    }

    /// A write to a closed peer returns EPIPE instead of killing the process with SIGPIPE.
    private static func noSigPipe(_ fd: Int32) {
        #if canImport(Darwin)
        var one: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
    }

    /// `getaddrinfo` once, every address it returns (port left to the dialler); nil when the name does not resolve.
    static let systemResolve: Resolver = { host in
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        hints.ai_socktype = streamType
        hints.ai_flags = AI_ADDRCONFIG
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, nil, &hints, &res) == 0 else { return nil }
        defer { freeaddrinfo(res) }
        var out: [sockaddr_storage] = []
        var cursor = res
        while let info = cursor {
            if let addr = info.pointee.ai_addr, Int(info.pointee.ai_addrlen) <= MemoryLayout<sockaddr_storage>.size {
                var storage = sockaddr_storage()
                withUnsafeMutableBytes(of: &storage) { dst in
                    dst.copyMemory(from: UnsafeRawBufferPointer(start: addr, count: Int(info.pointee.ai_addrlen)))
                }
                out.append(storage)
            }
            cursor = info.pointee.ai_next
        }
        return out
    }
}

/// One proxy per distinct allow-list (normalized, deduped, sorted), started on first use and kept until `stopAll`. Every
/// proxy it hands out shares one connection budget, so all of them together can never hold more than `globalLimit`
/// connections open at once (A-I2).
public actor EgressProxyPool {
    /// The shared descriptor ceiling across every proxy of one pool: a quarter of the process's open-file soft limit (which
    /// the engine raises at start), floored at 256 and capped at 2048, so the proxies' sockets can never starve the engine's
    /// own database, git and log descriptors (A-I2). At 2 fds per connection this is 128–1024 connections across all proxies.
    public static var descriptorBudget: Int { min(2048, max(256, FileLimit.current / 4)) }
    private nonisolated let proxies: Proxies

    public init() { proxies = Proxies(budget: EgressProxy.Budget(limit: EgressProxyPool.descriptorBudget)) }

    public func proxy(for allow: [String]) throws -> EgressProxy { try proxies.proxy(for: allow) }

    public func stopAll() { proxies.stopAll() }

    /// `proxy(for:)` for synchronous callers (`SeatbeltRunner.spawn`).
    nonisolated func proxyNow(for allow: [String]) throws -> EgressProxy { try proxies.proxy(for: allow) }

    private final class Proxies: @unchecked Sendable {
        private let lock = NSLock()
        private var proxies: [String: EgressProxy] = [:]
        private let budget: EgressProxy.Budget
        init(budget: EgressProxy.Budget) { self.budget = budget }

        func proxy(for allow: [String]) throws -> EgressProxy {
            let list = Array(Set(allow.map(DomainMatcher.normalize))).sorted()
            let key = list.joined(separator: "\n")
            return try lock.withLock {
                if let existing = proxies[key] { return existing }
                let made = try EgressProxy(allow: list, resolver: EgressProxy.systemResolve, budget: budget)
                proxies[key] = made
                return made
            }
        }

        func stopAll() {
            let all = lock.withLock { () -> [EgressProxy] in
                defer { proxies = [:] }
                return Array(proxies.values)
            }
            for p in all { p.stop() }
        }
    }
}
