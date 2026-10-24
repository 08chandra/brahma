import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import BrahmaCore

/// The egress proxy (CONNECT only, port 443, allow-list, public addresses only, one resolution) and its matchers.
@Suite struct EgressProxyTests {
    // MARK: DomainMatcher

    @Test func domainMatcherTable() {
        let allow = ["example.com", "*.stripe.com", "Registry.NPMjs.org."]
        let cases: [(String, Bool)] = [
            ("example.com", true), ("EXAMPLE.com", true), ("example.com.", true),
            ("www.example.com", false),            // exact entries do not cover subdomains
            ("api.stripe.com", true), ("a.b.stripe.com", true), ("API.Stripe.Com.", true),
            ("stripe.com", false),                 // a wildcard covers subdomains only
            ("evilstripe.com", false), ("stripe.com.evil.net", false),
            ("registry.npmjs.org", true),
            ("127.0.0.1", false), ("::1", false), ("[::1]", false), ("10.0.0.1", false),
            ("", false), (".", false), ("example..com", false), ("exa mple.com", false), ("example.com:443", false),
        ]
        for (host, expected) in cases {
            #expect(DomainMatcher.matches(host: host, allow: allow) == expected, "\(host)")
        }
        // An IP literal never matches, even listed verbatim; neither does an Anthropic host.
        #expect(!DomainMatcher.matches(host: "1.2.3.4", allow: ["1.2.3.4"]))
        #expect(!DomainMatcher.matches(host: "api.anthropic.com", allow: ["api.anthropic.com"]))
        #expect(!DomainMatcher.matches(host: "x.claude.ai", allow: ["*.claude.ai"]))
        #expect(!DomainMatcher.matches(host: "example.com", allow: []))
    }

    @Test func validPatterns() {
        for bad in ["*.github.io", "*.com", "*.co.uk", "*", "*.", "localhost", "*.localhost", "a.localhost", "127.0.0.1", "10.1.2.3",
                    "*.io", "*.amazonaws.com", "*.s3.amazonaws.com", "*.vercel.app", "*.example", "example", "-a.com", "a-.com",
                    "a..com", "exa mple.com", "ex_ample.com", "*.*.example.com", "http://example.com", "example.com/x", "::1", ""] {
            #expect(!DomainMatcher.isValidPattern(bad), "\(bad) should be refused")
        }
        for good in ["*.stripe.com", "example.com", "registry.npmjs.org", "EXAMPLE.COM", "example.com.", "a-b.example.co.uk",
                     "*.example.co.uk", "*.myapp.vercel.app"] {
            #expect(DomainMatcher.isValidPattern(good), "\(good) should be accepted")
        }
        // The pinned list (the brief's exact set).
        #expect(DomainMatcher.publicSuffixes.count == 36)
        #expect(DomainMatcher.publicSuffixes.contains("ngrok-free.app") && DomainMatcher.publicSuffixes.contains("blob.core.windows.net"))
    }

    @Test func storeUpdateSandboxUsesDomainMatcher() throws {
        let store = try Store.inMemory()
        let ws = try tempDir()
        let company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: ws)
        let home = try tempDir()
        #expect(throws: SandboxError.invalidDomain("*.github.io")) {
            try store.updateSandbox(companyId: company.id, SandboxPatch(allowedDomains: ["*.github.io"]), userHome: home)
        }
        #expect(throws: SandboxError.forbiddenDomain("api.anthropic.com")) {
            try store.updateSandbox(companyId: company.id, SandboxPatch(allowedDomains: ["api.anthropic.com"]), userHome: home)
        }
        try store.updateSandbox(companyId: company.id, SandboxPatch(allowedDomains: ["*.Stripe.com", "example.com."]), userHome: home)
        #expect(try store.company(id: company.id)?.allowedDomains == ["*.stripe.com", "example.com"])
    }

    // MARK: AddressPolicy

    private static func v4(_ s: String) -> sockaddr_storage {
        var storage = sockaddr_storage()
        withUnsafeMutableBytes(of: &storage) { raw in
            let sin = raw.baseAddress!.assumingMemoryBound(to: sockaddr_in.self)
            sin.pointee.sin_family = sa_family_t(AF_INET)
            _ = inet_pton(AF_INET, s, &sin.pointee.sin_addr)
        }
        return storage
    }

    private static func v6(_ s: String) -> sockaddr_storage {
        var storage = sockaddr_storage()
        withUnsafeMutableBytes(of: &storage) { raw in
            let sin6 = raw.baseAddress!.assumingMemoryBound(to: sockaddr_in6.self)
            sin6.pointee.sin6_family = sa_family_t(AF_INET6)
            _ = inet_pton(AF_INET6, s, &sin6.pointee.sin6_addr)
        }
        return storage
    }

    @Test func addressPolicyTable() {
        let refusedV4 = ["0.0.0.0", "0.1.2.3", "10.0.0.1", "10.255.255.255", "100.64.0.1", "100.127.255.254", "127.0.0.1", "127.8.9.10",
                         "169.254.169.254", "169.254.0.1", "172.16.0.1", "172.31.255.255", "192.0.0.8", "192.168.1.1", "198.18.0.1",
                         "198.19.255.255", "224.0.0.1", "239.255.255.250", "255.255.255.255", "240.0.0.1"]
        for a in refusedV4 { #expect(!AddressPolicy.isPublic(Self.v4(a)), "\(a) must be refused") }
        let publicV4 = ["93.184.215.14", "1.1.1.1", "8.8.8.8", "100.63.255.255", "100.128.0.1", "172.15.255.255", "172.32.0.1",
                        "192.0.1.1", "192.169.0.1", "198.17.255.255", "198.20.0.1", "11.0.0.1", "169.253.0.1"]
        for a in publicV4 { #expect(AddressPolicy.isPublic(Self.v4(a)), "\(a) is public") }

        let refusedV6 = ["::", "::1", "fc00::1", "fd12:3456::1", "fe80::1", "febf::1", "ff02::1", "ff0e::1", "::ffff:10.0.0.1",
                         "::ffff:127.0.0.1", "::ffff:169.254.169.254", "::ffff:192.168.0.1", "::127.0.0.1", "64:ff9b::a00:1",
                         "2002:a00:1::1", "2001:db8::1"]
        for a in refusedV6 { #expect(!AddressPolicy.isPublic(Self.v6(a)), "\(a) must be refused") }
        let publicV6 = ["2606:2800:220:1:248:1893:25c8:1946", "2a00:1450:4001::1", "::ffff:93.184.215.14", "2001:4860:4860::8888"]
        for a in publicV6 { #expect(AddressPolicy.isPublic(Self.v6(a)), "\(a) is public") }
        // Not an address family the proxy knows.
        #expect(!AddressPolicy.isPublic(sockaddr_storage()))
    }

    // MARK: The proxy

    /// Sends `request` to the proxy and returns what it answers first (up to the end of the headers or the connection).
    private static func ask(_ port: UInt16, _ request: String) throws -> String {
        let fd = socket(AF_INET, Int32(SOCK_STREAM), 0)
        #expect(fd >= 0)
        defer { close(fd) }
        var tv = timeval(tv_sec: 20, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = port.bigEndian
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let ok = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard ok == 0 else { throw POSIXError(.ECONNREFUSED) }
        _ = request.withCString { write(fd, $0, strlen($0)) }
        var got = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while !String(decoding: got, as: UTF8.self).contains("\r\n\r\n") {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            got += buffer[0..<n]
        }
        return String(decoding: got, as: UTF8.self)
    }

    private static func resolves(_ host: String) -> Bool {
        var hints = addrinfo()
        hints.ai_socktype = Int32(SOCK_STREAM)
        var res: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo(host, "443", &hints, &res) == 0 else { return false }
        freeaddrinfo(res)
        return true
    }

    @Test func privateAddressRefused() throws {
        // Deterministic first: whatever the allowed name resolves to, a private address is never dialled.
        for address in ["127.0.0.1", "169.254.169.254", "10.0.0.1"] {
            let fake = try EgressProxy(allow: ["internal.example.com"], resolver: { _ in [Self.v4(address)] })
            defer { fake.stop() }
            let reply = try Self.ask(fake.port, "CONNECT internal.example.com:443 HTTP/1.1\r\nHost: internal.example.com:443\r\n\r\n")
            #expect(reply.hasPrefix("HTTP/1.1 403"), "\(address): \(reply)")
            #expect(fake.deniedHosts == ["internal.example.com"])
        }
        // One public and one private answer: refused (every address must pass).
        let mixed = try EgressProxy(allow: ["mixed.example.com"], resolver: { _ in [Self.v4("93.184.215.14"), Self.v6("::ffff:10.0.0.1")] })
        defer { mixed.stop() }
        #expect(try Self.ask(mixed.port, "CONNECT mixed.example.com:443 HTTP/1.1\r\n\r\n").hasPrefix("HTTP/1.1 403"))
        // A name that does not resolve is refused too.
        let nothing = try EgressProxy(allow: ["gone.example.com"], resolver: { _ in nil })
        defer { nothing.stop() }
        #expect(try Self.ask(nothing.port, "CONNECT gone.example.com:443 HTTP/1.1\r\n\r\n").hasPrefix("HTTP/1.1 403"))

        // Then real DNS: localtest.me resolves to 127.0.0.1.
        guard Self.resolves("localtest.me") else { return }   // DNS unavailable: the deterministic part above stands
        let proxy = try EgressProxy(allow: ["localtest.me"])
        defer { proxy.stop() }
        let reply = try Self.ask(proxy.port, "CONNECT localtest.me:443 HTTP/1.1\r\nHost: localtest.me:443\r\n\r\n")
        #expect(reply.hasPrefix("HTTP/1.1 403"), "\(reply)")
        #expect(proxy.deniedHosts.contains("localtest.me"))
    }

    @Test func nonTLSPortRefused() throws {
        let proxy = try EgressProxy(allow: ["example.com"])
        defer { proxy.stop() }
        #expect(try Self.ask(proxy.port, "CONNECT example.com:80 HTTP/1.1\r\nHost: example.com:80\r\n\r\n").hasPrefix("HTTP/1.1 403"))
        #expect(try Self.ask(proxy.port, "CONNECT example.com:22 HTTP/1.1\r\n\r\n").hasPrefix("HTTP/1.1 403"))
        #expect(try Self.ask(proxy.port, "CONNECT example.com HTTP/1.1\r\n\r\n").hasPrefix("HTTP/1.1 403"))
        // Not allowed at all.
        #expect(try Self.ask(proxy.port, "CONNECT evil.example.net:443 HTTP/1.1\r\n\r\n").hasPrefix("HTTP/1.1 403"))
        // IP literals never match.
        #expect(try Self.ask(proxy.port, "CONNECT 93.184.215.14:443 HTTP/1.1\r\n\r\n").hasPrefix("HTTP/1.1 403"))
        #expect(try Self.ask(proxy.port, "CONNECT [::1]:443 HTTP/1.1\r\n\r\n").hasPrefix("HTTP/1.1 403"))
        #expect(proxy.deniedHosts.contains("example.com")); #expect(proxy.deniedHosts.contains("evil.example.net"))
        #expect(EgressProxy.allowedPort == 443)
        #expect(EgressProxy.connectTimeout == .seconds(10)); #expect(EgressProxy.idleTimeout == .seconds(300))
    }

    @Test func nonConnectGets405() throws {
        let proxy = try EgressProxy(allow: ["example.com"])
        defer { proxy.stop() }
        #expect(try Self.ask(proxy.port, "GET http://example.com/ HTTP/1.1\r\nHost: example.com\r\n\r\n").hasPrefix("HTTP/1.1 405"))
        #expect(try Self.ask(proxy.port, "POST / HTTP/1.1\r\n\r\n").hasPrefix("HTTP/1.1 405"))
        // Garbage is refused, not passed on.
        #expect(try Self.ask(proxy.port, "\r\n\r\n").hasPrefix("HTTP/1.1 4"))
        // It listens on loopback only.
        #expect(proxy.port > 0)
    }

    /// A vetted CONNECT is answered `200` and the bytes flow both ways (an echo server on loopback stands in for a public
    /// host: the address check is swapped for this test only).
    @Test func allowedConnectPipesBytes() throws {
        let server = socket(AF_INET, Int32(SOCK_STREAM), 0)
        defer { close(server) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(server, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        listen(server, 4)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(server, $0, &len) } }
        let echoPort = UInt16(bigEndian: addr.sin_port)
        Thread.detachNewThread {
            let c = accept(server, nil, nil)
            guard c >= 0 else { return }
            var buffer = [UInt8](repeating: 0, count: 1024)
            let n = read(c, &buffer, buffer.count)
            if n > 0 { _ = write(c, buffer, n) }
            close(c)
        }
        var target = sockaddr_storage()
        withUnsafeMutableBytes(of: &target) { raw in
            let sin = raw.baseAddress!.assumingMemoryBound(to: sockaddr_in.self)
            sin.pointee.sin_family = sa_family_t(AF_INET)
            sin.pointee.sin_addr.s_addr = inet_addr("127.0.0.1")
        }
        let vetted = target
        let proxy = try EgressProxy(allow: ["echo.example.com"], resolver: { _ in [vetted] }, vet: { _ in true }, dialPort: echoPort)
        defer { proxy.stop() }

        let fd = socket(AF_INET, Int32(SOCK_STREAM), 0)
        defer { close(fd) }
        var tv = timeval(tv_sec: 10, tv_usec: 0)
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        var p = sockaddr_in()
        p.sin_family = sa_family_t(AF_INET); p.sin_port = proxy.port.bigEndian; p.sin_addr.s_addr = inet_addr("127.0.0.1")
        _ = withUnsafePointer(to: &p) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        // The first payload rides along with the request, as TLS clients do.
        let request = "CONNECT echo.example.com:443 HTTP/1.1\r\nHost: echo.example.com:443\r\n\r\nPING-42"
        _ = request.withCString { write(fd, $0, strlen($0)) }
        var got = [UInt8]()
        var buffer = [UInt8](repeating: 0, count: 1024)
        while !String(decoding: got, as: UTF8.self).contains("PING-42") {
            let n = read(fd, &buffer, buffer.count)
            if n <= 0 { break }
            got += buffer[0..<n]
        }
        let text = String(decoding: got, as: UTF8.self)
        #expect(text.hasPrefix("HTTP/1.1 200 Connection established\r\n\r\n"), "\(text)")
        #expect(text.hasSuffix("PING-42"))
        #expect(proxy.deniedHosts.isEmpty)
    }

    @Test func poolSharesOneProxyPerAllowList() async throws {
        let pool = EgressProxyPool()
        let a = try await pool.proxy(for: ["b.example.com", "a.example.com"])
        let b = try await pool.proxy(for: ["A.example.com", "b.example.com."])
        let c = try await pool.proxy(for: ["c.example.com"])
        #expect(a === b); #expect(a !== c); #expect(a.port != c.port)
        await pool.stopAll()
        #expect(throws: (any Error).self) { try Self.ask(a.port, "CONNECT a.example.com:443 HTTP/1.1\r\n\r\n") }
    }
}
