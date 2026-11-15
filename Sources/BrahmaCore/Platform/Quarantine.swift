import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// macOS's download mark (`com.apple.quarantine`): a dropped file that carries it came from outside (`DropTrust`). Off
/// Darwin nothing is ever quarantined.
public enum Quarantine {
    public static let attribute = "com.apple.quarantine"

    /// Whether the file (never followed if it is a link) carries the quarantine attribute.
    public static func isQuarantined(_ url: URL) -> Bool {
        #if canImport(Darwin)
        return getxattr(url.path, attribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0
        #else
        return false
        #endif
    }

    /// Whether the open file carries the quarantine attribute (the descriptor the drop was inspected through).
    public static func isQuarantined(fd: Int32) -> Bool {
        #if canImport(Darwin)
        return fgetxattr(fd, attribute, nil, 0, 0, 0) >= 0
        #else
        return false
        #endif
    }
}
