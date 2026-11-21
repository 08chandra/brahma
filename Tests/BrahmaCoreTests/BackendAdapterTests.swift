import Testing
import Foundation
#if canImport(Darwin)
import Darwin
#else
import Glibc
#endif
@testable import BrahmaCore

/// A backend preview (Plan 4a Task 5): L's server start, then the surface's smoke requests against the preview's own loopback
/// origin, and the engine's confined copy of its OpenAPI file. FakeSandbox (real processes, unsandboxed) and fake probes.
@Suite(.scratch) struct BackendAdapterTests {
    static let policy = SandboxPolicy(writable: [URL(fileURLWithPath: "/nowhere")], readable: [], network: .none, toolchain: false)

    struct Setup {
        let dir: URL
        let context: PreviewContext
        let sandbox: FakeSandbox
        let http: FakeHTTPProbe
        let deps: PreviewDependencies
        var adapter: BackendAdapter { BackendAdapter(deps: deps) }

        /// Stops the server `update` started, if any.
        func stop(_ update: PreviewUpdate) async {
            guard let pid = update.process else { return }
            await deps.processes.process(pid)?.terminate(grace: .seconds(2))
            deps.processes.remove(pid)
        }
    }

    static func setup(smoke: [SmokeRequest] = [], url: String = "http://127.0.0.1:{port}/", openapiPath: String? = nil,
                      http: FakeHTTPProbe, redactor: Redactor? = CLIAdapterTests.redactor()) throws -> Setup {
        let dir = try tempDir()
        let runDir = dir.appending(path: "run", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: runDir, withIntermediateDirectories: true)
        let layout = EngineLayout(workspace: dir.appending(path: "ws", directoryHint: .isDirectory))
        try FileManager.default.createDirectory(at: layout.workspace, withIntermediateDirectories: true)
        _ = try EngineFiles.directory(workspace: layout.workspace, ".brahma/preview/logs")
        let now = Date()
        let surface = PreviewSurface(id: "s1", companyId: "c1", name: "api", kind: "backend", position: 0, build: nil, run: "sleep 300",
                                     url: url, smoke: smoke, setById: "owner", createdAt: now, updatedAt: now, openapiPath: openapiPath)
        let company = Company(id: "c1", name: "Acme", slug: "acme", goal: "g", workspacePath: layout.workspace.path, status: .running,
                              usageMode: .low, priorityWeight: 1, createdAt: now)
        let context = PreviewContext(surface: surface, company: company, layout: layout, run: runDir, commit: String(repeating: "a", count: 40),
                                     port: 47100, policy: policy, environment: ["PATH": "/bin:/usr/bin"], logURL: layout.previewLog(name: "api"),
                                     timeouts: PreviewTimeouts(ready: .seconds(600), poll: .milliseconds(50)), redactor: redactor)
        let sandbox = FakeSandbox()
        return Setup(dir: dir, context: context, sandbox: sandbox, http: http, deps: .fake(sandbox: sandbox, http: http))
    }

    static func running(_ update: PreviewUpdate) -> PreviewState {
        PreviewState(surfaceId: "s1", companyId: "c1", status: update.status, resolvedURL: update.resolvedURL, pid: update.process,
                     updatedAt: Date(), smokeResults: update.smokeResults)
    }

    @Test func smokeResultsRecorded() async throws {
        let http = FakeHTTPProbe([FakeHTTPProbe.ok(), FakeHTTPProbe.ok(200, body: "healthy"), FakeHTTPProbe.ok(201, body: "{\"id\":1}"),
                                  FakeHTTPProbe.ok(404, body: "nope"), FakeHTTPProbe.ok(200, body: "teapot")])
        let smoke = [SmokeRequest(method: "GET", path: "/health", expectStatus: 200),
                     SmokeRequest(method: "POST", path: "/items", body: "{\"a\":1}", expectStatus: 201),
                     SmokeRequest(method: "GET", path: "/missing"),
                     SmokeRequest(method: "GET", path: "/teapot", expectStatus: 418)]
        let s = try Self.setup(smoke: smoke, http: http)
        let update = await s.adapter.start(s.context)
        #expect(update.status == .running && update.message == "2/4 smoke requests ok", "\(update)")
        #expect(update.resolvedURL == "http://127.0.0.1:47100/" && update.process != nil)
        let r = update.smokeResults
        #expect(r.map(\.ok) == [true, true, false, false])
        #expect(r.map(\.status) == [200, 201, 404, 200])
        #expect(r.map(\.method) == ["GET", "POST", "GET", "GET"])
        #expect(r.map(\.url) == ["http://127.0.0.1:47100/health", "http://127.0.0.1:47100/items", "http://127.0.0.1:47100/missing",
                                 "http://127.0.0.1:47100/teapot"])
        #expect(r[0].bodyPrefix == "healthy" && r[0].error == nil)
        #expect(r[3].error == "expected 418, got 200")
        // The readiness GET, then each request with its body (the probe sends JSON content type with a body).
        let sent = http.requests
        #expect(sent.count == 5)
        #expect(sent[2].method == "POST" && sent[2].body == Data("{\"a\":1}".utf8))
        #expect(sent[1].body == nil)
        // demo re-runs them.
        // (The probe still holds its last answer, 200, which the first request gets.)
        http.answer([FakeHTTPProbe.ok(201), FakeHTTPProbe.ok(200), FakeHTTPProbe.ok(418)])
        let demo = await s.adapter.demo(s.context, state: Self.running(update))
        #expect(demo.ok && demo.line == "api: 4/4 smoke requests ok", "\(demo)")
        #expect(http.requests.count == 9)
        let stopped = await s.adapter.demo(s.context, state: PreviewState(surfaceId: "s1", companyId: "c1", status: .stopped, updatedAt: Date()))
        #expect(!stopped.ok && stopped.line == "api: not running")
        await s.stop(update)
        // No smoke requests: running, no summary; its demo is one GET.
        let plain = try Self.setup(http: FakeHTTPProbe([FakeHTTPProbe.ok()]))
        let bare = await plain.adapter.start(plain.context)
        #expect(bare.status == .running && bare.message == nil && bare.smokeResults.isEmpty, "\(bare)")
        let bareDemo = await plain.adapter.demo(plain.context, state: Self.running(bare))
        #expect(bareDemo.ok && bareDemo.line == "api: HTTP 200", "\(bareDemo)")
        await plain.stop(bare)
    }

    @Test func bodyIsCapped() async throws {
        let huge = String(repeating: "x", count: 60_000)
        let s = try Self.setup(smoke: [SmokeRequest(method: "GET", path: "/big")],
                               http: FakeHTTPProbe([FakeHTTPProbe.ok(), FakeHTTPProbe.ok(200, body: huge)]))
        let update = await s.adapter.start(s.context)
        #expect(update.status == .running, "\(update)")
        let result = try #require(update.smokeResults.first)
        #expect(result.ok && result.bodyPrefix.count == SmokeRequest.bodyKept && SmokeRequest.bodyKept == 4096)
        await s.stop(update)
        // Bodies and errors are redacted before they are kept.
        let secret = "sk-live-0123456789abcdef"
        let r = try Self.setup(smoke: [SmokeRequest(method: "GET", path: "/env")],
                               http: FakeHTTPProbe([FakeHTTPProbe.ok(), FakeHTTPProbe.ok(200, body: "key=\(secret)")]),
                               redactor: CLIAdapterTests.redactor([(name: "API_KEY", value: secret)]))
        let redacted = await r.adapter.start(r.context)
        #expect(redacted.smokeResults.first?.bodyPrefix == "key=[redacted API_KEY]", "\(redacted)")
        await r.stop(redacted)
        // A redactor that has not loaded: the body is withheld.
        let h = try Self.setup(smoke: [SmokeRequest(method: "GET", path: "/env")],
                               http: FakeHTTPProbe([FakeHTTPProbe.ok(), FakeHTTPProbe.ok(200, body: "key=\(secret)")]), redactor: Redactor())
        let held = await h.adapter.start(h.context)
        #expect(held.smokeResults.first?.bodyPrefix == "" && held.smokeResults.first?.ok == true, "\(held)")
        await h.stop(held)
    }

    @Test func smokeStaysOnOrigin() async throws {
        // A request path that would leave the origin (stored rows are not trusted to be valid) is never sent; every request
        // goes to the preview's own loopback origin and port, whatever path its URL has; a redirect is the answer, never
        // followed.
        let http = FakeHTTPProbe([FakeHTTPProbe.ok(), (302, "text/html", Data(), nil)])
        let s = try Self.setup(smoke: [SmokeRequest(method: "GET", path: "//evil.example/x"),
                                       SmokeRequest(method: "GET", path: "/go"),
                                       SmokeRequest(method: "GET", path: "/@evil.example/")],
                               url: "http://127.0.0.1:{port}/app/", http: http)
        let update = await s.adapter.start(s.context)
        #expect(update.status == .running, "\(update)")
        let r = update.smokeResults
        #expect(r.count == 3)
        #expect(r[0].ok == false && r[0].status == nil && r[0].error == "the smoke path does not stay on the preview's origin", "\(r[0])")
        #expect(r[1].url == "http://127.0.0.1:47100/go" && r[1].status == 302)
        let sent = http.requests
        #expect(sent.count == 3)          // the readiness GET, /go, /@evil.example/
        #expect(sent.allSatisfy { $0.url.host == "127.0.0.1" && $0.url.port == 47100 && $0.url.user == nil }, "\(sent)")
        await s.stop(update)

        // Fix round 1 (I1): a literal port in the URL that is not the engine's port. L's start already checked that the
        // preview listens on `c.port` (47100) only; the smoke requests (agent-chosen methods, paths and bodies) never go to
        // the literal port, where another local service may listen. None is sent, and the message says why.
        let literal = FakeHTTPProbe([FakeHTTPProbe.ok()])
        let l = try Self.setup(smoke: [SmokeRequest(method: "POST", path: "/admin/delete", body: "{\"all\":true}"),
                                       SmokeRequest(method: "GET", path: "/health")],
                               url: "http://127.0.0.1:47199/", http: literal)
        // Task 6 fix round 1 (controller ruling): the start fails before anything runs, so not even L's readiness GET goes to
        // the literal port.
        let lu = await l.adapter.start(l.context)
        #expect(lu.status == .failed && lu.smokeResults.isEmpty && lu.process == nil, "\(lu)")
        #expect(lu.message == "a backend preview must serve on its own port ($PORT)", "\(lu)")
        #expect(literal.requests.isEmpty, "\(literal.requests)")
        // A state that claims to run there (an earlier engine's record) still sends no smoke request on demo.
        let forged = PreviewState(surfaceId: "s1", companyId: "c1", status: .running, resolvedURL: "http://127.0.0.1:47199/", pid: nil,
                                  updatedAt: Date())
        let ld = await l.adapter.demo(l.context, state: forged)
        #expect(!ld.ok && ld.line == "api: smoke requests run only against the preview's own port", "\(ld)")
        #expect(literal.requests.isEmpty)
    }

    /// Task 6 fix round 1 (controller ruling): a backend URL that is not on the engine's own port fails the start before L's
    /// start runs (no build, no server, no readiness GET), with or without smoke requests and with no port at all.
    @Test func foreignPortFailsBeforeStart() async throws {
        for url in ["http://127.0.0.1:47199/", "http://127.0.0.1/", "http://localhost:8080/health"] {
            let http = FakeHTTPProbe([FakeHTTPProbe.ok()])
            let s = try Self.setup(url: url, http: http)
            let update = await s.adapter.start(s.context)
            #expect(update.status == .failed && update.message == "a backend preview must serve on its own port ($PORT)", "\(url): \(update)")
            #expect(http.requests.isEmpty && update.process == nil, "\(url)")
        }
        // The engine's own port still starts.
        let ok = try Self.setup(url: "http://127.0.0.1:{port}/", http: FakeHTTPProbe([FakeHTTPProbe.ok()]))
        let started = await ok.adapter.start(ok.context)
        #expect(started.status == .running, "\(started)")
        await ok.stop(started)
    }

    @Test func unreachableRequestRecordsError() async throws {
        let s = try Self.setup(smoke: [SmokeRequest(method: "GET", path: "/health")],
                               http: FakeHTTPProbe([FakeHTTPProbe.ok(), FakeHTTPProbe.refused]))
        let update = await s.adapter.start(s.context)
        #expect(update.status == .running && update.message == "0/1 smoke requests ok", "\(update)")
        let result = try #require(update.smokeResults.first)
        #expect(result.status == nil && !result.ok && result.error == "connection refused" && result.bodyPrefix.isEmpty)
        let demo = await s.adapter.demo(s.context, state: Self.running(update))
        #expect(!demo.ok && demo.line == "api: 0/1 smoke requests ok")
        await s.stop(update)
        // A server that never starts is L's failure, and no smoke request is sent.
        let dead = try Self.setup(smoke: [SmokeRequest(method: "GET", path: "/health")], http: FakeHTTPProbe())
        var c = dead.context
        c.surface.run = "exit 4"
        // Fix round 1: an OpenAPI copy an earlier start left is removed when a start fails.
        try Data("stale".utf8).write(to: c.layout.previewOpenAPI(name: "api"))
        let failed = await dead.adapter.start(c)
        #expect(failed.status == .failed && failed.smokeResults.isEmpty, "\(failed)")
        #expect(!FileManager.default.fileExists(atPath: c.layout.previewOpenAPI(name: "api").path))
    }

    @Test func openapiConfined() async throws {
        let refusal = "openapi_path must be a regular file of at most 2 MB inside the repo"
        let outside = try tempDir()
        try "{\"secret\":true}".write(to: outside.appending(path: "spec.json"), atomically: true, encoding: .utf8)
        let spec = "{\"openapi\":\"3.0.0\",\"paths\":{}}"

        // Inside the run: the engine copies it to the logs directory, the only place the app reads.
        let s = try Self.setup(openapiPath: "api/openapi.json", http: FakeHTTPProbe([FakeHTTPProbe.ok()]))
        let api = s.context.run.appending(path: "api", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: api, withIntermediateDirectories: true)
        try spec.write(to: api.appending(path: "openapi.json"), atomically: true, encoding: .utf8)
        let update = await s.adapter.start(s.context)
        #expect(update.status == .running && update.message == nil, "\(update)")
        let copy = s.context.layout.previewOpenAPI(name: "api")
        #expect(copy.path == s.context.layout.previewLogs.appending(path: "api-openapi.json").path)
        #expect(CLIAdapterTests.text(copy) == spec)
        await s.stop(update)

        // Each refusal: the server still runs, the message says why, and no copy is left (a stale one is removed).
        func refused(_ prepare: (URL) throws -> Void, path: String) async throws {
            let r = try Self.setup(openapiPath: path, http: FakeHTTPProbe([FakeHTTPProbe.ok()]))
            try prepare(r.context.run)
            try Data("stale".utf8).write(to: r.context.layout.previewOpenAPI(name: "api"))
            let u = await r.adapter.start(r.context)
            #expect(u.status == .running && u.message == refusal, "\(path): \(u)")
            #expect(!FileManager.default.fileExists(atPath: r.context.layout.previewOpenAPI(name: "api").path), "\(path)")
            await r.stop(u)
            #expect(BackendAdapter.copyOpenAPI(r.context) == refusal)
        }
        // A link out of the run.
        try await refused({ run in
            try FileManager.default.createSymbolicLink(at: run.appending(path: "openapi.json"), withDestinationURL: outside.appending(path: "spec.json"))
        }, path: "openapi.json")
        // A directory link out of the run on the way.
        try await refused({ run in
            try FileManager.default.createSymbolicLink(at: run.appending(path: "docs"), withDestinationURL: outside)
        }, path: "docs/spec.json")
        // Larger than 2 MB.
        try await refused({ run in
            try Data(repeating: UInt8(ascii: " "), count: 3_000_000).write(to: run.appending(path: "big.json"))
        }, path: "big.json")
        // Missing, a directory, a FIFO.
        try await refused({ _ in }, path: "missing.json")
        try await refused({ run in
            try FileManager.default.createDirectory(at: run.appending(path: "dir.json"), withIntermediateDirectories: true)
        }, path: "dir.json")
        try await refused({ run in
            #expect(mkfifo(run.appending(path: "fifo.json").path, 0o600) == 0)
        }, path: "fifo.json")
        #expect(BackendAdapter.openapiMaxBytes == 2_097_152)

        // Exactly at the limit is fine; a link inside the run to a file inside the run is fine too.
        let edge = try Self.setup(openapiPath: "link.json", http: FakeHTTPProbe([FakeHTTPProbe.ok()]))
        try Data(repeating: UInt8(ascii: " "), count: BackendAdapter.openapiMaxBytes).write(to: edge.context.run.appending(path: "full.json"))
        try FileManager.default.createSymbolicLink(atPath: edge.context.run.appending(path: "link.json").path, withDestinationPath: "full.json")
        #expect(BackendAdapter.copyOpenAPI(edge.context) == nil)
        let edgeCopy = try FileManager.default.attributesOfItem(atPath: edge.context.layout.previewOpenAPI(name: "api").path)
        #expect(edgeCopy[.size] as? Int == BackendAdapter.openapiMaxBytes)
    }
}
