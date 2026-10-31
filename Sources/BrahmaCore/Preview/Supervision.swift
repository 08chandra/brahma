import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

// The helpers that supervise preview servers: their logs, their ports, the probes that tell whether one is up and where it
// listens, and the table of processes the engine started.

/// A preview's log (`EngineLayout.previewLog(name:)`): agent-controlled text, appended by the engine (the server's output
/// reaches it through a pipe the engine reads; no preview policy writes the logs directory). Every open is a descriptor walk
/// from the workspace (`EngineFiles.openFileNoFollow`: `.brahma`, `preview` and `logs` each opened with `O_NOFOLLOW`, never
/// created), then the log itself with `O_NOFOLLOW`, and only a regular file with a single link that this user owns is read
/// or rewritten: a link planted anywhere on the way, or a second hard link, is refused and its target left alone.
public enum PreviewLog {
    /// Past this size the log is trimmed (5 MB) …
    public static let cap = 5_242_880
    /// … to its last 1 MB, from the first whole line in it.
    public static let keep = 1_048_576
    static let trimmedMarker = "[earlier output trimmed]\n"
    /// How much of the end of a log `tail` reads.
    static let tailWindow = 65_536

    static func relative(_ name: String) -> String { ".brahma/preview/logs/\(name).log" }

    /// Trims surface `name`'s log in place (same file, so the engine's open appender keeps writing to it) when it is over
    /// `cap`. A missing log is fine; a link on the way, a hard-linked or foreign file throws `UnsafeEngineFile`.
    public static func trimIfNeeded(_ l: EngineLayout, name: String) throws {
        guard let fd = try EngineFiles.openFileNoFollow(under: l.workspace, relative(name), flags: O_RDWR) else { return }
        defer { close(fd) }
        let shown = l.previewLog(name: name).path
        var st = stat()
        guard fstat(fd, &st) == 0 else { throw UnsafeEngineFile(path: shown, problem: "cannot be inspected") }
        let size = Int(st.st_size)
        guard size > cap else { return }
        var tail = try read(fd, offset: size - keep, count: keep, path: shown)
        if let newline = tail.firstIndex(of: 10) { tail = tail[tail.index(after: newline)...] }
        let kept = Data(trimmedMarker.utf8) + tail
        // Rewritten from the start, then cut: what is appended meanwhile may be lost, never anything else kept.
        let written = kept.withUnsafeBytes { pwrite(fd, $0.baseAddress, kept.count, 0) }
        guard written == kept.count, ftruncate(fd, off_t(kept.count)) == 0 else {
            throw UnsafeEngineFile(path: shown, problem: "could not be trimmed (\(String(cString: strerror(errno))))")
        }
    }

    /// The last `lines` lines of surface `name`'s log (from its last 64 KB), without their newlines; empty when it is
    /// missing or refused (a link on the way, a hard-linked or foreign file). Agent-controlled text: quote or flatten it.
    public static func tail(_ l: EngineLayout, name: String, lines: Int) -> [String] {
        guard lines > 0, let fd = try? EngineFiles.openFileNoFollow(under: l.workspace, relative(name), flags: O_RDONLY) else { return [] }
        defer { close(fd) }
        var st = stat()
        guard fstat(fd, &st) == 0 else { return [] }
        let size = Int(st.st_size)
        let start = max(0, size - tailWindow)
        guard var data = try? read(fd, offset: start, count: size - start, path: l.previewLog(name: name).path) else { return [] }
        if start > 0, let newline = data.firstIndex(of: 10) { data = data[data.index(after: newline)...] }
        var all = String(decoding: data, as: UTF8.self).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if all.last == "" { all.removeLast() }
        return Array(all.suffix(lines))
    }

    private static func read(_ fd: Int32, offset: Int, count: Int, path: String) throws -> Data {
        var buffer = [UInt8](repeating: 0, count: max(count, 0))
        var done = 0
        while done < count {
            let n = buffer.withUnsafeMutableBytes { pread(fd, $0.baseAddress! + done, count - done, off_t(offset + done)) }
            if n < 0, errno == EINTR { continue }
            guard n > 0 else {
                if n == 0 { break }
                throw UnsafeEngineFile(path: path, problem: "could not be read (\(String(cString: strerror(errno))))")
            }
            done += n
        }
        return Data(buffer[0..<done])
    }
}

/// Engine-wide preview ports. Task 2 adds the per-surface rule (`port(for:store:)`).
public enum PortAllocator {
    public static let range = 47100...47999

    /// The first port in `range`, not in `excluding`, that `bind(127.0.0.1)` accepts right now.
    public static func allocate(excluding: Set<Int>) throws -> Int {
        for port in range where !excluding.contains(port) && isFree(port) { return port }
        throw WorkError.conflict("no free preview port in \(range.lowerBound)…\(range.upperBound)")
    }

    /// Whether a TCP socket can bind `127.0.0.1:<port>` (closed again at once).
    static func isFree(_ port: Int) -> Bool {
        guard let p = UInt16(exactly: port) else { return false }
        #if canImport(Darwin)
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let fd = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = in_port_t(p.bigEndian)
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        return bound == 0
    }
}

/// One HTTP request to a preview (or, Task 7, a deployed site). Never throws: what went wrong is `error`.
public protocol HTTPProbing: Sendable {
    func send(method: String, url: URL, body: Data?, timeout: Duration) async -> (status: Int?, contentType: String?, body: Data, error: String?)
}

/// `HTTPProbing` over an ephemeral `URLSession` per request: no cookies, no cache, **no redirect followed** (a 3xx is the
/// answer, so a probe never leaves the URL it was given), at most `maxBody` bytes of the body kept.
public struct URLSessionHTTPProbe: HTTPProbing {
    public static let maxBody = 65_536

    public init() {}

    final class NoRedirects: NSObject, URLSessionTaskDelegate, @unchecked Sendable {
        func urlSession(_ session: URLSession, task: URLSessionTask, willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest, completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    public func send(method: String, url: URL, body: Data?, timeout: Duration) async -> (status: Int?, contentType: String?, body: Data, error: String?) {
        let seconds = max(0.1, Double(timeout.components.seconds) + Double(timeout.components.attoseconds) / 1e18)
        let config = URLSessionConfiguration.ephemeral
        config.timeoutIntervalForRequest = seconds
        config.timeoutIntervalForResource = seconds
        config.httpShouldSetCookies = false
        config.httpCookieAcceptPolicy = .never
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        let session = URLSession(configuration: config, delegate: NoRedirects(), delegateQueue: nil)
        defer { session.invalidateAndCancel() }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: seconds)
        request.httpMethod = method
        request.httpBody = body
        if body != nil { request.setValue("application/json", forHTTPHeaderField: "Content-Type") }
        do {
            #if canImport(Darwin)
            let (bytes, response) = try await session.bytes(for: request)
            var data = Data()
            for try await byte in bytes {
                if data.count >= Self.maxBody { break }
                data.append(byte)
            }
            #else
            let (whole, response) = try await session.data(for: request)
            let data = whole.prefix(Self.maxBody)
            #endif
            let http = response as? HTTPURLResponse
            return (http?.statusCode, http?.value(forHTTPHeaderField: "Content-Type"), Data(data), http == nil ? "not an HTTP response" : nil)
        } catch {
            return (nil, nil, Data(), (error as? URLError).map { "\($0.code.rawValue): \($0.localizedDescription)" } ?? "\(error)")
        }
    }
}

/// Where a process listens on a port.
public protocol ListenProbing: Sendable {
    /// The addresses something listens on at `port` (`127.0.0.1`, `[::1]`, `*` …); empty when none, or when it cannot tell.
    func listenAddresses(port: Int) -> [String]
}

/// `ListenProbing` by `lsof -nP -iTCP:<port> -sTCP:LISTEN -Fn` (a bounded engine tool run, `GroupExec`: its own process
/// group, 5 s). Blocking: call it off the cooperative pool where that matters. When lsof is missing or fails the answer is
/// empty (the Seatbelt profile only lets a preview bind its own loopback port anyway).
public struct LsofListenProbe: ListenProbing {
    static let candidates = ["/usr/sbin/lsof", "/usr/bin/lsof"]

    public init() {}

    public func listenAddresses(port: Int) -> [String] {
        guard (1...65535).contains(port), let lsof = Self.candidates.first(where: { access($0, X_OK) == 0 }) else { return [] }
        let result = GroupExec.run(executable: lsof, arguments: ["-nP", "-iTCP:\(port)", "-sTCP:LISTEN", "-Fn"],
                                   environment: ChildEnvironment.make(base: ProcessInfo.processInfo.environment),
                                   output: .capture(cap: 65_536, stderr: false), timeout: 5)
        guard result.launched, result.error == nil else { return [] }
        return Self.parse(String(decoding: result.output, as: UTF8.self))
    }

    /// The addresses of `n<addr>:<port>` lines (`-F` output), in order, deduplicated.
    static func parse(_ output: String) -> [String] {
        var out: [String] = []
        for line in output.split(whereSeparator: \.isNewline) where line.hasPrefix("n") {
            let name = line.dropFirst()
            guard let colon = name.lastIndex(of: ":"), colon != name.startIndex else { continue }
            let address = String(name[..<colon])
            if !out.contains(address) { out.append(address) }
        }
        return out
    }
}

/// The long-running processes the engine started through `SandboxedRunner.spawn` (previews; Task 7's deploy steps), by pid.
/// Lock-protected. (3a's `ProcessTable` is the process-table snapshot enum, PR-4.)
public final class SpawnedProcesses: @unchecked Sendable {
    private let lock = NSLock()
    private var byPid: [Int32: any SandboxedProcess] = [:]

    public init() {}

    public func insert(_ p: any SandboxedProcess) { lock.withLock { byPid[p.pid] = p } }
    public func process(_ pid: Int32) -> (any SandboxedProcess)? { lock.withLock { byPid[pid] } }
    public func remove(_ pid: Int32) { lock.withLock { _ = byPid.removeValue(forKey: pid) } }
    public var count: Int { lock.withLock { byPid.count } }
    /// Every process, by pid.
    public var all: [any SandboxedProcess] { lock.withLock { byPid.sorted { $0.key < $1.key }.map(\.value) } }
}
