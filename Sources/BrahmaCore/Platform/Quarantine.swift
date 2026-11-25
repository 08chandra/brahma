import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// macOS's download mark (`com.apple.quarantine`): a dropped file that carries it came from outside (`DropTrust`). Off
/// Darwin nothing is ever quarantined.
///
/// The check fails closed: only "no such attribute" (`ENOATTR`) and "attributes not supported here" (`ENOTSUP`) mean not
/// quarantined. Any other error (the attribute could not be read) counts as quarantined, so the drop defaults to untrusted.
public enum Quarantine {
    public static let attribute = "com.apple.quarantine"

    /// Whether the file (never followed if it is a link) carries the quarantine attribute.
    public static func isQuarantined(_ url: URL) -> Bool {
        #if canImport(Darwin)
        let rc = getxattr(url.path, attribute, nil, 0, 0, XATTR_NOFOLLOW)
        return interpret(rc: rc, errno: errno)
        #else
        return false
        #endif
    }

    /// Whether the open file carries the quarantine attribute (the descriptor the drop was inspected through).
    public static func isQuarantined(fd: Int32) -> Bool {
        #if canImport(Darwin)
        let rc = fgetxattr(fd, attribute, nil, 0, 0, 0)
        return interpret(rc: rc, errno: errno)
        #else
        return false
        #endif
    }

    /// Plan C Task C5: marks a file the owner exported (`Store.exportRef`) as downloaded, so Gatekeeper and the apps that
    /// honour the mark treat it as coming from outside: `0081;<unix time, hex>;Brahma;` on the file itself (never a link it
    /// may be). Throws when the mark can't be set (the caller then keeps no unmarked copy). Off Darwin there is no such mark:
    /// a no-op.
    public static func mark(_ url: URL) throws {
        #if canImport(Darwin)
        let value = "0081;\(String(UInt64(max(0, Date().timeIntervalSince1970)), radix: 16));Brahma;"
        let rc = value.withCString { setxattr(url.path, attribute, $0, strlen($0), 0, XATTR_NOFOLLOW) }
        guard rc == 0 else {
            throw QuarantineMarkError(errno: errno)
        }
        #endif
    }

    /// `mark`, on an open file's descriptor (C5 fix round 1: an export marks the file it wrote, never a path that may since
    /// name another).
    public static func mark(fd: Int32) throws {
        #if canImport(Darwin)
        let value = "0081;\(String(UInt64(max(0, Date().timeIntervalSince1970)), radix: 16));Brahma;"
        let rc = value.withCString { fsetxattr(fd, attribute, $0, strlen($0), 0, 0) }
        guard rc == 0 else { throw QuarantineMarkError(errno: errno) }
        #endif
    }

    #if canImport(Darwin)
    /// What a `getxattr` result means: present (rc ≥ 0), absent (`ENOATTR`, `ENOTSUP`), or unknown, which is quarantined.
    static func interpret(rc: Int, errno err: Int32) -> Bool {
        if rc >= 0 { return true }
        return err != ENOATTR && err != ENOTSUP
    }
    #endif
}

/// `Quarantine.mark` could not set the mark (the `setxattr` errno).
public struct QuarantineMarkError: Error, Equatable, Sendable, CustomStringConvertible {
    public let errno: Int32
    public var description: String { "the download mark could not be set (errno \(errno))" }
}
