import Testing
import Foundation
@testable import BrahmaCore
@testable import BrahmaSafety

@Suite(.scratch) struct PreviewModelTests {
    static func surface(name: String = "web", kind: String = "web", run: String? = "npm start", url: String? = "http://127.0.0.1:{port}/",
                        build: String? = nil, smoke: [SmokeRequest] = []) -> PreviewSurface {
        PreviewSurface(id: "S1", companyId: "C1", name: name, kind: kind, position: 0, build: build, run: run, url: url, smoke: smoke,
                       setById: "devops-1", createdAt: Date(timeIntervalSince1970: 0), updatedAt: Date(timeIntervalSince1970: 0))
    }

    static func message(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch let e as WorkError { return e.message } catch { return "\(error)" }
    }

    // MARK: LoopbackURL

    @Test(arguments: [("http://127.0.0.1:3000/", true), ("http://localhost:{port}/app", true), ("http://[::1]:8080", true),
                      ("http://0.0.0.0:3000", false), ("https://127.0.0.1:3000", false), ("http://example.com:80", false),
                      ("http://127.0.0.1", false), ("http://127.0.0.1:80", false)])
    func loopbackURLRules(url: String, ok: Bool) {
        let refused = Self.message { try LoopbackURL.validate(url) }
        if ok {
            #expect(refused == nil, "\(url)")
        } else {
            #expect(refused == "preview URLs must be http://127.0.0.1, localhost or [::1] with a port", "\(url)")
        }
    }

    @Test func loopbackURLEdges() {
        let bad = "preview URLs must be http://127.0.0.1, localhost or [::1] with a port"
        for url in ["http://127.0.0.1:65536/", "http://127.0.0.1:1023/", "http://user@127.0.0.1:3000/", "http://127.0.0.1:{port}/{port}",
                    "http://127.0.0.1:3000/{port}", "http://{port}:3000/", "", "127.0.0.1:3000", "http://127.0.0.2:3000/"] {
            #expect(Self.message { try LoopbackURL.validate(url) } == bad, "\(url)")
        }
        #expect(Self.message { try LoopbackURL.validate("http://127.0.0.1:65535/a?b=1") } == nil)
        #expect(LoopbackURL.resolve("http://localhost:{port}/app", port: 47123)?.absoluteString == "http://localhost:47123/app")
        #expect(LoopbackURL.resolve("http://localhost:{port}/app", port: nil) == nil)
        #expect(LoopbackURL.resolve("http://127.0.0.1:3000/", port: 47123)?.absoluteString == "http://127.0.0.1:3000/")
        for host in ["127.0.0.1", "localhost", "::1", "[::1]"] { #expect(LoopbackURL.isLoopback(host: host), "\(host)") }
        for host in ["*", "0.0.0.0", "192.168.1.4", "[::]", "example.com", ""] { #expect(!LoopbackURL.isLoopback(host: host), "\(host)") }
    }

    /// Collab design §4.6: a path the owner types stays on the preview: one leading `/`, no authority tricks, no header
    /// injection, segments percent-encoded, and the result is http://127.0.0.1:<port>.
    @Test func previewPathCannotLeaveLoopback() throws {
        let base = try #require(URL(string: "http://127.0.0.1:47123/"))
        let refusal = "preview paths start with one / and stay on the preview"
        for path in ["", "x", "//evil.com/x", "/a//b", "/a\\b", "/@evil.com", "/a@b", "http://evil.com/", "evil.com:80/x",
                     "/a\u{0}b", "/a\nb", "/a\u{7f}", "/x%0d%0aSet-Cookie:1", "/x%0D%0A", "/x%0a", "/" + String(repeating: "a", count: 2048)] {
            #expect(Self.message { _ = try LoopbackURL.withPath(base, path: path, port: 47123) } == refusal, "\(path.prefix(40))")
        }
        let ok = try LoopbackURL.withPath(base, path: "/items/a b/ü", port: 47123)
        #expect(ok.absoluteString == "http://127.0.0.1:47123/items/a%20b/%C3%BC")
        #expect(ok.scheme == "http" && ok.host == "127.0.0.1" && ok.port == 47123)
        #expect(try LoopbackURL.withPath(base, path: "/", port: 47123).absoluteString == "http://127.0.0.1:47123/")
        #expect(try LoopbackURL.withPath(base, path: "/search?q=a b", port: 47123).absoluteString == "http://127.0.0.1:47123/search?q=a%20b")
        // A colon after the first `/` is part of a segment, not a port.
        #expect(try LoopbackURL.withPath(base, path: "/a:b", port: 47123).absoluteString == "http://127.0.0.1:47123/a:b")
        // The base must be the preview itself (loopback, same port).
        let elsewhere = try #require(URL(string: "http://example.com:47123/"))
        #expect(Self.message { _ = try LoopbackURL.withPath(elsewhere, path: "/", port: 47123) } == refusal)
        #expect(Self.message { _ = try LoopbackURL.withPath(base, path: "/", port: 47124) } == refusal)
        #expect(Self.message { _ = try LoopbackURL.withPath(base, path: "/", port: 0) } == refusal)
    }

    // MARK: Surfaces and smoke requests

    @Test func surfaceValidationMessages() throws {
        try Self.surface().validate()
        try Self.surface(name: "a", build: "npm ci && npm run build", smoke: [try SmokeRequest.parse("GET /health 200")]).validate()
        let names = "preview names are lowercase letters, digits and dashes (max 24)"
        for name in ["", "Web", "1web", "-web", "web_1", "w" + String(repeating: "x", count: 24), "web/1", "wéb"] {
            #expect(Self.message { try Self.surface(name: name).validate() } == names, "\(name)")
        }
        #expect(Self.message { try Self.surface(name: "w" + String(repeating: "x", count: 23)).validate() } == nil)
        #expect(Self.message { try Self.surface(run: nil).validate() } == "a web preview needs run and url")
        #expect(Self.message { try Self.surface(url: nil).validate() } == "a web preview needs run and url")
        // Plan 4a: other kinds have their own rules (PreviewKindsTests); an unknown kind is refused.
        #expect(Self.message { try Self.surface(kind: "cli").validate() } == "a cli preview needs demo")
        #expect(Self.message { try Self.surface(kind: "tv").validate() } == "kind must be web, backend, cli, ios or macos")
        let commands = "preview commands must be 1–2000 characters"
        #expect(Self.message { try Self.surface(run: "   ").validate() } == commands)
        #expect(Self.message { try Self.surface(run: String(repeating: "x", count: 2001)).validate() } == commands)
        #expect(Self.message { try Self.surface(build: "").validate() } == commands)
        #expect(Self.message { try Self.surface(build: String(repeating: "x", count: 2001)).validate() } == commands)
        #expect(Self.message { try Self.surface(run: String(repeating: "x", count: 2000)).validate() } == nil)
        #expect(Self.message { try Self.surface(url: "http://example.com:3000/").validate() }
                == "preview URLs must be http://127.0.0.1, localhost or [::1] with a port")
        let smoke = "up to 10 smoke requests, each path starting with /"
        let get = SmokeRequest(method: "GET", path: "/", body: nil, expectStatus: nil)
        #expect(Self.message { try Self.surface(smoke: Array(repeating: get, count: 11)).validate() } == smoke)
        #expect(Self.message { try Self.surface(smoke: Array(repeating: get, count: 10)).validate() } == nil)
        for path in ["//evil.com/x", "health", ""] {
            #expect(Self.message { try Self.surface(smoke: [SmokeRequest(method: "GET", path: path, body: nil, expectStatus: nil)]).validate() } == smoke)
        }
        #expect(PreviewSurface.maxPerCompany == 8)
        #expect(SmokeRequest.max == 10 && SmokeRequest.bodyKept == 4096)
    }

    @Test func smokeParse() throws {
        #expect(try SmokeRequest.parse("GET /health 200") == SmokeRequest(method: "GET", path: "/health", body: nil, expectStatus: 200))
        #expect(try SmokeRequest.parse("POST /items {\"a\":1} 201") == SmokeRequest(method: "POST", path: "/items", body: "{\"a\":1}", expectStatus: 201))
        #expect(try SmokeRequest.parse("POST /items {\"a\": 1, \"b\": 2}") == SmokeRequest(method: "POST", path: "/items", body: "{\"a\": 1, \"b\": 2}", expectStatus: nil))
        #expect(try SmokeRequest.parse("GET /") == SmokeRequest(method: "GET", path: "/", body: nil, expectStatus: nil))
        #expect(try SmokeRequest.parse("  get   /x   404 ") == SmokeRequest(method: "GET", path: "/x", body: nil, expectStatus: 404))
        for bad in ["GET health", "", "GET", "GET //evil.com/x", "FETCH /", "GET /x 99", "GET /x 600", "GET /\u{7}x"] {
            #expect(throws: WorkError.self, "\(bad)") { try SmokeRequest.parse(bad) }
        }
        // A round trip through JSON (the `smoke` column).
        let requests = [try SmokeRequest.parse("POST /items {\"a\":1} 201")]
        #expect(try JSONDecoder().decode([SmokeRequest].self, from: JSONEncoder().encode(requests)) == requests)
    }

    @Test func statusAndKindTitles() {
        #expect(PreviewKind.allCases == [.web, .backend, .cli, .ios, .macos, .artifact] && PreviewKind.web.title == "Web")
        #expect(Self.surface().previewKind == .web && Self.surface(kind: "cli").previewKind == .cli && Self.surface(kind: "tv").previewKind == nil)
        let titles: [PreviewStatus: String] = [.idle: "Idle", .building: "Building", .starting: "Starting", .running: "Running",
                                               .failed: "Failed", .stopped: "Stopped", .unavailable: "Unavailable", .ran: "Ran"]
        for (status, title) in titles { #expect(status.title == title) }
        #expect(PreviewSurface.databaseTableName == "previewSurface" && PreviewState.databaseTableName == "previewState")
        let t = PreviewTimeouts()
        #expect(t.build == .seconds(1800) && t.ready == .seconds(120) && t.poll == .milliseconds(500))
        #expect(PreviewLog.cap == 5_242_880 && PreviewLog.keep == 1_048_576 && PortAllocator.range == 47100...47999)
    }

    // MARK: Layout and policy

    @Test func engineLayoutPaths() throws {
        let ws = URL(fileURLWithPath: "/w/acme", isDirectory: true)
        let l = EngineLayout(workspace: ws)
        #expect(l.previewDir.path == "/w/acme/.brahma/preview")
        #expect(l.previewLogs.path == "/w/acme/.brahma/preview/logs")
        #expect(l.previewLog(name: "web").path == "/w/acme/.brahma/preview/logs/web.log")
        #expect(l.releasesDir.path == "/w/acme/.brahma/releases")
        #expect(l.releaseDir(3).path == "/w/acme/.brahma/releases/R-3")
        // Deploys run under the data home, never in the workspace (Task 4 I3).
        let r = try ReleaseLayout(paths: BrahmaPaths(home: URL(fileURLWithPath: "/h", isDirectory: true), workspaces: ws), companyId: "C1")
        #expect(r.root.path == "/h/run/releases/C1")
        #expect(r.releaseDir(3).path == "/h/run/releases/C1/R-3")
        #expect(r.deployTools(cli: "wrangler").path == "/h/run/releases/C1/tools/wrangler")
        #expect(r.placeholderDir.path == "/h/run/releases/C1/placeholder")
        #expect(throws: WorkError.self) { try ReleaseLayout(paths: BrahmaPaths(home: ws, workspaces: ws), companyId: "../x") }
        // PR-16: one export per surface, commit and start; a valid 3a run id.
        let sha = "0123456789abcdef0123456789abcdef01234567"
        let id = try EngineLayout.previewRunId(surfaceId: "8F3A2B1C-0000-4000-8000-000000000000", commit: sha, start: 2)
        #expect(id == "prev-8F3A2B1C-0000-4000-8000-000000000000-0123456789ab-2")
        #expect(id.range(of: "^[A-Za-z0-9][A-Za-z0-9_-]{0,63}$", options: .regularExpression) != nil, "a valid 3a run id")
        #expect(try EngineLayout.previewRunId(surfaceId: "other-surface", commit: sha, start: 2) != id)
        #expect(try EngineLayout.previewRunId(surfaceId: "8F3A2B1C-0000-4000-8000-000000000000", commit: sha, start: 3) != id)
        #expect(throws: WorkError.self) { try EngineLayout.previewRunId(surfaceId: "s", commit: "not-a-sha", start: 1) }
        #expect(throws: WorkError.self) { try EngineLayout.previewRunId(surfaceId: "../x", commit: sha, start: 1) }
        #expect(throws: WorkError.self) { try EngineLayout.previewRunId(surfaceId: "s", commit: sha, start: -1) }
    }

    /// F3 (PR-16): the whole surface id is in the run id, so surfaces that share a prefix never share an export; a UUID id
    /// leaves room for any realistic start count, and one too long for a run id is refused, never cut.
    @Test func previewRunIdsNeverCollide() throws {
        let sha = "0123456789abcdef0123456789abcdef01234567"
        let a = try EngineLayout.previewRunId(surfaceId: "preview-web-a", commit: sha, start: 1)
        let b = try EngineLayout.previewRunId(surfaceId: "preview-web-b", commit: sha, start: 1)
        #expect(a != b)
        let uuids = (0..<50).map { _ in UUID().uuidString }
        let ids = try uuids.map { try EngineLayout.previewRunId(surfaceId: $0, commit: sha, start: 1) }
        #expect(Set(ids).count == uuids.count)
        let shared = "12345678-0000-4000-8000-00000000000"
        #expect(try EngineLayout.previewRunId(surfaceId: shared + "1", commit: sha, start: 1)
                != (try EngineLayout.previewRunId(surfaceId: shared + "2", commit: sha, start: 1)))
        let uuid = "8F3A2B1C-0000-4000-8000-000000000000"
        #expect(try EngineLayout.previewRunId(surfaceId: uuid, commit: sha, start: 999_999_999).count == 64)
        #expect(throws: WorkError.self) { try EngineLayout.previewRunId(surfaceId: uuid, commit: sha, start: 1_000_000_000) }
        #expect(throws: WorkError.self) { try EngineLayout.previewRunId(surfaceId: String(repeating: "a", count: 60), commit: sha, start: 1) }
    }

    @Test func serverPolicyIsScoped() throws {
        let root = try tempDir().resolvedForSandbox
        let home = root.appending(path: "data"), wss = root.appending(path: "wss"), user = root.appending(path: "user")
        for dir in [home, wss, user] { try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true) }
        let store = try Store.inMemory()
        let company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: wss)
        let ws = URL(fileURLWithPath: company.workspacePath, isDirectory: true)
        let l = EngineLayout(workspace: ws)
        let run = BrahmaPaths(home: home, workspaces: wss).exportDir(runId: "prev-s1-0123456789ab-1")
        try FileManager.default.createDirectory(at: run, withIntermediateDirectories: true)
        let p = PreviewPolicy.server(l, run: run, company: company, port: 47123)
        // F1: only its own export; the engine writes the log, so the logs directory is in no writable list.
        #expect(p.writable == [run.resolvedForSandbox])
        #expect(!p.writable.contains { $0.path.hasPrefix(l.previewDir.resolvedForSandbox.path) })
        #expect(p.readable == [run.resolvedForSandbox])
        let defaults = CompanyNetwork.scope(company: company, grantDomains: [], grantWebDomains: []).allowedDomains
        #expect(p.network == .loopbackListen(allow: defaults, ports: [47123]))
        #expect(p.toolchain)
        // PR-19: no shared cache, and nothing else of the workspace.
        let shared = SandboxLayout(paths: BrahmaPaths(home: home, workspaces: wss), company: company, agentHandle: "preview").sharedCache
        #expect(!(p.writable + p.readable).contains { $0.path.hasPrefix(shared.resolvedForSandbox.path) || $0.path == ws.resolvedForSandbox.path })
        #expect(!(p.writable + p.readable).contains { $0.path.hasPrefix(l.releasesDir.resolvedForSandbox.path) })
        // It passes the sandbox's own policy check (resolved paths, no writable containing a workspace).
        let baseline = SandboxBaseline(userHome: user, protected: [], darwinUserTemp: nil, darwinUserCache: nil,
                                       engineHomes: [home], companyWorkspaces: [ws.resolvedForSandbox])
        try SandboxPolicyCheck.validate(p, baseline: baseline)
        // An owner-added domain and a grant reach the allow list.
        var wider = company
        wider.allowedDomains = ["api.example.com"]
        let q = PreviewPolicy.server(l, run: run, company: wider, port: 47123, grantDomains: ["cdn.example.org"])
        #expect(q.network == .loopbackListen(allow: CompanyNetwork.scope(company: wider, grantDomains: ["cdn.example.org"],
                                                                         grantWebDomains: []).allowedDomains, ports: [47123]))
    }
}
