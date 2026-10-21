import Foundation

/// `<home>/owner.key`: 32 random bytes, hex, mode 0600. Owner-write CLI commands refuse to run without it.
/// It is created by the app launch, `brahma run` and `brahma company create`, so it always predates any agent.
/// Defense in depth only: until the 5-lite sandbox read-denies the data home to agents, an agent that can read the
/// file can satisfy the check.
public enum OwnerKey {
    public static func url(paths: BrahmaPaths) -> URL { paths.home.appending(path: "owner.key") }

    @discardableResult
    public static func ensure(paths: BrahmaPaths) throws -> URL {
        let file = url(paths: paths)
        try FileManager.default.createDirectory(at: paths.home, withIntermediateDirectories: true)
        let fd = open(file.path, O_CREAT | O_EXCL | O_WRONLY, 0o600)
        if fd < 0 {
            if errno == EEXIST { return file }
            throw CocoaError(.fileWriteUnknown)
        }
        defer { close(fd) }
        let bytes = (0..<32).map { _ in UInt8.random(in: 0...255) }
        let hex = bytes.map { String(format: "%02x", $0) }.joined()
        let data = Array((hex + "\n").utf8)
        guard write(fd, data, data.count) == data.count else { throw CocoaError(.fileWriteUnknown) }
        return file
    }

    public static func isReadable(paths: BrahmaPaths) -> Bool {
        let path = url(paths: paths).path
        return FileManager.default.fileExists(atPath: path) && FileManager.default.isReadableFile(atPath: path)
    }
}
