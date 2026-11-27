import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif

/// A backend preview (Plan 4a Task 5): L's web start (`WebAdapter.startServer`: build, server, readiness, loopback-only), then
/// the surface's smoke requests, each once with its own `requestTimeout`, against the preview's own origin: always
/// `http://127.0.0.1:<c.port>`, the engine's port, which L's start verified listens on the loopback only (fix round 1, I1).
/// When the surface's URL names another port (a literal port), no smoke request is sent at all (`ownPortOnly`): the engine
/// runs unsandboxed, and agent-chosen methods, paths and bodies must never reach another local service. A request whose path
/// would leave the origin is never sent, and a redirect is the answer (`HTTPProbing` follows none). A request is ok when it got a status, and that status is
/// its `expectStatus`, or below 400 when it has none. The result is `running` with `"<ok>/<n> smoke requests ok"`; the
/// requests run again on every start (so every restart) and for every `demo`.
///
/// URLs, response bodies and errors are agent-controlled text: each result keeps at most `SmokeRequest.bodyKept` characters
/// of the body, and all three are redacted with the context's redactor (withheld when it cannot redact).
///
/// `openapi_path`, when set, is resolved at every start: its real path must be inside the run, and it must be a regular file
/// of at most `openapiMaxBytes`. The engine copies it (read without following a link, checked on the open descriptor) to
/// `EngineLayout.previewOpenAPI(name:)`, the only copy the app reads, scrubbed with the context's redactor; otherwise the
/// message says why and no copy is left. A start that does not end `running` removes any copy an earlier start left.
public struct BackendAdapter: PreviewAdapter {
    /// Each smoke request's own timeout.
    public static let requestTimeout: Duration = .seconds(10)
    /// The largest OpenAPI file copied (2 MB, fix 11; the app's `OpenAPISummary.maxBytes`).
    public static let openapiMaxBytes = 2_097_152
    static let openapiRefusal = "openapi_path must be a regular file of at most 2 MB inside the repo"
    static let openapiWithheld = "openapi_path was not copied: secrets could not be loaded to scrub it"
    static let offOrigin = "the smoke path does not stay on the preview's origin"
    static let ownPortOnly = "smoke requests run only against the preview's own port"
    static let foreignPort = "a backend preview must serve on its own port ($PORT)"

    public let deps: PreviewDependencies

    public init(deps: PreviewDependencies) { self.deps = deps }

    public var kind: PreviewKind { .backend }
    public func availability() -> String? { nil }

    /// Through the runner `deps.runner(for: c)` picks (PR-5), telling `c.onSpawn` the server's pid, as the web adapter.
    public func start(_ c: PreviewContext) async -> PreviewUpdate {
        // Task 6 fix round 1 (controller ruling): a URL off the engine's own port fails before L's start runs, so not even its
        // readiness GET (unsandboxed, from the engine) is ever pointed at another local service.
        if !Self.servesOwnPort(c) {
            Self.removeOpenAPICopy(c)
            return PreviewUpdate(status: .failed, message: Self.foreignPort)
        }
        var update = await WebAdapter.startServer(c, deps: deps, onSpawn: c.onSpawn)
        guard update.status == .running, let resolved = update.resolvedURL else {
            Self.removeOpenAPICopy(c)
            return update
        }
        var notes: [String] = []
        if !c.surface.smoke.isEmpty {
            guard let base = Self.origin(resolvedURL: resolved, port: c.port) else {
                notes.append(Self.ownPortOnly)
                if let refusal = Self.copyOpenAPI(c) { notes.append(refusal) }
                update.message = notes.joined(separator: "; ")
                return update
            }
            let results = await Self.smoke(c, base: base, http: deps.http)
            if Task.isCancelled { return PreviewUpdate(status: .stopped, message: nil, process: update.process) }
            update.smokeResults = results
            notes.append(Self.summary(results))
        }
        if let refusal = Self.copyOpenAPI(c) { notes.append(refusal) }
        update.message = notes.isEmpty ? nil : notes.joined(separator: "; ")
        return update
    }

    public func stop(_ c: PreviewContext, state: PreviewState) async {
        await WebAdapter(deps: deps).stop(c, state: state)
    }

    /// The smoke requests again: ok when every one is, `"<name>: <ok>/<n> smoke requests ok"`. With none, the web adapter's
    /// one GET. Not running: `"<name>: not running"`.
    public func demo(_ c: PreviewContext, state: PreviewState) async -> DemoCapture {
        let name = c.surface.name
        if c.surface.smoke.isEmpty { return await WebAdapter(deps: deps).demo(c, state: state) }
        guard state.status == .running, let resolved = state.resolvedURL else { return DemoCapture(ok: false, line: "\(name): not running") }
        guard let base = Self.origin(resolvedURL: resolved, port: c.port) else {
            return DemoCapture(ok: false, line: "\(name): \(Self.ownPortOnly)")
        }
        let results = await Self.smoke(c, base: base, http: deps.http)
        return DemoCapture(ok: results.allSatisfy(\.ok), line: "\(name): \(Self.summary(results))")
    }

    static func summary(_ results: [SmokeResult]) -> String {
        "\(results.filter(\.ok).count)/\(results.count) smoke requests ok"
    }

    // MARK: Smoke requests

    /// Whether the surface's URL, with `{port}` filled in, names exactly the engine's port (`c.port`). A URL with no port, a
    /// literal port or one that does not parse is off-port (false). A surface without a URL is let through: L's start refuses
    /// it ("a web preview needs run and url") before anything runs.
    static func servesOwnPort(_ c: PreviewContext) -> Bool {
        guard let raw = c.surface.url else { return true }
        let text = raw.replacingOccurrences(of: LoopbackURL.placeholder, with: String(c.port))
        guard let parts = URLComponents(string: text) else { return false }
        return parts.port == c.port
    }

    /// The smoke origin of a started preview: `http://127.0.0.1:<port>`, `port` being the engine's (`c.port`), never one the
    /// agent wrote. Nil (no smoke request is sent) when the resolved URL is not a loopback URL on that same port, or the port
    /// is not one the engine allocates.
    static func origin(resolvedURL: String, port: Int) -> URL? {
        guard let parts = URLComponents(string: resolvedURL), let host = parts.host, LoopbackURL.isLoopback(host: host),
              parts.port == port, (1024...65535).contains(port) else { return nil }
        return URL(string: "http://127.0.0.1:\(port)")
    }

    /// Each request once, in order; cancellation stops before the next one.
    static func smoke(_ c: PreviewContext, base: URL, http: any HTTPProbing) async -> [SmokeResult] {
        var results: [SmokeResult] = []
        for request in c.surface.smoke {
            if Task.isCancelled { break }
            results.append(await probe(base: base, request: request, http: http, redactor: c.redactor))
        }
        return results
    }

    /// One request: ok = `status != nil && (expectStatus.map { $0 == status } ?? status! < 400)`.
    static func probe(base: URL, request: SmokeRequest, http: any HTTPProbing, redactor: Redactor?) async -> SmokeResult {
        guard let url = DeploySmoke.url(base: base, path: request.path), url.user == nil else {
            return SmokeResult(url: redacted(Store.flat(request.path, max: 200), redactor) ?? "", method: request.method, status: nil,
                               millis: 0, bodyPrefix: "", ok: false, error: offOrigin)
        }
        let started = AwakeTime.now
        let answer = await http.send(method: request.method, url: url, body: request.body.map { Data($0.utf8) }, timeout: requestTimeout)
        let elapsed = started.duration(to: AwakeTime.now)
        let millis = Int(elapsed.components.seconds) * 1000 + Int(elapsed.components.attoseconds / 1_000_000_000_000_000)
        let ok: Bool
        if let status = answer.status { ok = request.expectStatus.map { $0 == status } ?? (status < 400) } else { ok = false }
        var error = answer.error
        if error == nil, let status = answer.status, !ok {
            error = request.expectStatus.map { "expected \($0), got \(status)" } ?? "got \(status)"
        } else if error == nil, answer.status == nil {
            error = "no response"
        }
        let body = String(String(decoding: answer.body.prefix(SmokeRequest.bodyKept * 4), as: UTF8.self).prefix(SmokeRequest.bodyKept))
        return SmokeResult(url: redacted(url.absoluteString, redactor) ?? "", method: request.method, status: answer.status, millis: millis,
                           bodyPrefix: redacted(body, redactor) ?? "", ok: ok,
                           error: error.map { redacted($0, redactor) ?? "withheld (secrets not loaded)" })
    }

    /// `text` redacted, or nil when there is no redactor that has loaded (the text is withheld).
    static func redacted(_ text: String, _ redactor: Redactor?) -> String? {
        guard let redactor else { return nil }
        if !redactor.hasLoaded, let load = redactor.takeLoader() { load() }
        guard redactor.hasLoaded else { return nil }
        return redactor.apply(text)
    }

    // MARK: OpenAPI

    /// Copies the surface's OpenAPI file to `EngineLayout.previewOpenAPI(name:)`; the refusal message when it cannot (and then
    /// no copy is left), nil when it was copied or the surface has none.
    ///
    /// The path is resolved (`realpath`) and must lie inside the resolved run. The file is then read by a descriptor walk
    /// from the resolved run, every part opened with `O_NOFOLLOW` (`EngineFiles.readNoFollow`), and checked on the opened
    /// descriptor (a regular file, one link, this user's), at most `openapiMaxBytes + 1` bytes: a part swapped for a link
    /// between the check and the read is refused, never followed. The copy is written by the engine (`EngineFiles.replace`,
    /// atomic, never through a link) and scrubbed with the context's redactor (removed when it cannot be).
    static func copyOpenAPI(_ c: PreviewContext) -> String? {
        let name = c.surface.name
        let logs = ".brahma/preview/logs"
        let copyName = c.layout.previewOpenAPI(name: name).lastPathComponent
        // Whatever an earlier start left goes first, so a refusal or a failure below never leaves an old copy.
        removeOpenAPICopy(c)
        func refuse() -> String {
            removeOpenAPICopy(c)
            return openapiRefusal
        }
        guard let relative = c.surface.openapiPath else { return nil }
        guard PreviewSurface.isRelativePath(relative), let run = realpath(c.run.path),
              let real = realpath(c.run.appending(path: relative).path), real.hasPrefix(run + "/") else { return refuse() }
        guard let data = EngineFiles.readNoFollow(URL(fileURLWithPath: real), under: URL(fileURLWithPath: run, isDirectory: true),
                                                  limit: openapiMaxBytes + 1),
              data.count <= openapiMaxBytes else { return refuse() }
        do {
            _ = try EngineFiles.directory(workspace: c.layout.workspace, logs)
            try EngineFiles.replace(data, workspace: c.layout.workspace, dir: logs, name: copyName)
        } catch {
            return refuse()
        }
        // Scrubbed like every engine-kept output; when it cannot be, the copy is gone (`seal` removed it). A redaction that
        // took it over the limit the app accepts removes it too.
        guard CLIAdapter.seal(c.layout.previewOpenAPI(name: name), redactor: c.redactor, cap: .max).kept else { return openapiWithheld }
        var st = stat()
        guard lstat(c.layout.previewOpenAPI(name: name).path, &st) == 0, Int(st.st_size) <= openapiMaxBytes else { return refuse() }
        return nil
    }

    /// Removes the engine's OpenAPI copy of the surface, if any (the entry itself, by descriptor, never through a link).
    static func removeOpenAPICopy(_ c: PreviewContext) {
        try? EngineFiles.remove(workspace: c.layout.workspace, dir: ".brahma/preview/logs",
                                name: c.layout.previewOpenAPI(name: c.surface.name).lastPathComponent)
    }

    private static func realpath(_ path: String) -> String? {
        #if canImport(Darwin)
        guard let p = Darwin.realpath(path, nil) else { return nil }
        #else
        guard let p = Glibc.realpath(path, nil) else { return nil }
        #endif
        defer { free(p) }
        return String(cString: p)
    }
}
