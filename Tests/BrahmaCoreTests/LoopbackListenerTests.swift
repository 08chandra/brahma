import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import BrahmaCore

/// Plan X1 Task 7: the gateway's listening socket is IPv4 loopback only, on an ephemeral port, close-on-exec, without
/// SO_REUSEADDR, and `accept` refuses any peer that is not 127.0.0.1. Local sockets only (Ruling 40: no process tier here).
@Suite(.scratch) struct LoopbackListenerTests {
    @Test func bindsLoopbackOnly() throws {
        let (fd, port) = try LoopbackListener.listen()
        defer { _ = Darwin_close(fd) }
        #expect(port > 0)
        #expect(LoopbackListener.bindAddress == "127.0.0.1")
        // The bound address is 127.0.0.1:port.
        var addr = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        #expect(named == 0)
        #expect(Int32(addr.sin_family) == AF_INET)
        #expect(UInt32(bigEndian: addr.sin_addr.s_addr) == 0x7f00_0001)
        #expect(UInt16(bigEndian: addr.sin_port) == port)
        // Close-on-exec, and SO_REUSEADDR off.
        #expect(fcntl(fd, F_GETFD) & FD_CLOEXEC != 0)
        var reuse: Int32 = -1
        var size = socklen_t(MemoryLayout<Int32>.size)
        #expect(getsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &reuse, &size) == 0 && reuse == 0)
        // A loopback client connects and is accepted (close-on-exec too).
        let client = try #require(connectLoopback(port: port))
        defer { _ = Darwin_close(client) }
        let accepted = try LoopbackListener.accept(fd)
        defer { _ = Darwin_close(accepted) }
        #expect(fcntl(accepted, F_GETFD) & FD_CLOEXEC != 0)
        // The same port on each of this machine's non-loopback IPv4 addresses refuses the connection.
        let others = Self.nonLoopbackIPv4Addresses()
        for address in others {
            #expect(connectLoopback(port: port, address: address) == nil, "\(address):\(port) must not reach the gateway")
        }
        // (A machine with no non-loopback IPv4 address has nothing to try; the bound-address check above still holds.)
    }

    @Test func acceptRefusesNonLoopbackPeers() {
        func v4(_ dotted: String) -> sockaddr_storage {
            var s = sockaddr_storage()
            withUnsafeMutablePointer(to: &s) { $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) {
                $0.pointee.sin_family = sa_family_t(AF_INET)
                $0.pointee.sin_addr.s_addr = inet_addr(dotted)
            } }
            return s
        }
        #expect(LoopbackListener.isLoopbackPeer(v4("127.0.0.1")))
        for other in ["127.0.0.2", "127.1.0.1", "10.0.0.1", "192.168.1.20", "0.0.0.0", "255.255.255.255"] {
            #expect(!LoopbackListener.isLoopbackPeer(v4(other)), "\(other)")
        }
        var v6 = sockaddr_storage()
        withUnsafeMutablePointer(to: &v6) { $0.withMemoryRebound(to: sockaddr_in6.self, capacity: 1) {
            $0.pointee.sin6_family = sa_family_t(AF_INET6)
            $0.pointee.sin6_addr = in6addr_loopback
        } }
        #expect(!LoopbackListener.isLoopbackPeer(v6), "the listener is IPv4 only; ::1 is not its peer")
        #expect(!LoopbackListener.isLoopbackPeer(sockaddr_storage()))
    }

    @Test func eachListenGetsItsOwnEphemeralPort() throws {
        let a = try LoopbackListener.listen(), b = try LoopbackListener.listen()
        defer { _ = Darwin_close(a.fd); _ = Darwin_close(b.fd) }
        #expect(a.port != b.port)
    }

    /// Every IPv4 address on an interface that is up and not loopback.
    static func nonLoopbackIPv4Addresses() -> [String] {
        var head: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&head) == 0 else { return [] }
        defer { freeifaddrs(head) }
        var out: [String] = []
        var cursor = head
        while let ifa = cursor {
            defer { cursor = ifa.pointee.ifa_next }
            guard let sa = ifa.pointee.ifa_addr, Int32(sa.pointee.sa_family) == AF_INET,
                  Int32(ifa.pointee.ifa_flags) & IFF_UP != 0, Int32(ifa.pointee.ifa_flags) & IFF_LOOPBACK == 0 else { continue }
            let addr = sa.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr }
            var buf = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
            var a = addr
            guard inet_ntop(AF_INET, &a, &buf, socklen_t(buf.count)) != nil else { continue }
            out.append(String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self))
        }
        return out
    }
}
