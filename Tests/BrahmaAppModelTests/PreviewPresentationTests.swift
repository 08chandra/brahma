import Foundation
import Testing
import BrahmaCore
@testable import BrahmaAppModel

@MainActor @Suite(.scratch) struct PreviewPresentationTests {
    static let t0 = Date(timeIntervalSince1970: 1_800_000_000)

    static func surface(_ id: String, _ name: String, position: Int, setBy: String = "a1") -> PreviewSurface {
        PreviewSurface(id: id, companyId: "c", name: name, position: position, build: nil, run: "npm start",
                       url: "http://127.0.0.1:{port}/", smoke: [], setById: setBy, createdAt: t0, updatedAt: t0)
    }

    static func state(_ id: String, _ status: PreviewStatus, commit: String? = "abcdef1234567", url: String? = nil,
                      message: String? = nil, log: String? = nil) -> PreviewState {
        PreviewState(surfaceId: id, companyId: "c", status: status, commit: commit, resolvedURL: url, message: message, logPath: log,
                     updatedAt: t0)
    }

    static func snap(_ pairs: [(PreviewSurface, PreviewState?)], live: URL? = nil) -> PreviewSnapshot {
        var p = PreviewSnapshot.empty
        p.surfaces = pairs.map(\.0)
        for (s, st) in pairs { if let st { p.states[s.id] = st } }
        p.live = live
        p.liveRef = live == nil ? nil : "R-3"
        p.setBy = Dictionary(uniqueKeysWithValues: pairs.map { ($0.0.id, "devops-1") })
        return p
    }

    @Test func tabsOrderAndLiveTab() {
        let p = Self.snap([(Self.surface("s2", "api", position: 1), Self.state("s2", .building)),
                           (Self.surface("s1", "web", position: 0), Self.state("s1", .running, url: "http://127.0.0.1:47100/"))],
                          live: URL(string: "https://acme.pages.dev")!)
        let tabs = PreviewTabs.make(p)
        #expect(tabs.map(\.title) == ["WEB", "API", "LIVE"])
        #expect(tabs.map(\.tone) == [.good, .busy, .good])
        #expect(tabs.last?.id == "live")
        #expect(PreviewTabs.defaultSelection(tabs) == "surface:s1")
        let noGood = PreviewTabs.make(Self.snap([(Self.surface("s2", "api", position: 1), Self.state("s2", .failed))],
                                                live: URL(string: "https://acme.pages.dev")!))
        #expect(PreviewTabs.defaultSelection(noGood) == "live")
        let onlyIdle = PreviewTabs.make(Self.snap([(Self.surface("s2", "api", position: 1), nil)]))
        #expect(onlyIdle.map(\.tone) == [.idle])
        #expect(PreviewTabs.defaultSelection(onlyIdle) == "surface:s2")
        #expect(PreviewTabs.defaultSelection([]) == nil)
    }

    @Test func tabIdsAreNamespaced() {
        #expect(PreviewTabID.surface("x1") == "surface:x1")
        #expect(PreviewTabID.surfaceId("surface:x1") == "x1")
        #expect(PreviewTabID.surfaceId("live") == nil)
        #expect(PreviewTabID.surfaceId("artifacts") == nil)
        #expect(PreviewTabID.live == "live" && PreviewTabID.artifacts == "artifacts" && PreviewTabID.ref == "ref")
        let p = Self.snap([(Self.surface("s1", "web", position: 0), Self.state("s1", .running, url: "http://127.0.0.1:47100/"))])
        let tabs = PreviewTabs.make(p)
        #expect(tabs.map(\.id) == ["surface:s1"])
        #expect(PreviewTabs.resolve("ref", tabs) == "surface:s1")
        #expect(PreviewTabs.resolve("surface:gone", tabs) == "surface:s1")
        #expect(PreviewTabs.resolve("surface:s1", tabs) == "surface:s1")
        #expect(SelectTarget("preview:web") == .preview(name: "web"))
        #expect(SelectTarget("preview:live") == .preview(name: "live"))
    }

    @Test func bodiesPerStatus() {
        let log = URL(fileURLWithPath: "/tmp/x.log")
        let lines = (1...50).map { "line \($0)" }
        let tail: (URL) -> [String] = { _ in lines }
        let empty = PreviewBodies.body(for: nil, snapshot: .empty, logTail: tail)
        #expect(empty == .empty("No preview yet. When DevOps sets a preview command, the product appears here."))

        func body(_ st: PreviewState) -> PreviewBody {
            PreviewBodies.body(for: "surface:s1", snapshot: Self.snap([(Self.surface("s1", "web", position: 0), st)]), logTail: tail)
        }
        #expect(body(Self.state("s1", .building, message: "npm run build", log: log.path))
                == .status(title: "BUILDING WEB AT abcdef1", detail: "npm run build", logTail: Array(lines.suffix(40))))
        #expect(body(Self.state("s1", .starting, log: log.path))
                == .status(title: "BUILDING WEB AT abcdef1", detail: nil, logTail: Array(lines.suffix(40))))
        #expect(body(Self.state("s1", .failed, message: "exit 1", log: log.path))
                == .status(title: "WEB FAILED", detail: "exit 1", logTail: Array(lines.suffix(40))))
        #expect(body(Self.state("s1", .stopped, message: "stopped by the owner", log: log.path))
                == .status(title: "WEB STOPPED", detail: "stopped by the owner", logTail: []))
        #expect(body(Self.state("s1", .idle)) == .status(title: "WEB STOPPED", detail: nil, logTail: []))
    }

    @Test func webBodyCarriesBuiltBy() {
        let live = URL(string: "https://acme.pages.dev")!
        let p = Self.snap([(Self.surface("s1", "web", position: 0), Self.state("s1", .running, url: "http://127.0.0.1:47100/"))], live: live)
        let url = URL(string: "http://127.0.0.1:47100/")!
        #expect(PreviewBodies.body(for: "surface:s1", snapshot: p, logTail: { _ in [] })
                == .web(url: url, origin: url, builtBy: "@devops-1"))
        #expect(PreviewBodies.body(for: "live", snapshot: p, logTail: { _ in [] }) == .web(url: live, origin: live, builtBy: "R-3"))
        // An unknown id is no selection: the default tab's body.
        #expect(PreviewBodies.body(for: "artifacts", snapshot: p, logTail: { _ in [] }) == .web(url: url, origin: url, builtBy: "@devops-1"))
    }

    @Test func navigationPolicy() {
        let origin = URL(string: "http://127.0.0.1:47100/")!
        #expect(PreviewNavigationPolicy.allowsWeb(URL(string: "http://127.0.0.1:47100/a")!, origin: origin))
        #expect(!PreviewNavigationPolicy.allowsWeb(URL(string: "http://127.0.0.1:47101/a")!, origin: origin))
        #expect(!PreviewNavigationPolicy.allowsWeb(URL(string: "http://evil.com")!, origin: origin))
        #expect(!PreviewNavigationPolicy.allowsWeb(URL(string: "file:///etc/passwd")!, origin: origin))
        #expect(PreviewNavigationPolicy.allowsWeb(URL(string: "about:blank")!, origin: origin))
        let live = URL(string: "https://acme.pages.dev")!
        #expect(PreviewNavigationPolicy.allowsWeb(URL(string: "https://acme.pages.dev/x")!, origin: live))
        #expect(PreviewNavigationPolicy.allowsWeb(URL(string: "https://acme.pages.dev:443/x")!, origin: live))
        #expect(!PreviewNavigationPolicy.allowsWeb(URL(string: "https://evil.pages.dev")!, origin: live))
        #expect(!PreviewNavigationPolicy.allowsWeb(URL(string: "http://acme.pages.dev/x")!, origin: live))
    }
}
