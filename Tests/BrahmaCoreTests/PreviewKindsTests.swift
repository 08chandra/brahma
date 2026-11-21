import Testing
import Foundation
import GRDB
@testable import BrahmaCore

/// Runs the built `brahma` binary against a throwaway data home.
private func brahma(_ args: [String], home: URL, env: [String: String] = [:]) throws -> (status: Int32, stdout: String, stderr: String) {
    let url = brahmaExecutableURL()
    try #require(FileManager.default.isExecutableFile(atPath: url.path), "build the brahma product first")
    let p = Process()
    p.executableURL = url
    p.arguments = args
    var e = cliEnvironment(home: home)
    e.merge(env) { _, new in new }
    p.environment = e
    let out = Pipe(), err = Pipe()
    p.standardOutput = out; p.standardError = err
    p.standardInput = FileHandle.nullDevice
    try p.run()
    let o = out.fileHandleForReading.readDataToEndOfFile(), r = err.fileHandleForReading.readDataToEndOfFile()
    p.waitUntilExit()
    return (p.terminationStatus, String(decoding: o, as: UTF8.self), String(decoding: r, as: UTF8.self))
}

/// A preview adapter that records what it is asked and answers from a script (Plan 4a Task 4: adapter injection).
final class RecordingAdapter: PreviewAdapter, @unchecked Sendable {
    let kind: PreviewKind
    private let lock = NSLock()
    private var _starts: [PreviewContext] = []
    private var _stops: [(PreviewContext, PreviewState)] = []
    private var _result: PreviewUpdate
    private var _unavailable: String?

    init(_ kind: PreviewKind, result: PreviewUpdate = PreviewUpdate(status: .ran, message: "exit 0"), unavailable: String? = nil) {
        self.kind = kind; _result = result; _unavailable = unavailable
    }

    var starts: [PreviewContext] { lock.withLock { _starts } }
    var stops: [(PreviewContext, PreviewState)] { lock.withLock { _stops } }
    func answer(_ update: PreviewUpdate) { lock.withLock { _result = update } }

    func availability() -> String? { lock.withLock { _unavailable } }
    func start(_ c: PreviewContext) async -> PreviewUpdate { lock.withLock { _starts.append(c); return _result } }
    func stop(_ c: PreviewContext, state: PreviewState) async { lock.withLock { _stops.append((c, state)) } }
}

/// Non-web preview kinds on L's engine: the kind rules, the per-kind sandbox policies, adapter injection, port 0, the
/// terminal `ran`, the iOS owner gate, the web demo default, and the tool and CLI arguments.
@Suite(.scratch) struct PreviewKindsTests {
    struct Fx {
        let w: World
        let company: Company
        let devops: Agent
        let f: GitFixture
        let deps: PreviewDependencies
        let sandbox: FakeSandbox
        let adapters: [PreviewKind: RecordingAdapter]
        let runner: PreviewRunner

        static let fast = PreviewTimeouts(ready: .seconds(600), poll: .milliseconds(50))

        /// A company with `main` committed and a runner whose adapters for `kinds` are recorders (the web one too when listed;
        /// otherwise L's real web adapter from `PreviewAdapters.defaults`).
        init(kinds: [PreviewKind] = [.web, .backend, .cli, .ios, .macos], results: [PreviewKind: PreviewUpdate] = [:]) throws {
            let root = try tempDir()
            let data = root.appending(path: "data", directoryHint: .isDirectory)
            try FileManager.default.createDirectory(at: data, withIntermediateDirectories: true)
            let store = try Store(path: data.appending(path: "brahma.sqlite").path)
            sandbox = FakeSandbox()
            deps = PreviewDependencies.fake(sandbox: sandbox)
            w = try World(store: store, previewDeps: deps)
            company = try w.company("Acme")
            devops = try w.hire(company, "devops")
            f = GitFixture(existing: URL(fileURLWithPath: company.workspacePath, isDirectory: true))
            var recorders: [PreviewKind: RecordingAdapter] = [:]
            for kind in kinds {
                let fallback = kind.usesURL ? PreviewUpdate(status: .running, message: nil, resolvedURL: "http://127.0.0.1:1/")
                    : PreviewUpdate(status: .ran, message: "exit 0")
                recorders[kind] = RecordingAdapter(kind, result: results[kind] ?? fallback)
            }
            adapters = recorders
            var table = PreviewAdapters.defaults(deps)
            for (kind, adapter) in recorders { table[kind] = adapter }
            let paths = w.paths
            runner = PreviewRunner(store: store, paths: paths, deps: deps,
                                   sandboxLayout: { SandboxLayout(paths: paths, company: $0, agentHandle: "preview") },
                                   timeouts: Self.fast, memory: { false }, clock: w.clock.function, adapters: table)
            try merge(["README.md": "one"])
        }

        var store: Store { w.store }
        var now: Date { w.clock.now }

        @discardableResult
        func merge(_ files: [String: String]) throws -> String {
            for (path, text) in files { try f.write(path, text) }
            try f.git(["add", "-A"])
            try f.git(["commit", "-q", "-m", "change"])
            return try store.acceptMainCommit(companyId: company.id).head
        }

        func tools() -> CompanyTools { CompanyTools(store: store, companyId: company.id, agentId: devops.id) }

        /// (ok, text) of one `set_preview_command` call. The tool stamps the wall clock, so the test clock then moves past it
        /// (as the engine's clock would): a start after this sees the change once.
        func set(_ args: [String: JSONValue]) -> (ok: Bool, text: String) {
            defer { let lag = Date().timeIntervalSince(now); if lag > -1 { w.clock.advance(lag + 1) } }
            do { return (true, try tools().call(name: "set_preview_command", arguments: args)) }
            catch let e as ToolError { return (false, e.message) } catch { return (false, "\(error)") }
        }

        func cli(_ name: String = "tool", demo: String = "./demo.sh") throws {
            try #require(set(["name": .string(name), "kind": .string("cli"), "demo": .string(demo)]).ok)
        }

        func ios(_ name: String = "phone", appPath: String = "build/App.app") -> (ok: Bool, text: String) {
            set(["name": .string(name), "kind": .string("ios"), "build": .string("xcodebuild -scheme App"),
                 "app_path": .string(appPath), "bundle_id": .string("com.acme.app"), "device": .string("iPhone 15 Pro")])
        }

        func surface(_ name: String) throws -> PreviewSurface {
            try #require(try store.previewSurfaces(companyId: company.id).first { $0.name == name })
        }

        func state(_ name: String) throws -> PreviewState {
            try #require(try store.previewStates(companyId: company.id)[try surface(name).id])
        }

        /// Passes (each starts at most one surface) until nothing more starts.
        func settle(_ passes: Int = 8) async {
            for _ in 0..<passes {
                await runner.reconcile(now: now)
                await runner.waitForStarts()
            }
        }

        func asks() throws -> [Ask] { try store.asks(companyId: company.id) }

        var sandboxLayout: SandboxLayout { SandboxLayout(paths: w.paths, company: company, agentHandle: "preview") }
        var layout: EngineLayout { EngineLayout(workspace: URL(fileURLWithPath: company.workspacePath, isDirectory: false)) }
    }

    static func message(_ body: () throws -> Void) -> String? {
        do { try body(); return nil } catch let e as WorkError { return e.message } catch { return "\(error)" }
    }

    static func surface(kind: PreviewKind, build: String? = nil, run: String? = nil, url: String? = nil, demo: String? = nil,
                        openapiPath: String? = nil, appPath: String? = nil, bundleId: String? = nil, device: String? = nil) -> PreviewSurface {
        PreviewSurface(id: "s1", companyId: "c1", name: "p", kind: kind.rawValue, position: 0, build: build, run: run, url: url,
                       setById: "owner", createdAt: Date(), updatedAt: Date(), demo: demo, openapiPath: openapiPath,
                       appPath: appPath, bundleId: bundleId, device: device)
    }

    // MARK: Model

    @Test func kindValidationMessages() throws {
        let url = "http://127.0.0.1:{port}/"
        // Each kind's required fields.
        #expect(Self.message { try Self.surface(kind: .backend, run: "x").validate() } == "a backend preview needs run and url")
        #expect(Self.message { try Self.surface(kind: .backend, url: url).validate() } == "a backend preview needs run and url")
        #expect(Self.message { try Self.surface(kind: .backend, run: "x", url: url, openapiPath: "api/openapi.json").validate() } == nil)
        #expect(Self.message { try Self.surface(kind: .cli, build: "make").validate() } == "a cli preview needs demo")
        #expect(Self.message { try Self.surface(kind: .cli, demo: "./demo.sh").validate() } == nil)
        let ios = "an ios preview needs build, app_path and bundle_id"
        #expect(Self.message { try Self.surface(kind: .ios, appPath: "A.app", bundleId: "com.a").validate() } == ios)
        #expect(Self.message { try Self.surface(kind: .ios, build: "b", bundleId: "com.a").validate() } == ios)
        #expect(Self.message { try Self.surface(kind: .ios, build: "b", appPath: "A.app").validate() } == ios)
        #expect(Self.message { try Self.surface(kind: .ios, build: "b", appPath: "A.app", bundleId: "com.a", device: "iPhone 15 (Pro)").validate() } == nil)
        let macos = "a macos preview needs build and app_path"
        #expect(Self.message { try Self.surface(kind: .macos, build: "b").validate() } == macos)
        #expect(Self.message { try Self.surface(kind: .macos, appPath: "A.app").validate() } == macos)
        #expect(Self.message { try Self.surface(kind: .macos, build: "b", appPath: "A.app").validate() } == nil)
        #expect(Self.message { try Self.surface(kind: .artifact, demo: "x").validate() } == "artifacts appear automatically; use publish_artifact")
        var unknown = Self.surface(kind: .cli, demo: "x"); unknown.kind = "tv"
        #expect(Self.message { try unknown.validate() } == "kind must be web, backend, cli, ios or macos")
        // Paths: relative to the repo root.
        let paths = "paths must be relative to the repo root"
        for bad in ["/Applications/App.app", "../App.app", "build/../../App.app", "a/..", "..", "", "a\\b", "a\nb"] {
            #expect(Self.message { try Self.surface(kind: .macos, build: "b", appPath: bad).validate() } == paths, "\(bad)")
            #expect(Self.message { try Self.surface(kind: .backend, run: "x", url: url, openapiPath: bad).validate() } == paths, "\(bad)")
        }
        #expect(Self.message { try Self.surface(kind: .macos, build: "b", appPath: "build/..x/App.app").validate() } == nil)
        // Bundle ids: letters, digits, '.' and '-', 1–155.
        let bundle = "bundle_id may contain letters, digits, '.' and '-'"
        for bad in ["", "com.acme/app", "com.acme app", "com.acme_app", "com.acme\n", "cöm.acme", String(repeating: "a", count: 156)] {
            #expect(Self.message { try Self.surface(kind: .ios, build: "b", appPath: "A.app", bundleId: bad).validate() } == bundle, "\(bad)")
        }
        #expect(Self.message { try Self.surface(kind: .ios, build: "b", appPath: "A.app", bundleId: String(repeating: "a", count: 155)).validate() } == nil)
        // Devices: 1–64 letters, digits, spaces and ()._-.
        let device = "device names are 1–64 letters, digits, spaces and ()._-"
        for bad in ["", "iPhone;rm -rf", "iPhone\n", "iPhone 15 Pro'", String(repeating: "a", count: 65)] {
            #expect(Self.message { try Self.surface(kind: .ios, build: "b", appPath: "A.app", bundleId: "com.a", device: bad).validate() } == device, "\(bad)")
        }
        // L's command, URL and smoke rules still apply to every kind.
        #expect(Self.message { try Self.surface(kind: .cli, demo: "  ").validate() } == "preview commands must be 1–2000 characters")
        #expect(Self.message { try Self.surface(kind: .cli, demo: String(repeating: "x", count: 2001)).validate() } == "preview commands must be 1–2000 characters")
        #expect(Self.message { try Self.surface(kind: .backend, run: "x", url: "http://example.com:3000/").validate() }
                == "preview URLs must be http://127.0.0.1, localhost or [::1] with a port")
        var smoky = Self.surface(kind: .backend, run: "x", url: url)
        smoky.smoke = [SmokeRequest(method: "GET", path: "//evil", body: nil, expectStatus: nil)]
        #expect(Self.message { try smoky.validate() } == "up to 10 smoke requests, each path starting with /")
        // Titles.
        #expect(PreviewKind.allCases.map(\.title) == ["Web", "Backend", "CLI", "iOS", "macOS", "Artifacts"])
        #expect(PreviewStatus.ran.title == "Ran")
        #expect(PreviewTimeouts().demo == .seconds(120))
    }

    @Test func webStillValid() async throws {
        let url = "http://127.0.0.1:{port}/"
        #expect(Self.message { try Self.surface(kind: .web, run: "npm start", url: url).validate() } == nil)
        #expect(Self.message { try Self.surface(kind: .web, run: "npm start").validate() } == "a web preview needs run and url")
        #expect(Self.message { try Self.surface(kind: .web, url: url).validate() } == "a web preview needs run and url")
        let x = try Fx(kinds: [])
        let set = x.set(["name": .string("web"), "kind": .string("web"), "run": .string("npm start"), "url": .string(url)])
        #expect(set.ok, "\(set.text)")
        #expect(set.text == "Preview web (web) set; the engine builds it from main.")
        // L's real web adapter is the default one.
        await x.settle(1)
        #expect(try x.state("web").status == .running)
        #expect(x.sandbox.calls.filter { $0.kind == .spawn }.count == 1)
        await x.runner.stopAll()
    }

    // MARK: Tool and CLI

    @Test func toolAcceptsNewKinds() throws {
        let x = try Fx(kinds: [])
        #expect(x.set(["name": .string("tool"), "kind": .string("cli"), "build": .string("make"), "demo": .string("./demo.sh")]).text
                == "Preview tool (cli) set; the engine builds it from main.")
        let tool = try x.surface("tool")
        #expect(tool.kind == "cli" && tool.demo == "./demo.sh" && tool.build == "make" && tool.run == nil && tool.url == nil)
        #expect(x.set(["name": .string("api"), "kind": .string("backend"), "run": .string("PORT={port} ./serve"),
                       "url": .string("http://127.0.0.1:{port}/"), "openapi_path": .string("docs/openapi.json"),
                       "smoke": .array([.string("GET /health 200")])]).ok)
        #expect(try x.surface("api").openapiPath == "docs/openapi.json")
        #expect(x.ios().ok)
        let phone = try x.surface("phone")
        #expect(phone.kind == "ios" && phone.appPath == "build/App.app" && phone.bundleId == "com.acme.app" && phone.device == "iPhone 15 Pro")
        #expect(phone.outsideSandboxApprovedAt == nil && phone.outsideSandboxAskId == nil)
        #expect(x.set(["name": .string("mac"), "kind": .string("macos"), "build": .string("xcodebuild"), "app_path": .string("build/Mac.app")]).ok)
        #expect(try x.surface("mac").appPath == "build/Mac.app")
        // Refusals are the model's messages.
        #expect(x.ios("bad", appPath: "/Applications/Evil.app").text == "paths must be relative to the repo root")
        #expect(x.set(["name": .string("art"), "kind": .string("artifact")]).text == "artifacts appear automatically; use publish_artifact")
        #expect(x.set(["name": .string("tv"), "kind": .string("tv"), "demo": .string("x")]).text == "kind must be web, backend, cli, ios or macos")
        #expect(x.set(["name": .string("bad"), "kind": .string("ios"), "build": .string("b"), "app_path": .string("A.app"),
                       "bundle_id": .string("com.acme;x")]).text == "bundle_id may contain letters, digits, '.' and '-'")
        // No argument an agent passes approves a Simulator preview.
        _ = x.set(["name": .string("phone"), "kind": .string("ios"), "build": .string("xcodebuild -scheme App"),
                   "app_path": .string("build/App.app"), "bundle_id": .string("com.acme.app"),
                   "outside_sandbox_approved_at": .string("2020-01-01T00:00:00Z"), "outsideSandboxApprovedAt": .string("now"),
                   "outside_sandbox_ask_id": .string("A-1")])
        #expect(try x.surface("phone").outsideSandboxApprovedAt == nil && x.surface("phone").outsideSandboxAskId == nil)
        // The schema lists the new arguments.
        let spec = try #require(CompanyTools.previewToolSpecs().first { $0.name == "set_preview_command" })
        let text = "\(spec.inputSchema)"
        for key in ["demo", "openapi_path", "app_path", "bundle_id", "device"] { #expect(text.contains(key), "\(key)") }
    }

    @Test func previewCLIFlags() throws {
        let owner = try OwnerTestHome(); defer { withExtendedLifetime(owner) {} }
        let home = owner.url
        #expect(try brahma(["company", "create", "Acme", "--goal", "g", "--agents", "0"], home: home).status == 0)
        let cli = try brahma(["preview", "set", "Acme", "tool", "--kind", "cli", "--build", "make", "--demo", "./demo.sh"], home: home)
        #expect(cli.status == 0, "\(cli.stderr)"); #expect(cli.stdout == "Preview tool (cli) set; the engine builds it from main.\n")
        let ios = try brahma(["preview", "set", "Acme", "phone", "--kind", "ios", "--build", "xcodebuild -scheme App",
                              "--app-path", "build/App.app", "--bundle-id", "com.acme.app", "--device", "iPhone 15 Pro"], home: home)
        #expect(ios.status == 0, "\(ios.stderr)")
        let api = try brahma(["preview", "set", "Acme", "api", "--kind", "backend", "--run", "./serve", "--url", "http://127.0.0.1:{port}/",
                              "--openapi", "docs/openapi.json"], home: home)
        #expect(api.status == 0, "\(api.stderr)")
        let mac = try brahma(["preview", "set", "Acme", "mac", "--kind", "macos", "--build", "xcodebuild", "--app-path", "build/Mac.app"], home: home)
        #expect(mac.status == 0, "\(mac.stderr)")
        // The web default still works without --kind.
        let web = try brahma(["preview", "set", "Acme", "web", "--run", "npm start", "--url", "http://127.0.0.1:{port}/"], home: home)
        #expect(web.status == 0, "\(web.stderr)"); #expect(web.stdout == "Preview web (web) set; the engine builds it from main.\n")
        let list = try brahma(["preview", "Acme"], home: home)
        #expect(list.stdout.contains("tool  cli  idle") && list.stdout.contains("phone  ios  idle") && list.stdout.contains("mac  macos  idle"),
                "\(list.stdout)")
        // Refusals.
        let abs = try brahma(["preview", "set", "Acme", "evil", "--kind", "macos", "--build", "b", "--app-path", "/Applications/X.app"], home: home)
        #expect(abs.status != 0); #expect(abs.stderr.contains("paths must be relative to the repo root"))
        let art = try brahma(["preview", "set", "Acme", "art", "--kind", "artifact"], home: home)
        #expect(art.status != 0); #expect(art.stderr.contains("artifacts appear automatically; use publish_artifact"))
        let noDemo = try brahma(["preview", "set", "Acme", "x", "--kind", "cli"], home: home)
        #expect(noDemo.status != 0); #expect(noDemo.stderr.contains("a cli preview needs demo"))
        // An agent's shell cannot set one.
        let agent = try brahma(["preview", "set", "Acme", "tool", "--kind", "cli", "--demo", "x"], home: home, env: ["BRAHMA_AGENT_ID": "a1"])
        #expect(agent.status != 0); #expect(agent.stderr.contains("owner commands can't run inside an agent turn"))
    }

    // MARK: Runner

    @Test func injectedAdaptersUsed() async throws {
        let defaults = PreviewAdapters.defaults(PreviewDependencies.fake())
        #expect(Set(defaults.keys) == [.web] && defaults[.web] is WebAdapter)
        // An injected web adapter replaces L's: no server is spawned.
        let x = try Fx(kinds: [.web])
        #expect(x.set(["name": .string("web"), "kind": .string("web"), "run": .string("npm start"), "url": .string("http://127.0.0.1:{port}/")]).ok)
        // A kind with no adapter is unavailable, without an export or a start.
        try x.cli()
        await x.settle()
        let web = try #require(x.adapters[.web])
        #expect(web.starts.count == 1 && web.starts.first?.surface.name == "web")
        #expect(x.sandbox.calls.isEmpty)
        #expect(try x.state("web").status == .running)
        let tool = try x.state("tool")
        #expect(tool.status == .unavailable && tool.message == "CLI previews are not available on this engine yet", "\(tool)")
        // An adapter that is not available here says why.
        let y = try Fx(kinds: [.cli])
        let off = RecordingAdapter(.cli, unavailable: "no demos on this machine")
        let paths = y.w.paths
        let runner = PreviewRunner(store: y.store, paths: paths, deps: y.deps,
                                   sandboxLayout: { SandboxLayout(paths: paths, company: $0, agentHandle: "preview") },
                                   timeouts: Fx.fast, memory: { false }, clock: y.w.clock.function, adapters: [.cli: off])
        try y.cli()
        await runner.reconcile(now: y.now); await runner.waitForStarts()
        #expect(off.starts.isEmpty)
        let state = try y.state("tool")
        #expect(state.status == .unavailable && state.message == "no demos on this machine")
        await x.runner.stopAll()
    }

    @Test func policyPerKind() async throws {
        let x = try Fx()
        try x.cli()
        #expect(x.set(["name": .string("api"), "kind": .string("backend"), "run": .string("./serve"), "url": .string("http://127.0.0.1:{port}/")]).ok)
        #expect(x.set(["name": .string("mac"), "kind": .string("macos"), "build": .string("xcodebuild"), "app_path": .string("build/Mac.app")]).ok)
        #expect(x.ios().ok)
        await x.settle()
        // The iOS build needs the owner first.
        let ask = try #require(try x.asks().first)
        try x.store.ownerDecide(askId: ask.id, approve: true)
        await x.settle()
        let allow = CompanyNetwork.scope(company: x.company, grantDomains: [], grantWebDomains: []).allowedDomains
        // cli → oneShot: outbound only, reads and writes only its run (no logs, no shared cache), no toolchain.
        let cli = try #require(x.adapters[.cli]?.starts.first)
        let run = cli.run.resolvedForSandbox
        #expect(cli.policy == SandboxPolicy(writable: [run], readable: [run], network: .outbound(allow: allow), toolchain: false))
        #expect(!cli.policy.writable.contains(x.layout.previewLogs.resolvedForSandbox))
        #expect(!cli.policy.writable.contains(x.sandboxLayout.sharedCache.resolvedForSandbox))
        #expect(cli.appPolicy == nil)
        #expect(!FileManager.default.fileExists(atPath: cli.run.appending(path: ".git").path))
        // ios build → appleBuild (the toolchain), derived data inside the run.
        let ios = try #require(x.adapters[.ios]?.starts.first)
        let iosRun = ios.run.resolvedForSandbox
        #expect(ios.policy == SandboxPolicy(writable: [iosRun], readable: [iosRun], network: .outbound(allow: allow), toolchain: true))
        #expect(ios.environment["BRAHMA_DERIVED_DATA"] == ios.run.appending(path: ".build/DerivedData").path)
        // macos: appleBuild for the build, guiApp for the app.
        let mac = try #require(x.adapters[.macos]?.starts.first)
        let macRun = mac.run.resolvedForSandbox
        #expect(mac.policy == SandboxPolicy(writable: [macRun], readable: [macRun], network: .outbound(allow: allow), toolchain: true))
        let appData = x.sandboxLayout.sharedCache.appending(path: "apps/mac").resolvedForSandbox
        #expect(mac.appPolicy == SandboxPolicy(writable: [appData], readable: [macRun], network: .outbound(allow: allow), toolchain: true))
        #expect(mac.environment["BRAHMA_DERIVED_DATA"] == mac.run.appending(path: ".build/DerivedData").path)
        // backend → L's server on its allocated port.
        let api = try #require(x.adapters[.backend]?.starts.first)
        let port = try #require(try x.state("api").port)
        #expect(PortAllocator.range.contains(port) && api.port == port)
        #expect(api.policy.network == .loopbackListen(allow: allow, ports: [UInt16(port)]))
        #expect(api.policy == PreviewPolicy.server(x.layout, run: api.run, company: x.company, port: port))
        // The static forms agree.
        #expect(PreviewPolicy.oneShot(x.layout, run: cli.run, company: x.company, sandbox: x.sandboxLayout) == cli.policy)
        #expect(PreviewPolicy.guiApp(x.layout, run: mac.run, company: x.company, sandbox: x.sandboxLayout, surface: "mac") == mac.appPolicy)
        await x.runner.stopAll()
    }

    @Test func nonURLKindsGetPortZero() async throws {
        let x = try Fx()
        try x.cli()
        #expect(x.set(["name": .string("mac"), "kind": .string("macos"), "build": .string("xcodebuild"), "app_path": .string("build/Mac.app")]).ok)
        await x.settle()
        for (kind, name) in [(PreviewKind.cli, "tool"), (.macos, "mac")] {
            let c = try #require(x.adapters[kind]?.starts.first)
            #expect(c.port == 0 && c.environment["PORT"] == "0", "\(kind)")
            #expect(try x.state(name).port == nil, "\(kind)")
        }
        #expect(try x.store.previewPortHolders().isEmpty)
        let cli = try #require(x.adapters[.cli]?.starts.first)
        #expect(cli.outputURL == x.layout.previewOutput(name: "tool"))
        await x.runner.stopAll()
    }

    @Test func ranIsTerminal() async throws {
        let x = try Fx(results: [.cli: PreviewUpdate(status: .ran, message: "exit 0", outputPath: "/out/tool.out")])
        try x.cli()
        await x.settle()
        let cli = try #require(x.adapters[.cli])
        #expect(cli.starts.count == 1)
        var state = try x.state("tool")
        #expect(state.status == .ran && state.message == "exit 0" && state.outputPath == "/out/tool.out" && state.pid == nil, "\(state)")
        let main = try x.store.company(id: x.company.id)?.mainCommit
        #expect(state.exits.isEmpty && state.commit == main)
        // Nothing re-runs it while nothing changed, however long.
        x.w.clock.advance(3600)
        await x.settle()
        #expect(cli.starts.count == 1)
        #expect(try x.state("tool").status == .ran)
        // A restart flag re-runs it.
        try x.store.requestPreviewRestart(surfaceId: try x.surface("tool").id, by: .owner, now: x.now)
        await x.settle()
        #expect(cli.starts.count == 2)
        // So does a new main (after the debounce).
        try x.merge(["README.md": "two"])
        await x.settle()
        x.w.clock.advance(PreviewRunner.debounce + 1)
        await x.settle()
        #expect(cli.starts.count == 3)
        // And a change to it.
        x.w.clock.advance(1)
        try x.cli(demo: "./demo.sh --long")
        x.w.clock.advance(1)
        await x.settle()
        #expect(cli.starts.count == 4 && cli.starts.last?.surface.demo == "./demo.sh --long")
        state = try x.state("tool")
        #expect(state.status == .ran && state.exits.isEmpty)
        // The digest names the kind and its result.
        let line = try #require(TurnDigest.previewLine([(try x.surface("tool"), state)]))
        #expect(line.hasPrefix("Previews: tool (CLI) Ran: exit 0 @"), "\(line)")
        await x.runner.stopAll()
        // The engine's stop leaves a finished run as it was.
        #expect(try x.state("tool").status == .ran)
    }

    @Test func iosNeedsOwnerAsk() async throws {
        let x = try Fx(results: [.ios: PreviewUpdate(status: .running, message: nil, simulatorId: "SIM-1")])
        #expect(x.ios().ok)
        await x.settle()
        let ios = try #require(x.adapters[.ios])
        #expect(ios.starts.isEmpty)
        var state = try x.state("phone")
        #expect(state.status == .unavailable && state.message == SimulatorApproval.waitingMessage, "\(state)")
        #expect(SimulatorApproval.waitingMessage == "waiting for the owner to allow a Simulator preview (it runs outside the sandbox)")
        // One owner ask, filed once.
        await x.settle()
        var asks = try x.asks()
        #expect(asks.count == 1)
        let ask = try #require(asks.first)
        #expect(ask.kind == .other && ask.category == "permissions" && ask.risk == .high && ask.requesterId == "system")
        #expect(ask.title == "Allow iOS Simulator preview phone" && ask.status == .pendingOwner)
        #expect(ask.summary == "The iOS Simulator installs and runs the app outside Brahma's sandbox: it can read and write the Simulator's own data and reach the network. Approve only if you trust this company's code.")
        #expect(try x.surface("phone").outsideSandboxAskId == ask.id)
        // An agent's look-alike ask approved by the owner approves nothing.
        let forged = try x.store.propose(companyId: x.company.id, by: .agent(x.devops.id), kind: .other, risk: .high, category: "permissions",
                                         title: "Allow iOS Simulator preview phone", summary: SimulatorApproval.summary,
                                         subjectId: "preview-simulator:" + (try x.surface("phone").id), viaOwner: true)
        try x.store.ownerDecide(askId: forged.id, approve: true)
        await x.settle()
        #expect(try x.surface("phone").outsideSandboxApprovedAt == nil && ios.starts.isEmpty)
        // The owner's approval of the engine's ask: the next pass starts it.
        try x.store.ownerDecide(askId: ask.id, approve: true, now: x.now)
        #expect(try x.surface("phone").outsideSandboxApprovedAt != nil)
        await x.settle()
        #expect(ios.starts.count == 1)
        state = try x.state("phone")
        #expect(state.status == .running && state.simulatorId == "SIM-1", "\(state)")
        // Changing app_path clears the approval: the Simulator app is stopped and a new ask is filed.
        x.w.clock.advance(1)
        #expect(x.ios(appPath: "build/Other.app").ok)
        let changed = try x.surface("phone")
        #expect(changed.outsideSandboxApprovedAt == nil && changed.outsideSandboxAskId == nil)
        await x.settle()
        #expect(ios.starts.count == 1)
        #expect(ios.stops.contains { $0.1.simulatorId == "SIM-1" })
        state = try x.state("phone")
        #expect(state.status == .unavailable && state.message == SimulatorApproval.waitingMessage)
        asks = try x.asks().filter { $0.requesterId == "system" }
        #expect(asks.count == 2)
        let second = try #require(asks.first { $0.id != ask.id })
        #expect(try x.surface("phone").outsideSandboxAskId == second.id)
        // A change while that ask is open supersedes it; a declined ask leaves it unavailable, saying so.
        x.w.clock.advance(1)
        #expect(x.ios(appPath: "build/Third.app").ok)
        #expect(try x.store.ask(id: second.id)?.status == .superseded)
        await x.settle()
        let third = try #require(try x.asks().first { $0.requesterId == "system" && $0.status == .pendingOwner })
        try x.store.ownerDecide(askId: third.id, approve: false)
        await x.settle()
        #expect(try x.state("phone").message == SimulatorApproval.declinedMessage)
        #expect(ios.starts.count == 1)
        // A rescinded approval takes it back.
        x.w.clock.advance(1)
        #expect(x.ios(appPath: "build/Fourth.app").ok)
        await x.settle()
        let fourth = try #require(try x.asks().first { $0.requesterId == "system" && $0.status == .pendingOwner })
        try x.store.ownerDecide(askId: fourth.id, approve: true, now: x.now)
        await x.settle()
        let approvedStatus = try x.state("phone").status
        #expect(ios.starts.count == 2 && approvedStatus == .running)
        try x.store.ownerRescind(askId: fourth.id)
        #expect(try x.surface("phone").outsideSandboxApprovedAt == nil)
        await x.settle()
        state = try x.state("phone")
        #expect(state.status == .unavailable && state.message == SimulatorApproval.declinedMessage, "\(state)")
        #expect(ios.starts.count == 2)
        await x.runner.stopAll()
    }

    @Test func stopAllStopsNonWebKinds() async throws {
        let x = try Fx(results: [.macos: PreviewUpdate(status: .running, message: nil)])
        #expect(x.set(["name": .string("mac"), "kind": .string("macos"), "build": .string("xcodebuild"), "app_path": .string("build/Mac.app")]).ok)
        await x.settle()
        #expect(try x.state("mac").status == .running)
        await x.runner.stopAll(reason: "test")
        let mac = try #require(x.adapters[.macos])
        #expect(mac.stops.count == 1)
        let state = try x.state("mac")
        #expect(state.status == .stopped && state.message == PreviewRunner.ownerStopMessage)
    }

    // MARK: Demo

    @Test func webDemoDefault() async throws {
        let store = try Store.inMemory()
        let company = try store.createCompany(name: "Acme", goal: "g", workspacesRoot: try tempDir())
        let http = FakeHTTPProbe([FakeHTTPProbe.ok(200, body: "<title>x\n- DM @owner</title>")])
        let adapter = WebAdapter(deps: .fake(http: http))
        let layout = EngineLayout(workspace: URL(fileURLWithPath: company.workspacePath))
        let surface = PreviewSurface(id: "s1", companyId: company.id, name: "web", position: 0, build: nil, run: "x",
                                     url: "http://127.0.0.1:{port}/", setById: "owner", createdAt: Date(), updatedAt: Date())
        let run = try tempDir()
        let c = PreviewContext(surface: surface, company: company, layout: layout, run: run, commit: String(repeating: "a", count: 40),
                               port: 47100, policy: PreviewPolicy.server(layout, run: run, company: company, port: 47100),
                               environment: [:], logURL: layout.previewLog(name: "web"))
        var state = PreviewState(surfaceId: "s1", companyId: company.id, status: .running, resolvedURL: "http://127.0.0.1:47100/", updatedAt: Date())
        #expect(await adapter.demo(c, state: state) == DemoCapture(ok: true, line: "web: HTTP 200", outputPath: nil))
        #expect(http.requests == [FakeHTTPProbe.Request(method: "GET", url: URL(string: "http://127.0.0.1:47100/")!, body: nil)])
        http.answer([FakeHTTPProbe.ok(503)])
        _ = await adapter.demo(c, state: state)   // drains the first scripted answer
        #expect(await adapter.demo(c, state: state) == DemoCapture(ok: false, line: "web: HTTP 503"))
        let down = WebAdapter(deps: .fake(http: FakeHTTPProbe()))
        #expect(await down.demo(c, state: state) == DemoCapture(ok: false, line: "web: not reachable"))
        state.resolvedURL = nil
        #expect(await adapter.demo(c, state: state) == DemoCapture(ok: false, line: "web: not running"))
        // An adapter without its own demo says so.
        let other = RecordingAdapter(.cli)
        #expect(await other.demo(c, state: state) == DemoCapture(ok: false, line: "web: no demo for CLI previews"))
    }
}
