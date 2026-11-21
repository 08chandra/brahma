import Foundation
import Testing
import BrahmaCore
@testable import BrahmaAppModel

/// Plan 4a Task 8b: the ARTIFACTS tab, the bodies of the non-web kinds, `FileBody`'s render modes and the artifact
/// navigation policy.
@MainActor @Suite(.scratch) struct ArtifactPresentationTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func surface(_ id: String, _ name: String, kind: PreviewKind = .web, position: Int) -> PreviewSurface {
        PreviewSurface(id: id, companyId: "c", name: name, kind: kind.rawValue, position: position, build: nil,
                       run: kind.usesURL ? "npm start" : nil, url: kind.usesURL ? "http://127.0.0.1:{port}/" : nil, smoke: [],
                       setById: "a1", createdAt: t0, updatedAt: t0, demo: kind == .cli ? "./demo" : nil)
    }

    static func state(_ id: String, _ status: PreviewStatus, commit: String? = "abcdef1234567", url: String? = nil, pid: Int32? = nil,
                      message: String? = nil, log: String? = nil, simulatorId: String? = nil, outputPath: String? = nil,
                      smoke: [SmokeResult] = []) -> PreviewState {
        PreviewState(surfaceId: id, companyId: "c", status: status, commit: commit, resolvedURL: url, pid: pid, message: message,
                     logPath: log, updatedAt: t0, simulatorId: simulatorId, outputPath: outputPath, smokeResults: smoke)
    }

    static func artifact(_ n: Int, kind: ArtifactKind = .html, entry: String = "index.html") -> Artifact {
        Artifact(id: "ar\(n)", companyId: "c", number: n, title: "Thing \(n)", kind: kind, storedPath: ".brahma/artifacts/\(n)-thing",
                 entryFile: entry, sourcePath: "/ws/x", publishedById: "a1", itemId: nil, bytes: 10, createdAt: t0)
    }

    static func snap(_ pairs: [(PreviewSurface, PreviewState?)], artifacts: [Artifact] = [], live: URL? = nil,
                     openAPI: [String: PreviewOpenAPI] = [:]) -> PreviewSnapshot {
        var p = PreviewSnapshot.empty
        p.surfaces = pairs.map(\.0)
        for (s, st) in pairs { if let st { p.states[s.id] = st } }
        p.live = live
        p.liveRef = live == nil ? nil : "R-3"
        p.setBy = Dictionary(uniqueKeysWithValues: pairs.map { ($0.0.id, "devops-1") })
        p.artifacts = artifacts
        p.openAPI = openAPI
        p.workspace = URL(fileURLWithPath: "/ws", isDirectory: true)
        return p
    }

    // MARK: Tabs (A7)

    @Test func tabOrderSurfaceArtifactsLive() {
        let live = URL(string: "https://acme.pages.dev")!
        let p = Self.snap([(Self.surface("s2", "api", position: 1), Self.state("s2", .building)),
                           (Self.surface("s1", "web", position: 0), Self.state("s1", .running, url: "http://127.0.0.1:47100/"))],
                          artifacts: [Self.artifact(2), Self.artifact(1)], live: live)
        let tabs = PreviewTabs.make(p)
        #expect(tabs.map(\.title) == ["WEB", "API", "ARTIFACTS", "LIVE"])
        #expect(tabs.map(\.id) == ["surface:s1", "surface:s2", PreviewTabID.artifacts, PreviewTabID.live])
        #expect(tabs[2].statusTitle == "AR-2" && tabs[2].surfaceId == nil)
        #expect(tabs[2].tone == .idle, "not a health state: a neutral chip")
        // No artifact: no ARTIFACTS tab.
        var none = p
        none.artifacts = []
        #expect(PreviewTabs.make(none).map(\.title) == ["WEB", "API", "LIVE"])
    }

    @Test func defaultShowsArtifactsBeforeAnyPreview() {
        let live = URL(string: "https://acme.pages.dev")!
        let a = Self.artifact(1)
        // One failed surface and one artifact: the artifact shows (R-192).
        let failed = Self.snap([(Self.surface("s1", "web", position: 0), Self.state("s1", .failed, message: "exit 1"))], artifacts: [a])
        #expect(PreviewTabs.defaultSelection(PreviewTabs.make(failed)) == PreviewTabID.artifacts)
        #expect(PreviewBodies.body(for: nil, snapshot: failed, logTail: { _ in [] }) == .artifact(a, all: [a]))
        // A running web wins.
        let running = Self.snap([(Self.surface("s1", "web", position: 0), Self.state("s1", .running, url: "http://127.0.0.1:47100/"))],
                                artifacts: [a])
        #expect(PreviewTabs.defaultSelection(PreviewTabs.make(running)) == "surface:s1")
        // No surfaces, a live site and artifacts: ARTIFACTS, before LIVE.
        let liveAndArtifacts = Self.snap([], artifacts: [a], live: live)
        #expect(PreviewTabs.defaultSelection(PreviewTabs.make(liveAndArtifacts)) == PreviewTabID.artifacts)
        #expect(PreviewTabs.defaultSelection(PreviewTabs.make(Self.snap([], live: live))) == PreviewTabID.live)
        #expect(PreviewTabs.defaultSelection(PreviewTabs.make(Self.snap([]))) == nil)
        // The artifacts tab shows the newest artifact, or the selected one; an unknown selection is the newest.
        let two = Self.snap([], artifacts: [Self.artifact(2), a])
        #expect(PreviewBodies.body(for: PreviewTabID.artifacts, snapshot: two, logTail: { _ in [] })
                == .artifact(Self.artifact(2), all: [Self.artifact(2), a]))
        #expect(PreviewBodies.body(for: PreviewTabID.artifacts, snapshot: two, logTail: { _ in [] }, selectedArtifactId: "ar1")
                == .artifact(a, all: [Self.artifact(2), a]))
        #expect(PreviewBodies.body(for: PreviewTabID.artifacts, snapshot: two, logTail: { _ in [] }, selectedArtifactId: "gone")
                == .artifact(Self.artifact(2), all: [Self.artifact(2), a]))
    }

    // MARK: Bodies

    @Test func bodiesForNewKinds() {
        let out = (1...10).map { "\u{1B}[32mok\u{1B}[0m \($0)" }
        let log = ["listening on 47100"]
        let tail: (URL) -> [String] = { $0.path == "/tmp/demo.out" ? out : $0.path == "/tmp/api.log" ? log : [] }
        func body(_ s: PreviewSurface, _ st: PreviewState, openAPI: [String: PreviewOpenAPI] = [:]) -> PreviewBody {
            PreviewBodies.body(for: "surface:\(s.id)", snapshot: Self.snap([(s, st)], openAPI: openAPI), logTail: tail)
        }
        // A ran CLI demo: its output as a terminal, the footer "exit <n> · <sha7>".
        let cli = Self.surface("c1", "demo", kind: .cli, position: 0)
        #expect(body(cli, Self.state("c1", .ran, message: "exit 0", outputPath: "/tmp/demo.out"))
                == .terminal(lines: out, footer: "exit 0 · abcdef1"))
        #expect(body(cli, Self.state("c1", .ran, message: "timed out after 120 s", outputPath: nil))
                == .terminal(lines: [], footer: "timed out after 120 s · abcdef1"))
        #expect(body(cli, Self.state("c1", .unavailable, message: "no sandbox"))
                == .status(title: "DEMO UNAVAILABLE", detail: "no sandbox", logTail: []))
        #expect(body(cli, Self.state("c1", .failed, message: "build failed (exit 2)", log: "/tmp/api.log"))
                == .status(title: "DEMO FAILED", detail: "build failed (exit 2)", logTail: log))

        // A running backend: smoke rows, its log tail and the operations of the engine's OpenAPI copy.
        let api = Self.surface("b1", "api", kind: .backend, position: 0)
        let smoke = [SmokeResult(url: "http://127.0.0.1:47100/health", method: "GET", status: 200, millis: 12, bodyPrefix: "ok", ok: true, error: nil),
                     SmokeResult(url: "http://127.0.0.1:47100/items", method: "POST", status: nil, millis: 3000, bodyPrefix: "", ok: false,
                                 error: "timed out")]
        let op = OpenAPIOperation(method: "GET", path: "/health", summary: "Liveness")
        let runningAPI = Self.state("b1", .running, url: "http://127.0.0.1:47100/", log: "/tmp/api.log", smoke: smoke)
        #expect(body(api, runningAPI, openAPI: ["b1": .operations([op])])
                == .backend(smoke: [SmokeRow(method: "GET", path: "/health", statusTitle: "200", millis: 12, ok: true, error: nil),
                                    SmokeRow(method: "POST", path: "/items", statusTitle: "—", millis: 3000, ok: false, error: "timed out")],
                            logTail: log, operations: [op]))
        #expect(body(api, runningAPI) == .backend(smoke: PreviewBodies.smokeRows(smoke), logTail: log, operations: []))
        #expect(body(api, runningAPI, openAPI: ["b1": .timedOut])
                == .status(title: "CAN'T SHOW THIS FILE", detail: "it took too long to read", logTail: []))
        #expect(body(api, runningAPI, openAPI: ["b1": .unreadable])
                == .status(title: "CAN'T SHOW THIS FILE", detail: "the OpenAPI file couldn't be read", logTail: []))
        #expect(body(api, runningAPI, openAPI: ["b1": .loading]) == .backend(smoke: PreviewBodies.smokeRows(smoke), logTail: log, operations: []))
        #expect(body(api, Self.state("b1", .unavailable, message: "no sandbox"))
                == .status(title: "API UNAVAILABLE", detail: "no sandbox", logTail: []))

        // Apple kinds: the Simulator's frames, or the app's window.
        let phone = Self.surface("i1", "iphone", kind: .ios, position: 0)
        #expect(body(phone, Self.state("i1", .running, simulatorId: "UDID-1")) == .simulator(udid: "UDID-1"))
        #expect(body(phone, Self.state("i1", .running)) == .status(title: "IPHONE STARTING", detail: nil, logTail: []))
        let mac = Self.surface("m1", "mac", kind: .macos, position: 0)
        #expect(body(mac, Self.state("m1", .running, pid: 4242)) == .window(pid: 4242))
        #expect(body(mac, Self.state("m1", .running)) == .status(title: "MAC STARTING", detail: nil, logTail: []))
        // The web body is unchanged.
        let web = Self.surface("s1", "web", position: 0)
        let url = URL(string: "http://127.0.0.1:47100/")!
        #expect(body(web, Self.state("s1", .running, url: url.absoluteString)) == .web(url: url, origin: url, builtBy: "@devops-1"))
    }

    // MARK: FileBody

    @Test func fileBodyModes() throws {
        let root = try tempDir()
        func file(_ name: String, bytes: Int = 16) throws -> URL {
            let url = root.appending(path: name)
            try Data(repeating: 0x41, count: min(bytes, 16)).write(to: url)
            if bytes > 16 {
                let h = try FileHandle(forWritingTo: url)
                try h.truncate(atOffset: UInt64(bytes))
                try h.close()
            }
            return url
        }
        func mode(_ name: String, _ kind: ArtifactKind, bytes: Int = 16) throws -> FileBody.Mode {
            FileBody.make(url: try file(name, bytes: bytes), kind: kind, root: root).mode
        }
        #expect(try mode("a.html", .html) == .web)
        #expect(try mode("a.md", .markdown) == .markdown)
        #expect(try mode("a.pdf", .pdf) == .quickLook)
        #expect(try mode("a.xlsx", .spreadsheet) == .quickLook)
        #expect(try mode("a.docx", .document) == .quickLook)
        #expect(try mode("a.stl", .model3d) == .quickLook)
        #expect(try mode("a.usdz", .model3d) == .quickLook)
        #expect(try mode("a.glb", .model3d, bytes: 1_048_576) == .gltf)
        #expect(try mode("a.gltf", .model3d) == .gltf)
        #expect(try mode("big.glb", .model3d, bytes: 25 * 1_048_576) == .fileCard)
        #expect(try mode("a.step", .cad) == .fileCard)
        #expect(try mode("a.mp4", .video) == .video)
        #expect(try mode("a.png", .image) == .image)
        #expect(try mode("a.svg", .image) == .web)
        #expect(try mode("a.csv", .table) == .table)
        #expect(try mode("a.txt", .text) == .text)
        #expect(try mode("a.swift", .code) == .text)

        let png = FileBody.make(url: try file("b.png", bytes: 2048), kind: .image, root: root)
        #expect(png.bytes == 2048 && png.kind == .image && png.root == root)
        // In-process image decoding is for owner- and engine-made files only; agent and outside files go to Quick Look.
        #expect(png.effectiveMode(for: .agent("design-1")) == .quickLook)
        #expect(png.effectiveMode(for: .external("dropped")) == .quickLook)
        #expect(png.effectiveMode(for: .owner) == .image)
        #expect(png.effectiveMode(for: .engine) == .image)
        #expect(FileBody.make(url: try file("c.html"), kind: .html, root: root).effectiveMode(for: .agent("a")) == .web)
        // A missing file has no bytes; a glTF without bytes is still the in-process mode (the renderer refuses it).
        let missing = FileBody.make(url: root.appending(path: "missing.glb"), kind: .model3d, root: root)
        #expect(missing.bytes == 0 && missing.mode == .gltf)

        // An artifact's stored path is relative to the workspace: the body's url and root are joined with it.
        let ws = try tempDir()
        let a = Self.artifact(1)
        let body = PreviewBodies.fileBody(a, workspace: ws)
        #expect(body.root == ws.appending(path: ".brahma/artifacts/1-thing", directoryHint: .isDirectory))
        #expect(body.url == ws.appending(path: ".brahma/artifacts/1-thing", directoryHint: .isDirectory)
            .appending(path: "index.html", directoryHint: .notDirectory))
        #expect(body.mode == .web && body.kind == .html && body.bytes == 0)
    }

    @Test func navigationPolicy() {
        let root = URL(fileURLWithPath: "/ws/.brahma/artifacts/1-thing", isDirectory: true)
        #expect(PreviewNavigationPolicy.allowsArtifact(URL(fileURLWithPath: "/ws/.brahma/artifacts/1-thing/index.html"), root: root))
        #expect(PreviewNavigationPolicy.allowsArtifact(URL(fileURLWithPath: "/ws/.brahma/artifacts/1-thing/css/site.css"), root: root))
        #expect(PreviewNavigationPolicy.allowsArtifact(URL(string: "about:blank")!, root: root))
        #expect(!PreviewNavigationPolicy.allowsArtifact(URL(fileURLWithPath: "/ws/.brahma/artifacts/1-thing/../2-other/index.html"), root: root))
        #expect(!PreviewNavigationPolicy.allowsArtifact(URL(fileURLWithPath: "/ws/.brahma/artifacts/1-thingy/index.html"), root: root))
        #expect(!PreviewNavigationPolicy.allowsArtifact(URL(fileURLWithPath: "/ws/.brahma/artifacts/1-thing"), root: root))
        #expect(!PreviewNavigationPolicy.allowsArtifact(URL(fileURLWithPath: "/etc/passwd"), root: root))
        #expect(!PreviewNavigationPolicy.allowsArtifact(URL(string: "http://127.0.0.1:47100/")!, root: root))
        #expect(!PreviewNavigationPolicy.allowsArtifact(URL(string: "https://evil.com/")!, root: root))
        #expect(!PreviewNavigationPolicy.allowsArtifact(URL(string: "about:srcdoc")!, root: root))
    }
}
