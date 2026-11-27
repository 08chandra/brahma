import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// The settings file: `<runDir>/<agentId>.settings.json`, written atomically at 0600 (a temporary file created `O_EXCL` 0600
/// and renamed over the target, so a link planted there is replaced, never followed). The run directory is the data home's,
/// which no turn can read or write.
public enum SettingsFile {
    public static func write(_ text: String, to url: URL) throws {
        try writePrivate(Data(text.utf8), to: url)
    }

    /// `data` to `url` atomically at 0600; its directory is created 0700 when missing.
    public static func writePrivate(_ data: Data, to url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        let temp = dir.appending(path: ".\(url.lastPathComponent).\(UUID().uuidString)")
        let fd = open(temp.path, O_CREAT | O_EXCL | O_WRONLY | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard fd >= 0 else { throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: temp.path]) }
        let bytes = [UInt8](data)
        var written = 0
        while written < bytes.count {
            let n = bytes[written...].withUnsafeBytes { Foundation.write(fd, $0.baseAddress, $0.count) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else { break }
            written += n
        }
        let synced = fsync(fd) == 0
        close(fd)
        guard written == bytes.count, synced, rename(temp.path, url.path) == 0 else {
            unlink(temp.path)
            throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: url.path])
        }
    }
}
