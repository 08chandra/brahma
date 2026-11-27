import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum LoopbackListenerError: Error, Equatable, Sendable, CustomStringConvertible {
    /// A socket call failed while setting the listener up (`step` names it); nothing is left open.
    case setup(step: String, errno: Int32)
    /// `accept` failed (`EAGAIN` when nothing was pending on a non-blocking listener).
    case accept(errno: Int32)
    /// A peer that is not 127.0.0.1 connected; its socket was closed unread.
    case peerNotLoopback

    public var description: String {
        switch self {
        case .setup(let step, let code): "the gateway listener could not \(step) (errno \(code))"
        case .accept(let code): "the gateway listener could not accept a connection (errno \(code))"
        case .peerNotLoopback: "a connection from outside 127.0.0.1 was refused"
        }
    }
}

/// The gateway's listening socket (Plan X1 Task 7; the plan's `BrahmaSafety/Net`, Ruling 1): IPv4 `127.0.0.1` on an ephemeral
/// port, never another address; `SO_REUSEADDR` off; close-on-exec, so no child process inherits it. Same raw-socket pattern as
/// `EgressProxy.init`.
public enum LoopbackListener {
    /// The only address the gateway ever binds (pinned).
    public static let bindAddress = "127.0.0.1"
    static let loopbackHostOrder: UInt32 = 0x7f00_0001

    /// A listening socket on `127.0.0.1:<ephemeral>`. The caller owns `fd` (blocking mode; close it to stop listening).
    public static func listen(backlog: Int32 = 64) throws(LoopbackListenerError) -> (fd: Int32, port: UInt16) {
        let fd = socket(AF_INET, streamType, 0)
        guard fd >= 0 else { throw .setup(step: "create a socket", errno: errno) }
        func fail(_ step: String) -> LoopbackListenerError {
            let code = errno
            _ = closeSocket(fd)
            return .setup(step: step, errno: code)
        }
        guard fcntl(fd, F_SETFD, FD_CLOEXEC) == 0 else { throw fail("set close-on-exec") }
        var off: Int32 = 0
        guard setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &off, socklen_t(MemoryLayout<Int32>.size)) == 0 else {
            throw fail("turn SO_REUSEADDR off")
        }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = loopbackHostOrder.bigEndian
        let bound = withUnsafePointer(to: &addr) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0 else { throw fail("bind 127.0.0.1") }
        guard systemListen(fd, backlog) == 0 else { throw fail("listen") }
        // Read back what the kernel bound: it must be 127.0.0.1 and a real port.
        var named = sockaddr_in()
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let got = withUnsafeMutablePointer(to: &named) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &len) } }
        guard got == 0 else { throw fail("read its bound address") }
        let port = UInt16(bigEndian: named.sin_port)
        guard Int32(named.sin_family) == AF_INET, UInt32(bigEndian: named.sin_addr.s_addr) == loopbackHostOrder, port != 0 else {
            _ = closeSocket(fd)
            throw .setup(step: "bind 127.0.0.1 (the kernel bound another address)", errno: 0)
        }
        return (fd, port)
    }

    /// Accepts one connection: close-on-exec, and only from 127.0.0.1 (any other peer is closed and refused).
    public static func accept(_ fd: Int32) throws(LoopbackListenerError) -> Int32 {
        var peer = sockaddr_storage()
        var len = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let client = withUnsafeMutablePointer(to: &peer) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { systemAccept(fd, $0, &len) } }
        guard client >= 0 else { throw .accept(errno: errno) }
        guard fcntl(client, F_SETFD, FD_CLOEXEC) == 0 else {
            let code = errno
            _ = closeSocket(client)
            throw .accept(errno: code)
        }
        guard isLoopbackPeer(peer) else {
            _ = closeSocket(client)
            throw .peerNotLoopback
        }
        return client
    }

    /// Whether a peer address is exactly IPv4 127.0.0.1 (not the rest of 127/8, not `::1`: the listener is IPv4 only).
    static func isLoopbackPeer(_ peer: sockaddr_storage) -> Bool {
        guard Int32(peer.ss_family) == AF_INET else { return false }
        var copy = peer
        let address = withUnsafePointer(to: &copy) { $0.withMemoryRebound(to: sockaddr_in.self, capacity: 1) { $0.pointee.sin_addr.s_addr } }
        return UInt32(bigEndian: address) == loopbackHostOrder
    }

    #if canImport(Darwin)
    static let streamType = SOCK_STREAM
    #else
    static let streamType = Int32(SOCK_STREAM.rawValue)
    #endif
}

// The C calls whose names `LoopbackListener`'s own members shadow inside the enum.
private func systemListen(_ fd: Int32, _ backlog: Int32) -> Int32 { listen(fd, backlog) }
private func systemAccept(_ fd: Int32, _ addr: UnsafeMutablePointer<sockaddr>, _ len: UnsafeMutablePointer<socklen_t>) -> Int32 {
    accept(fd, addr, len)
}
func closeSocket(_ fd: Int32) -> Int32 { close(fd) }
