import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

public enum CompressorError: Error, Equatable, CustomStringConvertible {
    case failed(String)
    public var description: String {
        switch self { case .failed(let text): text }
    }
}

/// zstd (when installed) or gzip, reached through `Process`. Input and output go through files in a work directory, never
/// pipes, so a tool that stops reading can not deadlock the caller; the wait is bounded in awake time.
public enum Compressor: Sendable, Equatable {
    case zstd(path: String)
    case gzip

    /// Awake seconds a compression tool may take before it is killed.
    static let timeout: TimeInterval = 120

    public var fileExtension: String {
        switch self { case .zstd: "zst"; case .gzip: "gz" }
    }

    /// The codec name stored with a capture.
    public var codec: String { fileExtension }

    static let zstdCandidates = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd", "/usr/bin/zstd", "/usr/local/opt/zstd/bin/zstd"]

    /// The first executable zstd among the usual places and `PATH`.
    public static func findZstd(environment: [String: String] = ProcessInfo.processInfo.environment) -> String? {
        let onPath = (environment["PATH"] ?? "").split(separator: ":").map { "\($0)/zstd" }
        return (zstdCandidates + onPath).first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    public static func zstdOrGzip(zstdPath: String?) -> Compressor {
        zstdPath.map { .zstd(path: $0) } ?? .gzip
    }

    /// zstd when it is installed, otherwise gzip.
    public static var platformDefault: Compressor { zstdOrGzip(zstdPath: findZstd()) }

    /// The compressor that reads a stored file of `codec` (`zst` needs the tool installed).
    public static func forCodec(_ codec: String) throws -> Compressor {
        switch codec {
        case "gz": return .gzip
        case "zst":
            guard let path = findZstd() else { throw CompressorError.failed("zstd is not installed; it is needed to read this transcript") }
            return .zstd(path: path)
        default: throw CompressorError.failed("unknown transcript codec '\(codec)'")
        }
    }

    public func compress(_ data: Data, workDir: URL) throws -> Data {
        switch self {
        case .zstd(let path): try Self.run(path, ["-q", "-c", "-3"], input: data, workDir: workDir)
        case .gzip: try Self.run("/usr/bin/gzip", ["-c", "-n"], input: data, workDir: workDir)
        }
    }

    public func decompress(_ data: Data, workDir: URL) throws -> Data {
        switch self {
        case .zstd(let path): try Self.run(path, ["-q", "-d", "-c"], input: data, workDir: workDir)
        case .gzip: try Self.run("/usr/bin/gzip", ["-d", "-c"], input: data, workDir: workDir)
        }
    }

    private static func run(_ tool: String, _ arguments: [String], input: Data, workDir: URL) throws -> Data {
        guard FileManager.default.isExecutableFile(atPath: tool) else { throw CompressorError.failed("\(tool) is not available") }
        try BrahmaPaths.ensurePrivateDirectory(workDir)
        let id = UUID().uuidString
        let inURL = workDir.appending(path: ".compress-\(id).in"), outURL = workDir.appending(path: ".compress-\(id).out")
        defer { unlink(inURL.path); unlink(outURL.path) }
        guard FileManager.default.createFile(atPath: inURL.path, contents: input, attributes: [.posixPermissions: 0o600]),
              FileManager.default.createFile(atPath: outURL.path, contents: nil, attributes: [.posixPermissions: 0o600]) else {
            throw CompressorError.failed("could not stage \(tool)'s files in \(workDir.path)")
        }
        let reader = try FileHandle(forReadingFrom: inURL), writer = try FileHandle(forWritingTo: outURL)
        defer { try? reader.close(); try? writer.close() }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardInput = reader
        process.standardOutput = writer
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { throw CompressorError.failed("could not start \(tool): \(error)") }
        // Bounded in awake time (AwakeTime): a tool that hangs is terminated, then killed.
        let deadline = AwakeTime.uptime() + timeout
        var killAt: TimeInterval?
        while process.isRunning {
            let now = AwakeTime.uptime()
            if killAt == nil, now >= deadline { process.terminate(); killAt = now + 1 }
            if let k = killAt, now >= k { kill(process.processIdentifier, SIGKILL); break }
            usleep(2_000)
        }
        if killAt != nil { throw CompressorError.failed("\(tool) timed out") }
        guard process.terminationStatus == 0 else { throw CompressorError.failed("\(tool) exited with status \(process.terminationStatus)") }
        return try Data(contentsOf: outURL)
    }
}
