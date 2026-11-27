import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// Directory listing on descriptors only (no path is rebuilt), shared by `EngineFiles` and the drop walk in
/// `ResourceIntake`.
public enum DirectoryListing {
    /// The names in the directory open at `fd` (without `.` and `..`), at most `limit` of them, read through a fresh
    /// descriptor of it (so `fd`'s own position and lifetime are untouched). Nil when it cannot be listed, including a read
    /// error part-way (`readdir` failing is never taken for the end of the directory). With `byteLimit`
    /// the listing also stops right after the name that takes the summed UTF-8 bytes of the names past it (the caller sees
    /// the overflow and refuses; nothing past it is held).
    public static func names(fd: Int32, limit: Int = .max, byteLimit: Int = .max) -> [String]? {
        let own = openat(fd, ".", O_RDONLY | O_DIRECTORY | O_CLOEXEC)
        guard own >= 0, let dir = fdopendir(own) else {
            if own >= 0 { close(own) }
            return nil
        }
        defer { closedir(dir) }
        var names: [String] = []
        var bytes = 0
        while names.count < limit, bytes <= byteLimit {
            errno = 0
            guard let entry = readdir(dir) else {
                if errno != 0 { return nil }
                break
            }
            let name = withUnsafePointer(to: &entry.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXPATHLEN)) { String(cString: $0) }
            }
            if name != "." && name != ".." { names.append(name); bytes += name.utf8.count }
        }
        return names
    }
}
