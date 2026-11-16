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

    #if canImport(Darwin)
    /// What a `getxattr` result means: present (rc ≥ 0), absent (`ENOATTR`, `ENOTSUP`), or unknown, which is quarantined.
    static func interpret(rc: Int, errno err: Int32) -> Bool {
        if rc >= 0 { return true }
        return err != ENOATTR && err != ENOTSUP
    }
    #endif
}
