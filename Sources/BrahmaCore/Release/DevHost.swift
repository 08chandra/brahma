import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

// Dev-only hosting (Plan L Task 12, PR-32): `brahma dev release-scenario` (BRAHMA_DEV=1 only) drives the real deploy path
// against a "provider" that is a folder under the data home served on loopback. Nothing here is in `HostingAdapters`: the
// adapter is injected into `proposeDeploy` and `ReleaseExecutor` by the scenario alone (PR-25), and never contacts anything.

/// The dev "hosting provider": its deploy copies the release's output folder from `upload/` into
/// `<home>/dev-host/<company>/R-<n>/` with `/bin/cp` and prints the in-process `DevHostServer`'s loopback URL, which serves
/// the folder being deployed at its root (as a provider serves a site), and is the deploy URL and the smoke base. Its tool
/// install is a no-op (the scenario writes a marker where the provider CLI would be, so the executor installs nothing). It reports the company's configured provider as its `id`, so the executor's provider checks hold unchanged.
struct LocalCopyHostingAdapter: HostingAdapter {
    var id: HostingProviderID
    var tokenSecret = DevReleaseScenario.tokenSecret
    var cli = "dev-copy@0"
    var toolNetwork: [String] = []
    var network: [String] = []
    var providerConfigNames: [String] = []
    /// `<home>/dev-host/<company slug>`.
    var hostDir: URL
    /// The dev server's origin, `http://127.0.0.1:<port>/`: the deploy URL of every plan of this adapter.
    var server: URL

    static let copy = "/bin/cp"
    static let echo = "/bin/echo"

    func validate(_ s: HostingSettings) throws { try HostingAdapters.validateForDeploy(s) }

    /// `cp -R <source> <hostDir>/<folder>` (a source ending in `/` copies its contents), then the server's URL on stdout.
    private func steps(source: String, folder: String) -> [DeployStep] {
        [DeployStep(label: "copy", argv: [Self.copy, "-R", source, hostDir.appending(path: folder, directoryHint: .isDirectory).path]),
         DeployStep(label: "deploy", argv: [Self.echo, server.absoluteString])]
    }

    func deployPlan(_ i: DeployInput) throws -> DeployPlan {
        try validate(i.settings)
        try i.validate()
        let output = i.settings.outputDir ?? ""
        return try DeployPlan(steps: steps(source: output + "/", folder: i.releaseDir.lastPathComponent), stageFrom: [output],
                              cwdPath: i.inRelease("upload"), network: network, tokenSecret: tokenSecret, build: i.settings.build,
                              outputDir: i.settings.outputDir)
    }

    /// The restored release's upload (its output folder; else the placeholder) copied into `R-<n>-rollback`.
    func rollbackPlan(_ i: DeployInput) throws -> DeployPlan {
        try validate(i.settings)
        try i.validate()
        let source = i.previousUpload == nil ? "./" : (i.settings.outputDir ?? "") + "/"
        return try DeployPlan(steps: steps(source: source, folder: i.releaseDir.lastPathComponent + "-rollback"), stageFrom: [],
                              cwdPath: (i.previousUpload ?? i.placeholderDir).path, network: network, tokenSecret: tokenSecret,
                              build: i.settings.build, outputDir: i.settings.outputDir)
    }

    /// The server's URL when the last non-empty stdout line is exactly it, else nil.
    func deployURL(fromOutput: String, settings: HostingSettings) -> URL? {
        let last = fromOutput.split(whereSeparator: \.isNewline).last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        return last?.trimmingCharacters(in: .whitespaces) == server.absoluteString ? server : nil
    }

    func smokeBase(_ s: HostingSettings, deployURL: URL?) -> URL? { deployURL }
}

/// The scenario's sandbox: the platform sandbox, plus write access to the company's dev-host folder for exactly the dev
/// adapter's copy step (`/bin/cp -R <source> <hostDir>/…`). That folder is the dev provider's storage: what `.outbound(allow:
/// network)` is to a real provider's deploy step. Every other command (the build, the smoke on main, the verify-free echo)
/// runs with its policy unchanged.
struct DevHostSandbox: SandboxedRunner {
    let base: any SandboxedRunner
    let hostDir: URL

    func run(command: String, cwd: URL, environment: [String: String], timeout: Duration, outputURL: URL,
             policy: ValidatedPolicy) async -> CheckOutcome {
        switch granted(command, policy) {
        case .sandboxed(let p):
            return await base.run(command: command, cwd: cwd, environment: environment, timeout: timeout, outputURL: outputURL, policy: p)
        case let other:
            return await base.run(command: command, cwd: cwd, environment: environment, timeout: timeout, outputURL: outputURL, decision: other)
        }
    }

    func spawn(command: String, cwd: URL, environment: [String: String], logURL: URL, policy: ValidatedPolicy) throws -> any SandboxedProcess {
        switch granted(command, policy) {
        case .sandboxed(let p): return try base.spawn(command: command, cwd: cwd, environment: environment, logURL: logURL, policy: p)
        case .refused(let why): throw SandboxError.invalidPath(why)
        case .fullOptOut: throw SandboxError.invalidPath("the dev host's copy step runs only sandboxed")
        }
    }

    func policyBaseline() -> SandboxBaseline { base.policyBaseline() }

    /// The copy step's policy with the dev-host folder writable (kept off `writable[0]`, the TMPDIR, and the last entry, the
    /// toolchain HOME); any other policy as it is. Plan S Task S7: the widened policy is the factory's `.releaseTool`
    /// decision over the step's own places plus the folder (a verified place), so it is validated like any other.
    func granted(_ command: String, _ policy: ValidatedPolicy) -> PolicyDecision {
        let copy = ShellQuote.joinArgv([LocalCopyHostingAdapter.copy, "-R"], rawRefs: []) + " "
        let quoted = ShellQuote.quote(hostDir.path + "/")
        let target = " " + (quoted.hasPrefix("'") ? String(quoted.dropLast()) : quoted)
        guard command.hasPrefix(copy), command.contains(target), !policy.writable.isEmpty else { return .sandboxed(policy) }
        var writable = policy.writable.map { URL(fileURLWithPath: $0, isDirectory: false) }
        writable.insert(hostDir.resolvedForSandbox, at: 1)
        return ReleaseExecutor.toolDecision(writable: writable, readable: policy.readable.map { URL(fileURLWithPath: $0, isDirectory: false) },
                                            network: policy.allowedDomains ?? [], baseline: base.policyBaseline())
    }
}

/// A loopback static file server for the dev host (`http://127.0.0.1:<port>/`), in-process, read-only: `GET` and `HEAD` of
/// regular files under `base/<folder>` for the folder `serve(folder:)` names (nothing before it; `<path>/` serves
/// `<path>/index.html`), read with `EngineFiles.readNoFollow` (no link is
/// followed, no hard-linked file served). Anything else is 404 or 405. One request per connection. Stopped by `stop()`.
final class DevHostServer: @unchecked Sendable {
    let base: URL
    private var folder: String?
    let port: Int
    private let fd: Int32
    private let lock = NSLock()
    private var stopped = false
    private let done = DispatchSemaphore(value: 0)

    /// Binds `127.0.0.1` on a free port the system picks, and starts serving.
    init(base: URL) throws {
        self.base = base
        #if canImport(Darwin)
        let s = socket(AF_INET, SOCK_STREAM, 0)
        #else
        let s = socket(AF_INET, Int32(SOCK_STREAM.rawValue), 0)
        #endif
        guard s >= 0 else { throw WorkError.invalid("the dev host could not open a socket") }
        var one: Int32 = 1
        _ = setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, socklen_t(MemoryLayout<Int32>.size))
        var addr = sockaddr_in()
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr.s_addr = inet_addr("127.0.0.1")
        let bound = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(s, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) }
        }
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        let named = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(s, $0, &len) }
        }
        guard bound == 0, named == 0, listen(s, 16) == 0 else {
            close(s)
            throw WorkError.invalid("the dev host could not listen on 127.0.0.1")
        }
        fd = s
        port = Int(UInt16(bigEndian: addr.sin_port))
        let thread = Thread { [self] in serve() }
        thread.name = "brahma dev host"
        thread.start()
    }

    var url: URL { URL(string: "http://127.0.0.1:\(port)/")! }

    /// Serves `base/<folder>` at the root from now on (`R-<n>`: one path part, no `.` or `/`).
    func serve(folder: String) {
        guard !folder.isEmpty, !folder.hasPrefix("."), !folder.contains("/") else { return }
        lock.withLock { self.folder = folder }
    }

    private var root: URL? { lock.withLock { folder.map { base.appending(path: $0, directoryHint: .isDirectory) } } }

    /// Stops accepting and waits for the accept loop to end; the socket is closed.
    func stop() {
        let first: Bool = lock.withLock { defer { stopped = true }; return !stopped }
        guard first else { return }
        done.wait()
        close(fd)
    }

    private var isStopped: Bool { lock.withLock { stopped } }

    private func serve() {
        defer { done.signal() }
        while !isStopped {
            var p = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            guard poll(&p, 1, 100) > 0 else { continue }
            let client = accept(fd, nil, nil)
            guard client >= 0 else { continue }
            handle(client)
            close(client)
        }
    }

    private func handle(_ client: Int32) {
        var timeout = timeval(tv_sec: 5, tv_usec: 0)
        _ = setsockopt(client, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        _ = setsockopt(client, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        #if canImport(Darwin)
        var one: Int32 = 1
        _ = setsockopt(client, SOL_SOCKET, SO_NOSIGPIPE, &one, socklen_t(MemoryLayout<Int32>.size))
        #endif
        var request = Data()
        var buffer = [UInt8](repeating: 0, count: 4096)
        while request.count < 16_384, !request.contains(Data("\r\n\r\n".utf8)) {
            let n = recv(client, &buffer, buffer.count, 0)
            guard n > 0 else { break }
            request.append(contentsOf: buffer[0..<n])
        }
        let line = String(decoding: request.prefix { $0 != 13 && $0 != 10 }, as: UTF8.self).split(separator: " ")
        let method = line.first.map(String.init) ?? "", target = line.count > 1 ? String(line[1]) : ""
        let response = root.map { Self.response(method: method, target: target, root: $0) }
            ?? Self.response(method: method, target: "", root: base)
        response.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = send(client, raw.baseAddress! + sent, raw.count - sent, 0)
                guard n > 0 else { return }
                sent += n
            }
        }
    }

    /// The whole HTTP/1.0 response for one request line.
    static func response(method: String, target: String, root: URL) -> Data {
        guard method == "GET" || method == "HEAD" else { return reply(405, "Method Not Allowed", type: "text/plain", body: Data("method not allowed\n".utf8), head: false) }
        guard let file = file(target: target, root: root), let body = EngineFiles.readNoFollow(file, under: root) else {
            return reply(404, "Not Found", type: "text/plain", body: Data("not found\n".utf8), head: method == "HEAD")
        }
        return reply(200, "OK", type: contentType(file.pathExtension), body: body, head: method == "HEAD")
    }

    /// The file a request target names under `root`, or nil: the path only (query and fragment dropped), percent-decoded,
    /// starting with `/`, with no empty, `.` or `..` part and no NUL; a trailing `/` names its `index.html`.
    static func file(target: String, root: URL) -> URL? {
        let path = String(target.prefix { $0 != "?" && $0 != "#" })
        guard path.hasPrefix("/"), let decoded = path.removingPercentEncoding, !decoded.contains("\0") else { return nil }
        var parts = decoded.split(separator: "/", omittingEmptySubsequences: false).dropFirst().map(String.init)
        if parts.last == "" { parts[parts.count - 1] = "index.html" }
        guard !parts.isEmpty, !parts.contains(where: { $0.isEmpty || $0 == "." || $0 == ".." }) else { return nil }
        return parts.reduce(root) { $0.appending(path: $1, directoryHint: .notDirectory) }
    }

    static func contentType(_ ext: String) -> String {
        switch ext.lowercased() {
        case "html", "htm": "text/html; charset=utf-8"
        case "css": "text/css; charset=utf-8"
        case "js", "mjs": "text/javascript; charset=utf-8"
        case "json": "application/json"
        case "svg": "image/svg+xml"
        case "png": "image/png"
        case "jpg", "jpeg": "image/jpeg"
        case "ico": "image/x-icon"
        case "txt": "text/plain; charset=utf-8"
        default: "application/octet-stream"
        }
    }

    private static func reply(_ status: Int, _ reason: String, type: String, body: Data, head: Bool) -> Data {
        var out = Data("HTTP/1.0 \(status) \(reason)\r\nContent-Type: \(type)\r\nContent-Length: \(body.count)\r\nConnection: close\r\nCache-Control: no-store\r\n\r\n".utf8)
        if !head { out.append(body) }
        return out
    }
}
