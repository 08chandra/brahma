import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Directory listing on descriptors only (no path is rebuilt), shared by `EngineFiles` and the drop walk in
/// `ResourceIntake`.
enum DirectoryListing {
    /// The names in the directory open at `fd` (without `.` and `..`), at most `limit` of them, read through a fresh
    /// descriptor of it (so `fd`'s own position and lifetime are untouched). Nil when it cannot be listed.
    static func names(fd: Int32, limit: Int = .max) -> [String]? {
        let own = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard own >= 0, let dir = fdopendir(own) else {
            if own >= 0 { close(own) }
            return nil
        }
        defer { closedir(dir) }
        var names: [String] = []
        while names.count < limit, let entry = readdir(dir) {
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name) }
        }
        return names
    }
}
