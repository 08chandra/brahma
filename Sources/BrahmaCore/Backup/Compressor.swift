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

/// zstd (when installed) or gzip, run as its own process group (`GroupExec`). Input and output go through files in a work directory, never
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

    /// zstd's usual places, searched before `PATH`.
    public static let zstdDirectories = ["/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/usr/local/opt/zstd/bin"]

    /// The first usable zstd in its usual places (`preferring`), then on the engine's `PATH`. It is found through `ToolPaths`
    /// under its rules (Ruling S5-7): a safe directory, the owner and mode rule on the file and its resolved parent, and never
    /// inside a company workspace or data home. Throws `ToolPathsError.notInstalled` before the process installed its tools
    /// (Ruling S-c1). `searchPath` replaces the engine's `PATH` (a test seam).
    public static func findZstd(searchPath: String? = nil, preferring: [String] = zstdDirectories) throws -> String? {
        try ToolPaths.engineTool(named: "zstd", path: searchPath, preferring: preferring)
    }

    public static func zstdOrGzip(zstdPath: String?) -> Compressor {
        zstdPath.map { .zstd(path: $0) } ?? .gzip
    }

    /// zstd when it is installed, otherwise gzip. Before the process installed its tools nothing is looked up, so gzip
    /// (`/usr/bin/gzip`, a fixed path).
    public static var platformDefault: Compressor {
        do { return zstdOrGzip(zstdPath: try findZstd()) } catch { return .gzip }
    }

    /// The compressor that reads a stored file of `codec` (`zst` needs the tool installed).
    public static func forCodec(_ codec: String) throws -> Compressor {
        switch codec {
        case "gz": return .gzip
        case "zst":
            let found: String?
            do { found = try findZstd() } catch { throw CompressorError.failed("zstd was not looked up: \(error)") }
            guard let path = found else { throw CompressorError.failed("zstd is not installed; it is needed to read this transcript") }
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
        let reader = open(inURL.path, O_RDONLY | O_NOFOLLOW | O_CLOEXEC), writer = open(outURL.path, O_WRONLY | O_NOFOLLOW | O_CLOEXEC)
        defer { if reader >= 0 { close(reader) }; if writer >= 0 { close(writer) } }
        guard reader >= 0, writer >= 0 else { throw CompressorError.failed("could not open \(tool)'s staged files in \(workDir.path)") }
        // Bounded in awake time (`GroupExec`): a tool that hangs is terminated, then killed, with its process group.
        let r = GroupExec.run(executable: tool, arguments: arguments, environment: ProcessInfo.processInfo.environment,
                              stdin: reader, output: .descriptor(writer), timeout: timeout, killGrace: 1)
        guard r.launched else { throw CompressorError.failed(r.error ?? "could not start \(tool)") }
        if r.timedOut { throw CompressorError.failed("\(tool) timed out") }
        guard r.status == 0 else { throw CompressorError.failed("\(tool) exited with status \(r.status)") }
        return try Data(contentsOf: outURL)
    }
}
